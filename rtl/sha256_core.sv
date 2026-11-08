// SPDX-License-Identifier: GPL-3.0-or-later OR LicenseRef-Commercial
// SHA-256 iterative core, one round per cycle.
//
// Reference: NIST FIPS-180-4, "Secure Hash Standard (SHS)", August 2015,
//            sections 5.3.3 (initial hash values), 6.2 (SHA-256 hash
//            computation), and 4.1.2 / 4.2.2 (logical functions and K[]).
//
// Architecture:
//   * Streaming, one 512-bit block at a time. Caller pre-pads the message
//     per FIPS-180-4 §5.1.1; this core does not pad.
//   * 64 round cycles per block (one round/cycle).
//   * Message schedule W[0..63] is generated on the fly using a 16-word
//     rolling buffer (FIPS-180-4 §6.2.2 step 1):
//
//         W[t]  = M[t]                                          for t < 16
//         W[t]  = SSIG1(W[t-2]) + W[t-7] + SSIG0(W[t-15]) + W[t-16]
//                                                                for t >= 16
//
//     Implemented as a 16-deep shift register: at every cycle we emit
//     w_now = W[t] (the front of the buffer), then shift in the next
//     scheduled word for the t+16 slot.
//
//   * After 64 rounds, the working variables (a..h) are added back into
//     the running hash H[0..7] (FIPS-180-4 §6.2.2 step 4). H is held
//     across blocks so the caller can feed multiple blocks for a long
//     message; H is reset to FIPS-180-4 §5.3.3 H(0) when init_i is taken.
//
// Handshake (master <-> core):
//   * init_i (single-cycle pulse, with valid_i and the FIRST block on
//     block_i) starts a fresh hash: H is loaded from sha256_h0() and the
//     block is consumed.
//   * next_i (single-cycle pulse, with valid_i and a subsequent block)
//     processes another block of the same message; H is preserved.
//   * exactly one of init_i / next_i must be high together with valid_i.
//   * ready_o is high when the core can accept a new block. The core
//     drops ready_o for the duration of the 64 round cycles + a small
//     amount of FSM overhead.
//   * valid_o pulses for one cycle when the digest reflects all blocks
//     consumed so far. digest_o is the running hash after the last block
//     accepted; it is stable while ready_o is low after the final block,
//     and is updated after every block.
//
// Reset: rst_ni is active-low synchronous. After reset all state is zero
//        and ready_o is high; the next valid_i must come with init_i to
//        start a fresh hash (next_i alone after reset is undefined).

`include "sha256_constants.svh"

module sha256_core (
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

  // ---- FIPS-180-4 §4.2.2 K[t] / §5.3.3 H(0)[i] (see sha256_constants.svh)
  function automatic logic [31:0] sha256_k(input logic [5:0] t);
    logic [31:0] r;
    `SHA256_K_BODY(t, r)
    sha256_k = r;
  endfunction
  function automatic logic [31:0] sha256_h0(input logic [2:0] i);
    logic [31:0] r;
    `SHA256_H0_BODY(i, r)
    sha256_h0 = r;
  endfunction

  // ---------- FSM -----------------------------------------------------------
  typedef enum logic [1:0] {
    S_IDLE   = 2'd0,
    S_RUN    = 2'd1,  // running 64 rounds
    S_UPDATE = 2'd2,  // adding (a..h) into H
    S_DONE   = 2'd3   // pulsing valid_o
  } state_e;

  state_e      state_q, state_d;
  logic [6:0]  round_q, round_d;     // 0..64 (need >= 7 bits)

  // ---------- working variables a..h (FIPS-180-4 §6.2.2) -------------------
  logic [31:0] a_q, b_q, c_q, d_q, e_q, f_q, g_q, h_q;
  logic [31:0] a_d, b_d, c_d, d_d, e_d, f_d, g_d, h_d;
  logic [31:0] a_n, b_n, c_n, d_n, e_n, f_n, g_n, h_n;

  // ---------- running hash H[0..7] -----------------------------------------
  logic [31:0] H_q [0:7];
  logic [31:0] H_d [0:7];

  // ---------- message schedule rolling buffer W[t..t+15] -------------------
  // W_buf[0] is the W[t] used by the current round. After each round we
  // shift one position and load the new W[t+16] (or, for the first 16
  // rounds, the next message word) into W_buf[15].
  logic [31:0] W_buf_q [0:15];
  logic [31:0] W_buf_d [0:15];
  logic [31:0] w_now;        // = W_buf_q[0], passed to sha256_round
  logic [31:0] w_next;       // computed per FIPS-180-4 §6.2.2 step 1

  // ---------- combinational round next-state ------------------------------
  logic [31:0] k_now;
  assign k_now = sha256_k(round_q[5:0]);
  assign w_now = W_buf_q[0];

  sha256_round u_round (
    .a_i (a_q), .b_i (b_q), .c_i (c_q), .d_i (d_q),
    .e_i (e_q), .f_i (f_q), .g_i (g_q), .h_i (h_q),
    .k_i (k_now),
    .w_i (w_now),
    .a_o (a_n), .b_o (b_n), .c_o (c_n), .d_o (d_n),
    .e_o (e_n), .f_o (f_n), .g_o (g_n), .h_o (h_n)
  );

  // ---------- small-sigma helpers (FIPS-180-4 §4.1.2) ---------------------
  function automatic logic [31:0] rotr(input logic [31:0] x, input int n);
    rotr = (x >> n) | (x << (32 - n));
  endfunction
  function automatic logic [31:0] ssig0(input logic [31:0] x);
    ssig0 = rotr(x, 7) ^ rotr(x, 18) ^ (x >> 3);
  endfunction
  function automatic logic [31:0] ssig1(input logic [31:0] x);
    ssig1 = rotr(x, 17) ^ rotr(x, 19) ^ (x >> 10);
  endfunction

  // W[t+16] (FIPS-180-4 §6.2.2 step 1):
  //   W[t+16] = SSIG1(W[t+14]) + W[t+9] + SSIG0(W[t+1]) + W[t]
  // In our rolling buffer indices: buf[14], buf[9], buf[1], buf[0].
  assign w_next = ssig1(W_buf_q[14]) + W_buf_q[9]
                + ssig0(W_buf_q[1])  + W_buf_q[0];

  // ---------- FSM next-state logic ----------------------------------------
  always_comb begin
    state_d = state_q;
    round_d = round_q;

    a_d = a_q; b_d = b_q; c_d = c_q; d_d = d_q;
    e_d = e_q; f_d = f_q; g_d = g_q; h_d = h_q;

    for (int i = 0; i < 8; i++) H_d[i] = H_q[i];
    for (int i = 0; i < 16; i++) W_buf_d[i] = W_buf_q[i];

    case (state_q)
      // ----------------------------------------------------------------
      S_IDLE: begin
        if (valid_i && (init_i ^ next_i)) begin
          // Load message block (big-endian: word 0 = block_i[511:480])
          // FIPS-180-4 §6.2: M = (M_0 || M_1 || ... || M_15)
          for (int i = 0; i < 16; i++) begin
            W_buf_d[i] = block_i[511 - 32*i -: 32];
          end

          if (init_i) begin
            // Fresh hash: H gets the FIPS-180-4 §5.3.3 initial values
            for (int i = 0; i < 8; i++) H_d[i] = sha256_h0(i[2:0]);
            a_d = sha256_h0(3'd0);
            b_d = sha256_h0(3'd1);
            c_d = sha256_h0(3'd2);
            d_d = sha256_h0(3'd3);
            e_d = sha256_h0(3'd4);
            f_d = sha256_h0(3'd5);
            g_d = sha256_h0(3'd6);
            h_d = sha256_h0(3'd7);
          end else begin
            // Continuation block: working vars seeded from current H
            a_d = H_q[0];
            b_d = H_q[1];
            c_d = H_q[2];
            d_d = H_q[3];
            e_d = H_q[4];
            f_d = H_q[5];
            g_d = H_q[6];
            h_d = H_q[7];
          end
          round_d = 7'd0;
          state_d = S_RUN;
        end
      end

      // ----------------------------------------------------------------
      S_RUN: begin
        // Apply combinational round
        a_d = a_n; b_d = b_n; c_d = c_n; d_d = d_n;
        e_d = e_n; f_d = f_n; g_d = g_n; h_d = h_n;

        // Shift schedule buffer: buf[i] <= buf[i+1] for i in 0..14
        for (int i = 0; i < 15; i++) W_buf_d[i] = W_buf_q[i+1];
        // Load W[t+16] into buf[15]; for t < 48 this is the schedule
        // expansion; for t in 48..63 the value will never be read again
        // (all 64 rounds consume W from the front of the buffer), so the
        // overwrite is harmless.
        W_buf_d[15] = w_next;

        if (round_q == 7'd63) begin
          state_d = S_UPDATE;
        end else begin
          round_d = round_q + 7'd1;
        end
      end

      // ----------------------------------------------------------------
      S_UPDATE: begin
        // FIPS-180-4 §6.2.2 step 4: H[i] += working_var[i]
        H_d[0] = H_q[0] + a_q;
        H_d[1] = H_q[1] + b_q;
        H_d[2] = H_q[2] + c_q;
        H_d[3] = H_q[3] + d_q;
        H_d[4] = H_q[4] + e_q;
        H_d[5] = H_q[5] + f_q;
        H_d[6] = H_q[6] + g_q;
        H_d[7] = H_q[7] + h_q;
        state_d = S_DONE;
      end

      // ----------------------------------------------------------------
      S_DONE: begin
        // Pulse valid_o for one cycle (driven combinationally below from
        // state_q == S_DONE), then return to idle.
        state_d = S_IDLE;
      end

      default: state_d = S_IDLE;
    endcase
  end

  // ---------- registers ----------------------------------------------------
  always_ff @(posedge clk_i) begin
    if (!rst_ni) begin
      state_q <= S_IDLE;
      round_q <= 7'd0;
      a_q <= 32'd0; b_q <= 32'd0; c_q <= 32'd0; d_q <= 32'd0;
      e_q <= 32'd0; f_q <= 32'd0; g_q <= 32'd0; h_q <= 32'd0;
      for (int i = 0; i < 8; i++)  H_q[i]      <= 32'd0;
      for (int i = 0; i < 16; i++) W_buf_q[i]  <= 32'd0;
    end else begin
      state_q <= state_d;
      round_q <= round_d;
      a_q <= a_d; b_q <= b_d; c_q <= c_d; d_q <= d_d;
      e_q <= e_d; f_q <= f_d; g_q <= g_d; h_q <= h_d;
      for (int i = 0; i < 8; i++)  H_q[i]      <= H_d[i];
      for (int i = 0; i < 16; i++) W_buf_q[i]  <= W_buf_d[i];
    end
  end

  // ---------- outputs ------------------------------------------------------
  assign ready_o = (state_q == S_IDLE);
  assign valid_o = (state_q == S_DONE);

  // Concatenate H[0]..H[7] with H[0] as the most-significant 32 bits, per
  // FIPS-180-4 §6.2.2: "The resulting 256-bit message digest of the message
  // M is H_0^(N) || H_1^(N) || ... || H_7^(N)."
  assign digest_o = {H_q[0], H_q[1], H_q[2], H_q[3],
                     H_q[4], H_q[5], H_q[6], H_q[7]};

endmodule
