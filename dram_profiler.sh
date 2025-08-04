#!/usr/bin/env bash
###############################################################################
# dram_profiler.sh – measure DRAM traffic (reads / writes) for any command
#   * Works on any recent Intel server (Skylake → Sapphire-Rapids).
#   * Discovers per-IMC event names at runtime.
#   * Adds WR_PRE if present (captures RMW store traffic on SPR).
#   * Prints raw line-counts and human-readable byte totals.
###############################################################################
set -euo pipefail

[[ $# -lt 1 ]] && {
    echo "Usage: $(basename "$0") <command> [-- <args>...]" >&2
    exit 1
}
CMD=("$@")

# ───────────────────────── byte formatter ────────────────────────────
hr_bytes() {                      # $1 = integer bytes
    local b=$1 u=(B KB MB GB TB PB) i=0
    while (( b>=1024 && i<${#u[@]}-1 )); do b=$((b/1024)); ((i++)); done
    awk -vB="$1" -vE="$i" -vU="${u[$i]}" 'BEGIN{printf "%.2f %s",B/(1024^E),U}'
}

# ─────────────────── build per-IMC event list ────────────────────────
EVENTS=""
for evline in $(perf list --raw 2>/dev/null | grep -o \
     'uncore_imc_[0-9]\+/UNC_M_CAS_COUNT\.\(RD\|WR\|WR_PRE\)/'); do
    EVENTS+="${evline},"
done
EVENTS=${EVENTS%,}        # trim trailing comma

if [[ -z "$EVENTS" ]]; then
    echo "❌  No iMC CAS-COUNT events available (is intel_uncore loaded?)" >&2
    exit 1
fi

echo "🔷 Collecting via: $EVENTS"

# ─────────────────── run perf and capture CSV ────────────────────────
PERF=$(sudo perf stat -x, --no-scale -a -e "$EVENTS" -- "${CMD[@]}" \
       2>&1 | tee /dev/tty)

# ─────────────────── parse counts from CSV ───────────────────────────
reads=$( echo "$PERF" | awk -F',' \
          '/CAS_COUNT\.(RD|Rd)|cas_count_read/  {gsub(/[^0-9]/,"",$1);r+=$1}
          END{print r+0}')
writes=$(echo "$PERF" | awk -F',' \
          '/CAS_COUNT\.(WR|WR_PRE)|cas_count_write/ {gsub(/[^0-9]/,"",$1);w+=$1}
          END{print w+0}')

total_bytes=$(( 64 * (reads + writes) ))

# ─────────────────── summary ─────────────────────────────────────────
printf "\n--- DRAM traffic (64-B lines) ---\n"
printf "Reads : %'d  (%s)\n"  "$reads"  "$(hr_bytes $((64*reads)))"
printf "Writes: %'d  (%s)\n"  "$writes" "$(hr_bytes $((64*writes)))"
printf "Total : %s\n"         "$(hr_bytes $total_bytes)"