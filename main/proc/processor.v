/**
 * READ THIS DESCRIPTION!
 *
 * This is your processor module that will contain the bulk of your code submission. You are to implement
 * a 5-stage pipelined processor in this module, accounting for hazards and implementing bypasses as
 * necessary.
 *
 * Ultimately, your processor will be tested by a master skeleton, so the
 * testbench can see which controls signal you active when. Therefore, there needs to be a way to
 * "inject" imem, dmem, and regfile interfaces from some external controller module. The skeleton
 * file, Wrapper.v, acts as a small wrapper around your processor for this purpose. Refer to Wrapper.v
 * for more details.
 *
 * As a result, this module will NOT contain the RegFile nor the memory modules. Study the inputs 
 * very carefully - the RegFile-related I/Os are merely signals to be sent to the RegFile instantiated
 * in your Wrapper module. This is the same for your memory elements. 
 *
 *
 */
module processor(
    // Control signals
    clock,                          // I: The master clock
    reset,                          // I: A reset signal

    // Imem
    address_imem,                   // O: The address of the data to get from imem
    q_imem,                         // I: The data from imem

    // Dmem
    address_dmem,                   // O: The address of the data to get or put from/to dmem
    data,                           // O: The data to write to dmem
    wren,                           // O: Write enable for dmem
    q_dmem,                         // I: The data from dmem

    // Regfile
    ctrl_writeEnable,               // O: Write enable for RegFile
    ctrl_writeReg,                  // O: Register to write to in RegFile
    ctrl_readRegA,                  // O: Register to read from port A of RegFile
    ctrl_readRegB,                  // O: Register to read from port B of RegFile
    data_writeReg,                  // O: Data to write to for RegFile
    data_readRegA,                  // I: Data from port A of RegFile
    data_readRegB                   // I: Data from port B of RegFile
	 
	);

	// Control signals
	input clock, reset;
	
	// Imem
    output [31:0] address_imem;
	input [31:0] q_imem;

	// Dmem
	output [31:0] address_dmem, data;
	output wren;
	input [31:0] q_dmem;

	// Regfile
	output ctrl_writeEnable;
	output [4:0] ctrl_writeReg, ctrl_readRegA, ctrl_readRegB;
	output [31:0] data_writeReg;
	input [31:0] data_readRegA, data_readRegB;

	/* YOUR CODE STARTS HERE */
	//PC
    wire[31:0] pc_in, pc_out, pc_plus1;
    cla32 PC_adder(.A(pc_out), .B(32'd1), .Cin(1'b0), .S(pc_plus1), .Cout()); //word oriented +1
    register32 PC_reg(.q(pc_out), .d(pc_in), .clk(~clock), .input_enable(1'b1), .clr(reset));
    assign pc_in = pc_plus1; //increment PC by 1 each cycle

    //Insn Mem
    assign address_imem = pc_out;

    //F/D
    wire [31:0] fd_insn, fd_pc_plus1;
    register32 fd_insn_reg(.q(fd_insn), .d(q_imem), .clk(~clock), .input_enable(1'b1), .clr(reset));
    register32 fd_pc_plus1_reg(.q(fd_pc_plus1), .d(pc_plus1), .clk(~clock), .input_enable(1'b1), .clr(reset));

    //Decode
    wire[4:0] fd_opcode, fd_rs, fd_rt, fd_rd;
    assign fd_opcode = fd_insn[31:27];
    assign fd_rd = fd_insn[26:22];
    assign fd_rs = fd_insn[21:17];
    assign fd_rt = fd_insn[16:12];
    assign ctrl_readRegA = fd_rs;
    assign ctrl_readRegB = fd_rt;

    //RegFile - in Wrapper.v

    //D/X
    wire [31:0] dx_insn, dx_pc_plus1, dx_readDataA, dx_readDataB;
    register32 dx_insn_reg(.q(dx_insn), .d(fd_insn), .clk(~clock), .input_enable(1'b1), .clr(reset));
    register32 dx_pc_plus1_reg(.q(dx_pc_plus1), .d(fd_pc_plus1), .clk(~clock), .input_enable(1'b1), .clr(reset));
    register32 dx_readDataA_reg(.q(dx_readDataA), .d(data_readRegA), .clk(~clock), .input_enable(1'b1), .clr(reset));
    register32 dx_readDataB_reg(.q(dx_readDataB), .d(data_readRegB), .clk(~clock), .input_enable(1'b1), .clr(reset));

    //Execute
    wire [4:0] dx_opcode, dx_rs, dx_rt, dx_rd, dx_shamt, dx_aluop;
    assign dx_opcode = dx_insn[31:27];
    assign dx_rd = dx_insn[26:22];
    assign dx_rs = dx_insn[21:17];
    assign dx_rt = dx_insn[16:12];
    assign dx_shamt = dx_insn[11:7];
    assign dx_aluop = dx_insn[6:2];

    wire [31:0] dx_sign_ext_imm;
    assign dx_sign_ext_imm = {{15{dx_insn[16]}}, dx_insn[16:0]};

    //opcodes
    wire dx_rtype, dx_addi;
    assign dx_rtype = (dx_opcode == 5'b00000);
    assign dx_addi = (dx_opcode == 5'b00101);

    wire add, sub, and32, or32, sll, sra, mul, div;
    assign add = dx_rtype && (dx_aluop == 5'b00000);
    assign sub = dx_rtype && (dx_aluop == 5'b00001);
    assign and32 = dx_rtype && (dx_aluop == 5'b00010);
    assign or32 = dx_rtype && (dx_aluop == 5'b00011);
    assign sll = dx_rtype && (dx_aluop == 5'b00100);
    assign sra = dx_rtype && (dx_aluop == 5'b00101);
    assign mul = dx_rtype && (dx_aluop == 5'b00110);
    assign div = dx_rtype && (dx_aluop == 5'b00111);

    //ALU
    wire dx_regwrite;
    assign dx_regwrite = dx_rtype || dx_addi;
    wire [4:0] alu_opcode = dx_rtype ? dx_aluop : 5'b00000; //add for addi
    wire [31:0] alu_inB = dx_addi ? dx_sign_ext_imm: dx_readDataB; //use sign extended imm for addi, B otherwise

    wire [31:0] alu_out;
    wire alu_ne, alu_lt, alu_overflow;

    alu ALU(.data_operandA (dx_readDataA), .data_operandB (alu_inB), .ctrl_ALUopcode(alu_opcode), .ctrl_shiftamt(dx_shamt), .data_result(alu_out), .isNotEqual(alu_ne), .isLessThan(alu_lt), .overflow(alu_overflow));
    
    wire [31:0] dx_writedata;
    wire [4:0] dx_writereg;
    assign dx_writedata = alu_out;
    assign dx_writereg = dx_rd; //rt for addi, rd for R-type

    //overflow?

    //X/M - not needed now, not doing load or store word
    wire [31:0] xm_alu_out, xm_storedata;
    wire [4:0] xm_rd;
    wire xm_regwrite, xm_isSW_q, xm_isLW_q;

    register32 xm_result(.q(xm_alu_out), .d(dx_writedata), .clk(~clock), .input_enable(1'b1), .clr(reset));
    register32 xm_store(.q(xm_storedata), .d(alu_inB), .clk(~clock), .input_enable(1'b1), .clr(reset));

    //5-bit write register
    genvar xm_rd_i;
    generate
        for (xm_rd_i = 0; xm_rd_i < 5; xm_rd_i = xm_rd_i + 1) begin : XM_RD
            dffe_ref xm_rd_ff(.q(xm_rd[xm_rd_i]), .d(dx_writereg[xm_rd_i]), .clk(~clock), .en(1'b1), .clr(reset));
        end
    endgenerate

    //1-bit control signals
    dffe_ref xm_rw_ff(.q(xm_regwrite), .d(dx_regwrite), .clk(~clock), .en(1'b1), .clr(reset));
    dffe_ref xm_sw_ff(.q(xm_isSW_q), .d(1'b0), .clk(~clock), .en(1'b1), .clr(reset));
    dffe_ref xm_lw_ff(.q(xm_isLW_q), .d(1'b0), .clk(~clock), .en(1'b1), .clr(reset));

    //Data Mem
    assign address_dmem = xm_alu_out;
    assign data = xm_storedata;
    assign wren = 1'b0;

    //M/W - same thing not implementing load or store, pass along ALU result and control signals for writing to regfile
    wire [31:0] mw_alu_out;
    wire [4:0] mw_rd;
    wire mw_regwrite, mw_isLW_q;

    register32 mw_result(.q(mw_alu_out), .d(xm_alu_out), .clk(~clock), .input_enable(1'b1), .clr(reset));
    //5 bit write register
    genvar mw_rd_i;
    generate
        for (mw_rd_i = 0; mw_rd_i < 5; mw_rd_i = mw_rd_i + 1) begin : MW_RD
            dffe_ref mw_rd_ff(.q(mw_rd[mw_rd_i]), .d(xm_rd[mw_rd_i]), .clk(~clock), .en(1'b1), .clr(reset));
        end
    endgenerate

    //1-bit control signals
    dffe_ref mw_rw_ff(.q(mw_regwrite), .d(xm_regwrite), .clk(~clock), .en(1'b1), .clr(reset));
    dffe_ref mw_lw_ff(.q(mw_isLW_q), .d(xm_isLW_q), .clk(~clock), .en(1'b1), .clr(reset));

    //Writeback
    wire [31:0] mw_writedata = mw_isLW_q ? q_dmem : mw_alu_out;
    assign data_writeReg = mw_writedata;
    assign ctrl_writeReg = mw_rd;
    assign ctrl_writeEnable = mw_regwrite;
	/* END CODE */

endmodule
