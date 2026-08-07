# ============================================================================
# Stage 1: Builder - Clone ComfyUI and install all Python packages
# ============================================================================
FROM ubuntu:22.04 AS builder

ARG CUDA_APT_PACKAGE=cuda-minimal-build-12-4
ARG TORCH_INDEX_URL=https://download.pytorch.org/whl/cu124

ENV DEBIAN_FRONTEND=noninteractive

COPY scripts /opt/comfyui-base/scripts
COPY manifests /opt/comfyui-base/manifests

# Install system dependencies (Python 3.12, CUDA toolchain, pip)
RUN /opt/comfyui-base/scripts/install-build-deps.sh "$CUDA_APT_PACKAGE"

# Set CUDA environment for building
ENV PATH=/usr/local/cuda/bin:${PATH}
ENV LD_LIBRARY_PATH=/usr/local/cuda/lib64

# Clone ComfyUI to get requirements
WORKDIR /tmp/build
RUN git clone https://github.com/comfyanonymous/ComfyUI.git

# Install PyTorch and all ComfyUI dependencies
RUN python3.12 -m pip install --no-cache-dir \
    torch torchvision torchaudio --index-url "$TORCH_INDEX_URL"

WORKDIR /tmp/build/ComfyUI
RUN python3.12 -m pip install --no-cache-dir -r requirements.txt && \
    python3.12 -m pip install --no-cache-dir GitPython opencv-python

# Clone custom nodes and install their requirements
RUN REQUIREMENTS_ONLY=1 IGNORE_ERRORS=1 /opt/comfyui-base/scripts/install-custom-nodes.sh \
    /tmp/build/ComfyUI/custom_nodes /opt/comfyui-base/manifests/custom-nodes-base.txt

# ============================================================================
# Stage 2: Runtime - Clean image with pre-installed packages
# ============================================================================
FROM ubuntu:22.04 AS runtime

ARG CUDA_APT_PACKAGE=cuda-minimal-build-12-4

ENV DEBIAN_FRONTEND=noninteractive
ENV PYTHONUNBUFFERED=1
ENV IMAGEIO_FFMPEG_EXE=/usr/bin/ffmpeg
ENV FILEBROWSER_CONFIG=/workspace/runpod-slim/.filebrowser.json

COPY scripts /opt/comfyui-base/scripts
COPY manifests /opt/comfyui-base/manifests

# Install runtime dependencies, CUDA, common tools, FileBrowser and SSH config
RUN /opt/comfyui-base/scripts/install-runtime-deps.sh "$CUDA_APT_PACKAGE"

# Copy Python packages and pip executables from builder stage
COPY --from=builder /usr/local/lib/python3.12 /usr/local/lib/python3.12
COPY --from=builder /usr/local/bin /usr/local/bin

# Remove uv to force ComfyUI-Manager to use pip (uv doesn't respect --system-site-packages properly)
RUN pip uninstall -y uv 2>/dev/null || true && \
    rm -f /usr/local/bin/uv /usr/local/bin/uvx

# Set CUDA environment variables
ENV PATH=/usr/local/cuda/bin:${PATH}
ENV LD_LIBRARY_PATH=/usr/local/cuda/lib64

# Install Jupyter with Python kernel
RUN pip install jupyter

# Create workspace directory
RUN mkdir -p /workspace/runpod-slim
WORKDIR /workspace/runpod-slim

# Expose ports
EXPOSE 8188 22 8888 8080

# Copy and set up start script
COPY start.sh /start.sh
RUN chmod +x /start.sh

ENTRYPOINT ["/start.sh"]

# ============================================================================
# Stage 3: RTX 5090 - Runtime plus a baked-in Z-Image-Turbo workflow
# ============================================================================
FROM runtime AS rtx5090

# The CUDA 12.8 build gets its own venv so it never reuses the cu124 one
ENV COMFYUI_VENV_DIR=/workspace/runpod-slim/ComfyUI/.venv-cu128

# Clone ComfyUI fresh
RUN git clone https://github.com/comfyanonymous/ComfyUI.git /workspace/runpod-slim/ComfyUI && \
    cd /workspace/runpod-slim/ComfyUI && \
    python3.12 -m pip install --no-cache-dir -r requirements.txt

# Custom nodes and models for the Z-Image-Turbo workflow
RUN REQUIREMENTS_ONLY=1 IGNORE_ERRORS=1 /opt/comfyui-base/scripts/install-custom-nodes.sh \
    /workspace/runpod-slim/ComfyUI/custom_nodes /opt/comfyui-base/manifests/custom-nodes-5090.txt

RUN /opt/comfyui-base/scripts/download-files.sh \
    /workspace/runpod-slim/ComfyUI /opt/comfyui-base/manifests/models-5090.txt

WORKDIR /workspace/runpod-slim/ComfyUI
