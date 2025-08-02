#!/usr/bin/env bash
# ==============================================================================
# HEAAN Analysis: OS-aware dependency installer (Ubuntu 22.04 / Debian 12)
# Installs: core build deps, NTL, Go, perf/cpupower, Intel oneAPI VTune
# Re-runnable. Non-interactive. Versions/URLs overridable via env vars.
# ==============================================================================

set -Eeuo pipefail
IFS=$'\n\t'
export DEBIAN_FRONTEND=noninteractive

# ---- Versions / URLs (override via env) --------------------------------------
NTL_VERSION="${NTL_VERSION:-11.5.1}"
GO_VERSION="${GO_VERSION:-1.22.3}"
REPO_URL="${REPO_URL:-https://github.com/KyoohyungHan/FullRNS-HEAAN.git}"
REPO_DIR="${REPO_DIR:-$HOME/FullRNS-HEAAN}"

# ---- UI helpers --------------------------------------------------------------
BOLD=$(tput bold 2>/dev/null || true); RESET=$(tput sgr0 2>/dev/null || true)
BLUE=$(tput setaf 4 2>/dev/null || true); GREEN=$(tput setaf 2 2>/dev/null || true)
YELLOW=$(tput setaf 3 2>/dev/null || true); RED=$(tput setaf 1 2>/dev/null || true)
step() { printf "\n${BOLD}${BLUE}--- [Step %s] %s ---${RESET}\n" "$1" "$2"; }
ok()   { printf "${GREEN}✔ %s${RESET}\n" "$1"; }
warn() { printf "${YELLOW}⚠ %s${RESET}\n" "$1"; }
die()  { printf "${RED}✖ %s${RESET}\n" "$1"; exit 1; }
trap 'die "Failed at: ${BASH_COMMAND}"' ERR

append_once() { # append_once <file> <line>
  local file="$1" line="$2"
  grep -qxF "$line" "$file" 2>/dev/null || echo "$line" >> "$file"
}

# ---- Distro / Arch detection -------------------------------------------------
DISTRO_ID="unknown"
if [[ -f /etc/os-release ]]; then . /etc/os-release; DISTRO_ID="${ID:-unknown}"; fi
ARCH_DEB="$(dpkg --print-architecture 2>/dev/null || echo amd64)"   # amd64|arm64|...
case "$ARCH_DEB" in
  amd64) GO_ARCH=amd64 ;;
  arm64) GO_ARCH=arm64 ;;
  *)     GO_ARCH=amd64; warn "Unrecognized arch '$ARCH_DEB'; defaulting Go to amd64" ;;
esac

# ---- Step 1: Preflight — neutralize stale oneAPI repo ------------------------
step 1 "Preflight (disable broken Intel oneAPI repo if present)"
ONEAPI_LIST=/etc/apt/sources.list.d/oneAPI.list
ONEAPI_KEY=/usr/share/keyrings/oneapi-archive-keyring.gpg
if [[ -f "$ONEAPI_LIST" && ! -s "$ONEAPI_KEY" ]]; then
  sudo mv -f "$ONEAPI_LIST" "${ONEAPI_LIST}.disabled"
  warn "Temporarily disabled $ONEAPI_LIST (missing key). Will restore later."
fi
ok "Preflight done"

# ---- Step 2: apt update ------------------------------------------------------
step 2 "Updating package lists"
sudo apt-get update -y -o Acquire::Retries=3
ok "apt lists updated"

# ---- Step 3: core system + perf tools (OS-aware) ----------------------------
step 3 "Installing core build deps and performance tools"
sudo apt-get install -y -q \
  build-essential cmake git wget curl ca-certificates unzip pkg-config \
  libgmp-dev libssl-dev gnupg lsb-release \
  python3 python3-pip python3-venv \
  bc

case "$DISTRO_ID" in
  ubuntu)
    if ! sudo apt-get install -y -q linux-tools-common "linux-tools-$(uname -r)"; then
      warn "linux-tools-$(uname -r) not available; installing linux-tools-generic"
      sudo apt-get install -y -q linux-tools-generic || true
    fi
    ok "Installed Ubuntu perf tools"
    ;;
  debian)
    sudo apt-get install -y -q linux-cpupower || warn "linux-cpupower unavailable"
    sudo apt-get install -y -q linux-perf \
      || sudo apt-get install -y -q "linux-perf-$(uname -r | cut -d- -f1)" \
      || warn "linux-perf unavailable"
    ok "Installed Debian cpupower/perf"
    ;;
  *)
    warn "Unsupported distro '$DISTRO_ID'; skipping perf tool install"
    ;;
esac

# ---- Step 4: NTL from source -------------------------------------------------
step 4 "Installing NTL ${NTL_VERSION}"
if ldconfig -p 2>/dev/null | grep -q 'libntl\.so'; then
  ok "NTL already present"
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

# ---- Step 5: Go (pinned, arch-aware) ----------------------------------------
step 5 "Installing Go ${GO_VERSION} (${GO_ARCH})"
need_go=true
if command -v go >/dev/null 2>&1; then
  if go version | grep -q "go${GO_VERSION}"; then
    need_go=false; ok "Go ${GO_VERSION} already installed"
  else
    warn "Different Go detected: $(go version) — replacing with ${GO_VERSION}"
  fi
fi
if "$need_go"; then
  tmp="/tmp/go${GO_VERSION}.linux-${GO_ARCH}.tar.gz"
  wget -q "https://go.dev/dl/go${GO_VERSION}.linux-${GO_ARCH}.tar.gz" -O "$tmp"
  sudo rm -rf /usr/local/go
  sudo tar -C /usr/local -xzf "$tmp"
  rm -f "$tmp"
fi
append_once "$HOME/.bashrc" 'export PATH=/usr/local/go/bin:$PATH'
export PATH=/usr/local/go/bin:$PATH
printf "Verifying Go: "; go version
ok "Go ready"

# ---- Step 6: Clone/Update FullRNS-HEAAN (no prompts) ------------------------
step 6 "Cloning FullRNS-HEAAN repository"
if [[ -d "$REPO_DIR/.git" ]]; then
  (cd "$REPO_DIR" && git fetch --depth=1 origin && \
   (git rev-parse --verify origin/main >/dev/null 2>&1 && git reset --hard origin/main) || \
   (git rev-parse --verify origin/master >/dev/null 2>&1 && git reset --hard origin/master))
  ok "Repo updated at $REPO_DIR"
else
  git -c credential.interactive=never -c credential.helper= \
      clone --depth=1 "$REPO_URL" "$REPO_DIR"
  ok "Repo cloned to $REPO_DIR"
fi

# ---- Step 7: Intel oneAPI VTune (APT) + perf/uncore setup --------------------
step 7 "Installing Intel oneAPI VTune and enabling perf uncore access"
if [[ "$ARCH_DEB" != "amd64" ]]; then
  warn "Non-x86_64 architecture ($ARCH_DEB) — skipping VTune install"
else
  # 7.1 Install or refresh the Intel key and repo (idempotent)
  sudo install -m 0755 -d /usr/share/keyrings
  curl -fsSL https://apt.repos.intel.com/intel-gpg-keys/GPG-PUB-KEY-INTEL-SW-PRODUCTS.PUB \
    | gpg --dearmor | sudo tee "$ONEAPI_KEY" >/dev/null
  echo "deb [arch=amd64 signed-by=${ONEAPI_KEY}] https://apt.repos.intel.com/oneapi all main" \
    | sudo tee "$ONEAPI_LIST" >/dev/null

  sudo apt-get update -y -o Acquire::Retries=3
  sudo apt-get install -y -q intel-oneapi-vtune

  # 7.2 Ensure vtune env auto-loads in new shells
  VTUNE_ENV_SYS="/opt/intel/oneapi/vtune/latest/env/vars.sh"
  [[ -f "$VTUNE_ENV_SYS" ]] && append_once "$HOME/.bashrc" "source \"$VTUNE_ENV_SYS\" 2>/dev/null || true"

  # 7.3 Allow driverless perf + uncore
  sudo mkdir -p /etc/sysctl.d
  echo "kernel.perf_event_paranoid=0" | sudo tee /etc/sysctl.d/99-perf.conf >/dev/null
  sudo sysctl --system >/dev/null || true

  # 7.4 Best-effort SEP driver (optional)
  if sudo apt-get install -y -q "linux-headers-$(uname -r)"; then
    if [[ -x /opt/intel/oneapi/vtune/latest/bin64/vtune-sepdk-setup.sh ]]; then
      sudo /opt/intel/oneapi/vtune/latest/bin64/vtune-sepdk-setup.sh --install-driver || \
        warn "SEP driver setup failed; continuing with perf-only mode"
      sudo systemctl restart sep5 || true
    fi
  else
    warn "Kernel headers for $(uname -r) not found; using perf-only mode"
  fi
  ok "VTune installed and perf access configured"
fi

# ---- Step 8: Finalize --------------------------------------------------------
step 8 "Final cleanup"
sudo apt-get -y -q autoremove
sudo apt-get -y -q clean

printf "\n${BOLD}${GREEN}SUCCESS:${RESET} All dependencies installed.\n"
printf "Load env in current shell: ${BOLD}source ~/.bashrc${RESET}\n"