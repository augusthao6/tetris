module register32 (q, d, clk, input_enable, clr);
    input clk, input_enable, clr;
    input [31:0] d;
    output [31:0] q;

    genvar i;
    generate
        for (i=0; i<32; i=i+1) begin : dff_loop
            dffe_ref dff (.q(q[i]), .d(d[i]), .clk(clk), .en(input_enable), .clr(clr));
        end
    endgenerate
endmodule