/* s9x_seattle.c - Snes9x 1.39 platform layer for the Midway Seattle board.
 * EPROM Foundry Inc. / Mike Wolak, project Blitz99.
 *
 * Emulator core: Snes9x 1.39 (Gary Henderson, Jerremy Koot and the
 * authors named in its copyright.h), C++ core files compiled unmodified
 * apart from patches/snes9x-1.39-seattle.patch; interface: s9x_port.h.
 * This file has the structure of the NES platform layer
 * (nes/osd_seattle.c): video driver with the frame report, frame
 * throttle, audio pumped once per frame, input from the cabinet, the
 * quit combination, battery RAM on the exFAT volume.
 *
 * Video: the mode the ROM menu requests in the word at KSEG1 0xA07F0024
 * (bits 31:16 'VM', bits 7:0: 1 512x256 54 Hz, 2 512x240 59.98 Hz,
 * 3 384x240 59.9 Hz, 4 512x384 57 Hz) or the setting "vmode N", else
 * 512x240;
 * double buffered as the NES layer. The core renders the SNES frame
 * (256 x 224 or 239, RGB565) into DRAM (GFX.Screen, pitch 512 bytes).
 * At the end of each rendered frame the frame is written to TMU 0 as
 * rows 0 to h-1 of a 256x256 RGB565 texture, by GT-64010 DMA channel 0
 * while the emulation continues ("texture dma", the default; the quad
 * follows when the transfer has completed) or by 32-byte block writes
 * of the CPU ("texture cpu", voodoo_lfb_lines; a texture row is 512
 * contiguous bytes, the pitch of GFX.Screen), and two bilinear-filtered
 * textured triangles (tri_draw) cover the screen ("aspect fill": x 0 to voodoo_xdim, y 0
 * to voodoo_ydim) or the full width at an integer vertical scale with
 * black borders ("aspect integer"); the scaling is done by the TMU.
 * "aspect 1:1" copies the frame to the back buffer through the LFB
 * instead (snes/blit.S), centred and unscaled. A swap is then queued for
 * the next vertical retrace.
 *
 * Audio: the core's mixer (soundux.cpp) produces 16-bit stereo at the
 * DSP stream program's rate, 31,250 frames/s (or 15,625 with every
 * frame written twice), so no resampling follows; a ring of stereo
 * frames is moved to the DCS2 sound FIFO by the GT-64010 timer 0
 * interrupt (1 kHz) whenever the FIFO is below half full, right word
 * first, for dsp/stream.asm on the ADSP-2115 (the NES transport).
 *
 * Timing: S9xSyncSpeed is unix/unix.cpp's with gettimeofday replaced by
 * CP0 Count (75 MHz): automatic frame skip (at most maxskip frames in a
 * row, rendering resumes when the emulation is ahead of the 60 Hz
 * schedule) or a fixed skip, paced to Settings.FrameTime (16,667 us
 * NTSC, 20,000 us PAL).
 *
 * Input: I/O ASIC IN1 (0xB6000024) and SYSTEM (0xB6000028), active low
 * (MAME 0.289 seattle.cpp, seattle_common), read once per emulated
 * frame. Map (pads 1, the default):
 *   P1 stick       D-pad          P1 button 1   B
 *   P1 button 2    A              P1 button 3   Y
 *   Start 1        Start          P2 button 1   X
 *   P2 button 2    L              P2 button 3   R
 *   Start 2        Select
 * With "pads 2" the P2 panel is SNES pad 2 in the P1 layout (button 1
 * B, 2 A, 3 Y, Start 2 Start); X, L, R and Select are then not
 * reachable. Leave: P1 buttons 1, 2, 3 and Start 1 held 0.5 s (the
 * NES port's A + B + Select + Start, the same four switches), or ESC on
 * the serial line.
 *
 * 65C816: s9x_main_loop (s9x_cpu.cpp) runs the frame in the assembler
 * loop of cpu65.S ("cpu asm", the default) or in the core's S9xMainLoop
 * ("cpu c"); "check N" prints the state check line every N frames.
 *
 * Drawing (gfx.cpp, tile.cpp of the core patch): "fcrc N" prints the
 * chained CRC-32 of the rendered frames; the core's depth-buffer and
 * backdrop line fills call S9xFillLine and S9xCopyLine (whole cache lines
 * by snes/draw.S with "fill cde"); s9x_strip ("strip N") splits each
 * S9xUpdateScreen range into strips of N lines; s9x_direct ("direct on")
 * draws the sub screen into the main screen for backdrop-only addition.
 *
 * Settings: /snes/snes9x.cfg on the exFAT volume, one "name value" per
 * line (missing file or line: the default), see struct snes_cfg.
 *
 * Memory: the core allocates 2.3 MB of tables and caches plus a ROM
 * buffer of MAX_ROM_SIZE + 0x8200 bytes. The large blocks (64 KB and
 * more) come from an arena spanning the rest of the sbrk heap (to
 * HEAP_LIMIT 0x80600000, src/sys.c) and the image area above it
 * (0x80600000-0x807AFFFF, where dboot and fs_load place images; free
 * while a game runs) up to the stack floor 0x807B0000; smaller blocks
 * use the C library heap, from a 256 KB reserve kept in its free list.
 *
 * Fatal errors: exceptions at the general vector 0x80000180 go to the
 * exception dispatcher (irq.c, installed by irq_install as the Quake
 * build installs it) and its fatal-error screen (guru.c); the core's
 * S9xExit ends there too. A TLB refill (a load or store at a KUSEG
 * address, such as a null pointer plus an offset) enters at 0x80000000,
 * which irq_install does not write: there the monitor's handler
 * (src/monitor.c mon_vec) prints the exception and halts.
 *
 * Frame report on the UART every 600 emulated frames, one character per
 * frame (non-blocking), and in snes_stats for a debugger or MAME script.
 */
#include <stdio.h>
#include <string.h>
#include <stdint.h>
#include <stdlib.h>
#include <unistd.h>

#include "s9x_port.h"

#include "voodoo.h"
#include "irq.h"
#include "dcs.h"
#include "cp0.h"
#include "guru.h"
#include "tri.h"
#include "ff.h"
extern volatile uint32_t *wd_reg;     /* watchdog kick register (uart.c) */

#define WATCHDOG     (*wd_reg)
#define CP0_HZ       75000000u           /* CP0 Count: half the 150 MHz pipeline clock */
#define IOA_IN1      (*(volatile uint32_t *)0xb6000024u)
#define IOA_SYSTEM   (*(volatile uint32_t *)0xb6000028u)
#define SND_FIFO     (*(volatile uint32_t *)0xb3000000u)
#define SND_STAT     (*(volatile uint32_t *)0xb6000014u)
#define ST_HALF      0x10u
#define ST_FULL      0x20u
#define UART_ST      (*(volatile uint32_t *)0xb6000034u)
#define UART_OUT     (*(volatile uint32_t *)0xb6000004u)
/* DAC rate: STREAM.BIN plays one FIFO word per SPORT1 word, two words a
 * stereo frame; SCLKDIV 7 gives 16 MHz / (16 x 16 x 2) = 31,250 frames/s */
#define RATE         31250
#define RING         8192u                    /* stereo frames, power of two */
#define RING_TARGET  2048u                    /* frames queued: about 65 ms */
#define HEAP_LIMIT   0x80600000u              /* src/sys.c sbrk limit */
#define ARENA_TOP    0x807B0000u              /* stack floor (stack 0x807B0000-0x807FFFFF) */
#define RESERVE      (256u * 1024u)           /* C library heap kept for small blocks */
#define LFB_ROW      2048u                    /* bytes per LFB row (1024 pixels) */

void mon_printf(const char *fmt, ...);
void mon_install_vectors(void);
int  uart_getc(void);
int  fs_mounted(void);
void dcs_reset_board(void);
/* s9x_cpu.cpp: the 65C816 loop (cpu65.S or S9xMainLoop), the state check line,
   the opcode counts of an S9XA_HIST build */
extern int s9x_cpu_asm, s9x_spc_asm, s9x_tile_asm;
void s9x_main_loop(void);
void s9x_cpu_check(uint32_t frame);
void s9x_cpu_hist(void);
void s9x_cpu_setup(int lo, int hi);

/* ---- settings (/snes/snes9x.cfg) ------------------------------------------- */
struct snes_cfg {
    int frameskip;      /* "frameskip auto" (-1) or N: N frames skipped after each rendered one */
    int maxskip;        /* "maxskip N": automatic skip, at most N frames in a row (unix.cpp: 10) */
    int sound;          /* "sound on|off": mixing and output (the SPC700 runs either way) */
    int apu;            /* "apu on|off": off stops the SPC700 too (Settings.APUEnabled; games may hang) */
    int half;           /* "rate 31250|15625": mixing rate, 15,625 writes each frame twice */
    int stereo;         /* "stereo on|off" */
    int echo;           /* "echo on|off" (Settings.DisableSoundEcho) */
    int interp;         /* "interpolate on|off" (Settings.InterpolatedSound) */
    int transparency;   /* "transparency on|off" (Settings.Transparency) */
    int burst;          /* "blit burst|single": cache-line bursts or single uncached words */
    int aspect;         /* "aspect fill|integer|1:1": TMU-scaled quad over the screen, TMU-scaled with an integer vertical scale and borders, or the LFB copy 1:1 */
    int pads;           /* "pads 1|2" */
    int autosave;       /* "autosave N": battery RAM written N s after a change, 0: at game end only */
    int profile;        /* "profile on|off": program-counter histogram at 1 kHz */
    int filter;         /* "filter bilinear|point": the TMU's magnification and minification */
    int seconds;        /* "seconds N": the game ends by itself after N seconds (0: never) */
    int vmath;          /* "colormath voodoo|cpu": addition blended on the Voodoo or by the core */
    int cpu;            /* "cpu asm|c": 65C816 loop of cpu65.S or the core's S9xMainLoop */
    int check;          /* "check N": state check line every N emulated frames (0: none) */
    int cpuc_lo, cpuc_hi; /* "cpuc LO-HI" (hex): these opcodes by the core's C handlers (test) */
    int fcrc;           /* "fcrc N": CRC-32 of every rendered frame, chained, printed every N emulated frames (0: none) */
    int fill;           /* "fill cde|cpu": depth and back-colour line fills by allocating cache lines (draw.S) or by word stores */
    int strip;          /* "strip N": S9xUpdateScreen renders in strips of N lines (0: one pass) */
    int direct;         /* "direct on|off": sub screen drawn into the main screen for backdrop-only addition (gfx.cpp) */
    int dma;            /* "texture dma|cpu": frame texture written by GT-64010 DMA channel 0 or by CPU block writes */
    int vcrc;           /* "vcrc N": every N rendered frames the CRC-32 of the displayed Voodoo buffer (test; 0: none) */
    int scrc;           /* "scrc N": every N emulated frames the chained CRC-32 of the mixed samples; N > 0 mixes a fixed 520 frames each (test; 0: none) */
    uint32_t fprof;     /* "fprof ADDR" (hex): start of the 8-byte-bucket profile window (0: cpu65.S and spc700.S) */
    int pal8;           /* "pal8 on|off": frames without per-pixel colour math drawn as 8-bit palette indices, the colours by the TMU palette (gfx.cpp, tile8.S) */
    int vmode;          /* "vmode N": video mode 1-4 for the run (0: the request of the ROM menu, else the DIP choice) */
    int late;           /* "late N": with frame skip auto a frame is skipped only when the schedule is more than N percent of a frame behind (0-400) */
};
static struct snes_cfg cfg = { -1, 10, 1, 1, 0, 1, 1, 0, 1, 1, 0, 1, 0, 0, 0, 0, 0, 1, 0, 1, 0,
                                0, 1, 16, 1, 1, 0, 0, 0, 1, 0, 75 };  /* fcrc, fill, strip, direct, dma, vcrc, scrc, fprof, pal8, vmode, late */

/* settings given on the monitor line (snes_opt), applied after the file */
static char opt_k[8][32], opt_v[8][32];
static int n_opt;
void snes_opt_clear(void) { n_opt = 0; }
void snes_opt(const char *k, const char *v)
{
    if (n_opt < 8) {
        strncpy(opt_k[n_opt], k, 31); opt_k[n_opt][31] = 0;
        strncpy(opt_v[n_opt], v, 31); opt_v[n_opt][31] = 0;
        n_opt++;
    }
}

static int on_off(const char *v) { return !strcmp(v, "on") || !strcmp(v, "1") || !strcmp(v, "yes"); }

static void cfg_set(const char *k, const char *v);

static void cfg_load(void)
{
    FILE *f = fopen("/snes/snes9x.cfg", "r");
    char line[80], k[32], v[32];
    if (f) {
        while (fgets(line, sizeof line, f))
            if (sscanf(line, "%31s %31s", k, v) == 2 && k[0] != '#')
                cfg_set(k, v);
        fclose(f);
    }
    for (int i = 0; i < n_opt; i++)
        cfg_set(opt_k[i], opt_v[i]);
    if (cfg.maxskip < 0) cfg.maxskip = 0;
    if (cfg.frameskip > 9) cfg.frameskip = 9;
}

static void cfg_set(const char *k, const char *v)
{
        if (!strcmp(k, "frameskip"))         cfg.frameskip = strcmp(v, "auto") ? atoi(v) : -1;
        else if (!strcmp(k, "maxskip"))      cfg.maxskip = atoi(v);
        else if (!strcmp(k, "sound"))        cfg.sound = on_off(v);
        else if (!strcmp(k, "apu"))          cfg.apu = on_off(v);
        else if (!strcmp(k, "rate"))         cfg.half = atoi(v) < 20000;
        else if (!strcmp(k, "stereo"))       cfg.stereo = on_off(v);
        else if (!strcmp(k, "echo"))         cfg.echo = on_off(v);
        else if (!strcmp(k, "interpolate"))  cfg.interp = on_off(v);
        else if (!strcmp(k, "transparency")) cfg.transparency = on_off(v);
        else if (!strcmp(k, "blit"))         cfg.burst = strcmp(v, "single") != 0;
        else if (!strcmp(k, "aspect"))       cfg.aspect = !strcmp(v, "integer") ? 1 : !strcmp(v, "1:1") ? 2 : 0;
        else if (!strcmp(k, "pads"))         cfg.pads = atoi(v) == 2 ? 2 : 1;
        else if (!strcmp(k, "autosave"))     cfg.autosave = atoi(v);
        else if (!strcmp(k, "profile"))      cfg.profile = on_off(v);
        else if (!strcmp(k, "filter"))       cfg.filter = strcmp(v, "point") != 0;
        else if (!strcmp(k, "seconds"))      cfg.seconds = atoi(v);
        else if (!strcmp(k, "colormath"))    cfg.vmath = strcmp(v, "cpu") != 0;
        else if (!strcmp(k, "cpu"))          cfg.cpu = strcmp(v, "c") != 0;
        else if (!strcmp(k, "spc"))          s9x_spc_asm = strcmp(v, "c") != 0;
        else if (!strcmp(k, "tile"))         s9x_tile_asm = strcmp(v, "c") != 0;
        else if (!strcmp(k, "check"))        cfg.check = atoi(v);
        else if (!strcmp(k, "cpuc"))         { unsigned lo = 1, hi = 0; sscanf(v, "%x-%x", &lo, &hi); cfg.cpuc_lo = (int)lo; cfg.cpuc_hi = (int)hi; }
        else if (!strcmp(k, "fcrc"))         cfg.fcrc = atoi(v);
        else if (!strcmp(k, "fill"))         cfg.fill = strcmp(v, "cpu") != 0;
        else if (!strcmp(k, "strip"))        cfg.strip = atoi(v);
        else if (!strcmp(k, "direct"))       cfg.direct = on_off(v);
        else if (!strcmp(k, "pal8"))         cfg.pal8 = on_off(v);
        else if (!strcmp(k, "vmode"))        cfg.vmode = atoi(v);
        else if (!strcmp(k, "late"))         { cfg.late = atoi(v); if (cfg.late < 0) cfg.late = 0; if (cfg.late > 400) cfg.late = 400; }
        else if (!strcmp(k, "texture"))      cfg.dma = strcmp(v, "cpu") != 0;
        else if (!strcmp(k, "vcrc"))         cfg.vcrc = atoi(v);
        else if (!strcmp(k, "scrc"))         cfg.scrc = atoi(v);
        else if (!strcmp(k, "fprof"))        cfg.fprof = (uint32_t)strtoul(v, NULL, 16);
        else mon_printf("snes: %s: unknown setting\n", k);
}

/* ---- memory arena ------------------------------------------------------------ */
static uint8_t *arena_lo, *arena_ptr;
static char *brk0;
static void *pin;

static int arena_open(void)
{
    void *keep = malloc(RESERVE);
    pin = malloc(16);                    /* keeps the reserve below the top: not trimmed when freed */
    if (!keep || !pin) {
        free(keep); free(pin); pin = 0;
        return -1;
    }
    free(keep);
    brk0 = sbrk(0);
    if (sbrk((int)(HEAP_LIMIT - (uint32_t)brk0)) == (void *)-1) {
        free(pin); pin = 0;
        return -1;
    }
    arena_lo = arena_ptr = (uint8_t *)(((uint32_t)brk0 + 31u) & ~31u);
    return 0;
}

static void arena_close(void)
{
    if (!arena_lo)
        return;
    sbrk(-(int)(HEAP_LIMIT - (uint32_t)brk0));
    free(pin);
    pin = 0;
    arena_lo = arena_ptr = 0;
}

void *s9x_malloc(size_t n)
{
    if (n < 0x10000u || !arena_lo)
        return malloc(n);
    n = (n + 31u) & ~31u;
    if ((uint32_t)arena_ptr + n > ARENA_TOP) {
        mon_printf("snes: %u bytes requested, %u free\n", (unsigned)n,
                   (unsigned)(ARENA_TOP - (uint32_t)arena_ptr));
        return 0;
    }
    void *p = arena_ptr;
    arena_ptr += n;
    return p;
}

void s9x_free(void *p)
{
    if (arena_lo && (uint8_t *)p >= arena_lo && (uint32_t)p < ARENA_TOP)
        return;                          /* arena blocks are released together (arena_close) */
    free(p);
}

void *s9x_new_array(size_t n) { return s9x_malloc(n); }
void s9x_delete_sized(void *p, size_t n) { (void)n; s9x_free(p); }

/* ---- statistics and report ------------------------------------------------- */
struct snes_stats {
    uint32_t frames;            /* emulated frames, total */
    uint32_t rendered;          /* rendered frames, total */
    uint32_t fps10;             /* last report: emulated frames per second x 10 */
    uint32_t rfps10;            /* last report: rendered frames per second x 10 */
    uint32_t us_render;         /* last report: emulation time of a rendered frame, us (blit excluded) */
    uint32_t us_skip;           /* last report: emulation time of a skipped frame, us */
    uint32_t us_blit;           /* last report: blit per rendered frame, us */
    uint32_t us_mix;            /* last report: sound mixing per emulated frame, us */
    uint32_t us_idle;           /* last report: throttle wait per emulated frame, us */
    uint32_t snd_words;         /* last report: FIFO words per second */
    uint32_t snd_peak;          /* last report: largest sample magnitude */
    uint32_t snd_under;         /* FIFO ticks that found the ring empty, total */
    uint32_t reports;           /* reports made */
    uint32_t prof_base;         /* profile: address of bucket 0 */
    uint32_t prof_shift;        /* profile: log2 of the bucket size */
    uint32_t prof_n;            /* profile: buckets */
    uint32_t prof_samples;      /* profile: samples taken */
    uint32_t us_wait;           /* last report: wait for the previous swap per rendered frame, us (part of us_blit) */
    uint32_t us_tex;            /* last report: texture download per rendered frame, us (part of us_blit) */
    uint32_t us_quad;           /* last report: quad set-up and swap request per rendered frame, us (part of us_blit) */
    uint32_t us_fin;            /* last report: texture DMA completion wait, quad and swap request per rendered frame, us (not in us_blit) */
    uint32_t dma_fail;          /* texture DMA transfers that did not complete within 100 ms, total */
};
struct snes_stats snes_stats;

#define PROF_SHIFT   7u                       /* 128-byte buckets */
#define PROF_MAX     12288u                   /* 1.5 MB of code */
uint16_t snes_prof[PROF_MAX];
/* fine profile of the 65C816 assembler core (cpu65.S): 8-byte buckets */
#define FPROF_MAX    6144u
static uint16_t snes_fprof[FPROF_MAX];
static uint32_t fprof_base, fprof_n;

static uint32_t t_mark, t_frame0, t_emu_r, t_emu_s, n_r, n_s, t_blit, t_wait, t_tex, t_quad, n_blit, t_mix, t_idle, n_frames;
static uint32_t n_p8;                        /* shown frames of palette indices in the report period */
static uint32_t t_fin_in, t_fin_out;      /* texture DMA: completion wait, quad and swap request; inside and outside the emulation time */
static char rpt[240];
static uint32_t pad_seen;                   /* P1 pad bits seen since the last report (the input check) */
static int rpt_len, rpt_pos;
static volatile uint32_t n_words, n_under;
static int16_t peak;

static void rpt_drain(void)
{
    if (rpt_pos < rpt_len && (UART_ST & 0x2000u))
        UART_OUT = (uint8_t)rpt[rpt_pos++];
}

static void report(uint32_t now)
{
    uint32_t us = CP0_HZ / 1000000u;
    uint32_t el = (now - t_frame0) / 1000u;                  /* units of 1000 counts */
    struct snes_stats *s = &snes_stats;
    if (!el) el = 1u;
    s->fps10 = n_frames * 10u * (CP0_HZ / 1000u) / el;
    s->rfps10 = n_r * 10u * (CP0_HZ / 1000u) / el;
    s->us_render = n_r ? t_emu_r / n_r / us : 0;
    s->us_skip = n_s ? t_emu_s / n_s / us : 0;
    s->us_blit = n_blit ? t_blit / n_blit / us : 0;
    s->us_mix = t_mix / n_frames / us;
    s->us_idle = t_idle / n_frames / us;
    s->us_wait = n_blit ? t_wait / n_blit / us : 0;
    s->us_tex = n_blit ? t_tex / n_blit / us : 0;
    s->us_quad = n_blit ? t_quad / n_blit / us : 0;
    s->us_fin = n_blit ? (t_fin_in + t_fin_out) / n_blit / us : 0;
    s->snd_words = (uint32_t)((uint64_t)n_words * CP0_HZ / ((uint64_t)el * 1000u));
    s->snd_peak = (uint32_t)peak;
    s->snd_under = n_under;
    s->reports++;
    rpt_len = snprintf(rpt, sizeof rpt,
                       "snes: %u.%u fps, %u.%u shown  emu %u/%u  video %u (wait %u, texture %u, quad %u) fin %u  mix %u  idle %u us  snd %u w/s peak %u  pad %x  p8 %u/%u\r\n",
                       (unsigned)(s->fps10 / 10u), (unsigned)(s->fps10 % 10u),
                       (unsigned)(s->rfps10 / 10u), (unsigned)(s->rfps10 % 10u),
                       (unsigned)s->us_render, (unsigned)s->us_skip, (unsigned)s->us_blit, (unsigned)s->us_wait, (unsigned)s->us_tex, (unsigned)s->us_quad, (unsigned)s->us_fin,
                       (unsigned)s->us_mix, (unsigned)s->us_idle, (unsigned)s->snd_words, (unsigned)s->snd_peak,
                       (unsigned)pad_seen, (unsigned)n_p8, (unsigned)n_blit);
    pad_seen = 0;
    n_p8 = 0;
    rpt_pos = 0;
    n_words = 0; peak = 0;
    n_frames = 0; n_r = 0; n_s = 0; t_emu_r = 0; t_emu_s = 0; t_blit = 0; t_wait = 0; t_tex = 0; t_quad = 0; t_fin_in = 0; t_fin_out = 0; n_blit = 0; t_mix = 0; t_idle = 0;
    t_frame0 = now;
}

/* ---- video ------------------------------------------------------------------- */
#define SCR_W     256u
#define SCR_H     240u                       /* SNES_HEIGHT_EXTENDED (239) rounded up */
#define SCR_PITCH (SCR_W * 2u)
#define VREG(off) (*(volatile uint32_t *)(VOODOO_REG_BASE + (off)))
#define TEXMEM    0xa8800000u                /* TMU 0 texture window, LOD 0: byte t << 9 | s << 1 */
#define TEXB_BASE 0x4000u                    /* texBaseAddr of the sub-screen texture: 128 KB (8-byte units) */
#define R_ALPHAMODE     0x10cu
#define R_FBZCOLORPATH  0x104u

/* colour math on the Voodoo (gfx.h, gfx.cpp S9xUpdateScreen): s9x_vmath
   while added pixels are only flagged (bit 15), s9x_vmath_used when a part
   of this frame was, s9x_vmath_half for the half-add mode */
int s9x_vmath, s9x_vmath_used, s9x_vmath_half, s9x_vmath_enable;
int s9x_strip;                               /* gfx.cpp: lines per strip of S9xUpdateScreen (0: one pass) */
int s9x_direct;                              /* gfx.cpp: sub screen into the main screen (see cfg.direct) */
int s9x_pal8, s9x_pal8_frame, s9x_pal8_now;  /* gfx.cpp: frame of 8-bit palette indices (see cfg.pal8) */
uint16_t s9x_pal8_pal[256];                  /* gfx.cpp: its colours, RGB565 */
int s9x_tile_asm = 1;                        /* gfx.cpp: DrawTile16 and DrawClippedTile16 by tile16.S ("tile asm|c") */

/* depth-buffer and back-colour line fills of S9xUpdateScreen (gfx.cpp):
 * whole 32-byte cache lines by draw.S (allocated without a DRAM read),
 * otherwise word stores */
void s9x_fill_lines(void *dst, uint32_t pattern, uint32_t bytes);
void S9xFillLine(void *p, uint32_t pattern, uint32_t n)
{
    if (cfg.fill && !(((uint32_t)p | n) & 31u)) {
        s9x_fill_lines(p, pattern, n);
        return;
    }
    uint32_t *w = (uint32_t *)p, *e = (uint32_t *)((uint8_t *)p + n);
    while (w < e)
        *w++ = pattern;
}

void s9x_copy_lines(void *dst, const void *src, uint32_t bytes);
void S9xCopyLine(void *p, const void *s, uint32_t n)
{
    if (cfg.fill && !(((uint32_t)p | n) & 31u)) {
        s9x_copy_lines(p, s, n);
        return;
    }
    uint32_t *w = (uint32_t *)p, *e = (uint32_t *)((uint8_t *)p + n);
    const uint32_t *r = (const uint32_t *)s;
    while (w < e)
        *w++ = *r++;
}

/* "fcrc N": CRC-32 (IEEE 802.3, reflected, polynomial 0xEDB88320) of the
 * rows of every rendered frame, chained over the game, printed with the
 * count of rendered frames every N emulated frames. Equal lines from two
 * runs with the same rendered frames mean pixel-identical pictures */
static uint32_t fcrc_acc, fcrc_n;
static uint32_t scrc_acc, scrc_n;           /* "scrc N": mixed samples, chained CRC-32 and stereo frames */
static uint32_t crc32_buf(uint32_t c, const uint8_t *p, uint32_t n)
{
    static uint32_t t[256];
    if (!t[1])
        for (uint32_t i = 0; i < 256u; i++) {
            uint32_t r = i;
            for (int k = 0; k < 8; k++)
                r = (r >> 1) ^ (0xedb88320u & (0u - (r & 1u)));
            t[i] = r;
        }
    c = ~c;
    while (n--)
        c = t[(c ^ *p++) & 0xffu] ^ (c >> 8);
    return ~c;
}
#define R_STATUS        0x000u
#define R_FBZMODE       0x110u
#define R_TEXTUREMODE   0x300u
#define R_TLOD          0x304u
#define R_TDETAIL       0x308u
#define R_TEXBASEADDR   0x30cu
#define R_NCCTABLE0     0x324u               /* 12 registers; a write with bit 31 set to I0-Q3 (0x334-0x350) loads a palette entry */
void snes_blit_asm(const uint16_t *src, uint32_t dst, uint32_t rows, uint32_t mode);
static uint32_t shown_h;                     /* lines of the last frame; a change clears both buffers */

/* video mode request of the ROM menu: KSEG1 0xA07F0024, bits 31:16 'VM'
 * (0x564D), bits 7:0 the mode (0 the DIP choice) */
#define VMODE_WORD (*(volatile uint32_t *)0xa07f0024u)
static const struct voodoo_mode *requested_mode(void)
{
    uint32_t w = VMODE_WORD;
    if (cfg.vmode)                           /* the setting "vmode N" */
        w = 0x564D0000u | (uint32_t)cfg.vmode;
    if ((w >> 16) != 0x564Du || !(w & 0xFFu))
        return &voodoo_mode_nes;             /* no mode named: 512x240, the mode at the SNES frame rate */
    switch (w & 0xFFu) {
    case 1:  return &voodoo_mode_256;        /* 512x256, 54 Hz */
    case 2:  return &voodoo_mode_nes;        /* 512x240, 59.98 Hz */
    case 3:  return &voodoo_mode_384x240;    /* 384x240, 59.9 Hz */
    case 4:  return &voodoo_mode_384;        /* 512x384, 57 Hz */
    default: return 0;                       /* the DIP choice */
    }
}

/* TMU 0 set-up for the frame texture (tri.c tri_state_textured and
 * tri_texture_rgb565_at): one 256x256 RGB565 texture at texBaseAddr 0,
 * LOD 0 only, bilinear minification and magnification, s and t clamped,
 * texel times the white iterated colour; no depth test, no dithering,
 * colour writes to the back buffer */
/* textureMode of the frame quad: bits 1, 2 bilinear minification and
 * magnification; format (bits 11:8) P8 for a frame of palette indices,
 * else ARGB1555 (RGB555 rendering) or RGB565; seq: bit 31, sequential
 * download of 8-bit texels (four texels a word at consecutive word
 * addresses of a row), set only while the texture is written */
static uint32_t texmode(int p8, int seq)
{
    return 1u << 0 | (cfg.filter ? 1u << 1 | 1u << 2 : 0u) | 1u << 6 | 1u << 7 |
           (p8 ? 0x5u : s9x_vmath_enable ? 0xBu : 0xAu) << 8 |
           1u << 12 | 1u << 18 | 1u << 21 | 1u << 27 | (seq ? 1u << 31 : 0u);
}

static void quad_state(void)
{
    tri_state_textured();
    for (uint32_t t0 = cp0_count_rd(); (VREG(R_STATUS) & 0x3Fu) < 5u && cp0_count_rd() - t0 < 100u * 75000u; )
        WATCHDOG = 0;
    VREG(R_TEXBASEADDR) = 0;
    VREG(R_TLOD) = 0;                        /* lodmin = lodmax = 0 */
    VREG(R_TDETAIL) = 0;
    VREG(R_TEXTUREMODE) = texmode(0, 0);
    VREG(R_FBZMODE) = 1u << 0 | 1u << 9 | 1u << 14;   /* clip, RGB write, back buffer */
}

static void video_finish(int wait, int inside);

/* a rendered frame starts: the texture DMA of the last one reads
 * GFX.Screen, which this frame overwrites, so it completes first */
bool8 S9xInitUpdate(void)
{
    video_finish(1, 1);
    return TRUE;
}

/* the frame of h lines as TMU texture rows 0 to h-1 by 32-byte block
 * writes (a texture row is 512 contiguous bytes, 16 lines, the pitch of
 * GFX.Screen), row h a copy of row h-1 (the bilinear filter reads it at
 * the bottom edge), then two triangles over the target rectangle: s 0 to
 * 256, t 0 to h */
/* PCI FIFO room for n register writes (status bits 5:0), 100 ms at most */
static void fifo_room(uint32_t n)
{
    for (uint32_t t0 = cp0_count_rd(); (VREG(R_STATUS) & 0x3Fu) < n && cp0_count_rd() - t0 < 100u * 75000u; )
        WATCHDOG = 0;
}

static void tex_upload(const uint8_t *screen, uint32_t h)
{
    const unsigned int *src = (const unsigned int *)screen;
    voodoo_lfb_lines(TEXMEM, src, h * 16u);
    if (h < 256u)
        voodoo_lfb_lines(TEXMEM + h * 512u, src + (h - 1u) * 128u, 16u);
}

static void draw_quad(uint32_t h, float alpha);

/* "vcrc N" (test): after the swap request of every Nth shown frame, the
 * swap awaited, the chip idle (status bit 9 clear on 6 consecutive
 * reads, the sst1InitIdle condition), then the CRC-32 of the displayed
 * buffer read through the LFB (lfbMode 0: front buffer, RGB565), 512 x
 * voodoo_ydim pixels, read again until two reads in a row agree (8 reads
 * at most); line "snes: vcrc K crc X reads R", K the shown frames.
 * Equal lines from two texture paths mean equal pictures on the screen.
 * The read takes about 0.1 s; with a fixed frame skip the schedule
 * restarts after it and the emulation is unchanged. */
static uint32_t vcrc_n;
static void vcrc_frame(void)
{
    if (!cfg.vcrc || ++vcrc_n % (uint32_t)cfg.vcrc)
        return;
    for (uint32_t k = 0; k < 2000000u && voodoo_swaps_pending(); k++)
        WATCHDOG = 0;
    for (uint32_t clear = 0, k = 0; clear < 6u && k < 2000000u; k++) {
        WATCHDOG = 0;
        clear = (VREG(R_STATUS) & 0x200u) ? 0 : clear + 1u;
    }
    uint32_t mode = voodoo_lfbmode_get(), c = 0, prev = 0, reads = 0;
    voodoo_lfbmode_set(0);
    do {                                     /* until two reads in a row agree, 8 at most */
        prev = c;
        c = 0;
        for (uint32_t y = 0; y < voodoo_ydim; y++) {
            uint32_t row[256];
            const volatile uint32_t *p = (const volatile uint32_t *)(VOODOO_LFB_BASE + y * VOODOO_LFB_PITCH * 2u);
            for (uint32_t x = 0; x < 256u; x++)
                row[x] = p[x];
            c = crc32_buf(c, (const uint8_t *)row, sizeof row);
            WATCHDOG = 0;
        }
    } while (++reads < 2u || (c != prev && reads < 8u));
    voodoo_lfbmode_set(mode);
    char line[64];
    snprintf(line, sizeof line, "snes: vcrc %u crc %08x reads %u\n", (unsigned)vcrc_n, (unsigned)c, (unsigned)reads);
    mon_printf("%s", line);
}

/* "texture dma": the frame texture written by GT-64010 DMA channel 0
 * (data sheet 277-00106-0, sections 5.9-5.10) while the CPU continues.
 * Chained mode: records of four words (byte count, source, destination,
 * next record; 0 ends the chain) in DRAM, each at most 32 KB (the byte
 * count register holds 16 bits): rows 0 to h-1 in records of 64 rows,
 * then row h-1 again as row h. Source and destination are processor
 * physical addresses: GFX.Screen in DRAM, the texture window 0x08800000
 * in PCI memory space 0; the channel moves 32 bytes per access (the
 * size of its FIFO) in block mode. The DMA reads DRAM directly, so the
 * screen lines are written back from the data cache before the start.
 * Control: DatTransLim 111 (32 bytes, bits 8:6), chained (bit 9 clear),
 * IntMode 1 (bit 10, the completion cause bit only at the end of the
 * chain), TransMod block (bit 11), ChanEn (bit 12), FetNexRec (bit 13).
 * Complete when DMAActSt (bit 14) is clear, the byte count is 0 and the
 * next-record pointer is 0. The interrupt cause bit DMA0Comp (bit 4) is
 * acknowledged by writing 0; the CPU mask leaves it off the CPU. */
#define GT_REG(off)    (*(volatile uint32_t *)(0xac000000u + (off)))
#define GT_DMA0_COUNT  0x800u
#define GT_DMA0_NEXT   0x830u
#define GT_DMA0_CTRL   0x840u
#define GT_INT_CAUSE   0xc18u
#define GT_DMA0COMP    (1u << 4)
#define DMA_ACT        (1u << 14)
#define DMA_CTRL_RUN   (7u << 6 | 1u << 10 | 1u << 11 | 1u << 12 | 1u << 13)
#define TEX_PHYS       0x08800000u
#define DMA_ROWS       64u                    /* rows per record: 32,768 bytes */
#define DMA_RECS       6u

static uint32_t dma_rec[DMA_RECS * 4u] __attribute__((aligned(32)));
static int dma_pending;                        /* a transfer started; its quad not yet drawn */
static uint32_t dma_h, dma_t0;
static int dma_p8;                             /* the pending transfer is a frame of palette indices */

static void dcache_wb_inv(uint32_t a, uint32_t len)
{
    for (uint32_t e = a + len; a < e; a += 32u)
        __asm__ volatile("cache 0x15, 0(%0)" : : "r"(a));      /* Hit_Writeback_Invalidate_D */
}

static void tex_dma_start(const uint8_t *screen, uint32_t h)
{
    uint32_t src = (uint32_t)screen & 0x1FFFFFFFu, n = 0;
    for (uint32_t r = 0; r < h; r += DMA_ROWS, n++) {
        uint32_t k = h - r < DMA_ROWS ? h - r : DMA_ROWS;
        dma_rec[4u * n] = k * SCR_PITCH;
        dma_rec[4u * n + 1u] = src + r * SCR_PITCH;
        dma_rec[4u * n + 2u] = TEX_PHYS + r * SCR_PITCH;
    }
    if (h < 256u) {                            /* the bilinear filter's bottom row */
        dma_rec[4u * n] = SCR_PITCH;
        dma_rec[4u * n + 1u] = src + (h - 1u) * SCR_PITCH;
        dma_rec[4u * n + 2u] = TEX_PHYS + h * SCR_PITCH;
        n++;
    }
    for (uint32_t i = 0; i < n; i++)
        dma_rec[4u * i + 3u] = i + 1u < n ? ((uint32_t)&dma_rec[4u * (i + 1u)] & 0x1FFFFFFFu) : 0u;
    dcache_wb_inv((uint32_t)dma_rec, sizeof dma_rec);
    dcache_wb_inv((uint32_t)screen, h * SCR_PITCH);
    __asm__ volatile("sync" ::: "memory");
    GT_REG(GT_DMA0_CTRL) = 0;                  /* channel idle (the last chain ended) */
    GT_REG(GT_DMA0_NEXT) = (uint32_t)dma_rec & 0x1FFFFFFFu;
    GT_REG(GT_DMA0_CTRL) = DMA_CTRL_RUN;
    dma_pending = 1;
    dma_p8 = 0;
    dma_h = h;
    dma_t0 = cp0_count_rd();
}

/* ---- frame of palette indices (s9x_pal8_frame 1): GFX.SubScreen holds
 * 256 bytes a line, s9x_pal8_pal the colours. The texture is P8, 256
 * texels a row; with sequential 8-bit download a row is 64 consecutive
 * words at byte t << 9 of the texture window, so each line is one DMA
 * record of 256 bytes (or eight 32-byte block writes). The palette is
 * written to the TMU when it differs from the one last written. */
#define DMA8_RECS      257u
static uint32_t dma8_rec[DMA8_RECS * 4u] __attribute__((aligned(32)));
static uint16_t pal_sent[256];
static int pal_valid;
static int tex_p8;                             /* textureMode last written is the P8 one */

/* palette entry i: a write to NCC table 0 register 4 + (i & 7) with bit
 * 31 set, bits 30:24 = i >> 1, bits 23:0 the colour (the entry's low
 * index bit is the register's); RGB565 widened by bit replication */
static void pal_download(void)
{
    if (pal_valid && !memcmp(pal_sent, s9x_pal8_pal, sizeof pal_sent))
        return;
    for (uint32_t i = 0; i < 256u; i++) {
        uint32_t c = s9x_pal8_pal[i], r = c >> 11, g = (c >> 5) & 63u, b = c & 31u;
        if (!(i & 15u))
            fifo_room(16);
        VREG(R_NCCTABLE0 + 4u * (4u + (i & 7u))) = 0x80000000u | (i & 0xFEu) << 23 |
            (r << 3 | r >> 2) << 16 | (g << 2 | g >> 4) << 8 | (b << 3 | b >> 2);
    }
    memcpy(pal_sent, s9x_pal8_pal, sizeof pal_sent);
    pal_valid = 1;
}

static void tex8_dma_start(const uint8_t *screen, uint32_t h)
{
    static uint32_t rec_src, rec_h;             /* the chain in DRAM is the one for these */
    uint32_t src = (uint32_t)screen & 0x1FFFFFFFu, n = h;
    if (src != rec_src || h != rec_h) {
    for (uint32_t r = 0; r < h; r++) {
        dma8_rec[4u * r] = SCR_W;
        dma8_rec[4u * r + 1u] = src + r * SCR_W;
        dma8_rec[4u * r + 2u] = TEX_PHYS + r * 512u;
    }
    if (h < 256u) {                            /* the bilinear filter's bottom row */
        dma8_rec[4u * n] = SCR_W;
        dma8_rec[4u * n + 1u] = src + (h - 1u) * SCR_W;
        dma8_rec[4u * n + 2u] = TEX_PHYS + h * 512u;
        n++;
    }
    for (uint32_t i = 0; i < n; i++)
        dma8_rec[4u * i + 3u] = i + 1u < n ? ((uint32_t)&dma8_rec[4u * (i + 1u)] & 0x1FFFFFFFu) : 0u;
    dcache_wb_inv((uint32_t)dma8_rec, n * 16u);
    rec_src = src;
    rec_h = h;
    }
    dcache_wb_inv((uint32_t)screen, h * SCR_W);
    __asm__ volatile("sync" ::: "memory");
    GT_REG(GT_DMA0_CTRL) = 0;                  /* channel idle (the last chain ended) */
    GT_REG(GT_DMA0_NEXT) = (uint32_t)dma8_rec & 0x1FFFFFFFu;
    GT_REG(GT_DMA0_CTRL) = DMA_CTRL_RUN;
    dma_pending = 1;
    dma_p8 = 1;
    dma_h = h;
    dma_t0 = cp0_count_rd();
}

static void tex8_upload(const uint8_t *screen, uint32_t h)
{
    for (uint32_t r = 0; r < h; r++)
        voodoo_lfb_lines(TEXMEM + r * 512u, (const unsigned int *)(screen + r * SCR_W), 8u);
    if (h < 256u)
        voodoo_lfb_lines(TEXMEM + h * 512u, (const unsigned int *)(screen + (h - 1u) * SCR_W), 8u);
}

static int tex_dma_done(void)
{
    if ((GT_REG(GT_DMA0_CTRL) & DMA_ACT) || (GT_REG(GT_DMA0_COUNT) & 0xFFFFu) || GT_REG(GT_DMA0_NEXT)) {
        if (cp0_count_rd() - dma_t0 < 100u * 75000u)
            return 0;
        snes_stats.dma_fail++;                 /* 100 ms: the channel stopped and left */
    }
    GT_REG(GT_DMA0_CTRL) = 0;
    GT_REG(GT_INT_CAUSE) = ~GT_DMA0COMP;
    return 1;
}

/* the quad of the frame whose texture DMA has completed, and its swap;
 * wait: until the transfer completes, else only when it has. inside: the
 * call lies within the emulation time of a rendered frame */
static void video_finish(int wait, int inside)
{
    if (!dma_pending)
        return;
    uint32_t t0 = cp0_count_rd();
    while (!tex_dma_done()) {
        if (!wait)
            return;
        WATCHDOG = 0;
    }
    dma_pending = 0;
    if (dma_p8) {                               /* the download bit off before the quad */
        fifo_room(1);
        VREG(R_TEXTUREMODE) = texmode(1, 0);
    }
    draw_quad(dma_h, 255.0f);
    voodoo_swap_post();
    vcrc_frame();
    uint32_t t = cp0_count_rd() - t0;
    if (inside) t_fin_in += t; else t_fin_out += t;
}

/* the frame on the Voodoo. With colour math this frame: the sub screen
 * as texture B drawn opaque, then the main screen as texture A blended
 * over it, the texel's alpha (bit 15: an added pixel) times the iterated
 * alpha (1, or 0.5 for half addition) the blend factor:
 *   add:  main x 1 + sub x a
 *   half: main x (1 - a) + sub x a
 * Without: texture A drawn opaque. Texture writes land at texBaseAddr,
 * so each upload follows its base setting in the FIFO. */
static void frame_quad(uint32_t h)
{
    uint32_t t0 = cp0_count_rd();
    int math = s9x_vmath_enable && s9x_vmath_used;
    if (math) {
        fifo_room(4);
        VREG(R_TEXBASEADDR) = TEXB_BASE;
        VREG(R_ALPHAMODE) = 0;
        tex_upload(GFX.SubScreen, h);
        draw_quad(h, 255.0f);
        fifo_room(4);
        VREG(R_TEXBASEADDR) = 0;
        /* alpha = texture alpha x iterated alpha (mselect alocal, reverse blend) */
        VREG(R_FBZCOLORPATH) = 1u << 0 | 1u << 2 | 1u << 10 | 1u << 13 | 1u << 19 | 1u << 22 | 1u << 26 | 1u << 27;
        VREG(R_ALPHAMODE) = 1u << 4 | (s9x_vmath_half ? 5u : 4u) << 8 | 1u << 12;
    }
    tex_upload(GFX.Screen, h);
    uint32_t t1 = cp0_count_rd();
    draw_quad(h, math && s9x_vmath_half ? 128.0f : 255.0f);
    if (math) {
        fifo_room(2);
        VREG(R_ALPHAMODE) = 0;
        VREG(R_FBZCOLORPATH) = 1u << 0 | 1u << 2 | 1u << 10 | 1u << 13 | 1u << 17 | 1u << 23 | 1u << 26 | 1u << 27;
    }
    s9x_vmath_used = 0;
    voodoo_swap_post();
    vcrc_frame();
    uint32_t t2 = cp0_count_rd();
    t_tex += t1 - t0;
    t_quad += t2 - t1;
}

static void draw_quad(uint32_t h, float alpha)
{
    float x0 = 0.0f, x1 = (float)voodoo_xdim, y0 = 0.0f, y1 = (float)voodoo_ydim;
    if (cfg.aspect == 1) {                   /* integer vertical scale, centred, borders black */
        uint32_t k = voodoo_ydim / h;
        if (!k) k = 1;
        y0 = (float)((voodoo_ydim - k * h) / 2u);
        y1 = y0 + (float)(k * h);
    }
    tri_vtx v[4];
    const float xs[4] = { x0, x1, x1, x0 }, ys[4] = { y0, y0, y1, y1 };
    const float ss[4] = { 0.0f, 256.0f, 256.0f, 0.0f }, ts[4] = { 0.0f, 0.0f, (float)h, (float)h };
    for (int i = 0; i < 4; i++) {
        v[i].x = xs[i]; v[i].y = ys[i];
        v[i].r = v[i].g = v[i].b = 255.0f;
        v[i].a = alpha;
        v[i].z = 0.0f; v[i].oow = 1.0f;
        v[i].sow = ss[i]; v[i].tow = ts[i];
    }
    tri_draw(&v[0], &v[1], &v[2]);
    tri_draw(&v[0], &v[2], &v[3]);
}

bool8 S9xDeinitUpdate(int width, int height, bool8 sixteen_bit)
{
    (void)sixteen_bit; (void)width;
    uint32_t t0 = cp0_count_rd();
    uint32_t h = (uint32_t)height;
    if (h > SCR_H) h = SCR_H;
    if (cfg.aspect == 2 && h > voodoo_ydim) h = voodoo_ydim;
    if (cfg.fcrc) {
        if (s9x_pal8_frame == 1) {              /* the RGB565 pixels the indices stand for */
            static uint16_t row[SCR_W];
            for (uint32_t y = 0; y < h; y++) {
                const uint8_t *s = GFX.SubScreen + y * SCR_W;
                for (uint32_t x = 0; x < SCR_W; x++)
                    row[x] = s9x_pal8_pal[s[x]];
                fcrc_acc = crc32_buf(fcrc_acc, row, sizeof row);
            }
        } else
            fcrc_acc = crc32_buf(fcrc_acc, GFX.Screen, h * SCR_PITCH);
        fcrc_n++;
    }
    video_finish(1, 1);                         /* the previous frame's transfer, normally complete */
    if (h != shown_h) {                         /* 224 <-> 239 lines: old lines off both buffers */
        for (uint32_t k = 0; k < 2000000u && voodoo_swaps_pending(); k++)
            WATCHDOG = 0;
        voodoo_fill(0, 0);
        voodoo_fill(1, 0);
        if (cfg.aspect != 2)
            quad_state();
        shown_h = h;
    }
    for (uint32_t k = 0; k < 2000000u && voodoo_swaps_pending(); k++)
        WATCHDOG = 0;                           /* last swap taken: back buffer and texture free */
    t_wait += cp0_count_rd() - t0;
    if (tex_p8 && s9x_pal8_frame != 1 && cfg.aspect != 2) {   /* back to the RGB texture format */
        fifo_room(1);
        VREG(R_TEXTUREMODE) = texmode(0, 0);
        tex_p8 = 0;
    }
    if (cfg.aspect == 2) {                      /* LFB copy, 1:1, centred */
        uint32_t x0 = (voodoo_xdim - SCR_W) / 2u, y0 = (voodoo_ydim - h) / 2u;
        voodoo_draw_backbuffer();
        uint32_t base = cfg.burst ? 0x88400000u : 0xa8400000u;
        snes_blit_asm((const uint16_t *)GFX.Screen, base + y0 * LFB_ROW + x0 * 2u, h, cfg.burst ? 1u : 0u);
        voodoo_swap_post();
    } else if (s9x_pal8_frame == 1) {          /* palette indices: P8 texture and palette */
        uint32_t t1 = cp0_count_rd();
        fifo_room(1);
        VREG(R_TEXTUREMODE) = texmode(1, 1);
        tex_p8 = 1;
        pal_download();
        n_p8++;
        if (cfg.dma) {
            tex8_dma_start(GFX.SubScreen, h);  /* quad and swap in video_finish */
            t_tex += cp0_count_rd() - t1;
        } else {
            tex8_upload(GFX.SubScreen, h);
            fifo_room(1);
            VREG(R_TEXTUREMODE) = texmode(1, 0);
            t_tex += cp0_count_rd() - t1;
            draw_quad(h, 255.0f);
            voodoo_swap_post();
            vcrc_frame();
        }
    } else if (cfg.dma && !(s9x_vmath_enable && s9x_vmath_used)) {
        uint32_t t1 = cp0_count_rd();
        tex_dma_start(GFX.Screen, h);          /* quad and swap in video_finish */
        t_tex += cp0_count_rd() - t1;
    } else {
        frame_quad(h);
    }
    t_blit += cp0_count_rd() - t0;
    n_blit++;
    WATCHDOG = 0;
    return TRUE;
}

/* 8-bit rendering only; this port renders 16-bit RGB565 */
void S9xSetPalette(void) { }

/* ---- audio ------------------------------------------------------------------- */
static int16_t ring[2u * RING];              /* left, right */
static volatile uint32_t r_head, r_tail;
static int16_t mixbuf[2u * (RATE / 50 + 16)];
static volatile int snd_on;

static void fifo_tick(void)
{
    if (cfg.profile) {
        uint32_t i = (cp0_epc() - snes_stats.prof_base) >> PROF_SHIFT;
        if (i < snes_stats.prof_n && snes_prof[i] != 0xffffu)
            snes_prof[i]++;
        uint32_t f = (cp0_epc() - fprof_base) >> 3;
        if (f < fprof_n && snes_fprof[f] != 0xffffu)
            snes_fprof[f]++;
        snes_stats.prof_samples++;
    }
    if (!snd_on)
        return;
    int n = 0;
    /* at most 64 stereo frames (128 words) a tick at 1 kHz: 64,000
     * frames/s against the DSP's 31,250; the half-full flag (SOUNDSTAT
     * bit 4) stops each block of 32 */
    while (!(SND_STAT & ST_HALF) && n < 2) {
        for (int i = 0; i < 32; i++) {
            int16_t l = 0, r = 0;
            if (r_tail != r_head) {
                uint32_t k = (r_tail++ & (RING - 1u)) * 2u;
                l = ring[k]; r = ring[k + 1u];
            } else {
                n_under++;
            }
            SND_FIFO = (uint16_t)r;         /* right */
            SND_FIFO = (uint16_t)l;         /* left */
            n_words += 2u;
        }
        n++;
    }
}

bool8 S9xOpenSoundDevice(int mode, bool8 stereo, int buffer_size)
{
    (void)mode;
    so.playback_rate = cfg.half ? RATE / 2 : RATE;
    so.stereo = stereo;
    so.sixteen_bit = TRUE;
    so.buffer_size = buffer_size > 0 ? buffer_size : 4096;
    so.encoded = FALSE;
    S9xSetPlaybackRate((uint32_t)so.playback_rate);
    return TRUE;
}

/* mixing happens once per emulated frame (pump_audio), not on DSP
 * register writes */
void S9xGenerateSound(void) { }

static void ring_put(int16_t l, int16_t r)
{
    if (r_head - r_tail >= RING)
        return;                                  /* ring full: dropped */
    uint32_t k = (r_head & (RING - 1u)) * 2u;
    ring[k] = l; ring[k + 1u] = r;
    r_head++;
    if (l > peak) peak = l; else if (-l > peak) peak = (int16_t)-l;
}

static void pump_audio(void)
{
    if (!snd_on)
        return;
    /* frames per emulated frame from Settings.FrameTime; the count steers
     * the ring level to RING_TARGET as nes/osd_seattle.c does */
    uint32_t per = (uint32_t)RATE * Settings.FrameTime / 1000000u;
    uint32_t level = r_head - r_tail;
    uint32_t n = level < RING_TARGET / 2u ? per + 6u : level < RING_TARGET ? per + 2u : per - 1u;
    if (cfg.scrc)
        n = per;                                 /* test: the same count every frame, independent of the FIFO timing */
    uint32_t t0 = cp0_count_rd();
    uint32_t m = cfg.half ? (n + 1u) / 2u : n;   /* frames the core mixes */
    S9xMixSamples((uint8 *)mixbuf, (int)(so.stereo ? m * 2u : m));
    if (cfg.scrc) {
        scrc_acc = crc32_buf(scrc_acc, (const uint8_t *)mixbuf, (so.stereo ? m * 2u : m) * 2u);
        scrc_n += m;
    }
    for (uint32_t i = 0; i < m; i++) {
        int16_t l, r;
        if (so.stereo) { l = mixbuf[2u * i]; r = mixbuf[2u * i + 1u]; }
        else           { l = r = mixbuf[i]; }
        ring_put(l, r);
        if (cfg.half)
            ring_put(l, r);
    }
    t_mix += cp0_count_rd() - t0;
}

static int sound_start(void)
{
    extern const struct { const char *name; const uint8_t *data; uint32_t size; } rom_files[];
    extern const uint32_t rom_file_count;
    uint32_t psize = 0;
    for (uint32_t i = 0; i < rom_file_count; i++)
        if (!strcmp(rom_files[i].name, "STREAM.BIN"))
            psize = rom_files[i].size;
    if (!psize || dcs_boot_program("STREAM.BIN", (uint16_t)((psize - 4u) / 3u))) {
        mon_printf("snes: DSP stream program did not start, no sound\n");
        return -1;
    }
    snd_on = 1;
    return 0;
}

/* ---- input ------------------------------------------------------------------- */
static uint32_t pads[2];
static uint32_t t_game0;                    /* CP0 at the last read_pads ("seconds") */
static uint64_t t_game;                     /* CP0 counts since the game start; the 32-bit
                                               Count wraps every 57.3 s at 75 MHz */
static int quit_req, quit_hold;
int snes_quit_to_menu;                       /* set by the quit combination; menu.c returns to the ROM menu */

static void read_pads(void)
{
    uint32_t in1 = ~IOA_IN1, sys = ~IOA_SYSTEM, p1 = 0, p2 = 0;
    if (in1 & 0x0001u) p1 |= SNES_UP_MASK;
    if (in1 & 0x0002u) p1 |= SNES_DOWN_MASK;
    if (in1 & 0x0004u) p1 |= SNES_LEFT_MASK;
    if (in1 & 0x0008u) p1 |= SNES_RIGHT_MASK;
    if (in1 & 0x0010u) p1 |= SNES_B_MASK;
    if (in1 & 0x0020u) p1 |= SNES_A_MASK;
    if (in1 & 0x0040u) p1 |= SNES_Y_MASK;
    if (sys & 0x0004u) p1 |= SNES_START_MASK;
    if (cfg.pads == 2) {
        if (in1 & 0x0100u) p2 |= SNES_UP_MASK;
        if (in1 & 0x0200u) p2 |= SNES_DOWN_MASK;
        if (in1 & 0x0400u) p2 |= SNES_LEFT_MASK;
        if (in1 & 0x0800u) p2 |= SNES_RIGHT_MASK;
        if (in1 & 0x1000u) p2 |= SNES_B_MASK;
        if (in1 & 0x2000u) p2 |= SNES_A_MASK;
        if (in1 & 0x4000u) p2 |= SNES_Y_MASK;
        if (sys & 0x0020u) p2 |= SNES_START_MASK;
    } else {
        if (in1 & 0x1000u) p1 |= SNES_X_MASK;
        if (in1 & 0x2000u) p1 |= SNES_TL_MASK;
        if (in1 & 0x4000u) p1 |= SNES_TR_MASK;
        if (sys & 0x0020u) p1 |= SNES_SELECT_MASK;
    }
    pads[0] = p1;
    pads[1] = p2;
    pad_seen |= p1;
    uint32_t now = cp0_count_rd();
    t_game += now - t_game0;                /* called once per emulated frame */
    t_game0 = now;
    if (cfg.seconds && t_game >= (uint64_t)cfg.seconds * CP0_HZ)
        quit_req = 1;
    /* leave: P1 buttons 1-3 + Start 1 held 0.5 s, Start 1 + Start 2 held 1 s, or ESC on the serial line */
    const uint32_t combo = SNES_B_MASK | SNES_A_MASK | SNES_Y_MASK | SNES_START_MASK;
    static uint32_t ss_hold;                  /* Start 1 + Start 2 (SNES Start + Select) held */
    quit_hold = (p1 & combo) == combo ? quit_hold + 1 : 0;
    ss_hold = ((sys & 0x0024u) == 0x0024u) ? ss_hold + 1 : 0;
    int esc = uart_getc() == 0x1b;
    if (esc || quit_hold >= 30 || ss_hold >= 60) {
        quit_req = 1;
        if (!esc)
            snes_quit_to_menu = 1;
    }
}

uint32 S9xReadJoypad(int which)
{
    if (which == 0) return 0x80000000u | pads[0];
    if (which == 1 && cfg.pads == 2) return 0x80000000u | pads[1];
    return 0;
}

/* no mouse or Super Scope on this cabinet (Settings.Mouse and SuperScope off) */
bool8 S9xReadMousePosition(int which, int *x, int *y, uint32 *buttons)
{
    (void)which; *x = 0; *y = 0; *buttons = 0;
    return FALSE;
}
bool8 S9xReadSuperScopePosition(int *x, int *y, uint32 *buttons)
{
    *x = 0; *y = 0; *buttons = 0;
    return FALSE;
}

/* ---- frame end: timing (unix/unix.cpp S9xSyncSpeed on CP0 Count) ------------- */
static uint32_t next1, frame_counts;
static int next1_set;

void S9xSyncSpeed(void)
{
    if (cfg.check > 0 && (snes_stats.frames + 1u) % (uint32_t)cfg.check == 0)
        s9x_cpu_check(snes_stats.frames + 1u);
    if (cfg.fcrc > 0 && (snes_stats.frames + 1u) % (uint32_t)cfg.fcrc == 0) {
        char line[64];
        snprintf(line, sizeof line, "snes: fcrc %u n %u crc %08x\n", (unsigned)(snes_stats.frames + 1u),
                 (unsigned)fcrc_n, (unsigned)fcrc_acc);
        mon_printf("%s", line);
    }
    if (cfg.scrc > 0 && (snes_stats.frames + 1u) % (uint32_t)cfg.scrc == 0) {
        char line[64];
        snprintf(line, sizeof line, "snes: scrc %u n %u crc %08x\n", (unsigned)(snes_stats.frames + 1u),
                 (unsigned)scrc_n, (unsigned)scrc_acc);
        mon_printf("%s", line);
    }
    uint32_t t0 = cp0_count_rd();
    uint32_t emu = t0 - t_mark;
    if (IPPU.RenderThisFrame) { t_emu_r += emu; n_r++; snes_stats.rendered++; }
    else                      { t_emu_s += emu; n_s++; }
    WATCHDOG = 0;
    read_pads();
    pump_audio();
    video_finish(0, 0);
    rpt_drain();
    uint32_t w0 = cp0_count_rd();
    if (cfg.frameskip < 0) {
        uint32_t now = cp0_count_rd();
        if (!next1_set) { next1 = now + 1u; next1_set = 1; }
        /* on time, or behind by no more than "late" percent of a frame: the
         * next frame is rendered (frames shorter than the frame time make up
         * the delay); further behind: skipped */
        if ((int32_t)(next1 - now) > -(int32_t)(frame_counts / 100u * (uint32_t)cfg.late)) {
            if (IPPU.SkippedFrames == 0)
                do {
                    WATCHDOG = 0;
                    video_finish(0, 0);
                    now = cp0_count_rd();
                } while ((int32_t)(next1 - now) > 0);
            IPPU.RenderThisFrame = TRUE;
            IPPU.SkippedFrames = 0;
        } else {
            if (IPPU.SkippedFrames < (uint32_t)cfg.maxskip) {
                IPPU.SkippedFrames++;
                IPPU.RenderThisFrame = FALSE;
            } else {
                IPPU.RenderThisFrame = TRUE;
                IPPU.SkippedFrames = 0;
                next1 = now;
            }
        }
        next1 += frame_counts;
    } else {
        if (++IPPU.FrameSkip >= Settings.SkipFrames) {
            IPPU.FrameSkip = 0;
            IPPU.SkippedFrames = 0;
            IPPU.RenderThisFrame = TRUE;
        } else {
            IPPU.SkippedFrames++;
            IPPU.RenderThisFrame = FALSE;
        }
        /* pace to the frame time; more than one frame behind: restart the schedule */
        uint32_t now = cp0_count_rd();
        if (!next1_set || (int32_t)(now - next1) > (int32_t)frame_counts) { next1 = now; next1_set = 1; }
        while ((int32_t)(next1 - cp0_count_rd()) > 0)
            { WATCHDOG = 0; video_finish(0, 0); }
        next1 += frame_counts;
    }
    t_mark = cp0_count_rd();
    t_idle += t_mark - w0;
    /* the blit runs inside the emulated frame (S9xDeinitUpdate); its time
     * is taken off the emulation time of the rendered frames */
    snes_stats.frames++;
    if (++n_frames == 600u) {
        t_emu_r = t_emu_r > t_blit + t_fin_in ? t_emu_r - t_blit - t_fin_in : 0;
        report(t_mark);
    }
}

/* ---- files ------------------------------------------------------------------- */
static char rom_path[128], rom_base[96];

const char *S9xBasename(const char *f)
{
    const char *p = strrchr(f, '/');
    return p ? p + 1 : f;
}

/* battery RAM, real-time clock and snapshot files in /saves; IPS patch
 * and cheat files beside the ROM image */
const char *S9xGetFilename(const char *ext)
{
    static char name[160];
    if (!strcmp(ext, ".ips") || !strcmp(ext, ".cht")) {
        const char *b = S9xBasename(rom_path);
        snprintf(name, sizeof name, "%.*s%s%s", (int)(b - rom_path), rom_path, rom_base, ext);
    } else {
        snprintf(name, sizeof name, "/saves/%s%s", rom_base, ext);
    }
    return name;
}

bool8 S9xOpenSnapshotFile(const char *fname, bool8 read_only, FILE **file)
{
    *file = fopen(fname, read_only ? "rb" : "wb");
    return *file != NULL;
}

void S9xCloseSnapshotFile(FILE *file) { fclose(file); }

void S9xAutoSaveSRAM(void)
{
    f_mkdir("/saves");
    s9x_mem_save_sram(&Memory, S9xGetFilename(".srm"));
}

/* S-DD1 games need the pre-decompressed graphics packs of Snes9x 1.39
 * (SDD1GFX.IDX/.DAT); this port carries none */
void S9xLoadSDD1Data(void)
{
    s9x_mem_free_sdd1(&Memory);
    mon_printf("snes: S-DD1 cartridge, no graphics pack\n");
}

void S9xMessage(int type, int number, const char *message)
{
    (void)type; (void)number;
    mon_printf("snes9x: %s\n", message);
}

/* fatal core error (unknown SPC700 or PPU state the core cannot leave):
 * the fatal-error screen of every Seattle payload */
void S9xExit(void)
{
    guru(GURU_SYS_ERROR, (uint32_t)__builtin_return_address(0), "Snes9x: S9xExit");
}

/* command-line options: this port has none beyond the core's */
void S9xParseArg(char **argv, int *index, int argc) { (void)argv; (void)index; (void)argc; }
void S9xExtraUsage(void) { }

/* unix/unix.cpp _makepath and _splitpath */
void s9x_makepath(char *path, const char *drive, const char *dir, const char *fname, const char *ext)
{
    (void)drive;
    if (dir && *dir) {
        strcpy(path, dir);
        strcat(path, "/");
    } else {
        *path = 0;
    }
    strcat(path, fname);
    if (ext && *ext) {
        strcat(path, ".");
        strcat(path, ext);
    }
}

void s9x_splitpath(const char *path, char *drive, char *dir, char *fname, char *ext)
{
    *drive = 0;
    const char *slash = strrchr(path, '/');
    if (!slash)
        slash = strrchr(path, '\\');
    const char *dot = strrchr(path, '.');
    if (dot && slash && dot < slash)
        dot = NULL;
    if (!slash) {
        strcpy(dir, "");
        strcpy(fname, path);
        if (dot) {
            *(fname + (dot - path)) = 0;
            strcpy(ext, dot + 1);
        } else {
            strcpy(ext, "");
        }
    } else {
        strcpy(dir, path);
        *(dir + (slash - path)) = 0;
        strcpy(fname, slash + 1);
        if (dot) {
            *(fname + (dot - slash) - 1) = 0;
            strcpy(ext, dot + 1);
        } else {
            strcpy(ext, "");
        }
    }
}

/* ---- entry ------------------------------------------------------------------- */
static void settings_init(void)
{
    memset(&Settings, 0, sizeof Settings);
    Settings.JoystickEnabled = FALSE;
    Settings.SoundPlaybackRate = 7;          /* any mode: S9xOpenSoundDevice sets the DSP rate */
    Settings.Stereo = (bool8)cfg.stereo;
    Settings.SixteenBitSound = TRUE;
    Settings.SoundBufferSize = 0;
    Settings.CyclesPercentage = 100;
    Settings.DisableSoundEcho = (bool8)!cfg.echo;
    Settings.InterpolatedSound = (bool8)cfg.interp;
    Settings.APUEnabled = Settings.NextAPUEnabled = (bool8)cfg.apu;
    Settings.H_Max = SNES_CYCLES_PER_SCANLINE;
    Settings.SkipFrames = cfg.frameskip < 0 ? AUTO_FRAMERATE : (uint32)cfg.frameskip + 1u;
    Settings.ShutdownMaster = TRUE;
    Settings.FrameTimePAL = 20000;
    Settings.FrameTimeNTSC = 16667;
    Settings.FrameTime = Settings.FrameTimeNTSC;
    Settings.DisableSampleCaching = FALSE;
    Settings.DisableMasterVolume = FALSE;
    Settings.Mouse = FALSE;
    Settings.SuperScope = FALSE;
    Settings.MultiPlayer5 = FALSE;
    Settings.ControllerOption = SNES_JOYPAD;
    Settings.Transparency = (bool8)cfg.transparency;
    Settings.SixteenBit = TRUE;
    Settings.SupportHiRes = FALSE;
    Settings.NetPlay = FALSE;
    Settings.ThreadSound = FALSE;
    Settings.AutoSaveDelay = cfg.autosave;
    Settings.ApplyCheats = TRUE;
    Settings.TurboMode = FALSE;
    Settings.TurboSkipFrames = 15;
    Settings.HBlankStart = (256 * Settings.H_Max) / SNES_HCOUNTER_MAX;
}

/* the ROM buffer holds MAX_ROM_SIZE bytes plus a 512-byte copier header
 * (patches/snes9x-1.39-seattle.patch, S9X_MAX_ROM_SIZE) */
static long file_size(const char *path)
{
    FILINFO fi;
    if (f_stat(path, &fi) != FR_OK || (fi.fattrib & AM_DIR))
        return -1;
    return (long)fi.fsize;
}

int snes_run(const char *path)
{
    int r = -1;
    snes_quit_to_menu = 0;
    quit_req = 0;
    quit_hold = 0;
    t_game0 = cp0_count_rd();
    t_game = 0;
    if (fs_mounted()) {
        mon_printf("snes: exFAT volume not mounted\n");
        return -1;
    }
    long size = file_size(path);
    if (size < 0) {
        mon_printf("snes: %s not found\n", path);
        return -1;
    }
    if (size > S9X_MAX_ROM_SIZE + 0x200) {
        mon_printf("snes: %s is %u bytes, the ROM buffer holds %u\n", path, (unsigned)size,
                   (unsigned)(S9X_MAX_ROM_SIZE + 0x200));
        return -1;
    }
    strncpy(rom_path, path, sizeof rom_path - 1);
    {   /* file name without extension: the name of the battery RAM file */
        const char *b = S9xBasename(path), *d = strrchr(b, '.');
        size_t n = d ? (size_t)(d - b) : strlen(b);
        if (n > sizeof rom_base - 1) n = sizeof rom_base - 1;
        memcpy(rom_base, b, n);
        rom_base[n] = 0;
    }
    cfg_load();
    settings_init();
    if (arena_open()) {
        mon_printf("snes: heap exhausted before the start\n");
        return -1;
    }
    uint16_t *screen = 0;
    if (!s9x_mem_init(&Memory) || !S9xInitAPU()) {
        mon_printf("snes: core memory allocation failed\n");
        goto out_mem;
    }
    S9xInitSound((int)Settings.SoundPlaybackRate, Settings.Stereo, Settings.SoundBufferSize);
    s9x_vmath_enable = cfg.vmath;
    s9x_strip = cfg.strip;
    s9x_direct = cfg.direct;
    s9x_pal8 = cfg.pal8 && cfg.aspect != 2 && !cfg.vmath;
    s9x_pal8_frame = 0;
    pal_valid = 0;
    fcrc_acc = 0; fcrc_n = 0; scrc_acc = 0; scrc_n = 0;
    S9xSetRenderPixelFormat(s9x_vmath_enable ? RGB555 : RGB565);   /* RGB555: bit 15 free for the colour-math flag */
    if (!s9x_mem_load_rom(&Memory, path)) {
        mon_printf("snes: %s not loaded\n", path);
        goto out_core;
    }
    s9x_mem_load_sram(&Memory, S9xGetFilename(".srm"));

    screen = s9x_malloc(SCR_PITCH * SCR_H * 2u + SCR_W * SCR_H * 2u);
    if (!screen) {
        mon_printf("snes: no memory for the screen buffers\n");
        goto out_core;
    }
    GFX.Pitch = SCR_PITCH;
    GFX.Screen = (uint8 *)screen;
    GFX.SubScreen = (uint8 *)screen + SCR_PITCH * SCR_H;
    GFX.ZBuffer = (uint8 *)screen + SCR_PITCH * SCR_H * 2u;
    GFX.SubZBuffer = GFX.ZBuffer + SCR_W * SCR_H;
    if (!S9xGraphicsInit()) {
        mon_printf("snes: graphics tables not allocated\n");
        goto out_core;
    }
    mon_printf("snes: %s, %u bytes; %u KB of the arena used, %u KB free\n", path, (unsigned)size,
               (unsigned)(((uint32_t)arena_ptr - (uint32_t)arena_lo) / 1024u),
               (unsigned)((ARENA_TOP - (uint32_t)arena_ptr) / 1024u));

    voodoo_mode_override = requested_mode(); /* the ROM menu's request, else the DIP-selected mode */
    voodoo_video_init();
    voodoo_fill(0, 0);
    voodoo_fill(1, 0);
    shown_h = 0;

    irq_install();                            /* exception dispatcher at 0x80000180: fatal errors to guru.c */
    extern int sys_console_enabled;
    int con = sys_console_enabled;
    sys_console_enabled = 0;                  /* the game owns the screen */
    memset(&snes_stats, 0, sizeof snes_stats);
    if (cfg.profile) {
        extern char _start[], __bss_start[];
        uint32_t n = ((uint32_t)__bss_start - (uint32_t)_start) >> PROF_SHIFT;
        memset(snes_prof, 0, sizeof snes_prof);
        snes_stats.prof_base = (uint32_t)_start;
        snes_stats.prof_shift = PROF_SHIFT;
        snes_stats.prof_n = n < PROF_MAX ? n : PROF_MAX;
        extern char s9xa_run[], s9xa_spc_text_end[];
        memset(snes_fprof, 0, sizeof snes_fprof);
        fprof_base = (uint32_t)s9xa_run;
        fprof_n = ((uint32_t)s9xa_spc_text_end - fprof_base) >> 3;   /* cpu65.S, spc700.S */
        if (cfg.fprof) {                          /* the window given by "fprof ADDR" */
            fprof_base = cfg.fprof & ~7u;
            fprof_n = FPROF_MAX;
        }
        if (fprof_n > FPROF_MAX) fprof_n = FPROF_MAX;
    }
    r_head = r_tail = 0;
    n_under = 0;
    if (cfg.sound)
        sound_start();
    S9xSetSoundMute((bool8)!cfg.sound);
    gt_timer_enable(1000, fifo_tick);         /* sound FIFO and the profile */
    irq_take_ownership(ST_IM(2));             /* GT-64010 on hardware interrupt 0, IE on */

    frame_counts = Settings.FrameTime * (CP0_HZ / 1000000u);
    next1_set = 0;
    t_mark = t_frame0 = cp0_count_rd();
    n_frames = 0; n_r = n_s = 0; t_emu_r = t_emu_s = t_blit = t_wait = t_tex = t_quad = t_mix = t_idle = 0; n_blit = 0;
    t_fin_in = t_fin_out = 0; dma_pending = 0; vcrc_n = 0;
    mon_printf("snes: %s %s, frame skip %s, sound %s, 65C816 %s, ESC on the serial line stops\n",
               Settings.PAL ? "PAL" : "NTSC", cfg.aspect == 0 ? "TMU fill" : cfg.aspect == 1 ? "TMU integer" : "LFB 1:1",
               cfg.frameskip < 0 ? "auto" : "fixed", cfg.sound ? "on" : "off",
               cfg.cpu && !Settings.SA1 ? "cpu65.S" : "C core");
    s9x_cpu_asm = cfg.cpu;
    s9x_cpu_setup(cfg.cpuc_lo, cfg.cpuc_hi);
    while (!quit_req)
        s9x_main_loop();
    video_finish(1, 0);
    if (cfg.dma)
        mon_printf("snes: texture DMA transfers not complete after 100 ms: %u\n", (unsigned)snes_stats.dma_fail);

    S9xSetSoundMute(TRUE);
    snd_on = 0;
    dcs_reset_board();                        /* sound driver closed: DSP idle in its boot ROM */
    /* silence: the DSP repeats its 512-word output buffer while the FIFO
     * is empty, so 1,280 zero words (both buffer halves plus the FIFO)
     * leave it playing zeros */
    for (uint32_t i = 0, t0 = cp0_count_rd(); i < 1280u && cp0_count_rd() - t0 < 200u * 75000u; ) {
        WATCHDOG = 0;
        if (!(SND_STAT & ST_FULL)) { SND_FIFO = 0; i++; }
    }
    *(volatile uint32_t *)0xac000c1cu = 0;    /* GT-64010 CPU interrupt mask: timer off */
    cp0_status_w(cp0_status() & ~1u);         /* IE off */
    mon_install_vectors();                    /* monitor exception handler back */
    sys_console_enabled = con;
    f_mkdir("/saves");
    s9x_mem_save_sram(&Memory, S9xGetFilename(".srm"));
    s9x_cpu_hist();
    if (cfg.profile) {
        mon_printf("snes: profile, %u samples, %u-byte buckets from %x\n", (unsigned)snes_stats.prof_samples,
                   1u << PROF_SHIFT, (unsigned)snes_stats.prof_base);
        for (int k = 0; k < 400; k++) {         /* the largest buckets, cleared as printed */
            uint32_t best = 0, bi = 0;
            for (uint32_t i = 0; i < snes_stats.prof_n; i++)
                if (snes_prof[i] > best) { best = snes_prof[i]; bi = i; }
            if (!best)
                break;
            mon_printf("prof %x %u\n", (unsigned)(snes_stats.prof_base + (bi << PROF_SHIFT)), (unsigned)best);
            snes_prof[bi] = 0;
        }
        for (int k = 0; k < (cfg.fprof ? 240 : 80); k++) {   /* the fprof window, 8-byte buckets */
            uint32_t best = 0, bi = 0;
            for (uint32_t i = 0; i < fprof_n; i++)
                if (snes_fprof[i] > best) { best = snes_fprof[i]; bi = i; }
            if (!best)
                break;
            mon_printf("fprof %x %u\n", (unsigned)(fprof_base + (bi << 3)), (unsigned)best);
            snes_fprof[bi] = 0;
        }
    }
    r = 0;
    S9xGraphicsDeinit();
out_core:
    s9x_mem_deinit(&Memory);
    S9xDeinitAPU();
out_mem:
    arena_close();
    return r;
}
