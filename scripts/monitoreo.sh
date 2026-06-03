#!/bin/bash
set -euo pipefail

###############################################################################
# monitoreo.sh
# Monitoreo de uso de CPU y disco, registra lecturas y alerta por Telegram
# según umbrales configurables por argumentos o `config.txt`.
###############################################################################

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="$SCRIPT_DIR/../config.txt"
if [ ! -f "$CONFIG_FILE" ]; then
  CONFIG_FILE="$PWD/config.txt"
fi

if [ ! -f "$CONFIG_FILE" ]; then
  echo "No se encontró config.txt"
  exit 1
fi

source "$CONFIG_FILE"

LOG_FILE="${LOG_FILE:-/var/log/gestion_automatizada.log}"
CURL_BIN="${CURL_BIN:-curl}"

CPU_THRESHOLD_DEFAULT=70
DISK_THRESHOLD_DEFAULT=70
INTERVAL=60
RUN_ONCE=1
CPU_THRESHOLD=${CPU_THRESHOLD_DEFAULT}
DISK_THRESHOLD=${DISK_THRESHOLD_DEFAULT}
DISK_PATHS="/"

log_init() {
  local dir
  dir="$(dirname "$LOG_FILE")"
  if [ ! -d "$dir" ]; then
    mkdir -p "$dir"
  fi
  touch "$LOG_FILE" || true
}

log_msg() {
  log_init
  local ts msg
  ts="$(date --iso-8601=seconds)"
  msg="$1"
  echo "$ts - $msg" >> "$LOG_FILE"
}

send_telegram() {
  local text="$1"
  if [ -z "${TELEGRAM_BOT_TOKEN:-}" ] || [ -z "${TELEGRAM_CHAT_ID:-}" ]; then
    log_msg "AVISO: Telegram no configurado; no se envía notificación: $text"
    return 1
  fi
  if ! command -v "$CURL_BIN" >/dev/null 2>&1; then
    log_msg "ERROR: curl no disponible para Telegram: $text"
    return 1
  fi
  "$CURL_BIN" -s -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
    -d chat_id="${TELEGRAM_CHAT_ID}" -d text="$text" >/dev/null 2>&1 || true
}

usage() {
  cat <<EOF
Uso: $0 [--cpu N] [--disk N] [--paths "/ /home"] [--interval S] [--once]
  --cpu N       umbral CPU (%) (por defecto $CPU_THRESHOLD_DEFAULT)
  --disk N      umbral Disco (%) (por defecto $DISK_THRESHOLD_DEFAULT)
  --paths P1,P2  rutas de particiones a comprobar (por defecto: /)
  --interval S  intervalo en segundos para lecturas periódicas (por defecto $INTERVAL)
  --once        ejecutar una vez y salir (por defecto)
  --help        muestra esta ayuda
EOF
}

parse_args() {
  while [ $# -gt 0 ]; do
    case "$1" in
      --cpu)
        CPU_THRESHOLD="$2"; shift 2 ;;
      --disk)
        DISK_THRESHOLD="$2"; shift 2 ;;
      --paths)
        DISK_PATHS="$2"; shift 2 ;;
      --interval)
        INTERVAL="$2"; RUN_ONCE=0; shift 2 ;;
      --once)
        RUN_ONCE=1; shift 1 ;;
      --help|-h)
        usage; exit 0 ;;
      *) echo "Opción inválida: $1"; usage; exit 1 ;;
    esac
  done
}

cpu_usage_percent() {
  local prev total1 idle1 next total2 idle2 diff_total diff_idle busy pct
  read -r _ prev < <(awk '/^cpu /{print $0}' /proc/stat)
  total1=0; idle1=0
  for v in $prev; do total1=$((total1+v)); done
  idle1=$(echo $prev | awk '{print $4}')
  sleep 1
  read -r _ next < <(awk '/^cpu /{print $0}' /proc/stat)
  total2=0; idle2=0
  for v in $next; do total2=$((total2+v)); done
  idle2=$(echo $next | awk '{print $4}')
  diff_total=$((total2 - total1))
  diff_idle=$((idle2 - idle1))
  busy=$((diff_total - diff_idle))
  if [ $diff_total -le 0 ]; then
    echo 0
    return
  fi
  pct=$((100 * busy / diff_total))
  echo "$pct"
}

disk_usage_percent() {
  local path="$1"
  if [ ! -e "$path" ]; then
    echo "0"
    return
  fi
  df -P "$path" 2>/dev/null | awk 'NR==2{gsub(/%/,"",$5); print $5}' || echo 0
}

check_once() {
  local cpu disk pct_cpu pct_disk msg
  pct_cpu=$(cpu_usage_percent)
  msg="CPU: ${pct_cpu}%"
  log_msg "LECTURA: $msg"
  if [ "$pct_cpu" -ge "$CPU_THRESHOLD" ]; then
    send_telegram "[Monitoreo] Alerta CPU: ${pct_cpu}% >= ${CPU_THRESHOLD}%"
    log_msg "ALERTA: CPU ${pct_cpu}% >= ${CPU_THRESHOLD}%"
  fi

  IFS=',' read -ra paths <<<"$DISK_PATHS"
  for p in "${paths[@]}"; do
    pct_disk=$(disk_usage_percent "$p")
    log_msg "LECTURA: Disco($p): ${pct_disk}%"
    if [ "$pct_disk" -ge "$DISK_THRESHOLD" ]; then
      send_telegram "[Monitoreo] Alerta Disco $p: ${pct_disk}% >= ${DISK_THRESHOLD}%"
      log_msg "ALERTA: Disco($p) ${pct_disk}% >= ${DISK_THRESHOLD}%"
    fi
  done
}

trap 'echo; log_msg "Interrumpido por señal. Saliendo."; exit 0' SIGINT SIGTERM

main() {
  parse_args "$@"

  if ! [[ "$CPU_THRESHOLD" =~ ^[0-9]+$ ]]; then echo "CPU threshold inválido"; exit 1; fi
  if ! [[ "$DISK_THRESHOLD" =~ ^[0-9]+$ ]]; then echo "DISK threshold inválido"; exit 1; fi

  if [ "$RUN_ONCE" -eq 1 ]; then
    check_once
    exit 0
  fi

  while true; do
    check_once
    sleep "$INTERVAL"
  done
}

main "$@"