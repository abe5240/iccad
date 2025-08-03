# Int64Profiler – Example Workloads

This folder contains three tiny programs—one each for C++, Go, and Python—that you can use
to verify that **Int64Profiler** is working correctly.

| File                | Language | What it Does | How to Run |
|---------------------|----------|--------------|------------|
| `cpp_example.cpp`   | C++17    | Simple loop that exercises 64-bit ADD/SUB/MUL/DIV in registers | `g++ -O3 -std=c++17 cpp_example.cpp -o cpp_example`<br>`~/int64profiler.sh ./cpp_example` |
| `go_example.go`     | Go ≥1.13 | Similar arithmetic loop, compiled Go binary | `go build -o go_example go_example.go`<br>`~/int64profiler.sh ./go_example` |
| `py_example.py`     | Python 3 | Integer math in a Python loop (profiles the interpreter itself) | `chmod +x py_example.py`<br>`~/int64profiler.sh ./py_example.py -- arg1 arg2` |

> **Note**  
> Int64Profiler operates at the machine-instruction level.  
> For C++ and Go you’ll see counts from your program’s own instructions.  
> For Python you’ll see counts from the **Python interpreter** executing your script.

---

## Prerequisites

* You have already run the bootstrap script (e.g. `create_int64_profiler.sh`) so that:
  * Pin 3.31 lives in `~/pin-3.31`
  * `Int64Profiler.so` exists in  
    `~/pin-3.31/source/tools/Int64Profiler/obj-intel64/`
  * `~/int64profiler.sh` is on your `$PATH` (or run it with full path).

If any of those are missing, rerun the bootstrap before continuing.

---

## Quick Start

```bash
# C++ example
g++ -O3 -std=c++17 cpp_example.cpp -o cpp_example
./int64profiler.sh ./cpp_example

# Go example
go build -o go_example go_example.go
./int64profiler.sh ./go_example

# Python example
chmod +x py_example.py
./int64profiler.sh ./py_example.py
