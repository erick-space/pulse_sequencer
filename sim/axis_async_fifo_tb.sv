import axi_stream_pkg::*;

module axis_async_fifo_tb;

  // ---------------------------------------------------------------------------
  // Parameters (match pkg default: 16-bit transaction data)
  // ---------------------------------------------------------------------------
  localparam DATA_W = 16;
  localparam DEPTH  = 512;

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
  //  - Constructor signature observed i
  //      function new(virtual axi_stream_tb_if axi_if_master,
  //                   virtual axi_stream_tb_if axi_if_slave);
  // ---------------------------------------------------------------------------
  axi_stream_agent agent;

  initial begin
    // Create and bind agent to interfaces
    agent = new(s_if, m_if);

    // Running agent cause the driver to read transcation from sequencer mailbox
    // and the monitor will start monitoring the output from the DUV
    agent.run();
  end

  // ---------------------------------------------------------------------------
  // Scoreboard (TB-level): compare expected queue vs DUT output
  //  build 'exp_q' from transactions send via agent.sequencer.send()
  //  This keeps the agent driving, while TB checks the sink.
  // ---------------------------------------------------------------------------
  typedef struct packed { logic [DATA_W-1:0] data; logic last; } axis_txn_t;
  axis_txn_t exp_q[$];
  axis_txn_t exp;
  int sent, rcvd, err;

  // Monitor sink and compare
  always @(posedge m_aclk) begin
    if (!m_aresetn) begin
      rcvd <= 0;
    end else if (m_if.tvalid && m_if.tready) begin
      if (exp_q.size() == 0) begin
        $error("[%0t] Unexpected output beat: no expected item queued", $time);
        err++;
      end else begin
        exp = exp_q.pop_front();
        if (exp.data !== m_if.tdata || exp.last !== m_if.tlast) begin
          $display("[%0t] MISMATCH exp.data=%h last=%0d  got.data=%h last=%0d",
                   $time, exp.data, exp.last, m_if.tdata, m_if.tlast);
          err++;
          $finish;
        end
      end
      rcvd++;
    end
  end

  task automatic check_tready();
    if (s_if.tready)
      $error("Error tready remains high after filling FIFO");
  endtask

// ---------------------------------------------------------------------------
// Single-owner m_if.tready driver 
// ---------------------------------------------------------------------------
typedef enum logic [1:0] {RD_HOLD0, RD_HOLD1, RD_RANDOM} rd_mode_t;
rd_mode_t rd_mode;

initial begin
  wait (s_aresetn && m_aresetn);
  rd_mode = RD_RANDOM; // default random backpressure
  forever begin
    @(posedge m_aclk);
    unique case (rd_mode)
      RD_HOLD0:  m_if.tready <= 1'b0;
      RD_HOLD1:  m_if.tready <= 1'b1;
      RD_RANDOM: m_if.tready <= ($urandom_range(0,100) > 15); //Read-side backpressure, ~85% ready, 
    endcase
  end
end

// test-side helpers (call these in testcases instead of assigning tready)
task automatic set_ready_hold0();  rd_mode = RD_HOLD0;  endtask
task automatic set_ready_hold1();  rd_mode = RD_HOLD1;  endtask
task automatic set_ready_random(); rd_mode = RD_RANDOM; endtask

  // ---------------------------------------------------------------------------
  // Helpers that USE AGENT'S API
  //  - Create axi_stream_transaction from the 
  //  - Push into agent.sequencer via its 'send()' task 
  //  - queue expected beats for the scoreboard
  // ---------------------------------------------------------------------------
  task automatic enqueue_packet(int beats);
    
    axi_stream_transaction tx;
    logic [DATA_W-1:0] d;
    logic last;
    axis_txn_t e; 

    for (int i = 0; i < beats; i++) begin
      d = $urandom_range(0, (1<<DATA_W)-1);
      last = (i == beats-1);

      // Build your package's transaction
      tx = new(d, last);

      // Send to the agent's sequencer 
      // Pass transcation to the sequencer through the agent. Agent will put the transaction in a mailbox accessed by the driver
      // Sequencer class is delcared in a a. SO go to go through agent to get 
      // This is nonblocking. Meaning this call will not wait for the driver to complete  before moving on. 
      agent.sequencer.send(tx);

      // Build expected queue for scoreboard
      e.data = d; e.last = last;
      exp_q.push_back(e);
      sent++;
    end
  endtask

  // ---------------------------------------------------------------------------
  // Tests (use the same plan, now driving through your agent)
  // ---------------------------------------------------------------------------
  task automatic tc_smoke_basic();
    $display("\n[TC] smoke_basic");
    set_ready_hold0();  // fill
    enqueue_packet(DEPTH+1);
  endtask

  task automatic tc_random_bursts(int n);
    $display("\n[TC] random_bursts x%0d", n);
    repeat (n) enqueue_packet($urandom_range(1,16));
  endtask

  task automatic tc_fill_drain();
    $display("\n[TC] fill_drain");
    // Hold read off to fill
    set_ready_hold0();  // fill
    repeat (DEPTH+8) enqueue_packet(1);
    repeat (DEPTH+8) @(posedge s_aclk);
    check_tready();
    set_ready_hold1();  // drain
    repeat (200) @(posedge m_aclk);
  endtask

  task automatic tc_underflow_check();
    $display("\n[TC] underflow_check");
    wait (exp_q.size() == 0);
    set_ready_hold1(); 
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

    //tc_smoke_basic(); wait (exp_q.size() == 0); 

    //tc_random_bursts(10); wait (exp_q.size() == 0); 

    tc_fill_drain(); wait (exp_q.size() == 0); 

    //tc_underflow_check();

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