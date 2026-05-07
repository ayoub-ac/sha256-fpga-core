// SPDX-License-Identifier: GPL-3.0-or-later OR Commercial
// SHA-256 K[0..63] and H(0)[0..7] constants — preprocessor-includable form.
// Used by sha256_core.sv via `include "sha256_constants.svh"` so that older
// Yosys revisions which struggle with package imports still synthesize the
// core. The same constants are also exposed via the sha256_const_pkg
// package (see sha256_constants.sv).
//
// Reference: NIST FIPS-180-4 §4.2.2, §5.3.3.

`ifndef SHA256_CONSTANTS_SVH
`define SHA256_CONSTANTS_SVH

// Body of the K[t] case statement, used inside both the package function
// and the inline core function. Kept as a macro to avoid duplicating the
// 64 numeric literals in two places.
`define SHA256_K_BODY(IDX, OUT) \
  case (IDX) \
    6'd0:  OUT = 32'h428a2f98; \
    6'd1:  OUT = 32'h71374491; \
    6'd2:  OUT = 32'hb5c0fbcf; \
    6'd3:  OUT = 32'he9b5dba5; \
    6'd4:  OUT = 32'h3956c25b; \
    6'd5:  OUT = 32'h59f111f1; \
    6'd6:  OUT = 32'h923f82a4; \
    6'd7:  OUT = 32'hab1c5ed5; \
    6'd8:  OUT = 32'hd807aa98; \
    6'd9:  OUT = 32'h12835b01; \
    6'd10: OUT = 32'h243185be; \
    6'd11: OUT = 32'h550c7dc3; \
    6'd12: OUT = 32'h72be5d74; \
    6'd13: OUT = 32'h80deb1fe; \
    6'd14: OUT = 32'h9bdc06a7; \
    6'd15: OUT = 32'hc19bf174; \
    6'd16: OUT = 32'he49b69c1; \
    6'd17: OUT = 32'hefbe4786; \
    6'd18: OUT = 32'h0fc19dc6; \
    6'd19: OUT = 32'h240ca1cc; \
    6'd20: OUT = 32'h2de92c6f; \
    6'd21: OUT = 32'h4a7484aa; \
    6'd22: OUT = 32'h5cb0a9dc; \
    6'd23: OUT = 32'h76f988da; \
    6'd24: OUT = 32'h983e5152; \
    6'd25: OUT = 32'ha831c66d; \
    6'd26: OUT = 32'hb00327c8; \
    6'd27: OUT = 32'hbf597fc7; \
    6'd28: OUT = 32'hc6e00bf3; \
    6'd29: OUT = 32'hd5a79147; \
    6'd30: OUT = 32'h06ca6351; \
    6'd31: OUT = 32'h14292967; \
    6'd32: OUT = 32'h27b70a85; \
    6'd33: OUT = 32'h2e1b2138; \
    6'd34: OUT = 32'h4d2c6dfc; \
    6'd35: OUT = 32'h53380d13; \
    6'd36: OUT = 32'h650a7354; \
    6'd37: OUT = 32'h766a0abb; \
    6'd38: OUT = 32'h81c2c92e; \
    6'd39: OUT = 32'h92722c85; \
    6'd40: OUT = 32'ha2bfe8a1; \
    6'd41: OUT = 32'ha81a664b; \
    6'd42: OUT = 32'hc24b8b70; \
    6'd43: OUT = 32'hc76c51a3; \
    6'd44: OUT = 32'hd192e819; \
    6'd45: OUT = 32'hd6990624; \
    6'd46: OUT = 32'hf40e3585; \
    6'd47: OUT = 32'h106aa070; \
    6'd48: OUT = 32'h19a4c116; \
    6'd49: OUT = 32'h1e376c08; \
    6'd50: OUT = 32'h2748774c; \
    6'd51: OUT = 32'h34b0bcb5; \
    6'd52: OUT = 32'h391c0cb3; \
    6'd53: OUT = 32'h4ed8aa4a; \
    6'd54: OUT = 32'h5b9cca4f; \
    6'd55: OUT = 32'h682e6ff3; \
    6'd56: OUT = 32'h748f82ee; \
    6'd57: OUT = 32'h78a5636f; \
    6'd58: OUT = 32'h84c87814; \
    6'd59: OUT = 32'h8cc70208; \
    6'd60: OUT = 32'h90befffa; \
    6'd61: OUT = 32'ha4506ceb; \
    6'd62: OUT = 32'hbef9a3f7; \
    6'd63: OUT = 32'hc67178f2; \
    default: OUT = 32'h00000000; \
  endcase

`define SHA256_H0_BODY(IDX, OUT) \
  case (IDX) \
    3'd0: OUT = 32'h6a09e667; \
    3'd1: OUT = 32'hbb67ae85; \
    3'd2: OUT = 32'h3c6ef372; \
    3'd3: OUT = 32'ha54ff53a; \
    3'd4: OUT = 32'h510e527f; \
    3'd5: OUT = 32'h9b05688c; \
    3'd6: OUT = 32'h1f83d9ab; \
    3'd7: OUT = 32'h5be0cd19; \
    default: OUT = 32'h00000000; \
  endcase

`endif
