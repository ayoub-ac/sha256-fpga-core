# VHDL wrapper

`sha256_core_vhdl.vhd` is a thin VHDL-2008 entity that re-exposes the
SystemVerilog `sha256_core` module under a VHDL-friendly interface. Use it
from a VHDL design that does not want to touch SystemVerilog directly.

## Status

**Wrapper only.** The hash datapath (CH, MAJ, BSIG/SSIG, message schedule,
FSM) lives in `rtl/*.sv` and is instantiated as a SystemVerilog black-box,
so the toolchain must support mixed-language elaboration. The wrapper has not
been tested with any simulator or synthesiser.

A pure VHDL re-implementation of the core is on the roadmap (scope: parity with `rtl/sha256_core.sv`, including the same testbench
checks). Until then, treat this directory as a binding layer, not as a
second implementation.

## Usage

### Vivado / Quartus / Diamond

Add both the SystemVerilog files and `sha256_core_vhdl.vhd` to the same
project library (`work` is fine). The toolchain resolves the SV component
automatically:

```tcl
# Vivado
read_verilog -sv {rtl/sha256_round.sv rtl/sha256_core.sv}
read_vhdl -vhdl2008 vhdl_wrapper/sha256_core_vhdl.vhd
```

### ModelSim / Questa / Aldec

```
vlog -sv rtl/sha256_round.sv rtl/sha256_core.sv
vcom -2008 vhdl_wrapper/sha256_core_vhdl.vhd
```

### GHDL + Verilator (open-source co-sim)

GHDL compiles the VHDL side, Verilator compiles the SV side, and the two are
linked through GHDL's VHPI bridge. The provided `make vhdl-test` target wraps
this; run it from the repository root:

```
make vhdl-test
```

The target is a no-op (with a notice) if `ghdl` is not on `$PATH`.

## Instantiation example

```vhdl
library ieee;
  use ieee.std_logic_1164.all;

entity my_design is end entity;
architecture rtl of my_design is
  signal clk, rstn, init_i, next_i, valid_i, ready_o, valid_o : std_logic;
  signal block_i  : std_logic_vector(511 downto 0);
  signal digest_o : std_logic_vector(255 downto 0);
begin
  u_sha : entity work.sha256_core_vhdl
    port map (
      clk_i    => clk,
      rst_ni   => rstn,
      init_i   => init_i,
      next_i   => next_i,
      block_i  => block_i,
      valid_i  => valid_i,
      ready_o  => ready_o,
      digest_o => digest_o,
      valid_o  => valid_o
    );
end architecture;
```

## What this wrapper does NOT change

* Latency, throughput, area: intended to be identical to `sha256_core.sv`
  (unverified). There is no additional pipeline stage. 67 cycles per 512-bit
  block (design intent).
* Endianness: bit 511 is byte 0 of the message, MSB-first, exactly as
  documented in `PORT_DESCRIPTION.md`.
* Reset polarity: still active-low synchronous (`rst_ni`).
