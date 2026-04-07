`timescale 1ns / 1ps
/**
 * 
 * READ THIS DESCRIPTION:
 *
 * This is the Wrapper module that will serve as the header file combining your processor, 
 * RegFile and Memory elements together.
 *
 * This file will be used to generate the bitstream to upload to the FPGA.
 * We have provided a sibling file, Wrapper_tb.v so that you can test your processor's functionality.
 * 
 * We will be using our own separate Wrapper_tb.v to test your code. You are allowed to make changes to the Wrapper files 
 * for your own individual testing, but we expect your final processor.v and memory modules to work with the 
 * provided Wrapper interface.
 * 
 * Refer to Lab 5 documents for detailed instructions on how to interface 
 * with the memory elements. Each imem and dmem modules will take 12-bit 
 * addresses and will allow for storing of 32-bit values at each address. 
 * Each memory module should receive a single clock. At which edges, is 
 * purely a design choice (and thereby up to you). 
 * 
 * You must change line 36 to add the memory file of the test you created using the assembler
 * For example, you would add sample inside of the quotes on line 38 after assembling sample.s
 *
 **/

`timescale 1ns / 1ps

module Wrapper (
    input clk_100mhz,
    input BTNU, 
    input [15:0] SW,
    output reg [15:0] LED,

    // VGA outputs (REQUIRED by XDC)
    output hSync,
    output vSync,
    output [3:0] VGA_R,
    output [3:0] VGA_G,
    output [3:0] VGA_B
);

    wire clock, reset, clk_25mhz;
    assign clock = clk_25mhz;
    assign reset = BTNU; 
    
    clk_wiz_0 clk25 (
        .clk_in1(clk_100mhz),  // from board
        .clk_out1(clk_25mhz),  // generated 25 MHz
        .reset(1'b0),          // or use reset
        .locked(locked)
    );

    // ================= CPU wires =================
    wire rwe, mwe;
    wire [4:0] rd, rs1, rs2;
    wire [31:0] instAddr, instData;
    wire [31:0] rData, regA, regB;
    wire [31:0] memAddr, memDataIn, memDataOut, q_dmem;

    reg [15:0] SW_Q, SW_M;  

    // ================= IO mapping =================
    wire io_read  = (memAddr == 32'd4096);
    wire io_write = (memAddr == 32'd4097);

    always @(negedge clock) begin
        SW_M <= SW;
        SW_Q <= SW_M; 
    end

    always @(posedge clock) begin
        if (io_write)
            LED <= memDataIn[15:0];
    end

    reg [31:0] frame_counter;
    reg vSync_prev;
    always @(posedge clock) begin
        vSync_prev <= vSync;
        if (vSync && !vSync_prev)
            frame_counter <= frame_counter + 1;
    end

    assign q_dmem = io_read ? frame_counter : memDataOut;

    // ================= Program =================
    localparam INSTR_FILE = "tetris";

    // ================= CPU =================
   wire cpu_clk = clock & !vga_turn;

    processor CPU(
        .clock(cpu_clk), .reset(reset),
        .address_imem(instAddr), .q_imem(instData),
        .ctrl_writeEnable(rwe), .ctrl_writeReg(rd),
        .ctrl_readRegA(rs1), .ctrl_readRegB(rs2),
        .data_writeReg(rData), .data_readRegA(regA), .data_readRegB(regB),
        .wren(mwe), .address_dmem(memAddr),
        .data(memDataIn), .q_dmem(q_dmem)
    );

    // ================= ROM =================
    ROM #(.MEMFILE({INSTR_FILE, ".mem"})) InstMem(
        .clk(clock),
        .addr(instAddr[11:0]),
        .dataOut(instData)
    );

    // ================= RegFile =================
    regfile RegisterFile(
        .clock(clock),
        .ctrl_writeEnable(rwe), .ctrl_reset(reset),
        .ctrl_writeReg(rd),
        .ctrl_readRegA(rs1), .ctrl_readRegB(rs2),
        .data_writeReg(rData),
        .data_readRegA(regA), .data_readRegB(regB)
    );

    // ================= RAM =================
    // Mux: VGA reads on one half-cycle, CPU on the other
    reg vga_turn;
    always @(posedge clock)
        vga_turn <= ~vga_turn;
    
    wire [11:0] ram_addr = vga_turn ? (fb_addr + 12'd256) : memAddr[11:0];
    wire ram_wEn = vga_turn ? 1'b0 : (mwe && !io_write);
    
    // Capture VGA data when it's VGA's turn
    reg [31:0] fb_data_reg;
    always @(posedge clock)
        if (vga_turn)
            fb_data_reg <= memDataOut;
    
    assign fb_data = fb_data_reg;
    
    // RAM uses muxed signals
    RAM ProcMem(
        .clk(clock),
        .wEn(ram_wEn),
        .addr(ram_addr),
        .dataIn(memDataIn),
        .dataOut(memDataOut)
    );
    // ================= VGA =================
    wire [7:0] fb_addr;
    wire [31:0] fb_data;


    VGAController vga(
        .clk_25mhz(clk_25mhz),
        .reset(reset),
        .hSync(hSync),
        .vSync(vSync),
        .VGA_R(VGA_R),
        .VGA_G(VGA_G),
        .VGA_B(VGA_B),
        .fb_addr(fb_addr),
        .fb_data(fb_data)
    );

endmodule
