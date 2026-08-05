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
    input clock,
    input reset
);

    wire rwe, mwe;
    wire [4:0] rd, rs1, rs2;
    wire [31:0] instAddr, instData;
    wire [31:0] rData, regA, regB;
    wire [31:0] memAddr, memDataIn, memDataOut;

    // ? FIX: NO absolute Windows path
    localparam INSTR_FILE = "C:/Users/ah670/Documents/tetris/assembler-python-version/tetris.mem";

    // ================= CPU =================
    processor CPU(
        .clock(clock), .reset(reset),
        .address_imem(instAddr), .q_imem(instData),
        .ctrl_writeEnable(rwe), .ctrl_writeReg(rd),
        .ctrl_readRegA(rs1), .ctrl_readRegB(rs2),
        .data_writeReg(rData), .data_readRegA(regA), .data_readRegB(regB),
        .wren(mwe), .address_dmem(memAddr),
        .data(memDataIn), .q_dmem(memDataOut)
    );

    // ================= ROM =================
    ROM #(.MEMFILE(INSTR_FILE)) InstMem(
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
    RAM ProcMem(
        .clk(clock),
        .wEn(mwe),
        .addr(memAddr[11:0]),
        .dataIn(memDataIn),
        .dataOut(memDataOut)
    );

endmodule
