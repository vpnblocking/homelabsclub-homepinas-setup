#!/bin/bash

#############################################
# Fan Control Module (HomePinas)
#############################################
check_fanctl_dependencies() {

    info_msg "Checking fan control dependencies..."

    local missing_deps=()

    if ! command -v smartctl &>/dev/null; then
        missing_deps+=("smartmontools")
    fi

    if [ ${#missing_deps[@]} -gt 0 ]; then
        warning_msg "Installing missing dependencies: ${missing_deps[*]}"
        apt-get update -qq
        if apt-get install -y "${missing_deps[@]}"; then
            success_msg "Fan control dependencies installed."
        else
            error_msg "Failed to install fan control dependencies."
            return 1
        fi
    else
        success_msg "All fan control dependencies are present."
    fi

    return 0
}

check_i2c_fan_overlay() {

    local CONFIG_FILE="/boot/firmware/config.txt"
    local OVERLAY_LINE="dtoverlay=i2c-fan,emc2302,i2c_csi_dsi0"

    info_msg "Checking i2c fan controller overlay..."

    if grep -q "^${OVERLAY_LINE}$" "$CONFIG_FILE" 2>/dev/null; then
        success_msg "i2c-fan overlay already present."
        return 0
    fi

    warning_msg "i2c-fan overlay not found."
    warning_msg "Fan controller will NOT work without it."

    if whiptail --title "Enable Fan Controller" --yesno \
"To enable hardware fan control, the following line is required:

${OVERLAY_LINE}

It will be added to:
${CONFIG_FILE}

A SYSTEM REBOOT IS REQUIRED after this.

Do you want to add it now?" \
        18 70; then

        echo "" >> "$CONFIG_FILE"
        echo "# HomePinas fan controller" >> "$CONFIG_FILE"
        echo "$OVERLAY_LINE" >> "$CONFIG_FILE"

        success_msg "Overlay added to config.txt"

        whiptail --title "Reboot required" --msgbox \
"The fan controller overlay has been added.

You MUST reboot the system before fan control can work.

After reboot, re-run the installer to finish the setup." \
        14 70

        return 2
    else
        error_msg "Fan control installation aborted (overlay missing)."
        return 1
    fi
}

install_fanctl() {
    # Easter egg 🥚
        if systemctl list-unit-files | grep -q '^homepinas-fanctl.service'; then
            whiptail --title "🤨 Pero bueno..." --msgbox \
            "Esto ya está instalado.
            
            Si ya lo tienes funcionando…
            ¿pa qué le das otra vez?
            
            Paneo pa ti 
            
            (Pista: puedes ver logs con:
            journalctl -u homepinas-fanctl.service -f)" \
            15 60
            return 0
        fi
    info_msg "Installing HomePinas Fan Control..."
    
    check_i2c_fan_overlay
    case $? in
        0) ;;              # todo OK
        2) return 0 ;;     # overlay añadido → esperar reboot
        *) re
    if ! check_fanctl_dependencies; then
        error_msg "Cannot continue without required dependencies."
        return 1
    fi
    
    local SERVICE_NAME="homepinas-fanctl"
    local INSTALL_PATH="/usr/local/bin/homepinas-fanctl.sh"

    local RAW_BASE="https://raw.githubusercontent.com/alejandroperezlopez/homelabsclub-homepinas-setup/main"
    local REMOTE_SCRIPT_PATH="fanctl/homepinas-fanctl.sh"

    local SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"
    local TIMER_FILE="/etc/systemd/system/${SERVICE_NAME}.timer"

    # Descargar script
    info_msg "Downloading fan control script from GitHub..."
    if ! curl -fsSL "${RAW_BASE}/${REMOTE_SCRIPT_PATH}" -o "${INSTALL_PATH}"; then
        error_msg "Failed to download fan control script."
        return 1
    fi

    chmod +x "${INSTALL_PATH}"
    success_msg "Fan control script installed at ${INSTALL_PATH}"

    # Crear service
    info_msg "Creating systemd service..."
    cat > "${SERVICE_FILE}" <<EOF
[Unit]
Description=HomePinas Fan Control (HDD/SSD + NVMe/CPU)
After=multi-user.target
Wants=multi-user.target

[Service]
Type=oneshot
ExecStart=${INSTALL_PATH}
Restart=on-failure
RestartSec=5s
User=root
Group=root
StandardOutput=journal
StandardError=journal
EOF

    # Crear timer
    info_msg "Creating systemd timer..."
    cat > "${TIMER_FILE}" <<EOF
[Unit]
Description=Run HomePinas Fan Control periodically

[Timer]
OnBootSec=30s
OnUnitActiveSec=30s
AccuracySec=5s
Persistent=true

[Install]
WantedBy=timers.target
EOF

    # Recargar y activar
    info_msg "Enabling fan control timer..."
    systemctl daemon-reexec
    systemctl daemon-reload
    systemctl enable --now "${SERVICE_NAME}.timer"

    success_msg "HomePinas Fan Control installed and running."

    whiptail --msgbox \
    "Fan control installed successfully.
    
    Service: ${SERVICE_NAME}.service
    Timer:   ${SERVICE_NAME}.timer
    
    Logs:
    journalctl -u ${SERVICE_NAME}.service -f" \
    16 70

}
