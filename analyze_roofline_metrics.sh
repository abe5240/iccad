#!/usr/bin/env bash
# Roofline Metrics (integer ops + DRAM bytes) via VTune

VTUNE_UARCH_DIR="vtune_uarch_results"
VTUNE_MEM_DIR="vtune_memory_results"
OUTPUT_LOG_FILE="roofline_data.log"

set -Eeuo pipefail
IFS=$'\n\t'

if [ "$#" -lt 1 ]; then
  echo "Error: No target program specified." >&2
  exit 1
fi
TARGET_PROGRAM="$@"

find_vtune() {
  for cmd in vtune vtune-cl amplxe-cl; do
    command -v "$cmd" >/dev/null 2>&1 && { echo "$cmd"; return; }
  done
}
VTUNE_BIN="$(find_vtune || true)"
if [ -z "$VTUNE_BIN" ]; then
  HOME_DIR=$(getent passwd "${SUDO_USER:-$USER}" | cut -d: -f6)
  for envfile in \
    "$HOME_DIR/intel/oneapi/vtune/latest/env/vars.sh" \
    "$HOME_DIR/intel/oneapi/setvars.sh" \
    "/opt/intel/oneapi/vtune/latest/env/vars.sh" \
    "/opt/intel/oneapi/setvars.sh"
  do
    [ -f "$envfile" ] && { # shellcheck disable=SC1090
      source "$envfile" >/dev/null 2>&1 || true
    }
  done
  VTUNE_BIN="$(find_vtune || true)"
fi
[ -n "$VTUNE_BIN" ] || { echo "Error: vtune CLI not found."; exit 1; }

cleanup() { rm -rf "$VTUNE_UARCH_DIR" "$VTUNE_MEM_DIR" || true; }
reset_governor() {
  if [ -n "${CPUPOWER_CMD:-}" ]; then
    sudo "$CPUPOWER_CMD" -c all frequency-set -g ondemand >/dev/null 2>&1 \
      || sudo "$CPUPOWER_CMD" frequency-set -g ondemand >/dev/null 2>&1 \
      || sudo "$CPUPOWER_CMD" -c all frequency-set -g powersave >/dev/null 2>&1 \
      || sudo "$CPUPOWER_CMD" frequency-set -g powersave >/dev/null 2>&1 || true
  fi
}
trap 'reset_governor; cleanup; exit' SIGHUP SIGINT SIGTERM
trap 'cleanup' EXIT

CPUPOWER_CMD="$(command -v cpupower || true)"
if [ -n "$CPUPOWER_CMD" ]; then
  sudo -v || true
  sudo "$CPUPOWER_CMD" -c all frequency-set -g performance >/dev/null 2>&1 \
    || sudo "$CPUPOWER_CMD" frequency-set -g performance >/dev/null 2>&1 || true
fi

echo "======================================================================"
echo "           Generating Roofline Data for: $TARGET_PROGRAM"
echo "======================================================================"

rm -rf "$VTUNE_UARCH_DIR" "$VTUNE_MEM_DIR" "$OUTPUT_LOG_FILE"

echo -e "\n--- [RUN 1/2] Analyzing CPU core for Integer Operations ---"
echo -n "Running VTune collection (uarch-exploration)... "
"$VTUNE_BIN" -collect uarch-exploration -result-dir "$VTUNE_UARCH_DIR" -- "$@" \
  >/dev/null 2>&1
echo "done."

echo -n "Parsing instruction report... "
INSTR_LIST="ADD|ADC|SUB|SBB|IMUL|MUL"
TOTAL_OPS=$(
  "$VTUNE_BIN" -report summary -result-dir "$VTUNE_UARCH_DIR" \
    -format csv -csv-delimiter=, \
  | grep -E "$INSTR_LIST" | cut -d, -f2 | tr -d '"' \
  | awk '{s+=$1} END{print (s=="")?0:s}'
)
ELAPSED_TIME=$(
  "$VTUNE_BIN" -report summary -result-dir "$VTUNE_UARCH_DIR" -format text \
  | awk '/Elapsed Time/ {print $3; exit}'
)
ELAPSED_TIME=${ELAPSED_TIME:-0}
echo "done."

echo -e "\n--- [RUN 2/2] Analyzing Memory Subsystem for DRAM Traffic ---"
echo -n "Running VTune collection (memory-access)... "
"$VTUNE_BIN" -collect memory-access -result-dir "$VTUNE_MEM_DIR" -- "$@" \
  >/dev/null 2>&1
echo "done."

echo -n "Parsing memory report... "
DRAM_BW_LINE=$(
  "$VTUNE_BIN" -report summary -result-dir "$VTUNE_MEM_DIR" -format text \
  | grep -m1 "DRAM Bandwidth" || true
)
DRAM_BANDWIDTH_GB_S=$(awk 'match($0,/([0-9]*\.[0-9]+|[0-9]+)/,a){print a[1]}' \
  <<<"$DRAM_BW_LINE")
DRAM_BANDWIDTH_GB_S=${DRAM_BANDWIDTH_GB_S:-0}
MEM_ELAPSED_TIME=$(
  "$VTUNE_BIN" -report summary -result-dir "$VTUNE_MEM_DIR" -format text \
  | awk '/Elapsed Time/ {print $3; exit}'
)
MEM_ELAPSED_TIME=${MEM_ELAPSED_TIME:-0}
TOTAL_BYTES=$(echo "$DRAM_BANDWIDTH_GB_S * $MEM_ELAPSED_TIME * 1e9" \
  | bc -l | cut -d. -f1)
TOTAL_BYTES=${TOTAL_BYTES:-0}
echo "done."

echo -e "\n--- [COMPLETE] Calculating Final Metrics ---"
if (( $(echo "$TOTAL_BYTES == 0" | bc -l) )); then
  ARITHMETIC_INTENSITY="inf"
else
  ARITHMETIC_INTENSITY=$(echo "scale=4; $TOTAL_OPS / $TOTAL_BYTES" | bc -l)
fi
if (( $(echo "$ELAPSED_TIME == 0" | bc -l) )); then
  GIOPS="inf"
else
  GIOPS=$(echo "scale=4; ($TOTAL_OPS / $ELAPSED_TIME) / 1e9" | bc -l)
fi

{
  echo "================================================="
  echo "       Roofline Plot Data Point"
  echo "================================================="
  echo "Target Program:       $TARGET_PROGRAM"
  echo "Elapsed Time (s):     $ELAPSED_TIME"
  echo ""
  echo "--- NUMERATOR (Compute) ---"
  echo "Total Integer Ops:    $TOTAL_OPS"
  echo ""
  echo "--- DENOMINATOR (Memory) ---"
  echo "Total DRAM Bytes:     $TOTAL_BYTES"
  echo ""
  echo "--- ROOFLINE METRICS ---"
  echo "Attained GIOPS (Y-Axis):  $GIOPS"
  echo "Arithmetic Intensity (X-Axis): $ARITHMETIC_INTENSITY (Ops/Byte)"
  echo "================================================="
} | tee "$OUTPUT_LOG_FILE"

if [ -n "$CPUPOWER_CMD" ]; then
  echo -e "\nResetting CPU governor to 'ondemand' mode..."
  sudo "$CPUPOWER_CMD" frequency-set -g ondemand >/dev/null 2>&1 \
    || sudo "$CPUPOWER_CMD" -c all frequency-set -g ondemand >/dev/null 2>&1 \
    || true
fi
rm -rf "$VTUNE_UARCH_DIR" "$VTUNE_MEM_DIR"
echo -e "\nAnalysis complete. All data saved to '$OUTPUT_LOG_FILE'"