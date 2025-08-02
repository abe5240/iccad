// int64_ops.cpp
// Pin tool: Count 64-bit integer arithmetic (ADD/SUB/MUL/DIV) with filters,
// and sanity-check packed 64-bit ADD/SUB (instruction + lane-ops).
//
// Policy (scalar):
//   - 64-bit width only
//   - exclude immediates
//   - exclude stack traffic (rsp/rbp and stack mem refs)
//   - count reg-reg and reg<->mem (8B), optionally mem-dest RMW
//
// Policy (SIMD sanity check):
//   - track PADDQ/VPADDQ and PSUBQ/VPSUBQ
//   - count 1 per instruction and #active 64-bit lanes (mask-aware)
//   - early-return so SIMD never hits scalar path (no double counting)

#include "pin.H"
#include <iostream>
#include <vector>
#include <algorithm> // std::max

// ---------------------------- Configuration ---------------------------------
static constexpr bool kExcludeImmediates = true;
static constexpr bool kExcludeStack      = true;
static constexpr bool kCountMemDestRmw   = true; // keep reg->mem RMW

// ----------------------------- Data structures -------------------------------
struct alignas(64) Cnts {
    // Scalar 64-bit integer ALU
    UINT64 add_rr=0, sub_rr=0, mul_rr=0, div_rr=0; // reg <- reg|reg
    UINT64 add_rm=0, sub_rm=0, mul_rm=0, div_rm=0; // reg<->mem (8B, non-stack)

    // SIMD sanity check (64-bit lanes)
    UINT64 simd_addq_insn=0, simd_addq_ops=0; // PADDQ/VPADDQ
    UINT64 simd_subq_insn=0, simd_subq_ops=0; // PSUBQ/VPSUBQ
};

static TLS_KEY g_tls;
static std::vector<Cnts*> g_all; // per-thread blocks (collected at start)
static PIN_LOCK g_lock;

// ----------------------------- Fast analysis ---------------------------------
static VOID AddRR(Cnts* c){ c->add_rr++; }
static VOID SubRR(Cnts* c){ c->sub_rr++; }
static VOID MulRR(Cnts* c){ c->mul_rr++; }
static VOID DivRR(Cnts* c){ c->div_rr++; }
static VOID AddRM(Cnts* c){ c->add_rm++; }
static VOID SubRM(Cnts* c){ c->sub_rm++; }
static VOID MulRM(Cnts* c){ c->mul_rm++; }
static VOID DivRM(Cnts* c){ c->div_rm++; }

static VOID SimdAddQ(Cnts* c, UINT32 lanes){
    c->simd_addq_insn++; c->simd_addq_ops += lanes;
}
static VOID SimdSubQ(Cnts* c, UINT32 lanes){
    c->simd_subq_insn++; c->simd_subq_ops += lanes;
}
static VOID SimdAddQMasked(Cnts* c, UINT32 lanes, ADDRINT kbits){
    UINT32 active = 0; UINT64 m = static_cast<UINT64>(kbits);
    for (UINT32 i=0;i<lanes;i++) active += (m >> i) & 1u;
    c->simd_addq_insn++; c->simd_addq_ops += active;
}
static VOID SimdSubQMasked(Cnts* c, UINT32 lanes, ADDRINT kbits){
    UINT32 active = 0; UINT64 m = static_cast<UINT64>(kbits);
    for (UINT32 i=0;i<lanes;i++) active += (m >> i) & 1u;
    c->simd_subq_insn++; c->simd_subq_ops += active;
}

// ------------------------------ Small helpers --------------------------------
static inline BOOL Is64Gpr(REG r)    { return REG_is_gr64(r); }
static inline BOOL IsStackReg(REG r) { return r==REG_RSP || r==REG_RBP; }

static inline BOOL Is64ArithOpcode(xed_iclass_enum_t opc) {
    return opc==XED_ICLASS_ADD  || opc==XED_ICLASS_SUB  ||
           opc==XED_ICLASS_IMUL || opc==XED_ICLASS_MUL  ||
           opc==XED_ICLASS_IDIV || opc==XED_ICLASS_DIV;
}

static inline BOOL IsSimdAddQ(xed_iclass_enum_t opc){
    return opc==XED_ICLASS_PADDQ || opc==XED_ICLASS_VPADDQ;
}
static inline BOOL IsSimdSubQ(xed_iclass_enum_t opc){
    return opc==XED_ICLASS_PSUBQ || opc==XED_ICLASS_VPSUBQ;
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
        const REG r = INS_RegR(ins,i);
        if (IsStackReg(r)) return TRUE;
    }
    const UINT32 nw = INS_MaxNumWRegs(ins);
    for (UINT32 i=0;i<nw;i++) {
        const REG r = INS_RegW(ins,i);
        if (IsStackReg(r)) return TRUE;
    }
    return INS_IsStackRead(ins) || INS_IsStackWrite(ins);
}

static inline BOOL Has64RegRead(INS ins) {
    const UINT32 nr = INS_MaxNumRRegs(ins);
    for (UINT32 i=0;i<nr;i++) {
        const REG r = INS_RegR(ins,i);
        if (Is64Gpr(r) && !IsStackReg(r)) return TRUE;
    }
    return FALSE;
}

static inline BOOL Has64RegWrite(INS ins) {
    const UINT32 nw = INS_MaxNumWRegs(ins);
    for (UINT32 i=0;i<nw;i++) {
        const REG r = INS_RegW(ins,i);
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

// Number of 64-bit lanes written by a SIMD instruction (MMX/XMM/YMM/ZMM).
static inline UINT32 QwordLanesWritten(INS ins){
    UINT32 maxBytes = 0;
    const UINT32 nw = INS_MaxNumWRegs(ins);
    for (UINT32 i=0;i<nw;i++){
        const REG r = INS_RegW(ins,i);
        if (REG_is_mm(r) || REG_is_xmm(r) || REG_is_ymm(r) || REG_is_zmm(r))
            maxBytes = std::max<UINT32>(maxBytes, REG_Size(r));
    }
    if (maxBytes == 0) maxBytes = 16; // conservative default: XMM
    return maxBytes / 8;
}

// Returns first AVX-512 k-mask reg read (k1..k7). REG_INVALID_ if none.
static inline REG FirstKMaskRead(INS ins){
    const UINT32 nr = INS_MaxNumRRegs(ins);
    for (UINT32 i=0;i<nr;i++){
        const REG r = INS_RegR(ins,i);
        if (REG_is_k_mask(r)) return r;
    }
    return REG_INVALID_;
}

// ------------------------------ Classifiers ----------------------------------
// reg-reg: 64-bit ALU, no mem, no imm, not stack; must read & write 64-bit GPR.
static inline BOOL IsRegReg64Arith(INS ins) {
    if (INS_MemoryOperandCount(ins) != 0) return FALSE;
    if (HasImmediate(ins))                 return FALSE;
    if (TouchesStack(ins))                 return FALSE;
    return Has64RegRead(ins) && Has64RegWrite(ins);
}

// reg<->mem: 64-bit ALU with 8B non-stack mem; no imm.
// Count mem->reg, and reg->mem RMW if enabled.
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
    const xed_iclass_enum_t opc =
        static_cast<xed_iclass_enum_t>(INS_Opcode(ins));

    // ---- SIMD sanity check first; early-return to avoid any overlap ----
    if (IsSimdAddQ(opc) || IsSimdSubQ(opc)){
        const UINT32 lanes = QwordLanesWritten(ins);
        const REG kmask = FirstKMaskRead(ins);
        const BOOL masked = (kmask != REG_INVALID_);

        if (IsSimdAddQ(opc)){
            if (masked)
                INS_InsertCall(ins, IPOINT_BEFORE, (AFUNPTR)SimdAddQMasked,
                    IARG_FAST_ANALYSIS_CALL, IARG_TLS_PTR, g_tls,
                    IARG_UINT32, lanes, IARG_REG_VALUE, kmask, IARG_END);
            else
                INS_InsertCall(ins, IPOINT_BEFORE, (AFUNPTR)SimdAddQ,
                    IARG_FAST_ANALYSIS_CALL, IARG_TLS_PTR, g_tls,
                    IARG_UINT32, lanes, IARG_END);
        } else { // sub
            if (masked)
                INS_InsertCall(ins, IPOINT_BEFORE, (AFUNPTR)SimdSubQMasked,
                    IARG_FAST_ANALYSIS_CALL, IARG_TLS_PTR, g_tls,
                    IARG_UINT32, lanes, IARG_REG_VALUE, kmask, IARG_END);
            else
                INS_InsertCall(ins, IPOINT_BEFORE, (AFUNPTR)SimdSubQ,
                    IARG_FAST_ANALYSIS_CALL, IARG_TLS_PTR, g_tls,
                    IARG_UINT32, lanes, IARG_END);
        }
        return; // never let SIMD reach scalar path
    }

    // ---- Scalar 64-bit ALU path ----
    if (!Is64ArithOpcode(opc)) return;

    const BOOL rr = IsRegReg64Arith(ins);
    const BOOL rm = !rr && IsRegMem64Arith(ins);
    if (!rr && !rm) return;

    AFUNPTR f = nullptr;
    switch (opc) {
        case XED_ICLASS_ADD:  f = (AFUNPTR)(rr ? AddRR : AddRM); break;
        case XED_ICLASS_SUB:  f = (AFUNPTR)(rr ? SubRR : SubRM); break;
        case XED_ICLASS_IMUL:
        case XED_ICLASS_MUL:  f = (AFUNPTR)(rr ? MulRR : MulRM); break;
        case XED_ICLASS_IDIV:
        case XED_ICLASS_DIV:  f = (AFUNPTR)(rr ? DivRR : DivRM); break;
        default: return;
    }

    INS_InsertCall(ins, IPOINT_BEFORE, f,
                   IARG_FAST_ANALYSIS_CALL,
                   IARG_TLS_PTR, g_tls,
                   IARG_END);
}

// ------------------------------- Reporting -----------------------------------
static VOID Fini(INT32, VOID*) {
    UINT64 add_rr=0, sub_rr=0, mul_rr=0, div_rr=0;
    UINT64 add_rm=0, sub_rm=0, mul_rm=0, div_rm=0;
    UINT64 simd_addq_insn=0, simd_addq_ops=0;
    UINT64 simd_subq_insn=0, simd_subq_ops=0;

    for (Cnts* c : g_all) {
        add_rr += c->add_rr; sub_rr += c->sub_rr;
        mul_rr += c->mul_rr; div_rr += c->div_rr;
        add_rm += c->add_rm; sub_rm += c->sub_rm;
        mul_rm += c->mul_rm; div_rm += c->div_rm;

        simd_addq_insn += c->simd_addq_insn;
        simd_addq_ops  += c->simd_addq_ops;
        simd_subq_insn += c->simd_subq_insn;
        simd_subq_ops  += c->simd_subq_ops;

        delete c;
    }

    std::cout << "--- 64-bit integer arithmetic (no imm, no stack) ---\n";
    std::cout << "ADD  rr: " << add_rr << "   rm/mr: " << add_rm << "\n";
    std::cout << "SUB  rr: " << sub_rr << "   rm/mr: " << sub_rm << "\n";
    std::cout << "MUL  rr: " << mul_rr << "   rm/mr: " << mul_rm << "\n";
    std::cout << "DIV  rr: " << div_rr << "   rm/mr: " << div_rm << "\n";

    std::cout << "SIMD ADDQ: " << simd_addq_insn
              << " insns, " << simd_addq_ops << " lane-ops\n";
    std::cout << "SIMD SUBQ: " << simd_subq_insn
              << " insns, " << simd_subq_ops << " lane-ops\n";
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