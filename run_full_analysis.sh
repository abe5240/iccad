#!/usr/bin/env bash
# ==============================================================================
# Master Workflow: install_deps → load env → build FullRNS-HEAAN → roofline
# Ubuntu 22.04 / Debian 12. Non-interactive. Safe to re-run.
# ==============================================================================

set -Eeuo pipefail
IFS=$'\n\t'

# ---------- Pretty output ----------
BOLD=$(tput bold 2>/dev/null || true); RESET=$(tput sgr0 2>/dev/null || true)
BLUE=$(tput setaf 4 2>/dev/null || true); GREEN=$(tput setaf 2 2>/dev/null || true)
YELLOW=$(tput setaf 3 2>/dev/null || true); RED=$(tput setaf 1 2>/dev/null || true)
step() { printf "\n${BOLD}${BLUE}=== %s ===${RESET}\n" "$1"; }
ok()   { printf "${GREEN}✔ %s${RESET}\n" "$1"; }
warn() { printf "${YELLOW}⚠ %s${RESET}\n" "$1"; }
die()  { printf "${RED}✖ %s${RESET}\n" "$1"; exit 1; }
trap 'die "Failed at: ${BASH_COMMAND}"' ERR

# ---------- Paths / config (locked to install_deps.sh) ----------
SCRIPT_DIR="$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &>/dev/null && pwd )"
INSTALLER="${INSTALLER:-$SCRIPT_DIR/install_deps.sh}"
[[ -f "$INSTALLER" ]] || die "Installer not found: $INSTALLER"

REPO_DIR="${REPO_DIR:-$HOME/FullRNS-HEAAN}"
LIB_DIR="$REPO_DIR/lib"
RUN_DIR="$REPO_DIR/run"
ANALYSIS_SCRIPT="${ANALYSIS_SCRIPT:-$SCRIPT_DIR/analyze_roofline_metrics.sh}"
NCORES="$(command -v nproc >/dev/null 2>&1 && nproc || echo 1)"

# ---------- Forwarded args (ENV + CLI, preserves quoting) ----------
ENV_ARGS=()
if [[ -n "${TARGET_ARGS:-}" ]]; then
  # shellcheck disable=SC2206
  ENV_ARGS=($TARGET_ARGS)
fi
CLI_ARGS=("$@")
EXTRA_ARGS=("${ENV_ARGS[@]}" "${CLI_ARGS[@]}")

# ---------- Step 1: Provision dependencies ----------
step "STEP 1: Installing dependencies"
[[ -x "$INSTALLER" ]] || chmod +x "$INSTALLER" || true
bash "$INSTALLER"
ok "Dependencies installed via $(basename "$INSTALLER")"

# ---------- Step 2: Load environment (Go/VTune) ----------
step "STEP 2: Loading environment (Go/VTune)"
# Go PATH for this session
if [[ ":$PATH:" != *":/usr/local/go/bin:"* ]] && [[ -x /usr/local/go/bin/go ]]; then
  export PATH="/usr/local/go/bin:$PATH"
fi
if command -v go >/dev/null 2>&1; then
  ok "Go: $(go version)"
else
  warn "Go not found"
fi

# VTune env if present (analysis script also self-detects/sources)
if [[ -f "$HOME/intel/oneapi/vtune/latest/env/vars.sh" ]]; then
  # shellcheck disable=SC1090
  source "$HOME/intel/oneapi/vtune/latest/env/vars.sh"
  ok "VTune env sourced (user)"
elif [[ -f "/opt/intel/oneapi/vtune/latest/env/vars.sh" ]]; then
  # shellcheck disable=SC1090
  source "/opt/intel/oneapi/vtune/latest/env/vars.sh"
  ok "VTune env sourced (system)"
else
  warn "VTune env not found; proceeding (analysis script will try again)"
fi

# Also source .bashrc (harmless if missing)
[[ -f "$HOME/.bashrc" ]] && source "$HOME/.bashrc" || true

# ---------- Step 3: Build FullRNS-HEAAN ----------
step "STEP 3: Building FullRNS-HEAAN"
[[ -d "$REPO_DIR" ]] || die "Repo not found at $REPO_DIR (run installer first)"

# Build library
if [[ -d "$LIB_DIR" ]]; then
  pushd "$LIB_DIR" >/dev/null
  make clean || true
  make -j"$NCORES"
  popd >/dev/null
  ok "Built library: $LIB_DIR"
else
  warn "Missing $LIB_DIR; skipping library build"
fi

# Build run targets
[[ -d "$RUN_DIR" ]] || die "Missing $RUN_DIR"
pushd "$RUN_DIR" >/dev/null
make clean || true
make -j"$NCORES"
ok "Built run targets"

# Detect the executable:
# 1) prefer FRNSHEAAN if present; else 2) newest user-executable in run/
TARGET_EXECUTABLE=""
if [[ -x "$RUN_DIR/FRNSHEAAN" ]]; then
  TARGET_EXECUTABLE="$RUN_DIR/FRNSHEAAN"
else
  TARGET_EXECUTABLE="$(
    find "$RUN_DIR" -maxdepth 1 -type f -perm -u=x -printf '%T@ %p\n' 2>/dev/null \
      | sort -nr | awk 'NR==1{print $2}'
  )"
  if [[ -z "$TARGET_EXECUTABLE" ]]; then
    TARGET_EXECUTABLE="$(ls -t "$RUN_DIR"/* 2>/dev/null | head -n1 || true)"
  fi
fi
popd >/dev/null

[[ -n "$TARGET_EXECUTABLE" && -x "$TARGET_EXECUTABLE" ]] \
  || die "No runnable binary found in $RUN_DIR"

echo "Build complete. Target executable is: ${TARGET_EXECUTABLE}"

# ---------- Step 4: Roofline analysis ----------
step "STEP 4: RUNNING PERFORMANCE ANALYSIS"
[[ -f "$ANALYSIS_SCRIPT" ]] || die "Analysis script not found: $ANALYSIS_SCRIPT"
[[ -x "$ANALYSIS_SCRIPT" ]] || chmod +x "$ANALYSIS_SCRIPT" || true

bash "$ANALYSIS_SCRIPT" "$TARGET_EXECUTABLE" "${EXTRA_ARGS[@]}"

printf "\n${BOLD}${GREEN}DONE${RESET}\n"