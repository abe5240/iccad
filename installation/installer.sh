#!/usr/bin/env bash
###############################################################################
# installer.sh
# Build Int64Profiler, verify smoke-test, *and* confirm DRAM-counter access
# on a fresh Ubuntu 22.04 machine.
###############################################################################
set -euo pipefail

# ────────── optional CLI flag ──────────
VERBOSE=0
[[ "${1:-}" == "--verbose" ]] && { VERBOSE=1; shift; }

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

# ───────── 2. enable uncore PMUs ─────────
step "Loading msr & intel_uncore modules"
sudo modprobe msr
sudo modprobe intel_uncore || true

step "Dropping perf_event lock-down (paranoid = -1)"
echo -1 | sudo tee /proc/sys/kernel/perf_event_paranoid >/dev/null
ok "System ready for iMC CAS counters"

# ───────── 3. repo clone/update ─────────
step "Cloning / updating GitHub repo"
if [[ -d $REPO_DIR/.git ]]; then git -C "$REPO_DIR" pull --ff-only
else git clone https://github.com/abe5240/iccad.git "$REPO_DIR"; fi
ok "Repo ready"

# ───────── 4. payload check ─────────
step "Checking $INSTALL_DIR exists"
[[ -d "$INSTALL_DIR" ]] || { echo "❌  Missing $INSTALL_DIR"; exit 1; }
ok "Payload located"

# ───────── 5. extract Pin ─────────
step "Extracting Pin ${PIN_VER}"
rm -rf "$PIN_HOME"; mkdir -p "$PIN_HOME"
tar -xzf "$PIN_TAR" -C "$PIN_HOME" --strip-components=1
export PIN_HOME PIN_ROOT
ok "Pin ready"

# ───────── 6. prepare tool tree ─────────
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

# ───────── 8. smoke-test binary ─────────
step "Building test program"
g++ -O3 -std=c++17 "$TEST_CPP" -o "$TEST_BIN"
ok "Test binary → $TEST_BIN"

# ───────── 9. run pintool ─────────
step "Running pintool on test binary"
PIN_ARGS=()
(( VERBOSE )) && PIN_ARGS+=("-verbose" "1")
RAW=$("$PIN_HOME/pin" -t "$TOOL_DIR/obj-intel64/${TOOL_NAME}.so" \
      "${PIN_ARGS[@]}" -- "$TEST_BIN")

printf "\n--- Pintool results ---\n"
if (( VERBOSE )); then
  echo "$RAW"
else
  echo "$RAW" | grep -E '^(ADD:|SUB:|MUL:|DIV:)'
fi

# ───────── 10. DRAM traffic smoke-test ─────────
step "Measuring DRAM traffic with perf"
if perf list 2>/dev/null | grep -q 'uncore_imc/cas_count_read/'; then
    EVENTS="uncore_imc/cas_count_read/,uncore_imc/cas_count_write/"
else
    EVENTS=$(printf 'uncore_imc_%d/cas_count_read/,uncore_imc_%d/cas_count_write/,' {0..5} | sed 's/,$//')
fi

PERF_OUT=$(sudo perf stat -a -e "$EVENTS" -- "$TEST_BIN" 2>&1 >/dev/null)

READS=$(echo "$PERF_OUT" | awk '/cas_count_read/  {sum+=$1} END{print sum+0}')
WRITES=$(echo "$PERF_OUT" | awk '/cas_count_write/ {sum+=$1} END{print sum+0}')
BYTES=$(( 64 * (READS + WRITES) ))

printf "\n--- DRAM traffic (smoke-test) ---\n"
printf "Reads : %'d lines  (%'d bytes)\n"  "$READS"  $((64*READS))
printf "Writes: %'d lines  (%'d bytes)\n"  "$WRITES" $((64*WRITES))
printf "Total : %'d bytes\n"                "$BYTES"

echo
ok "Installation complete (full log: $LOG)"