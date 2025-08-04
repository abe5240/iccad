
#include <cstdint>
#include <cstdio>

extern "C" __attribute__((noinline,optimize("O0")))
void toBenchmark()
{
    constexpr int N = 1'000;
    uint64_t a=1,b=2,c=3,d=5;
    for(int i=0;i<N;++i){
        asm volatile(
          "addq  %[b], %[a]\n\t"
          "subq  %[d], %[c]\n\t"
          "imulq %[a], %[b]\n\t"
          "xorq  %%rdx, %%rdx\n\t"
          "movq  %[a], %%rax\n\t"
          "divq  %[c]\n\t"
          :[a]"+r"(a),[b]"+r"(b),[c]"+r"(c)
          :[d]"r"(d) : "rax","rdx","cc");
    }
    std::printf("%llu %llu %llu\n",
        (unsigned long long)a,
        (unsigned long long)b,
        (unsigned long long)c);
}

int main(){ toBenchmark(); }