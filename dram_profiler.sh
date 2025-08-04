#!/usr/bin/env bash
###############################################################################
# dram_profiler.sh – Measure DRAM traffic (reads / writes) for any command
#   * Uses iMC CAS-COUNT events on Intel servers (Sapphire Rapids, Ice Lake, …)
#   * Handles both the generic alias and explicit per-IMC events.
#   * Adds WR_PRE to capture RMW traffic on Sapphire Rapids.
#   * Falls back to all eight IMC instances (0-7) if the alias is missing.
#
# Output: human-readable bytes plus raw line counts.
###############################################################################
set -euo pipefail

[[ $# -lt 1 ]] && {
    echo "Usage: $(basename "$0") <program> [-- <args>...]" >&2
    exit 1
}
CMD=("$@")

# ────────────── helper: human readable byte formatter ───────────────
hr_bytes() {                      # $1 = integer byte-count
    local b=$1 u_idx=0
    local units=(B KB MB GB TB PB)
    while (( b >= 1024 && u_idx < ${#units[@]}-1 )); do
        b=$(( b / 1024 ))
        (( u_idx++ ))
    done
    awk -v bytes="$1" -v exp="$u_idx" -v u="${units[$u_idx]}" \
        'BEGIN{printf "%.2f %s", bytes/(1024^exp), u}'
}

# ────────────── choose event list ────────────────────────────────────
if perf list 2>/dev/null | grep -q 'uncore_imc/cas_count_read/'; then
    # kernel exposes the fan-out alias (preferred)
    EVENTS="uncore_imc/cas_count_read/,\
uncore_imc/cas_count_write/,\
uncore_imc/cas_count_write_pre/"
else
    # fall back to explicit PMU names (8 channels on SPR)
    EVENTS=$(printf 'uncore_imc_%d/cas_count_read/,\
uncore_imc_%d/cas_count_write/,\
uncore_imc_%d/cas_count_write_pre/,' {0..7} | sed 's/,$//')
fi

echo "🔷 Collecting DRAM traffic via: $EVENTS"

# ────────────── run perf and capture raw counts ─────────────────────
PERF_OUT=$(sudo perf stat -x, --no-scale -a -e "$EVENTS" -- "${CMD[@]}" \
           2>&1 | tee /dev/tty)

# ────────────── parse counts from perf CSV output ───────────────────
READS=$(echo "$PERF_OUT"  | awk -F',' '/cas_count_read/  {gsub(/[^0-9]/,"",$1);sum+=$1} END{print sum+0}')
WRITES=$(echo "$PERF_OUT" | awk -F',' '/cas_count_write/ {gsub(/[^0-9]/,"",$1);sum+=$1}
                                       /cas_count_write_pre/ {gsub(/[^0-9]/,"",$1);sum+=$1}
                                       END{print sum+0}')

TOTAL_BYTES=$(( 64 * (READS + WRITES) ))

# ────────────── nice summary ────────────────────────────────────────
printf "\n--- DRAM traffic (64-B lines) ---\n"
printf "Reads : %'d  (%s)\n"  "$READS"  "$(hr_bytes $((64*READS)))"
printf "Writes: %'d  (%s)\n"  "$WRITES" "$(hr_bytes $((64*WRITES)))"
printf "Total : %s\n"         "$(hr_bytes $TOTAL_BYTES)"