#!/usr/bin/env bash
#
# int64profiler.sh — Run Int64Profiler on any executable or script, with sanity checks.
#

PIN_HOME="$HOME/pin-3.31"
TOOL_SO="$PIN_HOME/source/tools/Int64Profiler/obj-intel64/Int64Profiler.so"

usage() {
  cat <<EOF
Usage: $(basename "$0") [--help] <path-to-executable-or-script> [-- <args>...]

Profiles 64-bit integer ADD/SUB/MUL/DIV ops in your program via Pin.

Examples:
  # C++ binary:
  g++ -O3 -std=c++17 hello.cpp -o hello
  ./int64profiler.sh ~/hello

  # Go binary:
  go build -o fib fib.go
  ./int64profiler.sh ~/fib

  # Python script:
  chmod +x myscript.py
  ./int64profiler.sh ~/myscript.py -- arg1 arg2

Flags:
  -h, --help    Show this help and exit
EOF
}

# ───────────────────  handle --help ───────────────────
if [[ "${1:-}" =~ ^(-h|--help)$ ]]; then
  usage
  exit 0
fi

# ──────────────────  check Pin installation ───────────────────
if [[ ! -d "$PIN_HOME" ]]; then
  echo "Error: Pin home not found at '$PIN_HOME'." >&2
  echo "Please run your bootstrap script to install Pin into $PIN_HOME." >&2
  exit 1
fi

if [[ ! -f "$TOOL_SO" ]]; then
  echo "Error: Int64Profiler tool missing at '$TOOL_SO'." >&2
  echo "Please run your bootstrap script to build the Int64Profiler tool." >&2
  exit 1
fi

# ───────────────────  require target ───────────────────
if (( $# < 1 )); then
  echo "Error: Missing target executable or script." >&2
  usage
  exit 1
fi

TARGET="$1"; shift

# ───────────────────  check target ───────────────────
if [[ ! -e "$TARGET" ]]; then
  echo "Error: Target '$TARGET' does not exist." >&2
  exit 1
fi
if [[ ! -x "$TARGET" ]]; then
  echo "Error: Target '$TARGET' is not executable." >&2
  exit 1
fi

# ───────────────────  run Pin profiling ───────────────────
"$PIN_HOME/pin" \
  -t "$TOOL_SO" -- "$TARGET" "$@" 2>/dev/null \
| grep -E '^(ADD|SUB|MUL|DIV|SIMD)'
