#!/bin/bash
# Builder stage system dependencies. Usage: install-build-deps.sh <cuda-apt-package>
set -e

CUDA_PACKAGE="${1:?cuda apt package required}"

source "$(dirname "$0")/lib/apt.sh"

apt-get update
apt_install git wget curl ca-certificates
add_ppa ppa:deadsnakes/ppa
apt_install "${PYTHON_APT_PACKAGES[@]}"
install_cuda "$CUDA_PACKAGE"
apt_cleanup

# Bootstrap pip for Python 3.12
curl -sS https://bootstrap.pypa.io/get-pip.py -o get-pip.py
python3.12 get-pip.py
python3.12 -m pip install --upgrade pip
rm get-pip.py
