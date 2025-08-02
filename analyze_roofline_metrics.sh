#!/usr/bin/env bash
# ==============================================================================
# Roofline Metrics (VTune-only)
# - Numerator  : Instructions Retired (from uarch-exploration)
# - Denominator: DRAM bytes = (DRAM GB/s from memory-access) * elapsed (s) * 1e9
# Exits non-zero if VTune is unavailable or a collection/report fails.
# ==============================================================================

set -Eeuo pipefail
IFS=$'\n\t'
LC_ALL=C

VTUNE_UARCH_DIR="vtune_uarch_results"
VTUNE_MEM_DIR="vtune_memory_results"
OUTPUT_LOG_FILE="roofline_data.log"

if [[ $# -lt 1 ]]; then
  echo "Error: No target program specified." >&2
  exit 1
fi
TARGET=("$@")  # preserve quoting

# ---------- helpers ----------
calc() { awk "BEGIN{print ($*)}"; }  # float arithmetic
cleanup() {
  [[ "${KEEP_RESULTS:-0}" == 1 ]] || rm -rf "$VTUNE_UARCH_DIR" "$VTUNE_MEM_DIR" || true
}
reset_governor() {
  if [[ -n "${CPUPOWER_CMD:-}" ]]; then
    sudo "$CPUPOWER_CMD" -c all frequency-set -g ondemand >/dev/null 2>&1 \
      || sudo "$CPUPOWER_CMD"  frequency-set -g ondemand >/dev/null 2>&1 \
      || sudo "$CPUPOWER_CMD" -c all frequency-set -g powersave >/dev/null 2>&1 \
      || sudo "$CPUPOWER_CMD"  frequency-set -g powersave >/dev/null 2>&1 || true
  fi
}
die() { echo "✖ $*" >&2; exit 1; }

trap 'reset_governor; cleanup; exit' SIGHUP SIGINT SIGTERM
trap 'cleanup' EXIT

# ---------- locate VTune (required) ----------
find_vtune() {
  for cmd in vtune vtune-cl amplxe-cl; do
    command -v "$cmd" >/dev/null 2>&1 && { echo "$cmd"; return; }
  done
}
VTUNE_BIN="$(find_vtune || true)"
if [[ -z "$VTUNE_BIN" ]]; then
  HOME_DIR=$(getent passwd "${SUDO_USER:-$USER}" | cut -d: -f6)
  for envfile in \
    "$HOME_DIR/intel/oneapi/vtune/latest/env/vars.sh" \
    "$HOME_DIR/intel/oneapi/setvars.sh" \
    "/opt/intel/oneapi/vtune/latest/env/vars.sh" \
    "/opt/intel/oneapi/setvars.sh"
  do
    [[ -f "$envfile" ]] && { # shellcheck disable=SC1090
      source "$envfile" >/dev/null 2>&1 || true
    }
  done
  VTUNE_BIN="$(find_vtune || true)"
fi
[[ -n "$VTUNE_BIN" ]] || die "VTune CLI not found. Install intel-oneapi-vtune."

# ---------- optional CPU governor tweak (best-effort) ----------
CPUPOWER_CMD="$(command -v cpupower || true)"
if [[ -n "$CPUPOWER_CMD" ]]; then
  sudo -v || true
  sudo "$CPUPOWER_CMD" -c all frequency-set -g performance >/dev/null 2>&1 \
    || sudo "$CPUPOWER_CMD"  frequency-set -g performance >/dev/null 2>&1 || true
fi

echo "======================================================================"
echo "           Generating Roofline Data for: ${TARGET[*]}"
echo "======================================================================"

rm -rf "$VTUNE_UARCH_DIR" "$VTUNE_MEM_DIR" "$OUTPUT_LOG_FILE"

# ---------------- [RUN 1] uarch-exploration ----------------
echo -e "\n--- [RUN 1/2] VTune: uarch-exploration ---"
set +e
"$VTUNE_BIN" -collect uarch-exploration -result-dir "$VTUNE_UARCH_DIR" -- "${TARGET[@]}" \
  > vtune_uarch.out 2> vtune_uarch.err
rc_uarch=$?
set -e
[[ $rc_uarch -eq 0 ]] || die "VTune uarch-exploration failed (rc=$rc_uarch). See vtune_uarch.err"

# Elapsed time (seconds)
ELAPSED_TIME="$(
  "$VTUNE_BIN" -report summary -result-dir "$VTUNE_UARCH_DIR" -format text \
  | awk '/Elapsed Time/ {for(i=1;i<=NF;i++) if ($i ~ /^[0-9.]+$/){print $i; exit}}'
)"
[[ -n "$ELAPSED_TIME" ]] || die "Failed to parse Elapsed Time from uarch-exploration report."

# Instructions Retired (total)
TOTAL_OPS="$(
  "$VTUNE_BIN" -report summary -result-dir "$VTUNE_UARCH_DIR" \
    -format csv -csv-delimiter=, \
  | awk -F, 'BEGIN{IGNORECASE=1}
             /Instructions Retired/ {gsub(/"/,"",$2); gsub(/,/,"",$2); v=$2}
             END{if (v=="") v=0; print v}'
)"
[[ "$TOTAL_OPS" != "0" ]] || TOTAL_OPS="$(
  "$VTUNE_BIN" -report summary -result-dir "$VTUNE_UARCH_DIR" -format text \
  | awk 'BEGIN{IGNORECASE=1}
         /Instructions Retired/ {for(i=1;i<=NF;i++) if ($i ~ /^[0-9.,]+$/){gsub(/,/,"",$i); print $i; exit}}'
)"
[[ -n "$TOTAL_OPS" && "$TOTAL_OPS" != "0" ]] || die "Failed to obtain Instructions Retired."

echo "Elapsed Time (s): $ELAPSED_TIME"
echo "Instructions Retired: $TOTAL_OPS"

# ---------------- [RUN 2] memory-access ----------------
echo -e "\n--- [RUN 2/2] VTune: memory-access ---"
set +e
"$VTUNE_BIN" -collect memory-access -result-dir "$VTUNE_MEM_DIR" -- "${TARGET[@]}" \
  > vtune_mem.out 2> vtune_mem.err
rc_mem=$?
set -e
[[ $rc_mem -eq 0 ]] || die "VTune memory-access failed (rc=$rc_mem). See vtune_mem.err"

# DRAM GB/s and elapsed time for memory-access run
DRAM_BW_GBS="$(
  "$VTUNE_BIN" -report summary -result-dir "$VTUNE_MEM_DIR" -format text \
  | awk 'BEGIN{IGNORECASE=1}
         /DRAM Bandwidth/ {for(i=1;i<=NF;i++) if ($i ~ /^[0-9.]+$/){print $i; exit}}'
)"
[[ -n "$DRAM_BW_GBS" ]] || die "Failed to parse DRAM Bandwidth (GB/s)."

MEM_ELAPSED_TIME="$(
  "$VTUNE_BIN" -report summary -result-dir "$VTUNE_MEM_DIR" -format text \
  | awk '/Elapsed Time/ {for(i=1;i<=NF;i++) if ($i ~ /^[0-9.]+$/){print $i; exit}}'
)"
[[ -n "$MEM_ELAPSED_TIME" ]] || die "Failed to parse Elapsed Time for memory-access."

TOTAL_BYTES="$(printf "%.0f" "$(calc "$DRAM_BW_GBS * $MEM_ELAPSED_TIME * 1e9")")"

# ---------------- Metrics ----------------
if [[ "$ELAPSED_TIME" == "0" ]]; then
  GIOPS="inf"
else
  GIOPS="$(calc "($TOTAL_OPS / $ELAPSED_TIME) / 1e9")"
fi

if [[ "$TOTAL_BYTES" == "0" ]]; then
  ARITHMETIC_INTENSITY="inf"
else
  ARITHMETIC_INTENSITY="$(calc "$TOTAL_OPS / $TOTAL_BYTES")"
fi

# ---------------- Output ----------------
{
  echo "================================================="
  echo "       Roofline Plot Data Point (VTune-only)"
  echo "================================================="
  echo "Target Program:             ${TARGET[*]}"
  echo "Elapsed Time (s):           $ELAPSED_TIME"
  echo ""
  echo "--- NUMERATOR (Compute) ---"
  echo "Instructions Retired:       $TOTAL_OPS"
  echo "Source (Compute):           VTune uarch-exploration"
  echo ""
  echo "--- DENOMINATOR (Memory) ---"
  echo "Total DRAM Bytes:           $TOTAL_BYTES"
  echo "DRAM Bandwidth (GB/s):      $DRAM_BW_GBS"
  echo "Elapsed (memory-access) s:  $MEM_ELAPSED_TIME"
  echo "Source (Memory):            VTune memory-access"
  echo ""
  echo "--- ROOFLINE METRICS ---"
  echo "Attained GIOPS (Y-Axis):    $GIOPS"
  echo "Arithmetic Intensity (X):   $ARITHMETIC_INTENSITY (Ops/Byte)"
  echo "================================================="
} | tee "$OUTPUT_LOG_FILE"

echo -e "\nAnalysis complete. Data saved to '$OUTPUT_LOG_FILE'"