#!/usr/bin/env bash
# ==============================================================================
# Roofline Metrics (VTune-only)
# - Numerator  : Instructions Retired (uarch-exploration)
# - Denominator: DRAM bytes = (Average DRAM GB/s from memory-access) * elapsed (s) * 1e9
# Fails if VTune is unavailable or any VTune collection/report fails.
# Works on Intel bare metal (e.g., AWS c7i.metal). No perf(1) fallback.
# ==============================================================================

set -Eeuo pipefail
IFS=$'\n\t'
LC_ALL=C

VTUNE_UARCH_DIR="vtune_uarch_results"
VTUNE_MEM_DIR="vtune_memory_results"
OUTPUT_LOG_FILE="roofline_data.log"

[[ $# -ge 1 ]] || { echo "Error: no target specified." >&2; exit 1; }
TARGET=("$@") # preserve quoting

# ---------- helpers ----------
calc() { awk "BEGIN{print ($*)}"; }
cleanup() {
  [[ "${KEEP_RESULTS:-0}" == 1 ]] || rm -rf "$VTUNE_UARCH_DIR" "$VTUNE_MEM_DIR" || true
}
die() { echo "✖ $*" >&2; exit 1; }

# Gate sudo usage: only if passwordless sudo is available (no prompts)
SUDO=""
if command -v sudo >/dev/null 2>&1 && sudo -n true 2>/dev/null; then
  SUDO="sudo -n"
fi

reset_governor() {
  if [[ -n "${CPUPOWER_CMD:-}" && -n "$SUDO" ]]; then
    $SUDO "$CPUPOWER_CMD" -c all frequency-set -g ondemand >/dev/null 2>&1 \
      || $SUDO "$CPUPOWER_CMD"  frequency-set -g ondemand >/dev/null 2>&1 \
      || $SUDO "$CPUPOWER_CMD" -c all frequency-set -g powersave >/dev/null 2>&1 \
      || $SUDO "$CPUPOWER_CMD"  frequency-set -g powersave >/dev/null 2>&1 || true
  fi
}

trap 'reset_governor; cleanup; exit' SIGHUP SIGINT SIGTERM
trap 'cleanup' EXIT

# ---------- fast-fail checks ----------
if command -v lscpu >/dev/null 2>&1 && ! lscpu | grep -q 'GenuineIntel'; then
  die "Non-Intel CPU detected. VTune collectors required here will not run."
fi

# ---------- locate VTune (required) ----------
find_vtune() {
  for cmd in vtune vtune-cl amplxe-cl; do
    command -v "$cmd" >/dev/null 2>&1 && { echo "$cmd"; return; }
  done
}
VTUNE_BIN="$(find_vtune || true)"
if [[ -z "$VTUNE_BIN" ]]; then
  for envfile in \
    "$HOME/intel/oneapi/vtune/latest/env/vars.sh" \
    "$HOME/intel/oneapi/setvars.sh" \
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

# ---------- best-effort counter access (no prompts) ----------
if [[ -n "$SUDO" ]]; then
  $SUDO sysctl -w kernel.perf_event_paranoid=0 >/dev/null 2>&1 || true
  $SUDO sysctl -w kernel.kptr_restrict=0      >/dev/null 2>&1 || true
fi

# Optional CPU governor tweak (best-effort, no prompts)
CPUPOWER_CMD="$(command -v cpupower || true)"
if [[ -n "$CPUPOWER_CMD" && -n "$SUDO" ]]; then
  $SUDO "$CPUPOWER_CMD" -c all frequency-set -g performance >/dev/null 2>&1 \
    || $SUDO "$CPUPOWER_CMD"  frequency-set -g performance >/dev/null 2>&1 || true
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
if [[ $rc_uarch -ne 0 ]]; then
  cat vtune_uarch.err >&2
  die "VTune uarch-exploration failed (rc=$rc_uarch). See logs above."
fi

UARCH_REPORT="$( "$VTUNE_BIN" -report summary -result-dir "$VTUNE_UARCH_DIR" -format text )"

# Robustly parse 'Elapsed Time: ...s' by removing the trailing 's'
ELAPSED_TIME="$(echo "$UARCH_REPORT" | awk '/^Elapsed Time:/ {gsub(/s/,"", $NF); print $NF}')"
[[ "$ELAPSED_TIME" =~ ^[0-9] ]] || die "Failed to parse Elapsed Time from uarch-exploration report."

# Robustly parse 'Instructions Retired: ...' by removing commas
TOTAL_OPS="$(echo "$UARCH_REPORT" | awk '/^Instructions Retired:/ {gsub(/,/,"", $NF); print $NF}')"
[[ "$TOTAL_OPS" =~ ^[0-9] ]] || die "Failed to parse Instructions Retired from uarch-exploration report."

echo "Elapsed Time (s): $ELAPSED_TIME"
echo "Instructions Retired: $TOTAL_OPS"

# ---------------- [RUN 2] memory-access ----------------
echo -e "\n--- [RUN 2/2] VTune: memory-access ---"
set +e
"$VTUNE_BIN" -collect memory-access -result-dir "$VTUNE_MEM_DIR" -- "${TARGET[@]}" \
  > vtune_mem.out 2> vtune_mem.err
rc_mem=$?
set -e
if [[ $rc_mem -ne 0 ]]; then
  cat vtune_mem.err >&2
  die "VTune memory-access failed (rc=$rc_mem). See logs above."
fi

MEM_REPORT="$( "$VTUNE_BIN" -report summary -result-dir "$VTUNE_MEM_DIR" -format text )"

# Precisely parse 'DRAM, GB/sec' table, getting the 5th field (Average)
DRAM_BW_GBS="$(echo "$MEM_REPORT" | awk '/^DRAM, GB\/sec/ {print $5}')"
[[ "$DRAM_BW_GBS" =~ ^[0-9] ]] || die "Failed to parse DRAM Bandwidth (GB/s) from memory-access report."

# Robustly parse 'Elapsed Time: ...s' by removing the trailing 's'
MEM_ELAPSED_TIME="$(echo "$MEM_REPORT" | awk '/^Elapsed Time:/ {gsub(/s/,"", $NF); print $NF}')"
[[ "$MEM_ELAPSED_TIME" =~ ^[0-9] ]] || die "Failed to parse elapsed time from memory-access report."

TOTAL_BYTES="$(printf "%.0f" "$(calc "$DRAM_BW_GBS * $MEM_ELAPSED_TIME * 1e9")")"

# ---------------- Metrics ----------------
GIOPS="$( [[ "$ELAPSED_TIME" == "0" ]] && echo inf \
          || calc "($TOTAL_OPS / $ELAPSED_TIME) / 1e9" )"
ARITHMETIC_INTENSITY="$( [[ "$TOTAL_BYTES" == "0" ]] && echo inf \
                         || calc "$TOTAL_OPS / $TOTAL_BYTES" )"

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