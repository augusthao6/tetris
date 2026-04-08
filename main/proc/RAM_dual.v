module RAM_dual #(
    parameter DATA_WIDTH = 32,
    parameter ADDRESS_WIDTH = 12,
    parameter DEPTH = 4096
)(
    input clk,
    input wEn,
    input [ADDRESS_WIDTH-1:0] addr_a,
    input [DATA_WIDTH-1:0] dataIn_a,
    output reg [DATA_WIDTH-1:0] dataOut_a,
    input [ADDRESS_WIDTH-1:0] addr_b,
    output reg [DATA_WIDTH-1:0] dataOut_b
);
    reg [DATA_WIDTH-1:0] mem [0:DEPTH-1];

    always @(negedge clk) begin
        if (wEn)
            mem[addr_a] <= dataIn_a;
        dataOut_a <= mem[addr_a];
        dataOut_b <= mem[addr_b];
    end
endmodule