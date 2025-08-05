// ─────────────────────────────────────────────────────────────────────────────
// Int64Profiler.cpp  –  Intel® Pin 3.31
//
//   Counts *64‑bit scalar* integer arithmetic instructions
//   (ADD/SUB/ADC/SBB/MUL/IMUL/MULX/AD*X/DIV/IDIV).
//
//   Modes
//   ─────
//   • Whole program                 (default, -addr 0)
//   • Region: everything executed
//       while <routine@addr> is on the call‑stack (-addr 0x1234)
//
//   Build
//       cd $PIN_HOME/source/tools/Int64Profiler
//       make
//
//   Run
//       # entire run
//       pin -t obj-intel64/Int64Profiler.so -- ./app
//
//       # only inside Evaluator.AddNew (incl. its callees)
//       pin -t obj-intel64/Int64Profiler.so -addr 0x681d40 -- ./app
// ─────────────────────────────────────────────────────────────────────────────
#include "pin.H"
#include <iomanip>
#include <iostream>
#include <sstream>
#include <string>
#include <vector>

// ─────────────────────────────────────────────────────────────────────────────
//  Command‑line knob
// ─────────────────────────────────────────────────────────────────────────────
KNOB<std::string> knobAddr(KNOB_MODE_WRITEONCE, "pintool",
                           "addr", "0x0",
                           "Hex start address (0 → whole program)");

// ─────────────────────────────────────────────────────────────────────────────
//  Counter block
// ─────────────────────────────────────────────────────────────────────────────
struct alignas(64) Cnts {
    /* register‑to‑register */
    UINT64 add_rr{}, sub_rr{}, adc_rr{}, sbb_rr{};
    UINT64 mul_rr{}, mulx_rr{}, adcx_rr{}, adox_rr{}, div_rr{};

    /* register↔memory (8‑byte only) */
    UINT64 add_rm{}, sub_rm{}, adc_rm{}, sbb_rm{};
    UINT64 mul_rm{}, mulx_rm{}, adcx_rm{}, adox_rm{}, div_rm{};
};

// ─────────────────────────────────────────────────────────────────────────────
//  Per‑thread state  (counters + region depth)
// ─────────────────────────────────────────────────────────────────────────────
struct alignas(64) ThreadState {
    Cnts   cnts;
    UINT32 depth = 0;        // >0 while inside target region
};

// TLS key and global list for cleanup/aggregation
static TLS_KEY                 g_tlsState;
static PIN_LOCK                g_lock;
static std::vector<ThreadState*> g_all;

// ─────────────────────────────────────────────────────────────────────────────
//  Globals
// ─────────────────────────────────────────────────────────────────────────────
static ADDRINT g_startAddr = 0;   // 0 ⇒ whole program
static bool    g_wholeProg = true;

// ─────────────────────────────────────────────────────────────────────────────
//  Convenience
// ─────────────────────────────────────────────────────────────────────────────
static inline ThreadState* S(THREADID tid) {
    return static_cast<ThreadState*>(PIN_GetThreadData(g_tlsState, tid));
}

static inline bool Counting(THREADID tid) {
    return g_wholeProg || (S(tid)->depth > 0);
}

// ─────────────────────────────────────────────────────────────────────────────
//  Region toggles (only used when g_wholeProg == false)
// ─────────────────────────────────────────────────────────────────────────────
static VOID PIN_FAST_ANALYSIS_CALL EnterRegion(THREADID tid) { ++S(tid)->depth; }
static VOID PIN_FAST_ANALYSIS_CALL ExitRegion (THREADID tid) { --S(tid)->depth; }

// ─────────────────────────────────────────────────────────────────────────────
//  Fast counter helpers
// ─────────────────────────────────────────────────────────────────────────────
#define FAST PIN_FAST_ANALYSIS_CALL
#define DEF_FAST(name)                                 \
    static VOID FAST name(THREADID tid) {              \
        if (Counting(tid)) S(tid)->cnts.name++;        \
    }

DEF_FAST(add_rr)  DEF_FAST(sub_rr)  DEF_FAST(adc_rr)  DEF_FAST(sbb_rr)
DEF_FAST(mul_rr)  DEF_FAST(mulx_rr) DEF_FAST(adcx_rr) DEF_FAST(adox_rr)
DEF_FAST(div_rr)
DEF_FAST(add_rm)  DEF_FAST(sub_rm)  DEF_FAST(adc_rm)  DEF_FAST(sbb_rm)
DEF_FAST(mul_rm)  DEF_FAST(mulx_rm) DEF_FAST(adcx_rm) DEF_FAST(adox_rm)
DEF_FAST(div_rm)

// ─────────────────────────────────────────────────────────────────────────────
//  Classification helpers
// ─────────────────────────────────────────────────────────────────────────────
static inline bool Is64Gpr(REG r)     { return REG_is_gr64(r); }
static inline bool IsStack(REG r)     { return r == REG_RSP || r == REG_RBP; }

static inline bool HasImm(INS ins) {
    for (UINT32 i = 0; i < INS_OperandCount(ins); ++i)
        if (INS_OperandIsImmediate(ins, i)) return true;
    return false;
}

static inline bool TouchesStack(INS ins) {
    for (UINT32 i = 0; i < INS_MaxNumRRegs(ins); ++i)
        if (IsStack(INS_RegR(ins, i))) return true;
    for (UINT32 i = 0; i < INS_MaxNumWRegs(ins); ++i)
        if (IsStack(INS_RegW(ins, i))) return true;
    return INS_IsStackRead(ins) || INS_IsStackWrite(ins);
}

static inline bool Has64RegR(INS ins) {
    for (UINT32 i = 0; i < INS_MaxNumRRegs(ins); ++i) {
        REG r = INS_RegR(ins, i);
        if (Is64Gpr(r) && !IsStack(r)) return true;
    }
    return false;
}

static inline bool Has64RegW(INS ins) {
    for (UINT32 i = 0; i < INS_MaxNumWRegs(ins); ++i) {
        REG r = INS_RegW(ins, i);
        if (Is64Gpr(r) && !IsStack(r)) return true;
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
    bool rmw = MemWrite8(ins) && Has64RegR(ins);  // count RMW as reg↔mem
    return mr || rmw;
}

// ─────────────────────────────────────────────────────────────────────────────
//  Instruction instrumentation
// ─────────────────────────────────────────────────────────────────────────────
static VOID Instruction(INS ins, VOID*)
{
    // skip if not 64‑bit ALU
    if (!Is64ALU(static_cast<xed_iclass_enum_t>(INS_Opcode(ins)))) return;
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
                   IARG_FAST_ANALYSIS_CALL,
                   IARG_THREAD_ID,
                   IARG_END);
}

// ─────────────────────────────────────────────────────────────────────────────
//  Image‑load: add region entry/exit hooks for the chosen routine
// ─────────────────────────────────────────────────────────────────────────────
static VOID ImageLoad(IMG img, VOID*)
{
    if (g_wholeProg) return;

    for (RTN rtn = IMG_RtnHead(img); RTN_Valid(rtn); rtn = RTN_Next(rtn)) {
        if (RTN_Address(rtn) != g_startAddr) continue;

        RTN_Open(rtn);
        RTN_InsertCall(rtn, IPOINT_BEFORE, (AFUNPTR)EnterRegion,
                       IARG_THREAD_ID, IARG_END);
        RTN_InsertCall(rtn, IPOINT_AFTER,  (AFUNPTR)ExitRegion,
                       IARG_THREAD_ID, IARG_END);
        RTN_Close(rtn);
        break;              // found it – stop scanning
    }
}

// ─────────────────────────────────────────────────────────────────────────────
//  Thread start
// ─────────────────────────────────────────────────────────────────────────────
static VOID ThreadStart(THREADID tid, CONTEXT*, INT32, VOID*)
{
    auto* st = new ThreadState;
    PIN_SetThreadData(g_tlsState, st, tid);

    PIN_GetLock(&g_lock, tid + 1);
    g_all.push_back(st);
    PIN_ReleaseLock(&g_lock);
}

// ─────────────────────────────────────────────────────────────────────────────
//  Final report
// ─────────────────────────────────────────────────────────────────────────────
static VOID Fini(INT32, VOID*)
{
    Cnts sum{};
    for (auto* st : g_all) {
#define ACC(x) sum.x += st->cnts.x
        ACC(add_rr);  ACC(sub_rr);  ACC(adc_rr);  ACC(sbb_rr);
        ACC(mul_rr);  ACC(mulx_rr); ACC(adcx_rr); ACC(adox_rr); ACC(div_rr);
        ACC(add_rm);  ACC(sub_rm);  ACC(adc_rm);  ACC(sbb_rm);
        ACC(mul_rm);  ACC(mulx_rm); ACC(adcx_rm); ACC(adox_rm); ACC(div_rm);
        delete st;
    }

    UINT64 ADD = sum.add_rr + sum.add_rm +
                 sum.adc_rr + sum.adc_rm +
                 sum.adcx_rr + sum.adcx_rm +
                 sum.adox_rr + sum.adox_rm;

    UINT64 SUB = sum.sub_rr + sum.sub_rm +
                 sum.sbb_rr + sum.sbb_rm;

    UINT64 MUL = sum.mul_rr + sum.mul_rm +
                 sum.mulx_rr + sum.mulx_rm;

    UINT64 DIV = sum.div_rr + sum.div_rm;

    std::cout << "ADD: " << ADD << '\n'
              << "SUB: " << SUB << '\n'
              << "MUL: " << MUL << '\n'
              << "DIV: " << DIV << '\n';
}

// ─────────────────────────────────────────────────────────────────────────────
//  Main
// ─────────────────────────────────────────────────────────────────────────────
int main(int argc, char* argv[])
{
    PIN_Init(argc, argv);

    std::stringstream ss(knobAddr.Value());
    ss >> std::hex >> g_startAddr;
    g_wholeProg = (g_startAddr == 0);

    PIN_InitLock(&g_lock);
    g_tlsState = PIN_CreateThreadDataKey(nullptr);

    PIN_AddThreadStartFunction(ThreadStart, nullptr);
    IMG_AddInstrumentFunction(ImageLoad, nullptr);
    INS_AddInstrumentFunction(Instruction, nullptr);
    PIN_AddFiniFunction(Fini, nullptr);

    PIN_StartProgram();     // never returns
    return 0;
}