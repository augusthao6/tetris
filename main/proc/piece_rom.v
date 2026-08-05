`timescale 1ns / 1ps
// Piece footprint ROM + metadata ROM
// MMIO interface (both use one shared query register):
//   SW to addr 4099 or 4100: latch query[4:0] = {piece_type[2:0], piece_rot[1:0]}
//   LW from addr 4099: returns 32-bit packed cell offsets
//     bits [7:4]=dr0  [3:0]=dc0   [15:12]=dr1 [11:8]=dc1
//          [23:20]=dr2 [19:16]=dc2 [31:28]=dr3 [27:24]=dc3
//   LW from addr 4100: returns {16'b0, floor_lim[7:0], right_lim[7:0]}
//     floor_lim = max valid piece_row before locking (blt row, floor_lim)
//     right_lim = max valid piece_col before right-wall block (blt col, right_lim)
module piece_rom (
    input        clk,
    input        wEn,
    input  [4:0] query_in,
    output [31:0] footprint,
    output [31:0] metadata
);
    reg [4:0] query_reg;

    always @(posedge clk)
        if (wEn) query_reg <= query_in;

    // ── Footprint ROM ──────────────────────────────────────────
    // Encoding per nibble pair: {dr[3:0], dc[3:0]} for cells 0..3
    reg [31:0] fp;
    always @(*) begin
        case (query_reg)
            // I (type=0)
            5'd0:  fp = 32'h03020100; // rot0: (0,0)(0,1)(0,2)(0,3)
            5'd1:  fp = 32'h30201000; // rot1: (0,0)(1,0)(2,0)(3,0)
            // O (type=1) — no rotation, all rots same
            5'd4:  fp = 32'h11100100; // rot0: (0,0)(0,1)(1,0)(1,1)
            5'd5:  fp = 32'h11100100;
            5'd6:  fp = 32'h11100100;
            5'd7:  fp = 32'h11100100;
            // T (type=2)
            5'd8:  fp = 32'h11020100; // rot0: (0,0)(0,1)(0,2)(1,1)
            5'd9:  fp = 32'h11201000; // rot1: (0,0)(1,0)(2,0)(1,1)
            5'd10: fp = 32'h12111001; // rot2: (0,1)(1,0)(1,1)(1,2)
            5'd11: fp = 32'h21111001; // rot3: (0,1)(1,0)(1,1)(2,1)
            // S (type=3)
            5'd12: fp = 32'h11100201; // rot0: (0,1)(0,2)(1,0)(1,1)
            5'd13: fp = 32'h21111000; // rot1: (0,0)(1,0)(1,1)(2,1)
            5'd14: fp = 32'h11100201; // rot2 = rot0
            5'd15: fp = 32'h21111000; // rot3 = rot1
            // Z (type=4)
            5'd16: fp = 32'h12110100; // rot0: (0,0)(0,1)(1,1)(1,2)
            5'd17: fp = 32'h20111001; // rot1: (0,1)(1,0)(1,1)(2,0)
            5'd18: fp = 32'h12110100; // rot2 = rot0
            5'd19: fp = 32'h20111001; // rot3 = rot1
            // J (type=5)
            5'd20: fp = 32'h12111000; // rot0: (0,0)(1,0)(1,1)(1,2)
            5'd21: fp = 32'h20100100; // rot1: (0,0)(0,1)(1,0)(2,0)
            5'd22: fp = 32'h12020100; // rot2: (0,0)(0,1)(0,2)(1,2)
            5'd23: fp = 32'h21201101; // rot3: (0,1)(1,1)(2,0)(2,1)
            // L (type=6)
            5'd24: fp = 32'h12111002; // rot0: (0,2)(1,0)(1,1)(1,2)
            5'd25: fp = 32'h21201000; // rot1: (0,0)(1,0)(2,0)(2,1)
            5'd26: fp = 32'h10020100; // rot2: (0,0)(0,1)(0,2)(1,0)
            5'd27: fp = 32'h21110100; // rot3: (0,0)(0,1)(1,1)(2,1)
            default: fp = 32'h0;
        endcase
    end
    assign footprint = fp;

    // ── Metadata ROM ───────────────────────────────────────────
    // {16'b0, floor_lim[7:0], right_lim[7:0]}
    // floor_lim: blt piece_row, floor_lim → floor ok (else lock)
    // right_lim: blt piece_col, right_lim → right-wall ok (else block)
    reg [31:0] md;
    always @(*) begin
        case (query_reg)
            5'd0:  md = {16'h0, 8'd19, 8'd6};  // I rot0: 1-tall, 4-wide
            5'd1:  md = {16'h0, 8'd16, 8'd10}; // I rot1: 4-tall, 1-wide (col<10 always)
            5'd4:  md = {16'h0, 8'd18, 8'd8};  // O
            5'd5:  md = {16'h0, 8'd18, 8'd8};
            5'd6:  md = {16'h0, 8'd18, 8'd8};
            5'd7:  md = {16'h0, 8'd18, 8'd8};
            5'd8:  md = {16'h0, 8'd18, 8'd7};  // T rot0
            5'd9:  md = {16'h0, 8'd17, 8'd8};  // T rot1
            5'd10: md = {16'h0, 8'd18, 8'd7};  // T rot2
            5'd11: md = {16'h0, 8'd17, 8'd8};  // T rot3
            5'd12: md = {16'h0, 8'd18, 8'd7};  // S rot0
            5'd13: md = {16'h0, 8'd17, 8'd8};  // S rot1
            5'd14: md = {16'h0, 8'd18, 8'd7};
            5'd15: md = {16'h0, 8'd17, 8'd8};
            5'd16: md = {16'h0, 8'd18, 8'd7};  // Z rot0
            5'd17: md = {16'h0, 8'd17, 8'd8};  // Z rot1
            5'd18: md = {16'h0, 8'd18, 8'd7};
            5'd19: md = {16'h0, 8'd17, 8'd8};
            5'd20: md = {16'h0, 8'd18, 8'd7};  // J rot0
            5'd21: md = {16'h0, 8'd17, 8'd8};  // J rot1
            5'd22: md = {16'h0, 8'd18, 8'd7};  // J rot2
            5'd23: md = {16'h0, 8'd17, 8'd8};  // J rot3
            5'd24: md = {16'h0, 8'd18, 8'd7};  // L rot0
            5'd25: md = {16'h0, 8'd17, 8'd8};  // L rot1
            5'd26: md = {16'h0, 8'd18, 8'd7};  // L rot2
            5'd27: md = {16'h0, 8'd17, 8'd8};  // L rot3
            default: md = {16'h0, 8'd18, 8'd7};
        endcase
    end
    assign metadata = md;

endmodule
