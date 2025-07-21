#!/bin/bash
# vps2suse-tumbleweed - Modified for Chris Garb's VPS requirements - DS

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
USERNAME="${credentials.username}"
PASSWORD="${credentials.password}" # Set this or prompt during installation
HOSTNAME="${credentials.hostname}"
TIMEZONE="America/New_York"
LOCALE="en_US.UTF-8"
KEYBOARD="us"
SWAP_SIZE="8G" # 8GB swap (half of your 16GB RAM)
XFS_SIZE="50G" # 50GB XFS partition
BOOT_SIZE="512M" # UEFI boot partition
GRUB_TIMEOUT="15" # 15-second GRUB timeout

# Desktop environments to install
DESKTOP_ENVS="enlightenment budgie lxqt"
REMOTE_DESKTOP_PACKAGES="tigervnc xorg-x11-server tightvnc"

# Required patterns
PATTERNS="yast2_basis yast2_server cockpit enlightenment budgie lxqt"

# Check if we're root
if [ "$(id -u)" != "0" ]; then
    echo "This script must be run as root" 1>&2
    exit 1
fi

# Prompt for password if not set
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

# Partitioning setup
echo "Setting up disk partitions..."
DEVICE=$(lsblk -d -p -n -l -o NAME -e 7,11)
PARTITION_BOOT="${DEVICE}1"
PARTITION_ROOT="${DEVICE}2"
PARTITION_XFS="${DEVICE}3"
PARTITION_SWAP="${DEVICE}4"

# Clear existing partition table and create new one
wipefs -a "$DEVICE"
parted -s "$DEVICE" mklabel gpt
parted -s "$DEVICE" mkpart primary fat32 1MiB $BOOT_SIZE
parted -s "$DEVICE" set 1 esp on
parted -s "$DEVICE" mkpart primary btrfs $BOOT_SIZE -$((XFS_SIZE + SWAP_SIZE))
parted -s "$DEVICE" mkpart primary xfs -$((XFS_SIZE + SWAP_SIZE)) -$SWAP_SIZE
parted -s "$DEVICE" mkpart primary linux-swap -$SWAP_SIZE 100%

# Create filesystems
echo "Creating filesystems..."
mkfs.fat -F32 "$PARTITION_BOOT"
mkfs.btrfs -f "$PARTITION_ROOT"
mkfs.xfs -f "$PARTITION_XFS"
mkswap "$PARTITION_SWAP"

# Setup LVM and BTRFS
echo "Setting up LVM and BTRFS..."
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

# Mount filesystems
echo "Mounting filesystems..."
mount /dev/vg_root/lv_root /mnt
mkdir -p /mnt/{boot,home,var,opt,xfs}
mount "$PARTITION_BOOT" /mnt/boot
mount /dev/vg_root/lv_home /mnt/home
mount /dev/vg_root/lv_var /mnt/var
mount /dev/vg_root/lv_opt /mnt/opt
mount "$PARTITION_XFS" /mnt/xfs
swapon "$PARTITION_SWAP"

# Install base system
echo "Installing base system..."
zypper --non-interactive --root /mnt install --no-recommends \
    patterns-base-base \
    patterns-base-enhanced_base \
    patterns-base-minimal_base \
    patterns-base-sw_management \
    patterns-server-server \
    patterns-yast-yast2_basis \
    patterns-yast-yast2_server \
    $PATTERNS

# Install desktop environments
echo "Installing desktop environments..."
for env in $DESKTOP_ENVS; do
    zypper --non-interactive --root /mnt install --no-recommends \
        patterns-x11-x11_${env}
done

# Install remote desktop packages
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

# Configure firewall
echo "Configuring firewall..."
chroot /mnt firewall-cmd --permanent --add-service=ssh
chroot /mnt firewall-cmd --permanent --add-service=http
chroot /mnt firewall-cmd --permanent --add-service=https
chroot /mnt firewall-cmd --permanent --add-service=cockpit
chroot /mnt firewall-cmd --permanent --add-port=3389/tcp # RDP
chroot /mnt firewall-cmd --permanent --add-port=5901/tcp # VNC
chroot /mnt firewall-cmd --reload

# Final steps
echo "Finalizing installation..."
umount -R /mnt
swapoff "$PARTITION_SWAP"

echo "Installation complete! Reboot your system to start using OpenSUSE Tumbleweed."
echo "You can connect via:"
echo "1. SSH: ssh $USERNAME@$HOSTNAME"
echo "2. Cockpit: https://$HOSTNAME:9090"
echo "3. RDP: Connect to $HOSTNAME:3389"
echo "4. VNC: Connect to $HOSTNAME:5901"