module barrel_shifter_right(in, shift, out);
    input [31:0] in;
    input [4:0] shift;
    output [31:0] out;

    wire [31:0] s16, s8, s4, s2;
    wire fill = in[31];

    assign s16 = shift[4] ? {{16{fill}}, in[31:16]} : in;
    assign s8 = shift[3] ? {{8{fill}}, s16[31:8]} : s16;
    assign s4 = shift[2] ? {{4{fill}}, s8[31:4]} : s8;
    assign s2 = shift[1] ? {{2{fill}}, s4[31:2]} : s4;
    assign out = shift[0] ? {{1{fill}}, s2[31:1]} : s2;
endmodule