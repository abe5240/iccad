// Minimal 64‑bit integer workload for Int64Profiler
#include <cstdint>
#include <iostream>

int main() {
    std::uint64_t a = 1, b = 2, c = 3, d = 4;
    for (std::uint64_t i = 0; i < 100000; ++i) {
        a += b;   // ADD
        b -= c;   // SUB
        c *= 5;   // MUL
        d /= 2;   // DIV
    }
    std::cout << "dummy: " << (a + b + c + d) << '\n';
    return 0;
}
