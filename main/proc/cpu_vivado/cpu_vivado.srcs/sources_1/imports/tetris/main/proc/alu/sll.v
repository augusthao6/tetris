module barrel_shift_left (A, shiftamt, O);
    input [31:0] A;
    input [4:0] shiftamt;

    output [31:0] O;
    wire [31:0] s16, s8, s4, s2;

    assign s16 = shiftamt[4] ? {A[15:0], 16'b0} : A;
    assign s8 = shiftamt[3] ? {s16[23:0], 8'b0} : s16;
    assign s4 = shiftamt[2] ? {s8[27:0], 4'b0} : s8;
    assign s2 = shiftamt[1] ? {s4[29:0], 2'b0} : s4;
    assign O = shiftamt[0] ? {s2[30:0], 1'b0} : s2;
endmodule