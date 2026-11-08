# Security model

This document describes what `sha256_core` (and the `hmac_sha256`
wrapper) is designed to defend against, what it is NOT designed to defend
against, and how to evaluate the claims.

If you need a side-channel-resistant hash core for a real product, read this
whole document and decide whether the threat model matches your deployment.
Don't trust marketing copy; trust the threat model and your own evaluation.

## What is intended to be protected (not evaluated)

### 1. Constant-time execution

The cores are intended to be constant-time; not evaluated. SHA-256
(FIPS-180-4) has no data-dependent branches. The `sha256_core` FSM is
designed to run exactly 67 cycles per 512-bit block (1 capture + 64 round + 1 update +
1 valid pulse) regardless of message content. `hmac_sha256` likewise has a
deterministic schedule:

  inner-key block (67c) + N message blocks (67c each) + outer-key block
  (67c) + outer inner-digest block (67c) + 1c for `mac_valid_o` setup.

Total HMAC latency = 67 * (3 + N) cycles for an N-block message (design
intent, unverified).

**What this is intended to protect (not evaluated)**: timing attacks that
observe completion latency to infer key or message bits. The design is
intended to have no path that takes a different number of cycles depending on
data values.

### 2. Bounded round count

The `p_round_bound` SVA assertion is intended to check that the internal
`round_q` counter never exceeds 63, on every cycle of every test in the
regression; results not independently confirmed. An FSM bug that allowed a
runaway round counter is intended to trip the assertion before reaching the
output.

### 3. Constant-time HMAC compare (caller-side)

The `hmac_sha256` variant emits the full 256-bit MAC. Callers
performing tag verification MUST use a constant-time comparison; a naive
byte-by-byte memcmp leaks information about how many leading bytes match.
No constant-time comparator is included in this repository.

### 4. No length-extension when used as HMAC

A naive raw SHA-256 deployment is vulnerable to length-extension attacks: an
attacker who knows `H(secret || message)` can compute `H(secret || message
|| padding || extra)` without knowing `secret`. HMAC's nested-hash
construction is not vulnerable to length-extension, and the HMAC-SHA-256
wrapper is intended to implement it; the wrapper has not been evaluated. **If you use raw `sha256_core` to authenticate
secret-prefixed messages, switch to `hmac_sha256` instead.**

## What is NOT covered (be honest)

This list is deliberately exhaustive so users can evaluate fit:

- **Differential power analysis (DPA)** on the round update: the working
  variables `(a..h)` and the message-schedule buffer `W` are unmasked. A
  power attacker measuring leakage at the FF-update boundary can mount
  standard CPA / DPA against intermediate values. Mitigation requires
  arithmetic masking of the additions and XOR-masking of the BSIG/SSIG
  rotations; not implemented.
- **Electromagnetic (EM) analysis** and **template attacks**: not
  specifically countered. There is no power-balancing, no differential
  routing, no constant-Hamming-weight encoding.
- **Fault injection** on the round counter, working variables, or
  message-schedule buffer: a flipped bit can corrupt the digest in ways
  that may or may not be detectable depending on where the fault lands.
  No duplicated-counter / parity-protected register implementation is
  included.
- **Cache / micro-architectural side channels**: not applicable (this is
  RTL, not software), but if you place this core into a system with a
  shared bus or shared memory, those channels can leak.
- **Length-extension on raw SHA-256**: as noted above, raw SHA-256 is
  vulnerable. Use `hmac_sha256` for any authentication use case where the
  secret is prepended.
- **Invasive attacks** (decap, microprobing) are entirely out of scope.

If your deployment threat model includes any of the above and the rest of
your system relies on hash integrity, this core is not enough on its own.

## Compliance claims

- **FIPS-180-4 conformance**: not validated. The RTL implements the
  FIPS 180-4 algorithm (not validated). Published NIST CAVP test vectors,
  FIPS-180-4 Appendix B vectors and 1000 random messages cross-checked
  against `hashlib.sha256` are included in the testbench; results not
  independently confirmed.
- **FIPS-198-1 conformance (HMAC-SHA-256)**: not validated. The
  `hmac_sha256` wrapper implements the FIPS 198-1 / RFC 2104 algorithm (not
  validated). All 7 RFC 4231 test vectors plus 100 random `(key, message)`
  pairs cross-checked against `hmac.new(key, msg, hashlib.sha256)` are
  included in the testbench; results not independently confirmed.
- **NIST CAVP test certificate**: NOT obtained. NIST CAVP known-answer tests
  are included in the simulation testbench (results not independently
  confirmed), and the RTL is not registered with NIST CAVP.
  CAVP requires a test harness running on the certified platform, which is
  the integrator's responsibility.
- **FIPS-140-2 / FIPS-140-3 certification**: NOT claimed. FIPS-140 is a
  module-level certification covering far more than the algorithm (RNG
  quality, key zeroization, role-based authentication, physical security,
  etc.) and is the responsibility of the integrator. This core implements
  one of the building blocks; it is not by itself a FIPS-140 cryptographic
  module.
- **Common Criteria**: not evaluated.

## Test methodology used to validate the security claims

The Verilator testbenches contain the checks below. The checks are included;
results not independently confirmed.

1. **Functional correctness on FIPS-180-4 vectors**: `make test`. Includes
   FIPS-180-4 Appendix B vectors, NIST CAVP `SHA256ShortMsg`, multi-block
   messages, back-to-back hashes, reset mid-hash, and 1000 random
   cross-validation messages.
2. **HMAC functional correctness on RFC 4231 vectors**: `make test-hmac`.
   All 7 RFC 4231 vectors plus 3 edge cases (zero-length key, max 256-bit
   key, 1024-byte message) plus 100 random vectors cross-checked against
   `hmac.new(...).hexdigest()`.
3. **SVA protocol invariants, intended to be checked on every cycle**: see
   `tb/sha256_core_assertions.sv`. Properties include latency bound,
   digest stability, round counter bound, init-during-busy ignored,
   and W-buffer first-word consistency.
4. **Functional coverage**: 8 bins (FSM states, single/multi-block,
   back-to-back, reset-mid-hash). Coverage report printed at end of
   `make test`.

We do NOT run experimental DPA / CPA against a real bitstream. The
constant-time claim is **design intent**, derived from the fact that
FIPS-180-4 has no data-dependent branches; it has not been evaluated. An
experimentally verified claim would require an FPGA, an oscilloscope, and a
trace-collection campaign measured in days or weeks; none has been done.

## How to use the cores safely

1. For any use case where you are authenticating data with a secret key,
   use `hmac_sha256` and not raw `sha256_core`. Length-extension on raw
   SHA-256 is a real attack with public exploit code.
2. Hold `rst_ni` low for >=4 cycles after power-on and before the first
   command.
3. Wipe the message and key from memory after use; the wrapper does not do
   this automatically (the working-variable registers retain post-hash
   state until the next `init_i`).
4. For tag verification, use a constant-time MAC compare. No reference
   implementation is included in this repository.
5. The cores are not a substitute for protocol-level measures like nonce
   uniqueness, rate-limiting, or AEAD authentication. Use HMAC inside an
   authenticated-encryption construction (Encrypt-then-MAC or AEAD modes
   like GCM / CCM / ChaCha20-Poly1305) for real systems.

## Reporting issues

Found a bug, a side channel we missed, or a discrepancy with FIPS-180-4 /
FIPS-198-1 / RFC 4231? Open a GitHub issue; do not post confidential details
in it. Coordinated disclosure welcome. We do not currently offer a bug bounty.
