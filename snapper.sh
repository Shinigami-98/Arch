#!/bin/bash
set -e

# Configuration
COUNTRY="Singapore"
LABEL="Legion -- X"
MKINITCPIO_CONF="/etc/mkinitcpio.conf"
GRUB_CONF="/etc/default/grub"
GRUB_BACKUP_CONF="/etc/default/grub.bak"

# Helper Functions
print_color() {
    local color=$1
    local message=$2
    echo -e "\e[${color}m${message}\e[0m"
}

error_handler() {
    print_color "31" "Error occurred on line $1"
    exit 1
}

check_root() {
    if [ "$EUID" -ne 0 ]; then
        print_color "31" "Please run this script as root"
        exit 1
    fi
}

check_btrfs() {
    if [[ $(findmnt -n -o FSTYPE /) != "btrfs" ]]; then
        print_color "31" "Error: Root filesystem is not BTRFS"
        exit 1
    fi
}

# Installation Functions
install_yay() {
    if [ "$EUID" -eq 0 ]; then
        print_color "31" "Error: yay should not be installed as root"
        print_color "33" "Please run the yay installation as a regular user"
        exit 1
    fi

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
}

setup_zram() {
    local zram_size=$1
    local compression=$2
    print_color "32" "Setting up zram for swap..."
    
    if ! pacman -S --noconfirm zram-generator; then
        print_color "31" "Failed to install zram-generator"
        exit 1
    fi

    # Configure zram
    cat > /etc/systemd/zram-generator.conf << EOF
[zram0]
zram-size = ${zram_size}G
compression-algorithm = ${compression}
EOF

    systemctl enable --now systemd-zram-setup@zram0.service
    echo "/dev/zram0 none swap defaults,pri=100 0 0" >> /etc/fstab
    print_color "32" "Zram swap set up successfully with top priority."
}

create_snapper_hooks() {
    mkdir -p /etc/pacman.d/hooks
    
    # Create GRUB update hook
    cat > /etc/pacman.d/hooks/95-snapper-grub-update.hook << 'EOF'
[Trigger]
Operation = Install
Operation = Upgrade
Operation = Remove
Type = Path
Target = var/lib/snapper/snapshots/*/info.xml

[Action]
Description = Updating GRUB after Snapper snapshot...
When = PostTransaction
Exec = /usr/bin/grub-mkconfig -o /boot/grub/grub.cfg
Depends = grub
EOF

    # Create boot backup hook
    cat > /etc/pacman.d/hooks/50-bootbackup.hook << 'EOF'
[Trigger]
Operation = Upgrade
Operation = Install
Operation = Remove
Type = Path
Target = boot/*

[Action]
Depends = rsync
Description = Backing up /boot...
When = PreTransaction
Exec = /usr/bin/rsync -a --delete /boot /.bootbackup
EOF

    # Create snapshot hook
    cat > /etc/pacman.d/hooks/80-snapshot.hook << 'EOF'
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
Exec = /usr/bin/snapper --no-dbus create -d "pacman: $(cat /tmp/pacman-cmd)"
EOF

    # Create a pre-transaction hook to save the pacman command
    cat > /etc/pacman.d/hooks/79-save-pacman-cmd.hook << 'EOF'
[Trigger]
Operation = Install
Operation = Upgrade
Operation = Remove
Type = Package
Target = *

[Action]
Description = Saving pacman command...
When = PreTransaction
Exec = /bin/sh -c 'echo "$@" > /tmp/pacman-cmd' -- $0 $@
EOF
}

setup_snapper() {
    local SNAPPER_USER=$1
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
    sudo chmod 750 /.snapshots

    # Configure snapper
    local config_file="/etc/snapper/configs/root"
    sed -i 's/^TIMELINE_MIN_AGE="[0-9]*"/TIMELINE_MIN_AGE="1800"/' "$config_file"
    sed -i 's/^TIMELINE_LIMIT_HOURLY="[0-9]*"/TIMELINE_LIMIT_HOURLY="5"/' "$config_file"
    sed -i 's/^TIMELINE_LIMIT_DAILY="[0-9]*"/TIMELINE_LIMIT_DAILY="7"/' "$config_file"
    sed -i 's/^TIMELINE_LIMIT_WEEKLY="[0-9]*"/TIMELINE_LIMIT_WEEKLY="0"/' "$config_file"
    sed -i 's/^TIMELINE_LIMIT_MONTHLY="[0-9]*"/TIMELINE_LIMIT_MONTHLY="0"/' "$config_file"
    sed -i 's/^TIMELINE_LIMIT_YEARLY="[0-9]*"/TIMELINE_LIMIT_YEARLY="0"/' "$config_file"
    sed -i 's/^NUMBER_LIMIT="[0-9]*"/NUMBER_LIMIT="10"/' "$config_file"
    sed -i 's/^NUMBER_MIN_AGE="[0-9]*"/NUMBER_MIN_AGE="1800"/' "$config_file"
    sed -i "s/^ALLOW_USERS=\"\"/ALLOW_USERS=\"$SNAPPER_USER\"/" "$config_file"
    sed -i 's/^ALLOW_GROUPS=""/ALLOW_GROUPS="wheel"/' "$config_file"

    create_snapper_hooks

    # Enable services
    systemctl enable --now snapper-timeline.timer
    systemctl enable --now snapper-cleanup.timer
    systemctl enable --now grub-btrfsd
    
    # Update GRUB and create initial snapshot
    grub-mkconfig -o /boot/grub/grub.cfg
    snapper -c root create -d "Initial snapshot"

    print_color "32" "Snapper setup complete with recommended configuration"
}

# Main Script
main() {
    # Only check root for operations that need it
    if [[ $setup_zram_choice =~ ^[Yy]$ ]] || [[ $setup_snapper_choice =~ ^[Yy]$ ]]; then
        check_root
        check_btrfs
    fi

    # Get user preferences for zram
    read -p "Do you want to set up zram for swap? (y/n): " setup_zram_choice
    
    if [[ $setup_zram_choice =~ ^[Yy]$ ]]; then
        echo "Select zram size:"
        echo "1) 2GB"
        echo "2) 4GB"
        echo "3) 6GB"
        echo "4) 8GB"
        read -p "Enter your choice (1-4): " size_choice
        
        case $size_choice in
            1) zram_size=2 ;;
            2) zram_size=4 ;;
            3) zram_size=6 ;;
            4) zram_size=8 ;;
            *) print_color "31" "Invalid choice. Using 4GB as default."; zram_size=4 ;;
        esac

        echo "Select compression algorithm:"
        echo "1) zstd (better compression)"
        echo "2) lz4 (faster)"
        read -p "Enter your choice (1-2): " comp_choice
        
        case $comp_choice in
            1) compression="zstd" ;;
            2) compression="lz4" ;;
            *) print_color "31" "Invalid choice. Using zstd as default."; compression="zstd" ;;
        esac
    fi

    read -p "Do you want to set up Snapper for system snapshots? (y/n): " setup_snapper_choice
    read -p "Do you want to install yay AUR helper? (y/n): " install_yay_choice

    # Execute chosen operations
    [[ $install_yay_choice =~ ^[Yy]$ ]] && install_yay
    [[ $setup_zram_choice =~ ^[Yy]$ ]] && setup_zram "$zram_size" "$compression"
    if [[ $setup_snapper_choice =~ ^[Yy]$ ]]; then
        read -p "Enter username for snapper access: " SNAPPER_USER
        setup_snapper "$SNAPPER_USER"
    fi

    sync
}

# Execute main function
main
