// SPDX-License-Identifier: GPL-3.0-or-later OR LicenseRef-Commercial
// SHA-256 round constants K[0..63] from FIPS-180-4 §4.2.2 and initial hash
// values H(0)[0..7] from §5.3.3.
//
// These are exposed as `automatic` functions in the sha256_const_pkg
// package for tools that handle SystemVerilog packages cleanly (Verilator,
// Modelsim/Questa, Vivado), AND as a parallel set of `pure function`
// definitions inside the core via `include "sha256_constants.svh"` for
// older Yosys revisions that still struggle with package imports.
//
// In practice the core uses `include "sha256_constants.svh"` because that
// gives uniform behaviour across all simulators and all Yosys versions we
// target. The package definition below is provided as a non-instantiated
// declaration so users with their own SV-aware flow can pull in the same
// constants without re-defining them.
//
// Reference: NIST FIPS-180-4, "Secure Hash Standard (SHS)", August 2015,
//            §4.2.2 (K table) and §5.3.3 (initial hash values).

`ifndef SHA256_CONSTANTS_SV
`define SHA256_CONSTANTS_SV

`include "sha256_constants.svh"

/* verilator lint_off DECLFILENAME */
package sha256_const_pkg;
/* verilator lint_on  DECLFILENAME */

  // FIPS-180-4 §4.2.2: K[0..63]
  function automatic logic [31:0] sha256_k_pkg(input logic [5:0] t);
    logic [31:0] r;
    `SHA256_K_BODY(t, r)
    sha256_k_pkg = r;
  endfunction

  // FIPS-180-4 §5.3.3: H(0)[0..7]
  function automatic logic [31:0] sha256_h0_pkg(input logic [2:0] i);
    logic [31:0] r;
    `SHA256_H0_BODY(i, r)
    sha256_h0_pkg = r;
  endfunction

endpackage

`endif
