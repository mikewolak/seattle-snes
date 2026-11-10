/* cpu65.S - 65C816 instruction loop of the Snes9x 1.39 core in R5000
 * assembler (MIPS IV, o32, little-endian).
 * EPROM Foundry Inc. / Mike Wolak, project Blitz99.
 *
 * s9xa_run is S9xMainLoop of cpuexec.cpp (LSB_FIRST, VAR_CYCLES,
 * CPU_SHUTDOWN, no debugger, no SA-1) with the 65C816 state held in
 * registers; the opcodes it implements are the core's handlers of
 * cpuops.cpp, cpuaddr.h and cpumacro.h step for step: the same memory
 * accesses in the same order, the same additions to CPU.Cycles before
 * each access, the same CPU.WaitAddress updates (CPU_SHUTDOWN). Opcodes
 * without a handler here run the core's C handler (op_c) with the state
 * written back and read again. Memory accesses read Memory.Map /
 * Memory.WriteMap, MemorySpeed and BlockIsRAM as getset.h does; an entry
 * below MAP_LAST (I/O, SRAM, special chips) goes to the C function of
 * getset.h (s9x_cpu.cpp) with PC, Cycles and PCAtOpcodeStart written to
 * CPU first and PC and Cycles read back after.
 *
 * Registers across opcodes:
 *   s0  CPU.PC (host pointer)        s1  CPU.Cycles
 *   s2  Registers.A.W                s3  Registers.X.W
 *   s4  Registers.Y.W                s5  ICPU._Zero (zero: Z set)
 *   s6  ICPU._Negative (bit 7: N)    s7  ICPU._Carry (0 or 1)
 *   s8  &Registers                   gp  &CPU
 *   t1  ICPU.ShiftedDB               t4  CPU.PCBase
 *   t2  MemorySpeed of bank 0 0000-1FFF
 *   t5  Memory.Map of bank 0 0000-1FFF when both blocks there are the
 *       same RAM for reading and writing with one speed (bank 0 low RAM:
 *       the direct page and the stack of most programs), else 0
 *   t3  &Memory.MemorySpeed (Map at -32768, WriteMap at -16384,
 *       BlockIsRAM at +4096)
 *   t6  CPU.PCAtOpcodeStart          t7  CPU.MemSpeed
 *   t8  limit: the loop leaves the fast path when Cycles >= limit;
 *       CPU.NextEvent, or the smallest integer while CPU.Flags is not
 *       zero (every opcode then takes the event and interrupt path, as
 *       S9xMainLoop does)
 *   t0  next free entry of s9xa_ring: CPU.Cycles at the start of each
 *       loop pass since the SPC700 last ran
 *   t9  jump table of the current M/X mode (emulation mode: M1X1, as
 *       S9xFixCycles)
 * Registers.P, D, S, DB, PB, ICPU.ShiftedPB, _Overflow and the rest of
 * CPU stay in memory; ShiftedDB and PCBase are written there as well when
 * they change. The limit is computed again after every call of C code,
 * the only code that changes NextEvent, Flags, APU.Cycles and
 * IAPU.APUExecuting. t5 and t2 come from s9x_cpu.cpp at each entry: the
 * map of bank 0 0000-1FFF is set at cartridge load (memmap.cpp) and
 * changed only by SA-1 code (sa1.cpp), which this loop does not run;
 * FixROMSpeed and the S-DD1 map change banks 80-FF only.
 *
 * SPC700: S9xMainLoop runs the SPC700 up to CPU.Cycles before every
 * 65C816 opcode (APU_EXECUTE). This loop records CPU.Cycles of each pass
 * in s9xa_ring instead and runs the SPC700 over the recorded limits
 * (s9xa_spc_sync, spc700.S) before every call of C code, before
 * CPUShutdown and at the end of the frame. The two machines meet only
 * through C code (the APU ports $2140-$217F in S9xGetPPU/S9xSetPPU, DMA,
 * the SPC700 timers and the cycle rebase in S9xDoHBlankProcessing), so
 * both run the same opcodes against the same values. A pass is at most
 * H_Max / ONE_CYCLE = 228 opcodes from the next event, so 1,024 entries
 * do not fill.
 *
 * Branches do not test CPU.BranchSkip: it is set only with the SPC700
 * off (ppu.cpp, Settings.APUEnabled clear), and s9x_cpu.cpp then sends
 * the branch opcodes to the core's handlers.
 */
#include "s9x_offs.h"

#define PC    $16
#define CYC   $17
#define RA    $18
#define RX    $19
#define RY    $20
#define RZ    $21
#define RN    $22
#define RC    $23
#define REG   $30
#define MSP   $11
#define OPS   $14
#define MS    $15
#define LIM   $24
#define TAB   $25
#define at    $1
#define v0    $2
#define v1    $3
#define a0    $4
#define a1    $5
#define a2    $6
#define a3    $7
#define RP    $8
#define DBR   $9
#define LRS   $10
#define PCB   $12
#define LRB   $13

#define FR_TAB  64                      /* frame slots: t9, t5, t2 */
#define FR_LRB  68
#define FR_LRS  72
#define FR_OP   76                      /* frame slots: opcode for op_c, */
#define FR_SH   80                      /* CPUShutdown's SPC700 limit */
#define FRAME   88

#define MAP_OFF       (MEM_Map - MEM_MemorySpeed)
#define WMAP_OFF      (MEM_WriteMap - MEM_MemorySpeed)
#define RAM_OFF       (MEM_BlockIsRAM - MEM_MemorySpeed)

    .set    noreorder
    .set    noat

/* ---- memory word at a symbol + offset ------------------------------------ */
    .macro  LWS r, sym
    lui     \r, %hi(\sym)
    lw      \r, %lo(\sym)(\r)
    .endm
    .macro  LBUS r, sym
    lui     \r, %hi(\sym)
    lbu     \r, %lo(\sym)(\r)
    .endm

/* ---- loop limit (t8) from CPU.Flags and CPU.NextEvent --------------------- */
    .macro  LIMIT
    lw      LIM, CPU_Flags($28)
    bnez    LIM, 91f
    lui     LIM, 0x8000
    lw      LIM, CPU_NextEvent($28)
91:
    .endm

/* ---- the SPC700 over the recorded limits (gp = _gp); clobbers the
 * caller-saved registers, leaves t0 at the start of the ring -------------- */
    .macro  SPCSYNC
    lui     a0, %hi(s9xa_ring)
    addiu   a0, a0, %lo(s9xa_ring)
    move    a1, RP
    jal     s9xa_spc_sync
    move    a2, $0
    lui     RP, %hi(s9xa_ring)
    addiu   RP, RP, %lo(s9xa_ring)
    .endm

/* ---- gp: &CPU in the loop; the linker's _gp for C code (newlib reaches
 * _impure_ptr gp-relative) ---------------------------------------------------- */
    .macro  GP_C
    lui     $28, %hi(_gp)
    addiu   $28, $28, %lo(_gp)
    .endm
    .macro  GP_CPU
    lui     $28, %hi(CPU)
    addiu   $28, $28, %lo(CPU)
    .endm

/* ---- event counters of an S9XA_HIST build --------------------------------------- */
    .macro  COUNT n                     /* s9xa_cnt[n]++; uses at, v1 */
#ifdef S9XA_HIST
    lui     v1, %hi(s9xa_cnt+4*\n)
    lw      at, %lo(s9xa_cnt+4*\n)(v1)
    addiu   at, at, 1
    sw      at, %lo(s9xa_cnt+4*\n)(v1)
#endif
    .endm

/* ---- t3 = &Memory.MemorySpeed ---------------------------------------------------- */
    .macro  SETMSP
    lui     MSP, %hi(Memory+MEM_MemorySpeed)
    addiu   MSP, MSP, %lo(Memory+MEM_MemorySpeed)
    .endm

/* ---- t-register state after a call of C code at the loop level -------------- */
    .macro  RELOAD
    lw      MS, CPU_MemSpeed($28)
    lw      PCB, CPU_PCBase($28)
    lw      TAB, FR_TAB($sp)
    lw      LRB, FR_LRB($sp)
    lw      LRS, FR_LRS($sp)
    LWS     DBR, ICPU+ICPU_ShiftedDB
    SETMSP
    lui     RP, %hi(s9xa_ring)
    addiu   RP, RP, %lo(s9xa_ring)
    .endm

/* ---- all state to the core's structures / back ------------------------------- */
    .macro  SYNC_OUT
    sw      PC, CPU_PC($28)
    sw      CYC, CPU_Cycles($28)
    sw      OPS, CPU_PCAtOpcodeStart($28)
    sh      RA, REG_A(REG)
    sh      RX, REG_X(REG)
    sh      RY, REG_Y(REG)
    lui     v1, %hi(ICPU)
    addiu   v1, v1, %lo(ICPU)
    sltu    at, $0, RZ
    sb      at, ICPU_Zero(v1)
    sb      RN, ICPU_Negative(v1)
    sb      RC, ICPU_Carry(v1)
    .endm

    .macro  SYNC_IN
    lw      PC, CPU_PC($28)
    lw      CYC, CPU_Cycles($28)
    lhu     RA, REG_A(REG)
    lhu     RX, REG_X(REG)
    lhu     RY, REG_Y(REG)
    lui     v1, %hi(ICPU)
    addiu   v1, v1, %lo(ICPU)
    lbu     RZ, ICPU_Zero(v1)
    lbu     RN, ICPU_Negative(v1)
    lbu     RC, ICPU_Carry(v1)
    bal     settab
    nop
    RELOAD
    LIMIT
    .endm

/* ---- operand fetch from the instruction stream ------------------------------- */
    .macro  FETCH8 r
    lbu     \r, 0(PC)
    addiu   PC, PC, 1
    .endm
    .macro  FETCH16 r
    lbu     \r, 0(PC)
    lbu     at, 1(PC)
    addiu   PC, PC, 2
    sll     at, at, 8
    or      \r, \r, at
    .endm
    .macro  FETCH24 r
    lbu     \r, 0(PC)
    lbu     at, 1(PC)
    sll     at, at, 8
    or      \r, \r, at
    lbu     at, 2(PC)
    addiu   PC, PC, 3
    sll     at, at, 16
    or      \r, \r, at
    .endm
    .macro  CYC1
    addu    CYC, CYC, MS
    .endm
    .macro  CYC2
    addu    CYC, CYC, MS
    addu    CYC, CYC, MS
    .endm
    .macro  CYC3
    addu    CYC, CYC, MS
    addu    CYC, CYC, MS
    addu    CYC, CYC, MS
    .endm
    .macro  SHPB r                      /* r = ICPU.ShiftedPB */
    LWS     \r, ICPU+ICPU_ShiftedPB
    .endm

/* ---- addressing modes (cpuaddr.h): OpAddress in a0 --------------------------- */
    .macro  AM_DP                       /* Direct */
    lbu     a0, 0(PC)
    lhu     at, REG_D(REG)
    addiu   PC, PC, 1
    addu    a0, a0, at
    andi    a0, a0, 0xffff
    CYC1
    .endm
    .macro  AM_DPX                      /* DirectIndexedX */
    lbu     a0, 0(PC)
    lhu     at, REG_D(REG)
    addiu   PC, PC, 1
    addu    a0, a0, at
    addu    a0, a0, RX
    andi    a0, a0, 0xffff
    CYC1
    addiu   CYC, CYC, 6
    .endm
    .macro  AM_DPY                      /* DirectIndexedY */
    lbu     a0, 0(PC)
    lhu     at, REG_D(REG)
    addiu   PC, PC, 1
    addu    a0, a0, at
    addu    a0, a0, RY
    andi    a0, a0, 0xffff
    CYC1
    addiu   CYC, CYC, 6
    .endm
    .macro  AM_DPI                      /* DirectIndirect */
    AM_DP
    bal     rd16
    nop
    addu    a0, DBR, v0
    .endm
    .macro  AM_DPIX                     /* DirectIndexedIndirect */
    lbu     a0, 0(PC)
    lhu     at, REG_D(REG)
    addiu   PC, PC, 1
    addu    a0, a0, at
    addu    a0, a0, RX
    andi    a0, a0, 0xffff
    CYC1
    bal     rd16
    nop
    addu    a0, DBR, v0
    addiu   CYC, CYC, 6
    .endm
    .macro  AM_DPIY                     /* DirectIndirectIndexed */
    AM_DP
    bal     rd16
    nop
    addu    a0, DBR, v0
    addu    a0, a0, RY
    .endm
    .macro  AM_DPIL                     /* DirectIndirectLong */
    AM_DP
    bal     rd16
    nop
    move    a1, v0
    bal     rd8
    addiu   a0, a0, 2
    sll     v0, v0, 16
    addu    a0, a1, v0
    .endm
    .macro  AM_DPILY                    /* DirectIndirectIndexedLong */
    AM_DPIL
    addu    a0, a0, RY
    .endm
    .macro  AM_ABS                      /* Absolute */
    FETCH16 a0
    addu    a0, a0, DBR
    CYC2
    .endm
    .macro  AM_ABSX                     /* AbsoluteIndexedX */
    FETCH16 a0
    addu    a0, a0, DBR
    addu    a0, a0, RX
    CYC2
    .endm
    .macro  AM_ABSY                     /* AbsoluteIndexedY */
    FETCH16 a0
    addu    a0, a0, DBR
    addu    a0, a0, RY
    CYC2
    .endm
    .macro  AM_LONG                     /* AbsoluteLong */
    FETCH24 a0
    CYC3
    .endm
    .macro  AM_LONGX                    /* AbsoluteLongIndexedX */
    FETCH24 a0
    addu    a0, a0, RX
    sll     a0, a0, 8
    srl     a0, a0, 8
    CYC3
    .endm
    .macro  AM_SR                       /* StackRelative */
    lbu     a0, 0(PC)
    lhu     at, REG_S(REG)
    addiu   PC, PC, 1
    addu    a0, a0, at
    andi    a0, a0, 0xffff
    CYC1
    addiu   CYC, CYC, 6
    .endm
    .macro  AM_SRIY                     /* StackRelativeIndirectIndexed */
    lbu     a0, 0(PC)
    lhu     at, REG_S(REG)
    addiu   PC, PC, 1
    addu    a0, a0, at
    andi    a0, a0, 0xffff
    CYC1
    addiu   CYC, CYC, 12
    bal     rd16
    nop
    addu    a0, DBR, v0
    addu    a0, a0, RY
    sll     a0, a0, 8
    srl     a0, a0, 8
    .endm

/* ---- flags ----------------------------------------------------------------- */
    .macro  ZN8 r                       /* SetZN8 */
    move    RZ, \r
    move    RN, \r
    .endm
    .macro  ZN16 r                      /* SetZN16 */
    move    RZ, \r
    srl     RN, \r, 8
    .endm
    .macro  SETLO dst, src              /* dst = (dst & 0xff00) | src (src < 0x100) */
    srl     \dst, \dst, 8
    sll     \dst, \dst, 8
    or      \dst, \dst, \src
    .endm
    .macro  SETV r                      /* ICPU._Overflow = r (0 or 1); uses v1 */
    lui     v1, %hi(ICPU+ICPU_Overflow)
    sb      \r, %lo(ICPU+ICPU_Overflow)(v1)
    .endm
    .macro  DECCHK                      /* decimal mode: the core's handler */
    lbu     at, REG_P(REG)
    andi    at, at, 8
    bnez    at, op_c
    nop
    .endm

/* ---- operations on a value read into v0 (cpumacro.h) ------------------------ */
    .macro  OP_LDA8
    SETLO   RA, v0
    ZN8     v0
    .endm
    .macro  OP_LDA16
    move    RA, v0
    ZN16    v0
    .endm
    .macro  OP_LDX8
    SETLO   RX, v0
    ZN8     v0
    .endm
    .macro  OP_LDX16
    move    RX, v0
    ZN16    v0
    .endm
    .macro  OP_LDY8
    SETLO   RY, v0
    ZN8     v0
    .endm
    .macro  OP_LDY16
    move    RY, v0
    ZN16    v0
    .endm
    .macro  OP_AND8
    ori     v0, v0, 0xff00
    and     RA, RA, v0
    andi    v0, RA, 0xff
    ZN8     v0
    .endm
    .macro  OP_AND16
    and     RA, RA, v0
    ZN16    RA
    .endm
    .macro  OP_ORA8
    or      RA, RA, v0
    andi    v0, RA, 0xff
    ZN8     v0
    .endm
    .macro  OP_ORA16
    or      RA, RA, v0
    ZN16    RA
    .endm
    .macro  OP_EOR8
    xor     RA, RA, v0
    andi    v0, RA, 0xff
    ZN8     v0
    .endm
    .macro  OP_EOR16
    xor     RA, RA, v0
    ZN16    RA
    .endm
    .macro  CMPN8 r                     /* CMP8, CMX8, CMY8 */
    andi    at, \r, 0xff
    sltu    RC, at, v0
    xori    RC, RC, 1
    subu    v0, at, v0
    andi    v0, v0, 0xff
    ZN8     v0
    .endm
    .macro  CMPN16 r                    /* CMP16, CMX16, CMY16 */
    sltu    RC, \r, v0
    xori    RC, RC, 1
    subu    v0, \r, v0
    andi    v0, v0, 0xffff
    ZN16    v0
    .endm
    .macro  OP_CMP8
    CMPN8   RA
    .endm
    .macro  OP_CMP16
    CMPN16  RA
    .endm
    .macro  OP_CPX8
    CMPN8   RX
    .endm
    .macro  OP_CPX16
    CMPN16  RX
    .endm
    .macro  OP_CPY8
    CMPN8   RY
    .endm
    .macro  OP_CPY16
    CMPN16  RY
    .endm
    .macro  OP_BIT8
    srl     at, v0, 6
    andi    at, at, 1
    SETV    at
    move    RN, v0
    and     RZ, v0, RA
    .endm
    .macro  OP_BIT16
    srl     at, v0, 14
    andi    at, at, 1
    SETV    at
    srl     RN, v0, 8
    and     RZ, v0, RA
    .endm
    .macro  OP_ADC8                     /* binary mode (DECCHK first) */
    andi    a1, RA, 0xff
    addu    a2, a1, v0
    addu    a2, a2, RC
    srl     RC, a2, 8
    xor     at, a1, v0
    nor     at, at, $0
    xor     a3, v0, a2
    and     at, at, a3
    srl     at, at, 7
    andi    at, at, 1
    SETV    at
    andi    a2, a2, 0xff
    SETLO   RA, a2
    ZN8     a2
    .endm
    .macro  OP_ADC16
    addu    a2, RA, v0
    addu    a2, a2, RC
    srl     RC, a2, 16
    xor     at, RA, v0
    nor     at, at, $0
    xor     a3, v0, a2
    and     at, at, a3
    srl     at, at, 15
    andi    at, at, 1
    SETV    at
    andi    RA, a2, 0xffff
    ZN16    RA
    .endm
    .macro  OP_SBC8
    andi    a1, RA, 0xff
    subu    a2, a1, v0
    addu    a2, a2, RC
    addiu   a2, a2, -1
    slt     RC, a2, $0
    xori    RC, RC, 1
    andi    a2, a2, 0xff
    xor     at, a1, v0
    xor     a3, a1, a2
    and     at, at, a3
    srl     at, at, 7
    andi    at, at, 1
    SETV    at
    SETLO   RA, a2
    ZN8     a2
    .endm
    .macro  OP_SBC16
    subu    a2, RA, v0
    addu    a2, a2, RC
    addiu   a2, a2, -1
    slt     RC, a2, $0
    xori    RC, RC, 1
    andi    a2, a2, 0xffff
    xor     at, RA, v0
    xor     a3, RA, a2
    and     at, at, a3
    srl     at, at, 15
    andi    at, at, 1
    SETV    at
    move    RA, a2
    ZN16    RA
    .endm

/* ---- handler generators ------------------------------------------------------ */
    .macro  RD8 lbl, am, op             /* addressing mode, byte read, operation */
\lbl:
    AM_\am
    bal     rd8
    nop
    OP_\op\()8
    b       next
    nop
    .endm
    .macro  RD16 lbl, am, op
\lbl:
    AM_\am
    bal     rd16
    nop
    OP_\op\()16
    b       next
    nop
    .endm
    .macro  RDD8 lbl, am, op            /* ADC, SBC: the core's handler in decimal mode */
\lbl:
    DECCHK
    AM_\am
    bal     rd8
    nop
    OP_\op\()8
    b       next
    nop
    .endm
    .macro  RDD16 lbl, am, op
\lbl:
    DECCHK
    AM_\am
    bal     rd16
    nop
    OP_\op\()16
    b       next
    nop
    .endm
    .macro  ST8 lbl, am, r              /* STA8, STX8, STY8, STZ8 */
\lbl:
    AM_\am
    bal     wr8
    move    a1, \r
    b       next
    nop
    .endm
    .macro  ST16 lbl, am, r
\lbl:
    AM_\am
    bal     wr16
    move    a1, \r
    b       next
    nop
    .endm

/* ---- read-modify-write (cpumacro.h ASL8 ... TSB16) ---------------------------- */
    .macro  RMW8 lbl, am, op
\lbl:
    AM_\am
    addiu   CYC, CYC, 6
    RMWOP8_\op
    b       next
    nop
    .endm
    .macro  RMW16 lbl, am, op
\lbl:
    AM_\am
    addiu   CYC, CYC, 6
    RMWOP16_\op
    b       next
    nop
    .endm
    .macro  RMWOP8_ASL
    bal     rd8
    nop
    srl     RC, v0, 7
    sll     a1, v0, 1
    andi    a1, a1, 0xff
    bal     wr8
    nop
    ZN8     a1
    .endm
    .macro  RMWOP16_ASL
    bal     rd16
    nop
    srl     RC, v0, 15
    sll     a1, v0, 1
    andi    a1, a1, 0xffff
    bal     wr16
    nop
    ZN16    a1
    .endm
    .macro  RMWOP8_LSR
    bal     rd8
    nop
    andi    RC, v0, 1
    srl     a1, v0, 1
    bal     wr8
    nop
    ZN8     a1
    .endm
    .macro  RMWOP16_LSR
    bal     rd16
    nop
    andi    RC, v0, 1
    srl     a1, v0, 1
    bal     wr16
    nop
    ZN16    a1
    .endm
    .macro  RMWOP8_ROL
    bal     rd8
    nop
    sll     a1, v0, 1
    or      a1, a1, RC
    srl     RC, a1, 8
    andi    a1, a1, 0xff
    bal     wr8
    nop
    ZN8     a1
    .endm
    .macro  RMWOP16_ROL
    bal     rd16
    nop
    sll     a1, v0, 1
    or      a1, a1, RC
    srl     RC, a1, 16
    andi    a1, a1, 0xffff
    bal     wr16
    nop
    ZN16    a1
    .endm
    .macro  RMWOP8_ROR
    bal     rd8
    nop
    sll     at, RC, 8
    or      a1, v0, at
    andi    RC, a1, 1
    srl     a1, a1, 1
    bal     wr8
    nop
    ZN8     a1
    .endm
    .macro  RMWOP16_ROR
    bal     rd16
    nop
    sll     at, RC, 16
    or      a1, v0, at
    andi    RC, a1, 1
    srl     a1, a1, 1
    bal     wr16
    nop
    ZN16    a1
    .endm
    .macro  RMWOP8_INC
    sw      $0, CPU_WaitAddress($28)
    bal     rd8
    nop
    addiu   a1, v0, 1
    andi    a1, a1, 0xff
    bal     wr8
    nop
    ZN8     a1
    .endm
    .macro  RMWOP16_INC
    sw      $0, CPU_WaitAddress($28)
    bal     rd16
    nop
    addiu   a1, v0, 1
    andi    a1, a1, 0xffff
    bal     wr16
    nop
    ZN16    a1
    .endm
    .macro  RMWOP8_DEC
    sw      $0, CPU_WaitAddress($28)
    bal     rd8
    nop
    addiu   a1, v0, -1
    andi    a1, a1, 0xff
    bal     wr8
    nop
    ZN8     a1
    .endm
    .macro  RMWOP16_DEC
    sw      $0, CPU_WaitAddress($28)
    bal     rd16
    nop
    addiu   a1, v0, -1
    andi    a1, a1, 0xffff
    bal     wr16
    nop
    ZN16    a1
    .endm
    .macro  RMWOP8_TSB
    bal     rd8
    nop
    and     RZ, v0, RA
    andi    RZ, RZ, 0xff
    andi    at, RA, 0xff
    bal     wr8
    or      a1, v0, at
    .endm
    .macro  RMWOP16_TSB
    bal     rd16
    nop
    and     RZ, v0, RA
    bal     wr16
    or      a1, v0, RA
    .endm
    .macro  RMWOP8_TRB
    bal     rd8
    nop
    and     RZ, v0, RA
    andi    RZ, RZ, 0xff
    nor     at, RA, $0
    and     a1, v0, at
    bal     wr8
    andi    a1, a1, 0xff
    .endm
    .macro  RMWOP16_TRB
    bal     rd16
    nop
    and     RZ, v0, RA
    nor     at, RA, $0
    and     a1, v0, at
    bal     wr16
    andi    a1, a1, 0xffff
    .endm

/* ---- pushes and pulls (cpuops.cpp PushB, PushW, PullB, PullW) ---------------- */
    .macro  PUSHB r                     /* S9xSetByte (r, Registers.S.W--) */
    lhu     a0, REG_S(REG)
    move    a1, \r
    bal     wr8
    addiu   at, a0, -1
    lhu     at, REG_S(REG)
    addiu   at, at, -1
    sh      at, REG_S(REG)
    .endm
    .macro  PUSHW r                     /* S9xSetWord (r, Registers.S.W - 1); S.W -= 2 */
    lhu     a0, REG_S(REG)
    move    a1, \r
    bal     wr16
    addiu   a0, a0, -1
    lhu     at, REG_S(REG)
    addiu   at, at, -2
    sh      at, REG_S(REG)
    .endm
    .macro  PULLB                       /* v0 = S9xGetByte (++Registers.S.W) */
    lhu     a0, REG_S(REG)
    addiu   a0, a0, 1
    andi    a0, a0, 0xffff
    bal     rd8
    sh      a0, REG_S(REG)
    .endm
    .macro  PULLW                       /* v0 = S9xGetWord (Registers.S.W + 1); S.W += 2 */
    lhu     a0, REG_S(REG)
    bal     rd16
    addiu   a0, a0, 1
    lhu     at, REG_S(REG)
    addiu   at, at, 2
    sh      at, REG_S(REG)
    .endm

/* ---- branches (Relative, BranchCheck, CPUShutdown) --------------------------- */
    .macro  TAKEN                       /* a0 = Int8 */
    subu    at, PC, PCB
    addu    at, at, a0
    andi    at, at, 0xffff
    addu    PC, PCB, at
    lw      at, CPU_WaitAddress($28)
    bne     at, PC, next
    addiu   CYC, CYC, 6
    b       shutdown
    nop
    .endm
    .macro  BRANCH lbl, cond, reg
\lbl:
    lb      a0, 0(PC)
    addiu   PC, PC, 1
    \cond   \reg, next
    addu    CYC, CYC, MS
    TAKEN
    .endm

/* ============================================================================ */
    .text
    .align  4

    .if (MEM_Map - MEM_MemorySpeed) != -32768
    .error  "Memory.Map is not 32768 bytes below Memory.MemorySpeed"
    .endif
    .if (MEM_WriteMap - MEM_MemorySpeed) != -16384
    .error  "Memory.WriteMap is not 16384 bytes below Memory.MemorySpeed"
    .endif
    .if (MEM_BlockIsRAM - MEM_MemorySpeed) != 4096
    .error  "Memory.BlockIsRAM is not 4096 bytes above Memory.MemorySpeed"
    .endif

/* void s9xa_run (void): S9xMainLoop's loop; returns at SCAN_KEYS_FLAG with
 * the state in CPU, Registers and ICPU */
    .globl  s9xa_run
    .ent    s9xa_run
s9xa_run:
    addiu   $sp, $sp, -FRAME
    sw      $31, 60($sp)
    sw      $30, 56($sp)
    sw      $28, 52($sp)
    sw      $23, 48($sp)
    sw      $22, 44($sp)
    sw      $21, 40($sp)
    sw      $20, 36($sp)
    sw      $19, 32($sp)
    sw      $18, 28($sp)
    sw      $17, 24($sp)
    sw      $16, 20($sp)
    lui     $28, %hi(CPU)
    addiu   $28, $28, %lo(CPU)
    lui     REG, %hi(Registers)
    addiu   REG, REG, %lo(Registers)
    LWS     at, s9xa_lr_base
    sw      at, FR_LRB($sp)
    LWS     at, s9xa_lr_speed
    sw      at, FR_LRS($sp)
    lw      OPS, CPU_PCAtOpcodeStart($28)
    SYNC_IN
    b       loop_top                    /* S9xMainLoop starts at the APU step */
    nop

/* after each opcode: DO_HBLANK_CHECK, then the next loop pass */
next:
    slt     at, CYC, LIM
    beqz    at, slow
    lbu     v0, 0(PC)
    sw      CYC, 0(RP)                  /* this pass's APU_EXECUTE limit */
    addiu   RP, RP, 4
disp:                                   /* v0 = opcode at PC */
    move    OPS, PC
    sll     v1, v0, 2
    addu    v1, v1, TAB
    lw      v1, 0(v1)
#ifdef S9XA_HIST
    lui     a0, %hi(s9xa_tables)
    addiu   a0, a0, %lo(s9xa_tables)
    subu    a0, TAB, a0
    sll     at, v0, 2
    addu    a0, a0, at
    lui     at, %hi(s9xa_hist)
    addu    a0, a0, at
    lw      at, %lo(s9xa_hist)(a0)
    addiu   at, at, 1
    sw      at, %lo(s9xa_hist)(a0)
#endif
    addiu   PC, PC, 1
    jr      v1
    addu    CYC, CYC, MS

slow:
    lw      v0, CPU_NextEvent($28)
    slt     at, CYC, v0
    bnez    at, loop_top
    nop
    COUNT   1
    sw      PC, CPU_PC($28)             /* S9xDoHBlankProcessing reads and writes */
    sw      CYC, CPU_Cycles($28)        /* PC, Cycles and PCAtOpcodeStart of the */
    sw      OPS, CPU_PCAtOpcodeStart($28) /* 65C816 state only */
    GP_C
    SPCSYNC
    jal     S9xDoHBlankProcessing
    nop
    GP_CPU
    lw      PC, CPU_PC($28)
    lw      CYC, CPU_Cycles($28)
    RELOAD
loop_top:
    sw      CYC, 0(RP)                  /* APU_EXECUTE limit of this pass */
    addiu   RP, RP, 4
    /* CPU.Flags: NMI, IRQ, end of frame */
    lw      v0, CPU_Flags($28)
    beqz    v0, 4f
    nop
    COUNT   2
    SYNC_OUT
    GP_C
    SPCSYNC
    jal     s9xa_flags
    nop
    GP_CPU
    bnez    v0, run_exit
    nop
    SYNC_IN
4:  LIMIT
    b       disp
    lbu     v0, 0(PC)

run_exit:
    lw      $31, 60($sp)
    lw      $30, 56($sp)
    lw      $28, 52($sp)
    lw      $23, 48($sp)
    lw      $22, 44($sp)
    lw      $21, 40($sp)
    lw      $20, 36($sp)
    lw      $19, 32($sp)
    lw      $18, 28($sp)
    lw      $17, 24($sp)
    lw      $16, 20($sp)
    jr      $31
    addiu   $sp, $sp, FRAME
    .end    s9xa_run

/* ---- the core's C handler for this opcode (v0 = opcode) ------------------------ */
    .globl  s9xa_op_c
s9xa_op_c:
op_c:
#ifdef S9XA_HIST
    lui     a0, %hi(s9xa_tables)
    addiu   a0, a0, %lo(s9xa_tables)
    subu    a0, TAB, a0
    sll     at, v0, 2
    addu    a0, a0, at
    lui     at, %hi(s9xa_fall)
    addu    a0, a0, at
    lw      at, %lo(s9xa_fall)(a0)
    addiu   at, at, 1
    sw      at, %lo(s9xa_fall)(a0)
#endif
    sw      v0, FR_OP($sp)
    SYNC_OUT
    GP_C
    SPCSYNC
    lw      a3, FR_OP($sp)
    LWS     at, ICPU+ICPU_S9xOpcodes
    sll     a3, a3, 2
    addu    at, at, a3
    lw      at, 0(at)
    jalr    at
    nop
    GP_CPU
    SYNC_IN
    b       next
    nop

/* ---- t9 and ICPU.S9xOpcodes from Registers.P (S9xFixCycles); uses at, v0, v1 */
settab:
    lhu     v0, REG_P(REG)
    andi    at, v0, 0x100
    srl     v0, v0, 4
    andi    v0, v0, 3                   /* M << 1 | X: 0 M0X0, 1 M0X1, 2 M1X0, 3 M1X1 */
    li      v1, 3
    movn    v0, v1, at                  /* emulation mode: M1X1 */
    sll     v1, v0, 10
    lui     TAB, %hi(s9xa_tables)
    addiu   TAB, TAB, %lo(s9xa_tables)
    addu    TAB, TAB, v1
    sw      TAB, FR_TAB($sp)
    sll     v0, v0, 2
    lui     at, %hi(s9xa_ctab)
    addu    at, at, v0
    lw      v1, %lo(s9xa_ctab)(at)
    lui     at, %hi(ICPU+ICPU_S9xOpcodes)
    jr      $31
    sw      v1, %lo(ICPU+ICPU_S9xOpcodes)(at)

/* ---- C call from inside an opcode: v0 = function, a0, a1 = arguments;
 * returns v0; preserves a0-a3 and the t-register state; runs
 * the SPC700 over the recorded limits first; PC and Cycles
 * go through CPU, MemSpeed and PCBase are read back (S9xSetPCBase) */
ccall:
    COUNT   0
    addiu   $sp, $sp, -64
    sw      $31, 60($sp)
    sw      a0, 16($sp)
    sw      a1, 20($sp)
    sw      a2, 24($sp)
    sw      a3, 28($sp)
    sw      v0, 32($sp)
    sw      DBR, 36($sp)
    sw      LRS, 40($sp)
    sw      OPS, 44($sp)
    sw      TAB, 48($sp)
    sw      LRB, 52($sp)
    sw      PC, CPU_PC($28)
    sw      CYC, CPU_Cycles($28)
    sw      OPS, CPU_PCAtOpcodeStart($28)
    GP_C
    SPCSYNC
    lw      a0, 16($sp)
    lw      a1, 20($sp)
    lw      v0, 32($sp)
    jalr    v0
    nop
    GP_CPU
    lw      PC, CPU_PC($28)
    lw      CYC, CPU_Cycles($28)
    lw      MS, CPU_MemSpeed($28)
    lw      PCB, CPU_PCBase($28)
    SETMSP
    LIMIT
    lw      $31, 60($sp)
    lw      a0, 16($sp)
    lw      a1, 20($sp)
    lw      a2, 24($sp)
    lw      a3, 28($sp)
    lw      DBR, 36($sp)
    lw      LRS, 40($sp)
    lw      OPS, 44($sp)
    lw      TAB, 48($sp)
    lw      LRB, 52($sp)
    lui     RP, %hi(s9xa_ring)
    addiu   RP, RP, %lo(s9xa_ring)
    jr      $31
    addiu   $sp, $sp, 64

/* ---- S9xGetByte: a0 = address; returns v0; preserves a0-a3 ------------------- */
rd8:
    sltiu   at, a0, 0x2000              /* bank 0 low RAM: Map[0] + a, BlockIsRAM */
    beqz    at, rd8_g
    srl     v1, a0, 12
    beqz    LRB, rd8_g
    addu    v0, LRB, a0
    addu    CYC, CYC, LRS
    lbu     v0, 0(v0)
    jr      $31
    sw      OPS, CPU_WaitAddress($28)
rd8_g:
    andi    v1, v1, 0xfff
    sll     at, v1, 2
    addu    at, at, MSP
    lw      v0, MAP_OFF(at)
    addu    v1, v1, MSP
    sltiu   at, v0, MEM_MAP_LAST
    bnez    at, rd8_c
    lbu     at, 0(v1)                   /* MemorySpeed [block] */
    addu    CYC, CYC, at
    lbu     at, RAM_OFF(v1)             /* BlockIsRAM [block] */
    andi    v1, a0, 0xffff
    addu    v1, v0, v1
    beqz    at, 1f
    lbu     v0, 0(v1)
    sw      OPS, CPU_WaitAddress($28)
1:  jr      $31
    nop
rd8_c:
    lui     v0, %hi(s9xa_getbyte)
    b       ccall
    addiu   v0, v0, %lo(s9xa_getbyte)

/* ---- S9xGetWord: a0 = address; returns v0 ---------------------------------- */
rd16:
    sltiu   at, a0, 0x1fff              /* bank 0 low RAM, both bytes */
    beqz    at, rd16_g
    nop
    beqz    LRB, rd16_g
    addu    v1, LRB, a0
    addu    CYC, CYC, LRS
    addu    CYC, CYC, LRS
    lbu     v0, 0(v1)
    lbu     v1, 1(v1)
    sw      OPS, CPU_WaitAddress($28)
    sll     v1, v1, 8
    jr      $31
    or      v0, v0, v1
rd16_g:
    andi    at, a0, 0x1fff
    xori    at, at, 0x1fff
    beqz    at, rd16_split
    srl     v1, a0, 12
    andi    v1, v1, 0xfff
    sll     at, v1, 2
    addu    at, at, MSP
    lw      v0, MAP_OFF(at)
    addu    v1, v1, MSP
    sltiu   at, v0, MEM_MAP_LAST
    bnez    at, rd16_c
    lbu     at, 0(v1)
    sll     at, at, 1
    addu    CYC, CYC, at
    lbu     at, RAM_OFF(v1)
    andi    v1, a0, 0xffff
    addu    v1, v0, v1
    lbu     v0, 0(v1)
    beqz    at, 1f
    lbu     v1, 1(v1)
    sw      OPS, CPU_WaitAddress($28)
1:  sll     v1, v1, 8
    jr      $31
    or      v0, v0, v1
rd16_c:
    lui     v0, %hi(s9xa_getword)
    b       ccall
    addiu   v0, v0, %lo(s9xa_getword)
rd16_split:                             /* GetByte (a) | GetByte (a + 1) << 8 */
    addiu   $sp, $sp, -16
    sw      $31, 0($sp)
    sw      a0, 4($sp)
    bal     rd8
    nop
    sw      v0, 8($sp)
    bal     rd8
    addiu   a0, a0, 1
    sll     v0, v0, 8
    lw      at, 8($sp)
    lw      a0, 4($sp)
    lw      $31, 0($sp)
    or      v0, v0, at
    jr      $31
    addiu   $sp, $sp, 16

/* ---- S9xSetByte: a0 = address, a1 = byte; preserves a0-a3 ------------------- */
wr8:
    sltiu   at, a0, 0x2000              /* bank 0 low RAM: WriteMap[0] + a */
    beqz    at, wr8_g
    sw      $0, CPU_WaitAddress($28)
    beqz    LRB, wr8_g
    addu    v1, LRB, a0
    addu    CYC, CYC, LRS
    jr      $31
    sb      a1, 0(v1)
wr8_g:
    srl     v1, a0, 12
    andi    v1, v1, 0xfff
    sll     at, v1, 2
    addu    at, at, MSP
    lw      v0, WMAP_OFF(at)
    addu    v1, v1, MSP
    sltiu   at, v0, MEM_MAP_LAST
    bnez    at, wr8_c
    lbu     at, 0(v1)
    addu    CYC, CYC, at
    andi    v1, a0, 0xffff
    addu    v1, v0, v1
    jr      $31
    sb      a1, 0(v1)
wr8_c:
    lui     v0, %hi(s9xa_setbyte)
    b       ccall
    addiu   v0, v0, %lo(s9xa_setbyte)

/* ---- S9xSetWord: a0 = address, a1 = word ----------------------------------- */
wr16:
    sltiu   at, a0, 0x2000              /* bank 0 low RAM (byte a + 1 follows in RAM) */
    beqz    at, wr16_g
    sw      $0, CPU_WaitAddress($28)
    beqz    LRB, wr16_g
    addu    v1, LRB, a0
    addu    CYC, CYC, LRS
    addu    CYC, CYC, LRS
    sb      a1, 0(v1)
    srl     at, a1, 8
    jr      $31
    sb      at, 1(v1)
wr16_g:
    srl     v1, a0, 12
    andi    v1, v1, 0xfff
    sll     at, v1, 2
    addu    at, at, MSP
    lw      v0, WMAP_OFF(at)
    addu    v1, v1, MSP
    sltiu   at, v0, MEM_MAP_LAST
    bnez    at, wr16_c
    lbu     at, 0(v1)
    sll     at, at, 1
    addu    CYC, CYC, at
    andi    v1, a0, 0xffff
    addu    v1, v0, v1
    sb      a1, 0(v1)
    srl     at, a1, 8
    jr      $31
    sb      at, 1(v1)
wr16_c:
    lui     v0, %hi(s9xa_setword)
    b       ccall
    addiu   v0, v0, %lo(s9xa_setword)

/* ---- S9xSetPCBase: a0 = address; sets PC, MemSpeed --------------------------- */
setpc:
    srl     v1, a0, 12
    andi    v1, v1, 0xfff
    sll     at, v1, 2
    addu    at, at, MSP
    lw      v0, MAP_OFF(at)
    sltiu   at, v0, MEM_MAP_LAST
    bnez    at, setpc_c
    addu    v1, v1, MSP
    lbu     MS, 0(v1)
    move    PCB, v0
    sw      v0, CPU_PCBase($28)
    sw      MS, CPU_MemSpeed($28)
    sll     at, MS, 1
    sw      at, CPU_MemSpeedx2($28)
    andi    at, a0, 0xffff
    jr      $31
    addu    PC, v0, at
setpc_c:
    lui     v0, %hi(s9xa_setpcbase)
    b       ccall
    addiu   v0, v0, %lo(s9xa_setpcbase)

/* ---- taken branch: a0 = Int8 (CPU.PC after the operand) ----------------------- */
taken:
    subu    at, PC, PCB
    addu    at, at, a0
    andi    at, at, 0xffff
    addu    PC, PCB, at
    lw      at, CPU_WaitAddress($28)
    bne     at, PC, next
    addiu   CYC, CYC, 6
shutdown:
    /* CPUShutdown (cpuops.cpp): Settings.Shutdown && CPU.PC == CPU.WaitAddress */
    COUNT   4
    LBUS    at, Settings+SET_Shutdown
    beqz    at, next
    lw      v0, CPU_WaitCounter($28)
    lw      v1, CPU_Flags($28)
    bnez    v0, 5f
    andi    v1, v1, FLAG_IRQNMI
    bnez    v1, 5f
    nop
    sw      $0, CPU_WaitAddress($28)
    lw      CYC, CPU_NextEvent($28)     /* CPU.Cycles = CPU.NextEvent */
    sw      CYC, CPU_Cycles($28)
    sw      PC, CPU_PC($28)
    sw      OPS, CPU_PCAtOpcodeStart($28)
    GP_C
    SPCSYNC                             /* the SPC700 up to this pass first */
    LBUS    at, IAPU+IAPU_APUExecuting
    beqz    at, 6f
    nop
    /* ICPU.CPUExecuting = FALSE; do APU_EXECUTE1 while (APU.Cycles < CPU.NextEvent),
       as one limit NextEvent - 1 with the first opcode untested */
    lui     at, %hi(ICPU+ICPU_CPUExecuting)
    sb      $0, %lo(ICPU+ICPU_CPUExecuting)(at)
    LWS     a0, CPU+CPU_NextEvent
    addiu   a0, a0, -1
    sw      a0, FR_SH($sp)
    addiu   a0, $sp, FR_SH
    addiu   a1, $sp, FR_SH + 4
    jal     s9xa_spc_sync
    li      a2, 1
    li      at, 1
    lui     v1, %hi(ICPU+ICPU_CPUExecuting)
    sb      at, %lo(ICPU+ICPU_CPUExecuting)(v1)
6:  GP_CPU
    lw      PC, CPU_PC($28)
    lw      CYC, CPU_Cycles($28)
    lw      OPS, CPU_PCAtOpcodeStart($28)
    RELOAD
    LIMIT
    b       next
    nop
5:  /* else if (CPU.WaitCounter >= 2) CPU.WaitCounter = 1; else CPU.WaitCounter-- */
    sltiu   at, v0, 2
    addiu   v0, v0, -1
    li      v1, 1
    movz    v0, v1, at
    b       next
    sw      v0, CPU_WaitCounter($28)

/* ============================================================================
 * opcode handlers; names h_OP (any mode), h_OP_M1 / _M0 (by the M flag),
 * h_OP_X1 / _X0 (by the X flag)
 * ========================================================================== */

/* ---- ORA, AND, EOR, ADC, LDA, CMP, SBC (cc = 01) --------------------------- */
    .macro  ALU_ALL hi1, hi2, op, kind8, kind16
    \kind8  h_\hi1\()1_M1, DPIX, \op
    \kind16 h_\hi1\()1_M0, DPIX, \op
    \kind8  h_\hi1\()3_M1, SR, \op
    \kind16 h_\hi1\()3_M0, SR, \op
    \kind8  h_\hi1\()5_M1, DP, \op
    \kind16 h_\hi1\()5_M0, DP, \op
    \kind8  h_\hi1\()7_M1, DPIL, \op
    \kind16 h_\hi1\()7_M0, DPIL, \op
    \kind8  h_\hi1\()D_M1, ABS, \op
    \kind16 h_\hi1\()D_M0, ABS, \op
    \kind8  h_\hi1\()F_M1, LONG, \op
    \kind16 h_\hi1\()F_M0, LONG, \op
    \kind8  h_\hi2\()1_M1, DPIY, \op
    \kind16 h_\hi2\()1_M0, DPIY, \op
    \kind8  h_\hi2\()2_M1, DPI, \op
    \kind16 h_\hi2\()2_M0, DPI, \op
    \kind8  h_\hi2\()3_M1, SRIY, \op
    \kind16 h_\hi2\()3_M0, SRIY, \op
    \kind8  h_\hi2\()5_M1, DPX, \op
    \kind16 h_\hi2\()5_M0, DPX, \op
    \kind8  h_\hi2\()7_M1, DPILY, \op
    \kind16 h_\hi2\()7_M0, DPILY, \op
    \kind8  h_\hi2\()9_M1, ABSY, \op
    \kind16 h_\hi2\()9_M0, ABSY, \op
    \kind8  h_\hi2\()D_M1, ABSX, \op
    \kind16 h_\hi2\()D_M0, ABSX, \op
    \kind8  h_\hi2\()F_M1, LONGX, \op
    \kind16 h_\hi2\()F_M0, LONGX, \op
    .endm

    ALU_ALL 0, 1, ORA, RD8, RD16
    ALU_ALL 2, 3, AND, RD8, RD16
    ALU_ALL 4, 5, EOR, RD8, RD16
    ALU_ALL 6, 7, ADC, RDD8, RDD16
    ALU_ALL A, B, LDA, RD8, RD16
    ALU_ALL C, D, CMP, RD8, RD16
    ALU_ALL E, F, SBC, RDD8, RDD16

/* STA (cc = 01, no immediate) */
    ST8     h_81_M1, DPIX, RA
    ST16    h_81_M0, DPIX, RA
    ST8     h_83_M1, SR, RA
    ST16    h_83_M0, SR, RA
    ST8     h_85_M1, DP, RA
    ST16    h_85_M0, DP, RA
    ST8     h_87_M1, DPIL, RA
    ST16    h_87_M0, DPIL, RA
    ST8     h_8D_M1, ABS, RA
    ST16    h_8D_M0, ABS, RA
    ST8     h_8F_M1, LONG, RA
    ST16    h_8F_M0, LONG, RA
    ST8     h_91_M1, DPIY, RA
    ST16    h_91_M0, DPIY, RA
    ST8     h_92_M1, DPI, RA
    ST16    h_92_M0, DPI, RA
    ST8     h_93_M1, SRIY, RA
    ST16    h_93_M0, SRIY, RA
    ST8     h_95_M1, DPX, RA
    ST16    h_95_M0, DPX, RA
    ST8     h_97_M1, DPILY, RA
    ST16    h_97_M0, DPILY, RA
    ST8     h_99_M1, ABSY, RA
    ST16    h_99_M0, ABSY, RA
    ST8     h_9D_M1, ABSX, RA
    ST16    h_9D_M0, ABSX, RA
    ST8     h_9F_M1, LONGX, RA
    ST16    h_9F_M0, LONGX, RA

/* STX, STY, STZ */
    ST8     h_86_X1, DP, RX
    ST16    h_86_X0, DP, RX
    ST8     h_96_X1, DPY, RX
    ST16    h_96_X0, DPY, RX
    ST8     h_8E_X1, ABS, RX
    ST16    h_8E_X0, ABS, RX
    ST8     h_84_X1, DP, RY
    ST16    h_84_X0, DP, RY
    ST8     h_94_X1, DPX, RY
    ST16    h_94_X0, DPX, RY
    ST8     h_8C_X1, ABS, RY
    ST16    h_8C_X0, ABS, RY
    ST8     h_64_M1, DP, $0
    ST16    h_64_M0, DP, $0
    ST8     h_74_M1, DPX, $0
    ST16    h_74_M0, DPX, $0
    ST8     h_9C_M1, ABS, $0
    ST16    h_9C_M0, ABS, $0
    ST8     h_9E_M1, ABSX, $0
    ST16    h_9E_M0, ABSX, $0

/* LDX, LDY, CPX, CPY, BIT (memory) */
    RD8     h_A6_X1, DP, LDX
    RD16    h_A6_X0, DP, LDX
    RD8     h_B6_X1, DPY, LDX
    RD16    h_B6_X0, DPY, LDX
    RD8     h_AE_X1, ABS, LDX
    RD16    h_AE_X0, ABS, LDX
    RD8     h_BE_X1, ABSY, LDX
    RD16    h_BE_X0, ABSY, LDX
    RD8     h_A4_X1, DP, LDY
    RD16    h_A4_X0, DP, LDY
    RD8     h_B4_X1, DPX, LDY
    RD16    h_B4_X0, DPX, LDY
    RD8     h_AC_X1, ABS, LDY
    RD16    h_AC_X0, ABS, LDY
    RD8     h_BC_X1, ABSX, LDY
    RD16    h_BC_X0, ABSX, LDY
    RD8     h_E4_X1, DP, CPX
    RD16    h_E4_X0, DP, CPX
    RD8     h_EC_X1, ABS, CPX
    RD16    h_EC_X0, ABS, CPX
    RD8     h_C4_X1, DP, CPY
    RD16    h_C4_X0, DP, CPY
    RD8     h_CC_X1, ABS, CPY
    RD16    h_CC_X0, ABS, CPY
    RD8     h_24_M1, DP, BIT
    RD16    h_24_M0, DP, BIT
    RD8     h_34_M1, DPX, BIT
    RD16    h_34_M0, DPX, BIT
    RD8     h_2C_M1, ABS, BIT
    RD16    h_2C_M0, ABS, BIT
    RD8     h_3C_M1, ABSX, BIT
    RD16    h_3C_M0, ABSX, BIT

/* read-modify-write on memory */
    .macro  RMW_ALL op, dp, dpx, abs, absx
    RMW8    h_\dp\()_M1, DP, \op
    RMW16   h_\dp\()_M0, DP, \op
    RMW8    h_\dpx\()_M1, DPX, \op
    RMW16   h_\dpx\()_M0, DPX, \op
    RMW8    h_\abs\()_M1, ABS, \op
    RMW16   h_\abs\()_M0, ABS, \op
    RMW8    h_\absx\()_M1, ABSX, \op
    RMW16   h_\absx\()_M0, ABSX, \op
    .endm
    RMW_ALL ASL, 06, 16, 0E, 1E
    RMW_ALL ROL, 26, 36, 2E, 3E
    RMW_ALL LSR, 46, 56, 4E, 5E
    RMW_ALL ROR, 66, 76, 6E, 7E
    RMW_ALL DEC, C6, D6, CE, DE
    RMW_ALL INC, E6, F6, EE, FE
    RMW8    h_04_M1, DP, TSB
    RMW16   h_04_M0, DP, TSB
    RMW8    h_0C_M1, ABS, TSB
    RMW16   h_0C_M0, ABS, TSB
    RMW8    h_14_M1, DP, TRB
    RMW16   h_14_M0, DP, TRB
    RMW8    h_1C_M1, ABS, TRB
    RMW16   h_1C_M0, ABS, TRB

/* ---- immediate operands read from *CPU.PC (cpuops.cpp) ----------------------- */
    .macro  IMM8_OP lbl, op
\lbl:
    FETCH8  v0
    OP_\op\()8
    b       next
    addu    CYC, CYC, MS
    .endm
    .macro  IMM16_OP lbl, op
\lbl:
    FETCH16 v0
    OP_\op\()16
    CYC1
    b       next
    addu    CYC, CYC, MS
    .endm
    IMM8_OP  h_09_M1, ORA
    IMM16_OP h_09_M0, ORA
    IMM8_OP  h_29_M1, AND
    IMM16_OP h_29_M0, AND
    IMM8_OP  h_49_M1, EOR
    IMM16_OP h_49_M0, EOR
    IMM8_OP  h_A9_M1, LDA
    IMM16_OP h_A9_M0, LDA
    IMM8_OP  h_C9_M1, CMP
    IMM16_OP h_C9_M0, CMP
    IMM8_OP  h_A2_X1, LDX
    IMM16_OP h_A2_X0, LDX
    IMM8_OP  h_A0_X1, LDY
    IMM16_OP h_A0_X0, LDY
    IMM8_OP  h_E0_X1, CPX
    IMM16_OP h_E0_X0, CPX
    IMM8_OP  h_C0_X1, CPY
    IMM16_OP h_C0_X0, CPY

h_89_M1:                                /* BIT #: _Zero = AL & imm */
    FETCH8  v0
    and     RZ, v0, RA
    b       next
    addu    CYC, CYC, MS
h_89_M0:
    FETCH16 v0
    and     RZ, v0, RA
    CYC1
    b       next
    addu    CYC, CYC, MS

/* ADC #, SBC #: Immediate8/16 read through S9xGetByte/S9xGetWord */
    .macro  IMMADDR                     /* a0 = ICPU.ShiftedPB + PC - PCBase */
    SHPB    a0
    addu    a0, a0, PC
    subu    a0, a0, PCB
    .endm
h_69_M1:
    DECCHK
    IMMADDR
    bal     rd8
    addiu   PC, PC, 1
    OP_ADC8
    b       next
    nop
h_69_M0:
    DECCHK
    IMMADDR
    bal     rd16
    addiu   PC, PC, 2
    OP_ADC16
    b       next
    nop
h_E9_M1:
    DECCHK
    IMMADDR
    bal     rd8
    addiu   PC, PC, 1
    OP_SBC8
    b       next
    nop
h_E9_M0:
    DECCHK
    IMMADDR
    bal     rd16
    addiu   PC, PC, 2
    OP_SBC16
    b       next
    nop

/* ---- accumulator shifts, INC A, DEC A -------------------------------------- */
h_0A_M1:                                /* A_ASL8 */
    addiu   CYC, CYC, 6
    andi    v0, RA, 0xff
    srl     RC, v0, 7
    sll     v0, v0, 1
    andi    v0, v0, 0xff
    SETLO   RA, v0
    move    RZ, v0
    b       next
    move    RN, v0
h_0A_M0:
    addiu   CYC, CYC, 6
    srl     RC, RA, 15
    sll     RA, RA, 1
    andi    RA, RA, 0xffff
    move    RZ, RA
    b       next
    srl     RN, RA, 8
h_4A_M1:                                /* A_LSR8 */
    addiu   CYC, CYC, 6
    andi    RC, RA, 1
    andi    v0, RA, 0xff
    srl     v0, v0, 1
    SETLO   RA, v0
    move    RZ, v0
    b       next
    move    RN, v0
h_4A_M0:
    addiu   CYC, CYC, 6
    andi    RC, RA, 1
    srl     RA, RA, 1
    move    RZ, RA
    b       next
    srl     RN, RA, 8
h_2A_M1:                                /* A_ROL8 */
    addiu   CYC, CYC, 6
    andi    v0, RA, 0xff
    sll     v0, v0, 1
    or      v0, v0, RC
    srl     RC, v0, 8
    andi    v0, v0, 0xff
    SETLO   RA, v0
    move    RZ, v0
    b       next
    move    RN, v0
h_2A_M0:
    addiu   CYC, CYC, 6
    sll     RA, RA, 1
    or      RA, RA, RC
    srl     RC, RA, 16
    andi    RA, RA, 0xffff
    move    RZ, RA
    b       next
    srl     RN, RA, 8
h_6A_M1:                                /* A_ROR8 */
    addiu   CYC, CYC, 6
    andi    v0, RA, 0xff
    sll     at, RC, 8
    or      v0, v0, at
    andi    RC, v0, 1
    srl     v0, v0, 1
    SETLO   RA, v0
    move    RZ, v0
    b       next
    move    RN, v0
h_6A_M0:
    addiu   CYC, CYC, 6
    sll     at, RC, 16
    or      RA, RA, at
    andi    RC, RA, 1
    srl     RA, RA, 1
    move    RZ, RA
    b       next
    srl     RN, RA, 8
h_1A_M1:                                /* A_INC8 */
    addiu   CYC, CYC, 6
    sw      $0, CPU_WaitAddress($28)
    addiu   v0, RA, 1
    andi    v0, v0, 0xff
    SETLO   RA, v0
    move    RZ, v0
    b       next
    move    RN, v0
h_1A_M0:
    addiu   CYC, CYC, 6
    sw      $0, CPU_WaitAddress($28)
    addiu   RA, RA, 1
    andi    RA, RA, 0xffff
    move    RZ, RA
    b       next
    srl     RN, RA, 8
h_3A_M1:                                /* A_DEC8 */
    addiu   CYC, CYC, 6
    sw      $0, CPU_WaitAddress($28)
    addiu   v0, RA, -1
    andi    v0, v0, 0xff
    SETLO   RA, v0
    move    RZ, v0
    b       next
    move    RN, v0
h_3A_M0:
    addiu   CYC, CYC, 6
    sw      $0, CPU_WaitAddress($28)
    addiu   RA, RA, -1
    andi    RA, RA, 0xffff
    move    RZ, RA
    b       next
    srl     RN, RA, 8

/* ---- INX, INY, DEX, DEY ---------------------------------------------------- */
    .macro  INCDEC8 lbl, r, d
\lbl:
    addiu   CYC, CYC, 6
    sw      $0, CPU_WaitAddress($28)
    addiu   v0, \r, \d
    andi    v0, v0, 0xff
    SETLO   \r, v0
    move    RZ, v0
    b       next
    move    RN, v0
    .endm
    .macro  INCDEC16 lbl, r, d
\lbl:
    addiu   CYC, CYC, 6
    sw      $0, CPU_WaitAddress($28)
    addiu   \r, \r, \d
    andi    \r, \r, 0xffff
    move    RZ, \r
    b       next
    srl     RN, \r, 8
    .endm
    INCDEC8  h_E8_X1, RX, 1
    INCDEC16 h_E8_X0, RX, 1
    INCDEC8  h_C8_X1, RY, 1
    INCDEC16 h_C8_X0, RY, 1
    INCDEC8  h_CA_X1, RX, -1
    INCDEC16 h_CA_X0, RX, -1
    INCDEC8  h_88_X1, RY, -1
    INCDEC16 h_88_X0, RY, -1

/* ---- transfers ------------------------------------------------------------- */
    .macro  TR8 lbl, dst, src           /* dst.l = src.l; SetZN8 */
\lbl:
    addiu   CYC, CYC, 6
    andi    v0, \src, 0xff
    SETLO   \dst, v0
    move    RZ, v0
    b       next
    move    RN, v0
    .endm
    .macro  TR16 lbl, dst, src          /* dst.W = src.W; SetZN16 */
\lbl:
    addiu   CYC, CYC, 6
    move    \dst, \src
    move    RZ, \dst
    b       next
    srl     RN, \dst, 8
    .endm
    TR8     h_AA_X1, RX, RA             /* TAX */
    TR16    h_AA_X0, RX, RA
    TR8     h_A8_X1, RY, RA             /* TAY */
    TR16    h_A8_X0, RY, RA
    TR8     h_8A_M1, RA, RX             /* TXA */
    TR16    h_8A_M0, RA, RX
    TR8     h_98_M1, RA, RY             /* TYA */
    TR16    h_98_M0, RA, RY
    TR8     h_9B_X1, RY, RX             /* TXY */
    TR16    h_9B_X0, RY, RX
    TR8     h_BB_X1, RX, RY             /* TYX */
    TR16    h_BB_X0, RX, RY
h_5B:                                   /* TCD */
    addiu   CYC, CYC, 6
    sh      RA, REG_D(REG)
    move    RZ, RA
    b       next
    srl     RN, RA, 8
h_7B:                                   /* TDC */
    addiu   CYC, CYC, 6
    lhu     RA, REG_D(REG)
    move    RZ, RA
    b       next
    srl     RN, RA, 8
h_3B:                                   /* TSC */
    addiu   CYC, CYC, 6
    lhu     RA, REG_S(REG)
    move    RZ, RA
    b       next
    srl     RN, RA, 8
h_BA_X1:                                /* TSX */
    addiu   CYC, CYC, 6
    lbu     v0, REG_S(REG)
    SETLO   RX, v0
    move    RZ, v0
    b       next
    move    RN, v0
h_BA_X0:
    addiu   CYC, CYC, 6
    lhu     RX, REG_S(REG)
    move    RZ, RX
    b       next
    srl     RN, RX, 8
h_1B:                                   /* TCS */
    addiu   CYC, CYC, 6
    lhu     at, REG_P(REG)
    andi    at, at, 0x100
    beqz    at, 1f
    move    v0, RA
    andi    v0, v0, 0xff
    ori     v0, v0, 0x100
1:  b       next
    sh      v0, REG_S(REG)
h_9A:                                   /* TXS */
    addiu   CYC, CYC, 6
    lhu     at, REG_P(REG)
    andi    at, at, 0x100
    beqz    at, 1f
    move    v0, RX
    andi    v0, v0, 0xff
    ori     v0, v0, 0x100
1:  b       next
    sh      v0, REG_S(REG)
h_EB:                                   /* XBA */
    srl     v0, RA, 8
    andi    at, RA, 0xff
    sll     at, at, 8
    or      RA, v0, at
    addiu   CYC, CYC, 12
    move    RZ, v0
    b       next
    move    RN, v0

/* ---- flags ----------------------------------------------------------------- */
h_18:                                   /* CLC */
    move    RC, $0
    b       next
    addiu   CYC, CYC, 6
h_38:                                   /* SEC */
    li      RC, 1
    b       next
    addiu   CYC, CYC, 6
h_B8:                                   /* CLV */
    SETV    $0
    b       next
    addiu   CYC, CYC, 6
h_D8:                                   /* CLD */
    lbu     at, REG_P(REG)
    andi    at, at, 0xf7
    sb      at, REG_P(REG)
    b       next
    addiu   CYC, CYC, 6
h_58:                                   /* CLI */
    lbu     at, REG_P(REG)
    andi    at, at, 0xfb
    sb      at, REG_P(REG)
    b       next
    addiu   CYC, CYC, 6
h_78:                                   /* SEI */
    lbu     at, REG_P(REG)
    ori     at, at, 4
    sb      at, REG_P(REG)
    b       next
    addiu   CYC, CYC, 6
h_EA:                                   /* NOP */
    b       next
    addiu   CYC, CYC, 6
h_42:                                   /* WDM */
    b       next
    nop

h_C2:                                   /* REP */
    lhu     at, REG_P(REG)
    andi    at, at, 0x100
    bnez    at, op_c                    /* emulation mode: the core's handler */
    nop
    FETCH8  a1
    nor     a3, a1, $0                  /* Work8 = ~imm */
    lbu     a2, REG_P(REG)
    and     a2, a2, a3
    sb      a2, REG_P(REG)
    and     RC, RC, a3
    LBUS    at, ICPU+ICPU_Overflow
    srl     v1, a3, 6
    and     at, at, v1
    SETV    at
    and     RN, RN, a3
    andi    at, a1, 2
    or      RZ, RZ, at
    CYC1
    b       modefix
    addiu   CYC, CYC, 6
h_E2:                                   /* SEP */
    lhu     at, REG_P(REG)
    andi    at, at, 0x100
    bnez    at, op_c
    nop
    FETCH8  a1
    lbu     a2, REG_P(REG)
    or      a2, a2, a1
    sb      a2, REG_P(REG)
    andi    at, a1, 1
    or      RC, RC, at
    LBUS    at, ICPU+ICPU_Overflow
    srl     v1, a1, 6
    andi    v1, v1, 1
    or      at, at, v1
    SETV    at
    or      RN, RN, a1
    andi    at, a1, 2
    movn    RZ, $0, at
    CYC1
    b       modefix
    addiu   CYC, CYC, 6
/* index registers 8 bits: XH = YH = 0; then S9xFixCycles */
modefix:
    lbu     at, REG_P(REG)
    andi    at, at, 0x10
    beqz    at, 1f
    nop
    andi    RX, RX, 0xff
    andi    RY, RY, 0xff
1:  bal     settab
    nop
    b       next
    nop

/* ---- pushes and pulls ------------------------------------------------------- */
h_48_M1:                                /* PHA */
    PUSHB   RA
    b       next
    addiu   CYC, CYC, 6
h_48_M0:
    PUSHW   RA
    b       next
    addiu   CYC, CYC, 6
h_DA_X1:                                /* PHX */
    PUSHB   RX
    b       next
    addiu   CYC, CYC, 6
h_DA_X0:
    PUSHW   RX
    b       next
    addiu   CYC, CYC, 6
h_5A_X1:                                /* PHY */
    PUSHB   RY
    b       next
    addiu   CYC, CYC, 6
h_5A_X0:
    PUSHW   RY
    b       next
    addiu   CYC, CYC, 6
h_8B:                                   /* PHB */
    lbu     a2, REG_DB(REG)
    PUSHB   a2
    b       next
    addiu   CYC, CYC, 6
h_4B:                                   /* PHK */
    lbu     a2, REG_PB(REG)
    PUSHB   a2
    b       next
    addiu   CYC, CYC, 6
h_0B:                                   /* PHD */
    lhu     a2, REG_D(REG)
    PUSHW   a2
    b       next
    addiu   CYC, CYC, 6
h_08:                                   /* PHP: S9xPackStatus, push P.l */
    lbu     a2, REG_P(REG)
    andi    a2, a2, 0x3c
    or      a2, a2, RC
    sltiu   at, RZ, 1
    sll     at, at, 1
    or      a2, a2, at
    andi    at, RN, 0x80
    or      a2, a2, at
    LBUS    at, ICPU+ICPU_Overflow
    sll     at, at, 6
    or      a2, a2, at
    sb      a2, REG_P(REG)
    PUSHB   a2
    b       next
    addiu   CYC, CYC, 6
h_68_M1:                                /* PLA */
    addiu   CYC, CYC, 12
    PULLB
    OP_LDA8
    b       next
    nop
h_68_M0:
    addiu   CYC, CYC, 12
    PULLW
    OP_LDA16
    b       next
    nop
h_FA_X1:                                /* PLX */
    addiu   CYC, CYC, 12
    PULLB
    OP_LDX8
    b       next
    nop
h_FA_X0:
    addiu   CYC, CYC, 12
    PULLW
    OP_LDX16
    b       next
    nop
h_7A_X1:                                /* PLY */
    addiu   CYC, CYC, 12
    PULLB
    OP_LDY8
    b       next
    nop
h_7A_X0:
    addiu   CYC, CYC, 12
    PULLW
    OP_LDY16
    b       next
    nop
h_AB:                                   /* PLB */
    addiu   CYC, CYC, 12
    PULLB
    sb      v0, REG_DB(REG)
    ZN8     v0
    sll     DBR, v0, 16
    lui     at, %hi(ICPU+ICPU_ShiftedDB)
    b       next
    sw      DBR, %lo(ICPU+ICPU_ShiftedDB)(at)
h_2B:                                   /* PLD */
    addiu   CYC, CYC, 12
    PULLW
    sh      v0, REG_D(REG)
    move    RZ, v0
    b       next
    srl     RN, v0, 8
h_28:                                   /* PLP: S9xUnpackStatus, then as OpC2 */
    addiu   CYC, CYC, 12
    PULLB
    sb      v0, REG_P(REG)
    andi    RZ, v0, 2
    xori    RZ, RZ, 2                   /* _Zero: nonzero when Z clear */
    andi    RN, v0, 0x80
    andi    RC, v0, 1
    srl     at, v0, 6
    andi    at, at, 1
    SETV    at
    b       modefix
    nop

h_F4:                                   /* PEA: Absolute, push OpAddress */
    AM_ABS
    andi    a2, a0, 0xffff
    PUSHW   a2
    b       next
    nop
h_D4:                                   /* PEI: DirectIndirect, push OpAddress */
    AM_DPI
    andi    a2, a0, 0xffff
    PUSHW   a2
    b       next
    nop
h_62:                                   /* PER: RelativeLong, push OpAddress */
    FETCH16 a2
    CYC2
    addiu   CYC, CYC, 6
    subu    at, PC, PCB
    addu    a2, a2, at
    andi    a2, a2, 0xffff
    PUSHW   a2
    b       next
    nop

/* ---- branches --------------------------------------------------------------- */
    BRANCH  h_90, bnez, RC              /* BCC: taken when C clear */
    BRANCH  h_B0, beqz, RC              /* BCS */
    BRANCH  h_F0, bnez, RZ              /* BEQ: taken when _Zero == 0 */
    BRANCH  h_D0, beqz, RZ              /* BNE */
h_30:                                   /* BMI */
    lb      a0, 0(PC)
    addiu   PC, PC, 1
    andi    at, RN, 0x80
    beqz    at, next
    addu    CYC, CYC, MS
    TAKEN
h_10:                                   /* BPL */
    lb      a0, 0(PC)
    addiu   PC, PC, 1
    andi    at, RN, 0x80
    bnez    at, next
    addu    CYC, CYC, MS
    TAKEN
h_50:                                   /* BVC */
    lb      a0, 0(PC)
    addiu   PC, PC, 1
    LBUS    at, ICPU+ICPU_Overflow
    bnez    at, next
    addu    CYC, CYC, MS
    TAKEN
h_70:                                   /* BVS */
    lb      a0, 0(PC)
    addiu   PC, PC, 1
    LBUS    at, ICPU+ICPU_Overflow
    beqz    at, next
    addu    CYC, CYC, MS
    TAKEN
h_80:                                   /* BRA */
    lb      a0, 0(PC)
    addiu   PC, PC, 1
    b       taken
    addu    CYC, CYC, MS
h_82:                                   /* BRL: RelativeLong, S9xSetPCBase */
    FETCH16 a2
    CYC2
    addiu   CYC, CYC, 6
    subu    at, PC, PCB
    addu    a2, a2, at
    andi    a2, a2, 0xffff
    SHPB    a0
    bal     setpc
    addu    a0, a0, a2
    b       next
    nop

/* ---- jumps, calls, returns ---------------------------------------------------- */
h_4C:                                   /* JMP abs */
    FETCH16 a2
    CYC2
    SHPB    a0
    bal     setpc
    addu    a0, a0, a2
    b       next
    nop
h_5C:                                   /* JML long */
    FETCH24 a0
    CYC3
    srl     at, a0, 16
    sb      at, REG_PB(REG)
    lui     v1, 0xff
    and     v1, a0, v1
    lui     at, %hi(ICPU+ICPU_ShiftedPB)
    bal     setpc
    sw      v1, %lo(ICPU+ICPU_ShiftedPB)(at)
    b       next
    nop
h_DC:                                   /* JML [abs]: AbsoluteIndirectLong */
    FETCH16 a0
    CYC2
    bal     rd16
    nop
    move    a2, v0
    bal     rd8
    addiu   a0, a0, 2
    sll     v0, v0, 16
    or      a0, a2, v0
    srl     at, a0, 16
    sb      at, REG_PB(REG)
    lui     v1, 0xff
    and     v1, a0, v1
    lui     at, %hi(ICPU+ICPU_ShiftedPB)
    bal     setpc
    sw      v1, %lo(ICPU+ICPU_ShiftedPB)(at)
    b       next
    addiu   CYC, CYC, 12
h_6C:                                   /* JMP (abs): AbsoluteIndirect */
    FETCH16 a0
    CYC2
    bal     rd16
    nop
    SHPB    a0
    bal     setpc
    addu    a0, a0, v0
    b       next
    nop
h_7C:                                   /* JMP (abs,X): AbsoluteIndexedIndirect */
    FETCH16 a0
    addu    a0, a0, RX
    andi    a0, a0, 0xffff
    CYC2
    SHPB    a2
    bal     rd16
    addu    a0, a0, a2
    bal     setpc
    addu    a0, a2, v0
    b       next
    addiu   CYC, CYC, 6
h_20:                                   /* JSR abs */
    FETCH16 a2
    CYC2
    subu    a3, PC, PCB
    addiu   a3, a3, -1
    PUSHW   a3
    SHPB    a0
    bal     setpc
    addu    a0, a0, a2
    b       next
    addiu   CYC, CYC, 6
h_FC:                                   /* JSR (abs,X) */
    FETCH16 a0
    addu    a0, a0, RX
    andi    a0, a0, 0xffff
    CYC2
    SHPB    a2
    bal     rd16
    addu    a0, a0, a2
    addu    a2, a2, v0                  /* ShiftedPB + OpAddress */
    subu    a3, PC, PCB
    addiu   a3, a3, -1
    PUSHW   a3
    bal     setpc
    move    a0, a2
    b       next
    addiu   CYC, CYC, 6
h_22:                                   /* JSL long */
    FETCH24 a2
    CYC3
    lbu     a3, REG_PB(REG)
    PUSHB   a3
    subu    a3, PC, PCB
    addiu   a3, a3, -1
    PUSHW   a3
    srl     at, a2, 16
    sb      at, REG_PB(REG)
    lui     v1, 0xff
    and     v1, a2, v1
    lui     at, %hi(ICPU+ICPU_ShiftedPB)
    sw      v1, %lo(ICPU+ICPU_ShiftedPB)(at)
    bal     setpc
    move    a0, a2
    b       next
    nop
h_60:                                   /* RTS */
    PULLW
    addiu   v0, v0, 1
    andi    v0, v0, 0xffff
    SHPB    a0
    bal     setpc
    addu    a0, a0, v0
    b       next
    addiu   CYC, CYC, 18
h_6B:                                   /* RTL */
    PULLW
    move    a2, v0
    PULLB
    sb      v0, REG_PB(REG)
    sll     v0, v0, 16
    lui     at, %hi(ICPU+ICPU_ShiftedPB)
    sw      v0, %lo(ICPU+ICPU_ShiftedPB)(at)
    addiu   a2, a2, 1
    andi    a2, a2, 0xffff
    bal     setpc
    addu    a0, v0, a2
    b       next
    addiu   CYC, CYC, 12

/* ---- block moves (Op54X1 ... Op44X0) ------------------------------------------ */
    .macro  BLKMOVE lbl, d, wide
\lbl:
    CYC2
    addiu   CYC, CYC, 12
    FETCH8  v0
    sb      v0, REG_DB(REG)
    sll     DBR, v0, 16
    lui     at, %hi(ICPU+ICPU_ShiftedDB)
    sw      DBR, %lo(ICPU+ICPU_ShiftedDB)(at)
    move    a2, DBR
    FETCH8  a0
    sll     a0, a0, 16
    bal     rd8
    addu    a0, a0, RX
    move    a1, v0
    bal     wr8
    addu    a0, a2, RY
    .if \wide
    addiu   RX, RX, \d
    andi    RX, RX, 0xffff
    addiu   RY, RY, \d
    andi    RY, RY, 0xffff
    .else
    addiu   v0, RX, \d
    andi    v0, v0, 0xff
    SETLO   RX, v0
    addiu   v0, RY, \d
    andi    v0, v0, 0xff
    SETLO   RY, v0
    .endif
    addiu   RA, RA, -1
    andi    RA, RA, 0xffff
    xori    at, RA, 0xffff
    beqz    at, next
    nop
    b       next
    addiu   PC, PC, -3
    .endm
    BLKMOVE h_54_X1, 1, 0               /* MVN */
    BLKMOVE h_54_X0, 1, 1
    BLKMOVE h_44_X1, -1, 0              /* MVP */
    BLKMOVE h_44_X0, -1, 1

    .globl  s9xa_text_end
s9xa_text_end:

/* ============================================================================
 * jump tables: s9xa_tables + mode x 1024, mode = M << 1 | X; an opcode
 * without a handler for the mode runs the core's handler (op_c)
 * ========================================================================== */
    .macro  ENT op, m, x
    .ifdef  h_\op\()_M\m
    .word   h_\op\()_M\m
    .else
    .ifdef  h_\op\()_X\x
    .word   h_\op\()_X\x
    .else
    .ifdef  h_\op
    .word   h_\op
    .else
    .word   op_c
    .endif
    .endif
    .endif
    .endm
    .macro  TABLE m, x
    .irp    hi, 0,1,2,3,4,5,6,7,8,9,A,B,C,D,E,F
    .irp    lo, 0,1,2,3,4,5,6,7,8,9,A,B,C,D,E,F
    ENT     \hi\lo, \m, \x
    .endr
    .endr
    .endm

    .bss
    .align  4
    .globl  s9xa_ring
s9xa_ring:
    .space  4096

    .data
    .align  4
    .globl  s9xa_tables
s9xa_tables:
    TABLE   0, 0
    TABLE   0, 1
    TABLE   1, 0
    TABLE   1, 1
s9xa_ctab:                              /* the core's tables in the same order */
    .word   S9xOpcodesM0X0, S9xOpcodesM0X1, S9xOpcodesM1X0, S9xOpcodesM1X1
