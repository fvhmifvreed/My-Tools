#!/bin/bash

# Exit on any error
set -e

# Variables
DOMAIN="aldosan.site"
SERVER_IP="80.240.25.238"
DB_NAME="mailserver"
MAIL_USERS=("info" "noreply")
CERTBOT_EMAIL="admin@$DOMAIN"

# Generate secure passwords
MYSQL_PASS=$(openssl rand -base64 16)
MAIL_PASS=$(openssl rand -base64 16)

# Function to handle errors
error_exit() {
    echo "Error: $1" 1>&2
    exit 1
}

# Update and install necessary packages
echo "Updating system and installing required packages..."
sudo apt update || error_exit "Failed to update package list"
sudo apt install -y postfix dovecot-core dovecot-imapd dovecot-mysql mysql-server certbot openssl || error_exit "Failed to install necessary packages"

# MySQL Configuration
echo "Configuring MySQL database for virtual mailboxes..."

# Secure MySQL installation
sudo mysql_secure_installation <<EOF

y
$MYSQL_PASS
$MYSQL_PASS
y
y
y
y
EOF

# Create database and user
sudo mysql -e "CREATE DATABASE IF NOT EXISTS $DB_NAME;" || error_exit "Failed to create MySQL database"
sudo mysql -e "CREATE USER IF NOT EXISTS 'mailuser'@'localhost' IDENTIFIED BY '$MYSQL_PASS';" || error_exit "Failed to create MySQL user"
sudo mysql -e "GRANT ALL PRIVILEGES ON $DB_NAME.* TO 'mailuser'@'localhost';" || error_exit "Failed to grant MySQL privileges"
sudo mysql -e "FLUSH PRIVILEGES;" || error_exit "Failed to flush MySQL privileges"

# Create MySQL tables
echo "Creating MySQL tables for virtual domains and users..."
sudo mysql -D $DB_NAME -e "
CREATE TABLE IF NOT EXISTS virtual_domains (
  id INT NOT NULL AUTO_INCREMENT,
  name VARCHAR(50) NOT NULL UNIQUE,
  PRIMARY KEY (id)
);" || error_exit "Failed to create virtual_domains table"

sudo mysql -D $DB_NAME -e "
CREATE TABLE IF NOT EXISTS virtual_users (
  id INT NOT NULL AUTO_INCREMENT,
  domain_id INT NOT NULL,
  email VARCHAR(100) NOT NULL,
  password VARCHAR(100) NOT NULL,
  PRIMARY KEY (id),
  FOREIGN KEY (domain_id) REFERENCES virtual_domains(id)
);" || error_exit "Failed to create virtual_users table"

sudo mysql -D $DB_NAME -e "
CREATE TABLE IF NOT EXISTS virtual_aliases (
  id INT NOT NULL AUTO_INCREMENT,
  domain_id INT NOT NULL,
  source VARCHAR(100) NOT NULL,
  destination VARCHAR(100) NOT NULL,
  PRIMARY KEY (id),
  FOREIGN KEY (domain_id) REFERENCES virtual_domains(id)
);" || error_exit "Failed to create virtual_aliases table"

# Check if domain already exists in virtual_domains table
DOMAIN_ID=$(sudo mysql -D $DB_NAME -sse "SELECT id FROM virtual_domains WHERE name='$DOMAIN' LIMIT 1;")

# Insert domain into virtual_domains table if it doesn't exist
if [[ -z "$DOMAIN_ID" ]]; then
    echo "Inserting domain '$DOMAIN' into virtual_domains table..."
    sudo mysql -D $DB_NAME -e "INSERT INTO virtual_domains (name) VALUES ('$DOMAIN');" || error_exit "Failed to insert domain into virtual_domains table"

    # Retrieve the domain ID again after insertion
    DOMAIN_ID=$(sudo mysql -D $DB_NAME -sse "SELECT id FROM virtual_domains WHERE name='$DOMAIN' LIMIT 1;")
    if [[ -z "$DOMAIN_ID" || ! "$DOMAIN_ID" =~ ^[0-9]+$ ]]; then
        error_exit "Failed to retrieve DOMAIN_ID after inserting into virtual_domains table"
    fi
else
    echo "Domain '$DOMAIN' already exists with DOMAIN_ID: $DOMAIN_ID"
fi

echo "DOMAIN_ID retrieved: $DOMAIN_ID"

# Insert email users into virtual_users table
for user in "${MAIL_USERS[@]}"; do
  HASHED_PASS=$(openssl passwd -1 $MAIL_PASS)
  echo "Inserting user '${user}@${DOMAIN}' into virtual_users table..."
  sudo mysql -D $DB_NAME -e "
  INSERT INTO virtual_users (domain_id, email, password)
  VALUES ($DOMAIN_ID, '${user}@$DOMAIN', '$HASHED_PASS')
  ON DUPLICATE KEY UPDATE password='$HASHED_PASS';" || error_exit "Failed to insert user ${user}@${DOMAIN} into virtual_users table"
done

# Configure Postfix
echo "Configuring Postfix..."
sudo postconf -e "myhostname = mail.$DOMAIN"
sudo postconf -e "mydestination = \$myhostname, localhost.$DOMAIN, localhost"
sudo postconf -e "virtual_mailbox_domains = mysql:/etc/postfix/mysql-virtual-mailbox-domains.cf"
sudo postconf -e "virtual_mailbox_maps = mysql:/etc/postfix/mysql-virtual-mailbox-maps.cf"
sudo postconf -e "virtual_alias_maps = mysql:/etc/postfix/mysql-virtual-alias-maps.cf"
sudo postconf -e "mynetworks = 127.0.0.0/8, $SERVER_IP"
sudo postconf -e "smtpd_tls_cert_file=/etc/letsencrypt/live/mail.$DOMAIN/fullchain.pem"
sudo postconf -e "smtpd_tls_key_file=/etc/letsencrypt/live/mail.$DOMAIN/privkey.pem"
sudo postconf -e "smtpd_use_tls=yes"

# Create MySQL config files for Postfix
echo "Creating Postfix MySQL configuration files..."

sudo tee /etc/postfix/mysql-virtual-mailbox-domains.cf > /dev/null <<EOF
user = mailuser
password = $MYSQL_PASS
hosts = 127.0.0.1
dbname = $DB_NAME
query = SELECT 1 FROM virtual_domains WHERE name='%s'
EOF

sudo tee /etc/postfix/mysql-virtual-mailbox-maps.cf > /dev/null <<EOF
user = mailuser
password = $MYSQL_PASS
hosts = 127.0.0.1
dbname = $DB_NAME
query = SELECT 1 FROM virtual_users WHERE email='%s'
EOF

sudo tee /etc/postfix/mysql-virtual-alias-maps.cf > /dev/null <<EOF
user = mailuser
password = $MYSQL_PASS
hosts = 127.0.0.1
dbname = $DB_NAME
query = SELECT destination FROM virtual_aliases WHERE source='%s'
EOF

sudo systemctl restart postfix || error_exit "Failed to restart Postfix"

# Configure Dovecot
echo "Configuring Dovecot..."
sudo tee /etc/dovecot/dovecot.conf > /dev/null <<EOF
protocols = imap
mail_location = maildir:/var/mail/vhosts/%d/%n
passdb {
  driver = sql
  args = /etc/dovecot/dovecot-sql.conf.ext
}
userdb {
  driver = static
  args = uid=vmail gid=vmail home=/var/mail/vhosts/%d/%n
}
ssl_cert = </etc/letsencrypt/live/mail.$DOMAIN/fullchain.pem
ssl_key = </etc/letsencrypt/live/mail.$DOMAIN/privkey.pem
ssl = yes
EOF

sudo tee /etc/dovecot/dovecot-sql.conf.ext > /dev/null <<EOF
driver = mysql
connect = host=127.0.0.1 dbname=$DB_NAME user=mailuser password=$MYSQL_PASS
default_pass_scheme = MD5-CRYPT
password_query = SELECT email as user, password FROM virtual_users WHERE email='%u';
EOF

# Set up directories for virtual mailboxes
echo "Setting up virtual mailbox directories..."
sudo groupadd -g 5000 vmail || true
sudo useradd -g vmail -u 5000 vmail -d /var/mail || true
sudo mkdir -p /var/mail/vhosts/$DOMAIN/info
sudo mkdir -p /var/mail/vhosts/$DOMAIN/noreply
sudo chown -R vmail:vmail /var/mail/vhosts

sudo systemctl restart dovecot || error_exit "Failed to restart Dovecot"

# Obtain SSL certificate with Let's Encrypt
echo "Obtaining SSL certificate for mail.$DOMAIN..."
sudo certbot certonly --standalone -d mail.$DOMAIN --email $CERTBOT_EMAIL --agree-tos --non-interactive || error_exit "Failed to obtain SSL certificate"

# Open necessary ports in firewall
echo "Configuring firewall..."
sudo ufw allow 25 || error_exit "Failed to open port 25 (SMTP)"
sudo ufw allow 587 || error_exit "Failed to open port 587 (SMTP with TLS)"
sudo ufw allow 143 || error_exit "Failed to open port 143 (IMAP)"
sudo ufw allow 993 || error_exit "Failed to open port 993 (IMAPS)"

# Reload firewall
sudo ufw reload || error_exit "Failed to reload firewall"

# Display generated credentials and IMAP configuration
echo "======================================"
echo "         Mail Server Setup Complete!  "
echo "======================================"
echo "MySQL Password: $MYSQL_PASS"
echo "Postfix DB User: mailuser"
echo "Postfix DB Password: $MYSQL_PASS"
echo "Email Users: info@$DOMAIN, noreply@$DOMAIN"
echo "Email Password: $MAIL_PASS"
echo ""
echo "IMAP Configuration for Email Clients:"
echo "--------------------------------------"
echo "IMAP Server: mail.$DOMAIN"
echo "IMAP Port: 993 (SSL/TLS enabled)"
echo "SMTP Server: mail.$DOMAIN"
echo "SMTP Port: 587 (STARTTLS enabled)"
echo "Username: info@$DOMAIN or noreply@$DOMAIN"
echo "Password: $MAIL_PASS"
echo "SSL Certificate: Configured for mail.$DOMAIN"
echo "--------------------------------------"
echo "======================================"
