#!/bin/bash
set -euo pipefail

###############################################################################
# remoto.sh
# Copia un script local a hosts remotos por SCP, lo ejecuta por SSH y genera
# reportes individuales por host con resultado y timestamp.
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

load_config_value() {
	local key="$1"
	local file="$2"
	if [ ! -f "$file" ]; then
		return 1
	fi
	grep -E "^[[:space:]]*${key}=" "$file" \
		| tail -n 1 \
		| sed -E 's/^[^=]*=[[:space:]]*//; s/^"//; s/"$//' \
		| tr -d '\r'
}

load_config() {
	local value

	value="$(load_config_value "LOG_FILE" "$CONFIG_FILE" 2>/dev/null || true)"
	if [ -n "$value" ]; then LOG_FILE="$value"; fi

	value="$(load_config_value "REMOTE_HOSTS_FILE" "$CONFIG_FILE" 2>/dev/null || true)"
	if [ -n "$value" ]; then HOSTS_FILE="$value"; fi

	value="$(load_config_value "REMOTE_SCRIPT_LOCAL" "$CONFIG_FILE" 2>/dev/null || true)"
	if [ -n "$value" ]; then LOCAL_SCRIPT="$value"; fi

	value="$(load_config_value "REMOTE_USER" "$CONFIG_FILE" 2>/dev/null || true)"
	if [ -n "$value" ]; then REMOTE_USER="$value"; fi

	value="$(load_config_value "REMOTE_SSH_PORT" "$CONFIG_FILE" 2>/dev/null || true)"
	if [ -n "$value" ]; then SSH_PORT="$value"; fi

	value="$(load_config_value "REMOTE_SSH_KEY" "$CONFIG_FILE" 2>/dev/null || true)"
	if [ -n "$value" ]; then SSH_KEY="$value"; fi

	value="$(load_config_value "REMOTE_TARGET_DIR" "$CONFIG_FILE" 2>/dev/null || true)"
	if [ -n "$value" ]; then REMOTE_TARGET_DIR="$value"; fi

	value="$(load_config_value "REMOTE_REPORT_DIR" "$CONFIG_FILE" 2>/dev/null || true)"
	if [ -n "$value" ]; then REPORT_BASE_DIR="$value"; fi

	value="$(load_config_value "REMOTE_CONNECT_TIMEOUT" "$CONFIG_FILE" 2>/dev/null || true)"
	if [ -n "$value" ]; then CONNECT_TIMEOUT="$value"; fi
}

usage() {
	cat <<EOF
Uso: $(basename "$0") -f HOSTS_FILE -s LOCAL_SCRIPT [opciones]

Opciones:
	-f, --hosts FILE         Archivo de hosts/IPs (uno por linea)
	-s, --script FILE        Script local a copiar y ejecutar remotamente
	-u, --user USER          Usuario SSH remoto (default: $USER)
	-p, --port PORT          Puerto SSH (default: 22)
	-i, --identity FILE      Llave privada SSH
	-d, --remote-dir DIR     Directorio remoto temporal (default: /tmp)
	-o, --output-dir DIR     Directorio base de reportes
	-t, --timeout SEG        Timeout de conexion en segundos (default: 8)
	-h, --help               Mostrar esta ayuda

Tambien puedes definir valores en config.txt:
	REMOTE_HOSTS_FILE, REMOTE_SCRIPT_LOCAL, REMOTE_USER, REMOTE_SSH_PORT,
	REMOTE_SSH_KEY, REMOTE_TARGET_DIR, REMOTE_REPORT_DIR, REMOTE_CONNECT_TIMEOUT.
EOF
}

require_command() {
	local cmd="$1"
	if ! command -v "$cmd" >/dev/null 2>&1; then
		echo "Error: se requiere '$cmd' y no esta instalado."
		exit 1
	fi
}

sanitize_host() {
	echo "$1" | sed 's/[^A-Za-z0-9_.-]/_/g'
}

is_valid_host() {
	local host="$1"
	[[ "$host" =~ ^[A-Za-z0-9._-]+$ ]]
}

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
				REMOTE_USER="${2:-}"
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
				REMOTE_TARGET_DIR="${2:-}"
				shift 2
				;;
			-o|--output-dir)
				REPORT_BASE_DIR="${2:-}"
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
				echo "Opcion invalida: $1"
				usage
				exit 1
				;;
		esac
	done
}

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
		echo "USUARIO_REMOTO=$REMOTE_USER"
		echo "PUERTO_SSH=$SSH_PORT"
		echo ""
		echo "--- SALIDA REMOTA ---"
		echo "$output"
	} > "$report_file"

	log_msg "Reporte generado para $host ($status): $report_file"
	echo "[$safe_host] $status -> $report_file"
}

copy_and_execute_host() {
	local host="$1"
	local safe_host
	local report_file
	local remote_name
	local remote_path
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
	remote_path="$REMOTE_TARGET_DIR/${remote_name%.*}_$$_$(date +%s).sh"

	SCP_CMD=(scp -P "$SSH_PORT" -o BatchMode=yes -o ConnectTimeout="$CONNECT_TIMEOUT")
	SSH_CMD=(ssh -p "$SSH_PORT" -o BatchMode=yes -o ConnectTimeout="$CONNECT_TIMEOUT")

	if [ -n "$SSH_KEY" ]; then
		SCP_CMD+=( -i "$SSH_KEY" )
		SSH_CMD+=( -i "$SSH_KEY" )
	fi

	if ! "${SCP_CMD[@]}" "$LOCAL_SCRIPT" "${REMOTE_USER}@${host}:${remote_path}" >/tmp/remoto_scp_$$.log 2>&1; then
		output="$(cat /tmp/remoto_scp_$$.log 2>/dev/null || true)"
		rm -f /tmp/remoto_scp_$$.log
		write_report "$host" "$safe_host" "SCP_ERROR" "1" "$output" "$report_file"
		FAIL_COUNT=$((FAIL_COUNT + 1))
		return
	fi

	rm -f /tmp/remoto_scp_$$.log

	output="$(${SSH_CMD[@]} "${REMOTE_USER}@${host}" "bash '$remote_path' 2>&1; rc=\$?; rm -f '$remote_path'; exit \$rc" 2>&1)"
	rc=$?

	if [ "$rc" -eq 0 ]; then
		write_report "$host" "$safe_host" "OK" "$rc" "$output" "$report_file"
		OK_COUNT=$((OK_COUNT + 1))
	else
		write_report "$host" "$safe_host" "SSH_ERROR" "$rc" "$output" "$report_file"
		FAIL_COUNT=$((FAIL_COUNT + 1))
	fi
}

validate_inputs() {
	if [ -z "$HOSTS_FILE" ]; then
		echo "Error: falta archivo de hosts (-f)."
		usage
		exit 1
	fi
	if [ -z "$LOCAL_SCRIPT" ]; then
		echo "Error: falta script local (-s)."
		usage
		exit 1
	fi
	if [ ! -f "$HOSTS_FILE" ]; then
		echo "Error: no existe el archivo de hosts: $HOSTS_FILE"
		exit 1
	fi

	if [ ! -f "$LOCAL_SCRIPT" ]; then
		if [ -f "$SCRIPT_DIR/$LOCAL_SCRIPT" ]; then
			LOCAL_SCRIPT="$SCRIPT_DIR/$LOCAL_SCRIPT"
		elif [ -f "$PWD/$LOCAL_SCRIPT" ]; then
			LOCAL_SCRIPT="$PWD/$LOCAL_SCRIPT"
		else
			echo "Error: no existe el script local: $LOCAL_SCRIPT" >&2
			echo "Asegurate de pasar la ruta correcta o usar una ruta absoluta." >&2
			exit 1
		fi
	fi

	if command -v realpath >/dev/null 2>&1; then
		LOCAL_SCRIPT="$(realpath "$LOCAL_SCRIPT")"
	fi
	if [ -n "$SSH_KEY" ] && [ ! -f "$SSH_KEY" ]; then
		echo "Error: no existe la llave SSH: $SSH_KEY"
		exit 1
	fi
	if ! [[ "$SSH_PORT" =~ ^[0-9]+$ ]]; then
		echo "Error: puerto SSH invalido: $SSH_PORT"
		exit 1
	fi
	if ! [[ "$CONNECT_TIMEOUT" =~ ^[0-9]+$ ]]; then
		echo "Error: timeout invalido: $CONNECT_TIMEOUT"
		exit 1
	fi
}

HOSTS_FILE=""
LOCAL_SCRIPT=""
REMOTE_USER="$USER"
SSH_PORT="22"
SSH_KEY=""
REMOTE_TARGET_DIR="/tmp"
REPORT_BASE_DIR="$SCRIPT_DIR/../reportes/remoto"
CONNECT_TIMEOUT="8"

if [ -f "$CONFIG_FILE" ]; then
	load_config
fi

parse_args "$@"
validate_inputs

mkdir -p "$REPORT_BASE_DIR"
RUN_REPORT_DIR="$REPORT_BASE_DIR/ejecucion_$(date +%Y%m%d_%H%M%S)"
mkdir -p "$RUN_REPORT_DIR"

log_msg "Inicio remoto.sh | hosts=$HOSTS_FILE | script=$LOCAL_SCRIPT | output=$RUN_REPORT_DIR"

read_hosts "$HOSTS_FILE"
if [ "${#HOSTS[@]}" -eq 0 ]; then
	echo "Error: no hay hosts validos en $HOSTS_FILE"
	exit 1
fi

OK_COUNT=0
FAIL_COUNT=0

for host in "${HOSTS[@]}"; do
	echo "Procesando host: $host"
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

log_msg "Fin remoto.sh | total=${#HOSTS[@]} | exitos=$OK_COUNT | fallos=$FAIL_COUNT"

echo ""
echo "Resumen de ejecucion"
echo "  Total hosts : ${#HOSTS[@]}"
echo "  Exitos      : $OK_COUNT"
echo "  Fallos      : $FAIL_COUNT"
echo "  Reportes    : $RUN_REPORT_DIR"

if [ "$FAIL_COUNT" -gt 0 ]; then
	exit 1
fi
exit 0
