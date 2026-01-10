#!/bin/bash

#############################################
# Fix Random MAC on RTL8125 / 2.5G NIC
# Module for HomePinas Setup Script
#############################################

fix_random_mac() {

    local STORE="/etc/persistent-mac-2p5g"

    info_msg "Detecting 2.5G (RTL8125) network interface..."

    # Detect 2.5G interface by capability
    local IFACE=""
    for dev in /sys/class/net/*; do
        local iface
        iface=$(basename "$dev")
        [[ "$iface" == "lo" ]] && continue

        if ethtool "$iface" 2>/dev/null | grep -q "2500base"; then
            IFACE="$iface"
            break
        fi
    done

    if [[ -z "$IFACE" ]]; then
        error_msg "No 2.5G interface detected."
        return 1
    fi

    success_msg "Detected 2.5G interface: $IFACE"

    # Generate or load persistent MAC
    local MAC=""
    if [[ -f "$STORE" ]]; then
        MAC=$(cat "$STORE")
        info_msg "Using existing persistent MAC: $MAC"
    else
        MAC=$(printf '02:%02X:%02X:%02X:%02X:%02X\n' \
            $((RANDOM%256)) $((RANDOM%256)) $((RANDOM%256)) \
            $((RANDOM%256)) $((RANDOM%256)))
        echo "$MAC" > "$STORE"
        chmod 600 "$STORE"
        success_msg "Generated and stored new MAC: $MAC"
    fi

    # Ensure NetworkManager is active
    if ! systemctl is-active --quiet NetworkManager; then
        error_msg "NetworkManager is not running. This fix requires NetworkManager."
        return 1
    fi

    # Find NetworkManager connection bound to this interface
    local CONN
    CONN=$(nmcli -t -f NAME,DEVICE con show | awk -F: -v i="$IFACE" '$2==i {print $1}')

    if [[ -z "$CONN" ]]; then
        error_msg "No NetworkManager connection found for interface $IFACE."
        error_msg "Make sure the interface is connected and retry."
        return 1
    fi

    info_msg "Applying persistent MAC to NetworkManager connection: $CONN"

    # Apply MAC persistently (NO interface down)
    nmcli con mod "$CONN" ethernet.cloned-mac-address "$MAC"
    nmcli con mod "$CONN" ethernet.mac-address-blacklist ""

    success_msg "Persistent random MAC configured successfully."
    warning_msg "A reboot is required for the MAC to take effect."

    whiptail --title "Reboot Required" \
        --msgbox "The persistent MAC has been configured.\n\nPlease reboot to apply the change safely." \
        10 60
}
