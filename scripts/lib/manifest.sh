#!/bin/bash
# Manifest files are plain text lists where blank lines and #-comments are ignored.

read_manifest() {
    grep -v '^[[:space:]]*\(#\|$\)' "$1"
}
