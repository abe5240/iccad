#include <cstdint>
#include <cstdlib>
#include <new>      // std::nothrow
#include <iostream> // optional: error message

int main()
{
    constexpr std::size_t N = 1ULL << 30;          // 1 GiB
    constexpr std::size_t LINE = 64;               // cache-line size

    // 64-byte aligned allocation (C++17). std::aligned_alloc returns void*
    std::uint8_t* p = static_cast<std::uint8_t*>(
        std::aligned_alloc(LINE, N));

    if (!p) { std::cerr << "alloc failed\n"; return 1; }

    /* First pass: write 0 – forces physical pages in and issues a
       read-for-ownership + store per 64-B line. */
    for (std::size_t i = 0; i < N; i += LINE)
        *reinterpret_cast<volatile std::uint64_t*>(p + i) = 0;

    /* Second pass: cold-read each line (optional sanity). */
    std::uint64_t sum = 0;
    for (std::size_t i = 0; i < N; i += LINE)
        sum += *reinterpret_cast<volatile std::uint64_t*>(p + i);

    std::free(p);
    return static_cast<int>(sum);                  // defeat dead-code removal
}