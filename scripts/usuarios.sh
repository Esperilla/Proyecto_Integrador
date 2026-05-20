#!/bin/bash
set -euo pipefail

###############################################################################
# usuarios.sh
# Script para crear, eliminar y modificar usuarios del sistema.
# Lee configuración desde config.txt, valida entradas, registra acciones y
# notifica a un bot de Telegram por cada acción.
# Uso: ejecutar como root (sudo).
###############################################################################

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="$SCRIPT_DIR/../config.txt"
if [ ! -f "$CONFIG_FILE" ]; then
  # fallback a pwd
  CONFIG_FILE="$PWD/config.txt"
fi

if [ ! -f "$CONFIG_FILE" ]; then
  echo "No se encontró config.txt. Copia config.txt.example o crea $CONFIG_FILE"
  exit 1
fi
