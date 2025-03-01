#!/bin/bash
set -euo pipefail

# Nextcloud HDD Mounting & Optimization Script
# Purpose: Securely detect, format, mount and optimize an external drive for Nextcloud usage

# Function to safely exit on error
cleanup() {
    if [ -f "/etc/fstab.backup" ]; then
        echo "Error detected! Restoring fstab backup..."
        sudo mv /etc/fstab.backup /etc/fstab
        echo "Backup restored. No changes were made to your system."
    fi
    exit 1
}
trap cleanup ERR

# Ensure running with sudo
if [ "$EUID" -ne 0 ]; then
    echo "Please run this script with sudo."
    exit 1
fi

# Backup fstab before any changes
cp /etc/fstab /etc/fstab.backup

# Define Nextcloud data directory (customize if needed)
NEXTCLOUD_DATA="/var/www/nextcloud/data"
NEXTCLOUD_USER="www-data"
NEXTCLOUD_GROUP="www-data"

# Mount base location
MOUNT_BASE="/mnt/nextcloud-data"

# Detect external drives (both USB and SATA)
echo "Scanning for external drives..."
mapfile -t DEVICES < <(lsblk -dnpo NAME,TRAN,SIZE,MODEL | grep -E 'usb|sata' | grep -v "$(findmnt -n -o SOURCE /)" | awk '{print $1}')

# If no drives found with TRAN column, try alternative method
if [ ${#DEVICES[@]} -eq 0 ]; then
    echo "No external drives detected with transport info. Trying alternative detection..."
    mapfile -t DEVICES < <(lsblk -dno NAME | grep -E '^sd[b-z]|^nvme[0-9]n[0-9]$' | grep -v "$(findmnt -n -o SOURCE / | cut -d'/' -f3 || echo "none")" | sed 's/^/\/dev\//')
    
    if [ ${#DEVICES[@]} -eq 0 ]; then
        echo "No external drives detected. Please connect a drive and try again."
        rm -f /etc/fstab.backup
        exit 0
    fi
fi

# Display detected drives
echo "Found ${#DEVICES[@]} external drive(s):"
for i in "${!DEVICES[@]}"; do
    DEVICE="${DEVICES[$i]}"
    SIZE=$(lsblk -dno SIZE "$DEVICE")
    MODEL=$(lsblk -dno MODEL "$DEVICE" | tr -d ' ')
    echo "[$i] $DEVICE - $SIZE - $MODEL"
done

# Ask which drive to use
read -p "Select drive to use for Nextcloud [0-$((${#DEVICES[@]}-1))]: " DRIVE_INDEX
if [[ ! "$DRIVE_INDEX" =~ ^[0-9]+$ ]] || [ "$DRIVE_INDEX" -ge "${#DEVICES[@]}" ]; then
    echo "Invalid selection. Exiting."
    rm -f /etc/fstab.backup
    exit 1
fi

DEVICE="${DEVICES[$DRIVE_INDEX]}"

# Verify device exists
if [ ! -b "$DEVICE" ]; then
    echo "Error: $DEVICE is not a valid block device."
    rm -f /etc/fstab.backup
    exit 1
fi

# Check if device is already mounted
MOUNTED_PARTS=$(lsblk -no MOUNTPOINT "$DEVICE" | grep -v "^$" || true)
if [ -n "$MOUNTED_PARTS" ]; then
    echo "⚠️  Drive $DEVICE is currently mounted at: $MOUNTED_PARTS"
    read -p "Would you like to unmount it? (yes/no): " UNMOUNT
    if [ "$UNMOUNT" = "yes" ]; then
        echo "Unmounting..."
        for MOUNT in $MOUNTED_PARTS; do
            umount "$MOUNT" || true
        done
    else
        echo "Aborting."
        rm -f /etc/fstab.backup
        exit 0
    fi
fi

# Get drive size for partition table decision
DRIVE_SIZE=$(blockdev --getsize64 "$DEVICE")

SIZE=$(lsblk -dno SIZE "$DEVICE")
echo "==============================================================="
echo "⚠️  WARNING: This will erase ALL DATA on $DEVICE ($SIZE) ⚠️"
echo "==============================================================="
read -p "Are you sure you want to proceed? (Type 'YES' to confirm): " CONFIRM
if [ "$CONFIRM" != "YES" ]; then
    echo "Operation cancelled."
    rm -f /etc/fstab.backup
    exit 0
fi

# Create new partition table
echo "Creating new partition table..."
if [ "$DRIVE_SIZE" -gt "$((2**41))" ]; then
    # GPT for drives larger than 2TB
    parted -s "$DEVICE" mklabel gpt
else
    # MBR for smaller drives
    parted -s "$DEVICE" mklabel msdos
fi

# Inform kernel of partition table changes
partprobe "$DEVICE"
sleep 2

# Create partition
echo "Creating new partition..."
if [ "$DRIVE_SIZE" -gt "$((2**41))" ]; then
    # GPT for drives larger than 2TB
    parted -a optimal "$DEVICE" mkpart primary ext4 0% 100%
else
    # MBR for smaller drives
    echo -e "n\np\n1\n\n\nw" | fdisk "$DEVICE"
fi

# Get the created partition
PARTITION="${DEVICE}1"

# Wait for partition to be available
echo "Waiting for partition to be ready..."
for i in {1..10}; do
    if [ -b "$PARTITION" ]; then
        break
    fi
    sleep 1
    if [ "$i" -eq 10 ]; then
        echo "Error: Partition not created after 10 seconds."
        cleanup
    fi
done

# Format with optimized ext4 settings for Nextcloud
echo "Formatting $PARTITION with optimized settings for Nextcloud..."
mkfs.ext4 -m 0.5 -L "NextcloudData" \
    -O dir_index,extent,large_file,sparse_super,uninit_bg,has_journal \
    "$PARTITION"

# Create mount point
echo "Creating mount point at $MOUNT_BASE..."
mkdir -p "$MOUNT_BASE"

# Get UUID for consistent mounting
UUID=$(blkid -s UUID -o value "$PARTITION")
if [ -z "$UUID" ]; then
    echo "Error: Could not get UUID for $PARTITION"
    cleanup
fi

# Mount with optimized options
echo "Updating /etc/fstab for auto-mounting with optimized settings..."
echo "# Nextcloud data drive - added $(date)" >> /etc/fstab
echo "UUID=$UUID $MOUNT_BASE ext4 defaults,nofail,noatime,data=ordered,barrier=1,commit=60,nosuid,nodev,auto 0 2" >> /etc/fstab

# Test mount
echo "Testing mount..."
mount -a

# Set secure permissions for Nextcloud
echo "Setting secure Nextcloud permissions..."
chown -R "$NEXTCLOUD_USER":"$NEXTCLOUD_GROUP" "$MOUNT_BASE"
chmod -R 0770 "$MOUNT_BASE"

# Apply system optimizations for Nextcloud
echo "Applying system optimizations for Nextcloud..."
cat > /etc/sysctl.d/60-nextcloud-optimizations.conf << EOF
# File system optimizations
vm.dirty_ratio = 40
vm.dirty_background_ratio = 10
vm.swappiness = 10

# Network performance
net.core.somaxconn = 4096
net.ipv4.tcp_max_syn_backlog = 8192
net.core.netdev_max_backlog = 5000
EOF

# Apply sysctl settings
sysctl -p /etc/sysctl.d/60-nextcloud-optimizations.conf

# Create Nextcloud directory structure (optional)
read -p "Create default Nextcloud directory structure? (yes/no): " CREATE_DIRS
if [ "$CREATE_DIRS" = "yes" ]; then
    mkdir -p "$MOUNT_BASE/appdata_$(hostname -s)"
    mkdir -p "$MOUNT_BASE/files"
    mkdir -p "$MOUNT_BASE/nextcloud.log"
    chown -R "$NEXTCLOUD_USER":"$NEXTCLOUD_GROUP" "$MOUNT_BASE"/*
    chmod -R 0770 "$MOUNT_BASE"/*
    echo "Created Nextcloud directory structure with proper permissions."
fi

# Remove backup if successful
rm -f /etc/fstab.backup

echo "======================================================================"
echo "✅ Drive setup complete! Your external drive is ready for Nextcloud."
echo "======================================================================"
echo "Drive: $DEVICE"
echo "Mount point: $MOUNT_BASE"
echo "Format: ext4 (optimized for Nextcloud)"
echo ""
echo "Next steps:"
echo "1. Configure your Nextcloud installation to use this storage location:"
echo "   - Edit config.php to set 'datadirectory' => '$MOUNT_BASE'"
echo "   - Or use this as external storage in Nextcloud settings"
echo ""
echo "2. For optimal performance, run:"
echo "   sudo -u $NEXTCLOUD_USER php $NEXTCLOUD_DATA/../occ files:scan --all"
echo ""
echo "3. To check drive health periodically, install smartmontools:"
echo "   apt install smartmontools"
echo "   smartctl -a $DEVICE"
echo ""
echo "4. Monitor for errors in dmesg and syslog to catch early drive issues."