# Proyecto Integrador - Programación en la Administración de Servicios

Este proyecto integrador contiene herramientas y scripts automatizados para la administración de servicios en un entorno Linux (Debian), incluyendo gestión de usuarios, respaldos, monitoreo de recursos, revisión de servicios, registro centralizado de logs (bitácora) y notificaciones en tiempo real a través de un bot de Telegram.

---

## 🚀 Arquitectura y Entorno de Pruebas

Para asegurar la portabilidad y facilitar el desarrollo, el proyecto incluye un entorno de laboratorio basado en Docker:

- **`Dockerfile`**: Basado en `debian:12-slim`. Instala `systemd`, herramientas de red (`curl`, `iputils-ping`, `netcat-openbsd`, `nmap`, `openssh`, `iproute2`), administración (`cron`, `procps`, `sudo`, `nano`, `tar`) y limpia unidades de systemd innecesarias para contenedores. Habilita los servicios `ssh` y `cron` por defecto. Crea un usuario de pruebas no privilegiado `supervisor` (contraseña: `password`) con permisos de `sudo` sin contraseña, directorios de prueba (`dir_Prueba1`, `dir_Prueba2`) y el archivo de bitácora preconfigurado.
- **`docker-compose.yml`**: Define el servicio `debian-lab` que levanta el contenedor en modo **privilegiado** con `systemd` como proceso init (`/sbin/init`), monta el directorio del proyecto en `/workspace` y el cgroup del host en `/sys/fs/cgroup`.

### Cómo levantar el laboratorio

1. Construir e iniciar el contenedor:
   ```bash
   docker compose up -d --build
   ```
2. Entrar al contenedor interactivo:
   ```bash
   docker compose exec debian-lab bash
   ```

---

## ⚙️ Configuración Global (`config.txt`)

El archivo de configuración principal unifica las variables utilizadas por todos los scripts. Contiene:

- **Configuración de Telegram**: `TELEGRAM_BOT_TOKEN` y `TELEGRAM_CHAT_ID` para enviar alertas y reportes de ejecución de manera automática.
- **Configuración de Logs**: Ruta del archivo bitácora central (`LOG_FILE`, por defecto `/var/log/gestion_automatizada.log`).
- **Configuración de Respaldos**: Directorios de origen (`BACKUP_SOURCE_DIRS`), directorio destino (`BACKUP_DEST_DIR`), prefijo de archivos (`BACKUP_PREFIX`) y la programación de cron (`CRON_SCHEDULE`).
- **Configuración de Servicios**: Lista de servicios a monitorear (`SERVICES`, por defecto `ssh cron`).

---

## 📂 Scripts

Los scripts se encuentran dentro del directorio `scripts/`:

### 1. Script de Usuarios (`scripts/usuarios.sh`)

Diseñado para la administración interactiva de usuarios del sistema. Debe ejecutarse con privilegios de superusuario (`sudo`).

- **Características**:
  - **Validaciones de Seguridad**: Validación estricta del formato del nombre de usuario mediante expresiones regulares (letras minúsculas, números, guiones y longitud máxima de 32 caracteres) y comprobación de existencia previa en el sistema.
  - **Confirmaciones**: Petición de confirmación interactiva para evitar la eliminación accidental de cuentas.
  - **Auditoría e Integración**: Registra cada operación en el archivo de bitácora global y envía notificaciones automáticas al bot de Telegram.
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
  4. **Listar usuarios**: Muestra todos los usuarios registrados en el sistema.
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

### 3. Script de Monitoreo (`scripts/monitoreo.sh`)

Monitorea el uso de CPU y disco del sistema, registra las lecturas en la bitácora y envía alertas por Telegram cuando se superan los umbrales configurados.

- **Características**:
  - Lectura de uso de CPU mediante muestreo de `/proc/stat` (cálculo de porcentaje real de ocupación).
  - Lectura de uso de disco con `df` para una o múltiples particiones.
  - Umbrales configurables por argumentos (por defecto 70% para CPU y disco).
  - Modo de ejecución única (`--once`, por defecto) o modo continuo con intervalo configurable (`--interval`).
  - Manejo de señales (`SIGINT`, `SIGTERM`) para salida limpia.
- **Argumentos de línea de comandos**:
  - `--cpu N`: Umbral de alerta para CPU (%).
  - `--disk N`: Umbral de alerta para disco (%).
  - `--paths P1,P2`: Rutas de particiones a comprobar (separadas por comas, por defecto `/`).
  - `--interval S`: Intervalo en segundos para lecturas periódicas (activa modo continuo).
  - `--once`: Ejecutar una sola lectura y salir (comportamiento por defecto).
- **Ejemplo de uso**:
  ```bash
  # Lectura única con umbrales personalizados
  ./monitoreo.sh --cpu 80 --disk 90

  # Monitoreo continuo cada 30 segundos
  ./monitoreo.sh --cpu 75 --disk 85 --interval 30
  ```

### 4. Script de Servicios (`scripts/servicios.sh`)

Revisa el estado de los servicios definidos en `config.txt` (variable `SERVICES`), intenta reiniciar los que estén inactivos y notifica los resultados por Telegram.

- **Características**:
  - Lee la lista de servicios desde `config.txt` mediante parsing directo (compatible con entornos sin `source`).
  - Verifica la existencia de cada servicio en `systemd` antes de consultar su estado.
  - Si un servicio está inactivo, intenta reiniciarlo automáticamente con `systemctl restart` (usa `sudo` si no es root).
  - Verifica el estado posterior al reinicio y reporta éxito o fallo.
  - Registra cada paso en la bitácora y notifica por Telegram.
- **Modo de uso**:
  ```bash
  # Ejecutar revisión de servicios
  sudo ./servicios.sh

  # Mostrar ayuda
  ./servicios.sh -h
  ```

---

## 📝 Nota sobre permisos del archivo de log

El Dockerfile ya crea el archivo de log y asigna la propiedad al usuario `supervisor`. Si por alguna razón necesitas recrearlo manualmente:

```bash
sudo touch /var/log/gestion_automatizada.log
sudo chown supervisor:supervisor /var/log/gestion_automatizada.log
```
