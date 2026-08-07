#!/bin/bash
set -e  # Exit the script if any statement returns a non-true return value

# Paths can be overridden from the environment; the defaults are the ones used
# inside the container image.
COMFYUI_DIR="${COMFYUI_DIR:-/workspace/runpod-slim/ComfyUI}"
VENV_DIR="${VENV_DIR:-$COMFYUI_DIR/.venv-cu128}"
FILEBROWSER_CONFIG="${FILEBROWSER_CONFIG:-/root/.config/filebrowser/config.json}"
DB_FILE="${DB_FILE:-/workspace/runpod-slim/filebrowser.db}"
ARGS_FILE="${ARGS_FILE:-/workspace/runpod-slim/comfyui_args.txt}"
COMFYUI_LOG="${COMFYUI_LOG:-/workspace/runpod-slim/comfyui.log}"
FILEBROWSER_LOG="${FILEBROWSER_LOG:-/filebrowser.log}"
JUPYTER_LOG="${JUPYTER_LOG:-/jupyter.log}"
WORKSPACE_DIR="${WORKSPACE_DIR:-/workspace}"
COMFYUI_ROOT="${COMFYUI_ROOT:-/workspace/runpod-slim}"

SSH_HOST_KEY_DIR="${SSH_HOST_KEY_DIR:-/etc/ssh}"
SSHD_CONFIG="${SSHD_CONFIG:-/etc/ssh/sshd_config}"
SSHD_BIN="${SSHD_BIN:-/usr/sbin/sshd}"
ENV_FILE="${ENV_FILE:-/etc/environment}"
PAM_ENV_FILE="${PAM_ENV_FILE:-/etc/security/pam_env.conf}"
RP_ENV_FILE="${RP_ENV_FILE:-/etc/rp_environment}"
SYSTEM_BASHRC="${SYSTEM_BASHRC:-/etc/bash.bashrc}"

COMFYUI_REPO="${COMFYUI_REPO:-https://github.com/comfyanonymous/ComfyUI.git}"
COMFYUI_MANAGER_REPO="${COMFYUI_MANAGER_REPO:-https://github.com/ltdrdata/ComfyUI-Manager.git}"

CUSTOM_NODES=(
    "https://github.com/kijai/ComfyUI-KJNodes"
    "https://github.com/MoonGoblinDev/Civicomfy"
    "https://github.com/MadiatorLabs/ComfyUI-RunpodDirect"
)

# ---------------------------------------------------------------------------- #
#                          Function Definitions                                  #
# ---------------------------------------------------------------------------- #

# Setup SSH with optional key or random password
setup_ssh() {
    mkdir -p ~/.ssh

    # Generate host keys if they don't exist
    for type in rsa dsa ecdsa ed25519; do
        if [ ! -f "${SSH_HOST_KEY_DIR}/ssh_host_${type}_key" ]; then
            ssh-keygen -t "${type}" -f "${SSH_HOST_KEY_DIR}/ssh_host_${type}_key" -q -N ''
            echo "${type^^} key fingerprint:"
            ssh-keygen -lf "${SSH_HOST_KEY_DIR}/ssh_host_${type}_key.pub"
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
    echo "PermitUserEnvironment yes" >> "$SSHD_CONFIG"

    # Start SSH service
    "$SSHD_BIN"
}

# Export environment variables
export_env_vars() {
    echo "Exporting environment variables..."

    local ssh_env_file="$HOME/.ssh/environment"

    # Backup original files
    cp "$ENV_FILE" "${ENV_FILE}.bak" 2>/dev/null || true
    cp "$PAM_ENV_FILE" "${PAM_ENV_FILE}.bak" 2>/dev/null || true

    # Clear files
    : > "$ENV_FILE"
    : > "$PAM_ENV_FILE"
    mkdir -p "$HOME/.ssh"
    : > "$ssh_env_file"

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
        echo "$name=\"$value\"" >> "$ssh_env_file"

        # Add to current shell
        echo "export $name=\"$value\"" >> "$RP_ENV_FILE"
    done

    # Add sourcing to shell startup files
    echo "source $RP_ENV_FILE" >> ~/.bashrc
    echo "source $RP_ENV_FILE" >> "$SYSTEM_BASHRC"

    # Set permissions
    chmod 644 "$ENV_FILE" "$PAM_ENV_FILE"
    chmod 600 "$ssh_env_file"
}

# Start Jupyter Lab server for remote access
start_jupyter() {
    mkdir -p "$WORKSPACE_DIR"
    echo "Starting Jupyter Lab on port 8888..."
    nohup jupyter lab \
        --allow-root \
        --no-browser \
        --port=8888 \
        --ip=0.0.0.0 \
        --FileContentsManager.delete_to_trash=False \
        --FileContentsManager.preferred_dir="$WORKSPACE_DIR" \
        --ServerApp.root_dir="$WORKSPACE_DIR" \
        --ServerApp.terminado_settings='{"shell_command":["/bin/bash"]}' \
        --IdentityProvider.token="${JUPYTER_PASSWORD:-}" \
        --ServerApp.allow_origin=* &> "$JUPYTER_LOG" &
    echo "Jupyter Lab started"
}

# Create the FileBrowser database and default admin user on first run
init_filebrowser() {
    if [ ! -f "$DB_FILE" ]; then
        echo "Initializing FileBrowser..."
        filebrowser config init
        filebrowser config set --address 0.0.0.0
        filebrowser config set --port 8080
        filebrowser config set --root "$WORKSPACE_DIR"
        filebrowser config set --auth.method=json
        filebrowser users add admin adminadmin12 --perm.admin
    else
        echo "Using existing FileBrowser configuration..."
    fi
}

start_filebrowser() {
    echo "Starting FileBrowser on port 8080..."
    nohup filebrowser &> "$FILEBROWSER_LOG" &
}

# Create default comfyui_args.txt if it doesn't exist
ensure_args_file() {
    if [ ! -f "$ARGS_FILE" ]; then
        echo "# Add your custom ComfyUI arguments here (one per line)" > "$ARGS_FILE"
        echo "Created empty ComfyUI arguments file at $ARGS_FILE"
    fi
}

clone_comfyui() {
    if [ ! -d "$COMFYUI_DIR" ]; then
        cd "$COMFYUI_ROOT"
        git clone "$COMFYUI_REPO"
    fi
}

# Clone ComfyUI-Manager and the pre-selected custom nodes when missing
install_custom_nodes() {
    if [ ! -d "$COMFYUI_DIR/custom_nodes/ComfyUI-Manager" ]; then
        echo "Installing ComfyUI-Manager..."
        mkdir -p "$COMFYUI_DIR/custom_nodes"
        cd "$COMFYUI_DIR/custom_nodes"
        git clone "$COMFYUI_MANAGER_REPO"
    fi

    local repo repo_name
    for repo in "${CUSTOM_NODES[@]}"; do
        repo_name=$(basename "$repo")
        if [ ! -d "$COMFYUI_DIR/custom_nodes/$repo_name" ]; then
            echo "Installing $repo_name..."
            cd "$COMFYUI_DIR/custom_nodes"
            git clone "$repo"
        fi
    done
}

# Install requirements.txt / install.py / setup.py for every custom node.
# $1 is the installer command prefix, e.g. "pip install --no-cache-dir".
install_custom_node_deps() {
    local installer="$1"
    local nodes_dir="$COMFYUI_DIR/custom_nodes"
    local node_dir

    cd "$nodes_dir"
    for node_dir in */; do
        # Resolve against $nodes_dir: the loop body changes the working directory.
        [ -d "$nodes_dir/$node_dir" ] || continue

        echo "Checking dependencies for $node_dir..."
        cd "$nodes_dir/$node_dir"

        # Check for requirements.txt
        if [ -f "requirements.txt" ]; then
            echo "Installing requirements.txt for $node_dir"
            $installer -r requirements.txt
        fi

        # Check for install.py
        if [ -f "install.py" ]; then
            echo "Running install.py for $node_dir"
            python install.py
        fi

        # Check for setup.py
        if [ -f "setup.py" ]; then
            echo "Running setup.py for $node_dir"
            $installer -e .
        fi
    done
}

setup_venv() {
    cd "$COMFYUI_DIR"
    # Create venv with access to system packages (torch cu128, numpy, etc. pre-installed in image)
    python3.12 -m venv --system-site-packages "$VENV_DIR"
    # shellcheck disable=SC1091
    source "$VENV_DIR/bin/activate"

    # Ensure pip is available in the venv (needed for ComfyUI-Manager)
    python -m ensurepip --upgrade
    python -m pip install --upgrade pip

    echo "Base packages (torch cu128, numpy, etc.) available from system site-packages"
    echo "Installing custom node dependencies..."

    install_custom_node_deps "pip install --no-cache-dir"
}

setup_comfyui() {
    if [ ! -d "$COMFYUI_DIR" ] || [ ! -d "$VENV_DIR" ]; then
        echo "First time setup: Installing ComfyUI and dependencies..."

        clone_comfyui
        install_custom_nodes

        if [ ! -d "$VENV_DIR" ]; then
            setup_venv
        fi
    else
        # Just activate the existing venv
        # shellcheck disable=SC1091
        source "$VENV_DIR/bin/activate"

        echo "Checking for custom node dependencies..."

        install_custom_node_deps "uv pip install --no-cache"
    fi
}

# Print the full ComfyUI argument list: the fixed args plus any user supplied
# ones from $1 (comment lines starting with '#' are ignored).
build_comfyui_args() {
    local args_file="$1"
    local fixed_args="--listen 0.0.0.0 --port 8188"
    local custom_args=""

    if [ -s "$args_file" ]; then
        custom_args=$(grep -v '^#' "$args_file" | tr '\n' ' ' | sed -e 's/[[:space:]]\{1,\}/ /g' -e 's/^ //' -e 's/ $//')
    fi

    if [ -n "$custom_args" ]; then
        echo "$fixed_args $custom_args"
    else
        echo "$fixed_args"
    fi
}

start_comfyui() {
    cd "$COMFYUI_DIR"
    local args
    args=$(build_comfyui_args "$ARGS_FILE")
    echo "Starting ComfyUI with arguments: $args"
    # shellcheck disable=SC2086
    nohup python main.py $args &> "$COMFYUI_LOG" &
}

# ---------------------------------------------------------------------------- #
#                               Main Program                                     #
# ---------------------------------------------------------------------------- #

main() {
    setup_ssh
    export_env_vars

    init_filebrowser
    start_filebrowser
    start_jupyter

    ensure_args_file
    setup_comfyui
    start_comfyui

    # Tail the log file
    tail -f "$COMFYUI_LOG"
}

if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    main "$@"
fi
