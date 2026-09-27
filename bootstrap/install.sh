#!/usr/bin/env bash
# install.sh [--dry-run] - item #2 has nothing to install: bootstrap.sh is
# run by hand, once on a fresh machine (or with --dry-run on the live one).
# This file exists so every item has the same four files, and so bootstrap
# step 9 can treat items uniformly. It never changes anything.
set -euo pipefail
case "${1:-}" in
    ""|--dry-run) ;;
    *) echo "Usage: install.sh [--dry-run]" >&2; exit 2 ;;
esac
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
echo "bootstrap: nothing to install: already done"
echo "bootstrap: check the server with: bash ${SCRIPT_DIR}/test.sh"
