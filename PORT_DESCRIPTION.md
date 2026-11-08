# Port description

This document is the contract for `sha256_core`. Bit widths, polarity, timing, and the handshake protocol.

## Module declaration

```systemverilog
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
```

## Pin-by-pin

| Signal      | Dir | Width | Description |
|-------------|-----|-------|-------------|
| `clk_i`     | in  | 1     | System clock. All flops in the core sample on the rising edge. |
| `rst_ni`    | in  | 1     | Synchronous, active-low reset. Hold low for >= 4 clocks before first valid command. |
| `init_i`    | in  | 1     | Pulse together with `valid_i` and the first 512-bit block of a fresh hash. Loads `H` from the FIPS-180-4 §5.3.3 initial values. Mutually exclusive with `next_i`. |
| `next_i`    | in  | 1     | Pulse together with `valid_i` and a continuation 512-bit block. `H` is preserved from the previous block. Mutually exclusive with `init_i`. |
| `block_i`   | in  | 512   | A pre-padded 512-bit message block. Big-endian: bit `[511:480]` is the first 32-bit word (M_0 in FIPS-180-4 §6.2.1), bit `[31:0]` is the last (M_15). |
| `valid_i`   | in  | 1     | Master asserts when `block_i` and `init_i`/`next_i` are valid. Asserting when `ready_o == 0` is allowed but the transfer does not complete until `ready_o` rises. |
| `ready_o`   | out | 1     | Core is ready to accept a new block. `valid_i && ready_o` = transfer accepted. |
| `digest_o`  | out | 256   | Current value of the running hash. After a fresh `init_i` block, this is `H` after one block. After successive `next_i` blocks, this is `H` after the last block consumed. Big-endian: bit `[255:224]` is `H[0]`, bit `[31:0]` is `H[7]`. |
| `valid_o`   | out | 1     | Pulses high for one cycle when the core has finished a block and `digest_o` is updated. |

## Handshake

The core uses a valid/ready protocol on the input side and a single-cycle pulse on the output side:

- A transfer happens on a rising clock edge where `valid_i && ready_o`.
- The master must drive `block_i`, exactly one of `init_i` / `next_i`, and `valid_i`.
- After the transfer, `ready_o` drops while the core runs the 64 rounds + update; `valid_o` then pulses for one cycle and `digest_o` is the running hash.
- The master can immediately issue another `next_i` block on the cycle after `valid_o`; the core re-asserts `ready_o` on the next cycle.

### Input handshake (master -> core)

```
clk         _|‾|_|‾|_|‾|_|‾|_
ready_o    1   1   1   0   ...     (drops for ~64 cycles while core runs)
valid_i    0   1   1   0   ...
init_i,
next_i,    -   X   X   -            (X = init for first block, next for continuation)
block_i    -   B   B   -

           ^ here master drives B and asserts valid_i; core's ready_o is also high,
             so the transfer is accepted on this rising edge. The core lowers
             ready_o and starts processing.
```

### Output (core -> master)

```
clk         _|‾|_|‾|_|‾|_|‾|_
valid_o    0   1   0   ...
digest_o   -   H'  H'  -            (H' is the running hash; stable from the cycle valid_o
                                     pulses onwards until the next block is consumed)
```

`valid_o` is a single-cycle pulse, not a held flag. `digest_o`, however, is held: it is a register that holds the running hash and is updated only at the end of each block. The master can read `digest_o` any time after the first `valid_o` pulse — it stays valid until the next `valid_o`.

## Driving a hash

A typical full hash sequence:

1. Reset the core (`rst_ni = 0` for >= 4 clocks, then `rst_ni = 1`).
2. Pad your message in software per FIPS-180-4 §5.1.1, producing one or more 64-byte blocks. Or use the `sha256_padder` helper module for hardware padding.
3. Wait for `ready_o`.
4. Drive the FIRST padded block on `block_i`, set `init_i = 1`, `next_i = 0`, `valid_i = 1` for one cycle.
5. Wait for `valid_o`. After this pulse, `digest_o` reflects the hash after block 0.
6. For each remaining block, wait for `ready_o`, drive it on `block_i`, set `init_i = 0`, `next_i = 1`, `valid_i = 1` for one cycle, then wait for `valid_o`.
7. After the last block's `valid_o`, `digest_o` is the final SHA-256 of the original message.

## Timing

- **Latency**: from the cycle `valid_i && ready_o` is captured to the cycle `valid_o` rises is designed to be exactly 67 cycles (unverified) — 1 cycle to register the input + reseed working variables, 64 round cycles, 1 cycle to add `(a..h)` into `H`, 1 cycle to assert `valid_o`.
- **Throughput**: one 512-bit block per 67 cycles. At 100 MHz that is ~765 Mbps for a steady stream of full blocks (unverified estimate derived from the cycle count).
- **Back-to-back**: yes — the master can present a new continuation block on the cycle after `valid_o` pulses (`ready_o` re-asserts on that cycle).

## Reset

- `rst_ni` is **synchronous**, **active-low**.
- Drive `rst_ni = 0` for at least four `clk_i` rising edges before the first command.
- During reset all output signals are low, all internal state is cleared. The previously running hash is wiped — issue a fresh `init_i` block on the next command. `next_i` after reset is undefined behaviour.

## Endianness clarification

A 512-bit SHA input block is conventionally written as 16 big-endian 32-bit words. We adopt the FIPS-180-4 §3.1 convention: word 0 (the leftmost word in the standard hex string) is in bits `[511:480]`, word 15 (the rightmost) is in bits `[31:0]`.

Byte 0 of the message lives in bits `[511:504]`. If your bus is byte-little-endian, you must reverse byte order before driving `block_i`.

The output `digest_o` follows the same convention: bits `[255:224]` are the first 32 bits of the canonical hex digest (`H[0]`), bits `[31:0]` are the last (`H[7]`).

## Clock domain

Single clock domain. `clk_i` clocks every flop in the design. If your system is multi-clock, instantiate this core in its own domain and use a CDC FIFO on `block_i` / `digest_o`.

## Synthesis attributes

The core uses no vendor-specific attributes. It is intended to synthesize with Yosys (`synth_ice40`, `synth_ecp5`, `synth_xilinx`) and with Vivado (default flow); not independently confirmed.
