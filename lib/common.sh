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
    
    info_msg "System disk identified as: $system_disk (will be excluded)" >&2
    
    # Get all disks (TYPE=disk), exclude loop devices, cd-roms, and system disk
    lsblk -dn -o NAME,SIZE,TYPE | awk '$3=="disk"' | grep -v -E 'mmcblk|zram|loop' | while read -r line; do
        local disk_name=$(echo "$line" | awk '{print $1}')
        local disk_size=$(echo "$line" | awk '{print $2}')
        local disk_base=$(basename "$disk_name")
        
        # Validate disk exists as block device
        if [ ! -b "$disk_name" ]; then
            continue
        fi
        
        # Skip system disk
        if [ "$disk_base" = "$system_disk" ]; then
            continue
        fi
        
        # Skip if disk is root or has root partition
        local has_root=0
        if lsblk -no MOUNTPOINT "$disk_name" 2>/dev/null | grep -q '^/$'; then
            has_root=1
        fi
        
        if [ "$has_root" -gt 0 ]; then
            continue
        fi
        
        # Skip if disk has boot partition
        local has_boot=0
        if lsblk -no MOUNTPOINT "$disk_name" 2>/dev/null | grep -q '^/boot'; then
            has_boot=1
        fi
        
        if [ "$has_boot" -gt 0 ]; then
            continue
        fi
        
        # Get serial number
        local serial=$(get_disk_serial "$disk_name")
        
        # Get model
        local model=$(get_disk_model "$disk_name")
        
        # Output:  disk_name|size|serial|model
        echo "$disk_name|$disk_size|$serial|$model"
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