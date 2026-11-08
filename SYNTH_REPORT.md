# Synthesis comparison report

Unverified: this file is not CI output and its numbers have not been
independently reproduced. Regenerate it locally with `make synth_report`.
Numbers are post-synthesis, pre-place-and-route.
Vendor flows (Vivado / Quartus) usually pack tighter than the open-source flow,
so the Yosys numbers should be read as upper bounds.

| Toolchain                | Target              | Result                                    |
|--------------------------|---------------------|-------------------------------------------|
| Yosys 0.x synth_ice40    | iCE40 UP5K          | 2208 LUT / 1067 FF / 0 BRAM                           |
| Yosys 0.x synth_ecp5     | ECP5 LFE5UM-25      | 1829 LUT / 1067 FF / 0 BRAM                            |
| Yosys 0.x synth_xilinx   | Xilinx 7-series     | 679 LUT / 1067 FF / 0 BRAM                             |
| Vivado synth_design      | Artix-7 xc7a35tcsg324-1 | (skipped: vivado not on PATH)                       |
| Quartus Pro              | Cyclone V 5CSEMA5F31C6  | (skipped: quartus_sh not on PATH)                      |

## Notes

* iCE40 numbers are dominated by SB_LUT4 4-input LUTs plus FFs for the
  16-deep message-schedule rolling buffer (W) and the eight working
  variables (a..h) plus the eight running-hash words (H).
* ECP5 generic synthesis in Yosys 0.x does not always pack the schedule
  buffer into distributed RAM; the resulting LUT count can be inflated.
  `nextpnr-ecp5` packs much tighter; for accurate ECP5 sizing run the full
  open toolchain through nextpnr.
* Xilinx generic numbers count Yosys's primitive cells before Vivado's LUT6
  and SLICEM packing. Real Vivado synth_design is expected to produce ~30-40%
  fewer LUTs (unverified estimate).
* Vivado / Quartus rows are skipped automatically when those tools are not
  on PATH; on a CI runner with the WebPACK / Web Edition installed they will
  be populated from a real synth_design / quartus_sh run.

## Reproduction

```
make synth_report
```

Raw logs land in `synth_report/`.
