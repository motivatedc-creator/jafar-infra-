#!/usr/bin/env bash
# uninstall.sh [--dry-run] - item #2 installs nothing of its own, so there is
# nothing to remove. It deliberately does NOT undo what bootstrap.sh set up
# (packages, logind, linger, Tailscale, Hermes, the restored ~/.hermes):
# that is the running server itself. It never changes anything.
set -euo pipefail
case "${1:-}" in
    ""|--dry-run) ;;
    *) echo "Usage: uninstall.sh [--dry-run]" >&2; exit 2 ;;
esac
echo "bootstrap: nothing to remove: already done"
echo "bootstrap: kept ~/.local/state/jafar/bootstrap-restored (it stops a second restore over live data)"
