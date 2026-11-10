/* blit.S - SNES frame to the Voodoo linear frame buffer, R5000 assembly.
 * EPROM Foundry Inc. / Mike Wolak, project Blitz99.
 *
 * void snes_blit_asm(const uint16_t *src, uint32_t dst,
 *                    uint32_t rows, uint32_t mode);
 *
 *   src    the core's 16-bit frame (GFX.Screen): 256 RGB565 pixels a
 *          row, rows 512 bytes apart
 *   dst    LFB address of the first pixel: 0xA8400000 + offset (KSEG1,
 *          uncached) for single words, 0x88400000 + offset (KSEG0,
 *          cached) for bursts; 32-byte aligned for bursts
 *   rows   rows to copy
 *   mode   1 = cache-line bursts, 0 = single uncached words
 *
 * Bursts as nes/blit.S: Create Dirty Exclusive (cache op 0x0D, no fill
 * read from PCI), eight stores into the line, Hit Writeback Invalidate
 * (op 0x15) sends it as one 8-word write. The copy is 1:1: one 32-bit
 * LFB word carries two pixels, 128 words or 16 lines per 256-pixel row.
 * LFB rows are 1024 pixels (2048 bytes).
 */
    .set    noreorder
    .set    noat
    .text
    .globl  snes_blit_asm
    .ent    snes_blit_asm
snes_blit_asm:
    beqz    $a2, done
    nop
    bnez    $a3, b1_rows
    nop

/* ---- 1:1, single uncached words, eight pixels per pass -------------------- */
s1_rows:
    move    $t8, $a0
    move    $t7, $a1
    addiu   $t6, $a0, 512
s1_loop:
    lw      $t0, 0($t8)
    lw      $t1, 4($t8)
    lw      $t2, 8($t8)
    lw      $t3, 12($t8)
    addiu   $t8, $t8, 16
    sw      $t0, 0($t7)
    sw      $t1, 4($t7)
    sw      $t2, 8($t7)
    sw      $t3, 12($t7)
    bne     $t8, $t6, s1_loop
    addiu   $t7, $t7, 16
    addiu   $a2, $a2, -1
    addiu   $a0, $a0, 512
    bnez    $a2, s1_rows
    addiu   $a1, $a1, 2048
    jr      $ra
    nop

/* ---- 1:1, cache-line bursts, sixteen pixels per line ---------------------- */
b1_rows:
    move    $t8, $a0
    move    $t7, $a1
    addiu   $t6, $a0, 512
b1_loop:
    cache   0x0D, 0($t7)            /* Create Dirty Exclusive D: line owned, no fill */
    lw      $t0, 0($t8)
    lw      $t1, 4($t8)
    lw      $t2, 8($t8)
    lw      $t3, 12($t8)
    lw      $t4, 16($t8)
    lw      $t5, 20($t8)
    lw      $at, 24($t8)
    lw      $v1, 28($t8)
    sw      $t0, 0($t7)
    sw      $t1, 4($t7)
    sw      $t2, 8($t7)
    sw      $t3, 12($t7)
    sw      $t4, 16($t7)
    sw      $t5, 20($t7)
    sw      $at, 24($t7)
    sw      $v1, 28($t7)
    cache   0x15, 0($t7)            /* Hit Writeback Invalidate D: 8-word write */
    addiu   $t8, $t8, 32
    bne     $t8, $t6, b1_loop
    addiu   $t7, $t7, 32
    addiu   $a2, $a2, -1
    addiu   $a0, $a0, 512
    bnez    $a2, b1_rows
    addiu   $a1, $a1, 2048
    sync                            /* every line written back before the swap */
    jr      $ra
    nop

done:
    jr      $ra
    nop
    .end    snes_blit_asm
