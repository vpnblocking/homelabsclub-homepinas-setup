#!/bin/bash

#############################################
# MergerFS Module
# Handles MergerFS installation and configuration
#############################################

# Install MergerFS
install_mergerfs_package() {
    info_msg "Installing MergerFS..."
    
    # Check if already installed
    if command_exists mergerfs; then
        success_msg "MergerFS is already installed."
        return 0
    fi
    
    # Install from apt (available in Debian repos)
    if apt-get install -y mergerfs; then
        success_msg "MergerFS installed successfully."
        return 0
    else
        error_msg "Failed to install MergerFS."
        return 1
    fi
}

# Get NonRAID data disks (non-parity)
get_nonraid_data_disks() {
    # Parse nmdctl status to get data disks
    # This is a simplified version - adjust based on actual output format
    local data_disks=()
    
    if ! command_exists nmdctl; then
        error_msg "NonRAID is not installed!"
        return 1
    fi
    
    # Get mount points of NonRAID array members (excluding parity)
    # This assumes disks are mounted under /mnt/disk*
    while IFS= read -r mount; do
        if [ -d "$mount" ] && [[ "$mount" == /mnt/disk* ]] && [[ "$mount" != *"parity"* ]]; then
            data_disks+=("$mount")
        fi
    done < <(mount | grep xfs | awk '{print $3}')
    
    if [ ${#data_disks[@]} -eq 0 ]; then
        error_msg "No NonRAID data disks found!"
        return 1
    fi
    
    echo "${data_disks[@]}"
    return 0
}

# Create protected mount point
create_protected_mountpoint() {
    local mount_point="$1"
    
    info_msg "Creating protected mount point..."
    
    # Create directory if it doesn't exist
    if [ ! -d "$mount_point" ]; then
        mkdir -p "$mount_point"
    fi
    
    # Remove all permissions to prevent accidental writes
    chmod 000 "$mount_point"
    
    # Create a guard file to indicate mount is not active
    echo "WARNING: This directory should be mounted.If you can read this file, the mount has FAILED!" > "${mount_point}.nomount"
    chmod 444 "${mount_point}.nomount"
    
    success_msg "Mount point created with safety protections"
    info_msg "Directory permissions: 000 (no access until mounted)"
    info_msg "Guard file created: ${mount_point}.nomount"
}

# Configure MergerFS
configure_mergerfs() {
    local mount_point="/mnt/homepinas-data"
    
    info_msg "Configuring MergerFS..."
    
    # Get data disks
    local data_disks=$(get_nonraid_data_disks)
    if [ $? -ne 0 ]; then
        error_msg "Failed to get NonRAID data disks."
        return 1
    fi

    # Create protected mount point
    create_protected_mountpoint "$mount_point"
        
    # Create fstab entry with noauto option (won't mount at boot, systemd service will handle it)
    local source_paths=$(echo "$data_disks" | tr ' ' ': ')
    local fstab_entry="$source_paths $mount_point fuse.mergerfs noauto,allow_other,use_ino,dropcacheonclose=true,category.create=mfs 0 0"
    
    # Check if entry already exists
    if grep -q "$mount_point" /etc/fstab; then
        warning_msg "MergerFS entry already exists in /etc/fstab.Updating..."
        sed -i "\|$mount_point|d" /etc/fstab
    fi
    
    # Add to fstab with noauto
    echo "$fstab_entry" >> /etc/fstab
    success_msg "Added MergerFS entry to /etc/fstab (with noauto)"
    
    # Create systemd service to ensure it starts after nonraid
    create_mergerfs_service "$mount_point"
    
    # Mount now
    if mount "$mount_point"; then
        success_msg "MergerFS mounted at $mount_point"
        return 0
    else
        error_msg "Failed to mount MergerFS."
        return 1
    fi
}

# Create systemd service for MergerFS
create_mergerfs_service() {
    local mount_point="$1"
    local service_file="/etc/systemd/system/mergerfs-homepinas.service"
    
    info_msg "Creating MergerFS systemd service..."
    
    # Create service that depends on nonraid.service
    cat > "$service_file" << EOF
[Unit]
Description=MergerFS HomePinas Data Mount
# Wait for NonRAID to be fully started and mounted
After=nonraid.service
Requires=nonraid.service
# Ensure filesystems are ready
After=local-fs.target
# Don't start if NonRAID failed
BindsTo=nonraid.service

[Service]
Type=oneshot
RemainAfterExit=yes
# Wait a bit for NonRAID mounts to settle
ExecStartPre=/bin/sleep 2
# Mount mergerfs
ExecStart=/bin/mount ${mount_point}
# Unmount on stop
ExecStop=/bin/umount ${mount_point}
# Retry on failure
Restart=on-failure
RestartSec=10s

[Install]
WantedBy=multi-user.target
EOF
    
    # Reload and enable
    systemctl daemon-reload
    if systemctl enable mergerfs-homepinas.service; then
        success_msg "MergerFS service created and enabled."
        
        info_msg "Service details:"
        echo -e "${CYAN}  - Service will start AFTER nonraid.service${NC}"
        echo -e "${CYAN}  - If nonraid.service fails, mergerfs won't start${NC}"
        echo -e "${CYAN}  - Automatic retry on failure${NC}"
        
        return 0
    else
        error_msg "Failed to enable MergerFS service."
        return 1
    fi
}

# Main MergerFS installation function
install_mergerfs() {
    # Check if NonRAID is installed
    if ! command_exists nmdctl; then
        whiptail --msgbox "NonRAID must be installed first!" 10 60 
        return 1
    fi
    
    # Check if NonRAID is running
    if !  is_nonraid_running; then
        whiptail --msgbox "NonRAID must be running before configuring MergerFS!\n\nPlease start NonRAID first." 12 60 
        return 1
    fi
    
    # Confirm installation
    if !  whiptail --title "Install MergerFS" --yesno \
        "This will install MergerFS and create a merged mount point at /mnt/homepinas-data.\n\nThe mount will be configured to start automatically AFTER NonRAID at boot.\n\nContinue?" 14 70 ; then
        return 0
    fi
    
    # Install package
    if ! install_mergerfs_package; then
        whiptail --msgbox "Failed to install MergerFS!" 10 60 
        return 1
    fi
    
    # Configure
    if ! configure_mergerfs; then
        whiptail --msgbox "Failed to configure MergerFS!" 10 60 
        return 1
    fi
    
    whiptail --msgbox "MergerFS installation completed successfully!\n\nData is accessible at: /mnt/homepinas-data\n\nThe mount will automatically start after NonRAID at boot." 14 70 
}