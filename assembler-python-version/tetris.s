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
#   663      : lfsr_state  (7-bit LFSR for random piece selection, 1-127)
#
# Piece cells (dr, dc) by rotation:
#   I(0) rot0: (0,0)(0,1)(0,2)(0,3)  1-wide×4  color=1
#   I(0) rot1: (0,0)(1,0)(2,0)(3,0)  4-tall×1
#   O(1) rot0: (0,0)(0,1)(1,0)(1,1)  2-wide×2  color=2  (no rotation)
#   T(2) rot0: (0,0)(0,1)(0,2)(1,1)            color=3
#   T(2) rot1: (0,0)(1,0)(2,0)(1,1)
#   T(2) rot2: (0,1)(1,0)(1,1)(1,2)
#   T(2) rot3: (0,1)(1,0)(1,1)(2,1)
#   S(3) rot0: (0,1)(0,2)(1,0)(1,1)            color=4
#   S(3) rot1: (0,0)(1,0)(1,1)(2,1)
#   Z(4) rot0: (0,0)(0,1)(1,1)(1,2)            color=5
#   Z(4) rot1: (0,1)(1,0)(1,1)(2,0)
#   J(5) rot0: (0,0)(1,0)(1,1)(1,2)            color=6
#   J(5) rot1: (0,0)(0,1)(1,0)(2,0)
#   J(5) rot2: (0,0)(0,1)(0,2)(1,2)
#   J(5) rot3: (0,1)(1,1)(2,0)(2,1)
#   L(6) rot0: (0,2)(1,0)(1,1)(1,2)            color=7
#   L(6) rot1: (0,0)(1,0)(2,0)(2,1)
#   L(6) rot2: (0,0)(0,1)(0,2)(1,0)
#   L(6) rot3: (0,0)(0,1)(1,1)(2,1)
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
# Calling convention:
#   $r31 = link register (saved/restored by non-leaf callers)
#   $r8  = collision flag output from check_collision routines
#   $r4,$r5,$r6,$r9 = scratch (destroyed by callees)
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

    # Seed 7-bit LFSR from MMIO frame counter (varies by when reset is pressed)
    lw      $r2, 0($r24)          # read frame counter
    addi    $r3, $r0, 127
    and     $r2, $r2, $r3         # keep low 7 bits
    bne     $r2, $r0, ip_seed_ok
    addi    $r2, $r0, 1           # LFSR state must never be 0
ip_seed_ok:
    addi    $r3, $r0, 663
    sw      $r2, 0($r3)           # lfsr_state = seed

    jal     lfsr_get_piece        # pick first piece, returns type in $r2
    sw      $r2, 0($r25)          # piece_type = result

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
#
# Each call: decrement timer. When timer hits 0:
#   1. Reset timer.
#   2. Floor check (pure row limit — prevents reading out-of-bounds).
#   3. Piece-collision check (locked_board cells below piece).
#   4. Move down OR lock + spawn + game-over check.
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

    # ── Floor check ──────────────────────────────────────────
    # Max row depends on piece height for current rotation:
    #   1-tall (I rot0):  row < 20 (≤19)
    #   2-tall (most):    row < 19 (≤18)
    #   3-tall (verticals): row < 18 (≤17)
    #   4-tall (I rot1):  row < 17 (≤16)
    lw      $r13, 0($r27)         # piece_rot
    bne     $r12, $r0, tg_floor_other
    # I-piece
    bne     $r13, $r0, tg_floor_I_vert
    addi    $r4, $r0, 19          # I rot0: 1-tall, r+1<=19 -> r<19
    blt     $r10, $r4, tg_floor_ok
    j       tg_lock
tg_floor_I_vert:
    addi    $r4, $r0, 16          # I rot1: 4-tall, r+4<=19 -> r<16
    blt     $r10, $r4, tg_floor_ok
    j       tg_lock

tg_floor_other:
    # T rot1/rot3, S rot1, Z rot1, J rot1/rot3, L rot1/rot3 are 3-tall
    # T(2) rot1 or rot3:
    addi    $r2, $r0, 2
    bne     $r12, $r2, tg_floor_chk_SZ
    addi    $r2, $r0, 1
    bne     $r13, $r2, tg_floor_T_not1
    j       tg_floor_3tall
tg_floor_T_not1:
    addi    $r2, $r0, 3
    bne     $r13, $r2, tg_floor_2tall
    j       tg_floor_3tall
    # S(3) rot1:
tg_floor_chk_SZ:
    addi    $r2, $r0, 3
    bne     $r12, $r2, tg_floor_chk_Z
    bne     $r13, $r0, tg_floor_3tall
    j       tg_floor_2tall
    # Z(4) rot1:
tg_floor_chk_Z:
    addi    $r2, $r0, 4
    bne     $r12, $r2, tg_floor_chk_JL
    bne     $r13, $r0, tg_floor_3tall
    j       tg_floor_2tall
    # J(5) and L(6) rot1 or rot3:
tg_floor_chk_JL:
    addi    $r2, $r0, 1
    bne     $r13, $r2, tg_floor_JL_not1
    j       tg_floor_3tall
tg_floor_JL_not1:
    addi    $r2, $r0, 3
    bne     $r13, $r2, tg_floor_2tall
    j       tg_floor_3tall
tg_floor_3tall:
    addi    $r4, $r0, 17          # 3-tall: r+3<=19 -> r<17
    blt     $r10, $r4, tg_floor_ok
    j       tg_lock
tg_floor_2tall:
    addi    $r4, $r0, 18          # 2-tall: r+2<=19 -> r<18
    blt     $r10, $r4, tg_floor_ok
    j       tg_lock

tg_floor_ok:
    # ── Piece-collision check ────────────────────────────────
    # check_collision_below sets $r8=1 if any locked cell is directly
    # below the active piece's footprint, 0 otherwise.
    jal     check_collision_below
    bne     $r8, $r0, tg_lock

    # Safe to fall — advance one row
    addi    $r10, $r10, 1
    sw      $r10, 0($r21)
    j       tg_done

tg_lock:
    jal     lock_piece
    jal     clear_lines
    jal     spawn_piece
    jal     check_gameover        # halts if top rows occupied

tg_done:
    lw      $r31, 0($r29)
    addi    $r29, $r29, 1
    jr      $r31

##############################################################
# CHECK_COLLISION_BELOW
#
# Checks whether any cell of the active piece, shifted down by 1,
# is occupied in locked_board.
# Returns $r8 = 0 (no collision) or 1 (collision).
# Reads $r10=piece_row, $r11=piece_col, $r12=piece_type.
# Dispatches to per-piece leaf routines via jal.
##############################################################
check_collision_below:
    addi    $r29, $r29, -1
    sw      $r31, 0($r29)

    lw      $r10, 0($r21)
    lw      $r11, 0($r22)
    lw      $r12, 0($r25)
    lw      $r13, 0($r27)         # piece_rot
    addi    $r8, $r0, 0           # collision flag = 0

    # If rot == 0, use existing rot-0 routines
    bne     $r13, $r0, ccb_rotated

    bne     $r12, $r0, ccb_not_I
    jal     coll_below_I
    j       ccb_done
ccb_not_I:
    addi    $r2, $r0, 1
    bne     $r12, $r2, ccb_not_O
    jal     coll_below_O
    j       ccb_done
ccb_not_O:
    addi    $r2, $r0, 2
    bne     $r12, $r2, ccb_not_T
    jal     coll_below_T
    j       ccb_done
ccb_not_T:
    addi    $r2, $r0, 3
    bne     $r12, $r2, ccb_not_S
    jal     coll_below_S
    j       ccb_done
ccb_not_S:
    addi    $r2, $r0, 4
    bne     $r12, $r2, ccb_not_Z
    jal     coll_below_Z
    j       ccb_done
ccb_not_Z:
    addi    $r2, $r0, 5
    bne     $r12, $r2, ccb_not_J
    jal     coll_below_J
    j       ccb_done
ccb_not_J:
    jal     coll_below_L
    j       ccb_done

# ── Rotated collision-below dispatch ────────────────────────
# Dispatch on (piece_type, piece_rot != 0)
ccb_rotated:
    bne     $r12, $r0, ccbr_not_I
    jal     coll_below_I_rot1      # I only has 2 rotations
    j       ccb_done
ccbr_not_I:
    addi    $r2, $r0, 2
    bne     $r12, $r2, ccbr_not_T
    addi    $r2, $r0, 1
    bne     $r13, $r2, ccbr_T_not1
    jal     coll_below_T_rot1
    j       ccb_done
ccbr_T_not1:
    addi    $r2, $r0, 2
    bne     $r13, $r2, ccbr_T_not2
    jal     coll_below_T_rot2
    j       ccb_done
ccbr_T_not2:
    jal     coll_below_T_rot3
    j       ccb_done
ccbr_not_T:
    addi    $r2, $r0, 3
    bne     $r12, $r2, ccbr_not_S
    jal     coll_below_S_rot1      # S has 2 rotations
    j       ccb_done
ccbr_not_S:
    addi    $r2, $r0, 4
    bne     $r12, $r2, ccbr_not_Z
    jal     coll_below_Z_rot1      # Z has 2 rotations
    j       ccb_done
ccbr_not_Z:
    addi    $r2, $r0, 5
    bne     $r12, $r2, ccbr_not_J
    addi    $r2, $r0, 1
    bne     $r13, $r2, ccbr_J_not1
    jal     coll_below_J_rot1
    j       ccb_done
ccbr_J_not1:
    addi    $r2, $r0, 2
    bne     $r13, $r2, ccbr_J_not2
    jal     coll_below_J_rot2
    j       ccb_done
ccbr_J_not2:
    jal     coll_below_J_rot3
    j       ccb_done
ccbr_not_J:
    addi    $r2, $r0, 1
    bne     $r13, $r2, ccbr_L_not1
    jal     coll_below_L_rot1
    j       ccb_done
ccbr_L_not1:
    addi    $r2, $r0, 2
    bne     $r13, $r2, ccbr_L_not2
    jal     coll_below_L_rot2
    j       ccb_done
ccbr_L_not2:
    jal     coll_below_L_rot3

ccb_done:
    lw      $r31, 0($r29)
    addi    $r29, $r29, 1
    jr      $r31

# ── Per-piece collision-below routines ───────────────────────
# Each is a leaf.  $r8 is set to 1 on first occupied cell found.
# $r4 = address scratch, $r5,$r6 = multiply scratch, $r9 = loaded value.
# row*10 computed as (row<<3)+(row<<1).

# Helper macro (inlined): compute locked_board addr for (row_reg+dr, $r11+dc)
# into $r4, load into $r9, branch to hit_label if nonzero.

# I-piece — new cells at (row+1, col+0..3)
coll_below_I:
    addi    $r6, $r10, 1
    sll     $r4, $r6, 3
    sll     $r5, $r6, 1
    add     $r4, $r4, $r5
    add     $r4, $r4, $r11
    add     $r4, $r26, $r4        # locked[(row+1)*10+col]
    lw      $r9, 0($r4)
    bne     $r9, $r0, cbi_hit
    addi    $r4, $r4, 1
    lw      $r9, 0($r4)
    bne     $r9, $r0, cbi_hit
    addi    $r4, $r4, 1
    lw      $r9, 0($r4)
    bne     $r9, $r0, cbi_hit
    addi    $r4, $r4, 1
    lw      $r9, 0($r4)
    bne     $r9, $r0, cbi_hit
    jr      $r31
cbi_hit:
    addi    $r8, $r0, 1
    jr      $r31

# O-piece — new cells at (row+1,col),(row+1,col+1),(row+2,col),(row+2,col+1)
coll_below_O:
    addi    $r6, $r10, 1
    sll     $r4, $r6, 3
    sll     $r5, $r6, 1
    add     $r4, $r4, $r5
    add     $r4, $r4, $r11
    add     $r4, $r26, $r4
    lw      $r9, 0($r4)
    bne     $r9, $r0, cbo_hit
    addi    $r4, $r4, 1
    lw      $r9, 0($r4)
    bne     $r9, $r0, cbo_hit
    addi    $r6, $r10, 2
    sll     $r4, $r6, 3
    sll     $r5, $r6, 1
    add     $r4, $r4, $r5
    add     $r4, $r4, $r11
    add     $r4, $r26, $r4
    lw      $r9, 0($r4)
    bne     $r9, $r0, cbo_hit
    addi    $r4, $r4, 1
    lw      $r9, 0($r4)
    bne     $r9, $r0, cbo_hit
    jr      $r31
cbo_hit:
    addi    $r8, $r0, 1
    jr      $r31

# T-piece — new cells at (row+1,col),(row+1,col+1),(row+1,col+2),(row+2,col+1)
coll_below_T:
    addi    $r6, $r10, 1
    sll     $r4, $r6, 3
    sll     $r5, $r6, 1
    add     $r4, $r4, $r5
    add     $r4, $r4, $r11
    add     $r4, $r26, $r4
    lw      $r9, 0($r4)
    bne     $r9, $r0, cbt_hit
    addi    $r4, $r4, 1
    lw      $r9, 0($r4)
    bne     $r9, $r0, cbt_hit
    addi    $r4, $r4, 1
    lw      $r9, 0($r4)
    bne     $r9, $r0, cbt_hit
    addi    $r6, $r10, 2
    sll     $r4, $r6, 3
    sll     $r5, $r6, 1
    add     $r4, $r4, $r5
    add     $r4, $r4, $r11
    addi    $r4, $r4, 1
    add     $r4, $r26, $r4
    lw      $r9, 0($r4)
    bne     $r9, $r0, cbt_hit
    jr      $r31
cbt_hit:
    addi    $r8, $r0, 1
    jr      $r31

# S-piece — new cells at (row+1,col+1),(row+1,col+2),(row+2,col),(row+2,col+1)
coll_below_S:
    addi    $r6, $r10, 1
    sll     $r4, $r6, 3
    sll     $r5, $r6, 1
    add     $r4, $r4, $r5
    add     $r4, $r4, $r11
    addi    $r4, $r4, 1
    add     $r4, $r26, $r4
    lw      $r9, 0($r4)
    bne     $r9, $r0, cbs_hit
    addi    $r4, $r4, 1
    lw      $r9, 0($r4)
    bne     $r9, $r0, cbs_hit
    addi    $r6, $r10, 2
    sll     $r4, $r6, 3
    sll     $r5, $r6, 1
    add     $r4, $r4, $r5
    add     $r4, $r4, $r11
    add     $r4, $r26, $r4
    lw      $r9, 0($r4)
    bne     $r9, $r0, cbs_hit
    addi    $r4, $r4, 1
    lw      $r9, 0($r4)
    bne     $r9, $r0, cbs_hit
    jr      $r31
cbs_hit:
    addi    $r8, $r0, 1
    jr      $r31

# Z-piece — new cells at (row+1,col),(row+1,col+1),(row+2,col+1),(row+2,col+2)
coll_below_Z:
    addi    $r6, $r10, 1
    sll     $r4, $r6, 3
    sll     $r5, $r6, 1
    add     $r4, $r4, $r5
    add     $r4, $r4, $r11
    add     $r4, $r26, $r4
    lw      $r9, 0($r4)
    bne     $r9, $r0, cbz_hit
    addi    $r4, $r4, 1
    lw      $r9, 0($r4)
    bne     $r9, $r0, cbz_hit
    addi    $r6, $r10, 2
    sll     $r4, $r6, 3
    sll     $r5, $r6, 1
    add     $r4, $r4, $r5
    add     $r4, $r4, $r11
    addi    $r4, $r4, 1
    add     $r4, $r26, $r4
    lw      $r9, 0($r4)
    bne     $r9, $r0, cbz_hit
    addi    $r4, $r4, 1
    lw      $r9, 0($r4)
    bne     $r9, $r0, cbz_hit
    jr      $r31
cbz_hit:
    addi    $r8, $r0, 1
    jr      $r31

# J-piece — new cells at (row+1,col),(row+2,col),(row+2,col+1),(row+2,col+2)
coll_below_J:
    addi    $r6, $r10, 1
    sll     $r4, $r6, 3
    sll     $r5, $r6, 1
    add     $r4, $r4, $r5
    add     $r4, $r4, $r11
    add     $r4, $r26, $r4
    lw      $r9, 0($r4)
    bne     $r9, $r0, cbj_hit
    addi    $r6, $r10, 2
    sll     $r4, $r6, 3
    sll     $r5, $r6, 1
    add     $r4, $r4, $r5
    add     $r4, $r4, $r11
    add     $r4, $r26, $r4
    lw      $r9, 0($r4)
    bne     $r9, $r0, cbj_hit
    addi    $r4, $r4, 1
    lw      $r9, 0($r4)
    bne     $r9, $r0, cbj_hit
    addi    $r4, $r4, 1
    lw      $r9, 0($r4)
    bne     $r9, $r0, cbj_hit
    jr      $r31
cbj_hit:
    addi    $r8, $r0, 1
    jr      $r31

# L-piece — new cells at (row+1,col+2),(row+2,col),(row+2,col+1),(row+2,col+2)
coll_below_L:
    addi    $r6, $r10, 1
    sll     $r4, $r6, 3
    sll     $r5, $r6, 1
    add     $r4, $r4, $r5
    add     $r4, $r4, $r11
    addi    $r4, $r4, 2
    add     $r4, $r26, $r4
    lw      $r9, 0($r4)
    bne     $r9, $r0, cbl_hit
    addi    $r6, $r10, 2
    sll     $r4, $r6, 3
    sll     $r5, $r6, 1
    add     $r4, $r4, $r5
    add     $r4, $r4, $r11
    add     $r4, $r26, $r4
    lw      $r9, 0($r4)
    bne     $r9, $r0, cbl_hit
    addi    $r4, $r4, 1
    lw      $r9, 0($r4)
    bne     $r9, $r0, cbl_hit
    addi    $r4, $r4, 1
    lw      $r9, 0($r4)
    bne     $r9, $r0, cbl_hit
    jr      $r31
cbl_hit:
    addi    $r8, $r0, 1
    jr      $r31

##############################################################
# CHECK_GAMEOVER — leaf
#
# Scans locked_board rows 0-1 (indices 0..19).
# If any cell is occupied the game is over → infinite loop (halt).
##############################################################
check_gameover:
    addi    $r2, $r0, 19
cgo_loop:
    add     $r3, $r26, $r2
    lw      $r4, 0($r3)
    bne     $r4, $r0, cgo_halt
    bne     $r2, $r0, cgo_dec
    jr      $r31                  # all clear
cgo_dec:
    addi    $r2, $r2, -1
    j       cgo_loop
cgo_halt:
    addi    $r2, $r0, 4097
    addi    $r3, $r0, -1          # 0xFFFF — all LEDs on
    sw      $r3, 0($r2)           # light up LEDs
cgo_loop2:
    lw      $r2, 0($r28)          # read buttons MMIO
    addi    $r3, $r0, 16          # bit 4 = reset button
    and     $r2, $r2, $r3
    bne     $r2, $r0, cgo_restart
    j       cgo_loop2             # GAME OVER — freeze
cgo_restart:
    j       start

##############################################################
# LOCK_PIECE — stamp active piece into locked_board
##############################################################
lock_piece:
    addi    $r29, $r29, -1
    sw      $r31, 0($r29)

    lw      $r10, 0($r21)
    lw      $r11, 0($r22)
    lw      $r12, 0($r25)
    lw      $r14, 0($r27)         # piece_rot
    addi    $r13, $r12, 1         # color = type+1

    bne     $r14, $r0, lp_rotated

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
    j       lp_done

# ── Rotated lock dispatch ────────────────────────────────────
lp_rotated:
    bne     $r12, $r0, lpr_not_I
    jal     lock_I_rot1
    j       lp_done
lpr_not_I:
    addi    $r2, $r0, 2
    bne     $r12, $r2, lpr_not_T
    addi    $r2, $r0, 1
    bne     $r14, $r2, lpr_T_not1
    jal     lock_T_rot1
    j       lp_done
lpr_T_not1:
    addi    $r2, $r0, 2
    bne     $r14, $r2, lpr_T_not2
    jal     lock_T_rot2
    j       lp_done
lpr_T_not2:
    jal     lock_T_rot3
    j       lp_done
lpr_not_T:
    addi    $r2, $r0, 3
    bne     $r12, $r2, lpr_not_S
    jal     lock_S_rot1
    j       lp_done
lpr_not_S:
    addi    $r2, $r0, 4
    bne     $r12, $r2, lpr_not_Z
    jal     lock_Z_rot1
    j       lp_done
lpr_not_Z:
    addi    $r2, $r0, 5
    bne     $r12, $r2, lpr_not_J
    addi    $r2, $r0, 1
    bne     $r14, $r2, lpr_J_not1
    jal     lock_J_rot1
    j       lp_done
lpr_J_not1:
    addi    $r2, $r0, 2
    bne     $r14, $r2, lpr_J_not2
    jal     lock_J_rot2
    j       lp_done
lpr_J_not2:
    jal     lock_J_rot3
    j       lp_done
lpr_not_J:
    addi    $r2, $r0, 1
    bne     $r14, $r2, lpr_L_not1
    jal     lock_L_rot1
    j       lp_done
lpr_L_not1:
    addi    $r2, $r0, 2
    bne     $r14, $r2, lpr_L_not2
    jal     lock_L_rot2
    j       lp_done
lpr_L_not2:
    jal     lock_L_rot3

lp_done:
    lw      $r31, 0($r29)
    addi    $r29, $r29, 1
    jr      $r31

lock_I:
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
    sll     $r4, $r10, 3
    sll     $r5, $r10, 1
    add     $r4, $r4, $r5
    add     $r4, $r4, $r11
    add     $r4, $r26, $r4
    sw      $r13, 0($r4)
    addi    $r4, $r4, 1
    sw      $r13, 0($r4)
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
    sll     $r4, $r10, 3
    sll     $r5, $r10, 1
    add     $r4, $r4, $r5
    add     $r4, $r4, $r11
    addi    $r4, $r4, 1
    add     $r4, $r26, $r4
    sw      $r13, 0($r4)
    addi    $r4, $r4, 1
    sw      $r13, 0($r4)
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
    sll     $r4, $r10, 3
    sll     $r5, $r10, 1
    add     $r4, $r4, $r5
    add     $r4, $r4, $r11
    add     $r4, $r26, $r4
    sw      $r13, 0($r4)
    addi    $r4, $r4, 1
    sw      $r13, 0($r4)
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
    sll     $r4, $r10, 3
    sll     $r5, $r10, 1
    add     $r4, $r4, $r5
    add     $r4, $r4, $r11
    add     $r4, $r26, $r4
    sw      $r13, 0($r4)
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
    sll     $r4, $r10, 3
    sll     $r5, $r10, 1
    add     $r4, $r4, $r5
    add     $r4, $r4, $r11
    addi    $r4, $r4, 2
    add     $r4, $r26, $r4
    sw      $r13, 0($r4)
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
# SPAWN_PIECE — pick next piece via LFSR, reset position/timer
##############################################################
spawn_piece:
    addi    $r29, $r29, -1
    sw      $r31, 0($r29)

    jal     lfsr_get_piece        # returns piece type (0-6) in $r2
    sw      $r2, 0($r25)          # piece_type = result
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
#
# Uses the custom `lfsr $rd, $rs` instruction (aluop 01000):
#   polynomial x^7+x^6+1, feedback = bit[6] XOR bit[5]
#   result = { state[5:0], feedback }
# The ~12-instruction XOR/shift sequence is replaced by one cycle.
#
# Reads/writes lfsr_state at addr 663.
# Returns piece type (0-6) in $r2.
# Leaf function. Uses $r4,$r5.
##############################################################
lfsr_get_piece:
    addi    $r5, $r0, 663
    lw      $r2, 0($r5)           # $r2 = current lfsr_state

    lfsr    $r2, $r2, $r0         # one-cycle LFSR step (custom instruction)
    # hardware guard (state==0 → 1) already handled in processor.v

    sw      $r2, 0($r5)           # save new lfsr_state

    # piece_type = state % 7  (state is 1-127, so at most 18 subtracts)
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
#   2. Overlay active piece.
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
    j       render_draw_piece
render_copy_dec:
    addi    $r2, $r2, -1
    j       render_copy

render_draw_piece:
    lw      $r10, 0($r21)
    lw      $r11, 0($r22)
    lw      $r12, 0($r25)
    lw      $r13, 0($r27)         # piece_rot
    addi    $r19, $r12, 1         # color = type+1

    bne     $r13, $r0, rd_rotated

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
    j       rd_done

# ── Rotated draw dispatch ────────────────────────────────────
rd_rotated:
    bne     $r12, $r0, rdr_not_I
    jal     draw_I_rot1
    j       rd_done
rdr_not_I:
    addi    $r2, $r0, 2
    bne     $r12, $r2, rdr_not_T
    addi    $r2, $r0, 1
    bne     $r13, $r2, rdr_T_not1
    jal     draw_T_rot1
    j       rd_done
rdr_T_not1:
    addi    $r2, $r0, 2
    bne     $r13, $r2, rdr_T_not2
    jal     draw_T_rot2
    j       rd_done
rdr_T_not2:
    jal     draw_T_rot3
    j       rd_done
rdr_not_T:
    addi    $r2, $r0, 3
    bne     $r12, $r2, rdr_not_S
    jal     draw_S_rot1
    j       rd_done
rdr_not_S:
    addi    $r2, $r0, 4
    bne     $r12, $r2, rdr_not_Z
    jal     draw_Z_rot1
    j       rd_done
rdr_not_Z:
    addi    $r2, $r0, 5
    bne     $r12, $r2, rdr_not_J
    addi    $r2, $r0, 1
    bne     $r13, $r2, rdr_J_not1
    jal     draw_J_rot1
    j       rd_done
rdr_J_not1:
    addi    $r2, $r0, 2
    bne     $r13, $r2, rdr_J_not2
    jal     draw_J_rot2
    j       rd_done
rdr_J_not2:
    jal     draw_J_rot3
    j       rd_done
rdr_not_J:
    addi    $r2, $r0, 1
    bne     $r13, $r2, rdr_L_not1
    jal     draw_L_rot1
    j       rd_done
rdr_L_not1:
    addi    $r2, $r0, 2
    bne     $r13, $r2, rdr_L_not2
    jal     draw_L_rot2
    j       rd_done
rdr_L_not2:
    jal     draw_L_rot3

rd_done:
    lw      $r31, 0($r29)
    addi    $r29, $r29, 1
    jr      $r31

draw_I:
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
    sll     $r4, $r10, 3
    sll     $r5, $r10, 1
    add     $r4, $r4, $r5
    add     $r4, $r4, $r11
    add     $r4, $r20, $r4
    sw      $r19, 0($r4)
    addi    $r4, $r4, 1
    sw      $r19, 0($r4)
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
    sll     $r4, $r10, 3
    sll     $r5, $r10, 1
    add     $r4, $r4, $r5
    add     $r4, $r4, $r11
    addi    $r4, $r4, 1
    add     $r4, $r20, $r4
    sw      $r19, 0($r4)
    addi    $r4, $r4, 1
    sw      $r19, 0($r4)
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
    sll     $r4, $r10, 3
    sll     $r5, $r10, 1
    add     $r4, $r4, $r5
    add     $r4, $r4, $r11
    add     $r4, $r20, $r4
    sw      $r19, 0($r4)
    addi    $r4, $r4, 1
    sw      $r19, 0($r4)
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
    sll     $r4, $r10, 3
    sll     $r5, $r10, 1
    add     $r4, $r4, $r5
    add     $r4, $r4, $r11
    add     $r4, $r20, $r4
    sw      $r19, 0($r4)
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
    sll     $r4, $r10, 3
    sll     $r5, $r10, 1
    add     $r4, $r4, $r5
    add     $r4, $r4, $r11
    addi    $r4, $r4, 2
    add     $r4, $r20, $r4
    sw      $r19, 0($r4)
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

##############################################################
# READ_INPUT — detect button rising edges, call handlers
# Reads MMIO[4098]: bit0=left, bit1=right, bit2=rotate
# Rising-edge detected via btn_prev at addr 661.
##############################################################
read_input:
    addi    $r29, $r29, -3        # slots: [0]=btn_prev [1]=btn_cur [2]=$r31
    sw      $r31, 2($r29)

    lw      $r2, 0($r28)          # current button state
    addi    $r4, $r0, 661         # addr(btn_prev)
    lw      $r3, 0($r4)           # previous state
    sw      $r2, 0($r4)           # save current as new prev
    sw      $r2, 1($r29)          # stash current on stack
    sw      $r3, 0($r29)          # stash prev on stack

    # ── Left (bit 0) rising edge? ─────────────────────────
    addi    $r5, $r0, 1
    and     $r6, $r2, $r5
    bne     $r6, $r0, ri_left_now
    j       ri_right
ri_left_now:
    and     $r7, $r3, $r5
    bne     $r7, $r0, ri_right    # was held — skip
    jal     move_left
    lw      $r2, 1($r29)          # restore (clobbered by collision fn)
    lw      $r3, 0($r29)

    # ── Right (bit 1) rising edge? ────────────────────────
ri_right:
    addi    $r5, $r0, 2
    and     $r6, $r2, $r5
    bne     $r6, $r0, ri_right_now
    j       ri_rotate
ri_right_now:
    and     $r7, $r3, $r5
    bne     $r7, $r0, ri_rotate
    jal     move_right
    lw      $r2, 1($r29)          # restore
    lw      $r3, 0($r29)

    # ── Rotate (bit 2) rising edge? ───────────────────────
ri_rotate:
    addi    $r5, $r0, 4
    and     $r6, $r2, $r5
    bne     $r6, $r0, ri_rot_now
    j       ri_soft_drop
ri_rot_now:
    and     $r7, $r3, $r5
    bne     $r7, $r0, ri_soft_drop
    jal     rotate_piece
    lw      $r2, 1($r29)          # restore for soft drop check

    # ── Soft drop (bit 3) level-triggered ─────────────────
ri_soft_drop:
    addi    $r5, $r0, 8
    and     $r6, $r2, $r5
    bne     $r6, $r0, ri_do_drop
    j       ri_done
ri_do_drop:
    addi    $r5, $r0, 1
    sw      $r5, 0($r23)          # gravity_timer = 1 → force drop this frame

ri_done:
    lw      $r31, 2($r29)
    addi    $r29, $r29, 3
    jr      $r31

##############################################################
# MOVE_LEFT — move piece left if not at wall and no collision
##############################################################
move_left:
    addi    $r29, $r29, -1
    sw      $r31, 0($r29)

    lw      $r11, 0($r22)         # piece_col
    # All pieces: leftmost cell is always at col or col+0 → wall at col==0
    bne     $r11, $r0, ml_not_wall
    j       ml_done
ml_not_wall:
    jal     check_collision_left  # returns $r8
    bne     $r8, $r0, ml_done
    addi    $r11, $r11, -1
    sw      $r11, 0($r22)
ml_done:
    lw      $r31, 0($r29)
    addi    $r29, $r29, 1
    jr      $r31

##############################################################
# MOVE_RIGHT — move piece right if not at wall and no collision
# Right-wall bound depends on piece width (rotation-aware).
##############################################################
move_right:
    addi    $r29, $r29, -1
    sw      $r31, 0($r29)

    lw      $r11, 0($r22)         # piece_col
    lw      $r12, 0($r25)         # piece_type
    lw      $r13, 0($r27)         # piece_rot

    # If rot == 0, use existing rot-0 width dispatch
    bne     $r13, $r0, mr_rotated

    # rot-0 width: I→4(max col=5), O→2(max col=7), others→3(max col=6)
    bne     $r12, $r0, mr0_not_I
    addi    $r4, $r0, 6           # I: 4-wide, col+4<=9 -> col<6
    blt     $r11, $r4, mr_wall_ok
    j       mr_done
mr0_not_I:
    addi    $r2, $r0, 1
    bne     $r12, $r2, mr0_not_O
    addi    $r4, $r0, 8           # O: 2-wide, col+2<=9 -> col<8
    blt     $r11, $r4, mr_wall_ok
    j       mr_done
mr0_not_O:
    addi    $r4, $r0, 7           # T,S,Z,J,L: 3-wide, col+3<=9 -> col<7
    blt     $r11, $r4, mr_wall_ok
    j       mr_done

mr_rotated:
    # I rot-1: 1-wide, max col 9
    bne     $r12, $r0, mr_rot_not_I
    addi    $r4, $r0, 9           # I rot1: 1-wide, col must be <9 to move right
    blt     $r11, $r4, mr_wall_ok
    j       mr_done
mr_rot_not_I:
    # Others: even rot → 3-wide (max 7), odd rot → 2-wide (max 8)
    sra     $r2, $r13, 1
    sll     $r2, $r2, 1
    sub     $r2, $r13, $r2        # $r2 = piece_rot & 1
    bne     $r2, $r0, mr_rot_odd
    addi    $r4, $r0, 7           # even rot: 3-wide, col+3<=9 -> col<7
    blt     $r11, $r4, mr_wall_ok
    j       mr_done
mr_rot_odd:
    addi    $r4, $r0, 8           # odd rot: 2-wide, col+2<=9 -> col<8
    blt     $r11, $r4, mr_wall_ok
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
# CHECK_COLLISION_LEFT — $r8=1 if locked cell blocks leftward move
# Rotation-aware dispatcher.  Reads $r10,$r11,$r12,$r13 from memory.
# $r4,$r5,$r6,$r9 = scratch.  row*10 = (row<<3)+(row<<1).
##############################################################
check_collision_left:
    addi    $r29, $r29, -1
    sw      $r31, 0($r29)

    lw      $r10, 0($r21)
    lw      $r11, 0($r22)
    lw      $r12, 0($r25)
    lw      $r13, 0($r27)         # piece_rot
    addi    $r8,  $r0, 0

    bne     $r13, $r0, ccl_rotated

    # ── rot-0 dispatch ────────────────────────────────────
    bne     $r12, $r0, ccl0_not_I
    jal     coll_left_I
    j       ccl_done
ccl0_not_I:
    addi    $r2, $r0, 1
    bne     $r12, $r2, ccl0_not_O
    jal     coll_left_O
    j       ccl_done
ccl0_not_O:
    addi    $r2, $r0, 2
    bne     $r12, $r2, ccl0_not_T
    jal     coll_left_T
    j       ccl_done
ccl0_not_T:
    addi    $r2, $r0, 3
    bne     $r12, $r2, ccl0_not_S
    jal     coll_left_S
    j       ccl_done
ccl0_not_S:
    addi    $r2, $r0, 4
    bne     $r12, $r2, ccl0_not_Z
    jal     coll_left_Z
    j       ccl_done
ccl0_not_Z:
    addi    $r2, $r0, 5
    bne     $r12, $r2, ccl0_not_J
    jal     coll_left_J
    j       ccl_done
ccl0_not_J:
    jal     coll_left_L
    j       ccl_done

    # ── rotated dispatch ──────────────────────────────────
ccl_rotated:
    bne     $r12, $r0, cclr_not_I
    jal     coll_left_I_rot1
    j       ccl_done
cclr_not_I:
    addi    $r2, $r0, 2
    bne     $r12, $r2, cclr_not_T
    addi    $r2, $r0, 1
    bne     $r13, $r2, cclr_T_not1
    jal     coll_left_T_rot1
    j       ccl_done
cclr_T_not1:
    addi    $r2, $r0, 2
    bne     $r13, $r2, cclr_T_not2
    jal     coll_left_T_rot2
    j       ccl_done
cclr_T_not2:
    jal     coll_left_T_rot3
    j       ccl_done
cclr_not_T:
    addi    $r2, $r0, 3
    bne     $r12, $r2, cclr_not_S
    jal     coll_left_S_rot1
    j       ccl_done
cclr_not_S:
    addi    $r2, $r0, 4
    bne     $r12, $r2, cclr_not_Z
    jal     coll_left_Z_rot1
    j       ccl_done
cclr_not_Z:
    addi    $r2, $r0, 5
    bne     $r12, $r2, cclr_not_J
    addi    $r2, $r0, 1
    bne     $r13, $r2, cclr_J_not1
    jal     coll_left_J_rot1
    j       ccl_done
cclr_J_not1:
    addi    $r2, $r0, 2
    bne     $r13, $r2, cclr_J_not2
    jal     coll_left_J_rot2
    j       ccl_done
cclr_J_not2:
    jal     coll_left_J_rot3
    j       ccl_done
cclr_not_J:
    addi    $r2, $r0, 1
    bne     $r13, $r2, cclr_L_not1
    jal     coll_left_L_rot1
    j       ccl_done
cclr_L_not1:
    addi    $r2, $r0, 2
    bne     $r13, $r2, cclr_L_not2
    jal     coll_left_L_rot2
    j       ccl_done
cclr_L_not2:
    jal     coll_left_L_rot3

ccl_done:
    lw      $r31, 0($r29)
    addi    $r29, $r29, 1
    jr      $r31

# ── rot-0 left-collision leaf routines ───────────────────────
# Each checks the locked cell immediately left of the leftmost
# occupied cell in each piece row.  $r8=1 on hit.
# addr = LOCKED_BASE + row*10 + col

# I rot-0: 1 row, check locked[row][col-1]
coll_left_I:
    sll     $r4, $r10, 3
    sll     $r5, $r10, 1
    add     $r4, $r4, $r5
    add     $r4, $r4, $r11
    addi    $r4, $r4, -1
    add     $r4, $r26, $r4
    lw      $r9, 0($r4)
    bne     $r9, $r0, cliL_hit
    jr      $r31
cliL_hit:
    addi    $r8, $r0, 1
    jr      $r31

# O rot-0: check locked[row][col-1] and locked[row+1][col-1]
coll_left_O:
    sll     $r4, $r10, 3
    sll     $r5, $r10, 1
    add     $r4, $r4, $r5
    add     $r4, $r4, $r11
    addi    $r4, $r4, -1
    add     $r4, $r26, $r4
    lw      $r9, 0($r4)
    bne     $r9, $r0, cloL_hit
    addi    $r6, $r10, 1
    sll     $r4, $r6, 3
    sll     $r5, $r6, 1
    add     $r4, $r4, $r5
    add     $r4, $r4, $r11
    addi    $r4, $r4, -1
    add     $r4, $r26, $r4
    lw      $r9, 0($r4)
    bne     $r9, $r0, cloL_hit
    jr      $r31
cloL_hit:
    addi    $r8, $r0, 1
    jr      $r31

# T rot-0: cells (r,c)(r,c+1)(r,c+2)(r+1,c+1)
# Left edges: row0→col, row1→col+1. Check col-1 and col.
coll_left_T:
    sll     $r4, $r10, 3
    sll     $r5, $r10, 1
    add     $r4, $r4, $r5
    add     $r4, $r4, $r11
    addi    $r4, $r4, -1
    add     $r4, $r26, $r4
    lw      $r9, 0($r4)
    bne     $r9, $r0, cltL_hit
    addi    $r6, $r10, 1
    sll     $r4, $r6, 3
    sll     $r5, $r6, 1
    add     $r4, $r4, $r5
    add     $r4, $r4, $r11
    add     $r4, $r26, $r4
    lw      $r9, 0($r4)
    bne     $r9, $r0, cltL_hit
    jr      $r31
cltL_hit:
    addi    $r8, $r0, 1
    jr      $r31

# S rot-0: cells (r,c+1)(r,c+2)(r+1,c)(r+1,c+1)
# Left edges: row0→col+1 (check col), row1→col (check col-1)
coll_left_S:
    sll     $r4, $r10, 3
    sll     $r5, $r10, 1
    add     $r4, $r4, $r5
    add     $r4, $r4, $r11
    add     $r4, $r26, $r4
    lw      $r9, 0($r4)
    bne     $r9, $r0, clsL_hit
    addi    $r6, $r10, 1
    sll     $r4, $r6, 3
    sll     $r5, $r6, 1
    add     $r4, $r4, $r5
    add     $r4, $r4, $r11
    addi    $r4, $r4, -1
    add     $r4, $r26, $r4
    lw      $r9, 0($r4)
    bne     $r9, $r0, clsL_hit
    jr      $r31
clsL_hit:
    addi    $r8, $r0, 1
    jr      $r31

# Z rot-0: cells (r,c)(r,c+1)(r+1,c+1)(r+1,c+2)
# Left edges: row0→col (check col-1), row1→col+1 (check col)
coll_left_Z:
    sll     $r4, $r10, 3
    sll     $r5, $r10, 1
    add     $r4, $r4, $r5
    add     $r4, $r4, $r11
    addi    $r4, $r4, -1
    add     $r4, $r26, $r4
    lw      $r9, 0($r4)
    bne     $r9, $r0, clzL_hit
    addi    $r6, $r10, 1
    sll     $r4, $r6, 3
    sll     $r5, $r6, 1
    add     $r4, $r4, $r5
    add     $r4, $r4, $r11
    add     $r4, $r26, $r4
    lw      $r9, 0($r4)
    bne     $r9, $r0, clzL_hit
    jr      $r31
clzL_hit:
    addi    $r8, $r0, 1
    jr      $r31

# J rot-0: cells (r,c)(r+1,c)(r+1,c+1)(r+1,c+2)
# Left edges: both rows at col. Check col-1 twice.
coll_left_J:
    sll     $r4, $r10, 3
    sll     $r5, $r10, 1
    add     $r4, $r4, $r5
    add     $r4, $r4, $r11
    addi    $r4, $r4, -1
    add     $r4, $r26, $r4
    lw      $r9, 0($r4)
    bne     $r9, $r0, cljL_hit
    addi    $r6, $r10, 1
    sll     $r4, $r6, 3
    sll     $r5, $r6, 1
    add     $r4, $r4, $r5
    add     $r4, $r4, $r11
    addi    $r4, $r4, -1
    add     $r4, $r26, $r4
    lw      $r9, 0($r4)
    bne     $r9, $r0, cljL_hit
    jr      $r31
cljL_hit:
    addi    $r8, $r0, 1
    jr      $r31

# L rot-0: cells (r,c+2)(r+1,c)(r+1,c+1)(r+1,c+2)
# Left edges: row0→col+2 (check col+1), row1→col (check col-1)
coll_left_L:
    sll     $r4, $r10, 3
    sll     $r5, $r10, 1
    add     $r4, $r4, $r5
    add     $r4, $r4, $r11
    addi    $r4, $r4, 1
    add     $r4, $r26, $r4
    lw      $r9, 0($r4)
    bne     $r9, $r0, cllL_hit
    addi    $r6, $r10, 1
    sll     $r4, $r6, 3
    sll     $r5, $r6, 1
    add     $r4, $r4, $r5
    add     $r4, $r4, $r11
    addi    $r4, $r4, -1
    add     $r4, $r26, $r4
    lw      $r9, 0($r4)
    bne     $r9, $r0, cllL_hit
    jr      $r31
cllL_hit:
    addi    $r8, $r0, 1
    jr      $r31

# ── Rotated left-collision leaf routines ─────────────────────

# I rot-1: cells (r,c)(r+1,c)(r+2,c)(r+3,c). Check col-1 in all 4 rows.
coll_left_I_rot1:
    sll     $r4, $r10, 3
    sll     $r5, $r10, 1
    add     $r4, $r4, $r5
    add     $r4, $r4, $r11
    addi    $r4, $r4, -1
    add     $r4, $r26, $r4
    lw      $r9, 0($r4)
    bne     $r9, $r0, clIv_hit
    addi    $r6, $r10, 1
    sll     $r4, $r6, 3
    sll     $r5, $r6, 1
    add     $r4, $r4, $r5
    add     $r4, $r4, $r11
    addi    $r4, $r4, -1
    add     $r4, $r26, $r4
    lw      $r9, 0($r4)
    bne     $r9, $r0, clIv_hit
    addi    $r6, $r10, 2
    sll     $r4, $r6, 3
    sll     $r5, $r6, 1
    add     $r4, $r4, $r5
    add     $r4, $r4, $r11
    addi    $r4, $r4, -1
    add     $r4, $r26, $r4
    lw      $r9, 0($r4)
    bne     $r9, $r0, clIv_hit
    addi    $r6, $r10, 3
    sll     $r4, $r6, 3
    sll     $r5, $r6, 1
    add     $r4, $r4, $r5
    add     $r4, $r4, $r11
    addi    $r4, $r4, -1
    add     $r4, $r26, $r4
    lw      $r9, 0($r4)
    bne     $r9, $r0, clIv_hit
    jr      $r31
clIv_hit:
    addi    $r8, $r0, 1
    jr      $r31

# T rot-1: cells (r,c)(r+1,c)(r+2,c)(r+1,c+1). Left col in all 3 rows is col. Check col-1.
coll_left_T_rot1:
    sll     $r4, $r10, 3
    sll     $r5, $r10, 1
    add     $r4, $r4, $r5
    add     $r4, $r4, $r11
    addi    $r4, $r4, -1
    add     $r4, $r26, $r4
    lw      $r9, 0($r4)
    bne     $r9, $r0, clTr1_hit
    addi    $r6, $r10, 1
    sll     $r4, $r6, 3
    sll     $r5, $r6, 1
    add     $r4, $r4, $r5
    add     $r4, $r4, $r11
    addi    $r4, $r4, -1
    add     $r4, $r26, $r4
    lw      $r9, 0($r4)
    bne     $r9, $r0, clTr1_hit
    addi    $r6, $r10, 2
    sll     $r4, $r6, 3
    sll     $r5, $r6, 1
    add     $r4, $r4, $r5
    add     $r4, $r4, $r11
    addi    $r4, $r4, -1
    add     $r4, $r26, $r4
    lw      $r9, 0($r4)
    bne     $r9, $r0, clTr1_hit
    jr      $r31
clTr1_hit:
    addi    $r8, $r0, 1
    jr      $r31

# T rot-2: cells (r,c+1)(r+1,c)(r+1,c+1)(r+1,c+2).
# Left: row0->col+1 check col, row1->col check col-1
coll_left_T_rot2:
    sll     $r4, $r10, 3
    sll     $r5, $r10, 1
    add     $r4, $r4, $r5
    add     $r4, $r4, $r11
    add     $r4, $r26, $r4
    lw      $r9, 0($r4)
    bne     $r9, $r0, clTr2_hit
    addi    $r6, $r10, 1
    sll     $r4, $r6, 3
    sll     $r5, $r6, 1
    add     $r4, $r4, $r5
    add     $r4, $r4, $r11
    addi    $r4, $r4, -1
    add     $r4, $r26, $r4
    lw      $r9, 0($r4)
    bne     $r9, $r0, clTr2_hit
    jr      $r31
clTr2_hit:
    addi    $r8, $r0, 1
    jr      $r31

# T rot-3: cells (r,c+1)(r+1,c)(r+1,c+1)(r+2,c+1).
# Left: row0->col+1 check col, row1->col check col-1, row2->col+1 check col
coll_left_T_rot3:
    sll     $r4, $r10, 3
    sll     $r5, $r10, 1
    add     $r4, $r4, $r5
    add     $r4, $r4, $r11
    add     $r4, $r26, $r4
    lw      $r9, 0($r4)
    bne     $r9, $r0, clTr3_hit
    addi    $r6, $r10, 1
    sll     $r4, $r6, 3
    sll     $r5, $r6, 1
    add     $r4, $r4, $r5
    add     $r4, $r4, $r11
    addi    $r4, $r4, -1
    add     $r4, $r26, $r4
    lw      $r9, 0($r4)
    bne     $r9, $r0, clTr3_hit
    addi    $r6, $r10, 2
    sll     $r4, $r6, 3
    sll     $r5, $r6, 1
    add     $r4, $r4, $r5
    add     $r4, $r4, $r11
    add     $r4, $r26, $r4
    lw      $r9, 0($r4)
    bne     $r9, $r0, clTr3_hit
    jr      $r31
clTr3_hit:
    addi    $r8, $r0, 1
    jr      $r31

# S rot-1: cells (r,c)(r+1,c)(r+1,c+1)(r+2,c+1).
# Left: row0->col check col-1, row1->col check col-1, row2->col+1 check col
coll_left_S_rot1:
    sll     $r4, $r10, 3
    sll     $r5, $r10, 1
    add     $r4, $r4, $r5
    add     $r4, $r4, $r11
    addi    $r4, $r4, -1
    add     $r4, $r26, $r4
    lw      $r9, 0($r4)
    bne     $r9, $r0, clSr1_hit
    addi    $r6, $r10, 1
    sll     $r4, $r6, 3
    sll     $r5, $r6, 1
    add     $r4, $r4, $r5
    add     $r4, $r4, $r11
    addi    $r4, $r4, -1
    add     $r4, $r26, $r4
    lw      $r9, 0($r4)
    bne     $r9, $r0, clSr1_hit
    addi    $r6, $r10, 2
    sll     $r4, $r6, 3
    sll     $r5, $r6, 1
    add     $r4, $r4, $r5
    add     $r4, $r4, $r11
    add     $r4, $r26, $r4
    lw      $r9, 0($r4)
    bne     $r9, $r0, clSr1_hit
    jr      $r31
clSr1_hit:
    addi    $r8, $r0, 1
    jr      $r31

# Z rot-1: cells (r,c+1)(r+1,c)(r+1,c+1)(r+2,c).
# Left: row0->col+1 check col, row1->col check col-1, row2->col check col-1
coll_left_Z_rot1:
    sll     $r4, $r10, 3
    sll     $r5, $r10, 1
    add     $r4, $r4, $r5
    add     $r4, $r4, $r11
    add     $r4, $r26, $r4
    lw      $r9, 0($r4)
    bne     $r9, $r0, clZr1_hit
    addi    $r6, $r10, 1
    sll     $r4, $r6, 3
    sll     $r5, $r6, 1
    add     $r4, $r4, $r5
    add     $r4, $r4, $r11
    addi    $r4, $r4, -1
    add     $r4, $r26, $r4
    lw      $r9, 0($r4)
    bne     $r9, $r0, clZr1_hit
    addi    $r6, $r10, 2
    sll     $r4, $r6, 3
    sll     $r5, $r6, 1
    add     $r4, $r4, $r5
    add     $r4, $r4, $r11
    addi    $r4, $r4, -1
    add     $r4, $r26, $r4
    lw      $r9, 0($r4)
    bne     $r9, $r0, clZr1_hit
    jr      $r31
clZr1_hit:
    addi    $r8, $r0, 1
    jr      $r31

# J rot-1: cells (r,c)(r,c+1)(r+1,c)(r+2,c). Left in all 3 rows is col. Check col-1.
coll_left_J_rot1:
    sll     $r4, $r10, 3
    sll     $r5, $r10, 1
    add     $r4, $r4, $r5
    add     $r4, $r4, $r11
    addi    $r4, $r4, -1
    add     $r4, $r26, $r4
    lw      $r9, 0($r4)
    bne     $r9, $r0, clJr1_hit
    addi    $r6, $r10, 1
    sll     $r4, $r6, 3
    sll     $r5, $r6, 1
    add     $r4, $r4, $r5
    add     $r4, $r4, $r11
    addi    $r4, $r4, -1
    add     $r4, $r26, $r4
    lw      $r9, 0($r4)
    bne     $r9, $r0, clJr1_hit
    addi    $r6, $r10, 2
    sll     $r4, $r6, 3
    sll     $r5, $r6, 1
    add     $r4, $r4, $r5
    add     $r4, $r4, $r11
    addi    $r4, $r4, -1
    add     $r4, $r26, $r4
    lw      $r9, 0($r4)
    bne     $r9, $r0, clJr1_hit
    jr      $r31
clJr1_hit:
    addi    $r8, $r0, 1
    jr      $r31

# J rot-2: cells (r,c)(r,c+1)(r,c+2)(r+1,c+2).
# Left: row0->col check col-1, row1->col+2 check col+1
coll_left_J_rot2:
    sll     $r4, $r10, 3
    sll     $r5, $r10, 1
    add     $r4, $r4, $r5
    add     $r4, $r4, $r11
    addi    $r4, $r4, -1
    add     $r4, $r26, $r4
    lw      $r9, 0($r4)
    bne     $r9, $r0, clJr2_hit
    addi    $r6, $r10, 1
    sll     $r4, $r6, 3
    sll     $r5, $r6, 1
    add     $r4, $r4, $r5
    add     $r4, $r4, $r11
    addi    $r4, $r4, 1
    add     $r4, $r26, $r4
    lw      $r9, 0($r4)
    bne     $r9, $r0, clJr2_hit
    jr      $r31
clJr2_hit:
    addi    $r8, $r0, 1
    jr      $r31

# J rot-3: cells (r,c+1)(r+1,c+1)(r+2,c)(r+2,c+1).
# Left: row0->col+1 check col, row1->col+1 check col, row2->col check col-1
coll_left_J_rot3:
    sll     $r4, $r10, 3
    sll     $r5, $r10, 1
    add     $r4, $r4, $r5
    add     $r4, $r4, $r11
    add     $r4, $r26, $r4
    lw      $r9, 0($r4)
    bne     $r9, $r0, clJr3_hit
    addi    $r6, $r10, 1
    sll     $r4, $r6, 3
    sll     $r5, $r6, 1
    add     $r4, $r4, $r5
    add     $r4, $r4, $r11
    add     $r4, $r26, $r4
    lw      $r9, 0($r4)
    bne     $r9, $r0, clJr3_hit
    addi    $r6, $r10, 2
    sll     $r4, $r6, 3
    sll     $r5, $r6, 1
    add     $r4, $r4, $r5
    add     $r4, $r4, $r11
    addi    $r4, $r4, -1
    add     $r4, $r26, $r4
    lw      $r9, 0($r4)
    bne     $r9, $r0, clJr3_hit
    jr      $r31
clJr3_hit:
    addi    $r8, $r0, 1
    jr      $r31

# L rot-1: cells (r,c)(r+1,c)(r+2,c)(r+2,c+1). Left in all 3 rows is col. Check col-1.
coll_left_L_rot1:
    sll     $r4, $r10, 3
    sll     $r5, $r10, 1
    add     $r4, $r4, $r5
    add     $r4, $r4, $r11
    addi    $r4, $r4, -1
    add     $r4, $r26, $r4
    lw      $r9, 0($r4)
    bne     $r9, $r0, clLr1_hit
    addi    $r6, $r10, 1
    sll     $r4, $r6, 3
    sll     $r5, $r6, 1
    add     $r4, $r4, $r5
    add     $r4, $r4, $r11
    addi    $r4, $r4, -1
    add     $r4, $r26, $r4
    lw      $r9, 0($r4)
    bne     $r9, $r0, clLr1_hit
    addi    $r6, $r10, 2
    sll     $r4, $r6, 3
    sll     $r5, $r6, 1
    add     $r4, $r4, $r5
    add     $r4, $r4, $r11
    addi    $r4, $r4, -1
    add     $r4, $r26, $r4
    lw      $r9, 0($r4)
    bne     $r9, $r0, clLr1_hit
    jr      $r31
clLr1_hit:
    addi    $r8, $r0, 1
    jr      $r31

# L rot-2: cells (r,c)(r,c+1)(r,c+2)(r+1,c).
# Left: row0->col check col-1, row1->col check col-1
coll_left_L_rot2:
    sll     $r4, $r10, 3
    sll     $r5, $r10, 1
    add     $r4, $r4, $r5
    add     $r4, $r4, $r11
    addi    $r4, $r4, -1
    add     $r4, $r26, $r4
    lw      $r9, 0($r4)
    bne     $r9, $r0, clLr2_hit
    addi    $r6, $r10, 1
    sll     $r4, $r6, 3
    sll     $r5, $r6, 1
    add     $r4, $r4, $r5
    add     $r4, $r4, $r11
    addi    $r4, $r4, -1
    add     $r4, $r26, $r4
    lw      $r9, 0($r4)
    bne     $r9, $r0, clLr2_hit
    jr      $r31
clLr2_hit:
    addi    $r8, $r0, 1
    jr      $r31

# L rot-3: cells (r,c)(r,c+1)(r+1,c+1)(r+2,c+1).
# Left: row0->col check col-1, row1->col+1 check col, row2->col+1 check col
coll_left_L_rot3:
    sll     $r4, $r10, 3
    sll     $r5, $r10, 1
    add     $r4, $r4, $r5
    add     $r4, $r4, $r11
    addi    $r4, $r4, -1
    add     $r4, $r26, $r4
    lw      $r9, 0($r4)
    bne     $r9, $r0, clLr3_hit
    addi    $r6, $r10, 1
    sll     $r4, $r6, 3
    sll     $r5, $r6, 1
    add     $r4, $r4, $r5
    add     $r4, $r4, $r11
    add     $r4, $r26, $r4
    lw      $r9, 0($r4)
    bne     $r9, $r0, clLr3_hit
    addi    $r6, $r10, 2
    sll     $r4, $r6, 3
    sll     $r5, $r6, 1
    add     $r4, $r4, $r5
    add     $r4, $r4, $r11
    add     $r4, $r26, $r4
    lw      $r9, 0($r4)
    bne     $r9, $r0, clLr3_hit
    jr      $r31
clLr3_hit:
    addi    $r8, $r0, 1
    jr      $r31

##############################################################
# CHECK_COLLISION_RIGHT — $r8=1 if locked cell blocks rightward move
##############################################################
check_collision_right:
    addi    $r29, $r29, -1
    sw      $r31, 0($r29)

    lw      $r10, 0($r21)
    lw      $r11, 0($r22)
    lw      $r12, 0($r25)
    lw      $r13, 0($r27)
    addi    $r8,  $r0, 0

    bne     $r13, $r0, ccr_rotated

    bne     $r12, $r0, ccr0_not_I
    jal     coll_right_I
    j       ccr_done
ccr0_not_I:
    addi    $r2, $r0, 1
    bne     $r12, $r2, ccr0_not_O
    jal     coll_right_O
    j       ccr_done
ccr0_not_O:
    addi    $r2, $r0, 2
    bne     $r12, $r2, ccr0_not_T
    jal     coll_right_T
    j       ccr_done
ccr0_not_T:
    addi    $r2, $r0, 3
    bne     $r12, $r2, ccr0_not_S
    jal     coll_right_S
    j       ccr_done
ccr0_not_S:
    addi    $r2, $r0, 4
    bne     $r12, $r2, ccr0_not_Z
    jal     coll_right_Z
    j       ccr_done
ccr0_not_Z:
    addi    $r2, $r0, 5
    bne     $r12, $r2, ccr0_not_J
    jal     coll_right_J
    j       ccr_done
ccr0_not_J:
    jal     coll_right_L
    j       ccr_done

ccr_rotated:
    bne     $r12, $r0, ccrr_not_I
    jal     coll_right_I_rot1
    j       ccr_done
ccrr_not_I:
    addi    $r2, $r0, 2
    bne     $r12, $r2, ccrr_not_T
    addi    $r2, $r0, 1
    bne     $r13, $r2, ccrr_T_not1
    jal     coll_right_T_rot1
    j       ccr_done
ccrr_T_not1:
    addi    $r2, $r0, 2
    bne     $r13, $r2, ccrr_T_not2
    jal     coll_right_T_rot2
    j       ccr_done
ccrr_T_not2:
    jal     coll_right_T_rot3
    j       ccr_done
ccrr_not_T:
    addi    $r2, $r0, 3
    bne     $r12, $r2, ccrr_not_S
    jal     coll_right_S_rot1
    j       ccr_done
ccrr_not_S:
    addi    $r2, $r0, 4
    bne     $r12, $r2, ccrr_not_Z
    jal     coll_right_Z_rot1
    j       ccr_done
ccrr_not_Z:
    addi    $r2, $r0, 5
    bne     $r12, $r2, ccrr_not_J
    addi    $r2, $r0, 1
    bne     $r13, $r2, ccrr_J_not1
    jal     coll_right_J_rot1
    j       ccr_done
ccrr_J_not1:
    addi    $r2, $r0, 2
    bne     $r13, $r2, ccrr_J_not2
    jal     coll_right_J_rot2
    j       ccr_done
ccrr_J_not2:
    jal     coll_right_J_rot3
    j       ccr_done
ccrr_not_J:
    addi    $r2, $r0, 1
    bne     $r13, $r2, ccrr_L_not1
    jal     coll_right_L_rot1
    j       ccr_done
ccrr_L_not1:
    addi    $r2, $r0, 2
    bne     $r13, $r2, ccrr_L_not2
    jal     coll_right_L_rot2
    j       ccr_done
ccrr_L_not2:
    jal     coll_right_L_rot3

ccr_done:
    lw      $r31, 0($r29)
    addi    $r29, $r29, 1
    jr      $r31

# ── rot-0 right-collision leaf routines ──────────────────────

# I rot-0: rightmost col+3. Check locked[row][col+4].
coll_right_I:
    sll     $r4, $r10, 3
    sll     $r5, $r10, 1
    add     $r4, $r4, $r5
    add     $r4, $r4, $r11
    addi    $r4, $r4, 4
    add     $r4, $r26, $r4
    lw      $r9, 0($r4)
    bne     $r9, $r0, criR_hit
    jr      $r31
criR_hit:
    addi    $r8, $r0, 1
    jr      $r31

# O rot-0: check locked[row][col+2] and locked[row+1][col+2]
coll_right_O:
    sll     $r4, $r10, 3
    sll     $r5, $r10, 1
    add     $r4, $r4, $r5
    add     $r4, $r4, $r11
    addi    $r4, $r4, 2
    add     $r4, $r26, $r4
    lw      $r9, 0($r4)
    bne     $r9, $r0, croR_hit
    addi    $r6, $r10, 1
    sll     $r4, $r6, 3
    sll     $r5, $r6, 1
    add     $r4, $r4, $r5
    add     $r4, $r4, $r11
    addi    $r4, $r4, 2
    add     $r4, $r26, $r4
    lw      $r9, 0($r4)
    bne     $r9, $r0, croR_hit
    jr      $r31
croR_hit:
    addi    $r8, $r0, 1
    jr      $r31

# T rot-0: right edges: row0->col+2 check col+3, row1->col+1 check col+2
coll_right_T:
    sll     $r4, $r10, 3
    sll     $r5, $r10, 1
    add     $r4, $r4, $r5
    add     $r4, $r4, $r11
    addi    $r4, $r4, 3
    add     $r4, $r26, $r4
    lw      $r9, 0($r4)
    bne     $r9, $r0, crtR_hit
    addi    $r6, $r10, 1
    sll     $r4, $r6, 3
    sll     $r5, $r6, 1
    add     $r4, $r4, $r5
    add     $r4, $r4, $r11
    addi    $r4, $r4, 2
    add     $r4, $r26, $r4
    lw      $r9, 0($r4)
    bne     $r9, $r0, crtR_hit
    jr      $r31
crtR_hit:
    addi    $r8, $r0, 1
    jr      $r31

# S rot-0: cells (r,c+1)(r,c+2)(r+1,c)(r+1,c+1).
# Right: row0->col+2 check col+3, row1->col+1 check col+2
coll_right_S:
    sll     $r4, $r10, 3
    sll     $r5, $r10, 1
    add     $r4, $r4, $r5
    add     $r4, $r4, $r11
    addi    $r4, $r4, 3
    add     $r4, $r26, $r4
    lw      $r9, 0($r4)
    bne     $r9, $r0, crsR_hit
    addi    $r6, $r10, 1
    sll     $r4, $r6, 3
    sll     $r5, $r6, 1
    add     $r4, $r4, $r5
    add     $r4, $r4, $r11
    addi    $r4, $r4, 2
    add     $r4, $r26, $r4
    lw      $r9, 0($r4)
    bne     $r9, $r0, crsR_hit
    jr      $r31
crsR_hit:
    addi    $r8, $r0, 1
    jr      $r31

# Z rot-0: cells (r,c)(r,c+1)(r+1,c+1)(r+1,c+2).
# Right: row0->col+1 check col+2, row1->col+2 check col+3
coll_right_Z:
    sll     $r4, $r10, 3
    sll     $r5, $r10, 1
    add     $r4, $r4, $r5
    add     $r4, $r4, $r11
    addi    $r4, $r4, 2
    add     $r4, $r26, $r4
    lw      $r9, 0($r4)
    bne     $r9, $r0, crzR_hit
    addi    $r6, $r10, 1
    sll     $r4, $r6, 3
    sll     $r5, $r6, 1
    add     $r4, $r4, $r5
    add     $r4, $r4, $r11
    addi    $r4, $r4, 3
    add     $r4, $r26, $r4
    lw      $r9, 0($r4)
    bne     $r9, $r0, crzR_hit
    jr      $r31
crzR_hit:
    addi    $r8, $r0, 1
    jr      $r31

# J rot-0: cells (r,c)(r+1,c)(r+1,c+1)(r+1,c+2).
# Right: row0->col check col+1, row1->col+2 check col+3
coll_right_J:
    sll     $r4, $r10, 3
    sll     $r5, $r10, 1
    add     $r4, $r4, $r5
    add     $r4, $r4, $r11
    addi    $r4, $r4, 1
    add     $r4, $r26, $r4
    lw      $r9, 0($r4)
    bne     $r9, $r0, crjR_hit
    addi    $r6, $r10, 1
    sll     $r4, $r6, 3
    sll     $r5, $r6, 1
    add     $r4, $r4, $r5
    add     $r4, $r4, $r11
    addi    $r4, $r4, 3
    add     $r4, $r26, $r4
    lw      $r9, 0($r4)
    bne     $r9, $r0, crjR_hit
    jr      $r31
crjR_hit:
    addi    $r8, $r0, 1
    jr      $r31

# L rot-0: cells (r,c+2)(r+1,c)(r+1,c+1)(r+1,c+2).
# Right: row0->col+2 check col+3, row1->col+2 check col+3
coll_right_L:
    sll     $r4, $r10, 3
    sll     $r5, $r10, 1
    add     $r4, $r4, $r5
    add     $r4, $r4, $r11
    addi    $r4, $r4, 3
    add     $r4, $r26, $r4
    lw      $r9, 0($r4)
    bne     $r9, $r0, crlR_hit
    addi    $r6, $r10, 1
    sll     $r4, $r6, 3
    sll     $r5, $r6, 1
    add     $r4, $r4, $r5
    add     $r4, $r4, $r11
    addi    $r4, $r4, 3
    add     $r4, $r26, $r4
    lw      $r9, 0($r4)
    bne     $r9, $r0, crlR_hit
    jr      $r31
crlR_hit:
    addi    $r8, $r0, 1
    jr      $r31

# ── Rotated right-collision leaf routines ────────────────────

# I rot-1: cells (r,c)..(r+3,c). Check col+1 in all 4 rows.
coll_right_I_rot1:
    sll     $r4, $r10, 3
    sll     $r5, $r10, 1
    add     $r4, $r4, $r5
    add     $r4, $r4, $r11
    addi    $r4, $r4, 1
    add     $r4, $r26, $r4
    lw      $r9, 0($r4)
    bne     $r9, $r0, crIv_hit
    addi    $r6, $r10, 1
    sll     $r4, $r6, 3
    sll     $r5, $r6, 1
    add     $r4, $r4, $r5
    add     $r4, $r4, $r11
    addi    $r4, $r4, 1
    add     $r4, $r26, $r4
    lw      $r9, 0($r4)
    bne     $r9, $r0, crIv_hit
    addi    $r6, $r10, 2
    sll     $r4, $r6, 3
    sll     $r5, $r6, 1
    add     $r4, $r4, $r5
    add     $r4, $r4, $r11
    addi    $r4, $r4, 1
    add     $r4, $r26, $r4
    lw      $r9, 0($r4)
    bne     $r9, $r0, crIv_hit
    addi    $r6, $r10, 3
    sll     $r4, $r6, 3
    sll     $r5, $r6, 1
    add     $r4, $r4, $r5
    add     $r4, $r4, $r11
    addi    $r4, $r4, 1
    add     $r4, $r26, $r4
    lw      $r9, 0($r4)
    bne     $r9, $r0, crIv_hit
    jr      $r31
crIv_hit:
    addi    $r8, $r0, 1
    jr      $r31

# T rot-1: cells (r,c)(r+1,c)(r+2,c)(r+1,c+1).
# Right: row0->col check col+1, row1->col+1 check col+2, row2->col check col+1
coll_right_T_rot1:
    sll     $r4, $r10, 3
    sll     $r5, $r10, 1
    add     $r4, $r4, $r5
    add     $r4, $r4, $r11
    addi    $r4, $r4, 1
    add     $r4, $r26, $r4
    lw      $r9, 0($r4)
    bne     $r9, $r0, crTr1_hit
    addi    $r6, $r10, 1
    sll     $r4, $r6, 3
    sll     $r5, $r6, 1
    add     $r4, $r4, $r5
    add     $r4, $r4, $r11
    addi    $r4, $r4, 2
    add     $r4, $r26, $r4
    lw      $r9, 0($r4)
    bne     $r9, $r0, crTr1_hit
    addi    $r6, $r10, 2
    sll     $r4, $r6, 3
    sll     $r5, $r6, 1
    add     $r4, $r4, $r5
    add     $r4, $r4, $r11
    addi    $r4, $r4, 1
    add     $r4, $r26, $r4
    lw      $r9, 0($r4)
    bne     $r9, $r0, crTr1_hit
    jr      $r31
crTr1_hit:
    addi    $r8, $r0, 1
    jr      $r31

# T rot-2: cells (r,c+1)(r+1,c)(r+1,c+1)(r+1,c+2).
# Right: row0->col+1 check col+2, row1->col+2 check col+3
coll_right_T_rot2:
    sll     $r4, $r10, 3
    sll     $r5, $r10, 1
    add     $r4, $r4, $r5
    add     $r4, $r4, $r11
    addi    $r4, $r4, 2
    add     $r4, $r26, $r4
    lw      $r9, 0($r4)
    bne     $r9, $r0, crTr2_hit
    addi    $r6, $r10, 1
    sll     $r4, $r6, 3
    sll     $r5, $r6, 1
    add     $r4, $r4, $r5
    add     $r4, $r4, $r11
    addi    $r4, $r4, 3
    add     $r4, $r26, $r4
    lw      $r9, 0($r4)
    bne     $r9, $r0, crTr2_hit
    jr      $r31
crTr2_hit:
    addi    $r8, $r0, 1
    jr      $r31

# T rot-3: cells (r,c+1)(r+1,c)(r+1,c+1)(r+2,c+1).
# Right: row0->col+1 check col+2, row1->col+1 check col+2, row2->col+1 check col+2
coll_right_T_rot3:
    sll     $r4, $r10, 3
    sll     $r5, $r10, 1
    add     $r4, $r4, $r5
    add     $r4, $r4, $r11
    addi    $r4, $r4, 2
    add     $r4, $r26, $r4
    lw      $r9, 0($r4)
    bne     $r9, $r0, crTr3_hit
    addi    $r6, $r10, 1
    sll     $r4, $r6, 3
    sll     $r5, $r6, 1
    add     $r4, $r4, $r5
    add     $r4, $r4, $r11
    addi    $r4, $r4, 2
    add     $r4, $r26, $r4
    lw      $r9, 0($r4)
    bne     $r9, $r0, crTr3_hit
    addi    $r6, $r10, 2
    sll     $r4, $r6, 3
    sll     $r5, $r6, 1
    add     $r4, $r4, $r5
    add     $r4, $r4, $r11
    addi    $r4, $r4, 2
    add     $r4, $r26, $r4
    lw      $r9, 0($r4)
    bne     $r9, $r0, crTr3_hit
    jr      $r31
crTr3_hit:
    addi    $r8, $r0, 1
    jr      $r31

# S rot-1: cells (r,c)(r+1,c)(r+1,c+1)(r+2,c+1).
# Right: row0->col check col+1, row1->col+1 check col+2, row2->col+1 check col+2
coll_right_S_rot1:
    sll     $r4, $r10, 3
    sll     $r5, $r10, 1
    add     $r4, $r4, $r5
    add     $r4, $r4, $r11
    addi    $r4, $r4, 1
    add     $r4, $r26, $r4
    lw      $r9, 0($r4)
    bne     $r9, $r0, crSr1_hit
    addi    $r6, $r10, 1
    sll     $r4, $r6, 3
    sll     $r5, $r6, 1
    add     $r4, $r4, $r5
    add     $r4, $r4, $r11
    addi    $r4, $r4, 2
    add     $r4, $r26, $r4
    lw      $r9, 0($r4)
    bne     $r9, $r0, crSr1_hit
    addi    $r6, $r10, 2
    sll     $r4, $r6, 3
    sll     $r5, $r6, 1
    add     $r4, $r4, $r5
    add     $r4, $r4, $r11
    addi    $r4, $r4, 2
    add     $r4, $r26, $r4
    lw      $r9, 0($r4)
    bne     $r9, $r0, crSr1_hit
    jr      $r31
crSr1_hit:
    addi    $r8, $r0, 1
    jr      $r31

# Z rot-1: cells (r,c+1)(r+1,c)(r+1,c+1)(r+2,c).
# Right: row0->col+1 check col+2, row1->col+1 check col+2, row2->col check col+1
coll_right_Z_rot1:
    sll     $r4, $r10, 3
    sll     $r5, $r10, 1
    add     $r4, $r4, $r5
    add     $r4, $r4, $r11
    addi    $r4, $r4, 2
    add     $r4, $r26, $r4
    lw      $r9, 0($r4)
    bne     $r9, $r0, crZr1_hit
    addi    $r6, $r10, 1
    sll     $r4, $r6, 3
    sll     $r5, $r6, 1
    add     $r4, $r4, $r5
    add     $r4, $r4, $r11
    addi    $r4, $r4, 2
    add     $r4, $r26, $r4
    lw      $r9, 0($r4)
    bne     $r9, $r0, crZr1_hit
    addi    $r6, $r10, 2
    sll     $r4, $r6, 3
    sll     $r5, $r6, 1
    add     $r4, $r4, $r5
    add     $r4, $r4, $r11
    addi    $r4, $r4, 1
    add     $r4, $r26, $r4
    lw      $r9, 0($r4)
    bne     $r9, $r0, crZr1_hit
    jr      $r31
crZr1_hit:
    addi    $r8, $r0, 1
    jr      $r31

# J rot-1: cells (r,c)(r,c+1)(r+1,c)(r+2,c).
# Right: row0->col+1 check col+2, row1->col check col+1, row2->col check col+1
coll_right_J_rot1:
    sll     $r4, $r10, 3
    sll     $r5, $r10, 1
    add     $r4, $r4, $r5
    add     $r4, $r4, $r11
    addi    $r4, $r4, 2
    add     $r4, $r26, $r4
    lw      $r9, 0($r4)
    bne     $r9, $r0, crJr1_hit
    addi    $r6, $r10, 1
    sll     $r4, $r6, 3
    sll     $r5, $r6, 1
    add     $r4, $r4, $r5
    add     $r4, $r4, $r11
    addi    $r4, $r4, 1
    add     $r4, $r26, $r4
    lw      $r9, 0($r4)
    bne     $r9, $r0, crJr1_hit
    addi    $r6, $r10, 2
    sll     $r4, $r6, 3
    sll     $r5, $r6, 1
    add     $r4, $r4, $r5
    add     $r4, $r4, $r11
    addi    $r4, $r4, 1
    add     $r4, $r26, $r4
    lw      $r9, 0($r4)
    bne     $r9, $r0, crJr1_hit
    jr      $r31
crJr1_hit:
    addi    $r8, $r0, 1
    jr      $r31

# J rot-2: cells (r,c)(r,c+1)(r,c+2)(r+1,c+2).
# Right: row0->col+2 check col+3, row1->col+2 check col+3
coll_right_J_rot2:
    sll     $r4, $r10, 3
    sll     $r5, $r10, 1
    add     $r4, $r4, $r5
    add     $r4, $r4, $r11
    addi    $r4, $r4, 3
    add     $r4, $r26, $r4
    lw      $r9, 0($r4)
    bne     $r9, $r0, crJr2_hit
    addi    $r6, $r10, 1
    sll     $r4, $r6, 3
    sll     $r5, $r6, 1
    add     $r4, $r4, $r5
    add     $r4, $r4, $r11
    addi    $r4, $r4, 3
    add     $r4, $r26, $r4
    lw      $r9, 0($r4)
    bne     $r9, $r0, crJr2_hit
    jr      $r31
crJr2_hit:
    addi    $r8, $r0, 1
    jr      $r31

# J rot-3: cells (r,c+1)(r+1,c+1)(r+2,c)(r+2,c+1).
# Right: row0->col+1 check col+2, row1->col+1 check col+2, row2->col+1 check col+2
coll_right_J_rot3:
    sll     $r4, $r10, 3
    sll     $r5, $r10, 1
    add     $r4, $r4, $r5
    add     $r4, $r4, $r11
    addi    $r4, $r4, 2
    add     $r4, $r26, $r4
    lw      $r9, 0($r4)
    bne     $r9, $r0, crJr3_hit
    addi    $r6, $r10, 1
    sll     $r4, $r6, 3
    sll     $r5, $r6, 1
    add     $r4, $r4, $r5
    add     $r4, $r4, $r11
    addi    $r4, $r4, 2
    add     $r4, $r26, $r4
    lw      $r9, 0($r4)
    bne     $r9, $r0, crJr3_hit
    addi    $r6, $r10, 2
    sll     $r4, $r6, 3
    sll     $r5, $r6, 1
    add     $r4, $r4, $r5
    add     $r4, $r4, $r11
    addi    $r4, $r4, 2
    add     $r4, $r26, $r4
    lw      $r9, 0($r4)
    bne     $r9, $r0, crJr3_hit
    jr      $r31
crJr3_hit:
    addi    $r8, $r0, 1
    jr      $r31

# L rot-1: cells (r,c)(r+1,c)(r+2,c)(r+2,c+1).
# Right: row0->col check col+1, row1->col check col+1, row2->col+1 check col+2
coll_right_L_rot1:
    sll     $r4, $r10, 3
    sll     $r5, $r10, 1
    add     $r4, $r4, $r5
    add     $r4, $r4, $r11
    addi    $r4, $r4, 1
    add     $r4, $r26, $r4
    lw      $r9, 0($r4)
    bne     $r9, $r0, crLr1_hit
    addi    $r6, $r10, 1
    sll     $r4, $r6, 3
    sll     $r5, $r6, 1
    add     $r4, $r4, $r5
    add     $r4, $r4, $r11
    addi    $r4, $r4, 1
    add     $r4, $r26, $r4
    lw      $r9, 0($r4)
    bne     $r9, $r0, crLr1_hit
    addi    $r6, $r10, 2
    sll     $r4, $r6, 3
    sll     $r5, $r6, 1
    add     $r4, $r4, $r5
    add     $r4, $r4, $r11
    addi    $r4, $r4, 2
    add     $r4, $r26, $r4
    lw      $r9, 0($r4)
    bne     $r9, $r0, crLr1_hit
    jr      $r31
crLr1_hit:
    addi    $r8, $r0, 1
    jr      $r31

# L rot-2: cells (r,c)(r,c+1)(r,c+2)(r+1,c).
# Right: row0->col+2 check col+3, row1->col check col+1
coll_right_L_rot2:
    sll     $r4, $r10, 3
    sll     $r5, $r10, 1
    add     $r4, $r4, $r5
    add     $r4, $r4, $r11
    addi    $r4, $r4, 3
    add     $r4, $r26, $r4
    lw      $r9, 0($r4)
    bne     $r9, $r0, crLr2_hit
    addi    $r6, $r10, 1
    sll     $r4, $r6, 3
    sll     $r5, $r6, 1
    add     $r4, $r4, $r5
    add     $r4, $r4, $r11
    addi    $r4, $r4, 1
    add     $r4, $r26, $r4
    lw      $r9, 0($r4)
    bne     $r9, $r0, crLr2_hit
    jr      $r31
crLr2_hit:
    addi    $r8, $r0, 1
    jr      $r31

# L rot-3: cells (r,c)(r,c+1)(r+1,c+1)(r+2,c+1).
# Right: row0->col+1 check col+2, row1->col+1 check col+2, row2->col+1 check col+2
coll_right_L_rot3:
    sll     $r4, $r10, 3
    sll     $r5, $r10, 1
    add     $r4, $r4, $r5
    add     $r4, $r4, $r11
    addi    $r4, $r4, 2
    add     $r4, $r26, $r4
    lw      $r9, 0($r4)
    bne     $r9, $r0, crLr3_hit
    addi    $r6, $r10, 1
    sll     $r4, $r6, 3
    sll     $r5, $r6, 1
    add     $r4, $r4, $r5
    add     $r4, $r4, $r11
    addi    $r4, $r4, 2
    add     $r4, $r26, $r4
    lw      $r9, 0($r4)
    bne     $r9, $r0, crLr3_hit
    addi    $r6, $r10, 2
    sll     $r4, $r6, 3
    sll     $r5, $r6, 1
    add     $r4, $r4, $r5
    add     $r4, $r4, $r11
    addi    $r4, $r4, 2
    add     $r4, $r26, $r4
    lw      $r9, 0($r4)
    bne     $r9, $r0, crLr3_hit
    jr      $r31
crLr3_hit:
    addi    $r8, $r0, 1
    jr      $r31

##############################################################
# ROTATE_PIECE
# 1. Skip O-piece (no rotation).
# 2. Compute new_rot = (piece_rot+1) % max_rotations.
# 3. Clamp piece_col for new rotation width.
# 4. Temporarily write new_rot and clamped col to memory.
# 5. Call validate_new_rotation -> $r8.
# 6. If invalid, restore original col and rot.
#
# Scratch: $r14=new_rot, $r15=orig_rot, $r16=clamped_col
# (these are not used by any callee, safe across jal)
##############################################################
rotate_piece:
    addi    $r29, $r29, -1
    sw      $r31, 0($r29)

    lw      $r10, 0($r21)         # piece_row
    lw      $r11, 0($r22)         # piece_col (original)
    lw      $r12, 0($r25)         # piece_type
    lw      $r15, 0($r27)         # piece_rot (original)

    # O-piece: no rotation
    addi    $r2, $r0, 1
    bne     $r12, $r2, rp_not_O
    j       rp_done
rp_not_O:

    # Compute new_rot
    addi    $r14, $r15, 1         # new_rot = rot + 1

    # I-piece: 2 rotations (mod 2)
    bne     $r12, $r0, rp_not_I
    addi    $r2, $r0, 2
    bne     $r14, $r2, rp_I_ok
    addi    $r14, $r0, 0
rp_I_ok:
    j       rp_clamp
rp_not_I:
    # S(3) and Z(4): 2 rotations (mod 2)
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
    # T(2), J(5), L(6): 4 rotations (mod 4)
    addi    $r2, $r0, 4
    bne     $r14, $r2, rp_clamp
    addi    $r14, $r0, 0

    # Clamp piece_col for new rotation's bounding box width
rp_clamp:
    addi    $r16, $r11, 0         # start with original col

    # I-piece width: rot0=4(max6) rot1=1(max9)
    bne     $r12, $r0, rp_clamp_other
    bne     $r14, $r0, rp_clamp_I_vert
    # I rot0: max col 6
    addi    $r2, $r0, 7
    blt     $r16, $r2, rp_try    # col < 7, ok
    addi    $r16, $r0, 6
    j       rp_try
rp_clamp_I_vert:
    # I rot1: max col 9, always valid (col 0-9)
    j       rp_try

rp_clamp_other:
    # Even new_rot -> 3-wide (max 7), odd -> 2-wide (max 8)
    sra     $r2, $r14, 1
    sll     $r2, $r2, 1
    sub     $r2, $r14, $r2        # $r2 = new_rot & 1
    bne     $r2, $r0, rp_clamp_odd
    # even: max col 7
    addi    $r2, $r0, 8
    blt     $r16, $r2, rp_try
    addi    $r16, $r0, 7
    j       rp_try
rp_clamp_odd:
    # odd: max col 8
    addi    $r2, $r0, 9
    blt     $r16, $r2, rp_try
    addi    $r16, $r0, 8

    # Write new_rot and clamped col into memory for validate to read
rp_try:
    sw      $r14, 0($r27)         # piece_rot = new_rot (tentative)
    sw      $r16, 0($r22)         # piece_col = clamped (tentative)

    jal     validate_new_rotation # -> $r8: 0=valid, 1=invalid

    bne     $r8, $r0, rp_invalid
    # Valid: keep new values already stored
    j       rp_done

rp_invalid:
    sw      $r15, 0($r27)         # restore original piece_rot
    sw      $r11, 0($r22)         # restore original piece_col

rp_done:
    lw      $r31, 0($r29)
    addi    $r29, $r29, 1
    jr      $r31

##############################################################
# VALIDATE_NEW_ROTATION
# Reads piece_type, piece_rot (already set to new_rot),
# piece_row, piece_col (already clamped) from memory.
# Checks all new cells against locked_board.
# Also checks row bounds for taller rotations.
# Returns $r8 = 0 (valid) or 1 (invalid / out of bounds).
##############################################################
validate_new_rotation:
    addi    $r29, $r29, -1
    sw      $r31, 0($r29)

    lw      $r10, 0($r21)
    lw      $r11, 0($r22)
    lw      $r12, 0($r25)
    lw      $r13, 0($r27)         # new_rot
    addi    $r8, $r0, 0

    bne     $r12, $r0, vr_not_I
    bne     $r13, $r0, vr_I1
    jal     validate_I_rot0
    j       vr_done
vr_I1:
    jal     validate_I_rot1
    j       vr_done
vr_not_I:
    addi    $r2, $r0, 2
    bne     $r12, $r2, vr_not_T
    addi    $r2, $r0, 1
    bne     $r13, $r2, vr_T_not1
    jal     validate_T_rot1
    j       vr_done
vr_T_not1:
    addi    $r2, $r0, 2
    bne     $r13, $r2, vr_T_not2
    jal     validate_T_rot2
    j       vr_done
vr_T_not2:
    addi    $r2, $r0, 3
    bne     $r13, $r2, vr_T_rot0
    jal     validate_T_rot3
    j       vr_done
vr_T_rot0:
    jal     validate_T_rot0
    j       vr_done
vr_not_T:
    addi    $r2, $r0, 3
    bne     $r12, $r2, vr_not_S
    bne     $r13, $r0, vr_S1
    jal     validate_S_rot0
    j       vr_done
vr_S1:
    jal     validate_S_rot1
    j       vr_done
vr_not_S:
    addi    $r2, $r0, 4
    bne     $r12, $r2, vr_not_Z
    bne     $r13, $r0, vr_Z1
    jal     validate_Z_rot0
    j       vr_done
vr_Z1:
    jal     validate_Z_rot1
    j       vr_done
vr_not_Z:
    addi    $r2, $r0, 5
    bne     $r12, $r2, vr_not_J
    addi    $r2, $r0, 1
    bne     $r13, $r2, vr_J_not1
    jal     validate_J_rot1
    j       vr_done
vr_J_not1:
    addi    $r2, $r0, 2
    bne     $r13, $r2, vr_J_not2
    jal     validate_J_rot2
    j       vr_done
vr_J_not2:
    addi    $r2, $r0, 3
    bne     $r13, $r2, vr_J_rot0
    jal     validate_J_rot3
    j       vr_done
vr_J_rot0:
    jal     validate_J_rot0
    j       vr_done
vr_not_J:
    addi    $r2, $r0, 1
    bne     $r13, $r2, vr_L_not1
    jal     validate_L_rot1
    j       vr_done
vr_L_not1:
    addi    $r2, $r0, 2
    bne     $r13, $r2, vr_L_not2
    jal     validate_L_rot2
    j       vr_done
vr_L_not2:
    addi    $r2, $r0, 3
    bne     $r13, $r2, vr_L_rot0
    jal     validate_L_rot3
    j       vr_done
vr_L_rot0:
    jal     validate_L_rot0

vr_done:
    lw      $r31, 0($r29)
    addi    $r29, $r29, 1
    jr      $r31

# ── Validation leaf routines ─────────────────────────────────
# Each checks row bounds then all 4 cells against locked_board.
# $r8=1 on any failure.  row*10 = (row<<3)+(row<<1).

# I rot-0: cells (r,c)(r,c+1)(r,c+2)(r,c+3). 1-tall, always in bounds.
validate_I_rot0:
    sll     $r4, $r10, 3
    sll     $r5, $r10, 1
    add     $r4, $r4, $r5
    add     $r4, $r4, $r11
    add     $r4, $r26, $r4
    lw      $r9, 0($r4)
    bne     $r9, $r0, vi_hit
    addi    $r4, $r4, 1
    lw      $r9, 0($r4)
    bne     $r9, $r0, vi_hit
    addi    $r4, $r4, 1
    lw      $r9, 0($r4)
    bne     $r9, $r0, vi_hit
    addi    $r4, $r4, 1
    lw      $r9, 0($r4)
    bne     $r9, $r0, vi_hit
    jr      $r31
vi_hit:
    addi    $r8, $r0, 1
    jr      $r31

# I rot-1: cells (r,c)(r+1,c)(r+2,c)(r+3,c). 4-tall: row+3 <= 19 -> row < 17.
validate_I_rot1:
    addi    $r4, $r0, 17
    blt     $r10, $r4, vIv_ok
    addi    $r8, $r0, 1
    jr      $r31
vIv_ok:
    sll     $r4, $r10, 3
    sll     $r5, $r10, 1
    add     $r4, $r4, $r5
    add     $r4, $r4, $r11
    add     $r4, $r26, $r4
    lw      $r9, 0($r4)
    bne     $r9, $r0, vIv_hit
    addi    $r6, $r10, 1
    sll     $r4, $r6, 3
    sll     $r5, $r6, 1
    add     $r4, $r4, $r5
    add     $r4, $r4, $r11
    add     $r4, $r26, $r4
    lw      $r9, 0($r4)
    bne     $r9, $r0, vIv_hit
    addi    $r6, $r10, 2
    sll     $r4, $r6, 3
    sll     $r5, $r6, 1
    add     $r4, $r4, $r5
    add     $r4, $r4, $r11
    add     $r4, $r26, $r4
    lw      $r9, 0($r4)
    bne     $r9, $r0, vIv_hit
    addi    $r6, $r10, 3
    sll     $r4, $r6, 3
    sll     $r5, $r6, 1
    add     $r4, $r4, $r5
    add     $r4, $r4, $r11
    add     $r4, $r26, $r4
    lw      $r9, 0($r4)
    bne     $r9, $r0, vIv_hit
    jr      $r31
vIv_hit:
    addi    $r8, $r0, 1
    jr      $r31

# T rot-0: cells (r,c)(r,c+1)(r,c+2)(r+1,c+1). 2-tall, always fits.
validate_T_rot0:
    sll     $r4, $r10, 3
    sll     $r5, $r10, 1
    add     $r4, $r4, $r5
    add     $r4, $r4, $r11
    add     $r4, $r26, $r4
    lw      $r9, 0($r4)
    bne     $r9, $r0, vT0_hit
    addi    $r4, $r4, 1
    lw      $r9, 0($r4)
    bne     $r9, $r0, vT0_hit
    addi    $r4, $r4, 1
    lw      $r9, 0($r4)
    bne     $r9, $r0, vT0_hit
    addi    $r6, $r10, 1
    sll     $r4, $r6, 3
    sll     $r5, $r6, 1
    add     $r4, $r4, $r5
    add     $r4, $r4, $r11
    addi    $r4, $r4, 1
    add     $r4, $r26, $r4
    lw      $r9, 0($r4)
    bne     $r9, $r0, vT0_hit
    jr      $r31
vT0_hit:
    addi    $r8, $r0, 1
    jr      $r31

# T rot-1: cells (r,c)(r+1,c)(r+2,c)(r+1,c+1). 3-tall: row < 18.
validate_T_rot1:
    addi    $r4, $r0, 18
    blt     $r10, $r4, vT1_ok
    addi    $r8, $r0, 1
    jr      $r31
vT1_ok:
    sll     $r4, $r10, 3
    sll     $r5, $r10, 1
    add     $r4, $r4, $r5
    add     $r4, $r4, $r11
    add     $r4, $r26, $r4
    lw      $r9, 0($r4)
    bne     $r9, $r0, vT1_hit
    addi    $r6, $r10, 1
    sll     $r4, $r6, 3
    sll     $r5, $r6, 1
    add     $r4, $r4, $r5
    add     $r4, $r4, $r11
    add     $r4, $r26, $r4
    lw      $r9, 0($r4)
    bne     $r9, $r0, vT1_hit
    addi    $r4, $r4, 1
    lw      $r9, 0($r4)
    bne     $r9, $r0, vT1_hit
    addi    $r6, $r10, 2
    sll     $r4, $r6, 3
    sll     $r5, $r6, 1
    add     $r4, $r4, $r5
    add     $r4, $r4, $r11
    add     $r4, $r26, $r4
    lw      $r9, 0($r4)
    bne     $r9, $r0, vT1_hit
    jr      $r31
vT1_hit:
    addi    $r8, $r0, 1
    jr      $r31

# T rot-2: cells (r,c+1)(r+1,c)(r+1,c+1)(r+1,c+2). 2-tall.
validate_T_rot2:
    sll     $r4, $r10, 3
    sll     $r5, $r10, 1
    add     $r4, $r4, $r5
    add     $r4, $r4, $r11
    addi    $r4, $r4, 1
    add     $r4, $r26, $r4
    lw      $r9, 0($r4)
    bne     $r9, $r0, vT2_hit
    addi    $r6, $r10, 1
    sll     $r4, $r6, 3
    sll     $r5, $r6, 1
    add     $r4, $r4, $r5
    add     $r4, $r4, $r11
    add     $r4, $r26, $r4
    lw      $r9, 0($r4)
    bne     $r9, $r0, vT2_hit
    addi    $r4, $r4, 1
    lw      $r9, 0($r4)
    bne     $r9, $r0, vT2_hit
    addi    $r4, $r4, 1
    lw      $r9, 0($r4)
    bne     $r9, $r0, vT2_hit
    jr      $r31
vT2_hit:
    addi    $r8, $r0, 1
    jr      $r31

# T rot-3: cells (r,c+1)(r+1,c)(r+1,c+1)(r+2,c+1). 3-tall: row < 18.
validate_T_rot3:
    addi    $r4, $r0, 18
    blt     $r10, $r4, vT3_ok
    addi    $r8, $r0, 1
    jr      $r31
vT3_ok:
    sll     $r4, $r10, 3
    sll     $r5, $r10, 1
    add     $r4, $r4, $r5
    add     $r4, $r4, $r11
    addi    $r4, $r4, 1
    add     $r4, $r26, $r4
    lw      $r9, 0($r4)
    bne     $r9, $r0, vT3_hit
    addi    $r6, $r10, 1
    sll     $r4, $r6, 3
    sll     $r5, $r6, 1
    add     $r4, $r4, $r5
    add     $r4, $r4, $r11
    add     $r4, $r26, $r4
    lw      $r9, 0($r4)
    bne     $r9, $r0, vT3_hit
    addi    $r4, $r4, 1
    lw      $r9, 0($r4)
    bne     $r9, $r0, vT3_hit
    addi    $r6, $r10, 2
    sll     $r4, $r6, 3
    sll     $r5, $r6, 1
    add     $r4, $r4, $r5
    add     $r4, $r4, $r11
    addi    $r4, $r4, 1
    add     $r4, $r26, $r4
    lw      $r9, 0($r4)
    bne     $r9, $r0, vT3_hit
    jr      $r31
vT3_hit:
    addi    $r8, $r0, 1
    jr      $r31

# S rot-0: cells (r,c+1)(r,c+2)(r+1,c)(r+1,c+1). 2-tall.
validate_S_rot0:
    sll     $r4, $r10, 3
    sll     $r5, $r10, 1
    add     $r4, $r4, $r5
    add     $r4, $r4, $r11
    addi    $r4, $r4, 1
    add     $r4, $r26, $r4
    lw      $r9, 0($r4)
    bne     $r9, $r0, vS0_hit
    addi    $r4, $r4, 1
    lw      $r9, 0($r4)
    bne     $r9, $r0, vS0_hit
    addi    $r6, $r10, 1
    sll     $r4, $r6, 3
    sll     $r5, $r6, 1
    add     $r4, $r4, $r5
    add     $r4, $r4, $r11
    add     $r4, $r26, $r4
    lw      $r9, 0($r4)
    bne     $r9, $r0, vS0_hit
    addi    $r4, $r4, 1
    lw      $r9, 0($r4)
    bne     $r9, $r0, vS0_hit
    jr      $r31
vS0_hit:
    addi    $r8, $r0, 1
    jr      $r31

# S rot-1: cells (r,c)(r+1,c)(r+1,c+1)(r+2,c+1). 3-tall: row < 18.
validate_S_rot1:
    addi    $r4, $r0, 18
    blt     $r10, $r4, vS1_ok
    addi    $r8, $r0, 1
    jr      $r31
vS1_ok:
    sll     $r4, $r10, 3
    sll     $r5, $r10, 1
    add     $r4, $r4, $r5
    add     $r4, $r4, $r11
    add     $r4, $r26, $r4
    lw      $r9, 0($r4)
    bne     $r9, $r0, vS1_hit
    addi    $r6, $r10, 1
    sll     $r4, $r6, 3
    sll     $r5, $r6, 1
    add     $r4, $r4, $r5
    add     $r4, $r4, $r11
    add     $r4, $r26, $r4
    lw      $r9, 0($r4)
    bne     $r9, $r0, vS1_hit
    addi    $r4, $r4, 1
    lw      $r9, 0($r4)
    bne     $r9, $r0, vS1_hit
    addi    $r6, $r10, 2
    sll     $r4, $r6, 3
    sll     $r5, $r6, 1
    add     $r4, $r4, $r5
    add     $r4, $r4, $r11
    addi    $r4, $r4, 1
    add     $r4, $r26, $r4
    lw      $r9, 0($r4)
    bne     $r9, $r0, vS1_hit
    jr      $r31
vS1_hit:
    addi    $r8, $r0, 1
    jr      $r31

# Z rot-0: cells (r,c)(r,c+1)(r+1,c+1)(r+1,c+2). 2-tall.
validate_Z_rot0:
    sll     $r4, $r10, 3
    sll     $r5, $r10, 1
    add     $r4, $r4, $r5
    add     $r4, $r4, $r11
    add     $r4, $r26, $r4
    lw      $r9, 0($r4)
    bne     $r9, $r0, vZ0_hit
    addi    $r4, $r4, 1
    lw      $r9, 0($r4)
    bne     $r9, $r0, vZ0_hit
    addi    $r6, $r10, 1
    sll     $r4, $r6, 3
    sll     $r5, $r6, 1
    add     $r4, $r4, $r5
    add     $r4, $r4, $r11
    addi    $r4, $r4, 1
    add     $r4, $r26, $r4
    lw      $r9, 0($r4)
    bne     $r9, $r0, vZ0_hit
    addi    $r4, $r4, 1
    lw      $r9, 0($r4)
    bne     $r9, $r0, vZ0_hit
    jr      $r31
vZ0_hit:
    addi    $r8, $r0, 1
    jr      $r31

# Z rot-1: cells (r,c+1)(r+1,c)(r+1,c+1)(r+2,c). 3-tall: row < 18.
validate_Z_rot1:
    addi    $r4, $r0, 18
    blt     $r10, $r4, vZ1_ok
    addi    $r8, $r0, 1
    jr      $r31
vZ1_ok:
    sll     $r4, $r10, 3
    sll     $r5, $r10, 1
    add     $r4, $r4, $r5
    add     $r4, $r4, $r11
    addi    $r4, $r4, 1
    add     $r4, $r26, $r4
    lw      $r9, 0($r4)
    bne     $r9, $r0, vZ1_hit
    addi    $r6, $r10, 1
    sll     $r4, $r6, 3
    sll     $r5, $r6, 1
    add     $r4, $r4, $r5
    add     $r4, $r4, $r11
    add     $r4, $r26, $r4
    lw      $r9, 0($r4)
    bne     $r9, $r0, vZ1_hit
    addi    $r4, $r4, 1
    lw      $r9, 0($r4)
    bne     $r9, $r0, vZ1_hit
    addi    $r6, $r10, 2
    sll     $r4, $r6, 3
    sll     $r5, $r6, 1
    add     $r4, $r4, $r5
    add     $r4, $r4, $r11
    add     $r4, $r26, $r4
    lw      $r9, 0($r4)
    bne     $r9, $r0, vZ1_hit
    jr      $r31
vZ1_hit:
    addi    $r8, $r0, 1
    jr      $r31

# J rot-0: cells (r,c)(r+1,c)(r+1,c+1)(r+1,c+2). 2-tall.
validate_J_rot0:
    sll     $r4, $r10, 3
    sll     $r5, $r10, 1
    add     $r4, $r4, $r5
    add     $r4, $r4, $r11
    add     $r4, $r26, $r4
    lw      $r9, 0($r4)
    bne     $r9, $r0, vJ0_hit
    addi    $r6, $r10, 1
    sll     $r4, $r6, 3
    sll     $r5, $r6, 1
    add     $r4, $r4, $r5
    add     $r4, $r4, $r11
    add     $r4, $r26, $r4
    lw      $r9, 0($r4)
    bne     $r9, $r0, vJ0_hit
    addi    $r4, $r4, 1
    lw      $r9, 0($r4)
    bne     $r9, $r0, vJ0_hit
    addi    $r4, $r4, 1
    lw      $r9, 0($r4)
    bne     $r9, $r0, vJ0_hit
    jr      $r31
vJ0_hit:
    addi    $r8, $r0, 1
    jr      $r31

# J rot-1: cells (r,c)(r,c+1)(r+1,c)(r+2,c). 3-tall: row < 18.
validate_J_rot1:
    addi    $r4, $r0, 18
    blt     $r10, $r4, vJ1_ok
    addi    $r8, $r0, 1
    jr      $r31
vJ1_ok:
    sll     $r4, $r10, 3
    sll     $r5, $r10, 1
    add     $r4, $r4, $r5
    add     $r4, $r4, $r11
    add     $r4, $r26, $r4
    lw      $r9, 0($r4)
    bne     $r9, $r0, vJ1_hit
    addi    $r4, $r4, 1
    lw      $r9, 0($r4)
    bne     $r9, $r0, vJ1_hit
    addi    $r6, $r10, 1
    sll     $r4, $r6, 3
    sll     $r5, $r6, 1
    add     $r4, $r4, $r5
    add     $r4, $r4, $r11
    add     $r4, $r26, $r4
    lw      $r9, 0($r4)
    bne     $r9, $r0, vJ1_hit
    addi    $r6, $r10, 2
    sll     $r4, $r6, 3
    sll     $r5, $r6, 1
    add     $r4, $r4, $r5
    add     $r4, $r4, $r11
    add     $r4, $r26, $r4
    lw      $r9, 0($r4)
    bne     $r9, $r0, vJ1_hit
    jr      $r31
vJ1_hit:
    addi    $r8, $r0, 1
    jr      $r31

# J rot-2: cells (r,c)(r,c+1)(r,c+2)(r+1,c+2). 2-tall.
validate_J_rot2:
    sll     $r4, $r10, 3
    sll     $r5, $r10, 1
    add     $r4, $r4, $r5
    add     $r4, $r4, $r11
    add     $r4, $r26, $r4
    lw      $r9, 0($r4)
    bne     $r9, $r0, vJ2_hit
    addi    $r4, $r4, 1
    lw      $r9, 0($r4)
    bne     $r9, $r0, vJ2_hit
    addi    $r4, $r4, 1
    lw      $r9, 0($r4)
    bne     $r9, $r0, vJ2_hit
    addi    $r6, $r10, 1
    sll     $r4, $r6, 3
    sll     $r5, $r6, 1
    add     $r4, $r4, $r5
    add     $r4, $r4, $r11
    addi    $r4, $r4, 2
    add     $r4, $r26, $r4
    lw      $r9, 0($r4)
    bne     $r9, $r0, vJ2_hit
    jr      $r31
vJ2_hit:
    addi    $r8, $r0, 1
    jr      $r31

# J rot-3: cells (r,c+1)(r+1,c+1)(r+2,c)(r+2,c+1). 3-tall: row < 18.
validate_J_rot3:
    addi    $r4, $r0, 18
    blt     $r10, $r4, vJ3_ok
    addi    $r8, $r0, 1
    jr      $r31
vJ3_ok:
    sll     $r4, $r10, 3
    sll     $r5, $r10, 1
    add     $r4, $r4, $r5
    add     $r4, $r4, $r11
    addi    $r4, $r4, 1
    add     $r4, $r26, $r4
    lw      $r9, 0($r4)
    bne     $r9, $r0, vJ3_hit
    addi    $r6, $r10, 1
    sll     $r4, $r6, 3
    sll     $r5, $r6, 1
    add     $r4, $r4, $r5
    add     $r4, $r4, $r11
    addi    $r4, $r4, 1
    add     $r4, $r26, $r4
    lw      $r9, 0($r4)
    bne     $r9, $r0, vJ3_hit
    addi    $r6, $r10, 2
    sll     $r4, $r6, 3
    sll     $r5, $r6, 1
    add     $r4, $r4, $r5
    add     $r4, $r4, $r11
    add     $r4, $r26, $r4
    lw      $r9, 0($r4)
    bne     $r9, $r0, vJ3_hit
    addi    $r4, $r4, 1
    lw      $r9, 0($r4)
    bne     $r9, $r0, vJ3_hit
    jr      $r31
vJ3_hit:
    addi    $r8, $r0, 1
    jr      $r31

# L rot-0: cells (r,c+2)(r+1,c)(r+1,c+1)(r+1,c+2). 2-tall.
validate_L_rot0:
    sll     $r4, $r10, 3
    sll     $r5, $r10, 1
    add     $r4, $r4, $r5
    add     $r4, $r4, $r11
    addi    $r4, $r4, 2
    add     $r4, $r26, $r4
    lw      $r9, 0($r4)
    bne     $r9, $r0, vL0_hit
    addi    $r6, $r10, 1
    sll     $r4, $r6, 3
    sll     $r5, $r6, 1
    add     $r4, $r4, $r5
    add     $r4, $r4, $r11
    add     $r4, $r26, $r4
    lw      $r9, 0($r4)
    bne     $r9, $r0, vL0_hit
    addi    $r4, $r4, 1
    lw      $r9, 0($r4)
    bne     $r9, $r0, vL0_hit
    addi    $r4, $r4, 1
    lw      $r9, 0($r4)
    bne     $r9, $r0, vL0_hit
    jr      $r31
vL0_hit:
    addi    $r8, $r0, 1
    jr      $r31

# L rot-1: cells (r,c)(r+1,c)(r+2,c)(r+2,c+1). 3-tall: row < 18.
validate_L_rot1:
    addi    $r4, $r0, 18
    blt     $r10, $r4, vL1_ok
    addi    $r8, $r0, 1
    jr      $r31
vL1_ok:
    sll     $r4, $r10, 3
    sll     $r5, $r10, 1
    add     $r4, $r4, $r5
    add     $r4, $r4, $r11
    add     $r4, $r26, $r4
    lw      $r9, 0($r4)
    bne     $r9, $r0, vL1_hit
    addi    $r6, $r10, 1
    sll     $r4, $r6, 3
    sll     $r5, $r6, 1
    add     $r4, $r4, $r5
    add     $r4, $r4, $r11
    add     $r4, $r26, $r4
    lw      $r9, 0($r4)
    bne     $r9, $r0, vL1_hit
    addi    $r6, $r10, 2
    sll     $r4, $r6, 3
    sll     $r5, $r6, 1
    add     $r4, $r4, $r5
    add     $r4, $r4, $r11
    add     $r4, $r26, $r4
    lw      $r9, 0($r4)
    bne     $r9, $r0, vL1_hit
    addi    $r4, $r4, 1
    lw      $r9, 0($r4)
    bne     $r9, $r0, vL1_hit
    jr      $r31
vL1_hit:
    addi    $r8, $r0, 1
    jr      $r31

# L rot-2: cells (r,c)(r,c+1)(r,c+2)(r+1,c). 2-tall.
validate_L_rot2:
    sll     $r4, $r10, 3
    sll     $r5, $r10, 1
    add     $r4, $r4, $r5
    add     $r4, $r4, $r11
    add     $r4, $r26, $r4
    lw      $r9, 0($r4)
    bne     $r9, $r0, vL2_hit
    addi    $r4, $r4, 1
    lw      $r9, 0($r4)
    bne     $r9, $r0, vL2_hit
    addi    $r4, $r4, 1
    lw      $r9, 0($r4)
    bne     $r9, $r0, vL2_hit
    addi    $r6, $r10, 1
    sll     $r4, $r6, 3
    sll     $r5, $r6, 1
    add     $r4, $r4, $r5
    add     $r4, $r4, $r11
    add     $r4, $r26, $r4
    lw      $r9, 0($r4)
    bne     $r9, $r0, vL2_hit
    jr      $r31
vL2_hit:
    addi    $r8, $r0, 1
    jr      $r31

# L rot-3: cells (r,c)(r,c+1)(r+1,c+1)(r+2,c+1). 3-tall: row < 18.
validate_L_rot3:
    addi    $r4, $r0, 18
    blt     $r10, $r4, vL3_ok
    addi    $r8, $r0, 1
    jr      $r31
vL3_ok:
    sll     $r4, $r10, 3
    sll     $r5, $r10, 1
    add     $r4, $r4, $r5
    add     $r4, $r4, $r11
    add     $r4, $r26, $r4
    lw      $r9, 0($r4)
    bne     $r9, $r0, vL3_hit
    addi    $r4, $r4, 1
    lw      $r9, 0($r4)
    bne     $r9, $r0, vL3_hit
    addi    $r6, $r10, 1
    sll     $r4, $r6, 3
    sll     $r5, $r6, 1
    add     $r4, $r4, $r5
    add     $r4, $r4, $r11
    addi    $r4, $r4, 1
    add     $r4, $r26, $r4
    lw      $r9, 0($r4)
    bne     $r9, $r0, vL3_hit
    addi    $r6, $r10, 2
    sll     $r4, $r6, 3
    sll     $r5, $r6, 1
    add     $r4, $r4, $r5
    add     $r4, $r4, $r11
    addi    $r4, $r4, 1
    add     $r4, $r26, $r4
    lw      $r9, 0($r4)
    bne     $r9, $r0, vL3_hit
    jr      $r31
vL3_hit:
    addi    $r8, $r0, 1
    jr      $r31

##############################################################
# ROTATED COLL_BELOW ROUTINES
# For each non-zero rotation, check the locked cells directly
# below the bottom edge of each column occupied by the piece.
##############################################################

# I rot-1: cells (r,c)(r+1,c)(r+2,c)(r+3,c). Bottom=row+3. Check locked[row+4][col].
coll_below_I_rot1:
    addi    $r6, $r10, 4
    sll     $r4, $r6, 3
    sll     $r5, $r6, 1
    add     $r4, $r4, $r5
    add     $r4, $r4, $r11
    add     $r4, $r26, $r4
    lw      $r9, 0($r4)
    bne     $r9, $r0, cbIv_hit
    jr      $r31
cbIv_hit:
    addi    $r8, $r0, 1
    jr      $r31

# T rot-1: cells (r,c)(r+1,c)(r+2,c)(r+1,c+1).
# Col c: bottom=row+2 -> check row+3. Col c+1: bottom=row+1 -> check row+2.
coll_below_T_rot1:
    addi    $r6, $r10, 3
    sll     $r4, $r6, 3
    sll     $r5, $r6, 1
    add     $r4, $r4, $r5
    add     $r4, $r4, $r11
    add     $r4, $r26, $r4
    lw      $r9, 0($r4)
    bne     $r9, $r0, cbTr1_hit
    addi    $r6, $r10, 2
    sll     $r4, $r6, 3
    sll     $r5, $r6, 1
    add     $r4, $r4, $r5
    add     $r4, $r4, $r11
    addi    $r4, $r4, 1
    add     $r4, $r26, $r4
    lw      $r9, 0($r4)
    bne     $r9, $r0, cbTr1_hit
    jr      $r31
cbTr1_hit:
    addi    $r8, $r0, 1
    jr      $r31

# T rot-2: cells (r,c+1)(r+1,c)(r+1,c+1)(r+1,c+2). Bottom row=row+1 for all cols.
# Check locked[row+2][col], locked[row+2][col+1], locked[row+2][col+2].
coll_below_T_rot2:
    addi    $r6, $r10, 2
    sll     $r4, $r6, 3
    sll     $r5, $r6, 1
    add     $r4, $r4, $r5
    add     $r4, $r4, $r11
    add     $r4, $r26, $r4
    lw      $r9, 0($r4)
    bne     $r9, $r0, cbTr2_hit
    addi    $r4, $r4, 1
    lw      $r9, 0($r4)
    bne     $r9, $r0, cbTr2_hit
    addi    $r4, $r4, 1
    lw      $r9, 0($r4)
    bne     $r9, $r0, cbTr2_hit
    jr      $r31
cbTr2_hit:
    addi    $r8, $r0, 1
    jr      $r31

# T rot-3: cells (r,c+1)(r+1,c)(r+1,c+1)(r+2,c+1).
# Col c: bottom=row+1 -> check row+2. Col c+1: bottom=row+2 -> check row+3.
coll_below_T_rot3:
    addi    $r6, $r10, 2
    sll     $r4, $r6, 3
    sll     $r5, $r6, 1
    add     $r4, $r4, $r5
    add     $r4, $r4, $r11
    add     $r4, $r26, $r4
    lw      $r9, 0($r4)
    bne     $r9, $r0, cbTr3_hit
    addi    $r6, $r10, 3
    sll     $r4, $r6, 3
    sll     $r5, $r6, 1
    add     $r4, $r4, $r5
    add     $r4, $r4, $r11
    addi    $r4, $r4, 1
    add     $r4, $r26, $r4
    lw      $r9, 0($r4)
    bne     $r9, $r0, cbTr3_hit
    jr      $r31
cbTr3_hit:
    addi    $r8, $r0, 1
    jr      $r31

# S rot-1: cells (r,c)(r+1,c)(r+1,c+1)(r+2,c+1).
# Col c: bottom=row+1 -> check row+2. Col c+1: bottom=row+2 -> check row+3.
coll_below_S_rot1:
    addi    $r6, $r10, 2
    sll     $r4, $r6, 3
    sll     $r5, $r6, 1
    add     $r4, $r4, $r5
    add     $r4, $r4, $r11
    add     $r4, $r26, $r4
    lw      $r9, 0($r4)
    bne     $r9, $r0, cbSr1_hit
    addi    $r6, $r10, 3
    sll     $r4, $r6, 3
    sll     $r5, $r6, 1
    add     $r4, $r4, $r5
    add     $r4, $r4, $r11
    addi    $r4, $r4, 1
    add     $r4, $r26, $r4
    lw      $r9, 0($r4)
    bne     $r9, $r0, cbSr1_hit
    jr      $r31
cbSr1_hit:
    addi    $r8, $r0, 1
    jr      $r31

# Z rot-1: cells (r,c+1)(r+1,c)(r+1,c+1)(r+2,c).
# Col c: bottom=row+2 -> check row+3. Col c+1: bottom=row+1 -> check row+2.
coll_below_Z_rot1:
    addi    $r6, $r10, 3
    sll     $r4, $r6, 3
    sll     $r5, $r6, 1
    add     $r4, $r4, $r5
    add     $r4, $r4, $r11
    add     $r4, $r26, $r4
    lw      $r9, 0($r4)
    bne     $r9, $r0, cbZr1_hit
    addi    $r6, $r10, 2
    sll     $r4, $r6, 3
    sll     $r5, $r6, 1
    add     $r4, $r4, $r5
    add     $r4, $r4, $r11
    addi    $r4, $r4, 1
    add     $r4, $r26, $r4
    lw      $r9, 0($r4)
    bne     $r9, $r0, cbZr1_hit
    jr      $r31
cbZr1_hit:
    addi    $r8, $r0, 1
    jr      $r31

# J rot-1: cells (r,c)(r,c+1)(r+1,c)(r+2,c).
# Col c: bottom=row+2 -> check row+3. Col c+1: bottom=row+0 -> check row+1.
coll_below_J_rot1:
    addi    $r6, $r10, 3
    sll     $r4, $r6, 3
    sll     $r5, $r6, 1
    add     $r4, $r4, $r5
    add     $r4, $r4, $r11
    add     $r4, $r26, $r4
    lw      $r9, 0($r4)
    bne     $r9, $r0, cbJr1_hit
    addi    $r6, $r10, 1
    sll     $r4, $r6, 3
    sll     $r5, $r6, 1
    add     $r4, $r4, $r5
    add     $r4, $r4, $r11
    addi    $r4, $r4, 1
    add     $r4, $r26, $r4
    lw      $r9, 0($r4)
    bne     $r9, $r0, cbJr1_hit
    jr      $r31
cbJr1_hit:
    addi    $r8, $r0, 1
    jr      $r31

# J rot-2: cells (r,c)(r,c+1)(r,c+2)(r+1,c+2).
# Col c: bottom=row+0 -> check row+1. Col c+1: same. Col c+2: bottom=row+1 -> check row+2.
coll_below_J_rot2:
    addi    $r6, $r10, 1
    sll     $r4, $r6, 3
    sll     $r5, $r6, 1
    add     $r4, $r4, $r5
    add     $r4, $r4, $r11
    add     $r4, $r26, $r4
    lw      $r9, 0($r4)
    bne     $r9, $r0, cbJr2_hit
    addi    $r4, $r4, 1
    lw      $r9, 0($r4)
    bne     $r9, $r0, cbJr2_hit
    addi    $r6, $r10, 2
    sll     $r4, $r6, 3
    sll     $r5, $r6, 1
    add     $r4, $r4, $r5
    add     $r4, $r4, $r11
    addi    $r4, $r4, 2
    add     $r4, $r26, $r4
    lw      $r9, 0($r4)
    bne     $r9, $r0, cbJr2_hit
    jr      $r31
cbJr2_hit:
    addi    $r8, $r0, 1
    jr      $r31

# J rot-3: cells (r,c+1)(r+1,c+1)(r+2,c)(r+2,c+1).
# Col c: bottom=row+2 -> check row+3. Col c+1: same.
coll_below_J_rot3:
    addi    $r6, $r10, 3
    sll     $r4, $r6, 3
    sll     $r5, $r6, 1
    add     $r4, $r4, $r5
    add     $r4, $r4, $r11
    add     $r4, $r26, $r4
    lw      $r9, 0($r4)
    bne     $r9, $r0, cbJr3_hit
    addi    $r4, $r4, 1
    lw      $r9, 0($r4)
    bne     $r9, $r0, cbJr3_hit
    jr      $r31
cbJr3_hit:
    addi    $r8, $r0, 1
    jr      $r31

# L rot-1: cells (r,c)(r+1,c)(r+2,c)(r+2,c+1). Col c and c+1 both bottom at row+2. Check row+3.
coll_below_L_rot1:
    addi    $r6, $r10, 3
    sll     $r4, $r6, 3
    sll     $r5, $r6, 1
    add     $r4, $r4, $r5
    add     $r4, $r4, $r11
    add     $r4, $r26, $r4
    lw      $r9, 0($r4)
    bne     $r9, $r0, cbLr1_hit
    addi    $r4, $r4, 1
    lw      $r9, 0($r4)
    bne     $r9, $r0, cbLr1_hit
    jr      $r31
cbLr1_hit:
    addi    $r8, $r0, 1
    jr      $r31

# L rot-2: cells (r,c)(r,c+1)(r,c+2)(r+1,c).
# Col c: bottom=row+1 -> check row+2. Col c+1: bottom=row+0 -> check row+1. Col c+2: check row+1.
coll_below_L_rot2:
    addi    $r6, $r10, 2
    sll     $r4, $r6, 3
    sll     $r5, $r6, 1
    add     $r4, $r4, $r5
    add     $r4, $r4, $r11
    add     $r4, $r26, $r4
    lw      $r9, 0($r4)
    bne     $r9, $r0, cbLr2_hit
    addi    $r6, $r10, 1
    sll     $r4, $r6, 3
    sll     $r5, $r6, 1
    add     $r4, $r4, $r5
    add     $r4, $r4, $r11
    addi    $r4, $r4, 1
    add     $r4, $r26, $r4
    lw      $r9, 0($r4)
    bne     $r9, $r0, cbLr2_hit
    addi    $r4, $r4, 1
    lw      $r9, 0($r4)
    bne     $r9, $r0, cbLr2_hit
    jr      $r31
cbLr2_hit:
    addi    $r8, $r0, 1
    jr      $r31

# L rot-3: cells (r,c)(r,c+1)(r+1,c+1)(r+2,c+1).
# Col c: bottom=row+0 -> check row+1. Col c+1: bottom=row+2 -> check row+3.
coll_below_L_rot3:
    addi    $r6, $r10, 1
    sll     $r4, $r6, 3
    sll     $r5, $r6, 1
    add     $r4, $r4, $r5
    add     $r4, $r4, $r11
    add     $r4, $r26, $r4
    lw      $r9, 0($r4)
    bne     $r9, $r0, cbLr3_hit
    addi    $r6, $r10, 3
    sll     $r4, $r6, 3
    sll     $r5, $r6, 1
    add     $r4, $r4, $r5
    add     $r4, $r4, $r11
    addi    $r4, $r4, 1
    add     $r4, $r26, $r4
    lw      $r9, 0($r4)
    bne     $r9, $r0, cbLr3_hit
    jr      $r31
cbLr3_hit:
    addi    $r8, $r0, 1
    jr      $r31

##############################################################
# ROTATED DRAW ROUTINES (write color $r19 to framebuffer $r20)
# Cells are (piece_row + dr, piece_col + dc).
# addr = FB_BASE + row*10 + col  where row*10 = (row<<3)+(row<<1)
##############################################################

# I rot-1: (r,c)(r+1,c)(r+2,c)(r+3,c)
draw_I_rot1:
    sll     $r4, $r10, 3
    sll     $r5, $r10, 1
    add     $r4, $r4, $r5
    add     $r4, $r4, $r11
    add     $r4, $r20, $r4
    sw      $r19, 0($r4)
    addi    $r6, $r10, 1
    sll     $r4, $r6, 3
    sll     $r5, $r6, 1
    add     $r4, $r4, $r5
    add     $r4, $r4, $r11
    add     $r4, $r20, $r4
    sw      $r19, 0($r4)
    addi    $r6, $r10, 2
    sll     $r4, $r6, 3
    sll     $r5, $r6, 1
    add     $r4, $r4, $r5
    add     $r4, $r4, $r11
    add     $r4, $r20, $r4
    sw      $r19, 0($r4)
    addi    $r6, $r10, 3
    sll     $r4, $r6, 3
    sll     $r5, $r6, 1
    add     $r4, $r4, $r5
    add     $r4, $r4, $r11
    add     $r4, $r20, $r4
    sw      $r19, 0($r4)
    jr      $r31

# T rot-1: (r,c)(r+1,c)(r+2,c)(r+1,c+1)
draw_T_rot1:
    sll     $r4, $r10, 3
    sll     $r5, $r10, 1
    add     $r4, $r4, $r5
    add     $r4, $r4, $r11
    add     $r4, $r20, $r4
    sw      $r19, 0($r4)
    addi    $r6, $r10, 1
    sll     $r4, $r6, 3
    sll     $r5, $r6, 1
    add     $r4, $r4, $r5
    add     $r4, $r4, $r11
    add     $r4, $r20, $r4
    sw      $r19, 0($r4)
    addi    $r4, $r4, 1
    sw      $r19, 0($r4)
    addi    $r6, $r10, 2
    sll     $r4, $r6, 3
    sll     $r5, $r6, 1
    add     $r4, $r4, $r5
    add     $r4, $r4, $r11
    add     $r4, $r20, $r4
    sw      $r19, 0($r4)
    jr      $r31

# T rot-2: (r,c+1)(r+1,c)(r+1,c+1)(r+1,c+2)
draw_T_rot2:
    sll     $r4, $r10, 3
    sll     $r5, $r10, 1
    add     $r4, $r4, $r5
    add     $r4, $r4, $r11
    addi    $r4, $r4, 1
    add     $r4, $r20, $r4
    sw      $r19, 0($r4)
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

# T rot-3: (r,c+1)(r+1,c)(r+1,c+1)(r+2,c+1)
draw_T_rot3:
    sll     $r4, $r10, 3
    sll     $r5, $r10, 1
    add     $r4, $r4, $r5
    add     $r4, $r4, $r11
    addi    $r4, $r4, 1
    add     $r4, $r20, $r4
    sw      $r19, 0($r4)
    addi    $r6, $r10, 1
    sll     $r4, $r6, 3
    sll     $r5, $r6, 1
    add     $r4, $r4, $r5
    add     $r4, $r4, $r11
    add     $r4, $r20, $r4
    sw      $r19, 0($r4)
    addi    $r4, $r4, 1
    sw      $r19, 0($r4)
    addi    $r6, $r10, 2
    sll     $r4, $r6, 3
    sll     $r5, $r6, 1
    add     $r4, $r4, $r5
    add     $r4, $r4, $r11
    addi    $r4, $r4, 1
    add     $r4, $r20, $r4
    sw      $r19, 0($r4)
    jr      $r31

# S rot-1: (r,c)(r+1,c)(r+1,c+1)(r+2,c+1)
draw_S_rot1:
    sll     $r4, $r10, 3
    sll     $r5, $r10, 1
    add     $r4, $r4, $r5
    add     $r4, $r4, $r11
    add     $r4, $r20, $r4
    sw      $r19, 0($r4)
    addi    $r6, $r10, 1
    sll     $r4, $r6, 3
    sll     $r5, $r6, 1
    add     $r4, $r4, $r5
    add     $r4, $r4, $r11
    add     $r4, $r20, $r4
    sw      $r19, 0($r4)
    addi    $r4, $r4, 1
    sw      $r19, 0($r4)
    addi    $r6, $r10, 2
    sll     $r4, $r6, 3
    sll     $r5, $r6, 1
    add     $r4, $r4, $r5
    add     $r4, $r4, $r11
    addi    $r4, $r4, 1
    add     $r4, $r20, $r4
    sw      $r19, 0($r4)
    jr      $r31

# Z rot-1: (r,c+1)(r+1,c)(r+1,c+1)(r+2,c)
draw_Z_rot1:
    sll     $r4, $r10, 3
    sll     $r5, $r10, 1
    add     $r4, $r4, $r5
    add     $r4, $r4, $r11
    addi    $r4, $r4, 1
    add     $r4, $r20, $r4
    sw      $r19, 0($r4)
    addi    $r6, $r10, 1
    sll     $r4, $r6, 3
    sll     $r5, $r6, 1
    add     $r4, $r4, $r5
    add     $r4, $r4, $r11
    add     $r4, $r20, $r4
    sw      $r19, 0($r4)
    addi    $r4, $r4, 1
    sw      $r19, 0($r4)
    addi    $r6, $r10, 2
    sll     $r4, $r6, 3
    sll     $r5, $r6, 1
    add     $r4, $r4, $r5
    add     $r4, $r4, $r11
    add     $r4, $r20, $r4
    sw      $r19, 0($r4)
    jr      $r31

# J rot-1: (r,c)(r,c+1)(r+1,c)(r+2,c)
draw_J_rot1:
    sll     $r4, $r10, 3
    sll     $r5, $r10, 1
    add     $r4, $r4, $r5
    add     $r4, $r4, $r11
    add     $r4, $r20, $r4
    sw      $r19, 0($r4)
    addi    $r4, $r4, 1
    sw      $r19, 0($r4)
    addi    $r6, $r10, 1
    sll     $r4, $r6, 3
    sll     $r5, $r6, 1
    add     $r4, $r4, $r5
    add     $r4, $r4, $r11
    add     $r4, $r20, $r4
    sw      $r19, 0($r4)
    addi    $r6, $r10, 2
    sll     $r4, $r6, 3
    sll     $r5, $r6, 1
    add     $r4, $r4, $r5
    add     $r4, $r4, $r11
    add     $r4, $r20, $r4
    sw      $r19, 0($r4)
    jr      $r31

# J rot-2: (r,c)(r,c+1)(r,c+2)(r+1,c+2)
draw_J_rot2:
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
    addi    $r6, $r10, 1
    sll     $r4, $r6, 3
    sll     $r5, $r6, 1
    add     $r4, $r4, $r5
    add     $r4, $r4, $r11
    addi    $r4, $r4, 2
    add     $r4, $r20, $r4
    sw      $r19, 0($r4)
    jr      $r31

# J rot-3: (r,c+1)(r+1,c+1)(r+2,c)(r+2,c+1)
draw_J_rot3:
    sll     $r4, $r10, 3
    sll     $r5, $r10, 1
    add     $r4, $r4, $r5
    add     $r4, $r4, $r11
    addi    $r4, $r4, 1
    add     $r4, $r20, $r4
    sw      $r19, 0($r4)
    addi    $r6, $r10, 1
    sll     $r4, $r6, 3
    sll     $r5, $r6, 1
    add     $r4, $r4, $r5
    add     $r4, $r4, $r11
    addi    $r4, $r4, 1
    add     $r4, $r20, $r4
    sw      $r19, 0($r4)
    addi    $r6, $r10, 2
    sll     $r4, $r6, 3
    sll     $r5, $r6, 1
    add     $r4, $r4, $r5
    add     $r4, $r4, $r11
    add     $r4, $r20, $r4
    sw      $r19, 0($r4)
    addi    $r4, $r4, 1
    sw      $r19, 0($r4)
    jr      $r31

# L rot-1: (r,c)(r+1,c)(r+2,c)(r+2,c+1)
draw_L_rot1:
    sll     $r4, $r10, 3
    sll     $r5, $r10, 1
    add     $r4, $r4, $r5
    add     $r4, $r4, $r11
    add     $r4, $r20, $r4
    sw      $r19, 0($r4)
    addi    $r6, $r10, 1
    sll     $r4, $r6, 3
    sll     $r5, $r6, 1
    add     $r4, $r4, $r5
    add     $r4, $r4, $r11
    add     $r4, $r20, $r4
    sw      $r19, 0($r4)
    addi    $r6, $r10, 2
    sll     $r4, $r6, 3
    sll     $r5, $r6, 1
    add     $r4, $r4, $r5
    add     $r4, $r4, $r11
    add     $r4, $r20, $r4
    sw      $r19, 0($r4)
    addi    $r4, $r4, 1
    sw      $r19, 0($r4)
    jr      $r31

# L rot-2: (r,c)(r,c+1)(r,c+2)(r+1,c)
draw_L_rot2:
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
    addi    $r6, $r10, 1
    sll     $r4, $r6, 3
    sll     $r5, $r6, 1
    add     $r4, $r4, $r5
    add     $r4, $r4, $r11
    add     $r4, $r20, $r4
    sw      $r19, 0($r4)
    jr      $r31

# L rot-3: (r,c)(r,c+1)(r+1,c+1)(r+2,c+1)
draw_L_rot3:
    sll     $r4, $r10, 3
    sll     $r5, $r10, 1
    add     $r4, $r4, $r5
    add     $r4, $r4, $r11
    add     $r4, $r20, $r4
    sw      $r19, 0($r4)
    addi    $r4, $r4, 1
    sw      $r19, 0($r4)
    addi    $r6, $r10, 1
    sll     $r4, $r6, 3
    sll     $r5, $r6, 1
    add     $r4, $r4, $r5
    add     $r4, $r4, $r11
    addi    $r4, $r4, 1
    add     $r4, $r20, $r4
    sw      $r19, 0($r4)
    addi    $r6, $r10, 2
    sll     $r4, $r6, 3
    sll     $r5, $r6, 1
    add     $r4, $r4, $r5
    add     $r4, $r4, $r11
    addi    $r4, $r4, 1
    add     $r4, $r20, $r4
    sw      $r19, 0($r4)
    jr      $r31

##############################################################
# ROTATED LOCK ROUTINES (same cells as draw but write to $r26)
# $r13 = color (= piece_type + 1, set in lock_piece before dispatch)
##############################################################

# I rot-1: (r,c)(r+1,c)(r+2,c)(r+3,c)
lock_I_rot1:
    sll     $r4, $r10, 3
    sll     $r5, $r10, 1
    add     $r4, $r4, $r5
    add     $r4, $r4, $r11
    add     $r4, $r26, $r4
    sw      $r13, 0($r4)
    addi    $r6, $r10, 1
    sll     $r4, $r6, 3
    sll     $r5, $r6, 1
    add     $r4, $r4, $r5
    add     $r4, $r4, $r11
    add     $r4, $r26, $r4
    sw      $r13, 0($r4)
    addi    $r6, $r10, 2
    sll     $r4, $r6, 3
    sll     $r5, $r6, 1
    add     $r4, $r4, $r5
    add     $r4, $r4, $r11
    add     $r4, $r26, $r4
    sw      $r13, 0($r4)
    addi    $r6, $r10, 3
    sll     $r4, $r6, 3
    sll     $r5, $r6, 1
    add     $r4, $r4, $r5
    add     $r4, $r4, $r11
    add     $r4, $r26, $r4
    sw      $r13, 0($r4)
    jr      $r31

# T rot-1: (r,c)(r+1,c)(r+2,c)(r+1,c+1)
lock_T_rot1:
    sll     $r4, $r10, 3
    sll     $r5, $r10, 1
    add     $r4, $r4, $r5
    add     $r4, $r4, $r11
    add     $r4, $r26, $r4
    sw      $r13, 0($r4)
    addi    $r6, $r10, 1
    sll     $r4, $r6, 3
    sll     $r5, $r6, 1
    add     $r4, $r4, $r5
    add     $r4, $r4, $r11
    add     $r4, $r26, $r4
    sw      $r13, 0($r4)
    addi    $r4, $r4, 1
    sw      $r13, 0($r4)
    addi    $r6, $r10, 2
    sll     $r4, $r6, 3
    sll     $r5, $r6, 1
    add     $r4, $r4, $r5
    add     $r4, $r4, $r11
    add     $r4, $r26, $r4
    sw      $r13, 0($r4)
    jr      $r31

# T rot-2: (r,c+1)(r+1,c)(r+1,c+1)(r+1,c+2)
lock_T_rot2:
    sll     $r4, $r10, 3
    sll     $r5, $r10, 1
    add     $r4, $r4, $r5
    add     $r4, $r4, $r11
    addi    $r4, $r4, 1
    add     $r4, $r26, $r4
    sw      $r13, 0($r4)
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

# T rot-3: (r,c+1)(r+1,c)(r+1,c+1)(r+2,c+1)
lock_T_rot3:
    sll     $r4, $r10, 3
    sll     $r5, $r10, 1
    add     $r4, $r4, $r5
    add     $r4, $r4, $r11
    addi    $r4, $r4, 1
    add     $r4, $r26, $r4
    sw      $r13, 0($r4)
    addi    $r6, $r10, 1
    sll     $r4, $r6, 3
    sll     $r5, $r6, 1
    add     $r4, $r4, $r5
    add     $r4, $r4, $r11
    add     $r4, $r26, $r4
    sw      $r13, 0($r4)
    addi    $r4, $r4, 1
    sw      $r13, 0($r4)
    addi    $r6, $r10, 2
    sll     $r4, $r6, 3
    sll     $r5, $r6, 1
    add     $r4, $r4, $r5
    add     $r4, $r4, $r11
    addi    $r4, $r4, 1
    add     $r4, $r26, $r4
    sw      $r13, 0($r4)
    jr      $r31

# S rot-1: (r,c)(r+1,c)(r+1,c+1)(r+2,c+1)
lock_S_rot1:
    sll     $r4, $r10, 3
    sll     $r5, $r10, 1
    add     $r4, $r4, $r5
    add     $r4, $r4, $r11
    add     $r4, $r26, $r4
    sw      $r13, 0($r4)
    addi    $r6, $r10, 1
    sll     $r4, $r6, 3
    sll     $r5, $r6, 1
    add     $r4, $r4, $r5
    add     $r4, $r4, $r11
    add     $r4, $r26, $r4
    sw      $r13, 0($r4)
    addi    $r4, $r4, 1
    sw      $r13, 0($r4)
    addi    $r6, $r10, 2
    sll     $r4, $r6, 3
    sll     $r5, $r6, 1
    add     $r4, $r4, $r5
    add     $r4, $r4, $r11
    addi    $r4, $r4, 1
    add     $r4, $r26, $r4
    sw      $r13, 0($r4)
    jr      $r31

# Z rot-1: (r,c+1)(r+1,c)(r+1,c+1)(r+2,c)
lock_Z_rot1:
    sll     $r4, $r10, 3
    sll     $r5, $r10, 1
    add     $r4, $r4, $r5
    add     $r4, $r4, $r11
    addi    $r4, $r4, 1
    add     $r4, $r26, $r4
    sw      $r13, 0($r4)
    addi    $r6, $r10, 1
    sll     $r4, $r6, 3
    sll     $r5, $r6, 1
    add     $r4, $r4, $r5
    add     $r4, $r4, $r11
    add     $r4, $r26, $r4
    sw      $r13, 0($r4)
    addi    $r4, $r4, 1
    sw      $r13, 0($r4)
    addi    $r6, $r10, 2
    sll     $r4, $r6, 3
    sll     $r5, $r6, 1
    add     $r4, $r4, $r5
    add     $r4, $r4, $r11
    add     $r4, $r26, $r4
    sw      $r13, 0($r4)
    jr      $r31

# J rot-1: (r,c)(r,c+1)(r+1,c)(r+2,c)
lock_J_rot1:
    sll     $r4, $r10, 3
    sll     $r5, $r10, 1
    add     $r4, $r4, $r5
    add     $r4, $r4, $r11
    add     $r4, $r26, $r4
    sw      $r13, 0($r4)
    addi    $r4, $r4, 1
    sw      $r13, 0($r4)
    addi    $r6, $r10, 1
    sll     $r4, $r6, 3
    sll     $r5, $r6, 1
    add     $r4, $r4, $r5
    add     $r4, $r4, $r11
    add     $r4, $r26, $r4
    sw      $r13, 0($r4)
    addi    $r6, $r10, 2
    sll     $r4, $r6, 3
    sll     $r5, $r6, 1
    add     $r4, $r4, $r5
    add     $r4, $r4, $r11
    add     $r4, $r26, $r4
    sw      $r13, 0($r4)
    jr      $r31

# J rot-2: (r,c)(r,c+1)(r,c+2)(r+1,c+2)
lock_J_rot2:
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
    addi    $r6, $r10, 1
    sll     $r4, $r6, 3
    sll     $r5, $r6, 1
    add     $r4, $r4, $r5
    add     $r4, $r4, $r11
    addi    $r4, $r4, 2
    add     $r4, $r26, $r4
    sw      $r13, 0($r4)
    jr      $r31

# J rot-3: (r,c+1)(r+1,c+1)(r+2,c)(r+2,c+1)
lock_J_rot3:
    sll     $r4, $r10, 3
    sll     $r5, $r10, 1
    add     $r4, $r4, $r5
    add     $r4, $r4, $r11
    addi    $r4, $r4, 1
    add     $r4, $r26, $r4
    sw      $r13, 0($r4)
    addi    $r6, $r10, 1
    sll     $r4, $r6, 3
    sll     $r5, $r6, 1
    add     $r4, $r4, $r5
    add     $r4, $r4, $r11
    addi    $r4, $r4, 1
    add     $r4, $r26, $r4
    sw      $r13, 0($r4)
    addi    $r6, $r10, 2
    sll     $r4, $r6, 3
    sll     $r5, $r6, 1
    add     $r4, $r4, $r5
    add     $r4, $r4, $r11
    add     $r4, $r26, $r4
    sw      $r13, 0($r4)
    addi    $r4, $r4, 1
    sw      $r13, 0($r4)
    jr      $r31

# L rot-1: (r,c)(r+1,c)(r+2,c)(r+2,c+1)
lock_L_rot1:
    sll     $r4, $r10, 3
    sll     $r5, $r10, 1
    add     $r4, $r4, $r5
    add     $r4, $r4, $r11
    add     $r4, $r26, $r4
    sw      $r13, 0($r4)
    addi    $r6, $r10, 1
    sll     $r4, $r6, 3
    sll     $r5, $r6, 1
    add     $r4, $r4, $r5
    add     $r4, $r4, $r11
    add     $r4, $r26, $r4
    sw      $r13, 0($r4)
    addi    $r6, $r10, 2
    sll     $r4, $r6, 3
    sll     $r5, $r6, 1
    add     $r4, $r4, $r5
    add     $r4, $r4, $r11
    add     $r4, $r26, $r4
    sw      $r13, 0($r4)
    addi    $r4, $r4, 1
    sw      $r13, 0($r4)
    jr      $r31

# L rot-2: (r,c)(r,c+1)(r,c+2)(r+1,c)
lock_L_rot2:
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
    addi    $r6, $r10, 1
    sll     $r4, $r6, 3
    sll     $r5, $r6, 1
    add     $r4, $r4, $r5
    add     $r4, $r4, $r11
    add     $r4, $r26, $r4
    sw      $r13, 0($r4)
    jr      $r31

# L rot-3: (r,c)(r,c+1)(r+1,c+1)(r+2,c+1)
lock_L_rot3:
    sll     $r4, $r10, 3
    sll     $r5, $r10, 1
    add     $r4, $r4, $r5
    add     $r4, $r4, $r11
    add     $r4, $r26, $r4
    sw      $r13, 0($r4)
    addi    $r4, $r4, 1
    sw      $r13, 0($r4)
    addi    $r6, $r10, 1
    sll     $r4, $r6, 3
    sll     $r5, $r6, 1
    add     $r4, $r4, $r5
    add     $r4, $r4, $r11
    addi    $r4, $r4, 1
    add     $r4, $r26, $r4
    sw      $r13, 0($r4)
    addi    $r6, $r10, 2
    sll     $r4, $r6, 3
    sll     $r5, $r6, 1
    add     $r4, $r4, $r5
    add     $r4, $r4, $r11
    addi    $r4, $r4, 1
    add     $r4, $r26, $r4
    sw      $r13, 0($r4)
    jr      $r31

##############################################################
# CLEAR_LINES
# After a piece locks, scan locked_board rows 19->0.
# For each full row: shift all rows above down by one,
# clear row 0, increment score, display on LEDs.
# Re-checks same row index after shift (shifted row may be full too).
#
# Memory: score at addr 662, LED MMIO at 4097.
# Scratch: $r17=scan_row (preserved across inner calls),
#          $r2,$r3=temp for score/LED writes.
##############################################################
clear_lines:
    addi    $r29, $r29, -1
    sw      $r31, 0($r29)

    addi    $r17, $r0, 19         # start at bottom row
    addi    $r18, $r0, 0          # lines_this_lock = 0

cl_outer:
    jal     check_row_full        # $r17=row -> $r8=1 if full
    bne     $r8, $r0, cl_full

    # not full: move up one row
    bne     $r17, $r0, cl_dec
    j       cl_score              # finished row 0, done
cl_dec:
    addi    $r17, $r17, -1
    j       cl_outer

cl_full:
    jal     shift_rows_down       # shift rows 0..$r17-1 down into $r17, clear row 0
    addi    $r18, $r18, 1         # lines_this_lock++
    # recheck same row (shifted content may also be full)
    bne     $r17, $r0, cl_outer
    j       cl_score              # row 0 was the cleared one

cl_score:
    # Real Tetris scoring: 0→+0  1→+100  2→+300  3→+500  4→+800
    bne     $r18, $r0, cl_s1
    j       cl_done               # 0 lines cleared this lock
cl_s1:
    addi    $r2, $r0, 662
    lw      $r3, 0($r2)           # $r3 = current score
    addi    $r4, $r0, 1
    bne     $r18, $r4, cl_s2
    addi    $r3, $r3, 100         # single: +100
    j       cl_score_upd
cl_s2:
    addi    $r4, $r0, 2
    bne     $r18, $r4, cl_s3
    addi    $r3, $r3, 300         # double: +300
    j       cl_score_upd
cl_s3:
    addi    $r4, $r0, 3
    bne     $r18, $r4, cl_s4
    addi    $r3, $r3, 500         # triple: +500
    j       cl_score_upd
cl_s4:
    addi    $r3, $r3, 800         # Tetris: +800
cl_score_upd:
    sw      $r3, 0($r2)           # save score to addr 662
    addi    $r2, $r0, 4097
    sw      $r3, 0($r2)           # update LEDs

cl_done:
    lw      $r31, 0($r29)
    addi    $r29, $r29, 1
    jr      $r31

##############################################################
# CHECK_ROW_FULL -- leaf
# Input:  $r17 = row index to check
# Output: $r8  = 1 if all 10 cells non-zero, 0 otherwise
# Scratch: $r4,$r5 (addr compute), $r6 (cell value), $r9 (col counter)
##############################################################
check_row_full:
    sll     $r4, $r17, 3
    sll     $r5, $r17, 1
    add     $r4, $r4, $r5         # row*10
    add     $r4, $r26, $r4        # &locked_board[row][0]
    addi    $r8, $r0, 1           # assume full
    addi    $r9, $r0, 10          # 10 cells per row
crf_loop:
    bne     $r9, $r0, crf_cell
    jr      $r31                  # all 10 non-zero: full
crf_cell:
    lw      $r6, 0($r4)
    bne     $r6, $r0, crf_ok
    addi    $r8, $r0, 0           # found empty cell: not full
    jr      $r31
crf_ok:
    addi    $r4, $r4, 1
    addi    $r9, $r9, -1
    j       crf_loop

##############################################################
# SHIFT_ROWS_DOWN -- leaf
# Input:  $r17 = index of the full (cleared) row
# Effect: for dest=$r17 downto 1: locked[dest] <- locked[dest-1]
#         then locked[0] <- zeros
# Scratch: $r14 (dest_row), $r15 (src_row),
#          $r4 (dest ptr), $r5 (temp), $r6 (src ptr),
#          $r9 (col count), $r16 (cell value)
##############################################################
shift_rows_down:
    addi    $r14, $r17, 0         # dest_row = cleared_row

srd_outer:
    bne     $r14, $r0, srd_copy

    # dest_row == 0: zero out row 0 and return
    add     $r4, $r26, $r0        # &locked_board[0][0]
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
    addi    $r15, $r14, -1        # src_row = dest_row - 1
    # dest ptr: &locked_board[dest_row][0]
    sll     $r4, $r14, 3
    sll     $r5, $r14, 1
    add     $r4, $r4, $r5
    add     $r4, $r26, $r4
    # src ptr: &locked_board[src_row][0]
    sll     $r6, $r15, 3
    sll     $r5, $r15, 1
    add     $r6, $r6, $r5
    add     $r6, $r26, $r6
    addi    $r9, $r0, 10
srd_copy_loop:
    bne     $r9, $r0, srd_copy_cell
    addi    $r14, $r14, -1        # dest_row--
    j       srd_outer
srd_copy_cell:
    lw      $r16, 0($r6)
    sw      $r16, 0($r4)
    addi    $r4, $r4, 1
    addi    $r6, $r6, 1
    addi    $r9, $r9, -1
    j       srd_copy_loop
