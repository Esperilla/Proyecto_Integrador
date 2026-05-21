#!/bin/bash
set -euo pipefail

###############################################################################
# usuarios.sh
# Script para crear, eliminar y modificar usuarios del sistema.
# Lee configuración desde config.txt, valida entradas, registra acciones y
# notifica a un bot de Telegram por cada acción.
# Uso: ejecutar como root (sudo).
###############################################################################

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="$SCRIPT_DIR/../config.txt"
if [ ! -f "$CONFIG_FILE" ]; then
  CONFIG_FILE="$PWD/config.txt"
fi

if [ ! -f "$CONFIG_FILE" ]; then
  echo "No se encontró config.txt. Copia config.txt.example o crea $CONFIG_FILE"
  exit 1
fi

source "$CONFIG_FILE"

if [ -z "${TELEGRAM_BOT_TOKEN:-}" ] || [ "$TELEGRAM_BOT_TOKEN" = "REPLACE_WITH_BOT_TOKEN" ]; then
  echo "ATENCIÓN: TELEGRAM_BOT_TOKEN no está configurado en $CONFIG_FILE"
fi
if [ -z "${TELEGRAM_CHAT_ID:-}" ] || [ "$TELEGRAM_CHAT_ID" = "REPLACE_WITH_CHAT_ID" ]; then
  echo "ATENCIÓN: TELEGRAM_CHAT_ID no está configurado en $CONFIG_FILE"
fi

LOG_FILE="${LOG_FILE:-/var/log/gestion_automatizada.log}"
CURL_BIN="${CURL_BIN:-curl}"

ensure_log_dir() {
  local dir
  dir="$(dirname "$LOG_FILE")"
  if [ ! -d "$dir" ]; then
    mkdir -p "$dir"
  fi
  touch "$LOG_FILE" || true
}

log_action() {
  ensure_log_dir
  local ts msg
  ts="$(date --iso-8601=seconds)"
  msg="$1"
  echo "$ts - $msg" >> "$LOG_FILE"
}

send_telegram() {
  local text="$1"
  if ! command -v "$CURL_BIN" >/dev/null 2>&1; then
    log_action "ERROR: curl no disponible para notificar: $text"
    return 1
  fi
  if [ -z "${TELEGRAM_BOT_TOKEN:-}" ] || [ -z "${TELEGRAM_CHAT_ID:-}" ]; then
    log_action "AVISO: credenciales Telegram incompletas; no se envía: $text"
    return 1
  fi
  "$CURL_BIN" -s -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
    -d chat_id="${TELEGRAM_CHAT_ID}" -d text="$text" >/dev/null 2>&1 || true
}

