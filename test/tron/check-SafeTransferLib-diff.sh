#!/bin/bash
# Verifies that the Tron SafeTransferLib override only differs from upstream solmate within
# ===== BEGIN/END TRON OVERRIDE ===== marker regions, so a future solmate bump can't silently
# drift the untouched functions (safeTransferFrom/safeApprove/safeTransferETH) out of sync
# without this failing.
#
# Run from anywhere:
#   ./test/tron/check-SafeTransferLib-diff.sh
set -euo pipefail
cd "$(dirname "$0")/../.."

UPSTREAM="lib/solmate/src/utils/SafeTransferLib.sol"
OVERRIDE="contracts/overrides/tron/SafeTransferLib.sol"

BEGINS=$(grep -n 'BEGIN TRON OVERRIDE' "$OVERRIDE" | cut -d: -f1 | tr '\n' ' ')
ENDS=$(grep -n 'END TRON OVERRIDE' "$OVERRIDE" | cut -d: -f1 | tr '\n' ' ')

if [ -z "$BEGINS" ] || [ "$(echo "$BEGINS" | wc -w)" != "$(echo "$ENDS" | wc -w)" ]; then
  echo "FAIL: could not find matching BEGIN/END TRON OVERRIDE marker pairs in $OVERRIDE"
  exit 1
fi

# For every line diff -u reports as added/changed in $OVERRIDE, verify it falls within one of
# the marker ranges above. Unmarked additions or removals mean the file has drifted from
# upstream outside the deliberately overridden sections.
BAD=$( (diff -u "$UPSTREAM" "$OVERRIDE" || true) | awk -v begins="$BEGINS" -v ends="$ENDS" '
  BEGIN {
    n = split(begins, b, " ")
    split(ends, e, " ")
  }
  function in_marker(line,    i) {
    for (i = 1; i <= n; i++) {
      if (line >= b[i] && line <= e[i]) return 1
    }
    return 0
  }
  /^@@/ {
    # Header looks like: @@ -a,b +c,d @@ — extract the "+c" new-file start line.
    split($0, parts, " ")
    plus = parts[3]
    sub(/^\+/, "", plus)
    split(plus, cd, ",")
    newline = cd[1] + 0
    next
  }
  /^\+\+\+/ { next }
  /^---/ { next }
  /^\+/ {
    if (!in_marker(newline)) {
      print "line " newline ": " $0
    }
    newline++
    next
  }
  /^ / { newline++; next }
')

if [ -n "$BAD" ]; then
  echo "FAIL: $OVERRIDE differs from upstream outside TRON OVERRIDE markers:"
  echo "$BAD"
  exit 1
fi

echo "OK: $OVERRIDE matches upstream solmate outside of TRON OVERRIDE markers"
