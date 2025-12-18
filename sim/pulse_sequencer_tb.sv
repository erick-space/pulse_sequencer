interface pulse_seq_if #(int CH=4, int ENTRY_W=64)(input logic clk);
  logic        rst_n;
  logic        start;
  logic        arm;
  logic        tick_1us;
  logic        trig_ext;
  logic [15:0] rd_idx;
  logic [ENTRY_W-1:0] rd_data;
  logic [CH-1:0] pulse_vec;
  logic          busy, done, err_underrun;
endinterface

module pulse_sequencer_tb;

  localparam int CLK_FREQ_MHZ = 100;
  localparam int ENTRY_W      = 64;
  localparam int CH           = 4;
  localparam int NUM_ENTRIES  = 20;

  logic clk    = 0;
  logic resetn = 0;

  always #5 clk = ~clk;

  initial begin
    resetn = 0;
    repeat (8) @(posedge clk);
    resetn = 1;
  end

  pulse_seq_if #(.CH(CH), .ENTRY_W(ENTRY_W)) pulse_s_if (.clk(clk));

  always_comb pulse_s_if.rst_n = resetn;

  typedef logic [63:0] entry_t;
  entry_t entry_table[];

  initial entry_table = new[NUM_ENTRIES];

  // feed DUT
  always_comb begin
    int unsigned idx = $unsigned(pulse_s_if.rd_idx);
    if (idx < NUM_ENTRIES)
      pulse_s_if.rd_data = entry_table[idx];
    else
      pulse_s_if.rd_data = '0;
  end


  pulse_sequencer #(
    .CH(CH),
    .ENTRY_W(ENTRY_W)
  ) dut (
    .clk        (pulse_s_if.clk),
    .rst_n      (pulse_s_if.rst_n),
    .start      (pulse_s_if.start),
    .arm        (pulse_s_if.arm),
    .tick_1us   (pulse_s_if.tick_1us),
    .trig_ext   (pulse_s_if.trig_ext),
    .rd_idx     (pulse_s_if.rd_idx),
    .rd_data    (pulse_s_if.rd_data),
    .pulse_vec  (pulse_s_if.pulse_vec),
    .busy       (pulse_s_if.busy),
    .done       (pulse_s_if.done),
    .err_underrun(pulse_s_if.err_underrun)
  );

  // ---------------------------------------------------------------------------
  // Model
  // ---------------------------------------------------------------------------
  class pulse_seq_model;
    entry_t entries[];
    int unsigned base_us;
    int unsigned now_us;
    int unsigned cur_idx;
    bit [CH-1:0] exp_pulse_vec;

    function new(entry_t e[]);
      entries        = e;
      exp_pulse_vec  = '0;
      base_us        = 0;
      now_us         = 0;
      cur_idx        = 0;
    endfunction

    function automatic int unsigned get_t_off(entry_t w);
      return w[63:40];
    endfunction

    function automatic int unsigned get_w_us(entry_t w);
      return w[39:24];
    endfunction

    function automatic bit [CH-1:0] get_ch_mask(entry_t w);
      return w[23:8];
    endfunction

    function void step(bit armed, bit started);
      now_us++;

      if (started) begin
        base_us        = now_us;
        cur_idx        = 0;
        exp_pulse_vec  = '0;
      end

      if (cur_idx < entries.size()) begin
        int rel_us = now_us - base_us;
        entry_t curw = entries[cur_idx];

        int unsigned t_off = get_t_off(curw);
        int unsigned w_us  = get_w_us(curw);
        bit [CH-1:0] ch_m  = get_ch_mask(curw);

        if (rel_us == t_off)
          exp_pulse_vec |= ch_m;

        if (w_us != 0 && rel_us == (t_off + w_us)) begin
          exp_pulse_vec &= ~ch_m;
          cur_idx++;
        end
      end
    endfunction
  endclass

  pulse_seq_model model;

  // ---------------------------------------------------------------------------
  // tick generator (1us pulse)
  // ---------------------------------------------------------------------------
  logic [7:0] counter;
  always_ff @(posedge clk) begin
    if (!resetn) begin
      counter              <= 0;
      pulse_s_if.tick_1us  <= 1'b0;
    end else begin
      if (counter == CLK_FREQ_MHZ - 1) begin
        counter             <= 0;
        pulse_s_if.tick_1us <= 1'b1;
      end else begin
        counter             <= counter + 1;
        pulse_s_if.tick_1us <= 1'b0;
      end
    end
  end

  // ---------------------------------------------------------------------------
  // run model + scoreboard on each 1us tick
  // ---------------------------------------------------------------------------
  initial begin
    pulse_s_if.start    = 0;
    pulse_s_if.trig_ext = 0;
    pulse_s_if.arm      = 0;
    wait (resetn);

    //TODO: Create tasks to generate randomize tests from here
    run_direct_test(); // just fro visual checks
  end

  always @(posedge pulse_s_if.tick_1us) begin
    model.step(pulse_s_if.arm, pulse_s_if.start);
  end

  // scoreboard
  always @(posedge pulse_s_if.tick_1us) begin
    if (pulse_s_if.pulse_vec !== model.exp_pulse_vec) begin
      $error("Mismatch @%0t: dut=%b exp=%b", $time, pulse_s_if.pulse_vec, model.exp_pulse_vec);
    end
  end

  // ---------------------------------------------------------------------------
  // test
  // ---------------------------------------------------------------------------
  task run_direct_test();
    @(posedge pulse_s_if.clk);
    set_entry(0, 10, 5, 1);  // on at 10, off at 15 (ch0)
    set_entry(1, 20, 5, 1);
    set_entry(2, 35, 10, 2);
    set_entry(3, 0,  0, 0); 

    model = new(entry_table);

    pulse_s_if.arm   <= 1'b1;
    @(posedge pulse_s_if.tick_1us);
    pulse_s_if.start <= 1'b1;
    @(posedge pulse_s_if.tick_1us); 
    @(posedge pulse_s_if.clk);
    pulse_s_if.start <= 1'b0;
    pulse_s_if.arm   <= 1'b0;

    fork
      begin
        wait (pulse_s_if.done);
        $display("DONE seen @%0t", $time);
      end
      begin
        repeat (20000) @(posedge clk);
        $fatal("Timeout waiting for done");
      end
    join_any
    disable fork;
  endtask

  task set_entry(int idx, int unsigned t_off, int unsigned w_us, int unsigned ch_m);
    entry_table[idx] = { t_off[23:0], w_us[15:0], ch_m[15:0], 8'h00 };
  endtask

endmodule
