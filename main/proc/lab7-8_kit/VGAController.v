module VGAController(     
    input clk_25mhz,
    input reset,
    output hSync,
    output vSync,
    output [3:0] VGA_R,
    output [3:0] VGA_G,
    output [3:0] VGA_B,
    // ── NEW: framebuffer read port ──────────────────
    output [7:0]  fb_addr,       // which cell to read (0–199, 10×20 grid)
    input  [31:0] fb_data        // color ID from processor's dmem
    // ── REMOVED: ps2, buttons, BTNU/L/R/D ──────────
);

    // Clock divider — keep exactly as-is
    wire clk25, locked;
    assign clk25 =clk_25mhz;

    localparam
        VIDEO_WIDTH  = 640,
        VIDEO_HEIGHT = 480,
        // Tetris grid: 10 cols × 20 rows
        // Each cell = 64×24 pixels (640/10 = 64, 480/20 = 24)
        CELL_W = 64,
        CELL_H = 24;

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

    // ── Compute which Tetris cell the current pixel is in ──
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
        end else begin
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

    // ── Color decode ──────────────────────────────────────
    // fb_data holds color ID written by processor (0=empty, 1–7=piece colors)
    // Map color ID → 12-bit RGB
    reg [11:0] piece_color;
    always @(*) begin
        case (fb_data[2:0])
            3'd0: piece_color = 12'h111;  // empty  — dark gray
            3'd1: piece_color = 12'h0FF;  // I piece — cyan
            3'd2: piece_color = 12'hFF0;  // O piece — yellow
            3'd3: piece_color = 12'hF0F;  // T piece — purple
            3'd4: piece_color = 12'h0F0;  // S piece — green
            3'd5: piece_color = 12'hF00;  // Z piece — red
            3'd6: piece_color = 12'h00F;  // J piece — blue
            3'd7: piece_color = 12'hFA0;  // L piece — orange
            default: piece_color = 12'h111;
        endcase
    end

    // Optional: draw a 1-pixel grid line between cells
    wire on_grid = (col_count == 0) || (row_count == 0);
    wire [11:0] finalColor = on_grid ? 12'h333 : piece_color;

    assign {VGA_R, VGA_G, VGA_B} = (active_d && !reset) ? finalColor : 12'd0;

endmodule