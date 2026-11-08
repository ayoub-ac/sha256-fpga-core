// SPDX-License-Identifier: GPL-3.0-or-later OR LicenseRef-Commercial
// NIST FIPS-180-4 Appendix B + NIST CAVP "Short Message" SHA-256 test vectors,
// as a SystemVerilog package for non-Verilator simulators.
//
// Sources:
//   * FIPS-180-4 Appendix B.1 (one-block, "abc")
//   * FIPS-180-4 Appendix B.2 (two-block, 448-bit)
//   * NIST CAVP SHA Test Vectors for Hashing Byte-Oriented Messages,
//     <https://csrc.nist.gov/projects/cryptographic-algorithm-validation-program>
//     SHA256ShortMsg.rsp, selected entries.
//
// The expected digest is given as the canonical hex string. Each test
// vector also gives the message in hex (msb-first) and the message length
// in bits. The C++ harness in tb/sim_main.cpp consumes these (compiled into
// the binary as a struct array — see tb/sim_main.cpp); this file is the
// SystemVerilog equivalent for users who want to re-run the same vectors
// in Vivado / Modelsim / Questa.

`ifndef SHA256_NIST_VECTORS_SVH
`define SHA256_NIST_VECTORS_SVH

package sha256_nist_vectors_pkg;

  typedef struct {
    string name;
    int    msg_bits;     // length of message in bits
    string msg_hex;      // message bytes as hex (empty string for L=0)
    string digest_hex;   // expected 256-bit digest as 64 hex chars
  } sha256_vec_t;

  // FIPS-180-4 Appendix B.1: "abc"
  // L = 24 bits
  // expected = ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad
  localparam sha256_vec_t kVecAbc = '{
    name:       "FIPS-180-4 App.B.1 (\"abc\")",
    msg_bits:   24,
    msg_hex:    "616263",
    digest_hex: "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
  };

  // Empty message
  // L = 0
  // expected = e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855
  localparam sha256_vec_t kVecEmpty = '{
    name:       "Empty message",
    msg_bits:   0,
    msg_hex:    "",
    digest_hex: "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
  };

  // FIPS-180-4 Appendix B.2: 448-bit message
  // "abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq"
  // L = 448 bits
  // expected = 248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1
  localparam sha256_vec_t kVec448 = '{
    name:       "FIPS-180-4 App.B.2 (448-bit)",
    msg_bits:   448,
    msg_hex:    "6162636462636465636465666465666765666768666768696768696a68696a6b696a6b6c6a6b6c6d6b6c6d6e6c6d6e6f6d6e6f706e6f7071",
    digest_hex: "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1"
  };

endpackage

`endif
