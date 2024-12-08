#!/bin/bash
set -e

# Configuration
COUNTRY="Singapore"
LABEL="Legion -- X"
MKINITCPIO_CONF="/etc/mkinitcpio.conf"
GRUB_CONF="/etc/default/grub"
GRUB_BACKUP_CONF="/etc/default/grub.bak"

# Function to print colored output
print_color() {
    local color=$1
    local message=$2
    echo -e "\e[${color}m${message}\e[0m"
}

# Function to handle errors
error_handler() {
    print_color "31" "Error occurred on line $1"
    exit 1
}

# Check if script is run as root
if [ "$EUID" -ne 0 ]; then
    print_color "31" "Please run this script as root"
    exit 1
fi

# Initial system checks
if [[ $(findmnt -n -o FSTYPE /) != "btrfs" ]]; then
    print_color "31" "Error: Root filesystem is not BTRFS"
    exit 1
fi

# Get user preferences
read -p "Do you want to set up zram for swap? (y/n): " setup_zram
if [[ $setup_zram =~ ^[Yy]$ ]]; then
    while true; do
        read -p "Enter desired zram size in GB (e.g., 4 for 4GB, or 'ram' to match RAM size): " zram_size
        if [[ "$zram_size" == "ram" ]] || [[ "$zram_size" =~ ^[0-9]+$ ]]; then
            break
        else
            print_color "31" "Please enter a valid number or 'ram'"
        fi
    done
fi

read -p "Do you want to set up Snapper for system snapshots? (y/n): " setup_snapper
read -p "Do you want to install yay AUR helper? (y/n): " install_yay

# Install yay if requested
if [[ $install_yay =~ ^[Yy]$ ]]; then
    print_color "32" "Installing yay AUR helper..."
    sudo pacman -S --needed --noconfirm base-devel git
    
    temp_dir=$(mktemp -d)
    cd "$temp_dir"
    git clone https://aur.archlinux.org/yay.git
    cd yay
    makepkg -si --noconfirm
    
    cd /
    rm -rf "$temp_dir"
    print_color "32" "yay has been successfully installed!"
fi

# Setup zram if requested
if [[ $setup_zram =~ ^[Yy]$ ]]; then
    print_color "32" "Setting up zram for swap..."
    
    if ! pacman -S --noconfirm zram-generator; then
        print_color "31" "Failed to install zram-generator"
        exit 1
    fi

    # Configure zram
    cat > /etc/systemd/zram-generator.conf << EOF
[zram0]
zram-size = ${zram_size == "ram" ? "ram" : "${zram_size}096"}
compression-algorithm = zstd
EOF

    systemctl enable --now systemd-zram-setup@zram0.service
    echo "/dev/zram0 none swap defaults,pri=100 0 0" >> /etc/fstab
    print_color "32" "Zram swap set up successfully with top priority."
fi

# Setup Snapper if requested
if [[ $setup_snapper =~ ^[Yy]$ ]]; then
    read -p "Enter username for snapper access: " SNAPPER_USER
    print_color "32" "Setting up Snapper for BTRFS snapshots..."

    # Install packages
    pacman -S --noconfirm snapper grub-btrfs

    # Setup snapshots directory
    sudo umount /.snapshots 2>/dev/null || true
    sudo rm -rf /.snapshots
    sudo snapper -c root create-config /
    sudo btrfs subvolume delete /.snapshots 2>/dev/null || true
    sudo mkdir /.snapshots
    sudo mount -a
    sudo chmod 755 /.snapshots

    # Configure snapper
    sed -i 's/^TIMELINE_MIN_AGE="[0-9]*"/TIMELINE_MIN_AGE="1800"/' /etc/snapper/configs/root
    sed -i 's/^TIMELINE_LIMIT_HOURLY="[0-9]*"/TIMELINE_LIMIT_HOURLY="5"/' /etc/snapper/configs/root
    sed -i 's/^TIMELINE_LIMIT_DAILY="[0-9]*"/TIMELINE_LIMIT_DAILY="7"/' /etc/snapper/configs/root
    sed -i 's/^TIMELINE_LIMIT_WEEKLY="[0-9]*"/TIMELINE_LIMIT_WEEKLY="0"/' /etc/snapper/configs/root
    sed -i 's/^TIMELINE_LIMIT_MONTHLY="[0-9]*"/TIMELINE_LIMIT_MONTHLY="0"/' /etc/snapper/configs/root
    sed -i 's/^TIMELINE_LIMIT_YEARLY="[0-9]*"/TIMELINE_LIMIT_YEARLY="0"/' /etc/snapper/configs/root
    sed -i 's/^NUMBER_LIMIT="[0-9]*"/NUMBER_LIMIT="10"/' /etc/snapper/configs/root
    sed -i 's/^NUMBER_MIN_AGE="[0-9]*"/NUMBER_MIN_AGE="1800"/' /etc/snapper/configs/root
    sed -i "s/^ALLOW_USERS=\"\"/ALLOW_USERS=\"$SNAPPER_USER\"/" /etc/snapper/configs/root
    sed -i 's/^ALLOW_GROUPS=""/ALLOW_GROUPS="wheel"/' /etc/snapper/configs/root

    # Setup pacman hooks
    mkdir -p /etc/pacman.d/hooks

    # Create hooks
    cat > /etc/pacman.d/hooks/90-snapper-grub-update.hook << 'EOF'
[Trigger]
Operation = Upgrade
Operation = Install
Operation = Remove
Type = Package
Target = *

[Action]
Description = Generating GRUB config to let grub-btrfs detect new snapshots...
Depends = grub
When = PostTransaction
Exec = /usr/share/libalpm/scripts/grub-mkconfig
EOF

    cat > /etc/pacman.d/hooks/50-bootbackup.hook << 'EOF'
[Trigger]
Operation = Upgrade
Operation = Install
Operation = Remove
Type = Path
Target = usr/lib/modules/*/vmlinuz

[Action]
Depends = rsync
Description = Backing up /boot...
When = PreTransaction
Exec = /usr/bin/rsync -a --delete /boot /.bootbackup
EOF

    cat > /etc/pacman.d/hooks/95-snapshot.hook << 'EOF'
[Trigger]
Operation = Install
Operation = Upgrade
Operation = Remove
Type = Package
Target = *

[Action]
Description = Creating Snapper snapshot...
Depends = snapper
When = PreTransaction
Exec = /usr/bin/snapper --no-dbus create -d "pacman transaction"
EOF

    # Enable services
    systemctl enable --now snapper-timeline.timer
    systemctl enable --now snapper-cleanup.timer
    systemctl enable --now grub-btrfsd
    
    # Update GRUB and create initial snapshot
    grub-mkconfig -o /boot/grub/grub.cfg
    snapper -c root create -d "Initial snapshot"

    print_color "32" "Snapper setup complete with recommended configuration"
fi

sync
