"""Independent protocol endpoints attached only to top-level chip pins.

All configuration, program loads, FIFO traffic and observations use the host
SPI pins. The fixture exposes scalar aliases because endpoint libraries need
single-bit simulator handles, not slices of uio_in.
"""
import importlib.util
import os
import random
from collections import deque
from pathlib import Path
from types import SimpleNamespace

import cocotb
import cocotb.clock
from cocotb.clock import Clock
from cocotb.triggers import FallingEdge, RisingEdge, Timer, with_timeout
from cocotbext.uart import UartSource, UartSink
# cocotbext-spi 0.5.0 uses BaseClock only to retain a signal handle; cocotb 2
# removed that old base class. Restore exactly that constructor contract locally.
if not hasattr(cocotb.clock, 'BaseClock') and os.getenv('PBE_STOCK_SPI') != '1':
    class _LegacyBaseClock:
        def __init__(self, signal):
            self.signal = signal
    cocotb.clock.BaseClock = _LegacyBaseClock
from cocotbext.spi import SpiMaster, SpiSlaveBase, SpiConfig
from cocotbext.spi import spi as spi_library
from cocotb.types import Logic
# Icarus exposes even [0:0] as scalar Logic; the old SPI model uses .integer.
if not hasattr(Logic, 'integer'):
    Logic.integer = property(lambda self: int(self))
_OriginalSpiClock = spi_library._SpiClock
class _PicosecondSpiClock(_OriginalSpiClock):
    def __init__(self, signal, period, units='step', start_high=True):
        if units == 'sec':
            # Avoid binary floating-point representation errors under cocotb 2.
            super().__init__(signal, 2*round(period*1e12/2), 'ps', start_high)
        else:
            super().__init__(signal, period, units, start_high)
spi_library._SpiClock = _PicosecondSpiClock
from cocotbext.i2c import I2cMaster, I2cMemory

ROOT = Path(os.environ['PBE_ROOT'])
spec = importlib.util.spec_from_file_location('pbe_asm', ROOT/'pbe_v1/tools/pbe_asm.py')
asm = importlib.util.module_from_spec(spec)
spec.loader.exec_module(asm)
# 48 MHz rounded to the closest even number of picoseconds: 32 ppm error.
PERIOD_PS = 20834
HZ = 1e12/PERIOD_PS
CASES = int(os.getenv('PBE_BUS_CASES', '3'))
SEED = int(os.getenv('PBE_BUS_SEED', '20261029'))

class Chip:
    def __init__(self, d):
        self.d = d
        self.ui = 2

    async def cycles(self, n):
        # Advance on falling edges so host pin writes precede sampling edges.
        for _ in range(n):
            await FallingEdge(self.d.clk)

    async def init(self):
        self.d.rst_n.value = 0
        self.d.ui_in.value = 2
        self.d.stretch_release.value = 1
        for i in range(4):
            getattr(self.d, f'ext{i}').value = 1
        cocotb.start_soon(Clock(self.d.clk, PERIOD_PS, unit='ps').start())
        await self.cycles(8)
        self.d.rst_n.value = 1
        await self.cycles(8)

    async def cs(self, val):
        await self.cycles(5)
        self.ui = (self.ui & ~2) | (val << 1)
        self.d.ui_in.value = self.ui
        await self.cycles(5)

    async def byte(self, value):
        rx = 0
        for bit in range(7, -1, -1):
            self.ui = (self.ui & ~4) | (((value >> bit) & 1) << 2)
            self.d.ui_in.value = self.ui
            await self.cycles(5)
            self.ui |= 1
            self.d.ui_in.value = self.ui
            rx = (rx << 1) | (int(self.d.uo_out.value) & 1)
            await self.cycles(5)
            self.ui &= ~1
            self.d.ui_in.value = self.ui
        return rx

    async def write(self, address, *data):
        await self.cs(0)
        await self.byte(0x80 | address)
        for value in data:
            await self.byte(value)
        await self.cs(1)

    async def read(self, address):
        await self.cs(0)
        await self.byte(address)
        value = await self.byte(0)
        await self.cs(1)
        return value

    async def load(self, *programs):
        await self.write(0, 0xc0)
        words = [0]*128
        for name, base in programs:
            program, _ = asm.assemble((ROOT/'pbe_v1/programs'/f'{name}.pbe').read_text(), base, name)
            words[base:base+len(program)] = program
        await self.write(6, 0)
        await self.write(7, *[b for word in words for b in (word >> 8, word & 255)])

    async def config(self, e=0, div=0, base=0, shift=3, start=0, jump=0):
        p = 0x10+16*e
        for offset, value in ((0, div & 255), (1, div >> 8), (2, base),
                              (3, jump), (4, shift), (5, start)):
            await self.write(p+offset, value)

    async def recv(self, count=1, e=0):
        result = []
        for _ in range(count):
            for attempt in range(1000):
                if await self.read(0x0a+e):
                    break
            else:
                raise AssertionError(f'RX timeout engine={e}, received={result}')
            result.append(await self.read(0x16+16*e))
        return result

def rng_for(name):
    return random.Random(f'{SEED}/{name}')

class StretchAwareMaster(I2cMaster):
    """Correct upstream 0.1.2 sampling before SCL rises under stretching.

    All framing, byte assembly, driving and timing remain the third-party
    implementation; only receive sampling moves to the actual high phase.
    Set PBE_STOCK_I2C=1 to run the uncorrected endpoint as a failing regression.
    """
    async def recv_bit(self):
        if not self.bus_active:
            await self.send_start()
        self._set_sda(1)
        await self._half_bit_t
        self._set_scl(1)
        while not int(self.scl.value):
            await RisingEdge(self.scl)
        b = bool(int(self.sda.value))
        await self._bit_t
        self._set_scl(0)
        await self._half_bit_t
        return b

@cocotb.test()
async def uart_tx(d):
    c = Chip(d)
    await c.init()
    r = rng_for('uart_tx')
    for case in range(CASES):
        await c.load(('uart_tx', 0))
        bit_clocks = r.choice((96, 192, 384))
        error = (-.01, 0, .01)[case % 3]
        sink = UartSink(d.sda, baud=HZ/bit_clocks*(1+error), bits=8)
        await c.config(div=bit_clocks//2-1, shift=0)
        await c.write(0, 0x11)
        data = bytes(r.randrange(256) for _ in range(6))
        for byte in data:
            await c.write(0x16, byte)
            await c.cycles(r.randrange(0, bit_clocks*3))
        await Timer((len(data)+1)*12*bit_clocks*PERIOD_PS, unit='ps')
        got = bytes(await with_timeout(sink.read(len(data)), 10, 'ms'))
        assert got == data, (case, bit_clocks, error, data.hex(), got.hex())
        d._log.info('UART TX case=%d bit_clocks=%d error=%+.2f%% data=%s',
                    case, bit_clocks, error*100, data.hex())
        sink._run_cr.cancel()

@cocotb.test()
async def uart_rx(d):
    c = Chip(d)
    await c.init()
    r = rng_for('uart_rx')
    for case in range(CASES):
        await c.load(('uart_rx', 0))
        bit_clocks = r.choice((96, 192, 384))
        error = (-.01, 0, .01)[case % 3]
        source = UartSource(d.ext0, baud=HZ/bit_clocks*(1+error), bits=8)
        await c.config(div=bit_clocks//4-1, shift=0)
        await c.write(0, 0x11)
        data = bytes(r.randrange(256) for _ in range(6))
        for byte in data:
            await source.write(bytes([byte]))
            await source.wait()
            await c.cycles(r.randrange(0, bit_clocks*3))
        got = bytes(await c.recv(len(data)))
        assert got == data, (case, bit_clocks, error, data.hex(), got.hex())
        d._log.info('UART RX case=%d bit_clocks=%d error=%+.2f%% data=%s',
                    case, bit_clocks, error*100, data.hex())
        source._run_cr.cancel()

class BytePeripheral(SpiSlaveBase):
    """Application layer only; wire shifting is cocotbext-spi's implementation."""
    _config = SpiConfig()

    def __init__(self, bus, replies):
        self.replies = deque(replies)
        self.received = []
        super().__init__(bus)

    async def _transaction(self, frame_start, frame_end):
        await frame_start
        while self.replies:
            reply = self.replies.popleft()
            self._miso.value = reply >> 7
            # _shift presents tx_word[7] after edge 2; bit 7 was preloaded above.
            self.received.append(await self._shift(8, (reply << 1) & 255))
        await frame_end

@cocotb.test()
async def spi_controller(d):
    c = Chip(d)
    await c.init()
    r = rng_for('spi_controller')
    for case in range(CASES):
        await c.load(('spi_ctrl', 0))
        data = bytes(r.randrange(256) for _ in range(5))
        replies = bytes(r.randrange(256) for _ in data)
        peripheral = BytePeripheral(SimpleNamespace(sclk=d.sclk, mosi=d.mosi,
                                       miso=d.ext2, cs=d.cs), replies)
        await c.config(div=r.choice((7, 13, 31)))
        await c.write(0x16, *data)
        await c.write(0, 0x11)
        got = bytes(await c.recv(len(data)))
        assert got == replies, (case, got.hex(), replies.hex())
        assert bytes(peripheral.received) == data
        d._log.info('SPI controller mode=0 case=%d data=%s replies=%s', case, data.hex(), replies.hex())
        peripheral._run_coroutine_obj.cancel()

@cocotb.test()
async def spi_peripheral(d):
    c = Chip(d)
    await c.init()
    r = rng_for('spi_peripheral')
    for case in range(CASES):
        await c.load(('spi_periph', 0))
        await c.config(jump=3)
        await c.write(0x1c, 240)
        await c.write(0x1e, 1)
        requested_freq = r.choice((500e3, 1e6, 2e6))*(1+(-.01, 0, .01)[case % 3])
        # Both full and half periods must be exactly representable by cocotb 2.
        half_ps = round(1e12/requested_freq/2)
        freq = 1e12/(2*half_ps)
        master = SpiMaster(SimpleNamespace(sclk=d.ext0, mosi=d.ext1,
                               miso=d.miso, cs=d.ext3), SpiConfig(sclk_freq=freq,
                               frame_spacing_ns=r.randrange(6000, 20001)))
        await c.write(0, 0x11)
        for transaction in range(2):
            data = bytes(r.randrange(256) for _ in range(4))
            replies = bytes(r.randrange(256) for _ in range(3)) + b'\xff'
            await c.write(0x16, *replies[:-1])
            await master.write(data, burst=True)
            got = bytes(master.read_nowait())
            assert got == replies, (case, freq, got.hex(), replies.hex())
            assert bytes(await c.recv(len(data))) == data
            await c.cycles(r.randrange(600, 900))
        d._log.info('SPI peripheral mode=0 case=%d SCLK=%f', case, freq)
        master._run_coroutine_obj.cancel()
        master._SpiClock._run_cr.cancel()

@cocotb.test()
async def i2c_controller(d):
    c = Chip(d)
    await c.init()
    r = rng_for('i2c_controller')
    mem = I2cMemory(d.sda, d.ext0, d.scl, d.ext1, addr=0x50, size=256)
    stretches = 0
    async def stretch():
        nonlocal stretches
        while True:
            # Begin only after a controller falling edge, so no artificial
            # shortened high phase is injected into the independent endpoint.
            await FallingEdge(d.scl)
            if r.randrange(3) == 0:
                d.stretch_release.value = 0
                stretches += 1
                await Timer(r.randrange(5000, 20000), unit='ns')
                d.stretch_release.value = 1
    cocotb.start_soon(stretch())
    for case in range(CASES):
        await c.load(('i2c_ctrl', 0))
        await c.config(div=r.choice((17, 35, 68)))
        await c.write(0, 0x11)
        data = bytes(r.randrange(256) for _ in range(4))
        pointer = r.randrange(0, 240)
        async def xfer(value, ack=0x80):
            await c.write(0x16, value, ack)
            return await c.recv(2)
        async def stop():
            await c.write(8, 2)
            for _ in range(100):
                if not await c.read(4) & 2:
                    return
            raise AssertionError('STOP did not finish')
        await c.write(8, 1)
        for value in bytes([0xa0, pointer])+data:
            seen, ack = await xfer(value)
            assert seen == value and ack == 0, (case, value, seen, ack)
            await c.cycles(r.randrange(0, 100))
        await stop()
        assert mem.read_mem(pointer, len(data)) == data
        await c.write(8, 1)
        assert (await xfer(0xa0))[1] == 0
        assert (await xfer(pointer))[1] == 0
        await c.write(8, 1)  # repeated START
        assert (await xfer(0xa1))[1] == 0
        got = []
        for i in range(len(data)):
            value, ack = await xfer(255, 0x80 if i == len(data)-1 else 0)
            got.append(value)
            assert ack == (i == len(data)-1)
        await stop()
        assert bytes(got) == data, (case, bytes(got).hex(), data.hex())
        assert stretches > 0
        d._log.info('I2C controller case=%d data=%s low-phase stretches=%d', case, data.hex(), stretches)

@cocotb.test()
async def i2c_target(d):
    c = Chip(d)
    await c.init()
    r = rng_for('i2c_target')
    for case in range(CASES):
        await c.load(('i2c_target', 0), ('i2c_watch', 64))
        await c.config()
        await c.config(e=1, start=64, jump=1)
        await c.write(0x28, 0)  # both engines share physical flags 0..3
        await c.write(4, 0)
        await c.write(0, 0x33)
        replies = deque(r.randrange(256) for _ in range(4))
        expected = bytes(replies)
        received = []
        addresses = []
        async def service():
            while True:
                drained = []
                for _ in range(await c.read(0x0a)):
                    drained.append(await c.read(0x16))
                flags = await c.read(4)
                if flags & 4:
                    # Address PUSH/FLAG2 can occur between the count snapshot and
                    # FLAGS read. Recheck before classifying an empty read request.
                    for _ in range(await c.read(0x0a)):
                        drained.append(await c.read(0x16))
                    if drained:
                        received.extend(drained[:-1])
                        addresses.append(drained[-1])
                    else:
                        assert replies, 'unexpected target read request'
                        await c.write(0x16, replies.popleft())
                    await c.cycles(r.randrange(0, 500))  # host-response latency stretches SCL
                    await c.write(9, 4)
                else:
                    received.extend(drained)
        worker = cocotb.start_soon(service())
        speed = r.choice((100e3, 200e3, 400e3))*(1+(-.01, 0, .01)[case % 3])
        endpoint = I2cMaster if os.getenv('PBE_STOCK_I2C') == '1' else StretchAwareMaster
        master = endpoint(d.sda, d.ext0, d.scl, d.ext1, speed=speed)
        data = bytes(r.randrange(256) for _ in range(5))
        await with_timeout(master.write(0x50, data), 100, 'ms')
        await master.send_stop()
        await Timer(100, unit='us')
        assert bytes(received) == data, (case, data.hex(), bytes(received).hex())
        got = bytes(await with_timeout(master.read(0x50, len(expected)), 100, 'ms'))
        await master.send_stop()
        assert got == expected, (case, got.hex(), expected.hex())
        assert addresses == [0xa0, 0xa1], addresses
        d._log.info('I2C target case=%d speed=%f write=%s read=%s', case, speed, data.hex(), got.hex())
        worker.cancel()
