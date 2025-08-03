#!/usr/bin/env python3
# Minimal Python loop for Int64Profiler (will profile the interpreter)
def main():
    add = sub = mul = div = 1
    for i in range(100000):
        add += i
        sub -= i
        mul *= 2
        div //= 2
    print("dummy:", add + sub + mul + div)

if __name__ == "__main__":
    main()
