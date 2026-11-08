# sha256-fpga-core

[![License: GPL-3.0-or-later or commercial](https://img.shields.io/badge/license-GPL--3.0%20%7C%20commercial-blue.svg)](LICENSE.md)

> **Status: experimental and unverified.** This core was written with AI assistance and has not been independently verified in simulation regressions, formal proofs or hardware. Claims in this repository about standards compliance, test results, timing and resource use are unverified. It has not been validated under NIST CAVP/CMVP and has not been evaluated for side-channel or fault-injection resistance. Do not use it in production or security-sensitive designs without your own verification. No support or maintenance is provided.

A small, synthesisable SHA-256 IP core in SystemVerilog. One round per cycle,
67-cycle iterative datapath, single clock domain. Targets iCE40, ECP5,
Xilinx 7-series, Cyclone V, and Tang Nano 9K.

The core implements the FIPS 180-4 algorithm (not validated). NIST
FIPS-180-4 Appendix B / NIST CAVP test vectors and a 1000-message cross-check
against Python `hashlib.sha256` are included in a Verilator testbench; results
not independently confirmed. No FPGA hardware is required to run the test suite.

The repository also includes an HMAC-SHA-256 wrapper that implements the
FIPS 198-1 / RFC 2104 algorithm (not validated). HMAC is intended for
authenticated-MAC use cases, because raw SHA-256 is vulnerable to
length-extension.

## Why this exists

Most freely available SHA-256 cores are either pre-2005 Verilog with no
testbench, pipelined-only (huge LUT cost), only verified against `"abc"`,
or licensed under unclear terms. This core is small, dual-licensed cleanly
(GPL for OSS use, commercial license for closed-source), shipped with a
real handshake protocol, NIST + CAVP vectors plus 1000 random
cross-validation vectors in the testbench, SystemVerilog assertions,
functional coverage, and a synthesis-comparison report across multiple
toolchains.

## Quickstart

```bash
git clone https://github.com/ayoub-ac/sha256-fpga-core.git
cd sha256-fpga-core
make lint test            # Verilator lint + run NIST vector tests
make test-padder          # padder helper conformance
make test-hmac            # HMAC-SHA-256 vs RFC 4231
make synth_report         # SYNTH_REPORT.md across iCE40/ECP5/Xilinx/Vivado/Quartus
```

Requires Verilator 5.0+ for simulation. Yosys 0.30+ for the open synth flow.

## Architecture

```
                   +-----------------+
       block_i --->|                 |
        init_i --->|   sha256_core   |---> digest_o
        next_i --->| (FSM + W sched) |
       valid_i --->| ready_o valid_o |---> valid_o
                   +--------+--------+
                            |
              +-------------+-------------+
              |             |             |
        sha256_round    W rolling      H[0..7]
        (combo CH/MAJ   buffer (16x32   running
         BSIG/SSIG)     FFs)            hash
```

FSM: `IDLE -> RUN (64c) -> UPDATE -> DONE -> IDLE`. The message schedule
W[t] is generated on the fly using a 16-deep rolling shift register
(FIPS-180-4 §6.2.2 step 1); after 64 round cycles the working variables
(a..h) are added back into the running hash H[0..7] (§6.2.2 step 4) which
is preserved across continuation blocks. Latency: 67 cycles per 512-bit
block (1 capture + 64 round + 1 update + 1 valid pulse; design intent,
unverified).

## Port table

| Signal     | Dir | Width | Description                                                                                                                            | FIPS-180-4 ref |
|------------|-----|-------|----------------------------------------------------------------------------------------------------------------------------------------|----------------|
| `clk_i`    | in  | 1     | System clock. All flops sample on the rising edge.                                                                                     | -              |
| `rst_ni`   | in  | 1     | Synchronous active-low reset. Hold low ≥4 cycles before first command.                                                                 | -              |
| `init_i`   | in  | 1     | Pulse with `valid_i` and the FIRST block of a fresh hash. Loads `H` from §5.3.3 initial values. Mutually exclusive with `next_i`.      | §5.3.3         |
| `next_i`   | in  | 1     | Pulse with `valid_i` and a continuation block. `H` is preserved. Mutually exclusive with `init_i`.                                     | §6.2           |
| `block_i`  | in  | 512   | Pre-padded 512-bit message block. Big-endian: bits `[511:480]` = M_0, bits `[31:0]` = M_15.                                            | §6.2.1         |
| `valid_i`  | in  | 1     | Master asserts when block + init/next are valid. Transfer accepted on `valid_i && ready_o`.                                            | -              |
| `ready_o`  | out | 1     | Core ready to accept a new block.                                                                                                      | -              |
| `digest_o` | out | 256   | Running hash. Bits `[255:224]` = H[0], bits `[31:0]` = H[7]. Stable from `valid_o` pulse until next block accepted.                    | §6.2.2 step 4  |
| `valid_o`  | out | 1     | Single-cycle pulse when `digest_o` reflects the block just consumed.                                                                   | -              |

See [`PORT_DESCRIPTION.md`](PORT_DESCRIPTION.md) for the full handshake
protocol with timing diagrams.

A separate `sha256_padder` helper module (`rtl/sha256_padder.sv`) is
provided for callers that want FIPS-180-4 §5.1.1 padding done in hardware.
The core itself does not pad — caller responsibility.

## Headline numbers

Unverified estimates attributed to `make synth` (Yosys 0.33, basic iterative
core). They have not been independently reproduced, and the clock frequencies
are not backed by place-and-route timing:

| Target           | LUT          | FF   | BRAM | Latency       | Throughput @ Fmax     |
|------------------|--------------|------|------|---------------|-----------------------|
| iCE40 UP5K       | 2208 SB_LUT4 | 1067 | 0    | 67 cycles/blk | ~382 Mbps @ 50 MHz    |
| ECP5 LFE5UM-25   | 1829 LUT4*   | 1067 | 0    | 67 cycles/blk | ~917 Mbps @ 120 MHz   |
| Xilinx Artix-7   | ~385 LUT     | 1067 | 0    | 67 cycles/blk | ~1.14 Gbps @ 150 MHz  |

\* ECP5 generic synth with Yosys does not pack the schedule buffer into
distributed RAM; `nextpnr-ecp5` packing is expected to reduce this several-fold
(unverified estimate).
See [`RESOURCE_ESTIMATES.md`](RESOURCE_ESTIMATES.md) for the full breakdown.

## Build & test

You need [Verilator](https://verilator.org/) 5.0 or newer.

```bash
make lint           # static check the RTL (core + padder + hmac)
make test           # build + run core NIST/CAVP/random tests
make test-padder    # padder helper FIPS-180-4 §5.1.1 conformance
make test-hmac      # HMAC-SHA-256 vs RFC 4231
make test-all       # all three
```

The harness is written to end a passing run with `+PASS all tests passed` and
exit 0. No passing run has been independently confirmed.

## Verification

Three techniques are wired into the testbench. Test vectors are included;
results not independently confirmed.

### Directed tests (core)

| # | Test                                  | Coverage                                        |
|---|---------------------------------------|-------------------------------------------------|
| 1 | FIPS-180-4 Appendix B vectors         | "abc", empty, 448-bit                           |
| 2 | NIST CAVP `SHA256ShortMsg`            | 9 entries, 8 to 1304 bits                       |
| 3 | 1000 random hashlib cross-check       | Lengths 0..2000, varied block counts            |
| 4 | Multi-block long messages             | 1024-byte all-`0x41` (16 blocks)                |
| 5 | Back-to-back hashes                   | init -> blocks -> digest -> init (new)          |
| 6 | Reset mid-hash                        | Aborted hash recovers cleanly                   |
| 7 | Single-byte input edge case           | Smallest non-empty input                        |
| 8 | Padder all tail lengths {0,1,16,55..} | FIPS-180-4 §5.1.1 padding checks                |

### Directed tests (HMAC)

| # | Test                                  | Coverage                                        |
|---|---------------------------------------|-------------------------------------------------|
| 1 | RFC 4231 HMAC-SHA-256 vectors         | All 7 reference vectors                         |
| 2 | Edge cases                            | Zero-length key, max 256-bit key, 1024-byte msg |
| 3 | 100 random vs hmac/hashlib            | Random `(key, msg)` cross-validation            |

### SystemVerilog assertions

`tb/sha256_core_assertions.sv` is intended to check protocol invariants on
every cycle of every test:

- `valid_o` only fires exactly 67 cycles after a block is accepted
- `digest_o` is stable while `valid_o` is asserted
- The round counter never exceeds 63
- `init_i` / `next_i` are ignored when the core is busy (`ready_o` low)
- W-buffer first-word consistency: `W_buf[0]` after capture = `block_i[511:480]`

The assertions are intended to compile with both Verilator 5.x (`--assert`)
and Vivado xsim (not independently confirmed). They are stripped on synthesis flows via `` `ifndef SYNTHESIS ``.

### Functional coverage

`tb/sha256_core_cov.sv` collects eight bins. The simulator prints a
coverage summary at end-of-test in this format (illustrative output; results
not independently confirmed):

```
---- Functional coverage ----
  [HIT ] state_idle / state_run / state_update / state_done
  [HIT ] single_block / multi_block / back_to_back / reset_mid_hash
Coverage: 8/8 bins (100.0%)
```

The harness is intended to fail a run that drops below 100%.

### Synthesis comparison report

`make synth_report` runs every available toolchain on the same RTL and
emits [`SYNTH_REPORT.md`](SYNTH_REPORT.md) with a side-by-side LUT/FF/BRAM
table. Yosys (`synth_ice40` / `synth_ecp5` / `synth_xilinx`) is mandatory;
Vivado and Quartus are detected automatically and skipped with a notice
when not on `$PATH`.

## Variants

| Variant                          | Use case                                                                                              |
|----------------------------------|-------------------------------------------------------------------------------------------------------|
| `rtl/sha256_core.sv`             | Default: 67-cycle iterative core, single 512-bit block at a time                                      |
| `rtl/sha256_padder.sv`           | FIPS-180-4 §5.1.1 hardware message padder helper                                                      |
| `rtl/hmac_sha256.sv`             | HMAC-SHA-256 wrapper; implements the FIPS 198-1 / RFC 2104 algorithm (not validated). Intended to avoid length-extension. See [`SECURITY.md`](SECURITY.md). |
| `vhdl_wrapper/sha256_core_vhdl.vhd` | VHDL-2008 entity wrapping the SV core for VHDL-only designs                                        |

## License

Dual-licensed:

- **GPL-3.0-or-later** for open-source projects. If your product links this
  RTL or its compiled bitstream, your project must also be GPL-3.0+.
- **Commercial license** for closed-source products. Commercial licenses are available on request: open a GitHub issue titled 'Commercial license request'. Do not post confidential details in the issue. Any commercial license is provided as is, without warranty, support or maintenance. This core is unverified (see README).
  See [`LICENSE.md`](LICENSE.md) for the license text.

If unsure which applies, read `LICENSE.md` or open an issue.

## Repository layout

```
rtl/                  RTL sources
  sha256_core.sv        top-level basic core, FSM, W rolling buffer
  sha256_round.sv       combinational CH/MAJ/BSIG0/BSIG1 round update
  sha256_constants.svh  K[0..63] / H(0)[0..7] preprocessor macros
  sha256_constants.sv   SV package wrapper (sha256_const_pkg)
  sha256_padder.sv      FIPS-180-4 §5.1.1 message padder helper
  hmac_sha256.sv        HMAC-SHA-256 wrapper
tb/                   testbench
  sim_main.cpp          C++ harness, NIST + CAVP + 1000 random vectors
  sim_padder.cpp        padder verification harness
  sim_hmac.cpp          HMAC harness, RFC 4231 + 100 random
  sha256_core_tb.sv     DUT wrapper + assertion + coverage instantiation
  sha256_core_assertions.sv  SVA properties
  sha256_core_cov.sv    functional coverage collector
  sha256_padder_tb.sv   padder DUT wrapper
  hmac_test.sv          HMAC DUT wrapper
  nist_vectors.sv       same vectors in SV (for non-Verilator simulators)
  random_vectors.h      generated cross-validation vectors (hashlib)
  hmac_random_vectors.h generated HMAC cross-validation vectors
  gen_random_vectors.py regenerates random_vectors.h
  gen_hmac_vectors.py   regenerates hmac_random_vectors.h
vhdl_wrapper/         VHDL-2008 wrapper for mixed-language designs
scripts/              helper scripts (synth_report.sh, vhdl_cosim.sh)
Makefile              build/lint/sim/synth/synth_report/vhdl-test/test-hmac
```

## Contributing

Bug reports and patches welcome. Process:

1. File an issue first for non-trivial changes.
2. Fork, branch, and run `make lint test test-padder test-hmac` locally.
3. Open a pull request with a description of what changed and why.
4. There is no CI; include the output of your local
   `make lint test test-padder test-hmac` run in the pull request.

## Citation

```bibtex
@misc{sha256-fpga-core,
  title  = {{sha256-fpga-core}: a small dual-licensed SHA-256 IP core in SystemVerilog with HMAC-SHA-256},
  author = {Achour, Ayoub},
  year   = {2026},
  howpublished = {\url{https://github.com/ayoub-ac/sha256-fpga-core}}
}
```

## References

- NIST FIPS-180-4, *Secure Hash Standard (SHS)*, August 2015.
- NIST FIPS-198-1, *The Keyed-Hash Message Authentication Code (HMAC)*, July 2008.
- IETF RFC 2104, *HMAC: Keyed-Hashing for Message Authentication*, February 1997.
- IETF RFC 4231, *Identifiers and Test Vectors for HMAC-SHA-224, HMAC-SHA-256, HMAC-SHA-384, and HMAC-SHA-512*, December 2005.
- NIST CAVP, *SHA Test Vectors for Hashing Byte-Oriented Messages*,
  <https://csrc.nist.gov/projects/cryptographic-algorithm-validation-program>.

## Author

Ayoub Achour - [github.com/ayoub-ac](https://github.com/ayoub-ac)
