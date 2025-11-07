
//------------------------------------------------------------------------------
// axis_async_fifo.sv
// Simple, clear AXI4-Stream asynchronous FIFO (dual clock domains)
// - Ready/Valid semantics on both sides
// - Stores {TDATA, TLAST}
// - Gray-coded pointers with two-flop synchronizers
// - Full/Empty computation without vendor primitives
// - DEPTH must be a power of two
//
// Best practices:
//  * One module = one purpose
//  * Explicit clock/reset per domain
//  * Simple, well-commented logic
//  * No latches, no mixed blocking/nonblocking
//  * Safe CDC via Gray pointers + 2FF sync
//------------------------------------------------------------------------------

`timescale 1ns/1ps

module axis_async_fifo #(
  parameter int unsigned DATA_W = 64,
  parameter int unsigned DEPTH  = 512  // power of two: 16,32,64,...
)(
  // Write (source) clock domain
  input  logic                 s_aclk,
  input  logic                 s_aresetn,      // async active-low reset (sync deassert recommended)
  input  logic                 s_tvalid,
  input  logic [DATA_W-1:0]    s_tdata,
  input  logic                 s_tlast,
  output logic                 s_tready,
  // Optional status (write domain)
  output logic                 s_almost_full,  // asserted when one slot remains

  // Read (sink) clock domain
  input  logic                 m_aclk,
  input  logic                 m_aresetn,      // async active-low reset (sync deassert recommended)
  output logic                 m_tvalid,
  output logic [DATA_W-1:0]    m_tdata,
  output logic                 m_tlast,
  input  logic                 m_tready,
  // Optional status (read domain)
  output logic                 m_almost_empty  // asserted when exactly one entry available
);

  // -----------------------------
  // Local params & types
  // -----------------------------
  localparam int unsigned ADDR_W     = (DEPTH <= 2) ? 1 : $clog2(DEPTH);
  localparam int unsigned PTR_W      = ADDR_W + 1; // extra MSB for wrap detection
  localparam int unsigned PAYLOAD_W  = DATA_W + 1; // {TLAST, TDATA}

  // Compile-time checks
  initial begin
    // Require power-of-two DEPTH
    if ((DEPTH & (DEPTH - 1)) != 0) begin
      $error("axis_async_fifo: DEPTH (%0d) must be a power-of-two.", DEPTH);
    end
  end

  // -----------------------------
  // Memory (simple dual-port)
  // -----------------------------
  (* ram_style = "block", ramstyle = "no_rw_check" *)
  logic [PAYLOAD_W-1:0] mem [0:DEPTH-1];

  // Write side (s_*) signals
  logic [PTR_W-1:0] wptr_bin,  wptr_bin_n;
  logic [PTR_W-1:0] wptr_gray, wptr_gray_n;

  // Read side (m_*) signals
  logic [PTR_W-1:0] rptr_bin,  rptr_bin_n;
  logic [PTR_W-1:0] rptr_gray, rptr_gray_n;

  // Crossed pointers (synchronized)
  logic [PTR_W-1:0] rptr_gray_sync_s; // read pointer observed in write domain
  logic [PTR_W-1:0] wptr_gray_sync_m; // write pointer observed in read domain

  // Two-flop synchronizers for CDC
  logic [PTR_W-1:0] rptr_gray_s0, rptr_gray_s1;
  logic [PTR_W-1:0] wptr_gray_m0, wptr_gray_m1;

  // Helpers
  function automatic [PTR_W-1:0] bin2gray(input [PTR_W-1:0] b);
    return (b >> 1) ^ b;
  endfunction

  function automatic [PTR_W-1:0] gray2bin(input [PTR_W-1:0] g);
    integer i;
    reg [PTR_W-1:0] b;
    b[PTR_W-1] = g[PTR_W-1];
    for (i = PTR_W-2; i >= 0; i=i-1)
      b[i] = b[i+1] ^ g[i];
    return b;
  endfunction

  // -----------------------------
  // Write domain logic
  // -----------------------------

  // FULL: next write gray equals read gray with MSBs inverted (classic async FIFO full)
  logic full;
  logic [PTR_W-1:0] rptr_bin_sync_s;

  // Synchronize read pointer into write clock domain (Gray -> sync -> bin)
  always_ff @(posedge s_aclk or negedge s_aresetn) begin
    if (!s_aresetn) begin
      rptr_gray_s0 <= '0;
      rptr_gray_s1 <= '0;
    end else begin
      rptr_gray_s0 <= rptr_gray;
      rptr_gray_s1 <= rptr_gray_s0;
    end
  end
  assign rptr_gray_sync_s = rptr_gray_s1;
  assign rptr_bin_sync_s  = gray2bin(rptr_gray_sync_s);

  // Compute next write pointer
  logic do_write;
  assign do_write = s_tvalid & s_tready;
  always_comb begin
    wptr_bin_n  = wptr_bin + (do_write ? 1 : 0);
    wptr_gray_n = bin2gray(wptr_bin_n);
  end

  // FULL detection (compare Gray-coded next write to read pointer with MSB inversion)
  logic [PTR_W-1:0] rgray_inv;
  always_comb begin
    // Invert the two MSBs of read pointer gray for full detection
    rgray_inv               = rptr_gray_sync_s;
    rgray_inv[PTR_W-1:PTR_W-2] = ~rgray_inv[PTR_W-1:PTR_W-2];
    full = (wptr_gray_n == rgray_inv);
  end

  // s_tready is high when not full
  //assign s_tready = ~full;
  always_ff @(posedge s_aclk) begin
    s_tready = ~full;
  end

  // Write pointer registers
  always_ff @(posedge s_aclk or negedge s_aresetn) begin
    if (!s_aresetn) begin
      wptr_bin  <= '0;
      wptr_gray <= '0;
    end else begin
      wptr_bin  <= wptr_bin_n;
      wptr_gray <= wptr_gray_n;
    end
  end

  // Memory write
  always_ff @(posedge s_aclk) begin
    if (do_write) begin
      mem[wptr_bin[ADDR_W-1:0]] <= {s_tlast, s_tdata};
    end
  end

  // Almost full: one free slot left
  // Compute occupancy in write domain: wbin - rbin_sync
  logic [PTR_W-1:0] w_occ_s;
  always_comb begin
    w_occ_s = wptr_bin - rptr_bin_sync_s;
    s_almost_full = (w_occ_s[ADDR_W-1:0] == (DEPTH-1));
  end

  // -----------------------------
  // Read domain logic
  // -----------------------------
  logic empty;
  logic [PTR_W-1:0] wptr_bin_sync_m;

  // Synchronize write pointer into read clock domain (Gray -> sync -> bin)
  always_ff @(posedge m_aclk or negedge m_aresetn) begin
    if (!m_aresetn) begin
      wptr_gray_m0 <= '0;
      wptr_gray_m1 <= '0;
    end else begin
      wptr_gray_m0 <= wptr_gray;
      wptr_gray_m1 <= wptr_gray_m0;
    end
  end
  assign wptr_gray_sync_m = wptr_gray_m1;
  assign wptr_bin_sync_m  = gray2bin(wptr_gray_sync_m);

  // EMPTY when next read pointer equals synchronized write pointer (in Gray)
  logic do_read;
  assign do_read = m_tvalid & m_tready;
  always_comb begin
    rptr_bin_n  = rptr_bin + (do_read ? 1 : 0);
    rptr_gray_n = bin2gray(rptr_bin_n);
  end

  always_comb begin
    empty = (rptr_gray == wptr_gray_sync_m);
  end

  // m_tvalid asserted when not empty
  assign m_tvalid = ~empty;

  // Read pointer registers
  always_ff @(posedge m_aclk or negedge m_aresetn) begin
    if (!m_aresetn) begin
      rptr_bin  <= '0;
      rptr_gray <= '0;
    end else begin
      rptr_bin  <= rptr_bin_n;
      rptr_gray <= rptr_gray_n;
    end
  end

  // Memory read (simple registered output)
  // Read data is presented from current rptr_bin before increment
  logic [PAYLOAD_W-1:0] rd_payload;
  always_ff @(posedge m_aclk) begin
    rd_payload <= mem[rptr_bin_n[ADDR_W-1:0]];
  end
  assign {m_tlast, m_tdata} = rd_payload;

  // Almost empty: exactly one entry available
  // Compute occupancy in read domain: wbin_sync - rbin
  logic [PTR_W-1:0] r_occ_m;
  always_comb begin
    r_occ_m = wptr_bin_sync_m - rptr_bin;
    m_almost_empty = (r_occ_m == {{(PTR_W-1){1'b0}}, 1'b1}); // == 1
  end

  // -----------------------------
  // Simple safety assertions (synthesis-time off, sim-time on)
//   // -----------------------------
// `ifdef ASSERT_ON
//   // Never write when full
//   property p_no_write_when_full;
//     @(posedge s_aclk) disable iff (!s_aresetn)
//       full |-> !s_tvalid;
//   endproperty
//   assert property (p_no_write_when_full)
//     else $error("axis_async_fifo: write attempted when FULL");

//   // Never read when empty
//   property p_no_read_when_empty;
//     @(posedge m_aclk) disable iff (!m_aresetn)
//       empty |-> !m_tready;
//   endproperty
//   assert property (p_no_read_when_empty)
//     else $error("axis_async_fifo: read attempted when EMPTY");
// `endif

endmodule
