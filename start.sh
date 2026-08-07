#!/bin/bash
set -e  # Exit the script if any statement returns a non-true return value

COMFYUI_DIR="/workspace/runpod-slim/ComfyUI"
# Image variants may pin a dedicated venv (e.g. .venv-cu128 for the CUDA 12.8 image)
VENV_DIR="${COMFYUI_VENV_DIR:-$COMFYUI_DIR/.venv}"
FILEBROWSER_CONFIG="/root/.config/filebrowser/config.json"
DB_FILE="/workspace/runpod-slim/filebrowser.db"
SCRIPTS_DIR="${SCRIPTS_DIR:-/opt/comfyui-base/scripts}"
MANIFESTS_DIR="${MANIFESTS_DIR:-/opt/comfyui-base/manifests}"

source "$SCRIPTS_DIR/lib/custom-nodes.sh"

# ---------------------------------------------------------------------------- #
#                          Function Definitions                                  #
# ---------------------------------------------------------------------------- #

# Setup SSH with optional key or random password
setup_ssh() {
    mkdir -p ~/.ssh
    
    # Generate host keys if they don't exist
    for type in rsa dsa ecdsa ed25519; do
        if [ ! -f "/etc/ssh/ssh_host_${type}_key" ]; then
            ssh-keygen -t ${type} -f "/etc/ssh/ssh_host_${type}_key" -q -N ''
            echo "${type^^} key fingerprint:"
            ssh-keygen -lf "/etc/ssh/ssh_host_${type}_key.pub"
        fi
    done

    # If PUBLIC_KEY is provided, use it
    if [[ $PUBLIC_KEY ]]; then
        echo "$PUBLIC_KEY" >> ~/.ssh/authorized_keys
        chmod 700 -R ~/.ssh
    else
        # Generate random password if no public key
        RANDOM_PASS=$(openssl rand -base64 12)
        echo "root:${RANDOM_PASS}" | chpasswd
        echo "Generated random SSH password for root: ${RANDOM_PASS}"
    fi

    # Configure SSH to preserve environment variables
    echo "PermitUserEnvironment yes" >> /etc/ssh/sshd_config

    # Start SSH service
    /usr/sbin/sshd
}

# Export environment variables
export_env_vars() {
    echo "Exporting environment variables..."
    
    # Create environment files
    ENV_FILE="/etc/environment"
    PAM_ENV_FILE="/etc/security/pam_env.conf"
    SSH_ENV_DIR="/root/.ssh/environment"
    
    # Backup original files
    cp "$ENV_FILE" "${ENV_FILE}.bak" 2>/dev/null || true
    cp "$PAM_ENV_FILE" "${PAM_ENV_FILE}.bak" 2>/dev/null || true
    
    # Clear files
    > "$ENV_FILE"
    > "$PAM_ENV_FILE"
    mkdir -p /root/.ssh
    > "$SSH_ENV_DIR"
    
    # Export to multiple locations for maximum compatibility
    printenv | grep -E '^RUNPOD_|^PATH=|^_=|^CUDA|^LD_LIBRARY_PATH|^PYTHONPATH' | while read -r line; do
        # Get variable name and value
        name=$(echo "$line" | cut -d= -f1)
        value=$(echo "$line" | cut -d= -f2-)
        
        # Add to /etc/environment (system-wide)
        echo "$name=\"$value\"" >> "$ENV_FILE"
        
        # Add to PAM environment
        echo "$name DEFAULT=\"$value\"" >> "$PAM_ENV_FILE"
        
        # Add to SSH environment file
        echo "$name=\"$value\"" >> "$SSH_ENV_DIR"
        
        # Add to current shell
        echo "export $name=\"$value\"" >> /etc/rp_environment
    done
    
    # Add sourcing to shell startup files
    echo 'source /etc/rp_environment' >> ~/.bashrc
    echo 'source /etc/rp_environment' >> /etc/bash.bashrc
    
    # Set permissions
    chmod 644 "$ENV_FILE" "$PAM_ENV_FILE"
    chmod 600 "$SSH_ENV_DIR"
}

# Start Jupyter Lab server for remote access
start_jupyter() {
    mkdir -p /workspace
    echo "Starting Jupyter Lab on port 8888..."
    nohup jupyter lab \
        --allow-root \
        --no-browser \
        --port=8888 \
        --ip=0.0.0.0 \
        --FileContentsManager.delete_to_trash=False \
        --FileContentsManager.preferred_dir=/workspace \
        --ServerApp.root_dir=/workspace \
        --ServerApp.terminado_settings='{"shell_command":["/bin/bash"]}' \
        --IdentityProvider.token="${JUPYTER_PASSWORD:-}" \
        --ServerApp.allow_origin=* &> /jupyter.log &
    echo "Jupyter Lab started"
}

setup_filebrowser() {
    if [ ! -f "$DB_FILE" ]; then
        echo "Initializing FileBrowser..."
        filebrowser config init
        filebrowser config set --address 0.0.0.0
        filebrowser config set --port 8080
        filebrowser config set --root /workspace
        filebrowser config set --auth.method=json
        filebrowser users add admin adminadmin12 --perm.admin
    else
        echo "Using existing FileBrowser configuration..."
    fi

    echo "Starting FileBrowser on port 8080..."
    nohup filebrowser &> /filebrowser.log &
}

start_comfyui() {
    cd "$COMFYUI_DIR"
    local fixed_args="--listen 0.0.0.0 --port 8188"
    local custom_args=""
    if [ -s "$ARGS_FILE" ]; then
        custom_args=$(grep -v '^#' "$ARGS_FILE" | tr '\n' ' ')
    fi

    if [ -n "${custom_args// }" ]; then
        echo "Starting ComfyUI with additional arguments: $custom_args"
    else
        echo "Starting ComfyUI with default arguments"
    fi
    nohup python main.py $fixed_args $custom_args &> /workspace/runpod-slim/comfyui.log &
}

# ---------------------------------------------------------------------------- #
#                               Main Program                                     #
# ---------------------------------------------------------------------------- #

# Setup environment
setup_ssh
export_env_vars
setup_filebrowser
start_jupyter

# Create default comfyui_args.txt if it doesn't exist
ARGS_FILE="/workspace/runpod-slim/comfyui_args.txt"
if [ ! -f "$ARGS_FILE" ]; then
    echo "# Add your custom ComfyUI arguments here (one per line)" > "$ARGS_FILE"
    echo "Created empty ComfyUI arguments file at $ARGS_FILE"
fi

# Setup ComfyUI if needed
if [ ! -d "$COMFYUI_DIR" ] || [ ! -d "$VENV_DIR" ]; then
    echo "First time setup: Installing ComfyUI and dependencies..."

    if [ ! -d "$COMFYUI_DIR" ]; then
        cd /workspace/runpod-slim
        git clone https://github.com/comfyanonymous/ComfyUI.git
    fi

    clone_custom_nodes "$COMFYUI_DIR/custom_nodes" \
        "$MANIFESTS_DIR/custom-nodes-base.txt" \
        "$MANIFESTS_DIR/custom-nodes-runtime.txt"

    if [ ! -d "$VENV_DIR" ]; then
        # Create venv with access to system packages (torch, numpy, etc. pre-installed in image)
        python3.12 -m venv --system-site-packages "$VENV_DIR"
        source "$VENV_DIR/bin/activate"

        # Ensure pip is available in the venv (needed for ComfyUI-Manager)
        python -m ensurepip --upgrade
        python -m pip install --upgrade pip

        echo "Base packages (torch, numpy, etc.) available from system site-packages"
    fi
else
    source "$VENV_DIR/bin/activate"
fi

echo "Checking for custom node dependencies..."
PYTHON_CMD=python
PIP_INSTALL="pip install --no-cache-dir"
install_custom_node_deps "$COMFYUI_DIR/custom_nodes"

start_comfyui

# Tail the log file
tail -f /workspace/runpod-slim/comfyui.log
