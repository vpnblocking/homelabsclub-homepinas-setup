#!/bin/bash

activate_usb_recovery() {

    info_msg "Checking current EEPROM boot configuration..."

    # Verificar entorno Raspberry Pi
    if ! command -v vcgencmd &>/dev/null; then
        error_msg "vcgencmd not found. This system does not appear to be a Raspberry Pi."
        return 1
    fi

    if ! command -v rpi-eeprom-config &>/dev/null; then
        error_msg "rpi-eeprom-config not found. EEPROM tools are missing."
        return 1
    fi

    # Leer configuración actual de EEPROM
    if ! BOOTCONF=$(rpi-eeprom-config 2>/dev/null); then
        error_msg "Unable to read EEPROM configuration."
        return 1
    fi

    CURRENT_ORDER=$(echo "$BOOTCONF" | grep "^BOOT_ORDER=" | cut -d= -f2)

    if [ -z "$CURRENT_ORDER" ]; then
        error_msg "BOOT_ORDER not found in EEPROM configuration."
        return 1
    fi

    echo
    info_msg "Current BOOT_ORDER: ${CURRENT_ORDER}"
    echo
    echo "Boot order meaning:"
    echo "  4 = USB"
    echo "  1 = microSD"
    echo "  6 = NVMe"
    echo "  f = repeat boot cycle"
    echo
    echo "Desired order:"
    echo "  USB → microSD → NVMe → repeat"
    echo "  BOOT_ORDER=0xf416"
    echo

    # Ya está configurado correctamente
    if [[ "$CURRENT_ORDER" == "0xf416" ]]; then
        success_msg "Boot order is already set to USB → microSD → NVMe."
        return 0
    fi

    warning_msg "This will change the boot order to:"
    warning_msg "USB → microSD → NVMe (with fallback loop)"

    if ! whiptail --yesno \
        "Current BOOT_ORDER: ${CURRENT_ORDER}\n\nApply new boot order?\n\nUSB → microSD → NVMe\nBOOT_ORDER=0xf416" \
        14 75; then
        info_msg "Operation cancelled by user."
        return 0
    fi

    info_msg "Applying new EEPROM boot configuration..."

    TMPFILE=$(mktemp)

    # Volcar EEPROM actual
    rpi-eeprom-config > "$TMPFILE"

    # Reemplazar o añadir BOOT_ORDER
    if grep -q "^BOOT_ORDER=" "$TMPFILE"; then
        sed -i 's/^BOOT_ORDER=.*/BOOT_ORDER=0xf416/' "$TMPFILE"
    else
        echo "BOOT_ORDER=0xf416" >> "$TMPFILE"
    fi

    # Aplicar configuración
    if rpi-eeprom-config --apply "$TMPFILE"; then
        success_msg "EEPROM updated successfully."
        warning_msg "A reboot is required for the new boot order to take effect."
    else
        error_msg "Failed to apply EEPROM configuration."
        rm -f "$TMPFILE"
        return 1
    fi

    rm -f "$TMPFILE"

    if whiptail --yesno "Reboot now to activate the new boot order?" 10 60; then
        info_msg "Rebooting system..."
        reboot
    else
        info_msg "Please reboot manually later."
    fi
}
