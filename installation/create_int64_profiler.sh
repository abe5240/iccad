#!/usr/bin/env bash
###############################################################################
# create_int64_profiler.sh
# End-to-end build & smoke-test for Int64Profiler pintool on Ubuntu 22.04
###############################################################################
set -euo pipefail

# ─────────── config ───────────
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

# ─────────── logging ───────────
LOG_DIR="$HOME/logs"; mkdir -p "$LOG_DIR"
LOG="$LOG_DIR/bootstrap_${TOOL_NAME,,}-$(date +%F_%H-%M-%S).log"
exec > >(tee "$LOG") 2>&1

trap 'echo -e "\n❌  Error on line $LINENO (see $LOG)"; exit 1' ERR

step(){ echo -e "\n🔷 $* …"; }
ok  (){ echo    "✔️  $*";    }

# ─────────── 1. tool-chain ───────────
step "Installing build tool-chain"
sudo -n apt-get update -qq
sudo -n apt-get install -y --no-install-recommends build-essential git ca-certificates
ok "Tool-chain ready"

# ─────────── 2. clone repo ───────────
step "Cloning / updating GitHub repo"
if [[ -d $REPO_DIR/.git ]]; then
  git -C "$REPO_DIR" pull --ff-only
else
  git clone https://github.com/abe5240/iccad.git "$REPO_DIR"
fi
ok "Repo ready at $REPO_DIR"

# ─────────── 3. verify installation folder ───────────
step "Verifying 'installation/' folder exists"
if [[ ! -d "$INSTALL_DIR" ]]; then
  echo "❌  Installation folder not found: $INSTALL_DIR"
  exit 1
fi
ok "'installation/' located"

# ─────────── 4. extract Pin ───────────
step "Extracting Pin $PIN_VER"
rm -rf "$PIN_HOME"
mkdir -p "$PIN_HOME"
tar -xzf "$PIN_TAR" -C "$PIN_HOME" --strip-components=1
export PIN_HOME PIN_ROOT
ok "Pin extracted to $PIN_HOME"

# ─────────── 5. prepare tool ───────────
step "Setting up ${TOOL_NAME} source tree"
rm -rf "$TOOL_DIR"
cp -r "$PIN_HOME/source/tools/MyPinTool" "$TOOL_DIR"
rm -f  "$TOOL_DIR/MyPinTool.cpp"
cp     "$SRC_CPP" "$TOOL_DIR/${TOOL_NAME}.cpp"

MF="$TOOL_DIR/makefile.rules"
sed -Ei 's/^[[:space:]]*TEST_TOOL_ROOTS[[:space:]]*:=[[:space:]].*/TEST_TOOL_ROOTS := '"$TOOL_NAME"'/' "$MF"
sed -Ei 's/^[[:space:]]*TOOL_ROOTS[[:space:]]*:=[[:space:]].*/TOOL_ROOTS := '"$TOOL_NAME"'/'         "$MF"
sed -i  's/\<MyPinTool\>/'"$TOOL_NAME"'/g'                                                          "$MF"
ok "makefile.rules patched"

# ─────────── 6. build pintool ───────────
step "Building ${TOOL_NAME}.so (quiet)"
make -s -C "$TOOL_DIR" clean
make -s -C "$TOOL_DIR"
ok "${TOOL_NAME}.so built"

# ─────────── 7. build test app ───────────
step "Building test application (quiet)"
g++ -O3 -std=c++17 "$TEST_CPP" -o "$TEST_BIN" 2>>"$LOG"
ok "Test binary → $TEST_BIN"

# ─────────── 8. run Pin ───────────
step "Running Pin with ${TOOL_NAME}"
RAW=$("$PIN_HOME/pin" -t "$TOOL_DIR/obj-intel64/${TOOL_NAME}.so" -- "$TEST_BIN")

# ─────────── 9. parsed totals ───────────
echo -e "\n----- Parsed totals -----"
echo "$RAW" | grep -E '^(ADD|SUB|MUL|DIV|SIMD)'

# ─────────── finished ───────────

echo    ""  # blank line
ok "Bootstrap complete (logs in $LOG_DIR)"
