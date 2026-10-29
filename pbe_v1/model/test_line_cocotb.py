"""Reproducible line-coder differential tests; all comparisons are per clock."""
import os
import random

import cocotb
from cocotb.triggers import Timer

from pbe_model import LineModel


@cocotb.test()
async def differential_line(dut):
    # Infrastructure mutation: a failing simulation must make the CLI nonzero.
    if os.environ.get('PBE_LINE_INJECT_FAILURE') == '1':
        raise AssertionError('intentional failure-propagation check')
    rng = random.Random(0x504245)
    model = LineModel()
    cycle = 0
    names = ('drive', 'a_out', 'b_out', 'tx_ready', 'rx_valid', 'rx_data', 'frame_end', 'err')

    async def edge(**inputs):
        nonlocal cycle
        dut.clk.value = 0
        for name, value in inputs.items():
            getattr(dut, name).value = int(value)
        await Timer(10416, unit='ps')  # even full period: 20,832 ps
        model.step(**inputs)
        dut.clk.value = 1
        await Timer(10416, unit='ps')
        actual = {name: int(getattr(dut, name).value) for name in names}
        expected = {name: int(getattr(model, name)) for name in names}
        assert actual == expected, f'line cycle={cycle} inputs={inputs} expected={expected} actual={actual} model={vars(model)}'
        cycle += 1

    dut.clk.value = 0
    dut.rst_n.value = 0
    base = dict(clear=True, cfg=0, sync=0, period_m1=0, out_msb_first=False,
                in_msb_first=False, a_in=1, b_in=0, tx_put=False, tx_end=False,
                tx_data=0, rx_take=False)
    for key, value in base.items():
        getattr(dut, key).value = int(value)
    await Timer(20832, unit='ps')
    dut.rst_n.value = 1
    for mode in (1, 2):
        for style in range(4):
            for pair in (False, True):
                for byte_mode in (False, True):
                    for divider in (0, 1, 3, 7, 19):
                        settings = dict(base, cfg=mode | style << 2 | int(pair) << 4 | int(byte_mode) << 5,
                                        sync=rng.choice((0, 0, 0x80, 0x55)), period_m1=divider,
                                        out_msb_first=bool(rng.getrandbits(1)),
                                        in_msb_first=bool(rng.getrandbits(1)))
                        await edge(**settings)
                        settings['clear'] = False
                        a, b = 1, 0
                        for tick in range(500):
                            if rng.random() < 0.08:
                                a = 1 - a
                                b = 1 - a if not pair or rng.random() < 0.95 else a
                            ready = model.tx_ready
                            put = ready and rng.random() < .12
                            end = ready and not put and rng.random() < .04
                            await edge(**dict(settings, a_in=a, b_in=b,
                                              tx_put=put, tx_end=end, tx_data=rng.randrange(256),
                                              rx_take=rng.random() < .15))
    dut._log.info('Line model matched %d clocks, seed=0x504245', cycle)
