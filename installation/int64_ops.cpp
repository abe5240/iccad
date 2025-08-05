// ─────────────────────────────────────────────────────────────────────────────
// Int64Profiler.cpp  –  Intel® Pin 3.31
//
//   Counts *64‑bit scalar* integer arithmetic instructions
//   (ADD/SUB/ADC/SBB/MUL/IMUL/MULX/AD*X/DIV/IDIV).
//
//   • Whole program            : default  (-addr 0)
//   • Region‑scoped            : everything executed while the routine that
//                                starts at <addr> is on‑stack.
//
//   Build:
//       cd $PIN_HOME/source/tools/Int64Profiler && make
//
//   Typical runs:
//       pin -t obj-intel64/Int64Profiler.so -- ./app
//       pin -t obj-intel64/Int64Profiler.so -addr 0x401130 -- ./app
//
//   Output (compact):
//       ADD: <total>   SUB: <total>   MUL: <total>   DIV: <total>
// ─────────────────────────────────────────────────────────────────────────────
#include "pin.H"
#include <iomanip>
#include <iostream>
#include <sstream>
#include <string>
#include <vector>

// ── knob ─────────────────────────────────────────────────────────────────────
KNOB<std::string> knobAddr(KNOB_MODE_WRITEONCE, "pintool",
                           "addr", "0x0",
                           "Hex start address (0 → whole program)");

// ── per‑thread data ─────────────────────────────────────────────────────────
struct alignas(64) Cnts {
    UINT64 add_rr{}, sub_rr{}, adc_rr{}, sbb_rr{};
    UINT64 mul_rr{}, mulx_rr{}, adcx_rr{}, adox_rr{}, div_rr{};
    UINT64 add_rm{}, sub_rm{}, adc_rm{}, sbb_rm{};
    UINT64 mul_rm{}, mulx_rm{}, adcx_rm{}, adox_rm{}, div_rm{};
};

struct alignas(64) ThreadState {
    Cnts cnts;
    int  depth = 0;          // >0 while inside the region
};

static TLS_KEY                     tlsKey;
static PIN_LOCK                    g_lock;
static std::vector<ThreadState*>   g_all;

static ADDRINT g_addr  = 0;   // address passed on the command line
static bool    g_whole = true;

// ── helpers ──────────────────────────────────────────────────────────────────
static inline ThreadState* St(THREADID tid) {
    return static_cast<ThreadState*>(PIN_GetThreadData(tlsKey, tid));
}
static inline bool Counting(THREADID tid) {
    return g_whole || (St(tid)->depth > 0);
}

// region toggles – **not** fast analysis (only runs once per call)
static VOID Enter(THREADID tid) { ++St(tid)->depth; }
static VOID Exit (THREADID tid) { --St(tid)->depth; }

// fast counters
#define DEF(name) \
    static VOID PIN_FAST_ANALYSIS_CALL name(THREADID tid){ \
        if (Counting(tid)) St(tid)->cnts.name++; }

DEF(add_rr)  DEF(sub_rr)  DEF(adc_rr)  DEF(sbb_rr)
DEF(mul_rr)  DEF(mulx_rr) DEF(adcx_rr) DEF(adox_rr) DEF(div_rr)
DEF(add_rm)  DEF(sub_rm)  DEF(adc_rm)  DEF(sbb_rm)
DEF(mul_rm)  DEF(mulx_rm) DEF(adcx_rm) DEF(adox_rm) DEF(div_rm)

// ── instruction classification (unchanged) ──────────────────────────────────
static inline bool Gpr64(REG r){ return REG_is_gr64(r); }
static inline bool Stack(REG r){ return r==REG_RSP || r==REG_RBP; }

static inline bool HasImm(INS ins){
    for(UINT32 i=0;i<INS_OperandCount(ins);++i)
        if(INS_OperandIsImmediate(ins,i)) return true;
    return false;
}
static inline bool TouchStack(INS ins){
    for(UINT32 i=0;i<INS_MaxNumRRegs(ins);++i)
        if(Stack(INS_RegR(ins,i))) return true;
    for(UINT32 i=0;i<INS_MaxNumWRegs(ins);++i)
        if(Stack(INS_RegW(ins,i))) return true;
    return INS_IsStackRead(ins)||INS_IsStackWrite(ins);
}
static inline bool Has64R(INS ins){
    for(UINT32 i=0;i<INS_MaxNumRRegs(ins);++i){
        REG r=INS_RegR(ins,i); if(Gpr64(r)&&!Stack(r)) return true;
    }
    return false;
}
static inline bool Has64W(INS ins){
    for(UINT32 i=0;i<INS_MaxNumWRegs(ins);++i){
        REG r=INS_RegW(ins,i); if(Gpr64(r)&&!Stack(r)) return true;
    }
    return false;
}
static inline bool MemRead8(INS ins){
    for(UINT32 i=0;i<INS_MemoryOperandCount(ins);++i)
        if(INS_MemoryOperandIsRead(ins,i)&&INS_MemoryOperandSize(ins,i)==8) return true;
    return false;
}
static inline bool MemWrite8(INS ins){
    for(UINT32 i=0;i<INS_MemoryOperandCount(ins);++i)
        if(INS_MemoryOperandIsWritten(ins,i)&&INS_MemoryOperandSize(ins,i)==8) return true;
    return false;
}
static inline bool ALU64(xed_iclass_enum_t o){
    switch(o){
        case XED_ICLASS_ADD: case XED_ICLASS_SUB: case XED_ICLASS_ADC:
        case XED_ICLASS_SBB: case XED_ICLASS_IMUL:case XED_ICLASS_MUL:
        case XED_ICLASS_MULX:case XED_ICLASS_ADCX:case XED_ICLASS_ADOX:
        case XED_ICLASS_IDIV:case XED_ICLASS_DIV:  return true;
        default: return false;
    }
}
static inline bool RegReg64(INS ins){
    return INS_MemoryOperandCount(ins)==0 && !HasImm(ins)&&!TouchStack(ins)
           &&Has64R(ins)&&Has64W(ins);
}
static inline bool RegMem64(INS ins){
    if(HasImm(ins)||TouchStack(ins)) return false;
    bool mr = MemRead8(ins)&&Has64W(ins)&&!MemWrite8(ins);
    bool rmw= MemWrite8(ins)&&Has64R(ins);
    return mr||rmw;
}

// ── per‑instruction instrumentation ─────────────────────────────────────────
static VOID Instruction(INS ins, VOID*)
{
    if(!ALU64((xed_iclass_enum_t)INS_Opcode(ins))) return;
    if(HasImm(ins)) return;

    bool rr=RegReg64(ins), rm=!rr&&RegMem64(ins); if(!rr&&!rm) return;

    AFUNPTR fn=nullptr;
    switch(INS_Opcode(ins)){
        case XED_ICLASS_ADD:  fn=(AFUNPTR)(rr?add_rr:add_rm);  break;
        case XED_ICLASS_SUB:  fn=(AFUNPTR)(rr?sub_rr:sub_rm);  break;
        case XED_ICLASS_ADC:  fn=(AFUNPTR)(rr?adc_rr:adc_rm);  break;
        case XED_ICLASS_SBB:  fn=(AFUNPTR)(rr?sbb_rr:sbb_rm);  break;
        case XED_ICLASS_MUL:
        case XED_ICLASS_IMUL: fn=(AFUNPTR)(rr?mul_rr:mul_rm);  break;
        case XED_ICLASS_MULX: fn=(AFUNPTR)(rr?mulx_rr:mulx_rm);break;
        case XED_ICLASS_ADCX: fn=(AFUNPTR)(rr?adcx_rr:adcx_rm);break;
        case XED_ICLASS_ADOX: fn=(AFUNPTR)(rr?adox_rr:adox_rm);break;
        case XED_ICLASS_DIV:
        case XED_ICLASS_IDIV: fn=(AFUNPTR)(rr?div_rr:div_rm);  break;
        default: return;
    }
    INS_InsertCall(ins, IPOINT_BEFORE, fn,
                   IARG_FAST_ANALYSIS_CALL, IARG_THREAD_ID, IARG_END);
}

// ── attach region toggles to the chosen routine ─────────────────────────────
static VOID ImageLoad(IMG img, VOID*)
{
    if(g_whole) return;
    static bool done=false; if(done) return;

    if(g_addr < IMG_LowAddress(img) || g_addr >= IMG_HighAddress(img))
        return;

    RTN rtn = RTN_FindByAddress(g_addr);
    if(!RTN_Valid(rtn)) return;

    RTN_Open(rtn);
    RTN_InsertCall(rtn, IPOINT_BEFORE, (AFUNPTR)Enter,
                   IARG_CALL_ORDER, CALL_ORDER_FIRST,
                   IARG_THREAD_ID, IARG_END);
    RTN_InsertCall(rtn, IPOINT_AFTER,  (AFUNPTR)Exit,
                   IARG_CALL_ORDER, CALL_ORDER_LAST,
                   IARG_THREAD_ID, IARG_END);
    RTN_Close(rtn);

    done = true;
}

// ── thread start / fini ─────────────────────────────────────────────────────
static VOID ThreadStart(THREADID tid, CONTEXT*, INT32, VOID*)
{
    auto* st = new ThreadState;
    PIN_SetThreadData(tlsKey, st, tid);

    PIN_GetLock(&g_lock, tid+1); g_all.push_back(st); PIN_ReleaseLock(&g_lock);
}

static VOID Fini(INT32, VOID*)
{
    Cnts sum{};
    for(auto* st : g_all){
#define ACC(f)  sum.f += st->cnts.f
        ACC(add_rr);  ACC(sub_rr);  ACC(adc_rr);  ACC(sbb_rr);
        ACC(mul_rr);  ACC(mulx_rr); ACC(adcx_rr); ACC(adox_rr); ACC(div_rr);
        ACC(add_rm);  ACC(sub_rm);  ACC(adc_rm);  ACC(sbb_rm);
        ACC(mul_rm);  ACC(mulx_rm); ACC(adcx_rm); ACC(adox_rm); ACC(div_rm);
        delete st;
    }

    const auto ADD = sum.add_rr + sum.add_rm + sum.adc_rr + sum.adc_rm
                   + sum.adcx_rr + sum.adcx_rm + sum.adox_rr + sum.adox_rm;
    const auto SUB = sum.sub_rr + sum.sub_rm + sum.sbb_rr + sum.sbb_rm;
    const auto MUL = sum.mul_rr + sum.mul_rm + sum.mulx_rr + sum.mulx_rm;
    const auto DIV = sum.div_rr + sum.div_rm;

    std::cout << "ADD: " << ADD << "\n"
              << "SUB: " << SUB << "\n"
              << "MUL: " << MUL << "\n"
              << "DIV: " << DIV << std::endl;
}

// ── main ─────────────────────────────────────────────────────────────────────
int main(int argc, char* argv[])
{
    PIN_Init(argc, argv);

    g_addr  = strtoull(knobAddr.Value().c_str(), nullptr, 0);
    g_whole = (g_addr == 0);

    PIN_InitLock(&g_lock);
    tlsKey = PIN_CreateThreadDataKey(nullptr);

    PIN_AddThreadStartFunction(ThreadStart, nullptr);
    IMG_AddInstrumentFunction(ImageLoad,    nullptr);
    INS_AddInstrumentFunction(Instruction,  nullptr);
    PIN_AddFiniFunction(Fini,               nullptr);

    PIN_StartProgram();   // never returns
    return 0;
}