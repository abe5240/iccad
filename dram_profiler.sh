#!/usr/bin/env bash
###############################################################################
# dram_profiler.sh – measure DRAM traffic (reads / writes) for any command
# Outputs results in the largest unit (B, KB, MB, GB…) with two‑decimal precision.
###############################################################################
set -euo pipefail

[[ $# -lt 1 ]] && { echo "Usage: $(basename "$0") <program> [-- <args>...]"; exit 1; }
CMD=("$@")

# ───────── human‑readable formatter ─────────
hr_bytes () {                          # $1 = integer byte count
    local b=$1 u_idx=0
    local units=(B KB MB GB TB PB)
    while (( b >= 1024 && u_idx < ${#units[@]}-1 )); do
        b=$(( b / 1024 ))
        (( u_idx++ ))
    done
    awk -v bytes="$1" -v exp="$u_idx" -v u="${units[$u_idx]}" \
        'BEGIN {printf "%.2f %s", bytes/(1024^exp), u}'
}

# ───────── pick correct events list ─────────
if perf list 2>/dev/null | grep -q 'uncore_imc/cas_count_read/'; then
    EVENTS="uncore_imc/cas_count_read/,uncore_imc/cas_count_write/"
else
    EVENTS=$(printf 'uncore_imc_%d/cas_count_read/,uncore_imc_%d/cas_count_write/,' {0..5} | sed 's/,$//')
fi

echo "🔷 Collecting DRAM traffic via: $EVENTS"

#   -x, forces CSV output     --no-scale, raw counts
PERF=$(sudo perf stat -x, --no-scale -a -e "$EVENTS" -- "${CMD[@]}" \
       2>&1 | tee /dev/tty)

# first column is the raw count; strip any non‑digit just in case
READS=$(echo "$PERF" | awk -F',' '/cas_count_read/  {gsub(/[^0-9]/,"",$1); sum+=$1} END{print sum+0}')
WRITES=$(echo "$PERF" | awk -F',' '/cas_count_write/ {gsub(/[^0-9]/,"",$1); sum+=$1} END{print sum+0}')
BYTES=$(( 64 * (READS + WRITES) ))

printf "\n--- DRAM traffic ---\n"
printf "Reads : %'d lines (%s)\n"  "$READS"  "$(hr_bytes $((64*READS)))"
printf "Writes: %'d lines (%s)\n"  "$WRITES" "$(hr_bytes $((64*WRITES)))"
printf "Total : %s\n"              "$(hr_bytes $BYTES)"