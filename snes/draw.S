/* draw.S - drawing helpers of the SNES renderer, R5000 assembly.
 * EPROM Foundry Inc. / Mike Wolak, project Blitz99.
 *
 * void s9x_fill_lines(void *dst, uint32_t pattern, uint32_t bytes);
 *
 *   dst      KSEG0 (cached) address, 32-byte aligned
 *   pattern  the 32-bit word stored
 *   bytes    a multiple of 32
 *
 * Every 32-byte data-cache line of the area is allocated by Create Dirty
 * Exclusive (cache op 0x0D, as snes/blit.S and nes/blit.S use it for the
 * LFB) and then filled by eight word stores: the line is not read from
 * DRAM first, as a store miss of the write-allocate data cache reads it.
 * The whole line is written, so its earlier DRAM content is not needed.
 */
    .set    noreorder
    .set    noat
    .set    mips3
    .text
    .globl  s9x_fill_lines
    .ent    s9x_fill_lines
s9x_fill_lines:
    beqz    $a2, 2f
    addu    $a2, $a0, $a2           /* end */
1:  cache   0x0d, 0($a0)
    sw      $a1, 0($a0)
    sw      $a1, 4($a0)
    sw      $a1, 8($a0)
    sw      $a1, 12($a0)
    sw      $a1, 16($a0)
    sw      $a1, 20($a0)
    sw      $a1, 24($a0)
    addiu   $a0, $a0, 32
    bne     $a0, $a2, 1b
    sw      $a1, -4($a0)
2:  jr      $ra
    nop
    .end    s9x_fill_lines

/* void s9x_copy_lines(void *dst, const void *src, uint32_t bytes);
 *
 *   dst      KSEG0 address, 32-byte aligned
 *   src      KSEG0 address, 4-byte aligned
 *   bytes    a multiple of 32
 *
 * As s9x_fill_lines, each destination line allocated by Create Dirty
 * Exclusive and then written whole, with eight words of src. */
    .globl  s9x_copy_lines
    .ent    s9x_copy_lines
s9x_copy_lines:
    beqz    $a2, 2f
    addu    $a2, $a0, $a2           /* end */
1:  lw      $t0, 0($a1)
    lw      $t1, 4($a1)
    lw      $t2, 8($a1)
    lw      $t3, 12($a1)
    lw      $t4, 16($a1)
    lw      $t5, 20($a1)
    lw      $t6, 24($a1)
    lw      $t7, 28($a1)
    cache   0x0d, 0($a0)
    sw      $t0, 0($a0)
    sw      $t1, 4($a0)
    sw      $t2, 8($a0)
    sw      $t3, 12($a0)
    sw      $t4, 16($a0)
    sw      $t5, 20($a0)
    sw      $t6, 24($a0)
    sw      $t7, 28($a0)
    addiu   $a0, $a0, 32
    bne     $a0, $a2, 1b
    addiu   $a1, $a1, 32
2:  jr      $ra
    nop
    .end    s9x_copy_lines
