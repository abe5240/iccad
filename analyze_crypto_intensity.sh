#!/usr/bin/env bash
# ==============================================================================
# Crypto Arithmetic Intensity Analyzer (VTune)
#
# This script calculates a specialized Arithmetic Intensity for crypto workloads.
# It uses two VTune runs:
#  1. uarch-exploration: To get Total Instructions and estimate the number of
#     integer-related operations (Integer, CISC, etc.).
#  2. memory-access: To get the total DRAM memory traffic.
#
# The final metric is: Estimated Integer Ops / Total DRAM Bytes
# ==============================================================================

set -Eeuo pipefail
IFS=$'\n\t'
LC_ALL=C

# --- Sanity Checks ---
if [[ "$#" -lt 1 ]]; then
  echo "Error: No target executable specified." >&2
  exit 1
fi
if ! command -v vtune &> /dev/null; then
    echo "Error: 'vtune' command not found. Has install_deps.sh been run and the shell restarted?" >&2
    exit 1
fi

TARGET_CMD=("$@")
VTUNE_UARCH_DIR="vtune_uarch_results"
VTUNE_MEM_DIR="vtune_memory_results"
OUTPUT_LOG_FILE="crypto_intensity.log"

# --- Helper Functions ---
cleanup() {
  rm -rf "$VTUNE_UARCH_DIR" "$VTUNE_MEM_DIR" vtune_*.log || true
}
calc() {
  awk "BEGIN{print ($*)}";
}

trap cleanup EXIT

# --- Step 1: Microarchitecture Analysis (for Operation Count) ---
echo "--- [1/2] Running Microarchitecture Analysis to estimate Integer Operations ---"
vtune -collect uarch-exploration -result-dir "$VTUNE_UARCH_DIR" -- "${TARGET_CMD[@]}" > vtune_uarch.log 2>&1

UARCH_REPORT=$(vtune -report summary -result-dir "$VTUNE_UARCH_DIR")

# --- Parse the Uarch Report ---
TOTAL_RETIRED=$(echo "$UARCH_REPORT" | awk '/Instructions Retired:/ {gsub(/,/,"", $NF); print $NF; exit}')

# Estimate integer-related ops by summing the pipeline slot percentages for relevant categories.
# This is an approximation, but it's much more accurate than using the total instructions.
P_INTEGER=$(echo "$UARCH_REPORT"    | awk '/Integer Operations:/ {print $NF; exit}' | sed 's/%//')
P_HEAVY_UOPS=$(echo "$UARCH_REPORT" | awk '/Few Uops Instructions:/ {print $NF; exit}' | sed 's/%//')
P_CISC=$(echo "$UARCH_REPORT"       | awk '/CISC:/ {print $NF; exit}' | sed 's/%//')

# Fallback to 0 if a metric isn't found
[[ -z "$P_INTEGER" ]] && P_INTEGER=0
[[ -z "$P_HEAVY_UOPS" ]] && P_HEAVY_UOPS=0
[[ -z "$P_CISC" ]] && P_CISC=0

TOTAL_INT_PERCENT=$(calc "$P_INTEGER + $P_HEAVY_UOPS + $P_CISC")
ESTIMATED_INTEGER_OPS=$(printf "%.0f" "$(calc "$TOTAL_RETIRED * ($TOTAL_INT_PERCENT / 100)")")

echo "  > Total Instructions Retired: $TOTAL_RETIRED"
echo "  > Estimated Integer-Related Pipeline Percentage: $TOTAL_INT_PERCENT %"
echo "  > Estimated Integer Operations: $ESTIMATED_INTEGER_OPS"

# --- Step 2: Memory Access Analysis (for Data Traffic) ---
echo "--- [2/2] Running Memory Access Analysis for DRAM Traffic ---"
vtune -collect memory-access -result-dir "$VTUNE_MEM_DIR" -- "${TARGET_CMD[@]}" > vtune_mem.log 2>&1

MEM_REPORT=$(vtune -report summary -result-dir "$VTUNE_MEM_DIR")

# --- Parse the Memory Report ---
DRAM_BW_GBS=$(echo "$MEM_REPORT" | awk '/^DRAM, GB\/sec/ {print $5; exit}')
MEM_ELAPSED=$(echo "$MEM_REPORT" | awk '/Elapsed Time:/ {gsub(/s/,"", $NF); print $NF; exit}')
TOTAL_DRAM_BYTES=$(printf "%.0f" "$(calc "$DRAM_BW_GBS * $MEM_ELAPSED * 1e9")")

echo "  > Average DRAM Bandwidth: $DRAM_BW_GBS GB/s"
echo "  > Total DRAM Bytes Transferred: $TOTAL_DRAM_BYTES"

# --- Step 3: Calculate and Display Final Intensity ---
echo "--- Final Results ---"
ARITHMETIC_INTENSITY="0"
if (( $(echo "$TOTAL_DRAM_BYTES > 0" | bc -l) )); then
  ARITHMETIC_INTENSITY=$(calc "$ESTIMATED_INTEGER_OPS / $TOTAL_DRAM_BYTES")
fi

# --- Output to both screen and log file ---
{
  echo "================================================="
  echo "    Crypto Arithmetic Intensity (VTune-based)"
  echo "================================================="
  echo "Target Program:             ${TARGET_CMD[*]}"
  echo ""
  echo "--- NUMERATOR (Estimated Integer Compute) ---"
  echo "Total Instructions Retired: $TOTAL_RETIRED"
  echo "Integer Ops % (Estimate):   $TOTAL_INT_PERCENT %"
  echo "Estimated Integer Ops:      $ESTIMATED_INTEGER_OPS"
  echo "Method: Sum of pipeline slot % for Integer Ops,"
  echo "        Few Uops Instructions, and CISC from TMA."
  echo ""
  echo "--- DENOMINATOR (Memory Traffic) ---"
  echo "Total DRAM Bytes:           $TOTAL_DRAM_BYTES"
  echo ""
  echo "--- CRYPTO ARITHMETIC INTENSITY ---"
  echo "Intensity (Est. Int Ops/Byte): $ARITHMETIC_INTENSITY"
  echo "================================================="
} | tee "$OUTPUT_LOG_FILE"