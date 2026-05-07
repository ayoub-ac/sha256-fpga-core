// SPDX-License-Identifier: GPL-3.0-or-later OR Commercial
//
// Standalone assertion module for sha256_core. Instantiated alongside the DUT
// in sha256_core_tb so the testbench can reuse the same protocol checks across
// any simulator (Verilator 5.x, Vivado xsim, ModelSim/Questa).
//
// Properties enforced:
//   p_valid_after_block       valid_o only fires exactly 67 cycles after a
//                             block is accepted (1 capture + 64 rounds + 1
//                             update + 1 valid pulse).
//   p_digest_stable           digest_o is stable while valid_o is asserted.
//   p_round_bound             internal round counter never exceeds 63.
//   p_no_init_during_run      init_i (and next_i) are ignored when the core
//                             is busy (state != IDLE); a transfer cannot be
//                             accepted while ready_o is low.
//   p_w_buffer_consistency    on the cycle a block is accepted, W_buf[0]
//                             equals block_i[511:480] (the first message
//                             word, FIPS-180-4 §6.2.1 M_0).
//
// Properties are wrapped in `ifndef SYNTHESIS so they are stripped on
// synthesis flows.

// BLOCK_LATENCY is measured in cycles since the cycle AFTER an accepted
// transfer (i.e. cycles_since_accept = 1 on the first cycle the FSM is in
// S_RUN). Total observed: 64 round cycles (S_RUN) + 1 update + 1 valid
// pulse = 66 cycles after the accept cycle. The "67 cycles per block" in
// PORT_DESCRIPTION.md counts the capture cycle as cycle 1.
module sha256_core_assertions #(
  parameter int BLOCK_LATENCY = 66
) (
  input logic         clk_i,
  input logic         rst_ni,
  input logic         init_i,
  input logic         next_i,
  input logic         valid_i,
  input logic         ready_o,
  input logic         valid_o,
  input logic [511:0] block_i,
  input logic [255:0] digest_o,
  input logic [6:0]   round_q,
  input logic [1:0]   state_q,
  input logic [31:0]  w_buf0_q
);
`ifndef SYNTHESIS

  localparam logic [1:0] L_IDLE = 2'd0;

  // Cycles since the last accepted block. Resets at every (valid_i && ready_o).
  int unsigned cycles_since_accept;
  always_ff @(posedge clk_i) begin
    if (!rst_ni)                       cycles_since_accept <= 0;
    else if (valid_i && ready_o)       cycles_since_accept <= 1;
    else if (cycles_since_accept != 0) cycles_since_accept <= cycles_since_accept + 1;
  end

  // ---------------------------------------------------------------------------
  // p_valid_after_block: valid_o never rises before exactly BLOCK_LATENCY
  // cycles have elapsed since the last accepted block.
  property p_valid_after_block;
    @(posedge clk_i) disable iff (!rst_ni)
      $rose(valid_o) |-> (cycles_since_accept == BLOCK_LATENCY);
  endproperty
  a_valid_after_block: assert property (p_valid_after_block)
    else $error("sha256_core_assertions: valid_o asserted at cycle %0d (expected %0d)",
                cycles_since_accept, BLOCK_LATENCY);

  // ---------------------------------------------------------------------------
  // p_digest_stable: digest_o is stable while valid_o is held high.
  property p_digest_stable;
    @(posedge clk_i) disable iff (!rst_ni)
      valid_o |=> (!valid_o || $stable(digest_o));
  endproperty
  a_digest_stable: assert property (p_digest_stable)
    else $error("sha256_core_assertions: digest_o changed while valid_o asserted");

  // ---------------------------------------------------------------------------
  // p_round_bound: round_q never exceeds 63.
  property p_round_bound;
    @(posedge clk_i) disable iff (!rst_ni) (round_q <= 7'd63);
  endproperty
  a_round_bound: assert property (p_round_bound)
    else $error("sha256_core_assertions: round_q = %0d exceeds 63", round_q);

  // ---------------------------------------------------------------------------
  // p_no_init_during_run: when the core is busy (state != IDLE) the master
  // cannot land a transfer. Equivalent: ready_o is low whenever state != IDLE,
  // so valid_i alongside init_i is ignored.
  property p_no_init_during_run;
    @(posedge clk_i) disable iff (!rst_ni)
      (state_q != L_IDLE) |-> !ready_o;
  endproperty
  a_no_init_during_run: assert property (p_no_init_during_run)
    else $error("sha256_core_assertions: ready_o high while state_q != IDLE");

  // ---------------------------------------------------------------------------
  // p_w_buffer_consistency: when a block is accepted, the FIRST message word
  // (block_i[511:480]) must land in W_buf[0] on the next cycle, and on the
  // last round W_buf[0] holds the W[63] value derived from the schedule.
  // We check the first-word property here (most easily provable from external
  // ports); the schedule recurrence is verified by the FIPS-180-4 vectors.
  property p_w_buffer_first_word;
    @(posedge clk_i) disable iff (!rst_ni)
      (valid_i && ready_o) |=> (w_buf0_q == $past(block_i[511:480]));
  endproperty
  a_w_buffer_first_word: assert property (p_w_buffer_first_word)
    else $error("sha256_core_assertions: W_buf[0] != block_i[511:480] after capture");

`endif // SYNTHESIS
endmodule
