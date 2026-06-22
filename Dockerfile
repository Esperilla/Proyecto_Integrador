FROM debian:12-slim

# Evitar prompts interactivos durante la instalación
ENV DEBIAN_FRONTEND=noninteractive

# Instalar las herramientas requeridas por los scripts del proyecto
RUN apt-get update && apt-get install -y \
    systemd \
    systemd-sysv \
    cron \
    curl \
    iputils-ping \
    bc \
    netcat-openbsd \
    nmap \
    openssh-client \
    openssh-server \
    procps \
    sudo \
    nano \
    iproute2 \
    tar \
    && rm -rf /var/lib/apt/lists/*

# Limpiar unidades de systemd innecesarias que causan problemas en contenedores
RUN rm -f /lib/systemd/system/multi-user.target.wants/* \
    /etc/systemd/system/*.wants/* \
    /lib/systemd/system/local-fs.target.wants/* \
    /lib/systemd/system/sockets.target.wants/*udev* \
    /lib/systemd/system/sockets.target.wants/*initctl* \
    /lib/systemd/system/sysinit.target.wants/systemd-tmpfiles-setup* \
    /lib/systemd/system/systemd-update-utmp*

# Habilitar los servicios ssh y cron para pruebas con servicios.sh
RUN systemctl enable ssh && systemctl enable cron

# Crear el usuario no-root "supervisor" para pruebas
RUN useradd -m -s /bin/bash supervisor && \
    echo "supervisor:password" | chpasswd && \
    adduser supervisor sudo

# Permitir a supervisor usar sudo sin contraseña
RUN echo "supervisor ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/supervisor

# Crear directorios de prueba para los scripts del proyecto
RUN mkdir -p /home/supervisor/dir_Prueba1 && touch /home/supervisor/dir_Prueba1/archivo1.txt
RUN mkdir -p /home/supervisor/dir_Prueba2 && touch /home/supervisor/dir_Prueba2/archivo2.txt

# Crear el directorio de logs
RUN mkdir -p /var/log && touch /var/log/gestion_automatizada.log && \
    chown supervisor:supervisor /var/log && chown supervisor:supervisor /var/log/gestion_automatizada.log


# Configurar el directorio de trabajo donde se montarán los scripts
WORKDIR /workspace

# Comando para mantener el contenedor interactivo
CMD ["/sbin/init"]