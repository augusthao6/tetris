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
    input BTNU,                    // reset
    input BTNL,                    // move left
    input BTNR,                    // move right
    input BTNC,                    // rotate (center button)
    input BTND,                     //soft drop
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
    wire io_read     = (memAddr == 32'd4096);   // frame counter read
    wire io_write    = (memAddr == 32'd4097);   // LED write
    wire io_btn_read = (memAddr == 32'd4098);   // button state read

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

    // ---- Button debounce (2-stage synchronizer) ----
    reg [1:0] btnL_sync, btnR_sync, btnC_sync, btnD_sync, btnU_sync;
    always @(posedge clock) begin
        btnL_sync <= {btnL_sync[0], BTNL};
        btnR_sync <= {btnR_sync[0], BTNR};
        btnC_sync <= {btnC_sync[0], BTNC};
        btnD_sync <= {btnD_sync[0], BTND};
        btnU_sync <= {btnU_sync[0], BTNU};
    end
    wire btn_left   = btnL_sync[1];
    wire btn_right  = btnR_sync[1];
    wire btn_rotate = btnC_sync[1];
    wire btn_down   = btnD_sync[1];
    wire btn_up     = btnU_sync[1];
    // bit0=left  bit1=right  bit2=rotate  bit3=soft-drop  bit4=reset(BTNU)
    wire [31:0] btn_state = {27'b0, btn_up, btn_down, btn_rotate, btn_right, btn_left};

    assign q_dmem = io_read     ? frame_counter :
                    io_btn_read ? btn_state      : memDataOut;

    // ---- Snoop CPU writes to score (addr 662) ----
    reg [31:0] score_reg;
    always @(posedge clock) begin
        if (reset)
            score_reg <= 0;
        else if (mwe && (memAddr == 32'd662))
            score_reg <= memDataIn;
    end

    // ================= Program =================
    localparam INSTR_FILE = "tetris";

    // ================= CPU =================

    processor CPU(
        .clock(clock), .reset(reset),
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
    RAM_dual ProcMem(
        .clk(clock),
        .wEn(mwe && !io_write),
        .addr_a(memAddr[11:0]),
        .dataIn_a(memDataIn),
        .dataOut_a(memDataOut),
        .addr_b(fb_addr + 12'd256),
        .dataOut_b(fb_data)
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
        .fb_data(fb_data),
        .score(score_reg)
    );

endmodule
