// SPDX-License-Identifier: GPL-3.0-or-later OR LicenseRef-Commercial
// Top-level wrapper for sha256_padder. Used by sim_padder.cpp to verify that
// the padder produces FIPS-180-4 §5.1.1 compliant output.

module sha256_padder_tb (
  input  logic         clk_i,
  input  logic         rst_ni,
  input  logic         start_i,
  input  logic [503:0] tail_bytes_i,
  input  logic [5:0]   tail_len_i,
  input  logic [63:0]  total_bits_i,
  output logic [511:0] block_o,
  output logic         block_valid_o,
  input  logic         block_ready_i,
  output logic         done_o
);

  sha256_padder u_dut (
    .clk_i         (clk_i),
    .rst_ni        (rst_ni),
    .start_i       (start_i),
    .tail_bytes_i  (tail_bytes_i),
    .tail_len_i    (tail_len_i),
    .total_bits_i  (total_bits_i),
    .block_o       (block_o),
    .block_valid_o (block_valid_o),
    .block_ready_i (block_ready_i),
    .done_o        (done_o)
  );

endmodule
