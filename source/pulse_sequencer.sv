

module pulse_sequencer #(
  parameter int CH = 4,
  parameter int ENTRY_W = 64
)(
  input  logic        clk, rst_n,
  input  logic        start, arm,
  input  logic        tick_1us,
  input  logic        trig_ext,
  output logic        busy,
  output logic [15:0] rd_idx,
  input  logic [ENTRY_W-1:0] rd_data,
  output logic [CH-1:0] pulse_vec,
  output logic done, err_underrun
);

  typedef enum logic [1:0] {IDLE, ARMED, RUN, DONE} state_e;
  state_e s, ns;
  logic [31:0] now_us;
  logic [23:0] t_off; logic [15:0] w_us; logic [15:0] ch_m;
  
  assign {t_off, w_us, ch_m, /*res*/} = rd_data;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) 
      now_us <= 32'd0;
    else if (tick_1us) 
      now_us <= now_us + 1;
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) pulse_vec <= '0;
    else begin
      if (tick_1us) begin
        if (now_us == t_off)          
          pulse_vec <= pulse_vec | ch_m;
        if (now_us == t_off + w_us)   
          pulse_vec <= pulse_vec & ~ch_m;
      end
    end
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin 
      s <= IDLE; 
      rd_idx <= '0; 
      busy <= 0; 
      done <= 0; 
    end else begin 
      s <= ns; 
    end
  end

  always_comb begin
    ns = s; 
    busy = 0; 
    done = 0;
    unique case (s)
      IDLE:  ns = arm ? ARMED : IDLE;
      ARMED: ns = (start || trig_ext) ? RUN : ARMED;
      RUN:   begin busy=1; end
      DONE:  begin done=1; ns = IDLE; end
    endcase
  end

endmodule
