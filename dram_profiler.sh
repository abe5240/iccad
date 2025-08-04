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

# Try running a quick perf stat to see if the events work
# This is more reliable than parsing perf list output
if ! sudo perf stat -x, --no-scale -a -e "${ALIAS_RD},${ALIAS_WR}" -- sleep 0.001 2>&1 | grep -q "cas_count"; then
    # Fallback: check if perf list shows the events (with more flexible matching)
    if ! sudo perf list 2>/dev/null | grep -E "(cas_count_read|cas_count_write)" >/dev/null; then
        cat >&2 <<EOF
❌  iMC CAS-COUNT alias events not available.
    • Is the intel_uncore driver loaded?
    • Are you running this script with sudo *or* perf_event_paranoid=0?
EOF
        exit 1
    fi
fi

EVENTS="${ALIAS_RD},${ALIAS_WR}"
echo "🔷 Measuring via events: $EVENTS"

######################## 4. run perf stat (CSV) ################################
# Run perf stat and capture both stdout and stderr
TMPFILE=$(mktemp)
sudo perf stat -x, --no-scale -a -e "$EVENTS" -- "${CMD[@]}" 2>"$TMPFILE"
CSV=$(cat "$TMPFILE")
rm -f "$TMPFILE"

######################## 5. parse counts #######################################
# More robust parsing that handles different output formats
reads=$( echo "$CSV" | grep -i "cas_count_read" | head -1 | cut -d',' -f1 | tr -cd '0-9')
writes=$(echo "$CSV" | grep -i "cas_count_write" | head -1 | cut -d',' -f1 | tr -cd '0-9')

# Default to 0 if parsing fails
reads=${reads:-0}
writes=${writes:-0}

total_bytes=$((64*(reads+writes)))

######################## 6. summary ###########################################
printf "\n--- DRAM traffic (64-B cache-lines) ---\n"
printf "Reads : %'15d lines  (%s)\n" "$reads"  "$(hr_bytes $((64*reads)))"
printf "Writes: %'15d lines  (%s)\n" "$writes" "$(hr_bytes $((64*writes)))"
printf "Total : %s\n"               "$(hr_bytes $total_bytes)"