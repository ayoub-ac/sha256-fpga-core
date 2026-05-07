-- SPDX-License-Identifier: GPL-3.0-or-later OR Commercial
--
-- VHDL-2008 wrapper for the SystemVerilog sha256_core module.
--
-- This entity exposes the SHA-256 core's port list in VHDL syntax. The
-- architecture instantiates the SystemVerilog module by component name; mixed-
-- language elaboration is supported natively by Vivado, Quartus, ModelSim /
-- Questa, and Aldec, and via the GHDL VHPI bridge for open simulation.
--
-- Status: WRAPPER ONLY. The hash datapath itself remains in SystemVerilog
-- (rtl/*.sv). A native VHDL port of the datapath is listed as future work in
-- vhdl_wrapper/README.md.
--
-- I/O contract: identical to sha256_core.sv (see PORT_DESCRIPTION.md).
--   * Single clock, active-low synchronous reset.
--   * Valid/ready handshake on the input side.
--   * 512-bit pre-padded input block, 256-bit running digest.
--   * init_i / next_i select fresh hash vs continuation.

library ieee;
  use ieee.std_logic_1164.all;
  use ieee.numeric_std.all;

entity sha256_core_vhdl is
  port (
    clk_i    : in  std_logic;
    rst_ni   : in  std_logic;
    init_i   : in  std_logic;
    next_i   : in  std_logic;
    block_i  : in  std_logic_vector(511 downto 0);
    valid_i  : in  std_logic;
    ready_o  : out std_logic;
    digest_o : out std_logic_vector(255 downto 0);
    valid_o  : out std_logic
  );
end entity sha256_core_vhdl;

architecture rtl of sha256_core_vhdl is

  -- Forward declaration of the SystemVerilog component. Tools resolve this by
  -- name at elaboration; the SystemVerilog source must be added to the same
  -- compilation library (work) before the VHDL elaboration step.
  component sha256_core
    port (
      clk_i    : in  std_logic;
      rst_ni   : in  std_logic;
      init_i   : in  std_logic;
      next_i   : in  std_logic;
      block_i  : in  std_logic_vector(511 downto 0);
      valid_i  : in  std_logic;
      ready_o  : out std_logic;
      digest_o : out std_logic_vector(255 downto 0);
      valid_o  : out std_logic
    );
  end component;

begin

  u_sha : sha256_core
    port map (
      clk_i    => clk_i,
      rst_ni   => rst_ni,
      init_i   => init_i,
      next_i   => next_i,
      block_i  => block_i,
      valid_i  => valid_i,
      ready_o  => ready_o,
      digest_o => digest_o,
      valid_o  => valid_o
    );

end architecture rtl;
