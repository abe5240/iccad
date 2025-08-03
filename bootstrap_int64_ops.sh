#!/usr/bin/env bash
# ──────────────────────────────────────────────────────────────────────────────
#  bootstrap_int64_ops.sh
#  End‑to‑end installer / builder / smoke‑tester for the “int64_ops” Pin tool.
#
#  ▸ Works on a pristine Ubuntu 22.04 LTS image.
#  ▸ Idempotent – you can re‑run it; existing artefacts are clobbered & rebuilt.
#  ▸ Verbose, emoji‑tagged progress logs for easy visual tracking.
# ──────────────────────────────────────────────────────────────────────────────
set -euo pipefail
IFS=$'\n\t'

### ───────────── 1.  Cosmetic helpers ─────────────────────────────────────────
STEP_EMOJI=('🚀' '📦' '🗜️ ' '🔧' '🏗️ ' '🛠️ ' '🧪' '✅')
ERROR_EMOJI='❌'
step() { echo -e "\n${STEP_EMOJI[$1]}  $2 ..."; }
trap 'echo -e "\n${ERROR_EMOJI}  Something went wrong – aborting."; exit 1' ERR

### ───────────── 2.  Basic variables ─────────────────────────────────────────
REPO_URL="https://github.com/abe5240/iccad.git"
WORKDIR="$HOME/iccad"
PIN_ARCHIVE="intel-pin-linux.tar.gz"   # expected to be in repo root
PIN_DIR="$HOME/pin-3.31"              # final extraction location
INT64_DIR="$PIN_DIR/source/tools/int64_ops"
TEST_BIN="$WORKDIR/test_installation.out"

### ───────────── 3.  Tool‑chain & git ────────────────────────────────────────
step 0 "Installing build tool‑chain (git, g++, make)"
sudo DEBIAN_FRONTEND=noninteractive apt-get update -qq
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        build-essential git ca-certificates 1>/dev/null

### ───────────── 4.  Clone (or refresh) repo ────────────────────────────────
step 1 "Cloning/updating repository"
if [[ -d "$WORKDIR/.git" ]]; then
    git -C "$WORKDIR" pull --quiet
else
    git clone --depth=1 "$REPO_URL" "$WORKDIR" --quiet
fi

### ───────────── 5.  Extract Pin ─────────────────────────────────────────────
step 2 "Extracting Pin"
rm -rf "$PIN_DIR"
mkdir -p "$(dirname "$PIN_DIR")"
tar -xf "$WORKDIR/$PIN_ARCHIVE" -C "$(dirname "$PIN_DIR")"
# Handle unknown inner directory name → move/rename to $PIN_DIR (canonical)
INNER_DIR="$(tar -tf "$WORKDIR/$PIN_ARCHIVE" | head -1 | cut -d/ -f1)"
mv "$(dirname "$PIN_DIR")/$INNER_DIR" "$PIN_DIR"

### ───────────── 6.  Prepare int64_ops tool sources ─────────────────────────
step 3 "Preparing int64_ops tool sources"
rm -rf "$INT64_DIR"
mkdir -p "$INT64_DIR"
cp  "$WORKDIR/int64_ops.cpp"               "$INT64_DIR/"
# Minimal makefile: piggy‑back on Pin’s build system
cat > "$INT64_DIR/Makefile" <<'MAKEFILE'
TOOL_ROOTS := int64_ops
include $(PIN_HOME)/source/tools/Config/makefile.default.rules
MAKEFILE

### ───────────── 7.  Build int64_ops (obj‑intel64/int64_ops.so) ─────────────
step 4 "Building int64_ops (this may take 1‑2 min)"
export PIN_HOME="$PIN_DIR"
make -C "$INT64_DIR"         \
     PIN_HOME="$PIN_HOME"     \
     obj-intel64/int64_ops.so \
     > /dev/null

### ───────────── 8.  Build the test workload ────────────────────────────────
step 5 "Compiling test_installation.cpp workload"
g++ -std=c++17 -O2 -pipe -march=native \
    "$WORKDIR/test_installation.cpp"   \
    -o  "$TEST_BIN"

### ───────────── 9.  Run smoke test via Pin ─────────────────────────────────
step 6 "Running Pin + int64_ops on the test workload"
PIN_CMD="$PIN_DIR/pin -t $INT64_DIR/obj-intel64/int64_ops.so -- $TEST_BIN"
echo "🔹  Command: $PIN_CMD"
echo    "🔹  Output:"
$PIN_CMD | tee /tmp/int64_ops_run.log

### ─────────────10.  All‑good banner ────────────────────────────────────────
step 7 "All tasks completed successfully"
echo -e "Log saved to /tmp/int64_ops_run.log\n"
