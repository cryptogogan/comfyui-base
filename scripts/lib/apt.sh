#!/bin/bash
# Shared apt/CUDA helpers used by the image build scripts.

export DEBIAN_FRONTEND=noninteractive

PYTHON_APT_PACKAGES=(
    python3.12
    python3.12-venv
    python3.12-dev
    build-essential
)

apt_install() {
    apt-get install -y --no-install-recommends "$@"
}

add_ppa() {
    apt_install software-properties-common gpg-agent
    for ppa in "$@"; do
        add-apt-repository "$ppa"
    done
    apt-get update
}

# Install a CUDA apt package (e.g. cuda-minimal-build-12-4) from NVIDIA's repo.
install_cuda() {
    local cuda_package="$1"
    local keyring=cuda-keyring_1.1-1_all.deb
    wget "https://developer.download.nvidia.com/compute/cuda/repos/ubuntu2204/x86_64/${keyring}"
    dpkg -i "$keyring"
    apt-get update
    apt_install "$cuda_package"
    rm "$keyring"
}

apt_cleanup() {
    apt-get clean
    rm -rf /var/lib/apt/lists/*
}
