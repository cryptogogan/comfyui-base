#!/bin/bash
# Runtime stage system dependencies. Usage: install-runtime-deps.sh <cuda-apt-package>
set -e

CUDA_PACKAGE="${1:?cuda apt package required}"

source "$(dirname "$0")/lib/apt.sh"

apt-get update
apt-get upgrade -y
add_ppa ppa:deadsnakes/ppa ppa:cybermax-dexter/ffmpeg-nvenc
apt_install \
    git \
    "${PYTHON_APT_PACKAGES[@]}" \
    wget \
    gnupg \
    xz-utils \
    openssh-client \
    openssh-server \
    nano \
    curl \
    htop \
    tmux \
    ca-certificates \
    less \
    net-tools \
    iputils-ping \
    procps \
    golang \
    make
install_cuda "$CUDA_PACKAGE"
apt_install ffmpeg
apt_cleanup

# Install FileBrowser
curl -fsSL https://raw.githubusercontent.com/filebrowser/get/master/get.sh | bash

# Configure SSH for root login
sed -i 's/#PermitRootLogin prohibit-password/PermitRootLogin yes/' /etc/ssh/sshd_config
sed -i 's/#PasswordAuthentication yes/PasswordAuthentication yes/' /etc/ssh/sshd_config
mkdir -p /run/sshd

# Set Python 3.12 as default
update-alternatives --install /usr/bin/python3 python3 /usr/bin/python3.12 1
update-alternatives --set python3 /usr/bin/python3.12
