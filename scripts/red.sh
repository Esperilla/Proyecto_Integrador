#!/bin/bash
set -euo pipefail

###############################################################################
# red.sh
# Monitorea conectividad de hosts mediante ping y verificación de puertos.
# Clasifica los hosts como accesibles, parcialmente accesibles o sin respuesta.
# Envía alertas por Telegram cuando un host o puerto crítico falla.
# Registra todos los resultados en el log del sistema.
###############################################################################

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="$SCRIPT_DIR/../config.txt"
LOG_FILE="${LOG_FILE:-/var/log/gestion_automatizada.log}"
CURL_BIN="${CURL_BIN:-curl}"
HOSTS_FILE="${HOSTS_FILE:-${NETWORK_HOSTS_FILE:-}}"

PING_COUNT="${PING_COUNT:-2}"
HOSTS=()

if [ ! -f "$CONFIG_FILE" ]; then
    CONFIG_FILE="$PWD/config.txt"
fi

if [ ! -f "$CONFIG_FILE" ]; then
    echo "No se encontró config.txt, crea $CONFIG_FILE"
    exit 1
fi

source "$CONFIG_FILE"

if [ -z "${TELEGRAM_BOT_TOKEN:-}" ] || [ "$TELEGRAM_BOT_TOKEN" = "REPLACE_WITH_BOT_TOKEN" ]; then
  echo "ATENCIÓN: TELEGRAM_BOT_TOKEN no está configurado en $CONFIG_FILE"
fi
if [ -z "${TELEGRAM_CHAT_ID:-}" ] || [ "$TELEGRAM_CHAT_ID" = "REPLACE_WITH_CHAT_ID" ]; then
  echo "ATENCIÓN: TELEGRAM_CHAT_ID no está configurado en $CONFIG_FILE"
fi

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

parse_hosts() {
    HOSTS=()

    if [ -n "$HOSTS_FILE" ]; then
        if [ ! -f "$HOSTS_FILE" ]; then
            echo "No se encontró el archivo de hosts: $HOSTS_FILE"
            return 1
        fi

        while IFS= read -r line || [ -n "$line" ]; do
            line="${line%%#*}"
            line="${line#${line%%[![:space:]]*}}"
            line="${line%${line##*[![:space:]]}}"

            if [ -n "$line" ]; then
                HOSTS+=("$line")
            fi
        done < "$HOSTS_FILE"

        if [ "${#HOSTS[@]}" -eq 0 ]; then
            return 1
        fi

        return 0
    fi

    local raw_hosts="${NETWORK_HOSTS:-}"

    if [ -z "$raw_hosts" ]; then
        return 1
    fi

    read -r -a HOSTS <<< "$raw_hosts"
}

validate_config() {
    if ! parse_hosts; then
        echo "NETWORK_HOSTS está vacío en config.txt"
        return 1
    fi

    if ! command -v ping >/dev/null 2>&1; then
        echo "ping no está instalado."
        return 1
    fi

    if ! command -v nc >/dev/null 2>&1; then
        echo "nc (netcat) no está instalado."
        return 1
    fi
}


check_port() {
    local host="$1"
    local port="$2"
    nc -z -w 2 "$host" "$port" >/dev/null 2>&1
}

check_hosts() {

    local entry
    local host
    local ports
    local total_ports
    local open_ports
    local classification

    for entry in "${HOSTS[@]}"; do

        host="${entry%%:*}"
        ports="${entry#*:}"

        if [ "$host" = "$ports" ]; then
            ports=""
        fi

        echo
        echo "Verificando $host ..."
        total_ports=0
        open_ports=0
        classification="SIN RESPUESTA"

        if ping -c "$PING_COUNT" -W 2 "$host" >/dev/null 2>&1; then

            if [ -n "$ports" ]; then

                IFS=',' read -ra PORT_LIST <<< "$ports"

                for port in "${PORT_LIST[@]}"; do

                    total_ports=$((total_ports + 1))

                    if check_port "$host" "$port"; then
                        open_ports=$((open_ports + 1))
                    else

                        if [[ " ${CRITICAL_PORTS:-} " =~ " ${port} " ]]; then

                            send_telegram "ALERTA RED: Puerto crítico $port cerrado en $host"

                        fi
                    fi

                done
            fi

            if [ "$total_ports" -eq 0 ]; then
                classification="ACCESIBLE"

            elif [ "$open_ports" -eq "$total_ports" ]; then
                classification="ACCESIBLE"

            elif [ "$open_ports" -gt 0 ]; then
                classification="PARCIALMENTE ACCESIBLE"

            else
                classification="SIN PUERTOS DISPONIBLES"
            fi

        else

            classification="SIN RESPUESTA"

            send_telegram "ALERTA RED: Host sin respuesta -> $host"
        fi

        echo "$host => $classification"

        log_msg \
        "Host=$host Estado=$classification PuertosAbiertos=$open_ports/$total_ports"

    done
}

show_config() {
    echo "Hosts: ${NETWORK_HOSTS:-<vacío>}"
    echo "Puertos críticos: ${CRITICAL_PORTS:-<vacío>}"
    echo "Log: $LOG_FILE"
}

menu() {

    while true; do

        echo
        echo "--- Monitoreo de Red ---"
        echo "1) Ejecutar monitoreo"
        echo "2) Mostrar configuración"
        echo "3) Salir"

        read -rp "Elija una opción: " opt

        case "$opt" in
            1) check_hosts ;;
            2) show_config ;;
            3) exit 0 ;;
            *) echo "Opción inválida." ;;
        esac

    done
}

main() {

    if ! validate_config; then
        exit 1
    fi

    case "${1:-}" in

        --check)
            check_hosts
            ;;

        --show-config)
            show_config
            ;;

        "")
            menu
            ;;

        *)
            echo "Uso: $0 [--check|--show-config]"
            exit 1
            ;;

    esac
}

main "$@"