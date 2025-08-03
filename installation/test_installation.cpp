#include <cstdint>
#include <vector>
#include <numeric>
#include <iostream>

// 4 KiB of 64‑bit ints – stays hot in L1, makes reg↔mem ops cheap
static constexpr std::size_t N = 512;

int main() {
    std::vector<std::uint64_t> a(N), b(N);
    std::iota(a.begin(), a.end(), 1);          // 1,2,3,…
    std::fill(b.begin(), b.end(), 3);          // 3,3,3,…

    std::uint64_t add = 0, sub = 0, mul = 1, div = 1;

    for (std::size_t i = 0; i < N; ++i) {
        // --- reg‑mem path (a[i] in memory, accumulator in register) ---
        add += a[i];
        sub -= a[i];
        mul *= a[i];
        div /= (a[i] | 1);                     // never divide by zero
    }

    // --- reg‑reg path (both operands already in registers) ---
    std::uint64_t x = 1234567890123ULL;
    std::uint64_t y = 9876543210987ULL;

    for (std::size_t i = 0; i < 100000; ++i) {
        add += y;              // ADD r64,r64
        sub -= x;              // SUB r64,r64
        mul *= ((x & 7) + 1);  // IMUL r64,r64   (no immediates)
        div /= ((y & 7) + 1);  // DIV  r64
        ++x; --y;
    }

    std::cout << "dummy: " << add+sub+mul+div << '\n';
    return 0;
}