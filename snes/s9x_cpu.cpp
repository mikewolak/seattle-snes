/* s9x_cpu.cpp - interface between the assembler 65C816 core (cpu65.S) and
 * the Snes9x 1.39 core, and the CPU check report.
 * EPROM Foundry Inc. / Mike Wolak, project Blitz99.
 *
 * Compiled with the core's flags (SNESCXX). s9x_main_loop replaces
 * S9xMainLoop (cpuexec.cpp) when s9x_cpu_asm is set and the cartridge has
 * no SA-1: s9xa_run (cpu65.S) runs the frame and returns with the state
 * written back to CPU, Registers and ICPU when the frame ends
 * (SCAN_KEYS_FLAG); the code after the loop is S9xMainLoop's. The other
 * functions are the core paths cpu65.S calls: the memory access functions
 * of getset.h for addresses that are not plain memory, S9xSetPCBase,
 * CPUShutdown (cpuops.cpp) and the interrupt part of S9xMainLoop's loop.
 * Each is the core's code; the assembler core writes PC, Cycles and
 * PCAtOpcodeStart (all registers for the interrupt part) to the core's
 * structures before the call and reads them back after it.
 */
#include <stdio.h>
#include <string.h>
#include "snes9x.h"
#include "memmap.h"
#include "cpuops.h"
#include "ppu.h"
#include "cpuexec.h"
#include "missing.h"
#include "apu.h"
#include "dma.h"
#include "sa1.h"
#include "spc700.h"

extern "C" {

int s9x_cpu_asm = 1;                   /* 1: cpu65.S runs the 65C816, 0: S9xMainLoop */
int s9x_spc_asm = 1;                   /* 1: spc700.S runs the SPC700 inside cpu65.S, 0: the core's functions */
uint32 s9xa_hist[1024];                /* opcode counts (mode x 256 + opcode), S9XA_HIST builds */
uint32 s9xa_fall[1024];                /* of them run by the core's C handler */
uint32 s9xa_spch[256];                 /* S9XA_HIST: SPC700 opcode counts */
uint32 s9xa_cnt[8];                    /* S9XA_HIST: C calls, H-blank events, interrupt passes, SPC700 opcodes */
void s9xa_run (void);
extern uint32 s9xa_tables[1024];
void s9xa_op_c (void);
extern uint32 s9xa_spc_tables[256];
void s9xa_spc_op_c (void);

uint8 *s9xa_lr_base;                   /* Memory.Map of bank 0 0000-1FFF for cpu65.S, or NULL */
uint32 s9xa_lr_speed;                  /* its MemorySpeed */
static uint32 tables0[1024];           /* s9xa_tables as assembled */
static uint32 spctables0[256];         /* s9xa_spc_tables as assembled */

/* game start: the jump tables as assembled ("spc c": the SPC700 opcodes by
   the core's functions); with the SPC700 off the branch
   opcodes (which test CPU.BranchSkip, set by S9xGetPPU only then) and the
   opcodes LO to HI (inclusive, a test setting) run the core's C handlers */
void s9x_cpu_setup (int lo, int hi)
{
    static const uint8 br[] = { 0x10, 0x30, 0x50, 0x70, 0x90, 0xb0, 0xd0, 0xf0 };
    if (!tables0[0])
    {
	memcpy (tables0, s9xa_tables, sizeof tables0);
	memcpy (spctables0, s9xa_spc_tables, sizeof spctables0);
    }
    memcpy (s9xa_tables, tables0, sizeof tables0);
    memcpy (s9xa_spc_tables, spctables0, sizeof spctables0);
    if (!s9x_spc_asm)			/* "spc c": every SPC700 opcode by the core's function */
	for (int op = 0; op < 256; op++)
	    s9xa_spc_tables[op] = (uint32) s9xa_spc_op_c;
    for (int m = 0; m < 4; m++)
    {
	for (int op = lo; op <= hi && op < 256; op++)
	    s9xa_tables[m * 256 + op] = (uint32) s9xa_op_c;
	if (!Settings.APUEnabled)
	    for (unsigned i = 0; i < sizeof br; i++)
		s9xa_tables[m * 256 + br[i]] = (uint32) s9xa_op_c;
    }
}

/* bank 0 0000-1FFF (blocks 0 and 1): one RAM base for reading and writing,
   one speed, BlockIsRAM set; else cpu65.S takes the general path there */
static void lowram (void)
{
    uint8 *b = Memory.Map[0];
    bool ok = b >= (uint8 *) CMemory::MAP_LAST && Memory.Map[1] == b &&
	      Memory.WriteMap[0] == b && Memory.WriteMap[1] == b &&
	      Memory.MemorySpeed[0] == Memory.MemorySpeed[1] &&
	      Memory.BlockIsRAM[0] && Memory.BlockIsRAM[1];
    s9xa_lr_base = ok ? b : NULL;
    s9xa_lr_speed = Memory.MemorySpeed[0];
}
void mon_printf (const char *fmt, ...);

uint32 s9xa_getbyte (uint32 a) { return S9xGetByte (a); }
uint32 s9xa_getword (uint32 a) { return S9xGetWord (a); }
void s9xa_setbyte (uint32 a, uint32 v) { S9xSetByte ((uint8) v, a); }
void s9xa_setword (uint32 a, uint32 v) { S9xSetWord ((uint16) v, a); }
void s9xa_setpcbase (uint32 a) { S9xSetPCBase (a); }

/* CPUShutdown of cpuops.cpp (CPU_SHUTDOWN, not SA1_OPCODES); called by a
 * taken branch when CPU.PC equals CPU.WaitAddress */
void s9xa_shutdown (void)
{
    if (Settings.Shutdown && CPU.PC == CPU.WaitAddress)
    {
	if (CPU.WaitCounter == 0 &&
	    !(CPU.Flags & (IRQ_PENDING_FLAG | NMI_FLAG)))
	{
	    CPU.WaitAddress = NULL;
	    if (Settings.SA1)
		S9xSA1ExecuteDuringSleep ();
	    CPU.Cycles = CPU.NextEvent;
	    if (IAPU.APUExecuting)
	    {
		ICPU.CPUExecuting = FALSE;
		do
		{
		    APU_EXECUTE1 ();
		} while (APU.Cycles < CPU.NextEvent);
		ICPU.CPUExecuting = TRUE;
	    }
	}
	else
	if (CPU.WaitCounter >= 2)
	    CPU.WaitCounter = 1;
	else
	    CPU.WaitCounter--;
    }
}

/* the CPU.Flags part of S9xMainLoop's loop (no debugger); returns 1 when
 * the loop ends (SCAN_KEYS_FLAG) */
int s9xa_flags (void)
{
    if (CPU.Flags & NMI_FLAG)
    {
	if (--CPU.NMICycleCount == 0)
	{
	    CPU.Flags &= ~NMI_FLAG;
	    if (CPU.WaitingForInterrupt)
	    {
		CPU.WaitingForInterrupt = FALSE;
		CPU.PC++;
	    }
	    S9xOpcode_NMI ();
	}
    }
    CHECK_SOUND ();
    if (CPU.Flags & IRQ_PENDING_FLAG)
    {
	if (CPU.IRQCycleCount == 0)
	{
	    if (CPU.WaitingForInterrupt)
	    {
		CPU.WaitingForInterrupt = FALSE;
		CPU.PC++;
	    }
	    if (CPU.IRQActive && !Settings.DisableIRQ)
	    {
		if (!CheckFlag (IRQ))
		    S9xOpcode_IRQ ();
	    }
	    else
		CPU.Flags &= ~IRQ_PENDING_FLAG;
	}
	else
	    CPU.IRQCycleCount--;
    }
    return (CPU.Flags & SCAN_KEYS_FLAG) != 0;
}

/* S9xMainLoop with the loop in cpu65.S; the code after the loop is the core's */
void s9x_main_loop (void)
{
    if (!s9x_cpu_asm || Settings.SA1)
    {
	S9xMainLoop ();
	return;
    }
    lowram ();
    s9xa_run ();
    Registers.PC = CPU.PC - CPU.PCBase;
    S9xPackStatus ();
    APURegisters.PC = IAPU.PC - IAPU.RAM;
    S9xAPUPackStatus ();
    if (CPU.Flags & SCAN_KEYS_FLAG)
    {
	S9xSyncSpeed ();
	CPU.Flags &= ~SCAN_KEYS_FLAG;
    }
    if (CPU.BRKTriggered && Settings.SuperFX && !CPU.TriedInterleavedMode2)
    {
	CPU.TriedInterleavedMode2 = TRUE;
	CPU.BRKTriggered = FALSE;
	S9xDeinterleaveMode2 ();
    }
}

/* CRC-32 (IEEE 802.3, reflected, polynomial 0xEDB88320) */
static uint32 crc32 (uint32 c, const uint8 *p, uint32 n)
{
    static uint32 t[256];
    if (!t[1])
	for (uint32 i = 0; i < 256; i++)
	{
	    uint32 r = i;
	    for (int k = 0; k < 8; k++)
		r = (r >> 1) ^ (0xedb88320u & (0u - (r & 1u)));
	    t[i] = r;
	}
    c = ~c;
    while (n--)
	c = t[(c ^ *p++) & 0xffu] ^ (c >> 8);
    return ~c;
}

/* check report at the end of a frame (after S9xPackStatus): CRC-32 of
 * WRAM (128 KB), VRAM (64 KB), the I/O register image (FillRAM 0x2000-0x5FFF)
 * and the SPC700 RAM (64 KB), the 65C816 and SPC700 registers and the cycle
 * counters; equal lines from two runs of the same ROM with the same input
 * mean the same machine state at that frame */
void s9x_cpu_check (uint32 frame)
{
    char line[200];
    snprintf (line, sizeof line, "snes: check %u ram %08x vram %08x io %08x apu %08x "
		"A %04x X %04x Y %04x S %04x D %04x DB %02x PB %02x PC %04x P %03x "
		"cyc %d v %d apc %04x acyc %d\n",
		(unsigned) frame,
		(unsigned) crc32 (0, Memory.RAM, 0x20000),
		(unsigned) crc32 (0, Memory.VRAM, 0x10000),
		(unsigned) crc32 (0, Memory.FillRAM + 0x2000, 0x4000),
		(unsigned) crc32 (0, IAPU.RAM, 0x10000),
		Registers.A.W, Registers.X.W, Registers.Y.W, Registers.S.W,
		Registers.D.W, Registers.DB, Registers.PB, Registers.PC,
		Registers.P.W, (int) CPU.Cycles, (int) CPU.V_Counter,
		APURegisters.PC, (int) APU.Cycles);
    mon_printf ("%s", line);
}

/* opcode counts of an S9XA_HIST build: the largest, cleared as printed */
static void hist_print (const char *tag, uint32 *h, uint32 len, int n)
{
    uint32 tot = 0;
    for (uint32 i = 0; i < len; i++)
	tot += h[i];
    mon_printf ("snes: %s, %u in all (mode 0 M0X0, 1 M0X1, 2 M1X0, 3 M1X1)\n", tag, (unsigned) tot);
    for (int k = 0; k < n; k++)
    {
	uint32 best = 0, bi = 0;
	for (uint32 i = 0; i < len; i++)
	    if (h[i] > best)
	    {
		best = h[i];
		bi = i;
	    }
	if (!best)
	    break;
	char line[64];
	snprintf (line, sizeof line, "snes: %s %u %02x %u\n", tag, (unsigned) (bi >> 8), (unsigned) (bi & 0xff), (unsigned) best);
	mon_printf ("%s", line);
	h[bi] = 0;
    }
}

void s9x_cpu_hist (void)
{
    uint32 any = 0;
    for (int i = 0; i < 1024; i++)
	any |= s9xa_hist[i];
    if (any)
    {
	mon_printf ("snes: C calls %u, H-blank %u, interrupt passes %u, SPC700 opcodes %u, shutdowns %u, SPC700 runs %u\n",
		    (unsigned) s9xa_cnt[0], (unsigned) s9xa_cnt[1], (unsigned) s9xa_cnt[2],
		    (unsigned) s9xa_cnt[3], (unsigned) s9xa_cnt[4], (unsigned) s9xa_cnt[5]);
	hist_print ("fall", s9xa_fall, 1024, 24);
	hist_print ("spc", s9xa_spch, 256, 80);
	hist_print ("op", s9xa_hist, 1024, 64);
    }
}

}
