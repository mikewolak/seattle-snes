/* tile8.S - tile renderers of the Snes9x 1.39 core for a frame of 8-bit
 * palette indices, in R5000 assembly.
 * EPROM Foundry Inc. / Mike Wolak, project Blitz99.
 * Counterparts of s9x_tile16, s9x_ctile16 and s9x_tilerun16 (tile16.S)
 * and through them of DrawTile16, DrawClippedTile16 and the middle loop
 * of DrawBackground in the core as changed by
 * patches/snes9x-1.39-seattle.patch (work derived from Snes9x, Snes9x
 * licence).
 *
 * void s9x_tile8(uint32 Tile, uint32 Offset, uint32 StartLine, uint32 LineCount);
 * void s9x_ctile8(uint32 Tile, uint32 Offset, uint32 StartPixel, uint32 Width,
 *                 uint32 StartLine, uint32 LineCount);
 * void s9x_tilerun8(const uint16 *t, uint32 n, uint32 Offset, uint32 VirtAlign,
 *                   uint32 Lines, uint32 z);
 *
 * The screen (GFX.S) holds one byte per pixel at GFX.S + Offset, the same
 * offset and line pitch (GFX.PPL) as the depth buffer GFX.DB. A pixel of
 * value p (not 0) of a tile is written as the byte p + palette base,
 * palette base = (((Tile >> 10) & BG.PaletteMask) << BG.PaletteShift) +
 * BG.StartPalette: the index of the colour that the 16-bit renderers read
 * from IPPU.ScreenColors. The sum is below 256 for every tile of 2 or 4
 * bits a pixel, so the four pixels of a group are formed by one addition
 * of the cache word and the palette base in each byte. The depth test and
 * the depth bytes written are those of tile16.S. GFX.ScreenColors is not
 * written (nothing reads it while a frame is drawn this way).
 *
 * A group of four pixels: lt = byte k bit 7 set where depth byte k is
 * below Z1 (as tile16.S), for a tile with pixels of value 0 also only
 * where pixel k is not 0 (bit 7 of ((w & 0x7f7f7f7f) + 0x7f7f7f7f) | w).
 * No bit: nothing. All four: the pixel word and the depth word stored.
 * Else both words merged under the byte mask lt | (lt - (lt >> 7)).
 * A horizontally flipped tile has the bytes of each cache word reversed
 * first; the clip masks of s9x_ctile8 then apply in column order for
 * every tile.
 *
 * A tile not yet converted is converted by the core's ConvertTile and
 * its state byte stored, as TILE_PREAMBLE does, then drawn.
 *
 * Registers in the row loops: a0 screen, a1 depth, a2 GFX.PPL, a3 depth
 * end, t3 row step (+8 or -8), t4 tile row, t5 palette base x 0x01010101,
 * t6 the Z1 compare word, t7 Z2 x 0x01010101, t8 0x80808080, t9
 * 0x7f7f7f7f; t0, t1 the row's two words; t2, v0, v1, at scratch; s0, s1
 * the clip masks of s9x_ctile8. Integer registers hold 32-bit values only
 * (the interrupt entry saves 32 bits of each).
 */
#include "s9x_offs.h"

    .set    noreorder
    .set    noat
    .set    mips3
    .text

/* group8 W, SO, DO, OPAQUE, label prefix: one group of four */
.macro group8 w, so, do, opq, p
  .if \opq == 0
    beqz    \w, \p\()_n
  .endif
    lwl     $t2, \do+3($a1)
    lwr     $t2, \do($a1)
    subu    $t2, $t6, $t2
  .if \opq == 0
    and     $v0, \w, $t9
    addu    $v0, $v0, $t9
    or      $v0, $v0, \w
    and     $t2, $t2, $v0
  .endif
    and     $t2, $t2, $t8
    bne     $t2, $t8, \p\()_m
    addu    $v0, \w, $t5                /* pixel + palette base in each byte */
    swl     $v0, \so+3($a0)
    swr     $v0, \so($a0)
    swl     $t7, \do+3($a1)
    b       \p\()_n
    swr     $t7, \do($a1)
\p\()_m:
    beqz    $t2, \p\()_n
    srl     $v1, $t2, 7
    subu    $v1, $t2, $v1
    or      $v1, $v1, $t2               /* 0xff in each byte to write */
    lwl     $at, \so+3($a0)
    lwr     $at, \so($a0)
    xor     $v0, $v0, $at
    and     $v0, $v0, $v1
    xor     $v0, $v0, $at
    swl     $v0, \so+3($a0)
    swr     $v0, \so($a0)
    lwl     $at, \do+3($a1)
    lwr     $at, \do($a1)
    xor     $v0, $t7, $at
    and     $v0, $v0, $v1
    xor     $v0, $v0, $at
    swl     $v0, \do+3($a1)
    swr     $v0, \do($a1)
\p\()_n:
.endm

/* bswap R: the four bytes of R reversed */
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

/* rows8 FLIPH, OPAQUE, CLIP, prefix, RET: the row loop of one variant;
 * CLIP: the words masked with s0 (left group) and s1 (right group) and
 * the loop left through RET, else by jr ra */
.macro rows8 fh, opq, clip, p, ret
\p\()_row:
  .if \fh == 0
    lw      $t0, 0($t4)
    lw      $t1, 4($t4)
  .else
    lw      $t0, 4($t4)
    lw      $t1, 0($t4)
    bswap   $t0
    bswap   $t1
  .endif
  .if \clip
    and     $t0, $t0, $s0
    and     $t1, $t1, $s1
  .endif
    group8  $t0, 0, 0, \opq, \p\()a
    group8  $t1, 4, 4, \opq, \p\()b
    addu    $t4, $t4, $t3
    addu    $a1, $a1, $a2
  .if \clip
    bne     $a1, $a3, \p\()_row
    addu    $a0, $a0, $a2
    b       \ret
    nop
  .else
    bne     $a1, $a3, \p\()_row
    addu    $a0, $a0, $a2
    jr      $ra
    nop
  .endif
.endm

/* x4 R, T: R = R x 0x01010101 (R below 256); T scratch */
.macro x4 r, t
    sll     \t, \r, 8
    or      \r, \r, \t
    sll     \t, \r, 16
    or      \r, \r, \t
.endm

/* setup8 CLIP, RET, CONV, prefix: TILE_PREAMBLE and the loop registers
 * from a0 Tile, a1 Offset, a2 StartLine, a3 LineCount; a blank tile or
 * no line goes to RET; a tile not converted to CONV with v0 TileAddr, t0
 * TileNumber, t1 the address of its state byte, t9 BG and a0-a3
 * unchanged. Then the row loop: prefix tn, tf, on, of, or with CLIP cn,
 * cf */
.macro setup8 clip, ret, conv, p
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
    li      $v1, TILE_BLANK
    beqz    $t8, \conv
    lw      $t2, BG_PaletteMask($t9)
    beq     $t8, $v1, \ret
    lw      $v1, BG_PaletteShift($t9)
    srl     $t5, $a0, 10
    and     $t5, $t5, $t2
    lw      $t2, BG_StartPalette($t9)
    sllv    $t5, $t5, $v1
    addu    $t5, $t5, $t2               /* palette base */
    x4      $t5, $v1
    lw      $t4, BG_Buffer($t9)
    sll     $t0, $t0, 6
    addu    $t4, $t4, $t0               /* pCache */
    lui     $t9, %hi(GFX)
    addiu   $t9, $t9, %lo(GFX)
    lbu     $t6, GFX_Z1($t9)
    lbu     $t7, GFX_Z2($t9)
    lw      $v0, GFX_S($t9)
    lw      $v1, GFX_DB($t9)
    lw      $t2, GFX_PPL($t9)
    multu   $a3, $t2                   /* LineCount x PPL */
    x4      $t6, $t0
    x4      $t7, $t0
    addu    $v1, $v1, $a1               /* depth */
    addu    $v0, $v0, $a1               /* screen */
    andi    $t1, $a0, 0x8000           /* V_FLIP */
    li      $t3, 8
    beqz    $t1, 2f
    addu    $t0, $t4, $a2               /* pCache + StartLine */
    subu    $t0, $t4, $a2
    addiu   $t0, $t0, 56               /* pCache + 56 - StartLine */
    li      $t3, -8
2:  mflo    $a3
    beqz    $a3, \ret
    move    $t4, $t0
    move    $a2, $t2                   /* PPL */
    addu    $a3, $a3, $v1               /* depth end */
    move    $a1, $v1
    andi    $t1, $a0, 0x4000           /* H_FLIP */
    move    $a0, $v0
    lui     $t0, 0x0101
    ori     $t0, $t0, 0x0101
    subu    $t6, $t6, $t0               /* (Z1 - 1) x 0x01010101 */
    lui     $t9, 0x7f7f
    ori     $t9, $t9, 0x7f7f
    lui     $t0, 0x8080
    ori     $t0, $t0, 0x8080
    or      $t6, $t6, $t0
  .if \clip
    bnez    $t1, \p\()cf_row
    move    $t8, $t0                   /* 0x80808080 */
    b       \p\()cn_row
    nop
  .else
    li      $v0, TILE_OPAQUE
    beq     $t8, $v0, 3f
    move    $t8, $t0                   /* 0x80808080 */
    bnez    $t1, \p\()tf_row
    nop
    b       \p\()tn_row
    nop
3:  bnez    $t1, \p\()of_row
    nop
    b       \p\()on_row
    nop
  .endif
.endm

/* convert RETRY: ConvertTile (pCache, TileAddr) for the tile of setup8's
 * CONV exit, its result stored as the state byte, then RETRY with a0-a3
 * as they were */
.macro convert retry
    addiu   $sp, $sp, -48
    sw      $ra, 44($sp)
    sw      $a0, 24($sp)
    sw      $a1, 28($sp)
    sw      $a2, 32($sp)
    sw      $a3, 36($sp)
    sw      $t1, 40($sp)
    lw      $a0, BG_Buffer($t9)
    sll     $t0, $t0, 6
    addu    $a0, $a0, $t0
    jal     _Z11ConvertTilePhj
    move    $a1, $v0
    lw      $t1, 40($sp)
    lw      $ra, 44($sp)
    sb      $v0, 0($t1)
    lw      $a0, 24($sp)
    lw      $a1, 28($sp)
    lw      $a2, 32($sp)
    lw      $a3, 36($sp)
    b       \retry
    addiu   $sp, $sp, 48
.endm

    .globl  s9x_tile8
    .ent    s9x_tile8
s9x_tile8:
    setup8  0, e_ret, e_conv, e_
e_ret:
    jr      $ra
    nop
e_conv:
    convert s9x_tile8

    rows8   0, 0, 0, e_tn, e_ret
    rows8   1, 0, 0, e_tf, e_ret
    rows8   0, 1, 0, e_on, e_ret
    rows8   1, 1, 0, e_of, e_ret
    .end    s9x_tile8

/* s9x_ctile8: the pixels StartPixel to StartPixel + Width - 1 of each
 * row; d1 (s0) and d2 (s1) of TILE_CLIP_PREAMBLE from HeadMask and
 * TailMask of the core. s0 and s1 are kept in the first two argument
 * words of the caller's frame (o32). */
    .globl  s9x_ctile8
    .ent    s9x_ctile8
s9x_ctile8:
    sw      $s0, 0($sp)
    sw      $s1, 4($sp)
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
ec_go:
    setup8  1, ec_ret, ec_conv, e_
ec_ret:
    lw      $s0, 0($sp)
    jr      $ra
    lw      $s1, 4($sp)
ec_conv:
    convert ec_go

    rows8   0, 0, 1, e_cn, ec_ret
    rows8   1, 0, 1, e_cf, ec_ret
    .end    s9x_ctile8

/* s9x_tilerun8: n unclipped 8 x 8 tiles of one background row (see
 * s9x_tilerun16 of tile16.S for the arguments and the frame). s0 map
 * pointer, s1 map end, s2 screen of the tile, s3 depth of the tile, s4
 * Lines x PPL, s5 VirtAlign, s6 GFX; ra holds q_skip while the tiles are
 * drawn, the row loops return there. */
#define R_SHIFT     16
#define R_TADDR     20
#define R_BUFFERED  24
#define R_BUFFER    28
#define R_PMASK     32
#define R_PSHIFT    36
#define R_PSTART    40
#define R_ZM        44      /* two words, by priority */
#define R_Z2        52      /* two words, by priority */
#define R_S0        60
#define R_RA        88
#define R_TMP       92
#define R_FRAME     96
#define R_LINES     (R_FRAME + 16)
#define R_Z         (R_FRAME + 20)

/* rconst8: the constants of the row loops and their return address */
.macro rconst8
    lui     $t8, 0x8080
    ori     $t8, $t8, 0x8080
    lui     $t9, 0x7f7f
    ori     $t9, $t9, 0x7f7f
    lw      $a2, GFX_PPL($s6)
    lui     $ra, %hi(q_skip)
    addiu   $ra, $ra, %lo(q_skip)
.endm

    .globl  s9x_tilerun8
    .ent    s9x_tilerun8
s9x_tilerun8:
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
    lw      $v1, GFX_DB($s6)
    addu    $s2, $v0, $a2
    addu    $s3, $v1, $a2
    rconst8
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
    sw      $v0, R_PSTART($sp)
    mflo    $s4                       /* Lines x PPL */
    lui     $t2, 0x0101
    ori     $t2, $t2, 0x0101
    lw      $t0, R_Z($sp)
    andi    $t1, $t0, 0xff             /* depth without the priority bit */
    x4      $t1, $v0
    sw      $t1, R_Z2($sp)
    subu    $t1, $t1, $t2
    or      $t1, $t1, $t8               /* (z - 1) x 0x01010101 | 0x80808080 */
    sw      $t1, R_ZM($sp)
    srl     $t1, $t0, 8
    andi    $t1, $t1, 0xff             /* depth with the priority bit */
    x4      $t1, $v0
    sw      $t1, R_Z2+4($sp)
    subu    $t1, $t1, $t2
    or      $t1, $t1, $t8
    b       q_next
    sw      $t1, R_ZM+4($sp)

q_skip:
    addiu   $s2, $s2, 8
    addiu   $s3, $s3, 8
q_next:
    beq     $s0, $s1, q_done
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
    beqz    $v1, q_conv               /* not converted */
    xori    $at, $v1, TILE_BLANK
    beqz    $at, q_skip
    srl     $t5, $a0, 10
    and     $t5, $t5, $t2
    lw      $t2, R_PSHIFT($sp)
    lw      $t1, R_PSTART($sp)
    sllv    $t5, $t5, $t2
    addu    $t5, $t5, $t1               /* palette base */
    x4      $t5, $t2
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
    bnez    $t2, e_tf_row
    nop
    b       e_tn_row
    nop
3:  bnez    $t2, e_of_row
    nop
    b       e_on_row
    nop

q_conv:                                 /* ConvertTile (pCache, TileAddr); the tile again */
    sw      $t1, R_TMP($sp)
    andi    $a1, $a0, 0x3ff
    sllv    $a1, $a1, $t0
    lw      $t2, R_TADDR($sp)
    lw      $a0, R_BUFFER($sp)
    addu    $a1, $a1, $t2
    andi    $a1, $a1, 0xffff
    sll     $v0, $v0, 6
    jal     _Z11ConvertTilePhj
    addu    $a0, $a0, $v0
    lw      $t1, R_TMP($sp)
    sb      $v0, 0($t1)
    rconst8
    b       q_next
    addiu   $s0, $s0, -2

q_done:
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
    .end    s9x_tilerun8
