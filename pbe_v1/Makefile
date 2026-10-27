# Requires: iverilog, yosys, python3.  IHP_LIB points at an IHP sg13g2 standard-cell liberty file
# (github.com/IHP-GmbH/IHP-Open-PDK, ihp-sg13g2/libs.ref/sg13g2_stdcell/lib/).
SRC     := src/pbe_fifo.sv src/pbe_host_spi.sv src/pbe_engine.sv src/tt_um_pbe.sv
IHP_LIB ?= ../ihp_lib/sg13g2_stdcell_typ_1p20V_25C.lib

.PHONY: test synth timing clean

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

test/conc_image.hex: programs/i2c_ctrl.pbe programs/onewire_ctrl.pbe tools/pbe_asm.py
	python3 tools/pbe_asm.py -o $@ programs/i2c_ctrl.pbe@0 programs/onewire_ctrl.pbe@34

test: test/conc_image.hex test/ow_image.hex test/modbus_image.hex test/nop_image.hex test/uart_image.hex test/spi_image.hex test/mixed_image.hex
	cd test && iverilog -g2012 -o restart.vvp tb_engine_restart.sv $(addprefix ../,$(SRC)) && vvp -n restart.vvp
	cd test && iverilog -g2012 -o sim.vvp tb_pbe.sv $(addprefix ../,$(SRC)) && vvp -n sim.vvp

synth:
	mkdir -p synth
	sed 's#\$$LIB#$(IHP_LIB)#g' synth/synth.ys.in > synth/synth.ys
	yosys -q -l synth/synth.log synth/synth.ys
	@grep "Chip area" synth/synth.log | tail -1

clean:
	rm -f test/sim.vvp test/*.vcd synth/synth.ys synth/*.log synth/*_netlist.v

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
