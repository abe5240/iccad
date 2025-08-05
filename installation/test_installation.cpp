// test_installation.cpp
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <tuple>

// Function 1: Performs the integer-only micro-kernel operations.
// It takes references to a, b, and c to modify them directly.
void integer_micro_kernel(uint64_t& a, uint64_t& b, uint64_t& c)
{
    /* ───── integer-only micro-kernel ───── */
    constexpr int ITERS = 1'000;
    const uint64_t d = 5; // d is constant within the loop
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
}

// Function 2: Performs the 1 GiB DRAM traffic test and returns the result.
uint64_t dram_traffic_litmus_test()
{
    /* ───── 1 GiB DRAM traffic litmus test ───── */
    const size_t N = 1ULL << 30; // 1 GiB
    uint8_t* p = static_cast<uint8_t*>(std::aligned_alloc(64, N));

    // Pass 1: write (read-for-ownership + store) every 64-B line
    for (size_t i = 0; i < N; i += 64)
        *(volatile uint64_t*)(p + i) = 0;

    // Pass 2: cold read each line to confirm counts
    uint64_t sum = 0;
    for (size_t i = 0; i < N; i += 64)
        sum += *(volatile uint64_t*)(p + i);

    std::free(p);
    return sum;
}

// The main benchmark function now acts as a wrapper,
// orchestrating the calls to the two sub-functions.
extern "C" __attribute__((noinline,optimize("O0")))
void toBenchmark()
{
    // Initialize variables for the integer kernel
    uint64_t a = 1, b = 2, c = 3;

    // Call the function for CPU-bound integer operations
    integer_micro_kernel(a, b, c);

    // Call the function for memory-bound data movement
    uint64_t sum = dram_traffic_litmus_test();

    // Print the results from both functions to keep the optimizer honest
    std::printf("%llu %llu %llu %llu\n",
                (unsigned long long)a,
                (unsigned long long)b,
                (unsigned long long)c,
                (unsigned long long)sum);
}

int main() { toBenchmark(); }