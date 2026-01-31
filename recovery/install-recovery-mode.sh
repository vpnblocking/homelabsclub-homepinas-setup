#!/bin/bash
set -e

echo "=== HomePinas – Instalación de USB Recovery Permanente ==="

RECOVERY_URL="https://raw.githubusercontent.com/juanlusoft/homepinas-recovery/main/recovery.sh"

# ---------------------------------------------------------
# 1. Autologin root en tty1 (PERMANENTE)
# ---------------------------------------------------------
echo "[1/3] Configurando autologin root en tty1..."

mkdir -p /etc/systemd/system/getty@tty1.service.d

cat > /etc/systemd/system/getty@tty1.service.d/autologin.conf << 'EOF'
[Service]
ExecStart=
ExecStart=-/sbin/agetty --autologin root --noclear %I $TERM
EOF

# ---------------------------------------------------------
# 2. Autoejecución del recovery en cada arranque
# ---------------------------------------------------------
echo "[2/3] Configurando autoarranque del recovery..."

cat > /root/.bash_profile << EOF
#!/bin/bash

# HomePinas Recovery – arranque automático permanente

# Esperar conectividad de red
until ping -c1 8.8.8.8 >/dev/null 2>&1; do
  sleep 2
done

# Ejecutar recovery desde GitHub
curl -fsSL $RECOVERY_URL | bash
EOF

chmod +x /root/.bash_profile

# ---------------------------------------------------------
# 3. Silenciar arranque (opcional pero recomendado)
# ---------------------------------------------------------
echo "[3/3] Ajustando arranque silencioso..."

CMDLINE=""
[ -f /boot/cmdline.txt ] && CMDLINE="/boot/cmdline.txt"
[ -f /boot/firmware/cmdline.txt ] && CMDLINE="/boot/firmware/cmdline.txt"

if [ -n "$CMDLINE" ] && ! grep -q "quiet" "$CMDLINE"; then
  sed -i 's/$/ quiet loglevel=3 systemd.show_status=false/' "$CMDLINE"
fi

# ---------------------------------------------------------
# Final
# ---------------------------------------------------------
systemctl daemon-reexec
systemctl daemon-reload

echo
echo "=== USB RECOVERY CONFIGURADO ==="
echo
echo "Este sistema queda PERMANENTEMENTE en modo recovery."
echo "Cada arranque ejecutará el recovery automáticamente."
echo
echo "Reinicia cuando quieras para probarlo."
