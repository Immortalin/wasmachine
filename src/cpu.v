`include "cpu.vh"

`include "opcodes.vh"
`include "SuperStack.vh"


`default_nettype none

module cpu
#(
  parameter MEM_DEPTH   = 3,
  parameter STACK_DEPTH = 7,

  parameter HAS_FPU = 1,
  parameter HAS_RAM = 1,
  parameter USE_64B = 1
)
(
  input clk,
  input reset,

  // Status
  input  wire [  MEM_DEPTH:0] pc,
  input  wire [STACK_DEPTH:0] index,
  output reg  [          3:0] trap = `NONE,

  // Memory
  output reg [     MEM_DEPTH  :0] mem_addr,
  output reg [     MEM_EXTRA-1:0] mem_extra,
  input      [8*2**MEM_EXTRA-1:0] mem_data,
  input                           mem_error,

  // Stack status
  input  wire                      pushStack,
  input  wire [2+DATA_WIDTH_MSB:0] stack_in,
  output wire [  DATA_WIDTH_MSB:0] result,
  output wire [               1:0] result_type,
  output wire                      result_empty
);

  localparam DATA_WIDTH     = USE_64B ? 64 : 32;
  localparam DATA_WIDTH_MSB = DATA_WIDTH-1;

  localparam MEM_EXTRA = $clog2(11);

  // Stack
  // TODO Remove useless bits when not using FPU or 64 bits data
  localparam STACK_WIDTH = 2+DATA_WIDTH;

  reg  [            2:0] stack_op;
  reg  [STACK_WIDTH-1:0] stack_data;
  reg  [STACK_DEPTH  :0] stack_offset;
  reg  [STACK_DEPTH  :0] stack_underflow = 0;
  reg  [STACK_DEPTH  :0] stack_upper = 0;
  reg  [STACK_DEPTH  :0] stack_lower = 0;
  reg                    stack_dropTos;
  wire [STACK_DEPTH  :0] stack_index;
  wire [STACK_WIDTH-1:0] stack_out;
  wire [STACK_WIDTH-1:0] stack_out1;
  wire [STACK_WIDTH-1:0] stack_out2;
  wire [            2:0] stack_status;

  SuperStack #(
    .WIDTH(STACK_WIDTH),
    .DEPTH(STACK_DEPTH)
  )
  stack (
    .clk(clk),
    .reset(reset),
    .op(stack_op),
    .data(stack_data),
    .offset(stack_offset),
    .underflow_limit(stack_underflow),
    .upper_limit(stack_upper),
    .lower_limit(stack_lower),
    .dropTos(stack_dropTos),
    .index(stack_index),
    .out(stack_out),
    .out1(stack_out1),
    .out2(stack_out2),
    .status(stack_status)
  );

  // Block stack
  localparam UNDERFLOW_L = 0;
  localparam UNDERFLOW_H = UNDERFLOW_L + STACK_DEPTH;
  localparam INDEX_L     = UNDERFLOW_H + 1;
  localparam INDEX_H     = INDEX_L     + STACK_DEPTH;
  localparam PC_L        = INDEX_H     + 1;
  localparam PC_H        = PC_L        + MEM_DEPTH;
  localparam RETURN_L    = PC_H        + 1;
  localparam RETURN_H    = RETURN_L    + 6;

  localparam TYPE_L = RETURN_H+1;
  localparam TYPE_H = TYPE_L  +1;

  localparam BLOCK_STACK_WIDTH = TYPE_H+1;
  localparam BLOCK_STACK_DEPTH = 3;

  reg  [                  2:0] blockStack_op;
  reg  [BLOCK_STACK_WIDTH-1:0] blockStack_data;
  reg  [BLOCK_STACK_DEPTH  :0] blockStack_offset;
  reg  [BLOCK_STACK_DEPTH  :0] blockStack_underflow = 0;
  reg  [BLOCK_STACK_DEPTH  :0] blockStack_lower = 0;
  wire [BLOCK_STACK_DEPTH  :0] blockStack_index;
  wire [BLOCK_STACK_WIDTH-1:0] blockStack_out;
  wire [                  2:0] blockStack_status;

  SuperStack #(
    .WIDTH(BLOCK_STACK_WIDTH),
    .DEPTH(BLOCK_STACK_DEPTH)
  )
  blockStack (
    .clk(clk),
    .reset(reset),
    .op(blockStack_op),
    .data(blockStack_data),
    .offset(blockStack_offset),
    .underflow_limit(blockStack_underflow),
    .upper_limit(blockStack_underflow),
    .lower_limit(blockStack_lower),
    .index(blockStack_index),
    .out(blockStack_out),
    .status(blockStack_status)
  );

  // Call stack
  localparam LOWER_L           = RETURN_H          + 1;
  localparam LOWER_H           = LOWER_L           + STACK_DEPTH;
  localparam UPPER_L           = LOWER_H           + 1;
  localparam UPPER_H           = UPPER_L           + STACK_DEPTH;
  localparam BLOCK_UNDERFLOW_L = UPPER_H           + 1;
  localparam BLOCK_UNDERFLOW_H = BLOCK_UNDERFLOW_L + BLOCK_STACK_DEPTH;
  localparam BLOCK_INDEX_L     = BLOCK_UNDERFLOW_H + 1;
  localparam BLOCK_INDEX_H     = BLOCK_INDEX_L     + BLOCK_STACK_DEPTH;

  localparam CALL_STACK_WIDTH = BLOCK_INDEX_H+1;
  localparam CALL_STACK_DEPTH = 1;

  reg  [                 1:0] callStack_op;
  reg  [CALL_STACK_WIDTH-1:0] callStack_data;
  wire [CALL_STACK_WIDTH-1:0] callStack_out;
  wire [                 1:0] callStack_status;

  stack #(
    .WIDTH(CALL_STACK_WIDTH),
    .DEPTH(CALL_STACK_DEPTH)
  )
  callStack (
    .clk(clk),
    .reset(reset),
    .op(callStack_op),
    .data(callStack_data),
    .tos(callStack_out),
    .status(callStack_status)
  );

  // LEB128 - decoder of `varintN` values
  wire[DATA_WIDTH_MSB:0] leb128_out;
  wire[             3:0] leb128_len;  // TODO number of bits

  if(USE_64B)
    unpack_i64 leb128(mem_data[79:72], mem_data[71:64], mem_data[63:56],
                      mem_data[55:48], mem_data[47:40], mem_data[39:32],
                      mem_data[31:24], mem_data[23:16], mem_data[15: 8],
                      mem_data[ 7: 0], leb128_out, leb128_len);
  else
    unpack_i32 leb128(mem_data[79:72], mem_data[71:64], mem_data[63:56],
                      mem_data[55:48], mem_data[47:40], leb128_out, leb128_len);

  // Double to Float
  wire        double_to_float_a_ack;
  reg         double_to_float_a_stb;
  wire [31:0] double_to_float_z;
  wire        double_to_float_z_stb;
  reg         double_to_float_z_ack;

  if(HAS_FPU && USE_64B)
    double_to_float d2f(
      .clk(clk),
      .rst(reset),
      .input_a_ack(double_to_float_a_ack),
      .input_a(stack_out_64),
      .input_a_stb(double_to_float_a_stb),
      .output_z(double_to_float_z),
      .output_z_stb(double_to_float_z_stb),
      .output_z_ack(double_to_float_z_ack)
    );


  //
  // Continuous assignments & wire aliases
  //

  // Result output
  assign result       = stack_out_64;
  assign result_type  = stack_out_type;
  assign result_empty = stack_status == `EMPTY;

  // ROM
  wire[ 7:0] mem_data_opcode = mem_data[87:80];

  wire[MEM_DEPTH:0] mem_data_PC = mem_data[71:40];

  wire[MEM_DEPTH:0] mem_data_functionAddress = mem_data[103:72];
  wire[        6:0] mem_data_returnType      = mem_data[ 70:64];  // High bit dropped
  wire[MEM_DEPTH:0] mem_data_arguments       = mem_data[ 63:32];
  wire[MEM_DEPTH:0] mem_data_localEntries    = mem_data[ 31: 0];

  // Stack
  wire[ 1:0] stack_out_type = stack_out[DATA_WIDTH+1:DATA_WIDTH];
  wire[63:0] stack_out_64   = stack_out[63:0];
  wire[31:0] stack_out_32   = stack_out[31:0];

  // Block stack
  wire[          1:0] blockStack_out_type       = blockStack_out[     TYPE_H:     TYPE_L];
  wire[          6:0] blockStack_out_returnType = blockStack_out[   RETURN_H:   RETURN_L];
  wire[  MEM_DEPTH:0] blockStack_out_PC         = blockStack_out[       PC_H:       PC_L];
  wire[STACK_DEPTH:0] blockStack_out_index      = blockStack_out[    INDEX_H:    INDEX_L];
  wire[STACK_DEPTH:0] blockStack_out_underflow  = blockStack_out[UNDERFLOW_H:UNDERFLOW_L];

  // Call stack
  wire[BLOCK_STACK_DEPTH:0] callStack_out_blockIndex     = callStack_out[    BLOCK_INDEX_H:    BLOCK_INDEX_L];
  wire[BLOCK_STACK_DEPTH:0] callStack_out_blockUnderflow = callStack_out[BLOCK_UNDERFLOW_H:BLOCK_UNDERFLOW_L];
  wire[      STACK_DEPTH:0] callStack_out_upper          = callStack_out[          UPPER_H:          UPPER_L];
  wire[      STACK_DEPTH:0] callStack_out_lower          = callStack_out[          LOWER_H:          LOWER_L];
  wire[                6:0] callStack_out_returnType     = callStack_out[         RETURN_H:         RETURN_L];
  wire[               31:0] callStack_out_PC             = callStack_out[             PC_H:             PC_L];
  wire[      STACK_DEPTH:0] callStack_out_index          = callStack_out[          INDEX_H:          INDEX_L];
  wire[      STACK_DEPTH:0] callStack_out_underflow      = callStack_out[      UNDERFLOW_H:      UNDERFLOW_L];

  //
  // CPU internal status
  //

  localparam FETCH  = 3'b000;
  localparam FETCH2 = 3'b001;
  localparam EXEC   = 3'b010;
  localparam EXEC2  = 3'b011;
  localparam EXEC3  = 3'b100;
  localparam EXEC4  = 3'b101;
  localparam EXEC5  = 3'b110;

  reg [        2:0] step = FETCH;
  reg [MEM_DEPTH:0] PC   = 0;
  reg [        7:0] opcode;

  reg [MEM_DEPTH:0] brTable_offset, brTable_offset2;
  reg [MEM_DEPTH:0] call_PC;


  //
  // Tasks
  //

  task call_return;
    // Main call (`start`, `export`), return results and halt
    if(callStack_status == `EMPTY)
      trap <= `ENDED;

    // Returning from a function call
    else begin
      // Reset blocks stack
      blockStack_offset    <= callStack_out_blockIndex;
      blockStack_underflow <= callStack_out_blockUnderflow;
      blockStack_op        <= `INDEX_RESET;

      stack_upper <= callStack_out_upper;
      stack_lower <= callStack_out_lower;

      block_return(callStack_out, 1);
    end
  endtask

  task block_return;
    input [RETURN_H:UNDERFLOW_L] stackSlice;
    input isCallReturn;

    reg [STACK_WIDTH-1:0] data;
    data = (opcode == `op_br_if) ? stack_out1 : stack_out;

    // Set program counter to next instruction after block or function call
    PC <= stackSlice[PC_H:PC_L];

    // Reset main stack
    if(isCallReturn) begin
      callStack_op   <= `POP;
      callStack_data <= 0;
    end
    else begin
      blockStack_op   <= `POP;
      blockStack_data <= 0;
    end

    stack_offset    <= stackSlice[    INDEX_H:    INDEX_L];
    stack_underflow <= stackSlice[UNDERFLOW_H:UNDERFLOW_L];

    // Check type and set result value
    // TODO "At the end of the block the remaining inner operands must match the
    // block signature". Should we check and use the actual stack status instead
    // of the expected output? Are we in fact relocating the stack data, or are
    // we just overwritting it?
    if(stackSlice[RETURN_H:RETURN_L] == 7'h40)
      stack_op <= `INDEX_RESET;

    else if(7'h7f - stackSlice[RETURN_H:RETURN_L] == data[DATA_WIDTH+1:DATA_WIDTH]) begin
      stack_op   <= `INDEX_RESET_AND_PUSH;
      stack_data <= data;
    end

    else
      trap <= `TYPE_MISMATCH;
  endtask

  task block_loop_back;
    // Go back to loop begin
    PC <= blockStack_out_PC;

    // Reset the stack
    stack_op     <= `INDEX_RESET;
    stack_offset <= blockStack_out_index;
  endtask

  task block_break;
    input [MEM_DEPTH:0] depth;

    // Breaking out from the root of a function
    if(blockStack_status == `EMPTY) begin
      // We can't break out beyond functions, raise error
      if(depth)
        trap <= `BLOCK_STACK_EMPTY;

      else
        call_return();
    end

    // Break to outter block, remove inner ones first
    else if(depth) begin
      blockStack_op   <= `POP;
      blockStack_data <= depth-1;  // Remove all slices except the desired one

      step <= (opcode == `op_br_table) ? EXEC4 : EXEC2;
    end

    // Current block
    else
      block_break2();
  endtask

  task block_break2;
    if(blockStack_status == `EMPTY)
      call_return();

    else
      case (blockStack_out_type)
        `block,
        `block_if  : block_return(blockStack_out, 0);
        `block_loop: block_loop_back();

        default:
          trap <= `BAD_BLOCK_TYPE;
      endcase
  endtask

  task block_add;
    input [MEM_DEPTH:0] block_PC;
    input [        1:0] block_type;

    // Store current status on the blocks stack
    blockStack_op   <= `PUSH;
    // TODO should we use relative addresses for destination?
    blockStack_data <= {block_type, leb128_out[6:0], block_PC, stack_index,
                        stack_underflow};

    // Set an empty stack for the block
    stack_underflow <= stack_index;
  endtask

  task set_stack_data_32;
    input [ 1:0] data_type;
    input [31:0] value;

    if(USE_64B)
      stack_data <= {data_type, 32'b0, value};
    else
      stack_data <= {data_type, value};
  endtask

  task comparison;
    input value;

    set_stack_data_32(`i32, value ? 32'b1 : 32'b0);
  endtask


  //
  // Main loop
  //

  always @(posedge clk) begin
    stack_op      <= `NONE;
    blockStack_op <= `NONE;
    callStack_op  <= `NONE;

    if(reset) begin
      trap <= `NONE;
      step <= FETCH;
      PC   <= pc;

      blockStack_offset    <= 0;
      blockStack_underflow <= 0;

      stack_op <= `INDEX_RESET;
      stack_offset    <= index;
      stack_underflow <= index;
      stack_upper     <= index;
      stack_lower     <= 0;
    end

    else if(pushStack) begin
      stack_op   <= `PUSH;
      stack_data <= stack_in;
    end

    else if(!trap)
      case (step)
        FETCH: begin
          mem_addr  <= PC;
          mem_extra <= 10;

          PC <= PC+1;
          step <= FETCH2;
        end

        FETCH2: begin
          if(stack_status > `EMPTY) trap <= `STACK_ERROR;

          else
            step <= EXEC;
        end

        EXEC: begin
          if(mem_error) trap <= `MEM_ERROR;

          else begin
            step <= FETCH;

            opcode = mem_data_opcode;

            // Operations
            case (opcode)
              // Control flow operators
              `op_unreachable: begin
                trap <= `UNREACHABLE;
              end

              `op_nop: begin
              end

              `op_block: begin
                block_add(mem_data_PC, `block);

                PC <= PC+5;
              end

              `op_loop: begin
                PC = PC+1;

                block_add(PC, `block_loop);
              end

              `op_if: begin
                if(stack_status == `EMPTY)
                  trap <= `STACK_EMPTY;

                else begin
                  // Add stack slice if conditional is true or we have an `else`
                  if(stack_out_32 || mem_data[39:8])
                    block_add(mem_data_PC, `block_if);

                  // Conditional is true, go to `true` block
                  if(stack_out_32)
                    PC <= PC+9;

                  // Conditional is `false`
                  else
                    // Go to begin of `else` block or end of `if` conditional
                    PC <= mem_data[39:8] ? mem_data[39:8] : mem_data_PC;
                end
              end

              `op_else: begin
                if(blockStack_status == `EMPTY)
                  trap <= `BLOCK_STACK_EMPTY;

                else if(blockStack_out_type != `block_if)
                  trap <= `BAD_BLOCK_TYPE;

                else
                  block_return(blockStack_out, 0);
              end

              `op_end: begin
                // Function
                if(blockStack_status == `EMPTY)
                  call_return();

                // Loop, go back to its begin
                else if(blockStack_out_type == `block_loop)
                  block_loop_back();

                // Block or if
                else
                  block_return(blockStack_out, 0);
              end

              `op_br: block_break(leb128_out[MEM_DEPTH:0]);

              `op_br_if: begin
                // Consume ToS
                stack_op   <= `POP;
                stack_data <= 0;

                if(stack_status == `EMPTY)
                  trap <= `STACK_EMPTY;

                else if(result_type != `i32)
                  trap <= `TYPE_MISMATCH;

                // Condition is `true`, do the break
                else if(stack_out_32)
                  block_break(leb128_out[MEM_DEPTH:0]);

                // Condition is `false`, don't break
                else
                  PC <= PC+leb128_len;
              end

              `op_br_table: begin
                // Consume ToS
                stack_op   <= `POP;
                stack_data <= 0;

                if(stack_status == `EMPTY)
                  trap <= `STACK_EMPTY;

                else if(result_type != `i32)
                  trap <= `TYPE_MISMATCH;

                else begin
                  brTable_offset = 4 * (leb128_out < stack_out_32
                                      ? leb128_out
                                      : stack_out_32);

                  // // Requested label is already available, break out directly
                  // brTable_offset2 = 6-leb128_len-brTable_offset;
                  // if(0 <= brTable_offset2)
                  //   block_break(mem_data[(brTable_offset2+4)*8-1:brTable_offset2*8]);
                  //
                  // // Search the requested label on the ROM before doing the
                  // // break out
                  // else begin
                    mem_addr  <= PC + leb128_len + brTable_offset;
                    mem_extra <= 3;

                    step <= EXEC2;
                  // end
                end
              end

              `op_return: call_return();

              // Call operators
              `op_call: begin
                // Get function metadata
                mem_addr  <= 4 + leb128_out * 13;
                mem_extra <= 12;

                // Store on call stack the address after the function call
                call_PC <= PC+leb128_len;

                step <= EXEC2;
              end

              // Parametric operators
              `op_drop: begin
                stack_op   <= `POP;
                stack_data <= 0;
              end

              `op_select: begin
                // Validate both operators are of the same type
                if(stack_out1[DATA_WIDTH+1:DATA_WIDTH] != stack_out2[DATA_WIDTH+1:DATA_WIDTH])
                  trap <= `TYPES_MISMATCH;

                else begin
                  stack_op     <= `INDEX_RESET_AND_PUSH;
                  stack_offset <= stack_index - 3;
                  stack_data   <= stack_out ? stack_out1 : stack_out2;
                end
              end

              // Variable access
              `op_get_local: begin
                stack_op     <= `UNDERFLOW_GET;
                stack_offset <= leb128_out;

                PC <= PC+leb128_len;
                step <= EXEC2;
              end

              `op_set_local,
              `op_tee_local: begin
                stack_op     <= `UNDERFLOW_SET;
                stack_data   <= stack_out;
                stack_offset <= leb128_out;

                // Remove from ToS the data we are storing as the local variable
                stack_dropTos <= opcode == `op_set_local;

                PC <= PC+leb128_len;
              end

              // Memory-related operators

              // Constants
              `op_i32_const: begin
                stack_op <= `PUSH;
                set_stack_data_32(`i32, leb128_out[31:0]);

                PC <= PC+leb128_len;
              end

              `op_i64_const: begin
                if(!USE_64B)
                  trap <= `NO_64B;

                else begin
                  stack_op <= `PUSH;
                  stack_data <= {`i64, leb128_out};

                  PC <= PC+leb128_len;
                end
              end

              `op_f32_const: begin
                stack_op <= `PUSH;
                set_stack_data_32(`f32, mem_data[79:48]);

                PC <= PC+4;
              end

              `op_f64_const: begin
                if(!USE_64B)
                  trap <= `NO_64B;

                else begin
                  stack_op <= `PUSH;
                  stack_data <= {`f64, mem_data[79:16]};

                  PC <= PC+8;
                end
              end

              // Comparison operators
              `op_i32_eqz: begin
                if(result_type != `i32)
                  trap <= `TYPE_MISMATCH;

                else begin
                  stack_op <= `REPLACE;
                  comparison(stack_out_32 == 32'b0);
                end
              end

              `op_i64_eqz: begin
                if(!USE_64B)
                  trap <= `NO_64B;

                else if(result_type != `i64)
                  trap <= `TYPE_MISMATCH;

                else begin
                  stack_op <= `REPLACE;
                  comparison(stack_out_64 == 64'b0);
                end
              end

              // Numeric operators

              // Conversions
              `op_i64_extend_s_i32: begin
                if(!USE_64B)
                  trap <= `NO_64B;

                else if(result_type != `i32)
                  trap <= `TYPE_MISMATCH;

                else begin
                  stack_op <= `REPLACE;
                  stack_data <= {`i64, {32{stack_out_32[31]}}, stack_out_32};
                end
              end

              `op_i64_extend_u_i32: begin
                if(!USE_64B)
                  trap <= `NO_64B;

                else if(result_type != `i32)
                  trap <= `TYPE_MISMATCH;

                else begin
                  stack_op <= `REPLACE;
                  stack_data <= {`i64, 32'b0, stack_out_32};
                end
              end

              `op_f32_demote_f64: begin
                if(!HAS_FPU)
                  trap <= `NO_FPU;

                else if(!USE_64B)
                  trap <= `NO_64B;

                else begin
                  double_to_float_a_stb <= 0;
                  double_to_float_z_ack <= 0;

                  if(result_type != `f64)
                    trap <= `TYPE_MISMATCH;

                  else if(double_to_float_z_stb) begin
                    stack_op   <= `REPLACE;
                    stack_data <= {`f32, 32'b0, double_to_float_z};

                    double_to_float_z_ack <= 1;
                  end

                  else begin
                    if(double_to_float_a_ack)
                      double_to_float_a_stb <= 1;

                    // Wait at the same step until the FPU is ready
                    step <= EXEC;
                  end
                end
              end

              `op_f64_promote_f32: begin
                if(!HAS_FPU)
                  trap <= `NO_FPU;

                else if(!USE_64B)
                  trap <= `NO_64B;

                else begin
                  // if(result_type != `f32)
                  //   trap <= `TYPE_MISMATCH;
                  //
                  // else if(input_a_ack) begin
                  //
                  // end
                  //
                  // else if(output_z_stb) begin
                  //
                  //   float_to_double_ack <= 1;
                  // end
                  //
                  // // Wait at the same step until the FPU is ready
                  // else
                  //   step <= EXEC;
                end
              end

              // Reinterpretations
              `op_i32_reinterpret_f32: begin
                if(result_type != `f32)
                  trap <= `TYPE_MISMATCH;

                else begin
                  stack_op <= `REPLACE;
                  set_stack_data_32(`i32, stack_out_32);

                  step <= FETCH;
                end
              end

              `op_i64_reinterpret_f64: begin
                if(!USE_64B)
                  trap <= `NO_64B;

                else if(result_type != `f64)
                  trap <= `TYPE_MISMATCH;

                else begin
                  stack_op <= `REPLACE;
                  stack_data <= {`i64, stack_out_64};

                  step <= FETCH;
                end
              end

              `op_f32_reinterpret_i32: begin
                if(result_type != `i32)
                  trap <= `TYPE_MISMATCH;

                else begin
                  stack_op <= `REPLACE;
                  set_stack_data_32(`f32, stack_out_32);

                  step <= FETCH;
                end
              end

              `op_f64_reinterpret_i64: begin
                if(!USE_64B)
                  trap <= `NO_64B;

                else if(result_type != `i64)
                  trap <= `TYPE_MISMATCH;

                else begin
                  stack_op <= `REPLACE;
                  stack_data <= {`f64, stack_out_64};

                  step <= FETCH;
                end
              end

              // Binary operations - 32 bits
              `op_i32_eq,
              `op_i32_ne,
              `op_i32_lt_s,
              `op_i32_lt_u,
              `op_i32_gt_s,
              `op_i32_gt_u,
              `op_i32_le_s,
              `op_i32_le_u,
              `op_i32_ge_s,
              `op_i32_ge_u,
              `op_i32_add,
              `op_i32_sub:
              begin
                if(stack_out[DATA_WIDTH+1:DATA_WIDTH] != `i32 || stack_out1[DATA_WIDTH+1:DATA_WIDTH] != `i32)
                  trap <= `TYPE_MISMATCH;

                else begin
                  stack_op     <= `INDEX_RESET_AND_PUSH;
                  stack_offset <= stack_index - 2;

                  case(opcode)
                    // Comparison operators
                    `op_i32_eq  : comparison(        stack_out1[31:0]  ==         stack_out[31:0] );
                    `op_i32_ne  : comparison(        stack_out1[31:0]  !=         stack_out[31:0] );
                    `op_i32_lt_s: comparison($signed(stack_out1[31:0]) <  $signed(stack_out[31:0]));
                    `op_i32_lt_u: comparison(        stack_out1[31:0]  <          stack_out[31:0] );
                    `op_i32_gt_s: comparison($signed(stack_out1[31:0]) >  $signed(stack_out[31:0]));
                    `op_i32_gt_u: comparison(        stack_out1[31:0]  >          stack_out[31:0] );
                    `op_i32_le_s: comparison($signed(stack_out1[31:0]) <= $signed(stack_out[31:0]));
                    `op_i32_le_u: comparison(        stack_out1[31:0]  <=         stack_out[31:0] );
                    `op_i32_ge_s: comparison($signed(stack_out1[31:0]) >= $signed(stack_out[31:0]));
                    `op_i32_ge_u: comparison(        stack_out1[31:0]  >=         stack_out[31:0] );

                    // Numeric operators
                    `op_i32_add: set_stack_data_32(`i32, stack_out1[31:0] + stack_out[31:0]);
                    `op_i32_sub: set_stack_data_32(`i32, stack_out1[31:0] - stack_out[31:0]);
                  endcase
                end
              end

              // Binary operations - 64 bits
              `op_i64_eq,
              `op_i64_ne,
              `op_i64_lt_s,
              `op_i64_lt_u,
              `op_i64_gt_s,
              `op_i64_gt_u,
              `op_i64_le_s,
              `op_i64_le_u,
              `op_i64_ge_s,
              `op_i64_ge_u,
              `op_i64_add,
              `op_i64_sub:
              begin
                if(!USE_64B)
                  trap <= `NO_64B;

                else if(stack_out[DATA_WIDTH+1:DATA_WIDTH] != `i64 || stack_out1[DATA_WIDTH+1:DATA_WIDTH] != `i64)
                  trap <= `TYPE_MISMATCH;

                else begin
                  stack_op     <= `INDEX_RESET_AND_PUSH;
                  stack_offset <= stack_index - 2;

                  case(opcode)
                    // Comparison operators
                    `op_i64_eq  : comparison(        stack_out1[63:0]  ==         stack_out[63:0] );
                    `op_i64_ne  : comparison(        stack_out1[63:0]  !=         stack_out[63:0] );
                    `op_i64_lt_s: comparison($signed(stack_out1[63:0]) <  $signed(stack_out[63:0]));
                    `op_i64_lt_u: comparison(        stack_out1[63:0]  <          stack_out[63:0] );
                    `op_i64_gt_s: comparison($signed(stack_out1[63:0]) >  $signed(stack_out[63:0]));
                    `op_i64_gt_u: comparison(        stack_out1[63:0]  >          stack_out[63:0] );
                    `op_i64_le_s: comparison($signed(stack_out1[63:0]) <= $signed(stack_out[63:0]));
                    `op_i64_le_u: comparison(        stack_out1[63:0]  <=         stack_out[63:0] );
                    `op_i64_ge_s: comparison($signed(stack_out1[63:0]) >= $signed(stack_out[63:0]));
                    `op_i64_ge_u: comparison(        stack_out1[63:0]  >=         stack_out[63:0] );

                    // Numeric operators
                    `op_i64_add: stack_data <= {`i64, stack_out1[63:0] + stack_out[63:0]};
                    `op_i64_sub: stack_data <= {`i64, stack_out1[63:0] - stack_out[63:0]};
                  endcase
                end
              end

              // Unknown opcode
              default:
                trap <= `UNKOWN_OPCODE;
            endcase
          end
        end

        EXEC2: begin
          step <= EXEC3;
        end

        EXEC3: begin
          step <= FETCH;

          case (opcode)
            // Control flow operators
            `op_br,
            `op_br_if: begin
              if(blockStack_status > `EMPTY)
                trap <= `BLOCK_STACK_ERROR;

              else
                block_break2();
            end

            `op_br_table: begin
              if(mem_error)
                trap <= `MEM_ERROR;

              else
                block_break(mem_data[MEM_DEPTH:0]);
            end

            // Call operators
            `op_call: begin
              if(mem_error)
                trap <= `MEM_ERROR;

              else begin
                PC <= mem_data_functionAddress;

                // Store block and operators stacks status on the call stack
                callStack_op   <= `PUSH;
                // TODO Spec says "A direct call to a function with a mismatched
                //      signature is a module verification error". Should return
                //       value be verified, or it's already done at loading?
                callStack_data <= {blockStack_index, blockStack_underflow,
                                   stack_upper, stack_lower,
                                   mem_data_returnType, call_PC,
                                   stack_index-mem_data_arguments,
                                   stack_underflow};

                // Set empty stacks for the called function
                blockStack_underflow <= blockStack_index;

                stack_underflow <= stack_index + mem_data_localEntries - mem_data_arguments;
                stack_upper     <= stack_index + mem_data_localEntries - mem_data_arguments;
                stack_lower     <= stack_index                         - mem_data_arguments;
              end
            end

            // Variable access
            `op_get_local: begin
              if(stack_status > `EMPTY) trap <= `STACK_ERROR;

              else begin
                stack_op   <= `PUSH;
                stack_data <= stack_out;
              end
            end
          endcase
        end

        EXEC4: begin
          step <= EXEC5;
        end

        EXEC5: begin
          step <= FETCH;

          case (opcode)
            `op_br_table: begin
              if(blockStack_status > `EMPTY)
                trap <= `BLOCK_STACK_ERROR;

              else
                block_break2();
            end
          endcase
        end
      endcase
  end
endmodule
