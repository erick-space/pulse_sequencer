//------------------------------------------------------------------------------
// pulse_sequencer.sv
//
// Multi-channel microsecond-timed pulse sequencer
//
// Description:
//   The pulse_sequencer generates precisely timed output pulses on multiple
//   channels based on a table of configuration entries. Each entry defines
//   when a pulse should start, how long it should remain asserted, and which
//   output channels are affected.
//
//   The sequencer operates on a 1-microsecond timebase and supports both
//   software and external triggering. Pulse timing is relative to the moment
//   the sequence is started, allowing the same table to be reused regardless
//   of absolute system time.
//
// Entry Format (rd_data, 64-bit):
//   [63:40] t_off   : Pulse start time offset from sequence start (microseconds)
//   [39:24] w_us    : Pulse width in microseconds (0 indicates end-of-sequence)
//   [23:8]  ch_m    : Channel mask (bit-per-channel pulse enable)
//   [7:0]   res     : Reserved for future use
//
// Notes:
//   - The table is assumed to be externally supplied (e.g., ROM/BRAM).
//   - A pulse width of zero (w_us == 0) marks the end of the sequence.
//   - The module is fully synchronous to clk, except for the async reset.
//
//------------------------------------------------------------------------------ 


module pulse_sequencer #(
  parameter int CH      = 4,
  parameter int ENTRY_W = 64
)(
  input  logic        clk,
  input  logic        rst_n,

  // control
  input  logic        start,      // software trigger
  input  logic        arm,        // arm before start
  input  logic        tick_1us,   // 1 us timebase pulse
  input  logic        trig_ext,   // external trigger

  // table read side
  output logic [15:0] rd_idx,     // which entry to read
  input  logic [ENTRY_W-1:0] rd_data,

  // outputs
  output logic [CH-1:0] pulse_vec,
  output logic          busy,
  output logic          done,
  output logic          err_underrun
);

  // ------------------------------------------------------------
  // Entry format (64-bit)
  // [63:40] t_off  (24b)   : time offset from start, in us
  // [39:24] w_us   (16b)   : pulse width in us (0 => end)
  // [23:8]  ch_m   (16b)   : channel mask
  // [7:0]   res    (8b)    : reserved
  // ------------------------------------------------------------
  logic [23:0] t_off;
  logic [15:0] w_us;
  logic [15:0] ch_m;
  logic [7:0]  res;

  assign {t_off, w_us, ch_m, res} = rd_data;

  // ------------------------------------------------------------
  // State machine
  // ------------------------------------------------------------
  typedef enum logic [1:0] {IDLE, ARMED, RUN, DONE_ST} state_e;
  state_e s, ns;

  // global microsecond counter
  logic [31:0] now_us;

  // time at which we started the current run
  logic [31:0] base_us;

  // convenience: time since start
  logic [31:0] rel_us;

  // for detecting end-of-entry
  logic        entry_is_last;

  // ------------------------------------------------------------
  // 1 us counter (free running)
  // ------------------------------------------------------------
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n)
      now_us <= 32'd0;
    else if (tick_1us)
      now_us <= now_us + 1;
  end

  // time since run started
  assign rel_us = now_us - base_us;

  // detect "this is the last entry"
  // rule: width 0 => no more pulses
  assign entry_is_last = (w_us == 16'd0);

  // ------------------------------------------------------------
  // Pulse generation
  //   - pulses are relative to rel_us (time since start)
  //   - we widen arithmetic to 32b to avoid truncation
  // ------------------------------------------------------------
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      pulse_vec <= '0;
    end else if (tick_1us) begin
      // start pulse
      if (rel_us == {8'b0, t_off}) begin
        pulse_vec <= pulse_vec | ch_m[CH-1:0];
      end
      // end pulse
      // compute t_off + w_us in 32 bits
      if (rel_us == ({8'b0, t_off} + w_us)) begin
        pulse_vec <= pulse_vec & ~ch_m[CH-1:0];
      end
    end
  end

  // ------------------------------------------------------------
  // FSM + index + bookkeeping
  // ------------------------------------------------------------
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      s            <= IDLE;
      err_underrun <= 1'b0;
    end else begin
      s      <= ns;
      // outputs that are 'pulsed' are driven in comb below
    end
  end

  always_comb begin
    ns            = s;
    busy          = 1'b0;
    done          = 1'b0;
    // keep err_underrun sticky once set
    // (so don't clear it here)

    unique case (s)
      // --------------------------------------------------------
      // wait for arm
      // --------------------------------------------------------
      IDLE: begin
        if (arm) ns = ARMED;
      end

      // --------------------------------------------------------
      // armed: wait for start or external trigger
      // --------------------------------------------------------
      ARMED: begin
        if (start || trig_ext) begin
          ns = RUN;
        end
      end

      // --------------------------------------------------------
      // run: actively playing entries
      // --------------------------------------------------------
      RUN: begin
        busy = 1;

        // we exit RUN when:
        //  - the current entry says width == 0 (sentinel)
        //  - AND all pulses have been turned off for that entry
        //
        // simpler heuristic: if width==0, we're done
        if (entry_is_last) begin
          ns = DONE_ST;
        end
      end

      // --------------------------------------------------------
      // done: report completion then go idle
      // --------------------------------------------------------
      DONE_ST: begin
        done = 1;
        ns   = IDLE;
      end
    endcase
  end

  // ------------------------------------------------------------
  // Advance table index while running
  // Here’s one simple policy:
  //  - whenever we have just turned OFF the pulse for an entry,
  //    move to the next entry
  //  - the actual turn-off happens on a tick_1us compare, so we
  //    watch for that condition
  // ------------------------------------------------------------
  logic [31:0] t_on;
  logic [31:0] t_off32;
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      rd_idx  <= '0;
      base_us <= 32'd0;
    end else begin
      case (s)
        IDLE: begin
          rd_idx  <= '0;
          base_us <= base_us; // unchanged
        end

        ARMED: begin
          // capture start time when we actually trigger
          if (start || trig_ext) begin
            base_us <= now_us;
          end
        end

        RUN: begin
          // if this entry has a nonzero width, watch for its end
          if (tick_1us) begin

            t_on    = {8'b0, t_off};
            t_off32 = t_on + w_us;
            // when we reach the end of this entry's pulse,
            // move to next entry
            if (!entry_is_last && (rel_us == t_off32)) begin
              rd_idx <= rd_idx + 1;
            end
          end
        end

        default: ;
      endcase
    end
  end

  // ------------------------------------------------------------
  // (Optional) underrun detection hook
  // If the fabric feeding rd_data can't keep up, you could set
  // err_underrun when we need the next entry but haven't got it.
  // Right now we leave it sticky-only, not asserted.
  // ------------------------------------------------------------

endmodule
