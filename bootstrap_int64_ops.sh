#!/usr/bin/env bash
###############################################################################
# bootstrap_int64_ops.sh
# End-to-end build & smoke-test for int64_ops pintool on Ubuntu 22.04
###############################################################################
set -euo pipefail

# ──────────────────────── config ────────────────────────
PIN_VER="3.31"
PIN_HOME="$HOME/pin-${PIN_VER}"
PIN_ROOT="$PIN_HOME"
REPO_DIR="$HOME/iccad"
TOOL_DIR="${PIN_HOME}/source/tools/int64_ops"
TEST_CPP="$REPO_DIR/test_installation.cpp"
TEST_BIN="/tmp/test_installation"

# ─────────────────────── logging ────────────────────────
LOG_DIR="$HOME/logs"; mkdir -p "$LOG_DIR"
LOG="$LOG_DIR/bootstrap_int64_ops-$(date +%F_%H-%M-%S).log"
exec > >(tee "$LOG") 2>&1

trap 'echo -e "\n❌  Error on line $LINENO (see $LOG)"; exit 1' ERR

step(){ echo -e "\n🔷 $* …"; }
ok  (){ echo    "✔️  $*";    }

# ─────────────────── 1. Tool-chain ──────────────────────
step "Installing build tool-chain"
sudo -n apt-get update  -qq
sudo -n apt-get install -y --no-install-recommends build-essential git ca-certificates
ok "Tool-chain ready"

# ─────────────────── 2. Repo ─────────────────────────────
step "Cloning / updating repo"
if [[ -d "$REPO_DIR/.git" ]]; then
  git -C "$REPO_DIR" pull --ff-only
else
  git clone https://github.com/abe5240/iccad.git "$REPO_DIR"
fi
ok "Repo ready at $REPO_DIR"

# ─────────────────── 3. Pin kit ──────────────────────────
step "Extracting Pin $PIN_VER"
rm -rf "$PIN_HOME"
mkdir -p "$PIN_HOME"
tar -xzf "$REPO_DIR/intel-pin-linux.tar.gz" -C "$PIN_HOME" --strip-components=1
export PIN_HOME PIN_ROOT
ok "Pin extracted to $PIN_HOME"

# ─────────────────── 4. Prepare tool ─────────────────────
step "Setting up int64_ops source tree"
rm -rf "$TOOL_DIR"
cp -r "$PIN_HOME/source/tools/MyPinTool" "$TOOL_DIR"
rm -f  "$TOOL_DIR/MyPinTool.cpp"
cp     "$REPO_DIR/int64_ops.cpp" "$TOOL_DIR/"

MF="$TOOL_DIR/makefile.rules"
sed -Ei 's/^[[:space:]]*TEST_TOOL_ROOTS[[:space:]]*:=[[:space:]].*/TEST_TOOL_ROOTS := int64_ops/' "$MF"
sed -Ei 's/^[[:space:]]*TOOL_ROOTS[[:space:]]*:=[[:space:]].*/TOOL_ROOTS := int64_ops/'         "$MF"
sed -i  's/\<MyPinTool\>/int64_ops/g'                                                              "$MF"
ok "makefile.rules patched"

# ─────────────────── 5. Build pintool ────────────────────
step "Building int64_ops.so (quiet)"
make -s -C "$TOOL_DIR" clean
make -s -C "$TOOL_DIR"
ok "int64_ops.so built"

# ────────────────── 6. Build test app ─────────────────────
step "Building test application (quiet)"
g++ -O3 -std=c++17 "$TEST_CPP" -o "$TEST_BIN" 2>>"$LOG"
ok "Test binary → $TEST_BIN"

# ─────────────────── 7. Run Pin ───────────────────────────
step "Running Pin with int64_ops"
RAW=$("$PIN_HOME/pin" -t "$TOOL_DIR/obj-intel64/int64_ops.so" -- "$TEST_BIN")

# ────────────────── 8. Parsed totals ─────────────────────
echo -e "\n----- Parsed totals -----"
echo "$RAW" | grep -E '^(ADD|SUB|MUL|DIV|SIMD)'

# ─────────────────── 9. Complete ──────────────────────────

echo    ""    # blank line
ok "Bootstrap complete (logs in $LOG_DIR)"
