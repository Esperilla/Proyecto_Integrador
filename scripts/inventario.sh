#!/bin/bash
set -euo pipefail
source "${0%/*}"/mensajes.sh
###############################################################################
# inventario.sh
# Recopila información del sistema: CPU, RAM, disco, SO y kernel.
# Genera un reporte en /var/log/inventario_FECHA.txt y notifica a Telegram.
# Permite ejecución como tarea cron programada.
###############################################################################

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="$SCRIPT_DIR/../config.txt"
LOG_FILE="${LOG_FILE:-/var/log/gestion_automatizada.log}"
CURL_BIN="${CURL_BIN:-curl}"

# Archivo de salida del inventario y ubicación donde se guardará.
INVENTORY_REPORT_DIR="/var/log"
TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
INVENTORY_REPORT="$INVENTORY_REPORT_DIR/inventario_$TIMESTAMP.txt"

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
  mensaje_advertencia "TELEGRAM_BOT_TOKEN no está configurado en $CONFIG_FILE"
fi
if [ -z "${TELEGRAM_CHAT_ID:-}" ] || [ "$TELEGRAM_CHAT_ID" = "REPLACE_WITH_CHAT_ID" ]; then
  mensaje_advertencia "TELEGRAM_CHAT_ID no está configurado en $CONFIG_FILE"
fi

# Inicializa el archivo de log creando el directorio si hace falta.
log_init() {
  local dir
  dir="$(dirname "$LOG_FILE")"
  if [ ! -d "$dir" ]; then
    mkdir -p "$dir"
  fi
  touch "$LOG_FILE" || true
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

# Crea el archivo de reporte y escribe el encabezado con fecha y host.
report_file_init() {
  local dir
  dir="$(dirname "$INVENTORY_REPORT")"
  if [ ! -d "$dir" ]; then
    mkdir -p "$dir" || {
      log_msg "ERROR: no se pudo crear directorio $dir"
      exit 1
    }
  fi
  
  # Crear encabezado del reporte
  {
    echo "================================================================================"
    mensaje_info "                      REPORTE DE INVENTARIO DEL SISTEMA"
    echo "================================================================================"
# Información básica para identificar el sistema donde se ejecuta el script.
    echo "Generado: $(date '+%d/%m/%Y %H:%M:%S')"
    echo "Hostname: $(hostname)"
    echo "================================================================================"
  } > "$INVENTORY_REPORT"
}

get_hostname_info() {
  {
    echo ""
    mensaje_info "--- INFORMACIÓN BÁSICA DEL SISTEMA ---"
    echo "Hostname: $(hostname)"
    echo "Dominio FQDN: $(hostname -f 2>/dev/null || echo 'No disponible')"
  } >> "$INVENTORY_REPORT"
}

# Datos del sistema operativo, kernel y arquitectura.
get_os_info() {
  {
    echo ""
    mensaje_info "--- SISTEMA OPERATIVO ---"
    if [ -f /etc/os-release ]; then
      grep "^PRETTY_NAME" /etc/os-release | cut -d= -f2 | tr -d '"'
    else
      lsb_release -d 2>/dev/null | cut -f2 || echo "No disponible"
    fi
    echo "Kernel: $(uname -r)"
    echo "Arquitectura: $(uname -m)"
  } >> "$INVENTORY_REPORT"
}

# Extrae datos de CPU desde /proc/cpuinfo y herramientas disponibles en el sistema.
get_cpu_info() {
  {
    echo ""
    mensaje_info "--- INFORMACIÓN DE CPU ---"
    
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

# Calcula memoria total, usada y disponible usando /proc/meminfo.
get_memory_info() {
  {
    echo ""
    mensaje_info "--- INFORMACIÓN DE MEMORIA RAM ---"
    
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

# Muestra el uso de discos en formato legible para el reporte.
get_disk_info() {
  {
    echo ""
    mensaje_info "--- INFORMACIÓN DE DISCOS Y PARTICIONES ---"
    echo ""
    df -h | awk 'NR==1 {next} {
      printf "%-20s %8s %8s %8s %6s %s\n", 
      $1, $2, $3, $4, $5, $6
    }' | {
      # Agregar encabezado
      echo "Sistema         Tamaño  Usado Disponible   Uso% Montado"
      echo "------- ---------- ---------- ------------ ------ --------"
      cat
    }
  } >> "$INVENTORY_REPORT"
}

main() {
  # Inicializa el archivo antes de escribir cualquier sección.
  report_file_init
  
  # Marca el inicio del proceso en el log.
  log_msg "Iniciando recopilación de inventario del sistema"
  
  # Recolecta cada bloque de información del sistema.
  get_hostname_info
  get_os_info
  get_cpu_info
  get_memory_info
  get_disk_info
  
  # Cierra el reporte con un mensaje visual de finalización.
  {
    echo ""
    echo "================================================================================"
    mensaje_exito "Reporte generado exitosamente"
    echo "================================================================================"
  } >> "$INVENTORY_REPORT"
  
  # Deja evidencia del archivo generado.
  log_msg "Reporte de inventario generado: $INVENTORY_REPORT"
  
  # Construye un resumen corto para enviar por Telegram.
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
  
  # Envía el resumen y registra que se notificó.
  send_telegram "$summary"
  log_msg "Notificación de inventario enviada a Telegram"
  
  # Salida final para consola.
  mensaje_exito "Inventario recopilado exitosamente"
  mensaje_info "Reporte guardado en: $INVENTORY_REPORT"
  cat "$INVENTORY_REPORT"
  exit 0
}

# Punto de entrada del script.
main
