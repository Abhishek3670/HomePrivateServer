#!/bin/bash

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

# Check if running as root
if [ "$(id -u)" -ne 0 ]; then
    print_error "This script must be run as root"
    exit 1
fi

print_message "Starting Nextcloud troubleshooting..."

# Add memory and disk space checks
TOTAL_MEM=$(free -m | awk '/^Mem:/{print $2}')
FREE_DISK=$(df -h /var/www | awk 'NR==2 {print $4}')

if [ "$TOTAL_MEM" -lt 512 ]; then
    print_warning "System has less than 512MB RAM ($TOTAL_MEM MB)"
fi
    
if [[ "$FREE_DISK" =~ ^[0-9.]+G$ ]] && [ "${FREE_DISK%G}" -lt 5 ]; then
    print_warning "Less than 5GB free disk space available ($FREE_DISK)"
fi

# Get IP address
SERVER_IP=$(hostname -I | awk '{print $1}')
print_message "Server IP: $SERVER_IP"

# Check if Nextcloud directory exists
if [ -d "/var/www/nextcloud" ]; then
    print_success "Nextcloud directory exists at /var/www/nextcloud"
else
    print_error "Nextcloud directory not found at /var/www/nextcloud"
    exit 1
fi

# Check web server status
if systemctl is-active --quiet apache2; then
    print_success "Apache is running"
    WEB_SERVER="apache2"
elif systemctl is-active --quiet nginx; then
    print_success "Nginx is running"
    WEB_SERVER="nginx"
else
    print_error "No web server (Apache/Nginx) is running"
    print_message "Attempting to start web servers..."
    
    if [ -f "/etc/apache2/apache2.conf" ]; then
        systemctl start apache2
        if systemctl is-active --quiet apache2; then
            print_success "Apache started successfully"
            WEB_SERVER="apache2"
        else
            print_error "Failed to start Apache"
        fi
    fi
    
    if [ -f "/etc/nginx/nginx.conf" ]; then
        systemctl start nginx
        if systemctl is-active --quiet nginx; then
            print_success "Nginx started successfully"
            WEB_SERVER="nginx"
        else
            print_error "Failed to start Nginx"
        fi
    fi
    
    if [ -z "$WEB_SERVER" ]; then
        print_error "Could not start any web server"
        exit 1
    fi
fi

# Check PHP-FPM status
PHP_VERSION=$(ls -1 /etc/php/ | sort -V | tail -n 1)
if [ -n "$PHP_VERSION" ]; then
    if systemctl is-active --quiet "php${PHP_VERSION}-fpm"; then
        print_success "PHP-FPM (version $PHP_VERSION) is running"
    else
        print_warning "PHP-FPM (version $PHP_VERSION) is not running"
        print_message "Attempting to start PHP-FPM..."
        systemctl start "php${PHP_VERSION}-fpm"
        if systemctl is-active --quiet "php${PHP_VERSION}-fpm"; then
            print_success "PHP-FPM started successfully"
        else
            print_error "Failed to start PHP-FPM"
            exit 1
        fi
    fi
else
    print_error "No PHP version found"
    exit 1
fi

# Check web server configuration
if [ "$WEB_SERVER" = "apache2" ]; then
    if [ -f "/etc/apache2/sites-enabled/nextcloud.conf" ]; then
        print_success "Apache Nextcloud configuration is enabled"
        
        # Check for common Apache configuration issues
        if ! grep -q "AllowOverride All" "/etc/apache2/sites-enabled/nextcloud.conf"; then
            print_warning "AllowOverride All not found in Apache config"
            print_message "Fixing Apache configuration..."
            sed -i 's/AllowOverride None/AllowOverride All/g' /etc/apache2/sites-enabled/nextcloud.conf
            systemctl restart apache2
        fi
        
        # Check if mod_rewrite is enabled
        if ! apache2ctl -M 2>/dev/null | grep -q "rewrite_module"; then
            print_warning "mod_rewrite not enabled in Apache"
            print_message "Enabling mod_rewrite..."
            a2enmod rewrite
            systemctl restart apache2
        fi
    else
        print_error "Apache Nextcloud configuration is not enabled"
        
        if [ -f "/etc/apache2/sites-available/nextcloud.conf" ]; then
            print_message "Enabling Nextcloud configuration for Apache..."
            a2ensite nextcloud.conf
            systemctl restart apache2
            print_success "Apache Nextcloud configuration enabled"
        else
            print_error "Nextcloud configuration file not found for Apache"
            exit 1
        fi
    fi
elif [ "$WEB_SERVER" = "nginx" ]; then
    if [ -f "/etc/nginx/sites-enabled/nextcloud" ]; then
        print_success "Nginx Nextcloud configuration is enabled"
        
        # Check for common Nginx configuration issues
        if ! grep -q "fastcgi_pass" "/etc/nginx/sites-enabled/nextcloud"; then
            print_warning "fastcgi_pass directive not found in Nginx config"
        fi
    else
        print_error "Nginx Nextcloud configuration is not enabled"
        
        if [ -f "/etc/nginx/sites-available/nextcloud" ]; then
            print_message "Enabling Nextcloud configuration for Nginx..."
            ln -sf /etc/nginx/sites-available/nextcloud /etc/nginx/sites-enabled/
            systemctl restart nginx
            print_success "Nginx Nextcloud configuration enabled"
        else
            print_error "Nextcloud configuration file not found for Nginx"
            exit 1
        fi
    fi
fi

# Check database connection
print_message "Checking database connection..."

# Try to get database credentials from config.php
DB_USER=$(grep -oP "(?<='dbuser' => ').*?(?=')" /var/www/nextcloud/config/config.php 2>/dev/null)
DB_NAME=$(grep -oP "(?<='dbname' => ').*?(?=')" /var/www/nextcloud/config/config.php 2>/dev/null)

if [ -n "$DB_USER" ] && [ -n "$DB_NAME" ]; then
    print_message "Found database credentials: User=$DB_USER, DB=$DB_NAME"
    
    # Check if MySQL/MariaDB is running
    if systemctl is-active --quiet mysql; then
        print_success "MySQL is running"
        DB_SERVICE="mysql"
    elif systemctl is-active --quiet mariadb; then
        print_success "MariaDB is running"
        DB_SERVICE="mariadb"
    else
        print_error "No database service (MySQL/MariaDB) is running"
        print_message "Attempting to start database service..."
        
        if [ -f "/etc/mysql/my.cnf" ]; then
            systemctl start mysql
            if systemctl is-active --quiet mysql; then
                print_success "MySQL started successfully"
                DB_SERVICE="mysql"
            else
                print_error "Failed to start MySQL"
            fi
        fi
        
        if [ -f "/etc/mysql/mariadb.cnf" ]; then
            systemctl start mariadb
            if systemctl is-active --quiet mariadb; then
                print_success "MariaDB started successfully"
                DB_SERVICE="mariadb"
            else
                print_error "Failed to start MariaDB"
            fi
        fi
        
        if [ -z "$DB_SERVICE" ]; then
            print_error "Could not start any database service"
            exit 1
        fi
    fi
else
    print_warning "Could not extract database credentials from config.php"
fi

# Check permissions
print_message "Checking file permissions..."

# Check if www-data owns Nextcloud files
if [ "$(stat -c '%U' /var/www/nextcloud)" != "www-data" ]; then
    print_warning "Nextcloud directory not owned by www-data"
    print_message "Fixing permissions..."
    chown -R www-data:www-data /var/www/nextcloud/
fi

# Get data directory from config.php
DATA_DIR=$(grep -oP "(?<='datadirectory' => ').*?(?=')" /var/www/nextcloud/config/config.php 2>/dev/null)

if [ -n "$DATA_DIR" ]; then
    print_message "Found data directory: $DATA_DIR"
    
    if [ -d "$DATA_DIR" ]; then
        if [ "$(stat -c '%U' "$DATA_DIR")" != "www-data" ]; then
            print_warning "Data directory not owned by www-data"
            print_message "Fixing data directory permissions..."
            chown -R www-data:www-data "$DATA_DIR"
        else
            print_success "Data directory has correct ownership"
        fi
    else
        print_error "Data directory does not exist: $DATA_DIR"
        print_message "Creating data directory..."
        mkdir -p "$DATA_DIR"
        chown -R www-data:www-data "$DATA_DIR"
    fi
else
    print_warning "Could not extract data directory from config.php"
fi

# Check config.php validity
print_message "Checking config.php..."

CONFIG_FILE="/var/www/nextcloud/config/config.php"
if [ -f "$CONFIG_FILE" ]; then
    # Check if the config.php file has valid PHP syntax
    if php -l "$CONFIG_FILE" >/dev/null 2>&1; then
        print_success "config.php has valid PHP syntax"
    else
        print_error "config.php contains PHP syntax errors"
        print_message "Please check and fix the syntax in $CONFIG_FILE"
    fi
    
    # Check for essential configuration items
    if ! grep -q "'dbtype'" "$CONFIG_FILE" || ! grep -q "'dbname'" "$CONFIG_FILE"; then
        print_error "config.php is missing essential database configuration"
    fi
    
    # Check trusted domains
    if ! grep -q "'trusted_domains'" "$CONFIG_FILE"; then
        print_warning "No trusted domains configured in config.php"
        print_message "Adding localhost and server IP to trusted domains..."
        
        # Add trusted domains before the closing );
        sed -i "s/);/  'trusted_domains' => \n  array (\n    0 => 'localhost',\n    1 => '$SERVER_IP',\n  ),\n);/" "$CONFIG_FILE"
        print_success "Added trusted domains to config.php"
    elif ! grep -q "$SERVER_IP" "$CONFIG_FILE"; then
        print_warning "Server IP not found in trusted domains"
        # Add server IP to trusted domains
        LINE_NUM=$(grep -n "'trusted_domains'" "$CONFIG_FILE" | cut -d: -f1)
        if [ -n "$LINE_NUM" ]; then
            sed -i "$((LINE_NUM+2)) i\\    $(grep -c "=>" <(grep -A10 "'trusted_domains'" "$CONFIG_FILE")) => '$SERVER_IP'," "$CONFIG_FILE"
            print_success "Added server IP to trusted domains"
        fi
    fi
else
    print_error "config.php file not found"
    exit 1
fi

# Run Nextcloud maintenance checks
print_message "Running Nextcloud maintenance checks..."
cd /var/www/nextcloud
sudo -u www-data php occ maintenance:mode --off
sudo -u www-data php occ maintenance:repair

# Check URL access
print_message "Testing URL access..."

if command -v curl >/dev/null 2>&1; then
    HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" "http://$SERVER_IP")
    if [ "$HTTP_CODE" = "200" ] || [ "$HTTP_CODE" = "301" ] || [ "$HTTP_CODE" = "302" ]; then
        print_success "HTTP access to Nextcloud is working (HTTP code: $HTTP_CODE)"
    else
        print_warning "HTTP access to Nextcloud returns code: $HTTP_CODE"
        
        # Try with localhost
        LOCALHOST_CODE=$(curl -s -o /dev/null -w "%{http_code}" "http://localhost")
        if [ "$LOCALHOST_CODE" = "200" ] || [ "$LOCALHOST_CODE" = "301" ] || [ "$LOCALHOST_CODE" = "302" ]; then
            print_success "HTTP access to localhost is working (HTTP code: $LOCALHOST_CODE)"
            print_warning "This suggests a network or firewall issue, not a Nextcloud configuration problem"
        fi
    fi
else
    print_warning "curl not installed, skipping URL test"
fi

# Display access information
print_message "Nextcloud access information:"
echo "URL: http://$SERVER_IP"

if [ -f "$CONFIG_FILE" ]; then
    echo "Check webserver logs for more information:"
    if [ "$WEB_SERVER" = "apache2" ]; then
        echo "Apache error log: tail -f /var/log/apache2/error.log"
    elif [ "$WEB_SERVER" = "nginx" ]; then
        echo "Nginx error log: tail -f /var/log/nginx/error.log"
    fi
    echo "PHP error log: tail -f /var/log/php*-fpm.log"
fi

print_success "Troubleshooting completed"
echo ""
echo "If you still can't access Nextcloud, please try the following:"
echo "1. Check web server logs for specific errors"
echo "2. Ensure port 80 is open in your firewall"
echo "3. Verify that any proxy or network settings aren't blocking access"
echo "4. If using a domain, check your DNS settings"
echo "5. Try accessing Nextcloud at http://localhost from the server itself"