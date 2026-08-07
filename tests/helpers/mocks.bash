#!/usr/bin/env bash
# Helpers to run the start scripts against a throwaway filesystem with every
# external binary replaced by a recording stub.

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
export REPO_ROOT

# Create the sandbox: a temp directory, a mock bin directory on PATH, and the
# environment overrides the start scripts read for their paths.
setup_sandbox() {
    TEST_TMP="$(mktemp -d "${BATS_TMPDIR:-/tmp}/comfyui-test.XXXXXX")"
    MOCK_BIN="$TEST_TMP/bin"
    MOCK_LOG="$TEST_TMP/calls.log"
    mkdir -p "$MOCK_BIN"
    : > "$MOCK_LOG"
    export TEST_TMP MOCK_BIN MOCK_LOG
    export PATH="$MOCK_BIN:$PATH"

    export HOME="$TEST_TMP/home"
    mkdir -p "$HOME"

    export WORKSPACE_DIR="$TEST_TMP/workspace"
    export COMFYUI_ROOT="$TEST_TMP/workspace/runpod-slim"
    export COMFYUI_DIR="$COMFYUI_ROOT/ComfyUI"
    export ARGS_FILE="$COMFYUI_ROOT/comfyui_args.txt"
    export DB_FILE="$COMFYUI_ROOT/filebrowser.db"
    export COMFYUI_LOG="$COMFYUI_ROOT/comfyui.log"
    export FILEBROWSER_LOG="$TEST_TMP/filebrowser.log"
    export JUPYTER_LOG="$TEST_TMP/jupyter.log"
    export FILEBROWSER_CONFIG="$TEST_TMP/filebrowser-config.json"
    mkdir -p "$COMFYUI_ROOT"

    export SSH_HOST_KEY_DIR="$TEST_TMP/etc/ssh"
    export SSHD_CONFIG="$TEST_TMP/etc/ssh/sshd_config"
    export SSHD_BIN="$MOCK_BIN/sshd"
    export ENV_FILE="$TEST_TMP/etc/environment"
    export PAM_ENV_FILE="$TEST_TMP/etc/pam_env.conf"
    export RP_ENV_FILE="$TEST_TMP/etc/rp_environment"
    export SYSTEM_BASHRC="$TEST_TMP/etc/bash.bashrc"
    mkdir -p "$TEST_TMP/etc/ssh"

    unset PUBLIC_KEY JUPYTER_PASSWORD

    mock_default_commands
}

teardown_sandbox() {
    cd / || return
    if [ -n "${TEST_TMP:-}" ] && [ -d "$TEST_TMP" ]; then
        rm -rf "$TEST_TMP"
    fi
}

# mock_command <name> [body]
# Creates an executable stub that appends "<name> <args>" to the call log and
# then runs the optional body.
mock_command() {
    local name="$1"
    shift
    {
        echo '#!/usr/bin/env bash'
        echo "echo \"$name \$*\" >> \"$MOCK_LOG\""
        if [ "$#" -gt 0 ]; then
            printf '%s\n' "$@"
        fi
    } > "$MOCK_BIN/$name"
    chmod +x "$MOCK_BIN/$name"
}

mock_default_commands() {
    local cmd
    for cmd in ssh-keygen chpasswd sshd filebrowser jupyter git uv pip tail; do
        mock_command "$cmd"
    done
    mock_command openssl 'echo "s3cr3t-password"'
    # `python3.12 -m venv <dir>` must leave behind a sourceable activate script.
    mock_command python3.12 \
        'if [ "$1" = "-m" ] && [ "$2" = "venv" ]; then' \
        '    venv_dir="${*: -1}"' \
        '    mkdir -p "$venv_dir/bin"' \
        '    echo "# fake activate" > "$venv_dir/bin/activate"' \
        'fi'
    mock_command python 'exit 0'
    # nohup would detach the mocks from the log; run the command inline instead.
    mock_command nohup 'exec "$@"'
}

source_start_script() {
    local script="${1:-start.sh}"
    # shellcheck disable=SC1090
    source "$REPO_ROOT/$script"
}

calls() {
    cat "$MOCK_LOG"
}

assert_called() {
    if ! grep -qF -- "$1" "$MOCK_LOG"; then
        echo "expected call not found: $1" >&2
        echo "--- recorded calls ---" >&2
        cat "$MOCK_LOG" >&2
        return 1
    fi
}

refute_called() {
    if grep -qF -- "$1" "$MOCK_LOG"; then
        echo "unexpected call found: $1" >&2
        echo "--- recorded calls ---" >&2
        cat "$MOCK_LOG" >&2
        return 1
    fi
}

# Create a fake venv whose activate script is a no-op.
make_fake_venv() {
    local venv="$1"
    mkdir -p "$venv/bin"
    echo '# fake activate' > "$venv/bin/activate"
}

# Create a custom node directory containing the given files.
make_custom_node() {
    local name="$1"
    shift
    local dir="$COMFYUI_DIR/custom_nodes/$name"
    mkdir -p "$dir"
    local file
    for file in "$@"; do
        touch "$dir/$file"
    done
}
