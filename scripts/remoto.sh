#!/bin/bash
set -euo pipefail

###############################################################################
# remoto.sh
# Copia un script local a hosts remotos por SCP, lo ejecuta por SSH y genera
# reportes individuales por host con resultado y timestamp.
###############################################################################

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="$SCRIPT_DIR/../config.txt"

if [ ! -f "$CONFIG_FILE" ]; then
	CONFIG_FILE="$PWD/config.txt"
fi

timestamp() {
	date --iso-8601=seconds
}

LOG_FILE_DEFAULT="$SCRIPT_DIR/../logs/gestion_automatizada.log"
LOG_FILE="$LOG_FILE_DEFAULT"

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