#!/bin/bash
# Download files listed in a manifest of "<destination> <url> [extra wget args]"
# lines, creating parent directories as needed.
# Usage: download-files.sh <base_dir> <manifest>
set -e

BASE_DIR="${1:?base directory required}"
MANIFEST="${2:?manifest required}"

source "$(dirname "$0")/lib/manifest.sh"

while read -r dest url extra_args; do
    target="$BASE_DIR/$dest"
    if [ -f "$target" ]; then
        echo "$dest already present, skipping"
        continue
    fi
    echo "Downloading $dest..."
    mkdir -p "$(dirname "$target")"
    wget -O "$target" "$url" $extra_args
done < <(read_manifest "$MANIFEST")
