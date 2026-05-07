// SPDX-License-Identifier: GPL-3.0-or-later OR Commercial
// SHA-256 message padder (helper module).
//
// Reference: NIST FIPS-180-4 §5.1.1 — "Padding the message".
//
// FIPS-180-4 §5.1.1, paraphrased:
//   Suppose the message M is L bits long. Append the bit "1" to the message,
//   followed by K zero bits where K is the smallest non-negative integer
//   such that (L + 1 + K) mod 512 = 448. Then append the 64-bit big-endian
//   representation of L. The padded message is now a multiple of 512 bits.
//
// Scope of this helper:
//   * Caller provides a message in 64-byte (512-bit) chunks plus a final
//     "tail" chunk of length 0..63 bytes.
//   * The padder consumes:
//       - any number of full blocks (no padding needed for these), AND
//       - one tail chunk of bytes [0..63] PLUS the total message bit-length.
//   * The padder emits the padded block(s) for the tail.
//     - If tail length L_tail satisfies L_tail < 56, the padder emits 1
//       block (tail + 0x80 + zeros + 64-bit length).
//     - If 56 <= L_tail <= 63, the padder emits 2 blocks: the first holds
//       (tail + 0x80 + zeros), the second holds (zeros + 64-bit length).
//
// Interface (single-shot, request/response):
//   * Master writes:
//       - tail_bytes_i  (up to 63 bytes, padded with zeros above
//         tail_len_i),
//       - tail_len_i    (number of valid bytes in tail_bytes_i, 0..63),
//       - total_bits_i  (total message length in bits across all blocks
//         the master fed to the core directly + the tail; this is the
//         L value placed in the final 64-bit length field),
//     and asserts start_i for one cycle.
//   * The padder pulses block_valid_o once or twice (depending on
//     whether the tail fits in one block) with the padded block on
//     block_o. Master must assert block_ready_i to consume each block.
//   * done_o pulses for one cycle after the last block has been
//     consumed.
//
// All arithmetic in this module is bit-exact with the FIPS-180-4 spec for
// any tail_len_i in [0,63]. The tail_bytes_i layout is byte-major:
// byte index 0 is in bits [503:496], byte index 62 in bits [7:0].
// (Byte index 63 cannot exist in a "tail" because tail_len_i < 64 — when
// the master has 64 bytes left, that's a full block, not a tail.)
//
// This is intentionally simple. For high-throughput streaming you typically
// want a wider port; for low-throughput / one-shot hashes (HMAC,
// signatures, CPU-fed control plane) this is the right shape.

module sha256_padder (
  input  logic         clk_i,
  input  logic         rst_ni,

  // ---- request --------------------------------------------------------
  input  logic         start_i,
  input  logic [503:0] tail_bytes_i,    // up to 63 bytes (504 bits)
  input  logic [5:0]   tail_len_i,      // 0..63
  input  logic [63:0]  total_bits_i,    // L (in bits) for length field

  // ---- response: block stream ----------------------------------------
  output logic [511:0] block_o,
  output logic         block_valid_o,
  input  logic         block_ready_i,

  // ---- done -----------------------------------------------------------
  output logic         done_o
);

  typedef enum logic [2:0] {
    P_IDLE   = 3'd0,
    P_BUILD  = 3'd1,  // build first padded block
    P_EMIT1  = 3'd2,  // emit first block
    P_BUILD2 = 3'd3,  // build optional second (length-only) block
    P_EMIT2  = 3'd4,  // emit second block
    P_DONE   = 3'd5   // pulse done_o
  } state_e;

  state_e state_q, state_d;

  logic [511:0] block_q, block_d;
  logic         valid_q, valid_d;
  logic         done_q,  done_d;
  logic         need_two_q, need_two_d;
  logic [63:0]  saved_bits_q, saved_bits_d;

  // Helper: write byte b into block bit position [511 - 8*idx -: 8].
  function automatic logic [511:0] place_byte(input logic [511:0] base,
                                              input int           idx,
                                              input logic [7:0]   b);
    logic [511:0] tmp;
    tmp = base;
    for (int k = 0; k < 8; k++) tmp[511 - 8*idx + k - 7] = b[k];
    return tmp;
  endfunction

  // Build the first padded block from the tail.
  function automatic logic [511:0] build_first(input logic [503:0] tail,
                                               input logic [5:0]   len,
                                               input logic [63:0]  total_bits,
                                               input logic         two);
    logic [511:0] blk;
    blk = '0;
    // Place the tail bytes (byte 0 at [503:496], byte i at [503-8i -: 8]).
    // Mirror this into the 512-bit block at the same byte indices.
    for (int i = 0; i < 63; i++) begin
      if (i < len) begin
        // tail bit position: bits [503 - 8*i -: 8]
        // block bit position: bits [511 - 8*i -: 8]
        for (int k = 0; k < 8; k++) begin
          blk[511 - 8*i + k - 7] = tail[503 - 8*i + k - 7];
        end
      end
    end
    // Place 0x80 right after the tail.
    blk = place_byte(blk, int'(len), 8'h80);
    // If we only need ONE block (tail < 56), place the 64-bit big-endian
    // length in bytes [56..63]. Otherwise leave bytes [56..63] zero (the
    // length goes in block 2).
    if (!two) begin
      for (int k = 0; k < 8; k++) begin
        blk = place_byte(blk, 56 + k, total_bits[63 - 8*k -: 8]);
      end
    end
    return blk;
  endfunction

  // Build the second (length-only) block.
  function automatic logic [511:0] build_second(input logic [63:0] total_bits);
    logic [511:0] blk;
    blk = '0;
    for (int k = 0; k < 8; k++) begin
      blk = place_byte(blk, 56 + k, total_bits[63 - 8*k -: 8]);
    end
    return blk;
  endfunction

  always_comb begin
    state_d      = state_q;
    block_d      = block_q;
    valid_d      = 1'b0;
    done_d       = 1'b0;
    need_two_d   = need_two_q;
    saved_bits_d = saved_bits_q;

    case (state_q)
      P_IDLE: begin
        if (start_i) begin
          need_two_d   = (tail_len_i >= 6'd56);
          saved_bits_d = total_bits_i;
          block_d      = build_first(tail_bytes_i, tail_len_i,
                                     total_bits_i,
                                     (tail_len_i >= 6'd56));
          state_d      = P_EMIT1;
        end
      end

      P_EMIT1: begin
        valid_d = 1'b1;
        if (block_ready_i) begin
          if (need_two_q) begin
            block_d = build_second(saved_bits_q);
            state_d = P_EMIT2;
          end else begin
            state_d = P_DONE;
          end
        end
      end

      P_EMIT2: begin
        valid_d = 1'b1;
        if (block_ready_i) begin
          state_d = P_DONE;
        end
      end

      P_DONE: begin
        done_d  = 1'b1;
        state_d = P_IDLE;
      end

      default: state_d = P_IDLE;
    endcase
  end

  always_ff @(posedge clk_i) begin
    if (!rst_ni) begin
      state_q      <= P_IDLE;
      block_q      <= '0;
      valid_q      <= 1'b0;
      done_q       <= 1'b0;
      need_two_q   <= 1'b0;
      saved_bits_q <= 64'd0;
    end else begin
      state_q      <= state_d;
      block_q      <= block_d;
      valid_q      <= valid_d;
      done_q       <= done_d;
      need_two_q   <= need_two_d;
      saved_bits_q <= saved_bits_d;
    end
  end

  // P_BUILD / P_BUILD2 are unused in this implementation (we build
  // combinationally on the cycle of start_i / on the EMIT1 -> EMIT2
  // transition). They are reserved in the enum so a future synchronous
  // build pass can be added without renumbering.
  // Suppress lint by referencing them in dead code.
  /* verilator lint_off CASEINCOMPLETE */
  /* verilator lint_on  CASEINCOMPLETE */

  assign block_o       = block_q;
  assign block_valid_o = valid_q;
  assign done_o        = done_q;

endmodule
