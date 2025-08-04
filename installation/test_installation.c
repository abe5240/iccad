#include <stdint.h>
#include <stdlib.h>

int main(void)
{
    const size_t N = 1UL << 30;              // 1 GiB
    uint8_t *p = aligned_alloc(64, N);

    /* First pass: write 0 → forces page allocation
       Each 64-B line: read-for-ownership (64 B) then store */
    for (size_t i = 0; i < N; i += 64)
        *(volatile uint64_t *)(p + i) = 0;

    /* Second pass: cold-read each line (optional sanity) */
    uint64_t sum = 0;
    for (size_t i = 0; i < N; i += 64)
        sum += *(volatile uint64_t *)(p + i);

    return (int)sum;                          // keep optimiser honest
}
