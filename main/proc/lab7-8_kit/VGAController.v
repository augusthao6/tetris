module VGAController(     
    input clk,
    input reset,
    output hSync,
    output vSync,
    output [3:0] VGA_R,
    output [3:0] VGA_G,
    output [3:0] VGA_B,
    // ── NEW: framebuffer read port ──────────────────
    output [6:0]  fb_addr,       // which cell to read (0–199, 10×20 grid)
    input  [31:0] fb_data        // color ID from processor's dmem
    // ── REMOVED: ps2, buttons, BTNU/L/R/D ──────────
);

    // Clock divider — keep exactly as-is
    wire clk25, locked;
    clk_wiz_0 pll(.clk_out1(clk25), .reset(reset), .locked(locked), .clk_in1(clk));

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
    wire [3:0] cell_col = x / CELL_W;   // 0–9
    wire [4:0] cell_row = y / CELL_H;   // 0–19

    // ── Request the framebuffer cell one cycle ahead ──
    // fb_addr is driven combinationally; fb_data comes back next cycle
    // To handle the 1-cycle RAM latency, register x/y one cycle
    reg [9:0] x_d; reg [8:0] y_d; reg active_d;
    always @(posedge clk25) begin
        x_d      <= x;
        y_d      <= y;
        active_d <= active;
    end

    // Address the cell for the *current* pixel (combinational)
    wire [3:0] cur_col = x_d / CELL_W;
    wire [4:0] cur_row = y_d / CELL_H;
    assign fb_addr = cur_row * 10 + cur_col;  // 7 bits covers 0–199

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
    wire on_grid = (x_d % CELL_W == 0) || (y_d % CELL_H == 0);
    wire [11:0] finalColor = on_grid ? 12'h333 : piece_color;

    assign {VGA_R, VGA_G, VGA_B} = active_d ? finalColor : 12'd0;

endmodule