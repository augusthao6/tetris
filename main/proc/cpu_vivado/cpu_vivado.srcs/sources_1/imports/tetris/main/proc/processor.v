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

    //Insn Mem
    assign address_imem = pc_out;

    //F/D
    wire [31:0] fd_insn, fd_pc_plus1;
    wire [31:0] fd_insn_final, fd_pc_plus1_in;
    wire stall_multdiv, stall_lw, stall;
    wire [31:0] bypass_readDataA, bypass_readDataB;
    wire flush_pipeline;

    assign fd_insn_final = (reset || flush_pipeline) ? 32'b0 : q_imem;
    assign fd_pc_plus1_in = flush_pipeline ? 32'b0 : pc_plus1;

    register32 fd_insn_reg(.q(fd_insn), .d(fd_insn_final), .clk(~clock), .input_enable(!stall), .clr(1'b0));
    register32 fd_pc_plus1_reg(.q(fd_pc_plus1), .d(fd_pc_plus1_in), .clk(~clock), .input_enable(!stall), .clr(reset));

    //Decode
    wire [4:0] fd_opcode, fd_rs, fd_rt, fd_rd;
    assign fd_opcode = fd_insn[31:27];
    wire fd_bex, fd_bne, fd_blt;
    assign fd_bex = (fd_opcode == 5'b10110);
    assign fd_bne = (fd_opcode == 5'b00010);
    assign fd_blt = (fd_opcode == 5'b00110);
    wire fd_jr;
    assign fd_jr = (fd_opcode == 5'b00100);
    wire fd_sw, fd_lw;
    assign fd_sw = (fd_opcode == 5'b00111);
    assign fd_lw = (fd_opcode == 5'b01000);
    assign fd_rd = fd_insn[26:22];
    assign fd_rs = fd_insn[21:17];
    assign fd_rt = fd_insn[16:12];
    assign ctrl_readRegA = fd_bex ? 5'd30 : (fd_jr || fd_bne || fd_blt) ? fd_rd : fd_rs;
    assign ctrl_readRegB = fd_sw ? fd_rd : (fd_bne || fd_blt) ? fd_rs : fd_rt;

    //RegFile - in Wrapper.v

    //D/X
    wire [31:0] dx_insn, dx_pc_plus1, dx_readDataA, dx_readDataB, dx_readDataA_in, dx_readDataB_in;
    wire [31:0] dx_insn_in, dx_pc_plus1_in;

    assign dx_insn_in = stall_lw ? 32'b0 : flush_pipeline ? 32'b0 : fd_insn;
    assign dx_pc_plus1_in = stall_lw ? 32'b0 : flush_pipeline ? 32'b0 : fd_pc_plus1;
    assign dx_readDataA_in = stall_lw ? 32'b0 : flush_pipeline ? 32'b0 : data_readRegA;
    assign dx_readDataB_in = stall_lw ? 32'b0 : flush_pipeline ? 32'b0 : data_readRegB;

    register32 dx_insn_reg(.q(dx_insn), .d(dx_insn_in), .clk(~clock), .input_enable(!stall_multdiv), .clr(reset));
    register32 dx_pc_plus1_reg(.q(dx_pc_plus1), .d(dx_pc_plus1_in), .clk(~clock), .input_enable(!stall_multdiv), .clr(reset));
    register32 dx_readDataA_reg(.q(dx_readDataA), .d(dx_readDataA_in), .clk(~clock), .input_enable(!stall_multdiv), .clr(reset));
    register32 dx_readDataB_reg(.q(dx_readDataB), .d(dx_readDataB_in), .clk(~clock), .input_enable(!stall_multdiv), .clr(reset));
    
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
    wire [26:0] dx_target;
    assign dx_target = dx_insn[26:0]; //j/jal/bex
    wire [31:0] dx_br_offset = {{10{dx_insn[21]}}, dx_insn[21:0]};

    //opcodes
    wire dx_rtype, dx_addi, dx_sw, dx_lw, dx_j, dx_jal, dx_jr, dx_bne, dx_blt, dx_bex, dx_setx;
    assign dx_rtype = (dx_opcode == 5'b00000);
    assign dx_addi = (dx_opcode == 5'b00101);
    assign dx_sw = (dx_opcode == 5'b00111);
    assign dx_lw = (dx_opcode == 5'b01000);
    assign dx_j = (dx_opcode == 5'b00001);
    assign dx_jal = (dx_opcode == 5'b00011);
    assign dx_jr = (dx_opcode == 5'b00100);
    assign dx_bne = (dx_opcode == 5'b00010);
    assign dx_blt = (dx_opcode == 5'b00110);
    assign dx_bex = (dx_opcode == 5'b10110);
    assign dx_setx = (dx_opcode == 5'b10101);

    wire add, sub, and32, or32, sll, sra, mul, div, dx_lfsr;
    assign add     = dx_rtype && (dx_aluop == 5'b00000);
    assign sub     = dx_rtype && (dx_aluop == 5'b00001);
    assign and32   = dx_rtype && (dx_aluop == 5'b00010);
    assign or32    = dx_rtype && (dx_aluop == 5'b00011);
    assign sll     = dx_rtype && (dx_aluop == 5'b00100);
    assign sra     = dx_rtype && (dx_aluop == 5'b00101);
    assign mul     = dx_rtype && (dx_aluop == 5'b00110);
    assign div     = dx_rtype && (dx_aluop == 5'b00111);
    // Custom: 7-bit Fibonacci LFSR step (aluop 01000)
    // Polynomial x^7+x^6+1: feedback = bit[6] XOR bit[5]
    // new_state = { state[5:0], feedback }  (7-bit shift left + insert feedback)
    assign dx_lfsr = dx_rtype && (dx_aluop == 5'b01000);
    wire lfsr_feedback = bypass_readDataA[6] ^ bypass_readDataA[5];
    wire [31:0] lfsr_raw = {25'b0, bypass_readDataA[5:0], lfsr_feedback};
    // Guard: LFSR state must never be zero; if so, reset to 1
    wire [31:0] lfsr_result = (lfsr_raw == 32'b0) ? 32'd1 : lfsr_raw;
    wire dx_multdiv;
    assign dx_multdiv = mul || div;

    //ALU
    wire [4:0] alu_opcode;
    assign alu_opcode = dx_rtype ? dx_aluop : (dx_bne || dx_blt) ? 5'b00001 : //subtract for comparison
                        5'b00000; //add for addi
    wire [31:0] alu_inB;
    assign alu_inB = (dx_addi || dx_sw || dx_lw) ? dx_sign_ext_imm: bypass_readDataB; //use sign extended imm for addi, B otherwise

    wire [31:0] alu_out;
    wire alu_ne, alu_lt, alu_overflow;

    alu ALU(.data_operandA(bypass_readDataA), .data_operandB(alu_inB), .ctrl_ALUopcode(alu_opcode), .ctrl_shiftamt(dx_shamt), .data_result(alu_out), .isNotEqual(alu_ne), .isLessThan(alu_lt), .overflow(alu_overflow));
    
    //multdiv
    wire [31:0] multdiv_out;
    wire multdiv_exception, multdiv_ready;
    wire multdiv_mult, multdiv_div;
    assign multdiv_mult = mul && !doing_multdiv;
    assign multdiv_div = div && !doing_multdiv;
    multdiv MULTDIV(.data_operandA(bypass_readDataA), .data_operandB(bypass_readDataB), .ctrl_MULT(multdiv_mult), .ctrl_DIV(multdiv_div), .clock(clock), .data_result(multdiv_out), .data_exception(multdiv_exception), .data_resultRDY(multdiv_ready));

    //need to stall for multdiv
    wire doing_multdiv, doing_multdiv_next;
    assign doing_multdiv_next = (dx_multdiv && !doing_multdiv) ? 1'b1 : // start
                                (doing_multdiv && multdiv_ready) ? 1'b0 : // done (one cycle after ready)
                                doing_multdiv;
    dffe_ref doing_multdiv_ff(.q(doing_multdiv), .d(doing_multdiv_next), .clk(~clock), .en(1'b1), .clr(reset));
    wire [4:0] multdiv_dest;
    genvar k;
    generate
        for (k = 0; k < 5; k = k + 1) begin : multdiv_dest_loop
            dffe_ref multdiv_dest_ff(.q(multdiv_dest[k]), .d(dx_rd[k]), .clk(~clock), .en(dx_multdiv && !doing_multdiv), .clr(reset));
        end
    endgenerate
    assign stall_multdiv = (doing_multdiv && !multdiv_ready) || (dx_multdiv && !doing_multdiv);

    //stall load when lw in DX and next insn in FD uses its destination reg
    assign stall_lw = dx_lw && (dx_rd != 5'd0) && ((dx_rd == ctrl_readRegA) || (dx_rd == ctrl_readRegB && !fd_sw));
    assign stall = stall_multdiv || stall_lw;

    //branch/jump
    wire do_bne, do_blt, do_bex;
    assign do_bne = dx_bne && alu_ne;
    assign do_blt = dx_blt && alu_lt;
    assign do_bex = dx_bex && (bypass_readDataA != 32'b0);
    wire branch_taken, jump_taken;
    assign branch_taken = do_bne || do_blt || do_bex;
    assign jump_taken = dx_j || dx_jal || dx_jr;
    assign flush_pipeline = (branch_taken || jump_taken) && !stall;

    //branch target: PC+1 + offset
    wire [31:0] branch_target;
    cla32 branch_adder(.A(dx_pc_plus1), .B(dx_br_offset), .Cin(1'b0), .S(branch_target), .Cout());

    //PC mux
    assign pc_in = stall ? pc_out : 
                   dx_jr ? bypass_readDataA : 
                   do_bex ? {5'b0, dx_target} :
                   branch_taken ? branch_target :
                   (dx_j || dx_jal) ? {5'b0, dx_target} : 
                   pc_plus1;
    //overflow
    wire overflow, overflow_add, overflow_addi, overflow_sub, overflow_mul, overflow_div;
    assign overflow_add = add & alu_overflow;
    assign overflow_addi = dx_addi && alu_overflow;
    assign overflow_sub = sub && alu_overflow;
    assign overflow_mul = doing_multdiv && mul && multdiv_exception && multdiv_ready;
    assign overflow_div = doing_multdiv && div && multdiv_exception && multdiv_ready;
    assign overflow = overflow_add || overflow_addi || overflow_sub || overflow_mul || overflow_div;

    wire [31:0] rstatus_val;
    assign rstatus_val = overflow_add ? 32'd1 : overflow_addi ? 32'd2 : overflow_sub  ? 32'd3 : overflow_mul  ? 32'd4 : overflow_div  ? 32'd5 : 32'd0;

    //determine write result and register destination
    wire [31:0] dx_writedata;
    wire [4:0] dx_writereg;
    assign dx_writedata = dx_lfsr                      ? lfsr_result        :
                          dx_setx                      ? {5'b0, dx_target}  :
                          overflow                     ? rstatus_val        :
                          dx_jal                       ? dx_pc_plus1        :
                          (doing_multdiv && multdiv_ready) ? multdiv_out    :
                                                         alu_out;
    assign dx_writereg = dx_setx ? 5'd30 :
                     overflow ? 5'd30 :
                     dx_jal ? 5'd31 :
                     (doing_multdiv && multdiv_ready) ? multdiv_dest :
                     (dx_rtype || dx_addi || dx_lw) ? dx_rd :
                     5'd0;
    wire dx_regwrite;
    assign dx_regwrite = dx_rtype || dx_addi || dx_lw || dx_jal || dx_setx || (doing_multdiv && multdiv_ready);

    //X/M
    wire [31:0] xm_alu_out, xm_storedata;
    wire [4:0] xm_rd;
    wire xm_regwrite, xm_sw, xm_lw;
    wire [31:0] xm_alu_in, xm_store_in;
    assign xm_alu_in = dx_writedata;
    assign xm_store_in = bypass_readDataB;
    wire [4:0] xm_rd_in;
    assign xm_rd_in = dx_writereg;
    wire xm_rw_in, xm_sw_in, xm_lw_in;
    assign xm_rw_in = dx_regwrite;
    assign xm_sw_in = dx_sw;
    assign xm_lw_in = dx_lw;

    register32 xm_result(.q(xm_alu_out), .d(xm_alu_in), .clk(~clock), .input_enable(1'b1), .clr(reset));
    register32 xm_store(.q(xm_storedata), .d(xm_store_in), .clk(~clock), .input_enable(1'b1), .clr(reset));

    //5-bit write register
    genvar i;
    generate
        for (i = 0; i < 5; i = i + 1) begin : xm_rd_loop
            dffe_ref xm_rd_ff(.q(xm_rd[i]), .d(xm_rd_in[i]), .clk(~clock), .en(1'b1), .clr(reset));
        end
    endgenerate

    //ALU XM bypass
    wire xm_bypass;
    assign xm_bypass = xm_regwrite && (xm_rd != 5'd0);

    wire [4:0] dx_readA_reg, dx_readB_reg;
    assign dx_readA_reg = dx_bex ? 5'd30 : (dx_jr || dx_bne || dx_blt) ? dx_rd : dx_rs;
    assign dx_readB_reg = dx_sw ? dx_rd : (dx_bne || dx_blt) ? dx_rs : dx_rt;
    wire xm_bypass_A, xm_bypass_B;
    assign xm_bypass_A = xm_bypass && (xm_rd == dx_readA_reg);
    assign xm_bypass_B = xm_bypass && (xm_rd == dx_readB_reg);

    //1-bit control signals
    dffe_ref xm_rw_ff(.q(xm_regwrite), .d(xm_rw_in), .clk(~clock), .en(1'b1), .clr(reset));
    dffe_ref xm_sw_ff(.q(xm_sw), .d(xm_sw_in), .clk(~clock), .en(1'b1), .clr(reset));
    dffe_ref xm_lw_ff(.q(xm_lw), .d(xm_lw_in), .clk(~clock), .en(1'b1), .clr(reset));

    //Data Mem
    assign address_dmem = xm_alu_out;
    assign data = xm_storedata;
    assign wren = xm_sw;

    //M/W
    wire [31:0] mw_alu_out;
    wire [31:0] mw_dmem;
    wire [4:0] mw_rd;
    wire mw_regwrite, mw_lw;

    register32 mw_result(.q(mw_alu_out), .d(xm_alu_out), .clk(~clock), .input_enable(1'b1), .clr(reset));
    //5 bit write register
    genvar j;
    generate
        for (j = 0; j < 5; j = j + 1) begin : mw_rd_loop
            dffe_ref mw_rd_ff(.q(mw_rd[j]), .d(xm_rd[j]), .clk(~clock), .en(1'b1), .clr(reset));
        end
    endgenerate

    //mw_dmem register that captures q_dmem as lw transitions from X/M to M/W
    register32 mw_dmem_reg(.q(mw_dmem), .d(q_dmem), .clk(~clock), .input_enable(1'b1), .clr(reset));

    //ALU MW bypass
    wire mw_bypass;
    assign mw_bypass = mw_regwrite && (mw_rd != 5'd0);

    //MW bypasses  if XM not bypassing
    wire mw_bypass_A, mw_bypass_B;
    assign mw_bypass_A = mw_bypass && (mw_rd == dx_readA_reg) && !xm_bypass_A;
    assign mw_bypass_B = mw_bypass && (mw_rd == dx_readB_reg) && !xm_bypass_B;

    //1-bit control signals
    dffe_ref mw_rw_ff(.q(mw_regwrite), .d(xm_regwrite), .clk(~clock), .en(1'b1), .clr(reset));
    dffe_ref mw_lw_ff(.q(mw_lw), .d(xm_lw), .clk(~clock), .en(1'b1), .clr(reset));

    //Writeback
    wire [31:0] mw_writedata, xm_bypass_val;
    assign mw_writedata = mw_lw ? mw_dmem : mw_alu_out;
    assign xm_bypass_val = xm_lw ? q_dmem : xm_alu_out;
    // Bypassed register read values
    assign bypass_readDataA = xm_bypass_A ? xm_bypass_val :
                                mw_bypass_A ? mw_writedata :
                                dx_readDataA;
    assign bypass_readDataB = xm_bypass_B ? xm_bypass_val :
                                mw_bypass_B ? mw_writedata :
                                dx_readDataB;
    assign data_writeReg = mw_writedata;
    assign ctrl_writeReg = mw_rd;
    assign ctrl_writeEnable = mw_regwrite && (mw_rd != 5'd0);
	/* END CODE */

endmodule