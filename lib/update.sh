#!/bin/bash

#############################################
# System Update Module
# Handles system updates
#############################################

update_system() {
    if whiptail --title "System Update" --yesno "This will update your system packages.Continue?" 10 60; then
        info_msg "Starting system update..."
        
        # Update package lists
        info_msg "Updating package lists..."
        if apt-get update; then
            success_msg "Package lists updated successfully."
        else
            error_msg "Failed to update package lists."
            pause
            return 1
        fi
        
        # Upgrade packages
        info_msg "Upgrading packages..."
        if DEBIAN_FRONTEND=noninteractive apt-get upgrade -y; then
            success_msg "System upgraded successfully."
        else
            error_msg "Failed to upgrade system."
            pause
            return 1
        fi
        
        # Check if reboot is required
        if [ -f /var/run/reboot-required ]; then
            warning_msg "System reboot is required!"
            if whiptail --title "Reboot Required" --yesno "A reboot is required.Reboot now?" 10 60; then
                info_msg "Rebooting system..."
                reboot
            fi
        fi
        
        whiptail --msgbox "System update completed successfully!" 10 60
    fi
}