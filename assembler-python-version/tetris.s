##############################################################
# Tetris: All 7 pieces, piece-collision, floor-collision, game-over
#
# Memory layout (word-addressed):
#   256-455  : framebuffer (FB_BASE, 10x20 = 200 words)
#   456      : piece_row
#   457      : piece_col
#   458      : gravity_timer
#   459      : piece_type  (0=I 1=O 2=T 3=S 4=Z 5=J 6=L)
#   460-659  : locked_board (200 words, same layout as framebuffer)
#
# Piece cells (dr, dc), rotation-0 only:
#   I(0): (0,0)(0,1)(0,2)(0,3)  color=1
#   O(1): (0,0)(0,1)(1,0)(1,1)  color=2
#   T(2): (0,0)(0,1)(0,2)(1,1)  color=3
#   S(3): (0,1)(0,2)(1,0)(1,1)  color=4
#   Z(4): (0,0)(0,1)(1,1)(1,2)  color=5
#   J(5): (0,0)(1,0)(1,1)(1,2)  color=6
#   L(6): (0,2)(1,0)(1,1)(1,2)  color=7
#
# Global registers (preserved across all calls):
#   $r20 = FB_BASE    = 256
#   $r21 = addr(piece_row)     = 456
#   $r22 = addr(piece_col)     = 457
#   $r23 = addr(gravity_timer) = 458
#   $r24 = MMIO frame counter  = 4096
#   $r25 = addr(piece_type)    = 459
#   $r26 = LOCKED_BASE = 460
#   $r29 = stack pointer
#
# Calling convention:
#   $r31 = link register (saved/restored by non-leaf callers)
#   $r8  = collision flag output from check_collision_below
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

    # Clear FB + locked_board (400 words starting at address 256)
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
    sw      $r0, 0($r25)          # piece_type = 0 (I-piece)

##############################################################
# GAME LOOP
##############################################################
game_loop:
    jal     wait_frame
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
    # I-piece (max dr=0): can move while piece_row < 19
    # All others (max dr=1): can move while piece_row < 18
    bne     $r12, $r0, tg_floor_other
    addi    $r4, $r0, 19
    blt     $r10, $r4, tg_floor_ok
    j       tg_lock
tg_floor_other:
    addi    $r4, $r0, 18
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
    addi    $r8, $r0, 0           # collision flag = 0

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
    j       cgo_halt              # GAME OVER — freeze

##############################################################
# LOCK_PIECE — stamp active piece into locked_board
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
# SPAWN_PIECE — cycle piece_type mod 7, reset position/timer
# Leaf function.
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
