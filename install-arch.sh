#!/bin/bash

# Arch Linux Automated Installation Script with Dotfiles
# Author: OpenAI Assistant
# Date: [Current Date]

set -e

# Variables
DISK="/dev/nvme0n1"
HOSTNAME="archlinux"
USERNAME="yup"
PASSWORD="ok"
TIMEZONE="America/Los_Angeles"
LOCALE="en_US.UTF-8"
LANGUAGE="en_US:en"
EFI_SIZE="+512M"
SWAP_SIZE="32G"
DOTFILES_REPO="https://github.com/utkarshkrsingh/.dotfiles"

# Update system clock
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
echo "root:$PASSWORD" | chpasswd

echo "Configuring pacman for parallel downloads..."
# Enable parallel downloads
sed -i 's/^#ParallelDownloads = 5/ParallelDownloads = 10/' /etc/pacman.conf

echo "Installing essential packages..."
# Install essential packages
pacman -S --noconfirm grub efibootmgr networkmanager git reflector neovim firefox

echo "Installing desktop environment and utilities..."
# Install packages required by dotfiles
pacman -S --noconfirm xorg-server xorg-xinit xorg-xwayland \
hyprland alacritty dunst eww waybar \
fish zsh neovim neofetch picom starship \
gtk3 gtk4 gtk-engine-murrine \
ttf-jetbrains-mono noto-fonts noto-fonts-emoji noto-fonts-cjk \
ttf-font-awesome ttf-nerd-fonts-symbols ttf-joypixels \
playerctl brightnessctl bluez bluez-utils pipewire pipewire-alsa pipewire-pulse pipewire-jack wireplumber \
polkit polkit-gnome

echo "Installing Intel GPU drivers..."
# Install Intel GPU drivers
pacman -S --noconfirm mesa libva-intel-driver intel-media-driver

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
echo "$USERNAME:$PASSWORD" | chpasswd

echo "Configuring sudoers file..."
# Allow wheel group sudo privileges
sed -i '/^# %wheel ALL=(ALL:ALL) ALL/s/^# //' /etc/sudoers

echo "Setting up user environment and cloning dotfiles..."
# Switch to user and clone dotfiles
su - $USERNAME <<EOL

echo "Cloning dotfiles..."
git clone --recursive $DOTFILES_REPO ~/.dotfiles

echo "Installing GNU Stow..."
sudo pacman -S --noconfirm stow

echo "Setting up dotfiles using stow..."
cd ~/.dotfiles
stow */

EOL

EOF

echo "Unmounting partitions and finishing installation..."
# Unmount and reboot
umount -R /mnt
swapoff -a

echo "Installation complete! You can now reboot your system."
