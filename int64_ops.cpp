// int64_ops.cpp – Pin 3.31
// Count 64‑bit scalar ADD/SUB/MUL/DIV instructions (reg‑reg + reg↔mem)
// and give a sanity check on packed‑QWORD ADD/SUB throughput.
// --------------------------------------------------------------------

#include "pin.H"
#include <iostream>
#include <algorithm>   // std::max
#include <vector>

// -------------------------- configuration ---------------------------
static constexpr bool kExcludeImms  = true;
static constexpr bool kExcludeStack = true;
static constexpr bool kCountMemRmw  = true;   // count reg→mem RMW

// ----------------------------- counters -----------------------------
struct alignas(64) Cnts {
    /* scalar 64‑bit */
    UINT64 add_rr{}, sub_rr{}, mul_rr{}, div_rr{};
    UINT64 add_rm{}, sub_rm{}, mul_rm{}, div_rm{};

    /* SIMD sanity */
    UINT64 simd_addq_insn{}, simd_addq_ops{};
    UINT64 simd_subq_insn{}, simd_subq_ops{};
};

// ------------------------- global bookkeeping -----------------------
static TLS_KEY           g_tls;
static std::vector<Cnts*> g_all;
static PIN_LOCK          g_lock;

// -------------------------- TLS accessor ----------------------------
static inline Cnts* C(THREADID tid)
{
    return static_cast<Cnts*>(PIN_GetThreadData(g_tls, tid));
}

// ------------------------- fast counters ----------------------------
#define FAST PIN_FAST_ANALYSIS_CALL

static VOID FAST AddRR (THREADID t){ C(t)->add_rr++; }
static VOID FAST SubRR (THREADID t){ C(t)->sub_rr++; }
static VOID FAST MulRR (THREADID t){ C(t)->mul_rr++; }
static VOID FAST DivRR (THREADID t){ C(t)->div_rr++; }
static VOID FAST AddRM (THREADID t){ C(t)->add_rm++; }
static VOID FAST SubRM (THREADID t){ C(t)->sub_rm++; }
static VOID FAST MulRM (THREADID t){ C(t)->mul_rm++; }
static VOID FAST DivRM (THREADID t){ C(t)->div_rm++; }

static VOID FAST SimdAddQ (THREADID t, UINT32 n)
{ auto* c=C(t); c->simd_addq_insn++; c->simd_addq_ops+=n; }

static VOID FAST SimdSubQ (THREADID t, UINT32 n)
{ auto* c=C(t); c->simd_subq_insn++; c->simd_subq_ops+=n; }

static VOID FAST SimdAddQMasked (THREADID t, UINT32 n, ADDRINT m)
{
    UINT32 a = __builtin_popcountll(
                   static_cast<UINT64>(m) & ((1ULL<<n)-1));
    auto* c=C(t); c->simd_addq_insn++; c->simd_addq_ops+=a;
}

static VOID FAST SimdSubQMasked (THREADID t, UINT32 n, ADDRINT m)
{
    UINT32 a = __builtin_popcountll(
                   static_cast<UINT64>(m) & ((1ULL<<n)-1));
    auto* c=C(t); c->simd_subq_insn++; c->simd_subq_ops+=a;
}

// ----------------------------- helpers ------------------------------
static inline BOOL Is64Gpr(REG r){ return REG_is_gr64(r); }
static inline BOOL IsStackRg(REG r){ return r==REG_RSP || r==REG_RBP; }

static inline BOOL Is64ALU(xed_iclass_enum_t o)
{
    return o==XED_ICLASS_ADD  || o==XED_ICLASS_SUB  ||
           o==XED_ICLASS_IMUL || o==XED_ICLASS_MUL  ||
           o==XED_ICLASS_IDIV || o==XED_ICLASS_DIV;
}

static inline BOOL IsAddQ(xed_iclass_enum_t o)
{ return o==XED_ICLASS_PADDQ || o==XED_ICLASS_VPADDQ; }

static inline BOOL IsSubQ(xed_iclass_enum_t o)
{ return o==XED_ICLASS_PSUBQ || o==XED_ICLASS_VPSUBQ; }

static inline BOOL HasImm(INS ins){
    if(!kExcludeImms) return FALSE;
    for(UINT32 i=0;i<INS_OperandCount(ins);++i)
        if(INS_OperandIsImmediate(ins,i)) return TRUE;
    return FALSE;
}

static inline BOOL TouchesStack(INS ins){
    if(!kExcludeStack) return FALSE;
    for(UINT32 i=0;i<INS_MaxNumRRegs(ins);++i)
        if(IsStackRg(INS_RegR(ins,i))) return TRUE;
    for(UINT32 i=0;i<INS_MaxNumWRegs(ins);++i)
        if(IsStackRg(INS_RegW(ins,i))) return TRUE;
    return INS_IsStackRead(ins) || INS_IsStackWrite(ins);
}

static inline BOOL Has64RegR(INS ins){
    for(UINT32 i=0;i<INS_MaxNumRRegs(ins);++i)
        if(Is64Gpr(INS_RegR(ins,i)) && !IsStackRg(INS_RegR(ins,i)))
            return TRUE;
    return FALSE;
}

static inline BOOL Has64RegW(INS ins){
    for(UINT32 i=0;i<INS_MaxNumWRegs(ins);++i)
        if(Is64Gpr(INS_RegW(ins,i)) && !IsStackRg(INS_RegW(ins,i)))
            return TRUE;
    return FALSE;
}

static inline BOOL MemRead8 (INS ins){
    for(UINT32 i=0;i<INS_MemoryOperandCount(ins);++i)
        if(INS_MemoryOperandIsRead(ins,i) &&
           INS_MemoryOperandSize(ins,i)==8) return TRUE;
    return FALSE;
}

static inline BOOL MemWrite8(INS ins){
    for(UINT32 i=0;i<INS_MemoryOperandCount(ins);++i)
        if(INS_MemoryOperandIsWritten(ins,i) &&
           INS_MemoryOperandSize(ins,i)==8) return TRUE;
    return FALSE;
}

static inline UINT32 QwordLanes(INS ins){
    UINT32 bytes = 0;
    for(UINT32 i=0;i<INS_MaxNumWRegs(ins);++i){
        REG r = INS_RegW(ins,i);
        if(REG_is_mm(r) || REG_is_xmm(r) ||
           REG_is_ymm(r) || REG_is_zmm(r))
            bytes = std::max<UINT32>(bytes, REG_Size(r));
    }
    return bytes ? bytes/8 : 2;   // default XMM → 2 lanes
}

static inline REG MaskReg(INS ins){
    for(UINT32 i=0;i<INS_MaxNumRRegs(ins);++i){
        REG r = INS_RegR(ins,i);
        if(REG_is_k_mask(r)) return r;
    }
    return REG_INVALID_;
}

// --------------------------- classifiers -----------------------------
static inline BOOL IsRegReg64(INS ins){
    return INS_MemoryOperandCount(ins)==0 &&
           !HasImm(ins) && !TouchesStack(ins) &&
           Has64RegR(ins) && Has64RegW(ins);
}

static inline BOOL IsRegMem64(INS ins){
    if(HasImm(ins) || TouchesStack(ins)) return FALSE;
    BOOL mr  = MemRead8(ins)  && Has64RegW(ins) && !MemWrite8(ins);
    BOOL rmw = MemWrite8(ins) && Has64RegR(ins) && kCountMemRmw;
    return mr || rmw;
}

// ------------------------- thread lifecycle -------------------------
static VOID ThreadStart(THREADID tid, CONTEXT*, INT32, VOID*)
{
    auto* c = new Cnts;
    PIN_SetThreadData(g_tls, c, tid);

    PIN_GetLock(&g_lock, tid + 1);
    g_all.push_back(c);
    PIN_ReleaseLock(&g_lock);
}

// ----------------------- instrumentation ----------------------------
static VOID Instruction(INS ins, VOID*)
{
    const auto opc = static_cast<xed_iclass_enum_t>(INS_Opcode(ins));

    /* SIMD sanity --------------------------------------------------- */
    if(IsAddQ(opc) || IsSubQ(opc)){
        UINT32 lanes = QwordLanes(ins);
        REG    km    = MaskReg(ins);
        BOOL   msk   = km != REG_INVALID_;

        if(IsAddQ(opc)){
            if(msk)
                INS_InsertCall(ins, IPOINT_BEFORE,
                    (AFUNPTR)SimdAddQMasked,
                    IARG_FAST_ANALYSIS_CALL, IARG_THREAD_ID,
                    IARG_UINT32, lanes, IARG_REG_VALUE, km,
                    IARG_END);
            else
                INS_InsertCall(ins, IPOINT_BEFORE,
                    (AFUNPTR)SimdAddQ,
                    IARG_FAST_ANALYSIS_CALL, IARG_THREAD_ID,
                    IARG_UINT32, lanes, IARG_END);
        }else{  // SUBQ
            if(msk)
                INS_InsertCall(ins, IPOINT_BEFORE,
                    (AFUNPTR)SimdSubQMasked,
                    IARG_FAST_ANALYSIS_CALL, IARG_THREAD_ID,
                    IARG_UINT32, lanes, IARG_REG_VALUE, km,
                    IARG_END);
            else
                INS_InsertCall(ins, IPOINT_BEFORE,
                    (AFUNPTR)SimdSubQ,
                    IARG_FAST_ANALYSIS_CALL, IARG_THREAD_ID,
                    IARG_UINT32, lanes, IARG_END);
        }
        return;             // skip scalar path
    }

    /* scalar 64‑bit ALU -------------------------------------------- */
    if(!Is64ALU(opc)) return;

    BOOL rr = IsRegReg64(ins);
    BOOL rm = !rr && IsRegMem64(ins);
    if(!rr && !rm) return;

    AFUNPTR fn = nullptr;
    switch(opc){
        case XED_ICLASS_ADD : fn = (AFUNPTR)(rr?AddRR:AddRM); break;
        case XED_ICLASS_SUB : fn = (AFUNPTR)(rr?SubRR:SubRM); break;
        case XED_ICLASS_IMUL:
        case XED_ICLASS_MUL : fn = (AFUNPTR)(rr?MulRR:MulRM); break;
        case XED_ICLASS_IDIV:
        case XED_ICLASS_DIV : fn = (AFUNPTR)(rr?DivRR:DivRM); break;
        default: return;
    }

    INS_InsertCall(ins, IPOINT_BEFORE, fn,
                   IARG_FAST_ANALYSIS_CALL,
                   IARG_THREAD_ID,
                   IARG_END);
}

// ---------------------------- final report --------------------------
static VOID Fini(INT32, VOID*)
{
    UINT64 add_rr=0, sub_rr=0, mul_rr=0, div_rr=0,
           add_rm=0, sub_rm=0, mul_rm=0, div_rm=0,
           simd_ai=0, simd_ao=0, simd_si=0, simd_so=0;

    for(auto* c : g_all){
        add_rr+=c->add_rr; sub_rr+=c->sub_rr;
        mul_rr+=c->mul_rr; div_rr+=c->div_rr;
        add_rm+=c->add_rm; sub_rm+=c->sub_rm;
        mul_rm+=c->mul_rm; div_rm+=c->div_rm;
        simd_ai+=c->simd_addq_insn; simd_ao+=c->simd_addq_ops;
        simd_si+=c->simd_subq_insn; simd_so+=c->simd_subq_ops;
        delete c;
    }

    std::cout
        << "--- 64‑bit integer arithmetic (no imm, no stack) ---\n"
        << "ADD  rr: " << add_rr << "   rm/mr: " << add_rm << '\n'
        << "SUB  rr: " << sub_rr << "   rm/mr: " << sub_rm << '\n'
        << "MUL  rr: " << mul_rr << "   rm/mr: " << mul_rm << '\n'
        << "DIV  rr: " << div_rr << "   rm/mr: " << div_rm << '\n'
        << "SIMD ADDQ: " << simd_ai << " insns, " << simd_ao
        << " lane‑ops\n"
        << "SIMD SUBQ: " << simd_si << " insns, " << simd_so
        << " lane‑ops\n";
}

// ------------------------------ entry -------------------------------
int main(int argc, char* argv[])
{
    PIN_Init(argc, argv);
    PIN_InitLock(&g_lock);
    g_tls = PIN_CreateThreadDataKey(nullptr);

    PIN_AddThreadStartFunction(ThreadStart, nullptr);
    INS_AddInstrumentFunction(Instruction, nullptr);
    PIN_AddFiniFunction(Fini, nullptr);

    PIN_StartProgram();   // never returns
    return 0;
}
