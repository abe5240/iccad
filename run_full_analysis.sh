#!/usr/bin/env bash
# ==============================================================================
# FILE: run_full_analysis.sh
# PURPOSE: Orchestrate dependency check and run the crypto intensity analysis.
#
# Usage:
#   ./run_full_analysis.sh /path/to/exe [args...]
#
# Notes:
#   - Calls ./install_deps.sh (no args).
#   - Then executes ./analyze_crypto_intensity.sh with your target and args.
#   - Preserves VTune result directories by default (KEEP_RESULTS=1).
# ==============================================================================

set -Eeuo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &>/dev/null && pwd )"

# Minimal color helpers
BOLD=$(tput bold 2>/dev/null || true)
RESET=$(tput sgr0 2>/dev/null || true)
BLUE=$(tput setaf 4 2>/dev/null || true)
GREEN=$(tput setaf 2 2>/dev/null || true)
step() { printf "\n${BOLD}${BLUE}=== %s ===${RESET}\n" "$1"; }

if [[ "$#" -lt 1 ]]; then
  echo "Error: No target program specified." >&2
  echo "Usage: $0 /path/to/executable [args...]" >&2
  exit 1
fi

TARGET_EXECUTABLE=("$@")

# realpath fallback
abspath() {
  local p="$1"
  if command -v realpath >/dev/null 2>&1; then
    realpath "$p"
  else
    readlink -f "$p"
  fi
}

TARGET_EXECUTABLE[0]="$(abspath "${TARGET_EXECUTABLE[0]}")"

if [[ ! -x "${TARGET_EXECUTABLE[0]}" ]]; then
  echo "Error: Target '${TARGET_EXECUTABLE[0]}' is not an executable file." >&2
  exit 1
fi

INSTALLER="${SCRIPT_DIR}/install_deps.sh"
ANALYSIS_SCRIPT="${SCRIPT_DIR}/analyze_crypto_intensity.sh"

[[ -f "$INSTALLER" ]] || { echo "Installer not found: $INSTALLER" >&2; exit 1; }
[[ -f "$ANALYSIS_SCRIPT" ]] || { echo "Analysis script not found: $ANALYSIS_SCRIPT" >&2; exit 1; }

step "STEP 1: Verifying System Dependencies"
bash "$INSTALLER"
# Ensure current shell sees the environment
# (best-effort; in many setups the installer appended to ~/.bashrc)
# shellcheck disable=SC1090
source "${HOME}/.bashrc" &>/dev/null || true

step "STEP 2: Running Crypto Performance Analysis"
cd "$SCRIPT_DIR"
bash "$ANALYSIS_SCRIPT" "${TARGET_EXECUTABLE[@]}"

printf "\n${BOLD}${GREEN}ANALYSIS COMPLETE${RESET}\n"