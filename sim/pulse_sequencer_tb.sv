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

  // ---------------------------------------------------------------------------
  // Parameters 
  // ---------------------------------------------------------------------------
  localparam CLK_FREQ_MHZ = 100;
  localparam ENTRY_W = 64;
  localparam CHANNEL = 4;

  // ---------------------------------------------------------------------------
  // clocks & resets
  // ---------------------------------------------------------------------------
  logic clk = 0
  logic resetn = 0;

  // Generate 100 Mhz clk
  always #5.0 clk = ~clk;   // period = 10ns 
 
  // Apply reset
  initial begin
    resetn = 0; 
    repeat (8)  @(posedge clk);
    resetn = 1;
  end

  // ----------------------------------------------------------------------------
  // Interfaces
  //-----------------------------------------------------------------------------
  pulse_seq_if #(.CH(CH), .ENTRY_W(ENTRY_W)) pulse_s_if( .clk(clk) );
  

  // ----------------------------------------------------------------------------
  // Entry table
  //-----------------------------------------------------------------------------
  typedef struct packed {
      bit [23:0] t_off;
      bit [15:0] w_us;
      bit [15:0] ch_m;
    } entry_t;

   entry_t entry_table[];
   
   assign pulse_s_if.rd_data = entry_table[pulse_seq_if.rd_idx];

  //----------------------------------------------------------------------------
  // Instantiate DUT
  //----------------------------------------------------------------------------
  pulse_sequencer #(
    .CH(CHANNEL),
    .ENTRY_W(ENTRY_W)
  ) DUT (
    .clk(pulse_s_if.clk),
    .rst_n(pulse_s_if.rst_n),
    .start(pulse_s_if.start),      // software trigger
    .arm(pulse_s_if.arm),        // arm before start
    .tick_1us(pulse_s_if.tick_1us),   // 1 us timebase pulse
    .trig_ext(pulse_s_if.trig_ext),   // external trigger
    .rd_idx(pulse_seq_if.rd_idx),     // which entry to read
    .rd_data(pulse_s_if.rd_data),
    .pulse_vec(pulse_s_if.pulse_vec),
    .busy(pulse_s_if.busy),
    .done(pulse_s_if.done),
    .err_underrun(pulse_s_if.err_underrun)  
  );


  //----------------------------------------------------------------------------
  // Local model
  //----------------------------------------------------------------------------
  class pulse_seq_model;

    entry_t entries[];
    int unsigned base_us;
    int unsigned now_us;
    int unsigned cur_idx;
    bit [3:0] pulse_vec; // parametrize

    function new(entry_t e[]);
      entries = e;
    endfunction

    // call this on every tick_1us
    function void step(bit armed, bit started);
      // advance time
      now_us++;

      if (started) begin
        base_us = now_us;
        cur_idx = 0;
        pulse_vec = '0;
      end

      if (cur_idx < entries.size()) begin
        int rel_us = now_us - base_us;
        entry_t cur = entries[cur_idx];

        if (rel_us == cur.t_off)
          pulse_vec |= cur.ch_m[3:0];

        if (cur.w_us != 0 && rel_us == (cur.t_off + cur.w_us)) begin
          pulse_vec &= ~cur.ch_m[3:0];
          cur_idx++;
        end
      end
    endfunction
  endclass


  //----------------------------------------------------------------------------
  // Declare class handler for the model
  //----------------------------------------------------------------------------
  pulse_seq_model model; 

  //----------------------------------------------------------------------------
  // Run tests
  //----------------------------------------------------------------------------
  initial begin
    model = new(entry_table);

    pulse_s_if.start = 0;
    pulse_s_if.trig_ext = 0;
    pulse_s_if.arm = 0;

    run_direct_test();
    //run_randomized_test();
  end
  


  //--------------------------------------------------------------------------------
  // Directed “sanity” tests
  //--------------------------------------------------------------------------------
  task run_direct_test()
    
    //Single entry, single channel
    // - table[0] = {t_off=10, w_us=5, ch_m=1, res=0}
    // - arm → start
    // - expect: at 10 µs ch0=1, at 15 µs ch0=0, then DONE
    @posedge(pulse_s_if.clk); 
    entry_table[0].t_off = 10;
    entry_table[0].w_us = 5;
    entry_table[0].ch_m = 1
    
    pulse_s_if.arm = 1'b1;// arm 
    pulse_s_if.start = 1'b1; // start

    @posedge(pulse_s_if.clk);  // Disarm
    pulse_s_if.arm = 1'b0;// arm 

    wait(pulse_s_if.done); 
    pulse_s_if.start = 1'b0; // start


  endtask

  //--------------------------------------------------------------------------------
  // 1us counter
  //--------------------------------------------------------------------------------
  logic [7:0] = counter
  always_ff @(posedge clk) begin
    if(!rst_n) begin
      counter <= 0;
      pulse_s_if.tick_1us <= '0;
    end else begin 
      if (counter == CLK_FREQ_MHZ -1) begin
        counter <=  0;
        pulse_s_if.tick_1us <= '1;
      end else begin
        counter <= counter +1;
        pulse_s_if.tick_1us <= '0;
      end
    end
  end

  initial begin
    forever begin
      @posedge(pulse_s_if.tick_1us);
      model.step(pulse_s_if.arm,pulse_s_if.start);
    end 
  end




endmodule