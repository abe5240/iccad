// test_int64_ops.cpp – defines the work region `toBenchmark`
// Build:  g++ -std=c++17 -O0 -g test_int64_ops.cpp -o test_int64_ops
#include <cstdint>
#include <cstdio>

__attribute__((noinline,optimize("O0")))
void toBenchmark()
{
    constexpr std::size_t N = 1'000;
    uint64_t a=1,b=2,c=3,d=5;
    for(std::size_t i=0;i<N;++i){
        asm volatile(
            "addq  %[b], %[a]\n\t"
            "subq  %[d], %[c]\n\t"
            "imulq %[a], %[b]\n\t"
            "xorq  %%rdx, %%rdx\n\t"
            "movq  %[a], %%rax\n\t"
            "divq  %[c]\n\t"
            : [a]"+r"(a), [b]"+r"(b), [c]"+r"(c)
            : [d]"r"(d) : "rax","rdx","cc");
    }
    std::printf("%llu %llu %llu\n",
                (unsigned long long)a,
                (unsigned long long)b,
                (unsigned long long)c);
}

int main()
{
    toBenchmark();
    return 0;
}