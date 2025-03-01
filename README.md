# Nextcloud Home Server Setup Guide

A comprehensive guide for setting up Nextcloud on Ubuntu Server with external storage and troubleshooting steps.

## Prerequisites

- Ubuntu Server 22.04 LTS or newer
- Minimum 1GB RAM (2GB recommended)
- At least 10GB storage space
- Root/sudo access
- External HDD/SSD (optional)
- Domain name (optional, for remote access)

## Installation Steps

### 1. System Preparation
```bash
# Update system
sudo apt update && sudo apt upgrade -y

# Install required packages
sudo apt install nginx php-fpm php-cli php-json php-curl php-imap php-gd php-mysql \
php-zip php-xml php-mbstring php-intl php-imagick php-gmp php-bcmath php-opcache \
mariadb-server redis-server php-redis unzip curl wget bzip2 fail2ban ufw certbot
```

### 2. Database Setup
```bash
# Secure MySQL installation
sudo mysql_secure_installation

# Create database and user
sudo mysql -u root -p
CREATE DATABASE nextcloud;
CREATE USER 'nextcloud'@'localhost' IDENTIFIED BY 'your_password';
GRANT ALL PRIVILEGES ON nextcloud.* TO 'nextcloud'@'localhost';
FLUSH PRIVILEGES;
EXIT;
```

### 3. Download and Install Nextcloud
```bash
# Download latest version
cd /tmp
wget https://download.nextcloud.com/server/releases/latest.zip
unzip latest.zip
sudo mv nextcloud /var/www/

# Set permissions
sudo chown -R www-data:www-data /var/www/nextcloud/
```

### 4. Configure Nginx
```bash
# Create Nginx config
sudo nano /etc/nginx/sites-available/nextcloud

# Enable site
sudo ln -s /etc/nginx/sites-available/nextcloud /etc/nginx/sites-enabled/
sudo rm /etc/nginx/sites-enabled/default
sudo nginx -t
sudo systemctl restart nginx
```

### 5. SSL Setup (Optional)
```bash
# Install SSL certificate
sudo certbot --nginx -d yourdomain.com
```

### 6. Security Enhancement
```bash
# Configure firewall
sudo ufw allow ssh
sudo ufw allow http
sudo ufw allow https
sudo ufw enable

# Setup fail2ban
sudo cp /etc/fail2ban/jail.conf /etc/fail2ban/jail.local
sudo systemctl restart fail2ban
```

## External Storage Setup

### 1. Prepare the Drive
```bash
# List available drives
lsblk

# Create partition
sudo fdisk /dev/sdX

# Format partition
sudo mkfs.ext4 /dev/sdX1

# Create mount point
sudo mkdir /mnt/nextcloud-data
```

### 2. Configure Auto-mount
```bash
# Get drive UUID
sudo blkid

# Add to fstab
sudo nano /etc/fstab
# Add line:
UUID=your-uuid /mnt/nextcloud-data ext4 defaults,nofail,noatime 0 2

# Mount drive
sudo mount -a
```

### 3. Set Permissions
```bash
sudo chown -R www-data:www-data /mnt/nextcloud-data
sudo chmod -R 0770 /mnt/nextcloud-data
```

## Troubleshooting Steps

### 1. Check System Status
```bash
# Check services
systemctl status nginx
systemctl status php*-fpm
systemctl status mysql
systemctl status redis

# Check logs
tail -f /var/log/nginx/error.log
tail -f /var/www/nextcloud/data/nextcloud.log
```

### 2. Verify Permissions
```bash
# Check ownership
ls -l /var/www/nextcloud
ls -l /mnt/nextcloud-data

# Fix permissions if needed
sudo chown -R www-data:www-data /var/www/nextcloud
sudo find /var/www/nextcloud/ -type d -exec chmod 750 {} \;
sudo find /var/www/nextcloud/ -type f -exec chmod 640 {} \;
```

### 3. Database Checks
```bash
# Test database connection
sudo -u www-data php /var/www/nextcloud/occ db:check
```

### 4. Performance Optimization
```bash
# Enable caching
sudo -u www-data php /var/www/nextcloud/occ config:system:set memcache.local --value="\OC\Memcache\Redis"
sudo -u www-data php /var/www/nextcloud/occ config:system:set memcache.distributed --value="\OC\Memcache\Redis"
```

## Maintenance Commands

```bash
# Scan files
sudo -u www-data php /var/www/nextcloud/occ files:scan --all

# Clear cache
sudo -u www-data php /var/www/nextcloud/occ cache:clear

# Update Nextcloud
sudo -u www-data php /var/www/nextcloud/occ upgrade
```

## Additional Resources

- [Official Nextcloud Documentation](https://docs.nextcloud.com/)
- [Nginx Configuration Generator](https://www.digitalocean.com/community/tools/nginx)
- [Let's Encrypt Documentation](https://letsencrypt.org/docs/)

## Notes

- Replace `yourdomain.com` with your actual domain
- Replace `your_password` with secure passwords
- Replace `/dev/sdX` with your actual drive path
- Adjust PHP memory limits if needed in php.ini
- Regular backups are highly recommended