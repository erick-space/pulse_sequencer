`timescale 1ns/1ps
`define ASSERT_ON

import axi_stream_pkg::*;           // transaction/driver/monitor/sequencer classes
`include "axi_stream_agent.sv"      // agent class using the pkg
`include "axi_stream_tb_if.sv"      // AXI-Stream testbench interface

module axis_async_fifo_tb_uvmstyle;

  // ---------------------------------------------------------------------------
  // Parameters (match pkg default: 16-bit transaction data)
  // ---------------------------------------------------------------------------
  localparam int unsigned DATA_W = 16;
  localparam int unsigned DEPTH  = 512;

  // ---------------------------------------------------------------------------
  // Asynchronous clocks & resets
  // ---------------------------------------------------------------------------
  logic s_aclk = 0, m_aclk = 0;
  logic s_aresetn = 0, m_aresetn = 0;

  // ~250 MHz write, ~156.25 MHz read (no jitter for determinism)
  always #2.0 s_aclk = ~s_aclk;     // 4.0 ns period
  always #3.2 m_aclk = ~m_aclk;     // 6.4 ns period

  initial begin
    s_aresetn = 0; m_aresetn = 0;
    repeat (8)  @(posedge s_aclk);
    s_aresetn = 1;
    repeat (6)  @(posedge m_aclk);
    m_aresetn = 1;
  end

  // ---------------------------------------------------------------------------
  // Interfaces (bind to proper clock/reset domains)
  // ---------------------------------------------------------------------------
  axi_stream_tb_if #(DATA_W) s_if ( .clk(s_aclk), .reset(~s_aresetn) );
  axi_stream_tb_if #(DATA_W) m_if ( .clk(m_aclk), .reset(~m_aresetn) );

  // Tie-offs (initial states)
  initial begin
    s_if.tvalid = 1'b0;
    s_if.tdata  = '0;
    s_if.tlast  = 1'b0;
    m_if.tready = 1'b0;
  end

  // ---------------------------------------------------------------------------
  // DUT
  // ---------------------------------------------------------------------------
  axis_async_fifo #(
    .DATA_W (DATA_W),
    .DEPTH  (DEPTH)
  ) dut (
    // write domain
    .s_aclk        (s_aclk),
    .s_aresetn     (s_aresetn),
    .s_tvalid      (s_if.tvalid),
    .s_tdata       (s_if.tdata),
    .s_tlast       (s_if.tlast),
    .s_tready      (s_if.tready),
    .s_almost_full (),

    // read domain
    .m_aclk        (m_aclk),
    .m_aresetn     (m_aresetn),
    .m_tvalid      (m_if.tvalid),
    .m_tdata       (m_if.tdata),
    .m_tlast       (m_if.tlast),
    .m_tready      (m_if.tready),
    .m_almost_empty()
  );

  // ---------------------------------------------------------------------------
  // Agent using your package (driver pulls from sequencer mailbox)
  //  - Constructor signature observed in your file:
  //      function new(virtual axi_stream_tb_if axi_if_master,
  //                   virtual axi_stream_tb_if axi_if_slave);
  // ---------------------------------------------------------------------------
  axi_stream_agent agent;

  initial begin
    // Create and bind agent to interfaces
    agent = new(s_if, m_if);
    // If your agent has start()/run() methods, call them (optional).
    // Some implementations auto-spawn driver/monitor threads in new().
    // Uncomment if your agent provides start():
    // agent.start();
  end

  // ---------------------------------------------------------------------------
  // Scoreboard (TB-level): compare expected queue vs DUT output
  //  We build 'exp_q' from transactions we send via agent.sequencer.send()
  //  This keeps the agent driving, while TB checks the sink.
  // ---------------------------------------------------------------------------
  typedef struct packed { logic [DATA_W-1:0] data; logic last; } axis_txn_t;
  axis_txn_t exp_q[$];
  int sent, rcvd, err;

  // Read-side backpressure
  initial begin
    wait (s_aresetn && m_aresetn);
    forever begin
      @(posedge m_aclk);
      m_if.tready <= ($urandom_range(0,100) > 15); // ~85% ready
    end
  end

  // Monitor sink and compare
  always @(posedge m_aclk) begin
    if (!m_aresetn) begin
      rcvd <= 0;
    end else if (m_if.tvalid && m_if.tready) begin
      if (exp_q.size() == 0) begin
        $error("[%0t] Unexpected output beat: no expected item queued", $time);
        err++;
      end else begin
        axis_txn_t exp = exp_q.pop_front();
        if (exp.data !== m_if.tdata || exp.last !== m_if.tlast) begin
          $display("[%0t] MISMATCH exp.data=%h last=%0d  got.data=%h last=%0d",
                   $time, exp.data, exp.last, m_if.tdata, m_if.tlast);
          err++;
        end
      end
      rcvd++;
    end
  end

  // ---------------------------------------------------------------------------
  // Helpers that USE YOUR AGENT'S API
  //  - We create axi_stream_transaction from the pkg (16-bit data, last)
  //  - We push into agent.sequencer via its 'send()' task (present in your pkg)
  //  - We also queue expected beats for the scoreboard
  // ---------------------------------------------------------------------------
  task automatic enqueue_packet(int beats);
    for (int i = 0; i < beats; i++) begin
      logic [DATA_W-1:0] d = $urandom_range(0, (1<<DATA_W)-1);
      logic last = (i == beats-1);

      // Build your package's transaction
      axi_stream_transaction tx = new(d, last);

      // Send to the agent's sequencer (defined in your pkg)qA
      agent.sequencer.send(tx);

      // Build expected queue for scoreboard
      axis_txn_t e; e.data = d; e.last = last;
      exp_q.push_back(e);
      sent++;
    end
  endtask

  // ---------------------------------------------------------------------------
  // Tests (use the same plan, now driving through your agent)
  // ---------------------------------------------------------------------------
  task automatic tc_smoke_basic();
    $display("\n[TC] smoke_basic");
    enqueue_packet(3);
  endtask

  task automatic tc_random_bursts(int n);
    $display("\n[TC] random_bursts x%0d", n);
    repeat (n) enqueue_packet($urandom_range(1,16));
  endtask

  task automatic tc_fill_drain();
    $display("\n[TC] fill_drain");
    // Hold read off to fill
    m_if.tready = 0;
    repeat (DEPTH+8) enqueue_packet(1);
    repeat (20) @(posedge s_aclk);
    // Drain
    m_if.tready = 1;
    repeat (200) @(posedge m_aclk);
  endtask

  task automatic tc_underflow_check();
    $display("\n[TC] underflow_check");
    wait (exp_q.size() == 0);
    m_if.tready = 1;
    repeat (40) @(posedge m_aclk);
    if (m_if.tvalid) begin
      $error("[%0t] m_tvalid asserted while FIFO empty", $time);
      err++;
    end
  endtask

  // ---------------------------------------------------------------------------
  // Run sequence
  // ---------------------------------------------------------------------------
  initial begin
    wait (s_aresetn && m_aresetn);

    tc_smoke_basic();
    tc_random_bursts(10);
    tc_fill_drain();
    tc_underflow_check();

    // Drain expected
    wait (exp_q.size() == 0);
    repeat (50) @(posedge m_aclk);

    $display("\n=======================================");
    $display(" SENT=%0d  RCV=%0d  ERR=%0d", sent, rcvd, err);
    $display("=======================================\n");

    if (err == 0) $finish;
    else begin
      $error("TEST FAILED with %0d errors", err);
      $finish;
    end
  end

endmodule
