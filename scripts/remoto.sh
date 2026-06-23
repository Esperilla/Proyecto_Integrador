#!/bin/bash
set -euo pipefail
source "${0%/*}"/mensajes.sh
###############################################################################
# remoto.sh
# Copia un script local a hosts remotos por SCP, lo ejecuta por SSH y genera
# reportes individuales por host con resultado y timestamp.
###############################################################################

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="$SCRIPT_DIR/../config.txt"
CURL_BIN="${CURL_BIN:-curl}"

# Valores base del flujo remoto; pueden sobrescribirse desde config.txt o por argumentos.
LOG_FILE_DEFAULT="$SCRIPT_DIR/../logs/gestion_automatizada.log"
LOG_FILE="$LOG_FILE_DEFAULT"
HOSTS_FILE=""
LOCAL_SCRIPT=""
SSH_USER=""
SSH_PORT="22"
SSH_KEY=""
TARGET_DIR="/tmp"
REPORT_DIR=""
CONNECT_TIMEOUT="8"

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

# Devuelve una marca temporal uniforme para logs y reportes.
timestamp() {
date --iso-8601=seconds
}

# Inicializa el archivo de log creando el directorio si hace falta.
log_init() {
local dir
dir="$(dirname "$LOG_FILE")"
mkdir -p "$dir" 2>/dev/null || true
touch "$LOG_FILE" 2>/dev/null || true
}

# Registra eventos del proceso remoto en el log local.
log_msg() {
log_init
local msg="$1"
if [ -w "$LOG_FILE" ] || [ ! -e "$LOG_FILE" ]; then
echo "$(timestamp) - $msg" >> "$LOG_FILE" 2>/dev/null || true
fi
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

# Muestra cómo ejecutar el script y qué variables espera en config.txt.
usage() {
cat <<EOF
Uso: $(basename "$0") -f HOSTS_FILE -s LOCAL_SCRIPT [opciones]

Opciones:
-f, --hosts FILE         Archivo de hosts/IPs (uno por linea)
-s, --script FILE        Script local a copiar y ejecutar remotamente
-u, --user USER          Usuario SSH remoto (default: $SSH_USER)
-p, --port PORT          Puerto SSH (default: 22)
-i, --identity FILE      Llave privada SSH
-d, --remote-dir DIR     Directorio remoto temporal (default: /tmp)
-o, --output-dir DIR     Directorio base de reportes
-t, --timeout SEG        Timeout de conexion en segundos (default: 8)
-h, --help               Mostrar esta ayuda

Tambien puedes definir valores en config.txt:
HOSTS_FILE, SCRIPT_LOCAL, SSH_USER, SSH_PORT,
SSH_KEY, TARGET_DIR, REPORT_DIR, CONNECT_TIMEOUT.
EOF
}

# Verifica que la herramienta pedida esté instalada antes de continuar.
require_command() {
local cmd="$1"
if ! command -v "$cmd" >/dev/null 2>&1; then
mensaje_error "Error: se requiere '$cmd' y no esta instalado."
exit 1
fi
}

# Convierte un host a un nombre seguro para usarlo en archivos de reporte.
sanitize_host() {
echo "$1" | sed 's/[^A-Za-z0-9_.-]/_/g'
}

# Acepta solo nombres de host simples, sin caracteres especiales.
is_valid_host() {
local host="$1"
[[ "$host" =~ ^[A-Za-z0-9._-]+$ ]]
}

# Procesa argumentos y sobrescribe la configuración por defecto.
parse_args() {
while [ $# -gt 0 ]; do
case "$1" in
-f|--hosts)
HOSTS_FILE="${2:-}"
shift 2
;;
-s|--script)
LOCAL_SCRIPT="${2:-}"
shift 2
;;
-u|--user)
SSH_USER="${2:-}"
shift 2
;;
-p|--port)
SSH_PORT="${2:-}"
shift 2
;;
-i|--identity)
SSH_KEY="${2:-}"
shift 2
;;
-d|--remote-dir)
TARGET_DIR="${2:-}"
shift 2
;;
-o|--output-dir)
REPORT_DIR="${2:-}"
shift 2
;;
-t|--timeout)
CONNECT_TIMEOUT="${2:-}"
shift 2
;;
-h|--help)
usage
exit 0
;;
*)
mensaje_advertencia "Opcion invalida: $1"
usage
exit 1
;;
esac
done
}

# Lee el archivo de hosts, elimina comentarios/espacios y deja solo entradas validas.
read_hosts() {
local file="$1"
local line
HOSTS=()

while IFS= read -r line || [ -n "$line" ]; do
line="$(echo "$line" | tr -d '\r')"
line="${line%%#*}"
line="$(echo "$line" | sed -E 's/^[[:space:]]+|[[:space:]]+$//g')"
[ -z "$line" ] && continue
HOSTS+=("$line")
done < "$file"
}

# Guarda el resultado de cada host en un archivo de reporte individual.
write_report() {
local host="$1"
local safe_host="$2"
local status="$3"
local exit_code="$4"
local output="$5"
local report_file="$6"

{
echo "HOST=$host"
echo "TIMESTAMP=$(timestamp)"
echo "ESTADO=$status"
echo "CODIGO_SALIDA=$exit_code"
echo "SCRIPT_LOCAL=$LOCAL_SCRIPT"
echo "USUARIO_REMOTO=$SSH_USER"
echo "PUERTO_SSH=$SSH_PORT"
echo ""
echo "--- SALIDA REMOTA ---"
echo "$output"
} > "$report_file"

log_msg "Reporte generado para $host ($status): $report_file"
echo "[$safe_host] $status -> $report_file"
}

# Copia el script al host, lo ejecuta y registra el resultado final.
copy_and_execute_host() {
local host="$1"
local safe_host
local report_file
local remote_name
local remote_path
# Variables locales para paths y comandos SCP/SSH
local remote_config_path
local local_config_path
local local_messages_path
local output
local rc

safe_host="$(sanitize_host "$host")"
report_file="$RUN_REPORT_DIR/${safe_host}_$(date +%Y%m%d_%H%M%S).txt"

if ! is_valid_host "$host"; then
write_report "$host" "$safe_host" "HOST_INVALIDO" "1" "Host con formato invalido" "$report_file"
FAIL_COUNT=$((FAIL_COUNT + 1))
return
fi

remote_name="$(basename "$LOCAL_SCRIPT")"
remote_path="$TARGET_DIR/${remote_name%.*}_$$_$(date +%s).sh"
remote_config_path="$TARGET_DIR/config.txt"
local_config_path="$SCRIPT_DIR/../config.txt"
local_messages_path="$(dirname "$LOCAL_SCRIPT")/mensajes.sh"

# Define los comandos SSH/SCP con timeout y autenticación opcional por llave.
SCP_CMD=(scp -P "$SSH_PORT" -o BatchMode=yes -o ConnectTimeout="$CONNECT_TIMEOUT")
SSH_CMD=(ssh -p "$SSH_PORT" -o BatchMode=yes -o ConnectTimeout="$CONNECT_TIMEOUT")

if [ -n "$SSH_KEY" ]; then
SCP_CMD+=( -i "$SSH_KEY" )
SSH_CMD+=( -i "$SSH_KEY" )
fi

# Primero copia el script; si falla, guarda la salida del error y pasa al siguiente host.
if ! "${SCP_CMD[@]}" "$LOCAL_SCRIPT" "${SSH_USER}@${host}:${remote_path}" >/tmp/remoto_scp_$$.log 2>&1; then
output="$(cat /tmp/remoto_scp_$$.log 2>/dev/null || true)"
rm -f /tmp/remoto_scp_$$.log
write_report "$host" "$safe_host" "SCP_ERROR" "1" "$output" "$report_file"
FAIL_COUNT=$((FAIL_COUNT + 1))
return
fi

rm -f /tmp/remoto_scp_$$.log

# Copia config.txt y mensajes.sh si existen, para que el script remoto pueda usarlos.
if [ -f "$local_messages_path" ]; then
if ! "${SCP_CMD[@]}" "$local_messages_path" "${SSH_USER}@${host}:${TARGET_DIR}/mensajes.sh" >/tmp/remoto_scp_$$.log 2>&1; then
output="$(cat /tmp/remoto_scp_$$.log 2>/dev/null || true)"
rm -f /tmp/remoto_scp_$$.log
write_report "$host" "$safe_host" "SCP_ERROR" "1" "$output" "$report_file"
FAIL_COUNT=$((FAIL_COUNT + 1))
return
fi
rm -f /tmp/remoto_scp_$$.log
fi
# Copia config.txt si existe, para que el script remoto pueda usarlo.
if [ -f "$local_config_path" ]; then
if ! "${SCP_CMD[@]}" "$local_config_path" "${SSH_USER}@${host}:${remote_config_path}" >/tmp/remoto_scp_$$.log 2>&1; then
output="$(cat /tmp/remoto_scp_$$.log 2>/dev/null || true)"
rm -f /tmp/remoto_scp_$$.log
write_report "$host" "$safe_host" "SCP_ERROR" "1" "$output" "$report_file"
FAIL_COUNT=$((FAIL_COUNT + 1))
return
fi
rm -f /tmp/remoto_scp_$$.log
fi

# Ejecuta el script remoto, captura su salida y limpia el archivo temporal al terminar.
set +e
output="$(${SSH_CMD[@]} "${SSH_USER}@${host}" "cd '$TARGET_DIR' && bash '$remote_path' 2>&1; rc=\$?; rm -f '$remote_path'; exit \$rc" 2>&1)"
rc=$?
set -e

if [ "$rc" -eq 0 ]; then
write_report "$host" "$safe_host" "OK" "$rc" "$output" "$report_file"
OK_COUNT=$((OK_COUNT + 1))
else
write_report "$host" "$safe_host" "SSH_ERROR" "$rc" "$output" "$report_file"
FAIL_COUNT=$((FAIL_COUNT + 1))
fi
}

# Valida que no falten parámetros y resuelve rutas relativas antes de ejecutar.
validate_inputs() {
if [ -z "$HOSTS_FILE" ]; then
mensaje_error "Error: falta archivo de hosts (-f)."
usage
exit 1
fi
if [ -z "$LOCAL_SCRIPT" ]; then
mensaje_error "Error: falta script local (-s)."
usage
exit 1
fi
if [ ! -f "$HOSTS_FILE" ]; then
mensaje_error "Error: no existe el archivo de hosts: $HOSTS_FILE"
exit 1
fi
if [ -z "$SSH_USER" ]; then
    mensaje_error "Error: falta usuario SSH (-u)."
    exit 1
fi
if [ -z "$REPORT_DIR" ]; then
mensaje_error "Error: falta directorio de reportes (-o)."
exit 1
fi

# Resolver posibles rutas relativas del script local: prioridad SCRIPT_DIR -> PWD
if [ ! -f "$LOCAL_SCRIPT" ]; then
if [ -f "$SCRIPT_DIR/$LOCAL_SCRIPT" ]; then
LOCAL_SCRIPT="$SCRIPT_DIR/$LOCAL_SCRIPT"
elif [ -f "$PWD/$LOCAL_SCRIPT" ]; then
LOCAL_SCRIPT="$PWD/$LOCAL_SCRIPT"
else
mensaje_error "Error: no existe el script local: $LOCAL_SCRIPT"
mensaje_advertencia "Asegurate de pasar la ruta correcta o usar una ruta absoluta."
exit 1
fi
fi

# Normaliza a ruta absoluta si es posible para evitar ambiguedades al copiar.
if command -v realpath >/dev/null 2>&1; then
LOCAL_SCRIPT="$(realpath "$LOCAL_SCRIPT")"
fi
if [ -n "$SSH_KEY" ] && [ ! -f "$SSH_KEY" ]; then
mensaje_error "Error: no existe la llave SSH: $SSH_KEY"
exit 1
fi
if ! [[ "$SSH_PORT" =~ ^[0-9]+$ ]]; then
mensaje_error "Error: puerto SSH invalido: $SSH_PORT"
exit 1
fi
if ! [[ "$CONNECT_TIMEOUT" =~ ^[0-9]+$ ]]; then
mensaje_error "Error: timeout invalido: $CONNECT_TIMEOUT"
exit 1
fi
}

# Flujo principal: leer argumentos, validar entradas, ejecutar por host y resumir resultados.
parse_args "$@"
validate_inputs

mkdir -p "$REPORT_DIR"
RUN_REPORT_DIR="$REPORT_DIR/ejecucion_$(date +%Y%m%d_%H%M%S)"
mkdir -p "$RUN_REPORT_DIR"

log_msg "Inicio remoto.sh | hosts=$HOSTS_FILE | script=$LOCAL_SCRIPT | output=$RUN_REPORT_DIR"

read_hosts "$HOSTS_FILE"
if [ "${#HOSTS[@]}" -eq 0 ]; then
mensaje_error "Error: no hay hosts validos en $HOSTS_FILE"
exit 1
fi

OK_COUNT=0
FAIL_COUNT=0

for host in "${HOSTS[@]}"; do
mensaje_info "Procesando host: $host"
copy_and_execute_host "$host"
done

SUMMARY_FILE="$RUN_REPORT_DIR/resumen.txt"
{
echo "TIMESTAMP=$(timestamp)"
echo "HOSTS_TOTALES=${#HOSTS[@]}"
echo "EXITOS=$OK_COUNT"
echo "FALLOS=$FAIL_COUNT"
echo "REPORTES_DIR=$RUN_REPORT_DIR"
} > "$SUMMARY_FILE"

msg="Remoto.sh finalizado: $OK_COUNT exitos, $FAIL_COUNT fallos. Detalles en $RUN_REPORT_DIR"
send_telegram "$msg"

log_msg "Fin remoto.sh | total=${#HOSTS[@]} | exitos=$OK_COUNT | fallos=$FAIL_COUNT"

echo ""
mensaje_info "Resumen de ejecucion"
echo "  Total hosts : ${#HOSTS[@]}"
echo "  Exitos      : $OK_COUNT"
echo "  Fallos      : $FAIL_COUNT"
echo "  Reportes    : $RUN_REPORT_DIR"

if [ "$FAIL_COUNT" -gt 0 ]; then
exit 1
fi
exit 0