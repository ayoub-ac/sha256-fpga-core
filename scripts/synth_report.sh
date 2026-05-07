#!/usr/bin/env bash
# Cross-toolchain synthesis report. Runs every installed FPGA toolchain
# against rtl/sha256_core.sv (basic, iterative core) and writes
# SYNTH_REPORT.md with a side-by-side LUT/FF/BRAM table.
#
# Toolchains attempted:
#   * Yosys synth_ice40   (always run, only requires yosys)
#   * Yosys synth_ecp5    (")
#   * Yosys synth_xilinx  (Xilinx generic)
#   * Vivado xc7a35tcsg324-1   (only if `vivado` is on PATH)
#   * Quartus Cyclone V        (only if `quartus_sh` is on PATH)
#
# Missing toolchains are noted as "(skipped: tool not on PATH)" rather than
# making the build fail.

set -u
cd "$(dirname "$0")/.."

OUTDIR="synth_report"
mkdir -p "$OUTDIR"

REPORT="SYNTH_REPORT.md"
RTL="rtl/sha256_round.sv rtl/sha256_core.sv"

have() { command -v "$1" >/dev/null 2>&1; }

# ---------------------------------------------------------------------------
# Yosys runs
# ---------------------------------------------------------------------------
yosys_run() {
    local target="$1" yopts="$2" outfile="$3"
    if ! have yosys; then
        echo "yosys not installed" > "$outfile"
        return 1
    fi
    yosys -p "read_verilog -sv -Irtl $RTL; hierarchy -top sha256_core; $yopts; stat" \
          > "$outfile" 2>&1
    return $?
}

extract_yosys_stat() {
    # Pull cell counts from the LAST "Printing statistics" block in a yosys
    # log. Returns a single-line markdown-table cell.
    local f="$1"
    if [[ ! -s "$f" ]] || grep -q "yosys not installed" "$f"; then
        echo "(skipped)"
        return
    fi

    # Yosys prints multiple "=== sha256_core ===" stat blocks (pre- and post-
    # synthesis). Take the LAST one and truncate at the next === marker so we
    # count only cells of the sha256_core module proper.
    local block
    block=$(awk '
        /^=== sha256_core ===/ { out=""; collect=1; next }
        /^=== / && collect     { collect=0; next }
        collect                { out = out "\n" $0 }
        END { print out }
    ' "$f")
    if [[ -z "$block" ]]; then
        echo "(no stat block)"
        return
    fi

    # Sum LUT-like primitives (last column = cell count for that primitive).
    local luts ffs brams
    luts=$(echo "$block" | awk '
        /SB_LUT4|LUT4|LUT5|LUT6|LUT2|LUT1|^[[:space:]]+LUT[[:space:]]/ {
            sum += $NF
        }
        END { print sum+0 }')
    ffs=$(echo "$block" | awk '
        /SB_DFF|SB_DFFESR|SB_DFFE|TRELLIS_FF|FDRE|FDCE|FDPE|FDSE|FDC|FDP/ {
            sum += $NF
        }
        END { print sum+0 }')
    brams=$(echo "$block" | awk '
        /SB_RAM40_4K|EBR|RAMB18|RAMB36/ { sum += $NF }
        END { print sum+0 }')
    echo "${luts} LUT / ${ffs} FF / ${brams} BRAM"
}

echo "[synth_report] Yosys ice40..."
yosys_run "ice40"  "synth_ice40 -top sha256_core"             "$OUTDIR/yosys_ice40.log"  || true
echo "[synth_report] Yosys ecp5..."
yosys_run "ecp5"   "synth_ecp5 -top sha256_core -abc9"        "$OUTDIR/yosys_ecp5.log"   || true
echo "[synth_report] Yosys xilinx..."
yosys_run "xilinx" "synth_xilinx -top sha256_core"            "$OUTDIR/yosys_xilinx.log" || true

# ---------------------------------------------------------------------------
# Vendor flows (best-effort)
# ---------------------------------------------------------------------------
VIVADO_RESULT="(skipped: vivado not on PATH)"
if have vivado; then
    echo "[synth_report] Vivado synth_design Artix-7..."
    cat > "$OUTDIR/vivado_synth.tcl" <<'EOF'
set_part xc7a35tcsg324-1
read_verilog -sv {rtl/sha256_round.sv rtl/sha256_core.sv}
synth_design -top sha256_core -part xc7a35tcsg324-1 -mode out_of_context -include_dirs rtl
report_utilization -file synth_report/vivado_util.rpt
EOF
    if vivado -mode batch -nojournal -nolog -source "$OUTDIR/vivado_synth.tcl" \
              > "$OUTDIR/vivado.log" 2>&1; then
        VIVADO_LUTS=$(awk '/Slice LUTs/ {print $4; exit}' "$OUTDIR/vivado_util.rpt" 2>/dev/null || echo "?")
        VIVADO_FFS=$(awk  '/Slice Registers/ {print $4; exit}' "$OUTDIR/vivado_util.rpt" 2>/dev/null || echo "?")
        VIVADO_BRAM=$(awk '/Block RAM Tile/ {print $5; exit}' "$OUTDIR/vivado_util.rpt" 2>/dev/null || echo "0")
        VIVADO_RESULT="${VIVADO_LUTS} LUT / ${VIVADO_FFS} FF / ${VIVADO_BRAM} BRAM"
    else
        VIVADO_RESULT="(failed - see synth_report/vivado.log)"
    fi
fi

QUARTUS_RESULT="(skipped: quartus_sh not on PATH)"
if have quartus_sh; then
    echo "[synth_report] Quartus Cyclone V..."
    QPROJ="$OUTDIR/qproj"
    mkdir -p "$QPROJ"
    cat > "$QPROJ/sha256_core.qsf" <<'EOF'
set_global_assignment -name FAMILY "Cyclone V"
set_global_assignment -name DEVICE 5CSEMA5F31C6
set_global_assignment -name TOP_LEVEL_ENTITY sha256_core
set_global_assignment -name SEARCH_PATH ../../rtl
set_global_assignment -name SYSTEMVERILOG_FILE ../../rtl/sha256_round.sv
set_global_assignment -name SYSTEMVERILOG_FILE ../../rtl/sha256_core.sv
EOF
    cat > "$QPROJ/sha256_core.qpf" <<'EOF'
PROJECT_REVISION = "sha256_core"
EOF
    if (cd "$QPROJ" && quartus_sh --flow compile sha256_core > ../quartus.log 2>&1); then
        QU_LUTS=$(awk -F\| '/ALMs needed/ {gsub(/ /,"",$3); print $3; exit}' "$OUTDIR/quartus.log" || echo "?")
        QU_FFS=$(awk  -F\| '/Total registers/ {gsub(/ /,"",$3); print $3; exit}' "$OUTDIR/quartus.log" || echo "?")
        QUARTUS_RESULT="${QU_LUTS} ALM / ${QU_FFS} FF"
    else
        QUARTUS_RESULT="(failed - see synth_report/quartus.log)"
    fi
fi

# ---------------------------------------------------------------------------
# Build the report
# ---------------------------------------------------------------------------
ICE40_RESULT=$(extract_yosys_stat "$OUTDIR/yosys_ice40.log")
ECP5_RESULT=$(extract_yosys_stat "$OUTDIR/yosys_ecp5.log")
XIL_RESULT=$(extract_yosys_stat   "$OUTDIR/yosys_xilinx.log")

cat > "$REPORT" <<EOF
# Synthesis comparison report

Generated by \`make synth_report\`. Numbers are post-synthesis, pre-place-and-route.
Vendor flows (Vivado / Quartus) usually pack tighter than the open-source flow,
so the Yosys numbers should be read as upper bounds.

| Toolchain                | Target              | Result                                    |
|--------------------------|---------------------|-------------------------------------------|
| Yosys 0.x synth_ice40    | iCE40 UP5K          | ${ICE40_RESULT}                           |
| Yosys 0.x synth_ecp5     | ECP5 LFE5UM-25      | ${ECP5_RESULT}                            |
| Yosys 0.x synth_xilinx   | Xilinx 7-series     | ${XIL_RESULT}                             |
| Vivado synth_design      | Artix-7 xc7a35tcsg324-1 | ${VIVADO_RESULT}                       |
| Quartus Pro              | Cyclone V 5CSEMA5F31C6  | ${QUARTUS_RESULT}                      |

## Notes

* iCE40 numbers are dominated by SB_LUT4 4-input LUTs plus FFs for the
  16-deep message-schedule rolling buffer (W) and the eight working
  variables (a..h) plus the eight running-hash words (H).
* ECP5 generic synthesis in Yosys 0.x does not always pack the schedule
  buffer into distributed RAM; the resulting LUT count can be inflated.
  \`nextpnr-ecp5\` packs much tighter; for accurate ECP5 sizing run the full
  open toolchain through nextpnr.
* Xilinx generic numbers count Yosys's primitive cells before Vivado's LUT6
  and SLICEM packing. Real Vivado synth_design typically produces ~30-40%
  fewer LUTs.
* Vivado / Quartus rows are skipped automatically when those tools are not
  on PATH; on a CI runner with the WebPACK / Web Edition installed they will
  be populated from a real synth_design / quartus_sh run.

## Reproduction

\`\`\`
make synth_report
\`\`\`

Raw logs land in \`synth_report/\`.
EOF

echo "[synth_report] Wrote $REPORT"
