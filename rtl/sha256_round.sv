// SPDX-License-Identifier: GPL-3.0-or-later OR Commercial
// SHA-256 single-round combinational logic.
//
// Implements the per-round update specified in FIPS-180-4 §6.2.2 step 3:
//
//   T1 = h + BSIG1(e) + CH(e,f,g) + K[t] + W[t]
//   T2 = BSIG0(a) + MAJ(a,b,c)
//   h  = g
//   g  = f
//   f  = e
//   e  = d + T1
//   d  = c
//   c  = b
//   b  = a
//   a  = T1 + T2
//
// Helper functions (FIPS-180-4 §4.1.2):
//   CH(x,y,z)    = (x AND y) XOR ((NOT x) AND z)
//   MAJ(x,y,z)   = (x AND y) XOR (x AND z) XOR (y AND z)
//   BSIG0(x)     = ROTR(x,2)  XOR ROTR(x,13) XOR ROTR(x,22)   // big sigma 0
//   BSIG1(x)     = ROTR(x,6)  XOR ROTR(x,11) XOR ROTR(x,25)   // big sigma 1
//
// All arithmetic is mod 2^32. The module is purely combinational; the parent
// FSM clocks (a..h) once per round.

module sha256_round (
  input  logic [31:0] a_i,
  input  logic [31:0] b_i,
  input  logic [31:0] c_i,
  input  logic [31:0] d_i,
  input  logic [31:0] e_i,
  input  logic [31:0] f_i,
  input  logic [31:0] g_i,
  input  logic [31:0] h_i,
  input  logic [31:0] k_i,         // K[t]
  input  logic [31:0] w_i,         // W[t]
  output logic [31:0] a_o,
  output logic [31:0] b_o,
  output logic [31:0] c_o,
  output logic [31:0] d_o,
  output logic [31:0] e_o,
  output logic [31:0] f_o,
  output logic [31:0] g_o,
  output logic [31:0] h_o
);

  // ---- right-rotate helper -------------------------------------------------
  function automatic logic [31:0] rotr(input logic [31:0] x, input int n);
    rotr = (x >> n) | (x << (32 - n));
  endfunction

  // ---- FIPS-180-4 §4.1.2 logical functions --------------------------------
  function automatic logic [31:0] ch(input logic [31:0] x,
                                     input logic [31:0] y,
                                     input logic [31:0] z);
    ch = (x & y) ^ (~x & z);
  endfunction

  function automatic logic [31:0] maj(input logic [31:0] x,
                                      input logic [31:0] y,
                                      input logic [31:0] z);
    maj = (x & y) ^ (x & z) ^ (y & z);
  endfunction

  function automatic logic [31:0] bsig0(input logic [31:0] x);
    bsig0 = rotr(x, 2) ^ rotr(x, 13) ^ rotr(x, 22);
  endfunction

  function automatic logic [31:0] bsig1(input logic [31:0] x);
    bsig1 = rotr(x, 6) ^ rotr(x, 11) ^ rotr(x, 25);
  endfunction

  // ---- T1, T2 (mod 2^32 implicit on logic add) ----------------------------
  logic [31:0] t1, t2;
  assign t1 = h_i + bsig1(e_i) + ch(e_i, f_i, g_i) + k_i + w_i;
  assign t2 = bsig0(a_i) + maj(a_i, b_i, c_i);

  // ---- next working variables (FIPS-180-4 §6.2.2 step 3) ------------------
  assign a_o = t1 + t2;
  assign b_o = a_i;
  assign c_o = b_i;
  assign d_o = c_i;
  assign e_o = d_i + t1;
  assign f_o = e_i;
  assign g_o = f_i;
  assign h_o = g_i;

endmodule
