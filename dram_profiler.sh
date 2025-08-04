#!/usr/bin/env bash
###############################################################################
# dram_profiler.sh  –  DRAM traffic (64-B lines) for any command
###############################################################################
set -euo pipefail
[[ $# -lt 1 ]] && { echo "Usage: $(basename "$0") <program> [-- <args>...]"; exit 1; }
CMD=("$@")

# ---------- pretty-print bytes ----------------------------------------------
hr_bytes() { local b=$1; local u=(B KB MB GB TB PB) i=0
             while (( b>=1024 && i<${#u[@]}-1 )); do b=$((b/1024)); ((i++)); done
             awk -vB="$1" -vE="$i" -vU="${u[$i]}" 'BEGIN{printf "%.2f %s",B/(1024^E),U}'; }

# ---------- build event list -------------------------------------------------
alias_rd="uncore_imc/cas_count_read/"
alias_wr="uncore_imc/cas_count_write/"
alias_wrpre="uncore_imc/cas_count_write_pre/"

if perf list | grep -q "$alias_rd"; then        # alias path (easy)
    EVENTS="$alias_rd,$alias_wr"
    if perf list | grep -q "$alias_wrpre"; then
        EVENTS+=",${alias_wrpre}"
    fi
else                                            # explicit IMC instances
    EVENTS=""
    for i in {0..7}; do
        for suff in RD WR WR_PRE; do
            ev="uncore_imc_${i}/UNC_M_CAS_COUNT.${suff}/"
            perf list | grep -q "$ev" && EVENTS+="$ev,"
        done
    done
    EVENTS=${EVENTS%,}   # strip trailing comma
fi

[[ -z "$EVENTS" ]] && { echo "No iMC CAS_COUNT events available"; exit 1; }
echo "🔷 Collecting via: $EVENTS"

# ---------- run perf ---------------------------------------------------------
OUT=$(sudo perf stat -x, --no-scale -a -e "$EVENTS" -- "${CMD[@]}" 2>&1 | tee /dev/tty)

# ---------- parse counts -----------------------------------------------------
reads=$(echo "$OUT"  | awk -F',' '/CAS_COUNT.*(RD|read)/  {gsub(/[^0-9]/,"",$1);s+=$1} END{print s+0}')
writes=$(echo "$OUT" | awk -F',' '/CAS_COUNT.*(WR|write)/ {gsub(/[^0-9]/,"",$1);s+=$1} END{print s+0}')
bytes=$((64*(reads+writes)))

printf "\n--- DRAM traffic ---\n"
printf "Reads : %'d lines (%s)\n"  "$reads"  "$(hr_bytes $((64*reads)))"
printf "Writes: %'d lines (%s)\n"  "$writes" "$(hr_bytes $((64*writes)))"
printf "Total : %s\n"              "$(hr_bytes $bytes)"