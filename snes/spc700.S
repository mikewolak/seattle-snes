/* spc700.S - SPC700 instruction loop of the Snes9x 1.39 core in R5000
 * assembler (MIPS IV, o32, little-endian).
 * EPROM Foundry Inc. / Mike Wolak, project Blitz99.
 *
 * s9xa_spc_sync (begin, end, first) runs the loop APU_EXECUTE of
 * spc700.h (SPC700_C, SPC700_SHUTDOWN) once for each limit in the list
 * begin..end, as S9xMainLoop runs it once before each 65C816 opcode: if
 * IAPU.APUExecuting, then APU.Cycles += S9xAPUCycles [opcode] and the
 * opcode while APU.Cycles <= the limit. The list holds the CPU.Cycles of
 * the opcode starts since the last call (cpu65.S); the limits rise. While
 * IAPU.APUExecuting stays set, running against each limit in turn equals
 * running against the last one, so the loop runs to the last limit. Only
 * an SPC700 opcode clears APUExecuting between two calls (APUShutdown in a
 * taken branch, SLEEP, STOP in the core's functions); the core then
 * finishes the limit that opcode ran under (the first limit at or above
 * APU.Cycles at the opcode's start) and runs nothing for the later ones,
 * and so does spc_stop here. With first != 0 the single limit runs its
 * first opcode without the test (the do-while loop of CPUShutdown). The
 * opcodes are those of spc700.cpp step for step, with the memory functions
 * of apumem.h (S9xAPUGetByteZ, S9xAPUSetByteZ, S9xAPUGetByte,
 * S9xAPUSetByte): the same reads and writes in the same order, the same
 * extra cycles of taken branches (IAPU.TwoCycles), the same
 * IAPU.WaitAddress1/2, IAPU.WaitCounter and APUShutdown updates. DSP
 * register reads and writes (0xF3) and control writes (0xF1) call
 * S9xGetAPUDSP, S9xSetAPUDSP and S9xSetAPUControl (apu.cpp) with the
 * SPC700 state written back first. Opcodes without a handler here
 * (spc_op_c) run the core's function of S9xApuOpcodes the same way.
 * The core's scratch variables of spc700.cpp (IAPU.Address, IAPU.Bit,
 * Work8, Work16, W1, Int16) are not written; no code reads them between
 * opcodes.
 *
 * Registers inside the loop (all caller-saved; the caller's s0-s8 are not
 * used):
 *   t0  IAPU.PC (host pointer)        t1  APURegisters.YA.B.A
 *   t2  APURegisters.X                t3  APURegisters.YA.B.Y
 *   t4  APURegisters.S                t5  IAPU._Zero (N in bit 7, Z when 0)
 *   t6  IAPU._Carry (0 or 1)          t7  IAPU.DirectPage
 *   t8  APU.Cycles                    t9  the limit
 *   a3  IAPU.RAM
 * APURegisters.P and IAPU._Overflow stay in memory. gp is not used; the
 * caller sets it to _gp for the C functions called here.
 */
#include "s9x_offs.h"

#define SPC   $8
#define SA    $9
#define SX    $10
#define SY    $11
#define SS    $12
#define SZ    $13
#define SC    $14
#define SDP   $15
#define ACY   $24
#define ALIM  $25
#define SRAM  $7
#define at    $1
#define v0    $2
#define v1    $3
#define a0    $4
#define a1    $5
#define a2    $6

    .set    noreorder
    .set    noat

    .macro  LWS r, sym
    lui     \r, %hi(\sym)
    lw      \r, %lo(\sym)(\r)
    .endm
    .macro  LBUS r, sym
    lui     \r, %hi(\sym)
    lbu     \r, %lo(\sym)(\r)
    .endm

/* ---- SPC700 state to the core's structures / back; use at, v1 only -------- */
    .macro  SPC_OUT
    lui     at, %hi(IAPU)
    addiu   at, at, %lo(IAPU)
    sw      SPC, IAPU_PC(at)
    sb      SZ, IAPU_Zero(at)
    sb      SC, IAPU_Carry(at)
    lui     v1, %hi(APURegisters)
    addiu   v1, v1, %lo(APURegisters)
    sb      SA, AREG_A(v1)
    sb      SY, AREG_Y(v1)
    sb      SX, AREG_X(v1)
    sb      SS, AREG_S(v1)
    lui     at, %hi(APU+APU_Cycles)
    sw      ACY, %lo(APU+APU_Cycles)(at)
    .endm
    .macro  SPC_IN
    lui     at, %hi(IAPU)
    addiu   at, at, %lo(IAPU)
    lw      SPC, IAPU_PC(at)
    lw      SRAM, IAPU_RAM(at)
    lw      SDP, IAPU_DirectPage(at)
    lbu     SZ, IAPU_Zero(at)
    lbu     SC, IAPU_Carry(at)
    lui     v1, %hi(APURegisters)
    addiu   v1, v1, %lo(APURegisters)
    lbu     SA, AREG_A(v1)
    lbu     SY, AREG_Y(v1)
    lbu     SX, AREG_X(v1)
    lbu     SS, AREG_S(v1)
    LWS     ACY, APU+APU_Cycles
    .endm

/* ---- next opcode after PC += n ------------------------------------------------ */
    .macro  SNEXT n
    b       spc_next
    addiu   SPC, SPC, \n
    .endm

/* ---- operands ----------------------------------------------------------------- */
    .macro  OP1 r
    lbu     \r, 1(SPC)
    .endm
    .macro  OP2 r
    lbu     \r, 2(SPC)
    .endm
    .macro  ABSA r                      /* OP1 + (OP2 << 8) */
    lbu     \r, 1(SPC)
    lbu     at, 2(SPC)
    sll     at, at, 8
    or      \r, \r, at
    .endm
    .macro  DPXIND                      /* a0 = DP[(OP1 + X) & 0xff] + (DP[(OP1 + X + 1) & 0xff] << 8) */
    lbu     a0, 1(SPC)
    addu    a0, a0, SX
    addiu   v1, a0, 1
    andi    a0, a0, 0xff
    andi    v1, v1, 0xff
    addu    a0, SDP, a0
    addu    v1, SDP, v1
    lbu     a0, 0(a0)
    lbu     v1, 0(v1)
    sll     v1, v1, 8
    or      a0, a0, v1
    .endm
    .macro  DPINDY                      /* a0 = DP[OP1] + (DP[OP1 + 1] << 8) + Y */
    lbu     a0, 1(SPC)
    addu    v1, SDP, a0
    lbu     a0, 0(v1)
    lbu     v1, 1(v1)
    sll     v1, v1, 8
    or      a0, a0, v1
    addu    a0, a0, SY
    .endm

/* ---- flags -------------------------------------------------------------------- */
    .macro  SETV r                      /* IAPU._Overflow = r; uses v1 */
    lui     v1, %hi(IAPU+IAPU_Overflow)
    sb      \r, %lo(IAPU+IAPU_Overflow)(v1)
    .endm
    .macro  CLRH                        /* APURegisters.P &= ~HalfCarry; uses at, v1 */
    lui     v1, %hi(APURegisters+AREG_P)
    lbu     at, %lo(APURegisters+AREG_P)(v1)
    andi    at, at, 0xf7
    sb      at, %lo(APURegisters+AREG_P)(v1)
    .endm

/* ---- operations: r = r op v, flags as spc700.cpp; use at, v1 ----------------- */
    .macro  SOP_OR r, v
    or      \r, \r, \v
    move    SZ, \r
    .endm
    .macro  SOP_AND r, v
    and     \r, \r, \v
    move    SZ, \r
    .endm
    .macro  SOP_EOR r, v
    xor     \r, \r, \v
    move    SZ, \r
    .endm
    .macro  SOP_CMP r, v                /* CMP: r unchanged */
    sltu    SC, \r, \v
    xori    SC, SC, 1
    subu    SZ, \r, \v
    andi    SZ, SZ, 0xff
    .endm
    .macro  SOP_ADC r, v
    CLRH
    addu    at, \r, \v
    addu    at, at, SC
    srl     SC, at, 8
    andi    at, at, 0xff
    xor     v1, \r, \v
    nor     v1, v1, $0
    move    \r, at
    xor     at, \v, at
    and     v1, v1, at
    srl     v1, v1, 7
    andi    at, v1, 1
    SETV    at
    move    SZ, \r
    .endm
    .macro  SOP_SBC r, v
    CLRH
    subu    at, \r, \v
    addu    at, at, SC
    addiu   at, at, -1                  /* Int16 */
    slt     SC, at, $0
    xori    SC, SC, 1
    andi    at, at, 0xff
    xor     v1, \r, \v
    xor     \r, \r, at
    and     v1, v1, \r                  /* (r ^ v) & (r ^ result) & 0x80 */
    srl     v1, v1, 7
    andi    v1, v1, 1
    move    \r, at
    lui     at, %hi(IAPU+IAPU_Overflow)
    sb      v1, %lo(IAPU+IAPU_Overflow)(at)
    move    SZ, \r
    .endm

/* ---- memory functions of apumem.h -------------------------------------------- */

/* ---- loop --------------------------------------------------------------------- */
    .text
    .align  4

/* void s9xa_spc_sync (const int32 *begin, const int32 *end, int first) */
    .globl  s9xa_spc_sync
    .ent    s9xa_spc_sync
s9xa_spc_sync:
    beq     a0, a1, 9f                  /* empty list */
    nop
    bnez    a2, 8f
    lui     at, %hi(IAPU+IAPU_APUExecuting)
    lbu     at, %lo(IAPU+IAPU_APUExecuting)(at)
    lui     v0, %hi(APU+APU_Cycles)
    lw      v0, %lo(APU+APU_Cycles)(v0)
    beqz    at, 9f                      /* SPC700 stopped: nothing runs */
    lw      v1, -4(a1)
    slt     at, v1, v0
    bnez    at, 9f                      /* APU.Cycles above the last limit: nothing runs */
    nop
8:  addiu   $sp, $sp, -32
    sw      $31, 28($sp)
    sw      a1, 20($sp)
#ifdef S9XA_HIST
    lui     at, %hi(s9xa_cnt+20)
    lw      v0, %lo(s9xa_cnt+20)(at)
    addiu   v0, v0, 1
    sw      v0, %lo(s9xa_cnt+20)(at)
#endif
    sw      a0, 16($sp)
    SPC_IN
    bnez    a2, spc_go
    lw      ALIM, 0(a0)                 /* first: the single limit */
    LBUS    at, IAPU+IAPU_APUExecuting
    beqz    at, spc_exit
    nop
    lw      ALIM, -4(a1)                /* the last limit */
spc_next:
    slt     at, ALIM, ACY               /* APU.Cycles > limit: done */
    bnez    at, spc_exit
spc_go:
    lbu     v0, 0(SPC)
    sll     v1, v0, 2
#ifdef S9XA_HIST
    lui     at, %hi(s9xa_spch)
    addu    at, at, v1
    lw      a0, %lo(s9xa_spch)(at)
    addiu   a0, a0, 1
    sw      a0, %lo(s9xa_spch)(at)
    lui     at, %hi(s9xa_cnt+12)
    lw      a0, %lo(s9xa_cnt+12)(at)
    addiu   a0, a0, 1
    sw      a0, %lo(s9xa_cnt+12)(at)
#endif
    sw      ACY, 24($sp)                /* APU.Cycles at the opcode's start */
    lui     a0, %hi(S9xAPUCycles)
    addu    a0, a0, v1
    lw      a0, %lo(S9xAPUCycles)(a0)
    lui     a1, %hi(s9xa_spc_tables)
    addu    a1, a1, v1
    lw      a1, %lo(s9xa_spc_tables)(a1)
    jr      a1
    addu    ACY, ACY, a0                /* APU.Cycles += S9xAPUCycles [opcode] */
spc_exit:
    SPC_OUT
    lw      $31, 28($sp)
    addiu   $sp, $sp, 32
9:  jr      $31
    nop
    .end    s9xa_spc_sync

/* the core's function for this opcode (v0 = opcode) */
    .globl  s9xa_spc_op_c
s9xa_spc_op_c:
spc_op_c:
    SPC_OUT
    sll     v0, v0, 2
    lui     at, %hi(S9xApuOpcodes)
    addu    at, at, v0
    lw      at, %lo(S9xApuOpcodes)(at)
    jalr    at
    nop
    SPC_IN
    LBUS    at, IAPU+IAPU_APUExecuting  /* SLEEP, STOP */
    bnez    at, spc_next
    nop
spc_stop:
    /* APUExecuting cleared by this opcode: finish the first limit at or
       above its start cycle, nothing after it */
    lw      a0, 16($sp)
    lw      a1, 20($sp)
    lw      v0, 24($sp)
1:  lw      ALIM, 0(a0)
    addiu   a0, a0, 4
    slt     at, ALIM, v0
    beqz    at, spc_next
    nop
    bne     a0, a1, 1b
    nop
    b       spc_next                    /* none: the last limit */
    nop

/* C function v0 (S9xGetAPUDSP, S9xSetAPUDSP, S9xSetAPUControl) with the
 * argument in a1; returns v0; preserves a0-a2 */
spc_c:
    addiu   $sp, $sp, -32
    sw      $31, 28($sp)
    sw      a0, 16($sp)
    sw      a1, 20($sp)
    sw      a2, 24($sp)
    SPC_OUT
    jalr    v0
    move    a0, a1
    SPC_IN
    lw      $31, 28($sp)
    lw      a0, 16($sp)
    lw      a1, 20($sp)
    lw      a2, 24($sp)
    jr      $31
    addiu   $sp, $sp, 32

/* S9xAPUGetByteZ: a0 = address 0-0xff; returns v0; uses v1, at */
zrd:
    sltiu   at, a0, 0xf0
    bnez    at, 1f
    addu    v1, SDP, a0
    beq     SDP, SRAM, io_rd
    nop
1:  jr      $31
    lbu     v0, 0(v1)

/* S9xAPUGetByte: a0 = address (masked to 16 bits here) */
ard:
    andi    a0, a0, 0xffff
    addiu   at, a0, -0xf0
    sltiu   at, at, 0x10
    bnez    at, io_rd
    addu    v1, SRAM, a0
    jr      $31
    lbu     v0, 0(v1)

/* registers 0xF0-0xFF read: a0 = address */
io_rd:
    addiu   at, a0, -0xf4
    sltiu   at, at, 4
    bnez    at, 2f                      /* 0xF4-0xF7: ports */
    addiu   at, a0, -0xf3
    beqz    at, 3f                      /* 0xF3: DSP data */
    sltiu   at, a0, 0xfd
    bnez    at, 4f                      /* other registers: RAM */
    addu    v1, SRAM, a0
    lui     at, %hi(IAPU)               /* 0xFD-0xFF: counters, cleared by the read */
    addiu   at, at, %lo(IAPU)
    lw      v0, IAPU_WaitAddress1(at)
    sw      SPC, IAPU_WaitAddress1(at)
    sw      v0, IAPU_WaitAddress2(at)
    lbu     v0, 0(v1)
    jr      $31
    sb      $0, 0(v1)
2:  lui     at, %hi(IAPU)
    addiu   at, at, %lo(IAPU)
    lw      v0, IAPU_WaitAddress1(at)
    sw      SPC, IAPU_WaitAddress1(at)
    sw      v0, IAPU_WaitAddress2(at)
    addu    v1, SRAM, a0
    jr      $31
    lbu     v0, 0(v1)
3:  lui     v0, %hi(S9xGetAPUDSP)
    b       spc_c
    addiu   v0, v0, %lo(S9xGetAPUDSP)
4:  jr      $31
    lbu     v0, 0(v1)

/* S9xAPUSetByteZ: a0 = address 0-0xff, a1 = byte; uses v0, v1, at */
zwr:
    sltiu   at, a0, 0xf0
    bnez    at, 1f
    addu    v1, SDP, a0
    beq     SDP, SRAM, io_wr
    nop
1:  jr      $31
    sb      a1, 0(v1)

/* S9xAPUSetByte: a0 = address (masked to 16 bits here), a1 = byte */
awr:
    andi    a0, a0, 0xffff
    addiu   at, a0, -0xf0
    sltiu   at, at, 0x10
    bnez    at, io_wr
    srl     at, a0, 6
    xori    at, at, 0x3ff               /* 0xFFC0-0xFFFF: at = 0 */
    beqz    at, 1f
    addu    v1, SRAM, a0
    jr      $31
    sb      a1, 0(v1)
1:  andi    v0, a0, 0x3f                /* APU.ExtraRAM; RAM too unless the IPL ROM shows */
    lui     at, %hi(APU+APU_ExtraRAM)
    addu    at, at, v0
    sb      a1, %lo(APU+APU_ExtraRAM)(at)
    LBUS    at, APU+APU_ShowROM
    bnez    at, 2f
    nop
    sb      a1, 0(v1)
2:  jr      $31
    nop

/* registers 0xF0-0xFF written: a0 = address, a1 = byte */
io_wr:
    addiu   at, a0, -0xf3
    beqz    at, 3f                      /* 0xF3: DSP data */
    addiu   at, a0, -0xf4
    sltiu   at, at, 4
    bnez    at, 2f                      /* 0xF4-0xF7: APU.OutPorts */
    addiu   at, a0, -0xf1
    beqz    at, 5f                      /* 0xF1: control */
    sltiu   at, a0, 0xfd
    beqz    at, 9f                      /* 0xFD-0xFF: not written */
    addu    v1, SRAM, a0
    sb      a1, 0(v1)
    sltiu   at, a0, 0xfa
    bnez    at, 9f
    li      v0, 0x100                   /* 0xFA-0xFC: APU.TimerTarget = byte, 0 as 0x100 */
    movn    v0, a1, a1
    addiu   v1, a0, -0xfa
    sll     v1, v1, 1
    lui     at, %hi(APU+APU_TimerTarget)
    addu    at, at, v1
    sh      v0, %lo(APU+APU_TimerTarget)(at)
9:  jr      $31
    nop
2:  addiu   v1, a0, -0xf4
    lui     at, %hi(APU+APU_OutPorts)
    addu    at, at, v1
    jr      $31
    sb      a1, %lo(APU+APU_OutPorts)(at)
3:  lui     v0, %hi(S9xSetAPUDSP)
    b       spc_c
    addiu   v0, v0, %lo(S9xSetAPUDSP)
5:  lui     v0, %hi(S9xSetAPUControl)
    b       spc_c
    addiu   v0, v0, %lo(S9xSetAPUControl)

/* ---- branch targets ----------------------------------------------------------- */
/* taken: PC = RAM + (uint16) (PC + n - RAM + Int8); APU.Cycles += IAPU.TwoCycles
 * (a0 = Int8, a2 = n); spc_taken_s then APUShutdown */
spc_taken:
    subu    v1, SPC, SRAM
    addu    v1, v1, a2
    addu    v1, v1, a0
    andi    v1, v1, 0xffff
    addu    SPC, SRAM, v1
    LWS     at, IAPU+IAPU_TwoCycles
    b       spc_next
    addu    ACY, ACY, at
spc_taken_s:
    subu    v1, SPC, SRAM
    addu    v1, v1, a2
    addu    v1, v1, a0
    andi    v1, v1, 0xffff
    addu    SPC, SRAM, v1
    LWS     at, IAPU+IAPU_TwoCycles
    addu    ACY, ACY, at
    /* APUShutdown: Settings.Shutdown && (PC == WaitAddress1 || PC == WaitAddress2) */
    LBUS    at, Settings+SET_Shutdown
    beqz    at, spc_next
    lui     a2, %hi(IAPU)
    addiu   a2, a2, %lo(IAPU)
    lw      v0, IAPU_WaitAddress1(a2)
    lw      v1, IAPU_WaitAddress2(a2)
    beq     v0, SPC, 1f
    nop
    bne     v1, SPC, spc_next
    nop
1:  lw      v0, IAPU_WaitCounter(a2)
    bnez    v0, 3f
    nop
    LBUS    at, ICPU+ICPU_CPUExecuting
    bnez    at, 2f
    nop
    LWS     ACY, CPU+CPU_NextEvent      /* APU.Cycles = CPU.Cycles = CPU.NextEvent */
    lui     at, %hi(CPU+CPU_Cycles)
    b       spc_next
    sw      ACY, %lo(CPU+CPU_Cycles)(at)
2:  b       spc_stop                    /* IAPU.APUExecuting = FALSE */
    sb      $0, IAPU_APUExecuting(a2)
3:  sltiu   at, v0, 2                   /* WaitCounter >= 2: 1, else WaitCounter - 1 */
    addiu   v0, v0, -1
    li      v1, 1
    movz    v0, v1, at
    b       spc_next
    sw      v0, IAPU_WaitCounter(a2)

    .macro  WAITCNT                     /* IAPU.WaitCounter++; uses at, v1 */
    lui     v1, %hi(IAPU+IAPU_WaitCounter)
    lw      at, %lo(IAPU+IAPU_WaitCounter)(v1)
    addiu   at, at, 1
    sw      at, %lo(IAPU+IAPU_WaitCounter)(v1)
    .endm

/* ============================================================================
 * opcode handlers s_XX
 * ========================================================================== */

/* ---- OR, AND, EOR, CMP, ADC, SBC families (hi = 0, 2, 4, 6, 8, A) ----------- */
    .macro  SFAM op, h, h1, cmp
s_\h\()4:                               /* A, dp */
    OP1     a0
    bal     zrd
    nop
    SOP_\op SA, v0
    SNEXT   2
s_\h\()5:                               /* A, abs */
    ABSA    a0
    bal     ard
    nop
    SOP_\op SA, v0
    SNEXT   3
s_\h\()6:                               /* A, (X) */
    bal     zrd
    move    a0, SX
    SOP_\op SA, v0
    SNEXT   1
s_\h\()7:                               /* A, [dp+X] */
    DPXIND
    bal     ard
    nop
    SOP_\op SA, v0
    SNEXT   2
s_\h\()8:                               /* A, #imm */
    OP1     v0
    SOP_\op SA, v0
    SNEXT   2
s_\h\()9:                               /* dp(OP2), dp(OP1) */
    OP1     a0
    bal     zrd
    nop
    move    a2, v0
    bal     zrd
    OP2     a0
    SOP_\op v0, a2
    .if !\cmp
    bal     zwr
    move    a1, v0
    .endif
    SNEXT   3
s_\h1\()4:                              /* A, dp+X */
    OP1     a0
    addu    a0, a0, SX
    bal     zrd
    andi    a0, a0, 0xff
    SOP_\op SA, v0
    SNEXT   2
s_\h1\()5:                              /* A, abs+X */
    ABSA    a0
    bal     ard
    addu    a0, a0, SX
    SOP_\op SA, v0
    SNEXT   3
s_\h1\()6:                              /* A, abs+Y */
    ABSA    a0
    bal     ard
    addu    a0, a0, SY
    SOP_\op SA, v0
    SNEXT   3
s_\h1\()7:                              /* A, [dp]+Y */
    DPINDY
    bal     ard
    nop
    SOP_\op SA, v0
    SNEXT   2
s_\h1\()8:                              /* dp(OP2), #imm(OP1) */
    OP1     a2
    bal     zrd
    OP2     a0
    SOP_\op v0, a2
    .if !\cmp
    bal     zwr
    move    a1, v0
    .endif
    SNEXT   3
s_\h1\()9:                              /* (X), (Y) */
    bal     zrd
    move    a0, SX
    move    a2, v0
    bal     zrd
    move    a0, SY
    move    a1, v0
    move    v0, a2
    SOP_\op v0, a1
    .if !\cmp
    move    a1, v0
    bal     zwr
    move    a0, SX
    .endif
    SNEXT   1
    .endm

    SFAM    OR, 0, 1, 0
    SFAM    AND, 2, 3, 0
    SFAM    EOR, 4, 5, 0
    SFAM    CMP, 6, 7, 1
    SFAM    ADC, 8, 9, 0
    SFAM    SBC, A, B, 0

/* ---- MOV A, X, Y from memory ------------------------------------------------- */
s_E4:
    OP1     a0
    bal     zrd
    nop
    move    SA, v0
    move    SZ, v0
    SNEXT   2
s_E5:
    ABSA    a0
    bal     ard
    nop
    move    SA, v0
    move    SZ, v0
    SNEXT   3
s_E6:
    bal     zrd
    move    a0, SX
    move    SA, v0
    move    SZ, v0
    SNEXT   1
s_E7:
    DPXIND
    bal     ard
    nop
    move    SA, v0
    move    SZ, v0
    SNEXT   2
s_E8:
    OP1     SA
    move    SZ, SA
    SNEXT   2
s_F4:
    OP1     a0
    addu    a0, a0, SX
    bal     zrd
    andi    a0, a0, 0xff
    move    SA, v0
    move    SZ, v0
    SNEXT   2
s_F5:
    ABSA    a0
    bal     ard
    addu    a0, a0, SX
    move    SA, v0
    move    SZ, v0
    SNEXT   3
s_F6:
    ABSA    a0
    bal     ard
    addu    a0, a0, SY
    move    SA, v0
    move    SZ, v0
    SNEXT   3
s_F7:
    DPINDY
    bal     ard
    nop
    move    SA, v0
    move    SZ, v0
    SNEXT   2
s_BF:                                   /* MOV A, (X)+ */
    bal     zrd
    move    a0, SX
    addiu   SX, SX, 1
    andi    SX, SX, 0xff
    move    SA, v0
    move    SZ, v0
    SNEXT   1
s_F8:                                   /* MOV X, dp */
    OP1     a0
    bal     zrd
    nop
    move    SX, v0
    move    SZ, v0
    SNEXT   2
s_F9:                                   /* MOV X, dp+Y */
    OP1     a0
    addu    a0, a0, SY
    bal     zrd
    andi    a0, a0, 0xff
    move    SX, v0
    move    SZ, v0
    SNEXT   2
s_E9:                                   /* MOV X, abs */
    ABSA    a0
    bal     ard
    nop
    move    SX, v0
    move    SZ, v0
    SNEXT   3
s_CD:                                   /* MOV X, #imm */
    OP1     SX
    move    SZ, SX
    SNEXT   2
s_EB:                                   /* MOV Y, dp */
    OP1     a0
    bal     zrd
    nop
    move    SY, v0
    move    SZ, v0
    SNEXT   2
s_FB:                                   /* MOV Y, dp+X */
    OP1     a0
    addu    a0, a0, SX
    bal     zrd
    andi    a0, a0, 0xff
    move    SY, v0
    move    SZ, v0
    SNEXT   2
s_EC:                                   /* MOV Y, abs */
    ABSA    a0
    bal     ard
    nop
    move    SY, v0
    move    SZ, v0
    SNEXT   3
s_8D:                                   /* MOV Y, #imm */
    OP1     SY
    move    SZ, SY
    SNEXT   2

/* ---- MOV memory from A, X, Y ------------------------------------------------- */
s_C4:
    OP1     a0
    bal     zwr
    move    a1, SA
    SNEXT   2
s_C5:
    ABSA    a0
    bal     awr
    move    a1, SA
    SNEXT   3
s_C6:
    move    a0, SX
    bal     zwr
    move    a1, SA
    SNEXT   1
s_C7:
    DPXIND
    bal     awr
    move    a1, SA
    SNEXT   2
s_D4:
    OP1     a0
    addu    a0, a0, SX
    andi    a0, a0, 0xff
    bal     zwr
    move    a1, SA
    SNEXT   2
s_D5:
    ABSA    a0
    addu    a0, a0, SX
    bal     awr
    move    a1, SA
    SNEXT   3
s_D6:
    ABSA    a0
    addu    a0, a0, SY
    bal     awr
    move    a1, SA
    SNEXT   3
s_D7:
    DPINDY
    bal     awr
    move    a1, SA
    SNEXT   2
s_AF:                                   /* MOV (X)+, A */
    move    a0, SX
    addiu   SX, SX, 1
    andi    SX, SX, 0xff
    bal     zwr
    move    a1, SA
    SNEXT   1
s_D8:                                   /* MOV dp, X */
    OP1     a0
    bal     zwr
    move    a1, SX
    SNEXT   2
s_D9:                                   /* MOV dp+Y, X */
    OP1     a0
    addu    a0, a0, SY
    andi    a0, a0, 0xff
    bal     zwr
    move    a1, SX
    SNEXT   2
s_C9:                                   /* MOV abs, X */
    ABSA    a0
    bal     awr
    move    a1, SX
    SNEXT   3
s_CB:                                   /* MOV dp, Y */
    OP1     a0
    bal     zwr
    move    a1, SY
    SNEXT   2
s_DB:                                   /* MOV dp+X, Y */
    OP1     a0
    addu    a0, a0, SX
    andi    a0, a0, 0xff
    bal     zwr
    move    a1, SY
    SNEXT   2
s_CC:                                   /* MOV abs, Y */
    ABSA    a0
    bal     awr
    move    a1, SY
    SNEXT   3
s_FA:                                   /* MOV dp(OP2), dp(OP1) */
    OP1     a0
    bal     zrd
    nop
    move    a1, v0
    bal     zwr
    OP2     a0
    SNEXT   3
s_8F:                                   /* MOV dp(OP2), #imm */
    OP1     a1
    bal     zwr
    OP2     a0
    SNEXT   3

/* ---- register moves ---------------------------------------------------------- */
s_7D:                                   /* MOV A, X */
    move    SA, SX
    move    SZ, SA
    SNEXT   1
s_DD:                                   /* MOV A, Y */
    move    SA, SY
    move    SZ, SA
    SNEXT   1
s_5D:                                   /* MOV X, A */
    move    SX, SA
    move    SZ, SX
    SNEXT   1
s_FD:                                   /* MOV Y, A */
    move    SY, SA
    move    SZ, SY
    SNEXT   1
s_9D:                                   /* MOV X, SP */
    move    SX, SS
    move    SZ, SX
    SNEXT   1
s_BD:                                   /* MOV SP, X */
    move    SS, SX
    SNEXT   1

/* ---- stack ------------------------------------------------------------------- */
    .macro  SPUSH r                     /* RAM [0x100 + S] = r; S-- */
    addu    at, SRAM, SS
    sb      \r, 0x100(at)
    addiu   SS, SS, -1
    andi    SS, SS, 0xff
    .endm
    .macro  SPOP r                      /* S++; r = RAM [0x100 + S] */
    addiu   SS, SS, 1
    andi    SS, SS, 0xff
    addu    at, SRAM, SS
    lbu     \r, 0x100(at)
    .endm
    .macro  SPUSHW r                    /* RAM [0xff + S] = r; RAM [0x100 + S] = r >> 8; S -= 2 */
    addu    at, SRAM, SS
    sb      \r, 0xff(at)
    srl     v1, \r, 8
    sb      v1, 0x100(at)
    addiu   SS, SS, -2
    andi    SS, SS, 0xff
    .endm
    .macro  SPOPW r                     /* S += 2; r = RAM [0xff + S] + (RAM [0x100 + S] << 8) */
    addiu   SS, SS, 2
    andi    SS, SS, 0xff
    addu    at, SRAM, SS
    lbu     \r, 0xff(at)
    lbu     v1, 0x100(at)
    sll     v1, v1, 8
    or      \r, \r, v1
    .endm
s_2D:
    SPUSH   SA
    SNEXT   1
s_4D:
    SPUSH   SX
    SNEXT   1
s_6D:
    SPUSH   SY
    SNEXT   1
s_AE:
    SPOP    SA
    SNEXT   1
s_CE:
    SPOP    SX
    SNEXT   1
s_EE:
    SPOP    SY
    SNEXT   1
s_0D:                                   /* PUSH PSW: S9xAPUPackStatus */
    lui     a2, %hi(APURegisters+AREG_P)
    lbu     a0, %lo(APURegisters+AREG_P)(a2)
    andi    a0, a0, 0x3c
    or      a0, a0, SC
    sltiu   at, SZ, 1
    sll     at, at, 1
    or      a0, a0, at
    andi    at, SZ, 0x80
    or      a0, a0, at
    LBUS    at, IAPU+IAPU_Overflow
    sll     at, at, 6
    or      a0, a0, at
    sb      a0, %lo(APURegisters+AREG_P)(a2)
    SPUSH   a0
    SNEXT   1
s_8E:                                   /* POP PSW: S9xAPUUnpackStatus, direct page */
    SPOP    a0
    lui     a2, %hi(APURegisters+AREG_P)
    sb      a0, %lo(APURegisters+AREG_P)(a2)
    andi    SZ, a0, 2
    xori    SZ, SZ, 2
    sltu    SZ, $0, SZ                  /* (P & Zero) == 0 */
    andi    at, a0, 0x80
    or      SZ, SZ, at
    andi    SC, a0, 1
    srl     at, a0, 6
    andi    at, at, 1
    SETV    at
    andi    at, a0, 0x20
    sll     at, at, 3                   /* DirectPage = RAM + 0x100 when P & 0x20 */
    addu    SDP, SRAM, at
    lui     at, %hi(IAPU+IAPU_DirectPage)
    sw      SDP, %lo(IAPU+IAPU_DirectPage)(at)
    SNEXT   1

/* ---- INC, DEC (IAPU.WaitCounter++) ------------------------------------------- */
    .macro  SINCR lbl, r, d
\lbl:
    addiu   \r, \r, \d
    andi    \r, \r, 0xff
    move    SZ, \r
    WAITCNT
    SNEXT   1
    .endm
    SINCR   s_3D, SX, 1
    SINCR   s_FC, SY, 1
    SINCR   s_1D, SX, -1
    SINCR   s_DC, SY, -1
    SINCR   s_BC, SA, 1
    SINCR   s_9C, SA, -1
    .macro  SINCZ lbl, d, x             /* dp or dp+X */
\lbl:
    OP1     a0
    .if \x
    addu    a0, a0, SX
    andi    a0, a0, 0xff
    .endif
    bal     zrd
    nop
    addiu   a1, v0, \d
    andi    a1, a1, 0xff
    bal     zwr
    move    SZ, a1
    WAITCNT
    SNEXT   2
    .endm
    SINCZ   s_AB, 1, 0
    SINCZ   s_BB, 1, 1
    SINCZ   s_8B, -1, 0
    SINCZ   s_9B, -1, 1
    .macro  SINCA lbl, d                /* abs */
\lbl:
    ABSA    a0
    bal     ard
    nop
    addiu   a1, v0, \d
    andi    a1, a1, 0xff
    bal     awr
    move    SZ, a1
    WAITCNT
    SNEXT   3
    .endm
    SINCA   s_AC, 1
    SINCA   s_8C, -1

/* ---- shifts and rotates: value in v0, result in a1 --------------------------- */
    .macro  SSH_ASL
    srl     SC, v0, 7
    sll     a1, v0, 1
    andi    a1, a1, 0xff
    move    SZ, a1
    .endm
    .macro  SSH_LSR
    andi    SC, v0, 1
    srl     a1, v0, 1
    move    SZ, a1
    .endm
    .macro  SSH_ROL
    sll     a1, v0, 1
    or      a1, a1, SC
    srl     SC, a1, 8
    andi    a1, a1, 0xff
    move    SZ, a1
    .endm
    .macro  SSH_ROR
    sll     at, SC, 8
    or      a1, v0, at
    andi    SC, a1, 1
    srl     a1, a1, 1
    move    SZ, a1
    .endm
    .macro  SSHIFT op, a, dp, dpx, abs
s_\a:                                   /* A */
    move    v0, SA
    SSH_\op
    move    SA, a1
    SNEXT   1
s_\dp:                                  /* dp */
    OP1     a0
    bal     zrd
    nop
    SSH_\op
    bal     zwr
    nop
    SNEXT   2
s_\dpx:                                 /* dp+X */
    OP1     a0
    addu    a0, a0, SX
    bal     zrd
    andi    a0, a0, 0xff
    SSH_\op
    bal     zwr
    nop
    SNEXT   2
s_\abs:                                 /* abs */
    ABSA    a0
    bal     ard
    nop
    SSH_\op
    bal     awr
    nop
    SNEXT   3
    .endm
    SSHIFT  ASL, 1C, 0B, 1B, 0C
    SSHIFT  LSR, 5C, 4B, 5B, 4C
    SSHIFT  ROL, 3C, 2B, 3B, 2C
    SSHIFT  ROR, 7C, 6B, 7B, 6C

/* ---- SET1, CLR1 dp.bit -------------------------------------------------------- */
    .macro  SBITW lbl, b, set
\lbl:
    OP1     a0
    bal     zrd
    nop
    .if \set
    ori     a1, v0, 1 << \b
    .else
    andi    a1, v0, 0xff & ~(1 << \b)
    .endif
    bal     zwr
    nop
    SNEXT   2
    .endm
    SBITW   s_02, 0, 1
    SBITW   s_22, 1, 1
    SBITW   s_42, 2, 1
    SBITW   s_62, 3, 1
    SBITW   s_82, 4, 1
    SBITW   s_A2, 5, 1
    SBITW   s_C2, 6, 1
    SBITW   s_E2, 7, 1
    SBITW   s_12, 0, 0
    SBITW   s_32, 1, 0
    SBITW   s_52, 2, 0
    SBITW   s_72, 3, 0
    SBITW   s_92, 4, 0
    SBITW   s_B2, 5, 0
    SBITW   s_D2, 6, 0
    SBITW   s_F2, 7, 0

/* ---- branches ----------------------------------------------------------------- */
    .macro  SBR lbl, test, reg, mask, shut
\lbl:
    lb      a0, 1(SPC)
    .if \mask
    andi    v0, \reg, \mask
    \test   v0, 1f
    .else
    \test   \reg, 1f
    .endif
    li      a2, 2
    .if \shut
    b       spc_taken_s
    .else
    b       spc_taken
    .endif
    nop
1:  SNEXT   2
    .endm
    SBR     s_10, bnez, SZ, 0x80, 1     /* BPL: taken when N clear */
    SBR     s_30, beqz, SZ, 0x80, 1     /* BMI */
    SBR     s_90, bnez, SC, 0, 1        /* BCC */
    SBR     s_B0, beqz, SC, 0, 1        /* BCS */
    SBR     s_D0, beqz, SZ, 0, 1        /* BNE: taken when _Zero != 0 */
    SBR     s_F0, bnez, SZ, 0, 1        /* BEQ */
s_50:                                   /* BVC */
    lb      a0, 1(SPC)
    LBUS    v0, IAPU+IAPU_Overflow
    bnez    v0, 1f
    li      a2, 2
    b       spc_taken
    nop
1:  SNEXT   2
s_70:                                   /* BVS */
    lb      a0, 1(SPC)
    LBUS    v0, IAPU+IAPU_Overflow
    beqz    v0, 1f
    li      a2, 2
    b       spc_taken
    nop
1:  SNEXT   2
s_2F:                                   /* BRA: no extra cycles in spc700.cpp */
    lb      a0, 1(SPC)
    subu    v1, SPC, SRAM
    addiu   v1, v1, 2
    addu    v1, v1, a0
    andi    v1, v1, 0xffff
    b       spc_next
    addu    SPC, SRAM, v1
    .macro  SBB lbl, b, set             /* BBS / BBC dp.bit, rel */
\lbl:
    OP1     a0
    bal     zrd
    nop
    andi    v0, v0, 1 << \b
    .if \set
    beqz    v0, 1f
    .else
    bnez    v0, 1f
    .endif
    lb      a0, 2(SPC)
    b       spc_taken
    li      a2, 3
1:  SNEXT   3
    .endm
    SBB     s_03, 0, 1
    SBB     s_23, 1, 1
    SBB     s_43, 2, 1
    SBB     s_63, 3, 1
    SBB     s_83, 4, 1
    SBB     s_A3, 5, 1
    SBB     s_C3, 6, 1
    SBB     s_E3, 7, 1
    SBB     s_13, 0, 0
    SBB     s_33, 1, 0
    SBB     s_53, 2, 0
    SBB     s_73, 3, 0
    SBB     s_93, 4, 0
    SBB     s_B3, 5, 0
    SBB     s_D3, 6, 0
    SBB     s_F3, 7, 0
s_2E:                                   /* CBNE dp, rel */
    OP1     a0
    bal     zrd
    nop
    beq     v0, SA, 1f
    lb      a0, 2(SPC)
    b       spc_taken_s
    li      a2, 3
1:  SNEXT   3
s_DE:                                   /* CBNE dp+X, rel */
    OP1     a0
    addu    a0, a0, SX
    bal     zrd
    andi    a0, a0, 0xff
    beq     v0, SA, 1f
    lb      a0, 2(SPC)
    b       spc_taken_s
    li      a2, 3
1:  SNEXT   3
s_6E:                                   /* DBNZ dp, rel */
    OP1     a0
    bal     zrd
    nop
    addiu   a1, v0, -1
    bal     zwr
    andi    a1, a1, 0xff
    beqz    a1, 1f
    lb      a0, 2(SPC)
    b       spc_taken
    li      a2, 3
1:  SNEXT   3
s_FE:                                   /* DBNZ Y, rel */
    addiu   SY, SY, -1
    andi    SY, SY, 0xff
    beqz    SY, 1f
    lb      a0, 1(SPC)
    b       spc_taken
    li      a2, 2
1:  SNEXT   2

/* ---- jumps, calls, returns ---------------------------------------------------- */
s_5F:                                   /* JMP abs */
    ABSA    a0
    b       spc_next
    addu    SPC, SRAM, a0
s_3F:                                   /* CALL abs */
    ABSA    a2
    subu    a0, SPC, SRAM
    addiu   a0, a0, 3
    SPUSHW  a0
    b       spc_next
    addu    SPC, SRAM, a2
s_4F:                                   /* PCALL $FF00 + OP1 */
    OP1     a2
    subu    a0, SPC, SRAM
    addiu   a0, a0, 2
    SPUSHW  a0
    ori     a2, a2, 0xff00
    b       spc_next
    addu    SPC, SRAM, a2
s_6F:                                   /* RET */
    SPOPW   a0
    b       spc_next
    addu    SPC, SRAM, a0

/* ---- flags -------------------------------------------------------------------- */
s_60:                                   /* CLRC */
    move    SC, $0
    SNEXT   1
s_80:                                   /* SETC */
    li      SC, 1
    SNEXT   1
s_ED:                                   /* NOTC */
    xori    SC, SC, 1
    SNEXT   1
s_E0:                                   /* CLRV: P &= ~HalfCarry, _Overflow = 0 */
    CLRH
    SETV    $0
    SNEXT   1
s_20:                                   /* CLRP */
    lui     v1, %hi(APURegisters+AREG_P)
    lbu     at, %lo(APURegisters+AREG_P)(v1)
    andi    at, at, 0xdf
    sb      at, %lo(APURegisters+AREG_P)(v1)
    move    SDP, SRAM
    lui     at, %hi(IAPU+IAPU_DirectPage)
    sw      SDP, %lo(IAPU+IAPU_DirectPage)(at)
    SNEXT   1
s_40:                                   /* SETP */
    lui     v1, %hi(APURegisters+AREG_P)
    lbu     at, %lo(APURegisters+AREG_P)(v1)
    ori     at, at, 0x20
    sb      at, %lo(APURegisters+AREG_P)(v1)
    addiu   SDP, SRAM, 0x100
    lui     at, %hi(IAPU+IAPU_DirectPage)
    sw      SDP, %lo(IAPU+IAPU_DirectPage)(at)
    SNEXT   1
s_C0:                                   /* DI */
    lui     v1, %hi(APURegisters+AREG_P)
    lbu     at, %lo(APURegisters+AREG_P)(v1)
    andi    at, at, 0xfb
    sb      at, %lo(APURegisters+AREG_P)(v1)
    SNEXT   1
s_A0:                                   /* EI */
    lui     v1, %hi(APURegisters+AREG_P)
    lbu     at, %lo(APURegisters+AREG_P)(v1)
    ori     at, at, 4
    sb      at, %lo(APURegisters+AREG_P)(v1)
    SNEXT   1
s_00:                                   /* NOP */
    SNEXT   1

/* ---- 16-bit YA operations ------------------------------------------------------ */
    .macro  ZW16 r                      /* _Zero = (r != 0) | (r >> 8) */
    sltu    SZ, $0, \r
    srl     at, \r, 8
    or      SZ, SZ, at
    .endm
    .macro  RDW                         /* v0 = GetByteZ (OP1) + (GetByteZ (OP1 + 1) << 8); a2 = OP1 */
    OP1     a2
    bal     zrd
    move    a0, a2
    move    a1, v0
    addiu   a0, a2, 1
    bal     zrd
    andi    a0, a0, 0xff
    sll     v0, v0, 8
    or      v0, v0, a1
    .endm
s_1A:                                   /* DECW dp */
    RDW
    addiu   a2, v0, -1
    andi    a2, a2, 0xffff
    ZW16    a2
    OP1     a0
    bal     zwr
    andi    a1, a2, 0xff
    OP1     a0
    addiu   a0, a0, 1
    andi    a0, a0, 0xff
    bal     zwr
    srl     a1, a2, 8
    SNEXT   2
s_3A:                                   /* INCW dp */
    RDW
    addiu   a2, v0, 1
    andi    a2, a2, 0xffff
    ZW16    a2
    OP1     a0
    bal     zwr
    andi    a1, a2, 0xff
    OP1     a0
    addiu   a0, a0, 1
    andi    a0, a0, 0xff
    bal     zwr
    srl     a1, a2, 8
    SNEXT   2
s_5A:                                   /* CMPW YA, dp */
    RDW
    sll     a0, SY, 8
    or      a0, a0, SA
    sltu    SC, a0, v0
    xori    SC, SC, 1
    subu    a0, a0, v0
    andi    a0, a0, 0xffff
    ZW16    a0
    SNEXT   2
s_7A:                                   /* ADDW YA, dp */
    RDW
    CLRH
    sll     a0, SY, 8
    or      a0, a0, SA
    addu    a1, a0, v0
    srl     SC, a1, 16
    andi    a1, a1, 0xffff
    xor     at, a0, v0
    nor     at, at, $0
    xor     v1, v0, a1
    and     at, at, v1
    srl     at, at, 15
    andi    at, at, 1
    SETV    at
    andi    SA, a1, 0xff
    srl     SY, a1, 8
    ZW16    a1
    SNEXT   2
s_9A:                                   /* SUBW YA, dp */
    RDW
    CLRH
    sll     a0, SY, 8
    or      a0, a0, SA
    subu    a1, a0, v0
    slt     SC, a1, $0
    xori    SC, SC, 1
    andi    a1, a1, 0xffff
    xor     a2, a0, v0                  /* YA ^ Work16 */
    xor     v0, a0, a1                  /* YA ^ result */
    and     a2, a2, v0
    srl     at, a2, 15
    andi    at, at, 1
    SETV    at
    andi    at, a2, 0x80                /* half carry: bit 7 of both */
    beqz    at, 1f
    lui     v1, %hi(APURegisters+AREG_P)
    lbu     at, %lo(APURegisters+AREG_P)(v1)
    ori     at, at, 8
    sb      at, %lo(APURegisters+AREG_P)(v1)
1:  andi    SA, a1, 0xff
    srl     SY, a1, 8
    ZW16    a1
    SNEXT   2
s_BA:                                   /* MOVW YA, dp */
    OP1     a2
    bal     zrd
    move    a0, a2
    move    SA, v0
    addiu   a0, a2, 1
    bal     zrd
    andi    a0, a0, 0xff
    move    SY, v0
    sll     a0, SY, 8
    or      a0, a0, SA
    ZW16    a0
    SNEXT   2
s_DA:                                   /* MOVW dp, YA */
    OP1     a2
    move    a0, a2
    bal     zwr
    move    a1, SA
    addiu   a0, a2, 1
    andi    a0, a0, 0xff
    bal     zwr
    move    a1, SY
    SNEXT   2
s_CF:                                   /* MUL YA */
    multu   SA, SY
    mflo    a0
    andi    SA, a0, 0xff
    srl     SY, a0, 8
    andi    SY, SY, 0xff
    andi    a0, a0, 0xffff
    ZW16    a0
    SNEXT   1
s_9F:                                   /* XCN A */
    srl     at, SA, 4
    sll     SA, SA, 4
    or      SA, SA, at
    andi    SA, SA, 0xff
    move    SZ, SA
    SNEXT   1

    .globl  s9xa_spc_text_end
s9xa_spc_text_end:

/* ============================================================================
 * jump table; opcodes without a handler run the core's function (spc_op_c)
 * ========================================================================== */
    .macro  SENT op
    .ifdef  s_\op
    .word   s_\op
    .else
    .word   spc_op_c
    .endif
    .endm

    .data
    .align  4
    .globl  s9xa_spc_tables
s9xa_spc_tables:
    .irp    hi, 0,1,2,3,4,5,6,7,8,9,A,B,C,D,E,F
    .irp    lo, 0,1,2,3,4,5,6,7,8,9,A,B,C,D,E,F
    SENT    \hi\lo
    .endr
    .endr
