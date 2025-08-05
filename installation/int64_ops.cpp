// ─────────────────────────────────────────────────────────────────────────────
// Int64Profiler.cpp  –  Intel® Pin 3.31
//
//   Counts 64‑bit *scalar* integer arithmetic instructions
//   (ADD / SUB / ADC / SBB / MUL / IMUL / MULX / ADCX / ADOX / DIV / IDIV).
//
//   • Whole program            : default  (omit -addr)
//   • Region‑scoped            : start counting at <addr>, stop at the first
//                                RET that executes while the region is active.
//
//   Typical use:
//       # whole run
//       pin -t Int64Profiler.so -- ./app
//
//       # only the dynamic slice rooted at toBenchmark()
//       ADDR=$(nm ./app | awk '$3=="toBenchmark"&&$2~/T/{print "0x"$1}')
//       pin -t Int64Profiler.so -addr "$ADDR" -- ./app
//
//   Debugging:
//       ... -dbg 1      # prints basic progress messages
// ─────────────────────────────────────────────────────────────────────────────
#include "pin.H"
#include <iostream>
#include <sstream>
#include <string>
#include <vector>

// ── command‑line knobs ───────────────────────────────────────────────────────
KNOB<std::string> knobAddr(KNOB_MODE_WRITEONCE, "pintool",
                           "addr", "0x0",
                           "Hex start address (0 → whole program)");
KNOB<std::string> knobDbg(KNOB_MODE_WRITEONCE, "pintool",
                          "dbg",  "0",
                          "Debug verbosity (0‑silent, 1‑info, 2‑verbose)");

static int g_dbg = 0;      // set once in main()

#define DBG(level, msg)                                               \
    do { if (g_dbg >= (level))                                        \
         std::cerr << "[Int64Profiler] " << msg << std::endl; } while (0)

// ── per‑thread structures ───────────────────────────────────────────────────
struct alignas(64) Cnts {
    /* reg‑reg */
    UINT64 add_rr{}, sub_rr{}, adc_rr{}, sbb_rr{};
    UINT64 mul_rr{}, mulx_rr{}, adcx_rr{}, adox_rr{}, div_rr{};
    /* reg ↔ mem (64‑bit operands only) */
    UINT64 add_rm{}, sub_rm{}, adc_rm{}, sbb_rm{};
    UINT64 mul_rm{}, mulx_rm{}, adcx_rm{}, adox_rm{}, div_rm{};
};

struct alignas(64) ThreadState {
    Cnts  cnts;
    bool  active = false;      // counting flag
};

static TLS_KEY                     tlsKey;
static PIN_LOCK                    g_lock;
static std::vector<ThreadState*>   g_all;     // gather at fini

// ── global options ──────────────────────────────────────────────────────────
static ADDRINT g_start = 0;   // 0 → whole program
static bool    g_whole = true;

// ── convenience helpers ─────────────────────────────────────────────────────
static inline ThreadState* St(THREADID tid)
{
    return static_cast<ThreadState*>(PIN_GetThreadData(tlsKey, tid));
}
static inline bool Counting(THREADID tid)
{
    return g_whole || St(tid)->active;
}

// ── region toggles ─────────────────────────────────────────────────────────
static VOID StartRegion(THREADID tid)
{
    St(tid)->active = true;
    DBG(2, "StartRegion (tid=" << tid << ")");
}
static VOID StopRegion(THREADID tid)
{
    if (St(tid)->active) {
        St(tid)->active = false;
        DBG(2, "StopRegion (tid=" << tid << ")");
    }
}

// ── fast counter stubs (one per bucket) ─────────────────────────────────────
#define DEF_COUNTER(name)                                             \
    static VOID PIN_FAST_ANALYSIS_CALL name(THREADID tid)             \
    { if (Counting(tid)) St(tid)->cnts.name++; }

DEF_COUNTER(add_rr)  DEF_COUNTER(sub_rr)  DEF_COUNTER(adc_rr)  DEF_COUNTER(sbb_rr)
DEF_COUNTER(mul_rr)  DEF_COUNTER(mulx_rr) DEF_COUNTER(adcx_rr) DEF_COUNTER(adox_rr)
DEF_COUNTER(div_rr)
DEF_COUNTER(add_rm)  DEF_COUNTER(sub_rm)  DEF_COUNTER(adc_rm)  DEF_COUNTER(sbb_rm)
DEF_COUNTER(mul_rm)  DEF_COUNTER(mulx_rm) DEF_COUNTER(adcx_rm) DEF_COUNTER(adox_rm)
DEF_COUNTER(div_rm)

// ── instruction classification helpers ─────────────────────────────────────
static inline bool Is64Gpr(REG r)   { return REG_is_gr64(r); }
static inline bool IsStack(REG r)   { return r == REG_RSP || r == REG_RBP; }

static inline bool HasImm(INS ins)
{
    for (UINT32 i = 0; i < INS_OperandCount(ins); ++i)
        if (INS_OperandIsImmediate(ins, i)) return true;
    return false;
}
static inline bool TouchesStack(INS ins)
{
    for (UINT32 i = 0; i < INS_MaxNumRRegs(ins); ++i)
        if (IsStack(INS_RegR(ins, i))) return true;
    for (UINT32 i = 0; i < INS_MaxNumWRegs(ins); ++i)
        if (IsStack(INS_RegW(ins, i))) return true;
    return INS_IsStackRead(ins) || INS_IsStackWrite(ins);
}
static inline bool Has64R(INS ins)
{
    for (UINT32 i = 0; i < INS_MaxNumRRegs(ins); ++i) {
        REG r = INS_RegR(ins, i);
        if (Is64Gpr(r) && !IsStack(r)) return true;
    }
    return false;
}
static inline bool Has64W(INS ins)
{
    for (UINT32 i = 0; i < INS_MaxNumWRegs(ins); ++i) {
        REG r = INS_RegW(ins, i);
        if (Is64Gpr(r) && !IsStack(r)) return true;
    }
    return false;
}
static inline bool MemRead8(INS ins)
{
    for (UINT32 i = 0; i < INS_MemoryOperandCount(ins); ++i)
        if (INS_MemoryOperandIsRead(ins, i) &&
            INS_MemoryOperandSize(ins, i) == 8) return true;
    return false;
}
static inline bool MemWrite8(INS ins)
{
    for (UINT32 i = 0; i < INS_MemoryOperandCount(ins); ++i)
        if (INS_MemoryOperandIsWritten(ins, i) &&
            INS_MemoryOperandSize(ins, i) == 8) return true;
    return false;
}
static inline bool IsALU64(xed_iclass_enum_t opc)
{
    switch (opc) {
        case XED_ICLASS_ADD:  case XED_ICLASS_SUB:  case XED_ICLASS_ADC:
        case XED_ICLASS_SBB:  case XED_ICLASS_IMUL: case XED_ICLASS_MUL:
        case XED_ICLASS_MULX: case XED_ICLASS_ADCX: case XED_ICLASS_ADOX:
        case XED_ICLASS_IDIV: case XED_ICLASS_DIV:
            return true;
        default:
            return false;
    }
}
static inline bool IsRegReg64(INS ins)
{
    return INS_MemoryOperandCount(ins) == 0 &&
           !HasImm(ins) && !TouchesStack(ins) &&
           Has64R(ins) && Has64W(ins);
}
static inline bool IsRegMem64(INS ins)
{
    if (HasImm(ins) || TouchesStack(ins)) return false;
    bool mr  = MemRead8(ins)  && Has64W(ins) && !MemWrite8(ins);
    bool rmw = MemWrite8(ins) && Has64R(ins);          // count RMW as reg‑mem
    return mr || rmw;
}

// ── instrumentation – arithmetic instructions ───────────────────────────────
static VOID InstrumentArith(INS ins, VOID*)
{
    if (!IsALU64(static_cast<xed_iclass_enum_t>(INS_Opcode(ins)))) return;
    if (HasImm(ins)) return;

    bool rr = IsRegReg64(ins);
    bool rm = !rr && IsRegMem64(ins);
    if (!rr && !rm) return;

    AFUNPTR fn = nullptr;
    switch (INS_Opcode(ins)) {
        case XED_ICLASS_ADD : fn = (AFUNPTR)(rr ? add_rr  : add_rm);  break;
        case XED_ICLASS_SUB : fn = (AFUNPTR)(rr ? sub_rr  : sub_rm);  break;
        case XED_ICLASS_ADC : fn = (AFUNPTR)(rr ? adc_rr  : adc_rm);  break;
        case XED_ICLASS_SBB : fn = (AFUNPTR)(rr ? sbb_rr  : sbb_rm);  break;
        case XED_ICLASS_MUL :
        case XED_ICLASS_IMUL: fn = (AFUNPTR)(rr ? mul_rr  : mul_rm);  break;
        case XED_ICLASS_MULX: fn = (AFUNPTR)(rr ? mulx_rr : mulx_rm); break;
        case XED_ICLASS_ADCX: fn = (AFUNPTR)(rr ? adcx_rr : adcx_rm); break;
        case XED_ICLASS_ADOX: fn = (AFUNPTR)(rr ? adox_rr : adox_rm); break;
        case XED_ICLASS_DIV :
        case XED_ICLASS_IDIV: fn = (AFUNPTR)(rr ? div_rr  : div_rm);  break;
        default: return;
    }
    INS_InsertCall(ins, IPOINT_BEFORE, fn,
                   IARG_FAST_ANALYSIS_CALL, IARG_THREAD_ID, IARG_END);
}

// ── instrumentation – region start & stop ───────────────────────────────────
static VOID InstrumentRegion(INS ins, VOID*)
{
    /* start: exact address match */
    if (!g_whole && INS_Address(ins) == g_start) {
        INS_InsertCall(ins, IPOINT_BEFORE, (AFUNPTR)StartRegion,
                       IARG_THREAD_ID, IARG_END);
    }

    /* stop: first RET executed while region is active */
    if (INS_IsRet(ins)) {
        INS_InsertCall(ins, IPOINT_BEFORE, (AFUNPTR)StopRegion,
                       IARG_FAST_ANALYSIS_CALL, IARG_THREAD_ID, IARG_END);
    }
}

// ── thread lifecycle ────────────────────────────────────────────────────────
static VOID ThreadStart(THREADID tid, CONTEXT*, INT32, VOID*)
{
    auto* st = new ThreadState;
    PIN_SetThreadData(tlsKey, st, tid);

    PIN_GetLock(&g_lock, tid + 1);
    g_all.push_back(st);
    PIN_ReleaseLock(&g_lock);
}

// ── report ──────────────────────────────────────────────────────────────────
static VOID Fini(INT32, VOID*)
{
    Cnts total{};
    for (auto* st : g_all) {
#define ACC(f) total.f += st->cnts.f
        ACC(add_rr);  ACC(sub_rr);  ACC(adc_rr);  ACC(sbb_rr);
        ACC(mul_rr);  ACC(mulx_rr); ACC(adcx_rr); ACC(adox_rr); ACC(div_rr);
        ACC(add_rm);  ACC(sub_rm);  ACC(adc_rm);  ACC(sbb_rm);
        ACC(mul_rm);  ACC(mulx_rm); ACC(adcx_rm); ACC(adox_rm); ACC(div_rm);
        delete st;
    }

    const auto ADD = total.add_rr + total.add_rm + total.adc_rr + total.adc_rm +
                     total.adcx_rr + total.adcx_rm + total.adox_rr + total.adox_rm;
    const auto SUB = total.sub_rr + total.sub_rm + total.sbb_rr + total.sbb_rm;
    const auto MUL = total.mul_rr + total.mul_rm + total.mulx_rr + total.mulx_rm;
    const auto DIV = total.div_rr + total.div_rm;

    std::cout << "ADD: " << ADD << '\n'
              << "SUB: " << SUB << '\n'
              << "MUL: " << MUL << '\n'
              << "DIV: " << DIV << std::endl;
}

// ── main ─────────────────────────────────────────────────────────────────────
int main(int argc, char* argv[])
{
    PIN_InitSymbols();             // enable symbol lookup for RTN names
    PIN_Init(argc, argv);

    g_start = strtoull(knobAddr.Value().c_str(), nullptr, 0);
    g_whole = (g_start == 0);
    g_dbg   = std::atoi(knobDbg.Value().c_str());

    if (!g_whole) DBG(1, "region starts at 0x" << std::hex << g_start);
    else          DBG(1, "whole‑program mode");

    /* prepare TLS and locks */
    PIN_InitLock(&g_lock);
    tlsKey = PIN_CreateThreadDataKey(nullptr);

    /* register callbacks */
    PIN_AddThreadStartFunction(ThreadStart,   nullptr);
    INS_AddInstrumentFunction (InstrumentRegion, nullptr);   // start/stop hooks
    INS_AddInstrumentFunction (InstrumentArith,  nullptr);   // counting
    PIN_AddFiniFunction       (Fini,           nullptr);

    PIN_StartProgram();     // never returns
    return 0;
}