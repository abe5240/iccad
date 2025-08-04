// int64_ops.cpp – Pin 3.31 (counts only while `toBenchmark()` runs)
//
// Build:
//   make -C $PIN_HOME/source/tools/Int64Profiler \
//        PIN_CXXFLAGS_EXTRA="-std=c++17" \
///       obj-intel64/int64_ops.so
//
// Run:
//   $PIN_HOME/pin -t $PIN_HOME/source/tools/Int64Profiler/obj-int64/int64_ops.so \
//     -- ./your_program
//   (add -func <name> to profile a different routine)
//
// ------------------------------------------------------------------
#include "pin.H"
#include <iostream>
#include <algorithm>
#include <vector>
#include <string>          

// ───────── command-line knobs ─────────
KNOB<std::string> knobFunc(
    KNOB_MODE_WRITEONCE, "pintool",
    "func", "toBenchmark",
    "Name of function whose body should be counted");

KNOB<BOOL> knobVerbose(
    KNOB_MODE_WRITEONCE, "pintool",
    "verbose", "0",
    "Print full per-opcode breakdown");

// ───────── compile-time filters ─────────
static constexpr bool kExcludeImms  = true;
static constexpr bool kExcludeStack = true;
static constexpr bool kCountMemRmw  = true;

// ───────── per-thread counters ─────────
struct alignas(64) Cnts {
    UINT64 add_rr{}, sub_rr{}, adc_rr{}, sbb_rr{};
    UINT64 mul_rr{}, mulx_rr{}, adcx_rr{}, adox_rr{}, div_rr{};
    UINT64 add_rm{}, sub_rm{}, adc_rm{}, sbb_rm{};
    UINT64 mul_rm{}, mulx_rm{}, adcx_rm{}, adox_rm{}, div_rm{};
    UINT64 simd_addq_insn{}, simd_addq_ops{};
    UINT64 simd_subq_insn{}, simd_subq_ops{};
    UINT64 imm_ops{};
};

static TLS_KEY            g_tls_cnts;   // pointer → Cnts
static TLS_KEY            g_tls_flag;   // nullptr / non-nullptr = counting?
static std::vector<Cnts*> g_all;
static PIN_LOCK           g_lock;

static inline Cnts* C(THREADID t)
{ return static_cast<Cnts*>(PIN_GetThreadData(g_tls_cnts, t)); }

static inline bool Counting(THREADID t)
{ return PIN_GetThreadData(g_tls_flag, t) != nullptr; }

// ───────── fast increment helpers ─────────
#define FAST PIN_FAST_ANALYSIS_CALL
#define DEF_FAST(fn) static VOID FAST fn(THREADID t){ C(t)->fn++; }

DEF_FAST(add_rr)  DEF_FAST(sub_rr)  DEF_FAST(adc_rr)  DEF_FAST(sbb_rr)
DEF_FAST(mul_rr)  DEF_FAST(mulx_rr) DEF_FAST(adcx_rr) DEF_FAST(adox_rr)
DEF_FAST(div_rr)
DEF_FAST(add_rm)  DEF_FAST(sub_rm)  DEF_FAST(adc_rm)  DEF_FAST(sbb_rm)
DEF_FAST(mul_rm)  DEF_FAST(mulx_rm) DEF_FAST(adcx_rm) DEF_FAST(adox_rm)
DEF_FAST(div_rm)

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
static VOID FAST ImmOp(THREADID t)
{ C(t)->imm_ops++; }

// ───────── helpers ─────────
static inline BOOL Is64Gpr(REG r){ return REG_is_gr64(r); }
static inline BOOL IsStackRg(REG r){ return r==REG_RSP || r==REG_RBP; }

static inline BOOL HasImm(INS ins){
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
    return bytes ? bytes/8 : 2;
}
static inline REG MaskReg(INS ins){
    for(UINT32 i=0;i<INS_MaxNumRRegs(ins);++i){
        REG r = INS_RegR(ins,i);
        if(REG_is_k_mask(r)) return r;
    }
    return REG_INVALID_;
}

// ───────── opcode classifiers ─────────
static inline BOOL Is64ALU(xed_iclass_enum_t o)
{
    switch(o){
        case XED_ICLASS_ADD: case XED_ICLASS_SUB:
        case XED_ICLASS_ADC: case XED_ICLASS_SBB:
        case XED_ICLASS_IMUL: case XED_ICLASS_MUL:
        case XED_ICLASS_MULX:
        case XED_ICLASS_ADCX: case XED_ICLASS_ADOX:
        case XED_ICLASS_IDIV: case XED_ICLASS_DIV:
            return TRUE;
        default: return FALSE;
    }
}
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

// ───────── thread lifecycle ─────────
static VOID ThreadStart(THREADID tid, CONTEXT*, INT32, VOID*)
{
    auto* c = new Cnts;
    PIN_SetThreadData(g_tls_cnts, c, tid);
    PIN_SetThreadData(g_tls_flag, nullptr, tid);

    PIN_GetLock(&g_lock, tid+1);
    g_all.push_back(c);
    PIN_ReleaseLock(&g_lock);
}

// ───────── region toggles ─────────
static VOID Enter(THREADID t) { PIN_SetThreadData(g_tls_flag,(VOID*)1,t); }
static VOID Leave(THREADID t) { PIN_SetThreadData(g_tls_flag,nullptr,t); }

static VOID ImageLoad(IMG img, VOID*)
{
    RTN rtn = RTN_FindByName(img, knobFunc.Value().c_str());
    if(!RTN_Valid(rtn)) return;

    RTN_Open(rtn);
    RTN_InsertCall(rtn, IPOINT_BEFORE, (AFUNPTR)Enter,
                   IARG_THREAD_ID, IARG_END);
    RTN_InsertCall(rtn, IPOINT_AFTER,  (AFUNPTR)Leave,
                   IARG_THREAD_ID, IARG_END);
    RTN_Close(rtn);
}

// ───────── instruction instrumentation ─────────
static VOID Instruction(INS ins, VOID*)
{
    if(!Counting(PIN_ThreadId())) return;

    const auto opc = static_cast<xed_iclass_enum_t>(INS_Opcode(ins));

    /* SIMD sanity */
    if(opc==XED_ICLASS_PADDQ || opc==XED_ICLASS_VPADDQ ||
       opc==XED_ICLASS_PSUBQ || opc==XED_ICLASS_VPSUBQ){
        UINT32 lanes = QwordLanes(ins);
        REG km = MaskReg(ins);
        if(opc==XED_ICLASS_PADDQ || opc==XED_ICLASS_VPADDQ){
            INS_InsertCall(ins, IPOINT_BEFORE,
                km!=REG_INVALID_? (AFUNPTR)SimdAddQMasked : (AFUNPTR)SimdAddQ,
                IARG_FAST_ANALYSIS_CALL, IARG_THREAD_ID,
                IARG_UINT32, lanes,
                km!=REG_INVALID_? IARG_REG_VALUE : IARG_UINT32,
                km!=REG_INVALID_? km             : (ADDRINT)0,
                IARG_END);
        }else{
            INS_InsertCall(ins, IPOINT_BEFORE,
                km!=REG_INVALID_? (AFUNPTR)SimdSubQMasked : (AFUNPTR)SimdSubQ,
                IARG_FAST_ANALYSIS_CALL, IARG_THREAD_ID,
                IARG_UINT32, lanes,
                km!=REG_INVALID_? IARG_REG_VALUE : IARG_UINT32,
                km!=REG_INVALID_? km             : (ADDRINT)0,
                IARG_END);
        }
        return;
    }

    /* scalar ALU */
    if(!Is64ALU(opc)) return;

    if(HasImm(ins)){
        INS_InsertCall(ins, IPOINT_BEFORE, (AFUNPTR)ImmOp,
                       IARG_FAST_ANALYSIS_CALL, IARG_THREAD_ID, IARG_END);
        return;
    }

    BOOL rr = IsRegReg64(ins);
    BOOL rm = !rr && IsRegMem64(ins);
    if(!rr && !rm) return;

    AFUNPTR fn = nullptr;
    switch(opc){
        case XED_ICLASS_ADD : fn = (AFUNPTR)(rr?add_rr:add_rm); break;
        case XED_ICLASS_SUB : fn = (AFUNPTR)(rr?sub_rr:sub_rm); break;
        case XED_ICLASS_ADC : fn = (AFUNPTR)(rr?adc_rr:adc_rm); break;
        case XED_ICLASS_SBB : fn = (AFUNPTR)(rr?sbb_rr:sbb_rm); break;
        case XED_ICLASS_IMUL:
        case XED_ICLASS_MUL : fn = (AFUNPTR)(rr?mul_rr:mul_rm); break;
        case XED_ICLASS_MULX: fn = (AFUNPTR)(rr?mulx_rr:mulx_rm); break;
        case XED_ICLASS_ADCX: fn = (AFUNPTR)(rr?adcx_rr:adcx_rm); break;
        case XED_ICLASS_ADOX: fn = (AFUNPTR)(rr?adox_rr:adox_rm); break;
        case XED_ICLASS_IDIV:
        case XED_ICLASS_DIV : fn = (AFUNPTR)(rr?div_rr:div_rm); break;
        default: return;
    }
    INS_InsertCall(ins, IPOINT_BEFORE, fn,
                   IARG_FAST_ANALYSIS_CALL, IARG_THREAD_ID, IARG_END);
}

// ───────── final report ─────────
static VOID Fini(INT32, VOID*)
{
    Cnts tot{};
    for(auto* c: g_all){
        #define ADD(f) tot.f += c->f
        ADD(add_rr);ADD(sub_rr);ADD(adc_rr);ADD(sbb_rr);
        ADD(mul_rr);ADD(mulx_rr);ADD(adcx_rr);ADD(adox_rr);ADD(div_rr);
        ADD(add_rm);ADD(sub_rm);ADD(adc_rm);ADD(sbb_rm);
        ADD(mul_rm);ADD(mulx_rm);ADD(adcx_rm);ADD(adox_rm);ADD(div_rm);
        ADD(simd_addq_insn);ADD(simd_addq_ops);
        ADD(simd_subq_insn);ADD(simd_subq_ops);
        ADD(imm_ops);
        delete c;
    }

    if(knobVerbose.Value()){
        std::cout<<"--- 64-bit integer arithmetic (inside "
                 <<knobFunc.Value()<<") ---\n"
                 <<"ADD_rr "<<tot.add_rr<<"  ADD_rm "<<tot.add_rm<<"\n"
                 <<"SUB_rr "<<tot.sub_rr<<"  SUB_rm "<<tot.sub_rm<<"\n"
                 <<"MUL_rr "<<tot.mul_rr<<"  MUL_rm "<<tot.mul_rm<<"\n"
                 <<"DIV_rr "<<tot.div_rr<<"  DIV_rm "<<tot.div_rm<<"\n"
                 <<"SIMD ADDQ "<<tot.simd_addq_insn<<" insns / "
                 <<tot.simd_addq_ops<<" ops\n"
                 <<"SIMD SUBQ "<<tot.simd_subq_insn<<" insns / "
                 <<tot.simd_subq_ops<<" ops\n"
                 <<"IMM "<<tot.imm_ops<<" insns\n";
    }else{
        uint64_t ADD = tot.add_rr+tot.add_rm+tot.adc_rr+tot.adc_rm+
                       tot.adcx_rr+tot.adcx_rm+tot.adox_rr+tot.adox_rm;
        uint64_t SUB = tot.sub_rr+tot.sub_rm+tot.sbb_rr+tot.sbb_rm;
        uint64_t MUL = tot.mul_rr+tot.mul_rm+tot.mulx_rr+tot.mulx_rm;
        uint64_t DIV = tot.div_rr+tot.div_rm;
        std::cout<<"--- 64-bit integer arithmetic ("<<knobFunc.Value()<<") ---\n"
                 <<"ADD: "<<ADD<<"\nSUB: "<<SUB<<"\nMUL: "<<MUL<<"\nDIV: "<<DIV<<"\n";
    }
}

// ───────── entry ─────────
int main(int argc, char* argv[])
{
    PIN_Init(argc, argv);
    PIN_InitLock(&g_lock);
    g_tls_cnts = PIN_CreateThreadDataKey(nullptr);
    g_tls_flag = PIN_CreateThreadDataKey(nullptr);

    PIN_AddThreadStartFunction(ThreadStart, nullptr);
    IMG_AddInstrumentFunction(ImageLoad, nullptr);
    INS_AddInstrumentFunction(Instruction, nullptr);
    PIN_AddFiniFunction(Fini, nullptr);

    PIN_StartProgram();
    return 0;
}