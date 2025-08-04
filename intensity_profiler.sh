#!/usr/bin/env bash
###############################################################################
# intensity_profiler.sh
#
# Aggregates:
#   • int64_profiler.sh   (integer‑op totals, whole program or symbol‑gated)
#   • dram_profiler.sh    (DRAM read / write cache‑line counts)
#
# Usage
#   ./intensity_profiler.sh <target> [function] [--verbose] [-- <args>...]
#
# Examples
#   ./intensity_profiler.sh ./my_app                  # whole program
#   ./intensity_profiler.sh ./my_app myKernel         # kernel‑only ops
#   ./intensity_profiler.sh ./my_app myKernel --verbose
###############################################################################
set -euo pipefail

#───────── locate helper scripts (assumed in same directory) ─────────
SELF_DIR="$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"
INT64_SH="$SELF_DIR/int64_profiler.sh"
DRAM_SH="$SELF_DIR/dram_profiler.sh"

#───────── 1. argument parsing ─────────
[[ $# -lt 1 ]] && {
  echo "Usage: $(basename "$0") <target> [function] [--verbose] [-- <args>...]"
  exit 1
}

TARGET=$1; shift
FUNC=""
if [[ $# -gt 0 && $1 != --* ]]; then FUNC=$1; shift; fi

VERBOSE=0
if [[ "${1:-}" == "--verbose" ]]; then VERBOSE=1; shift; fi
if [[ "${1:-}" == "--" ]]; then shift; fi
EXTRA_ARGS=("$@")   # pass‑through arguments for the target program

#───────── 2. sanity checks ─────────
[[ -x "$TARGET"    ]] || { echo "Target $TARGET not executable"; exit 1; }
[[ -x "$INT64_SH"  ]] || { echo "int64_profiler.sh not found";  exit 1; }
[[ -x "$DRAM_SH"   ]] || { echo "dram_profiler.sh not found";   exit 1; }

#───────── 3. helper: human‑readable bytes ─────────
hr_bytes() {
  local b=$1 u=(B KB MB GB TB PB) i=0
  while (( b>=1024 && i<${#u[@]}-1 )); do b=$((b/1024)); ((i++)); done
  awk -vB="$1" -vE="$i" -vU="${u[$i]}" 'BEGIN{printf "%.2f %s",B/(1024^E),U}'
}

###############################################################################
# 4. run int64_profiler.sh → integer‑op totals
###############################################################################
INT64_CMD=("$INT64_SH" "$TARGET")
[[ -n "$FUNC" ]]   && INT64_CMD+=("$FUNC")
(( VERBOSE ))      && INT64_CMD+=(--verbose)
INT64_CMD+=("--" "${EXTRA_ARGS[@]}")

INT_RAW=$("${INT64_CMD[@]}")

# Extract the sum of the four categories
INT_OPS=$(echo "$INT_RAW" |
          awk '/^(ADD:|SUB:|MUL:|DIV:)/ {gsub(/[,]/,"",$2); s+=$2} END{print s+0}')

###############################################################################
# 5. run dram_profiler.sh → DRAM traffic
###############################################################################
DRAM_RAW=$("$DRAM_SH" "$TARGET" "${EXTRA_ARGS[@]}")
READ_LINES=0
WRITE_LINES=0

# parse “Reads : 123 lines (…”
while read -r line; do
    case "$line" in
        *Reads*)  READ_LINES=$(grep -oE '[0-9,]+' <<<"$line" | head -1 | tr -d ,);;
        *Writes*) WRITE_LINES=$(grep -oE '[0-9,]+' <<<"$line" | head -1 | tr -d ,);;
    esac
done <<<"$DRAM_RAW"

# ensure vars exist even if grep failed
READ_LINES=${READ_LINES:-0}
WRITE_LINES=${WRITE_LINES:-0}

READ_BYTES=$(( READ_LINES  * 64 ))
WRITE_BYTES=$(( WRITE_LINES * 64 ))
TOTAL_BYTES=$(( READ_BYTES + WRITE_BYTES ))

###############################################################################
# 6. arithmetic intensity
###############################################################################
if (( TOTAL_BYTES == 0 )); then
  INTENSITY="n/a"
else
  INTENSITY=$(awk -v o="$INT_OPS" -v b="$TOTAL_BYTES" 'BEGIN{printf "%.6f",o/b}')
fi

###############################################################################
# 7. summary
###############################################################################
echo
printf "===== Integer‑Intensity Report =====\n"
[[ -n "$FUNC" ]] && printf "(integer ops scoped to %s)\n" "$FUNC"
printf "Integer ops : %'d\n"            "$INT_OPS"
printf "DRAM reads  : %'d lines (%s)\n"  "$READ_LINES"  "$(hr_bytes $READ_BYTES)"
printf "DRAM writes : %'d lines (%s)\n"  "$WRITE_LINES" "$(hr_bytes $WRITE_BYTES)"
printf "Total bytes : %s\n"              "$(hr_bytes $TOTAL_BYTES)"
printf "Intensity   : %s ops/byte\n"     "$INTENSITY"