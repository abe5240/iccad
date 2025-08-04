#!/usr/bin/env bash
###############################################################################
# dram_profiler.sh
#
# Measure DRAM traffic (iMC CAS-COUNT read & write lines) for any command.
#   * Works on Intel server CPUs (Skylake → Sapphire-Rapids).
#   * Counts 64-byte cache-line transfers; prints human-readable bytes.
#
# REQUIREMENTS
#   • Run the script with sudo   ──OR──   set /proc/sys/kernel/perf_event_paranoid to 0
#   • intel_uncore driver loaded so the alias events exist.
#
# EXAMPLE
#   sudo ./dram_profiler.sh ./touch1gb
###############################################################################
set -euo pipefail

######################## 1. argument check ####################################
[[ $# -lt 1 ]] && { echo "Usage: $(basename "$0") <command> [args]" >&2; exit 1; }
CMD=( "$@" )

######################## 2. helper: human-readable bytes ######################
hr_bytes() {                       # $1 = integer bytes
    local b=$1; local u=(B KB MB GB TB PB); local i=0
    while (( b>=1024 && i<${#u[@]}-1 )); do b=$((b/1024)); ((i++)); done
    awk -vB="$1" -vE="$i" -vU="${u[$i]}" 'BEGIN{printf "%.2f %s",B/(1024^E),U}'
}

######################## 3. verify alias events exist #########################
ALIAS_RD="uncore_imc/cas_count_read/"
ALIAS_WR="uncore_imc/cas_count_write/"

if ! sudo perf list 2>/dev/null | grep -q "$ALIAS_RD"; then
    cat >&2 <<EOF
❌  iMC CAS-COUNT alias events not available.
    • Is the intel_uncore driver loaded?
    • Are you running this script with sudo *or* perf_event_paranoid=0?
EOF
    exit 1
fi
EVENTS="${ALIAS_RD},${ALIAS_WR}"
echo "🔷 Measuring via events: $EVENTS"

######################## 4. run perf stat (CSV) ################################
CSV=$(sudo perf stat -x, --no-scale -a -e "$EVENTS" -- "${CMD[@]}" 2>&1 | tee /dev/tty)

######################## 5. parse counts #######################################
reads=$( echo "$CSV" | awk -F',' '/cas_count_read/  {gsub(/[^0-9]/,"",$1);r+=$1} END{print r+0}')
writes=$(echo "$CSV" | awk -F',' '/cas_count_write/ {gsub(/[^0-9]/,"",$1);w+=$1} END{print w+0}')
total_bytes=$((64*(reads+writes)))

######################## 6. summary ###########################################
printf "\n--- DRAM traffic (64-B cache-lines) ---\n"
printf "Reads : %'15d lines  (%s)\n" "$reads"  "$(hr_bytes $((64*reads)))"
printf "Writes: %'15d lines  (%s)\n" "$writes" "$(hr_bytes $((64*writes)))"
printf "Total : %s\n"               "$(hr_bytes $total_bytes)"