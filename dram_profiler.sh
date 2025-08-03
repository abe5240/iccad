#!/usr/bin/env bash
###############################################################################
# dram_traffic.sh – measure DRAM traffic (bytes) for any command
#
# Requires:
#   • perf, msr, intel_uncore (set up by create_int64_profiler.sh)
# Usage:
#   ./dram_traffic.sh <program> [-- <args>...]
###############################################################################
set -euo pipefail

[[ $# -lt 1 ]] && { echo "Usage: $(basename "$0") cmd [-- args]"; exit 1; }

CMD=("$@")

# pick the aggregate alias if present, else enumerate channels 0–5
if perf list 2>/dev/null | grep -q 'uncore_imc/cas_count_read/'; then
    EVENTS="uncore_imc/cas_count_read/,uncore_imc/cas_count_write/"
else
    EVENTS=$(printf 'uncore_imc_%d/cas_count_read/,uncore_imc_%d/cas_count_write/,' {0..5} | sed 's/,$//')
fi

echo "🔷 Collecting DRAM traffic via: $EVENTS"
OUT=$(sudo perf stat -a -e "$EVENTS" -- "${CMD[@]}" 2>&1 >/dev/null)

READS=$(echo "$OUT" | awk '/cas_count_read/ {sum += $1} END{print sum+0}')
WRITES=$(echo "$OUT" | awk '/cas_count_write/ {sum += $1} END{print sum+0}')
BYTES=$(( 64 * (READS + WRITES) ))

printf "\n--- DRAM traffic ---\n"
printf "Reads : %'d lines  (%'d bytes)\n"  "$READS"  $((64*READS))
printf "Writes: %'d lines  (%'d bytes)\n"  "$WRITES" $((64*WRITES))
printf "Total : %'d bytes\n"                "$BYTES"