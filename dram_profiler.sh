#!/usr/bin/env bash
###############################################################################
# dram_profiler.sh
#
# Measure DRAM traffic (64‑byte cache‑line reads & writes) for any command.
#   • Intel server CPUs Skylake → Sapphire‑Rapids.
#   • Needs root   ─or─   /proc/sys/kernel/perf_event_paranoid == 0.
#   • Requires the intel_uncore driver (autoloaded by perf/modprobe).
#
# Example
#   sudo ./dram_profiler.sh ./touch1gb
###############################################################################

set -euo pipefail

#################################### Setup ####################################
# Use sudo only when not already root.
SUDO='' ; ((EUID)) && SUDO=sudo

# Autoload intel_uncore. Ignore failure on non‑Intel CPUs.
$SUDO modprobe intel_uncore 2>/dev/null || true
# A dummy perf run also triggers autoload.
$SUDO perf stat -x, -e cycles -- true 2>/dev/null || true

#################################### Args #####################################
[[ $# -lt 1 ]] && {
    echo "Usage: $(basename "$0") <command> [args]" >&2
    exit 1
}
CMD=( "$@" )

################################### Events ####################################
ALIAS_RD="uncore_imc/cas_count_read/"
ALIAS_WR="uncore_imc/cas_count_write/"
EVENTS="${ALIAS_RD},${ALIAS_WR}"

# Runtime test: can we open the events?
if ! $SUDO perf stat -x, -a -e "$EVENTS" -- true >/dev/null 2>&1; then
    cat >&2 <<EOF
❌  iMC CAS‑COUNT events not usable.
    • intel_uncore driver missing or too old kernel?
    • Non‑Intel CPU?
EOF
    exit 1
fi
echo "🔷 Measuring via events: $EVENTS"

######################## Helpers: pretty‑print bytes ##########################
hr_bytes() {
    local bytes=$1 units=(B KB MB GB TB PB) idx=0
    while (( bytes >= 1024 && idx < ${#units[@]}-1 )); do
        bytes=$((bytes / 1024)); ((idx++))
    done
    awk -vB="$1" -vE="$idx" -vU="${units[$idx]}" \
        'BEGIN { printf "%.2f %s", B/(1024^E), U }'
}

################################## Measure ####################################
CSV=$($SUDO perf stat -x, --no-scale -a -e "$EVENTS" \
      -- "${CMD[@]}" 2>&1 | tee /dev/tty)

############################### Parse results #################################
reads=$( echo "$CSV" | awk -F',' '/cas_count_read/  {
             gsub(/[^0-9]/,"",$1); r+=$1 } END { print r+0 }')
writes=$(echo "$CSV" | awk -F',' '/cas_count_write/ {
             gsub(/[^0-9]/,"",$1); w+=$1 } END { print w+0 }')
total_bytes=$((64 * (reads + writes)))

################################## Summary ####################################
printf "\n--- DRAM traffic (64‑B cache‑lines) ---\n"
printf "Reads : %'15d lines  (%s)\n"  "$reads"  "$(hr_bytes $((64*reads)))"
printf "Writes: %'15d lines  (%s)\n"  "$writes" "$(hr_bytes $((64*writes)))"
printf "Total : %s\n"                 "$(hr_bytes $total_bytes)"