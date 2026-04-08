##############################################################
# Minimal Tetris: one falling piece
#
# Memory layout:
#   $r20 = FB_BASE = 256     (framebuffer, 200 words)
#   $r21 = 456               (piece_row)
#   $r22 = 457               (piece_col)
#   $r23 = 458               (gravity_timer)
#   $r24 = MMIO timer = 0xF001 (frame counter from HW)
#
# Active piece: T-piece, rotation 0
#   Cells relative to (piece_row, piece_col):
#     (0,0) (0,1) (0,2) (1,1)   <- T shape
#
# Color ID for T-piece = 3
##############################################################

start:
    # Init stack pointer
    addi    $r29, $r0, 4000       # SP = 4000 (grows down)

    # Load base addresses
    addi    $r20, $r0, 256        # FB_BASE
    addi    $r21, $r0, 456        # addr of piece_row
    addi    $r22, $r0, 457        # addr of piece_col
    addi    $r23, $r0, 458        # addr of gravity_timer

    # MMIO timer address: 0xF001 = 61441
    addi    $r24, $r0, 4096       # MMIO frame timer (matches Wrapper io_read)

    # Init piece position: row=0, col=4 (center), timer=30
    sw      $r0,  0($r21)         # piece_row = 0
    addi    $r2,  $r0, 4
    sw      $r2,  0($r22)         # piece_col = 4
    addi    $r2,  $r0, 30
    sw      $r2,  0($r23)         # gravity_timer = 30

    # Clear framebuffer (200 words = 0)
    addi    $r2, $r0, 199
clear_fb:
    add     $r3, $r20, $r2
    sw      $r0, 0($r3)
    bne     $r2, $r0, clear_dec
    j       game_loop
clear_dec:
    addi    $r2, $r2, -1
    j       clear_fb

##############################################################
# GAME LOOP
##############################################################
game_loop:
    jal     wait_frame
    jal     tick_gravity
    jal     render
    j       game_loop

##############################################################
# WAIT_FRAME — spin until MMIO timer increments
##############################################################
wait_frame:
    lw      $r2, 0($r24)          # read current timer
wf_loop:
    lw      $r3, 0($r24)
    bne     $r3, $r2, wf_done
    j       wf_loop
wf_done:
    jr      $r31

##############################################################
# TICK_GRAVITY
# Decrement timer. When zero: try to move piece down.
# If floor hit (row+1+1 >= 20 for bottom cell), lock it.
# "Lock" here just stops the loop (infinite loop at bottom).
##############################################################
tick_gravity:
    addi    $r29, $r29, -1
    sw      $r31, 0($r29)
    lw      $r2, 0($r23)          # gravity_timer
    addi    $r2, $r2, -1
    sw      $r2, 0($r23)
    bne     $r2, $r0, tg_done     # not time yet

    # Reset timer
    addi    $r2, $r0, 30
    sw      $r2, 0($r23)

    # Load piece_row
    lw      $r10, 0($r21)         # $r10 = piece_row
    lw      $r11, 0($r22)         # $r11 = piece_col

    # T-piece bottom cell is at row+1 (the stem)
    # Check if row+1+1 >= 20  (i.e. next row would put stem at row 20)
    addi    $r3, $r10, 2          # row + 2 (row after moving)
    addi    $r4, $r0, 20
    blt     $r3, $r4, tg_move     # if row+2 < 20, safe to move

    # Floor hit — lock (halt game loop by jumping to locked)
    j       piece_locked

tg_move:
    addi    $r10, $r10, 1         # piece_row++
    sw      $r10, 0($r21)

tg_done:
    lw      $r31, 0($r29)
    addi    $r29, $r29, 1
    jr      $r31
##############################################################
# RENDER
# Clear FB, then draw T-piece at (piece_row, piece_col).
# T-piece cells: (0,0)(0,1)(0,2)(1,1) relative to origin.
# Color = 3.
##############################################################
render:
    addi    $r29, $r29, -1
    sw      $r31, 0($r29)
    # Clear framebuffer
    addi    $r2, $r0, 199
render_clear:
    add     $r3, $r20, $r2
    sw      $r0, 0($r3)
    bne     $r2, $r0, render_clear_dec
    j       render_draw
render_clear_dec:
    addi    $r2, $r2, -1
    j       render_clear

render_draw:
    lw      $r10, 0($r21)         # piece_row
    lw      $r11, 0($r22)         # piece_col
    addi    $r19, $r0, 3          # color = 3 (T-piece purple)

    # Cell (0,0): fb[row*10 + col]
    jal     write_cell_0_0
    # Cell (0,1): fb[row*10 + col+1]
    jal     write_cell_0_1
    # Cell (0,2): fb[row*10 + col+2]
    jal     write_cell_0_2
    # Cell (1,1): fb[(row+1)*10 + col+1]
    jal     write_cell_1_1

    lw      $r31, 0($r29)
    addi    $r29, $r29, 1
    jr      $r31

# Helper: compute fb index for (piece_row+dr)*10 + (piece_col+dc)
# row*10 = (row<<3)+(row<<1)

write_cell_0_0:
    # dr=0, dc=0
    sll     $r4, $r10, 3          # row*8
    sll     $r5, $r10, 1          # row*2
    add     $r4, $r4, $r5         # row*10
    add     $r4, $r4, $r11        # + col
    add     $r4, $r20, $r4        # + FB_BASE
    sw      $r19, 0($r4)
    jr      $r31

write_cell_0_1:
    # dr=0, dc=1
    sll     $r4, $r10, 3
    sll     $r5, $r10, 1
    add     $r4, $r4, $r5
    add     $r4, $r4, $r11
    addi    $r4, $r4, 1           # col+1
    add     $r4, $r20, $r4
    sw      $r19, 0($r4)
    jr      $r31

write_cell_0_2:
    # dr=0, dc=2
    sll     $r4, $r10, 3
    sll     $r5, $r10, 1
    add     $r4, $r4, $r5
    add     $r4, $r4, $r11
    addi    $r4, $r4, 2           # col+2
    add     $r4, $r20, $r4
    sw      $r19, 0($r4)
    jr      $r31

write_cell_1_1:
    # dr=1, dc=1
    addi    $r6, $r10, 1          # row+1
    sll     $r4, $r6, 3
    sll     $r5, $r6, 1
    add     $r4, $r4, $r5         # (row+1)*10
    add     $r4, $r4, $r11
    addi    $r4, $r4, 1           # col+1
    add     $r4, $r20, $r4
    sw      $r19, 0($r4)
    jr      $r31

##############################################################
# PIECE_LOCKED — piece hit the floor, stop here
##############################################################
piece_locked:
    j       piece_locked          # infinite loop / halt