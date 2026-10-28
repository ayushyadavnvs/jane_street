# Requires: iverilog, yosys, python3.  IHP_LIB points at an IHP sg13g2 standard-cell liberty file
# (github.com/IHP-GmbH/IHP-Open-PDK, ihp-sg13g2/libs.ref/sg13g2_stdcell/lib/).
SRC     := src/pbe_fifo.sv src/pbe_host_spi.sv src/pbe_crc.sv src/pbe_line.sv src/pbe_engine.sv src/tt_um_pbe.sv
IHP_LIB ?= ../ihp_lib/sg13g2_stdcell_typ_1p20V_25C.lib

.PHONY: test test-proto test-usb synth timing clean

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
LINT = cd test && for tb in tb_engine_restart tb_engine_ops tb_line tb_usb tb_proto tb_pbe; do \
	  if iverilog -g2012 -o /dev/null $$tb.sv $(addprefix ../,$(SRC)) 2>&1 | grep "Static variable initialization"; then exit 1; fi; done

test/ops_image.hex: test/ops_test.pbe tools/pbe_asm.py
	python3 tools/pbe_asm.py -o $@ test/ops_test.pbe@0

test: $(IMAGES:%=test/%_image.hex) test/ops_image.hex
	$(LINT)
	cd test && iverilog -g2012 -o restart.vvp tb_engine_restart.sv $(addprefix ../,$(SRC)) && vvp -n restart.vvp
	cd test && iverilog -g2012 -o ops.vvp tb_engine_ops.sv $(addprefix ../,$(SRC)) && vvp -n ops.vvp
	cd test && iverilog -g2012 -o line.vvp tb_line.sv $(addprefix ../,$(SRC)) && vvp -n line.vvp
	cd test && iverilog -g2012 -o usb.vvp tb_usb.sv $(addprefix ../,$(SRC)) && vvp -n usb.vvp
	cd test && iverilog -g2012 -o proto.vvp tb_proto.sv $(addprefix ../,$(SRC)) && vvp -n proto.vvp
	cd test && iverilog -g2012 -o sim.vvp tb_pbe.sv $(addprefix ../,$(SRC)) && vvp -n sim.vvp

# only USB (tb_usb), a quicker loop while working on it
test-usb: $(IMAGES:%=test/%_image.hex)
	$(LINT)
	cd test && iverilog -g2012 -o usb.vvp tb_usb.sv $(addprefix ../,$(SRC)) && vvp -n usb.vvp

# only the device-side and LED protocols (tb_proto), a quicker loop while working on them
test-proto: $(IMAGES:%=test/%_image.hex)
	$(LINT)
	cd test && iverilog -g2012 -o proto.vvp tb_proto.sv $(addprefix ../,$(SRC)) && vvp -n proto.vvp

synth:
	mkdir -p synth
	sed 's#\$$LIB#$(IHP_LIB)#g' synth/synth.ys.in > synth/synth.ys
	yosys -q -l synth/synth.log synth/synth.ys
	@grep "Chip area" synth/synth.log | tail -1

clean:
	rm -f test/*.vvp test/*.vcd synth/synth.ys synth/*.log synth/*_netlist.v

# Logic-only critical path with ABC (no wires, no clock tree). Add clk-to-Q (~0.57 ns) and
# setup (~0.31 ns) from the slow library for a register-to-register estimate.
IHP_SLOW ?= ../ihp_lib/sg13g2_stdcell_slow_1p08V_125C.lib
timing:
	mkdir -p synth
	yosys -q -l synth/timing.log -p "read_verilog -sv $(SRC); synth -top tt_um_pbe -flatten; \
	  dfflibmap -liberty $(IHP_SLOW); \
	  abc -liberty $(IHP_SLOW) -script +strash;dch,-f;map,-B,0.9;topo;buffer,-p;upsize;dnsize;stime,-p" >/dev/null
	@grep -o 'Delay = *[0-9.]* ps' synth/timing.log | tail -1
	@grep -o 'Start-point = .*' synth/timing.log | tail -1
