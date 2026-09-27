#!/usr/bin/env bash
# hermes-backup.sh - the Jafar Build Plan's name for the nightly backup.
# Thin alias for backup-hermes.sh, which the live crontab calls by that name;
# both stay so neither the plan's commands nor the existing cron line break.
# All arguments and exit codes are those of backup-hermes.sh.
set -euo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
exec "${SCRIPT_DIR}/backup-hermes.sh" "$@"
