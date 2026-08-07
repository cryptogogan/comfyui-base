#!/usr/bin/env bats
#
# start.5090.sh is a near copy of start.sh, so these tests pin down the pieces
# that must differ and assert the rest stays in sync.

load helpers/mocks

setup() {
    setup_sandbox
}

teardown() {
    teardown_sandbox
}

@test "start.5090.sh: defaults to the cu128 virtualenv" {
    unset VENV_DIR
    source_start_script start.5090.sh
    [ "$VENV_DIR" = "$COMFYUI_DIR/.venv-cu128" ]
}

@test "start.sh: defaults to the plain virtualenv" {
    unset VENV_DIR
    source_start_script start.sh
    [ "$VENV_DIR" = "$COMFYUI_DIR/.venv" ]
}

@test "start.5090.sh: only the virtualenv path and its comments differ from start.sh" {
    run diff "$REPO_ROOT/start.sh" "$REPO_ROOT/start.5090.sh"
    [ "$status" -eq 1 ]
    run bash -c "diff '$REPO_ROOT/start.sh' '$REPO_ROOT/start.5090.sh' | grep -c -E '^[<>]'"
    [ "$output" = "6" ]
}

@test "start.5090.sh: exposes the same startup functions as start.sh" {
    source_start_script start.5090.sh
    local fn
    for fn in setup_ssh export_env_vars start_jupyter init_filebrowser \
        start_filebrowser ensure_args_file clone_comfyui install_custom_nodes \
        install_custom_node_deps setup_venv setup_comfyui build_comfyui_args \
        start_comfyui main; do
        run declare -F "$fn"
        [ "$status" -eq 0 ]
    done
}

@test "start.5090.sh: builds the same ComfyUI arguments as start.sh" {
    source_start_script start.5090.sh
    printf -- '--lowvram\n' > "$ARGS_FILE"
    run build_comfyui_args "$ARGS_FILE"
    [ "$output" = "--listen 0.0.0.0 --port 8188 --lowvram" ]
}

@test "start.5090.sh: creates the cu128 venv on first run" {
    unset VENV_DIR
    source_start_script start.5090.sh
    setup_comfyui
    assert_called "python3.12 -m venv --system-site-packages $COMFYUI_DIR/.venv-cu128"
}

@test "start.5090.sh: does not run main when sourced" {
    source_start_script start.5090.sh
    refute_called "sshd"
}
