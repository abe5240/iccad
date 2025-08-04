#!/usr/bin/env bash
###############################################################################
# dram_profiler.sh  –  measure DRAM read / write traffic for any command
#   • Intel server CPUs (Skylake → Sapphire-Rapids) with iMC CAS_COUNT events
#   • Counts 64-B cache-line transfers; prints human-readable bytes
#   • Requires root or perf_event_paranoid ≤ 0
###############################################################################
set -euo pipefail

[[ $# -lt 1 ]] && { echo "Usage: $(basename "$0") <cmd> [args]" >&2; exit 1; }
CMD=( "$@" )

# ─────────── byte formatter ─────────────────────────────────────────
hr() { local b=$1 u=(B KB MB GB TB PB) i=0
       while (( b>=1024 && i<${#u[@]}-1 )); do b=$((b/1024)); ((i++)); done
       awk -vB="$1" -vE="$i" -vU="${u[$i]}" 'BEGIN{printf "%.2f %s",B/(1024^E),U}'; }

# ─────────── confirm alias events exist ────────────────────────────
if ! perf list | grep -q 'uncore_imc/cas_count_read/'; then
    echo "❌  iMC CAS_COUNT alias not found (intel_uncore not loaded?)" >&2
    exit 1
fi
EVENTS="uncore_imc/cas_count_read/,uncore_imc/cas_count_write/"
echo "🔷 Collecting via: $EVENTS"

# ─────────── run perf & capture CSV output ─────────────────────────
CSV=$(sudo perf stat -x, --no-scale -a -e "$EVENTS" -- "${CMD[@]}" 2>&1 | tee /dev/tty)

# ─────────── parse counts ──────────────────────────────────────────
reads=$( echo "$CSV" | awk -F',' '/cas_count_read/  {gsub(/[^0-9]/,"",$1);r+=$1} END{print r+0}')
writes=$(echo "$CSV" | awk -F',' '/cas_count_write/ {gsub(/[^0-9]/,"",$1);w+=$1} END{print w+0}')
bytes=$(( 64 * (reads + writes) ))

# ─────────── summary ───────────────────────────────────────────────
printf "\n--- DRAM traffic (64-B lines) ---\n"
printf "Reads : %'d  (%s)\n"  "$reads"  "$(hr $((64*reads)))"
printf "Writes: %'d  (%s)\n"  "$writes" "$(hr $((64*writes)))"
printf "Total : %s\n"         "$(hr $bytes)"