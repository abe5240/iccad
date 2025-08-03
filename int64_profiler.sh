#!/usr/bin/env bash
###############################################################################
# int64_profiler.sh – run Int64Profiler on any executable or script.
#   • Default  : prints compact totals (ADD / SUB / MUL / DIV).
#   • --verbose: prints full per-opcode report + SIMD + immediates.
###############################################################################
set -euo pipefail

# ───────── config ─────────
PIN_HOME="$HOME/pin-3.31"
TOOL_SO="$PIN_HOME/source/tools/Int64Profiler/obj-intel64/Int64Profiler.so"

# ───────── CLI parsing ─────────
VERBOSE=0
if [[ "${1:-}" == "--verbose" ]]; then VERBOSE=1; shift; fi
if [[ "${1:-}" =~ ^(-h|--help)$ || $# -lt 1 ]]; then
  cat <<EOF
Usage: $(basename "$0") [--verbose] <target> [-- <args>...]

Profiles 64-bit integer arithmetic via Intel Pin.

Examples:
  ./int64_profiler.sh            ./my_binary
  ./int64_profiler.sh --verbose ./script.py -- arg1 arg2
EOF
  exit 0
fi

TARGET="$1"; shift

# ───────── sanity checks ─────────
[[ -d "$PIN_HOME" ]] || { echo "Pin not found at $PIN_HOME"; exit 1; }
[[ -f "$TOOL_SO"  ]] || { echo "Int64Profiler.so missing";  exit 1; }
[[ -e "$TARGET"   ]] || { echo "Target $TARGET does not exist"; exit 1; }
[[ -x "$TARGET"   ]] || { echo "Target $TARGET not executable"; exit 1; }

# ───────── run pintool ─────────
PIN_ARGS=()
(( VERBOSE )) && PIN_ARGS+=("-verbose" "1")

RAW=$(
  { "$PIN_HOME/pin" -t "$TOOL_SO" "${PIN_ARGS[@]}" -- "$TARGET" "$@" 2>/dev/null; } \
  | tee /dev/tty
)

# ───────── print result ─────────
if (( VERBOSE )); then
  echo "$RAW"
else
  echo "$RAW" | grep -E '^(ADD:|SUB:|MUL:|DIV:)'
fi