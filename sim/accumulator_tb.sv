//==============================================================================
// Title       : AXI Stream Accumulator Testbench
// File        : accumulator_tb.sv
// Description : Testbench for verifying an AXI Stream accumulator module.
//               It sends various AXI Stream frames to the DUT and compares
//               the output with a reference model using a scoreboard.
//==============================================================================

import axi_stream_pkg::*;

module accumulator_tb;

  parameter DATA_WIDTH = 16;
  parameter MINIMUN_SAMPLE_PER_FRAME = 3;

  // Clock and reset signals
  logic clk = 0;
  logic reset;
  logic clear_accum_dut;
  logic clear_accum;

  // Clock generation: 100 MHz (10 ns period)
  always #5 clk = ~clk;

  // ---------------------------------------------------------------------------
  // Interfaces (bind to proper clock/reset domains)
  // ---------------------------------------------------------------------------
  axi_stream_tb_if #(DATA_W) s_if ( .clk(s_aclk), .reset(~s_aresetn) );
  axi_stream_tb_if #(DATA_W) m_if ( .clk(m_aclk), .reset(~m_aresetn) );


  //============================================================================
  // Scoreboard Class: Models expected behavior and compares with DUT output
  //============================================================================
  class axi_stream_scoreboard;
    mailbox #(axi_stream_transaction) mon_mbx;
    logic signed [15:0] sum[8192];
    logic signed [15:0] expected_values[8192*2];
    logic signed [15:0] values[8192];
    int sum_index = 0;
    int index_verifier = 0;
    int index_model = 0;

    function new(mailbox #(axi_stream_transaction) mon_mbx);
      this.mon_mbx = mon_mbx;
    endfunction

    // Accumulator model: adds incoming data to running sum
    task model(axi_stream_transaction trans);
      sum[sum_index] += trans.data;
      expected_values[index_model] = sum[sum_index];
      sum_index++;
      index_model++;
    endtask

    // Compares DUT output with expected values
    task run();
      axi_stream_transaction trans;
      forever begin
        mon_mbx.get(trans);
        if (trans.data != expected_values[index_verifier]) begin
          $error("Index %0d: Received %0d, Expected %0d",
                 index_verifier,
                 32'(signed'(trans.data)),
                 32'(signed'(expected_values[index_verifier])));
          $finish;
        end
        index_verifier++;
      end
    endtask

    // Reset sum index for new frame
    task loop_back();
      sum_index = 0;
    endtask

    // Reset scoreboard state
    task reset();
      foreach (sum[i]) sum[i] = 0;
      index_model = 0;
      index_verifier = 0;
      sum_index = 0;
    endtask
  endclass

  // AXI Stream agent and scoreboard
  axi_stream_agent agent;
  axi_stream_scoreboard scoreboard;

  //============================================================================
  // Testbench Initialization
  //============================================================================
  initial begin
    agent = new(axi_if_master, axi_if_slave);
    scoreboard = new(agent.monitor.mon_mbx);
    agent.run();

    fork
      scoreboard.run();
    join_none

    reset = 1;
    repeat (3) @(posedge clk);
    reset = 0;

    run_all_tests();

    $display("---------------------------------------------");
    $display("Test Done");
    $finish;
  end

  //============================================================================
  // Test Runner: Executes multiple test scenarios
  //============================================================================
  task run_all_tests();

    run_test("Frame arrives at a fixed rate", 20, 10, 100, 0, 0);
    #1000;
    run_test("Continuous Frame", 20, 10, 0, 0, 0);
    #1000;
    run_test("Minimun Sample Per Frame", 20, MINIMUN_SAMPLE_PER_FRAME, 0, 0, 0);
    #1000;
    run_test("Noncontinuous data rate", 20, 10, 0, 20, 0);
    #1000;
    run_test("Noncontinuous data rate", 32, 10, 0, 0, 0);
    #1000;
    run_test("Max Frame Size", 2, 8192, 0, 0, 0);

    for (int i = 0; i < 100; i++) begin
      #1000;
      run_test("Randomize Test", 0, 0, 0, 0, 1);
      $display("Test: %d", i);
    end
  endtask

  //============================================================================
  // Test Executor: Sends frames and compares results
  //============================================================================
  task run_ test(string name, int frame_count, int data_count,
                int frame_delay, int data_delay, bit random);

    int frameCnt, dataCnt, frameDelay, dataDelay;
    int signed_random_value;

    $display("---------------------------------------------");
    $display("Running: %s", name);

    if (random) begin
      frameCnt = $urandom_range(1, 32);
      dataCnt = $urandom_range(MINIMUN_SAMPLE_PER_FRAME, 20);
      frameDelay = $urandom_range(10, 60);
      $display("frameCnt=%0d dataCnt=%0d frameDelay=%0d",
               frameCnt, dataCnt, frameDelay);
    end else begin
      frameCnt = frame_count;
      dataCnt = data_count;
      frameDelay = frame_delay;
      dataDelay = data_delay;
    end

    scoreboard.reset();

    // Clear DUT accumulator
    @(posedge clk); clear_accum_dut = 1;
    @(posedge clk); clear_accum_dut = 0;

    // Send frames
    for (int i = 0; i < frameCnt; i++) begin
      for (int j = 0; j < dataCnt; j++) begin
        automatic axi_stream_transaction tx;
        signed_random_value = int'($urandom_range(-1024, 1023));
        tx = new(signed_random_value, (j == dataCnt - 1));
        agent.sequencer.send(tx);
        scoreboard.model(tx);

        if (random) begin
          dataDelay = $urandom_range(1, 15);
          #dataDelay;
          @(posedge clk);
        end else if (data_delay != 0) begin
          #data_delay;
          @(posedge clk);
        end
      end

      if (dataCnt > 1 && dataDelay == 0) begin
       
        #frameDelay;
      end

      scoreboard.loop_back();
    end
  endtask



endmodule
