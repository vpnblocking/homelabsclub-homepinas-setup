#!/bin/bash

#############################################
# NonRAID Module
# Handles NonRAID installation and management
#############################################

# Install NonRAID dependencies
install_nonraid_dependencies() {
    info_msg "Installing NonRAID dependencies..."
    
    local deps=(
        "build-essential"
        "dkms"
        "linux-headers-$(uname -r)"
        "git"
        "xfsprogs"
    )
    
    if apt-get install -y "${deps[@]}"; then
        success_msg "Dependencies installed successfully."
        return 0
    else
        error_msg "Failed to install dependencies."
        return 1
    fi
}

# Clone and build NonRAID
build_nonraid() {
    info_msg "Cloning NonRAID repository..."
    
    local temp_dir="/tmp/nonraid-build"
    
    # Remove existing temp directory if present
    if [ -d "$temp_dir" ]; then
        rm -rf "$temp_dir"
    fi
    
    # Clone repository to temp location
    if git clone https://github.com/qvr/nonraid.git "$temp_dir"; then
        success_msg "Repository cloned successfully."
    else
        error_msg "Failed to clone repository."
        return 1
    fi
    
    cd "$temp_dir"
    
    # Extract version from dkms.conf properly
    info_msg "Extracting version information..."
    
    if [ !  -f "dkms.conf" ]; then
        error_msg "dkms.conf not found in repository!"
        return 1
    fi
    
    # Extract version - handle different formats
    local version=""
    
    # Try different extraction methods
    if grep -q 'PACKAGE_VERSION=' dkms.conf; then
        # Extract value after = and remove quotes
        version=$(grep 'PACKAGE_VERSION=' dkms.conf | head -1 | cut -d'=' -f2 | tr -d '"' | tr -d "'" | xargs)
    fi
    
    if [ -z "$version" ]; then
        error_msg "Could not extract version from dkms.conf"
        cat dkms.conf
        return 1
    fi
    
    info_msg "Detected version: $version"
    
    # Extract module name from dkms.conf
    local module_name=""
    if grep -q 'PACKAGE_NAME=' dkms.conf; then
        module_name=$(grep 'PACKAGE_NAME=' dkms.conf | head -1 | cut -d'=' -f2 | tr -d '"' | tr -d "'" | xargs)
    fi
    
    if [ -z "$module_name" ]; then
        # Default to 'md' if not found
        module_name="md"
        warning_msg "Could not extract module name, using default: $module_name"
    fi
    
    info_msg "Module name: $module_name"

    # Install nmdctl command-line tool
    info_msg "Installing nmdctl command-line tool..."
    
    if [ -f "tools/nmdctl" ]; then
        # Copy nmdctl to /usr/local/bin
        if cp "tools/nmdctl" /usr/local/bin/nmdctl; then
            # Make it executable
            chmod +x /usr/local/bin/nmdctl
            success_msg "nmdctl installed to /usr/local/bin/nmdctl"
        else
            error_msg "Failed to copy nmdctl to /usr/local/bin"
            return 1
        fi
    else
        error_msg "nmdctl not found in tools/ directory!"
        ls -la tools/
        return 1
    fi
    
    # Verify nmdctl is accessible
    if command -v nmdctl &> /dev/null; then
        success_msg "nmdctl is now available in PATH"
        info_msg "nmdctl version: $(nmdctl --version 2>&1 || echo 'unknown')"
    else
        error_msg "nmdctl was installed but is not in PATH!"
        return 1
    fi
    
    # Prepare DKMS source directory
    local dkms_dir="/usr/src/${module_name}-${version}"
    
    info_msg "Preparing DKMS source directory:  $dkms_dir"
    
    # Remove existing DKMS directory if present
    if [ -d "$dkms_dir" ]; then
        warning_msg "Removing existing DKMS directory..."
        rm -rf "$dkms_dir"
    fi
    
    # Copy source to DKMS directory
    cp -r "$temp_dir" "$dkms_dir"
    success_msg "Source copied to DKMS directory."
    
    # Verify dkms.conf exists in new location
    if [ ! -f "$dkms_dir/dkms.conf" ]; then
        error_msg "dkms.conf not found in $dkms_dir"
        return 1
    fi
    
    info_msg "Building NonRAID kernel module with DKMS..."
    
    # Remove from DKMS if already added (cleanup)
    dkms remove -m "$module_name" -v "$version" --all 2>/dev/null || true
    
    # Add to DKMS
    info_msg "Adding module to DKMS..."
    if dkms add -m "$module_name" -v "$version"; then
        success_msg "Added to DKMS."
    else
        error_msg "Failed to add module to DKMS."
        return 1
    fi
    
    # Build module
    info_msg "Building kernel module (this may take a few minutes)..."
    if dkms build -m "$module_name" -v "$version"; then
        success_msg "Module built successfully."
    else
        error_msg "Failed to build module."
        error_msg "Check /var/lib/dkms/${module_name}/${version}/build/make.log for details"
        return 1
    fi
    
    # Install module
    info_msg "Installing kernel module..."
    if dkms install -m "$module_name" -v "$version"; then
        success_msg "Module installed successfully."
    else
        error_msg "Failed to install module."
        return 1
    fi
    
    # Clean up temp directory
    rm -rf "$temp_dir"
    
    # Load module
    info_msg "Loading kernel module..."
    
    # Unload if already loaded
    rmmod md 2>/dev/null || true
    
    if modprobe md; then
        success_msg "Kernel module loaded."
    else
        error_msg "Failed to load kernel module."
        error_msg "Try manually:  modprobe md"
        return 1
    fi
    
    # Verify module is loaded
    if lsmod | grep -q "^md "; then
        success_msg "Module verification successful."
        info_msg "Module info:"
        modinfo md | grep -E "^(filename|version|description):" | while read line; do
            echo "  $line"
        done
    else
        warning_msg "Module may not be loaded correctly."
    fi

    return 0
}

# Select disks for NonRAID
select_data_disks() {
    local disk_list=()
    
    info_msg "Scanning for available disks..." >&2
    
    # Get available disks with serial numbers
    while IFS='|' read -r disk_name disk_size serial model; do
        # Create description with serial and model
        local disk_desc="${disk_size} | S/N: ${serial}"
        if [ "$model" != "Unknown" ]; then
            disk_desc="${disk_desc} | ${model}"
        fi
        
        # Check if mounted
        if is_disk_mounted "$disk_name"; then
            disk_desc="${disk_desc} [MOUNTED]"
        fi
        
        disk_list+=("$disk_name" "$disk_desc" "OFF")
    done < <(get_available_disks)
    
    if [ ${#disk_list[@]} -eq 0 ]; then
        whiptail --msgbox "No available disks found!\n\nAll disks are either:\n- System disks\n- Already in use\n- Loop/virtual devices" 12 60 
        return 1
    fi
    
    # Show disk selection dialog
    local selected=$(whiptail --title "Select Data Disks for NonRAID" \
        --checklist "Select disks for NonRAID array (use SPACE to select):\n\nIMPORTANT:  Verify serial numbers to ensure correct disk selection!" 25 90 15 \
        "${disk_list[@]}" \
        3>&1 1>&2 2>&3 )
    
    if [ -z "$selected" ]; then
        warning_msg "No disks selected."
        return 1
    fi
    
    # Remove quotes from selected disks
    selected=$(echo "$selected" | tr -d '"')
    echo "$selected"
    return 0
}

# Unmount disk and all its partitions
unmount_disk() {
    local disk="$1"
    
    # Validate input
    if [ -z "$disk" ]; then
        error_msg "No disk specified for unmount"
        return 1
    fi
    
    if [ ! -b "$disk" ]; then
        error_msg "Disk $disk is not a valid block device"
        return 1
    fi
    
    local disk_name=$(basename "$disk")
    
    info_msg "Checking for mounted partitions on $disk..."
    
    # Get all mountpoints for this disk
    local mountpoints=$(get_disk_mountpoints "$disk")
    
    if [ -z "$mountpoints" ]; then
        success_msg "Disk $disk is not mounted."
        return 0
    fi
    
    warning_msg "Disk $disk has mounted partitions:"
    echo "$mountpoints" | while read -r mp; do
        if [ -n "$mp" ]; then
            echo -e "${YELLOW}  - $mp${NC}"
        fi
    done
    
    info_msg "Unmounting all partitions..."
    
    # Unmount all partitions (in reverse order to handle nested mounts)
    echo "$mountpoints" | tac | while read -r mp; do
        if [ -n "$mp" ]; then
            info_msg "Unmounting:  $mp"
            if umount "$mp" 2>/dev/null; then
                success_msg "Unmounted: $mp"
            else
                # Try lazy unmount if normal unmount fails
                warning_msg "Force unmounting: $mp"
                if umount -l "$mp" 2>/dev/null; then
                    success_msg "Force unmounted: $mp"
                else
                    error_msg "Failed to unmount: $mp"
                    return 1
                fi
            fi
        fi
    done
    
    # Verify unmount
    sleep 1
    if is_disk_mounted "$disk"; then
        error_msg "Failed to unmount all partitions from $disk"
        return 1
    fi
    
    success_msg "All partitions unmounted from $disk"
    return 0
}

# Wipe and format disk
wipe_and_format_disk() {
    local disk="$1"
    local serial=$(get_disk_serial "$disk")
    
    echo ""
    warning_msg "=========================================="
    warning_msg "PREPARING DISK:  $disk"
    warning_msg "Serial Number: $serial"
    warning_msg "=========================================="
    echo ""
    
    # Check if disk is mounted
    if is_disk_mounted "$disk"; then
        warning_msg "Disk $disk is currently MOUNTED!"
        
        # Show mountpoints
        echo -e "${YELLOW}Mounted at:${NC}"
        get_disk_mountpoints "$disk" | while read -r mp; do
            echo -e "${YELLOW}  - $mp${NC}"
        done
        
        # Ask for confirmation to unmount
        if whiptail --title "Disk Mounted" --yesno \
            "Disk $disk is currently mounted.\n\nSerial:  $serial\n\nDo you want to unmount it and continue?" 12 70 ; then
            
            if !  unmount_disk "$disk"; then
                error_msg "Failed to unmount $disk.Aborting."
                return 1
            fi
        else
            warning_msg "User cancelled.Skipping disk $disk"
            return 1
        fi
    fi
    
    info_msg "Wiping disk:  $disk (S/N: $serial)"
    
    # Final safety check
    sleep 1
    
    # Stop any RAID/LVM that might be using this disk
    mdadm --stop "$disk" 2>/dev/null || true
    pvremove -ff "$disk" 2>/dev/null || true
    
    # Wipe filesystem signatures
    info_msg "Removing filesystem signatures..."
    wipefs -a "$disk" 2>/dev/null || true
    
    # Zero out the first part of the disk
    info_msg "Zeroing partition table..."
    dd if=/dev/zero of="$disk" bs=1M count=100 2>/dev/null || true
    
    # Zero out the end of the disk (backup GPT)
    info_msg "Clearing backup partition table..."
    dd if=/dev/zero of="$disk" bs=1M count=100 seek=$(($(blockdev --getsz "$disk") / 2048 - 100)) 2>/dev/null || true

    # Inform kernel of changes
    partprobe "$disk" 2>/dev/null || true
    
    # info_msg "Creating XFS filesystem on $disk"
    
    # Create XFS filesystem
    # if mkfs.xfs -f "$disk"; then
    #     success_msg "Filesystem created on $disk (S/N: $serial)"
    # else
    #     error_msg "Failed to create filesystem on $disk"
    #     return 1
    # fi

    info_msg "Creating partitions over the wiped disk"

    if parted "$disk" --script mklabel gpt 2>/dev/null; then
        success_msg "GPT label created successfully on $disk"
    else
        error_msg "Failed to create GPT label on $disk"
        return 1
    fi
    
    if parted "$disk" --script mkpart primary 1MiB 100% 2>/dev/null; then
        success_msg "Partition created correctly on $disk"
        return 0
    else
        error_msg "Failed to create partition on $disk"
        return 1
    fi
}

# Setup NonRAID array
setup_nonraid_array() {
    local disks=($1)
    
    info_msg "Setting up NonRAID array with ${#disks[@]} disk(s)..."
    
    echo ""
    echo -e "${CYAN}╔════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║         DISK PREPARATION SUMMARY           ║${NC}"
    echo -e "${CYAN}╔════════════════════════════════════════════╗${NC}"
    
    # Show summary of selected disks
    for disk in "${disks[@]}"; do
        local serial=$(get_disk_serial "$disk")
        local model=$(get_disk_model "$disk")
        local size=$(lsblk -no SIZE "$disk" | head -1)
        
        echo -e "${YELLOW}Disk: ${NC}   $disk"
        echo -e "${YELLOW}Size:${NC}   $size"
        echo -e "${YELLOW}Model:${NC}  $model"
        echo -e "${YELLOW}Serial:${NC} $serial"
        
        if is_disk_mounted "$disk"; then
            echo -e "${RED}Status:  MOUNTED - Will be unmounted${NC}"
        else
            echo -e "${GREEN}Status: Ready${NC}"
        fi
        echo "---"
    done
    
    echo -e "${CYAN}╚════════════════════════════════════════════╝${NC}"
    echo ""

    # Wait for the user to read the list of disks selected...
    pause
    
    # Final confirmation
    if !  whiptail --title "⚠️  FINAL CONFIRMATION ⚠️" --yesno \
        "You are about to WIPE ${#disks[@]} disk(s).\n\nThis action is IRREVERSIBLE!\n\nPlease verify the serial numbers above match your intended disks.\n\nContinue?" 14 70 ; then
        warning_msg "Operation cancelled by user."
        return 1
    fi
    
    # Wipe and format each disk
    for disk in "${disks[@]}"; do
        if ! wipe_and_format_disk "$disk"; then
            error_msg "Failed to prepare disk:  $disk"
            if whiptail --title "Error" --yesno "Failed to prepare $disk.\n\nContinue with remaining disks?" 10 60 ; then
                continue
            else
                return 1
            fi
        fi
    done
    
    success_msg "All disks prepared successfully!"
    echo ""
    
    info_msg "Creating NonRAID array..."
    info_msg "You will now be prompted to configure the array interactively."
    echo ""
    pause
    
    # Run nmdctl create interactively
    if nmdctl create; then
        success_msg "NonRAID array created successfully."
        return 0
    else
        error_msg "Failed to create NonRAID array."
        return 1
    fi
}

# Install default configuration
install_default_config() {
    info_msg "Installing default configuration..."
    
    local config_url="https://raw.githubusercontent.com/qvr/nonraid/main/tools/systemd/nonraid.default"
    local config_file="/etc/default/nonraid"
    
    # Create /etc/default directory if it doesn't exist
    mkdir -p /etc/default
    
    # Download default configuration
    if curl -fsSL "${config_url}" -o "${config_file}"; then
        success_msg "Default configuration installed at ${config_file}"
        
        # Prompt user if they want to customize the configuration
        if whiptail --title "Configuration" --yesno \
            "Default configuration installed.\n\nDo you want to customize the NonRAID configuration now?\n(You can edit /etc/default/nonraid later)" 12 70 ; then
            
            # Ask for custom superblock location
            local super_path=$(whiptail --inputbox "Enter superblock file path:" 10 60 "/nonraid.dat" 3>&1 1>&2 2>&3 )
            if [ -n "$super_path" ]; then
                sed -i "s|#SUPER=.*|SUPER=${super_path}|" "${config_file}"
                success_msg "Superblock path set to: ${super_path}"
            fi
            
            # # Ask for mount parameters
            # local mount_params=$(whiptail --inputbox "Enter mount parameters (optional):\nExample: /mnt/disk" 10 60 "/mnt/disk" 3>&1 1>&2 2>&3 )
            # if [ -n "$mount_params" ]; then
            #     sed -i "s|#MOUNT_PARAMS=.*|MOUNT_PARAMS=\"${mount_params}\"|" "${config_file}"
            #     success_msg "Mount parameters set."
            # fi
            
            # # Ask about notifications
            # if whiptail --title "Notifications" --yesno "Do you want to enable status notifications?" 10 60 ; then
            #     local notify_cmd=$(whiptail --inputbox "Enter notification command:\nExample: mail -s 'NonRAID Alert' admin@example.com" 10 70 "" 3>&1 1>&2 2>&3 )
            #     if [ -n "$notify_cmd" ]; then
            #         sed -i "s|#NONRAID_NOTIFY_CMD=.*|NONRAID_NOTIFY_CMD=\"${notify_cmd}\"|" "${config_file}"
            #         success_msg "Notifications configured."
            #     fi
            # fi
        fi
        
        return 0
    else
        error_msg "Failed to install default configuration"
        return 1
    fi
}

# Install systemd services
install_systemd_services() {
    info_msg "Installing systemd services..."
    
    local systemd_url="https://raw.githubusercontent.com/qvr/nonraid/main/tools/systemd"
    local service_dir="/etc/systemd/system"
    
    # List of all services and timers to install
    local files=(
        "nonraid.service"
        "nonraid-notify.service"
        "nonraid-notify.timer"
        "nonraid-parity-check.service"
        "nonraid-parity-check.timer"
    )
    
    # Download and install each service/timer
    for file in "${files[@]}"; do
        info_msg "Installing ${file}..."
        if curl -fsSL "${systemd_url}/${file}" -o "${service_dir}/${file}"; then
            success_msg "Installed ${file}"
        else
            error_msg "Failed to install ${file}"
            return 1
        fi
    done
    
    # Reload systemd
    systemctl daemon-reload
    
    # Enable main service
    if systemctl enable nonraid.service; then
        success_msg "Enabled nonraid.service"
    else
        error_msg "Failed to enable nonraid.service"
        return 1
    fi
    
    # Ask if user wants to enable parity check timer
    if whiptail --title "Parity Check" --yesno \
        "Do you want to enable automatic parity checks?\n(This will run periodic parity checks)" 10 60 ; then
        if systemctl enable nonraid-parity-check.timer; then
            success_msg "Enabled automatic parity checks"
        fi
    fi
    
    # Ask if user wants to enable notification timer
    # if whiptail --title "Notifications" --yesno \
    #     "Do you want to enable status notifications?\n(This requires notification command in /etc/default/nonraid)" 10 70 ; then
    #     if systemctl enable nonraid-notify.timer; then
    #         success_msg "Enabled status notifications"
    #     fi
    # fi
    
    success_msg "Systemd services installed."
    return 0
}

# Main NonRAID installation function
install_nonraid() {
    # Check if already running
    if is_nonraid_running; then
        if !  whiptail --title "NonRAID Running" --yesno "NonRAID is already running.Reinstall?" 10 60 ; then
            return 0
        fi
        systemctl stop nonraid.service 2>/dev/null || true
    fi
    
    # Confirm installation
    if !  whiptail --title "Install NonRAID" --yesno "This will install NonRAID and its dependencies.Continue?" 10 60 ; then
        return 0
    fi
    
    # Install dependencies
    if ! install_nonraid_dependencies; then
        whiptail --msgbox "Failed to install dependencies!" 10 60 
        return 1
    fi
    
    # Build NonRAID
    if ! build_nonraid; then
        whiptail --msgbox "Failed to build NonRAID!" 10 60 
        return 1
    fi
    
    # Select disks
    local selected_disks=$(select_data_disks)
    if [ -z "$selected_disks" ]; then
        return 1
    fi
    
    # Warning about data loss
    if ! whiptail --title "⚠️  WARNING ⚠️" --yesno \
        "The selected disks will be COMPLETELY WIPED!\n\nSelected disks: $selected_disks\n\nAll data will be lost.Continue?" 15 70 ; then
        warning_msg "Installation cancelled by user."
        return 0
    fi
    
    # Setup array
    if ! setup_nonraid_array "$selected_disks"; then
        whiptail --msgbox "Failed to setup NonRAID array!" 10 60 
        return 1
    fi
    
    # Install default configuration
    if !  install_default_config; then
        whiptail --msgbox "Failed to install default configuration!" 10 60 
        return 1
    fi
    
    # Install systemd services
    if ! install_systemd_services; then
        whiptail --msgbox "Failed to install systemd services!" 10 60 
        return 1
    fi
    
    whiptail --msgbox "NonRAID installation completed successfully!\n\nYou can customize settings in /etc/default/nonraid" 12 70 
}

# Show NonRAID status
show_nonraid_status() {
    if ! command_exists nmdctl; then
        whiptail --msgbox "NonRAID is not installed!" 10 60 
        return 1
    fi
    
    info_msg "NonRAID Status:"
    echo ""
    nmdctl status
    echo ""
    pause
}