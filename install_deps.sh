#!/usr/bin/env bash
# ==============================================================================
# FILE: install_deps.sh
# PURPOSE: Ensure Intel VTune Profiler is available in PATH (idempotent).
# ==============================================================================
# Behavior:
#   - If 'vtune' is already in PATH, exit 0.
#   - Otherwise try to source oneAPI VTune env vars from common locations.
#   - Append the sourcing line to ~/.bashrc if a working vars.sh is found.
#   - Print actionable guidance if VTune is not installed.
# ==============================================================================

set -Eeuo pipefail

echo "  > [install_deps.sh] Checking for 'vtune' command..."

if command -v vtune &>/dev/null; then
  echo "  > VTune is already in PATH. OK."
  exit 0
fi

ONEAPI_ROOT_DEFAULT="/opt/intel/oneapi"
CANDIDATES=()

# Preferred canonical path
CANDIDATES+=("${ONEAPI_ROOT_DEFAULT}/vtune/latest/env/vars.sh")

# Fallback: scan typical oneAPI layouts (avoid glob errors if dirs absent)
if [[ -d "${ONEAPI_ROOT_DEFAULT}" ]]; then
  while IFS= read -r -d '' f; do CANDIDATES+=("$f"); done < <(
    find "${ONEAPI_ROOT_DEFAULT}" -type f -path "*/vtune/*/env/vars.sh" -print0 2>/dev/null || true
  )
fi

FOUND_VARS=""
for f in "${CANDIDATES[@]}"; do
  if [[ -f "$f" ]]; then
    echo "  > Found candidate VTune env script: $f"
    # shellcheck disable=SC1090
    source "$f" || true
    if command -v vtune &>/dev/null; then
      FOUND_VARS="$f"
      break
    fi
  fi
done

if [[ -n "$FOUND_VARS" ]]; then
  # Make it persistent for future shells
  if ! grep -Fq "source ${FOUND_VARS}" "${HOME}/.bashrc"; then
    echo "source ${FOUND_VARS}" >> "${HOME}/.bashrc"
    echo "  > Added 'source ${FOUND_VARS}' to ~/.bashrc"
  fi
  echo "  > VTune available in current shell."
  exit 0
fi

cat >&2 <<'EOF'
Error: 'vtune' command not found and no oneAPI VTune env script was located.
Please install Intel oneAPI VTune Profiler and/or set up the environment:

  - On Intel oneAPI systems:
      source /opt/intel/oneapi/vtune/latest/env/vars.sh

  - Or install via Intel installers / package manager appropriate to your distro.

Once installed, re-run this script.
EOF
exit 1