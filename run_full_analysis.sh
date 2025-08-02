#!/usr/bin/env bash
# ==============================================================================
# Master Workflow: Prepares system and runs Crypto Intensity analysis.
#
# This script orchestrates the entire process:
#  1. Ensures all dependencies are installed by calling install_deps.sh.
#  2. Takes a PRE-COMPILED executable as an argument.
#  3. Runs the detailed analysis script on that executable.
#
# Usage:
#   ./run_full_analysis.sh /path/to/your/compiled_program
#
# Example (after 'make' in FullRNS-HEAAN/run):
#   ./run_full_analysis.sh ../FullRNS-HEAAN/run/FRNSHEAAN
#
# Example (after 'go build' in a lattigo example dir):
#   ./run_full_analysis.sh ./basics
# ==============================================================================

set -Eeuo pipefail
IFS=$'\n\t'

# --- Paths and Pretty Output ---
SCRIPT_DIR="$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &>/dev/null && pwd )"
BOLD=$(tput bold 2>/dev/null || true); RESET=$(tput sgr0 2>/dev/null || true)
BLUE=$(tput setaf 4 2>/dev/null || true); GREEN=$(tput setaf 2 2>/dev/null || true)
step() { printf "\n${BOLD}${BLUE}=== %s ===${RESET}\n" "$1"; }

# --- Check for Target ---
if [[ "$#" -lt 1 ]]; then
    echo "Error: No target program specified." >&2
    echo "Usage: $0 /path/to/your/compiled_executable [args...]" >&2
    exit 1
fi
TARGET_EXECUTABLE=("$@")
if [[ ! -x "${TARGET_EXECUTABLE[0]}" ]]; then
    echo "Error: Target '${TARGET_EXECUTABLE[0]}' is not an executable file." >&2
    exit 1
fi

# --- Step 1: Provision Dependencies ---
step "STEP 1: Verifying System Dependencies"
INSTALLER="${SCRIPT_DIR}/install_deps.sh"
[[ -f "$INSTALLER" ]] || { echo "Installer not found: $INSTALLER"; exit 1; }
bash "$INSTALLER" # This script is idempotent, so it's safe to run every time.
# Source the environment for the rest of this script's execution
source ~/.bashrc &>/dev/null || true

# --- Step 2: Run Performance Analysis ---
step "STEP 2: Running Crypto Performance Analysis"
ANALYSIS_SCRIPT="${SCRIPT_DIR}/analyze_crypto_intensity.sh"
[[ -f "$ANALYSIS_SCRIPT" ]] || { echo "Analysis script not found: $ANALYSIS_SCRIPT"; exit 1; }
bash "$ANALYSIS_SCRIPT" "${TARGET_EXECUTABLE[@]}"

printf "\n${BOLD}${GREEN}ANALYSIS COMPLETE${RESET}\n"