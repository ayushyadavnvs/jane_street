# SPDX-FileCopyrightText: © 2026 Ayush Yadav
# SPDX-License-Identifier: Apache-2.0
#
# Tiny Tapeout test of the Programmable Bit Engine, used both on the RTL and, by the gl_test
# workflow, on the gate-level netlist after place and route. It goes through the chip's pins
# only, like the full suite in pbe_v1/test (which runs on the RTL):
#   1. the host SPI port: write a register and read it back
#   2. load the UART programs into program memory, loop protocol pin 0 back to pin 1, and send
#      bytes from engine 0 (UART TX) to engine 1 (UART RX)

from pathlib import Path

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles, FallingEdge

CLK_PS = 20834     # 48 MHz (cocotb needs an even period)
HOST_HALF = 8      # host SCK half period in clocks (SCK = clk / 16)
UART_BIT = 100     # clocks per UART bit
IMAGE = Path(__file__).resolve().parent.parent / "pbe_v1" / "test" / "uart_image.hex"


class Host:
    """The host side of the chip's SPI register port (mode 0): ui_in[0] SCK, [1] CS_n, [2] MOSI,
    uo_out[0] MISO. Command byte [7] = write, [6:0] = address; then data bytes."""

    def __init__(self, dut):
        self.dut = dut
        self.ui = 0b010  # CS_n high
        dut.ui_in.value = self.ui

    def _set(self, bit, v):
        self.ui = (self.ui | (1 << bit)) if v else (self.ui & ~(1 << bit))
        self.dut.ui_in.value = self.ui

    async def byte(self, tx):
        rx = 0
        for i in range(7, -1, -1):
            self._set(2, (tx >> i) & 1)
            await ClockCycles(self.dut.clk, HOST_HALF)
            self._set(0, 1)  # rising edge: both sides sample
            rx = (rx << 1) | (int(self.dut.uo_out.value) & 1)
            await ClockCycles(self.dut.clk, HOST_HALF)
            self._set(0, 0)
        return rx

    async def cs(self, level):
        await ClockCycles(self.dut.clk, HOST_HALF)
        self._set(1, level)
        await ClockCycles(self.dut.clk, HOST_HALF)

    async def write(self, addr, data):
        await self.cs(0)
        await self.byte(0x80 | addr)
        await self.byte(data)
        await self.cs(1)

    async def read(self, addr):
        await self.cs(0)
        await self.byte(addr)
        d = await self.byte(0)
        await self.cs(1)
        return d

    async def load_program(self, words):
        await self.write(0x06, 0)        # program memory byte pointer = 0
        await self.cs(0)
        await self.byte(0x80 | 0x07)     # burst into PM_DATA
        for w in words:
            await self.byte(w >> 8)
            await self.byte(w & 0xFF)
        await self.cs(1)


async def bus(dut, loop01):
    """Protocol pins: pulled up when not driven; optionally pin 0 looped back to pin 1."""
    while True:
        await FallingEdge(dut.clk)
        try:
            out, oe = int(dut.uio_out.value), int(dut.uio_oe.value)
        except ValueError:  # unknown values before reset on the gate-level netlist
            out, oe = 0, 0
        lvl = (out & oe) | (~oe & 0xFF)
        if loop01["on"]:
            lvl = (lvl & ~0x02) | ((lvl & 0x01) << 1)
        dut.uio_in.value = lvl


async def start(dut):
    cocotb.start_soon(Clock(dut.clk, CLK_PS, unit="ps").start())
    dut.ena.value = 1
    dut.uio_in.value = 0xFF
    host = Host(dut)
    dut.rst_n.value = 0
    await ClockCycles(dut.clk, 10)
    dut.rst_n.value = 1
    await ClockCycles(dut.clk, 10)
    return host


@cocotb.test()
async def test_registers(dut):
    host = await start(dut)
    for v in (0xA5, 0x5A, 0x00, 0xFF):
        await host.write(0x10, v)           # engine 0 CLKDIV_L
        got = await host.read(0x10)
        assert got == v, f"CLKDIV_L read back {got:02x}, wrote {v:02x}"
    assert await host.read(0x0A) == 0, "RX_COUNT of engine 0 should be 0 after reset"


@cocotb.test()
async def test_uart_loopback(dut):
    host = await start(dut)
    loop01 = {"on": False}
    cocotb.start_soon(bus(dut, loop01))
    words = [int(x, 16) for x in IMAGE.read_text().split()]
    await host.load_program(words)       # uart_tx at word 0, uart_rx at word 8
    await host.write(0x10, UART_BIT // 2 - 1)  # E0 tick = 1/2 bit
    await host.write(0x11, 0)
    await host.write(0x12, 0)            # E0 pins start at 0
    await host.write(0x14, 0)            # LSB first
    await host.write(0x15, 0)
    await host.write(0x20, UART_BIT // 4 - 1)  # E1 tick = 1/4 bit
    await host.write(0x21, 0)
    await host.write(0x22, 1)            # E1 pins start at 1
    await host.write(0x23, 0)            # JMP pin = rx
    await host.write(0x24, 0)
    await host.write(0x25, 8)            # uart_rx starts at word 8
    await host.write(0x03, 0b0000_0010)  # pin 1 belongs to E1
    loop01["on"] = True
    await host.write(0x00, 0b0011_0011)  # restart + run both engines

    sent = [0x55, 0xA3, 0x00, 0xFF, 0x0F, 0x80]
    for b in sent:
        await host.write(0x16, b)        # engine 0 TX FIFO (16 deep: all fit)
    got = []
    for _ in range(4000):
        if len(got) == len(sent):
            break
        if await host.read(0x0B):        # RX_COUNT of engine 1
            got.append(await host.read(0x26))
    assert got == sent, f"UART loopback received {[hex(x) for x in got]}, sent {[hex(x) for x in sent]}"
