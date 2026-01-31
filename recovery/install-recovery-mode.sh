#!/bin/bash
set -e

echo "=== HomePinas Recovery Mode Installer ==="

# ---------------------------------------------------------
# CONFIG
# ---------------------------------------------------------
RECOVERY_URL="https://raw.githubusercontent.com/vpnblocking/homelabsclub-homepinas-setup/refs/heads/main/recovery/recovery.sh"

GETTY_OVERRIDE_DIR="/etc/systemd/system/getty@tty1.service.d"
GETTY_OVERRIDE_FILE="$GETTY_OVERRIDE_DIR/autologin.conf"

BASH_PROFILE="/root/.bash_profile"

CMDLINE_FILE=""
[ -f /boot/cmdline.txt ] && CMDLINE_FILE="/boot/cmdline.txt"
[ -f /boot/firmware/cmdline.txt ] && CMDLINE_FILE="/boot/firmware/cmdline.txt"

# ---------------------------------------------------------
# 1. Autologin root en tty1
# ---------------------------------------------------------
echo "[1/4] Configurando autologin root en tty1..."

mkdir -p "$GETTY_OVERRIDE_DIR"

cat > "$GETTY_OVERRIDE_FILE" << 'EOF'
[Service]
ExecStart=
ExecStart=-/sbin/agetty --autologin root --noclear %I $TERM
EOF

# ---------------------------------------------------------
# 2. Autoejecución del recovery en login shell
# ---------------------------------------------------------
echo "[2/4] Configurando autoarranque del recovery..."

cat > "$BASH_PROFILE" << EOF
#!/bin/bash

# HomePinas Recovery autostart

# Evitar ejecuciones múltiples
if [ -z "\$HOMEPINAS_RECOVERY_DONE" ]; then
  export HOMEPINAS_RECOVERY_DONE=1

  # Esperar conectividad
  until ping -c1 8.8.8.8 >/dev/null 2>&1; do
    sleep 2
  done

  # Descargar y ejecutar recovery
  curl -fsSL $RECOVERY_URL | bash
fi
EOF

chmod +x "$BASH_PROFILE"

# ---------------------------------------------------------
# 3. Silenciar logs de arranque (opcional pero recomendado)
# ---------------------------------------------------------
if [ -n "$CMDLINE_FILE" ]; then
  echo "[3/4] Ajustando cmdline para arranque silencioso..."

  if ! grep -q "quiet" "$CMDLINE_FILE"; then
    sed -i 's/$/ quiet loglevel=3 systemd.show_status=false/' "$CMDLINE_FILE"
  fi
fi

# ---------------------------------------------------------
# 4. Recargar systemd
# ---------------------------------------------------------
echo "[4/4] Recargando systemd..."

systemctl daemon-reexec
systemctl daemon-reload

echo
echo "=== INSTALACIÓN COMPLETADA ==="
echo
echo "El sistema ha quedado configurado como MODO RECOVERY."
echo
echo "A partir de ahora, en cada arranque:"
echo " - Se hará autologin como root"
echo " - Se ejecutará el recovery automáticamente"
echo " - El recovery apagará el sistema"
echo
echo "No se ha ejecutado el recovery ahora."
echo "Reinicia cuando quieras para probarlo."
