#!/usr/bin/env bash
###############################################################################
# dram_profiler.sh – measure DRAM traffic (reads / writes) for any command
#
# Prerequisites (handled by installer.sh):
#   • perf, msr, intel_uncore modules
#
# Usage:
#   ./dram_profiler.sh <program> [-- <args>...]
###############################################################################
set -euo pipefail

[[ $# -lt 1 ]] && { echo "Usage: $(basename "$0") cmd [-- args]"; exit 1; }
CMD=("$@")

# ───────── human-readable bytes with two decimals ─────────
hr_bytes () {
    local bytes=$1
    local units=(B KB MB GB TB)
    local exp=0
    while (( bytes >= 1024 && exp < ${#units[@]}-1 )); do
        bytes=$(( bytes / 1024 ))
        ((exp++))
    done
    printf "%.2f %s" "$(awk "BEGIN {printf $1/(1024^$exp)}")" "${units[$exp]}"
}

# ───────── choose events ─────────
if perf list 2>/dev/null | grep -q 'uncore_imc/cas_count_read/'; then
    EVENTS="uncore_imc/cas_count_read/,uncore_imc/cas_count_write/"
else
    EVENTS=$(printf 'uncore_imc_%d/cas_count_read/,uncore_imc_%d/cas_count_write/,' {0..5} | sed 's/,$//')
fi

echo "🔷 Collecting DRAM traffic via: $EVENTS"

PERF=$(sudo perf stat -a --no-scale -e "$EVENTS" -- "${CMD[@]}" 2>&1 >/dev/null)

READS=$(echo "$PERF" | awk '/cas_count_read/  {gsub(/[,]/,""); sum+=$1} END{print sum+0}')
WRITES=$(echo "$PERF" | awk '/cas_count_write/ {gsub(/[,]/,""); sum+=$1} END{print sum+0}')
BYTES=$(( 64 * (READS + WRITES) ))

printf "\n--- DRAM traffic ---\n"
printf "Reads : %'d lines (%s)\n"  "$READS"  "$(hr_bytes $((64*READS)))"
printf "Writes: %'d lines (%s)\n"  "$WRITES" "$(hr_bytes $((64*WRITES)))"
printf "Total : %s\n"              "$(hr_bytes $BYTES)"