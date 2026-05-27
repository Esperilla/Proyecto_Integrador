# Proyecto Integrador - Programación en la Administración de Servicios

Este proyecto integrador contiene herramientas y scripts automatizados para la administración de servicios en un entorno Linux (Debian), incluyendo gestión de respaldos, gestión de usuarios, registro de logs (bitácora) y notificaciones en tiempo real a través de un bot de Telegram.

---

## 🚀 Arquitectura y Entorno de Pruebas

Para asegurar la portabilidad y facilitar el desarrollo, el proyecto incluye un entorno de laboratorio basado en Docker:

- **`Dockerfile`**: Basado en `debian:12-slim`. Instala las dependencias necesarias (`cron`, `curl`, `iputils-ping`, `netcat-openbsd`, `nmap`, `openssh`, `sudo`, `tar`) y crea un usuario de pruebas no privilegiado llamado `supervisor` (contraseña: `password`) con permisos de `sudo`.
- **`docker-compose.yml`**: Define el servicio `debian-lab` que levanta el contenedor con la terminal interactiva abierta (`tty`, `stdin_open`) y monta el directorio del proyecto en `/workspace`.

### Cómo levantar el laboratorio

1. Iniciar el contenedor:
   ```bash
   docker compose up -d
   ```
2. Entrar al contenedor interactivo:
   ```bash
   docker compose exec debian-lab bash
   ```

---

## ⚙️ Configuración Global (`config.txt`)

El archivo de configuración principal unifica las variables utilizadas por todos los scripts. Contiene:

- **Configuración de Telegram**: `TELEGRAM_BOT_TOKEN` y `TELEGRAM_CHAT_ID` para enviar alertas y reportes de ejecución de manera automática.
- **Configuración de Logs**: Ruta del archivo bitácora central (`/var/log/gestion_automatizada.log`).
- **Configuración de Respaldos**: Directorios de origen (`BACKUP_SOURCE_DIRS`), directorio destino (`BACKUP_DEST_DIR`), prefijo de archivos (`BACKUP_PREFIX`) y la programación de cron (`CRON_SCHEDULE`).

---

## 📂 Scripts

Los scripts se encuentran dentro del directorio `scripts/`:

### 1. Script de Usuarios (`scripts/usuarios.sh`)
Diseñado para la administración interactiva de usuarios del sistema. Debe ejecutarse con privilegios de superusuario (`sudo`).

- **Características**:
  - **Validaciones de Seguridad**: Validación estricta del formato del nombre de usuario mediante expresiones regulares (letras minúsculas, números, guiones y longitud máxima de 32 caracteres) y comprobación de existencia previa en el sistema.
  - **Confirmaciones**: Petición de confirmación interactiva para evitar la eliminación accidental de cuentas.
  - **Auditoría e Integración**: Registra cada operación (éxito o fallo) en el archivo de bitácora global (`/var/log/gestion_automatizada.log`) y envía notificaciones automáticas al bot de Telegram.
- **Menú Interactivo**:
  Al ejecutar el script con `sudo ./usuarios.sh`, se muestra un menú en la terminal:
  1. **Crear usuario**: Crea un usuario nuevo con su directorio home, comentarios (nombre completo) y contraseña inicial.
  2. **Eliminar usuario**: Borra un usuario del sistema de forma segura junto con su directorio home (`userdel -r`) tras una confirmación.
  3. **Modificar usuario**: Despliega un submenú para aplicar cambios específicos a una cuenta existente:
     - Cambiar la shell asignada.
     - Actualizar la información completa (GECOS).
     - Modificar la contraseña.
     - Añadir al usuario a grupos secundarios.
     - Quitar al usuario de grupos secundarios específicos (reconstruyendo la lista de grupos actual de manera segura).
  4. **Listar usuarios**: Muestra una lista formateada en columnas con todos los usuarios registrados en el sistema.
  5. **Salir**: Finaliza el script.

### 2. Script de Respaldos (`scripts/respaldo.sh`)

Automatiza la compresión de directorios con `tar`, valida los resultados, registra las bitácoras y notifica mediante Telegram.

- **Características**:
  - Verificación automática de existencia de los directorios de origen.
  - Generación de bitácora detallada con marcas de tiempo en formato ISO-8601.
  - Notificación de tamaño del respaldo y fecha al canal de Telegram configurado.
  - Instalación automática y transparente del script en el `crontab` del usuario actual (sin requerir permisos de `root`).
- **Modo de uso**:
  - **Menú Interactivo**: Al ejecutar `./respaldo.sh` sin argumentos, se despliega un menú interactivo en consola:
    1. Ejecutar respaldo ahora
    2. Programar respaldo con cron
    3. Mostrar configuración
    4. Salir
  - **Argumentos de línea de comandos**:
    - `--backup-now`: Ejecuta el respaldo inmediatamente.
    - `--install-cron`: Configura e instala la tarea en el crontab actual del usuario.
    - `--show-config`: Muestra los parámetros de configuración vigentes cargados desde `config.txt`.
