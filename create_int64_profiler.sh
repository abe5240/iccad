#!/usr/bin/env bash
###############################################################################
# bootstrap_int64profiler.sh
# End-to-end build & smoke-test for Int64Profiler Pin tool on Ubuntu 22.04
#
# 🎨 Prettified version with perfect spacing and consistent formatting
###############################################################################
set -euo pipefail

# ┏━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┓
# ┃                                CONFIGURATION                               ┃
# ┗━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┛
PIN_VER="3.31"
PIN_HOME="$HOME/pin-${PIN_VER}"
PIN_ROOT="$PIN_HOME"
REPO_DIR="$HOME/iccad"
TOOL_NAME="Int64Profiler"
TOOL_DIR="${PIN_HOME}/source/tools/${TOOL_NAME}"
SRC_CPP="$REPO_DIR/int64_ops.cpp"
TEST_CPP="$REPO_DIR/test_installation.cpp"
TEST_BIN="/tmp/test_installation"

# ┏━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┓
# ┃                                  LOGGING                                   ┃
# ┗━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┛
LOG_DIR="$HOME/logs"; mkdir -p "$LOG_DIR"
LOG="$LOG_DIR/bootstrap_${TOOL_NAME,,}-$(date +%F_%H-%M-%S).log"
exec > >(tee "$LOG") 2>&1

# Color definitions
RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Error handling
trap 'echo -e "\n${RED}❌ Error${NC} on line $LINENO (see ${CYAN}$LOG${NC})"; exit 1' ERR

# ┏━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┓
# ┃                                PRINT FUNCTIONS                             ┃
# ┗━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┛
step() { 
    echo -e "\n${BLUE}🔷 ${CYAN}$*${NC} ${YELLOW}…${NC}" 
}

ok() { 
    echo -e "${GREEN}✔️  Success:${NC} $*" 
}

section() {
    echo -e "\n${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${YELLOW}✨ $*${NC}"
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
}

# ┏━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┓
# ┃                                MAIN SCRIPT                                 ┃
# ┗━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┛

section "Starting Int64Profiler Bootstrap"

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
step "Installing build tool-chain"
sudo -n apt-get update -qq
sudo -n apt-get install -y --no-install-recommends build-essential git ca-certificates
ok "Build tools installed"

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
step "Cloning/updating repository"
if [[ -d "$REPO_DIR/.git" ]]; then
    git -C "$REPO_DIR" pull --ff-only
else
    git clone https://github.com/abe5240/iccad.git "$REPO_DIR"
fi
ok "Repository ready at ${CYAN}$REPO_DIR${NC}"

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
step "Extracting Pin $PIN_VER"
rm -rf "$PIN_HOME"
mkdir -p "$PIN_HOME"
tar -xzf "$REPO_DIR/intel-pin-linux.tar.gz" -C "$PIN_HOME" --strip-components=1
export PIN_HOME PIN_ROOT
ok "Pin extracted to ${CYAN}$PIN_HOME${NC}"

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
step "Setting up ${TOOL_NAME} source tree"
rm -rf "$TOOL_DIR"
cp -r "$PIN_HOME/source/tools/MyPinTool" "$TOOL_DIR"
rm -f "$TOOL_DIR/MyPinTool.cpp"
cp "$SRC_CPP" "$TOOL_DIR/${TOOL_NAME}.cpp"

MF="$TOOL_DIR/makefile.rules"
sed -Ei 's/^[[:space:]]*TEST_TOOL_ROOTS[[:space:]]*:=[[:space:]].*/TEST_TOOL_ROOTS := '"$TOOL_NAME"'/' "$MF"
sed -Ei 's/^[[:space:]]*TOOL_ROOTS[[:space:]]*:=[[:space:]].*/TOOL_ROOTS := '"$TOOL_NAME"'/' "$MF"
sed -i 's/\<MyPinTool\>/'"$TOOL_NAME"'/g' "$MF"
ok "Source tree prepared in ${CYAN}$TOOL_DIR${NC}"

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
step "Building ${TOOL_NAME}.so (quiet mode)"
make -s -C "$TOOL_DIR" clean
make -s -C "$TOOL_DIR"
ok "${TOOL_NAME}.so successfully built"

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
step "Building test application"
g++ -O3 -std=c++17 "$TEST_CPP" -o "$TEST_BIN" 2>>"$LOG"
ok "Test binary compiled to ${CYAN}$TEST_BIN${NC}"

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
step "Running Pin with ${TOOL_NAME}"
RAW=$("$PIN_HOME/pin" -t "$TOOL_DIR/obj-intel64/${TOOL_NAME}.so" -- "$TEST_BIN")

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
section "Execution Results"
echo "$RAW" | grep -E '^(ADD|SUB|MUL|DIV|SIMD)' | column -t

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
section "Bootstrap Complete"
echo -e "Log file: ${CYAN}$LOG${NC}"
echo -e "Pin tool: ${CYAN}$TOOL_DIR/obj-intel64/${TOOL_NAME}.so${NC}"
echo -e "${GREEN}✅ All operations completed successfully${NC}\n"