"""Executable ISA and documented cycle-contract reference for the PBE.

The public interface separates pre-edge effects from edge updates.  A top-level
model must compute effects for *both* engines before changing shared flags/FIFOs.
Architectural rules come from the instruction comments, CRC comments and D50;
the fetch address is the next word while ``iv`` is true.  All integer arithmetic
is explicitly bounded, so Python's unlimited integers do not hide wraparound.

This model does not invoke an HDL simulator or import live RTL state. That is
not sufficient to prove historical independence: the round-2 audit inventories
implementation-informed priorities/timing and the header clarifications that
now document them (verify/golden-model/ROUND2_MODEL_AUDIT.md). Treat shared corner-case
rules as observational conformance, not independent proof of architecture.
``snapshot`` is diagnostic only, not the differential oracle.
"""

from collections import Counter
from collections import deque


def reverse_bits(value, width):
    return int(f"{value & ((1 << width) - 1):0{width}b}"[::-1], 2)


class EngineModel:
    DEFAULT_CONFIG = dict(run=False, clkdiv=0, pin_base=0, jmp_pin=0,
                          out_msb_first=False, in_msb_first=False, start_pc=0,
                          crc_poly=0, crc_cfg=0, timeout=0, line_cfg=0,
                          coder_cfg=0, sync=0, crc_good=0)

    def __init__(self, config=None, **kwargs):
        self.config = dict(self.DEFAULT_CONFIG)
        if config:
            self.config.update(config)
        self.config.update(kwargs)
        self.coverage = Counter()
        self.reset()

    def configure(self, **kwargs):
        self.config.update(kwargs)

    def reset(self):
        self.pc = self.instr_q = 0
        self.iv = False
        self.div_cnt = self.dly_cnt = 0
        self.blocked = False
        self.x = self.osr = self.isr = 0
        self.pout = self.poe = 0
        self.pins_prev = self.flags_prev = 0
        self.par_out = self.par_in = 0
        self.tmo_seen = self.rx_ovf = False
        self.tmo_cnt = 0
        self.line_ev = self.line_err = False
        self.cf_cnt = self.cf_sh = 0
        self.crc = 0
        self.line = LineModel()
        self.cycles = 0

    @property
    def coder_on(self):
        return bool(self.config['coder_cfg'] & 3)

    @property
    def crc_now(self):
        width = (self.config['crc_cfg'] & 15) + 1
        return reverse_bits(self.crc, width) if self.config['crc_cfg'] & 32 else self.crc

    @property
    def crc_ok(self):
        return self.crc == self.config['crc_good']

    @property
    def par_err(self):
        cfg = self.config['line_cfg']
        return False if cfg & 64 else bool(self.par_in ^ (cfg >> 7 & 1))

    @property
    def status(self):
        return (int(self.line_err) << 4 | int(self.rx_ovf) << 3 |
                int(self.tmo_seen) << 2 | int(self.crc_ok) << 1 | int(self.par_err))

    @property
    def pins_out(self):
        mask, value = self._line_pins()
        return (self.pout & ~mask | value & mask) & 255

    @property
    def pins_oe(self):
        return (self.poe | self._line_pins()[0]) & 255

    def _line_pins(self):
        base = self.config['pin_base'] & 7
        other = (base + 1) & 7
        if not self.line.drive:
            return 0, 0
        mask = 1 << base
        if self.config['coder_cfg'] & 16:
            mask |= 1 << other
        return mask, self.line.a_out << base | self.line.b_out << other

    def _context(self, **inputs):
        c = self.config
        p = dict(pins_in=0, flags=0, tx_data=0, tx_empty=True, rx_full=False,
                 run=c['run'], restart=False, pm_wr=False, host_crc_init=False,
                 host_tmo_clr=False, host_ovf_clr=False, host_lerr_clr=False)
        p.update(inputs)
        if p['run'] is None:
            p['run'] = c['run']
        unknown_instruction = self.instr_q is None
        # Unwritten program RAM is unspecified and may be fetched while the
        # engine is stopped. A decode placeholder is safe only while no
        # instruction executes; it must never turn unknown memory into a NOP.
        word = 0xd800 if unknown_instruction else self.instr_q
        op, arg, delay = word >> 13, word >> 4 & 511, word & 15
        sub = arg >> 6
        pin = (c['pin_base'] + sub) & 7
        bit = p['pins_in'] >> pin & 1
        was = self.pins_prev >> pin & 1
        act = arg >> 3 & 7
        txop = self.coder_on and op == 0 and act in (4, 5, 7)
        now_wait, was_wait = bit, was
        if arg & 32:
            flag = arg >> 6 & 3
            now_wait = p['flags'] >> flag & 1
            was_wait = self.flags_prev >> flag & 1
        cond = arg >> 3 & 3
        wait_ok = (not now_wait, bool(now_wait), not was_wait and now_wait,
                   was_wait and not now_wait)[cond]
        ready = True
        if op == 2:
            ready = wait_ok
        elif op == 5:
            ready = not (p['rx_full'] if arg & 256 else p['tx_empty'])
        elif txop:
            ready = self.line.tx_ready
        elif op == 1 and self.coder_on:
            ready = self.line.rx_valid or self.line_ev
        ready = bool(ready and not self.cf_cnt)
        due = self.coder_on or self.div_cnt >= c['clkdiv']
        tick = due and self.iv
        issue = p['run'] and self.iv and (self.blocked or tick and not self.dly_cnt)
        execute = bool(issue and ready and not p['restart'])
        if unknown_instruction and execute:
            raise ValueError(f'uninitialized program instruction at address {(self.pc - 1) & 127}, '
                             f'cycle {self.cycles}; load program memory before running')
        timeout = bool(p['run'] and not p['restart'] and self.iv and self.blocked
                       and not ready and c['timeout'] and self.tmo_cnt >= c['timeout'])
        overflow = bool(p['run'] and not p['restart'] and issue and op == 5
                        and arg & 256 and p['rx_full'])
        jp = p['pins_in'] >> ((c['pin_base'] + c['jmp_pin']) & 7) & 1
        jump = False
        if op == 3:
            jump = (True, self.x != 0, bool(jp), not jp, p['tx_empty'],
                    not p['tx_empty'], bool(p['flags'] & 1), bool(p['flags'] & 2))[sub]
        elif op == 7:
            jump = {3: not self.crc_ok or self.line_err, 4: self.isr == self.osr,
                    5: self.isr != self.osr, 6: self.line_ev}.get(sub, False)
        out_bit = self.osr >> 7 if c['out_msb_first'] else self.osr & 1
        in_bit = self.line.rx_data & 1 if self.coder_on else bit
        is_out = execute and op == 0 and act in (4, 5)
        is_in = execute and op == 1 and (not self.coder_on or self.line.rx_valid)
        crc_out = bool(is_out and not arg & 1 and c['crc_cfg'] & 64)
        crc_in = bool(is_in and not arg & 32 and c['crc_cfg'] & 128)
        p.update(op=op, arg=arg, dly=delay, sub=sub, pin=pin, bit=bit, act=act,
                 line_rx_data=self.line.rx_data,
                 txop=txop, ready=ready, due=due, tick=tick, issue=issue,
                 execute=execute, timeout_hit=timeout, overflow=overflow,
                 jump=bool(jump), out_bit=out_bit, in_bit=in_bit,
                 is_out=is_out, is_in=is_in, crc_out=crc_out, crc_in=crc_in,
                 cf_start=self.coder_on and bool(c['coder_cfg'] & 32) and (crc_out or crc_in))
        return p

    def effects(self, **inputs):
        p = self._context(**inputs)
        ex, op, arg = p['execute'], p['op'], p['arg']
        flag_act = arg >> 7
        return dict(tx_pop=bool(ex and op == 5 and not arg & 256),
                    rx_push=bool(ex and op == 5 and arg & 256), rx_data=self.isr,
                    flag_set=(1 << (arg & 3)) if ex and op == 6 and flag_act == 0 else 0,
                    flag_clr=(1 << (arg & 3)) if ex and op == 6 and flag_act == 1 else 0,
                    irq=bool(ex and op == 6 and flag_act == 2 or p['overflow'] and not self.rx_ovf),
                    execute=ex, issue=bool(p['issue']), instruction=self.instr_q,
                    instruction_pc=(self.pc - 1) & 127 if self.iv else self.pc)

    def step(self, program, **inputs):
        """Advance one rising edge, returning the effects consumed on that edge.

        ``program`` may be a sequence of 128 words or a callable read(address).
        Host program writes must be applied by the caller *after* this method,
        since the edge samples the pre-write memory value.
        """
        p = self._context(**inputs)
        effects = self.effects(**inputs)
        c = self.config
        incoming = program(self.pc) if callable(program) else program[self.pc % len(program)]
        old_status, old_crc = self.status, self.crc_now
        old_cf_cnt, old_cf_sh = self.cf_cnt, self.cf_sh
        old_iv, old_blocked = self.iv, self.blocked
        op, arg, sub, act = p['op'], p['arg'], p['sub'], p['act']
        execute, jump = p['execute'], p['jump']

        # CRC is an independently clocked bit-stream accumulator. Initialisation
        # wins over feed; byte transfers enqueue exactly eight subsequent bits.
        crc_init = p['host_crc_init'] or p['restart'] or execute and op == 7 and sub == 0
        width = (c['crc_cfg'] & 15) + 1
        mask = (1 << width) - 1
        if crc_init:
            self.crc = mask if c['crc_cfg'] & 16 else 0
        elif old_cf_cnt or not p['cf_start'] and (p['crc_out'] or p['crc_in']):
            feed = old_cf_sh & 1 if old_cf_cnt else p['out_bit'] if p['is_out'] else p['in_bit']
            feedback = feed ^ (self.crc >> (width - 1) & 1)
            self.crc = ((self.crc << 1) ^ (c['crc_poly'] if feedback else 0)) & mask

        # A line module has its own clock and keeps running while run=0.
        line_end, line_error = self.line.frame_end, self.line.err
        self.line.step(cfg=c['coder_cfg'], sync=c['sync'], period_m1=c['clkdiv'],
                       out_msb_first=c['out_msb_first'], in_msb_first=c['in_msb_first'],
                       a_in=p['pins_in'] >> (c['pin_base'] & 7) & 1,
                       b_in=p['pins_in'] >> ((c['pin_base'] + 1) & 7) & 1,
                       clear=p['restart'] or not self.coder_on,
                       tx_put=execute and p['txop'] and act != 7,
                       tx_end=execute and p['txop'] and act == 7,
                       tx_data=self.osr if c['coder_cfg'] & 32 else p['out_bit'],
                       rx_take=execute and self.coder_on and op == 1 and self.line.rx_valid)

        # D50 fetch: consume a prefetched sequential word, or mark a branch
        # target for a one-clock refill. Writes refetch the next instruction.
        next_pc = self.pc
        if not old_iv:
            next_pc = (self.pc + 1) & 127
        if execute:
            next_pc = (c['start_pc'] + (arg & 63) if jump else self.pc + 1) & 127
        if p['timeout_hit']:
            next_pc = (c['start_pc'] + (c['line_cfg'] & 63)) & 127
        if p['pm_wr'] and not (execute and jump) and not p['timeout_hit']:
            next_pc = (self.pc - 1) & 127 if old_iv and not execute else self.pc
        if p['restart']:
            next_pc = c['start_pc'] & 127
            self.iv = False
            self.div_cnt = self.dly_cnt = self.tmo_cnt = 0
            self.blocked = False
            self.x = self.osr = self.isr = self.poe = 0
            self.line_ev = self.line_err = False
            self.cf_cnt = 0
            self.par_out = self.par_in = 0
            self.tmo_seen = self.rx_ovf = False
        else:
            self.pins_prev, self.flags_prev = p['pins_in'], p['flags']
            if p['host_tmo_clr']:
                self.tmo_seen = False
            if p['host_ovf_clr']:
                self.rx_ovf = False
            elif p['overflow']:
                self.rx_ovf = True
            self.line_ev = bool((self.line_ev and not (execute and op == 7 and sub == 6)) or line_end)
            if p['host_lerr_clr']:
                self.line_err = False
            elif line_error:
                self.line_err = True
            if old_cf_cnt:
                self.cf_cnt -= 1
                self.cf_sh >>= 1
            elif p['cf_start']:
                byte = self.osr if p['crc_out'] else p['line_rx_data']
                msb = c['out_msb_first'] if p['crc_out'] else c['in_msb_first']
                self.cf_sh = reverse_bits(byte, 8) if msb else byte
                self.cf_cnt = 8
            if not old_iv:
                self.instr_q, self.iv = incoming, True
            if p['run']:
                if execute and old_blocked or p['timeout_hit'] or p['tick']:
                    self.div_cnt = 0
                elif not p['due']:
                    self.div_cnt = (self.div_cnt + 1) & 65535
                if p['tick'] and self.dly_cnt and not old_blocked:
                    self.dly_cnt -= 1
                if p['issue'] and not p['ready']:
                    self.blocked = True
                if not old_blocked:
                    self.tmo_cnt = 0
                elif p['tick']:
                    self.tmo_cnt = (self.tmo_cnt + 1) & 65535
                if execute:
                    self.coverage[f'op:{op}'] += 1
                    self.coverage[f'op:{op}/sub:{act if op == 0 else sub if op in (3, 7) else arg >> 7 if op == 6 else int(bool(arg & 256)) if op in (4, 5) else arg >> 3 & 3 if op == 2 else 0}'] += 1
                    self.blocked, self.dly_cnt = False, p['dly']
                    if jump:
                        self.iv = False
                    else:
                        self.instr_q = incoming
                    if op == 0:
                        if p['txop']:
                            if not c['coder_cfg'] & 32 and act != 7:
                                self._shift_out()
                        elif act != 7:
                            mask_pin = 1 << p['pin']
                            if act == 2:
                                self.poe &= ~mask_pin
                            else:
                                value = {0: 0, 1: 1, 3: not bool(self.pout & mask_pin),
                                         4: p['out_bit'], 5: 0,
                                         6: bool(c['line_cfg'] & 64) or self.par_out ^ (c['line_cfg'] >> 7 & 1)}[act]
                                self.pout = (self.pout & ~mask_pin) | (int(value) << p['pin'])
                                self.poe = (self.poe & ~mask_pin) | (int(not p['out_bit'] if act == 5 else True) << p['pin'])
                                if act in (4, 5):
                                    self._shift_out()
                    elif op == 1:
                        if not self.coder_on:
                            self._shift_in(p['bit'])
                        elif p['is_in']:
                            if c['coder_cfg'] & 32:
                                self.isr = p['line_rx_data']
                            else:
                                self._shift_in(p['in_bit'])
                        self.par_in ^= p['in_bit']
                    elif op == 3 and sub == 1 and self.x:
                        self.x = (self.x - 1) & 255
                    elif op == 4:
                        if arg & 256:
                            self.osr, self.par_out = arg & 255, 0
                        else:
                            self.x = arg & 255
                    elif op == 5:
                        if arg & 256:
                            self.isr = 0
                        else:
                            self.osr, self.par_out = p['tx_data'], 0
                    elif op == 6 and arg >> 7 == 3 and arg >> 4 & 3:
                        value = (0, self.x, self.osr, self.isr)[arg >> 2 & 3]
                        dest = arg >> 4 & 3
                        if dest == 1:
                            self.x = value
                        elif dest == 2:
                            self.osr, self.par_out = value, 0
                        else:
                            self.isr = value
                    elif op == 7:
                        if sub == 0 and not line_error:
                            self.line_err = False
                        elif sub == 1:
                            self.osr = ((old_crc >> (8 if arg & 1 else 0)) & 255) ^ (255 if arg & 2 else 0)
                            self.par_out = 0
                        elif sub == 2:
                            self.isr = old_status
                            self.par_in = 0
                            self.tmo_seen = False
                    if p['is_out']:
                        self.par_out ^= p['out_bit']
                if p['timeout_hit']:
                    self.iv = self.blocked = False
                    self.dly_cnt = 0
                    self.tmo_seen = True
            if p['pm_wr']:
                self.iv = False
        self.pc = next_pc
        self.cycles += 1
        return effects

    def _shift_out(self):
        self.osr = (self.osr << 1) & 255 if self.config['out_msb_first'] else self.osr >> 1

    def _shift_in(self, bit):
        self.isr = ((self.isr << 1) | bit) & 255 if self.config['in_msb_first'] else (bit << 7 | self.isr >> 1)

    def snapshot(self):
        return {name: getattr(self, name) for name in
                ('cycles', 'pc', 'instr_q', 'iv', 'div_cnt', 'dly_cnt', 'blocked',
                 'x', 'osr', 'isr', 'pins_out', 'pins_oe', 'status', 'crc_now',
                 'tmo_cnt', 'cf_cnt', 'line_ev', 'line_err')}


class LineModel:
    """A bit-slot/queue model of the optional half-duplex line coder.

    A transmit entry is expanded to a list of wire-order bits, with stuffing
    inserted as slots are emitted. Receive bits accumulate in Python lists and
    are assembled only at the transfer width. This representation deliberately
    differs from the HDL shift-register implementation.

    The clock interface uses registered pulses: an engine samples frame_end and
    err on the following edge. Timer phase at an input edge is retained for the
    sample already due on that edge (synchronous midpoint sampling).
    """

    def __init__(self):
        self.drive = False
        self.a_out, self.b_out = 1, 0
        self.rx_valid = False
        self.rx_data = 0
        self.frame_end = self.err = False
        self.tx_phase = 'idle'
        self.tx_age = 0
        self.tx_kick = False
        self.gap_left = 2
        self.queue = None
        self.tx_bits = deque()
        self.tx_level = 1
        self.tx_run = 0
        self.tx_last = 1
        self.tx_stuff = False
        self.rx_phase = 'idle'
        self.rx_age = 0
        self.previous_input = 1
        self.rx_previous_level = 1
        self.rx_last = 1
        self.rx_run = self.rx_idle = 0
        self.rx_stuff = False
        self.hunting = False
        self.sync_window = deque(maxlen=8)
        self.rx_bits = []

    @property
    def tx_ready(self):
        return self.queue is None

    @staticmethod
    def _bits(byte, width, msb):
        if width == 1:
            return [byte & 1]
        return [(byte >> bit) & 1 for bit in (range(7, -1, -1) if msb else range(8))]

    @staticmethod
    def _byte(bits, msb):
        return sum(bit << (len(bits) - 1 - index if msb else index)
                   for index, bit in enumerate(bits))

    @staticmethod
    def _run_after(bit, run, previous, style, stuffed=False):
        if style != 3:
            return 0 if stuffed or not bit else (run + 1) & 7
        return 1 if stuffed or bit != previous else (run + 1) & 7

    def step(self, clear=False, cfg=0, sync=0, period_m1=0,
             out_msb_first=False, in_msb_first=False, a_in=1, b_in=0,
             tx_put=False, tx_end=False, tx_data=0, rx_take=False):
        if clear or not cfg & 3:
            self.__init__()
            return
        nrzi, style, pair, byte_mode = cfg & 3 == 2, cfg >> 2 & 3, bool(cfg & 16), bool(cfg & 32)
        threshold, width = (6 if style == 1 else 5), (8 if byte_mode else 1)
        old_phase, old_queue = self.tx_phase, self.queue
        old_frame_end, old_rx_valid = self.frame_end, self.rx_valid
        old_rx_age = self.rx_age
        boundary = self.tx_age == period_m1
        kick = self.tx_kick
        self.frame_end = self.err = False
        if tx_put or tx_end:
            self.queue = ('end', 0) if tx_end else ('data', tx_data)
        self.tx_age = 0 if old_phase == 'idle' or boundary or kick else (self.tx_age + 1) & 65535
        self.tx_kick = False
        if old_phase == 'idle':
            if old_queue:
                if old_queue[0] == 'end':
                    self.queue = None
                else:
                    self.tx_phase, self.gap_left = 'gap', 2
        elif old_phase == 'gap':
            if boundary:
                self.gap_left -= 1
                if not self.gap_left:
                    self.tx_phase, self.tx_kick = 'data', True
                    self.tx_level, self.tx_run, self.tx_last, self.tx_stuff = 1, 0, 1, False
                    self.tx_bits = deque(self._bits(sync, 8, out_msb_first) if sync else [])
        elif old_phase == 'data':
            if boundary or kick:
                if not self.tx_stuff and not self.tx_bits and old_queue and old_queue[0] == 'data':
                    self.tx_bits.extend(self._bits(old_queue[1], width, out_msb_first))
                    self.queue = None
                if self.tx_stuff or self.tx_bits:
                    stuffed = self.tx_stuff
                    bit = (0 if style != 3 else 1 - self.tx_last) if stuffed else self.tx_bits.popleft()
                    self.tx_run = self._run_after(bit, self.tx_run, self.tx_last, style, stuffed)
                    self.tx_last = bit
                    self.tx_stuff = bool(not stuffed and style and self.tx_run == threshold)
                    self.tx_level = (self.tx_level if bit else 1 - self.tx_level) if nrzi else bit
                    self.a_out, self.b_out = self.tx_level, 1 - self.tx_level
                    self.drive = True
                elif old_queue and old_queue[0] == 'end':
                    self.queue = None
                    if pair:
                        self.tx_phase, self.a_out, self.b_out = 'se0-first', 0, 0
                    else:
                        self.tx_phase, self.drive = 'idle', False
                else:
                    self.err = True
        elif old_phase == 'se0-first':
            if boundary:
                self.tx_phase = 'se0-second'
        elif old_phase == 'se0-second':
            if boundary:
                self.tx_phase, self.a_out, self.b_out = 'idle-bit', 1, 0
        elif boundary:  # final idle bit, then release the bus
            self.tx_phase, self.drive, self.tx_level = 'idle', False, 1

        # A single edge-centred sampler is used for NRZ and NRZI. For NRZI,
        # the previous sampled *line level* decodes zero as a transition.
        changed = a_in != self.previous_input
        self.previous_input = a_in
        self.rx_age = 0 if changed or old_rx_age == period_m1 else (old_rx_age + 1) & 65535
        sample = old_rx_age == (period_m1 >> 1) + 1
        se0 = pair and not a_in and not b_in
        if rx_take:
            self.rx_valid = False
        if old_phase != 'idle':
            self.rx_phase = 'idle'
        elif self.rx_phase == 'idle':
            if se0:
                self.rx_phase = 'se0'
            elif not a_in:
                self.rx_phase = 'data'
                self.rx_previous_level = self.rx_last = 1
                self.rx_run = self.rx_idle = 0
                self.rx_stuff = False
                self.hunting = bool(sync)
                self.sync_window.clear()
                self.rx_bits.clear()
        elif self.rx_phase == 'se0':
            if sample and not se0:
                self.rx_phase = 'idle'
                self.frame_end = bool(a_in)
        elif sample:
            if se0:
                self.rx_phase = 'se0'
            else:
                bit = int(a_in == self.rx_previous_level) if nrzi else a_in
                self.rx_previous_level = a_in
                expected = 0 if style != 3 else 1 - self.rx_last
                stuffed = self.rx_stuff
                old_idle = self.rx_idle
                self.rx_idle = (self.rx_idle + 1) & 7 if a_in else 0
                self.rx_run = self._run_after(bit, self.rx_run, self.rx_last, style, stuffed)
                self.rx_last = expected if stuffed else bit
                if not pair and a_in and old_idle == 7:
                    self.rx_phase, self.frame_end = 'idle', True
                if stuffed:
                    self.rx_stuff = False
                    if bit != expected:
                        if not pair and a_in:
                            self.rx_phase, self.frame_end = 'idle', True
                        else:
                            self.err = True
                else:
                    self.rx_stuff = bool(style and self.rx_run == threshold)
                    if self.hunting:
                        self.sync_window.append(bit)
                        # Leading zeroes in the sliding window are significant:
                        # the sync comparator has an eight-bit reset window.
                        window = [0] * (8 - len(self.sync_window)) + list(self.sync_window)
                        if self._byte(window, in_msb_first) == sync:
                            self.hunting = False
                    else:
                        self.rx_bits.append(bit)
                        if len(self.rx_bits) == width:
                            self.rx_data = self._byte(self.rx_bits, in_msb_first)
                            self.rx_bits.clear()
                            if old_rx_valid and not rx_take:
                                self.err = True
                            self.rx_valid = True
        # A registered end indication invalidates any unread transfer on the
        # edge where that indication is observed by the engine.
        if old_frame_end:
            self.rx_valid = False


def __getattr__(name):
    """Expose the top-level oracle from the requested model entry point."""
    if name in ('PBEModel', 'FIFO', 'HostSPI'):
        from . import top_model
        return getattr(top_model, name)
    raise AttributeError(name)
