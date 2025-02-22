# Home Private Server

## **1️⃣ Install Ubuntu Server 24.04 LTS**

Download the latest Ubuntu Server version from: 🔗 [Ubuntu Server Download](https://ubuntu.com/download/server)

---

## **2️⃣ Install a Lightweight Desktop Environment (Optional)**

If you want a GUI, install **XFCE**:

```bash
sudo apt update && sudo apt install xfce4 xfce4-goodies -y
sudo reboot
```

---

## **3️⃣ Set Up Remote Access (SSH)**

To remotely access your server:

```bash
sudo apt install openssh-server -y  
sudo systemctl enable ssh  
sudo systemctl start ssh  
```

Find your server's IP:

```bash
ip a  
```

Connect via SSH from another machine:

```bash
ssh username@server-ip  
```

---

## **4️⃣ Install Nextcloud (Personal Cloud Storage)**

```bash
sudo snap install nextcloud  
```

Access Nextcloud in your browser:

```text
http://your-server-ip
```

---

## **5️⃣ Install a Media Server (Plex)**

```bash
sudo snap install plexmediaserver -y
```

Access Plex in your browser:

```text
http://your-server-ip:32400
```

---

## **6️⃣ Install qBittorrent (For Downloading)**

```bash
sudo apt install qbittorrent-nox -y  
```

Start the service:

```bash
qbittorrent-nox  
```

Access qBittorrent Web UI:

```text
http://your-server-ip:8080
```

---

## **7️⃣ Enable & Configure the Firewall (UFW)**

Check firewall status:

```bash
sudo ufw status
```

If inactive, enable it:

```bash
sudo ufw enable
```

Allow essential services:

```bash
sudo ufw allow OpenSSH
sudo ufw allow 32400  # Plex
sudo ufw allow 80 443  # Web traffic (if using a web server)
sudo ufw enable
```

Verify allowed rules:

```bash
sudo ufw status numbered
```

---

## **8️⃣ Enable Automatic Security Updates**

```bash
sudo apt install unattended-upgrades -y
sudo dpkg-reconfigure unattended-upgrades
```

---

## **9️⃣ Install Fail2Ban (Protect Against Brute Force Attacks)**

```bash
sudo apt install fail2ban -y
```

Enable & start the service:

```bash
sudo systemctl enable fail2ban
sudo systemctl start fail2ban
```

---

## **🔟 Create a Non-Root User (Recommended)**

```bash
sudo adduser newuser
sudo usermod -aG sudo newuser
```

Now, you can log in with `newuser` instead of `root` for better security.

---

### ✅ **Your Home Server is Ready!**

- **📁 Personal Cloud (Nextcloud)**
- **🎥 Media Streaming (Plex)**
- **⏬ Download Manager (qBittorrent)**
- **🔐 Secured with Firewall & Fail2Ban**

Let me know if you need further improvements! 🚀

