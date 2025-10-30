

module timebase_tick #(parameter int CLK_MHZ = 250) (
  input logic clk, rst_n,
  input logic [31:0] cfg_period_us, // usually 1
  output logic tick_1us
);

  localparam int CYCLES_PER_US = CLK_MHZ;
  logic [$clog2(CYCLES_PER_US*2)-1:0] cnt;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin 
      cnt<=0; 
      tick_1us<=0; 
    end else begin
      tick_1us <= 1'b0;
      if (cnt == CYCLES_PER_US*cfg_period_us-1) begin
        cnt <= '0; 
        tick_1us <= 1'b1;
      end else 
        cnt <= cnt + 1'b1;
    end
  end

endmodule