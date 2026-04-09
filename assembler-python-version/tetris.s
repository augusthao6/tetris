##############################################################
# Tetris: All 7 pieces falling and locking
#
# Memory layout (word-addressed):
#   256-455  : framebuffer (FB_BASE, 10×20 = 200 words)
#   456      : piece_row
#   457      : piece_col
#   458      : gravity_timer
#   459      : piece_type  (0=I 1=O 2=T 3=S 4=Z 5=J 6=L)
#   460-659  : locked_board (200 words, mirrors framebuffer layout)
#
# Piece cells (row-offset, col-offset), all rotation-0:
#   I(0): (0,0)(0,1)(0,2)(0,3)  color=1 cyan
#   O(1): (0,0)(0,1)(1,0)(1,1)  color=2 yellow
#   T(2): (0,0)(0,1)(0,2)(1,1)  color=3 purple
#   S(3): (0,1)(0,2)(1,0)(1,1)  color=4 green
#   Z(4): (0,0)(0,1)(1,1)(1,2)  color=5 red
#   J(5): (0,0)(1,0)(1,1)(1,2)  color=6 blue
#   L(6): (0,2)(1,0)(1,1)(1,2)  color=7 orange
#
# Global registers (never clobbered by callees):
#   $r20 = FB_BASE     = 256
#   $r21 = addr(piece_row)     = 456
#   $r22 = addr(piece_col)     = 457
#   $r23 = addr(gravity_timer) = 458
#   $r24 = MMIO frame counter  = 4096
#   $r25 = addr(piece_type)    = 459
#   $r26 = LOCKED_BASE = 460
#   $r29 = stack pointer
##############################################################

start:
    addi    $r29, $r0, 4000

    addi    $r20, $r0, 256
    addi    $r21, $r0, 456
    addi    $r22, $r0, 457
    addi    $r23, $r0, 458
    addi    $r24, $r0, 4096
    addi    $r25, $r0, 459
    addi    $r26, $r0, 460

    # Clear FB + locked board (400 consecutive words starting at 256)
    addi    $r2, $r0, 399
clear_all:
    add     $r3, $r20, $r2
    sw      $r0, 0($r3)
    bne     $r2, $r0, clear_dec
    j       init_piece
clear_dec:
    addi    $r2, $r2, -1
    j       clear_all

init_piece:
    sw      $r0, 0($r21)          # piece_row = 0
    addi    $r2, $r0, 3
    sw      $r2, 0($r22)          # piece_col = 3
    addi    $r2, $r0, 30
    sw      $r2, 0($r23)          # gravity_timer = 30
    sw      $r0, 0($r25)          # piece_type = 0 (I)

##############################################################
# GAME LOOP
##############################################################
game_loop:
    jal     wait_frame
    jal     tick_gravity
    jal     render
    j       game_loop

##############################################################
# WAIT_FRAME — spin until MMIO frame counter increments
##############################################################
wait_frame:
    lw      $r2, 0($r24)
wf_loop:
    lw      $r3, 0($r24)
    bne     $r3, $r2, wf_done
    j       wf_loop
wf_done:
    jr      $r31

##############################################################
# TICK_GRAVITY
##############################################################
tick_gravity:
    addi    $r29, $r29, -1
    sw      $r31, 0($r29)

    lw      $r2, 0($r23)
    addi    $r2, $r2, -1
    sw      $r2, 0($r23)
    bne     $r2, $r0, tg_done

    # Timer hit zero — reset it
    addi    $r2, $r0, 30
    sw      $r2, 0($r23)

    lw      $r10, 0($r21)         # piece_row
    lw      $r12, 0($r25)         # piece_type

    # Floor limit: I (type 0) → row must be < 19; all others → row < 18
    bne     $r12, $r0, tg_check_other
    addi    $r4, $r0, 19
    blt     $r10, $r4, tg_move
    j       tg_lock
tg_check_other:
    addi    $r4, $r0, 18
    blt     $r10, $r4, tg_move
    j       tg_lock

tg_move:
    addi    $r10, $r10, 1
    sw      $r10, 0($r21)
    j       tg_done

tg_lock:
    jal     lock_piece
    jal     spawn_piece

tg_done:
    lw      $r31, 0($r29)
    addi    $r29, $r29, 1
    jr      $r31

##############################################################
# LOCK_PIECE — stamp active piece into locked_board
# Loads piece_row→$r10, piece_col→$r11, piece_type→$r12
# color ($r12+1) stored into locked_board cells
##############################################################
lock_piece:
    addi    $r29, $r29, -1
    sw      $r31, 0($r29)

    lw      $r10, 0($r21)
    lw      $r11, 0($r22)
    lw      $r12, 0($r25)
    addi    $r13, $r12, 1         # color = type+1

    bne     $r12, $r0, lp_not_I
    jal     lock_I
    j       lp_done
lp_not_I:
    addi    $r2, $r0, 1
    bne     $r12, $r2, lp_not_O
    jal     lock_O
    j       lp_done
lp_not_O:
    addi    $r2, $r0, 2
    bne     $r12, $r2, lp_not_T
    jal     lock_T
    j       lp_done
lp_not_T:
    addi    $r2, $r0, 3
    bne     $r12, $r2, lp_not_S
    jal     lock_S
    j       lp_done
lp_not_S:
    addi    $r2, $r0, 4
    bne     $r12, $r2, lp_not_Z
    jal     lock_Z
    j       lp_done
lp_not_Z:
    addi    $r2, $r0, 5
    bne     $r12, $r2, lp_not_J
    jal     lock_J
    j       lp_done
lp_not_J:
    jal     lock_L
lp_done:
    lw      $r31, 0($r29)
    addi    $r29, $r29, 1
    jr      $r31

# lock_* helpers: write $r13 to locked_board for each piece cell
# Scratch: $r4 $r5 $r6.  Leaf functions — use jr $r31 directly.

lock_I:
    # cells (0,0)(0,1)(0,2)(0,3)
    sll     $r4, $r10, 3
    sll     $r5, $r10, 1
    add     $r4, $r4, $r5
    add     $r4, $r4, $r11
    add     $r4, $r26, $r4
    sw      $r13, 0($r4)
    addi    $r4, $r4, 1
    sw      $r13, 0($r4)
    addi    $r4, $r4, 1
    sw      $r13, 0($r4)
    addi    $r4, $r4, 1
    sw      $r13, 0($r4)
    jr      $r31

lock_O:
    # cells (0,0)(0,1)
    sll     $r4, $r10, 3
    sll     $r5, $r10, 1
    add     $r4, $r4, $r5
    add     $r4, $r4, $r11
    add     $r4, $r26, $r4
    sw      $r13, 0($r4)
    addi    $r4, $r4, 1
    sw      $r13, 0($r4)
    # cells (1,0)(1,1)
    addi    $r6, $r10, 1
    sll     $r4, $r6, 3
    sll     $r5, $r6, 1
    add     $r4, $r4, $r5
    add     $r4, $r4, $r11
    add     $r4, $r26, $r4
    sw      $r13, 0($r4)
    addi    $r4, $r4, 1
    sw      $r13, 0($r4)
    jr      $r31

lock_T:
    # cells (0,0)(0,1)(0,2)
    sll     $r4, $r10, 3
    sll     $r5, $r10, 1
    add     $r4, $r4, $r5
    add     $r4, $r4, $r11
    add     $r4, $r26, $r4
    sw      $r13, 0($r4)
    addi    $r4, $r4, 1
    sw      $r13, 0($r4)
    addi    $r4, $r4, 1
    sw      $r13, 0($r4)
    # cell (1,1)
    addi    $r6, $r10, 1
    sll     $r4, $r6, 3
    sll     $r5, $r6, 1
    add     $r4, $r4, $r5
    add     $r4, $r4, $r11
    addi    $r4, $r4, 1
    add     $r4, $r26, $r4
    sw      $r13, 0($r4)
    jr      $r31

lock_S:
    # cells (0,1)(0,2)
    sll     $r4, $r10, 3
    sll     $r5, $r10, 1
    add     $r4, $r4, $r5
    add     $r4, $r4, $r11
    addi    $r4, $r4, 1
    add     $r4, $r26, $r4
    sw      $r13, 0($r4)
    addi    $r4, $r4, 1
    sw      $r13, 0($r4)
    # cells (1,0)(1,1)
    addi    $r6, $r10, 1
    sll     $r4, $r6, 3
    sll     $r5, $r6, 1
    add     $r4, $r4, $r5
    add     $r4, $r4, $r11
    add     $r4, $r26, $r4
    sw      $r13, 0($r4)
    addi    $r4, $r4, 1
    sw      $r13, 0($r4)
    jr      $r31

lock_Z:
    # cells (0,0)(0,1)
    sll     $r4, $r10, 3
    sll     $r5, $r10, 1
    add     $r4, $r4, $r5
    add     $r4, $r4, $r11
    add     $r4, $r26, $r4
    sw      $r13, 0($r4)
    addi    $r4, $r4, 1
    sw      $r13, 0($r4)
    # cells (1,1)(1,2)
    addi    $r6, $r10, 1
    sll     $r4, $r6, 3
    sll     $r5, $r6, 1
    add     $r4, $r4, $r5
    add     $r4, $r4, $r11
    addi    $r4, $r4, 1
    add     $r4, $r26, $r4
    sw      $r13, 0($r4)
    addi    $r4, $r4, 1
    sw      $r13, 0($r4)
    jr      $r31

lock_J:
    # cell (0,0)
    sll     $r4, $r10, 3
    sll     $r5, $r10, 1
    add     $r4, $r4, $r5
    add     $r4, $r4, $r11
    add     $r4, $r26, $r4
    sw      $r13, 0($r4)
    # cells (1,0)(1,1)(1,2)
    addi    $r6, $r10, 1
    sll     $r4, $r6, 3
    sll     $r5, $r6, 1
    add     $r4, $r4, $r5
    add     $r4, $r4, $r11
    add     $r4, $r26, $r4
    sw      $r13, 0($r4)
    addi    $r4, $r4, 1
    sw      $r13, 0($r4)
    addi    $r4, $r4, 1
    sw      $r13, 0($r4)
    jr      $r31

lock_L:
    # cell (0,2)
    sll     $r4, $r10, 3
    sll     $r5, $r10, 1
    add     $r4, $r4, $r5
    add     $r4, $r4, $r11
    addi    $r4, $r4, 2
    add     $r4, $r26, $r4
    sw      $r13, 0($r4)
    # cells (1,0)(1,1)(1,2)
    addi    $r6, $r10, 1
    sll     $r4, $r6, 3
    sll     $r5, $r6, 1
    add     $r4, $r4, $r5
    add     $r4, $r4, $r11
    add     $r4, $r26, $r4
    sw      $r13, 0($r4)
    addi    $r4, $r4, 1
    sw      $r13, 0($r4)
    addi    $r4, $r4, 1
    sw      $r13, 0($r4)
    jr      $r31

##############################################################
# SPAWN_PIECE — advance piece_type (mod 7), reset position
##############################################################
spawn_piece:
    lw      $r12, 0($r25)
    addi    $r12, $r12, 1
    addi    $r2, $r0, 7
    bne     $r12, $r2, sp_no_wrap
    addi    $r12, $r0, 0
sp_no_wrap:
    sw      $r12, 0($r25)
    sw      $r0, 0($r21)          # piece_row = 0
    addi    $r2, $r0, 3
    sw      $r2, 0($r22)          # piece_col = 3
    addi    $r2, $r0, 30
    sw      $r2, 0($r23)          # gravity_timer = 30
    jr      $r31

##############################################################
# RENDER
#   1. Copy locked_board → framebuffer (200 words)
#   2. Draw active piece on top
##############################################################
render:
    addi    $r29, $r29, -1
    sw      $r31, 0($r29)

    # Copy locked_board to FB
    addi    $r2, $r0, 199
render_copy:
    add     $r3, $r26, $r2
    lw      $r4, 0($r3)
    add     $r3, $r20, $r2
    sw      $r4, 0($r3)
    bne     $r2, $r0, render_copy_dec
    j       render_draw_piece
render_copy_dec:
    addi    $r2, $r2, -1
    j       render_copy

render_draw_piece:
    lw      $r10, 0($r21)
    lw      $r11, 0($r22)
    lw      $r12, 0($r25)
    addi    $r19, $r12, 1         # color = type+1

    bne     $r12, $r0, rd_not_I
    jal     draw_I
    j       rd_done
rd_not_I:
    addi    $r2, $r0, 1
    bne     $r12, $r2, rd_not_O
    jal     draw_O
    j       rd_done
rd_not_O:
    addi    $r2, $r0, 2
    bne     $r12, $r2, rd_not_T
    jal     draw_T
    j       rd_done
rd_not_T:
    addi    $r2, $r0, 3
    bne     $r12, $r2, rd_not_S
    jal     draw_S
    j       rd_done
rd_not_S:
    addi    $r2, $r0, 4
    bne     $r12, $r2, rd_not_Z
    jal     draw_Z
    j       rd_done
rd_not_Z:
    addi    $r2, $r0, 5
    bne     $r12, $r2, rd_not_J
    jal     draw_J
    j       rd_done
rd_not_J:
    jal     draw_L
rd_done:
    lw      $r31, 0($r29)
    addi    $r29, $r29, 1
    jr      $r31

# draw_* helpers: write $r19 to framebuffer for each piece cell.
# $r10=piece_row, $r11=piece_col, $r20=FB_BASE. Leaf functions.

draw_I:
    # (0,0)(0,1)(0,2)(0,3)
    sll     $r4, $r10, 3
    sll     $r5, $r10, 1
    add     $r4, $r4, $r5
    add     $r4, $r4, $r11
    add     $r4, $r20, $r4
    sw      $r19, 0($r4)
    addi    $r4, $r4, 1
    sw      $r19, 0($r4)
    addi    $r4, $r4, 1
    sw      $r19, 0($r4)
    addi    $r4, $r4, 1
    sw      $r19, 0($r4)
    jr      $r31

draw_O:
    # (0,0)(0,1)
    sll     $r4, $r10, 3
    sll     $r5, $r10, 1
    add     $r4, $r4, $r5
    add     $r4, $r4, $r11
    add     $r4, $r20, $r4
    sw      $r19, 0($r4)
    addi    $r4, $r4, 1
    sw      $r19, 0($r4)
    # (1,0)(1,1)
    addi    $r6, $r10, 1
    sll     $r4, $r6, 3
    sll     $r5, $r6, 1
    add     $r4, $r4, $r5
    add     $r4, $r4, $r11
    add     $r4, $r20, $r4
    sw      $r19, 0($r4)
    addi    $r4, $r4, 1
    sw      $r19, 0($r4)
    jr      $r31

draw_T:
    # (0,0)(0,1)(0,2)
    sll     $r4, $r10, 3
    sll     $r5, $r10, 1
    add     $r4, $r4, $r5
    add     $r4, $r4, $r11
    add     $r4, $r20, $r4
    sw      $r19, 0($r4)
    addi    $r4, $r4, 1
    sw      $r19, 0($r4)
    addi    $r4, $r4, 1
    sw      $r19, 0($r4)
    # (1,1)
    addi    $r6, $r10, 1
    sll     $r4, $r6, 3
    sll     $r5, $r6, 1
    add     $r4, $r4, $r5
    add     $r4, $r4, $r11
    addi    $r4, $r4, 1
    add     $r4, $r20, $r4
    sw      $r19, 0($r4)
    jr      $r31

draw_S:
    # (0,1)(0,2)
    sll     $r4, $r10, 3
    sll     $r5, $r10, 1
    add     $r4, $r4, $r5
    add     $r4, $r4, $r11
    addi    $r4, $r4, 1
    add     $r4, $r20, $r4
    sw      $r19, 0($r4)
    addi    $r4, $r4, 1
    sw      $r19, 0($r4)
    # (1,0)(1,1)
    addi    $r6, $r10, 1
    sll     $r4, $r6, 3
    sll     $r5, $r6, 1
    add     $r4, $r4, $r5
    add     $r4, $r4, $r11
    add     $r4, $r20, $r4
    sw      $r19, 0($r4)
    addi    $r4, $r4, 1
    sw      $r19, 0($r4)
    jr      $r31

draw_Z:
    # (0,0)(0,1)
    sll     $r4, $r10, 3
    sll     $r5, $r10, 1
    add     $r4, $r4, $r5
    add     $r4, $r4, $r11
    add     $r4, $r20, $r4
    sw      $r19, 0($r4)
    addi    $r4, $r4, 1
    sw      $r19, 0($r4)
    # (1,1)(1,2)
    addi    $r6, $r10, 1
    sll     $r4, $r6, 3
    sll     $r5, $r6, 1
    add     $r4, $r4, $r5
    add     $r4, $r4, $r11
    addi    $r4, $r4, 1
    add     $r4, $r20, $r4
    sw      $r19, 0($r4)
    addi    $r4, $r4, 1
    sw      $r19, 0($r4)
    jr      $r31

draw_J:
    # (0,0)
    sll     $r4, $r10, 3
    sll     $r5, $r10, 1
    add     $r4, $r4, $r5
    add     $r4, $r4, $r11
    add     $r4, $r20, $r4
    sw      $r19, 0($r4)
    # (1,0)(1,1)(1,2)
    addi    $r6, $r10, 1
    sll     $r4, $r6, 3
    sll     $r5, $r6, 1
    add     $r4, $r4, $r5
    add     $r4, $r4, $r11
    add     $r4, $r20, $r4
    sw      $r19, 0($r4)
    addi    $r4, $r4, 1
    sw      $r19, 0($r4)
    addi    $r4, $r4, 1
    sw      $r19, 0($r4)
    jr      $r31

draw_L:
    # (0,2)
    sll     $r4, $r10, 3
    sll     $r5, $r10, 1
    add     $r4, $r4, $r5
    add     $r4, $r4, $r11
    addi    $r4, $r4, 2
    add     $r4, $r20, $r4
    sw      $r19, 0($r4)
    # (1,0)(1,1)(1,2)
    addi    $r6, $r10, 1
    sll     $r4, $r6, 3
    sll     $r5, $r6, 1
    add     $r4, $r4, $r5
    add     $r4, $r4, $r11
    add     $r4, $r20, $r4
    sw      $r19, 0($r4)
    addi    $r4, $r4, 1
    sw      $r19, 0($r4)
    addi    $r4, $r4, 1
    sw      $r19, 0($r4)
    jr      $r31
