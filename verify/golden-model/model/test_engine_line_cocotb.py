"""Engine/coder interaction, byte CRC feed and registered event checks."""
import random

import cocotb
from cocotb.triggers import Timer

from pbe_model import EngineModel


@cocotb.test()
async def differential_engine_line(dut):
    seed = 0x454c494e45
    rng = random.Random(seed)
    model = EngineModel()
    program = [0xd800] * 128
    cycle = 0
    effects_names = ('tx_pop', 'rx_push', 'rx_data', 'flag_set', 'flag_clr', 'irq')
    states = ('pins_out', 'pins_oe', 'status', 'crc_now', 'pc')

    async def edge(**inputs):
        nonlocal cycle
        dut.clk.value = 0
        for key, value in model.config.items():
            getattr(dut, key).value = int(value)
        for key, value in inputs.items():
            getattr(dut, key).value = int(value)
        dut.instr.value = program[model.pc]
        await Timer(10416, unit='ps')
        expected_effects = model.effects(**inputs)
        actual_effects = {name: int(getattr(dut, name).value) for name in effects_names}
        assert actual_effects == {name: int(expected_effects[name]) for name in effects_names}, (
            f'seed={seed} cycle={cycle} pre-edge pc={model.pc} instruction={model.instr_q:04x} '
            f'expected={expected_effects} actual={actual_effects} state={model.snapshot()}')
        model.step(program, **inputs)
        dut.clk.value = 1
        await Timer(10416, unit='ps')
        actual = {name: int(getattr(dut, name).value) for name in states}
        expected = {name: int(getattr(model, name)) for name in states}
        assert actual == expected, (f'seed={seed} cycle={cycle} pc={model.pc} instruction={model.instr_q:04x} '
                                    f'config={model.config} inputs={inputs} expected={expected} actual={actual} '
                                    f'state={model.snapshot()} line={vars(model.line)}')
        cycle += 1

    defaults = dict(pins_in=255, flags=0, tx_empty=True, tx_data=0, rx_full=False,
                    restart=False, pm_wr=False, host_crc_init=False, host_tmo_clr=False,
                    host_ovf_clr=False, host_lerr_clr=False)
    dut.clk.value = 0
    dut.rst_n.value = 0
    for key, value in dict(model.config, **defaults).items():
        getattr(dut, key).value = int(value)
    dut.instr.value = 0xd800
    await Timer(20832, unit='ps')
    dut.rst_n.value = 1
    for trial in range(64):
        cfg = (trial & 1) + 1 | (trial >> 1 & 3) << 2 | (trial >> 3 & 1) << 4 | (trial >> 4 & 1) << 5
        model.configure(run=True, coder_cfg=cfg, sync=rng.choice((0, 0x80, 0x55)),
                        clkdiv=rng.choice((0, 1, 3, 7, 19)), start_pc=rng.choice((0, 64)),
                        pin_base=rng.randrange(8), jmp_pin=rng.randrange(8),
                        out_msb_first=bool(rng.getrandbits(1)), in_msb_first=bool(rng.getrandbits(1)),
                        crc_cfg=rng.randrange(256), crc_poly=rng.randrange(65536),
                        crc_good=rng.choice((0, 0x800d)), timeout=rng.choice((0, 1, 4, 20)),
                        line_cfg=rng.randrange(256))
        program[:] = [rng.randrange(65536) for _ in range(128)]
        await edge(**dict(defaults, restart=True))
        for _ in range(1000):
            inputs = dict(defaults, pins_in=rng.randrange(256), flags=rng.randrange(16),
                          tx_empty=rng.random() < .35, rx_full=rng.random() < .15,
                          tx_data=rng.randrange(256), restart=rng.random() < .003,
                          pm_wr=rng.random() < .01, host_crc_init=rng.random() < .01,
                          host_tmo_clr=rng.random() < .01, host_ovf_clr=rng.random() < .01,
                          host_lerr_clr=rng.random() < .01)
            model.config['run'] = rng.random() >= .02
            await edge(**inputs)
            if inputs['pm_wr']:
                program[rng.randrange(128)] = rng.randrange(65536)
    dut._log.info('Engine/line composition matched %d clocks, seed=%#x', cycle, seed)
