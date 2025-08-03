#!/usr/bin/env bash
###############################################################################
# create_int64_profiler.sh
# Build Int64Profiler and enable uncore DRAM counters on Ubuntu 22.04
###############################################################################
set -euo pipefail

# ────────── optional CLI flag ──────────
VERBOSE=0
[[ "${1:-}" == "--verbose" ]] && { VERBOSE=1; shift; }

# ───────────── config ─────────────
PIN_VER="3.31"
PIN_HOME="$HOME/pin-${PIN_VER}"
PIN_ROOT="$PIN_HOME"
REPO_DIR="$HOME/iccad"
INSTALL_DIR="$REPO_DIR/installation"

TOOL_NAME="Int64Profiler"
TOOL_DIR="$PIN_HOME/source/tools/${TOOL_NAME}"

SRC_CPP="$INSTALL_DIR/int64_ops.cpp"
TEST_CPP="$INSTALL_DIR/test_installation.cpp"
PIN_TAR="$INSTALL_DIR/intel-pin-linux.tar.gz"
TEST_BIN="/tmp/test_installation"

LOG_DIR="$HOME/logs"; mkdir -p "$LOG_DIR"
LOG="$LOG_DIR/bootstrap_${TOOL_NAME,,}-$(date +%F_%H-%M-%S).log"
exec > >(tee "$LOG") 2>&1
trap 'echo -e "\n❌  Error on line $LINENO (see $LOG)"; exit 1' ERR
step(){ echo -e "\n🔷 $* …"; }
ok(){   echo    "✔️  $*";   }

# ───────── 1. packages ─────────
step "Installing build chain + perf tools"
sudo apt-get update -qq
sudo apt-get install -y --no-install-recommends \
     build-essential git ca-certificates \
     linux-tools-common linux-tools-$(uname -r) \
     msr-tools
ok "Packages ready"

# ───────── 2. enable uncore PMUs (once per boot) ─────────
step "Loading msr & intel_uncore kernel modules"
sudo modprobe msr
sudo modprobe intel_uncore || true   # older kernels auto-load on first use

step "Dropping perf_event lock-down (paranoid = -1)"
echo -1 | sudo tee /proc/sys/kernel/perf_event_paranoid >/dev/null
ok "System ready for uncore counters"

# ───────── 3. clone repo ─────────
step "Cloning / updating GitHub repo"
if [[ -d $REPO_DIR/.git ]]; then git -C "$REPO_DIR" pull --ff-only
else git clone https://github.com/abe5240/iccad.git "$REPO_DIR"; fi
ok "Repo ready"

# ───────── 4. verify installation payload ─────────
step "Checking $INSTALL_DIR exists"
[[ -d "$INSTALL_DIR" ]] || { echo "❌  Missing $INSTALL_DIR"; exit 1; }
ok "Payload located"

# ───────── 5. extract Pin ─────────
step "Extracting Pin ${PIN_VER}"
rm -rf "$PIN_HOME"; mkdir -p "$PIN_HOME"
tar -xzf "$PIN_TAR" -C "$PIN_HOME" --strip-components=1
export PIN_HOME PIN_ROOT
ok "Pin ready"

# ───────── 6. set up tool tree ─────────
step "Creating ${TOOL_NAME} source tree"
rm -rf "$TOOL_DIR"
cp -r "$PIN_HOME/source/tools/MyPinTool" "$TOOL_DIR"
rm -f  "$TOOL_DIR/MyPinTool.cpp"
cp     "$SRC_CPP" "$TOOL_DIR/${TOOL_NAME}.cpp"

MF="$TOOL_DIR/makefile.rules"
sed -Ei 's/TEST_TOOL_ROOTS[[:space:]]*:=.*/TEST_TOOL_ROOTS := '"$TOOL_NAME"'/' "$MF"
sed -Ei 's/TOOL_ROOTS[[:space:]]*:=.*/TOOL_ROOTS := '"$TOOL_NAME"'/'           "$MF"
sed -i  's/\<MyPinTool\>/'"$TOOL_NAME"'/g' "$MF"
ok "makefile.rules patched"

# ───────── 7. build pintool ─────────
step "Compiling ${TOOL_NAME}.so"
make -s -C "$TOOL_DIR" clean
make -s -C "$TOOL_DIR"
ok "Pintool built"

# ───────── 8. build smoke-test app ─────────
step "Building test program"
g++ -O3 -std=c++17 "$TEST_CPP" -o "$TEST_BIN"
ok "Test binary → $TEST_BIN"

# ───────── 9. run smoke-test ─────────
step "Running pintool on test binary"
PIN_ARGS=()
(( VERBOSE )) && PIN_ARGS+=("-verbose" "1")
RAW=$("$PIN_HOME/pin" -t "$TOOL_DIR/obj-intel64/${TOOL_NAME}.so" \
      "${PIN_ARGS[@]}" -- "$TEST_BIN")

echo -e "\n----- Parsed totals -----"
if (( VERBOSE )); then
  echo "$RAW"
else
  echo "$RAW" | grep -E '^(ADD:|SUB:|MUL:|DIV:)'
fi

echo
ok "Installation complete (full log: $LOG)"