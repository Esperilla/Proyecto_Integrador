#!/bin/bash
set -euo pipefail

###############################################################################
# inventario.sh
# Recopila información del sistema: CPU, RAM, disco, SO y kernel.
# Genera un reporte en /var/log/inventario_FECHA.txt y notifica a Telegram.
# Permite ejecución como tarea cron programada.
###############################################################################


SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="$SCRIPT_DIR/../config.txt"

LOG_FILE_DEFAULT="$SCRIPT_DIR/../logs/gestion_automatizada.log"
LOG_FILE="$LOG_FILE_DEFAULT"

if [ ! -f "$CONFIG_FILE" ]; then
	CONFIG_FILE="$PWD/config.txt"
fi
timestamp() {
	date --iso-8601=seconds
}

log_init() {
	local dir
	dir="$(dirname "$LOG_FILE")"
	mkdir -p "$dir" 2>/dev/null || true
	touch "$LOG_FILE" 2>/dev/null || true
}

log_msg() {
	log_init
	local msg="$1"
	if [ -w "$LOG_FILE" ] || [ ! -e "$LOG_FILE" ]; then
		echo "$(timestamp) - $msg" >> "$LOG_FILE" 2>/dev/null || true
	fi
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

report_file_init() {
  local dir
  dir="$(dirname "$INVENTORY_REPORT")"
  if [ ! -d "$dir" ]; then
    mkdir -p "$dir" || {
      log_msg "ERROR: no se pudo crear directorio $dir"
      exit 1
    }
  fi
  
  {
    echo "================================================================================"
    echo "                      REPORTE DE INVENTARIO DEL SISTEMA"
    echo "================================================================================"
    echo "Generado: $(date '+%d/%m/%Y %H:%M:%S')"
    echo "Hostname: $(hostname)"
    echo "================================================================================"
  } > "$INVENTORY_REPORT"
}

get_hostname_info() {
  {
    echo ""
    echo "--- INFORMACIÓN BÁSICA DEL SISTEMA ---"
    echo "Hostname: $(hostname)"
    echo "Dominio FQDN: $(hostname -f 2>/dev/null || echo 'No disponible')"
  } >> "$INVENTORY_REPORT"
}

get_os_info() {
  {
    echo ""
    echo "--- SISTEMA OPERATIVO ---"
    if [ -f /etc/os-release ]; then
      grep "^PRETTY_NAME" /etc/os-release | cut -d= -f2 | tr -d '"'
    else
      lsb_release -d 2>/dev/null | cut -f2 || echo "No disponible"
    fi
    echo "Kernel: $(uname -r)"
    echo "Arquitectura: $(uname -m)"
  } >> "$INVENTORY_REPORT"
}

get_cpu_info() {
  {
    echo ""
    echo "--- INFORMACIÓN DE CPU ---"
    
    # Modelo de CPU
    if grep -q "model name" /proc/cpuinfo; then
      model=$(grep "model name" /proc/cpuinfo | head -1 | cut -d: -f2 | xargs)
      echo "Modelo: $model"
    fi
    
    # Número de núcleos físicos
    if command -v nproc >/dev/null 2>&1; then
      cores=$(nproc)
      echo "Núcleos lógicos: $cores"
    fi
    
    # Velocidad de CPU (si disponible)
    if grep -q "cpu MHz" /proc/cpuinfo; then
      freq=$(grep "cpu MHz" /proc/cpuinfo | head -1 | cut -d: -f2 | xargs | cut -d. -f1)
      echo "Frecuencia: ${freq} MHz"
    fi
  } >> "$INVENTORY_REPORT"
}