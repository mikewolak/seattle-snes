/* menu.c - SNES game list of the disk build.
 * EPROM Foundry Inc. / Mike Wolak, project Blitz99.
 *
 * The NES game list of nes/menu.c (games_menu, menu_games, the key
 * reader and the title rule) for the SNES: the ROM launch menu's
 * Other Apps item "SNES" makes the disk build (src/main.c, request
 * "SNES") call menu_snes_games. Drawn with vgacon in the video mode the
 * DIP switches select. Input: player 1 joystick up/down moves, button 1
 * or 1 Player Start selects (I/O ASIC IN1 0xB6000024, SYSTEM
 * 0xB6000028, active low); on the serial line "w"/"s" move and Enter
 * selects. Items: "< back" and the SNES images in /snes on the exFAT
 * volume (.smc, .sfc, .swc, .fig), sorted, a scrolling list. A game is
 * run by snes_run (snes/s9x_seattle.c); its quit combination returns to
 * the caller, which goes back to the ROM menu.
 */
#include <stdint.h>
#include <string.h>
#include <strings.h>

#include "vgacon.h"
#include "voodoo.h"
#include "cp0.h"
#include "ff.h"
extern volatile uint32_t *wd_reg;     /* watchdog kick register (uart.c) */

#define IOA_IN1     (*(volatile uint32_t *)0xb6000024u)
#define IOA_SYSTEM  (*(volatile uint32_t *)0xb6000028u)
#define WATCHDOG    (*wd_reg)
#define MS(n)       ((n) * 75000u)          /* CP0 Count at 75 MHz */

#define K_UP     1u
#define K_DOWN   2u
#define K_SELECT 4u

#define MAX_GAMES 64

int  snes_run(const char *path);
extern int snes_quit_to_menu;        /* set by the quit combination in snes/s9x_seattle.c */
int  uart_getc(void);
int  fs_mounted(void);
void mon_printf(const char *fmt, ...);

static char games[MAX_GAMES][64];
static int n_games;

/* joystick and serial, edge-detected with repeat for up/down */
static uint32_t read_keys(void)
{
    uint32_t in1 = ~IOA_IN1, sys = ~IOA_SYSTEM, k = 0;
    if (in1 & 0x01u) k |= K_UP;
    if (in1 & 0x02u) k |= K_DOWN;
    if ((in1 & 0x10u) || (sys & 0x04u)) k |= K_SELECT;
    return k;
}

static uint32_t wait_key(void)
{
    static uint32_t prev, t_rep;
    for (;;) {
        uint32_t t0 = cp0_count_rd();
        while (cp0_count_rd() - t0 < MS(20))
            WATCHDOG = 0;
        int c = uart_getc();
        if (c == 'w' || c == 'W') return K_UP;
        if (c == 's' || c == 'S') return K_DOWN;
        if (c == '\r' || c == '\n' || c == ' ') return K_SELECT;
        uint32_t k = read_keys(), now = cp0_count_rd();
        uint32_t edge = k & ~prev;
        prev = k;
        if (edge) {
            t_rep = now + MS(400);
            return edge;
        }
        if ((k & (K_UP | K_DOWN)) && (int32_t)(now - t_rep) >= 0) {
            t_rep = now + MS(120);
            return k & (K_UP | K_DOWN);
        }
    }
}

static void wait_release(void)
{
    while (read_keys())
        WATCHDOG = 0;
}

static int snes_ext(const char *f)
{
    size_t l = strlen(f);
    if (l < 5) return 0;
    const char *e = f + l - 4;
    return !strcasecmp(e, ".smc") || !strcasecmp(e, ".sfc") || !strcasecmp(e, ".swc") || !strcasecmp(e, ".fig");
}

/* directory listing: up to max names of SNES images in dir, sorted
 * (src/fscmd.c fs_list_nes with the SNES extensions) */
static int list_snes(const char *dir, char (*names)[64], int max)
{
    DIR d; FILINFO fi; int n = 0;
    if (fs_mounted() || f_opendir(&d, dir)) return 0;
    while (n < max && f_readdir(&d, &fi) == FR_OK && fi.fname[0]) {
        size_t l = strlen(fi.fname);
        if ((fi.fattrib & AM_DIR) || l > 63 || fi.fname[0] == '.' || !snes_ext(fi.fname)) continue;
        strcpy(names[n++], fi.fname);
    }
    f_closedir(&d);
    for (int i = 1; i < n; i++)                        /* insertion sort, case-insensitive */
        for (int j = i; j > 0 && strcasecmp(names[j - 1], names[j]) > 0; j--) {
            char t[64]; strcpy(t, names[j]); strcpy(names[j], names[j - 1]); strcpy(names[j - 1], t);
        }
    return n;
}

/* title from a file name: up to " (" or the extension */
static void title(char *out, const char *f)
{
    int i = 0;
    for (; f[i] && i < 60; i++) {
        if ((f[i] == ' ' && f[i + 1] == '(') || (f[i] == '.' && snes_ext(f))) break;
        out[i] = f[i];
    }
    out[i] = 0;
}

static void video_menu_mode(void)
{
    voodoo_mode_override = 0;               /* the DIP-selected mode */
    vgacon_init();
}

static void games_menu(void)
{
    int sel = n_games ? 1 : 0, top = 0;     /* the first game selected: Enter or button 1 starts it */
    for (;;) {
        int rows = (int)vgacon_rows() - 7;
        if (rows < 3) rows = 3;
        if (sel < top) top = sel;
        if (sel >= top + rows) top = sel - rows + 1;
        vgacon_clear();
        vgacon_header("SNES GAMES ON DISK", "EPROM FOUNDRY");
        for (int i = top; i < n_games + 1 && i < top + rows; i++) {
            char t[64];
            if (i == 0) strcpy(t, "< back"); else title(t, games[i - 1]);
            vgacon_gotoxy(4, (unsigned)(3 + (i - top)));
            vgacon_color(i == sel ? VC_BLACK : VC_GREY, i == sel ? VC_YELLOW : VC_BLACK);
            vgacon_puts(i == sel ? " > " : "   ");
            vgacon_puts(t);
            vgacon_puts("   ");
        }
        vgacon_color(VC_DGREY, VC_BLACK);
        vgacon_gotoxy(4, vgacon_rows() - 2);
        vgacon_puts("STICK: MOVE  BUTTON 1 / START: PLAY  BUTTONS 1+2+3+START 0.5 S: QUIT GAME");
        vgacon_color(VC_GREY, VC_BLACK);
        vgacon_flush();
        uint32_t k = wait_key();
        if (k & K_UP)   { sel = sel ? sel - 1 : n_games; continue; }
        if (k & K_DOWN) { sel = sel < n_games ? sel + 1 : 0; continue; }
        wait_release();
        if (sel == 0) {
            mon_printf("menu: back to the ROM menu\n");
            return;
        }
        char path[80];
        strcpy(path, "/snes/");
        strcat(path, games[sel - 1]);
        vgacon_clear();
        vgacon_puts("Loading ");
        vgacon_puts(path);
        vgacon_flush();
        mon_printf("menu: %s\n", path);
        snes_run(path);
        wait_release();
        if (snes_quit_to_menu)          /* the quit combination: back to the ROM menu */
            return;
        video_menu_mode();
    }
}

/* the SNES game list alone (the ROM launch menu's "SNES") */
void menu_snes_games(void)
{
    video_menu_mode();
    n_games = list_snes("/snes", games, MAX_GAMES);
    mon_printf("menu: %u SNES games in /snes\n", (unsigned)n_games);
    games_menu();
}
