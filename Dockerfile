FROM debian:12-slim

# Evitar prompts interactivos durante la instalación
ENV DEBIAN_FRONTEND=noninteractive

# Instalar las herramientas requeridas por los scripts del proyecto
RUN apt-get update && apt-get install -y \
    cron \
    curl \
    iputils-ping \
    netcat-openbsd \
    nmap \
    openssh-client \
    openssh-server \
    procps \
    sudo \
    tar \
    && rm -rf /var/lib/apt/lists/*

# Crear el usuario no-root "supervisor" para pruebas (Requerimiento del proyecto)
RUN useradd -m -s /bin/bash supervisor && \
    echo "supervisor:password" | chpasswd && \
    adduser supervisor sudo

# Configurar el directorio de trabajo donde se montarán los scripts
WORKDIR /workspace

# Comando por defecto para mantener el contenedor interactivo
CMD ["/bin/bash"]