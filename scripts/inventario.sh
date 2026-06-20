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


get_memory_info() {
  {
    echo ""
    echo "--- INFORMACIÓN DE MEMORIA RAM ---"
    
    # RAM total
    if [ -f /proc/meminfo ]; then
      total_kb=$(grep "^MemTotal:" /proc/meminfo | awk '{print $2}')
      available_kb=$(grep "^MemAvailable:" /proc/meminfo | awk '{print $2}')
      used_kb=$((total_kb - available_kb))
      
      # Convertir a MB/GB
      total_mb=$((total_kb / 1024))
      available_mb=$((available_kb / 1024))
      used_mb=$((used_kb / 1024))
      
      echo "RAM Total: ${total_mb} MB ($(echo "scale=2; $total_mb/1024" | bc) GB)"
      echo "RAM Disponible: ${available_mb} MB ($(echo "scale=2; $available_mb/1024" | bc) GB)"
      echo "RAM Usada: ${used_mb} MB ($(echo "scale=2; $used_mb/1024" | bc) GB)"
      
      # Porcentaje de uso
      if [ "$total_kb" -gt 0 ]; then
        percent=$((used_kb * 100 / total_kb))
        echo "Porcentaje de Uso: ${percent}%"
      fi
    fi
  } >> "$INVENTORY_REPORT"
}

get_disk_info() {
  {
    echo ""
    echo "--- INFORMACIÓN DE DISCOS Y PARTICIONES ---"
    echo ""
    df -h | awk 'NR==1 {next} {
      printf "%-20s %8s %8s %8s %6s %s\n", 
      $1, $2, $3, $4, $5, $6
    }' | {
      echo "Sistema         Tamaño  Usado Disponible   Uso% Montado"
      echo "------- ---------- ---------- ------------ ------ --------"
      cat
    }
  } >> "$INVENTORY_REPORT"
}

main() {
  report_file_init
  
  log_msg "Iniciando recopilación de inventario del sistema"
  
  get_hostname_info
  get_os_info
  get_cpu_info
  get_memory_info
  get_disk_info
  
  {
    echo ""
    echo "================================================================================"
    echo "Reporte generado exitosamente"
    echo "================================================================================"
  } >> "$INVENTORY_REPORT"
  
  log_msg "Reporte de inventario generado: $INVENTORY_REPORT"
  
  summary=$(cat <<EOF
🖥️ *INVENTARIO DEL SISTEMA*

*Hostname:* $(hostname)

*OS:* $(grep "^PRETTY_NAME" /etc/os-release 2>/dev/null | cut -d= -f2 | tr -d '"' || echo 'No disponible')
*Kernel:* $(uname -r)

*CPU:* $(grep "model name" /proc/cpuinfo 2>/dev/null | head -1 | cut -d: -f2 | xargs || echo 'No disponible')
*Núcleos:* $(nproc 2>/dev/null || echo 'No disponible')

*RAM Total:* $(grep "^MemTotal:" /proc/meminfo 2>/dev/null | awk '{print int($2/1024/1024) "GB"}' || echo 'No disponible')
*RAM Disponible:* $(grep "^MemAvailable:" /proc/meminfo 2>/dev/null | awk '{print int($2/1024/1024) "GB"}' || echo 'No disponible')

*Reporte completo:* $INVENTORY_REPORT
EOF
  )
  
  send_telegram "$summary"
  log_msg "Notificación de inventario enviada a Telegram"
  
  echo "✓ Inventario recopilado exitosamente"
  echo "✓ Reporte guardado en: $INVENTORY_REPORT"
  cat "$INVENTORY_REPORT"
  exit 0
}

main
