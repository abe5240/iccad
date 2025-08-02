#!/usr/bin/env bash
# ==============================================================================
# FILE: analyze_crypto_intensity.sh
# PURPOSE: Compute a crypto-leaning "Arithmetic Intensity" using VTune.
#
#   Numerator  ~ Estimated Integer-like Operations
#   Denominator: Total DRAM bytes (from memory-access)
#
# Notes:
#   * Uses VTune CSV reports to avoid brittle label matching.
#   * Integer-like share defaults to the "Useful Work" pipeline percentage
#     (portable). You can experiment with ENABLE_HW_EVENTS=1 to refine using
#     event counters if available (guarded/optional).
#
# Usage:
#   ./analyze_crypto_intensity.sh /path/to/exe [args...]
#
# Env vars:
#   VTUNE_UARCH_DIR   (default: vtune_uarch_results)
#   VTUNE_MEM_DIR     (default: vtune_memory_results)
#   OUTPUT_LOG_FILE   (default: crypto_intensity.log)
#   KEEP_RESULTS      (default: 1; set 0 to auto-clean results on exit)
#   ENABLE_HW_EVENTS  (default: 0; experimental refinement if supported)
# ==============================================================================

set -Eeuo pipefail
IFS=$'\n\t'
LC_ALL=C

# ---- Config / Defaults -------------------------------------------------------
VTUNE_UARCH_DIR="${VTUNE_UARCH_DIR:-vtune_uarch_results}"
VTUNE_MEM_DIR="${VTUNE_MEM_DIR:-vtune_memory_results}"
OUTPUT_LOG_FILE="${OUTPUT_LOG_FILE:-crypto_intensity.log}"
KEEP_RESULTS="${KEEP_RESULTS:-1}"
ENABLE_HW_EVENTS="${ENABLE_HW_EVENTS:-0}"

# ---- Sanity ------------------------------------------------------------------
if [[ "$#" -lt 1 ]]; then
  echo "Error: No target executable specified." >&2
  echo "Usage: $0 /path/to/executable [args...]" >&2
  exit 1
fi
if ! command -v vtune &>/dev/null; then
  echo "Error: 'vtune' not found. Run ./install_deps.sh and re-open your shell." >&2
  exit 1
fi

TARGET_CMD=("$@")

# ---- Helpers -----------------------------------------------------------------
cleanup() {
  if [[ "${KEEP_RESULTS}" -eq 0 ]]; then
    rm -rf "$VTUNE_UARCH_DIR" "$VTUNE_MEM_DIR" vtune_*.log || true
  fi
}
trap cleanup EXIT

calc() { awk "BEGIN{print ($*)}"; }

# Extract last numeric-looking field from rows whose first col matches regex
# Expects VTune CSV (with quotes). Case-insensitive match on the first column.
#   $1: CSV blob
#   $2: regex to match the metric/header (first cell)
csv_get_val_lastnum_firstcol_match() {
  local csv_blob="$1" re="$2"
  echo "$csv_blob" | awk -F',' -v IGNORECASE=1 -v re="$re" '
    {
      # strip quotes from first field for matching
      f1=$1; gsub(/"/,"",f1)
      if (f1 ~ re) {
        # find last numeric field
        for (i=NF; i>=1; --i) {
          v=$i; gsub(/"/,"",v)
          if (v ~ /^-?[0-9.]+([eE][-+]?[0-9]+)?$/) { print v; exit }
        }
      }
    }'
}

# ---- Step 1: Microarchitecture (uarch-exploration) ---------------------------
echo "--- [1/3] Microarchitecture analysis (uarch-exploration) ---"
rm -rf "$VTUNE_UARCH_DIR" || true
vtune -collect uarch-exploration -result-dir "$VTUNE_UARCH_DIR" -- "${TARGET_CMD[@]}" \
  > vtune_uarch.log 2>&1 || {
    echo "Error: VTune uarch-exploration failed. See vtune_uarch.log" >&2
    exit 1
  }

UARCH_CSV="$(vtune -report summary -result-dir "$VTUNE_UARCH_DIR" -format csv -csv-delimiter ',' || true)"

# Total retired instructions (stable label in CSV)
TOTAL_RETIRED="$(csv_get_val_lastnum_firstcol_match "$UARCH_CSV" "^Instructions[[:space:]]*Retired")"
[[ -z "$TOTAL_RETIRED" ]] && TOTAL_RETIRED=0

# Integer-ish share proxy: "Useful Work" (% of pipeline slots)
P_USEFUL="$(csv_get_val_lastnum_firstcol_match "$UARCH_CSV" "^Useful[[:space:]]*Work")"
[[ -z "$P_USEFUL" ]] && P_USEFUL=0

TOTAL_INT_PERCENT="$P_USEFUL"
ESTIMATED_INTEGER_OPS="$(awk "BEGIN{printf \"%.0f\", ($TOTAL_RETIRED * ($TOTAL_INT_PERCENT/100.0))}")"

echo "  > Total Instructions Retired: $TOTAL_RETIRED"
echo "  > Useful Work % (proxy for integer-ish compute): $TOTAL_INT_PERCENT"
echo "  > Estimated Integer-like Operations: $ESTIMATED_INTEGER_OPS"

# ---- Optional refinement via HW events (experimental) ------------------------
if [[ "$ENABLE_HW_EVENTS" -eq 1 ]]; then
  echo "--- [1b/3] HW events refinement (experimental) ---"
  VTUNE_HW_DIR="vtune_hw_results"
  rm -rf "$VTUNE_HW_DIR" || true
  # If this fails or events are unavailable, we silently keep the proxy.
  if vtune -collect hw-events -result-dir "$VTUNE_HW_DIR" -- "${TARGET_CMD[@]}" \
        > vtune_hw.log 2>&1; then
    # Some VTune versions expose counters via CSV "summary" or "raw".
    # Try both, ignore failures; keep proxy if not present.
    if HW_CSV="$(vtune -report summary -result-dir "$VTUNE_HW_DIR" -format csv -csv-delimiter ',' 2>/dev/null)"; then
      :
    elif HW_CSV="$(vtune -report raw -result-dir "$VTUNE_HW_DIR" -format csv -csv-delimiter ',' 2>/dev/null)"; then
      :
    else
      HW_CSV=""
    fi

    # Try to retrieve totals if present (names vary, so keep it best-effort).
    # Look for INST_RETIRED.ANY* and FP_ARITH_INST_RETIRED*
    sum_event() {
      local csv="$1" re="$2"
      echo "$csv" | awk -F',' -v IGNORECASE=1 -v re="$re" '
        {
          line=$0
          gsub(/"/,"",line)
          if (line ~ re) {
            for (i=NF; i>=1; --i) {
              v=$i; gsub(/"/,"",v)
              if (v ~ /^-?[0-9.]+([eE][-+]?[0-9]+)?$/) { s+=v; break }
            }
          }
        }
        END { printf "%.0f", s+0 }'
    }

    if [[ -n "$HW_CSV" ]]; then
      TOTAL_INST_EVT="$(sum_event "$HW_CSV" "INST_RETIRED[._]ANY")"
      FP_INST_EVT="$(sum_event "$HW_CSV" "FP_ARITH_INST_RETIRED")"

      if [[ "${TOTAL_INST_EVT:-0}" -gt 0 ]]; then
        local_est_int=$(( TOTAL_INST_EVT - FP_INST_EVT ))
        (( local_est_int < 0 )) && local_est_int=0
        ESTIMATED_INTEGER_OPS="$local_est_int"
        TOTAL_INT_PERCENT="$(awk "BEGIN{printf \"%.2f\", (100.0*$ESTIMATED_INTEGER_OPS/$TOTAL_INST_EVT)}")"
        echo "  > HW refined: TOTAL_INST_EVT=${TOTAL_INST_EVT}, FP_INST_EVT=${FP_INST_EVT}"
        echo "  > HW refined: Estimated Integer Ops=${ESTIMATED_INTEGER_OPS} (${TOTAL_INT_PERCENT}%)"
      else
        echo "  > HW events not conclusive; keeping Useful Work proxy."
      fi
    else
      echo "  > HW CSV not available; keeping Useful Work proxy."
    fi
  else
    echo "  > hw-events collection failed; keeping Useful Work proxy."
  fi
fi

# ---- Step 2: Memory Access (for DRAM bytes) ----------------------------------
echo "--- [2/3] Memory analysis (memory-access) ---"
rm -rf "$VTUNE_MEM_DIR" || true
vtune -collect memory-access -result-dir "$VTUNE_MEM_DIR" -- "${TARGET_CMD[@]}" \
  > vtune_mem.log 2>&1 || {
    echo "Error: VTune memory-access failed. See vtune_mem.log" >&2
    exit 1
  }

MEM_CSV="$(vtune -report summary -result-dir "$VTUNE_MEM_DIR" -format csv -csv-delimiter ',' || true)"

# Elapsed Time (s)
MEM_ELAPSED="$(csv_get_val_lastnum_firstcol_match "$MEM_CSV" "^Elapsed[[:space:]]*Time.*\\(s\\)")"
[[ -z "$MEM_ELAPSED" ]] && MEM_ELAPSED=0

# DRAM bandwidth in GB/s: match anything that looks like "DRAM ... Bandwidth ... GB/s"
DRAM_BW_GBS="$(csv_get_val_lastnum_firstcol_match "$MEM_CSV" "^DRAM.*Bandwidth")"
[[ -z "$DRAM_BW_GBS" ]] && DRAM_BW_GBS=0

TOTAL_DRAM_BYTES="$(awk "BEGIN{printf \"%.0f\", ($DRAM_BW_GBS * $MEM_ELAPSED * 1e9)}")"

echo "  > Elapsed Time (s): $MEM_ELAPSED"
echo "  > Average DRAM Bandwidth (GB/s): $DRAM_BW_GBS"
echo "  > Total DRAM Bytes: $TOTAL_DRAM_BYTES"

# ---- Step 3: Final Intensity -------------------------------------------------
echo "--- [3/3] Final metric ---"
ARITHMETIC_INTENSITY="0"
if (( TOTAL_DRAM_BYTES > 0 )); then
  ARITHMETIC_INTENSITY="$(awk "BEGIN{printf \"%.6g\", ($ESTIMATED_INTEGER_OPS / $TOTAL_DRAM_BYTES)}")"
fi

{
  echo "================================================="
  echo "    Crypto Arithmetic Intensity (VTune-based)"
  echo "================================================="
  echo "Target Program:             ${TARGET_CMD[*]}"
  echo ""
  echo "--- NUMERATOR (Estimated Integer Compute) ---"
  echo "Total Instructions Retired: $TOTAL_RETIRED"
  echo "Integer-ish % (proxy):      $TOTAL_INT_PERCENT %"
  echo "Estimated Integer Ops:      $ESTIMATED_INTEGER_OPS"
  [[ "$ENABLE_HW_EVENTS" -eq 1 ]] && echo "Refinement via HW events:    ENABLED (best-effort)"
  echo ""
  echo "--- DENOMINATOR (Memory Traffic) ---"
  echo "Elapsed Time (s):           $MEM_ELAPSED"
  echo "Avg DRAM BW (GB/s):         $DRAM_BW_GBS"
  echo "Total DRAM Bytes:           $TOTAL_DRAM_BYTES"
  echo ""
  echo "--- RESULT ---"
  echo "Intensity (Est. Int Ops/Byte): $ARITHMETIC_INTENSITY"
  echo "================================================="
} | tee "$OUTPUT_LOG_FILE"