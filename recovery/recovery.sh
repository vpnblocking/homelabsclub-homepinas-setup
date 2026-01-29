#!/bin/bash

# =========================================================
# HomePinas Recovery System - V2
# (V1 exacta + descarga online + user-data cloud-init)
# =========================================================

set -e

# --- Asegurar ejecución como root ---
if [ "$(id -u)" -ne 0 ]; then
    echo "Este script debe ejecutarse como root"
    exit 1
fi

export NCURSES_NO_UTF8_ACS=1
export DEBIAN_FRONTEND=noninteractive

# ---------------------------------------------------------
# Variables
# ---------------------------------------------------------
OS_JSON_URL="https://downloads.raspberrypi.com/os_list_imagingutility_v4.json"
IMAGE_XZ="/tmp/raspios-lite-latest.img.xz"
BOOT_MOUNT="/mnt/bootfs"

sleep 2
clear

# =========================================================
# DEPENDENCIAS (DietPi)
# =========================================================
REQUIRED_PKGS=(
  whiptail
  pv
  wget
  curl
  jq
  xz-utils
  util-linux
  parted
  procps
  dosfstools
)

MISSING_PKGS=()
for pkg in "${REQUIRED_PKGS[@]}"; do
    dpkg -s "$pkg" >/dev/null 2>&1 || MISSING_PKGS+=("$pkg")
done

if [ "${#MISSING_PKGS[@]}" -ne 0 ]; then
    echo "[INFO] Instalando dependencias: ${MISSING_PKGS[*]}"
    apt update
    apt install -y "${MISSING_PKGS[@]}"
fi

# =========================================================
# DETECCIÓN DE DISPOSITIVO (V1)
# =========================================================

while true; do

    TARGET=""
    TARGET_NAME=""

    # Detectar eMMC
    if [ -b /dev/mmcblk0 ]; then
        TARGET="/dev/mmcblk0"
        TARGET_NAME="eMMC interna"
    else
        # Detectar microSD
        if [ -b /dev/mmcblk1 ]; then
            TARGET="/dev/mmcblk1"
            TARGET_NAME="tarjeta microSD"
        fi
    fi

    if [ -z "$TARGET" ]; then
        whiptail --title "HomePinas Recovery" \
        --msgbox "\
No se ha detectado ningún dispositivo de almacenamiento válido.

No se ha encontrado ni eMMC ni tarjeta microSD.

El sistema se apagará ahora." \
        15 72
        poweroff
    fi

    # Pantalla inicial (V1)
    whiptail --title "HomePinas Recovery" \
    --msgbox "\
Bienvenido al sistema de recuperación personalizado de HomePinas

Recuperación creada por la comunidad homelabs.club

Dispositivo de destino detectado:

$TARGET_NAME
($TARGET)

Para continuar, pulse Aceptar." \
    18 72

    # Confirmación final (V1)
    if ! whiptail --title "Confirmación de recuperación" \
    --yesno "\
Está a punto de restaurar el sistema en:

$TARGET_NAME
($TARGET)

⚠️ ATENCIÓN ⚠️
Esta operación sobrescribirá COMPLETAMENTE el dispositivo.
Todos los datos se perderán de forma irreversible.

¿Desea continuar?" \
    20 72; then

        if whiptail --title "Operación cancelada" \
        --yesno "\
La recuperación ha sido cancelada.

¿Desea volver al menú de recuperación?" \
        12 72; then
            clear
            continue
        else
            poweroff
        fi
    fi

    break
done

# =========================================================
# OBTENER METADATOS + URL + SHA DESDE CATÁLOGO (ONLINE)
# =========================================================

OS_DATA=$(curl -fsSL "$OS_JSON_URL" | jq -r '
limit(1;
  .. | objects
  | select(
      (.name? | type=="string")
      and (.name | test("^Raspberry Pi OS Lite"))
      and (.url? | type=="string")
      and (.url | endswith(".img.xz"))
      and (.url | test("arm64"))
      and (.extract_sha256? | type=="string")
  )
)
')

if [ -z "$OS_DATA" ]; then
    whiptail --title "Error crítico" \
    --msgbox "\
No se ha podido obtener la información del sistema desde el catálogo oficial.

No se puede continuar." \
    14 72
    poweroff
fi

IMAGE_URL=$(echo "$OS_DATA" | jq -r '.url')
EXPECTED_SHA=$(echo "$OS_DATA" | jq -r '.extract_sha256')
RELEASE_DATE=$(echo "$OS_DATA" | jq -r '.release_date')
IMAGE_NAME=$(basename "$IMAGE_URL")

# =========================================================
# DESCARGA DE IMAGEN (SUSTITUYE IMAGEN LOCAL)
# =========================================================

rm -f "$IMAGE_XZ"

whiptail --title "Descargando sistema" \
--infobox "\
Descargando la última imagen oficial:

Raspberry Pi OS Lite (64-bit)
Versión: $RELEASE_DATE

Archivo:
$IMAGE_NAME

Por favor, espere..." \
12 72

sleep 1

wget -O "$IMAGE_XZ" "$IMAGE_URL" >/dev/null 2>&1 || true

if [ ! -f "$IMAGE_XZ" ]; then
    whiptail --title "Error crítico" \
    --msgbox "\
La descarga de la imagen ha fallado.

Compruebe la conexión a Internet y reintente." \
    14 72
    poweroff
fi

# =========================================================
# VERIFICACIÓN SHA256 (AVISO EXPLÍCITO)
# =========================================================

whiptail --title "Verificando integridad" \
--infobox "\
Comprobando hash SHA256 de la imagen descargada...

Esto puede tardar un poco." \
10 72

sleep 1

CALCULATED_SHA=$(xz -dc "$IMAGE_XZ" | sha256sum | awk '{print $1}')

if [ "$CALCULATED_SHA" != "$EXPECTED_SHA" ]; then
    whiptail --title "Error de integridad" \
    --msgbox "\
La verificación SHA256 ha fallado.

La imagen descargada está corrupta o incompleta.

No se puede continuar." \
    14 72
    poweroff
fi

# =========================================================
# RECUPERACIÓN REAL (IMG.XZ EN STREAMING) - V1
# =========================================================

# Desmontar restos (V1)
umount ${TARGET}* 2>/dev/null || true

# Tamaño del fichero comprimido (para el gauge) (V1)
IMAGE_SIZE=$(stat -c%s "$IMAGE_XZ")

# =========================================================
# PROGRESO + DESCOMPRESIÓN + DD (V1)
# =========================================================

(
    pv -n -s "$IMAGE_SIZE" "$IMAGE_XZ" \
    | xz -dc \
    | dd of="$TARGET" bs=4M conv=fsync status=none
) 2>&1 | whiptail --title "Restaurando sistema" \
    --gauge "\
Restaurando HomePinas en:

$TARGET_NAME
($TARGET)

Por favor, espere..." \
    10 70 0

# Forzar escritura (V1)
sync

# =========================================================
# VERIFICACIONES POST-RECUPERACIÓN (V1)
# =========================================================

partprobe "$TARGET" 2>/dev/null
sleep 1

if [ ! -b "${TARGET}p1" ] || [ ! -b "${TARGET}p2" ]; then
    whiptail --title "Error de recuperación" \
    --msgbox "\
La restauración ha finalizado, pero no se han detectado
las particiones esperadas.

El sistema puede no ser arrancable." \
    15 72
    poweroff
fi

# =========================================================
# V2: MONTAR BOOTFS Y ESCRIBIR user-data (cloud-init)
# =========================================================

mkdir -p "$BOOT_MOUNT"

mount "${TARGET}p1" "$BOOT_MOUNT" 2>/dev/null || true

if [ ! -d "$BOOT_MOUNT" ] || ! mountpoint -q "$BOOT_MOUNT"; then
    whiptail --title "Error" \
    --msgbox "\
No se ha podido montar la partición bootfs (${TARGET}p1).

No se puede escribir user-data." \
    14 72
    poweroff
fi

cat > "$BOOT_MOUNT/user-data" << 'EOF'
#cloud-config
manage_resolv_conf: false

hostname: homepinas
manage_etc_hosts: true

packages:
  - avahi-daemon

apt:
  preserve_sources_list: true
  conf: |
    Acquire {
      Check-Date "false";
    };

timezone: Europe/Madrid

keyboard:
  model: pc105
  layout: "es"

users:
  - name: homepinas
    groups: users,adm,dialout,audio,netdev,video,plugdev,cdrom,games,input,gpio,spi,i2c,render,sudo
    shell: /bin/bash
    lock_passwd: false
    passwd: "$y$jB5$o.HFXRqPpRaGidYHiRIFM/$dlRIT22sVuqMbetq7A8VCfBnbKRL3zTjg5pqEe7aCL2"

enable_ssh: true
ssh_pwauth: true

rpi:
  interfaces:
    serial: true

runcmd:
  - [ rfkill, unblock, wifi ]
  - [ sh, -c, "for f in /var/lib/systemd/rfkill/*:wlan; do echo 0 > \"$f\"; done" ]

  - |
      cat << 'EOF2' > /usr/local/bin/homepinas-install.sh
      #!/bin/bash
      set -euo pipefail

      LOG=/root/homepinas-install.log
      exec > >(tee -a "$LOG") 2>&1

      echo "=== HomePinas install started ==="

      until ping -c1 8.8.8.8 >/dev/null 2>&1; do
        sleep 2
      done

      curl -fsSL https://raw.githubusercontent.com/juanlusoft/homepinas-v2/main/install.sh | bash

      systemctl disable homepinas-install.service
      rm -f /etc/systemd/system/homepinas-install.service
      systemctl daemon-reload
      rm -f /usr/local/bin/homepinas-install.sh

      echo "=== HomePinas install finished and cleaned ==="
      EOF2

  - chmod +x /usr/local/bin/homepinas-install.sh

  - |
      cat << 'EOF2' > /etc/systemd/system/homepinas-install.service
      [Unit]
      Description=HomePinas first boot installer
      After=network-online.target
      Wants=network-online.target

      [Service]
      Type=oneshot
      ExecStart=/usr/local/bin/homepinas-install.sh

      [Install]
      WantedBy=multi-user.target
      EOF2

  - systemctl daemon-reload
  - systemctl enable homepinas-install.service
  - systemctl start homepinas-install.service
EOF

sync
umount "$BOOT_MOUNT"

# =========================================================
# ÉXITO (V1 EXACTO)
# =========================================================

whiptail --title "Recuperación completada" \
--msgbox "\
La recuperación del sistema se ha completado correctamente.

El dispositivo ha sido restaurado con éxito.

Por favor:
1. Retire el USB de recuperación
2. El sistema se apagará ahora" \
12 72

poweroff
