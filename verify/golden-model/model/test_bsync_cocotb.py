"""Seeded random differential of pbe_bsync (CAN mode) against can_model.py (D66-D68).

The DUT is the bit-synchronous coder alone on a wired-AND bus with a transceiver loop delay.
Three kinds of trials, each with a random bit time (48 or 96 clocks), sample point (75 or
87.5 %), clock error of the other node (+-0.8 %), frame (ID, RTR, DLC 0-15, data) and a random
sequence of unit widths (1-8, set by LINECTL as a program would):
  receive  - a model transmitter sends the frame; the units IN would take, the CRC feed and
             the ACK the coder drives must match the model;
  transmit - the coder sends the frame unit by unit (OUT after each IN, like can_node); a model
             receiver samples the bus, removes stuff bits and must read the same frame, and
             the readback units, the `sent` pulse and the absence of errors are checked;
  error    - the model transmitter breaks the stuffing rule at a random stuff bit; the coder
             must report the error and drive a 6-bit active error flag from the next bit.
"""
import os
import random

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import FallingEdge

import can_model as cm

LD = 4   # loop delay, clocks


class Bus:
    def __init__(self, dut):
        self.dut, self.ext, self.line, self.clk = dut, 1, [1] * LD, 0
        self.drive_log = []

    async def run(self):
        while True:
            await FallingEdge(self.dut.clk)
            self.clk += 1
            v = self.dut.drive.value
            drive = int(v) if v.is_resolvable else 0
            self.drive_log.append(drive)
            self.line.append(1 if (self.ext and not drive) else 0)
            self.dut.a_in.value = self.line.pop(0)


async def edges(dut, n):
    for _ in range(n):
        await FallingEdge(dut.clk)


async def reset(dut, period, sp):
    dut.clear.value = 1
    for name in ('tx_put', 'rx_take', 'ctl', 'drop', 'crc_ok'):
        getattr(dut, name).value = 0
    dut.cfg.value = 0x0D            # NRZ, stuffing 5 equal, frames start with 1-bit units
    dut.cfg2.value = 0x20 | sp      # CAN mode, no idle wait
    dut.period_m1.value = period - 1
    dut.tx_data.value = 0
    dut.ctl_param.value = 0
    dut.out_msb_first.value = 1     # CAN is MSB first
    dut.in_msb_first.value = 1
    await edges(dut, 3)
    dut.clear.value = 0
    await edges(dut, 12 * period)   # integration: 11 recessive bits


def random_frame(rng):
    fid = rng.randrange(0x7F0)      # the 7 MSBs of an ID must not all be recessive
    rtr = int(rng.random() < 0.15)
    dlc = rng.randrange(16)
    data = [rng.randrange(256) for _ in range(8)]
    return fid, rtr, dlc, data


def random_widths(rng, n):
    widths, total = [1], 1           # the SOF unit (frames start with 1-bit units)
    while total < n:
        w = min(rng.randrange(1, 9), n - total)
        widths.append(w)
        total += w
    return widths


async def program_rx(dut, widths, stuffed_len, got, crc_feed, state):
    """The receiving program: take each unit, set the next width, end the stuffed region."""
    k = 0
    while True:
        await FallingEdge(dut.clk)
        dut.rx_take.value = 0
        dut.ctl.value = 0
        if int(dut.crc_step.value):
            crc_feed.append(int(dut.crc_bit.value))
        if int(dut.rx_valid.value) and k < len(widths):
            v = dut.rx_data.value
            assert v.is_resolvable, f'unit {k}: rx_data {v} (rx_valid set)'
            got.append(int(v))
            dut.rx_take.value = 1
            k += 1
            if k < len(widths):
                dut.ctl_param.value = (widths[k] - 1) | (8 if sum(widths[:k]) < 13 else 0)
            else:
                dut.ctl_param.value = 0b10001   # stuffing off: the coder runs the tail
                dut.crc_ok.value = 1
            dut.ctl.value = 1
        if int(dut.frame_end.value):
            state['frame_end'] += 1
        if int(dut.err.value):
            state['err'] += 1
        if int(dut.arb_lost.value):
            state['arb'] += 1
        if int(dut.sent.value):
            state['sent'] += 1


async def transmit_line(dut, bus, levels, period, ppm, ack_from=None):
    """Drive `levels` as the other node, one bit every period*(1+ppm) clocks (fractional)."""
    t, starts = 0.0, []
    for i, level in enumerate(levels):
        bus.ext = level
        starts.append(bus.clk)
        t += period * (1 + ppm)
        n = int(round(t)) - (bus.clk - starts[0])
        await edges(dut, max(n, 1))
    bus.ext = 1
    return starts


@cocotb.test()
async def bsync_random(dut):
    seed = int(os.environ.get('PBE_CAN_SEED', '0x43414E'), 0)
    trials = int(os.environ.get('PBE_CAN_TRIALS', '8'))
    rng = random.Random(seed)
    cocotb.start_soon(Clock(dut.clk, 20832, unit='ps').start())
    dut.rst_n.value = 0
    dut.a_in.value = 1
    bus = Bus(dut)
    cocotb.start_soon(bus.run())
    await edges(dut, 3)
    dut.rst_n.value = 1
    counts = dict(receive=0, transmit=0, error=0)
    for trial in range(3 * trials):
        kind = ('receive', 'transmit', 'error')[trial % 3]
        period = rng.choice((48, 96))
        sp = rng.choice((2, 3))
        ppm = rng.uniform(-0.008, 0.008)
        fid, rtr, dlc, data = random_frame(rng)
        bits = cm.frame_bits(fid, rtr, dlc, data)
        line, index = cm.stuff(bits)
        widths = random_widths(rng, len(bits))
        what = f'trial {trial} {kind} P={period} sp={sp} ppm={ppm*1e6:.0f} id={fid:03x} rtr={rtr} dlc={dlc}'
        await reset(dut, period, sp)
        state = dict(frame_end=0, err=0, arb=0, sent=0)
        got, crc_feed = [], []
        prog = cocotb.start_soon(program_rx(dut, widths, len(line), got, crc_feed, state))
        if kind == 'receive':
            mark = len(bus.drive_log)
            starts = await transmit_line(dut, bus, line + [1] * (cm.TAIL + 3), period, ppm)
            await edges(dut, 4 * period)
            ack = starts[len(line) + 1]
            mid = ack + period // 2 + LD
            assert bus.drive_log[mid - 1] == 1 or bus.drive_log[mid] == 1, f'{what}: no ACK driven'
            assert sum(bus.drive_log[mark:]) <= period + 4, f'{what}: drove outside the ACK slot'
            assert got == cm.units(bits, widths), f'{what}: units {got} != model {cm.units(bits, widths)}'
            assert crc_feed == bits, f'{what}: CRC fed {len(crc_feed)} bits, not the frame'
            assert state['err'] == 0 and state['frame_end'] == 1, f'{what}: {state}'
        elif kind == 'transmit':
            # the program queues unit k after taking unit k-1 (OUT after IN); the model reads the bus
            values = cm.units(bits, widths)
            k_sent = 0

            async def put_units():
                nonlocal k_sent
                while k_sent < len(widths):
                    await FallingEdge(dut.clk)
                    dut.tx_put.value = 0
                    if int(dut.tx_ready.value) and k_sent <= len(got):
                        w = widths[k_sent]
                        dut.tx_data.value = (values[k_sent] << (8 - w)) & 255
                        dut.tx_put.value = 1
                        k_sent += 1
                await FallingEdge(dut.clk)
                dut.tx_put.value = 0
            putter = cocotb.start_soon(put_units())
            # wait for the start of frame on the bus, then sample like a receiver
            while bus.line[-1] == 1:
                await FallingEdge(dut.clk)
            sampled = []
            await edges(dut, period // 2 + LD)
            for _ in range(len(line)):
                sampled.append(bus.line[-1])
                if len(sampled) == len(line):
                    break
                await edges(dut, period)
            # the ACK slot after the CRC delimiter
            await edges(dut, 2 * period - period // 2 - LD)
            bus.ext = 0
            await edges(dut, period)
            bus.ext = 1
            await edges(dut, 12 * period)
            putter.cancel()
            assert sampled == line, f'{what}: bus levels differ from the model\'s stuffed frame'
            assert cm.destuff(sampled) == bits, f'{what}: destuffed bus differs'
            assert got == values, f'{what}: readback units differ'
            assert state['sent'] == 1 and state['err'] == 0 and state['arb'] == 0, f'{what}: {state}'
        else:
            stuffs = [i for i, x in enumerate(index) if x is None]
            if not stuffs:
                prog.cancel()
                continue
            j = rng.choice(stuffs)
            bad = list(line[:j + 1])
            bad[j] = 1 - bad[j]          # the stuff bit equals the 5 before it: a stuff error
            levels = bad + [1] * 20
            mark = len(bus.drive_log)
            starts = await transmit_line(dut, bus, levels, period, ppm)
            await edges(dut, 2 * period)
            log = bus.drive_log[mark:]
            first = next((i for i, d in enumerate(log) if d), None)
            assert state['err'] >= 1, f'{what}: no error reported'
            assert first is not None, f'{what}: no error flag'
            flag_start = first + mark
            nxt = starts[j + 1]
            # the coder's bit grid may drift from the transmitter's by the clock error over the
            # up to 6 bits since the last edge it resynchronized on
            drift = int(6 * period * abs(ppm)) + 2
            assert nxt + LD - drift <= flag_start <= nxt + LD + drift + period // 4, \
                f'{what}: flag at {flag_start}, bit after the error starts at {nxt} (+{LD})'
            length = 0
            while first + length < len(log) and log[first + length]:
                length += 1
            assert abs(length - 6 * period) <= 2 * LD + 4, f'{what}: flag {length} clocks, not 6 bits'
        prog.cancel()
        counts[kind] += 1
    dut._log.info(f'BSYNC_DIFFERENTIAL seed={seed:#x} {counts}')
