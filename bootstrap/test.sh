#!/usr/bin/env bash
# test.sh - item #2's check on the real server (the plan's test): run
# bootstrap.sh --dry-run and assert that every one of the 10 steps says
# "already done". Changes nothing. Prints PASS/FAIL per step and exits
# non-zero on any FAIL.
#
#   bash bootstrap/test.sh             the live check
#   bash bootstrap/test.sh --sandbox   the offline suite (stubbed commands,
#                                      fake home; safe anywhere)
set -Euo pipefail
export LC_ALL=C
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"

case "${1:-}" in
    "") ;;
    --sandbox) exec bash "${SCRIPT_DIR}/tests/run-tests.sh" ;;
    *) echo "Usage: test.sh [--sandbox]" >&2; exit 2 ;;
esac

out=$(bash "${SCRIPT_DIR}/bootstrap.sh" --dry-run 2>&1)
rc=$?
fails=0
for n in 1 2 3 4 5 6 7 8 9 10; do
    line=$(grep -E "^\[ ?${n}/10\]" <<<"$out" | sed -n 1p)
    if [[ "$line" == *"already done"* ]]; then
        printf 'PASS  %s\n' "$line"
    else
        printf 'FAIL  %s\n' "${line:-[${n}/10] (no output for this step)}"
        fails=$((fails + 1))
    fi
done
if (( fails > 0 )); then
    echo
    echo "Full dry-run output:"
    while IFS= read -r l; do printf '  %s\n' "$l"; done <<<"$out"
fi
if (( rc != 0 && fails == 0 )); then
    printf 'FAIL  bootstrap.sh --dry-run exited %s\n' "$rc"
    fails=$((fails + 1))
fi
echo
if (( fails == 0 )); then echo "bootstrap test: all PASS"; else echo "bootstrap test: ${fails} FAIL"; fi
(( fails == 0 ))
