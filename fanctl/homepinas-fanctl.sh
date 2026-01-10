#!/usr/bin/env bash
set -euo pipefail

# =========================
# Configuración
# =========================

# Curva PWM1 (HDD/SSD) según temp máxima HDD/SSD (°C)
# Ajusta si quieres.
pwm_hdd_from_temp() {
  local t="$1"
  if   (( t <= 30 )); then echo 65
  elif (( t <= 35 )); then echo 90
  elif (( t <= 40 )); then echo 130
  elif (( t <= 45 )); then echo 180
  else                    echo 230
  fi
}

# Curva PWM2 (NVMe+CPU) según temp efectiva max(NVMe, CPU) (°C)
pwm_fast_from_temp() {
  local t="$1"
  if   (( t <= 40 )); then echo 80
  elif (( t <= 50 )); then echo 120
  elif (( t <= 60 )); then echo 170
  else                    echo 255
  fi
}

# Mínimos/máximos por seguridad
MIN_PWM1=65
MIN_PWM2=80
MAX_PWM=255

# Failsafe
CPU_FAILSAFE_C=80        # si CPU >= esto => ambos 255
FAST_FAILSAFE_C=70       # si NVMe/FAST >= esto => pwm2 255 (y opcional pwm1 también)

# Histeresis (en PWM): no cambia si la diferencia es pequeña
HYST_PWM=10

# Estado (últimos PWM aplicados)
STATE_FILE="/run/homepinas-fanctl.state"

# DRYRUN=1 para no escribir PWM (por si quieres volver a probar)
DRYRUN="${DRYRUN:-0}"

# =========================
# Helpers
# =========================

log() { echo "[$(date '+%F %T')] $*"; }

need_root() {
  if (( EUID != 0 )); then
    echo "ERROR: Ejecuta como root (sudo)." >&2
    exit 1
  fi
}

find_emc_hwmon() {
  local hw
  hw="$(grep -l '^emc2305$' /sys/class/hwmon/hwmon*/name 2>/dev/null | head -n1 || true)"
  if [[ -z "$hw" ]]; then
    echo ""
    return 1
  fi
  echo "${hw%/name}"
}

read_cpu_temp_c() {
  local f="/sys/class/thermal/thermal_zone0/temp"
  if [[ -r "$f" ]]; then
    echo $(( $(cat "$f") / 1000 ))
  else
    echo 0
  fi
}

# SATA temp: prefer attribute 194, fallback 190; take RAW_VALUE column and strip junk.
read_sata_temp_c() {
  local dev="$1"
  local t=""
  t="$(smartctl -A "$dev" 2>/dev/null | awk '$1==194 {print $10; exit}')"
  if [[ -z "$t" ]]; then
    t="$(smartctl -A "$dev" 2>/dev/null | awk '$1==190 {print $10; exit}')"
  fi
  t="$(echo "$t" | sed 's/[^0-9].*$//')"
  if [[ "$t" =~ ^[0-9]+$ ]]; then
    echo "$t"
  else
    echo ""
  fi
}

# NVMe USB ASMedia temp: from "Temperature:" line.
read_nvme_usb_temp_c() {
  local dev="$1"
  local t=""
  t="$(smartctl -a -d sntasmedia "$dev" 2>/dev/null | awk '/^Temperature:/ {print $2; exit}')"
  if [[ "$t" =~ ^[0-9]+$ ]]; then
    echo "$t"
  else
    echo ""
  fi
}

# Safe write with hysteresis
apply_pwm() {
  local pwm_path="$1"
  local new="$2"
  local last="$3"
  local label="$4"

  # Clamp
  (( new < 0 )) && new=0
  (( new > MAX_PWM )) && new=$MAX_PWM

  # Histeresis
  if [[ -n "$last" && "$last" =~ ^[0-9]+$ ]]; then
    local diff=$(( new > last ? new-last : last-new ))
    if (( diff < HYST_PWM )); then
      log "$label: mantiene PWM=$last (nuevo $new, diff $diff < $HYST_PWM)" >&2
      echo "$last"
      return 0
    fi
  fi

  if (( DRYRUN == 1 )); then
    log "$label: (DRYRUN) pondría PWM=$new" >&2
  else
    echo "$new" > "$pwm_path"
    log "$label: PWM aplicado $new → $pwm_path" >&2
  fi

  echo "$new"
}


load_last_state() {
  if [[ -r "$STATE_FILE" ]]; then
    # formato: PWM1=xxx PWM2=yyy
    # shellcheck disable=SC1090
    source "$STATE_FILE" || true
  fi
  PWM1_LAST="${PWM1_LAST:-}"
  PWM2_LAST="${PWM2_LAST:-}"
}

save_state() {
  local p1="$1" p2="$2"
  umask 077
  cat > "$STATE_FILE" <<EOF
PWM1_LAST=$p1
PWM2_LAST=$p2
EOF
}

# =========================
# Main
# =========================

need_root

if ! command -v smartctl >/dev/null 2>&1; then
  echo "ERROR: smartctl no encontrado. Instala smartmontools." >&2
  exit 1
fi

HWMON="$(find_emc_hwmon)" || true
if [[ -z "$HWMON" ]]; then
  echo "ERROR: No encuentro el hwmon de emc2305. ¿Está cargado el driver?" >&2
  exit 1
fi

PWM1_PATH="$HWMON/pwm1"
PWM2_PATH="$HWMON/pwm2"

if [[ ! -w "$PWM1_PATH" || ! -w "$PWM2_PATH" ]]; then
  echo "ERROR: No puedo escribir en $PWM1_PATH o $PWM2_PATH" >&2
  echo "Comprueba permisos/driver/overlay." >&2
  exit 1
fi

load_last_state

# Cache del scan (para saber qué /dev/sdX son NVMe USB ASMedia)
SCAN="$(smartctl --scan 2>/dev/null || true)"

MAX_HDD=0
MAX_NVME=0

log "Controlador: $HWMON"
log "Leyendo temperaturas por disco…"

# Enumerar /dev/sd?
for d in /dev/sd?; do
  [[ -b "$d" ]] || continue

  if echo "$SCAN" | grep -q "^$d .*sntasmedia"; then
    # NVMe USB ASMedia
    t="$(read_nvme_usb_temp_c "$d")"
    if [[ -n "$t" ]]; then
      log "  NVMe USB  $d → ${t}°C"
      (( t > MAX_NVME )) && MAX_NVME=$t
    else
      log "  NVMe USB  $d → (sin temp)"
    fi
  else
    # SATA/SSD/HDD
    t="$(read_sata_temp_c "$d")"
    if [[ -n "$t" ]]; then
      log "  HDD/SSD   $d → ${t}°C"
      (( t > MAX_HDD )) && MAX_HDD=$t
    else
      log "  HDD/SSD   $d → (sin temp)"
    fi
  fi
done

CPU_TEMP="$(read_cpu_temp_c)"
log "  CPU       → ${CPU_TEMP}°C"

FAST_TEMP=$(( MAX_NVME > CPU_TEMP ? MAX_NVME : CPU_TEMP ))

# Si no hay discos HDD/SSD con temp válida, MAX_HDD queda 0 → no queremos PWM mínimo ridículo:
# en ese caso, mantén al menos MIN_PWM1.
PWM1_TARGET="$(pwm_hdd_from_temp "$MAX_HDD")"
PWM2_TARGET="$(pwm_fast_from_temp "$FAST_TEMP")"

# Clamps mínimos
(( PWM1_TARGET < MIN_PWM1 )) && PWM1_TARGET=$MIN_PWM1
(( PWM2_TARGET < MIN_PWM2 )) && PWM2_TARGET=$MIN_PWM2

# Failsafe
if (( CPU_TEMP >= CPU_FAILSAFE_C )); then
  log "FAILSAFE: CPU ${CPU_TEMP}°C >= ${CPU_FAILSAFE_C}°C → PWM1=255 PWM2=255"
  PWM1_TARGET=255
  PWM2_TARGET=255
elif (( FAST_TEMP >= FAST_FAILSAFE_C )); then
  log "FAILSAFE: FAST ${FAST_TEMP}°C >= ${FAST_FAILSAFE_C}°C → PWM2=255"
  PWM2_TARGET=255
fi

log "Resumen:"
log "  Max HDD/SSD: ${MAX_HDD}°C → PWM1 target: $PWM1_TARGET"
log "  Max NVMe:    ${MAX_NVME}°C"
log "  FAST(max NVMe/CPU): ${FAST_TEMP}°C → PWM2 target: $PWM2_TARGET"

NEW_PWM1="$(apply_pwm "$PWM1_PATH" "$PWM1_TARGET" "${PWM1_LAST:-}" "PWM1 (HDD/SSD)")"
NEW_PWM2="$(apply_pwm "$PWM2_PATH" "$PWM2_TARGET" "${PWM2_LAST:-}" "PWM2 (NVMe+CPU)")"

save_state "$NEW_PWM1" "$NEW_PWM2"

log "OK."
