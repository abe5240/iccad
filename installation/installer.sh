#!/usr/bin/env bash
###############################################################################
# installer.sh
#
# • Compiles Int64Profiler (whole‑program OR -addr‑gated version)
# • Installs kernel tweaks for unprivileged perf access
# • Builds a test binary that has   extern "C" void toBenchmark()
# • Runs a smoke‑test through   intensity_profiler.sh
#
# Usage:
#   ./installer.sh            # compact smoke‑test
#   ./installer.sh --verbose  # pintool opcode dump + profiler output
###############################################################################
set -euo pipefail

VERBOSE=0
[[ "${1:-}" == "--verbose" ]] && { VERBOSE=1; shift; }

# ───────── paths & names ─────────
PIN_VER="3.31"
PIN_HOME="$HOME/pin-${PIN_VER}"

REPO_DIR="$HOME/iccad"                 # repo that already contains scripts
INSTALL_DIR="$REPO_DIR/installation"   # holds payloads
TOOL_NAME="Int64Profiler"
TOOL_DIR="$PIN_HOME/source/tools/${TOOL_NAME}"
PIN_TAR="$INSTALL_DIR/intel-pin-linux.tar.gz"

SRC_CPP="$INSTALL_DIR/int64_ops.cpp"           # pintool source 
TEST_CPP="$INSTALL_DIR/test_installation.cpp"  # tiny benchmark
TEST_BIN="/tmp/test_installation"

LOG_DIR="$HOME/logs"
mkdir -p "$LOG_DIR"
LOG="$LOG_DIR/bootstrap_${TOOL_NAME,,}-$(date +%F_%H-%M-%S).log"
exec > >(tee "$LOG") 2>&1
trap 'echo -e "\n❌  Error on line $LINENO (see $LOG)"; exit 1' ERR
step(){ echo -e "\n🔷 $* …"; }
ok(){   echo    "✔️ $*";   }

###############################################################################
# 1. packages
###############################################################################
step "Installing build & perf prerequisites"
sudo apt-get update -qq
sudo apt-get install -y --no-install-recommends \
     build-essential git ca-certificates \
     linux-tools-common linux-tools-$(uname -r) \
     msr-tools
ok "Packages installed"

###############################################################################
# 2. enable uncore PMU access (persist across reboot)
###############################################################################
step "Loading msr / intel_uncore modules & relaxing perf security"
sudo modprobe msr
sudo modprobe intel_uncore || true

echo "# perf counters"            | sudo tee /etc/sysctl.d/99-perf.conf >/dev/null
echo "kernel.perf_event_paranoid=-1" | sudo tee -a /etc/sysctl.d/99-perf.conf >/dev/null
sudo sysctl -p /etc/sysctl.d/99-perf.conf >/dev/null

echo "# auto‑load modules"        | sudo tee /etc/modules-load.d/intel-uncore.conf >/dev/null
echo "msr"         | sudo tee -a /etc/modules-load.d/intel-uncore.conf >/dev/null
echo "intel_uncore"| sudo tee -a /etc/modules-load.d/intel-uncore.conf >/dev/null
ok "Uncore PMUs accessible without sudo (permanent)"

###############################################################################
# 3. git repo (contains intensity_profiler.sh, installer payloads, etc.)
###############################################################################
step "Cloning / updating $REPO_DIR"
if [[ -d $REPO_DIR/.git ]]; then
    git -C "$REPO_DIR" pull --ff-only
else
    git clone https://github.com/abe5240/iccad.git "$REPO_DIR"
fi
ok "Repo ready"

###############################################################################
# 4. unpack Pin kit
###############################################################################
step "Extracting Pin $PIN_VER"
rm -rf "$PIN_HOME"; mkdir -p "$PIN_HOME"
tar --strip-components=1 -xf "$PIN_TAR" -C "$PIN_HOME"
export PIN_HOME
ok "Pin installed at $PIN_HOME"

###############################################################################
# 5. set up pintool source tree
###############################################################################
step "Installing pintool source"
rm -rf "$TOOL_DIR"
cp -r "$PIN_HOME/source/tools/MyPinTool" "$TOOL_DIR"
rm "$TOOL_DIR"/MyPinTool.cpp
cp "$SRC_CPP" "$TOOL_DIR/${TOOL_NAME}.cpp"

# edit makefile.rules so the tool actually builds
sed -Ei "s/TEST_TOOL_ROOTS[[:space:]]*:=.*/TEST_TOOL_ROOTS := ${TOOL_NAME}/" "$TOOL_DIR/makefile.rules"
sed -Ei "s/TOOL_ROOTS[[:space:]]*:=.*/TOOL_ROOTS := ${TOOL_NAME}/"           "$TOOL_DIR/makefile.rules"
sed -i  "s/\\<MyPinTool\\>/${TOOL_NAME}/g"                                   "$TOOL_DIR/makefile.rules"
ok "Tool source prepared"

###############################################################################
# 6. build pintool
###############################################################################
step "Compiling $TOOL_NAME"
make -s -C "$TOOL_DIR" clean
make -s -C "$TOOL_DIR" EXTRA_LDFLAGS=-Wl,-w
ok "Pintool built → $TOOL_DIR/obj-intel64/${TOOL_NAME}.so"

###############################################################################
# 7. build test binary with toBenchmark() (non‑PIE, exported symbol)
###############################################################################
step "Building test binary"
g++ -std=c++17 -O0 -g -no-pie -fno-pie -rdynamic \
    "$TEST_CPP" -o "$TEST_BIN"
ok "Test binary → $TEST_BIN"

###############################################################################
# 8. pintool & perf smoke‑test via intensity_profiler.sh
###############################################################################
PROF="$REPO_DIR/intensity_profiler.sh"
[[ -x "$PROF" ]] || { echo "❌ $PROF not found or not executable"; exit 1; }

step "Running integer‑intensity smoke‑test"
ARGS=("$TEST_BIN" "toBenchmark")
(( VERBOSE )) && ARGS+=(--verbose)

"$PROF" "${ARGS[@]}"
echo
ok "Smoke‑test finished"

echo -e "\n🎉  Installation complete (details in $LOG)"
echo "   You can now run ${PROF##*/} on any binary:"
echo "     $ $PROF <my_prog> [function] [--verbose]"
echo