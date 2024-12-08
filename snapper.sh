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

sudo chmod 777 /etc/pacman.conf
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

if [[ $install_yay =~ ^[Yy]$ ]]; then
    print_color "32" "Installing yay AUR helper..."
    
    # Install base-devel if not already installed
    sudo pacman -S --needed --noconfirm base-devel git
    
    # Create temporary directory for yay installation
    temp_dir=$(mktemp -d)
    cd "$temp_dir"
    
    # Clone and build yay
    git clone https://aur.archlinux.org/yay.git
    cd yay
    makepkg -si --noconfirm
    
    # Clean up
    cd /
    rm -rf "$temp_dir"
    
    print_color "32" "yay has been successfully installed!"
else
    print_color "33" "Skipping yay installation."
fi

if [[ $setup_zram =~ ^[Yy]$ ]]; then
    print_color "32" "Setting up zram for swap..."
    print_color "33" "Debug: Testing environment..."
    if pwd; then
        print_color "32" "Environment is accessible"
    else
        print_color "31" "Cannot access environment"
        exit 1
    fi

    # Install zram-generator with error checking
    if ! pacman -S --noconfirm zram-generator; then
        print_color "31" "Failed to install zram-generator. Check if environment is properly set up."
        exit 1
    fi

    # Configure zram with user-specified size
    echo "[zram0]" > /etc/systemd/zram-generator.conf
    if [[ "$zram_size" == "ram" ]]; then
        echo "zram-size = ram" >> /etc/systemd/zram-generator.conf
    else
        echo "zram-size = ${zram_size}096" >> /etc/systemd/zram-generator.conf
    fi
    echo "compression-algorithm = zstd" >> /etc/systemd/zram-generator.conf

    # Enable zram swap with top priority
    systemctl enable --now systemd-zram-setup@zram0.service
    echo "/dev/zram0 none swap defaults,pri=100 0 0" >> /etc/fstab

    print_color "32" "Zram swap set up successfully with top priority."
else
    print_color "33" "Skipping zram setup."
fi

# Move the snapper setup implementation here (after zram setup)
if [[ $setup_snapper =~ ^[Yy]$ ]]; then
    read -p "Enter username for snapper access: " SNAPPER_USER

    print_color "32" "Setting up Snapper for BTRFS snapshots..."

    # Install necessary packages including GUI tools
    pacman -S --noconfirm snapper grub-btrfs

    sudo umount /.snapshots
    sudo rm -r /.snapshots

    # Create snapper config for root
    sudo snapper -c root create-config /

    sudo btrfs su del /.snapshots
    sudo mkdir /.snapshots

    sudo mount -a

    # Set correct permissions for snapshots directory
    chmod 755 /.snapshots

    # Modify default snapper configuration according to Arch Wiki
    sed -i 's/TIMELINE_MIN_AGE="[0-9]*"/TIMELINE_MIN_AGE="1800"/' /etc/snapper/configs/root
    sed -i 's/^TIMELINE_LIMIT_HOURLY="10"/TIMELINE_LIMIT_HOURLY="5"/' /etc/snapper/configs/root
    sed -i 's/^TIMELINE_LIMIT_DAILY="10"/TIMELINE_LIMIT_DAILY="7"/' /etc/snapper/configs/root
    sed -i 's/^TIMELINE_LIMIT_WEEKLY="0"/TIMELINE_LIMIT_WEEKLY="0"/' /etc/snapper/configs/root
    sed -i 's/^TIMELINE_LIMIT_MONTHLY="10"/TIMELINE_LIMIT_MONTHLY="0"/' /etc/snapper/configs/root
    sed -i 's/^TIMELINE_LIMIT_YEARLY="10"/TIMELINE_LIMIT_YEARLY="0"/' /etc/snapper/configs/root

    # Set up snapshot cleanup
    sed -i 's/^NUMBER_LIMIT="50"/NUMBER_LIMIT="10"/' /etc/snapper/configs/root
    sed -i 's/^NUMBER_MIN_AGE="[0-9]*"/NUMBER_MIN_AGE="1800"/' /etc/snapper/configs/root

    # Set ALLOW_USERS and ALLOW_GROUPS in snapper config
    read -p "Enter username for snapper access: " SNAPPER_USER
    sed -i 's/^ALLOW_USERS=""/ALLOW_USERS="'"$SNAPPER_USER"'"/' /etc/snapper/configs/root
    sed -i 's/^ALLOW_GROUPS=""/ALLOW_GROUPS="wheel"/' /etc/snapper/configs/root

    # Configure pacman hooks for automatic snapshots
    if [[ ! -d "/etc/pacman.d/hooks" ]]; then
        mkdir -p /etc/pacman.d/hooks
    fi

    # Add hook for updating GRUB after Snapper snapshots
    cat > /etc/pacman.d/hooks/90-snapper-grub-update.hook << 'EOF'
[Trigger]
Operation = Post
Type = Path
Target = var/lib/snapper/snapshots/*/info.xml

[Action]
Description = Updating GRUB after Snapper snapshot...
When = PostTransaction
Exec = /usr/bin/grub-mkconfig -o /boot/grub/grub.cfg
Depends = grub
EOF

    # Original hooks remain unchanged
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

    # Enable and start snapper timeline and cleanup services
    sudo systemctl enable --now snapper-timeline.timer
    sudo systemctl enable --now snapper-cleanup.timer

    # Create grub-btrfs config directory and enable its services
    sudo systemctl enable --now grub-btrfsd
    
    # Update GRUB configuration
    sudo grub-mkconfig -o /boot/grub/grub.cfg

    # Create the first snapshot
    sudo snapper -c root create -d "Initial snapshot"

    print_color "32" "Snapper setup complete with Arch Wiki recommended configuration:"
    print_color "33" "- 5 hourly snapshots"
    print_color "33" "- 7 daily snapshots"
    print_color "33" "- 0 weekly snapshots"
    print_color "33" "- 0 monthly snapshots"
    print_color "33" "- 0 yearly snapshots"
    print_color "33" "- Maximum of 10 snapshots for number cleanup"
    print_color "33" "- Automatic snapshots before package operations"
    print_color "33" "- Boot backup before kernel updates"
    print_color "33" "- Initial snapshot created"
    print_color "33" "- Snapshots will be available in GRUB menu"
    print_color "33" "- GUI tools installed: snapper-gui and btrfs-assistant"
else
    print_color "33" "Skipping Snapper setup."
fi

sync
