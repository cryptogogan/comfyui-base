#!/bin/bash
# Clone custom nodes from a manifest and install their dependencies.
# Usage: install-custom-nodes.sh <custom_nodes_dir> <manifest> [<manifest>...]
set -e

NODES_DIR="${1:?custom nodes directory required}"
shift

source "$(dirname "$0")/lib/custom-nodes.sh"

for manifest in "$@"; do
    clone_custom_nodes "$NODES_DIR" "$manifest"
done

install_custom_node_deps "$NODES_DIR"
