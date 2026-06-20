#!/bin/bash
set -euo pipefail
source "${0%/*}"/mensajes.sh
###############################################################################
# usuarios.sh
# Script para crear, eliminar y modificar usuarios del sistema.
# Lee configuración desde config.txt, valida entradas, registra acciones y
# notifica a un bot de Telegram por cada acción.
# Requiere privilegios de root para modificar usuarios.
###############################################################################

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="$SCRIPT_DIR/../config.txt"
LOG_FILE="${LOG_FILE:-/var/log/gestion_automatizada.log}"
CURL_BIN="${CURL_BIN:-curl}"

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

# Verifica existencia del usuario consultando su UID.
user_exists() {
  local user="$1"
  if id -u "$user" >/dev/null 2>&1; then
    return 0
  else
    return 1
  fi
}

# Valida formato de nombre de usuario con una regex segura.
validate_username() {
  local user="$1"
  if [[ "$user" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]]; then
    return 0
  else
    return 1
  fi
}

# Crea un usuario con home, shell bash y contraseña inicial.
create_user() {
  read -rp "Nombre de usuario a crear: " username
  if ! validate_username "$username"; then
    mensaje_advertencia "Nombre de usuario inválido. Solo minúsculas, números, guiones bajos/medios."
    return 1
  fi
  if user_exists "$username"; then
    mensaje_advertencia "El usuario '$username' ya existe."
    return 1
  fi
  read -rp "Nombre completo (GECOS) (opcional): " fullname
  read -rsp "Contraseña inicial: " password
  echo
  if [ -z "$password" ]; then
    mensaje_error "Contraseña vacía. Abortando."; return 1
  fi
  useradd -m -c "$fullname" -s /bin/bash "$username"
  echo "$username:$password" | chpasswd
  if [ $? -eq 0 ]; then
    local msg="Usuario creado: $username"
    mensaje_exito "$msg"
    log_msg "$msg"
    send_telegram "[Usuarios.sh] $msg"
    return 0
  else
    mensaje_error "Error al crear el usuario."; return 1
  fi
}

# Elimina un usuario y su home tras confirmación explícita.
delete_user() {
  read -rp "Nombre de usuario a eliminar: " username
  if ! user_exists "$username"; then
    mensaje_advertencia "El usuario '$username' no existe."
    return 1
  fi
  read -rp "CONFIRME eliminación de $username (escriba 'si'): " confirm
  if [ "$confirm" != "si" ]; then
    mensaje_advertencia "Eliminación cancelada."
    return 1
  fi
  userdel -r "$username" >/dev/null 2>&1 || true
  local msg="Usuario eliminado: $username"
  mensaje_exito "$msg"
  log_msg "$msg"
  send_telegram "[Usuarios.sh] $msg"
}

# Modifica datos del usuario: shell, GECOS, contraseña y membresía en grupos.
modify_user() {
  read -rp "Nombre de usuario a modificar: " username
  if ! user_exists "$username"; then
    mensaje_advertencia "El usuario '$username' no existe."
    return 1
  fi
  echo "Opciones de modificación para $username:"
  echo "  1) Cambiar shell"
  echo "  2) Cambiar nombre completo (GECOS)"
  echo "  3) Cambiar contraseña"
  echo "  4) Añadir a grupos"
  echo "  5) Quitar de grupos"
  echo "  6) Volver"
  read -rp "Elija opción: " opt
  case "$opt" in
    1)
      read -rp "Nuevo shell (ej. /bin/bash): " newshell
      usermod -s "$newshell" "$username"
      msg="Shell cambiado para $username a $newshell"
      ;;
    2)
      read -rp "Nuevo nombre completo (GECOS): " newgecos
      usermod -c "$newgecos" "$username"
      msg="GECOS cambiado para $username a '$newgecos'"
      ;;
    3)
      read -rsp "Nueva contraseña: " newpass; echo
      if [ -z "$newpass" ]; then mensaje_error "Contraseña vacía. Abortando."; return 1; fi
      echo "$username:$newpass" | chpasswd
      msg="Contraseña cambiada para $username"
      ;;
    4)
      read -rp "Grupos a añadir (coma-separados): " addgr
      usermod -a -G "$addgr" "$username"
      msg="Añadido $username a grupos: $addgr"
      ;;
    5)
      read -rp "Grupos a quitar (coma-separados): " delgr
      # Reconstruye la lista de grupos manteniendo solo los que no se quieren quitar.
      current_groups=$(id -nG "$username" | tr ' ' ',')
      # Construye la nueva lista excluyendo los grupos indicados.
      IFS=',' read -ra keep <<<"$current_groups"
      IFS=',' read -ra rem <<<"$delgr"
      newlist=""
      for g in "${keep[@]}"; do
        skip=0
        for r in "${rem[@]}"; do
          if [ "$g" = "$r" ]; then skip=1; break; fi
        done
        if [ $skip -eq 0 ]; then
          if [ -z "$newlist" ]; then newlist="$g"; else newlist+=",$g"; fi
        fi
      done
      usermod -G "$newlist" "$username"
      msg="Actualizados grupos de $username -> $newlist"
      ;;
    6)
      return 0
      ;;
    *) echo "Opción inválida"; return 1;;
  esac
  mensaje_info "$msg"
  log_msg "$msg"
  send_telegram "[Usuarios.sh] $msg"
}

# Muestra todos los logins registrados en /etc/passwd.
list_users() {
  mensaje_info "Usuarios del sistema (login):"
  cut -d: -f1 /etc/passwd
}

# Permite salida limpia con Ctrl+C o señales de terminación.
trap 'echo; echo "Saliendo..."; exit 0' SIGINT SIGTERM

# Menú principal con verificación de privilegios root y bucle interactivo.
main_menu() {
  if [ "$EUID" -ne 0 ]; then
    mensaje_info "Este script debe ejecutarse como root. Use sudo."; exit 1
  fi
  while true; do
    echo
    echo "--- Gestión de usuarios ---"
    echo "1) Crear usuario"
    echo "2) Eliminar usuario"
    echo "3) Modificar usuario"
    echo "4) Listar usuarios"
    echo "5) Salir"
    read -rp "Elija una opción: " opt
    case "$opt" in
      1) create_user ;;
      2) delete_user ;;
      3) modify_user ;;
      4) list_users ;;
      5) mensaje_info "Adiós."; exit 0 ;;
      *) mensaje_advertencia "Opción inválida." ;;
    esac
  done
}

main_menu
