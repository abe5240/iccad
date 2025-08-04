#!/usr/bin/env bash
###############################################################################
# int64_profiler.sh – run Int64Profiler
#
#   ./int64_profiler.sh <target> [function] [--verbose] [-- <prog-args…>]
#
#   • If <function> is omitted → count the whole program
#   • If provided  → counts only inside that symbol using -addr 0x…
###############################################################################
set -euo pipefail

PIN_HOME="$HOME/pin-3.31"
TOOL_SO="$PIN_HOME/source/tools/Int64Profiler/obj-intel64/Int64Profiler.so"

###############################################################################
# 1. parse positional args
###############################################################################
[[ $# -ge 1 ]] || { echo "Usage: $(basename "$0") <target> [function]"; exit 1; }
TARGET=$1; shift

FUNC=""
if [[ $# -gt 0 && $1 != --* ]]; then FUNC=$1; shift; fi

VERBOSE=0
if [[ "${1:-}" == "--verbose" ]]; then VERBOSE=1; shift; fi
if [[ "${1:-}" == "--" ]]; then shift; fi   # discard separator

###############################################################################
# 2. sanity checks
###############################################################################
[[ -x "$TARGET" ]]   || { echo "Target $TARGET not executable"; exit 1; }
[[ -f "$TOOL_SO" ]]  || { echo "Int64Profiler.so missing";    exit 1; }

###############################################################################
# 3. resolve symbol → address  (only if a function was given)
###############################################################################
PIN_ARGS=()
if [[ -n "$FUNC" ]]; then
  ADDR=$(nm "$TARGET" | awk -v f="$FUNC" '$3==f && $2=="T"{print $1; exit}')
  [[ -n "$ADDR" ]] || { echo "Function '$FUNC' not found"; exit 1; }
  echo "📍  Profiling only $FUNC() @ 0x$ADDR"
  PIN_ARGS+=( -addr "0x$ADDR" )
else
  echo "📍  Profiling entire process"
fi
(( VERBOSE )) && PIN_ARGS+=( -verbose 1 )

###############################################################################
# 4. run Pin
###############################################################################
echo "🔷  Running Pin…"
if (( VERBOSE )); then
  "$PIN_HOME/pin" -t "$TOOL_SO" "${PIN_ARGS[@]}" -- "$TARGET" "$@"
else
  RAW=$( "$PIN_HOME/pin" -t "$TOOL_SO" "${PIN_ARGS[@]}" -- "$TARGET" "$@" )
  echo "$RAW" | grep -E '^(ADD:|SUB:|MUL:|DIV:)'
fi