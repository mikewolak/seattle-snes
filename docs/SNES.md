# SNES Emulator for the Midway Seattle Board

Snes9x 1.39 on the A-21464 board (QED R5000 at 150 MHz, 8 MB DRAM, Voodoo SST-1, ADSP-2115 DCS2 sound), built into the disk build of the bring-up monitor beside the NES emulator and started from the ROM launch menu, Other Apps, SNES.

## 1 Provenance

| Component | Origin | Author | Licence |
|---|---|---|---|
| Emulator core | Snes9x 1.39 release source `s9xs139.zip`, <https://www.lysator.liu.se/snes9x/1.39/s9xs139.zip>, 666,463 bytes, SHA-256 `996b3ed10debca64e02e31f28e3e7f78b3d39608aa918cb739b2c2fa17bce27b`; `snes9x.h` defines `VERSION "1.39"`; files dated 2001-09-18 | Gary Henderson, Jerremy Koot; Super FX C code Ivar and Gary Henderson; DSP-1 code Ivar, _Demo_ and Gary Henderson; C4 code zsKnight, _Demo_ and Gary Henderson (`copyright.h`) | Snes9x licence, quoted in section 1.1 |
| Core changes | `patches/snes9x-1.39-seattle.patch`, section 3 | Mike Wolak, EPROM Foundry Inc., project Blitz99 | as the core |
| Seattle platform layer | `bringup/snes/` (`s9x_seattle.c`, `s9x_port.h`, `menu.c`, `blit.S`, `draw.S`), C99 and R5000 assembly | Mike Wolak, EPROM Foundry Inc., project Blitz99 | project licence |
| 65C816 and SPC700 instruction loops | `bringup/snes/cpu65.S`, `bringup/snes/spc700.S` (R5000 assembly), `s9x_cpu.cpp` and `s9x_offs.cpp` (C++ against the core headers), section 9 | Mike Wolak, EPROM Foundry Inc., project Blitz99; the opcode semantics are those of Snes9x 1.39 `cpuops.cpp`, `cpuaddr.h`, `cpumacro.h`, `getset.h`, `cpuexec.cpp`, `spc700.cpp`, `apumem.h` | as the core (work derived from Snes9x) |
| Build and launch integration | `patches/bringup-snes-integration.patch` (`bringup/Makefile`, `bringup/src/main.c`, `bringup/src/appmenu.c`) | Mike Wolak, EPROM Foundry Inc., project Blitz99 | project licence |
| Reused platform code | `bringup/nes/` (structure, FIFO transport, frame report, menu), `q2seattle/src/sys/` (voodoo.c, irq.c, dcs.c, guru.c, sgrab.c), `bringup/fatfs` (FatFs R0.16, ChaN) | Mike Wolak, EPROM Foundry Inc.; FatFs by ChaN | as their sources |
| Test ROM (MAME only, not distributed with the port) | 240p Test Suite for SNES 1.03, `240pSuite-SNES-1.03.zip` from <https://sourceforge.net/projects/testsuite240p/files/OldFiles/SNES_SFC/>, `240pSuite.sfc` 524,288 bytes, SHA-256 `404917504fe5e3bcd070d9527fafdd6eeaf04dee75b4010792907499d536c22a` | Artemio Urbina | GPL-2.0 (`GPLv2.txt` and source in the archive) |

### 1.1 Snes9x Licence (copyright.h, verbatim extract)

> Permission to use, copy, modify and distribute Snes9x in both binary and source form, for non-commercial purposes, is hereby granted without fee, providing that this license information and copyright notice appear with all copies and any derived work.
>
> This software is provided 'as-is', without any express or implied warranty. In no event shall the authors be held liable for any damages arising from the use of this software.
>
> Snes9x is freeware for PERSONAL USE only. Commercial users should seek permission of the copyright holders first. Commercial use includes charging money for Snes9x or software derived from Snes9x.

A disk build that contains the SNES block is a work derived from Snes9x and carries this licence: non-commercial distribution only. The block does not link the GPL-2.0 MIPS FPU emulator (`q2seattle/src/sys/fpe.c`, `math-emu/`), whose licence is incompatible with the Snes9x terms; a floating-point unimplemented-operation exception in this build therefore reaches the fatal-error screen instead of being completed in software.

## 2 Build and Installation

1. Obtain the core and apply the core patch:

   ```
   mkdir -p $HOME/snes9x-1.39 && cd $HOME/snes9x-1.39
   unzip s9xs139.zip                      # creates release/
   patch -p1 < <repository>/patches/snes9x-1.39-seattle.patch
   ```

2. Apply the integration patch to the bring-up tree (repository root): `patch -p1 < patches/bringup-snes-integration.patch`.
3. Build the disk build: `cd bringup && make FATFS=1 BUILD=build-fs build-fs/payload.bin`. `SNES9X` (default `$(HOME)/snes9x-1.39/release`) names the core directory; `SNES_MAX_ROM` (default `0x280000`) sizes the ROM buffer.
4. Install the payload as the disk build at LBA 0x3EE080 (`loadz` + `dsave 3ee080 80600000 LEN` at the disk monitor, as for any disk build).
5. Copy SNES images (`.smc`, `.sfc`, `.swc`, `.fig`) to `/snes` on the exFAT volume. Names that start with `.` are not listed. Optional settings file: `/snes/snes9x.cfg` (section 6).

The minimal ROM (`MIN=1`) links no SNES code; its launch menu gains the item SNES (14 bytes more in `appmenu.o`, measured with the MIN flags).

## 3 Changes to the Core

`patches/snes9x-1.39-seattle.patch`, seven files; the patch applied to the unpacked `s9xs139.zip` reproduces the core tree of the build byte for byte.

| File | Change | Reason |
|---|---|---|
| `dsp1.h` | `extern struct SDSP1 DSP1;` moved inside the `START_EXTERN_C` block | `globals.cpp` defines `DSP1` inside `extern "C"`; GCC 12 rejects the C++-linkage declaration that precedes it (error: conflicting declaration with 'C' linkage) |
| `memmap.h` | `MAX_ROM_SIZE` takes the value of `S9X_MAX_ROM_SIZE`, default `0x600000` | The unmodified ROM buffer is 6 MB + 33 KB; 8 MB DRAM holds the disk build, the core's 2.3 MB of tables and caches and at most a 2.5 MB buffer |
| `memmap.cpp` | With `S9X_MAX_ROM_SIZE` below `0x412000`, `C4RAM` is placed at `ROM + MAX_ROM_SIZE - 0x10000 - 8192` | The unmodified address `ROM + 0x400000 + 0x10000` lies beyond a smaller buffer. The new place is below the 64 KB SA-1 and S-DD1 scratch area at the top of the buffer; C4 cartridges are at most 2 MB |
| `gfx.h` | `COLOR_ADD`, `COLOR_ADD1_2` flag the pixel (bit 15) instead of adding while `s9x_vmath` is set; declarations of `s9x_strip`, `s9x_direct`, `S9xFillLine`, `S9xCopyLine` | colour math on the Voodoo (`colormath voodoo`); the drawing path of section 10 |
| `gfx.cpp` | `S9xUpdateScreen`: the sub screen preset to the fixed colour for `colormath voodoo`; strips (`s9x_strip`); backdrop passes by `S9xComposeBack`; the sub screen drawn into the main screen (`s9x_direct`); depth and back-colour fills by `S9xFillLine`, `S9xCopyLine` | section 10 |
| `tile.cpp` | `DrawTile16`, `DrawClippedTile16` with locals and four depth bytes per test | section 10 |
| `soundux.cpp` | `MixStereo`: envelope error, envelope rate and sample counter in locals, written to the channel before the envelope and sample steps and after the loop | section 11.2 |

Build options of the core (Makefile `SNESDEFS`): `LSB_FIRST VAR_CYCLES CPU_SHUTDOWN SPC700_SHUTDOWN SPC700_C EXECUTE_SUPERFX_PER_LINE`, the C CPU (its opcode handlers serve the assembler loop of section 9 and run alone with `cpu c` or an SA-1 cartridge), SPC700, Super FX and C4 cores, no debugger, no zlib, no unzip, no netplay. Compiler flags `-O2 -fno-exceptions -fno-rtti`; no libstdc++ or libsupc++ is linked (the toolchain carries a soft-float libsupc++ only). The core's `malloc` and `free` are mapped to the platform arena by `-Dmalloc=s9x_malloc -Dfree=s9x_free`. Core files compiled: cpuops, cpuexec, sa1cpu, spc700, soundux, apu, fxinst, fxemu, c4, c4emu, cpu, sa1, sdd1, tile, srtc, gfx, memmap, snaporig, clip, dsp1, ppu, dma, snes9x, snapshot, cheats, cheats2, data, globals.

## 4 Platform Layer

| Function | Implementation |
|---|---|
| 65C816 loop | `s9x_main_loop` (`s9x_cpu.cpp`): `cpu65.S` (section 9) with `cpu asm` (default) and no SA-1, else the core's `S9xMainLoop` |
| Core interface | `s9x_port.h`: the C-linkage interface through the core headers `snes9x.h`, `soundux.h`, `apu.h`; C++-linkage functions (CMemory members, `S9xSetSoundMute`, `S9xSetPlaybackRate`, `S9xOpenSoundDevice`, `S9xAutoSaveSRAM`, `_makepath`, `_splitpath`, `operator new[]`, sized `operator delete`) by their Itanium ABI symbols; the leading members of `struct SGFX` and `struct InternalPPU` |
| Video | Mode from the ROM menu's word at KSEG1 0xA07F0024 (bits 31:16 0x564D 'VM'; bits 7:0: 1 = 512 x 256 54 Hz, 2 = 512 x 240 59.98 Hz, 3 = 384 x 240 59.9 Hz, 4 = 512 x 384 57 Hz, 0 or no tag = the DIP choice), `voodoo_video_init` unchanged. 16-bit RGB565 rendering into DRAM. Default (`aspect fill`): the frame is written to TMU 0 as rows 0 to h-1 of a 256 x 256 RGB565 texture (plus row h repeated for the bilinear filter) by GT-64010 DMA channel 0 while the emulation continues (`texture dma`, section 11.1) or by 32-byte block writes of the CPU (`texture cpu`, `voodoo_lfb_lines`, 3,584 lines for 224 rows), then two bilinear-filtered textured triangles (`tri_draw`) cover the screen; the TMU scales (2 x horizontally at 512, 1.5 x at 384; 224 lines to 240, 256 or 384). `aspect integer`: full width, integer vertical scale, black borders. `aspect 1:1`: `blit.S` copies the frame unscaled and centred through the LFB. Swap at the next vertical retrace |
| Sound | Core mixer at 31,250 frames/s, 16-bit stereo, the rate of `dsp/stream.asm`; no resampling. Ring of 8,192 stereo frames, filled once per emulated frame (frame count steered to a 2,048-frame level), drained by the GT-64010 timer 0 interrupt at 1 kHz into the I/O ASIC sound FIFO while it is below half full (the NES transport) |
| Timing | `S9xSyncSpeed` of `unix/unix.cpp` on CP0 Count (75 MHz): automatic frame skip (at most 10 frames in a row) or fixed skip, paced to `Settings.FrameTime` (16,667 us NTSC, 20,000 us PAL) |
| Input | IN1 and SYSTEM of the I/O ASIC, once per emulated frame; map in section 5 |
| Files | ROM images from `/snes`; battery RAM `/saves/<name>.srm` (core `LoadSRAM`/`SaveSRAM` through newlib and FatFs), loaded at start and written at game end (`autosave N` writes N s after a change); IPS and cheat files beside the image |
| Memory | Blocks of 64 KB and more from an arena: the rest of the sbrk heap up to `HEAP_LIMIT` 0x80600000 and the image area 0x80600000-0x807AFFFF up to the stack floor 0x807B0000; a 256 KB reserve of the C library heap for smaller blocks |
| Fatal errors | `irq_install` and `guru.c` (with `sgrab.c`) as in the Quake build; `crashdump_write` stays a weak reference; `S9xExit` calls `guru` |
| Leave | P1 buttons 1, 2, 3 and Start 1 held 0.5 s (30 emulated frames): sound board reset to its boot ROM, battery RAM written, return to the ROM menu (the NES port's quit path and switches). ESC on the serial line ends the game and returns to the game list |
| Report | UART line every 600 emulated frames, one character per frame; the same values in `snes_stats` |

## 5 Button Map

JAMMA inputs through the I/O ASIC, active low (MAME 0.289 `seattle.cpp`). MAME names the buttons of the blitz99 driver "A", "B" and "Turbo".

| Cabinet input | Register bit | SNES pad 1 (`pads 1`, default) | `pads 2` |
|---|---|---|---|
| P1 stick | IN1 0x0001-0x0008 | D-pad | pad 1 D-pad |
| P1 button 1 (MAME "P1 A") | IN1 0x0010 | B | pad 1 B |
| P1 button 2 (MAME "P1 B") | IN1 0x0020 | A | pad 1 A |
| P1 button 3 (MAME "P1 Turbo") | IN1 0x0040 | Y | pad 1 Y |
| Start 1 | SYSTEM 0x0004 | Start | pad 1 Start |
| P2 button 1 | IN1 0x1000 | X | pad 2 B |
| P2 button 2 | IN1 0x2000 | L | pad 2 A |
| P2 button 3 | IN1 0x4000 | R | pad 2 Y |
| Start 2 | SYSTEM 0x0020 | Select | pad 2 Start |
| P2 stick | IN1 0x0100-0x0800 | not used | pad 2 D-pad |

With `pads 2`, X, L, R and Select are not reachable. Game list: the first game is selected at entry, with the item "< back" (return to the ROM menu) above it; stick moves, button 1 or Start 1 selects; on the serial line `w`, `s`, Enter.

## 6 Settings (`/snes/snes9x.cfg`)

One `name value` per line; `#` starts a comment line; a missing file or line keeps the default.

| Name | Values | Default | Effect |
|---|---|---|---|
| `frameskip` | `auto`, 0-9 | `auto` | automatic skip, or N frames skipped after each rendered frame |
| `maxskip` | 0-n | 10 | longest automatic skip |
| `sound` | `on`, `off` | `on` | mixing and output; the SPC700 runs either way |
| `apu` | `on`, `off` | `on` | `off` stops the SPC700 (`Settings.APUEnabled`); games that wait on it stop |
| `rate` | 31250, 15625 | 31250 | mixing rate; 15,625 writes each frame twice |
| `stereo` | `on`, `off` | `on` | |
| `echo` | `on`, `off` | `on` | `Settings.DisableSoundEcho` |
| `interpolate` | `on`, `off` | `off` | `Settings.InterpolatedSound` |
| `transparency` | `on`, `off` | `on` | `Settings.Transparency` |
| `aspect` | `fill`, `integer`, `1:1` | `fill` | TMU-scaled quad over the screen; TMU-scaled, integer vertical scale, borders; LFB copy unscaled |
| `blit` | `burst`, `single` | `burst` | cache-line bursts or single uncached LFB words |
| `pads` | 1, 2 | 1 | section 5 |
| `autosave` | seconds | 0 | battery RAM written N s after a change; 0: at game end |
| `profile` | `on`, `off` | `off` | program-counter histogram at 1 kHz (128-byte buckets), the 400 largest buckets printed at game end (`prof` lines), and 8-byte buckets over `cpu65.S` (80 `fprof` lines) |
| `fprof` | address (hex) | 0 | with `profile on`: start of the 8-byte-bucket window (240 `fprof` lines); 0: the window over `cpu65.S` and `spc700.S` |
| `cpu` | `asm`, `c` | `asm` | 65C816 loop: `cpu65.S` or the core's `S9xMainLoop` (section 9) |
| `spc` | `asm`, `c` | `asm` | with `cpu asm`: SPC700 opcodes in `spc700.S` or by the core's functions of `spc700.cpp` (section 9.6) |
| `tile` | `asm`, `c` | `asm` | `DrawTile16` and `DrawClippedTile16`: `tile16.S` or the functions of the core's `tile.cpp` |
| `check` | N | 0 | every N emulated frames a line `snes: check F ram R vram V io I apu P A .. X .. Y .. S .. D .. DB .. PB .. PC .. P .. cyc C v L apc Q acyc K`: CRC-32 of WRAM (128 KB), VRAM (64 KB), the I/O register image (FillRAM 0x2000-0x5FFF) and the SPC700 RAM (64 KB), the 65C816 and SPC700 registers and cycle counters |
| `cpuc` | `LO-HI` (hex) | none | opcodes LO to HI run by the core's C handlers inside `cpu65.S` (test setting) |
| `fcrc` | N | 0 | every N emulated frames a line `snes: fcrc F n R crc X`: R rendered frames so far, X the CRC-32 (polynomial 0xEDB88320) chained over the rows of every rendered frame (256 x 224 RGB565, 114,688 bytes a frame) |
| `direct` | `on`, `off` | `on` | backdrop-only addition with back colour 0: the sub screen drawn into the main screen (section 10) |
| `pal8` | `on`, `off` | `on` | frames without per-pixel colour math drawn as 8-bit palette indices, the colours by the TMU palette (section 10.7) |
| `vmode` | 0-4 | 0 | video mode of the run: 1 512x256 (54 Hz), 2 512x240 (59.98 Hz), 3 384x240, 4 512x384; 0: the mode the ROM menu requests (Settings, VIDEO MODE), 512x240 when it names none |
| `late` | 0-400 | 75 | `frameskip auto`: the next frame is skipped only when the schedule is more than N percent of a frame time behind; a smaller delay is made up by the following frames |
| `strip` | N | 16 | `S9xUpdateScreen` renders its lines in strips ending on multiples of N; 0: one pass |
| `fill` | `cde`, `cpu` | `cde` | depth and back-colour line fills: whole cache lines allocated by Create Dirty Exclusive (`draw.S`), or word stores |
| `texture` | `dma`, `cpu` | `dma` | frame texture written by GT-64010 DMA channel 0 (section 11.1) or by CPU block writes; with colour math on the Voodoo in the frame always by the CPU |
| `vcrc` | N | 0 | every N shown frames a line `snes: vcrc K crc X reads R`: CRC-32 of the displayed Voodoo buffer (512 x screen height, RGB565, LFB reads repeated until two agree, R reads); about 0.1 s each (test setting) |
| `scrc` | N | 0 | every N emulated frames a line `snes: scrc F n S crc X`: S stereo frames mixed so far, X the CRC-32 chained over the mixed samples; any N above 0 mixes a fixed 520 stereo frames per emulated frame, independent of the FIFO level (test setting) |

## 7 Sizes

| Image | Text | Data | BSS | Payload |
|---|---|---|---|---|
| Disk build without SNES (same tree) | 597,660 | 15,948 | 472,400 | 613,620 bytes |
| Disk build with SNES (`SNES_MAX_ROM` 0x280000) | 1,179,888 | 23,972 | 1,264,240 | 1,203,876 bytes, CRC32 d1e1b53e |
| Disk build with SNES and `cpu65.S` (`SNES_MAX_ROM` 0x260000, `EXTRA=-DUART_DIV=0x00u`), board runs of section 9.4 | 1,287,184 | 36,648 | 1,473,280 | 1,323,860 bytes, CRC32 01aba28f; arena at game start 4,808 KB used, 67 KB free |
| Disk build with SNES, `cpu65.S`, `spc700.S` and the drawing path of section 10 (same options), board runs of section 10.4 | 1,303,040 | 37,688 | 1,480,992 | 1,340,756 bytes, CRC32 9224e2c8; arena at game start 4,808 KB used, 43 KB free |
| Disk build with the texture DMA and the mixer of section 11 (same options) | 1,306,528 | 37,704 | 1,481,152 | 1,344,260 bytes, CRC32 13fdda77; arena at game start 4,808 KB used, 43 KB free |
| `dboot` limit | | | | 1,769,472 bytes (0x1B0000) |

| Memory at game start (MAME) | Value |
|---|---|
| Arena used (tables, caches, ROM buffer 0x288200, screen buffers) | 4,936 KB |
| Arena free | 263 KB |
| Largest ROM image | 2,621,440 bytes + 512-byte copier header (20 Mbit); larger files are refused with a message |

## 8 Test Results (MAME 0.289 with the project patch, driver blitz99)

MAME executes the R5000 without a cache model and without PCI bus timing; its instruction rate is not the board's. Every time and rate in this section is a MAME value and is not a measurement of the board. The board is untested.

Set-up: boot ROM `seattle_monitor21_27C4001.bin` (its NES launch; the Lua script replaces the request word "NES " at 0x007F0020 by "SNES" before the disk build reads it), disk image with the disk build at LBA 0x3EE080 and a 64 MB exFAT volume at LBA 0x3F0000, CHD with CHS 4227/16/63, `-video none`, one instance, snapshots by `manager.machine.video:snapshot()`.

| Test | Result |
|---|---|
| Launch: request "SNES", game list, game start | 14 of 14 runs; `menu: 1 SNES games in /snes` (2 with the SRAM test image) |
| ROM recognition | `"240P TEST SUITE SNES" [checksum ok] LoROM, 4Mbits, Type: ROM only, Mode: 20, TV: NTSC` |
| Video, 512 x 256 | menu, Sound Test and Scroll Test screens, 256 x 224 centred 1:1 (figures in section 8.1) |
| Video, 512 x 384 | Scroll Test centred 1:1 |
| Sound to the FIFO | 62,488-62,545 words/s (31,244-31,272 frames/s); ring peak 1,461 in Sound Test |
| Sound at the DAC (MAME WAV, 48 kHz) | beeps every 2.1 s (one Sound Test press per 120 frames), peak 1,818 of 32,767 at 31,250 stereo; peak 1,682 at 15,625 mono |
| Quit combination | 10 of 10 runs that hold it return to the ROM launch menu |
| Battery RAM | 2,048-byte `/saves/sram.srm` written at game end (image with the header patched to 2 KB S-RAM); a pattern file placed before the start is read and written back byte-identical |
| Fatal error | an address-error injection (ICPU.S9xOpcodes overwritten from Lua) ends on the guru.c screen, "Guru Meditation #0000000A.B6000000", "No memory dump in this build." |
| ESC on the serial line, PAL timing, Super FX, SA-1, C4, DSP-1, `pads 2`, `autosave` | untested |
| Commercial games | untested (none on the test host) |

### 8.1 Screen captures (MAME)

| Screen | File (scratch area of the test host) |
|---|---|
| Test suite menu, 512 x 256 | `snes/snap/blitz99/0004.png` |
| Sound Test, 512 x 256 | `snes/snap-run2/blitz99/0002.png` |
| Scroll Test, 512 x 256 | `snes/snap-run3/blitz99/0001.png` |
| Scroll Test, 512 x 384 | `snes/snap-v-def384/blitz99/0001.png` |
| Fatal-error screen | `snes/snap-crash2/blitz99/0001.png` |

### 8.2 Frame timing (MAME, 600-frame report)

| Configuration (Scroll Test unless stated) | Emulated fps | Shown fps | Emulation, rendered frame | Emulation, skipped frame | Blit (of it: swap wait) | Mixing | Idle |
|---|---|---|---|---|---|---|---|
| Defaults, 512 x 256 | 59.9 | 54.0 | 12,494 us | 2,136 us | 1,608 us (1,092) | 348 us | 3,391 us |
| `transparency off` | 59.9 | 54.0 | 12,493 us | 2,136 us | 1,605 us (1,090) | 348 us | 3,393 us |
| `sound off` | 60.0 | 54.1 | 12,441 us | 2,125 us | 1,797 us (1,284) | 0 | 3,594 us |
| `frameskip 0` | 54.1 | 54.1 | 12,494 us | - | 5,628 us (5,113) | 351 us | 0 |
| Defaults, 512 x 384 | 59.9 | 56.8 | 12,494 us | 2,135 us | 1,143 us (628) | 348 us | 3,273 us |
| Sound Test, `rate 15625`, `stereo off`, `blit single` | 59.9 | 54.0 | 10,918 us | 2,034 us | 2,412 us (1,873) | 236 us | 4,208 us |

The shown rate is bound by the swap at MAME's refresh of the mode (54.1 frames/s at 512 x 256, `frameskip 0`), not by emulation time. The copy alone (blit minus swap wait) is 0.5 ms in MAME; MAME does not model PCI write cost, so the board value is untested.

### 8.3 Where the time goes (MAME, 1 kHz program-counter samples, defaults, menu then Scroll Test, 36,383 samples)

| Function | Share |
|---|---|
| `S9xSyncSpeed` (throttle wait) | 21.0 % |
| `DrawTile16` (tile renderer, tile.cpp) | 42.9 % |
| `voodoo_swaps_pending` (wait for the previous swap) | 6.0 % |
| `S9xUpdateScreen` | 4.3 % |
| `blit.S` copy | 2.7 % |
| `OpCB` (65C816 WAI) | 2.6 % |
| `DrawBackground` | 1.5 % |
| `S9xMixSamplesO` (sound mixing) | 0.8 % |
| `S9xMainLoop` | 0.8 % |

In this workload the PPU renderer takes about 9 of the 12.5 ms of a rendered frame (rendered against skipped frame), the 65C816 waits in WAI, and the SPC700 and the mixer take under 0.4 ms. Commercial games load the 65C816 and SPC700 far more than the test suite; their cost and the board's cost with cache misses and PCI writes are untested.

### 8.4 Super Mario World (USA) and the TMU-scaled picture (merged disk build, MAME, windowed)

| Item | Result |
|---|---|
| Hang reported on the board after "menu: 1 SNES games in /snes" and Enter | reproduced in 2 of 2 runs: the list opened on "< back", so the first Enter returned through the reset vector; the ROM re-initialises the UART at 9,645 baud, so a host at 520,833 baud shows nothing until the ROM menu. The list now opens on the first game and "< back" prints `menu: back to the ROM menu` |
| Start from the list with an immediate Enter or button 1 | 3 of 3 runs start the game |
| Title screen | reached in every run, ROM info `"SUPER MARIOWORLD" [checksum ok] LoROM, 4Mbits, Type: ROM+RAM+BAT, S-RAM: 2Kb` |
| Frame rate, title and attract demo | 59.9 to 60.0 emulated frames/s; 30.4 to 45.3 shown; emulation 14.4 to 22.3 ms a rendered frame, 5.9 to 6.4 ms a skipped frame |
| Sound | 62,495 to 62,538 FIFO words/s; ring peak 18,054; MAME WAV peak 18,700, sound in 55 of the 120 s of the run |
| Video modes (word 1 to 4 written from Lua) | 512 x 256, 512 x 240, 384 x 240, 512 x 384 filled; `aspect integer` at 512 x 384: 224 lines centred with borders; `aspect 1:1` unchanged |
| Texture download per rendered frame (224 rows) | 506 to 507 us in MAME |
| Quad set-up and swap request | 18 us in MAME |
| Board cost | untested; at the 510 ns per 32-byte line measured for LFB block writes (voodoo.c) the download of 3,600 lines would take about 1.8 ms |
| Battery RAM | `/saves/Super Mario World (USA).srm` (2,048 bytes) written at quit; a pattern file placed before the start read into S-RAM (first bytes 03 0a 11 18 at the S-RAM address after load) and written back byte-identical |
| Arena at game start | 4,936 KB used, 15 KB free (the merged disk build has a larger BSS); a further 15 KB of BSS growth makes every game fail to start with the message "N bytes requested, M free" unless `SNES_MAX_ROM` is lowered |

## 9 65C816 Loop in Assembler (`cpu65.S`)

### 9.1 Function

| Item | Implementation |
|---|---|
| Loop | `s9xa_run`: `S9xMainLoop` of `cpuexec.cpp` (LSB_FIRST, VAR_CYCLES, CPU_SHUTDOWN, no debugger, no SA-1). Returns at `SCAN_KEYS_FLAG` with the state written to `CPU`, `Registers`, `ICPU`; the code after the loop runs in `s9x_main_loop` as in the core |
| Registers across opcodes | s0 `CPU.PC` (host pointer), s1 `CPU.Cycles`, s2-s4 A, X, Y, s5-s7 `_Zero`, `_Negative`, `_Carry`, s8 `&Registers`, gp `&CPU`, t1 `ICPU.ShiftedDB`, t4 `CPU.PCBase`, t7 `CPU.MemSpeed`, t9 jump table of the M/X mode, t8 the loop limit, t5/t2 base and speed of bank 0 0000-1FFF |
| Dispatch | one jump table of 256 words per mode (M0X0, M0X1, M1X0, M1X1; emulation mode M1X1 as `S9xFixCycles`), 10 instructions per opcode |
| Loop limit | the fast path runs while `Cycles < NextEvent` and `CPU.Flags` is 0; otherwise the H-blank check and the interrupt step run in the order of `S9xMainLoop`. The limit is recomputed after every call of C code, the only code that changes these values. The SPC700 runs as section 9.6 describes |
| Opcodes in assembler | all opcodes in all modes except: BRK, COP, RTI, WAI, STP, XCE, SED, REP/SEP in emulation mode, ADC/SBC with the D flag set, branches while the SPC700 is off (`CPU.BranchSkip`); these run the core's C handler (`op_c`) with the state written back and read again |
| Exactness | each handler performs the core handler's memory accesses in the same order with the same `CPU.Cycles` additions before each access and the same `CPU.WaitAddress` updates (idle-loop detection); `CPUShutdown` and its SPC700 loop are step-for-step copies |
| Memory | `Memory.Map` / `WriteMap`, `MemorySpeed`, `BlockIsRAM` as `getset.h`; addresses below 0x2000 use the bank 0 RAM base directly when `s9x_cpu.cpp` finds blocks 0 and 1 mapped to one RAM for reading and writing with one speed (checked at each loop entry; only SA-1 code changes that part of the map). Map entries below `MAP_LAST` (I/O, SRAM, special chips) call the `getset.h` functions with PC, Cycles and PCAtOpcodeStart written to `CPU` first |
| C calls | gp is set to the linker's `_gp` for every call of C code (newlib reaches `_impure_ptr` gp-relative) and to `&CPU` after it |
| Structure offsets | `s9x_offs.h`, generated from `s9x_offs.cpp` compiled with `-S` (Makefile rule) |
| Size | `cpu65.o` text 36 KB, data 4 KB (jump tables) |
| Opcode counts | build with `CPU65FLAGS=-DS9XA_HIST`: opcode counts per mode, the opcodes run by C handlers, C calls, H-blank events, interrupt passes, SPC700 opcodes and shutdowns, printed at game end |

### 9.2 Correctness

| Test | Result |
|---|---|
| MAME, Super Mario World title and attract demo, `check 60`, `frameskip 1`, `sound off`, 150 s | 126 check lines (frames 60-7,560) of `cpu asm` equal to those of `cpu c` |
| MAME, `cpu asm` with `cpuc 00-ff` (every opcode by the C handlers inside `cpu65.S`) | check lines equal to `cpu c` |
| Board, `check 120`, `frameskip 1`, `sound off`, 40 s each | 10 common check lines (frames 120-1,440) equal between `cpu asm` and `cpu c`, and equal to the MAME `cpu c` lines of the same frames |
| Other cartridges (Super FX, DSP-1, C4, S-DD1, HiROM), PAL timing | untested |

### 9.3 Opcode statistics (MAME, Super Mario World, 50 s, `S9XA_HIST` build)

| Quantity | Per emulated frame |
|---|---|
| 65C816 opcodes | 6,700 (20,151,036 in 3,000 frames) |
| of them by C handlers | 1 (RTI; JML [abs] before it was added) |
| SPC700 opcodes | 3,200 |
| H-blank events | 477 |
| CPUShutdown with `PC == WaitAddress` | 530 |
| C calls from opcodes (I/O, S9xSetPCBase outside plain memory) | 263 |

Most frequent opcodes: BEQ (2,222,629), LDA dp (1,917,001), LDA abs,X (588,547), BNE in M1X0 (553,494), ASL A (517,355), STA abs (490,761).

### 9.4 Board timing (Super Mario World attract demo, defaults: `frameskip auto`, sound on, TMU fill, 50 s, same disk build, 10-s reports 2 to 4)

| Loop | Rendered frame (emulation and drawing) | Skipped frame | Frames shown per second |
|---|---|---|---|
| `cpu c` (`S9xMainLoop`) | 36,435 / 37,365 / 30,454 us | 9,350 / 10,293 / 9,274 us | 10.4 / 8.2 / 13.9 |
| `cpu asm` (`cpu65.S`) | 33,567 / 34,045 / 25,559 us | 6,357 / 6,808 / 6,228 us | 16.4 / 15.2 / 22.6 |

Every report: 59.8-60.1 emulated frames per second; video 2,412-2,790 us per rendered frame; mixing 1,150-2,294 us per frame.

### 9.5 Where the time goes on the board (1 kHz program-counter samples, the runs of section 9.4)

| Part | `cpu c` (48,021 samples) | `cpu asm` (47,436 samples) |
|---|---|---|
| 65C816: loop, handlers, memory access, SPC700 dispatch | 42.1 % | 23.9 % |
| Drawing (tile renderer, `S9xUpdateScreen`, clearing) | 28.7 % | 44.8 % |
| Sound mixing and FIFO output | 10.3 % | 10.6 % |
| SPC700 opcode functions (`spc700.cpp`) | 6.2 % | 6.0 % |
| DMA and HDMA | 4.2 % | 4.3 % |
| Frame upload and pacing | 2.5 % | 4.8 % |
| Other | 5.9 % | 5.6 % |

Inside the 23.9 % of `cpu asm` (128-byte buckets): H-blank call and SPC700 step at the loop top 5.4 %, CPUShutdown with its SPC700 loop 1.6 % (both call one C function per SPC700 opcode and reload the loop registers after each step), dispatch 4.8 %, opcode handlers, memory access and C calls the rest.

### 9.6 SPC700 loop in assembler (`spc700.S`)

| Item | Implementation |
|---|---|
| Scheduling | `S9xMainLoop` runs the SPC700 up to `CPU.Cycles` before every 65C816 opcode. `cpu65.S` writes `CPU.Cycles` of each loop pass into `s9xa_ring` (2 instructions) and runs the SPC700 over the recorded limits (`s9xa_spc_sync`) before every call of C code (I/O, DMA, H-blank, interrupts, the core's opcode handlers), before CPUShutdown and at the end of the frame. The two processors meet only through C code (APU ports in `S9xGetPPU`/`S9xSetPPU`, DMA, the SPC700 timers and the cycle rebase in `S9xDoHBlankProcessing`), so both execute the same opcodes against the same values |
| Exactness of the limits | while `IAPU.APUExecuting` stays set, running against each recorded limit in turn equals running against the last one. Only an SPC700 opcode clears it between two runs (APUShutdown of a taken branch, SLEEP, STOP); the run then finishes the limit that opcode ran under (the first recorded limit at or above `APU.Cycles` at its start) and nothing after it, as the core does. A loop pass is at most 228 opcodes (H_Max / ONE_CYCLE) from the next event, below the 1,024 entries of the ring |
| Registers | t0 IAPU.PC (host pointer), t1-t4 A, X, Y, S, t5 `_Zero`, t6 `_Carry`, t7 `IAPU.DirectPage`, t8 `APU.Cycles`, t9 the limit, a3 `IAPU.RAM`; `APURegisters.P`, `_Overflow`, `WaitAddress1/2`, `WaitCounter` stay in memory |
| Opcodes in assembler | 216 of 256: all moves, OR/AND/EOR/CMP/ADC/SBC in all modes, INC/DEC, shifts and rotates, SET1/CLR1, BBS/BBC, the branches with APUShutdown, CBNE, DBNZ, CALL, PCALL, RET, JMP, PUSH/POP, flag operations, MOVW/INCW/DECW/ADDW/SUBW/CMPW, MUL, XCN. The others (DIV, DAA, DAS, BRK, RETI, SLEEP, STOP, TCALL, TSET1/TCLR1, the bit operations on absolute addresses, JMP [abs+X]) run the core's function with the state written back |
| Memory | `S9xAPUGetByteZ`, `S9xAPUSetByteZ`, `S9xAPUGetByte`, `S9xAPUSetByte` of `apumem.h`: RAM inline, registers 0xF0-0xFF with the port, counter, timer-target, IPL-ROM and WaitAddress rules inline; the DSP (0xF3) and control (0xF1) registers call `S9xGetAPUDSP`, `S9xSetAPUDSP`, `S9xSetAPUControl` |
| Not written | the core's scratch variables of `spc700.cpp` (`IAPU.Address`, `IAPU.Bit`, `Work8`, `Work16`, `W1`, `Int16`), which no code reads between opcodes |
| Size | `spc700.o` text 11 KB, data 1 KB (jump table) |

| Test | Result |
|---|---|
| MAME, `check 60`, `frameskip 1`, `sound off`, 150 s, `spc asm` and `spc c` | 126 check lines (frames 60-7,560, SPC700 RAM CRC and registers included) equal to `cpu c` |
| Board, `check 120`, `frameskip 1`, `sound off`, 40 s | 10 common check lines (frames 120-1,440) equal to `cpu c` and to MAME |
| SPC700 opcodes executed (MAME, 50 s, `S9XA_HIST`) | 9,598,822 with `spc700.S`, the same count as the core's functions |

Board timing, the conditions of section 9.4, one disk build (1,336,452 bytes, CRC32 940eb472), 10-s reports 2 to 4:

| Configuration | Rendered frame | Skipped frame | Frames shown per second |
|---|---|---|---|
| `cpu c` | 36,410 / 37,491 / 30,267 us | 9,460 / 10,429 / 9,333 us | 10.2 / 8.0 / 13.9 |
| `cpu asm`, `spc c` (ring scheduling, the core's SPC700 functions) | 34,721 / 35,096 / 26,088 us | 7,493 / 7,905 / 7,330 us | 14.1 / 13.0 / 20.3 |
| `cpu asm`, `spc asm` | 32,862 / 33,370 / 25,184 us | 5,653 / 6,052 / 5,594 us | 17.9 / 16.7 / 23.8 |

Profile shares of the same runs (1 kHz samples, about 47,600 each): 65C816 and SPC700 loops 42.9 % with `cpu c` (plus SPC700 opcode functions 5.7 %), 25.4 % with `cpu asm`, `spc asm` (SPC700 opcode functions 0.4 %, the opcodes left to the core); drawing 28.2 % and 48.2 %; sound mixing 10.4 % and 10.5 %; DMA/HDMA 4.3 % and 4.1 %. Per emulated frame the two loops take 8.1 ms with `cpu c` and 4.3 ms with `cpu asm`, `spc asm` (samples / frames).

## 10 Drawing Path

The Snes9x 1.39 C renderer (`gfx.cpp`, `tile.cpp`), changed in place by the core patch (section 3), with two R5000 assembly routines in `bringup/snes/draw.S`. Every change gives the pixels of the unmodified renderer (section 10.2).

### 10.1 Function

| Part | Implementation |
|---|---|
| Tile renderer | `DrawTile16`, `DrawClippedTile16` (main and sub screen without colour math on the layer): `GFX.ScreenColors`, `GFX.Z1`, `GFX.Z2` in registers (the byte stores to the depth buffer made the compiler reload them for every pixel). Four depth bytes are compared with Z1 in one word: byte k of `((Z1 - 1) x 0x01010101 \| 0x80808080) - depth` has bit 7 set exactly when depth byte k is below Z1 (depth values are at most 49, below 128, so no borrow crosses a byte). A group of four pixels with no depth below Z1 is skipped; with all four below Z1 and four non-zero pixels it is written without per-pixel tests (four palette loads and stores, one unaligned word store of Z2) |
| Backdrop passes | the per-pixel loops of `S9xUpdateScreen` after the main screen (addition, subtraction, halved, the sub-screen copy, the back colour): `S9xComposeBack` reads four main-screen depth bytes as one aligned word and skips four covered pixels; the value of an uncovered pixel comes from a functor with the expression of the original loop |
| Sub screen into the main screen (`direct on`) | CGADSUB 0x20 (addition of the sub screen to the backdrop only, not halved), back colour 0, no main-screen colour window, no hi-res, no `colormath voodoo`: each line is filled with the backdrop value (fixed colour inside the sub-screen colour window, 0 outside; a template line copied by `S9xCopyLine`), the main-screen depth line cleared, the main screen drawn, then the sub screen drawn into the same screen and depth buffer. Main-screen depths are 34 and above, sub-screen depths 2 to 17, so the depth test keeps every main-screen pixel and the sub-screen layers fill only the rest. The original path renders the sub screen into its own buffer, clears a sub depth buffer and composes every pixel afterwards; Super Mario World uses this mode in every frame of the attract demo (CGADSUB 0x20, TM 0x15, TS 0x02, one sub-screen colour window) |
| Line fills | depth clears and back-colour fills of `S9xUpdateScreen` by `S9xFillLine`, `S9xCopyLine` (`s9x_seattle.c`): with `fill cde` and 32-byte aligned lines, `s9x_fill_lines` and `s9x_copy_lines` (`draw.S`) allocate each 32-byte data-cache line by Create Dirty Exclusive (cache op 0x0D, as `blit.S`) and write it whole; otherwise word stores |
| Strips | `S9xUpdateScreen` renders its line range in strips ending on multiples of `strip` (16): every pass of the original acts on a pixel from its own line and from state constant within the call, so the strips give the pixels of one pass |
| Frame check | `fcrc N`: CRC-32 of the rows of every rendered frame, chained, printed every N emulated frames (section 6) |

### 10.2 Correctness (Super Mario World attract demo, `check` and `fcrc`, `frameskip 1`, `sound off`)

| Test | Result |
|---|---|
| MAME, 90 s, each step of section 10.3 against the unmodified renderer | 65 `fcrc` lines (1,950 rendered frames) and 65 `check` lines equal |
| MAME, 90 s, `direct off`, `strip 0`, `fill cpu` | equal (the general path alone) |
| MAME, 120 s, final build against the unmodified renderer, both on the SPC700 assembler loop | 96 `fcrc` lines (2,880 rendered frames) equal |
| Board, 40 s each, final build against the unmodified renderer (same tree otherwise) | 12 common `fcrc` lines (frames 120-1,440, 720 rendered frames) and 12 `check` lines equal; the final build's 19 `fcrc` lines (to frame 2,280, 1,140 rendered frames) equal to the MAME lines of the same frames |
| Fault injection (MAME) | four pixels of a group written at the wrong offset changed the `fcrc` line of frame 86 onward |
| Other games, modes 2-7, mosaic, colour windows on the main screen, subtraction, hi-res | untested on the changed passes; `direct` is limited to the mode above, the other modes take the general path |

### 10.3 Board timing per step (attract demo, defaults: `frameskip auto`, sound on, TMU fill; 40 s, 10-s reports 2 and 3; tree of section 9.4, SPC700 by the core's C functions)

| Step | Rendered frame | Skipped frame | Frames shown per second |
|---|---|---|---|
| Unmodified renderer | 33,715 / 34,259 us | 6,549 / 7,041 us | 16.1 / 14.7 |
| Tile renderer | 27,612 / 28,259 us | 6,419 / 6,913 us | 20.5 / 18.8 |
| Backdrop passes by depth words | 25,822 / 26,377 us | 6,254 / 6,698 us | 22.4 / 20.7 |
| Line fills by cache-line allocation (`fill cde`), alone | 25,912 / 26,509 us | 6,421 / 6,920 us | 22.0 / 20.2 |
| Sub screen into the main screen, sub screen first, backdrop pass after | 21,305 / 21,352 us | 6,131 / 6,568 us | 28.4 / 27.1 |
| Backdrop value filled first, no backdrop pass | 19,572 / 19,668 us | 6,321 / 6,802 us | 30.5 / 29.1 |
| Main screen first, sub screen after | 17,899 / 18,171 us | 6,295 / 6,752 us | 33.7 / 32.0 |
| `strip 16` | 17,427 / 17,791 us | 6,317 / 6,736 us | 34.5 / 32.7 |

Strips measured at each step: 16 lines 0.5-1.5 ms faster than one pass, 8 lines no faster; cache-line allocation of the main and sub-screen lines before drawing in the general path no faster (not kept). Video (texture download and quad) 2,382-2,598 us per rendered frame throughout, about 170 us more with strips.

### 10.4 Board timing, final tree (with the SPC700 loop of section 9.6), 50 s, 10-s reports 2 to 4

| Renderer | Rendered frame | Skipped frame | Frames shown per second | Rendered minus skipped |
|---|---|---|---|---|
| Unmodified | 32,995 / 33,407 / 25,272 us | 5,713 / 6,119 / 5,630 us | 17.7 / 16.6 / 23.7 | 27.3 / 27.3 / 19.6 ms |
| Section 10 (defaults) | 16,871 / 17,141 / 14,766 us | 5,624 / 5,973 / 5,624 us | 36.5 / 35.4 / 40.3 | 11.2 / 11.2 / 9.1 ms |

Every report 59.9-60.0 emulated frames per second; video 2,411-2,644 us (unmodified) and 2,606-2,857 us per rendered frame; mixing 1,851-2,288 us per emulated frame.

Profile shares of the same runs (1 kHz samples, 47,663 and 45,963): drawing (tile renderer, `DrawBackground`, `S9xUpdateScreen`, fills, OBJ set-up) 46.9 % and 39.1 % of the samples at 1.9 times the rendered frames; `DrawTile16` 24.7 % and 23.8 %, `S9xUpdateScreen` 14.9 % and 0.9 %, `memset` 4.1 % and 0.3 %, `DrawBackground` 1.9 % and 5.4 % (the sub-screen tiles are now fetched and mostly rejected by the depth test), line fills (`draw.S`, `S9xFillLine`) 0 and 5.6 %.

### 10.5 State

| Item | State |
|---|---|
| Drawing per rendered frame (rendered minus skipped frame) | 27.3 ms -> 9.1-11.2 ms |
| 60 rendered frames per second | not reached: a rendered frame takes 14.8-17.1 ms of emulation and drawing plus 2.6 ms video plus about 2 ms mixing; the frame time is 16.7 ms |
| Remaining drawing cost | `DrawTile16` (about 5 instructions per written pixel and 6-9 per group test, measured in the disassembly; about 60 % of the drawing samples), `DrawBackground` tile set-up, line fills (the write-back of the replaced cache lines) |
| Not done | `DrawTile16` in assembler (the compiled fast path is within 3 instructions per group of a hand count), `colormath voodoo` with the new paths, the GT-64010 DMA engine for fills, texture download from the strips; the frame texture by DMA is section 11.1 |

### 10.6 Tile routines in assembler (`bringup/snes/tile16.S`, setting `tile asm|c`)

| Routine | Function |
|---|---|
| `s9x_tile16` | `DrawTile16`: the tile set-up of `TILE_PREAMBLE` and four row loops (normal and horizontally flipped, each for tiles with and without a pixel 0). The pixels and depth bytes written are those of the function in `tile.cpp` |
| `s9x_ctile16` | `DrawClippedTile16`: the same row loops with the two cache words of a row masked by `HeadMask` and `TailMask` |
| `s9x_tilerun16` | the middle loop of `DrawBackground` for unclipped 8 x 8 tiles: one call per run of tiles up to the next 32-tile boundary of the tile map. The values taken from `BG` and `GFX` are read once per run; a blank tile costs the map word, the tile number and the state byte of the tile cache |
| Core changes | `ConvertTile` returns `S9X_OPAQUE_TILE` (3) for a tile with no pixel 0; `gfx.cpp` selects the routines through `S9X_DRAWTILE16` and `S9X_DRAWCTILE16` while `s9x_tile_asm` is set, and `DrawBackground` calls `s9x_tilerun16` when the tile renderer is `s9x_tile16`, the tile size is 8, direct colour is off and both depths are above 0 |
| Left to the core | a tile not yet converted (drawn by `DrawTile16`, which converts it), direct-colour tiles, 16 x 16 tiles, the clipped tiles at the two edges of a row (`s9x_ctile16`), every renderer with colour math |
| Registers | 32-bit values only: the interrupt entry (`q2seattle/boot/irq_vec.S`) saves 32 bits of each integer register. A 64-bit `ld`/`sd` path is not usable without a change of that entry |

Tile statistics of the attract demo (MAME, counters in a test build of the core, average per rendered frame over 300 frames): 4,000 `DrawTile16` calls, of which 2,100 for blank tiles; 10,700 tile rows; groups of four pixels: 12,600 written whole, 5,900 skipped by the depth test (sub screen), 1,700 written per pixel, 1,100 empty cache words.

MAME, Super Mario World attract demo, `frameskip 1`, `sound off`, 120 s (MAME times follow the instruction count and are not board times):

| Build | Rendered frame, 10-s reports 2 to 4 | `fcrc` and `check` against `tile c` |
|---|---|---|
| `tile c` | 12,768 / 12,943 / 11,579 us | reference: 98 `fcrc` lines (2,940 rendered frames), 98 `check` lines |
| `s9x_tile16` and `s9x_ctile16` | 11,652 / 11,812 / 10,621 us | equal |
| plus `s9x_tilerun16` | 10,553 / 10,721 / 9,641 us | equal |
| plus branch delay slots used in the group and pixel code, depth-bit tests by sign, the row loops returning straight to the run loop | 10,251 / 10,422 / 9,391 us | equal |

Board: untested (timing, `check`, `fcrc`, `scrc`).

Not adopted: `-O3 -funroll-loops` for the core, or for `gfx.cpp`, `tile.cpp` and `soundux.cpp` alone: the image grows by 123 KB and 57 KB and the graphics tables no longer fit the arena.

### 10.7 Frame of 8-bit palette indices (setting `pal8 on|off`, `bringup/snes/tile8.S`)

| Item | Implementation |
|---|---|
| Frame | each pixel one byte: the index of its colour in `IPPU.ScreenColors` (pixel value plus palette base), 256 bytes a line in the buffer of the sub screen (`GFX.SubScreen`), the same offset and pitch as the depth buffer |
| Tile routines | `s9x_tile8`, `s9x_ctile8`, `s9x_tilerun8`: the depth test of `tile16.S`; a group of four pixels written whole is one addition (cache word plus palette base in each byte) and two word stores; a group written in part is merged under a byte mask without a branch per pixel. A tile not yet converted is converted by `ConvertTile` and drawn |
| Lines drawn this way | BG modes 0 and 1 without mosaic, 256 pixels wide, in two cases of `S9xUpdateScreenLines`: no colour math in operation (back colour entry 0, black of forced blanking and outside the main-screen colour window entry 16), and the case of `direct` (section 10.1: fixed colour inside the sub-screen colour window entry 16, back colour 0 entry 0) |
| Entry 16 | the pixel value 0 of a palette, never drawn by a tile of 2 or 4 bits a pixel; holds the one colour of the frame that is not a palette colour |
| Colours of a frame | `IPPU.ScreenColors` and entry 16 at the frame's first lines (`s9x_pal8_pal`). Lines rendered later are drawn as indices only while the 255 colours and entry 16 are unchanged |
| Change-over | on a change of the colours, of entry 16, of the BG mode or of the colour math within a frame the lines drawn so far are expanded to RGB565 in `GFX.Screen` and the frame continues as RGB565; the next 60 rendered frames are RGB565 from their first line |
| Voodoo | texture format P8 (textureMode bits 11:8 = 5), 256 texels a row; download with textureMode bit 31 set (sequential 8-bit download: 64 consecutive words a row at byte t << 9 of the texture window), cleared before the quad; one GT-64010 DMA record of 256 bytes a line (`texture dma`) or eight 32-byte block writes a line (`texture cpu`). Palette: 256 writes to NCC table 0 registers I0-Q3 with bit 31 set (`_grTexDownloadPalette` of Glide 2.x, 3Dfx Interactive), RGB565 widened by bit replication, written when it differs from the palette last written |
| Off | with `aspect 1:1` (LFB copy) and `colormath voodoo` |
| Report | field `p8 N/M` of the `snes:` report line: N of the M shown frames of the period were frames of palette indices |
| `fcrc` | over the RGB565 value of every pixel (`s9x_pal8_pal [index]`): the lines of a frame of palette indices equal those of the RGB565 frame |

MAME, Super Mario World attract demo, `frameskip 1`, `sound off` (MAME times follow the instruction count and are not board times):

| Test | Result |
|---|---|
| 120 s, `pal8 on` against `tile c` with `pal8 off` (section 10.6) | 98 `fcrc` lines (2,940 rendered frames) and 98 `check` lines equal; `p8 300/300` in every report |
| Rendered frame, reports 2 to 4 | 8,724 / 8,879 / 8,208 us (`pal8 off`, same build: 10,251 / 10,422 / 9,391 us) |
| 70 s, `vcrc 20`, `pal8 on` against `pal8 off` | 67 `vcrc` lines (CRC-32 of the displayed Voodoo buffer) equal |
| 60 s, test build with every frame changed over at line 112 | 38 `fcrc` and 38 `check` lines equal to the reference; `p8 0/300` |

Board: untested (timing, picture, `check`, `fcrc`, `vcrc`). Untested in MAME and on the board: games other than Super Mario World, BG mode 0, 16 x 16 tiles, the colour windows, `texture cpu`, `filter bilinear` with the P8 texture.

### 10.8 Board results (A-21464, Super Mario World attract demo, sound on, `frameskip auto`, `texture dma`, 10-s reports 2 and 3)

Build: `make -C bringup FATFS=1 BUILD=build-fs28 EXTRA="-DUART_DIV=0x00u" build-fs28/payload.bin`, payload 1,358,916 bytes, CRC32 6f5d6ab9; arena 4,808 KB used, 19 KB free at game start.

| Run | Emulated frames/s | Shown frames/s | Rendered frame | Skipped frame | Mixing | Video | Idle |
|---|---|---|---|---|---|---|---|
| Tree before sections 10.6 and 10.7 (section 11.1), 512x256 | 59.9 / 60.0 | 39.3 / 39.3 | 17,102 / 17,384 us | 5,524 / 5,892 us | 1,959 / 2,008 us | 509 / 517 us | 1,198 / 847 us |
| `tile asm`, `pal8 on`, 512x256 (54 Hz) | 59.9 / 59.9 | 53.6 / 53.7 | 12,398 / 12,721 us | 5,731 / 6,087 us | 1,772 / 1,814 us | 805 / 655 us | 2,440 / 2,177 us |
| the same, 512x240 (59.98 Hz), `late 0` behaviour (a frame skipped at any delay) | 60.0 / 59.9 | 54.7 / 55.0 | 12,553 / 12,902 us | 6,297 / 6,336 us | 1,772 / 1,815 us | 736 / 779 us | 2,162 / 1,722 us |
| the same, `late 75` (default) | 60.0 / 59.9 | 59.8 / 59.7 | 12,589 / 12,907 us | 5,844 / 6,400 us | 1,777 / 1,819 us | 1,867 / 1,530 us | 401 / 382 us |
| disk build started from the card (`dboot 3ee080`), default settings, report 2 | 60.0 | 59.8 | 12,475 us | 5,505 us | 1,776 us | 1,832 us | 553 us |

Every shown frame of the `pal8 on` runs is a frame of palette indices (`p8 598/598`); texture DMA transfers not complete after 100 ms: 0. The video time of the last two rows includes the wait for the previous buffer swap (1,276 to 1,613 us): the program runs in step with the vertical retrace. The display refreshes at 59.98 Hz and the SNES frame rate is 60.1 Hz, so about one frame in 8 s is skipped.

| Check | Result |
|---|---|
| `frameskip 1`, `sound off`, `check 60`, `fcrc 60`, 40 s, release build with `pal8 on` against the MAME run of `tile c` with `pal8 off` (section 10.6) | 38 `fcrc` lines (1,140 rendered frames) and 38 `check` lines equal, last `fcrc 2280 n 1140 crc 2f320595` |
| Picture and sound, owner at the cabinet, 512x240 | Super Mario World attract demo and play: correct |
| Untested on the board | `tile c` and `pal8 off` timing of this tree, `vcrc`, `scrc`, a second `snes` run without a reset between (the first attempt reported "core memory allocation failed"), games other than Super Mario World |

## 11 Texture DMA and Mixer

### 11.1 Frame texture by GT-64010 DMA channel 0 (`texture dma`)

| Item | Implementation |
|---|---|
| Channel | GT-64010A DMA channel 0 (data sheet 277-00106-0, sections 5.9-5.10): byte count 0x800, source 0x810, destination 0x820, next record 0x830, control 0x840; interrupt cause 0xC18 bit 4 (DMA0Comp), acknowledged by writing 0; the CPU interrupt mask keeps it off the CPU |
| Mode | chained (ChainMod 0), block (TransMod 1), DatTransLim 111 (32 bytes per access, the size of the channel FIFO), IntMode 1, ChanEn and FetNexRec: control word 0x3DC0, written after a 0 that disables the channel |
| Records | four words (byte count, source, destination, next record; 0 ends the chain) in a 32-byte aligned array, written back from the data cache before the start: rows 0 to h-1 in records of 64 rows (32,768 bytes; the byte count register holds 16 bits), then row h-1 again as row h. Processor physical addresses: `GFX.Screen` in DRAM, the texture window 0x08800000 in PCI memory space 0 |
| Coherency | the screen rows are written back and invalidated (Hit_Writeback_Invalidate_D, 3,584 lines for 224 rows) before the start: the channel reads DRAM, not the data cache |
| Order | `S9xDeinitUpdate`: the previous transfer completed and its quad drawn, the previous swap awaited (texture and back buffer free), write-back, start. The quad and the swap request follow when the chain has completed (DMAActSt bit 14 clear, byte count 0, next-record pointer 0): polled after mixing and in the frame throttle (`S9xSyncSpeed`), awaited in `S9xInitUpdate` before the next rendered frame draws into `GFX.Screen`, and at game end. One screen buffer: 43 KB of the arena are free at game start, a second buffer needs 120 KB. A transfer not complete after 100 ms is stopped and counted (line `snes: texture DMA transfers not complete after 100 ms: N` at game end) |
| Colour math on the Voodoo | frames that use it take the CPU path (two textures, two quads) |
| MAME 0.289 | `gt64xxx.cpp` models the channel: 128 bytes per 1/520,833 s, records fetched at the FetNexRec write and at each record end, DMAActSt and ChanEn cleared at the end of a chain |

Correctness (Super Mario World attract demo, `frameskip 1`, `sound off`, `check`, `fcrc`, `vcrc 30`):

| Test | Result |
|---|---|
| MAME, 60 s, `texture cpu` against `texture dma` | 36 `vcrc` lines (1,080 shown frames) and 72 `check` and `fcrc` lines equal |
| MAME, fault injection: destination of rows 64-127 shifted by 4 bytes | `vcrc` lines differ from the second line on |
| Board, 40 s, three runs per path | `check` and `fcrc` lines equal in all six runs (to frame 2,040 or 2,160) and equal to the MAME lines of the same frames (`fcrc 2160 n 1080 crc f4819b02`); `vcrc`: of 32 sampled shown frames (30 to 960) the CPU runs differ from the six-run majority in 2, 3 and 1 frames, the DMA runs in 1, 1 and 0; in the third pair every LFB read agreed with the second read (68 of 68). The displayed picture of a frame differs now and then on the board with either path; cause unknown |

Board timing (attract demo, defaults: `frameskip auto`, sound on, TMU fill; 50 s, 10-s reports 2 to 4):

| Path | Rendered frame (emulation and drawing) | Skipped frame | Video per rendered frame | Frames shown per second |
|---|---|---|---|---|
| `texture cpu` (section 10.4) | 16,871 / 17,141 / 14,766 us | 5,624 / 5,973 / 5,624 us | 2,610 / 2,606 / 2,857 us | 36.5 / 35.4 / 40.3 |
| `texture dma` | 17,256 / 17,533 / 15,167 us | 5,613 / 5,976 / 5,581 us | 539 / 595 / 904 us | 38.8 / 38.0 / 41.8 |

Video with `texture dma`: wait for the previous swap 102 / 158 / 455 us, write-back and start 398 / 398 / 413 us, completion check, quad and swap request 36 / 36 / 33 us (report field `fin`). The rendered frame is 0.4 ms longer than with the CPU path (the channel's DRAM and PCI traffic during the emulation, the invalidated screen lines). Every report 59.9-60.0 emulated frames per second; mixing 2,135 / 2,268 / 1,868 us per emulated frame. Profile (49,658 samples): `DrawTile16` 23.9 %, `S9xSyncSpeed` (throttle wait) 9.9 %, `MixStereo` 7.9 %, `DrawBackground` 5.2 %, `s9xa_run` 4.9 %, `s9x_copy_lines` 3.2 %; `voodoo_lfb_lines` (4.3 % with the CPU path) no longer appears.

### 11.2 Mixer (`soundux.cpp` `MixStereo`)

| Item | Implementation |
|---|---|
| Change | the envelope error, the envelope rate and the sample counter of the channel in locals; written to the channel before the envelope step and the sample step (which read them, call `S9xSetEnvRate` or end the channel) and after the loop, read back after each step. `Settings.ReverseStereo`, the echo-buffer pointer and the pitch-modulation test are read once per channel instead of once per sample |
| Check | `scrc N` (section 6): CRC-32 chained over the mixed samples, 520 stereo frames per emulated frame |
| MAME, attract demo, `frameskip 1`, sound on, `scrc 60`, 90 s | 67 `scrc` lines (2,089,880 stereo frames) and 134 `check` and `fcrc` lines equal to the unmodified mixer |
| Board | untested (timing and `scrc`) |

### 11.3 State

| Item | State |
|---|---|
| Per rendered frame (board, `texture dma`) | 15.2-17.5 ms emulation and drawing, 0.5-0.9 ms video, about 2 ms mixing per emulated frame; the frame time is 16.7 ms |
| 60 rendered frames per second | not reached: 38.0-41.8 frames shown per second |
| Board measurement | stopped after two failed uploads in a row (the first left the board in the bring-up ROM menu, the second found no menu response at 9,645 baud); the mixer timing is unmeasured |
| Not done | mixer timing on the board; `DrawTile16` in assembler; a second screen buffer (no arena room) |

## 12 Limitations

| Item | State |
|---|---|
| ROM images above 2,621,440 bytes (24 and 32 Mbit games, ExHiROM, S-DD1, SA-1 titles, which are 4 MB) | not supported: DRAM |
| S-DD1 | not supported: Snes9x 1.39 needs pre-decompressed graphics packs |
| Hi-res modes 5 and 6 | rendered at 256 pixels (`Settings.SupportHiRes` off) |
| Mouse, Super Scope, multitap | not emulated (no such input on the cabinet) |
| Scaling | by the Voodoo TMU (bilinear); the CPU does not scale. Board cost of the texture download untested |
| TLB refill exceptions | a load or store at a KUSEG address enters at 0x80000000, which `irq_install` does not write; the monitor's handler prints it and halts instead of the guru.c screen (the same for every payload installed by `irq_install` from the disk build) |
| Board | untested: speed, picture, sound, input, battery RAM |
