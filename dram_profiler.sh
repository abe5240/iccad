#!/usr/bin/env bash
###############################################################################
# dram_profiler.sh
#
# Measure DRAM traffic (reads / writes) for any command on Intel server CPUs.
#
#  • Counts iMC CAS-COUNT lines (64-byte cache-line transfers).
#  • Handles both reads and writes; totals are reported in bytes.
#  • Prints a human-friendly summary as well as raw line counts.
#
# REQUIREMENTS
#  • Run as root   ──OR──   set /proc/sys/kernel/perf_event_paranoid ≤ 0
#  • intel_uncore driver loaded (visible via `perf list`).
#
# EXAMPLE
#   sudo ./dram_profiler.sh ./my_program --arg1 foo
#
###############################################################################
set -euo pipefail

#######################################
# Helper: print human-readable byte sizes
# Globals:  none
# Arguments:
#   $1 – integer #bytes
#######################################
hr_bytes() {
    local b=$1 units=(B KB MB GB TB PB) idx=0
    while (( b >= 1024 && idx < ${#units[@]}-1 )); do
        b=$(( b / 1024 ))
        (( idx++ ))
    done
    # original bytes still in $1
    awk -vB="$1" -vE="$idx" -vU="${units[$idx]}" \
        'BEGIN{printf("%.2f %s",B/(1024^E),U)}'
}

#######################################
# Abort if no command supplied
#######################################
[[ $# -lt 1 ]] && {
    echo "Usage: $(basename "$0") <command> [-- <args>...]" >&2
    exit 1
}
CMD=( "$@" )

#######################################
# Verify CAS-COUNT alias events exist
#######################################
ALIAS_RD='uncore_imc/cas_count_read/'
ALIAS_WR='uncore_imc/cas_count_write/'

if ! sudo perf list 2>/dev/null | grep -q "$ALIAS_RD"; then
    cat >&2 <<EOF
❌  iMC CAS-COUNT alias events not available.
    • Is the intel_uncore driver loaded?
    • Are you running with sufficient privilege?
      (run script via sudo or set perf_event_paranoid to 0)
EOF
    exit 1
fi
EVENTS="${ALIAS_RD},${ALIAS_WR}"
echo "🔷 Measuring via events: $EVENTS"

#######################################
# Run perf stat (CSV mode) and capture output
#######################################
PERF_CSV=$(sudo perf stat -x, --no-scale -a -e "$EVENTS" -- "${CMD[@]}" \
           2>&1 | tee /dev/tty)

#######################################
# Parse raw line counts from CSV
#######################################
reads=$( echo "$PERF_CSV"  \
         | awk -F',' '/cas_count_read/  {gsub(/[^0-9]/,"",$1);r+=$1} END{print r+0}')
writes=$(echo "$PERF_CSV"  \
         | awk -F',' '/cas_count_write/ {gsub(/[^0-9]/,"",$1);w+=$1} END{print w+0}')
total_bytes=$(( 64 * (reads + writes) ))

#######################################
# Report
#######################################
printf "\n--- DRAM traffic (64-byte cache-lines) ---\n"
printf "Reads : %'15d lines  (%s)\n" "$reads"  "$(hr_bytes $((64*reads)))"
printf "Writes: %'15d lines  (%s)\n" "$writes" "$(hr_bytes $((64*writes)))"
printf "Total : %s\n"                 "$(hr_bytes $total_bytes)"