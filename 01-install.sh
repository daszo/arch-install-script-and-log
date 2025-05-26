#!/usr/bin/env bash

set -e

set -x

function get_password() {
  while true; do
    read -s -p "Enter password: " pass1
    echo >&2 # Echo a newline to stderr for cleaner prompt

    read -s -p "Enter password again: " pass2
    echo >&2 # Echo a newline to stderr for cleaner prompt

    if [ "$pass1" == "$pass2" ]; then
      echo "Passwords match" >&2 # Redirect this message to stderr
      echo "$pass1"              # This will go to stdout (and be captured)
      break
    else
      echo "Passwords do not match" >&2 # Redirect this message to stderr
      echo "Try again:" >&2             # Redirect this message to stderr
    fi
  done
}

set +x

echo "root password"
root_password=$(get_password)

# read -p "Enter username " username
username="daszo"

echo "password for user: $username"
user_password=$(get_password)

echo "disk encryption password (LUKS)"
luks_password=$(get_password)

set -x
# read -p "Enter hostname" hostname
hostname="Arch-t480"

timedatectl

fdisk -l

read -p "Drive: " disk

fdisk "$disk" <<EOF
g
n


+1G
t

1
n


p
w
EOF

disk_efi="$disk"p1
disk_main="$disk"p2

name_crypt_root="main"

set +x
# Encrypt the main partition
echo -n "$luks_password" | cryptsetup luksFormat --type luks2 "$disk_main" -
echo -n "$luks_password" | cryptsetup open "$disk_main" $name_crypt_root -

set -x
disk_encrypted="/dev/mapper/""$name_crypt_root"

mkfs.btrfs -f "$disk_encrypted"

mount "$disk_encrypted" /mnt

btrfs subvolume create /mnt/@
btrfs subvolume create /mnt/@home
btrfs subvolume create /mnt/@opt
btrfs subvolume create /mnt/@srv
btrfs subvolume create /mnt/@cache
btrfs subvolume create /mnt/@images
btrfs subvolume create /mnt/@log
btrfs subvolume create /mnt/@spool
btrfs subvolume create /mnt/@tmp

umount /mnt

# MOUNT_OPTS="noatime,ssd,compress=zstd,space_cache=v2,subvol="

# For encrypted SSDs, consider if you want discard
MOUNT_OPTS="noatime,ssd,compress=zstd,space_cache=v2,discard=async,subvol="

mount -o "$MOUNT_OPTS"@ "$disk_encrypted" /mnt

mkdir -p /mnt/home
mkdir -p /mnt/opt
mkdir -p /mnt/srv
mkdir -p /mnt/var/cache
mkdir -p /mnt/var/lib/libvirt/images
mkdir -p /mnt/var/log
mkdir -p /mnt/var/spool
mkdir -p /mnt/tmp

mount -o "$MOUNT_OPTS"@home "$disk_encrypted" /mnt/home
mount -o "$MOUNT_OPTS"@opt "$disk_encrypted" /mnt/opt
mount -o "$MOUNT_OPTS"@srv "$disk_encrypted" /mnt/srv
mount -o "$MOUNT_OPTS"@cache "$disk_encrypted" /mnt/var/cache
mount -o "$MOUNT_OPTS"@images "$disk_encrypted" /mnt/var/lib/libvirt/images
mount -o "$MOUNT_OPTS"@log "$disk_encrypted" /mnt/var/log
mount -o "$MOUNT_OPTS"@spool "$disk_encrypted" /mnt/var/spool
mount -o "$MOUNT_OPTS"@tmp "$disk_encrypted" /mnt/tmp

mkfs.fat -F 32 "$disk_efi"

mkdir -p /mnt/boot
# boot_dir="/efi"
boot_dir="/efi"
mkdir -p /mnt$boot_dir

mount "$disk_efi" /mnt"$boot_dir"

pacstrap -K /mnt \
  base \
  base-devel \
  linux \
  linux-firmware \
  linux-headers \
  git \
  btrfs-progs \
  grub \
  efibootmgr \
  grub-btrfs \
  inotify-tools \
  timeshift \
  vim \
  networkmanager \
  pipewire \
  pipewire-alsa \
  pipewire-pulse \
  pipewire-jack \
  wireplumber \
  reflector \
  zsh \
  zsh-completions \
  zsh-autosuggestions \
  openssh \
  man \
  sudo \
  intel-ucode

genfstab -U /mnt >>/mnt/etc/fstab

cat /mnt/etc/fstab

# Get UUID of encrypted partition
CRYPT_UUID=$(blkid -s UUID -o value "$disk_main")

arch-chroot /mnt /bin/bash <<EOF

ln -sf /usr/share/zoneinfo/Europe/Amsterdam /etc/localtime

hwclock --systohc

sed -i.bak "s/^#\s*\(en_US\.UTF-8 UTF-8\)/\1/" /etc/locale.gen

locale-gen

touch /etc/locale.conf
echo "LANG=en_US.UTF-8" >/etc/locale.conf

touch /etc/vconsole.conf
echo "KEYMAP=us" >/etc/vconsole.conf

touch /etc/hostname
echo "$hostname" > /etc/hostname

bash -c "cat <<EOZ > /etc/hosts
127.0.0.1 localhost
::1 localhost
127.0.1.1
EOZ"

sed -i '\$s/$/ $hostname/' /etc/hosts


echo "Set root password: "
echo "root:$root_password" | chpasswd

echo "set user password: "
useradd -mG wheel "$username"
echo "$username:$user_password" | chpasswd

SUDOERS_FILE_PATH="/etc/sudoers"
sed -E -i.visudo_bak 's/^([[:space:]]*)#[[:space:]]?([[:space:]]*%wheel[[:space:]]+ALL=\(ALL:ALL\)[[:space:]]+ALL)/\1\2/' /etc/sudoers

echo "Attempted to uncomment the %wheel group line in /etc/sudoers."
echo "Visudo will now perform a syntax check."

# Verify if the line is now uncommented (optional check, visudo is the main validator)
if grep -Eq "^[[:space:]]*%wheel[[:space:]]+ALL=\(ALL:ALL\)[[:space:]]+ALL" /etc/sudoers; then
  echo "Verification: %wheel group line appears to be uncommented."
else
  echo "Verification: %wheel group line does NOT appear to be uncommented as expected. Please check when visudo prompts." >&2
  # Do not exit with error here, let visudo handle it. It might be that the line wasn't there to begin with.
fi
 
# Configure mkinitcpio for encryption
sed -i 's/^HOOKS=.*/HOOKS=(base udev autodetect microcode modconf kms keyboard keymap consolefont block encrypt filesystems fsck)/' /etc/mkinitcpio.conf
mkinitcpio -P


grub-install --target=x86_64-efi --efi-directory=$boot_dir --boot-directory=/boot --bootloader-id=GRUB --recheck
# grub-install --target=x86_64-efi --efi-directory=$boot_dir --bootloader-id=GRUB --recheck

# Install GRUB with cryptodisk support
grub-mkconfig -o $boot_dir/grub/grub.cfg

#
# # Configure GRUB for encryption - CRITICAL FIXES HERE
# # 1. Enable cryptodisk support
# sed -i 's/^#GRUB_ENABLE_CRYPTODISK=.*/GRUB_ENABLE_CRYPTODISK=y/' /etc/default/grub
# # If the line doesn't exist, add it
# grep -q "GRUB_ENABLE_CRYPTODISK" /etc/default/grub || echo "GRUB_ENABLE_CRYPTODISK=y" >> /etc/default/grub

# Set the kernel parameters with proper UUID substitution
sed -i "s|^GRUB_CMDLINE_LINUX_DEFAULT=.*|GRUB_CMDLINE_LINUX_DEFAULT=\"loglevel=3 quiet cryptdevice=UUID=$CRYPT_UUID:$name_crypt_root root=$disk_encrypted\"|" /etc/default/grub

#
# Also set GRUB_CMDLINE_LINUX in case it's needed
# sed -i "s|^GRUB_CMDLINE_LINUX=.*|GRUB_CMDLINE_LINUX=\"cryptdevice=UUID=$CRYPT_UUID:$name_crypt_root\"|" /etc/default/grub

# Install GRUB with cryptodisk support
grub-mkconfig -o $boot_dir/grub/grub.cfg

systemctl enable NetworkManager
EOF

rsync -aAXHv --progress "/root/arch-setup-profiles/profiles" "/mnt/"

umount -R /mnt
cryptsetup close cryptroot

exit
