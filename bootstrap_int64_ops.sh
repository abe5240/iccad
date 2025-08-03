#!/usr/bin/env bash
# ------------------------------------------------------------
# Fully automatic build‑and‑test for the "int64_ops" Pin tool
# Target OS : Ubuntu 22.04 LTS (vanilla cloud image)
# Repository : https://github.com/abe5240/iccad.git
# ------------------------------------------------------------
set -euo pipefail

# ---------- configuration ----------
REPO_URL="https://github.com/abe5240/iccad.git"
PIN_TGZ="intel-pin-linux.tar.gz"         # shipped in the repo root
PIN_SUBDIR=""                            # set after extraction
TOOL="int64_ops"
TEST="test_installation.cpp"
CORES=$(nproc)

# ---------- 0.   system packages ----------
echo "[+] Installing build tool‑chain ..."
sudo DEBIAN_FRONTEND=noninteractive apt-get update -qq
sudo DEBIAN_FRONTEND=noninteractive apt-get install -yq build-essential git ca-certificates

# ---------- 1.   clone repo ----------
if [[ ! -d iccad ]]; then
    echo "[+] Cloning ${REPO_URL} ..."
    git clone --depth=1 "${REPO_URL}"
fi
cd iccad

# ---------- 2.   unpack Pin kit ----------
echo "[+] Extracting Pin ..."
PIN_SUBDIR=$(tar -tf "${PIN_TGZ}" | head -1 | cut -d/ -f1)
[[ -d "${PIN_SUBDIR}" ]] || tar -xzf "${PIN_TGZ}"
export PIN_ROOT="$PWD/${PIN_SUBDIR}"
export PATH="$PIN_ROOT:$PATH"
echo "    PIN_ROOT = ${PIN_ROOT}"

# ---------- 3.   place tool sources ----------
mkdir -p  "$PIN_ROOT/source/tools/${TOOL}"
cp        "${TOOL}.cpp"                   "$PIN_ROOT/source/tools/${TOOL}/"

cat >"$PIN_ROOT/source/tools/${TOOL}/makefile" <<'MAKE'
TOOL_ROOTS = int64_ops
include $(PIN_ROOT)/source/tools/Config/makefile.rules
MAKE

# ---------- 4.   build pintool ----------
echo "[+] Building pintool ..."
make -C "$PIN_ROOT/source/tools/${TOOL}" clean >/dev/null
make -C "$PIN_ROOT/source/tools/${TOOL}"   -j"$CORES"
TOOL_SO="$PIN_ROOT/source/tools/${TOOL}/obj-intel64/${TOOL}.so"
[[ -f "${TOOL_SO}" ]] || { echo "[-] build failed"; exit 1; }

# ---------- 5.   build workload ----------
echo "[+] Compiling ${TEST} ..."
g++ -O2 -std=c++17 "$TEST" -o test_installation

# ---------- 6.   run under Pin ----------
echo "[+] Running Pin ..."
"$PIN_ROOT/pin" -t "$TOOL_SO" -- ./test_installation