#!/usr/bin/env bash
###############################################################################
# intensity_profiler.sh
#
# Outputs:
#   • Integer‑op totals  (ADD+SUB+MUL+DIV categories)
#   • DRAM traffic (reads / writes, auto‑scaled to KB/MB/GB)
#   • Arithmetic intensity  = ops / byte
#
# Usage:
#   ./intensity_profiler.sh [--verbose] <program> [-- <args>...]
###############################################################################
set -euo pipefail

# ───────── config (adjust if Pin path differs) ─────────
PIN_HOME="$HOME/pin-3.31"
TOOL_SO="$PIN_HOME/source/tools/Int64Profiler/obj-intel64/Int64Profiler.so"

# ───────── CLI parsing ─────────
VERBOSE=0
if [[ "${1:-}" == "--verbose" ]]; then VERBOSE=1; shift; fi
if [[ $# -lt 1 ]]; then
  echo "Usage: $(basename "$0") [--verbose] <target> [-- <args>...]"; exit 1
fi
TARGET="$1"; shift

# ───────── sanity checks ─────────
[[ -d "$PIN_HOME" ]] || { echo "Pin not found at $PIN_HOME";  exit 1; }
[[ -f "$TOOL_SO"  ]] || { echo "Int64Profiler.so missing";    exit 1; }
[[ -e "$TARGET"   ]] || { echo "Target $TARGET not found";    exit 1; }
[[ -x "$TARGET"   ]] || { echo "Target $TARGET not executable"; exit 1; }

# ───────── helper: human‑readable bytes ─────────
hr_bytes () {
    local bytes=$1 units=(B KB MB GB TB PB) idx=0
    while (( bytes >= 1024 && idx < ${#units[@]}-1 )); do
        bytes=$(( bytes / 1024 )); ((idx++))
    done
    awk -v b="$1" -v e="$idx" -v u="${units[$idx]}" \
        'BEGIN {printf "%.2f %s", b/(1024^e), u}'
}

# ───────── step 1 – integer operations ─────────
PIN_ARGS=(); (( VERBOSE )) && PIN_ARGS+=("-verbose" "1")
RAW=$("$PIN_HOME/pin" -t "$TOOL_SO" "${PIN_ARGS[@]}" -- "$TARGET" "$@" 2>/dev/null)

if (( VERBOSE )); then echo "$RAW"; fi

INT_OPS=$(echo "$RAW" | \
          awk '/^(ADD:|SUB:|MUL:|DIV:)/ {gsub(/[,]/,"",$2); sum+=$2} END{print sum+0}')

# ───────── step 2 – DRAM traffic ─────────
if perf list 2>/dev/null | grep -q 'uncore_imc/cas_count_read/'; then
    EVENTS="uncore_imc/cas_count_read/,uncore_imc/cas_count_write/"
else
    EVENTS=$(printf 'uncore_imc_%d/cas_count_read/,uncore_imc_%d/cas_count_write/,' {0..5} | sed 's/,$//')
fi

PERF=$(sudo perf stat -x, --no-scale -a -e "$EVENTS" -- "$TARGET" "$@" 2>&1 >/dev/null)

READS=$(echo "$PERF" | awk -F',' '/cas_count_read/  {gsub(/[^0-9]/,"",$1); sum+=$1} END{print sum+0}')
WRITES=$(echo "$PERF" | awk -F',' '/cas_count_write/ {gsub(/[^0-9]/,"",$1); sum+=$1} END{print sum+0}')
BYTES=$(( 64 * (READS + WRITES) ))

# ───────── step 3 – compute intensity ─────────
if (( BYTES == 0 )); then
    INTENSITY="n/a"
else
    INTENSITY=$(awk -v o="$INT_OPS" -v b="$BYTES" 'BEGIN {printf "%.3f", o/b}')
fi

# ───────── print summary ─────────
echo
printf "=== Integer Intensity Report ===\n"
printf "Integer ops : %'d\n"         "$INT_OPS"
printf "DRAM reads  : %'d lines (%s)\n"  "$READS"  "$(hr_bytes $((64*READS)))"
printf "DRAM writes : %'d lines (%s)\n"  "$WRITES" "$(hr_bytes $((64*WRITES)))"
printf "Total bytes : %s\n"              "$(hr_bytes $BYTES)"
printf "Intensity   : %s ops/byte\n"     "$INTENSITY"
