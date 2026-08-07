#!/usr/bin/env bats

load helpers/mocks

setup() {
    setup_sandbox
    source_start_script start.sh
}

teardown() {
    teardown_sandbox
}

# --------------------------------------------------------------------------- #
# build_comfyui_args
# --------------------------------------------------------------------------- #

@test "build_comfyui_args: missing file yields only the fixed args" {
    run build_comfyui_args "$TEST_TMP/does-not-exist.txt"
    [ "$status" -eq 0 ]
    [ "$output" = "--listen 0.0.0.0 --port 8188" ]
}

@test "build_comfyui_args: empty file yields only the fixed args" {
    : > "$ARGS_FILE"
    run build_comfyui_args "$ARGS_FILE"
    [ "$status" -eq 0 ]
    [ "$output" = "--listen 0.0.0.0 --port 8188" ]
}

@test "build_comfyui_args: comment-only file yields only the fixed args" {
    printf '# a comment\n# another one\n' > "$ARGS_FILE"
    run build_comfyui_args "$ARGS_FILE"
    [ "$status" -eq 0 ]
    [ "$output" = "--listen 0.0.0.0 --port 8188" ]
}

@test "build_comfyui_args: blank lines are not treated as arguments" {
    printf '\n\n' > "$ARGS_FILE"
    run build_comfyui_args "$ARGS_FILE"
    [ "$status" -eq 0 ]
    [ "$output" = "--listen 0.0.0.0 --port 8188" ]
}

@test "build_comfyui_args: custom args are appended after the fixed args" {
    printf -- '--max-batch-size 8\n--preview-method auto\n' > "$ARGS_FILE"
    run build_comfyui_args "$ARGS_FILE"
    [ "$status" -eq 0 ]
    [ "$output" = "--listen 0.0.0.0 --port 8188 --max-batch-size 8 --preview-method auto" ]
}

@test "build_comfyui_args: comments are stripped from a file with real args" {
    printf '# header\n--lowvram\n' > "$ARGS_FILE"
    run build_comfyui_args "$ARGS_FILE"
    [ "$status" -eq 0 ]
    [ "$output" = "--listen 0.0.0.0 --port 8188 --lowvram" ]
}

# --------------------------------------------------------------------------- #
# start_comfyui
# --------------------------------------------------------------------------- #

@test "start_comfyui: launches main.py with the fixed args and logs to comfyui.log" {
    mkdir -p "$COMFYUI_DIR"
    : > "$ARGS_FILE"
    start_comfyui
    wait || true
    run cat "$COMFYUI_LOG"
    [ "$status" -eq 0 ]
    assert_called "python main.py --listen 0.0.0.0 --port 8188"
}

@test "start_comfyui: passes custom args through to main.py" {
    mkdir -p "$COMFYUI_DIR"
    printf -- '--lowvram\n' > "$ARGS_FILE"
    start_comfyui
    wait || true
    assert_called "python main.py --listen 0.0.0.0 --port 8188 --lowvram"
}

# --------------------------------------------------------------------------- #
# ensure_args_file
# --------------------------------------------------------------------------- #

@test "ensure_args_file: creates a commented placeholder when absent" {
    [ ! -f "$ARGS_FILE" ]
    ensure_args_file
    [ -f "$ARGS_FILE" ]
    run cat "$ARGS_FILE"
    [ "$output" = "# Add your custom ComfyUI arguments here (one per line)" ]
}

@test "ensure_args_file: leaves an existing file untouched" {
    printf -- '--lowvram\n' > "$ARGS_FILE"
    ensure_args_file
    run cat "$ARGS_FILE"
    [ "$output" = "--lowvram" ]
}

# --------------------------------------------------------------------------- #
# init_filebrowser / start_filebrowser
# --------------------------------------------------------------------------- #

@test "init_filebrowser: configures address, port, root, auth and admin user on first run" {
    init_filebrowser
    assert_called "filebrowser config init"
    assert_called "filebrowser config set --address 0.0.0.0"
    assert_called "filebrowser config set --port 8080"
    assert_called "filebrowser config set --root $WORKSPACE_DIR"
    assert_called "filebrowser config set --auth.method=json"
    assert_called "filebrowser users add admin adminadmin12 --perm.admin"
}

@test "init_filebrowser: skips configuration when the database already exists" {
    touch "$DB_FILE"
    run init_filebrowser
    [ "$status" -eq 0 ]
    [[ "$output" == *"Using existing FileBrowser configuration"* ]]
    refute_called "filebrowser config init"
    refute_called "filebrowser users add"
}

@test "start_filebrowser: runs filebrowser and redirects output to its log" {
    start_filebrowser
    wait || true
    assert_called "filebrowser "
    [ -f "$FILEBROWSER_LOG" ]
}

# --------------------------------------------------------------------------- #
# start_jupyter
# --------------------------------------------------------------------------- #

@test "start_jupyter: serves /workspace on port 8888 for root" {
    start_jupyter
    wait || true
    assert_called "--port=8888"
    assert_called "--ip=0.0.0.0"
    assert_called "--allow-root"
    assert_called "--ServerApp.root_dir=$WORKSPACE_DIR"
    [ -d "$WORKSPACE_DIR" ]
}

@test "start_jupyter: uses JUPYTER_PASSWORD as the identity token" {
    export JUPYTER_PASSWORD="hunter2"
    start_jupyter
    wait || true
    assert_called "--IdentityProvider.token=hunter2"
}

@test "start_jupyter: falls back to an empty token when JUPYTER_PASSWORD is unset" {
    unset JUPYTER_PASSWORD
    start_jupyter
    wait || true
    assert_called "--IdentityProvider.token="
}

# --------------------------------------------------------------------------- #
# setup_ssh
# --------------------------------------------------------------------------- #

@test "setup_ssh: generates all four host key types when none exist" {
    setup_ssh
    assert_called "ssh-keygen -t rsa"
    assert_called "ssh-keygen -t dsa"
    assert_called "ssh-keygen -t ecdsa"
    assert_called "ssh-keygen -t ed25519"
}

@test "setup_ssh: does not regenerate host keys that already exist" {
    touch "$SSH_HOST_KEY_DIR/ssh_host_rsa_key"
    setup_ssh
    refute_called "ssh-keygen -t rsa"
    assert_called "ssh-keygen -t ed25519"
}

@test "setup_ssh: installs PUBLIC_KEY into authorized_keys and skips the password" {
    export PUBLIC_KEY="ssh-ed25519 AAAA test@example"
    setup_ssh
    run cat "$HOME/.ssh/authorized_keys"
    [ "$output" = "ssh-ed25519 AAAA test@example" ]
    refute_called "chpasswd"
}

@test "setup_ssh: generates a random root password when PUBLIC_KEY is unset" {
    run setup_ssh
    [ "$status" -eq 0 ]
    [[ "$output" == *"Generated random SSH password for root: s3cr3t-password"* ]]
    assert_called "openssl rand -base64 12"
    assert_called "chpasswd"
    [ ! -f "$HOME/.ssh/authorized_keys" ]
}

@test "setup_ssh: enables PermitUserEnvironment and starts sshd" {
    setup_ssh
    run cat "$SSHD_CONFIG"
    [[ "$output" == *"PermitUserEnvironment yes"* ]]
    assert_called "sshd "
}

# --------------------------------------------------------------------------- #
# export_env_vars
# --------------------------------------------------------------------------- #

@test "export_env_vars: propagates RUNPOD_ and CUDA vars to every environment file" {
    export RUNPOD_POD_ID="pod-123"
    export CUDA_VERSION="12.4"
    export_env_vars

    run cat "$ENV_FILE"
    [[ "$output" == *'RUNPOD_POD_ID="pod-123"'* ]]
    [[ "$output" == *'CUDA_VERSION="12.4"'* ]]

    run cat "$PAM_ENV_FILE"
    [[ "$output" == *'RUNPOD_POD_ID DEFAULT="pod-123"'* ]]

    run cat "$HOME/.ssh/environment"
    [[ "$output" == *'RUNPOD_POD_ID="pod-123"'* ]]

    run cat "$RP_ENV_FILE"
    [[ "$output" == *'export RUNPOD_POD_ID="pod-123"'* ]]
}

@test "export_env_vars: ignores variables outside the allowed prefixes" {
    export SOME_SECRET="do-not-leak"
    export_env_vars
    run cat "$ENV_FILE"
    [[ "$output" != *"SOME_SECRET"* ]]
    [[ "$output" != *"do-not-leak"* ]]
}

@test "export_env_vars: keeps values containing equals signs intact" {
    export RUNPOD_OPTS="a=b=c"
    export_env_vars
    run cat "$ENV_FILE"
    [[ "$output" == *'RUNPOD_OPTS="a=b=c"'* ]]
}

@test "export_env_vars: sources the generated env file from both bashrc files" {
    export_env_vars
    run cat "$HOME/.bashrc"
    [[ "$output" == *"source $RP_ENV_FILE"* ]]
    run cat "$SYSTEM_BASHRC"
    [[ "$output" == *"source $RP_ENV_FILE"* ]]
}

@test "export_env_vars: restricts permissions on the ssh environment file" {
    export_env_vars
    run stat -c '%a' "$HOME/.ssh/environment"
    [ "$output" = "600" ]
    run stat -c '%a' "$ENV_FILE"
    [ "$output" = "644" ]
}

# --------------------------------------------------------------------------- #
# install_custom_nodes
# --------------------------------------------------------------------------- #

@test "install_custom_nodes: clones the manager and every default custom node" {
    mkdir -p "$COMFYUI_DIR"
    install_custom_nodes
    assert_called "git clone https://github.com/ltdrdata/ComfyUI-Manager.git"
    assert_called "git clone https://github.com/kijai/ComfyUI-KJNodes"
    assert_called "git clone https://github.com/MoonGoblinDev/Civicomfy"
    assert_called "git clone https://github.com/MadiatorLabs/ComfyUI-RunpodDirect"
}

@test "install_custom_nodes: skips nodes that are already checked out" {
    mkdir -p "$COMFYUI_DIR/custom_nodes/ComfyUI-Manager"
    mkdir -p "$COMFYUI_DIR/custom_nodes/ComfyUI-KJNodes"
    install_custom_nodes
    refute_called "git clone https://github.com/ltdrdata/ComfyUI-Manager.git"
    refute_called "git clone https://github.com/kijai/ComfyUI-KJNodes"
    assert_called "git clone https://github.com/MoonGoblinDev/Civicomfy"
}

@test "clone_comfyui: clones upstream only when the directory is missing" {
    clone_comfyui
    assert_called "git clone $COMFYUI_REPO"

    : > "$MOCK_LOG"
    mkdir -p "$COMFYUI_DIR"
    clone_comfyui
    refute_called "git clone"
}

# --------------------------------------------------------------------------- #
# install_custom_node_deps
# --------------------------------------------------------------------------- #

@test "install_custom_node_deps: installs requirements.txt, install.py and setup.py" {
    make_custom_node node-a requirements.txt install.py setup.py
    install_custom_node_deps "uv pip install --no-cache"
    assert_called "uv pip install --no-cache -r requirements.txt"
    assert_called "python install.py"
    assert_called "uv pip install --no-cache -e ."
}

@test "install_custom_node_deps: skips install steps a node does not provide" {
    make_custom_node node-a requirements.txt
    install_custom_node_deps "uv pip install --no-cache"
    assert_called "uv pip install --no-cache -r requirements.txt"
    refute_called "python install.py"
    refute_called "-e ."
}

@test "install_custom_node_deps: installs deps for every node, not just the first" {
    make_custom_node node-a requirements.txt
    make_custom_node node-b install.py
    make_custom_node node-c setup.py
    run install_custom_node_deps "uv pip install --no-cache"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Checking dependencies for node-a/"* ]]
    [[ "$output" == *"Checking dependencies for node-b/"* ]]
    [[ "$output" == *"Checking dependencies for node-c/"* ]]
    assert_called "uv pip install --no-cache -r requirements.txt"
    assert_called "python install.py"
    assert_called "uv pip install --no-cache -e ."
}

@test "install_custom_node_deps: honours the installer command it is given" {
    make_custom_node node-a requirements.txt
    install_custom_node_deps "pip install --no-cache-dir"
    assert_called "pip install --no-cache-dir -r requirements.txt"
    refute_called "uv pip"
}

@test "install_custom_node_deps: is a no-op when there are no custom nodes" {
    mkdir -p "$COMFYUI_DIR/custom_nodes"
    install_custom_node_deps "uv pip install --no-cache"
    refute_called "pip"
    refute_called "python install.py"
}

# --------------------------------------------------------------------------- #
# setup_comfyui
# --------------------------------------------------------------------------- #

@test "setup_comfyui: first run clones ComfyUI and creates the venv" {
    run setup_comfyui
    [ "$status" -eq 0 ]
    [[ "$output" == *"First time setup"* ]]
    assert_called "git clone $COMFYUI_REPO"
    assert_called "python3.12 -m venv --system-site-packages $VENV_DIR"
}

@test "setup_comfyui: first run installs node dependencies with pip, not uv" {
    mkdir -p "$COMFYUI_DIR"
    make_custom_node ComfyUI-Manager requirements.txt
    make_custom_node node-a requirements.txt
    setup_comfyui
    assert_called "pip install --no-cache-dir -r requirements.txt"
    refute_called "uv pip install"
}

@test "setup_comfyui: existing venv activates it and reinstalls deps with uv" {
    mkdir -p "$COMFYUI_DIR"
    make_fake_venv "$VENV_DIR"
    make_custom_node node-a requirements.txt
    run setup_comfyui
    [ "$status" -eq 0 ]
    [[ "$output" == *"Checking for custom node dependencies"* ]]
    assert_called "uv pip install --no-cache -r requirements.txt"
    refute_called "python3.12 -m venv"
}

@test "setup_comfyui: creates the venv when ComfyUI exists without one" {
    mkdir -p "$COMFYUI_DIR/custom_nodes/ComfyUI-Manager"
    run setup_comfyui
    [ "$status" -eq 0 ]
    [[ "$output" == *"First time setup"* ]]
    assert_called "python3.12 -m venv --system-site-packages $VENV_DIR"
    refute_called "git clone $COMFYUI_REPO"
}

# --------------------------------------------------------------------------- #
# main
# --------------------------------------------------------------------------- #

@test "main: is not executed when the script is only sourced" {
    refute_called "sshd"
    refute_called "filebrowser"
    refute_called "jupyter"
}

@test "main: runs every startup stage" {
    mkdir -p "$COMFYUI_DIR/custom_nodes"
    make_fake_venv "$VENV_DIR"
    run main
    [ "$status" -eq 0 ]
    wait || true

    assert_called "sshd "
    assert_called "filebrowser config init"
    assert_called "jupyter lab"
    assert_called "python main.py --listen 0.0.0.0 --port 8188"
    assert_called "tail -f $COMFYUI_LOG"
}

@test "main: sets up ssh before starting ComfyUI" {
    mkdir -p "$COMFYUI_DIR/custom_nodes"
    make_fake_venv "$VENV_DIR"
    main
    wait || true
    local ssh_line comfy_line
    ssh_line=$(grep -n '^sshd ' "$MOCK_LOG" | head -1 | cut -d: -f1)
    comfy_line=$(grep -n '^python main.py' "$MOCK_LOG" | head -1 | cut -d: -f1)
    [ "$ssh_line" -lt "$comfy_line" ]
}

@test "main: creates the args file when it is missing" {
    mkdir -p "$COMFYUI_DIR/custom_nodes"
    make_fake_venv "$VENV_DIR"
    main
    wait || true
    [ -f "$ARGS_FILE" ]
}
