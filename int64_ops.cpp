// int64_ops.cpp
#include "pin.H"
#include <iostream>
#include <vector>

// ---------------------------- Configuration ---------------------------------
// Keep as-is (matches your current rules).
static constexpr bool kExcludeImmediates = true;
static constexpr bool kExcludeStack      = true;
static constexpr bool kCountMemDestRmw   = true; // p += x; arr[i] -= y; etc.

// ----------------------------- Data structures -------------------------------
struct alignas(64) Cnts {
    UINT64 add_rr=0, sub_rr=0, mul_rr=0, div_rr=0; // reg <- reg|reg
    UINT64 add_rm=0, sub_rm=0, mul_rm=0, div_rm=0; // reg<->mem (8B, non-stack)
};

static TLS_KEY g_tls;
static std::vector<Cnts*> g_all; // collected per-thread blocks
static PIN_LOCK g_lock;

// ----------------------------- Fast analysis ---------------------------------
static PIN_FAST_ANALYSIS_CALL VOID AddRR(Cnts* c){ c->add_rr++; }
static PIN_FAST_ANALYSIS_CALL VOID SubRR(Cnts* c){ c->sub_rr++; }
static PIN_FAST_ANALYSIS_CALL VOID MulRR(Cnts* c){ c->mul_rr++; }
static PIN_FAST_ANALYSIS_CALL VOID DivRR(Cnts* c){ c->div_rr++; }
static PIN_FAST_ANALYSIS_CALL VOID AddRM(Cnts* c){ c->add_rm++; }
static PIN_FAST_ANALYSIS_CALL VOID SubRM(Cnts* c){ c->sub_rm++; }
static PIN_FAST_ANALYSIS_CALL VOID MulRM(Cnts* c){ c->mul_rm++; }
static PIN_FAST_ANALYSIS_CALL VOID DivRM(Cnts* c){ c->div_rm++; }

// ------------------------------ Small helpers --------------------------------
static inline BOOL Is64Gpr(REG r)      { return REG_is_gr64(r); }
static inline BOOL IsStackReg(REG r)   { return r==REG_RSP || r==REG_RBP; }

static inline BOOL Is64ArithOpcode(xed_iclass_enum_t opc) {
    return opc==XED_ICLASS_ADD  || opc==XED_ICLASS_SUB  ||
           opc==XED_ICLASS_IMUL || opc==XED_ICLASS_MUL  ||
           opc==XED_ICLASS_IDIV || opc==XED_ICLASS_DIV;
}

static inline BOOL HasImmediate(INS ins) {
    if (!kExcludeImmediates) return FALSE;
    const UINT32 n = INS_OperandCount(ins);
    for (UINT32 i=0;i<n;i++)
        if (INS_OperandIsImmediate(ins,i)) return TRUE;
    return FALSE;
}

static inline BOOL TouchesStack(INS ins) {
    if (!kExcludeStack) return FALSE;

    const UINT32 nr = INS_MaxNumRRegs(ins);
    for (UINT32 i=0;i<nr;i++) {
        REG r = INS_RegR(ins,i);
        if (IsStackReg(r)) return TRUE;
    }
    const UINT32 nw = INS_MaxNumWRegs(ins);
    for (UINT32 i=0;i<nw;i++) {
        REG r = INS_RegW(ins,i);
        if (IsStackReg(r)) return TRUE;
    }
    // Also exclude explicit stack memory references.
    return INS_IsStackRead(ins) || INS_IsStackWrite(ins);
}

static inline BOOL Has64RegRead(INS ins) {
    const UINT32 nr = INS_MaxNumRRegs(ins);
    for (UINT32 i=0;i<nr;i++) {
        REG r = INS_RegR(ins,i);
        if (Is64Gpr(r) && !IsStackReg(r)) return TRUE;
    }
    return FALSE;
}

static inline BOOL Has64RegWrite(INS ins) {
    const UINT32 nw = INS_MaxNumWRegs(ins);
    for (UINT32 i=0;i<nw;i++) {
        REG r = INS_RegW(ins,i);
        if (Is64Gpr(r) && !IsStackReg(r)) return TRUE;
    }
    return FALSE;
}

static inline BOOL HasMemRead8(INS ins) {
    const UINT32 m = INS_MemoryOperandCount(ins);
    for (UINT32 i=0;i<m;i++)
        if (INS_MemoryOperandIsRead(ins,i) &&
            INS_MemoryOperandSize(ins,i)==8) return TRUE;
    return FALSE;
}

static inline BOOL HasMemWrite8(INS ins) {
    const UINT32 m = INS_MemoryOperandCount(ins);
    for (UINT32 i=0;i<m;i++)
        if (INS_MemoryOperandIsWritten(ins,i) &&
            INS_MemoryOperandSize(ins,i)==8) return TRUE;
    return FALSE;
}

// ------------------------------ Classifiers ----------------------------------
// reg-reg: 64-bit ALU, no mem, no imm, not stack; must read & write a 64-bit GPR.
static inline BOOL IsRegReg64Arith(INS ins) {
    if (INS_MemoryOperandCount(ins) != 0) return FALSE;
    if (HasImmediate(ins))                 return FALSE;
    if (TouchesStack(ins))                 return FALSE;
    return Has64RegRead(ins) && Has64RegWrite(ins);
}

// reg<->mem: 64-bit ALU with 8B non-stack mem operand(s); no imm.
// Count either mem->reg (read mem, write reg) or reg->mem RMW if enabled.
static inline BOOL IsRegMem64Arith(INS ins) {
    if (HasImmediate(ins)) return FALSE;
    if (TouchesStack(ins)) return FALSE;

    const BOOL mem_r8 = HasMemRead8(ins);
    const BOOL mem_w8 = HasMemWrite8(ins);

    // mem -> reg
    if (mem_r8 && Has64RegWrite(ins) && !mem_w8) return TRUE;

    // reg -> mem (RMW) if allowed
    if (kCountMemDestRmw && mem_w8 && Has64RegRead(ins)) return TRUE;

    return FALSE;
}

// ------------------------------ Threading ------------------------------------
static VOID ThreadStart(THREADID tid, CONTEXT*, INT32, VOID*) {
    auto* c = new Cnts();
    PIN_SetThreadData(g_tls, c, tid);

    PIN_GetLock(&g_lock, tid+1);
    g_all.push_back(c);
    PIN_ReleaseLock(&g_lock);
}

// --------------------------- Instrumentation ---------------------------------
static VOID Instruction(INS ins, VOID*) {
    const xed_iclass_enum_t opc = (xed_iclass_enum_t)INS_Opcode(ins);
    if (!Is64ArithOpcode(opc)) return;

    const BOOL rr = IsRegReg64Arith(ins);
    const BOOL rm = !rr && IsRegMem64Arith(ins);
    if (!rr && !rm) return;

    AFUNPTR f = 0;
    if (opc==XED_ICLASS_ADD)               f = (AFUNPTR)(rr?AddRR:AddRM);
    else if (opc==XED_ICLASS_SUB)          f = (AFUNPTR)(rr?SubRR:SubRM);
    else if (opc==XED_ICLASS_IMUL ||
             opc==XED_ICLASS_MUL)          f = (AFUNPTR)(rr?MulRR:MulRM);
    else if (opc==XED_ICLASS_IDIV ||
             opc==XED_ICLASS_DIV)          f = (AFUNPTR)(rr?DivRR:DivRM);
    if (!f) return;

    INS_InsertCall(ins, IPOINT_BEFORE, f,
                   IARG_FAST_ANALYSIS_CALL,
                   IARG_TLS_PTR, g_tls,
                   IARG_END);
}

// ------------------------------- Reporting -----------------------------------
static VOID Fini(INT32, VOID*) {
    UINT64 add_rr=0, sub_rr=0, mul_rr=0, div_rr=0;
    UINT64 add_rm=0, sub_rm=0, mul_rm=0, div_rm=0;

    for (Cnts* c : g_all) {
        add_rr += c->add_rr; sub_rr += c->sub_rr;
        mul_rr += c->mul_rr; div_rr += c->div_rr;
        add_rm += c->add_rm; sub_rm += c->sub_rm;
        mul_rm += c->mul_rm; div_rm += c->div_rm;
        delete c;
    }

    std::cout << "--- 64-bit integer arithmetic (no imm, no stack) ---\n";
    std::cout << "ADD  rr: " << add_rr << "   rm/mr: " << add_rm << "\n";
    std::cout << "SUB  rr: " << sub_rr << "   rm/mr: " << sub_rm << "\n";
    std::cout << "MUL  rr: " << mul_rr << "   rm/mr: " << mul_rm << "\n";
    std::cout << "DIV  rr: " << div_rr << "   rm/mr: " << div_rm << "\n";
}

// --------------------------------- Main --------------------------------------
int main(int argc, char* argv[]) {
    PIN_Init(argc, argv);
    PIN_InitLock(&g_lock);
    g_tls = PIN_CreateThreadDataKey(nullptr);

    PIN_AddThreadStartFunction(ThreadStart, nullptr);
    INS_AddInstrumentFunction(Instruction, nullptr);
    PIN_AddFiniFunction(Fini, nullptr);

    PIN_StartProgram();
    return 0;
}