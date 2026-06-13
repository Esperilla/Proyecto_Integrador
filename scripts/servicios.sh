#!/bin/bash
set -uo pipefail

###############################################################################
# servicios.sh
# Revisa una lista de servicios definidos en config.txt, intenta reiniciarlos
# si están inactivos, notifica vía Telegram y registra en el log.
###############################################################################

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="$SCRIPT_DIR/../config.txt"
LOG_FILE="${LOG_FILE:-/var/log/gestion_automatizada.log}"
CURL_BIN="${CURL_BIN:-curl}"

if [ ! -f "$CONFIG_FILE" ]; then
  CONFIG_FILE="$PWD/config.txt"
fi

if [ ! -f "$CONFIG_FILE" ]; then
  echo "No se encontró config.txt, crea $CONFIG_FILE"
  exit 1
fi

log_init() {
  local dir
  dir="$(dirname "$LOG_FILE")"
  if [ ! -d "$dir" ]; then
    mkdir -p "$dir"
  fi
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
  if ! command -v "$CURL_BIN" >/dev/null 2>&1; then
    log_msg "ERROR: curl no disponible para notificar: $text"
    return 1
  fi
  if [ -z "${TELEGRAM_BOT_TOKEN:-}" ] || [ -z "${TELEGRAM_CHAT_ID:-}" ]; then
    log_msg "AVISO: Telegram no configurado; no se envía notificación: $text"
    return 1
  fi
  "$CURL_BIN" -s -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
    -d chat_id="${TELEGRAM_CHAT_ID}" -d text="$text" >/dev/null 2>&1 || true
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

TELEGRAM_BOT_TOKEN=$(grep -E '^TELEGRAM_BOT_TOKEN=' "$CONFIG_FILE" | sed -E 's/^[^=]*=[ \t]*"?([^"]*)"?.*/\1/' | tr -d '\r')
TELEGRAM_CHAT_ID=$(grep -E '^TELEGRAM_CHAT_ID=' "$CONFIG_FILE" | sed -E 's/^[^=]*=[ \t]*"?([^"]*)"?.*/\1/' | tr -d '\r')
LOG_FILE=$(grep -E '^LOG_FILE=' "$CONFIG_FILE" | sed -E 's/^[^=]*=[ \t]*"?([^"]*)"?.*/\1/' | tr -d '\r')
SERVICES=$(grep -E '^SERVICES=' "$CONFIG_FILE" | sed -E 's/^[^=]*=[ \t]*"?([^"]*)"?.*/\1/' | tr -d '\r')

if [ -z "$SERVICES" ]; then
    echo "La variable SERVICES no está definida en $CONFIG_FILE." >&2
    echo "Agrega una línea como: SERVICES=\"ssh nginx mysql\"" >&2
    log_msg "SERVICES no definido en config.txt. Abortando."
    exit 1
fi

log_msg "Inicio de revisión de servicios: $SERVICES"

for svc in $SERVICES; do
    svc_name="$svc"
    svc_name="${svc_name%.service}"

    if ! systemctl list-units --type=service --all | grep -q "${svc_name}.service"; then
        msg="Servicio ${svc_name} no encontrado en systemd"
        echo "$msg"
        log_msg "$msg"
        send_telegram "[servicios.sh] ${msg}"
        continue
    fi

    status=$(systemctl is-active "$svc_name" 2>/dev/null || echo unknown)
    if [ "$status" = "active" ]; then
        msg="Servicio ${svc_name} está activo"
        echo "$msg"
        log_msg "$msg"
        continue
    fi

    msg="Servicio ${svc_name} inactivo (estado: $status). Intentando reiniciar..."
    echo "$msg"
    log_msg "$msg"

    if [ "$(id -u)" -eq 0 ]; then
        restart_cmd=(systemctl restart "$svc_name")
    else
        if command -v sudo >/dev/null 2>&1; then
            restart_cmd=(sudo systemctl restart "$svc_name")
        else
            restart_cmd=(systemctl restart "$svc_name")
        fi
    fi

    if "${restart_cmd[@]}"; then
        sleep 1
        new_status=$(systemctl is-active "$svc_name" 2>/dev/null || echo unknown)
        if [ "$new_status" = "active" ]; then
            result_msg="Reinicio exitoso: ${svc_name} ahora activo"
            echo "$result_msg"
            log_msg "$result_msg"
            send_telegram "[servicios.sh] Servicio ${svc_name} reiniciado correctamente."
        else
            result_msg="Fallo al reiniciar ${svc_name}. Estado actual: $new_status"
            echo "$result_msg"
            log_msg "$result_msg"
            send_telegram "[servicios.sh] Error reiniciando ${svc_name}: estado ${new_status}"
        fi
    else
        err_msg="Error ejecutando reinicio para ${svc_name}"
        echo "$err_msg" >&2
        log_msg "$err_msg"
        send_telegram "[servicios.sh] No se pudo ejecutar reinicio de ${svc_name}. Revisa permisos." || true
    fi
done

log_msg "Fin de revisión de servicios"

exit 0
