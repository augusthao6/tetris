`timescale 1ns / 1ps

module booth_trace_tb;

    // Inputs
    reg [31:0] data_operandA;
    reg [31:0] data_operandB;
    reg ctrl_MULT;
    reg ctrl_DIV;
    reg clock;

    // Outputs
    wire [31:0] data_result;
    wire data_exception;
    wire data_resultRDY;

    // Instantiate the Unit Under Test (UUT)
    multdiv uut (
        .data_operandA(data_operandA), 
        .data_operandB(data_operandB), 
        .ctrl_MULT(ctrl_MULT), 
        .ctrl_DIV(ctrl_DIV), 
        .clock(clock), 
        .data_result(data_result), 
        .data_exception(data_exception), 
        .data_resultRDY(data_resultRDY)
    );

    // Clock generation
    initial begin
        clock = 0;
        forever #5 clock = ~clock; // 10ns period
    end

    // Variables for tracing
    integer cycle;
    reg [31:0] prev_p_high;
    reg [31:0] prev_p_low;
    reg prev_p_extra;

    // Test stimulus and trace
    initial begin
        // Initialize inputs
        data_operandA = 0;
        data_operandB = 0;
        ctrl_MULT = 0;
        ctrl_DIV = 0;
        cycle = 0;
        
        // Wait for initial setup
        #20;
        
        $display("================================================================================");
        $display("Booth's Multiplication Algorithm Trace: -2147483648 × -1");
        $display("================================================================================");
        $display("Multiplicand (M): -2147483648 (0x%h)", 32'h80000000);
        $display("Multiplier:       -1          (0x%h)", 32'hFFFFFFFF);
        $display("Expected Result:  2147483648 (overflow - exceeds 32-bit signed range)");
        $display("================================================================================");
        $display("");
        
        // Set up operands
        data_operandA = 32'h80000000; // -2147483648
        data_operandB = 32'hFFFFFFFF; // -1
        ctrl_MULT = 1;
        
        #10; // One clock cycle to latch inputs
        ctrl_MULT = 0;
        
        $display("Cycle | Booth | Action        | P_high (32 bits)        | P_low (32 bits)         | P_extra");
        $display("------|-------|---------------|-------------------------|-------------------------|--------");
        
        // Wait for completion while monitoring
        while (!uut.data_resultRDY) begin
            @(posedge clock);
            #1; // Small delay to let signals settle
            
            // Access internal signals for tracing
            $display("%5d | %b    | %-13s | %h | %h | %b",
                     cycle,
                     {uut.p_out_low[0], uut.p_out_extra},
                     get_action({uut.p_out_low[0], uut.p_out_extra}),
                     uut.p_out_high,
                     uut.p_out_low,
                     uut.p_out_extra);
            
            cycle = cycle + 1;
        end
        
        // Print final state
        @(posedge clock);
        #1;
        $display("%5d | %b    | %-13s | %h | %h | %b",
                 cycle,
                 {uut.p_out_low[0], uut.p_out_extra},
                 get_action({uut.p_out_low[0], uut.p_out_extra}),
                 uut.p_out_high,
                 uut.p_out_low,
                 uut.p_out_extra);
        $display("------|-------|---------------|-------------------------|-------------------------|--------");
        
        #10;
        
        $display("");
        $display("================================================================================");
        $display("Final Results:");
        $display("================================================================================");
        $display("64-bit Product:  {%h, %h}", uut.p_out_high, uut.p_out_low);
        $display("32-bit Result:   %h (%d)", data_result, $signed(data_result));
        $display("Upper 32 bits:   %h", uut.p_out_high);
        $display("Lower 32 bits:   %h", uut.p_out_low);
        $display("");
        $display("Overflow Analysis:");
        $display("------------------");
        $display("Result sign bit (bit 31):      %b", uut.p_out_low[31]);
        $display("Upper bits all zero:           %b", ~(|uut.p_out_high));
        $display("Upper bits all one:            %b", &uut.p_out_high);
        $display("");
        
        if (uut.p_out_low[31] == 1) begin
            $display("Result appears negative (bit 31 = 1)");
            $display("For proper sign extension, upper 32 bits should be: 0xFFFFFFFF");
            $display("Actual upper 32 bits:                                0x%h", uut.p_out_high);
            if (uut.p_out_high == 32'hFFFFFFFF) begin
                $display("✓ Proper sign extension - NO overflow");
            end else begin
                $display("✗ NOT proper sign extension - OVERFLOW DETECTED");
            end
        end else begin
            $display("Result appears positive (bit 31 = 0)");
            $display("For proper sign extension, upper 32 bits should be: 0x00000000");
            $display("Actual upper 32 bits:                                0x%h", uut.p_out_high);
            if (uut.p_out_high == 32'h00000000) begin
                $display("✓ Proper sign extension - NO overflow");
            end else begin
                $display("✗ NOT proper sign extension - OVERFLOW DETECTED");
            end
        end
        
        $display("");
        $display("Exception Flag: %b", data_exception);
        $display("Result Ready:   %b", data_resultRDY);
        $display("");
        
        if (data_exception == 1) begin
            $display("✓ PASS: Overflow correctly detected!");
            $display("   Explanation: -2147483648 × -1 = 2147483648");
            $display("   This exceeds the maximum 32-bit signed value (2147483647)");
        end else begin
            $display("✗ FAIL: Overflow NOT detected (expected exception = 1, got %b)", data_exception);
        end
        
        $display("================================================================================");
        
        #50;
        $finish;
    end
    
    // Function to decode Booth action
    function [103:0] get_action; // 13 characters * 8 bits
        input [1:0] booth_bits;
        begin
            case(booth_bits)
                2'b00: get_action = "No operation";
                2'b01: get_action = "Add M       ";
                2'b10: get_action = "Subtract M  ";
                2'b11: get_action = "No operation";
                default: get_action = "Unknown     ";
            endcase
        end
    endfunction

endmodule