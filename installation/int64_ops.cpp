// ─────────────────────────────────────────────────────────────────────────────
// Int64Profiler.cpp  –  Intel® Pin 3.31
//
//   Purpose     : Count *64-bit scalar* integer arithmetic instructions
//                 (ADD/SUB/ADC/SBB/MUL/IMUL/MULX/AD*X/DIV/IDIV) either
//                 • for the *entire* program               (default),   or
//                 • only while execution is within a region bounded by
//                   <start-address> … first RET            (-addr 0xXXXX).
//
//   Build inside the tool tree:
//       cd $PIN_HOME/source/tools/Int64Profiler
//       make                 # produces obj-intel64/Int64Profiler.so
//
//   Common runtime examples:
//       # whole program
//       pin -t Int64Profiler.so -- ./app
//
//       # only inside toBenchmark()
//       ADDR=$(nm ./app | awk '$3=="toBenchmark"&&$2=="T"{print "0x"$1}')
//       pin -t Int64Profiler.so -addr $ADDR -- ./app
//
//   Output (compact):
//       ADD: <total>
//       SUB: <total>
//       MUL: <total>
//       DIV: <total>
// ─────────────────────────────────────────────────────────────────────────────
#include "pin.H"
#include <algorithm>
#include <iomanip>
#include <iostream>
#include <sstream>
#include <string>
#include <vector>

//------------------------------------------------------------------------------
//  Command-line knob
//------------------------------------------------------------------------------
KNOB<std::string> knobAddr(KNOB_MODE_WRITEONCE, "pintool",
                           "addr", "0x0",
                           "Hex start address (0 → count whole program)");

//------------------------------------------------------------------------------
//  Per-thread counters  (aligned to avoid false sharing)
//------------------------------------------------------------------------------
struct alignas(64) Cnts {
    /* register-to-register */
    UINT64 add_rr{}, sub_rr{}, adc_rr{}, sbb_rr{};
    UINT64 mul_rr{}, mulx_rr{}, adcx_rr{}, adox_rr{}, div_rr{};

    /* register↔memory (8-byte operands only) */
    UINT64 add_rm{}, sub_rm{}, adc_rm{}, sbb_rm{};
    UINT64 mul_rm{}, mulx_rm{}, adcx_rm{}, adox_rm{}, div_rm{};
};

//------------------------------------------------------------------------------
//  Globals
//------------------------------------------------------------------------------
static TLS_KEY g_tlsCnts;   // → Cnts per thread
static TLS_KEY g_tlsFlag;   // nullptr  : not counting
                            // non-null : counting region active

static PIN_LOCK           g_lock;
static std::vector<Cnts*> g_all;   // collect per-thread objects at fini

static ADDRINT g_startAddr = 0;    // 0 ⇒ whole program (no gating)
static bool    g_wholeProg = true; // true when addr knob == 0

//------------------------------------------------------------------------------
//  Convenience accessors
//------------------------------------------------------------------------------
static inline Cnts* C(THREADID tid) {
    return static_cast<Cnts*>(PIN_GetThreadData(g_tlsCnts, tid));
}

static inline bool Counting(THREADID tid) {
    /*  Whole-program mode → always true.
        Region-gated mode  → check TLS flag.                     */
    return g_wholeProg ||
           PIN_GetThreadData(g_tlsFlag, tid) != nullptr;
}

//------------------------------------------------------------------------------
//  Region-toggle helpers (used only when g_wholeProg == false)
//------------------------------------------------------------------------------
static VOID PIN_FAST_ANALYSIS_CALL StartRegion(THREADID tid) {
    PIN_SetThreadData(g_tlsFlag, reinterpret_cast<void*>(1), tid);
}

static VOID PIN_FAST_ANALYSIS_CALL StopRegion(THREADID tid) {
    PIN_SetThreadData(g_tlsFlag, nullptr, tid);
}

//------------------------------------------------------------------------------
//  Fast counter macro – increments only when Counting() is true
//------------------------------------------------------------------------------
#define FAST PIN_FAST_ANALYSIS_CALL
#define DEF_FAST(name)                                   \
    static VOID FAST name(THREADID tid) {                \
        if (Counting(tid)) C(tid)->name++;               \
    }

DEF_FAST(add_rr)  DEF_FAST(sub_rr)  DEF_FAST(adc_rr)  DEF_FAST(sbb_rr)
DEF_FAST(mul_rr)  DEF_FAST(mulx_rr) DEF_FAST(adcx_rr) DEF_FAST(adox_rr)
DEF_FAST(div_rr)
DEF_FAST(add_rm)  DEF_FAST(sub_rm)  DEF_FAST(adc_rm)  DEF_FAST(sbb_rm)
DEF_FAST(mul_rm)  DEF_FAST(mulx_rm) DEF_FAST(adcx_rm) DEF_FAST(adox_rm)
DEF_FAST(div_rm)

//------------------------------------------------------------------------------
//  Helpers for instruction classification
//------------------------------------------------------------------------------
static inline bool Is64Gpr(REG r)     { return REG_is_gr64(r); }
static inline bool IsStackReg(REG r)  { return r == REG_RSP || r == REG_RBP; }

static inline bool HasImm(INS ins) {
    for (UINT32 i = 0; i < INS_OperandCount(ins); ++i)
        if (INS_OperandIsImmediate(ins, i)) return true;
    return false;
}

static inline bool TouchesStack(INS ins) {
    for (UINT32 i = 0; i < INS_MaxNumRRegs(ins); ++i)
        if (IsStackReg(INS_RegR(ins, i))) return true;
    for (UINT32 i = 0; i < INS_MaxNumWRegs(ins); ++i)
        if (IsStackReg(INS_RegW(ins, i))) return true;
    return INS_IsStackRead(ins) || INS_IsStackWrite(ins);
}

static inline bool Has64RegR(INS ins) {
    for (UINT32 i = 0; i < INS_MaxNumRRegs(ins); ++i) {
        REG r = INS_RegR(ins, i);
        if (Is64Gpr(r) && !IsStackReg(r)) return true;
    }
    return false;
}

static inline bool Has64RegW(INS ins) {
    for (UINT32 i = 0; i < INS_MaxNumWRegs(ins); ++i) {
        REG r = INS_RegW(ins, i);
        if (Is64Gpr(r) && !IsStackReg(r)) return true;
    }
    return false;
}

static inline bool MemRead8(INS ins) {
    for (UINT32 i = 0; i < INS_MemoryOperandCount(ins); ++i)
        if (INS_MemoryOperandIsRead(ins, i) &&
            INS_MemoryOperandSize(ins, i) == 8) return true;
    return false;
}

static inline bool MemWrite8(INS ins) {
    for (UINT32 i = 0; i < INS_MemoryOperandCount(ins); ++i)
        if (INS_MemoryOperandIsWritten(ins, i) &&
            INS_MemoryOperandSize(ins, i) == 8) return true;
    return false;
}

static inline bool Is64ALU(xed_iclass_enum_t opc) {
    switch (opc) {
        case XED_ICLASS_ADD:  case XED_ICLASS_SUB:
        case XED_ICLASS_ADC:  case XED_ICLASS_SBB:
        case XED_ICLASS_IMUL: case XED_ICLASS_MUL:
        case XED_ICLASS_MULX:
        case XED_ICLASS_ADCX: case XED_ICLASS_ADOX:
        case XED_ICLASS_IDIV: case XED_ICLASS_DIV:
            return true;
        default:
            return false;
    }
}

static inline bool IsRegReg64(INS ins) {
    return INS_MemoryOperandCount(ins) == 0 &&
           !HasImm(ins) && !TouchesStack(ins) &&
           Has64RegR(ins) && Has64RegW(ins);
}

static inline bool IsRegMem64(INS ins) {
    if (HasImm(ins) || TouchesStack(ins)) return false;
    bool mr  = MemRead8(ins)  && Has64RegW(ins) && !MemWrite8(ins);
    bool rmw = MemWrite8(ins) && Has64RegR(ins);          // count RMW
    return mr || rmw;
}

//------------------------------------------------------------------------------
//  Instrument every instruction once
//------------------------------------------------------------------------------
static VOID Instruction(INS ins, VOID*)
{
    // Region-start / region-stop hooks  (only needed in gated mode)
    if (!g_wholeProg) {
        if (INS_Address(ins) == g_startAddr)
            INS_InsertCall(ins, IPOINT_BEFORE,
                           (AFUNPTR)StartRegion, IARG_THREAD_ID, IARG_END);

        if (INS_IsRet(ins))
            INS_InsertCall(ins, IPOINT_BEFORE,
                           (AFUNPTR)StopRegion, IARG_THREAD_ID, IARG_END);
    }

    // --- classify scalar 64-bit arithmetic -----------------------------------
    if (!Is64ALU(static_cast<xed_iclass_enum_t>(INS_Opcode(ins)))) return;

    if (HasImm(ins)) return;              // skip immediates

    bool rr = IsRegReg64(ins);
    bool rm = !rr && IsRegMem64(ins);
    if (!rr && !rm) return;

    // Select counter
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
                   IARG_FAST_ANALYSIS_CALL,
                   IARG_THREAD_ID,
                   IARG_END);
}

//------------------------------------------------------------------------------
//  Thread-start: allocate per-thread counter block
//------------------------------------------------------------------------------
static VOID ThreadStart(THREADID tid, CONTEXT*, INT32, VOID*)
{
    auto* blk = new Cnts;
    PIN_SetThreadData(g_tlsCnts, blk, tid);
    PIN_SetThreadData(g_tlsFlag, nullptr, tid);

    PIN_GetLock(&g_lock, tid + 1);
    g_all.push_back(blk);
    PIN_ReleaseLock(&g_lock);
}

//------------------------------------------------------------------------------
//  Final report
//------------------------------------------------------------------------------
static VOID Fini(INT32, VOID*)
{
    Cnts sum{};
    for (auto* c : g_all) {
#define ACCUM(x)  sum.x += c->x
        ACCUM(add_rr); ACCUM(sub_rr); ACCUM(adc_rr); ACCUM(sbb_rr);
        ACCUM(mul_rr); ACCUM(mulx_rr); ACCUM(adcx_rr); ACCUM(adox_rr); ACCUM(div_rr);
        ACCUM(add_rm); ACCUM(sub_rm); ACCUM(adc_rm); ACCUM(sbb_rm);
        ACCUM(mul_rm); ACCUM(mulx_rm); ACCUM(adcx_rm); ACCUM(adox_rm); ACCUM(div_rm);
        delete c;
    }

    auto ADD = sum.add_rr + sum.add_rm + sum.adc_rr + sum.adc_rm +
               sum.adcx_rr + sum.adcx_rm + sum.adox_rr + sum.adox_rm;

    auto SUB = sum.sub_rr + sum.sub_rm + sum.sbb_rr + sum.sbb_rm;

    auto MUL = sum.mul_rr + sum.mul_rm + sum.mulx_rr + sum.mulx_rm;

    auto DIV = sum.div_rr + sum.div_rm;

    std::cout << std::dec;
    std::cout << "ADD: " << ADD << '\n'
              << "SUB: " << SUB << '\n'
              << "MUL: " << MUL << '\n'
              << "DIV: " << DIV << '\n';
}

//------------------------------------------------------------------------------
//  Entry
//------------------------------------------------------------------------------
int main(int argc, char* argv[])
{
    // Initialise Pin & knob
    PIN_Init(argc, argv);

    std::stringstream ss(knobAddr.Value());
    ss >> std::hex >> g_startAddr;
    g_wholeProg = (g_startAddr == 0);     // 0 ⇒ count entire run

    // TLS keys
    PIN_InitLock(&g_lock);
    g_tlsCnts = PIN_CreateThreadDataKey(nullptr);
    g_tlsFlag = PIN_CreateThreadDataKey(nullptr);

    // Register callbacks
    PIN_AddThreadStartFunction(ThreadStart, nullptr);
    INS_AddInstrumentFunction(Instruction, nullptr);
    PIN_AddFiniFunction(Fini, nullptr);

    PIN_StartProgram();   // never returns
    return 0;
}