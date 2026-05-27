#!/bin/bash
set -u -o pipefail

###############################################################################
# respaldo.sh
# Script para comprimir uno o más directorios con tar, verificar el respaldo,
# notificar por Telegram y registrar el resultado en el log del sistema.
# También permite programar la ejecución periódica con cron para el usuario
# actual, sin requerir privilegios de root.
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
BACKUP_PREFIX="${BACKUP_PREFIX:-respaldo}"
BACKUP_DEST_DIR="${BACKUP_DEST_DIR:-$HOME/backups}"
CRON_SCHEDULE="${CRON_SCHEDULE:-0 2 * * *}"

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

parse_sources() {
  local raw_sources="${BACKUP_SOURCE_DIRS:-}"
  if [ -z "$raw_sources" ]; then
    return 1
  fi
  BACKUP_SOURCES=( $raw_sources )
}

validate_sources() {
  local src
  if ! parse_sources; then
    echo "BACKUP_SOURCE_DIRS está vacío en config.txt"
    return 1
  fi
  for src in "${BACKUP_SOURCES[@]}"; do
    if [ ! -d "$src" ]; then
      echo "No existe el directorio: $src"
      return 1
    fi
  done
}

do_backup() {
  local ts archive archive_size
  if ! validate_sources; then
    log_msg "RESPALDO FALLIDO: directorios inválidos"
    return 1
  fi

  mkdir -p "$BACKUP_DEST_DIR"
  ts="$(date +%Y%m%d_%H%M%S)"
  archive="$BACKUP_DEST_DIR/${BACKUP_PREFIX}_${ts}.tar.gz"

  if tar -czf "$archive" -P "${BACKUP_SOURCES[@]}"; then
    if [ -f "$archive" ] && [ -s "$archive" ]; then
      archive_size="$(du -h "$archive" | awk '{print $1}')"
      local msg="Respaldo generado: $archive | Tamaño: $archive_size | Fecha: $(date --iso-8601=seconds)"
      echo "$msg"
      log_msg "$msg"
      send_telegram "[Respaldo] $msg"
      return 0
    fi
  fi

  rm -f "$archive" 2>/dev/null || true
  log_msg "RESPALDO FALLIDO: no se generó un archivo válido"
  echo "Error: el archivo comprimido no se generó correctamente."
  return 1
}

install_cron() {
  local script_path cron_line current_cron
  if ! command -v crontab >/dev/null 2>&1; then
    echo "crontab no está instalado en este entorno."
    return 1
  fi

  script_path="$(realpath "$0")"
  cron_line="$CRON_SCHEDULE /bin/bash \"$script_path\" --backup-now >> \"$LOG_FILE\" 2>&1"

  current_cron="$(crontab -l 2>/dev/null || true)"
  current_cron="$(printf '%s\n' "$current_cron" | grep -vF "$script_path" || true)"

  printf '%s\n%s\n' "$current_cron" "$cron_line" | sed '/^$/d' | crontab -
  log_msg "Cron instalado para ejecutar respaldo: $cron_line"
  echo "Cron configurado correctamente para el usuario actual."
}