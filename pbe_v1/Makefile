# Requires: iverilog, yosys, python3.  IHP_LIB points at an IHP sg13g2 standard-cell liberty file
# (github.com/IHP-GmbH/IHP-Open-PDK, ihp-sg13g2/libs.ref/sg13g2_stdcell/lib/).
# ENG_SRC: everything below the top level (the engine-only benches compile only these).
# SRC: the design. The program memory is an IHP SRAM macro per engine (pbe_pmem_sram.sv, D82):
#  - simulation uses IHP's model of the macro (SRAM_MODEL, FUNCTIONAL selects its behavioural core);
#  - synthesis and lint use the black box src/sram_bb.v (the flow does too, via info.yaml).
# PBE_PMEM_FF selects the flip-flop fallback instead (64 words per engine, `make test-ff`).
ENG_SRC := src/pbe_fifo.sv src/pbe_host_spi.sv src/pbe_crc.sv src/pbe_line.sv src/pbe_bsync.sv src/pbe_engine.sv
SRC     := $(ENG_SRC) src/pbe_pmem_sram.sv src/tt_um_pbe.sv
SRAM_BB := src/sram_bb.v
IHP_LIB ?= ../ihp_lib/sg13g2_stdcell_typ_1p20V_25C.lib

# the debug-port target models (D75, D76)
DEBUG_MODELS := jtag_tap.sv swd_dp.sv
# the device models of the D84-D88 protocols
PROTO2_MODELS := ps2_dev.sv hc_chain.sv qspi_flash_model.sv hdlc_model.sv

.PHONY: test test-proto test-usb test-can test-debug test-gl test-ff synth timing clean

# IHP's model of the SRAM macro, for simulation (the same files as test/sram_model, D82)
SRAM_DIR   := ../macros/RM_IHPSG13_1P_256x16_c2_bm_bist
SRAM_MODEL := $(SRAM_DIR)/RM_IHPSG13_1P_256x16_c2_bm_bist.v $(SRAM_DIR)/RM_IHPSG13_1P_core_behavioral_bm_bist.v
# Top-level benches: the design and the model. Engine-only benches: ENG_SRC alone (an
# uninstantiated top level would become a root with an unconnected macro, whose model stops).
TOP     = -DFUNCTIONAL $(addprefix ../,$(SRC) $(SRAM_MODEL))
ENG     = $(addprefix ../,$(ENG_SRC))

test/uart_image.hex: programs/uart_tx.pbe programs/uart_rx.pbe tools/pbe_asm.py
	python3 tools/pbe_asm.py -o $@ programs/uart_tx.pbe@0:0 programs/uart_rx.pbe@1:8

test/spi_image.hex: programs/spi_ctrl.pbe tools/pbe_asm.py
	python3 tools/pbe_asm.py -o $@ programs/spi_ctrl.pbe@0:0

test/mixed_image.hex: programs/uart_tx.pbe programs/i2c_ctrl.pbe tools/pbe_asm.py
	python3 tools/pbe_asm.py -o $@ programs/uart_tx.pbe@0:0 programs/i2c_ctrl.pbe@1:8

test/nop_image.hex: programs/nop_test.pbe tools/pbe_asm.py
	python3 tools/pbe_asm.py -o $@ programs/nop_test.pbe@0:0

test/ow_image.hex: programs/onewire_ctrl.pbe tools/pbe_asm.py
	python3 tools/pbe_asm.py -o $@ programs/onewire_ctrl.pbe@1:0

test/modbus_image.hex: programs/modbus_rtu.pbe tools/pbe_asm.py
	python3 tools/pbe_asm.py -o $@ programs/modbus_rtu.pbe@0:0

test/ws2812_image.hex: programs/ws2812.pbe tools/pbe_asm.py
	python3 tools/pbe_asm.py -o $@ programs/ws2812.pbe@0:0

test/spi_periph_image.hex: programs/spi_periph.pbe tools/pbe_asm.py
	python3 tools/pbe_asm.py -o $@ programs/spi_periph.pbe@0:0

test/i2c_target_image.hex: programs/i2c_target.pbe programs/i2c_watch.pbe tools/pbe_asm.py
	python3 tools/pbe_asm.py -o $@ programs/i2c_target.pbe@0:0 programs/i2c_watch.pbe@1:0

test/usb_image.hex: programs/usb_dev.pbe tools/pbe_asm.py
	python3 tools/pbe_asm.py -o $@ programs/usb_dev.pbe@0:0

test/can_image.hex: programs/can_node.pbe tools/pbe_asm.py
	python3 tools/pbe_asm.py -o $@ programs/can_node.pbe@0:0 programs/can_node.pbe@1:128

test/debug_image.hex: programs/jtag.pbe programs/swd.pbe tools/pbe_asm.py
	python3 tools/pbe_asm.py -o $@ programs/jtag.pbe@0:0 programs/swd.pbe@1:192

test/ps2_image.hex: programs/ps2_host.pbe tools/pbe_asm.py
	python3 tools/pbe_asm.py -o $@ programs/ps2_host.pbe@0:0

test/gpio_image.hex: programs/gpio_expander.pbe tools/pbe_asm.py
	python3 tools/pbe_asm.py -o $@ programs/gpio_expander.pbe@0:0

test/la_image.hex: programs/la_capture.pbe programs/wavegen.pbe tools/pbe_asm.py
	python3 tools/pbe_asm.py -o $@ programs/la_capture.pbe@0:0 programs/wavegen.pbe@1:0

test/qspi_image.hex: programs/qspi_flash.pbe tools/pbe_asm.py
	python3 tools/pbe_asm.py -o $@ programs/qspi_flash.pbe@0:0

test/hdlc_image.hex: programs/hdlc_tx.pbe programs/hdlc_rx.pbe tools/pbe_asm.py
	python3 tools/pbe_asm.py -o $@ programs/hdlc_tx.pbe@0:0 programs/hdlc_rx.pbe@1:0

test/eth_image.hex: programs/eth_tx.pbe programs/eth_rx.pbe tools/pbe_asm.py
	python3 tools/pbe_asm.py -o $@ programs/eth_tx.pbe@0:0 programs/eth_rx.pbe@1:0

test/conc_image.hex: programs/onewire_ctrl.pbe programs/i2c_ctrl.pbe tools/pbe_asm.py
	python3 tools/pbe_asm.py -o $@ programs/onewire_ctrl.pbe@0:130 programs/i2c_ctrl.pbe@1:0

IMAGES := conc ow modbus nop uart spi mixed ws2812 spi_periph i2c_target usb can debug page page_loop ps2 gpio la qspi hdlc eth

# A variable declared with an initializer inside a procedural block is static: the initializer
# runs once, at time 0, not each time the block runs (BUG-023). Icarus only warns, so fail on it.
LINT = cd test && for tb in tb_fetch tb_page tb_usb tb_proto tb_pbe tb_can tb_debug tb_ps2 tb_gpio tb_la tb_qspi tb_hdlc tb_quad tb_eth; do \
	  if iverilog -g2012 -o /dev/null $$tb.sv can_ref_node.sv $(DEBUG_MODELS) $(PROTO2_MODELS) eth_model.sv $(TOP) 2>&1 | grep "Static variable initialization"; then exit 1; fi; done; \
	  for tb in tb_engine_restart tb_engine_ops tb_line; do \
	  if iverilog -g2012 -o /dev/null $$tb.sv $(ENG) 2>&1 | grep "Static variable initialization"; then exit 1; fi; done

test/ops_image.hex: test/ops_test.pbe tools/pbe_asm.py
	python3 tools/pbe_asm.py -o $@ test/ops_test.pbe@0:0

test/can_ops_image.hex: test/can_ops.pbe tools/pbe_asm.py
	python3 tools/pbe_asm.py -o $@ test/can_ops.pbe@0:0

# PAGE (D83): a 201-word program on engine 0, the stop/restart checks on engine 1; the loop
test/page_image.hex: test/page_test.pbe test/page_restart.pbe tools/pbe_asm.py
	python3 tools/pbe_asm.py -o $@ test/page_test.pbe@0:0 test/page_restart.pbe@1:0

test/page_loop_image.hex: test/page_loop.pbe tools/pbe_asm.py
	python3 tools/pbe_asm.py -o $@ test/page_loop.pbe@0:0

test/fetch_image.hex: test/fetch_timing.pbe test/fetch_stream.pbe test/fetch_host.pbe tools/pbe_asm.py
	python3 tools/pbe_asm.py -o $@ test/fetch_timing.pbe@0:0 test/fetch_stream.pbe@0:128 test/fetch_host.pbe@1:200

test: test-manchester-idle $(IMAGES:%=test/%_image.hex) test/ops_image.hex test/can_ops_image.hex test/fetch_image.hex
	$(LINT)
	$(MAKE) test-timeout-boundary test-parity-boundary
	cd test && iverilog -g2012 -o fifo_robustness.vvp tb_fifo_robustness.sv ../src/pbe_fifo.sv && vvp -n fifo_robustness.vvp
	cd test && iverilog -g2012 -o known_reset.vvp tb_engine_known_reset.sv $(ENG) && vvp -n known_reset.vvp
	cd test && iverilog -g2012 -o restart.vvp tb_engine_restart.sv $(ENG) && vvp -n restart.vvp
	cd test && iverilog -g2012 -o ops.vvp tb_engine_ops.sv $(ENG) && vvp -n ops.vvp
	cd test && iverilog -g2012 -o fetch.vvp tb_fetch.sv $(TOP) && vvp -n fetch.vvp
	cd test && iverilog -g2012 -o page.vvp tb_page.sv $(TOP) && vvp -n page.vvp
	cd test && iverilog -g2012 -o line.vvp tb_line.sv $(ENG) && vvp -n line.vvp
	cd test && iverilog -g2012 -o crc.vvp tb_crc.sv ref_pbe_crc16.sv ../src/pbe_crc.sv && vvp -n crc.vvp
	cd test && iverilog -g2012 -o usb.vvp tb_usb.sv $(TOP) && vvp -n usb.vvp
	cd test && iverilog -g2012 -o proto.vvp tb_proto.sv $(TOP) && vvp -n proto.vvp
	cd test && iverilog -g2012 -o sim.vvp tb_pbe.sv $(TOP) && vvp -n sim.vvp
	cd test && iverilog -g2012 -o can.vvp tb_can.sv can_ref_node.sv $(TOP) && vvp -n can.vvp
	cd test && iverilog -g2012 -o debug.vvp tb_debug.sv $(DEBUG_MODELS) $(TOP) && vvp -n debug.vvp
	$(MAKE) test-proto2
	$(MAKE) test-quad-unit
	$(MAKE) test-eth
	$(MAKE) test-ff
	$(PYTHON) $(V)/spec_boundaries/check_spec_boundaries.py
	$(MAKE) test-model
	$(PYTHON) -m unittest discover -s $(V)/formal -p test_runner.py -v
	$(MAKE) test-coverage-tools
	$(MAKE) test-sigrok-extract
	$(MAKE) diff N=2 CYCLES=600 SEED=0x504245
	$(MAKE) diff-can CAN_TRIALS=3

# The flip-flop fallback (PBE_PMEM_FF, D82): 64 words per engine, so only the benches whose
# programs all sit below word 64 of their engine's memory (tb_usb, tb_proto). The engine-only
# testbenches do not use the top level, so they are not repeated.
FF_ALL = -DPBE_PMEM_FF $(addprefix ../,$(ENG_SRC) src/tt_um_pbe.sv)
test-ff: test/usb_image.hex test/ws2812_image.hex test/spi_periph_image.hex test/i2c_target_image.hex
	cd test && iverilog -g2012 -o usb_ff.vvp tb_usb.sv $(FF_ALL) && vvp -n usb_ff.vvp
	cd test && iverilog -g2012 -o proto_ff.vvp tb_proto.sv $(FF_ALL) && vvp -n proto_ff.vvp

# Testbenches under Verilator as well as Icarus (BUG-102). Two simulators may run the processes
# woken by one clock edge in different orders, so a testbench race shows up as a difference: each
# bench must pass under both, and their logs must be identical (only the $finish line, which
# differs in format, is left out). VL_BENCHES are the benches the Verilator in CI (Ubuntu's 5.020)
# runs correctly; tb_engine_ops (BUG-103) and tb_proto (`disable` of a named fork) need 5.05x.
VERILATOR  ?= verilator
VL_BENCHES ?= tb_line tb_engine_restart tb_engine_known_reset tb_fifo_robustness tb_fetch tb_page
VL_BUILD   := build/verilator
.PHONY: test-verilator
test-verilator: $(IMAGES:%=test/%_image.hex) test/ops_image.hex test/can_ops_image.hex test/fetch_image.hex
	mkdir -p $(VL_BUILD)
	set -e; for tb in $(VL_BENCHES); do \
	  echo "== $$tb"; \
	  case $$tb in tb_line|tb_engine_*|tb_fifo_*) srcs="$(ENG)";; *) srcs="$(TOP)";; esac; \
	  (cd test && $(VERILATOR) --binary --timing --assert -Wno-fatal -j 2 --top-module $$tb \
	    --Mdir ../$(VL_BUILD)/obj_$$tb -o sim $$tb.sv $$srcs) > $(VL_BUILD)/$$tb-build.log 2>&1 \
	    || { tail -20 $(VL_BUILD)/$$tb-build.log; exit 1; }; \
	  (cd test && ../$(VL_BUILD)/obj_$$tb/sim) > $(VL_BUILD)/$$tb-verilator.log 2>&1 \
	    || { tail -20 $(VL_BUILD)/$$tb-verilator.log; exit 1; }; \
	  (cd test && iverilog -g2012 -o ../$(VL_BUILD)/$$tb.vvp $$tb.sv $$srcs 2>/dev/null \
	    && vvp -n ../$(VL_BUILD)/$$tb.vvp) > $(VL_BUILD)/$$tb-icarus.log 2>&1 \
	    || { tail -20 $(VL_BUILD)/$$tb-icarus.log; exit 1; }; \
	  grep -v '\$$finish' $(VL_BUILD)/$$tb-icarus.log > $(VL_BUILD)/$$tb-icarus.cmp; \
	  grep -v -e '\$$finish' -e '^- ' $(VL_BUILD)/$$tb-verilator.log > $(VL_BUILD)/$$tb-verilator.cmp; \
	  diff $(VL_BUILD)/$$tb-icarus.cmp $(VL_BUILD)/$$tb-verilator.cmp \
	    || { echo "$$tb: Icarus and Verilator logs differ (a race?)"; exit 1; }; \
	  tail -1 $(VL_BUILD)/$$tb-icarus.cmp; \
	done

# 10BASE-T (D93): eth_tx.pbe and eth_rx.pbe against eth_model.sv, a link partner from IEEE 802.3
.PHONY: test-eth
test-eth: test/eth_image.hex
	cd test && iverilog -g2012 -o eth.vvp tb_eth.sv eth_model.sv $(TOP) && vvp -n eth.vvp

# The quad host port (D89): tb_quad (modes, pins, recovery, a program load and a UART loopback),
# and the logic analyser bench with its whole host side in quad mode (+QUAD, tb_host.svh).
.PHONY: test-quad-unit test-quad
test-quad-unit: test/uart_image.hex test/la_image.hex
	cd test && iverilog -g2012 -o quad.vvp tb_quad.sv $(TOP) && vvp -n quad.vvp
	cd test && iverilog -g2012 -o la_quad.vvp tb_la.sv $(TOP) && vvp -n la_quad.vvp +QUAD

# Longer: tb_pbe (UART, SPI, I2C, 1-Wire, Modbus, SMBus) with its host in quad mode.
test-quad: test-quad-unit $(IMAGES:%=test/%_image.hex)
	cd test && iverilog -g2012 -o sim_quad.vvp tb_pbe.sv $(TOP) && vvp -n sim_quad.vvp +QUAD

# only USB (tb_usb), a quicker loop while working on it
test-usb: $(IMAGES:%=test/%_image.hex)
	$(LINT)
	cd test && iverilog -g2012 -o usb.vvp tb_usb.sv $(TOP) && vvp -n usb.vvp

# The protocols of D84-D88, each against its own model written from the specification.
.PHONY: test-proto2 test-ps2 test-gpio test-la test-qspi test-hdlc
test-proto2: test-ps2 test-gpio test-la test-qspi test-hdlc

test-hdlc: test/hdlc_image.hex
	cd test && iverilog -g2012 -o hdlc.vvp tb_hdlc.sv hdlc_model.sv $(TOP) && vvp -n hdlc.vvp

test-qspi: test/qspi_image.hex
	cd test && iverilog -g2012 -o qspi.vvp tb_qspi.sv qspi_flash_model.sv $(TOP) && vvp -n qspi.vvp

test-la: test/la_image.hex
	cd test && iverilog -g2012 -o la.vvp tb_la.sv $(TOP) && vvp -n la.vvp

test-gpio: test/gpio_image.hex
	cd test && iverilog -g2012 -o gpio.vvp tb_gpio.sv hc_chain.sv $(TOP) && vvp -n gpio.vvp

test-ps2: test/ps2_image.hex
	cd test && iverilog -g2012 -o ps2.vvp tb_ps2.sv ps2_dev.sv $(TOP) && vvp -n ps2.vvp

# only CAN (tb_can); ONLY=rates|arb|ack|inject|biterr|busoff|two runs one scenario
test-can: $(IMAGES:%=test/%_image.hex)
	$(LINT)
	cd test && iverilog -g2012 -o can.vvp tb_can.sv can_ref_node.sv $(TOP) && vvp -n can.vvp $(if $(ONLY),+ONLY=$(ONLY))

# only JTAG and SWD (tb_debug); ONLY=jtag|swd|both|slow runs one phase
test-debug: test/debug_image.hex
	$(LINT)
	cd test && iverilog -g2012 -o debug.vvp tb_debug.sv $(DEBUG_MODELS) $(TOP) && vvp -n debug.vvp $(if $(ONLY),+ONLY=$(ONLY))

# only the device-side and LED protocols (tb_proto), a quicker loop while working on them
test-proto: $(IMAGES:%=test/%_image.hex)
	$(LINT)
	cd test && iverilog -g2012 -o proto.vvp tb_proto.sv $(TOP) && vvp -n proto.vvp

# The end-to-end testbenches on the gate-level netlist from the Tiny Tapeout flow (run by the
# gds workflow). GL_NETLIST is the routed netlist (tt_submission/*.v); PDK_ROOT and PDK point at
# the standard-cell Verilog models.
PDK      ?= ihp-sg13cmos5l
PDK_CELL  = $(patsubst ihp-%,%,$(PDK))
PDK_VLOG  = $(PDK_ROOT)/$(PDK)/libs.ref/$(PDK_CELL)_stdcell/verilog
GL_SRC    = $(abspath $(GL_NETLIST)) $(wildcard $(PDK_VLOG)/$(PDK_CELL)_udp.v) $(PDK_VLOG)/$(PDK_CELL)_stdcell.v \
            $(addprefix ../,$(SRAM_MODEL))
GL_FLAGS  = -DGL_TEST -DFUNCTIONAL -DSIM

test-gl: $(IMAGES:%=test/%_image.hex) test/fetch_image.hex
	test -f "$(GL_NETLIST)" && test -d "$(PDK_VLOG)"
	cd test && iverilog -g2012 $(GL_FLAGS) -o fetch_gl.vvp tb_fetch.sv $(GL_SRC) && vvp -n fetch_gl.vvp
	cd test && iverilog -g2012 $(GL_FLAGS) -o page_gl.vvp tb_page.sv $(GL_SRC) && vvp -n page_gl.vvp
	cd test && iverilog -g2012 $(GL_FLAGS) -o proto_gl.vvp tb_proto.sv $(GL_SRC) && vvp -n proto_gl.vvp
	cd test && iverilog -g2012 $(GL_FLAGS) -o usb_gl.vvp tb_usb.sv $(GL_SRC) && vvp -n usb_gl.vvp
	cd test && iverilog -g2012 $(GL_FLAGS) -o sim_gl.vvp tb_pbe.sv $(GL_SRC) && vvp -n sim_gl.vvp

# Synthesis of the default build. The SRAM macros are black boxes (src/sram_bb.v), so the
# area is the standard cells only (the macros add 2 x 28,127 um2, from the LEF). The macros'
# instance names after flattening are listed: the flow's MACROS uses them.
# `make synth FF=1` synthesizes the flip-flop fallback (PBE_PMEM_FF) instead.
SYNTH_DEFS = $(if $(FF),-DPBE_PMEM_FF)
synth:
	mkdir -p synth
	sed -e 's#\$$LIB#$(IHP_LIB)#g' -e 's#\$$SRC#$(SRC) $(SRAM_BB)#' -e 's#\$$DEFS#$(SYNTH_DEFS)#' \
	  synth/synth.ys.in > synth/synth.ys
	yosys -q -l synth/synth.log synth/synth.ys
	@grep "Chip area" synth/synth.log | tail -1
	@grep "^tt_um_ayushyadavnvs_pbe/u_pmem\." synth/synth.log

clean:
	rm -f test/*.vvp test/*.vcd synth/synth.ys synth/*.log synth/*_netlist.v

# Logic-only critical path with ABC (no wires, no clock tree). Add clk-to-Q (~0.57 ns) and
# setup (~0.31 ns) from the slow library for a register-to-register estimate. The SRAM macros
# are black boxes: their outputs count as path start points with no delay, so add the macro's
# clock-to-DOUT (5.06 ns at the slow corner, its datasheet) to a path that starts at A_DOUT,
# and its inputs are end points (A_ADDR setup is negative, about -0.6 ns, at the slow corner).
IHP_SLOW ?= ../ihp_lib/sg13g2_stdcell_slow_1p08V_125C.lib
timing:
	mkdir -p synth
	yosys -q -l synth/timing.log -p "read_verilog $(SYNTH_DEFS) -sv $(SRC) $(SRAM_BB); synth -top tt_um_ayushyadavnvs_pbe -flatten; \
	  dfflibmap -liberty $(IHP_SLOW); \
	  abc -liberty $(IHP_SLOW) -script +strash;dch,-f;map,-B,0.9;topo;buffer,-p;upsize;dnsize;stime,-p" >/dev/null
	@grep -o 'Delay = *[0-9.]* ps' synth/timing.log | tail -1
	@grep -o 'Start-point = .*' synth/timing.log | tail -1

# Verification only (the golden model, sigrok decoding and bus models live in
# ../verify/golden-model; formal, vectors, coverage, stress and mutation in ../verify, D64).
# Install golden-model/differential/requirements.txt into a virtual environment.
V  := ../verify
GM := $(V)/golden-model
PYTHON ?= $(if $(wildcard ../.venv/bin/python),$(abspath ../.venv/bin/python),python3)
N ?= 1000
SEED ?= 0x504245
CYCLES ?= 1200
.PHONY: diff test-model

diff:
	$(PYTHON) $(GM)/differential/run.py --n $(N) --seed $(SEED) --cycles $(CYCLES) $(if $(filter 1,$(ETHERNET)),--ethernet,)

test-model:
	cd $(GM) && $(PYTHON) -m unittest discover -s model -p 'test_*.py' -v

.PHONY: diff-line
diff-line:
	$(PYTHON) $(GM)/model/check_line_model.py

# CAN mode (pbe_bsync) against verify/golden-model/model/can_model.py, seeded random (D66)
CAN_TRIALS ?= 40
CAN_SEED ?= 0x43414E
.PHONY: diff-can
diff-can:
	$(PYTHON) $(GM)/model/check_bsync_model.py --seed $(CAN_SEED) --trials $(CAN_TRIALS)

.PHONY: diff-engine-line
diff-engine-line:
	$(PYTHON) $(GM)/model/check_engine_line_model.py

SIGROK_CLI ?= sigrok-cli
.PHONY: sigrok sigrok-full test-sigrok-extract
sigrok:
	$(PYTHON) $(GM)/sigrok/sigrok_verify.py --sigrok-cli "$(SIGROK_CLI)"

# sigrok's stock can decoder on tb_can's bus at 125k-1M (D72)
.PHONY: sigrok-can
sigrok-can:
	$(PYTHON) $(GM)/sigrok/can_verify.py --sigrok-cli "$(SIGROK_CLI)"

# sigrok's stock jtag and swd decoders on tb_debug's pins (D77)
.PHONY: sigrok-debug
sigrok-debug:
	$(PYTHON) $(GM)/sigrok/debug_verify.py --sigrok-cli "$(SIGROK_CLI)"

# sigrok's stock decoders on the pins of the D84-D88 protocols (ps2, spi for the 74HC chain and
# the single-line phase of QSPI); PROTO2=ps2|gpio|qspi runs one
.PHONY: sigrok-proto2
sigrok-proto2:
	$(PYTHON) $(GM)/sigrok/proto2_verify.py --sigrok-cli "$(SIGROK_CLI)" $(PROTO2)

# A strict comparison: libsigrokdecode 0.5.3 intentionally returns nonzero here.
sigrok-full:
	$(PYTHON) $(GM)/sigrok/sigrok_verify.py --sigrok-cli "$(SIGROK_CLI)" --full-usb-request

test-sigrok-extract:
	$(PYTHON) -m unittest discover -s $(GM)/sigrok -p test_sigrok_extract.py -v

BUS_SEED ?= 20261029
CASES ?= 3
.PHONY: test-buses
test-buses:
	$(PYTHON) $(GM)/bus_models/run.py --seed $(BUS_SEED) --cases $(CASES)

# Round-2 fault audit: long runs stay outside the default gate.
.PHONY: mutate
mutate:
	$(PYTHON) $(V)/mutation/mutate.py --jobs $(or $(JOBS),2) --n 1 --cycles 600 --seed $(SEED)

FORMAL_BLOCK ?= all
FORMAL_JOBS ?= 3
FORMAL_ARGS ?=
.PHONY: formal
formal:
	$(PYTHON) $(V)/formal/run.py --block $(FORMAL_BLOCK) --jobs $(FORMAL_JOBS) $(FORMAL_ARGS)

# Independent library/catalogue packet checks; install their pinned requirements explicitly.
.PHONY: test-crc-vectors test-protocol-vectors
test-crc-vectors:
	$(PYTHON) $(V)/vectors/crc/run.py $(if $(filter 1,$(WIDE)),--wide,)

test-protocol-vectors:
	$(PYTHON) $(V)/vectors/protocols/run.py

# Source coverage remains a separate long campaign; artifact guards are quick default tests.
COVERAGE_JOBS ?= 2
.PHONY: coverage test-coverage-tools
coverage:
	$(PYTHON) $(V)/coverage/run.py --jobs $(COVERAGE_JOBS)

test-coverage-tools:
	$(PYTHON) -m unittest discover -s $(V)/coverage -p test_harness.py -v

# Optional finite robustness campaign; characterization retains adverse FAIL labels.
STRESS_SEED ?= 0x50424534
.PHONY: stress stress-characterize stress-strict
stress:
	$(PYTHON) $(V)/stress/run.py --seed $(STRESS_SEED) --required-only

stress-characterize:
	$(PYTHON) $(V)/stress/run.py --seed $(STRESS_SEED) --characterize

stress-strict:
	$(PYTHON) $(V)/stress/run.py --seed $(STRESS_SEED)

# Exact timeout deadline: catches the retained M19 >= to > fault.
.PHONY: test-timeout-boundary
test-timeout-boundary:
	mkdir -p build
	iverilog -g2012 -s tb_timeout_boundary -o build/timeout-boundary.vvp ../verify/ethernet/tb_timeout_boundary.sv $(ENG_SRC)
	vvp -n build/timeout-boundary.vvp

.PHONY: test-parity-boundary
test-parity-boundary:
	mkdir -p build
	iverilog -g2012 -s tb_parity_boundary -o build/parity-boundary.vvp ../verify/ethernet/tb_parity_boundary.sv $(ENG_SRC)
	vvp -n build/parity-boundary.vvp

# Round 3: independent Ethernet/HDLC verification (long targets remain opt-in).
.PHONY: test-manchester-idle test-ethernet-corners test-wire-vectors stress-ethernet coverage-ethernet mutate-ethernet
test-manchester-idle:
	mkdir -p build
	iverilog -g2012 -s tb_manchester_idle_wait -o build/mc_idle.vvp ../verify/ethernet/tb_manchester_idle_wait.sv src/pbe_line.sv
	vvp build/mc_idle.vvp
test-ethernet-corners:
	$(PYTHON) ../verify/ethernet/run_directed.py
test-wire-vectors:
	$(PYTHON) ../verify/ethernet/run_wire.py --sim verilator
stress-ethernet:
	$(PYTHON) ../verify/ethernet/run_wire.py --sim verilator --stress
coverage-ethernet:
	$(PYTHON) ../verify/coverage/run.py --jobs 1 --ethernet
mutate-ethernet:
	$(PYTHON) ../verify/mutation/ethernet_mutate.py
