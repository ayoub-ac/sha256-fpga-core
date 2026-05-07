// SPDX-License-Identifier: GPL-3.0-or-later OR Commercial
//
// HMAC-SHA-256 (FIPS-198-1 / RFC 2104) wrapper around sha256_core.
//
// Computes:
//
//     MAC = H( (K' XOR opad) || H((K' XOR ipad) || M) )
//
// where:
//   - K' is the HMAC key, zero-padded on the right to the SHA-256 block size
//     (512 bits / 64 bytes). If `key_len_i` exceeds 256 bits this wrapper
//     does NOT pre-hash; this implementation accepts keys of length 1..256
//     bits (which is the common HMAC key range and matches the IETF
//     recommendation in RFC 2104 section 3 of using a key the same size as
//     the hash output).
//   - ipad = 0x36 repeated 64 times.
//   - opad = 0x5c repeated 64 times.
//   - M is the message, fed as a stream of 512-bit blocks; the LAST block
//     must be marked with `data_last_i` and must already be padded by the
//     caller per FIPS-180-4 §5.1.1 with the length field reflecting the
//     length of M alone (NOT including the K'^ipad block).
//
// Key length (bits) is taken from `key_len_i` (range 0..256). Bits above
// `key_len_i` of `key_i` are ignored (treated as zero) when assembling K'.
//
// Handshake (caller side):
//   - Hold `key_i` / `key_len_i` stable from the start of a MAC until at
//     least the cycle after the inner key block has been consumed (the
//     wrapper latches K' once at the start; thereafter changes are ignored).
//   - Assert `data_valid_i` together with `data_block_i` and `data_last_i`.
//     A transfer is accepted on the rising edge where `data_valid_i &&
//     ready_o`. After acceptance, the caller can present the next block
//     (or wait for `mac_valid_o` if the last block was just accepted).
//   - `mac_valid_o` pulses for one cycle when `mac_o` reflects the final
//     MAC of the message just streamed in.

module hmac_sha256 (
  input  logic         clk_i,
  input  logic         rst_ni,
  input  logic [255:0] key_i,
  input  logic [8:0]   key_len_i,        // bits, 0..256
  input  logic [511:0] data_block_i,
  input  logic         data_last_i,
  input  logic         data_valid_i,
  output logic         ready_o,
  output logic [255:0] mac_o,
  output logic         mac_valid_o
);

  // ---------- HMAC key prep: K' = key_i zero-padded to 512 bits, with bits
  // above key_len_i forced to zero. Combinational (function of latched
  // key/key_len in latched_key_q).
  logic [255:0] latched_key_q;
  logic [8:0]   latched_klen_q;

  logic [511:0] k_prime;
  always_comb begin
    k_prime = {latched_key_q, 256'd0};
    for (int b = 0; b < 256; b++) begin
      if (b >= latched_klen_q) k_prime[511 - b] = 1'b0;
    end
  end

  // ---------- ipad / opad expansions (constants)
  localparam logic [511:0] IPAD = {64{8'h36}};
  localparam logic [511:0] OPAD = {64{8'h5c}};

  logic [511:0] inner_key_block;
  logic [511:0] outer_key_block;
  assign inner_key_block = k_prime ^ IPAD;
  assign outer_key_block = k_prime ^ OPAD;

  // ---------- single sha256_core handles both inner and outer hashes
  // sequentially. We drive its init/next pulses from our own FSM.
  logic         core_init;
  logic         core_next;
  logic [511:0] core_block;
  logic         core_valid_in;
  logic         core_ready;
  logic [255:0] core_digest;
  logic         core_valid_out;

  sha256_core u_core (
    .clk_i    (clk_i),
    .rst_ni   (rst_ni),
    .init_i   (core_init),
    .next_i   (core_next),
    .block_i  (core_block),
    .valid_i  (core_valid_in),
    .ready_o  (core_ready),
    .digest_o (core_digest),
    .valid_o  (core_valid_out)
  );

  // ---------- FSM
  typedef enum logic [3:0] {
    H_IDLE,            // capture key, push inner_key_block
    H_FEED_INNER_KEY,  // wait for ready, then issue init with inner_key_block
    H_WAIT_INNER_KEY,  // wait for valid_o on inner_key_block
    H_ACCEPT_DATA,     // ready_o high, accept caller's data_block as next
    H_WAIT_DATA,       // wait for valid_o after a data block
    H_LATCH_INNER,     // capture inner digest from core
    H_FEED_OUTER_KEY,  // push outer_key_block (init_i to start fresh hash)
    H_WAIT_OUTER_KEY,
    H_FEED_OUTER_INNER,// push padded inner-digest block (next_i)
    H_WAIT_OUTER_INNER,
    H_DONE             // pulse mac_valid_o
  } hstate_e;

  hstate_e state_q, state_d;
  logic    saw_last_q, saw_last_d;
  logic [255:0] inner_digest_q, inner_digest_d;
  logic [255:0] latched_key_d;
  logic [8:0]   latched_klen_d;

  // Pre-format the second outer block: H(inner) followed by FIPS-180-4
  // padding for a 768-bit total outer message (512 outer-key block + 256
  // inner-digest bits = 768 bits total, written in big-endian).
  //   bits [511:256] = inner_digest_q  (256 bits)
  //   bit  [255]     = 1'b1            (padding 0x80)
  //   bits [254:64]  = 0
  //   bits [63:0]    = 64'd768          (length in bits)
  logic [511:0] outer_pad_block;
  assign outer_pad_block = {inner_digest_q, 1'b1, 191'd0, 64'd768};

  always_comb begin
    state_d        = state_q;
    saw_last_d     = saw_last_q;
    inner_digest_d = inner_digest_q;
    latched_key_d  = latched_key_q;
    latched_klen_d = latched_klen_q;

    core_init      = 1'b0;
    core_next      = 1'b0;
    core_block     = 512'd0;
    core_valid_in  = 1'b0;

    ready_o        = 1'b0;
    mac_valid_o    = 1'b0;

    case (state_q)
      H_IDLE: begin
        // Latch the key on every cycle while idle so the caller can drive
        // it stably and we capture it before kicking off. We expose
        // ready_o here so the caller can present (key, first data block,
        // data_valid_i) simultaneously; we accept the data block in
        // H_ACCEPT_DATA below after the inner-key block has been processed.
        latched_key_d  = key_i;
        latched_klen_d = key_len_i;
        // Wait for the caller to assert data_valid_i (signalling there is
        // a message to MAC). This also gives the caller time to drive the
        // key stably without the FSM advancing past H_IDLE prematurely.
        if (data_valid_i) state_d = H_FEED_INNER_KEY;
      end

      H_FEED_INNER_KEY: begin
        if (core_ready) begin
          core_init     = 1'b1;
          core_block    = inner_key_block;
          core_valid_in = 1'b1;
          state_d       = H_WAIT_INNER_KEY;
        end
      end

      H_WAIT_INNER_KEY: begin
        if (core_valid_out) state_d = H_ACCEPT_DATA;
      end

      H_ACCEPT_DATA: begin
        ready_o = core_ready;
        if (data_valid_i && core_ready) begin
          core_next     = 1'b1;
          core_block    = data_block_i;
          core_valid_in = 1'b1;
          saw_last_d    = data_last_i;
          state_d       = H_WAIT_DATA;
        end
      end

      H_WAIT_DATA: begin
        if (core_valid_out) begin
          if (saw_last_q) state_d = H_LATCH_INNER;
          else            state_d = H_ACCEPT_DATA;
        end
      end

      H_LATCH_INNER: begin
        inner_digest_d = core_digest;
        state_d        = H_FEED_OUTER_KEY;
      end

      H_FEED_OUTER_KEY: begin
        if (core_ready) begin
          core_init     = 1'b1;            // start FRESH outer hash
          core_block    = outer_key_block;
          core_valid_in = 1'b1;
          state_d       = H_WAIT_OUTER_KEY;
        end
      end

      H_WAIT_OUTER_KEY: begin
        if (core_valid_out) state_d = H_FEED_OUTER_INNER;
      end

      H_FEED_OUTER_INNER: begin
        if (core_ready) begin
          core_next     = 1'b1;
          core_block    = outer_pad_block;
          core_valid_in = 1'b1;
          state_d       = H_WAIT_OUTER_INNER;
        end
      end

      H_WAIT_OUTER_INNER: begin
        if (core_valid_out) state_d = H_DONE;
      end

      H_DONE: begin
        mac_valid_o = 1'b1;
        state_d     = H_IDLE;
      end

      default: state_d = H_IDLE;
    endcase
  end

  always_ff @(posedge clk_i) begin
    if (!rst_ni) begin
      state_q        <= H_IDLE;
      saw_last_q     <= 1'b0;
      inner_digest_q <= 256'd0;
      latched_key_q  <= 256'd0;
      latched_klen_q <= 9'd0;
    end else begin
      state_q        <= state_d;
      saw_last_q     <= saw_last_d;
      inner_digest_q <= inner_digest_d;
      latched_key_q  <= latched_key_d;
      latched_klen_q <= latched_klen_d;
    end
  end

  assign mac_o = core_digest;

endmodule
