/* s9x_offs.cpp - structure offsets of the Snes9x 1.39 core for cpu65.S,
 * spc700.S and tile16.S.
 * EPROM Foundry Inc. / Mike Wolak, project Blitz99.
 *
 * Compiled to assembler text only (-S); every OFF line becomes
 * "#define NAME VALUE" in the generated header s9x_offs.h (Makefile rule),
 * so the assembler core uses the offsets of the structures as the C++
 * compiler lays them out for this build (LSB_FIRST, VAR_CYCLES,
 * CPU_SHUTDOWN).
 */
#include <stddef.h>
#include "snes9x.h"
#include "memmap.h"
#include "cpuexec.h"
#include "apu.h"
#include "65c816.h"
#include "gfx.h"
#include "ppu.h"

#define OFF(name, val) __asm__ volatile ("\n#define " #name " %0" : : "n" ((int) (val)))

void s9x_offsets (void)
{
    OFF (CPU_Flags, offsetof (struct SCPUState, Flags));
    OFF (CPU_BranchSkip, offsetof (struct SCPUState, BranchSkip));
    OFF (CPU_PC, offsetof (struct SCPUState, PC));
    OFF (CPU_PCBase, offsetof (struct SCPUState, PCBase));
    OFF (CPU_PCAtOpcodeStart, offsetof (struct SCPUState, PCAtOpcodeStart));
    OFF (CPU_WaitAddress, offsetof (struct SCPUState, WaitAddress));
    OFF (CPU_Cycles, offsetof (struct SCPUState, Cycles));
    OFF (CPU_NextEvent, offsetof (struct SCPUState, NextEvent));
    OFF (CPU_MemSpeed, offsetof (struct SCPUState, MemSpeed));
    OFF (CPU_MemSpeedx2, offsetof (struct SCPUState, MemSpeedx2));
    OFF (CPU_WaitCounter, offsetof (struct SCPUState, WaitCounter));
    OFF (SET_Shutdown, offsetof (struct SSettings, Shutdown));
    OFF (ICPU_CPUExecuting, offsetof (struct SICPU, CPUExecuting));
    OFF (FLAG_IRQNMI, IRQ_PENDING_FLAG | NMI_FLAG);

    OFF (REG_PB, offsetof (struct SRegisters, PB));
    OFF (REG_DB, offsetof (struct SRegisters, DB));
    OFF (REG_P, offsetof (struct SRegisters, P));
    OFF (REG_A, offsetof (struct SRegisters, A));
    OFF (REG_D, offsetof (struct SRegisters, D));
    OFF (REG_S, offsetof (struct SRegisters, S));
    OFF (REG_X, offsetof (struct SRegisters, X));
    OFF (REG_Y, offsetof (struct SRegisters, Y));

    OFF (ICPU_S9xOpcodes, offsetof (struct SICPU, S9xOpcodes));
    OFF (ICPU_Carry, offsetof (struct SICPU, _Carry));
    OFF (ICPU_Zero, offsetof (struct SICPU, _Zero));
    OFF (ICPU_Negative, offsetof (struct SICPU, _Negative));
    OFF (ICPU_Overflow, offsetof (struct SICPU, _Overflow));
    OFF (ICPU_ShiftedPB, offsetof (struct SICPU, ShiftedPB));
    OFF (ICPU_ShiftedDB, offsetof (struct SICPU, ShiftedDB));

    OFF (MEM_Map, offsetof (CMemory, Map));
    OFF (MEM_WriteMap, offsetof (CMemory, WriteMap));
    OFF (MEM_MemorySpeed, offsetof (CMemory, MemorySpeed));
    OFF (MEM_BlockIsRAM, offsetof (CMemory, BlockIsRAM));
    OFF (MEM_MAP_LAST, CMemory::MAP_LAST);

    OFF (APU_Cycles, offsetof (struct SAPU, Cycles));
    OFF (APU_ShowROM, offsetof (struct SAPU, ShowROM));
    OFF (APU_OutPorts, offsetof (struct SAPU, OutPorts));
    OFF (APU_ExtraRAM, offsetof (struct SAPU, ExtraRAM));
    OFF (APU_TimerTarget, offsetof (struct SAPU, TimerTarget));
    OFF (IAPU_RAM, offsetof (struct SIAPU, RAM));
    OFF (IAPU_DirectPage, offsetof (struct SIAPU, DirectPage));
    OFF (IAPU_WaitAddress1, offsetof (struct SIAPU, WaitAddress1));
    OFF (IAPU_WaitAddress2, offsetof (struct SIAPU, WaitAddress2));
    OFF (IAPU_WaitCounter, offsetof (struct SIAPU, WaitCounter));
    OFF (IAPU_Carry, offsetof (struct SIAPU, _Carry));
    OFF (IAPU_Zero, offsetof (struct SIAPU, _Zero));
    OFF (IAPU_Overflow, offsetof (struct SIAPU, _Overflow));
    OFF (IAPU_TwoCycles, offsetof (struct SIAPU, TwoCycles));
    OFF (AREG_P, offsetof (struct SAPURegisters, P));
    OFF (AREG_A, offsetof (struct SAPURegisters, YA.B.A));
    OFF (AREG_Y, offsetof (struct SAPURegisters, YA.B.Y));
    OFF (AREG_X, offsetof (struct SAPURegisters, X));
    OFF (AREG_S, offsetof (struct SAPURegisters, S));
    OFF (IAPU_PC, offsetof (struct SIAPU, PC));
    OFF (IAPU_APUExecuting, offsetof (struct SIAPU, APUExecuting));

    OFF (BG_TileShift, offsetof (struct SBG, TileShift));
    OFF (BG_TileAddress, offsetof (struct SBG, TileAddress));
    OFF (BG_NameSelect, offsetof (struct SBG, NameSelect));
    OFF (BG_StartPalette, offsetof (struct SBG, StartPalette));
    OFF (BG_PaletteShift, offsetof (struct SBG, PaletteShift));
    OFF (BG_PaletteMask, offsetof (struct SBG, PaletteMask));
    OFF (BG_Buffer, offsetof (struct SBG, Buffer));
    OFF (BG_Buffered, offsetof (struct SBG, Buffered));
    OFF (BG_DirectColourMode, offsetof (struct SBG, DirectColourMode));
    OFF (GFX_PPL, offsetof (struct SGFX, PPL));
    OFF (GFX_S, offsetof (struct SGFX, S));
    OFF (GFX_DB, offsetof (struct SGFX, DB));
    OFF (GFX_ScreenColors, offsetof (struct SGFX, ScreenColors));
    OFF (GFX_Z1, offsetof (struct SGFX, Z1));
    OFF (GFX_Z2, offsetof (struct SGFX, Z2));
    OFF (IPPU_ScreenColors, offsetof (struct InternalPPU, ScreenColors));
    OFF (TILE_BLANK, BLANK_TILE);
    OFF (TILE_OPAQUE, S9X_OPAQUE_TILE);
}
