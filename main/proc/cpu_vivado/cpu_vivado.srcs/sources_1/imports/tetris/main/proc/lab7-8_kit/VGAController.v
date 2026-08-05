module VGAController(
    input clk_25mhz,
    input reset,
    output hSync,
    output vSync,
    output [3:0] VGA_R,
    output [3:0] VGA_G,
    output [3:0] VGA_B,
    // framebuffer read port (10×20 grid, cells 0–199)
    output [7:0]  fb_addr,
    input  [31:0] fb_data,
    // scores from CPU (raw integer)
    input  [31:0] score,
    input  [31:0] high_score
);

    wire clk25;
    assign clk25 = clk_25mhz;

    localparam
        VIDEO_WIDTH  = 640,
        VIDEO_HEIGHT = 480,
        // Game board: 10 cols × 20 rows, left-aligned
        // 32 px wide × 24 px tall per cell  →  320 × 480 px
        CELL_W = 32,
        CELL_H = 24,
        BOARD_W = 320,   // 10 * CELL_W
        // Score panel: x = 320..639
        PANEL_X = 320;

    wire active, screenEnd;
    wire [9:0] x;
    wire [8:0] y;

    VGATimingGenerator #(.HEIGHT(VIDEO_HEIGHT), .WIDTH(VIDEO_WIDTH))
    Display(
        .clk25(clk25), .reset(reset),
        .screenEnd(screenEnd), .active(active),
        .hSync(hSync), .vSync(vSync),
        .x(x), .y(y)
    );

    // ── Board cell tracking (only meaningful for x < BOARD_W) ──
    reg [3:0] cell_col;
    reg [4:0] cell_row;
    reg [5:0] col_count;
    reg [4:0] row_count;
    reg active_d;

    reg vSync_prev;
    always @(posedge clk25)
        vSync_prev <= vSync;
    wire vSync_edge = !vSync && vSync_prev;

    reg active_prev;
    always @(posedge clk25)
        active_prev <= active;
    wire active_falling = !active && active_prev;

    always @(posedge clk25) begin
        active_d <= active;
        if (!active) begin
            cell_col  <= 0;
            col_count <= 0;
        end else if (x < BOARD_W) begin
            if (col_count == CELL_W - 1) begin
                col_count <= 0;
                cell_col  <= cell_col + 1;
            end else
                col_count <= col_count + 1;
        end

        if (active_falling) begin
            if (row_count == CELL_H - 1) begin
                row_count <= 0;
                cell_row  <= cell_row + 1;
            end else
                row_count <= row_count + 1;
        end

        if (vSync_edge) begin
            cell_row  <= 0;
            row_count <= 0;
        end
    end

    assign fb_addr = (cell_row << 3) + (cell_row << 1) + cell_col;

    // ── Board color decode ────────────────────────────────────
    reg [11:0] piece_color;
    always @(*) begin
        case (fb_data[2:0])
            3'd0: piece_color = 12'h111;  // empty  — dark gray
            3'd1: piece_color = 12'h0FF;  // I — cyan
            3'd2: piece_color = 12'hFF0;  // O — yellow
            3'd3: piece_color = 12'hA0F;  // T — purple
            3'd4: piece_color = 12'h0F0;  // S — green
            3'd5: piece_color = 12'hF00;  // Z — red
            3'd6: piece_color = 12'h00F;  // J — blue
            3'd7: piece_color = 12'hFA0;  // L — orange
            default: piece_color = 12'h111;
        endcase
    end

    wire on_grid = (col_count == 0) || (row_count == 0);
    wire [11:0] board_pixel = on_grid ? 12'h333 : piece_color;

    // ── Score panel (x = 320..639) ───────────────────────────
    // Two 5-digit displays stacked vertically:
    //   Top:    current score  (yellow digits)
    //   Bottom: high score     (cyan digits)
    //
    // Each digit: 5×7 font scaled ×4 → 20px wide × 28px tall
    // 5 digits + 4 gaps = 5*20 + 4*4 = 116px
    // Centred in 320px panel: start_x = 320 + (320-116)/2 = 422

    // Decompose score into 5 decimal digits (capped at 99999)
    wire [16:0] score_cap = (score > 17'd99999) ? 17'd99999 : score[16:0];
    wire [3:0] sd4 = score_cap / 10000;
    wire [3:0] sd3 = (score_cap % 10000) / 1000;
    wire [3:0] sd2 = (score_cap % 1000)  / 100;
    wire [3:0] sd1 = (score_cap % 100)   / 10;
    wire [3:0] sd0 = score_cap % 10;

    // Decompose high_score into 5 decimal digits (capped at 99999)
    wire [16:0] best_cap = (high_score > 17'd99999) ? 17'd99999 : high_score[16:0];
    wire [3:0] bd4 = best_cap / 10000;
    wire [3:0] bd3 = (best_cap % 10000) / 1000;
    wire [3:0] bd2 = (best_cap % 1000)  / 100;
    wire [3:0] bd1 = (best_cap % 100)   / 10;
    wire [3:0] bd0 = best_cap % 10;

    // 5×7 bitmap font (35 bits per digit, rows MSB first)
    // Each row is 5 bits, packed as [34:30]=row0 .. [4:0]=row6
    function [34:0] digit_bitmap;
        input [3:0] d;
        case (d)
            4'd0: digit_bitmap = 35'b01110_10001_10011_10101_11001_10001_01110;
            4'd1: digit_bitmap = 35'b00100_01100_00100_00100_00100_00100_01110;
            4'd2: digit_bitmap = 35'b01110_10001_00001_00110_01000_10000_11111;
            4'd3: digit_bitmap = 35'b11111_00010_00100_00010_00001_10001_01110;
            4'd4: digit_bitmap = 35'b00010_00110_01010_10010_11111_00010_00010;
            4'd5: digit_bitmap = 35'b11111_10000_11110_00001_00001_10001_01110;
            4'd6: digit_bitmap = 35'b00110_01000_10000_11110_10001_10001_01110;
            4'd7: digit_bitmap = 35'b11111_00001_00010_00100_01000_01000_01000;
            4'd8: digit_bitmap = 35'b01110_10001_10001_01110_10001_10001_01110;
            4'd9: digit_bitmap = 35'b01110_10001_10001_01111_00001_00010_01100;
            default: digit_bitmap = 35'b0;
        endcase
    endfunction

    function font_bit;
        input [34:0] bmp;
        input [2:0]  row;
        input [2:0]  col;
        reg [4:0] rowbits;
        begin
            case (row)
                3'd0: rowbits = bmp[34:30];
                3'd1: rowbits = bmp[29:25];
                3'd2: rowbits = bmp[24:20];
                3'd3: rowbits = bmp[19:15];
                3'd4: rowbits = bmp[14:10];
                3'd5: rowbits = bmp[9:5];
                3'd6: rowbits = bmp[4:0];
                default: rowbits = 5'b0;
            endcase
            font_bit = rowbits[4 - col];
        end
    endfunction

    // ── Layout constants ──────────────────────────────────────
    localparam DIGIT_W   = 20;   // 5 font cols × scale 4
    localparam DIGIT_H   = 28;   // 7 font rows × scale 4
    localparam DIGIT_GAP = 4;
    // 5 digits: total span = 5*DIGIT_W + 4*DIGIT_GAP = 116px
    // Centered in 320px panel: 320 + (320-116)/2 = 422
    localparam SCORE_X0  = 422;
    localparam SCORE_Y0  = 130;  // score digits y-start
    localparam BEST_X0   = 422;
    localparam BEST_Y0   = 310;  // high-score digits y-start

    wire [9:0] px = x;
    wire [8:0] py = y;

    // ── Score digit hit-tests ─────────────────────────────────
    wire [9:0] sr4 = px - SCORE_X0;
    wire [9:0] sr3 = px - (SCORE_X0 +   (DIGIT_W + DIGIT_GAP));
    wire [9:0] sr2 = px - (SCORE_X0 + 2*(DIGIT_W + DIGIT_GAP));
    wire [9:0] sr1 = px - (SCORE_X0 + 3*(DIGIT_W + DIGIT_GAP));
    wire [9:0] sr0 = px - (SCORE_X0 + 4*(DIGIT_W + DIGIT_GAP));

    wire s_in4 = (px >= SCORE_X0)                              && (px < SCORE_X0 +   DIGIT_W);
    wire s_in3 = (px >= SCORE_X0 +   (DIGIT_W+DIGIT_GAP))     && (px < SCORE_X0 + 2*DIGIT_W +   DIGIT_GAP);
    wire s_in2 = (px >= SCORE_X0 + 2*(DIGIT_W+DIGIT_GAP))     && (px < SCORE_X0 + 3*DIGIT_W + 2*DIGIT_GAP);
    wire s_in1 = (px >= SCORE_X0 + 3*(DIGIT_W+DIGIT_GAP))     && (px < SCORE_X0 + 4*DIGIT_W + 3*DIGIT_GAP);
    wire s_in0 = (px >= SCORE_X0 + 4*(DIGIT_W+DIGIT_GAP))     && (px < SCORE_X0 + 5*DIGIT_W + 4*DIGIT_GAP);

    wire [2:0] sfc4 = sr4[4:2];
    wire [2:0] sfc3 = sr3[4:2];
    wire [2:0] sfc2 = sr2[4:2];
    wire [2:0] sfc1 = sr1[4:2];
    wire [2:0] sfc0 = sr0[4:2];

    wire in_score_y = (py >= SCORE_Y0) && (py < SCORE_Y0 + DIGIT_H);
    wire [2:0] sfrow = (py - SCORE_Y0) >> 2;

    wire sbit4 = font_bit(digit_bitmap(sd4), sfrow, sfc4);
    wire sbit3 = font_bit(digit_bitmap(sd3), sfrow, sfc3);
    wire sbit2 = font_bit(digit_bitmap(sd2), sfrow, sfc2);
    wire sbit1 = font_bit(digit_bitmap(sd1), sfrow, sfc1);
    wire sbit0 = font_bit(digit_bitmap(sd0), sfrow, sfc0);

    wire score_dot = in_score_y && (
        (s_in4 && sbit4) ||
        (s_in3 && sbit3) ||
        (s_in2 && sbit2) ||
        (s_in1 && sbit1) ||
        (s_in0 && sbit0)
    );

    wire score_label_bar = (py >= SCORE_Y0 - 10) && (py < SCORE_Y0 - 6)
                        && (px >= SCORE_X0) && (px < SCORE_X0 + 5*DIGIT_W + 4*DIGIT_GAP);

    // ── High-score digit hit-tests ────────────────────────────
    wire [9:0] br4 = px - BEST_X0;
    wire [9:0] br3 = px - (BEST_X0 +   (DIGIT_W + DIGIT_GAP));
    wire [9:0] br2 = px - (BEST_X0 + 2*(DIGIT_W + DIGIT_GAP));
    wire [9:0] br1 = px - (BEST_X0 + 3*(DIGIT_W + DIGIT_GAP));
    wire [9:0] br0 = px - (BEST_X0 + 4*(DIGIT_W + DIGIT_GAP));

    wire b_in4 = (px >= BEST_X0)                              && (px < BEST_X0 +   DIGIT_W);
    wire b_in3 = (px >= BEST_X0 +   (DIGIT_W+DIGIT_GAP))     && (px < BEST_X0 + 2*DIGIT_W +   DIGIT_GAP);
    wire b_in2 = (px >= BEST_X0 + 2*(DIGIT_W+DIGIT_GAP))     && (px < BEST_X0 + 3*DIGIT_W + 2*DIGIT_GAP);
    wire b_in1 = (px >= BEST_X0 + 3*(DIGIT_W+DIGIT_GAP))     && (px < BEST_X0 + 4*DIGIT_W + 3*DIGIT_GAP);
    wire b_in0 = (px >= BEST_X0 + 4*(DIGIT_W+DIGIT_GAP))     && (px < BEST_X0 + 5*DIGIT_W + 4*DIGIT_GAP);

    wire [2:0] bfc4 = br4[4:2];
    wire [2:0] bfc3 = br3[4:2];
    wire [2:0] bfc2 = br2[4:2];
    wire [2:0] bfc1 = br1[4:2];
    wire [2:0] bfc0 = br0[4:2];

    wire in_best_y = (py >= BEST_Y0) && (py < BEST_Y0 + DIGIT_H);
    wire [2:0] bfrow = (py - BEST_Y0) >> 2;

    wire bbit4 = font_bit(digit_bitmap(bd4), bfrow, bfc4);
    wire bbit3 = font_bit(digit_bitmap(bd3), bfrow, bfc3);
    wire bbit2 = font_bit(digit_bitmap(bd2), bfrow, bfc2);
    wire bbit1 = font_bit(digit_bitmap(bd1), bfrow, bfc1);
    wire bbit0 = font_bit(digit_bitmap(bd0), bfrow, bfc0);

    wire best_dot = in_best_y && (
        (b_in4 && bbit4) ||
        (b_in3 && bbit3) ||
        (b_in2 && bbit2) ||
        (b_in1 && bbit1) ||
        (b_in0 && bbit0)
    );

    wire best_label_bar = (py >= BEST_Y0 - 10) && (py < BEST_Y0 - 6)
                       && (px >= BEST_X0) && (px < BEST_X0 + 5*DIGIT_W + 4*DIGIT_GAP);

    // ── Panel pixel mux ───────────────────────────────────────
    wire in_panel = active_d && (x >= PANEL_X);

    wire [11:0] panel_pixel =
        score_dot       ? 12'hFF0 :   // score digits     — yellow
        best_dot        ? 12'h0FF :   // high-score digits — cyan
        score_label_bar ? 12'hAAA :   // score label line  — gray
        best_label_bar  ? 12'h777 :   // best label line   — darker gray
                          12'h112;    // panel background  — dark blue

    // Divider line between board and panel
    wire divider = active_d && (x == PANEL_X || x == PANEL_X + 1);

    // ── Final output mux ──────────────────────────────────────
    wire [11:0] finalColor =
        divider                          ? 12'hFFF :
        (active_d && x < PANEL_X)        ? board_pixel :
        in_panel                         ? panel_pixel :
                                           12'h000;

    assign {VGA_R, VGA_G, VGA_B} = (active_d && !reset) ? finalColor : 12'd0;

endmodule
