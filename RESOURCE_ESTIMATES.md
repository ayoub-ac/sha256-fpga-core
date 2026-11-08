# Resource estimates

Numbers below are unverified estimates attributed to Yosys 0.33 generic synthesis (`make synth`); they have not been independently reproduced. They are pre-place-and-route, so the vendor flow (nextpnr / Vivado / Diamond) will usually pack tighter, especially on iCE40 where SB_LUT4 + carry chains pack across boundaries that Yosys does not, and on Xilinx where Vivado fuses small LUTs into LUT6 + LUT6_2. Run `make synth` for authoritative numbers on your toolchain version.

## Summary (post-Yosys, pre-PnR)

| Target                         | LUT (logic)         | FF       | Notes |
|--------------------------------|---------------------|----------|-------|
| Lattice iCE40 UP5K             | 2208 SB_LUT4        | 1067 FF  | 1031 SB_DFFESR + 36 SB_DFF. Carry chain: 374 SB_CARRY. |
| Lattice ECP5 LFE5UM-25         | 1829 LUT4 (+ 197 PFUMX + 61 L6MUX21) | 1067 TRELLIS_FF | 196 CCU2C carry cells. |
| Xilinx Artix-7 XC7A35T         | 12 LUT4 + 153 LUT3 + 64 LUT2 + 32 LUT5 + 124 LUT6 = ~385 LUT (Yosys generic synth, before Vivado packing) | 1067 FDRE | 24 CARRY4. Vivado will repack into LUT6 + LUT6_2 form. |
| Gowin GW1NR-9 (Tang Nano 9K)   | not characterized in this run | ~1.07k FF | Use `synth_gowin` or the Gowin IDE. Resource shape is comparable to iCE40 UP5K. |

These numbers cover the iterative core. The padder helper (`sha256_padder.sv`) is an additional ~700 LUT4 and ~640 FF on iCE40 (unverified estimate) (one 512-bit assembly buffer plus an 8-state FSM); see the `sha256_padder` synth target in your own flow if you instantiate it.

## What dominates the area

- **Working variables `(a..h)` = 8 × 32 = 256 FFs** — the per-block state.
- **Running hash `H[0..7]` = 8 × 32 = 256 FFs** — held across blocks.
- **Message-schedule rolling buffer `W[t..t+15]` = 16 × 32 = 512 FFs** — the dominant register cost.
  - 256 + 256 + 512 = 1024 FFs of state, plus a 7-bit round counter and a 2-bit FSM = ~1067 FFs total (unverified estimate).
- **Round-update logic** — the combinational `BSIG0`, `BSIG1`, `CH`, `MAJ` plus three 32-bit additions per cycle. This is where most of the LUTs live.
- **Message-schedule expansion** — `SSIG0`, `SSIG1` plus two 32-bit additions per cycle. Lighter than the round update.

## What you can do to shrink it

- **Externalise `W` to BRAM**: with `(* ram_style = "block" *)` (Vivado) or `(* ram_style = "distributed" *)` (Yosys / Lattice), the 16-deep × 32-bit `W` buffer can drop into a small block RAM, reclaiming ~512 FFs at a cost of ~1 BRAM (unverified estimate). No such variant is included in this repository.
- **Byte-serial mode**: halve the per-cycle datapath width and double the cycle count, trading 2x latency for fewer LUTs. No such variant is included in this repository.

## What you can do to push throughput

- **Pipelined / parallel variant** (not included in this repository): unroll the round loop to reduce per-block latency from 67 cycles toward 1 round per cycle steady-state. Useful for blockchain mining, TLS bulk hashing, signature batching.
- **Cache the message schedule**: pre-compute `W[0..63]` on the first cycle and stream rounds against the cached schedule. Reduces critical-path through `W_buf -> ssig -> add -> ssig -> ...`.

## Frequency

The figures below are unverified estimates; no place-and-route timing has been confirmed.

- iCE40 UP5K, default toolchain (Yosys + nextpnr), no constraints: ~50-60 MHz typical.
- ECP5: ~120 MHz typical, ~150 MHz with effort.
- Artix-7 -1 speed grade: ~150 MHz typical, ~200 MHz with effort and timing constraints. Vivado tends to push retiming through the BSIG XOR trees automatically; on Yosys+nextpnr you may need explicit `nextpnr -t` retiming.

The combinational path is dominated by the round-update adder chain (`h + BSIG1(e) + CH(e,f,g) + K[t] + W[t]` is four 32-bit adds in series). Splitting that adder over two cycles is the obvious next throughput knob; no such variant is included in this repository.

## Power

Power has not been characterized. Static power is dominated by the FPGA itself.

## How to reproduce

```bash
make synth       # all three targets
```

This runs Yosys with `synth_ice40`, `synth_ecp5` (with `-abc9`), and `synth_xilinx` and dumps statistics in `synth_*.log`. The stats line at the bottom tells you cell counts per primitive.

For end-to-end place-and-route numbers (post-PnR LUT counts and timing), run the vendor flow:
- iCE40 / ECP5: nextpnr-ice40 / nextpnr-ecp5 with Yosys output (open toolchain).
- Xilinx: Vivado with a project pointing at the `rtl/` files.
- Lattice Diamond / Radiant: project with `rtl/` added.
