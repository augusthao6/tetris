module regfile (
	clock,
	ctrl_writeEnable, ctrl_reset, ctrl_writeReg,
	ctrl_readRegA, ctrl_readRegB, data_writeReg,
	data_readRegA, data_readRegB
);

	input clock, ctrl_writeEnable, ctrl_reset;
	input [4:0] ctrl_writeReg, ctrl_readRegA, ctrl_readRegB;
	input [31:0] data_writeReg;

	output [31:0] data_readRegA, data_readRegB;

	wire [31:0] write_sel = ctrl_writeEnable << ctrl_writeReg;
    wire [31:0] read_selA = 32'b1 << ctrl_readRegA;
    wire [31:0] read_selB = 32'b1 << ctrl_readRegB;


	wire [31:0] reg_out [0:31];
	assign reg_out[0] = 32'b0;
	genvar i;
	generate
		for (i = 1; i < 32; i = i + 1) begin: register_loop
			register32 reg_inst(.q(reg_out[i]), .d(data_writeReg),.clk(clock), .input_enable(write_sel[i]), .clr(ctrl_reset));
		end
	endgenerate
	genvar j;
	generate
		for (j = 0; j < 32; j = j + 1) begin: tristate_loop
			tristate triA(.in(reg_out[j]), .oe(read_selA[j]), .out(data_readRegA));
			tristate triB(.in(reg_out[j]), .oe(read_selB[j]), .out(data_readRegB));
		end
	endgenerate
endmodule