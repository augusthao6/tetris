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
    // score from CPU (raw integer, up to 9999)
    input  [31:0] score
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
    // Display up to 4 decimal digits, centred in the right half.
    // Each digit is drawn with a 5×7 dot-matrix font scaled ×4 (20×28 px).
    // Digits start at y=180, x=340 (first digit).

    // Decompose score into 4 decimal digits (capped at 9999 for display)
    wire [13:0] score_cap = (score > 14'd9999) ? 14'd9999 : score[13:0];
    wire [3:0] d3 = score_cap / 1000;          // thousands
    wire [3:0] d2 = (score_cap % 1000) / 100;  // hundreds
    wire [3:0] d1 = (score_cap % 100)  / 10;   // tens
    wire [3:0] d0 = score_cap % 10;             // units

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

    // Panel layout constants (registered for timing)
    // 4 digits, each 20px wide (5 cols × 4), 4px gap → total 4*20+3*4 = 92px
    // Centre in 320px panel: start_x = 320 + (320-92)/2 = 320 + 114 = 434
    localparam DIGIT_W   = 20;   // 5 font cols × scale 4
    localparam DIGIT_H   = 28;   // 7 font rows × scale 4
    localparam DIGIT_GAP = 4;
    localparam SCORE_X0  = 434;  // x of leftmost digit (in full-screen coords)
    localparam SCORE_Y0  = 226;  // y: (480 - 28) / 2

    // Compute panel pixel
    wire in_panel = active_d && (x >= PANEL_X);

    // Which digit slot? (0=thousands, 1=hundreds, 2=tens, 3=units)
    // Precompute relative x within panel (pipeline stage handled by active_d)
    wire [9:0] px = x;   // current pixel x (combinational OK, 1-cycle pipeline via active_d)
    wire [8:0] py = y;

    wire in_score_y = (py >= SCORE_Y0) && (py < SCORE_Y0 + DIGIT_H);

    // For each digit position check if pixel hits it
    wire [9:0] rel0 = px - SCORE_X0;
    wire [9:0] rel1 = px - (SCORE_X0 + DIGIT_W + DIGIT_GAP);
    wire [9:0] rel2 = px - (SCORE_X0 + 2*(DIGIT_W + DIGIT_GAP));
    wire [9:0] rel3 = px - (SCORE_X0 + 3*(DIGIT_W + DIGIT_GAP));

    wire in_d3 = (px >= SCORE_X0)                             && (px < SCORE_X0 + DIGIT_W);
    wire in_d2 = (px >= SCORE_X0 +   DIGIT_W + DIGIT_GAP)    && (px < SCORE_X0 + 2*DIGIT_W +   DIGIT_GAP);
    wire in_d1 = (px >= SCORE_X0 + 2*DIGIT_W + 2*DIGIT_GAP)  && (px < SCORE_X0 + 3*DIGIT_W + 2*DIGIT_GAP);
    wire in_d0 = (px >= SCORE_X0 + 3*DIGIT_W + 3*DIGIT_GAP)  && (px < SCORE_X0 + 4*DIGIT_W + 3*DIGIT_GAP);

    // font_col (0–4) and font_row (0–6) within the digit
    wire [2:0] fc3 = rel0[4:2];   // rel / 4
    wire [2:0] fc2 = rel1[4:2];
    wire [2:0] fc1 = rel2[4:2];
    wire [2:0] fc0 = rel3[4:2];
    wire [2:0] font_row = (py - SCORE_Y0) >> 2;  // (py - SCORE_Y0) / 4

    function font_bit;
        input [34:0] bmp;
        input [2:0]  row;
        input [2:0]  col;
        // row 0 = bits [34:30], row 6 = bits [4:0]
        // within each row, col 0 = MSB (bit 4)
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

    wire bit3 = font_bit(digit_bitmap(d3), font_row, fc3);
    wire bit2 = font_bit(digit_bitmap(d2), font_row, fc2);
    wire bit1 = font_bit(digit_bitmap(d1), font_row, fc1);
    wire bit0 = font_bit(digit_bitmap(d0), font_row, fc0);

    wire score_dot = in_score_y && (
        (in_d3 && bit3) ||
        (in_d2 && bit2) ||
        (in_d1 && bit1) ||
        (in_d0 && bit0)
    );

    // "SCORE" label: simple horizontal bar at y=190 (just above digits)
    wire score_label_bar = (py >= SCORE_Y0 - 10) && (py < SCORE_Y0 - 6)
                        && (px >= SCORE_X0) && (px < SCORE_X0 + 4*DIGIT_W + 3*DIGIT_GAP);

    wire [11:0] panel_pixel = score_dot    ? 12'hFF0 :   // digits — yellow
                              score_label_bar ? 12'hAAA : // label line — gray
                              12'h112;                    // panel background — dark blue

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
