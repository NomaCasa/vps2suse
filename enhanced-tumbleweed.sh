#!/bin/bash
# vps2suse-tumbleweed-enhanced - With NoVNC, Nginx, and Let's Encrypt

# Load secrets securely
SECRETS_FILE="$(dirname "$0")/.secrets"
if [ ! -f "$SECRETS_FILE" ]; then
  echo "Error: .secrets file not found!" >&2
  exit 1
fi

# Read secrets
source "$SECRETS_FILE"

# Now use variables like:
# USERNAME="${credentials.username}"
# PASSWORD="${credentials.password}"
# etc.

set -e

# Configuration variables
USERNAME="chrisgarb"
PASSWORD="" # Set this or prompt during installation
HOSTNAME="vps.chrisgarb.com"
DOMAIN="vps.chrisgarb.com" # For Let's Encrypt
CLOUDFLARE_EMAIL="" # Your Cloudflare email
CLOUDFLARE_API_KEY="" # Your Cloudflare API key
TIMEZONE="America/New_York"
LOCALE="en_US.UTF-8"
KEYBOARD="us"
SWAP_SIZE="8G"
XFS_SIZE="50G"
BOOT_SIZE="512M"
GRUB_TIMEOUT="15"

# Desktop environments
DESKTOP_ENVS="enlightenment budgie lxqt"
REMOTE_DESKTOP_PACKAGES="tigervnc xorg-x11-server tightvnc websockify novnc"

# Required patterns
PATTERNS="yast2_basis yast2_server cockpit enlightenment budgie lxqt"

# Web stack packages
WEB_PACKAGES="nginx python3-certbot-dns-cloudflare"

# Check if we're root
if [ "$(id -u)" != "0" ]; then
    echo "This script must be run as root" 1>&2
    exit 1
fi

# Prompt for missing credentials
if [ -z "$PASSWORD" ]; then
    read -s -p "Enter password for $USERNAME: " PASSWORD
    echo
    read -s -p "Confirm password: " PASSWORD_CONFIRM
    echo
    if [ "$PASSWORD" != "$PASSWORD_CONFIRM" ]; then
        echo "Passwords do not match!" 1>&2
        exit 1
    fi
fi

if [ -z "$CLOUDFLARE_EMAIL" ]; then
    read -p "Enter Cloudflare email: " CLOUDFLARE_EMAIL
fi

if [ -z "$CLOUDFLARE_API_KEY" ]; then
    read -s -p "Enter Cloudflare API key: " CLOUDFLARE_API_KEY
    echo
fi

# Upgrade from Leap 15.6 to Tumbleweed
echo "Starting upgrade from Leap 15.6 to Tumbleweed..."
zypper --non-interactive ar -f -c https://download.opensuse.org/tumbleweed/repo/oss/ oss
zypper --non-interactive ar -f -c https://download.opensuse.org/tumbleweed/repo/non-oss/ non-oss
zypper --non-interactive ar -f -c https://download.opensuse.org/update/tumbleweed/ update
zypper --non-interactive ar -f -d -c https://download.opensuse.org/distribution/leap/15.6/repo/oss/ leap-oss
zypper --non-interactive ar -f -d -c https://download.opensuse.org/distribution/leap/15.6/repo/non-oss/ leap-non-oss
zypper --non-interactive ar -f -d -c https://download.opensuse.org/update/leap/15.6/oss/ leap-update

# Refresh repos and dist-upgrade
zypper --non-interactive --gpg-auto-import-keys ref
zypper --non-interactive dup --allow-vendor-change --from oss --from non-oss --from update

# Set hostname and timezone
echo "Setting hostname and timezone..."
hostnamectl set-hostname "$HOSTNAME"
timedatectl set-timezone "$TIMEZONE"

# Configure locale
echo "Configuring locale..."
sed -i "s/^RC_LANG=.*/RC_LANG=$LOCALE/" /etc/sysconfig/language
echo "LANG=$LOCALE" > /etc/locale.conf
localectl set-locale LANG=$LOCALE
localectl set-keymap $KEYBOARD

# Partitioning setup (same as before)
echo "Setting up disk partitions..."
DEVICE=$(lsblk -d -p -n -l -o NAME -e 7,11)
PARTITION_BOOT="${DEVICE}1"
PARTITION_ROOT="${DEVICE}2"
PARTITION_XFS="${DEVICE}3"
PARTITION_SWAP="${DEVICE}4"

wipefs -a "$DEVICE"
parted -s "$DEVICE" mklabel gpt
parted -s "$DEVICE" mkpart primary fat32 1MiB $BOOT_SIZE
parted -s "$DEVICE" set 1 esp on
parted -s "$DEVICE" mkpart primary btrfs $BOOT_SIZE -$((XFS_SIZE + SWAP_SIZE))
parted -s "$DEVICE" mkpart primary xfs -$((XFS_SIZE + SWAP_SIZE)) -$SWAP_SIZE
parted -s "$DEVICE" mkpart primary linux-swap -$SWAP_SIZE 100%

mkfs.fat -F32 "$PARTITION_BOOT"
mkfs.btrfs -f "$PARTITION_ROOT"
mkfs.xfs -f "$PARTITION_XFS"
mkswap "$PARTITION_SWAP"

pvcreate "$PARTITION_ROOT"
vgcreate vg_root "$PARTITION_ROOT"
lvcreate -L 20G -n lv_root vg_root
lvcreate -L 20G -n lv_home vg_root
lvcreate -L 20G -n lv_var vg_root
lvcreate -L 20G -n lv_log vg_root
lvcreate -L 20G -n lv_opt vg_root

mkfs.btrfs /dev/vg_root/lv_root
mkfs.btrfs /dev/vg_root/lv_home
mkfs.btrfs /dev/vg_root/lv_var
mkfs.btrfs /dev/vg_root/lv_log
mkfs.btrfs /dev/vg_root/lv_opt

mount /dev/vg_root/lv_root /mnt
mkdir -p /mnt/{boot,home,var,opt,xfs}
mount "$PARTITION_BOOT" /mnt/boot
mount /dev/vg_root/lv_home /mnt/home
mount /dev/vg_root/lv_var /mnt/var
mount /dev/vg_root/lv_opt /mnt/opt
mount "$PARTITION_XFS" /mnt/xfs
swapon "$PARTITION_SWAP"

# Install base system with additional web packages
echo "Installing base system..."
zypper --non-interactive --root /mnt install --no-recommends \
    patterns-base-base \
    patterns-base-enhanced_base \
    patterns-base-minimal_base \
    patterns-base-sw_management \
    patterns-server-server \
    patterns-yast-yast2_basis \
    patterns-yast-yast2_server \
    $PATTERNS \
    $WEB_PACKAGES

# Install desktop environments
echo "Installing desktop environments..."
for env in $DESKTOP_ENVS; do
    zypper --non-interactive --root /mnt install --no-recommends \
        patterns-x11-x11_${env}
done

# Install remote desktop packages including NoVNC
echo "Installing remote desktop packages..."
zypper --non-interactive --root /mnt install --no-recommends \
    $REMOTE_DESKTOP_PACKAGES \
    xrdp \
    xorg-x11-Xvnc

# Configure GRUB
echo "Configuring GRUB..."
chroot /mnt grub2-install "$DEVICE"
echo "GRUB_TIMEOUT=$GRUB_TIMEOUT" >> /mnt/etc/default/grub
chroot /mnt grub2-mkconfig -o /boot/grub2/grub.cfg

# Create user
echo "Creating user $USERNAME..."
chroot /mnt useradd -m -G wheel,users "$USERNAME"
echo "$USERNAME:$PASSWORD" | chroot /mnt chpasswd

# Enable sudo for wheel group
echo "%wheel ALL=(ALL) ALL" >> /mnt/etc/sudoers

# Enable services
echo "Enabling services..."
chroot /mnt systemctl enable sshd
chroot /mnt systemctl enable cockpit.socket
chroot /mnt systemctl enable xrdp
chroot /mnt systemctl enable nginx

# Configure VNC
echo "Configuring VNC..."
cat > /mnt/etc/systemd/system/vncserver@.service << EOF
[Unit]
Description=Remote desktop service (VNC)
After=syslog.target network.target

[Service]
Type=forking
User=$USERNAME
WorkingDirectory=/home/$USERNAME

ExecStartPre=-/usr/bin/vncserver -kill :%i > /dev/null 2>&1
ExecStart=/usr/bin/vncserver :%i -geometry 1280x800 -depth 24
ExecStop=/usr/bin/vncserver -kill :%i

[Install]
WantedBy=multi-user.target
EOF

chroot /mnt systemctl daemon-reload
chroot /mnt systemctl enable vncserver@1.service

# Configure XRDP
cat > /mnt/etc/xrdp/xrdp.ini << EOF
[globals]
bitmap_cache=yes
bitmap_compression=yes
port=3389
crypt_level=low
channel_code=1
max_bpp=24

[xrdp1]
name=VNC-Session
lib=libvnc.so
username=ask
password=ask
ip=127.0.0.1
port=5901
EOF

# Configure NoVNC
echo "Configuring NoVNC..."
mkdir -p /mnt/etc/novnc
cat > /mnt/etc/novnc/config << EOF
{
    "host": "localhost",
    "port": "5901",
    "password": "",
    "ssl_only": false,
    "cert": "/etc/ssl/novnc.pem",
    "key": "/etc/ssl/novnc.key",
    "web": "/usr/share/novnc",
    "prefer_ipv6": false
}
EOF

# Create systemd service for NoVNC
cat > /mnt/etc/systemd/system/novnc.service << EOF
[Unit]
Description=NoVNC - HTML5 VNC client
After=network.target vncserver@1.service

[Service]
Type=simple
User=nobody
ExecStart=/usr/bin/websockify --web /usr/share/novnc 6080 localhost:5901
Restart=always

[Install]
WantedBy=multi-user.target
EOF

chroot /mnt systemctl enable novnc.service

# Configure Nginx as reverse proxy
echo "Configuring Nginx..."
mkdir -p /mnt/etc/nginx/sites-available
mkdir -p /mnt/etc/nginx/sites-enabled

# Main Nginx configuration
cat > /mnt/etc/nginx/nginx.conf << EOF
user nginx;
worker_processes auto;
error_log /var/log/nginx/error.log;
pid /run/nginx.pid;

events {
    worker_connections 1024;
}

http {
    include /etc/nginx/mime.types;
    default_type application/octet-stream;
    
    log_format main '\$remote_addr - \$remote_user [\$time_local] "\$request" '
                    '\$status \$body_bytes_sent "\$http_referer" '
                    '"\$http_user_agent" "\$http_x_forwarded_for"';
    
    access_log /var/log/nginx/access.log main;
    
    sendfile on;
    tcp_nopush on;
    tcp_nodelay on;
    keepalive_timeout 65;
    types_hash_max_size 2048;
    
    include /etc/nginx/conf.d/*.conf;
    include /etc/nginx/sites-enabled/*;
}
EOF

# NoVNC proxy configuration
cat > /mnt/etc/nginx/sites-available/novnc << EOF
server {
    listen 80;
    server_name $DOMAIN;
    
    location / {
        return 301 https://\$host\$request_uri;
    }
}

server {
    listen 443 ssl http2;
    server_name $DOMAIN;
    
    ssl_certificate /etc/letsencrypt/live/$DOMAIN/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$DOMAIN/privkey.pem;
    
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_prefer_server_ciphers on;
    ssl_ciphers EECDH+AESGCM:EDH+AESGCM;
    ssl_ecdh_curve secp384r1;
    ssl_session_timeout 10m;
    ssl_session_cache shared:SSL:10m;
    ssl_session_tickets off;
    ssl_stapling on;
    ssl_stapling_verify on;
    
    location / {
        proxy_pass http://localhost:6080;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
    
    location /cockpit/ {
        proxy_pass https://localhost:9090/cockpit/;
        proxy_set_header Host \$host;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
}
EOF

# Enable the site
chroot /mnt ln -s /etc/nginx/sites-available/novnc /etc/nginx/sites-enabled/

# Configure Cloudflare DNS for Certbot
mkdir -p /mnt/etc/letsencrypt
cat > /mnt/etc/letsencrypt/cloudflare.ini << EOF
# Cloudflare API credentials used by Certbot
dns_cloudflare_email = $CLOUDFLARE_EMAIL
dns_cloudflare_api_key = $CLOUDFLARE_API_KEY
EOF

chroot /mnt chmod 600 /etc/letsencrypt/cloudflare.ini

# Create certbot renewal hook
mkdir -p /mnt/etc/letsencrypt/renewal-hooks/deploy
cat > /mnt/etc/letsencrypt/renewal-hooks/deploy/restart-nginx << EOF
#!/bin/sh
systemctl restart nginx
EOF
chroot /mnt chmod +x /etc/letsencrypt/renewal-hooks/deploy/restart-nginx

# Configure firewall
echo "Configuring firewall..."
chroot /mnt firewall-cmd --permanent --add-service=ssh
chroot /mnt firewall-cmd --permanent --add-service=http
chroot /mnt firewall-cmd --permanent --add-service=https
chroot /mnt firewall-cmd --permanent --add-service=cockpit
chroot /mnt firewall-cmd --permanent --add-port=3389/tcp # RDP
chroot /mnt firewall-cmd --permanent --add-port=5901/tcp # VNC
chroot /mnt firewall-cmd --permanent --add-port=6080/tcp # NoVNC
chroot /mnt firewall-cmd --reload

# Final steps
echo "Finalizing installation..."
umount -R /mnt
swapoff "$PARTITION_SWAP"

echo "Installation complete! After reboot, run these commands:"
echo "1. To get Let's Encrypt certificate:"
echo "   certbot certonly --dns-cloudflare --dns-cloudflare-credentials /etc/letsencrypt/cloudflare.ini -d $DOMAIN"
echo "2. To test Nginx configuration:"
echo "   nginx -t"
echo "3. To start all services:"
echo "   systemctl start nginx novnc vncserver@1 xrdp"
echo ""
echo "You can then connect via:"
echo "1. SSH: ssh $USERNAME@$DOMAIN"
echo "2. Cockpit: https://$DOMAIN/cockpit"
echo "3. RDP: Connect to $DOMAIN:3389"
echo "4. VNC: Connect to $DOMAIN:5901"
echo "5. NoVNC (Browser): https://$DOMAIN"
