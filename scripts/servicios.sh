#!/bin/bash
set -euo pipefail
source "${0%/*}"/mensajes.sh
###############################################################################
# servicios.sh
# Revisa una lista de servicios definidos en config.txt, intenta reiniciarlos
# si están inactivos, notifica vía Telegram y registra en el log.
###############################################################################

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="$SCRIPT_DIR/../config.txt"
LOG_FILE="${LOG_FILE:-/var/log/gestion_automatizada.log}"
CURL_BIN="${CURL_BIN:-curl}"

# Lista de servicios a revisar, puede redefinirse desde config.txt.
SERVICES="ssh nginx mysql"

# Intenta ubicar config.txt relativo al script; si no existe, usa el directorio actual.
if [ ! -f "$CONFIG_FILE" ]; then
  CONFIG_FILE="$PWD/config.txt"
fi

if [ ! -f "$CONFIG_FILE" ]; then
  mensaje_error "No se encontró config.txt, crea $CONFIG_FILE"
  exit 1
fi

# Cargar configuración.
source "$CONFIG_FILE"

if [ -z "${TELEGRAM_BOT_TOKEN:-}" ] || [ "$TELEGRAM_BOT_TOKEN" = "REPLACE_WITH_BOT_TOKEN" ]; then
  mensaje_advertencia "ATENCIÓN: TELEGRAM_BOT_TOKEN no está configurado en $CONFIG_FILE"
fi
if [ -z "${TELEGRAM_CHAT_ID:-}" ] || [ "$TELEGRAM_CHAT_ID" = "REPLACE_WITH_CHAT_ID" ]; then
  mensaje_advertencia "ATENCIÓN: TELEGRAM_CHAT_ID no está configurado en $CONFIG_FILE"
fi

# Inicializa el archivo de log creando el directorio si hace falta.
log_init() {
  local dir
  dir="$(dirname "$LOG_FILE")"
  if [ ! -d "$dir" ]; then
    mkdir -p "$dir"
  fi
}

# Registra eventos con marca de tiempo ISO-8601.
log_msg() {
  log_init
  local ts msg
  ts="$(date --iso-8601=seconds)"
  msg="$1"
  echo "$ts - $msg" >> "$LOG_FILE"
}

# Envía notificaciones a Telegram; si no hay configuración, solo deja rastro en log.
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

# Muestra cómo ejecutar el script y qué variable espera en config.txt.
usage() {
    cat <<EOF
Uso: $(basename "$0")
Lee la lista de servicios desde config.txt en la variable SERVICES.
Opciones:
  -h    Muestra esta ayuda
EOF
}

# Permite salir limpio con Ctrl+C o una señal de terminación.
trap 'log_msg "Script interrumpido"; exit 1' INT TERM

if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
    usage
    exit 0
fi

# Si SERVICES quedó vacío, no hay nada que revisar y se detiene con mensaje claro.
if [ -z "$SERVICES" ]; then
    mensaje_error "La variable SERVICES no está definida en $CONFIG_FILE."
    mensaje_info "Agrega una línea como: SERVICES=\"ssh nginx mysql\""
    log_msg "SERVICES no definido en config.txt. Abortando."
    exit 1
fi

# Inicio de la revisión: recorre cada servicio definido y actúa según su estado.
log_msg "Inicio de revisión de servicios: $SERVICES"

for svc in $SERVICES; do
  # Normaliza el nombre por si el usuario escribió 'nginx.service'.
    svc_name="$svc"
    svc_name="${svc_name%.service}"

  # Verifica que el servicio exista antes de consultar o reiniciar.
    if ! systemctl list-units --type=service --all | grep -q "${svc_name}.service"; then
        msg="Servicio ${svc_name} no encontrado en systemd"
        mensaje_info "$msg"
        log_msg "$msg"
        send_telegram "[Servicios.sh] ${msg}"
        continue
    fi

      # Consulta si el servicio ya está activo.
    status=$(systemctl is-active "$svc_name" 2>/dev/null || echo unknown)
    if [ "$status" = "active" ]; then
        msg="Servicio ${svc_name} está activo"
        mensaje_info "$msg"
        log_msg "$msg"
        continue
    fi

    msg="Servicio ${svc_name} inactivo (estado: $status). Intentando reiniciar..."
    mensaje_advertencia "$msg"
    log_msg "$msg"

    # Construye el comando de reinicio: usa sudo si no se ejecuta como root.
    if [ "$(id -u)" -eq 0 ]; then
        restart_cmd=(systemctl restart "$svc_name")
    else
        if command -v sudo >/dev/null 2>&1; then
            restart_cmd=(sudo systemctl restart "$svc_name")
        else
            restart_cmd=(systemctl restart "$svc_name")
        fi
    fi

      # Tras reiniciar, vuelve a consultar el estado para confirmar el resultado.
    if "${restart_cmd[@]}"; then
        sleep 1
        new_status=$(systemctl is-active "$svc_name" 2>/dev/null || echo unknown)
        if [ "$new_status" = "active" ]; then
            result_msg="Reinicio exitoso: ${svc_name} ahora activo"
            mensaje_exito "$result_msg"
            log_msg "$result_msg"
            send_telegram "[Servicios.sh] Servicio ${svc_name} reiniciado correctamente."
        else
            result_msg="Fallo al reiniciar ${svc_name}. Estado actual: $new_status"
            mensaje_error "$result_msg"
            log_msg "$result_msg"
            send_telegram "[Servicios.sh] Error reiniciando ${svc_name}: estado ${new_status}"
        fi
    else
        err_msg="Error ejecutando reinicio para ${svc_name}"
        mensaje_error "$err_msg"
        log_msg "$err_msg"
        send_telegram "[Servicios.sh] No se pudo ejecutar reinicio de ${svc_name}. Revisa permisos." || true
    fi
done

  # Cierre normal del ciclo de revisión.
log_msg "Fin de revisión de servicios"

exit 0
