#!/bin/bash
# Shared helpers for cloning ComfyUI custom nodes and installing their dependencies.

# Python/pip commands used for dependency installation. Override PIP_INSTALL when
# running inside a virtualenv that uses a different installer.
PYTHON_CMD="${PYTHON_CMD:-python3.12}"
PIP_INSTALL="${PIP_INSTALL:-$PYTHON_CMD -m pip install --no-cache-dir}"

source "$(dirname "${BASH_SOURCE[0]}")/manifest.sh"

# clone_custom_nodes <custom_nodes_dir> <manifest> - clone every repo listed in
# the manifest, skipping ones that already exist.
clone_custom_nodes() {
    local nodes_dir="$1" manifest="$2" repo name
    mkdir -p "$nodes_dir"
    while read -r repo; do
        name=$(basename "$repo" .git)
        if [ -d "$nodes_dir/$name" ]; then
            echo "$name already installed, skipping"
            continue
        fi
        echo "Installing $name..."
        git clone "$repo" "$nodes_dir/$name"
    done < <(read_manifest "$manifest")
}

# install_custom_node_deps <custom_nodes_dir> - install requirements.txt,
# install.py and setup.py for every custom node directory. Set REQUIREMENTS_ONLY=1
# to only handle requirements.txt, and IGNORE_ERRORS=1 to keep going on failure.
install_custom_node_deps() {
    local nodes_dir="$1" node_dir name
    for node_dir in "$nodes_dir"/*/; do
        [ -d "$node_dir" ] || continue
        name=$(basename "$node_dir")
        echo "Checking dependencies for $name..."
        # Explicit `|| exit 1` because errexit is disabled inside a subshell
        # whose exit status is being tested.
        if ! (
            cd "$node_dir" || exit 1
            if [ -f requirements.txt ]; then
                echo "Installing requirements.txt for $name"
                $PIP_INSTALL -r requirements.txt || exit 1
            fi
            if [ -z "$REQUIREMENTS_ONLY" ]; then
                if [ -f install.py ]; then
                    echo "Running install.py for $name"
                    $PYTHON_CMD install.py || exit 1
                fi
                if [ -f setup.py ]; then
                    echo "Running setup.py for $name"
                    $PIP_INSTALL -e . || exit 1
                fi
            fi
        ); then
            echo "Dependency installation failed for $name" >&2
            [ -n "$IGNORE_ERRORS" ] || return 1
        fi
    done
}
