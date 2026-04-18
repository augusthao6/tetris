##############################################################
# Tetris: All 7 pieces, piece-collision, floor-collision, game-over
#         + user input: left/right movement, rotation
#
# Memory layout (word-addressed):
#   256-455  : framebuffer (FB_BASE, 10x20 = 200 words)
#   456      : piece_row
#   457      : piece_col
#   458      : gravity_timer
#   459      : piece_type  (0=I 1=O 2=T 3=S 4=Z 5=J 6=L)
#   460-659  : locked_board (200 words, same layout as framebuffer)
#   660      : piece_rot   (rotation state, 0-3)
#   661      : btn_prev    (previous button state for edge detection)
#   662      : score
#   663      : lfsr_state  (7-bit LFSR for random piece selection, 1-127)
#
# Piece cells (dr, dc) by rotation — matches piece_rom.v ROM entries:
#   I(0) rot0: (0,0)(0,1)(0,2)(0,3)   I(0) rot1: (0,0)(1,0)(2,0)(3,0)
#   O(1) rot0: (0,0)(0,1)(1,0)(1,1)   (no rotation)
#   T(2) rot0: (0,0)(0,1)(0,2)(1,1)   T(2) rot1: (0,0)(1,0)(2,0)(1,1)
#   T(2) rot2: (0,1)(1,0)(1,1)(1,2)   T(2) rot3: (0,1)(1,0)(1,1)(2,1)
#   S(3) rot0: (0,1)(0,2)(1,0)(1,1)   S(3) rot1: (0,0)(1,0)(1,1)(2,1)
#   Z(4) rot0: (0,0)(0,1)(1,1)(1,2)   Z(4) rot1: (0,1)(1,0)(1,1)(2,0)
#   J(5) rot0: (0,0)(1,0)(1,1)(1,2)   J(5) rot1: (0,0)(0,1)(1,0)(2,0)
#   J(5) rot2: (0,0)(0,1)(0,2)(1,2)   J(5) rot3: (0,1)(1,1)(2,0)(2,1)
#   L(6) rot0: (0,2)(1,0)(1,1)(1,2)   L(6) rot1: (0,0)(1,0)(2,0)(2,1)
#   L(6) rot2: (0,0)(0,1)(0,2)(1,0)   L(6) rot3: (0,0)(0,1)(1,1)(2,1)
#
# Global registers (preserved across all calls):
#   $r20 = FB_BASE    = 256
#   $r21 = addr(piece_row)     = 456
#   $r22 = addr(piece_col)     = 457
#   $r23 = addr(gravity_timer) = 458
#   $r24 = MMIO frame counter  = 4096
#   $r25 = addr(piece_type)    = 459
#   $r26 = LOCKED_BASE = 460
#   $r27 = addr(piece_rot)     = 660
#   $r28 = MMIO buttons        = 4098   (bit0=left, bit1=right, bit2=rotate)
#   $r29 = stack pointer
#
# MMIO piece ROM (piece_rom.v):
#   Write {type[2:0]<<2 | rot[1:0]} to 4099 → read packed footprint
#   Write same query to 4100 → read {floor_lim[15:8], right_lim[7:0]}
#
# Calling convention:
#   $r31 = link register (saved/restored by non-leaf callers)
#   $r8  = collision / validity flag output from check_collision / validate
#   $r2-$r6, $r9, $r14-$r16 = scratch (destroyed by callees)
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
    addi    $r27, $r0, 660
    addi    $r28, $r0, 4098

    # Clear FB + locked_board + piece_rot + btn_prev + score (addr 256..662)
    addi    $r2, $r0, 406
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

    # Seed 7-bit LFSR from MMIO frame counter
    lw      $r2, 0($r24)
    addi    $r3, $r0, 127
    and     $r2, $r2, $r3
    bne     $r2, $r0, ip_seed_ok
    addi    $r2, $r0, 1
ip_seed_ok:
    addi    $r3, $r0, 663
    sw      $r2, 0($r3)

    jal     lfsr_get_piece
    sw      $r2, 0($r25)

    sw      $r0, 0($r27)          # piece_rot = 0
    addi    $r2, $r0, 661
    sw      $r0, 0($r2)           # btn_prev = 0
    addi    $r2, $r0, 662
    sw      $r0, 0($r2)           # score = 0
    addi    $r2, $r0, 4097
    sw      $r0, 0($r2)           # LED = 0

##############################################################
# GAME LOOP
##############################################################
game_loop:
    jal     wait_frame
    jal     read_input
    jal     tick_gravity
    jal     render
    j       game_loop

##############################################################
# WAIT_FRAME — spin until MMIO frame counter changes
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

    # Timer expired — reset it
    addi    $r2, $r0, 30
    sw      $r2, 0($r23)

    lw      $r10, 0($r21)         # piece_row
    lw      $r11, 0($r22)         # piece_col
    lw      $r12, 0($r25)         # piece_type
    lw      $r13, 0($r27)         # piece_rot

    # ── Floor check via piece metadata ROM ───────────────────
    sll     $r2, $r12, 2
    add     $r2, $r2, $r13
    addi    $r15, $r0, 4100
    sw      $r2, 0($r15)
    lw      $r2, 0($r15)          # {floor_lim[15:8], right_lim[7:0]}
    sra     $r2, $r2, 8           # isolate floor_lim byte
    addi    $r6, $r0, 255
    and     $r2, $r2, $r6
    blt     $r10, $r2, tg_floor_ok
    j       tg_lock

tg_floor_ok:
    jal     check_collision_below
    bne     $r8, $r0, tg_lock

    # Safe to fall
    addi    $r10, $r10, 1
    sw      $r10, 0($r21)
    j       tg_done

tg_lock:
    jal     lock_piece
    jal     clear_lines
    jal     spawn_piece
    jal     check_gameover

tg_done:
    lw      $r31, 0($r29)
    addi    $r29, $r29, 1
    jr      $r31

##############################################################
# CHECK_COLLISION_BELOW (generic)
# Queries piece ROM for all 4 cell offsets (dr, dc).
# Checks locked_board[(row+dr+1)*10 + (col+dc)] for each cell.
# Returns $r8 = 1 if any cell is occupied, 0 otherwise.
# Clobbers: $r2-$r6, $r9, $r13-$r16
##############################################################
check_collision_below:
    lw      $r10, 0($r21)
    lw      $r11, 0($r22)
    lw      $r12, 0($r25)
    lw      $r13, 0($r27)
    addi    $r8,  $r0, 0

    addi    $r15, $r0, 4099
    sll     $r2,  $r12, 2
    add     $r2,  $r2,  $r13
    sw      $r2,  0($r15)
    lw      $r14, 0($r15)

    addi    $r9, $r0, 4
    addi    $r6, $r0, 15
ccb_cell:
    and     $r5,  $r14, $r6        # dc
    sra     $r14, $r14, 4
    and     $r4,  $r14, $r6        # dr
    sra     $r14, $r14, 4
    add     $r3,  $r10, $r4
    addi    $r3,  $r3,  1          # row+dr+1
    sll     $r16, $r3,  3
    sll     $r2,  $r3,  1
    add     $r16, $r16, $r2        # *10
    add     $r16, $r16, $r5
    add     $r16, $r16, $r11
    add     $r16, $r26, $r16
    lw      $r3,  0($r16)
    bne     $r3,  $r0, ccb_hit
    addi    $r9,  $r9,  -1
    bne     $r9,  $r0, ccb_cell
    jr      $r31
ccb_hit:
    addi    $r8, $r0, 1
    jr      $r31

##############################################################
# CHECK_COLLISION_LEFT (generic)
# Checks locked_board[(row+dr)*10 + (col+dc-1)] for each cell.
# Caller must ensure col > 0 (left-wall check) before calling.
# Returns $r8 = 1 if blocked.
##############################################################
check_collision_left:
    lw      $r10, 0($r21)
    lw      $r11, 0($r22)
    lw      $r12, 0($r25)
    lw      $r13, 0($r27)
    addi    $r8,  $r0, 0

    addi    $r15, $r0, 4099
    sll     $r2,  $r12, 2
    add     $r2,  $r2,  $r13
    sw      $r2,  0($r15)
    lw      $r14, 0($r15)

    addi    $r9, $r0, 4
    addi    $r6, $r0, 15
ccl_cell:
    and     $r5,  $r14, $r6        # dc
    sra     $r14, $r14, 4
    and     $r4,  $r14, $r6        # dr
    sra     $r14, $r14, 4
    add     $r3,  $r10, $r4        # row+dr
    sll     $r16, $r3,  3
    sll     $r2,  $r3,  1
    add     $r16, $r16, $r2
    add     $r16, $r16, $r5
    add     $r16, $r16, $r11
    addi    $r16, $r16, -1         # col+dc-1
    add     $r16, $r26, $r16
    lw      $r3,  0($r16)
    bne     $r3,  $r0, ccl_hit
    addi    $r9,  $r9,  -1
    bne     $r9,  $r0, ccl_cell
    jr      $r31
ccl_hit:
    addi    $r8, $r0, 1
    jr      $r31

##############################################################
# CHECK_COLLISION_RIGHT (generic)
# Checks locked_board[(row+dr)*10 + (col+dc+1)] for each cell.
# Caller must ensure col < right_lim (right-wall check) before calling.
# Returns $r8 = 1 if blocked.
##############################################################
check_collision_right:
    lw      $r10, 0($r21)
    lw      $r11, 0($r22)
    lw      $r12, 0($r25)
    lw      $r13, 0($r27)
    addi    $r8,  $r0, 0

    addi    $r15, $r0, 4099
    sll     $r2,  $r12, 2
    add     $r2,  $r2,  $r13
    sw      $r2,  0($r15)
    lw      $r14, 0($r15)

    addi    $r9, $r0, 4
    addi    $r6, $r0, 15
ccr_cell:
    and     $r5,  $r14, $r6        # dc
    sra     $r14, $r14, 4
    and     $r4,  $r14, $r6        # dr
    sra     $r14, $r14, 4
    add     $r3,  $r10, $r4
    sll     $r16, $r3,  3
    sll     $r2,  $r3,  1
    add     $r16, $r16, $r2
    add     $r16, $r16, $r5
    add     $r16, $r16, $r11
    addi    $r16, $r16, 1          # col+dc+1
    add     $r16, $r26, $r16
    lw      $r3,  0($r16)
    bne     $r3,  $r0, ccr_hit
    addi    $r9,  $r9,  -1
    bne     $r9,  $r0, ccr_cell
    jr      $r31
ccr_hit:
    addi    $r8, $r0, 1
    jr      $r31

##############################################################
# CHECK_GAMEOVER — leaf
# Scans locked_board rows 0-1 (first 20 cells).
# Halts if any occupied; loops waiting for reset button.
##############################################################
check_gameover:
    addi    $r2, $r0, 19
cgo_loop:
    add     $r3, $r26, $r2
    lw      $r4, 0($r3)
    bne     $r4, $r0, cgo_halt
    bne     $r2, $r0, cgo_dec
    jr      $r31
cgo_dec:
    addi    $r2, $r2, -1
    j       cgo_loop
cgo_halt:
    addi    $r2, $r0, 4097
    addi    $r3, $r0, -1
    sw      $r3, 0($r2)           # all LEDs on
cgo_loop2:
    lw      $r2, 0($r28)
    addi    $r3, $r0, 16          # bit 4 = reset
    and     $r2, $r2, $r3
    bne     $r2, $r0, cgo_restart
    j       cgo_loop2
cgo_restart:
    j       start

##############################################################
# LOCK_PIECE (generic)
# Stamps active piece into locked_board using piece ROM offsets.
# Writes color (type+1) to locked_board[(row+dr)*10 + (col+dc)].
##############################################################
lock_piece:
    lw      $r10, 0($r21)
    lw      $r11, 0($r22)
    lw      $r12, 0($r25)
    lw      $r13, 0($r27)
    addi    $r19, $r12, 1         # color = type+1

    addi    $r15, $r0, 4099
    sll     $r2,  $r12, 2
    add     $r2,  $r2,  $r13
    sw      $r2,  0($r15)
    lw      $r14, 0($r15)

    addi    $r9, $r0, 4
    addi    $r6, $r0, 15
lk_cell:
    and     $r5,  $r14, $r6        # dc
    sra     $r14, $r14, 4
    and     $r4,  $r14, $r6        # dr
    sra     $r14, $r14, 4
    add     $r3,  $r10, $r4
    sll     $r16, $r3,  3
    sll     $r2,  $r3,  1
    add     $r16, $r16, $r2
    add     $r16, $r16, $r5
    add     $r16, $r16, $r11
    add     $r16, $r26, $r16
    sw      $r19, 0($r16)
    addi    $r9,  $r9,  -1
    bne     $r9,  $r0, lk_cell
    jr      $r31

##############################################################
# SPAWN_PIECE
##############################################################
spawn_piece:
    addi    $r29, $r29, -1
    sw      $r31, 0($r29)

    jal     lfsr_get_piece
    sw      $r2, 0($r25)
    sw      $r0, 0($r21)          # piece_row = 0
    addi    $r2, $r0, 3
    sw      $r2, 0($r22)          # piece_col = 3
    addi    $r2, $r0, 30
    sw      $r2, 0($r23)          # gravity_timer = 30
    sw      $r0, 0($r27)          # piece_rot = 0

    lw      $r31, 0($r29)
    addi    $r29, $r29, 1
    jr      $r31

##############################################################
# LFSR_GET_PIECE — advance 7-bit Fibonacci LFSR, return 0-6
# Uses custom `lfsr $rd, $rs` instruction (aluop 01000).
##############################################################
lfsr_get_piece:
    addi    $r5, $r0, 663
    lw      $r2, 0($r5)
    lfsr    $r2, $r2, $r0
    sw      $r2, 0($r5)
    addi    $r4, $r0, 7
lgp_mod7:
    blt     $r2, $r4, lgp_done
    sub     $r2, $r2, $r4
    j       lgp_mod7
lgp_done:
    jr      $r31

##############################################################
# RENDER
#   1. Copy locked_board → framebuffer.
#   2. Overlay active piece via draw_piece.
##############################################################
render:
    addi    $r29, $r29, -1
    sw      $r31, 0($r29)

    addi    $r2, $r0, 199
render_copy:
    add     $r3, $r26, $r2
    lw      $r4, 0($r3)
    add     $r3, $r20, $r2
    sw      $r4, 0($r3)
    bne     $r2, $r0, render_copy_dec
    j       render_draw
render_copy_dec:
    addi    $r2, $r2, -1
    j       render_copy

render_draw:
    jal     draw_piece

    lw      $r31, 0($r29)
    addi    $r29, $r29, 1
    jr      $r31

##############################################################
# DRAW_PIECE (generic)
# Writes color (type+1) to framebuffer[(row+dr)*10 + (col+dc)].
##############################################################
draw_piece:
    lw      $r10, 0($r21)
    lw      $r11, 0($r22)
    lw      $r12, 0($r25)
    lw      $r13, 0($r27)
    addi    $r19, $r12, 1         # color = type+1

    addi    $r15, $r0, 4099
    sll     $r2,  $r12, 2
    add     $r2,  $r2,  $r13
    sw      $r2,  0($r15)
    lw      $r14, 0($r15)

    addi    $r9, $r0, 4
    addi    $r6, $r0, 15
dp_cell:
    and     $r5,  $r14, $r6        # dc
    sra     $r14, $r14, 4
    and     $r4,  $r14, $r6        # dr
    sra     $r14, $r14, 4
    add     $r3,  $r10, $r4
    sll     $r16, $r3,  3
    sll     $r2,  $r3,  1
    add     $r16, $r16, $r2
    add     $r16, $r16, $r5
    add     $r16, $r16, $r11
    add     $r16, $r20, $r16      # FB_BASE + offset
    sw      $r19, 0($r16)
    addi    $r9,  $r9,  -1
    bne     $r9,  $r0, dp_cell
    jr      $r31

##############################################################
# READ_INPUT — detect button rising edges, call handlers
# Reads MMIO[4098]: bit0=left, bit1=right, bit2=rotate, bit3=soft-drop
##############################################################
read_input:
    addi    $r29, $r29, -3
    sw      $r31, 2($r29)

    lw      $r2, 0($r28)
    addi    $r4, $r0, 661
    lw      $r3, 0($r4)
    sw      $r2, 0($r4)
    sw      $r2, 1($r29)
    sw      $r3, 0($r29)

    # Left (bit 0) rising edge?
    addi    $r5, $r0, 1
    and     $r6, $r2, $r5
    bne     $r6, $r0, ri_left_now
    j       ri_right
ri_left_now:
    and     $r7, $r3, $r5
    bne     $r7, $r0, ri_right
    jal     move_left
    lw      $r2, 1($r29)
    lw      $r3, 0($r29)

ri_right:
    addi    $r5, $r0, 2
    and     $r6, $r2, $r5
    bne     $r6, $r0, ri_right_now
    j       ri_rotate
ri_right_now:
    and     $r7, $r3, $r5
    bne     $r7, $r0, ri_rotate
    jal     move_right
    lw      $r2, 1($r29)
    lw      $r3, 0($r29)

ri_rotate:
    addi    $r5, $r0, 4
    and     $r6, $r2, $r5
    bne     $r6, $r0, ri_rot_now
    j       ri_soft_drop
ri_rot_now:
    and     $r7, $r3, $r5
    bne     $r7, $r0, ri_soft_drop
    jal     rotate_piece
    lw      $r2, 1($r29)

ri_soft_drop:
    addi    $r5, $r0, 8
    and     $r6, $r2, $r5
    bne     $r6, $r0, ri_do_drop
    j       ri_done
ri_do_drop:
    addi    $r5, $r0, 1
    sw      $r5, 0($r23)

ri_done:
    lw      $r31, 2($r29)
    addi    $r29, $r29, 3
    jr      $r31

##############################################################
# MOVE_LEFT
##############################################################
move_left:
    addi    $r29, $r29, -1
    sw      $r31, 0($r29)

    lw      $r11, 0($r22)
    bne     $r11, $r0, ml_not_wall
    j       ml_done
ml_not_wall:
    jal     check_collision_left
    bne     $r8, $r0, ml_done
    addi    $r11, $r11, -1
    sw      $r11, 0($r22)
ml_done:
    lw      $r31, 0($r29)
    addi    $r29, $r29, 1
    jr      $r31

##############################################################
# MOVE_RIGHT — right-wall limit from piece metadata ROM (4100)
##############################################################
move_right:
    addi    $r29, $r29, -1
    sw      $r31, 0($r29)

    lw      $r11, 0($r22)
    lw      $r12, 0($r25)
    lw      $r13, 0($r27)

    # Read right_lim from metadata ROM
    sll     $r2,  $r12, 2
    add     $r2,  $r2,  $r13
    addi    $r15, $r0,  4100
    sw      $r2,  0($r15)
    lw      $r2,  0($r15)
    addi    $r6,  $r0,  255
    and     $r2,  $r2,  $r6       # right_lim = bits[7:0]
    blt     $r11, $r2, mr_wall_ok
    j       mr_done
mr_wall_ok:
    jal     check_collision_right
    bne     $r8, $r0, mr_done
    addi    $r11, $r11, 1
    sw      $r11, 0($r22)
mr_done:
    lw      $r31, 0($r29)
    addi    $r29, $r29, 1
    jr      $r31

##############################################################
# VALIDATE_NEW_ROTATION (generic)
# Reads piece_type, piece_rot (already set to new_rot),
# piece_row, piece_col (already clamped) from memory.
# Checks every cell against locked_board and row bounds.
# Returns $r8 = 0 (valid) or 1 (invalid).
##############################################################
validate_new_rotation:
    lw      $r10, 0($r21)
    lw      $r11, 0($r22)
    lw      $r12, 0($r25)
    lw      $r13, 0($r27)
    addi    $r8,  $r0, 0

    addi    $r15, $r0, 4099
    sll     $r2,  $r12, 2
    add     $r2,  $r2,  $r13
    sw      $r2,  0($r15)
    lw      $r14, 0($r15)

    addi    $r9, $r0, 4
    addi    $r6, $r0, 15
vr_cell:
    and     $r5,  $r14, $r6        # dc
    sra     $r14, $r14, 4
    and     $r4,  $r14, $r6        # dr
    sra     $r14, $r14, 4

    # Row bounds check: row+dr must be <= 19
    add     $r3,  $r10, $r4
    addi    $r2,  $r0,  20
    blt     $r3,  $r2,  vr_check_lock
    addi    $r8,  $r0,  1          # out of bounds
    jr      $r31

vr_check_lock:
    sll     $r16, $r3,  3
    sll     $r2,  $r3,  1
    add     $r16, $r16, $r2
    add     $r16, $r16, $r5
    add     $r16, $r16, $r11
    add     $r16, $r26, $r16
    lw      $r3,  0($r16)
    bne     $r3,  $r0,  vr_hit
    addi    $r9,  $r9,  -1
    bne     $r9,  $r0,  vr_cell
    jr      $r31                   # $r8 = 0, valid

vr_hit:
    addi    $r8, $r0, 1
    jr      $r31

##############################################################
# ROTATE_PIECE
# 1. Skip O-piece (no rotation).
# 2. Compute new_rot = (piece_rot+1) % max_rotations.
# 3. Clamp piece_col using right_lim from metadata ROM.
# 4. Write new_rot and clamped col; call validate_new_rotation.
# 5. If invalid, restore originals.
##############################################################
rotate_piece:
    addi    $r29, $r29, -1
    sw      $r31, 0($r29)

    lw      $r10, 0($r21)
    lw      $r11, 0($r22)         # original col
    lw      $r12, 0($r25)
    lw      $r15, 0($r27)         # original rot

    # O-piece: no rotation
    addi    $r2, $r0, 1
    bne     $r12, $r2, rp_not_O
    j       rp_done
rp_not_O:

    # new_rot = rot + 1, wrapping by piece family
    addi    $r14, $r15, 1

    # I-piece: 2 rotations
    bne     $r12, $r0, rp_not_I
    addi    $r2, $r0, 2
    bne     $r14, $r2, rp_clamp
    addi    $r14, $r0, 0
    j       rp_clamp
rp_not_I:
    # S(3) and Z(4): 2 rotations
    addi    $r2, $r0, 3
    bne     $r12, $r2, rp_not_S
    addi    $r2, $r0, 2
    bne     $r14, $r2, rp_clamp
    addi    $r14, $r0, 0
    j       rp_clamp
rp_not_S:
    addi    $r2, $r0, 4
    bne     $r12, $r2, rp_not_Z
    addi    $r2, $r0, 2
    bne     $r14, $r2, rp_clamp
    addi    $r14, $r0, 0
    j       rp_clamp
rp_not_Z:
    # T(2), J(5), L(6): 4 rotations
    addi    $r2, $r0, 4
    bne     $r14, $r2, rp_clamp
    addi    $r14, $r0, 0

rp_clamp:
    # Get right_lim for (type, new_rot) from metadata ROM
    addi    $r16, $r11, 0          # start with original col
    sll     $r2,  $r12, 2
    add     $r2,  $r2,  $r14       # {type<<2 | new_rot}
    addi    $r15, $r0,  4100
    sw      $r2,  0($r15)
    lw      $r2,  0($r15)
    addi    $r6,  $r0,  255
    and     $r2,  $r2,  $r6        # right_lim = bits[7:0]
    blt     $r16, $r2,  rp_try
    addi    $r16, $r2,  -1         # clamp col = right_lim - 1

rp_try:
    # Restore $r15 = original rot before writing tentative values
    lw      $r15, 0($r27)
    sw      $r14, 0($r27)          # piece_rot = new_rot (tentative)
    sw      $r16, 0($r22)          # piece_col = clamped (tentative)

    jal     validate_new_rotation  # $r8: 0=valid, 1=invalid

    bne     $r8, $r0, rp_invalid
    j       rp_done
rp_invalid:
    sw      $r15, 0($r27)          # restore original rot
    sw      $r11, 0($r22)          # restore original col

rp_done:
    lw      $r31, 0($r29)
    addi    $r29, $r29, 1
    jr      $r31

##############################################################
# CLEAR_LINES
##############################################################
clear_lines:
    addi    $r29, $r29, -1
    sw      $r31, 0($r29)

    addi    $r17, $r0, 19
    addi    $r18, $r0, 0

cl_outer:
    jal     check_row_full
    bne     $r8, $r0, cl_full
    bne     $r17, $r0, cl_dec
    j       cl_score
cl_dec:
    addi    $r17, $r17, -1
    j       cl_outer

cl_full:
    jal     shift_rows_down
    addi    $r18, $r18, 1
    bne     $r17, $r0, cl_outer
    j       cl_score

cl_score:
    bne     $r18, $r0, cl_s1
    j       cl_done
cl_s1:
    addi    $r2, $r0, 662
    lw      $r3, 0($r2)
    addi    $r4, $r0, 1
    bne     $r18, $r4, cl_s2
    addi    $r3, $r3, 100
    j       cl_score_upd
cl_s2:
    addi    $r4, $r0, 2
    bne     $r18, $r4, cl_s3
    addi    $r3, $r3, 300
    j       cl_score_upd
cl_s3:
    addi    $r4, $r0, 3
    bne     $r18, $r4, cl_s4
    addi    $r3, $r3, 500
    j       cl_score_upd
cl_s4:
    addi    $r3, $r3, 800
cl_score_upd:
    sw      $r3, 0($r2)
    addi    $r2, $r0, 4097
    sw      $r3, 0($r2)

cl_done:
    lw      $r31, 0($r29)
    addi    $r29, $r29, 1
    jr      $r31

##############################################################
# CHECK_ROW_FULL — leaf
# Input:  $r17 = row index
# Output: $r8  = 1 if all 10 cells non-zero
##############################################################
check_row_full:
    sll     $r4, $r17, 3
    sll     $r5, $r17, 1
    add     $r4, $r4, $r5
    add     $r4, $r26, $r4
    addi    $r8, $r0, 1
    addi    $r9, $r0, 10
crf_loop:
    bne     $r9, $r0, crf_cell
    jr      $r31
crf_cell:
    lw      $r6, 0($r4)
    bne     $r6, $r0, crf_ok
    addi    $r8, $r0, 0
    jr      $r31
crf_ok:
    addi    $r4, $r4, 1
    addi    $r9, $r9, -1
    j       crf_loop

##############################################################
# SHIFT_ROWS_DOWN — leaf
# Input:  $r17 = index of the full (cleared) row
# Effect: for dest=$r17 downto 1: locked[dest] <- locked[dest-1]
#         then locked[0] <- zeros
##############################################################
shift_rows_down:
    addi    $r14, $r17, 0

srd_outer:
    bne     $r14, $r0, srd_copy
    add     $r4, $r26, $r0
    addi    $r9, $r0, 10
srd_clr:
    bne     $r9, $r0, srd_clr_cell
    jr      $r31
srd_clr_cell:
    sw      $r0, 0($r4)
    addi    $r4, $r4, 1
    addi    $r9, $r9, -1
    j       srd_clr

srd_copy:
    addi    $r15, $r14, -1
    sll     $r4, $r14, 3
    sll     $r5, $r14, 1
    add     $r4, $r4, $r5
    add     $r4, $r26, $r4
    sll     $r6, $r15, 3
    sll     $r5, $r15, 1
    add     $r6, $r6, $r5
    add     $r6, $r26, $r6
    addi    $r9, $r0, 10
srd_copy_loop:
    bne     $r9, $r0, srd_copy_cell
    addi    $r14, $r14, -1
    j       srd_outer
srd_copy_cell:
    lw      $r16, 0($r6)
    sw      $r16, 0($r4)
    addi    $r4, $r4, 1
    addi    $r6, $r6, 1
    addi    $r9, $r9, -1
    j       srd_copy_loop
