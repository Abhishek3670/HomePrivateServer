#!/bin/bash

# Nextcloud Installation Script for Ubuntu Server
# This script performs a clean Nextcloud installation with user-defined configurations

# Terminal colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Function to display colored messages
print_message() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

print_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Function to check if script is run as root
check_root() {
    if [ "$(id -u)" -ne 0 ]; then
        print_error "This script must be run as root"
        exit 1
    fi
}

# Function to generate a secure random password
generate_password() {
    < /dev/urandom tr -dc 'A-Za-z0-9!#$%&()*+,-./:;<=>?@[\]^_`{|}~' | head -c 16
}

# Function to check if a package is installed
is_package_installed() {
    dpkg -l "$1" 2>/dev/null | grep -q "^ii"
    return $?
}

# Function to check if Nextcloud is already installed
check_nextcloud_installed() {
    if [ -d "/var/www/nextcloud" ]; then
        return 0
    else
        return 1
    fi
}

# Function to remove existing Nextcloud installation
remove_nextcloud() {
    print_message "Checking for existing Nextcloud installation..."
    
    # Check if Nextcloud directory exists
    if check_nextcloud_installed; then
        print_warning "Existing Nextcloud installation found. Preparing to remove..."
        
        # Get database info if available
        if [ -f "/var/www/nextcloud/config/config.php" ]; then
            DB_NAME=$(grep -oP "(?<='dbname' => ').*?(?=')" /var/www/nextcloud/config/config.php)
            DB_USER=$(grep -oP "(?<='dbuser' => ').*?(?=')" /var/www/nextcloud/config/config.php)
            
            if [ -n "$DB_NAME" ] && [ -n "$DB_USER" ]; then
                print_message "Found database: $DB_NAME with user: $DB_USER"
            fi
        fi
        
        # Stop and disable Apache/Nginx services
        if is_package_installed "apache2"; then
            systemctl stop apache2
        fi
        
        if is_package_installed "nginx"; then
            systemctl stop nginx
        fi
        
        # Remove Nextcloud files
        print_message "Removing Nextcloud files..."
        rm -rf /var/www/nextcloud
        
        # Remove Apache/Nginx configuration files
        if [ -f "/etc/apache2/sites-available/nextcloud.conf" ]; then
            a2dissite nextcloud.conf
            rm /etc/apache2/sites-available/nextcloud.conf
        fi
        
        if [ -f "/etc/nginx/sites-available/nextcloud" ]; then
            rm /etc/nginx/sites-available/nextcloud
            if [ -L "/etc/nginx/sites-enabled/nextcloud" ]; then
                rm /etc/nginx/sites-enabled/nextcloud
            fi
        fi
        
        # Remove database if user agrees
        if [ -n "$DB_NAME" ]; then
            read -p "Do you want to remove the Nextcloud database '$DB_NAME'? (y/n): " -r remove_db
            if [[ $remove_db =~ ^[Yy]$ ]]; then
                if is_package_installed "mysql-server" || is_package_installed "mariadb-server"; then
                    mysql -e "DROP DATABASE IF EXISTS $DB_NAME;"
                    mysql -e "DROP USER IF EXISTS '$DB_USER'@'localhost';"
                    print_success "Database $DB_NAME and user $DB_USER removed"
                fi
            else
                print_warning "Database not removed. It will be reused if you specify the same name."
            fi
        fi
        
        print_success "Nextcloud removal completed"
    else
        print_message "No existing Nextcloud installation found"
    fi
}

# Function to install required dependencies
install_dependencies() {
    print_message "Updating package lists..."
    apt update
    
    print_message "Installing dependencies..."
    
    # Choose web server
    PS3="Select a web server to install: "
    select web_server in "Apache" "Nginx"; do
        case $web_server in
            Apache)
                WEBSERVER="apache2"
                break
                ;;
            Nginx)
                WEBSERVER="nginx"
                break
                ;;
            *) 
                print_error "Invalid selection"
                ;;
        esac
    done
    
    # Install selected web server
    if [ "$WEBSERVER" = "apache2" ]; then
        apt install -y apache2 libapache2-mod-php
        a2enmod rewrite headers env dir mime setenvif ssl
    else
        apt install -y nginx
    fi
    
    # Install PHP and extensions
    apt install -y php php-cli php-fpm php-json php-curl php-imap php-gd php-mysql \
    php-zip php-xml php-mbstring php-intl php-imagick php-gmp php-bcmath php-opcache
    
    # Install database server if not already installed
    if ! is_package_installed "mysql-server" && ! is_package_installed "mariadb-server"; then
        PS3="Select a database server to install: "
        select db_server in "MariaDB" "MySQL"; do
            case $db_server in
                MariaDB)
                    apt install -y mariadb-server
                    DB_SERVICE="mariadb"
                    break
                    ;;
                MySQL)
                    apt install -y mysql-server
                    DB_SERVICE="mysql"
                    break
                    ;;
                *) 
                    print_error "Invalid selection"
                    ;;
            esac
        done
    else
        if is_package_installed "mariadb-server"; then
            DB_SERVICE="mariadb"
            print_message "MariaDB is already installed"
        else
            DB_SERVICE="mysql"
            print_message "MySQL is already installed"
        fi
    fi
    
    # Install Redis for caching
    apt install -y redis-server php-redis
    
    # Install Certbot for SSL
    apt install -y certbot
    
    if [ "$WEBSERVER" = "apache2" ]; then
        apt install -y python3-certbot-apache
    else
        apt install -y python3-certbot-nginx
    fi
    
    # Install additional utilities
    apt install -y unzip curl wget bzip2 fail2ban ufw
    
    print_success "Dependencies installed successfully"
}

# Function to collect user configuration
collect_user_config() {
    print_message "Setting up configuration..."
    
    # Database configuration
    read -p "Enter database name for Nextcloud [nextcloud]: " DB_NAME
    DB_NAME=${DB_NAME:-nextcloud}
    
    read -p "Enter database username [nextcloud]: " DB_USER
    DB_USER=${DB_USER:-nextcloud}
    
    read -p "Enter database password [auto-generate]: " DB_PASS
    if [ -z "$DB_PASS" ]; then
        DB_PASS=$(generate_password)
        print_message "Generated password: $DB_PASS"
    fi
    
    # Storage path configuration
    read -p "Enter path for Nextcloud data directory [/var/www/nextcloud/data]: " DATA_DIR
    DATA_DIR=${DATA_DIR:-/var/www/nextcloud/data}
    
    # Check if directory exists
    if [ ! -d "$(dirname "$DATA_DIR")" ]; then
        print_warning "Parent directory does not exist. It will be created during installation."
    fi
    
    # Domain configuration
    read -p "Enter domain name for Nextcloud (leave empty for local access): " DOMAIN
    
    # SSL configuration
    if [ -n "$DOMAIN" ]; then
        read -p "Do you want to set up SSL with Let's Encrypt? (y/n) [y]: " -r SETUP_SSL
        SETUP_SSL=${SETUP_SSL:-y}
    else
        SETUP_SSL="n"
        print_message "Using local access, SSL setup skipped"
    fi
    
    # Admin account configuration
    read -p "Enter Nextcloud admin username [admin]: " ADMIN_USER
    ADMIN_USER=${ADMIN_USER:-admin}
    
    read -p "Enter Nextcloud admin password [auto-generate]: " ADMIN_PASS
    if [ -z "$ADMIN_PASS" ]; then
        ADMIN_PASS=$(generate_password)
        print_message "Generated admin password: $ADMIN_PASS"
    fi
    
    print_success "Configuration collected"
}

# Function to configure database
configure_database() {
    print_message "Configuring database..."
    
    # Secure the database installation if not already done
    if [ -x "$(command -v mysql_secure_installation)" ]; then
        print_message "It's recommended to run mysql_secure_installation manually if you haven't already."
    fi
    
    # Create database and user
    mysql -e "CREATE DATABASE IF NOT EXISTS $DB_NAME CHARACTER SET utf8mb4 COLLATE utf8mb4_general_ci;"
    mysql -e "CREATE USER IF NOT EXISTS '$DB_USER'@'localhost' IDENTIFIED BY '$DB_PASS';"
    mysql -e "GRANT ALL PRIVILEGES ON $DB_NAME.* TO '$DB_USER'@'localhost';"
    mysql -e "FLUSH PRIVILEGES;"
    
    print_success "Database configured successfully"
}

# Function to download and install Nextcloud
install_nextcloud() {
    print_message "Installing Nextcloud..."
    
    # Download latest Nextcloud
    cd /tmp
    NEXTCLOUD_URL="https://download.nextcloud.com/server/releases/latest.zip"
    wget -O nextcloud.zip "$NEXTCLOUD_URL"
    
    # Extract and move to web directory
    unzip -q nextcloud.zip
    mv nextcloud /var/www/
    
    # Set up data directory
    mkdir -p "$DATA_DIR"
    chown -R www-data:www-data "$DATA_DIR"
    
    # Set permissions
    chown -R www-data:www-data /var/www/nextcloud/
    find /var/www/nextcloud/ -type d -exec chmod 750 {} \;
    find /var/www/nextcloud/ -type f -exec chmod 640 {} \;
    
    print_success "Nextcloud files installed"
}

# Function to configure web server
configure_web_server() {
    print_message "Configuring web server..."
    
    if [ "$WEBSERVER" = "apache2" ]; then
        # Configure Apache
        cat > /etc/apache2/sites-available/nextcloud.conf << EOF
<VirtualHost *:80>
    ServerAdmin webmaster@localhost
EOF
        
        if [ -n "$DOMAIN" ]; then
            echo "    ServerName $DOMAIN" >> /etc/apache2/sites-available/nextcloud.conf
        fi
        
        cat >> /etc/apache2/sites-available/nextcloud.conf << EOF
    DocumentRoot /var/www/nextcloud/
    
    <Directory /var/www/nextcloud/>
        Options +FollowSymlinks
        AllowOverride All
        Require all granted
        <IfModule mod_dav.c>
            Dav off
        </IfModule>
        SetEnv HOME /var/www/nextcloud
        SetEnv HTTP_HOME /var/www/nextcloud
    </Directory>
    
    ErrorLog \${APACHE_LOG_DIR}/error.log
    CustomLog \${APACHE_LOG_DIR}/access.log combined
</VirtualHost>
EOF
        
        # Enable the site
        a2ensite nextcloud.conf
        a2dissite 000-default.conf
        
        # Enable required modules
        a2enmod rewrite
        a2enmod headers
        a2enmod env
        a2enmod dir
        a2enmod mime
        
        # Restart Apache
        systemctl restart apache2
        
    else
        # Configure Nginx
        cat > /etc/nginx/sites-available/nextcloud << EOF
server {
    listen 80;
EOF
        
        if [ -n "$DOMAIN" ]; then
            echo "    server_name $DOMAIN;" >> /etc/nginx/sites-available/nextcloud
        else
            echo "    server_name _;" >> /etc/nginx/sites-available/nextcloud
        fi
        
        cat >> /etc/nginx/sites-available/nextcloud << EOF
    
    # Add headers to serve security related headers
    add_header X-Content-Type-Options nosniff;
    add_header X-XSS-Protection "1; mode=block";
    add_header X-Robots-Tag none;
    add_header X-Download-Options noopen;
    add_header X-Permitted-Cross-Domain-Policies none;
    add_header Referrer-Policy no-referrer;
    
    # Path to the root of your Nextcloud installation
    root /var/www/nextcloud/;
    
    location = /robots.txt {
        allow all;
        log_not_found off;
        access_log off;
    }
    
    # The following 2 rules are only needed for the user_webfinger app.
    # Uncomment it if you're planning to use this app.
    #rewrite ^/.well-known/host-meta /public.php?service=host-meta last;
    #rewrite ^/.well-known/host-meta.json /public.php?service=host-meta-json last;
    
    location = /.well-known/carddav {
        return 301 \$scheme://\$host/remote.php/dav;
    }
    
    location = /.well-known/caldav {
        return 301 \$scheme://\$host/remote.php/dav;
    }
    
    location ~ /.well-known/acme-challenge {
        allow all;
    }
    
    # set max upload size
    client_max_body_size 512M;
    fastcgi_buffers 64 4K;
    
    # Enable gzip but do not remove ETag headers
    gzip on;
    gzip_vary on;
    gzip_comp_level 4;
    gzip_min_length 256;
    gzip_proxied expired no-cache no-store private no_last_modified no_etag auth;
    gzip_types application/atom+xml application/javascript application/json application/ld+json application/manifest+json application/rss+xml application/vnd.geo+json application/vnd.ms-fontobject application/x-font-ttf application/x-web-app-manifest+json application/xhtml+xml application/xml font/opentype image/bmp image/svg+xml image/x-icon text/cache-manifest text/css text/plain text/vcard text/vnd.rim.location.xloc text/vtt text/x-component text/x-cross-domain-policy;
    
    # Uncomment if your server is build with the ngx_pagespeed module
    # This module is currently not supported.
    #pagespeed off;
    
    location / {
        rewrite ^ /index.php;
    }
    
    location ~ ^/(?:build|tests|config|lib|3rdparty|templates|data)/ {
        deny all;
    }
    
    location ~ ^/(?:\\.|autotest|occ|issue|indie|db_|console) {
        deny all;
    }
    
    location ~ ^/(?:index|remote|public|cron|core/ajax/update|status|ocs/v[12]|updater/.+|oc[ms]-provider/.+)\\.php(?:\$|/) {
        fastcgi_split_path_info ^(.+\\.php)(/.*)?\$;
        include fastcgi_params;
        fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
        fastcgi_param PATH_INFO \$fastcgi_path_info;
        fastcgi_param HTTPS on;
        fastcgi_param modHeadersAvailable true;
        fastcgi_param front_controller_active true;
        fastcgi_pass unix:/var/run/php/php-fpm.sock;
        fastcgi_intercept_errors on;
        fastcgi_request_buffering off;
    }
    
    location ~ ^/(?:updater|oc[ms]-provider)(?:\$|/) {
        try_files \$uri/ =404;
        index index.php;
    }
    
    # Adding the cache control header for js, css and map files
    location ~ \\.(?:css|js|woff2?|svg|gif|map)\$ {
        try_files \$uri /index.php\$request_uri;
        add_header Cache-Control "public, max-age=15778463";
        # Add headers to serve security related headers
        add_header X-Content-Type-Options nosniff;
        add_header X-XSS-Protection "1; mode=block";
        add_header X-Robots-Tag none;
        add_header X-Download-Options noopen;
        add_header X-Permitted-Cross-Domain-Policies none;
        add_header Referrer-Policy no-referrer;
        access_log off;
    }
    
    location ~ \\.(?:png|html|ttf|ico|jpg|jpeg|bcmap)\$ {
        try_files \$uri /index.php\$request_uri;
        access_log off;
    }
}
EOF
        
        # Enable the site
        ln -sf /etc/nginx/sites-available/nextcloud /etc/nginx/sites-enabled/
        
        # Remove default config if it exists
        if [ -L /etc/nginx/sites-enabled/default ]; then
            rm /etc/nginx/sites-enabled/default
        fi
        
        # Fix php-fpm configuration for Nginx
        sed -i 's/;cgi.fix_pathinfo=1/cgi.fix_pathinfo=0/' /etc/php/*/fpm/php.ini
        
        # Restart Nginx and PHP-FPM
        systemctl restart php*-fpm
        systemctl restart nginx
    fi
    
    print_success "Web server configured"
}

# Function to configure SSL with Let's Encrypt
configure_ssl() {
    if [[ "$SETUP_SSL" =~ ^[Yy]$ ]] && [ -n "$DOMAIN" ]; then
        print_message "Setting up SSL with Let's Encrypt..."
        
        if [ "$WEBSERVER" = "apache2" ]; then
            certbot --apache -d "$DOMAIN" --non-interactive --agree-tos --email webmaster@"$DOMAIN" --redirect
        else
            certbot --nginx -d "$DOMAIN" --non-interactive --agree-tos --email webmaster@"$DOMAIN" --redirect
        fi
        
        print_success "SSL certificate installed"
    else
        print_message "SSL setup skipped"
    fi
}

# Function to install and configure Nextcloud
configure_nextcloud() {
    print_message "Configuring Nextcloud..."
    
    # Install Nextcloud using occ command
    cd /var/www/nextcloud
    sudo -u www-data php occ maintenance:install \
        --database "mysql" \
        --database-name "$DB_NAME" \
        --database-user "$DB_USER" \
        --database-pass "$DB_PASS" \
        --admin-user "$ADMIN_USER" \
        --admin-pass "$ADMIN_PASS" \
        --data-dir "$DATA_DIR"
    
    # Add a brief pause to ensure Nextcloud is fully initialized
    sleep 5
    
    # Configure trusted domains - edit config.php directly if occ command fails
    if [ -n "$DOMAIN" ]; then
        # Try using occ command first
        sudo -u www-data php occ config:system:set trusted_domains 1 --value="$DOMAIN" || {
            print_warning "Using direct config.php modification for trusted domains"
            CONFIG_FILE="/var/www/nextcloud/config/config.php"
            # Check if config file exists
            if [ -f "$CONFIG_FILE" ]; then
                # Add domain to trusted_domains array
                PATTERN="'trusted_domains' =>"
                if grep -q "$PATTERN" "$CONFIG_FILE"; then
                    # If trusted_domains exists, add new domain
                    sed -i "/trusted_domains/a\\    1 => '$DOMAIN'," "$CONFIG_FILE"
                fi
            fi
        }
    else
        SERVER_IP=$(hostname -I | awk '{print $1}')
        sudo -u www-data php occ config:system:set trusted_domains 1 --value="$SERVER_IP" || {
            print_warning "Using direct config.php modification for trusted domains"
            CONFIG_FILE="/var/www/nextcloud/config/config.php"
            if [ -f "$CONFIG_FILE" ]; then
                PATTERN="'trusted_domains' =>"
                if grep -q "$PATTERN" "$CONFIG_FILE"; then
                    sed -i "/trusted_domains/a\\    1 => '$SERVER_IP'," "$CONFIG_FILE"
                fi
            fi
        }
    fi
    
    # Configure PHP settings by editing php.ini
    print_message "Configuring PHP settings..."
    for PHP_DIR in /etc/php/*/fpm; do
        if [ -d "$PHP_DIR" ]; then
            PHP_INI="$PHP_DIR/php.ini"
            if [ -f "$PHP_INI" ]; then
                sed -i 's/memory_limit = .*/memory_limit = 512M/' "$PHP_INI"
                sed -i 's/upload_max_filesize = .*/upload_max_filesize = 10G/' "$PHP_INI"
                sed -i 's/post_max_size = .*/post_max_size = 10G/' "$PHP_INI"
                sed -i 's/max_execution_time = .*/max_execution_time = 3600/' "$PHP_INI"
                sed -i 's/max_input_time = .*/max_input_time = 3600/' "$PHP_INI"
            fi
        fi
    done
    
    # Configure Redis cache - direct config.php modification
    print_message "Configuring Redis caching..."
    CONFIG_FILE="/var/www/nextcloud/config/config.php"
    if [ -f "$CONFIG_FILE" ]; then
        # Check if 'memcache.local' is already configured
        if ! grep -q "'memcache.local'" "$CONFIG_FILE"; then
            # Add Redis configuration before the closing );
            sed -i "s/);/  'memcache.local' => '\\\\OC\\\\Memcache\\\\Redis',\n  'memcache.locking' => '\\\\OC\\\\Memcache\\\\Redis',\n  'redis' => array(\n    'host' => 'localhost',\n    'port' => 6379,\n  ),\n);/" "$CONFIG_FILE"
        fi
    fi
    
    # Manual approach instead of occ commands that may fail
    print_message "Setting up cron job for background tasks..."
    # Add crontab entry for www-data user
    (crontab -u www-data -l 2>/dev/null || true; echo "*/5 * * * * php -f /var/www/nextcloud/cron.php > /dev/null 2>&1") | crontab -u www-data -
    
    # Manually edit config to set background jobs mode
    if [ -f "$CONFIG_FILE" ]; then
        if ! grep -q "'backgroundjobs_mode'" "$CONFIG_FILE"; then
            sed -i "s/);/  'backgroundjobs_mode' => 'cron',\n);/" "$CONFIG_FILE"
        fi
    fi
    
    # Restart PHP-FPM to apply changes
    systemctl restart php*-fpm
    
    # Fix permissions again after configuration
    chown -R www-data:www-data /var/www/nextcloud/
    chown -R www-data:www-data "$DATA_DIR"
    
    print_success "Nextcloud configured successfully"
}

# Function to setup security enhancements
setup_security() {
    print_message "Setting up security enhancements..."
    
    # Configure fail2ban
    if [ ! -f "/etc/fail2ban/filter.d/nextcloud.conf" ]; then
        cat > /etc/fail2ban/filter.d/nextcloud.conf << EOF
[Definition]
failregex = ^.*Login failed: '.*' \(Remote IP: '<HOST>'.*$
ignoreregex =
EOF
    fi
    
    if [ ! -f "/etc/fail2ban/jail.d/nextcloud.conf" ]; then
        cat > /etc/fail2ban/jail.d/nextcloud.conf << EOF
[nextcloud]
enabled = true
port = 80,443
protocol = tcp
filter = nextcloud
logpath = /var/www/nextcloud/data/nextcloud.log
maxretry = 3
bantime = 86400
findtime = 43200
EOF
    fi
    
    # Restart fail2ban
    systemctl restart fail2ban
    
    # Configure firewall
    print_message "Configuring firewall..."
    ufw allow ssh
    ufw allow http
    ufw allow https
    
    # Enable firewall if not already enabled
    if [ "$(ufw status | grep -c "Status: active")" -eq 0 ]; then
        echo "y" | ufw enable
    fi
    
    print_success "Security enhancements configured"
}

# Add version checking
MINIMUM_PHP_VERSION="8.0"
check_php_version() {
    PHP_VERSION=$(php -r 'echo PHP_VERSION;')
    if [ "$(printf '%s\n' "$MINIMUM_PHP_VERSION" "$PHP_VERSION" | sort -V | head -n1)" != "$MINIMUM_PHP_VERSION" ]; then
        print_error "PHP version $PHP_VERSION is less than required version $MINIMUM_PHP_VERSION"
        exit 1
    fi
}

# Function to perform final checks
final_checks() {
    print_message "Performing final checks..."
    
    # Run Nextcloud diagnostic check
    cd /var/www/nextcloud
    sudo -u www-data php occ maintenance:repair
    sudo -u www-data php occ maintenance:mode --off
    
    # Get access URL
    if [ -n "$DOMAIN" ]; then
        if [[ "$SETUP_SSL" =~ ^[Yy]$ ]]; then
            ACCESS_URL="https://$DOMAIN"
        else
            ACCESS_URL="http://$DOMAIN"
        fi
    else
        SERVER_IP=$(hostname -I | awk '{print $1}')
        ACCESS_URL="http://$SERVER_IP"
    fi
    
    print_success "Nextcloud has been successfully installed!"
    
    echo "-----------------------------------------------"
    echo "Access Information:"
    echo "URL: $ACCESS_URL"
    echo "Admin User: $ADMIN_USER"
    echo "Admin Password: $ADMIN_PASS"
    echo "Database Name: $DB_NAME"
    echo "Database User: $DB_USER"
    echo "Database Password: $DB_PASS"
    echo "Data Directory: $DATA_DIR"
    echo "-----------------------------------------------"
    
    echo "Recommended next steps:"
    echo "1. Enable two-factor authentication for the admin account"
    echo "2. Configure a backup solution for your Nextcloud data"
    echo "3. Review and update your PHP and web server configurations if needed"
    echo "4. Configure a separate trusted domain for remote access if needed"
    echo "-----------------------------------------------"
}

# Main function to execute the installation process
main() {
    print_message "Starting Nextcloud installation script"
    
    # Check if running as root
    check_root
    
    # Remove existing installation if any
    remove_nextcloud
    
    # Install required dependencies
    install_dependencies
    
    # Collect user configuration
    collect_user_config
    
    # Configure database
    configure_database
    
    # Install Nextcloud
    install_nextcloud
    
    # Configure web server
    configure_web_server
    
    # Configure SSL with Let's Encrypt if requested
    configure_ssl
    
    # Configure Nextcloud
    configure_nextcloud
    
    # Set up security enhancements
    setup_security

    # Perform final checks
    final_checks
    
    print_message "Installation process completed"
}

# Execute main function
main