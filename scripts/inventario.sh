#!/bin/bash
set -euo pipefail

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