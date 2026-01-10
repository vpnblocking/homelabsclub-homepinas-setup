#!/bin/bash

#############################################
# HomePinas Setup Script
# Main entry point for system setup
# Usage: curl -fsSL https://raw.githubusercontent.com/alejandroperezlopez/homelabsclub-homepinas-setup/main/install.sh | bash
#############################################

set -e

# Configuration
REPO_BASE_URL="https://raw.githubusercontent.com/alejandroperezlopez/homelabsclub-homepinas-setup/main"
SCRIPT_VERSION="1.0.0"

# Color definitions
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# Basic message functions
info_msg() {
    echo -e "${CYAN}ℹ $1${NC}"
}

error_msg() {
    echo -e "${RED}✗ $1${NC}"
}

warning_msg() {
    echo -e "${YELLOW}⚠ $1${NC}"
}

success_msg() {
    echo -e "${GREEN}✓ $1${NC}"
}

# Check and elevate privileges if needed
check_and_elevate() {
    if [ "$EUID" -ne 0 ]; then
        warning_msg "This script requires root privileges."
        info_msg "Re-executing with sudo..."
        
        # Re-execute the script with sudo by curling again
        sudo bash -c "curl -fsSL ${REPO_BASE_URL}/install.sh | bash"
        exit $? 
    fi
}

# Function to load a module dynamically (in memory, no file download)
load_module() {
    local module_name="$1"
    local module_url="${REPO_BASE_URL}/lib/${module_name}.sh"
    
    info_msg "Loading module:   ${module_name}..."
    
    # Source directly from URL without downloading
    if source <(curl -fsSL "${module_url}"); then
        success_msg "Module ${module_name} loaded."
    else
        error_msg "Failed to load module:  ${module_name}"
        exit 1
    fi
}

# Check for required base dependencies
check_base_dependencies() {
    info_msg "Checking for required dependencies..."
    
    local missing_deps=()
    
    if ! command -v whiptail &> /dev/null; then
        missing_deps+=("whiptail")
    fi
    
    if ! command -v curl &> /dev/null; then
        missing_deps+=("curl")
    fi
    
    if [ ${#missing_deps[@]} -gt 0 ]; then
        warning_msg "Installing missing dependencies:  ${missing_deps[*]}"
        apt-get update -qq
        apt-get install -y "${missing_deps[@]}"
        success_msg "Dependencies installed successfully."
    else
        success_msg "All dependencies are present."
    fi
}

# Display banner
show_banner() {
    clear
    echo -e "${CYAN}"
    echo "╔════════════════════════════════════════════╗"
    echo "║     HomePinas Setup Script v${SCRIPT_VERSION}           ║"
    echo "║     Homelabs.club 2026        ║"
    echo "╚════════════════════════════════════════════╝"
    echo -e "${NC}"
}

# Main menu
show_main_menu() {
    while true; do
        # Use the detected terminal device for whiptail
        CHOICE=$(whiptail --title "HomePinas Setup Menu" --menu "Choose an option:" 20 70 10 \
            "1" "Update System" \
            "2" "Install NonRAID" \
            "3" "Show NonRAID Status" \
            "4" "Install MergerFS" \
            "5" "Exit" \
            3>&1 1>&2 2>&3 )
        
        exitstatus=$?
        if [ $exitstatus != 0 ]; then
            echo -e "${GREEN}Goodbye!${NC}"
            exit 0
        fi
        
        case $CHOICE in
            1)
                load_module "update"
                update_system
                ;;
            2)
                load_module "nonraid"
                install_nonraid
                ;;
            3)
                load_module "nonraid"
                show_nonraid_status
                ;;
            4)
                load_module "mergerfs"
                install_mergerfs
                ;;
            5)
                echo -e "${GREEN}Goodbye!${NC}"
                exit 0
                ;;
            *)
                whiptail --msgbox "Invalid option.Please try again." 8 45 
                ;;
        esac
    done
}

# Main execution
main() {

    exec < /dev/tty

    show_banner
    check_and_elevate
    check_base_dependencies
    load_module "common"
    show_main_menu
}

main "$@"