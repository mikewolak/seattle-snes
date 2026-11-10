/* tile16.S - DrawTile16 and DrawClippedTile16 of the Snes9x 1.39 tile
 * renderer in R5000 assembly.
 * EPROM Foundry Inc. / Mike Wolak, project Blitz99.
 * The pixels written are those of the two functions in the core's tile.cpp as
 * changed by patches/snes9x-1.39-seattle.patch (work derived from Snes9x,
 * Snes9x licence).
 *
 * void s9x_tile16(uint32 Tile, uint32 Offset, uint32 StartLine, uint32 LineCount);
 *
 * TILE_PREAMBLE of tile.h: the tile's cache entry; a tile not yet
 * converted (BG.Buffered 0) or drawn in direct-colour mode is passed to
 * the core's function (tail call, arguments unchanged), a blank tile
 * returns. GFX.ScreenColors is set as the core sets it.
 *
 * Each tile row is two words of the tile cache, one pixel value per byte
 * (pixel k of the row: byte k of the first word for k < 4, of the second
 * for k >= 4; little-endian). A group of four pixels and four depth bytes
 * (unaligned word at GFX.DB + Offset) is tested as in tile.cpp: byte k of
 * ((Z1 - 1) x 0x01010101 | 0x80808080) - depth has bit 7 set exactly when
 * depth byte k is below Z1 (depths are below 128). No byte below Z1: the
 * group is skipped. Every byte below Z1 and no pixel 0: four palette
 * entries stored and the depth word set to Z2 x 0x01010101. Otherwise
 * each pixel whose depth is below Z1 and whose value is not 0 is written
 * with its depth byte. A tile converted as S9X_OPAQUE_TILE (no pixel 0)
 * skips the tests for pixel 0. A horizontally flipped tile takes pixel k
 * from byte 3 - k of the other word; a vertically flipped tile walks the
 * rows upward from row 7 - StartLine / 8.
 *
 * Registers in the row loops: a0 screen (uint16, GFX.S + 2 Offset), a1
 * depth (GFX.DB + Offset), a2 GFX.PPL, a3 depth end, t3 row step (+8 or
 * -8), t4 tile row, t5 colours, t6 the Z1 compare word, t7 Z2 x
 * 0x01010101, t8 0x80808080, t9 0x01010101; t0, t1 the row's two words;
 * t2, v0, v1 scratch. Leaf functions without a stack frame. Integer
 * registers hold 32-bit values only: the interrupt entry (irq_vec.S)
 * saves and restores 32 bits of each.
 */
#include "s9x_offs.h"

    .set    noreorder
    .set    mips3
    .text

/* shf R, W, K: R = byte K of W shifted to bit 1, other bits of W around it */
.macro shf r, w, k
  .if \k == 0
    sll     \r, \w, 1
  .else
    srl     \r, \w, (8 * \k - 1)
  .endif
.endm

/* idx2 R, W, K: R = 2 x byte K of W (the palette offset) */
.macro idx2 r, w, k
    shf     \r, \w, \k
    andi    \r, \r, 0x1fe
.endm

/* full W, SO, DO, K0..K3, N: four pixels (column j from byte Kj of W) at
 * a0 + SO, depth word at a1 + DO set to Z2; entered with v0 = shf of byte
 * K0 (the delay slot of the branch before it); ends with the branch to N */
.macro full w, so, do, k0, k1, k2, k3, n
    andi    $v0, $v0, 0x1fe
    addu    $v0, $t5, $v0
    idx2    $v1, \w, \k1
    lhu     $v0, 0($v0)
    addu    $v1, $t5, $v1
    idx2    $t2, \w, \k2
    lhu     $v1, 0($v1)
    sh      $v0, \so($a0)
    addu    $t2, $t5, $t2
    idx2    $v0, \w, \k3
    lhu     $t2, 0($t2)
    sh      $v1, \so+2($a0)
    addu    $v0, $t5, $v0
    lhu     $v0, 0($v0)
    sh      $t2, \so+4($a0)
    swl     $t7, \do+3($a1)
    swr     $t7, \do($a1)
    b       \n
    sh      $v0, \so+6($a0)
.endm

/* pixb W, SO, DO, J, K, LBL: the body of one pixel, entered in the delay
 * slot of the depth branch: column J (byte K of W) written if not 0 */
.macro pixb w, so, do, j, k, lbl
    shf     $v1, \w, \k
    andi    $v1, $v1, 0x1fe
    beqz    $v1, \lbl
    addu    $v1, $t5, $v1
    lhu     $v1, 0($v1)
    sb      $t7, \do+\j($a1)
    sh      $v1, \so+2*\j($a0)
\lbl:
.endm

/* pix1 W, LT, SO, DO, J, K, LBL: column J (byte K of W) if bit 7 of byte J
 * of LT is set (LT has no other bits) and the pixel is not 0 */
.macro pix1 w, lt, so, do, j, k, lbl
  .if \j == 3
    bgez    \lt, \lbl
  .else
    sll     $v0, \lt, (24 - 8 * \j)
    bgez    $v0, \lbl
  .endif
    pixb    \w, \so, \do, \j, \k, \lbl
.endm

/* group W, SO, DO, K0..K3, OPAQUE, label prefix: one group of four */
.macro group w, so, do, k0, k1, k2, k3, opq, p
  .if \opq == 0
    beqz    \w, \p\()_n
  .endif
    lwl     $t2, \do+3($a1)
    lwr     $t2, \do($a1)
    subu    $t2, $t6, $t2
    and     $t2, $t2, $t8
  .if \opq == 0
    bne     $t2, $t8, \p\()_m
    subu    $v0, \w, $t9
    nor     $v1, \w, $0
    and     $v0, $v0, $v1
    and     $v0, $v0, $t8
    bnez    $v0, \p\()_s             /* a pixel 0: per pixel, every depth below Z1 */
    shf     $v0, \w, \k0
  .else
    bne     $t2, $t8, \p\()_m
    shf     $v0, \w, \k0
  .endif
    full    \w, \so, \do, \k0, \k1, \k2, \k3, \p\()_n
\p\()_m:
    beqz    $t2, \p\()_n
    sll     $v0, $t2, 24
    bgez    $v0, \p\()_0
\p\()_s:
    pixb    \w, \so, \do, 0, \k0, \p\()_0
    pix1    \w, $t2, \so, \do, 1, \k1, \p\()_1
    pix1    \w, $t2, \so, \do, 2, \k2, \p\()_2
    pix1    \w, $t2, \so, \do, 3, \k3, \p\()_3
\p\()_n:
.endm

/* rows FLIPH, OPAQUE, CLIP, prefix: the row loop of one tile variant.
 * CLIP: the row's words are masked with s0 (left group) and s1 (right
 * group), and the loop ends at ct_ret */
.macro rows fh, opq, clip, p
\p\()_row:
  .if \fh == 0
    lw      $t0, 0($t4)
    lw      $t1, 4($t4)
  .else
    lw      $t0, 4($t4)
    lw      $t1, 0($t4)
  .endif
  .if \clip
    and     $t0, $t0, $s0
    and     $t1, $t1, $s1
  .endif
  .if \fh == 0
    group   $t0, 0, 0, 0, 1, 2, 3, \opq, \p\()a
    group   $t1, 8, 4, 0, 1, 2, 3, \opq, \p\()b
  .else
    group   $t0, 0, 0, 3, 2, 1, 0, \opq, \p\()a
    group   $t1, 8, 4, 3, 2, 1, 0, \opq, \p\()b
  .endif
    addu    $t4, $t4, $t3
    addu    $a1, $a1, $a2
    addu    $a0, $a0, $a2
    bne     $a1, $a3, \p\()_row
    addu    $a0, $a0, $a2
  .if \clip
    b       ct_ret
    nop
  .else
    jr      $ra
    nop
  .endif
.endm

/* bswap R: the four bytes of R reversed (SWAP_DWORD of gfx.h) */
.macro bswap r
    srl     $v0, \r, 24
    andi    $v1, \r, 0xff00
    sll     $v1, $v1, 8
    or      $v0, $v0, $v1
    srl     $v1, \r, 8
    andi    $v1, $v1, 0xff00
    or      $v0, $v0, $v1
    sll     \r, \r, 24
    or      \r, \r, $v0
.endm

/* setup CLIP, RET, CORE: TILE_PREAMBLE and the loop registers from a0
 * Tile, a1 Offset, a2 StartLine, a3 LineCount; a blank tile or no line
 * goes to RET, a tile left to the core to CORE (a0 and a1 unchanged
 * there). Then the row loop of the variant: tn, tf, on, of, or with CLIP
 * cn, cf (s0 and s1 byte-reversed for a horizontally flipped tile). */
.macro setup clip, ret, core
    lui     $t9, %hi(BG)
    addiu   $t9, $t9, %lo(BG)
    lw      $t0, BG_TileShift($t9)
    lw      $t1, BG_TileAddress($t9)
    andi    $v0, $a0, 0x3ff
    sllv    $v0, $v0, $t0
    andi    $v1, $a0, 0x100            /* (Tile & 0x1ff) >= 256 */
    beqz    $v1, 1f
    addu    $v0, $v0, $t1
    lw      $v1, BG_NameSelect($t9)
    addu    $v0, $v0, $v1
1:  andi    $v0, $v0, 0xffff           /* TileAddr */
    srlv    $t0, $v0, $t0               /* TileNumber */
    lw      $t1, BG_Buffered($t9)
    addu    $t1, $t1, $t0
    lbu     $t8, 0($t1)
    lbu     $t2, BG_DirectColourMode($t9)
    beqz    $t8, \core                 /* not converted: the core converts and draws */
    li      $v1, TILE_BLANK
    beq     $t8, $v1, \ret
    nop
    bnez    $t2, \core                 /* direct colour: the core */
    lw      $t2, BG_PaletteMask($t9)
    /* GFX.ScreenColors = &IPPU.ScreenColors[(((Tile >> 10) & PaletteMask) << PaletteShift) + StartPalette] */
    lw      $v1, BG_PaletteShift($t9)
    srl     $v0, $a0, 10
    and     $v0, $v0, $t2
    lw      $t2, BG_StartPalette($t9)
    sllv    $v0, $v0, $v1
    addu    $v0, $v0, $t2
    sll     $v0, $v0, 1
    lui     $t5, %hi(IPPU + IPPU_ScreenColors)
    addiu   $t5, $t5, %lo(IPPU + IPPU_ScreenColors)
    addu    $t5, $t5, $v0               /* colours */
    lw      $t4, BG_Buffer($t9)
    sll     $t0, $t0, 6
    addu    $t4, $t4, $t0               /* pCache */
    lui     $t9, %hi(GFX)
    addiu   $t9, $t9, %lo(GFX)
    sw      $t5, GFX_ScreenColors($t9)
    lbu     $t6, GFX_Z1($t9)
    lbu     $t7, GFX_Z2($t9)
    lw      $v0, GFX_S($t9)
    lw      $v1, GFX_DB($t9)
    lw      $t2, GFX_PPL($t9)
    beqz    $t6, \core                 /* Z1 0: the core */
    addiu   $t6, $t6, -1
    multu   $a3, $t2                   /* LineCount x PPL */
    sll     $t0, $t6, 8                /* (Z1 - 1) x 0x01010101, Z1 - 1 below 256 */
    or      $t6, $t6, $t0
    sll     $t0, $t6, 16
    or      $t6, $t6, $t0
    sll     $t0, $t7, 8                /* Z2 x 0x01010101 */
    or      $t7, $t7, $t0
    sll     $t0, $t7, 16
    or      $t7, $t7, $t0
    addu    $v1, $v1, $a1               /* depth */
    sll     $a1, $a1, 1
    addu    $v0, $v0, $a1               /* screen */
    andi    $t1, $a0, 0x8000           /* V_FLIP */
    li      $t3, 8
    beqz    $t1, 2f
    addu    $t0, $t4, $a2               /* pCache + StartLine */
    subu    $t0, $t4, $a2
    addiu   $t0, $t0, 56               /* pCache + 56 - StartLine */
    li      $t3, -8
2:  mflo    $a3                       /* LineCount x PPL */
    beqz    $a3, \ret
    move    $t4, $t0
    move    $a2, $t2                   /* PPL */
    addu    $a3, $a3, $v1               /* depth end */
    move    $a1, $v1
    andi    $t1, $a0, 0x4000           /* H_FLIP */
    move    $a0, $v0
    lui     $t0, 0x8080
    ori     $t0, $t0, 0x8080
    or      $t6, $t6, $t0               /* (Z1 - 1) x 0x01010101 | 0x80808080 */
    lui     $t9, 0x0101
    ori     $t9, $t9, 0x0101           /* 0x01010101 */
  .if \clip
    beqz    $t1, cn_row
    move    $t8, $t0                   /* 0x80808080 */
    bswap   $s0
    bswap   $s1
    b       cf_row
    nop
  .else
    li      $v0, TILE_OPAQUE
    beq     $t8, $v0, 3f
    move    $t8, $t0                   /* 0x80808080 */
    bnez    $t1, tf_row
    nop
    b       tn_row
    nop
3:  bnez    $t1, of_row
    nop
    b       on_row
    nop
  .endif
.endm

    .globl  s9x_tile16
    .ent    s9x_tile16
s9x_tile16:
    setup   0, t_ret, t_core
t_ret:
    jr      $ra
    nop
t_core:
    j       _Z10DrawTile16jjjj
    nop

    rows    0, 0, 0, tn
    rows    1, 0, 0, tf
    rows    0, 1, 0, on
    rows    1, 1, 0, of
    .end    s9x_tile16

/* void s9x_ctile16(uint32 Tile, uint32 Offset, uint32 StartPixel,
 *                  uint32 Width, uint32 StartLine, uint32 LineCount);
 *
 * DrawClippedTile16: the pixels StartPixel to StartPixel + Width - 1 of
 * each row. TILE_CLIP_PREAMBLE of tile.h: the cache word of the left
 * group is masked with d1, of the right group with d2 (HeadMask and
 * TailMask of the core, one byte of 0xff per pixel kept); a masked-out
 * pixel has the value 0 and is not written. s0 holds d1, s1 d2; s0, s1
 * and the arguments a2, a3 are kept in the four argument words of the
 * caller's frame (o32), so that a tile left to the core is passed to
 * DrawClippedTile16 with the arguments unchanged. */
    .globl  s9x_ctile16
    .ent    s9x_ctile16
s9x_ctile16:
    sw      $s0, 0($sp)
    sw      $s1, 4($sp)
    sw      $a2, 8($sp)
    sw      $a3, 12($sp)
    lui     $t0, %hi(HeadMask)
    addiu   $t0, $t0, %lo(HeadMask)
    lui     $t1, %hi(TailMask)
    addiu   $t1, $t1, %lo(TailMask)
    addu    $t2, $a2, $a3               /* StartPixel + Width */
    move    $s0, $0
    sltiu   $v0, $a2, 4
    beqz    $v0, 1f                   /* StartPixel >= 4: d1 = 0 */
    sll     $v1, $a2, 2
    addu    $v1, $t0, $v1
    lw      $s0, 0($v1)                /* HeadMask [StartPixel] */
    sltiu   $v0, $t2, 4
    beqz    $v0, 1f
    sll     $v1, $t2, 2
    addu    $v1, $t1, $v1
    lw      $v1, 0($v1)                /* TailMask [StartPixel + Width] */
    and     $s0, $s0, $v1
1:  sltiu   $v0, $t2, 5
    bnez    $v0, 3f                   /* StartPixel + Width <= 4: d2 = 0 */
    move    $s1, $0
    sltiu   $v0, $a2, 5
    bnez    $v0, 2f                   /* StartPixel <= 4: all of the head */
    li      $s1, -1
    sll     $v1, $a2, 2
    addu    $v1, $t0, $v1
    lw      $s1, -16($v1)              /* HeadMask [StartPixel - 4] */
2:  sll     $v1, $t2, 2
    addu    $v1, $t1, $v1
    lw      $v1, -16($v1)              /* TailMask [StartPixel + Width - 4] */
    and     $s1, $s1, $v1
3:  lw      $a2, 16($sp)               /* StartLine */
    lw      $a3, 20($sp)               /* LineCount */
    setup   1, ct_ret, ct_core
ct_ret:
    lw      $s0, 0($sp)
    jr      $ra
    lw      $s1, 4($sp)
ct_core:
    lw      $a2, 8($sp)
    lw      $a3, 12($sp)
    lw      $s0, 0($sp)
    j       _Z17DrawClippedTile16jjjjjj
    lw      $s1, 4($sp)

    rows    0, 0, 1, cn
    rows    1, 0, 1, cf
    .end    s9x_ctile16

/* void s9x_tilerun16(const uint16 *t, uint32 n, uint32 Offset,
 *                    uint32 VirtAlign, uint32 Lines, uint32 z);
 *
 * n unclipped 8 x 8 tiles of one background row, the middle loop of
 * DrawBackground in the core's gfx.cpp: tile map words t [0 .. n - 1],
 * the first tile at Offset, each following tile 8 pixels to the right,
 * rows from VirtAlign (8 x the first tile row), Lines lines. z: the
 * depth of a tile without the priority bit (bit 13 of the map word) in
 * bits 7-0, with it in bits 15-8; a tile is drawn with GFX.Z1 = GFX.Z2 =
 * that depth. Both depths are above 0, BG.DirectColourMode and
 * BG.NameSelect are 0 (DrawBackground sets NameSelect 0).
 *
 * The values that s9x_tile16 derives for every tile from BG and GFX are
 * taken once and kept in the stack frame. Per tile: the map word, the
 * tile number, the state byte of the tile cache; a blank tile is passed
 * over; a tile not yet converted is drawn by the core's DrawTile16
 * (which converts it); any other tile has its colours, depth words and
 * cache row set and its rows drawn by the row loops of s9x_tile16.
 * GFX.ScreenColors is stored for every drawn tile as TILE_PREAMBLE does.
 *
 * s0 map pointer, s1 map end, s2 screen of the tile, s3 depth of the
 * tile, s4 Lines x PPL, s5 VirtAlign, s6 GFX; ra holds r_skip while the
 * tiles are drawn, the row loops return there. */
#define R_SHIFT     16
#define R_TADDR     20
#define R_BUFFERED  24
#define R_BUFFER    28
#define R_PMASK     32
#define R_PSHIFT    36
#define R_CBASE     40
#define R_ZM        44      /* two words, by priority */
#define R_Z2        52      /* two words, by priority */
#define R_S0        60
#define R_RA        88
#define R_FRAME     96
#define R_LINES     (R_FRAME + 16)
#define R_Z         (R_FRAME + 20)

/* rconst: the constants of the row loops */
.macro rconst
    lui     $t8, 0x8080
    ori     $t8, $t8, 0x8080
    lui     $t9, 0x0101
    ori     $t9, $t9, 0x0101
    lw      $a2, GFX_PPL($s6)
.endm

    .globl  s9x_tilerun16
    .ent    s9x_tilerun16
s9x_tilerun16:
    addiu   $sp, $sp, -R_FRAME
    sw      $s0, R_S0($sp)
    sw      $s1, R_S0+4($sp)
    sw      $s2, R_S0+8($sp)
    sw      $s3, R_S0+12($sp)
    sw      $s4, R_S0+16($sp)
    sw      $s5, R_S0+20($sp)
    sw      $s6, R_S0+24($sp)
    sw      $ra, R_RA($sp)
    move    $s0, $a0
    sll     $a1, $a1, 1
    addu    $s1, $a0, $a1
    move    $s5, $a3
    lui     $s6, %hi(GFX)
    addiu   $s6, $s6, %lo(GFX)
    lw      $v0, GFX_S($s6)
    sll     $t0, $a2, 1
    addu    $s2, $v0, $t0
    lw      $v0, GFX_DB($s6)
    addu    $s3, $v0, $a2
    rconst
    lw      $t0, R_LINES($sp)
    multu   $t0, $a2
    lui     $t1, %hi(BG)
    addiu   $t1, $t1, %lo(BG)
    lw      $v0, BG_TileShift($t1)
    lw      $v1, BG_TileAddress($t1)
    sw      $v0, R_SHIFT($sp)
    sw      $v1, R_TADDR($sp)
    lw      $v0, BG_Buffered($t1)
    lw      $v1, BG_Buffer($t1)
    sw      $v0, R_BUFFERED($sp)
    sw      $v1, R_BUFFER($sp)
    lw      $v0, BG_PaletteMask($t1)
    lw      $v1, BG_PaletteShift($t1)
    sw      $v0, R_PMASK($sp)
    sw      $v1, R_PSHIFT($sp)
    lw      $v0, BG_StartPalette($t1)
    lui     $v1, %hi(IPPU + IPPU_ScreenColors)
    addiu   $v1, $v1, %lo(IPPU + IPPU_ScreenColors)
    sll     $v0, $v0, 1
    addu    $v0, $v0, $v1
    sw      $v0, R_CBASE($sp)
    mflo    $s4                       /* Lines x PPL */
    lw      $t0, R_Z($sp)
    andi    $t1, $t0, 0xff             /* depth without the priority bit */
    sll     $v0, $t1, 8
    or      $t1, $t1, $v0
    sll     $v0, $t1, 16
    or      $t1, $t1, $v0               /* z x 0x01010101 */
    sw      $t1, R_Z2($sp)
    subu    $t1, $t1, $t9
    or      $t1, $t1, $t8               /* (z - 1) x 0x01010101 | 0x80808080 */
    sw      $t1, R_ZM($sp)
    srl     $t1, $t0, 8
    andi    $t1, $t1, 0xff             /* depth with the priority bit */
    sll     $v0, $t1, 8
    or      $t1, $t1, $v0
    sll     $v0, $t1, 16
    or      $t1, $t1, $v0
    sw      $t1, R_Z2+4($sp)
    subu    $t1, $t1, $t9
    or      $t1, $t1, $t8
    lui     $ra, %hi(r_skip)
    addiu   $ra, $ra, %lo(r_skip)       /* return address of the row loops */
    b       r_next
    sw      $t1, R_ZM+4($sp)

r_skip:
    addiu   $s2, $s2, 16
    addiu   $s3, $s3, 8
r_next:
    beq     $s0, $s1, r_done
    lw      $t0, R_SHIFT($sp)
    lhu     $a0, 0($s0)                /* Tile */
    lw      $t1, R_TADDR($sp)
    addiu   $s0, $s0, 2
    andi    $v0, $a0, 0x3ff
    sllv    $v0, $v0, $t0
    addu    $v0, $v0, $t1
    andi    $v0, $v0, 0xffff           /* TileAddr */
    lw      $t1, R_BUFFERED($sp)
    srlv    $v0, $v0, $t0               /* TileNumber */
    addu    $t1, $t1, $v0
    lbu     $v1, 0($t1)
    lw      $t2, R_PMASK($sp)
    beqz    $v1, r_core               /* not converted */
    xori    $t1, $v1, TILE_BLANK
    beqz    $t1, r_skip
    srl     $t5, $a0, 10
    and     $t5, $t5, $t2
    lw      $t2, R_PSHIFT($sp)
    lw      $t1, R_CBASE($sp)
    sllv    $t5, $t5, $t2
    sll     $t5, $t5, 1
    addu    $t5, $t5, $t1               /* colours */
    sw      $t5, GFX_ScreenColors($s6)
    srl     $t2, $a0, 11
    andi    $t2, $t2, 4                /* 4 x priority bit */
    addu    $t2, $sp, $t2
    lw      $t6, R_ZM($t2)
    lw      $t7, R_Z2($t2)
    lw      $t4, R_BUFFER($sp)
    sll     $v0, $v0, 6
    addu    $t4, $t4, $v0               /* pCache */
    andi    $t2, $a0, 0x8000           /* V_FLIP */
    li      $t3, 8
    beqz    $t2, 1f
    addu    $t0, $t4, $s5               /* pCache + VirtAlign */
    subu    $t0, $t4, $s5
    addiu   $t0, $t0, 56               /* pCache + 56 - VirtAlign */
    li      $t3, -8
1:  move    $t4, $t0
    andi    $t2, $a0, 0x4000           /* H_FLIP */
    move    $a0, $s2
    move    $a1, $s3
    xori    $v1, $v1, TILE_OPAQUE
    beqz    $v1, 3f
    addu    $a3, $s3, $s4               /* depth end */
    bnez    $t2, tf_row              /* the row loops return to r_skip (ra) */
    nop
    b       tn_row
    nop
3:  bnez    $t2, of_row
    nop
    b       on_row
    nop

r_core:                                 /* GFX.Z1 = GFX.Z2 = depth; DrawTile16 (Tile, Offset, VirtAlign, Lines) */
    srl     $t2, $a0, 13
    andi    $t2, $t2, 1
    addu    $t2, $sp, $t2
    lbu     $t2, R_Z($t2)
    lw      $v0, GFX_DB($s6)
    sb      $t2, GFX_Z1($s6)
    sb      $t2, GFX_Z2($s6)
    subu    $a1, $s3, $v0
    move    $a2, $s5
    jal     _Z10DrawTile16jjjj
    lw      $a3, R_LINES($sp)
    rconst
    lui     $ra, %hi(r_skip)
    addiu   $ra, $ra, %lo(r_skip)
    b       r_skip
    nop

r_done:
    lw      $s0, R_S0($sp)
    lw      $s1, R_S0+4($sp)
    lw      $s2, R_S0+8($sp)
    lw      $s3, R_S0+12($sp)
    lw      $s4, R_S0+16($sp)
    lw      $s5, R_S0+20($sp)
    lw      $s6, R_S0+24($sp)
    lw      $ra, R_RA($sp)
    jr      $ra
    addiu   $sp, $sp, R_FRAME
    .end    s9x_tilerun16
