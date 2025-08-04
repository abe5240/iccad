#!/usr/bin/env bash
###############################################################################
# dram_profiler.sh
#
# Measure DRAM traffic (64-byte cache-line reads & writes) for any command.
#   • Works on Intel server CPUs Skylake → Sapphire-Rapids.
#   • Requires root *or* perf_event_paranoid=0.
#   • Needs the intel_uncore driver for the iMC alias events.
#
# Example:
#   sudo ./dram_profiler.sh ./touch1gb
###############################################################################

set -euo pipefail

################################### Helpers ###################################
# Use sudo only if we're not already root.
SUDO='' ; ((EUID)) && SUDO=sudo

# Pretty-print bytes in human-readable units.
hr_bytes() {
    local bytes=$1
    local units=(B KB MB GB TB PB)
    local idx=0
    while (( bytes >= 1024 && idx < ${#units[@]}-1 )); do
        bytes=$((bytes / 1024))
        ((idx++))
    done
    awk -vB="$1" -vE="$idx" -vU="${units[$idx]}" \
        'BEGIN { printf "%.2f %s", B/(1024^E), U }'
}

################################ Arg & driver check ###########################
[[ $# -lt 1 ]] && {
    echo "Usage: $(basename "$0") <command> [args]" >&2
    exit 1
}

# Load intel_uncore if not already present. Ignore failure on non-Intel CPUs.
$SUDO modprobe intel_uncore 2>/dev/null || true
# Fallback: a dummy perf call also autoloads the module.
$SUDO perf stat -x, -e cycles -- true 2>/dev/null || true

################################ Event aliases ################################
ALIAS_RD="uncore_imc/cas_count_read/"
ALIAS_WR="uncore_imc/cas_count_write/"

if ! $SUDO perf list | grep -q "$ALIAS_RD"; then
    cat >&2 <<EOF
❌  iMC CAS-COUNT alias events not available.
    • intel_uncore module failed to load?
    • Non-Intel CPU or very old kernel?
EOF
    exit 1
fi

EVENTS="${ALIAS_RD},${ALIAS_WR}"
echo "🔷 Measuring via events: $EVENTS"

################################ Run perf stat ################################
CMD=( "$@" )
CSV=$($SUDO perf stat -x, --no-scale -a -e "$EVENTS" \
      -- "${CMD[@]}" 2>&1 | tee /dev/tty)

################################ Parse counters ###############################
reads=$( echo "$CSV" | awk -F',' '/cas_count_read/  {
             gsub(/[^0-9]/,"",$1); r+=$1 } END { print r+0 }')

writes=$(echo "$CSV" | awk -F',' '/cas_count_write/ {
             gsub(/[^0-9]/,"",$1); w+=$1 } END { print w+0 }')

total_bytes=$((64 * (reads + writes)))

################################## Summary ####################################
printf "\n--- DRAM traffic (64-B cache-lines) ---\n"
printf "Reads : %'15d lines  (%s)\n"  "$reads"  "$(hr_bytes $((64*reads)))"
printf "Writes: %'15d lines  (%s)\n"  "$writes" "$(hr_bytes $((64*writes)))"
printf "Total : %s\n"                 "$(hr_bytes $total_bytes)"