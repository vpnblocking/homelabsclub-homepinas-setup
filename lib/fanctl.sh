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

    if ! command -v sensors &>/dev/null; then
        missing_deps+=("lm-sensors")
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
    local I2C_LINE="dtparam=i2c_arm=on"
    local OVERLAY_LINE="dtoverlay=i2c-fan,emc2301,addr=0x2e,i2c_csi_dsi0,minpwm=65,maxpwm=255,midtemp=45000,maxtemp=6500"

    info_msg "Checking i2c fan controller overlay and i2c support..."

    local has_i2c=0
    local has_overlay=0

    grep -q "^${I2C_LINE}$" "$CONFIG_FILE" 2>/dev/null && has_i2c=1
    grep -q "^${OVERLAY_LINE}$" "$CONFIG_FILE" 2>/dev/null && has_overlay=1

    if [ "$has_i2c" -eq 1 ] && [ "$has_overlay" -eq 1 ]; then
        success_msg "i2c enabled and i2c-fan overlay already present."
        return 0
    fi

    warning_msg "Required i2c configuration not found."
    warning_msg "Fan controller will NOT work without it."

    if whiptail --title "Enable I2C Fan Controller" --yesno \
"To enable hardware fan control, the following lines are required:

${I2C_LINE}
${OVERLAY_LINE}

They will be added to:
${CONFIG_FILE}

A SYSTEM REBOOT IS REQUIRED after this.

Do you want to add them now?" \
        20 75; then

        echo "" >> "$CONFIG_FILE"
        echo "# HomePinas fan controller" >> "$CONFIG_FILE"

        if [ "$has_i2c" -eq 0 ]; then
            echo "$I2C_LINE" >> "$CONFIG_FILE"
        fi

        if [ "$has_overlay" -eq 0 ]; then
            echo "$OVERLAY_LINE" >> "$CONFIG_FILE"
        fi

        success_msg "I2C and fan controller overlay added to config.txt"

        whiptail --title "Reboot required" --msgbox \
"The I2C configuration and fan controller overlay have been added.

You MUST reboot the system before fan control can work.

After reboot, re-run the installer to finish the setup." \
        14 70

        return 2
    else
        error_msg "Fan control installation aborted (missing i2c configuration)."
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

Paneo pa ti 😏

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
        *)
            return 1
            ;;
    esac

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

    info_msg "Downloading fan control script from GitHub..."
    if ! curl -fsSL "${RAW_BASE}/${REMOTE_SCRIPT_PATH}" -o "${INSTALL_PATH}"; then
        error_msg "Failed to download fan control script."
        return 1
    fi

    chmod +x "${INSTALL_PATH}"
    success_msg "Fan control script installed at ${INSTALL_PATH}"

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
