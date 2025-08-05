// test_installation.cpp
#include <cstdint>
#include <cstdio>
#include <cstdlib>

extern "C" __attribute__((noinline,optimize("O0")))
void toBenchmark()
{
    /* ───── integer-only micro-kernel (same as before) ───── */
    constexpr int ITERS = 1'000;
    uint64_t a = 1, b = 2, c = 3, d = 5;
    for (int i = 0; i < ITERS; ++i) {
        asm volatile(
            "addq  %[b], %[a]\n\t"
            "subq  %[d], %[c]\n\t"
            "imulq %[a], %[b]\n\t"
            "xorq  %%rdx, %%rdx\n\t"
            "movq  %[a], %%rax\n\t"
            "divq  %[c]\n\t"
            : [a] "+r"(a), [b] "+r"(b), [c] "+r"(c)
            : [d] "r"(d)
            : "rax", "rdx", "cc");
    }

    /* ───── 1 GiB DRAM traffic litmus test ───── */
    const size_t N = 1ULL << 30;                  // 1 GiB
    uint8_t* p = static_cast<uint8_t*>(std::aligned_alloc(64, N));

    // Pass 1: write (read-for-ownership + store) every 64-B line
    for (size_t i = 0; i < N; i += 64)
        *(volatile uint64_t*)(p + i) = 0;

    // Pass 2: cold read each line to confirm counts
    uint64_t sum = 0;
    for (size_t i = 0; i < N; i += 64)
        sum += *(volatile uint64_t*)(p + i);

    std::free(p);

    std::printf("%llu %llu %llu %llu\n",
                (unsigned long long)a,
                (unsigned long long)b,
                (unsigned long long)c,
                (unsigned long long)sum);         // keep optimiser honest
}

int main() { toBenchmark(); }