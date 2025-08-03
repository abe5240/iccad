# ICCAD Roofline Plot Generation

This repository provides everything you need to **build the
_Int64Profiler_ pintool and collect 64-bit integer-operation counts**
for any workload.  The counts can be combined with FLOP and bandwidth
numbers to populate a classic roofline plot for your ICCAD submission.

---

## 1. Quick Start

```bash
# 1) Clone this repo
git clone https://github.com/abe5240/iccad.git
cd iccad

# 2) Install & build Pin + Int64Profiler (≈2 min, first time only)
cp installation/create_int64_profiler.sh ~/
chmod +x ~/create_int64_profiler.sh
~/create_int64_profiler.sh      # one-shot bootstrap

# 3) Copy the lightweight wrapper (optional but convenient)
cp int64profiler.sh ~/
chmod +x ~/int64profiler.sh
```

After step 2 you will have:

```
~/pin-3.31/                               # Pin developer kit
~/pin-3.31/source/tools/Int64Profiler/…   # pintool (.so, sources, objs)
~/logs/<timestamp>.log                    # full build/run logs
```

---

## 2. Directory Layout

```
iccad/
├── installation/           # bootstrap assets
│   ├── create_int64_profiler.sh
│   ├── int64_ops.cpp
│   ├── test_installation.cpp
│   └── intel-pin-linux.tar.gz
├── int64profiler.sh        # run wrapper
└── examples/               # ready-to-use workloads
    ├── cpp_example.cpp
    ├── go_example.go
    └── py_example.py
```

All build artefacts (Pin kit, pintool, logs, test binaries) live
outside the repo—in your home directory or */tmp*.

---

## 3. Running Your Own Workloads

```bash
# C++ (or any native binary)
g++ -O3 -std=c++17 mycode.cpp -o mycode
~/int64profiler.sh ./mycode

# Go
go build -o mygoapp main.go
~/int64profiler.sh ./mygoapp

# Python / shell / Perl / etc.
chmod +x myscript.py
~/int64profiler.sh ./myscript.py -- arg1 arg2
```

> For scripts, Int64Profiler instruments the **interpreter binary**
> (e.g. `python3`) while it runs your code.

---

## 4. Example Workloads

Compile and profile each example to sanity-check your setup:

```bash
# C++
g++ -O3 -std=c++17 examples/cpp_example.cpp -o examples/cpp_example
~/int64profiler.sh examples/cpp_example

# Go
go build -o examples/go_example examples/go_example.go
~/int64profiler.sh examples/go_example

# Python
chmod +x examples/py_example.py
~/int64profiler.sh examples/py_example.py
```

Expected console output (values vary slightly):

```
----- Parsed totals -----
ADD  rr: 203042   rm/mr: 16377
SUB  rr: 101339   rm/mr:  2608
MUL  rr: 100579   rm/mr:     0
DIV  rr: 103040   rm/mr:     0
SIMD ADDQ: 128 insns, 256 lane-ops
SIMD SUBQ:   0 insns,   0 lane-ops
```

---

## 5. Cleaning Up

```bash
rm -rf ~/pin-3.31          # remove Pin kit and pintool
rm    ~/create_int64_profiler.sh
rm    ~/int64profiler.sh
rm -rf ~/logs
```

Re-run the bootstrap script any time to rebuild from scratch.

---

## 6. Troubleshooting

| Symptom                              | Fix |
|--------------------------------------|-----|
| `Pin home not found`                 | Run `create_int64_profiler.sh` first. |
| `Int64Profiler.so missing`           | Re-run bootstrap (rebuilds the tool). |
| Target “not executable”              | `chmod +x <file>` or rebuild with `-o`. |
| Need verbose build/run output        | Check the log file in `~/logs/`. |

---

Happy profiling!
