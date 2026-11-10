/* s9x_port.h - the interface between the Seattle platform layer (C99)
 * and the Snes9x 1.39 core (C++, compiled unmodified apart from
 * patches/snes9x-1.39-seattle.patch).
 * EPROM Foundry Inc. / Mike Wolak, project Blitz99.
 *
 * Most of the core's port interface has C linkage (display.h, port.h,
 * snes9x.h, soundux.h and apu.h declare it inside START_EXTERN_C) and is
 * used through the core headers snes9x.h, soundux.h and apu.h, which a
 * C compiler accepts. The rest has C++ linkage and is reached here by its
 * Itanium C++ ABI symbol (GCC asm labels); on the o32 ABI a member
 * function takes the object address as its first argument and a C++
 * reference is passed as a pointer, so these C prototypes are
 * call-compatible:
 *
 *   CMemory::Init/Deinit/LoadROM/LoadSRAM/SaveSRAM/FreeSDD1Data (memmap.h)
 *   S9xSetSoundMute, S9xSetPlaybackRate (soundux.h)
 *   S9xOpenSoundDevice, S9xAutoSaveSRAM, _makepath, _splitpath: port
 *   functions the core calls with C++ linkage (soundux.cpp, gfx.cpp,
 *   snapshot.cpp)
 *   operator new[] and sized operator delete (snapshot.cpp, snaporig.cpp)
 *
 * gfx.h and ppu.h use C++ references and are not C; the platform layer
 * sees only the leading members of two of their structures, declared
 * here with the same types and order:
 *   struct SGFX (gfx.h): Screen, SubScreen, ZBuffer, SubZBuffer, Pitch,
 *     the members the port sets before S9xGraphicsInit (HOW2PORT.TXT,
 *     "Initialisation Code");
 *   struct InternalPPU (ppu.h): ColorsChanged ... FrameSkip, of which
 *     the port writes RenderThisFrame, SkippedFrames and FrameSkip in
 *     S9xSyncSpeed (unix/unix.cpp).
 */
#ifndef S9X_PORT_H
#define S9X_PORT_H

#include <stdint.h>
#include <stddef.h>

/* C++-linkage core functions, declared before the core headers so that
 * their later plain declarations keep these symbol names */
typedef unsigned char s9x_bool8;
s9x_bool8 S9xSetSoundMute(s9x_bool8 mute) __asm__("_Z15S9xSetSoundMuteh");
void S9xSetPlaybackRate(unsigned int rate) __asm__("_Z18S9xSetPlaybackRatej");
void S9xResetSound(s9x_bool8 full) __asm__("_Z13S9xResetSoundh");

#include "snes9x.h"
#include "soundux.h"
#include "apu.h"

/* CMemory member functions; the object is the global Memory (globals.cpp) */
extern char Memory;                     /* class CMemory; used by address only */
bool8 s9x_mem_init(void *m) __asm__("_ZN7CMemory4InitEv");
void  s9x_mem_deinit(void *m) __asm__("_ZN7CMemory6DeinitEv");
bool8 s9x_mem_load_rom(void *m, const char *name) __asm__("_ZN7CMemory7LoadROMEPKc");
bool8 s9x_mem_load_sram(void *m, const char *name) __asm__("_ZN7CMemory8LoadSRAMEPKc");
bool8 s9x_mem_save_sram(void *m, const char *name) __asm__("_ZN7CMemory8SaveSRAMEPKc");
void  s9x_mem_free_sdd1(void *m) __asm__("_ZN7CMemory12FreeSDD1DataEv");

/* C-linkage core functions whose headers are C++ only (gfx.h, cpuexec.h) */
bool8 S9xGraphicsInit(void);
void  S9xGraphicsDeinit(void);
bool8 S9xSetRenderPixelFormat(int format);
void  S9xMainLoop(void);
void  S9xReset(void);

/* leading members of struct SGFX (gfx.h) */
struct s9x_gfx_head {
    uint8 *Screen;
    uint8 *SubScreen;
    uint8 *ZBuffer;
    uint8 *SubZBuffer;
    uint32 Pitch;
};
extern struct s9x_gfx_head GFX;

/* leading members of struct InternalPPU (ppu.h) */
struct s9x_ippu_head {
    bool8  ColorsChanged;
    uint8  HDMA;
    bool8  HDMAStarted;
    uint8  MaxBrightness;
    bool8  LatchedBlanking;
    bool8  OBJChanged;
    bool8  RenderThisFrame;
    bool8  DirectColourMapsNeedRebuild;
    uint32 FrameCount;
    uint32 RenderedFramesCount;
    uint32 DisplayedRenderedFrameCount;
    uint32 SkippedFrames;
    uint32 FrameSkip;
};
extern struct s9x_ippu_head IPPU;

/* port functions with C++ linkage, defined in s9x_seattle.c */
bool8 S9xOpenSoundDevice(int mode, bool8 stereo, int buffer_size) __asm__("_Z18S9xOpenSoundDeviceihi");
void  S9xAutoSaveSRAM(void) __asm__("_Z15S9xAutoSaveSRAMv");
void  s9x_makepath(char *path, const char *drive, const char *dir, const char *fname,
                   const char *ext) __asm__("_Z9_makepathPcPKcS1_S1_S1_");
void  s9x_splitpath(const char *path, char *drive, char *dir, char *fname,
                    char *ext) __asm__("_Z10_splitpathPKcPcS1_S1_S1_");
void *s9x_new_array(size_t n) __asm__("_Znaj");
void  s9x_delete_sized(void *p, size_t n) __asm__("_ZdlPvj");

/* the core's malloc and free (Makefile: -Dmalloc=s9x_malloc -Dfree=s9x_free) */
void *s9x_malloc(size_t n);
void  s9x_free(void *p);

#endif
