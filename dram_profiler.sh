#!/usr/bin/env bash
###############################################################################
# dram_profiler.sh
#
# Measure DRAM traffic (iMC CAS-COUNT read & write lines) for any command.
#   * Works on Intel server CPUs (Skylake → Sapphire-Rapids).
#   * Counts 64-byte cache-line transfers; prints human-readable bytes.
#
# REQUIREMENTS
#   • Run the script with sudo   ──OR──   set /proc/sys/kernel/perf_event_paranoid=0
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

EVENTS="${ALIAS_RD},${ALIAS_WR}"
echo "🔷 Measuring via events: $EVENTS"

######################## 4. run perf stat (CSV) ################################
# Run perf stat and capture stderr where CSV output goes
CSV=$(sudo perf stat -x, --no-scale -a -e "$EVENTS" -- "${CMD[@]}" 2>&1 1>/dev/null)
echo "$CSV"

######################## 5. parse counts with proper unit handling #############
# Parse CSV format: value,unit,event,...
# Extract reads
read_line=$(echo "$CSV" | grep -i "cas_count_read" | head -1)
read_value=$(echo "$read_line" | cut -d',' -f1)
read_unit=$(echo "$read_line" | cut -d',' -f2)

# Extract writes  
write_line=$(echo "$CSV" | grep -i "cas_count_write" | head -1)
write_value=$(echo "$write_line" | cut -d',' -f1)
write_unit=$(echo "$write_line" | cut -d',' -f2)

# Convert values to bytes based on unit
convert_to_bytes() {
    local value=$1
    local unit=$2
    # Convert decimal to integer for bash arithmetic
    local int_val=$(echo "$value" | awk '{printf "%.0f", $1}')
    
    case "$unit" in
        "MiB") echo $((int_val * 1048576)) ;;
        "GiB") echo $((int_val * 1073741824)) ;;
        "KiB") echo $((int_val * 1024)) ;;
        "B"|"") echo "$int_val" ;;
        *) echo $((int_val * 64)) ;;  # Assume raw count of cache lines
    esac
}

read_bytes=$(convert_to_bytes "$read_value" "$read_unit")
write_bytes=$(convert_to_bytes "$write_value" "$write_unit")

# Calculate cache lines
read_lines=$((read_bytes / 64))
write_lines=$((write_bytes / 64))
total_bytes=$((read_bytes + write_bytes))

######################## 6. summary ###########################################
printf "\n--- DRAM traffic (64-B cache-lines) ---\n"
printf "Reads : %'15d lines  (%s)\n" "$read_lines"  "$(hr_bytes $read_bytes)"
printf "Writes: %'15d lines  (%s)\n"