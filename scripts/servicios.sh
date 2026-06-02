#!/bin/bash
set -uo pipefail
# servicios.sh
# Revisa una lista de servicios definidos en config.txt, intenta reiniciarlos
# si están inactivos, notifica vía Telegram y registra en el log.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="$SCRIPT_DIR/../config.txt"
timestamp() { date '+%Y-%m-%d %H:%M:%S'; }

log_msg() {
    local msg="$1"
    if [ -n "${LOG_FILE:-}" ]; then
        echo "$(timestamp) - ${msg}" >> "$LOG_FILE" 2>/dev/null || echo "$(timestamp) - ${msg}" >> "$SCRIPT_DIR/gestion_automatizada.log"
    else
        echo "$(timestamp) - ${msg}" >> "$SCRIPT_DIR/gestion_automatizada.log"
    fi
}
send_telegram() {
    local text="$1"
    if [ -z "${TELEGRAM_BOT_TOKEN:-}" ] || [ -z "${TELEGRAM_CHAT_ID:-}" ]; then
        log_msg "Telegram no configurado: mensaje no enviado: $text"
        return 1
    fi
    curl -s -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
        --data-urlencode "chat_id=${TELEGRAM_CHAT_ID}" \
        --data-urlencode "text=${text}" >/dev/null 2>&1 || return 1
}
usage() {
    cat <<EOF
Uso: $(basename "$0")
Lee la lista de servicios desde config.txt en la variable SERVICES.
Opciones:
  -h    Muestra esta ayuda
EOF
}

trap 'log_msg "Script interrumpido"; exit 1' INT TERM
if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
    usage
    exit 0
fi
if [ ! -f "$CONFIG_FILE" ]; then
    echo "No se encontró config.txt en $CONFIG_FILE" >&2
    exit 1
fi
# Cargar variables esenciales desde config.txt sin usar 'source' directo (evita CRLF issues)
TELEGRAM_BOT_TOKEN=$(grep -E '^TELEGRAM_BOT_TOKEN=' "$CONFIG_FILE" | sed -E 's/^[^=]*=[ \t]*"?(.*)"?/\1/' | tr -d '\r')
TELEGRAM_CHAT_ID=$(grep -E '^TELEGRAM_CHAT_ID=' "$CONFIG_FILE" | sed -E 's/^[^=]*=[ \t]*"?(.*)"?/\1/' | tr -d '\r')
LOG_FILE=$(grep -E '^LOG_FILE=' "$CONFIG_FILE" | sed -E 's/^[^=]*=[ \t]*"?(.*)"?/\1/' | tr -d '\r')
SERVICES=$(grep -E '^SERVICES=' "$CONFIG_FILE" | sed -E 's/^[^=]*=[ \t]*"?(.*)"?/\1/' | tr -d '\r')
if [ -z "$SERVICES" ]; then
    log_msg "No se definieron servicios en config.txt (SERVICES)"
    exit 1
fi