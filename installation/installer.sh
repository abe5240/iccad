#!/usr/bin/env bash
###############################################################################
# installer.sh
# Build Int64Profiler, smoke-test it, and verify DRAM counters.
# Default = compact pintool output; add --verbose for full opcode dump.
###############################################################################
set -euo pipefail

# ────────── CLI flag ──────────
VERBOSE=0
[[ "${1:-}" == "--verbose" ]] && { VERBOSE=1; shift; }

# ────────── config ──────────
PIN_VER="3.31"
PIN_HOME="$HOME/pin-${PIN_VER}"
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

# ───────── human-readable formatter ─────────
hr_bytes () {                    # $1 = integer bytes
    local bytes=$1
    local units=(B KB MB GB TB)
    local exp=0
    while (( bytes >= 1024 && exp < ${#units[@]}-1 )); do
        bytes=$(( bytes / 1024 ))
        ((exp++))
    done
    # recompute floating value with two decimals
    local value
    value=$(awk "BEGIN {printf \"%.2f\", $1/(1024^$exp)}")
    printf "%s %s" "$value" "${units[$exp]}"
}

# ───────── helper: parse perf value with unit ─────────
parse_perf_value() {
    local line=$1
    local value=$(echo "$line" | cut -d',' -f1)
    local unit=$(echo "$line" | cut -d',' -f2)
    
    # Convert decimal value to integer for bash arithmetic
    local int_val=$(echo "$value" | awk '{printf "%.0f", $1}')
    
    # Convert to bytes based on unit
    case "$unit" in
        "MiB") echo $(( int_val * 1048576 )) ;;
        "GiB") echo $(( int_val * 1073741824 )) ;;
        "KiB") echo $(( int_val * 1024 )) ;;
        "B"|"") echo "$int_val" ;;
        *) 
            # No unit or unknown unit - assume raw cache line count
            echo $(( int_val * 64 )) ;;
    esac
}

# ───────── 1. packages ─────────
step "Installing compiler, Pin prerequisites, and perf tools"
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
step "Setting /proc/sys/kernel/perf_event_paranoid → -1"
echo -1 | sudo tee /proc/sys/kernel/perf_event_paranoid >/dev/null
ok "Uncore counters accessible"

# ───────── 3. clone / update repo ─────────
step "Cloning / updating iccad repo"
if [[ -d $REPO_DIR/.git ]]; then git -C "$REPO_DIR" pull --ff-only
else git clone https://github.com/abe5240/iccad.git "$REPO_DIR"; fi
ok "Repo ready"

# ───────── 4. check payload ─────────
[[ -d "$INSTALL_DIR" ]] || { echo "❌  $INSTALL_DIR missing"; exit 1; }

# ───────── 5. extract Pin ─────────
step "Extracting Pin ${PIN_VER}"
rm -rf "$PIN_HOME"; mkdir -p "$PIN_HOME"
tar -xzf "$PIN_TAR" -C "$PIN_HOME" --strip-components=1
export PIN_HOME
ok "Pin ready"

# ───────── 6. prepare pintool tree ─────────
step "Setting up ${TOOL_NAME} source"
rm -rf "$TOOL_DIR"
cp -r "$PIN_HOME/source/tools/MyPinTool" "$TOOL_DIR"
rm -f  "$TOOL_DIR/MyPinTool.cpp"
cp     "$SRC_CPP" "$TOOL_DIR/${TOOL_NAME}.cpp"
sed -Ei 's/TEST_TOOL_ROOTS[[:space:]]*:=.*/TEST_TOOL_ROOTS := '"$TOOL_NAME"'/' "$TOOL_DIR/makefile.rules"
sed -Ei 's/TOOL_ROOTS[[:space:]]*:=.*/TOOL_ROOTS := '"$TOOL_NAME"'/'           "$TOOL_DIR/makefile.rules"
sed -i  's/\<MyPinTool\>/'"$TOOL_NAME"'/g'                                      "$TOOL_DIR/makefile.rules"
ok "makefile.rules patched"

# ───────── 7. compile pintool ─────────
step "Building pintool"
make -s -C "$TOOL_DIR" clean
make -s -C "$TOOL_DIR"
ok "Pintool built"

# ───────── 8. build test app ─────────
g++ -O3 -std=c++17 "$TEST_CPP" -o "$TEST_BIN"

# ───────── 9. pintool smoke-test ─────────
step "Running pintool smoke-test"
PIN_ARGS=(); (( VERBOSE )) && PIN_ARGS+=("-verbose" "1")
RAW=$("$PIN_HOME/pin" -t "$TOOL_DIR/obj-intel64/${TOOL_NAME}.so" \
      "${PIN_ARGS[@]}" -- "$TEST_BIN")

printf "\n--- Pintool results ---\n"
if (( VERBOSE )); then echo "$RAW"
else                   echo "$RAW" | grep -E '^(ADD:|SUB:|MUL:|DIV:)'
fi

# ───────── 10. DRAM traffic smoke‑test (FIXED) ─────────
step "Measuring DRAM traffic with perf"
if perf list 2>/dev/null | grep -q 'uncore_imc/cas_count_read/'; then
    EVENTS="uncore_imc/cas_count_read/,uncore_imc/cas_count_write/"
else
    EVENTS=$(printf 'uncore_imc_%d/cas_count_read/,uncore_imc_%d/cas_count_write/,' {0..5} | sed 's/,$//')
fi

PERF=$(sudo perf stat -x, --no-scale -a -e "$EVENTS" -- "$TEST_BIN" 2>&1 >/dev/null)

# Parse DRAM traffic with proper unit handling
READ_BYTES=0
WRITE_BYTES=0

# Process all read events
while IFS= read -r line; do
    if [[ -n "$line" ]]; then
        bytes=$(parse_perf_value "$line")
        READ_BYTES=$(( READ_BYTES + bytes ))
    fi
done < <(echo "$PERF" | grep -i "cas_count_read")

# Process all write events
while IFS= read -r line; do
    if [[ -n "$line" ]]; then
        bytes=$(parse_perf_value "$line")
        WRITE_BYTES=$(( WRITE_BYTES + bytes ))
    fi
done < <(echo "$PERF" | grep -i "cas_count_write")

# Total bytes and cache lines
BYTES=$(( READ_BYTES + WRITE_BYTES ))
READS=$(( READ_BYTES / 64 ))
WRITES=$(( WRITE_BYTES / 64 ))

printf "\n--- DRAM traffic (smoke-test) ---\n"
printf "Reads : %'d lines (%s)\n"  "$READS"  "$(hr_bytes $READ_BYTES)"
printf "Writes: %'d lines (%s)\n"  "$WRITES" "$(hr_bytes $WRITE_BYTES)"
printf "Total : %s\n"              "$(hr_bytes $BYTES)"

# ───────── 11. Arithmetic‑intensity smoke‑test ─────────
step "Calculating integer arithmetic intensity"

# Always collect the compact 4‑line totals (cheap second run)
AGG_RAW=$("$PIN_HOME/pin" -t "$TOOL_DIR/obj-intel64/${TOOL_NAME}.so" -- "$TEST_BIN")

INT_OPS=$(echo "$AGG_RAW" | \
          awk '/^(ADD:|SUB:|MUL:|DIV:)/ {gsub(/[,]/,"",$2); sum += $2} END{print sum+0}')

AI=$(awk -v ops="$INT_OPS" -v bytes="$BYTES" \
         'BEGIN {if (bytes==0) print "n/a"; else printf "%.3f", ops/bytes}')

printf "\n--- Integer arithmetic intensity (smoke-test) ---\n"
printf "Integer ops : %'d\n" "$INT_OPS"
printf "DRAM bytes  : %s\n"  "$(hr_bytes $BYTES)"
printf "Intensity   : %s ops/byte\n" "$AI"

echo
ok "Installation complete (log: $LOG)"