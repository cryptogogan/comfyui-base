#!/usr/bin/env bash
set -Eeuo pipefail

COMFYUI_DIR="/workspace/runpod-slim/ComfyUI"
VENV_DIR="$COMFYUI_DIR/.venv"
FILEBROWSER_CONFIG="/root/.config/filebrowser/config.json"
DB_FILE="/workspace/runpod-slim/filebrowser.db"
COMFYUI_LOG="/workspace/runpod-slim/comfyui.log"
JUPYTER_LOG="/jupyter.log"
FILEBROWSER_LOG="/filebrowser.log"

# Non-fatal problems collected during startup and reported before ComfyUI starts
DEGRADED=()

# ---------------------------------------------------------------------------- #
#                          Function Definitions                                  #
# ---------------------------------------------------------------------------- #

log() { printf '[start] %s\n' "$*"; }
warn() { printf '[start][WARN] %s\n' "$*" >&2; }
err() { printf '[start][ERROR] %s\n' "$*" >&2; }

# Record a non-fatal failure so it is visible in the startup summary
degrade() {
    DEGRADED+=("$1")
    warn "$1"
}

on_error() {
    local exit_code=$1 line=$2 command=$3
    err "startup aborted: '${command}' failed with exit code ${exit_code} (${BASH_SOURCE[0]}:${line})"
    exit "$exit_code"
}
trap 'on_error "$?" "$LINENO" "$BASH_COMMAND"' ERR

# Print the tail of a log file so failures are diagnosable from container logs
dump_log() {
    local file=$1
    if [ -f "$file" ]; then
        err "last 50 lines of ${file}:"
        tail -n 50 "$file" >&2 || true
    else
        err "no log file at ${file}"
    fi
}

# Verify a backgrounded service is still alive shortly after launch
service_is_up() {
    local pid=$1 name=$2 logfile=$3
    sleep 2
    if kill -0 "$pid" 2>/dev/null; then
        return 0
    fi
    err "${name} exited immediately after launch"
    dump_log "$logfile"
    return 1
}

# Install python packages. pip is preferred because uv does not respect
# --system-site-packages; uv is only used when pip is unavailable.
pip_install() {
    if command -v pip >/dev/null 2>&1; then
        pip install --no-cache-dir "$@"
    elif command -v uv >/dev/null 2>&1; then
        uv pip install --no-cache "$@"
    else
        err "neither pip nor uv is available"
        return 1
    fi
}

# Setup SSH with optional key or random password
setup_ssh() {
    mkdir -p ~/.ssh

    # Generate host keys if they don't exist. Some key types (e.g. dsa) are not
    # supported by newer OpenSSH builds, so a single failure must not abort startup.
    local type
    for type in rsa dsa ecdsa ed25519; do
        if [ ! -f "/etc/ssh/ssh_host_${type}_key" ]; then
            if ssh-keygen -t "${type}" -f "/etc/ssh/ssh_host_${type}_key" -q -N ''; then
                echo "${type^^} key fingerprint:"
                ssh-keygen -lf "/etc/ssh/ssh_host_${type}_key.pub" || true
            else
                warn "could not generate ${type} host key (unsupported key type?)"
            fi
        fi
    done

    if ! compgen -G "/etc/ssh/ssh_host_*_key" >/dev/null; then
        degrade "no SSH host keys available; SSH will not be started"
        return 0
    fi

    # If PUBLIC_KEY is provided, use it
    if [[ -n "${PUBLIC_KEY:-}" ]]; then
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
    if ! /usr/sbin/sshd; then
        degrade "sshd failed to start; SSH access on port 22 is unavailable"
    fi
}

# Export environment variables
export_env_vars() {
    log "Exporting environment variables..."

    # Create environment files
    ENV_FILE="/etc/environment"
    PAM_ENV_FILE="/etc/security/pam_env.conf"
    SSH_ENV_DIR="/root/.ssh/environment"

    # Backup original files
    cp "$ENV_FILE" "${ENV_FILE}.bak" 2>/dev/null || warn "could not back up ${ENV_FILE}"
    cp "$PAM_ENV_FILE" "${PAM_ENV_FILE}.bak" 2>/dev/null || warn "could not back up ${PAM_ENV_FILE}"

    # Clear files
    > "$ENV_FILE"
    > "$PAM_ENV_FILE"
    mkdir -p /root/.ssh
    > "$SSH_ENV_DIR"

    # grep exits 1 when nothing matches, which is not an error here
    local env_lines
    env_lines=$(printenv | grep -E '^RUNPOD_|^PATH=|^_=|^CUDA|^LD_LIBRARY_PATH|^PYTHONPATH' || true)
    if [ -z "$env_lines" ]; then
        warn "no environment variables matched the export filter"
    fi

    # Export to multiple locations for maximum compatibility
    local line name value
    while IFS= read -r line; do
        [ -n "$line" ] || continue
        name=${line%%=*}
        value=${line#*=}

        # Add to /etc/environment (system-wide)
        echo "$name=\"$value\"" >> "$ENV_FILE"

        # Add to PAM environment
        echo "$name DEFAULT=\"$value\"" >> "$PAM_ENV_FILE"

        # Add to SSH environment file
        echo "$name=\"$value\"" >> "$SSH_ENV_DIR"

        # Add to current shell
        echo "export $name=\"$value\"" >> /etc/rp_environment
    done <<< "$env_lines"

    # Add sourcing to shell startup files
    echo 'source /etc/rp_environment' >> ~/.bashrc
    echo 'source /etc/rp_environment' >> /etc/bash.bashrc

    # Set permissions
    chmod 644 "$ENV_FILE" "$PAM_ENV_FILE"
    chmod 600 "$SSH_ENV_DIR"
}

# Initialize FileBrowser, removing a partial database so init is retried next boot
setup_filebrowser() {
    if [ -f "$DB_FILE" ]; then
        log "Using existing FileBrowser configuration..."
        return 0
    fi

    log "Initializing FileBrowser..."
    if filebrowser config init &&
        filebrowser config set --address 0.0.0.0 &&
        filebrowser config set --port 8080 &&
        filebrowser config set --root /workspace &&
        filebrowser config set --auth.method=json &&
        filebrowser users add admin adminadmin12 --perm.admin; then
        return 0
    fi

    rm -f "$DB_FILE"
    degrade "FileBrowser initialization failed; database removed so it is retried on next start"
    return 1
}

start_filebrowser() {
    log "Starting FileBrowser on port 8080..."
    nohup filebrowser &> "$FILEBROWSER_LOG" &
    local pid=$!
    if ! service_is_up "$pid" "FileBrowser" "$FILEBROWSER_LOG"; then
        degrade "FileBrowser is not running; port 8080 is unavailable"
    fi
}

# Start Jupyter Lab server for remote access
start_jupyter() {
    mkdir -p /workspace
    log "Starting Jupyter Lab on port 8888..."
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
        --ServerApp.allow_origin=* &> "$JUPYTER_LOG" &
    local pid=$!
    if service_is_up "$pid" "Jupyter Lab" "$JUPYTER_LOG"; then
        log "Jupyter Lab started"
    else
        degrade "Jupyter Lab is not running; port 8888 is unavailable"
    fi
}

# Install dependencies of every custom node. A broken node must not prevent
# ComfyUI from starting, but every failure is reported.
install_custom_node_deps() {
    log "Checking for custom node dependencies..."
    local node_dir name
    for node_dir in "$COMFYUI_DIR"/custom_nodes/*/; do
        [ -d "$node_dir" ] || continue
        name=$(basename "$node_dir")
        log "Checking dependencies for $name..."
        cd "$node_dir"

        if [ -f "requirements.txt" ]; then
            log "Installing requirements.txt for $name"
            pip_install -r requirements.txt || degrade "requirements.txt install failed for custom node $name"
        fi

        if [ -f "install.py" ]; then
            log "Running install.py for $name"
            python install.py || degrade "install.py failed for custom node $name"
        fi

        if [ -f "setup.py" ]; then
            log "Running setup.py for $name"
            pip_install -e . || degrade "setup.py install failed for custom node $name"
        fi
    done
}

report_degraded() {
    if [ "${#DEGRADED[@]}" -eq 0 ]; then
        return 0
    fi
    err "startup completed with ${#DEGRADED[@]} problem(s):"
    local item
    for item in "${DEGRADED[@]}"; do
        err "  - $item"
    done
}

# ---------------------------------------------------------------------------- #
#                               Main Program                                     #
# ---------------------------------------------------------------------------- #

# Setup environment
setup_ssh
export_env_vars

setup_filebrowser || true
start_filebrowser
start_jupyter

# Create default comfyui_args.txt if it doesn't exist
ARGS_FILE="/workspace/runpod-slim/comfyui_args.txt"
mkdir -p "$(dirname "$ARGS_FILE")"
if [ ! -f "$ARGS_FILE" ]; then
    echo "# Add your custom ComfyUI arguments here (one per line)" > "$ARGS_FILE"
    log "Created empty ComfyUI arguments file at $ARGS_FILE"
fi

# Setup ComfyUI if needed
if [ ! -d "$COMFYUI_DIR" ] || [ ! -d "$VENV_DIR" ]; then
    log "First time setup: Installing ComfyUI and dependencies..."

    # Clone ComfyUI if not present
    if [ ! -d "$COMFYUI_DIR" ]; then
        cd /workspace/runpod-slim
        git clone https://github.com/comfyanonymous/ComfyUI.git
    fi

    # Install ComfyUI-Manager if not present
    if [ ! -d "$COMFYUI_DIR/custom_nodes/ComfyUI-Manager" ]; then
        log "Installing ComfyUI-Manager..."
        mkdir -p "$COMFYUI_DIR/custom_nodes"
        cd "$COMFYUI_DIR/custom_nodes"
        git clone https://github.com/ltdrdata/ComfyUI-Manager.git
    fi

    # Install additional custom nodes
    CUSTOM_NODES=(
        "https://github.com/kijai/ComfyUI-KJNodes"
        "https://github.com/MoonGoblinDev/Civicomfy"
        "https://github.com/MadiatorLabs/ComfyUI-RunpodDirect"
    )

    for repo in "${CUSTOM_NODES[@]}"; do
        repo_name=$(basename "$repo")
        if [ ! -d "$COMFYUI_DIR/custom_nodes/$repo_name" ]; then
            log "Installing $repo_name..."
            cd "$COMFYUI_DIR/custom_nodes"
            # An unreachable optional node repo must not block startup
            git clone "$repo" || degrade "could not clone custom node $repo_name"
        fi
    done

    # Create and setup virtual environment if not present
    if [ ! -d "$VENV_DIR" ]; then
        cd "$COMFYUI_DIR"
        # Create venv with access to system packages (torch, numpy, etc. pre-installed in image)
        python3.12 -m venv --system-site-packages "$VENV_DIR"
        # shellcheck disable=SC1091
        source "$VENV_DIR/bin/activate"

        # Ensure pip is available in the venv (needed for ComfyUI-Manager)
        python -m ensurepip --upgrade
        python -m pip install --upgrade pip

        log "Base packages (torch, numpy, etc.) available from system site-packages"
        install_custom_node_deps
    fi
else
    # Just activate the existing venv
    # shellcheck disable=SC1091
    source "$VENV_DIR/bin/activate"
    install_custom_node_deps
fi

report_degraded

# Start ComfyUI with custom arguments if provided
cd "$COMFYUI_DIR"
FIXED_ARGS=(--listen 0.0.0.0 --port 8188)
CUSTOM_ARGS=()
if [ -s "$ARGS_FILE" ]; then
    # grep exits 1 when the file only contains comments
    while IFS= read -r line; do
        read -ra words <<< "$line"
        [ "${#words[@]}" -gt 0 ] && CUSTOM_ARGS+=("${words[@]}")
    done < <(grep -v '^#' "$ARGS_FILE" || true)
fi

if [ "${#CUSTOM_ARGS[@]}" -gt 0 ]; then
    log "Starting ComfyUI with additional arguments: ${CUSTOM_ARGS[*]}"
else
    log "Starting ComfyUI with default arguments"
fi

nohup python main.py "${FIXED_ARGS[@]}" "${CUSTOM_ARGS[@]}" &> "$COMFYUI_LOG" &
COMFYUI_PID=$!

if ! service_is_up "$COMFYUI_PID" "ComfyUI" "$COMFYUI_LOG"; then
    err "ComfyUI failed to start"
    exit 1
fi

# Tail the log file in the background so the container's stdout stays live
tail -n +1 -f "$COMFYUI_LOG" &
TAIL_PID=$!

shutdown() {
    local signal=$1
    log "Received SIG${signal}, stopping ComfyUI..."
    kill -"$signal" "$COMFYUI_PID" 2>/dev/null || true
}
trap 'shutdown TERM' TERM
trap 'shutdown INT' INT

# Propagate ComfyUI's exit status instead of keeping the container alive on a
# dead process
trap - ERR
set +e
wait "$COMFYUI_PID"
COMFYUI_STATUS=$?

kill "$TAIL_PID" 2>/dev/null || true

if [ "$COMFYUI_STATUS" -eq 0 ]; then
    log "ComfyUI exited cleanly"
elif [ "$COMFYUI_STATUS" -gt 128 ]; then
    log "ComfyUI terminated by signal $((COMFYUI_STATUS - 128))"
else
    err "ComfyUI exited with status ${COMFYUI_STATUS}"
    dump_log "$COMFYUI_LOG"
fi

exit "$COMFYUI_STATUS"
