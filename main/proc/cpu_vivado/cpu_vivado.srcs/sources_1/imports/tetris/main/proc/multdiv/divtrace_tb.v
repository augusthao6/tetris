`timescale 1ns/1ps

module divider_tb;

    // ---- DUT signals ----
    reg  [31:0] data_operandA;
    reg  [31:0] data_operandB;
    reg         ctrl_DIV;
    reg         clock;
    wire [31:0] data_result;
    wire        data_exception;
    wire        data_resultRDY;

    // ---- Instantiate DUT ----
    multdiv dut (
        .data_operandA(data_operandA),
        .data_operandB(data_operandB),
        .ctrl_DIV(ctrl_DIV),
        .clock(clock),
        .data_result(data_result),
        .data_exception(data_exception),
        .data_resultRDY(data_resultRDY)
    );

    // ---- Clock: 25 MHz → 40ns period ----
    initial clock = 0;
    always #20 clock = ~clock;

    // ---- Tracking ----
    integer test_num;
    integer pass_count;
    integer fail_count;
    integer total_cycles;

    // ---- Task: run one division and print every cycle ----
    task run_div;
        input [31:0] A;
        input [31:0] B;
        input [31:0] expected_result;
        input        expected_exception;
        input [63:0] test_id;

        integer cycle;
        reg     got_ready;
        reg [31:0] captured_result;
        reg        captured_exception;
    begin
        test_num = test_num + 1;
        $display("============================================================");
        $display("TEST %0d: A=%0d (0x%08h)  B=%0d (0x%08h)", 
                  test_id, $signed(A), A, $signed(B), B);
        $display("  Expected result=%0d  Expected exception=%0b",
                  $signed(expected_result), expected_exception);
        $display("------------------------------------------------------------");
        $display("  Cycle |      A (rq_high)       |      Q (rq_low)        | resultRDY | exception | result");

        // Assert ctrl_DIV for one cycle
        @(negedge clock);
        data_operandA = A;
        data_operandB = B;
        ctrl_DIV      = 1;
        @(negedge clock);
        ctrl_DIV      = 0;

        // Watch every rising edge until data_resultRDY
        got_ready = 0;
        cycle     = 0;
        captured_result    = 0;
        captured_exception = 0;

        repeat(70) begin
            @(posedge clock);
            #1; // tiny settle
            $display("  %5d | %12d (0x%08h) | %12d (0x%08h) |     %0b     |     %0b     | %0d",
                      cycle,
                      $signed(data_result), data_result,   // we don't have internal wires,
                      // so we show result twice; replace with internal probes if needed
                      $signed(data_result), data_result,
                      data_resultRDY,
                      data_exception,
                      $signed(data_result));
            if (data_resultRDY && !got_ready) begin
                got_ready          = 1;
                captured_result    = data_result;
                captured_exception = data_exception;
            end
            cycle = cycle + 1;
        end

        // Verdict
        $display("------------------------------------------------------------");
        if (!got_ready) begin
            $display("  FAIL: data_resultRDY never asserted!");
            fail_count = fail_count + 1;
        end else if (expected_exception) begin
            // For exceptions, only check the exception flag
            if (captured_exception === expected_exception) begin
                $display("  PASS: exception correctly asserted");
                pass_count = pass_count + 1;
            end else begin
                $display("  FAIL: exception=%0b  expected=%0b",
                          captured_exception, expected_exception);
                fail_count = fail_count + 1;
            end
        end else begin
            if (captured_result === expected_result && captured_exception === expected_exception) begin
                $display("  PASS: result=%0d  exception=%0b",
                          $signed(captured_result), captured_exception);
                pass_count = pass_count + 1;
            end else begin
                $display("  FAIL: got result=%0d exception=%0b | expected result=%0d exception=%0b",
                          $signed(captured_result), captured_exception,
                          $signed(expected_result), expected_exception);
                fail_count = fail_count + 1;
            end
        end
        $display("============================================================");
        $display("");
    end
    endtask

    // ---- Main test sequence ----
    initial begin
        // Init
        data_operandA = 0;
        data_operandB = 0;
        ctrl_DIV      = 0;
        test_num      = 0;
        pass_count    = 0;
        fail_count    = 0;

        // Let reset settle
        repeat(4) @(negedge clock);

        $display("");
        $display("####################################################");
        $display("#          DIVIDER FULL TRACE TESTBENCH            #");
        $display("####################################################");
        $display("");

        // ---- Basic sanity ----
        run_div(32'd7,   32'd3,   32'd2,              0, 1);   // 7/3 = 2
        run_div(32'd0,   32'd3,   32'd0,              0, 2);   // 0/3 = 0
        run_div(32'd1,   32'd1,   32'd1,              0, 3);   // 1/1 = 1

        // ---- From autograder basic division tests ----
        run_div(32'd1,             32'd0,            32'd0,              1, 4);   // div by zero → exception
        run_div(32'd2,             32'd1,            32'd2,              0, 5);
        run_div(-32'd4,            32'd2,            -32'd2,             0, 6);
        run_div(32'd8,             32'd4,            32'd2,              0, 7);
        run_div(32'd16,            -32'd8,           -32'd2,             0, 8);
        run_div(32'd32,            32'd16,           32'd2,              0, 9);
        run_div(-32'd64,           32'd32,           -32'd2,             0, 10);
        run_div(32'd128,           32'd64,           32'd2,              0, 11);
        run_div(32'd256,           -32'd128,         -32'd2,             0, 12);
        run_div(32'd512,           32'd256,          32'd2,              0, 13);
        run_div(-32'd1024,         32'd512,          -32'd2,             0, 14);
        run_div(32'd2048,          32'd1024,         32'd2,              0, 15);
        run_div(32'd4096,          -32'd2048,        -32'd2,             0, 16);
        run_div(32'd8192,          32'd4096,         32'd2,              0, 17);
        run_div(-32'd16384,        32'd8192,         -32'd2,             0, 18);
        run_div(32'd32768,         32'd16384,        32'd2,              0, 19);
        run_div(32'h80000000,      32'd2,            32'hC0000000,       0, 20); // -2147483648/2

        // ---- Divide by zero tests ----
        run_div(-32'd282475249,    32'd0,            32'd0,              1, 21);
        run_div(-32'd7,            32'd0,            32'd0,              1, 22);
        run_div(32'd0,             32'd0,            32'd0,              1, 23);
        run_div(32'd7,             32'd0,            32'd0,              1, 24);
        run_div(32'd282475249,     32'd0,            32'd0,              1, 25);

        // ---- Comprehensive division tests ----
        run_div(-32'd282475249,    -32'd282475249,   32'd1,              0, 26);
        run_div(-32'd282475249,    -32'd7,           32'd40353607,       0, 27);
        run_div(-32'd282475249,    32'd7,            -32'd40353607,      0, 28);
        run_div(-32'd282475249,    32'd282475249,    -32'd1,             0, 29);
        run_div(-32'd7,            -32'd7,           32'd1,              0, 30);
        run_div(-32'd7,            32'd7,            -32'd1,             0, 31);
        run_div(32'd7,             -32'd7,           -32'd1,             0, 32);
        run_div(32'd7,             32'd7,            32'd1,              0, 33);
        run_div(32'd282475249,     -32'd282475249,   -32'd1,             0, 34);
        run_div(32'd282475249,     -32'd7,           -32'd40353607,      0, 35);
        run_div(32'd282475249,     32'd7,            32'd40353607,       0, 36);
        run_div(32'd282475249,     32'd282475249,    32'd1,              0, 37);
        run_div(-32'd1299827,      -32'd1299827,     32'd1,              0, 38);
        run_div(-32'd1299827,      -32'd7,           32'd185689,         0, 39);
        run_div(-32'd1299827,      32'd7,            -32'd185689,        0, 40);
        run_div(-32'd1299827,      32'd1299821,      -32'd1,             0, 41);
        run_div(32'd1299821,       -32'd7,           -32'd185688,        0, 42);
        run_div(32'd1299821,       32'd7,            32'd185688,         0, 43);
        run_div(32'd1299821,       32'd1299821,      32'd1,              0, 44);

        // ---- Edge cases ----
        run_div(32'd1,             32'd2,            32'd0,              0, 45);  // 1/2 = 0 (truncate)
        run_div(-32'd1,            32'd2,            32'd0,              0, 46);  // -1/2 = 0
        run_div(32'h7FFFFFFF,      32'd1,            32'h7FFFFFFF,       0, 47);  // MAX_INT / 1
        run_div(32'h80000000,      -32'd1,           32'h80000000,       0, 48);  // MIN_INT / -1 (overflow edge)
        run_div(32'h7FFFFFFF,      32'h7FFFFFFF,     32'd1,              0, 49);  // same / same
        run_div(32'd100,           32'd7,            32'd14,             0, 50);  // 100/7 = 14

        // ---- Summary ----
        $display("####################################################");
        $display("  RESULTS: %0d passed, %0d failed out of %0d tests",
                  pass_count, fail_count, test_num);
        $display("####################################################");
        $finish;
    end

endmodule