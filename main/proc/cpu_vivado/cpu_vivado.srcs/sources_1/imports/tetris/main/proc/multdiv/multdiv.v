module multdiv(
	data_operandA, data_operandB, 
	ctrl_MULT, ctrl_DIV, 
	clock, 
	data_result, data_exception, data_resultRDY);

    input [31:0] data_operandA, data_operandB;
    input ctrl_MULT, ctrl_DIV, clock;

    output [31:0] data_result;
    output data_exception, data_resultRDY;

    //mult
    wire [31:0] multiplicand, multiplier;
    register32 regA(.q(multiplicand), .d(data_operandB), .clk(clock), .input_enable(ctrl_MULT), .clr(1'b0));
    register32 regB(.q(multiplier), .d(data_operandA), .clk(clock), .input_enable(ctrl_MULT), .clr(1'b0));

    //div
    wire [31:0] notA;
    assign notA = ~data_operandA;
    wire [31:0] notB;
    assign notB = ~data_operandB;
    wire [31:0] absA, absB;
    cla32 twoscompA(.A(notA), .B(32'd0), .Cin(1'b1), .S(absA), .Cout());
    cla32 twoscompB(.A(notB), .B(32'd0), .Cin(1'b1), .S(absB), .Cout());

    wire [31:0] unsigned_dividend;
    assign unsigned_dividend = data_operandA[31] ? absA : data_operandA;
    wire [31:0] unsigned_divisor;
    assign unsigned_divisor = data_operandB[31] ? absB : data_operandB;

    //latch sign and unsigned data on ctrl_DIV
    wire [31:0] latch_udividend, latch_udivisor;
    wire dividend_sign, divisor_sign;
    register32 reg_udividend (.q(latch_udividend), .d(unsigned_dividend), .clk(clock), .input_enable(ctrl_DIV), .clr(1'b0));
    register32 reg_udivisor(.q(latch_udivisor),  .d(unsigned_divisor),  .clk(clock), .input_enable(ctrl_DIV), .clr(1'b0));
    dffe_ref reg_sdividend(.q(dividend_sign), .d(data_operandA[31]), .clk(clock), .en(ctrl_DIV), .clr(1'b0));
    dffe_ref reg_sdivisor(.q(divisor_sign), .d(data_operandB[31]),  .clk(clock), .en(ctrl_DIV), .clr(1'b0));
    wire [31:0] latch_udivisor_inv = ~latch_udivisor;
    wire [31:0] neg_latch_udivisor;
    cla32 neg_div(.A(latch_udivisor_inv), .B(32'd0), .Cin(1'b1), .S(neg_latch_udivisor), .Cout());

    //control logic
    wire dividing;
    wire dividing_next = ctrl_DIV ? 1'b1 : (ctrl_MULT ? 1'b0 : dividing);
    dffe_ref dividing_reg(.q(dividing), .d(dividing_next), .clk(clock), .en(1'b1), .clr(1'b0));

    //counter
    wire is_busy;
    wire [31:0] current_count, incremented_count, next_count_val;
    cla32 count_adder(.A(current_count), .B(32'b0), .Cin(1'b1), .S(incremented_count));
    
    wire mult_count_done;
    assign mult_count_done = current_count[5] & ~dividing_next; //32
    wire div_count_done, div_iter_done;
    assign div_iter_done = current_count[5] & ~current_count[0] & dividing_next; //32
    assign div_count_done = current_count[5] & current_count[0] & dividing_next; //33 = 32 + restore
    wire count_done;
    assign count_done = mult_count_done | div_count_done;
    
    wire start;
    assign start = (ctrl_MULT | ctrl_DIV);  //only start if not already busy
    wire busy_d;
    assign busy_d = (is_busy & ~count_done) | start;
    assign next_count_val = start ? 32'b0 : incremented_count;
    dffe_ref busy_state(.q(is_busy), .d(busy_d), .clk(clock), .en(1'b1), .clr(1'b0));
    
    wire count_enable;
    assign count_enable = start | (is_busy & ~count_done);
    register32 count_reg(.q(current_count), .d(next_count_val), .clk(clock), .input_enable(count_enable), .clr(1'b0));

    //mult logic:
    wire [31:0] p_out_high;
    wire [31:0] p_out_low;
    wire p_out_extra;

    wire [1:0] booth;
    assign booth = {p_out_low[0], p_out_extra};

    //booth decoding 01 = +M, 10 = -M, 00 and 11 = do nothing
    wire add, sub;
    assign add = ~booth[1] & booth[0];
    assign sub = booth[1] & ~booth[0];
    wire do_op;
    assign do_op = add | sub;

    //precompute -M
    wire [31:0] M;
    assign M = multiplicand;
    wire [31:0] M_inverted;
    assign M_inverted = ~M;
    wire [31:0] M_neg;
    cla32 negM(.A(M_inverted), .B(32'd0), .Cin(1'b1), .S(M_neg), .Cout());

    //add
    wire [31:0] upper;
    assign upper = p_out_high;
    wire [31:0] Bsel;
    assign Bsel = sub ? M_neg : M;

    wire [31:0] sum;
    wire carry_out;

    cla32 upper_add(.A(upper), .B(Bsel), .Cin(1'b0), .S(sum), .Cout(carry_out));

    wire [31:0] next_upper;
    assign next_upper = do_op ? sum : upper;

    //right shift
    wire [64:0] full_before_shift;
    assign full_before_shift = {next_upper, p_out_low, p_out_extra};
    wire [64:0] full_shifted;
    assign full_shifted = {full_before_shift[64], full_before_shift[64:1]};

    wire [31:0] p_high_next;
    assign p_high_next = ctrl_MULT ? 32'd0 : full_shifted[64:33];
    wire [31:0] p_low_next;
    assign p_low_next = ctrl_MULT ? data_operandA : full_shifted[32:1];
    wire p_extra_next;
    assign p_extra_next = ctrl_MULT ? 1'b0 : full_shifted[0];

    //update p on ctrl_MULT or while busy
    wire mult_reg_en = start | (is_busy & ~count_done);
    register32 p_high(.q(p_out_high), .d(p_high_next), .clk(clock), .input_enable(mult_reg_en), .clr(1'b0));
    register32 p_low(.q(p_out_low), .d(p_low_next), .clk(clock), .input_enable(mult_reg_en), .clr(1'b0));
    dffe_ref p_extra(.q(p_out_extra), .d(p_extra_next), .clk(clock), .en(mult_reg_en), .clr(1'b0));

    //div logic:
    wire [31:0] r, q;
    wire [63:0] rq;
    assign rq = {r, q};

    //sign bit of R: 0 = -M, 1 = +M
    wire r_sign;
    assign r_sign = r[31];

    //shift left RQ
    wire [63:0] rq_shifted;
    assign rq_shifted = {r[30:0], q, 1'b0};

    //+M if r_sign negative, -M if r_sign positive
    wire [31:0] todo;
    assign todo = r_sign ? latch_udivisor : neg_latch_udivisor;
    wire [31:0] new_R;
    cla32 iter_add(.A(rq_shifted[63:32]), .B(todo), .Cin(1'b0), .S(new_R), .Cout());

    //Set Q(0)=1 if R[31]=0, Q(0)=0 if R[31]=1
    wire new_Q_bit;
    assign new_Q_bit = ~new_R[31];
    wire [31:0] new_Q;
    assign new_Q = {rq_shifted[31:1], new_Q_bit};

    //Final restore cycle: if R[31]=1 after 32 cycles, add back +M
    wire [31:0] R_restore;
    cla32 restore(.A(new_R), .B(latch_udivisor), .Cin(1'b0), .S(R_restore), .Cout());
    wire [31:0] final_R;
    assign final_R = new_R[31] ? R_restore : new_R;

    //div registers
    //Mux between: init (start=1), iteration(is_busy & ~div_iter_done & ~div_count_done), final restore (div_iter_done & !count_done)
    wire [31:0] r_next;
    assign r_next = start ? 32'b0 : //init
                    div_iter_done ? final_R : //final restore
                    new_R; //iter
    wire [31:0] q_next;
    assign q_next = start ? unsigned_dividend : //init
                    div_iter_done ? q : //final restore doesn't change Q
                    new_Q; //iter

    wire div_reg_en;
    assign div_reg_en = start | (is_busy & ~count_done);

    register32 reg_r(.q(r), .d(r_next), .clk(clock), .input_enable(div_reg_en), .clr(1'b0));
    register32 reg_q(.q(q), .d(q_next), .clk(clock), .input_enable(div_reg_en), .clr(1'b0));

    //sign correct for quotient
    wire quotient_negative;
    assign quotient_negative = dividend_sign ^ divisor_sign;
    wire [31:0] quotient_inv;
    assign quotient_inv = ~q;
    wire [31:0] quotient_neg;
    cla32 neg_q(.A(quotient_inv), .B(32'd0), .Cin(1'b1), .S(quotient_neg), .Cout());
    wire [31:0] final_quotient = quotient_negative ? quotient_neg : q;

    //outputs
    assign data_result = dividing ? final_quotient : p_out_low;

    //exception overflow detection
    wire result_sign;
    assign result_sign = p_out_low[31];
    wire upper_all_zero;
    assign upper_all_zero = ~(|p_out_high);
    wire upper_all_one;
    assign upper_all_one = &p_out_high;
    wire proper_sign_extension;
    assign proper_sign_extension = result_sign ? upper_all_one : upper_all_zero;
    wire inputs_same_sign;
    assign inputs_same_sign = ~(multiplicand[31] ^ multiplier[31]);
    wire result_is_zero;
    assign result_is_zero = ~(|p_out_high) & ~(|p_out_low);
    wire expected_positive;
    assign expected_positive = inputs_same_sign & ~result_is_zero;
    wire expected_negative;
    assign expected_negative = ~inputs_same_sign & ~result_is_zero;
    wire sign_overflow;
    assign sign_overflow = expected_positive & result_sign & upper_all_one;

    wire mult_exception;
    assign mult_exception = mult_count_done & (~proper_sign_extension | sign_overflow);

    //divide by zero exception
    wire divide_by_zero;
    assign divide_by_zero = ~(|latch_udivisor);
    wire div_overflow;
    assign div_overflow = latch_udividend[31] & ~(|latch_udividend[30:0]) & ~(|latch_udivisor[31:1]) & latch_udivisor[0];
    wire div_exception;
    assign div_exception = div_count_done & (divide_by_zero | div_overflow);
    
    assign data_exception = mult_exception | div_exception;
    assign data_resultRDY = count_done;
endmodule