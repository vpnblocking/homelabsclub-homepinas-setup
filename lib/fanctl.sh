#!/bin/bash

#############################################
# Fan Control Module (HomePinas)
#############################################

install_fanctl() {

    info_msg "Installing HomePinas Fan Control..."

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
        "Fan control installed successfully.\n\n"\
        "Service: ${SERVICE_NAME}.service\n"\
        "Timer:   ${SERVICE_NAME}.timer\n\n"\
        "Logs:\njournalctl -u ${SERVICE_NAME}.service -f" \
        16 70
}
