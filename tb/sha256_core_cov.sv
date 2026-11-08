// SPDX-License-Identifier: GPL-3.0-or-later OR LicenseRef-Commercial
//
// Functional coverage collector for sha256_core. Counts hits on the bins below
// from C++ via Verilator's --public-flat-rw, so the harness can read them at
// the end of the simulation and print a coverage percentage.
//
// Bins:
//   c_state_idle       FSM in S_IDLE at least once
//   c_state_run        FSM in S_RUN  at least once
//   c_state_update     FSM in S_UPDATE at least once
//   c_state_done       FSM in S_DONE at least once
//   c_single_block     a hash completed in a single block
//   c_multi_block      a hash spanned >=2 blocks (next_i seen after init_i)
//   c_back_to_back     two init_i'd hashes back-to-back
//   c_reset_mid_hash   reset asserted while state != IDLE
//
// Total: 8 bins. Coverage % = hits / 8 * 100.

module sha256_core_cov (
  input logic         clk_i,
  input logic         rst_ni,
  input logic         init_i,
  input logic         next_i,
  input logic         valid_i,
  input logic         ready_o,
  input logic         valid_o,
  input logic [1:0]   state_q
);

  localparam logic [1:0] L_IDLE   = 2'd0;
  localparam logic [1:0] L_RUN    = 2'd1;
  localparam logic [1:0] L_UPDATE = 2'd2;
  localparam logic [1:0] L_DONE   = 2'd3;

  // Public coverage flags. /*verilator public*/ exposes them to the C++ side.
  logic c_state_idle    /*verilator public*/;
  logic c_state_run     /*verilator public*/;
  logic c_state_update  /*verilator public*/;
  logic c_state_done    /*verilator public*/;
  logic c_single_block  /*verilator public*/;
  logic c_multi_block   /*verilator public*/;
  logic c_back_to_back  /*verilator public*/;
  logic c_reset_mid_hash/*verilator public*/;

  // Track per-hash state to distinguish single/multi-block.
  logic next_seen_in_hash_q;
  logic init_pending_q;        // last accepted command was init_i

  always_ff @(posedge clk_i) begin
    if (!rst_ni) begin
      // If FSM was busy when reset hit, count as mid-hash reset. Coverage
      // flags themselves are sticky: a reset between tests does not erase
      // prior bin hits.
      if (state_q != L_IDLE) c_reset_mid_hash <= 1'b1;
      next_seen_in_hash_q  <= 1'b0;
      init_pending_q       <= 1'b0;
    end else begin
      // FSM state coverage
      if (state_q == L_IDLE)   c_state_idle   <= 1'b1;
      if (state_q == L_RUN)    c_state_run    <= 1'b1;
      if (state_q == L_UPDATE) c_state_update <= 1'b1;
      if (state_q == L_DONE)   c_state_done   <= 1'b1;

      // Sample on accepted command (valid_i && ready_o)
      if (valid_i && ready_o) begin
        if (init_i) begin
          // Back-to-back if a previous hash was already running and we
          // immediately start a new one with init.
          if (init_pending_q) c_back_to_back <= 1'b1;
          // Reset multi-block tracker for new hash.
          next_seen_in_hash_q <= 1'b0;
          init_pending_q      <= 1'b1;
        end
        if (next_i) begin
          // A continuation block was accepted -> multi-block hash.
          c_multi_block       <= 1'b1;
          next_seen_in_hash_q <= 1'b1;
        end
      end

      // When valid_o pulses on the final block: classify single vs multi.
      // (For multi-block, c_multi_block was already set on the next_i.)
      if (valid_o && !next_seen_in_hash_q && init_pending_q) begin
        c_single_block <= 1'b1;
      end
    end
  end

  initial begin
    c_state_idle     = 1'b0;
    c_state_run      = 1'b0;
    c_state_update   = 1'b0;
    c_state_done     = 1'b0;
    c_single_block   = 1'b0;
    c_multi_block    = 1'b0;
    c_back_to_back   = 1'b0;
    c_reset_mid_hash = 1'b0;
  end

endmodule
