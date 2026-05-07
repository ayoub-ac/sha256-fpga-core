# SHA-256 FPGA core - build / lint / sim / synth
#
# Targets:
#   make lint           verilator --lint-only on RTL (core + padder + hmac)
#   make sim            build the core simulator
#   make test           build + run core sim, check for "+PASS"
#   make sim-padder     build the padder simulator
#   make test-padder    build + run padder sim
#   make sim-hmac       build the HMAC-SHA-256 simulator
#   make test-hmac      build + run HMAC sim, check for "+PASS"
#   make test-all       run core + padder + hmac suites
#   make synth          Yosys: ice40 + ecp5 + xilinx generic for the core
#   make synth-hmac     same for the HMAC variant
#   make synth_report   run all available toolchains and emit SYNTH_REPORT.md
#   make vhdl-test      GHDL+Verilator co-sim of the VHDL wrapper (if installed)
#   make clean          remove build artifacts
#   make regen_vectors  regenerate tb/random_vectors.h from hashlib

VERILATOR ?= verilator
YOSYS     ?= yosys
GHDL      ?= ghdl
VIVADO    ?= vivado
QUARTUS   ?= quartus_sh

# sha256_constants.svh is `include`d by sha256_core.sv; it does not need to
# be on the source list. sha256_constants.sv defines a parallel package
# (sha256_const_pkg) for users with full-SV-aware flows; we still lint it
# to make sure it stays valid SystemVerilog.
RTL_CORE := \
    rtl/sha256_round.sv \
    rtl/sha256_core.sv

RTL_CORE_LINT := \
    rtl/sha256_constants.sv \
    $(RTL_CORE)

RTL_PADDER := \
    rtl/sha256_padder.sv

RTL_HMAC := \
    $(RTL_CORE) \
    rtl/hmac_sha256.sv

TB_CORE_TOP   := tb/sha256_core_tb.sv
TB_CORE_AUX   := tb/sha256_core_assertions.sv tb/sha256_core_cov.sv
TB_CORE_CPP   := tb/sim_main.cpp
TB_PAD_TOP    := tb/sha256_padder_tb.sv
TB_PAD_CPP    := tb/sim_padder.cpp
TB_HMAC_TOP   := tb/hmac_test.sv
TB_HMAC_CPP   := tb/sim_hmac.cpp

VFLAGS := -Wall -Wno-UNUSEDPARAM -Wno-UNUSEDSIGNAL -Irtl

.PHONY: lint sim test sim-padder test-padder sim-hmac test-hmac test-all \
        synth synth-hmac synth_report vhdl-test clean regen_vectors

lint:
	$(VERILATOR) --lint-only $(VFLAGS) --top-module sha256_core_tb \
	    $(RTL_CORE_LINT) $(TB_CORE_TOP) $(TB_CORE_AUX)
	$(VERILATOR) --lint-only $(VFLAGS) --top-module sha256_padder_tb \
	    $(RTL_PADDER) $(TB_PAD_TOP)
	$(VERILATOR) --lint-only $(VFLAGS) --top-module hmac_test \
	    $(RTL_HMAC) $(TB_HMAC_TOP)

sim: obj_dir/Vsha256_core_tb

obj_dir/Vsha256_core_tb: $(RTL_CORE) rtl/sha256_constants.svh \
                         $(TB_CORE_TOP) $(TB_CORE_AUX) $(TB_CORE_CPP) \
                         tb/random_vectors.h
	$(VERILATOR) --cc --exe --build $(VFLAGS) --assert --public-flat-rw \
	    --top-module sha256_core_tb \
	    $(RTL_CORE) $(TB_CORE_TOP) $(TB_CORE_AUX) $(TB_CORE_CPP) \
	    -o Vsha256_core_tb

test: sim
	./obj_dir/Vsha256_core_tb | tee test.log
	@grep -q "+PASS" test.log && echo "TESTS PASSED" || (echo "TESTS FAILED" && exit 1)

sim-padder: obj_dir_padder/Vsha256_padder_tb

obj_dir_padder/Vsha256_padder_tb: $(RTL_PADDER) $(TB_PAD_TOP) $(TB_PAD_CPP)
	$(VERILATOR) --cc --exe --build $(VFLAGS) --top-module sha256_padder_tb \
	    --Mdir obj_dir_padder \
	    $(RTL_PADDER) $(TB_PAD_TOP) $(TB_PAD_CPP) \
	    -o Vsha256_padder_tb

test-padder: sim-padder
	./obj_dir_padder/Vsha256_padder_tb | tee test_padder.log
	@grep -q "+PASS" test_padder.log && echo "PADDER TESTS PASSED" || (echo "PADDER TESTS FAILED" && exit 1)

sim-hmac: obj_dir_hmac/Vhmac_test

obj_dir_hmac/Vhmac_test: $(RTL_HMAC) rtl/sha256_constants.svh \
                         $(TB_HMAC_TOP) $(TB_HMAC_CPP)
	$(VERILATOR) --cc --exe --build $(VFLAGS) --top-module hmac_test \
	    --Mdir obj_dir_hmac \
	    $(RTL_HMAC) $(TB_HMAC_TOP) $(TB_HMAC_CPP) \
	    -o Vhmac_test

test-hmac: sim-hmac
	./obj_dir_hmac/Vhmac_test | tee test_hmac.log
	@grep -q "+PASS" test_hmac.log && echo "HMAC TESTS PASSED" || (echo "HMAC TESTS FAILED" && exit 1)

test-all: test test-padder test-hmac

# ---------- Open synthesis (Yosys) ------------------------------------------
synth:
	$(YOSYS) -p "read_verilog -sv -Irtl $(RTL_CORE); hierarchy -top sha256_core; synth_ice40 -top sha256_core; stat" \
	    | tee synth_ice40.log
	$(YOSYS) -p "read_verilog -sv -Irtl $(RTL_CORE); hierarchy -top sha256_core; synth_ecp5 -top sha256_core -abc9; stat" \
	    | tee synth_ecp5.log
	$(YOSYS) -p "read_verilog -sv -Irtl $(RTL_CORE); hierarchy -top sha256_core; synth_xilinx -top sha256_core; stat" \
	    | tee synth_xilinx.log

synth-hmac:
	$(YOSYS) -p "read_verilog -sv -Irtl $(RTL_HMAC); hierarchy -top hmac_sha256; synth_xilinx -top hmac_sha256; stat" \
	    | tee synth_hmac_xilinx.log

# ---------- Cross-toolchain synthesis report --------------------------------
# Runs every available toolchain and writes SYNTH_REPORT.md. Missing tools are
# noted as "skipped"; existing tools produce real LUT/FF numbers.
synth_report:
	@bash scripts/synth_report.sh

# ---------- VHDL co-sim (optional) ------------------------------------------
vhdl-test:
	@which $(GHDL) >/dev/null 2>&1 || { echo "ghdl not installed - skipping vhdl-test"; exit 0; }
	@which $(VERILATOR) >/dev/null 2>&1 || { echo "verilator not installed"; exit 1; }
	@bash scripts/vhdl_cosim.sh

clean:
	rm -rf obj_dir obj_dir_padder obj_dir_hmac \
	    test.log test_padder.log test_hmac.log \
	    synth_ice40.log synth_ecp5.log synth_xilinx.log synth_hmac_xilinx.log \
	    synth_report/ SYNTH_REPORT.md

regen_vectors:
	python tb/gen_random_vectors.py > tb/random_vectors.h
