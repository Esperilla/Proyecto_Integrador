#!/bin/bash
#==================================#
# SCRIPT PARA MENSAJES DEL SISTEMA #
#==================================#
ROJO='\033[0;31m'      
VERDE='\033[0;32m'
AMARILLO='\033[1;33m'
AZUL='\033[0;34m'
NC='\033[0m'

mensaje_exito() {
    echo -e "${VERDE}✓ $1${NC}"
}

mensaje_info() {
    echo -e "${AZUL}ℹ $1${NC}"
}

salida_error() {
    echo -e "${ROJO}ERROR: $1${NC}" >&2
    exit 1
}

mensaje_advertencia() {
    echo -e "${AMARILLO}⚠ $1${NC}"
}