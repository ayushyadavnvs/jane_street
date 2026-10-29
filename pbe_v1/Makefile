# Requires: iverilog, yosys, python3.  IHP_LIB points at an IHP sg13g2 standard-cell liberty file
# (github.com/IHP-GmbH/IHP-Open-PDK, ihp-sg13g2/libs.ref/sg13g2_stdcell/lib/).
SRC     := src/pbe_fifo.sv src/pbe_host_spi.sv src/pbe_crc.sv src/pbe_line.sv src/pbe_engine.sv src/tt_um_pbe.sv
IHP_LIB ?= ../ihp_lib/sg13g2_stdcell_typ_1p20V_25C.lib

.PHONY: test test-proto test-usb test-gl test-sram synth synth-sram timing clean

# The SRAM program memory (D55, a proposal): the wrapper, IHP's model of the macro (FUNCTIONAL
# selects its behavioural core) and, for synthesis, the macro as a black box.
SRAM_DIR   := ../macros/RM_IHPSG13_1P_256x16_c2_bm_bist
SRAM_MODEL := $(SRAM_DIR)/RM_IHPSG13_1P_256x16_c2_bm_bist.v $(SRAM_DIR)/RM_IHPSG13_1P_core_behavioral_bm_bist.v
SRAM_SRC   := src/pbe_pmem_sram.sv

test/uart_image.hex: programs/uart_tx.pbe programs/uart_rx.pbe tools/pbe_asm.py
	python3 tools/pbe_asm.py -o $@ programs/uart_tx.pbe@0 programs/uart_rx.pbe@8

test/spi_image.hex: programs/spi_ctrl.pbe tools/pbe_asm.py
	python3 tools/pbe_asm.py -o $@ programs/spi_ctrl.pbe@0

test/mixed_image.hex: programs/uart_tx.pbe programs/i2c_ctrl.pbe tools/pbe_asm.py
	python3 tools/pbe_asm.py -o $@ programs/uart_tx.pbe@0 programs/i2c_ctrl.pbe@8

test/nop_image.hex: programs/nop_test.pbe tools/pbe_asm.py
	python3 tools/pbe_asm.py -o $@ programs/nop_test.pbe@0

test/ow_image.hex: programs/onewire_ctrl.pbe tools/pbe_asm.py
	python3 tools/pbe_asm.py -o $@ programs/onewire_ctrl.pbe@0

test/modbus_image.hex: programs/modbus_rtu.pbe tools/pbe_asm.py
	python3 tools/pbe_asm.py -o $@ programs/modbus_rtu.pbe@0

test/ws2812_image.hex: programs/ws2812.pbe tools/pbe_asm.py
	python3 tools/pbe_asm.py -o $@ programs/ws2812.pbe@0

test/spi_periph_image.hex: programs/spi_periph.pbe tools/pbe_asm.py
	python3 tools/pbe_asm.py -o $@ programs/spi_periph.pbe@0

test/i2c_target_image.hex: programs/i2c_target.pbe programs/i2c_watch.pbe tools/pbe_asm.py
	python3 tools/pbe_asm.py -o $@ programs/i2c_target.pbe@0 programs/i2c_watch.pbe@64

test/usb_image.hex: programs/usb_dev.pbe tools/pbe_asm.py
	python3 tools/pbe_asm.py -o $@ programs/usb_dev.pbe@0

test/conc_image.hex: programs/i2c_ctrl.pbe programs/onewire_ctrl.pbe tools/pbe_asm.py
	python3 tools/pbe_asm.py -o $@ programs/i2c_ctrl.pbe@0 programs/onewire_ctrl.pbe@64

IMAGES := conc ow modbus nop uart spi mixed ws2812 spi_periph i2c_target usb

# A variable declared with an initializer inside a procedural block is static: the initializer
# runs once, at time 0, not each time the block runs (BUG-023). Icarus only warns, so fail on it.
LINT = cd test && for tb in tb_engine_restart tb_engine_ops tb_fetch tb_line tb_usb tb_proto tb_pbe; do \
	  if iverilog -g2012 -o /dev/null $$tb.sv $(addprefix ../,$(SRC)) 2>&1 | grep "Static variable initialization"; then exit 1; fi; done

test/ops_image.hex: test/ops_test.pbe tools/pbe_asm.py
	python3 tools/pbe_asm.py -o $@ test/ops_test.pbe@0

test/fetch_image.hex: test/fetch_timing.pbe test/fetch_host.pbe tools/pbe_asm.py
	python3 tools/pbe_asm.py -o $@ test/fetch_timing.pbe@0 test/fetch_host.pbe@64

test: $(IMAGES:%=test/%_image.hex) test/ops_image.hex test/fetch_image.hex
	$(LINT)
	cd test && iverilog -g2012 -o restart.vvp tb_engine_restart.sv $(addprefix ../,$(SRC)) && vvp -n restart.vvp
	cd test && iverilog -g2012 -o ops.vvp tb_engine_ops.sv $(addprefix ../,$(SRC)) && vvp -n ops.vvp
	cd test && iverilog -g2012 -o fetch.vvp tb_fetch.sv $(addprefix ../,$(SRC)) && vvp -n fetch.vvp
	cd test && iverilog -g2012 -o line.vvp tb_line.sv $(addprefix ../,$(SRC)) && vvp -n line.vvp
	cd test && iverilog -g2012 -o usb.vvp tb_usb.sv $(addprefix ../,$(SRC)) && vvp -n usb.vvp
	cd test && iverilog -g2012 -o proto.vvp tb_proto.sv $(addprefix ../,$(SRC)) && vvp -n proto.vvp
	cd test && iverilog -g2012 -o sim.vvp tb_pbe.sv $(addprefix ../,$(SRC)) && vvp -n sim.vvp
	$(MAKE) test-sram
	$(MAKE) test-model
	$(MAKE) test-sigrok-extract
	$(MAKE) diff N=2 CYCLES=600 SEED=0x504245

# The end-to-end testbenches on the SRAM program memory (USE_SRAM, D55). The engine-only
# testbenches do not use the top level, so they are not repeated.
SRAM_FLAGS = -DUSE_SRAM -DFUNCTIONAL
SRAM_ALL   = $(addprefix ../,$(SRC) $(SRAM_SRC) $(SRAM_MODEL))
test-sram: $(IMAGES:%=test/%_image.hex) test/fetch_image.hex
	cd test && iverilog -g2012 $(SRAM_FLAGS) -o fetch_sram.vvp tb_fetch.sv $(SRAM_ALL) && vvp -n fetch_sram.vvp
	cd test && iverilog -g2012 $(SRAM_FLAGS) -o usb_sram.vvp tb_usb.sv $(SRAM_ALL) && vvp -n usb_sram.vvp
	cd test && iverilog -g2012 $(SRAM_FLAGS) -o proto_sram.vvp tb_proto.sv $(SRAM_ALL) && vvp -n proto_sram.vvp
	cd test && iverilog -g2012 $(SRAM_FLAGS) -o sim_sram.vvp tb_pbe.sv $(SRAM_ALL) && vvp -n sim_sram.vvp

# only USB (tb_usb), a quicker loop while working on it
test-usb: $(IMAGES:%=test/%_image.hex)
	$(LINT)
	cd test && iverilog -g2012 -o usb.vvp tb_usb.sv $(addprefix ../,$(SRC)) && vvp -n usb.vvp

# only the device-side and LED protocols (tb_proto), a quicker loop while working on them
test-proto: $(IMAGES:%=test/%_image.hex)
	$(LINT)
	cd test && iverilog -g2012 -o proto.vvp tb_proto.sv $(addprefix ../,$(SRC)) && vvp -n proto.vvp

# The end-to-end testbenches on the gate-level netlist from the Tiny Tapeout flow (run by the
# gds workflow). GL_NETLIST is the routed netlist (tt_submission/*.v); PDK_ROOT and PDK point at
# the standard-cell Verilog models.
PDK      ?= ihp-sg13cmos5l
PDK_CELL  = $(patsubst ihp-%,%,$(PDK))
PDK_VLOG  = $(PDK_ROOT)/$(PDK)/libs.ref/$(PDK_CELL)_stdcell/verilog
GL_SRC    = $(abspath $(GL_NETLIST)) $(wildcard $(PDK_VLOG)/$(PDK_CELL)_udp.v) $(PDK_VLOG)/$(PDK_CELL)_stdcell.v
GL_FLAGS  = -DGL_TEST -DFUNCTIONAL -DSIM

test-gl: $(IMAGES:%=test/%_image.hex) test/fetch_image.hex
	test -f "$(GL_NETLIST)" && test -d "$(PDK_VLOG)"
	cd test && iverilog -g2012 $(GL_FLAGS) -o fetch_gl.vvp tb_fetch.sv $(GL_SRC) && vvp -n fetch_gl.vvp
	cd test && iverilog -g2012 $(GL_FLAGS) -o proto_gl.vvp tb_proto.sv $(GL_SRC) && vvp -n proto_gl.vvp
	cd test && iverilog -g2012 $(GL_FLAGS) -o usb_gl.vvp tb_usb.sv $(GL_SRC) && vvp -n usb_gl.vvp
	cd test && iverilog -g2012 $(GL_FLAGS) -o sim_gl.vvp tb_pbe.sv $(GL_SRC) && vvp -n sim_gl.vvp

synth:
	mkdir -p synth
	sed 's#\$$LIB#$(IHP_LIB)#g' synth/synth.ys.in > synth/synth.ys
	yosys -q -l synth/synth.log synth/synth.ys
	@grep "Chip area" synth/synth.log | tail -1

# Synthesis with the SRAM program memory; the macros are black boxes, so their area is not in
# the total (2 x 28,127 um2, from the LEF).
synth-sram:
	mkdir -p synth
	yosys -q -l synth/synth_sram.log -p "read_verilog -DUSE_SRAM -sv $(SRC) $(SRAM_SRC); \
	  read_verilog $(SRAM_DIR)/RM_IHPSG13_1P_256x16_c2_bm_bist_bb.v; \
	  synth -top tt_um_ayushyadavnvs_pbe -flatten; dfflibmap -liberty $(IHP_LIB); abc -liberty $(IHP_LIB); \
	  opt_clean -purge; stat -liberty $(IHP_LIB); select -list t:RM_IHPSG13_*"
	@grep "Chip area" synth/synth_sram.log | tail -1
	@grep "/u_pmem" synth/synth_sram.log

clean:
	rm -f test/*.vvp test/*.vcd synth/synth.ys synth/*.log synth/*_netlist.v

# Logic-only critical path with ABC (no wires, no clock tree). Add clk-to-Q (~0.57 ns) and
# setup (~0.31 ns) from the slow library for a register-to-register estimate.
IHP_SLOW ?= ../ihp_lib/sg13g2_stdcell_slow_1p08V_125C.lib
timing:
	mkdir -p synth
	yosys -q -l synth/timing.log -p "read_verilog -sv $(SRC); synth -top tt_um_ayushyadavnvs_pbe -flatten; \
	  dfflibmap -liberty $(IHP_SLOW); \
	  abc -liberty $(IHP_SLOW) -script +strash;dch,-f;map,-B,0.9;topo;buffer,-p;upsize;dnsize;stime,-p" >/dev/null
	@grep -o 'Delay = *[0-9.]* ps' synth/timing.log | tail -1
	@grep -o 'Start-point = .*' synth/timing.log | tail -1

# Verification only. Install test/differential/requirements.txt into a virtual environment.
PYTHON ?= $(if $(wildcard ../.venv/bin/python),../.venv/bin/python,python3)
N ?= 1000
SEED ?= 0x504245
CYCLES ?= 1200
.PHONY: diff test-model

diff:
	$(PYTHON) test/differential/run.py --n $(N) --seed $(SEED) --cycles $(CYCLES)

test-model:
	$(PYTHON) -m unittest discover -s model -p 'test_*.py' -v

.PHONY: diff-line
diff-line:
	$(PYTHON) model/check_line_model.py

.PHONY: diff-engine-line
diff-engine-line:
	$(PYTHON) model/check_engine_line_model.py

SIGROK_CLI ?= sigrok-cli
.PHONY: sigrok sigrok-full test-sigrok-extract
sigrok:
	$(PYTHON) tools/sigrok_verify.py --sigrok-cli "$(SIGROK_CLI)"

# A strict comparison: libsigrokdecode 0.5.3 intentionally returns nonzero here.
sigrok-full:
	$(PYTHON) tools/sigrok_verify.py --sigrok-cli "$(SIGROK_CLI)" --full-usb-request

test-sigrok-extract:
	$(PYTHON) -m unittest discover -s test -p test_sigrok_extract.py -v

BUS_SEED ?= 20261029
CASES ?= 3
.PHONY: test-buses
test-buses:
	$(PYTHON) test/bus_models/run.py --seed $(BUS_SEED) --cases $(CASES)
