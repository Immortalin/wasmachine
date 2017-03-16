`include "assert.vh"


module cpu_tb();

  reg         clk   = 0;
  reg         reset = 0;
  wire [63:0] result;
  wire        result_empty;
  wire [ 2:0] trap;

  cpu #(
    .ROM_FILE("i64.eqz1.hex"),
    .ROM_ADDR(4)
  )
  dut
  (
    .clk(clk),
    .reset(reset),
    .result(result),
    .result_empty(result_empty),
    .trap(trap)
  );

  always #1 clk = ~clk;

  initial begin
    $dumpfile("i64.eqz1_tb.vcd");
    $dumpvars(0, cpu_tb);

    #30
    `assert(result, 1);
    `assert(result_empty, 0);

    $display("ok");
    $finish;
  end

endmodule