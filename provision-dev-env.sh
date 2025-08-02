#!/usr/bin/env bash
# ==============================================================================
# Setup script: system deps, NTL, Python, Go, FullRNS-HEAAN, Intel oneAPI VTune
#
# Safe to re-run (idempotent where practical). Uses pinned versions by default.
# Override with env vars: NTL_VERSION, GO_VERSION, ONEAPI_URL, REPO_URL, REPO_DIR
# ==============================================================================

set -Eeuo pipefail
IFS=$'\n\t'

# ---- Versions / URLs ---------------------------------------------------------
NTL_VERSION="${NTL_VERSION:-11.5.1}"
GO_VERSION="${GO_VERSION:-1.22.3}"
ONEAPI_URL="${ONEAPI_URL:-https://registrationcenter-download.intel.com/akdlm/irc_nas/19078/l_oneapi_basekit_p_2023.2.0.49397_offline.sh}"
REPO_URL="${REPO_URL:-https://github.com/K-miran/FullRNS-HEAAN.git}"
REPO_DIR="${REPO_DIR:-$HOME/FullRNS-HEAAN}"

# ---- UI helpers --------------------------------------------------------------
BOLD=$(tput bold || true); RESET=$(tput sgr0 || true)
GREEN=$(tput setaf 2 || true); BLUE=$(tput setaf 4 || true)
YELLOW=$(tput setaf 3 || true); RED=$(tput setaf 1 || true)

step() { printf "\n${BOLD}${BLUE}--- [Step %s/7] %s ---${RESET}\n" "$1" "$2"; }
ok()   { printf "${GREEN}✔ %s${RESET}\n" "$1"; }
warn() { printf "${YELLOW}⚠ %s${RESET}\n" "$1"; }
die()  { printf "${RED}✖ %s${RESET}\n" "$1"; exit 1; }

trap 'die "Failed at: ${BASH_COMMAND}"' ERR

# ---- Utilities ---------------------------------------------------------------
append_once() {
  # append_once <file> <line>
  local file="$1" line="$2"
  grep -qxF "$line" "$file" 2>/dev/null || echo "$line" >> "$file"
}

# ---- Step 1: apt update ------------------------------------------------------
step 1 "Updating package lists"
export DEBIAN_FRONTEND=noninteractive
sudo apt-get update -y
ok "apt lists updated"

# ---- Step 2: core system & C++ deps -----------------------------------------
step 2 "Installing core system and C/C++ dependencies"
sudo apt-get install -y \
  build-essential git wget curl ca-certificates unzip pkg-config \
  libgmp-dev libssl-dev linux-tools-common linux-tools-generic
ok "Core packages installed"

# ---- Step 3: NTL (Number Theory Library) ------------------------------------
step 3 "Installing NTL ${NTL_VERSION} from source"
if ldconfig -p | grep -q libntl; then
  ok "NTL already present (ldconfig reports libntl)"
else
  tmpdir=$(mktemp -d)
  pushd "$tmpdir" >/dev/null
  wget -q "https://libntl.org/ntl-${NTL_VERSION}.tar.gz"
  tar -xzf "ntl-${NTL_VERSION}.tar.gz"
  cd "ntl-${NTL_VERSION}/src"
  ./configure
  make -j"$(nproc)"
  sudo make install
  popd >/dev/null
  rm -rf "$tmpdir"
  ok "NTL ${NTL_VERSION} installed"
fi

# ---- Step 4: Python & Go -----------------------------------------------------
step 4 "Installing Python and Go ${GO_VERSION}"
sudo apt-get install -y python3 python3-pip python3-venv
ok "Python installed"

need_go=true
if command -v go >/dev/null 2>&1; then
  if go version | grep -q "go${GO_VERSION}"; then
    need_go=false
    ok "Go ${GO_VERSION} already installed"
  else
    warn "Different Go detected: $(go version); replacing"
  fi
fi

if "$need_go"; then
  tmp="/tmp/go${GO_VERSION}.linux-amd64.tar.gz"
  wget -q "https://go.dev/dl/go${GO_VERSION}.linux-amd64.tar.gz" -O "$tmp"
  sudo rm -rf /usr/local/go
  sudo tar -C /usr/local -xzf "$tmp"
  rm -f "$tmp"
fi

append_once "$HOME/.bashrc" \
'export PATH=/usr/local/go/bin:$PATH'
export PATH=/usr/local/go/bin:$PATH
printf "Verifying Go installation: "
go version
ok "Go ready"

# ---- Step 5: Clone FullRNS-HEAAN --------------------------------------------
step 5 "Cloning FullRNS-HEAAN repository"
if [ -d "$REPO_DIR/.git" ]; then
  (cd "$REPO_DIR" && git pull --ff-only)
  ok "Repo updated at $REPO_DIR"
else
  git clone "$REPO_URL" "$REPO_DIR"
  ok "Repo cloned to $REPO_DIR"
fi

# ---- Step 6: Intel oneAPI Base Toolkit (VTune) -------------------------------
step 6 "Installing Intel oneAPI Base Toolkit (VTune)"
vtune_env="$HOME/intel/oneapi/vtune/latest/env/vars.sh"
if [ -f "$vtune_env" ]; then
  ok "oneAPI VTune already installed"
else
  inst="/tmp/oneapi_installer.sh"
  wget -q "$ONEAPI_URL" -O "$inst"
  chmod +x "$inst"
  sudo "$inst" --silent --eula accept
  rm -f "$inst"
  ok "oneAPI installed"
fi

append_once "$HOME/.bashrc" \
"source \"$vtune_env\" 2>/dev/null || true"
ok "VTune environment will auto-load in new shells"

# ---- Step 7: Finalize --------------------------------------------------------
step 7 "Final cleanup"
sudo apt-get -y autoremove
sudo apt-get -y clean
ok "Cleanup complete"

printf "\n${BOLD}${GREEN}SUCCESS:${RESET} All dependencies installed.\n"