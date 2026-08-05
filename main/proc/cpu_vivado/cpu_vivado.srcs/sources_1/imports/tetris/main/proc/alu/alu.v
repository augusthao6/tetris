module alu(data_operandA, data_operandB, ctrl_ALUopcode, ctrl_shiftamt, data_result, isNotEqual, isLessThan, overflow);
        
    input [31:0] data_operandA, data_operandB;
    input [4:0] ctrl_ALUopcode, ctrl_shiftamt;

    output [31:0] data_result;
    output isNotEqual, isLessThan, overflow;

    //read opcode
    wire op_add, op_sub, op_and, op_or, op_sll, op_sra;
    wire op0, op1, op2, op3, op4;
    assign op0 = ctrl_ALUopcode[0];
    assign op1 = ctrl_ALUopcode[1];
    assign op2 = ctrl_ALUopcode[2];
    assign op3 = ctrl_ALUopcode[3];
    assign op4 = ctrl_ALUopcode[4];
    
    //not for subtract
    wire not0, not1, not2, not3, not4;
    not(not0, ctrl_ALUopcode[0]);
    not(not1, ctrl_ALUopcode[1]);
    not(not2, ctrl_ALUopcode[2]);
    not(not3, ctrl_ALUopcode[3]);
    not(not4, ctrl_ALUopcode[4]);

    and check_add(op_add, not4, not3, not2, not1, not0); //00000
    and check_sub(op_sub, not4, not3, not2, not1, op0); //00001
    and check_and(op_and, not4, not3, not2, op1, not0); //00010
    and check_or(op_or, not4, not3, not2, op1, op0); //00011
    and check_sll(op_sll, not4, not3, op2, not1, not0); //00100
    and check_sra(op_sra, not4, not3, op2, not1, op0); //00101

    //get B, not B if subtract
    wire [31:0] B;
    genvar i;
    generate
        for (i=0; i<32; i=i+1) begin : B_loop
            xor subb(B[i], data_operandB[i], op_sub); //flip B for subtract
        end
    endgenerate

    //add
    wire [31:0] sum_out;
    wire cout_adder;
    cla32 adder(.A(data_operandA), .B(B), .Cin(op_sub), .S(sum_out), .Cout(cout_adder));

    //AND and OR
    wire [31:0] and_out, or_out;
    and32 and_inst(.A(data_operandA), .B(data_operandB), .Y(and_out));
    or32  or_inst(.A(data_operandA), .B(data_operandB), .Y(or_out));

    //shift left logical, shift right arithmetic
    wire [31:0] sll_out, sra_out;
    barrel_shift_left sll_inst(.A(data_operandA), .shiftamt(ctrl_shiftamt), .O(sll_out));
    barrel_shifter_right sra_inst(.in(data_operandA), .shift(ctrl_shiftamt), .out(sra_out));

    //mux result
    assign data_result = op_add ? sum_out : op_sub ? sum_out :
                         op_and ? and_out : op_or  ? or_out  : 
                         op_sll ? sll_out : op_sra ? sra_out :
                         32'b0;
    
    //isNotEqual, check if any bit in sum_out is 1, or all bits, isNotEqual = 0 if notequal[31] = 0
    wire [31:0] notequal;
    assign notequal[0] = sum_out[0];
    generate
        for (i=1; i<32; i=i+1) begin : or_loop
            or (notequal[i], notequal[i-1], sum_out[i]);
        end
    endgenerate
    assign isNotEqual = notequal[31];

    //Overflow two numbers same sign and sum not same sign MSB: (A[31] == B[31]) && (Sum[31] != A[31])
    wire same_sign, different_result_sign;
    xnor (same_sign, data_operandA[31], B[31]);
    xor (different_result_sign, sum_out[31], data_operandA[31]);
    wire arith_overflow, is_arith;
    and (arith_overflow, same_sign, different_result_sign);
    or (is_arith, op_add, op_sub);
    assign overflow = is_arith ? arith_overflow : 1'b0;

    //isLessThan = A<B, MSB sum_out ^ overflow
    xor (isLessThan, sum_out[31], arith_overflow);
endmodule