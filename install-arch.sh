#!/bin/bash

# Arch Linux Automated Installation Script without Initial Dotfiles
# Author: Grok 2 by xAI
# Date: 2024-12-30

set -e

# Variables
DISK="/dev/nvme0n1"  # Change this if your NVMe is different
HOSTNAME="archlinux"
USERNAME="yup"
PASSWORD="ok"
TIMEZONE="America/Los_Angeles"
LOCALE="en_US.UTF-8"
LANGUAGE="en_US:en"
EFI_SIZE="+512M"
SWAP_SIZE="20G"
DOTFILES_REPO="https://github.com/utkarshkrsingh/.dotfiles"

# Function to prompt for password
prompt_for_password() {
    read -r -s -p "Enter password for root and user $USERNAME: " PASSWORD
    echo
    if [ -z "$PASSWORD" ]; then
        echo "Password cannot be empty."
        exit 1
    fi
}

# Ensure script runs as root
if [ "$(id -u)" -ne 0 ]; then
   echo "This script must be run as root"
   exit 1
fi

# Prompt for password
prompt_for_password

echo "Updating system clock..."
timedatectl set-ntp true

echo "Partitioning the disk..."
# Partition the disk
sgdisk -Z $DISK  # Zap all on disk
sgdisk -n 1:0:${EFI_SIZE} -t 1:ef00 -c 1:"EFI System Partition" $DISK
sgdisk -n 2:0:+${SWAP_SIZE} -t 2:8200 -c 2:"Linux Swap" $DISK
sgdisk -n 3:0:0 -t 3:8300 -c 3:"Linux filesystem" $DISK

echo "Formatting the partitions..."
# Format the partitions
mkfs.fat -F32 "${DISK}p1"
mkswap "${DISK}p2"
mkfs.btrfs -f "${DISK}p3"

echo "Mounting the file systems..."
# Mount the root partition
mount "${DISK}p3" /mnt

# Create Btrfs subvolumes
btrfs su cr /mnt/@
btrfs su cr /mnt/@home
btrfs su cr /mnt/@var
btrfs su cr /mnt/@tmp
btrfs su cr /mnt/@.snapshots
umount /mnt

# Mount subvolumes with compression
mount -o noatime,compress=zstd,space_cache=v2,discard=async,subvol=@ "${DISK}p3" /mnt
mkdir -p /mnt/{boot/efi,home,var,tmp,.snapshots}
mount -o noatime,compress=zstd,space_cache=v2,discard=async,subvol=@home "${DISK}p3" /mnt/home
mount -o noatime,compress=zstd,space_cache=v2,discard=async,subvol=@var "${DISK}p3" /mnt/var
mount -o noatime,compress=zstd,space_cache=v2,discard=async,subvol=@tmp "${DISK}p3" /mnt/tmp
mount -o noatime,compress=zstd,space_cache=v2,discard=async,subvol=@.snapshots "${DISK}p3" /mnt/.snapshots

# Mount EFI partition
mount "${DISK}p1" /mnt/boot/efi

# Enable swap
swapon "${DISK}p2"

echo "Updating mirrorlist with the fastest servers..."
# Update mirrorlist
pacman -Sy --noconfirm reflector
reflector --country 'United States' --age 12 --protocol https --sort rate --save /etc/pacman.d/mirrorlist

echo "Installing the base system..."
# Install base packages
pacstrap /mnt base linux linux-firmware btrfs-progs intel-ucode

echo "Generating fstab..."
# Generate fstab
genfstab -U /mnt >> /mnt/etc/fstab

echo "Chrooting into the new system..."
# Chroot into the system
arch-chroot /mnt /bin/bash <<EOF

echo "Setting up time zone..."
# Set time zone
ln -sf /usr/share/zoneinfo/$TIMEZONE /etc/localtime
hwclock --systohc

echo "Configuring localization..."
# Localization
echo "$LOCALE UTF-8" >> /etc/locale.gen
locale-gen
echo "LANG=$LOCALE" > /etc/locale.conf

echo "Configuring hostname and hosts file..."
# Network configuration
echo "$HOSTNAME" > /etc/hostname
cat >> /etc/hosts <<EOL
127.0.0.1   localhost
::1         localhost
127.0.1.1   $HOSTNAME.localdomain $HOSTNAME
EOL

echo "Generating initramfs..."
# Initramfs
mkinitcpio -P

echo "Setting root password..."
# Set root password
echo -e "$PASSWORD\n$PASSWORD" | passwd

echo "Configuring pacman for parallel downloads..."
# Enable parallel downloads
sed -i 's/^#ParallelDownloads = 5/ParallelDownloads = 10/' /etc/pacman.conf

echo "Installing essential packages..."
# Install essential packages
pacman -S --noconfirm grub efibootmgr networkmanager git reflector neovim firefox

echo "Installing desktop environment and utilities..."
# Install packages required by dotfiles
pacman -S --noconfirm xorg-server xorg-xinit xorg-xwayland \
hyprland kitty dunst eww waybar \
zsh vim neovim neofetch picom \
gtk3 gtk4 gtk-engine-murrine \
ttf-jetbrains-mono noto-fonts noto-fonts-emoji noto-fonts-cjk \
ttf-font-awesome ttf-nerd-fonts-symbols ttf-joypixels \
playerctl brightnessctl bluez bluez-utils pipewire pipewire-alsa pipewire-pulse pipewire-jack wireplumber \
polkit polkit-gnome

echo "Installing Intel GPU drivers..."
# Install Intel GPU drivers
pacman -S --noconfirm mesa libva-intel-driver intel-media-driver opencl

echo "Installing GRUB bootloader..."
# Install bootloader
grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=GRUB
grub-mkconfig -o /boot/grub/grub.cfg

echo "Enabling services..."
# Enable NetworkManager and Bluetooth
systemctl enable NetworkManager
systemctl enable bluetooth

echo "Creating user $USERNAME..."
# Create user
useradd -m -G wheel -s /bin/fish $USERNAME
echo -e "$PASSWORD\n$PASSWORD" | passwd $USERNAME

echo "Configuring sudoers file..."
# Allow wheel group sudo privileges
sed -i '/^# %wheel ALL=(ALL:ALL) ALL/s/^# //' /etc/sudoers

echo "Creating a systemd service for post-reboot dotfiles installation..."
cat <<SERVICE > /etc/systemd/system/dotfiles-setup.service
[Unit]
Description=Dotfiles Setup
After=network.target

[Service]
Type=oneshot
User=$USERNAME
ExecStart=/usr/bin/bash -c "[ ! -d /home/$USERNAME/.dotfiles ] && git clone $DOTFILES_REPO /home/$USERNAME/.dotfiles"
ExecStartPost=/usr/bin/bash /home/$USERNAME/.dotfiles/setup.sh
ExecStartPost=/usr/bin/rm -f /etc/systemd/system/dotfiles-setup.service
ExecStartPost=/usr/bin/systemctl daemon-reload
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
SERVICE

systemctl enable dotfiles-setup.service

EOF

echo "Unmounting partitions and finishing installation..."
umount -R /mnt
swapoff -a

echo "Installation complete. Rebooting system..."
reboot
