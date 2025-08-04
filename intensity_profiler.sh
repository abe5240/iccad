#!/usr/bin/env bash
###############################################################################
# intensity_profiler.sh
#
# Aggregates results from:
#   • int64_profiler.sh   → integer‑operation totals
#   • dram_profiler.sh    → DRAM traffic (cache‑line counts)
#
# Usage
#   ./intensity_profiler.sh <target> [function] [--verbose] [-- <args>...]
#
# Notes
#   • If <function> is omitted, integer ops are for the whole process.
#   • DRAM traffic is always whole‑process (hardware limitation).
###############################################################################
set -euo pipefail

SELF_DIR="$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"
INT64="$SELF_DIR/int64_profiler.sh"
DRAM="$SELF_DIR/dram_profiler.sh"

###############################################################################
# 1. argument parsing
###############################################################################
[[ $# -lt 1 ]] && {
  echo "Usage: $(basename "$0") <target> [function] [--verbose] [-- <args>...]"
  exit 1
}

TARGET=$1; shift
FUNC=""
if [[ $# -gt 0 && $1 != --* ]]; then FUNC=$1; shift; fi

VERBOSE=0
if [[ "${1:-}" == "--verbose" ]]; then VERBOSE=1; shift; fi
if [[ "${1:-}" == "--"      ]]; then shift; fi   # discard separator
EXTRA_ARGS=("$@")                                # pass‑through

###############################################################################
# 2. sanity checks
###############################################################################
[[ -x "$TARGET" ]]  || { echo "Target $TARGET not executable"; exit 1; }
[[ -x "$INT64"  ]]  || { echo "int64_profiler.sh not found";  exit 1; }
[[ -x "$DRAM"   ]]  || { echo "dram_profiler.sh not found";   exit 1; }

###############################################################################
# 3. helper – human‑readable bytes
###############################################################################
hr_bytes() {
  local b=$1; local u=(B KB MB GB TB PB); local i=0
  while (( b>=1024 && i<${#u[@]}-1 )); do b=$((b/1024)); ((i++)); done
  awk -vB="$1" -vE="$i" -vU="${u[$i]}" 'BEGIN{printf "%.2f %s",B/(1024^E),U}'
}

###############################################################################
# 4. gather integer‑op totals
###############################################################################
INT64_ARGS=("$TARGET")
[[ -n "$FUNC" ]] && INT64_ARGS+=("$FUNC")
(( VERBOSE ))   && INT64_ARGS+=(--verbose)
INT_RAW=$("$INT64" "${INT64_ARGS[@]}" "${EXTRA_ARGS[@]}")

# extract the four totals
INT_OPS=$(echo "$INT_RAW" |
          awk '/^(ADD:|SUB:|MUL:|DIV:)/ {gsub(/[,]/,"",$2); s+=$2} END{print s+0}')

###############################################################################
# 5. gather DRAM traffic
###############################################################################
DRAM_RAW=$("$DRAM" "$TARGET" "${EXTRA_ARGS[@]}")

READ_LINES=$( echo "$DRAM_RAW" | awk '/Reads/ {gsub(/[,]/,"",$3); print $3}')
WRITE_LINES=$(echo "$DRAM_RAW" | awk '/Writes/ {gsub(/[,]/,"",$3); print $3}')
READ_BYTES=$(( READ_LINES  * 64 ))
WRITE_BYTES=$(( WRITE_LINES * 64 ))
TOTAL_BYTES=$(( READ_BYTES + WRITE_BYTES ))

###############################################################################
# 6. arithmetic intensity
###############################################################################
if (( TOTAL_BYTES == 0 )); then
  INTENSITY="n/a"
else
  INTENSITY=$(awk -v o="$INT_OPS" -v b="$TOTAL_BYTES" \
                 'BEGIN{printf "%.3f",o/b}')
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