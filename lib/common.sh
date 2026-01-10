#!/bin/bash

#############################################
# Common Utilities
# Helper functions for the setup script
#############################################

# Pause and wait for user
pause() {
    echo "Press [Enter] key to continue..." >&2
    read -r < /dev/tty
}

# Check if a command exists
command_exists() {
    command -v "$1" &> /dev/null
}

# Get system disk (the one with root mounted)
get_system_disk() {
    # Find the disk that contains the root partition
    local root_device=$(findmnt -n -o SOURCE /)
    
    # Get the base disk name (remove partition number)
    local system_disk=$(lsblk -no PKNAME "$root_device" 2>/dev/null)
    
    if [ -z "$system_disk" ]; then
        # Fallback:  try to extract disk name from device
        system_disk=$(echo "$root_device" | sed 's/[0-9]*$//' | sed 's/p$//')
        system_disk=$(basename "$system_disk")
    fi
    
    echo "$system_disk"
}

# Get disk serial number
get_disk_serial() {
    local disk="$1"
    local serial=""
    
    # Validate input
    if [ -z "$disk" ] || [ !  -b "$disk" ]; then
        echo "N/A"
        return 1
    fi
    
    # Try multiple methods to get serial number
    
    # Method 1: lsblk
    serial=$(lsblk -no SERIAL "$disk" 2>/dev/null | head -1 | xargs)
    
    # Method 2: udevadm if lsblk failed
    if [ -z "$serial" ] || [ "$serial" = "n/a" ]; then
        serial=$(udevadm info --query=property --name="$disk" 2>/dev/null | grep -E "^ID_SERIAL=" | cut -d'=' -f2 | xargs)
    fi
    
    # Method 3: Check by-id links
    if [ -z "$serial" ] || [ "$serial" = "n/a" ]; then
        local disk_name=$(basename "$disk")
        local by_id=$(ls -l /dev/disk/by-id/ 2>/dev/null | grep "${disk_name}\$" | awk '{print $9}' | head -1)
        if [ -n "$by_id" ]; then
            serial="$by_id"
        fi
    fi
    
    # Fallback
    if [ -z "$serial" ] || [ "$serial" = "n/a" ]; then
        serial="N/A"
    fi
    
    echo "$serial"
}

# Get disk model
get_disk_model() {
    local disk="$1"
    local model=""
    
    # Validate input
    if [ -z "$disk" ] || [ !  -b "$disk" ]; then
        echo "Unknown"
        return 1
    fi
    
    # Try lsblk first
    model=$(lsblk -no MODEL "$disk" 2>/dev/null | head -1 | xargs)
    
    # Try udevadm if lsblk failed
    if [ -z "$model" ]; then
        model=$(udevadm info --query=property --name="$disk" 2>/dev/null | grep -E "^ID_MODEL=" | cut -d'=' -f2 | xargs)
    fi
    
    # Fallback
    if [ -z "$model" ]; then
        model="Unknown"
    fi
    
    echo "$model"
}

# Check if disk is mounted (including any of its partitions)
is_disk_mounted() {
    local disk="$1"
    
    # Validate input
    if [ -z "$disk" ]; then
        return 1
    fi
    
    local disk_name=$(basename "$disk")
    
    # Check if the disk itself or any of its partitions are mounted
    # Use grep -F for fixed string matching to avoid regex issues
    if mount | grep -F "$disk" | grep -qv "^/"; then
        return 0
    fi
    
    # Check by lsblk - this is more reliable
    if lsblk -no MOUNTPOINT "$disk" 2>/dev/null | grep -q '^/' ; then
        return 0
    fi
    
    return 1
}

# Get mounted partitions of a disk
get_disk_mountpoints() {
    local disk="$1"
    
    # Validate input
    if [ -z "$disk" ]; then
        return 1
    fi
    
    # Use lsblk to get all mountpoints for this disk and its partitions
    lsblk -no MOUNTPOINT "$disk" 2>/dev/null | grep -v '^$' | grep '^/'
}

# Get list of available disks (excluding system disk, only full disks not partitions)
get_available_disks() {
    local system_disk=$(get_system_disk)
    
    # Send info message to stderr so it doesn't interfere with data output
    info_msg "System disk identified as: $system_disk (will be excluded)" >&2
    
    # Get all disks with FULL PATHS using -p flag
    # TYPE=disk ensures only full disks, not partitions
    lsblk -dpno NAME,SIZE,TYPE 2>/dev/null | while read -r disk_path disk_size disk_type; do
        # Skip if not a disk
        if [ "$disk_type" != "disk" ]; then
            continue
        fi
        
        # Skip if empty
        if [ -z "$disk_path" ]; then
            continue
        fi
        
        # Get base disk name (without /dev/)
        local disk_base=$(basename "$disk_path")
        
        # Validate disk exists as block device
        if [ ! -b "$disk_path" ]; then
            continue
        fi
        
        # Skip loop, zram, and RAM disks
        if [[ "$disk_base" =~ ^(loop|zram|ram) ]]; then
            continue
        fi
        
        # Skip system disk (mmcblk typically for CM5)
        if [[ "$disk_base" =~ ^mmcblk ]]; then
            # Check if this is the system disk
            if [ "$disk_base" = "$system_disk" ] || [[ "$disk_base" == ${system_disk}* ]]; then
                continue
            fi
        fi
        
        # Skip if disk is system disk
        if [ "$disk_base" = "$system_disk" ]; then
            continue
        fi
        
        # Skip if disk has root partition
        if lsblk -no MOUNTPOINT "$disk_path" 2>/dev/null | grep -q '^/$'; then
            continue
        fi
        
        # Skip if disk has boot partition
        if lsblk -no MOUNTPOINT "$disk_path" 2>/dev/null | grep -q '^/boot'; then
            continue
        fi
        
        # Get serial number
        local serial=$(get_disk_serial "$disk_path")
        
        # Get model
        local model=$(get_disk_model "$disk_path")
        
        # Output to stdout:   disk_path|size|serial|model
        echo "$disk_path|$disk_size|$serial|$model"
    done
}

# Check if nonraid is running
is_nonraid_running() {
    if systemctl is-active --quiet nonraid.service 2>/dev/null; then
        return 0
    else
        return 1
    fi
}

# Check if a disk has data
disk_has_data() {
    local disk="$1"
    
    # Validate input
    if [ -z "$disk" ] || [ ! -b "$disk" ]; then
        return 1
    fi
    
    # Check if disk has partitions or filesystem
    if lsblk -no FSTYPE "$disk" 2>/dev/null | grep -v '^$' | grep -q .; then
        return 0
    else
        return 1
    fi
}