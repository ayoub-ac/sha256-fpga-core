// SPDX-License-Identifier: GPL-3.0-or-later OR LicenseRef-Commercial
//
// Top-level testbench wrapper for sha256_core. Stimulus is driven from the C++
// harness (tb/sim_main.cpp); this module re-exports the DUT ports and binds:
//   * tb/sha256_core_assertions.sv  -- SVA protocol checks
//   * tb/sha256_core_cov.sv         -- functional coverage collector

module sha256_core_tb (
  input  logic         clk_i,
  input  logic         rst_ni,
  input  logic         init_i,
  input  logic         next_i,
  input  logic [511:0] block_i,
  input  logic         valid_i,
  output logic         ready_o,
  output logic [255:0] digest_o,
  output logic         valid_o
);

  sha256_core u_dut (
    .clk_i    (clk_i),
    .rst_ni   (rst_ni),
    .init_i   (init_i),
    .next_i   (next_i),
    .block_i  (block_i),
    .valid_i  (valid_i),
    .ready_o  (ready_o),
    .digest_o (digest_o),
    .valid_o  (valid_o)
  );

  // Hierarchical references into the DUT for assertion / coverage observation.
  // These signals do not need to be at the module's port boundary.
  wire [6:0]  dut_round_q  = u_dut.round_q;
  wire [1:0]  dut_state_q  = u_dut.state_q;
  wire [31:0] dut_w_buf0_q = u_dut.W_buf_q[0];

  sha256_core_assertions u_assert (
    .clk_i    (clk_i),
    .rst_ni   (rst_ni),
    .init_i   (init_i),
    .next_i   (next_i),
    .valid_i  (valid_i),
    .ready_o  (ready_o),
    .valid_o  (valid_o),
    .block_i  (block_i),
    .digest_o (digest_o),
    .round_q  (dut_round_q),
    .state_q  (dut_state_q),
    .w_buf0_q (dut_w_buf0_q)
  );

  sha256_core_cov u_cov (
    .clk_i   (clk_i),
    .rst_ni  (rst_ni),
    .init_i  (init_i),
    .next_i  (next_i),
    .valid_i (valid_i),
    .ready_o (ready_o),
    .valid_o (valid_o),
    .state_q (dut_state_q)
  );

endmodule
