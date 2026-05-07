// SPDX-License-Identifier: GPL-3.0-or-later OR Commercial
//
// Testbench wrapper for hmac_sha256. Stimulus is driven from the C++ harness
// (tb/sim_hmac.cpp); this module just re-exports the DUT ports.

module hmac_test (
  input  logic         clk_i,
  input  logic         rst_ni,
  input  logic [255:0] key_i,
  input  logic [8:0]   key_len_i,
  input  logic [511:0] data_block_i,
  input  logic         data_last_i,
  input  logic         data_valid_i,
  output logic         ready_o,
  output logic [255:0] mac_o,
  output logic         mac_valid_o
);

  hmac_sha256 u_dut (
    .clk_i        (clk_i),
    .rst_ni       (rst_ni),
    .key_i        (key_i),
    .key_len_i    (key_len_i),
    .data_block_i (data_block_i),
    .data_last_i  (data_last_i),
    .data_valid_i (data_valid_i),
    .ready_o      (ready_o),
    .mac_o        (mac_o),
    .mac_valid_o  (mac_valid_o)
  );

endmodule
