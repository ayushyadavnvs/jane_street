# Bug log

Every bug found in the design, the tests or the tools: what was wrong (with the code before),
how it was found, the fix (with the code after), and the test that now guards it.

Keep this file current: add an entry for every bug, including test and tool bugs, and never
delete an entry. Where possible, a bug gets a test that fails before the fix and passes
after it.

v2 (USB) has been retired (design decision D28). Its entries stay here; the v2 code they refer
to is on the branch `archive/v2-usb`, and `docs/USB_NOTES.md` summarizes them.

| ID | Area | Summary | Found by | Status |
|---|---|---|---|---|
| BUG-001 | Testbench | Two host transactions ran at once on the single host port | First UART run | Fixed |
| BUG-002 | Testbench | SPI peripheral model fetched its reply byte twice | First SPI run | Fixed |
| BUG-003 | Testbench | I2C START handshake deadlock between testbench and program | First I2C run | Fixed |
| BUG-004 | Testbench | Clock-stretching test passed even with stretching support removed | Mutation check | Fixed |
| BUG-005 | Tooling | Output filter hid a failed compile; a stale simulation ran | USB bring-up | Fixed |
| BUG-006 | Tooling | Icarus Verilog syntax limits and runtime crashes in USB helpers | USB bring-up | Fixed |
| BUG-007 | Testbench | A failing simulation exits with code 0 (`make test` "succeeds") | AI review #1 | Fixed |
| BUG-008 | Assembler (v2) | `NOP` assembles to the same word as `UTX` | AI review #2 | Fixed |
| BUG-009 | RTL (v2 USB) | Receiver drops stuffed bits without checking they are 0 | AI review #4 | Fixed |
| BUG-010 | Program (I2C) | SCL low time shorter than high time; violates I2C minimum low time | Speed analysis | Fixed |
| BUG-011 | Program (I2C) | STOP flag cleared before STOP finishes | AI review #5 | Fixed |
| BUG-012 | RTL (engine) | Restart does not cancel the current instruction's side effects | AI review #3 | Fixed |
| BUG-013 | RTL (engine) | Restart cleared pin output values: a line held high could glitch low | Modbus test (glitch monitor) | Fixed |
| BUG-014 | Testbench | Modbus device model took a zero-width glitch for a start bit | Modbus test bring-up | Fixed |
| BUG-015 | Program (Modbus) | Receiver polled for the next start bit inside the parity bit | Modbus test bring-up | Fixed |
| BUG-016 | Testbench | A counter shared with a static task was overwritten | Modbus test bring-up | Fixed |
| BUG-017 | RTL (top) | Shared flags: two flag-using protocols on the two engines consumed each other's flags | Design review (D27) | Fixed |
| BUG-018 | Testbench | Host-port lock was unfair; one host process starved the other | Two-protocol test bring-up | Fixed |
| BUG-019 | Program (Modbus) / RTL | Rewriting Modbus for `OUTPAR` dropped 8N2 support | Completeness review | Fixed |
| BUG-020 | Testbench | Tests ran at 50 MHz, not the planned 48 MHz | Completeness review | Fixed |
| BUG-021 | Testbench | `strong` is a reserved word; the 200 ms time limit looked like a hang | Bring-up of this round | Fixed |
| BUG-022 | Program (I2C) | ACK bits fed the CRC, so the SMBus PEC came out wrong | Test 7, written first | Fixed |
| BUG-023 | Testbench | Variable initializers inside procedural blocks run once, at time 0 | Icarus warning hidden by a filter; a false failure | Fixed, lint step |
| BUG-024 | Tooling | Icarus 12 aborts on a too-wide `push_back` and on a bit-select as an `output` argument | Bring-up of `tb_proto` | Worked around |
| BUG-025 | Testbench | I2C controller model never sent a repeated START | First Test 10 run | Fixed |
| BUG-026 | Testbench | SPI peripheral test never had an empty TX FIFO at CS fall | Mutation check | Fixed |
| BUG-027 | Testbench | Stimulus read a DUT output in the same time step it changed (tb_line, tb_engine_ops) | First unit-test runs | Fixed |
| BUG-028 | RTL (line coder) | A byte left unread when its frame ended was taken as the next frame's first byte | Test 11 (USB), trace | Fixed |
| BUG-029 | Testbench | The USB host model overwrote the OUT payload with the SETUP request | Test 11, FIFO trace | Fixed |
| BUG-030 | RTL (host port) | A burst read of an RX FIFO could lose a byte arriving during the burst | Review of the read pipeline | Fixed (RX_COUNT) |
| BUG-031 | Firmware flow | Flushing both FIFOs on SETUP dropped the OUT record arriving behind it | Test 11, FIFO trace | Fixed (TX_FLUSH) |
| BUG-032 | Design (USB records) | Records that piled up in the RX FIFO could not be told apart | Test 11, firmware trace | Fixed |
| BUG-033 | RTL (line coder) | Without SE0, the idle line after a frame was reported as a stuffing error | tb_line, written first | Fixed |
| BUG-034 | Testbench | A pile-up test that overflowed the 16-byte RX FIFO | Full suite | Fixed |
| BUG-035 | Tooling | More Icarus 12 limits: queue arguments, `return` in tasks, array ports, and others | Bring-up of tb_line, tb_usb | Worked around |
| BUG-036 | CI | The gate-level regression job looked for the netlist one folder too deep | First CI run | Fixed |
| BUG-037 | Testbench / CI | The gate-level regression failed early; with Icarus 13, tb_pbe used a variable before its declaration | Second and third CI runs | Fixed |
| BUG-043 | Design (D50 draft) | A bubble after every instruction broke the SPI peripheral at 2 MHz | Timing review of the draft; Test 9 on it | Fixed (prefetch) |
| BUG-044 | Tooling | Yosys merged the copies of the read address back into one register, `keep` on the variable notwithstanding | Flip-flop count after synthesis | Fixed |
| BUG-045 | Tooling | Verilator 5.020 rejects a default value on a module input, which the unit testbenches needed for `pm_wr` | Lint before the first run | Worked around |

---

## BUG-001 — Host transactions collided on the single SPI port

- **Where:** `test/tb_pbe.sv`, UART test.
- **Symptom:** Engine 1's RX FIFO stayed empty; the UART pin never toggled.
- **Cause:** The test sent and received in parallel with `fork`. Both branches drove the
  same host SPI pins, so the transactions corrupted each other and no byte reached the TX
  FIFO. The engine was correctly waiting in `PULL`.
- **Before:**
  ```systemverilog
  fork
    foreach (sent[i]) fifo_send(0, sent[i]);
    foreach (sent[i]) begin
      fifo_recv(1, got);
      check(got === sent[i], ...);
    end
  join
  ```
- **After:** one process takes turns, keeping up to 4 bytes queued.
  ```systemverilog
  for (int i = 0; i < 4; i++) fifo_send(0, sent[i]);
  foreach (sent[i]) begin
    fifo_recv(1, got);
    check(got === sent[i], ...);
    if (i + 4 < sent.size()) fifo_send(0, sent[i+4]);
  end
  ```
- **Lesson:** The host port is a shared resource; a testbench must serialize it like real
  firmware would.

## BUG-002 — SPI peripheral model fetched a reply twice

- **Where:** `test/tb_pbe.sv`, SPI peripheral model.
- **Symptom:** Read byte 1 was `81` instead of `C3`; byte 2 was `EE`.
- **Cause:** The model loaded its next reply both at the falling clock edge after a byte
  and again when CS̅ fell for the next byte, skipping one.
- **Before:**
  ```systemverilog
  always @(negedge bus[3]) if (spi_dev_en) begin
    dev_tx = spi_reply.size() ? spi_reply.pop_front() : 8'hEE;
    ...
  ```
- **After:** a `dev_loaded` flag; whichever event comes first loads the reply, the other
  reuses it.
  ```systemverilog
  always @(negedge bus[3]) if (spi_dev_en) begin
    if (!dev_loaded) dev_tx = next_reply();
    dev_loaded = 1;
    ...
  ```

## BUG-003 — I2C START handshake deadlock

- **Where:** `test/tb_pbe.sv`, I2C helpers.
- **Symptom:** Simulation timed out; engine 1 looped in `idle` with FLAG0 set and the TX FIFO
  empty.
- **Cause:** By design the program performs START when the next byte arrives. The testbench
  waited for the program to clear FLAG0 *before* sending that byte. Each side waited for the
  other.
- **Before:**
  ```systemverilog
  reg_write(7'h04, flag);
  do reg_read(7'h04, f); while (f != 0);   // also for START
  ```
- **After:** only STOP waits for completion.
  ```systemverilog
  reg_write(7'h04, flag);
  if (flag[1]) do reg_read(7'h04, f); while (f != 0);
  ```
- **Lesson:** The host protocol was right but undocumented; it is now in the README.

## BUG-004 — Clock-stretching test was too weak

- **Where:** `test/tb_pbe.sv`, I2C peripheral model.
- **How found:** Removing every `WAIT scl, HIGH` from `i2c_ctrl.pbe` still passed.
- **Cause:** The model stretched SCL only before the ACK slot. At that moment the engine is
  always blocked on `PULL` waiting for the host's next byte, so the engine was paused anyway
  and never needed to wait for SCL.
- **Before:** stretch only when `i_bit == 8`.
- **After:** stretch after bit 4 (mid-byte, engine at full speed) and bit 8.
  ```systemverilog
  if (i_bit == 4 || i_bit == 8) begin
    ext_drive[SCL] = 1;
    ext_val[SCL] = 0;
    repeat (I2C_STRETCH) @(posedge clk);
    ext_drive[SCL] = 0;
  end
  ```
- **Evidence:** with the fix the mutant (no `WAIT`) fails with "address+W not ACKed"; the real
  program passes with 20 stretches.
- **Lesson:** A passing test proves little until it is shown to fail when the feature is broken.

## BUG-005 — A failed compile was hidden; a stale simulation ran

- **Where:** the command used to run tests.
- **Symptom:** Test 4 (USB) was missing from the output although it was in the file.
- **Cause:** Compiler output was piped through `grep -v sorry` to hide a harmless Icarus
  warning. That also hid "sorry: break statements not supported", the compile failed, and
  the old `sim.vvp` from before the USB test ran instead.
- **Fix:** Delete `sim.vvp` before compiling, filter only the exact harmless warning
  ("constant selects in always"), and check the compiler's exit code.
- **Lesson:** Never filter tool output broadly. BUG-007 is the same lesson for the simulator.

## BUG-006 — Icarus Verilog limits and crashes

- **Where:** `pbe_v2/test/tb_pbe.sv`, USB helpers.
- **Symptoms and fixes:**

  | Problem | Fix |
  |---|---|
  | `pulldown` and `before` are reserved words | Renamed `pull_lo`, `n_prev` |
  | `break` not supported | Loop condition instead |
  | Queue slice `d[1:$]` not supported | Loop from index 1 |
  | Bit-select of a queue element with variable indexes (`d[i][b]`) rejected | Copy the element to a temporary first |
  | Function with a queue argument: compiler assertion | Removed |
  | Automatic tasks using queues: runtime crash at time 0 (`vthread_get_rd_context_item`) | USB helpers rewritten as static tasks on module-level variables |
- **How the crash was isolated:** removing helper blocks one at a time, then statements one at
  a time.
- **Lesson:** Keep testbench SystemVerilog simple when the simulator is Icarus.

---

## BUG-007 — A failing simulation exits with code 0

- **Where:** `pbe_v1/test/tb_pbe.sv`, `pbe_v2/test/tb_pbe.sv` (end of the test and the timeout).
- **Found by:** AI review, finding #1. Confirmed: with a deliberately broken design the
  simulation printed 5 FAILs and `vvp` returned 0.
- **Why it matters:** Any script or CI job trusts the exit code, so a broken design would pass.
- **Before:**
  ```systemverilog
  if (errors == 0) $display("PASS");
  else $display("FAILED with %0d error(s)", errors);
  $finish;
  ...
  #20ms;
  $display("FAILED: timeout");
  $finish;
  ```
- **After:** `$fatal` ends a failing run with a non-zero exit code.
  ```systemverilog
  // $fatal gives a non-zero exit code, so make and CI see the failure (BUG-007)
  if (errors == 0) begin
    $display("PASS");
    $finish;
  end else $fatal(1, "FAILED with %0d error(s)", errors);
  ...
  $fatal(1, "FAILED: timeout");
  ```
- **Test:** a copy of v1 with a deliberately broken UART setting.
  - Before: 5 FAILs printed, `vvp` exit code **0**.
  - After: `FATAL: FAILED with 4 error(s)`, `make test` exit code **2**.
- **Status:** Fixed in v1 and v2.

## BUG-008 — `NOP` assembles to `UTX` in v2

- **Where:** `pbe_v2/tools/pbe_asm.py`; meaning defined in `pbe_v2/src/pbe_engine.sv`.
- **Found by:** AI review, finding #2. Confirmed: `NOP` and `UTX` both assemble to `0xE000`.
- **Why it matters:** In v1 opcode 111 was reserved and did nothing. In v2 it is the USB
  opcode, and sub-op 0 with argument 0 is `UTX`: it shifts the OSR, updates the CRC, drives
  the D+/D- pins and can stall. Any program using `NOP` for a delay would emit USB activity.
- **Before:**
  ```python
  OPS = {..., "FLAG": 6, "NOP": 7}
  ...
  else:  # NOP
      need(0)
      arg = 0          # -> 0xE000 == UTX in v2
  ```
- **After:** `NOP` is `FLAG` with action 3, which the engine ignores in every version:
  `0xD800`.
  ```python
  OPS = {..., "FLAG": 6, "NOP": 6}
  ...
  else:  # NOP: FLAG with action 3, which does nothing (opcode 111 is USB in v2)
      need(0)
      arg = 3 << 7
  ```
  The engine header now documents `FLAG` action 3 as "none (the assembler's NOP)".
- **Test:** Test 0 runs a program of only `NOP`s on pins 2–3 (a USB pair in v2) and checks
  that no pin is driven and no flag or interrupt changes.
  - Before (v2): `FAIL: NOP drove pins: uio_oe = 00001100`. v1 passed (opcode 111 did nothing there).
  - After: passes in both.
- **Status:** Fixed in v1 and v2 (v1 changed too, so programs mean the same in both).

## BUG-009 — USB receiver drops stuffed bits without checking them

- **Where:** `pbe_v2/src/pbe_usb_line.sv`, receiver.
- **Found by:** AI review, finding #4.
- **Why it matters:** After six 1s the sender must insert a 0. If the next bit is a 1 instead,
  the packet is malformed and USB requires rejecting it (USB 2.0 §7.1.9.1). The receiver
  dropped that bit whatever it was, so data and CRC could come out unchanged and the packet
  would look valid.
- **Before:**
  ```systemverilog
  end else if (rones == 3'd6) begin
    rones <= '0;  // stuffed bit, drop it
  end else begin
  ```
- **After:** the dropped bit must decode as 0; otherwise a sticky stuffing-error flag is set.
  It clears at the next SYNC and is reported by `STAT` as bit 2.
  ```systemverilog
  end else if (rones == 3'd6) begin
    rones <= '0;  // stuffed bit: drop it, but it must decode as a 0
    if (dp_in == prev_k) serr <= 1'b1;
  end else begin
  ...
  U_STAT: isr <= {5'b0, u_serr, u_crc16_ok, u_crc5_ok};
  ```
- **Test:** the USB host model can send a 1 where the first stuffed 0 belongs. Test 4 sends
  a DATA0 packet that way; the existing good packets now also check that bit 2 stays 0.
  - Before: status `02`, CRC "ok": the malformed packet looked valid, exactly as the review
    predicted.
  - After: status `06` (bit 2 set). Good packets still report `01` / `02`.
- **Status:** Fixed (v2 only; v1 has no USB).

## BUG-010 — I2C SCL low time shorter than the high time

- **Where:** `programs/i2c_ctrl.pbe`, both versions.
- **Found by:** working out the achievable I2C speeds at 48 MHz.
- **Why it matters:** I2C sets a minimum low time longer than the minimum high time
  (standard mode 4.7 / 4.0 µs, fast mode 1.3 / 0.6 µs). The program held SCL low for 3 ticks
  and high for 4. At a 400 kHz setting the low phase is 1.13 µs, below the 1.3 µs minimum.
- **Before:**
  ```
  bit:    PIN  sda, OUTOD
          PIN  scl, REL
          WAIT scl, HIGH
          IN   sda [1]         ; high phase gets the extra tick
          PIN  scl, DRV0
          JMP  X--, bit
  ```
- **After:** the extra tick moves from the sampling instruction to the "SCL low" instruction:
  SCL is now low 4 ticks, high 3. `IN` still samples while SCL is high.
  ```
  bit:    PIN  sda, OUTOD
          PIN  scl, REL
          WAIT scl, HIGH
          IN   sda             ; sample while SCL is high
          PIN  scl, DRV0 [1]   ; low phase gets the extra tick
          JMP  X--, bit
  ```
  The ACK slot got the same change. START/STOP setup and hold times and the bus-free time
  also meet fast mode at this speed (2 ticks = 0.72–0.75 µs ≥ 0.6 µs; 4 ticks ≥ 1.3 µs).
- **Test:** Test 3 now runs I2C at a fast-mode setting (CLKDIV = 17) and measures every SCL
  phase: low ≥ 1.3 µs, high ≥ 0.6 µs, period ≥ 2.5 µs. (The period check skips the cycle
  right after a clock stretch, where the controller times the high phase from when it sees
  SCL rise; the spec only sets minimum low and high times.)
  - Before: `SCL low 1080 ns` (v1) / `1125 ns` (v2), fast mode needs 1300.
  - After: low 1440 / 1500 ns, high 780 / 813 ns, period 2520 / 2625 ns (v1 / v2).
- **Status:** Fixed in v1 and v2.

## BUG-011 — I2C STOP flag cleared before STOP finishes

- **Where:** `programs/i2c_ctrl.pbe`, both versions.
- **Found by:** AI review, finding #5.
- **Why it matters:** The README tells the host to wait for FLAG1 to clear. The program cleared
  it as the first instruction of the STOP routine, before releasing SCL, waiting for
  stretching and raising SDA, so the host could believe the bus is free too early.
- **Before:**
  ```
  stop:   FLAG 1, CLR          ; cleared first
          PIN  sda, DRV0
          PIN  scl, REL
          WAIT scl, HIGH [1]
          PIN  sda, REL [3]    ; STOP: SDA rises while SCL is high
          JMP  idle
  ```
- **After:** FLAG1 is cleared as the last step of the STOP routine.
  ```
  stop:   PIN  sda, DRV0
          PIN  scl, REL
          WAIT scl, HIGH [1]
          PIN  sda, REL [3]    ; STOP: SDA rises while SCL is high
          FLAG 1, CLR          ; only now tell the host the STOP is done
          JMP  idle
  ```
- **Test:** a monitor checks that whenever FLAG1 clears, both SDA and SCL are already high.
  - Before: `FAIL: I2C: FLAG1 (STOP) cleared before the STOP finished`, 3 times (every STOP).
  - After: passes.
- **Status:** Fixed in v1 and v2.

## BUG-012 — Restart does not cancel the current instruction's side effects

- **Where:** `src/pbe_engine.sv`, both versions.
- **Found by:** AI review, finding #3.
- **Why it matters:** `restart` wins in the engine's state update, but the side-effect
  strobes are combinational from `exec`. If the host restarts a running engine in the same
  cycle a `PULL` completes, the TX FIFO pops while the engine clears the OSR: that byte is
  lost. The same applies to `PUSH` and flag changes (and in v2 to the USB line unit inputs).
- **Before:**
  ```systemverilog
  assign exec = issue && ready;
  assign tx_pop   = exec && op == OP_FIFO && !arg_hi;
  ...
  end else if (restart) begin
    pc  <= start_pc;
    osr <= '0;
  ```
- **After:** `exec` is false during a restart, so no strobe can fire.
  ```systemverilog
  // A restart in the same cycle cancels the instruction, so it has no side effects.
  assign exec = issue && ready && !restart;
  ```
  In v2 this also covers the USB line unit's inputs, which are driven from `exec`.
- **Test:** new unit test `test/tb_engine_restart.sv` (run by `make test`) holds an
  instruction ready and raises `restart` in that cycle, for `PULL`, `PUSH`,
  `FLAG SET/CLR/IRQ`.
  - Before: `PUSH` pushed, the flag set/clear strobes fired and the IRQ fired (4 failures).
    `PULL` did not show it in this setup; it goes through the same `exec` term as `PUSH`.
  - After: no side effects for any of them.
- **Cost:** the worst logic path grew slightly (v1 3.61 → 3.78 ns, v2 3.72 → 3.96 ns),
  still far under 20.8 ns.
- **Status:** Fixed in v1 and v2.

## BUG-013 — Restart could glitch a high pin low

- **Where:** `src/pbe_engine.sv`, restart branch, both versions.
- **Found by:** bringing up the Modbus test. The device model saw a "start bit" at the moment
  engine 0 was restarted, and a new glitch monitor on the TX line confirmed it.
- **Cause:** restart cleared both the output value and the output enable of every pin. A pin
  that was driving high had its value change to 0 in the same cycle as its driver turned off.
  In simulation that is a zero-width low pulse (v1 shows it; in v2 the event order happens to
  hide it). In silicon, skew between the value and enable paths could drive the line low for a
  fraction of a nanosecond: a false start bit for UART/Modbus, a false slot for 1-Wire.
- **Before:**
  ```systemverilog
  end else if (restart) begin
    ...
    pins_out <= '0;
    pins_oe  <= '0;
  ```
- **After:** restart only releases pins; the line floats to its pull-up with no low pulse.
  ```systemverilog
  end else if (restart) begin
    ...
    pins_oe  <= '0;  // release every pin; keep pins_out so a line held high cannot glitch low
  ```
  Programs set a pin's value before toggling it, so a stale value after restart is harmless.
- **Test:** the Modbus test counts every low pulse on the TX line shorter than half a bit.
  - Before (v1): `FAIL: Modbus: 1 glitches on the TX line`.
  - After: 0 glitches in v1 and v2.
- **Status:** Fixed in v1 and v2.

## BUG-014 — Modbus device model took a glitch for a start bit

- **Where:** `test/tb_pbe.sv`, Modbus device model.
- **Symptom:** the first request arrived garbled (`05 0D 02 …` instead of `01 03 00 …`), 9 bytes
  instead of 8; the second request was fine.
- **Cause:** the model started a character on any falling edge, including BUG-013's zero-width
  glitch, and stayed misaligned for the whole frame. Real UART receivers check that the line is
  still low part-way into the start bit (our own UART RX program does).
- **Before:**
  ```systemverilog
  wait (mb_en && !bus[0]);  // start bit of a request
  ...
  #(MB_BIT * 1.5);          // first data bit
  ```
- **After:**
  ```systemverilog
  wait (mb_en && !bus[0]);  // start bit of a request
  #(MB_BIT / 4);
  if (!bus[0]) begin        // still low: a real start bit, not a glitch
  ...
  #(mb_first ? MB_BIT * 1.25 : MB_BIT * 1.5);
  ```
- **Lesson:** the glitch was real (BUG-013), so making the model robust was not enough on its
  own; a separate monitor now makes the glitch itself a failure.

## BUG-015 — Modbus receiver polled for a start bit inside the parity bit

- **Where:** `programs/modbus_rtu.pbe`, both versions.
- **Symptom:** response bytes 0 and 1 were right, then every byte was shifted by one bit
  (`04` arrived as `08`).
- **Cause:** after sampling the parity bit the program started polling for the next start bit
  3 ticks later, still inside the parity bit. When the parity bit is 0 (byte `03`), that looks
  like a start bit. Byte `01` survived only because its parity bit is 1.
- **Before:**
  ```
          IN   rx              ; parity bit, at 9.5 bits
          PUSH
          SET  X, silence      ; polling starts at ~9.9 bits: still the parity bit
  gap:    JMP  PIN_LO, rxc
  ```
- **After:** polling starts in the middle of the stop bit; the silence count drops by 2 to keep
  the 3.5-character timeout.
  ```
          IN   rx              ; parity bit, at 9.5 bits
          PUSH
          SET  X, silence [4]  ; start polling in the stop bit, not the parity bit
  gap:    JMP  PIN_LO, rxc
  ```
- **Test:** the Modbus test's response checks (every byte and the CRC).
  - Before: `FAIL: Modbus response byte 2: 08` … `response CRC failed`.
  - After: all 9 bytes and the CRC correct, in both rounds.
- **Status:** Fixed in v1 and v2.

## BUG-016 — A counter shared with a static task was overwritten

- **Where:** `test/tb_pbe.sv`, Modbus test.
- **Symptom:** the host reported 8 parity errors per round, although every status byte was
  correct when printed.
- **First guess, disproved:** that Icarus parsed `^mb_d != mb_x[7]` as `^(mb_d != mb_x[7])`.
  A standalone test showed Icarus parses it correctly.
- **Cause:** the parity-error counter was `mb_j`, which is also the bit-loop variable of the
  static `mb_crc16` task. Calling `mb_crc16` after the counting loop left `mb_j = 8`. Static tasks
  share variables (they were made static to avoid Icarus crashes, BUG-006).
- **Before:**
  ```systemverilog
  mb_j = 0;
  for (...) if (^mb_d != mb_x[7]) mb_j++;
  mb_buf = mb_rx;
  mb_crc16;                       // uses mb_j internally
  check(mb_j == (round ? 1 : 0), ...);
  ```
- **After:** a counter of its own.
  ```systemverilog
  int mb_i, mb_j, mb_perr;  // mb_i/mb_j belong to the tasks; static tasks share variables
  ...
  if ((^mb_d) != mb_x[7]) mb_perr++;
  ```
- **Lesson:** with static tasks, give every caller-side variable its own name.

## BUG-017 — Shared flags: two protocols consumed each other's flags

- **Where:** `src/tt_um_pbe.sv`, both versions (the flags register and its connection to the engines).
- **Found by:** design review; recorded as limitation D27 when 1-Wire and Modbus were added.
- **Cause:** there were 4 flags, shared by both engines, and `JMP` can only test FLAG0 and FLAG1.
  I2C, 1-Wire, Modbus and USB TX all use FLAG0/FLAG1 as host requests, so on two engines they
  read each other's requests. The host also rewrote the whole flags register to set one flag,
  which could wipe a flag the other engine had just changed.
- **Before:**
  ```systemverilog
  logic [3:0] flags;  // shared by both engines
  flags <= (flags | f_set[3:0] | f_set[7:4]) & ~(f_clr[3:0] | f_clr[7:4]);
  7'h04: flags <= wr_data[3:0];   // the host's only way to change a flag
  .flags (flags),                 // both engines see the same 4 flags
  ```
- **After:** 8 flags. Each engine sees a window of 4 starting at its `FLAG_BASE` (engine
  register +8; reset 0 for engine 0, 4 for engine 1), so "FLAG n" in a program is physical flag
  `(FLAG_BASE + n) mod 8`. Overlapping bases still let the engines signal each other. The host
  gets `FLAG_SET` (0x08) and `FLAG_CLR` (0x09) to change single bits. Programs are unchanged.
  ```systemverilog
  wire [2:0]  fbase = flag_base[e*3+:3];
  wire [15:0] fl2   = {flags, flags};
  wire [15:0] set2  = {12'b0, f_set[e*4+:4]} << fbase;
  assign e_flags[e*4+:4] = fl2[fbase+:4];          // the engine's 4 flags
  assign p_set[e*8+:8]   = set2[7:0] | set2[15:8];   // back to physical flags
  ...
  flags <= (flags | p_set[7:0] | p_set[15:8] | host_set) & ~(p_clr[7:0] | p_clr[15:8] | host_clr);
  ```
- **Test:** new test "1-Wire Search ROM (engine 0) and I2C (engine 1) at the same time": two
  host processes run a full Search ROM and repeated I2C write/read rounds concurrently.
  - Before (old hardware; helpers rewritten to read-modify-write the old 4 shared flags):
    `FAIL: concurrent I2C round 1 read 40, wrote 41`, the same for round 3, then a timeout.
    A trace shows the host setting FLAG0 for a 1-Wire reset and the **I2C engine** taking it as a
    START request and clearing it.
  - After: passes in v1 and v2: Search ROM found both devices while I2C completed 62 rounds;
    406 1-Wire edges happened during I2C traffic.
- **Cost:** about 2,700 µm² (+2 %); worst logic path ~3.95 ns.
- **Status:** Fixed in v1 and v2.

## BUG-018 — Host-port lock let one process starve the other

- **Where:** `test/tb_pbe.sv`, the `cs` task (host SPI chip select), both versions.
- **Symptom:** the two-protocol test timed out on the new hardware. A progress probe showed I2C
  running 223 rounds while the 1-Wire host process never got another transaction through.
- **Cause:** the lock was a busy flag. The I2C process released it at the end of a transaction
  and took it again in the same simulation instant, before the waiting 1-Wire process woke up.
  (The first "before" run of BUG-017 used this lock too, so it was rerun with the fixed lock to
  make sure the old-hardware failure was the flag clash and not the lock.)
- **Before:**
  ```systemverilog
  bit host_busy = 0;
  if (!level) begin
    while (host_busy) @(posedge clk);
    host_busy = 1;
  end
  ...
  if (level) host_busy = 0;
  ```
- **After:** a ticket lock, which serves waiters in arrival order.
  ```systemverilog
  int host_next = 0, host_serving = 0;
  int ticket;
  if (!level) begin
    ticket = host_next++;
    while (host_serving != ticket) @(posedge clk);
  end
  ...
  if (level) host_serving++;
  ```
- **Lesson:** a shared resource in a testbench needs a fair lock, just as in software.

## BUG-019 — Modbus 8N2 lost when the program moved to `OUTPAR`

- **Where:** `programs/modbus_rtu.pbe` and the parity logic in `src/pbe_engine.sv`.
- **Found by:** reviewing what was still missing after the CRC/parity/timeout round.
- **Cause:** the first Modbus program sent whatever bit the host put in a "parity byte", so the
  host could send 1 for 8N2 (no parity, two stop bits). The rewrite generates parity in hardware
  with `OUTPAR`, which always sent a parity bit, and the receiver always checked one. A
  regression: no test covered 8N2.
- **Before:**
  ```systemverilog
  wire par_err = par_in ^ odd;
  3'd6: begin pins_out[pin_idx] <= par_out ^ odd; pins_oe[pin_idx] <= 1'b1; end   // OUTPAR
  ```
- **After:** `LINE_CFG[6]` = no parity: `OUTPAR` sends 1 and receive parity errors are masked.
  The Modbus program is unchanged; the host sets `LINE_CFG` = 0x41.
  ```systemverilog
  wire no_par  = line_cfg[6];
  wire par_err = !no_par && (par_in ^ odd);
  wire par_bit = no_par || (par_out ^ odd);  // what OUTPAR sends
  3'd6: begin pins_out[pin_idx] <= par_bit; pins_oe[pin_idx] <= 1'b1; end
  ```
- **Test:** a new Modbus round in 8N2; the device model expects a second stop bit and sends one.
  - Before: `FAIL: Modbus round 4: engine reported 5 parity errors`, and the device saw 4 wrong
    "second stop bits" (the parity bits of characters with odd parity).
  - After: the 8N2 round passes with no parity errors and a good CRC.
- **Lesson:** when a feature moves from software to hardware, test every mode the old version
  supported.

## BUG-020 — Tests ran at 50 MHz, not the planned 48 MHz

- **Where:** `test/tb_pbe.sv`.
- **Cause:** v1's testbench kept the 50 MHz clock from the first version after the plan moved
  to 48 MHz (D18). Programs compute their settings from the clock, so nothing failed, but the
  planned frequency itself was never simulated.
- **Before:** `localparam int CLK_NS = 20;  // 50 MHz`
- **After:** `localparam real CLK_NS = 20.8333;  // 48 MHz, the planned clock`
- **Test:** the whole suite. Before: passed at 50 MHz. After: passes at 48 MHz (I2C fast mode
  measures 1.5 µs low / 0.8 µs high at this clock).

## BUG-021 — Reserved word `strong`; a time limit that looked like a hang

- **Where:** `test/tb_pbe.sv`.
- **Symptoms and fixes:**

  | Problem | Fix |
  |---|---|
  | The 1-Wire device model's new port `strong` broke compilation: it is a SystemVerilog keyword (as `pulldown` and `before` were in BUG-006) | Renamed `hard_hi` |
  | The two-protocol test timed out. A progress probe showed it was running normally; the new 1-Wire and Modbus checks had pushed it past the 200 ms simulated-time limit (it started at 168.6 ms) | Limit raised to 400 ms |
- **Lesson:** before treating a timeout as a hang, check whether the test is still making progress.

## BUG-022 — I2C controller fed its ACK bits into the CRC

- **Where:** `programs/i2c_ctrl.pbe`.
- **Found by:** Test 7 (SMBus PEC), written before the fix.
- **Cause:** every `IN` feeds the CRC unit when `CRC_CFG[7]` is set, including the one that
  samples the ACK slot. An SMBus PEC covers bytes only, so each ACK bit (a 0) corrupted it. No
  earlier test used the CRC unit with I2C.
- **Before:**
  ```
          WAIT scl, HIGH
          IN   sda
          PIN  scl, DRV0 [1]
          PUSH                 ; 0 = ACK, 1 = NACK
  ```
- **After:**
  ```
          WAIT scl, HIGH
          IN   sda, NOCRC      ; the ACK bit is not part of an SMBus PEC
          PIN  scl, DRV0 [1]
          PUSH                 ; 0 = ACK, 1 = NACK
  ```
- **Test:** Test 7 in `tb_pbe.sv`.
  - Before (old program, new test):
    ```
    FAIL: SMBus write: engine PEC 2c, expected ef
    FAIL: SMBus write: the device's CRC over the message and PEC is 47
    FAIL: SMBus read with the right PEC 88: CRC ok = 0
    ```
  - After: passes; the corrupted-PEC read still reports CRC ok = 0.

## BUG-023 — Declaration initializers in procedural blocks run only once

- **Where:** `test/tb_proto.sv` (new code), and one harmless case in `test/tb_pbe.sv`.
- **Cause:** in SystemVerilog, a variable declared inside a `begin`/`end` of an `initial` or
  `always` block is static, and its initializer runs once at time 0, not each time the block
  runs.
  - `realtime low = $realtime - ws_fall;` in the WS2812 decoder: caught when reading the code
    before the first run.
  - `int bytes_before = tgt_bytes;` in Test 10: produced a false failure. Icarus prints
    `warning: Static variable initialization requires explicit lifetime`, but the build's output
    filter (which hides Icarus's many "sorry: constant selects" notes) hid it too, the same
    trap as BUG-005.
- **Before:**
  ```systemverilog
  int bytes_before = tgt_bytes;   // runs at time 0: always 0
  ```
- **After:**
  ```systemverilog
  int bytes_before;
  bytes_before = tgt_bytes;  // not an initializer: that would run once, at time 0
  ```
  plus a lint step in the Makefile, run first by `make test` and `make test-proto`:
  ```make
  LINT = cd test && for tb in tb_engine_restart tb_proto tb_pbe; do \
  	  if iverilog -g2012 -o /dev/null $$tb.sv $(addprefix ../,$(SRC)) 2>&1 | grep "Static variable initialization"; then exit 1; fi; done
  ```
- **Test:**
  - Before: `FAIL: I2C target passed 7 bytes of another device's transaction to the host`. The 7
    bytes were all from the earlier transactions.
  - After: passes. The lint step was checked against a file with a static initializer: it fails.

## BUG-024 — Icarus 12 aborts on two testbench constructs

- **Where:** `test/tb_proto.sv` (Icarus Verilog 12.0).
- **Symptoms and fixes:**

  | Construct | Icarus | Workaround |
  |---|---|---|
  | `exp.push_back(8'h10 * led + frame)`: a 32-bit value pushed into a queue of bytes; also `ws_bits.push_back(ws_last)` (1 bit into 8) | `vthread.cc:520: pop_value: Assertion 'value.size() == wid' failed` | Cast to the element width: `push_back(8'(...))` |
  | `ic_bit(1, b[i])`: a bit-select of an automatic variable as an `output` argument | Segmentation fault | Pass a temporary, then `b[i] = r` |

  Two more changes were made as a precaution while hunting the crashes and were not confirmed
  as causes: a queue `pop_front()` passed straight as a task argument now goes through a
  temporary, and the 1-bit queue became 8 bits wide.
- **How it was found:** the simulation died with no output (lost in the buffer). A run under
  `stdbuf -o0` and a copy of the testbench with a progress `$display` after each step located
  each crash.
- **Test:** `make test-proto` runs to `PASS`.

## BUG-025 — I2C controller model never sent a repeated START

- **Where:** `test/tb_proto.sv`, task `ic_start`.
- **Found by:** the first run of Test 10: reads after a repeated START returned `ff ff ff`, and
  the host saw only 3 of 4 address ACKs. A trace showed no START on the bus at that point: the
  target had correctly taken the read address `0x85` as a data byte.
- **Cause:** `ic_start` tested `bus[1]` (SCL) to decide between START and repeated START, in the
  same time step that `ic_bit` had just pulled SCL low. The wired-AND net had not updated yet,
  so the model saw SCL high and skipped raising SCL for the repeated START.
- **Before:**
  ```systemverilog
  task automatic ic_start;  // START, or repeated START when SCL is low
    if (!bus[1]) begin
  ```
- **After:**
  ```systemverilog
  task automatic ic_start;  // START, or repeated START when SCL is low
    // Test our own drive, not bus[1]: right after ic_scl(0) the net has not updated yet.
    if (ext_drive[1]) begin
  ```
- **Test:**
  - Before: `FAIL: I2C target read ff ff ff, expected ad be ef`.
  - After: passes. The mutation that removes the target's repeated-START check (`JMP FLAG0,
    start` in the write loop) now fails it.

## BUG-026 — SPI peripheral test missed the "nothing queued at select" case

- **Where:** `test/tb_proto.sv`, Test 9.
- **Found by:** mutation check. Removing the first `SET OSR, 0xFF` in `spi_periph.pbe` (the
  default reply when CS falls with an empty TX FIFO) still passed. Every transaction in the test
  queued a reply before selecting, so only the mid-transaction default was tested.
- **Fix:** a third transaction with nothing queued, which expects `ff ff`.
- **Test:**
  - Before: that mutation ran with `0 FAIL lines, exit 0`.
  - After: the mutation fails with `FAIL: SPI peripheral with nothing queued replied fe ff,
    expected ff ff`, and the unmodified program passes.

## BUG-027 — Stimulus raced the DUT at clock edges

- **Where:** `test/tb_line.sv` (task `send_u`/`send_v`) and `test/tb_engine_ops.sv` (its TX FIFO
  stand-in).
- **Cause:** both read or changed a signal in the same time step as the clock edge at which the
  DUT updates it.
  - `send_u` checked `tx_ready` right after `@(posedge clk)`, before the coder's update from the
    previous byte, so it put a second byte into the full queue and overwrote the first.
  - The FIFO stand-in popped its queue at the same edge at which the engine loaded `tx_data`,
    so the engine sometimes took the next byte.
- **Before:**
  ```systemverilog
  while (!ready_u) @(posedge clk);
  data_u <= d; put_u <= !is_end; end_u <= is_end;
  ...
  if (tx_pop) d = tx_q.pop_front();
  ```
- **After:**
  ```systemverilog
  @(negedge clk);  // between edges, so tx_ready already shows the last put (BUG-027)
  while (!ready_u) @(negedge clk);
  data_u = d; put_u = !is_end; end_u = is_end;
  ...
  if (tx_pop) begin
    #1;  // after the engine has taken tx_data at this edge
    d = tx_q.pop_front();
  ```
- **Test:**
  - Before: `FAIL: USB TX: driven for 1184 clocks, expected 72 bits x 32` and `FAIL: byte 3 is 3f,
    expected dd` (a CRC over the wrong bytes).
  - After: both unit tests pass. The coder's transmit matches the reference encoder bit for bit.

## BUG-028 — An unread byte survived the end of its frame

- **Where:** `src/pbe_line.sv`, with `programs/usb_dev.pbe`'s `skip` loop.
- **Found by:** Test 11. After SET_ADDRESS, every SETUP at the new address went unanswered,
  until a keep-alive. A trace showed what happened:
  - An IN for the old address went to `skip`, which waits for the end of the packet without
    reading it.
  - The token's third byte stayed in the coder. After the end-of-frame event, `idle` read that
    stale byte as the next PID.
  - From then on every packet was off by one byte.
- **Before:** `rx_valid` was cleared only by a read.
- **After:**
  ```systemverilog
  // A byte the engine has not taken when its frame ends belongs to that frame: drop it,
  // so it cannot be read as the start of the next frame (BUG-028).
  if (frame_end) rx_valid <= 1'b0;
  ```
  Every reading path in a program takes its bytes within a few clocks; only code that ignores a
  frame on purpose leaves one behind. Fixing the program instead (`skip` reading the rest) would
  have cost a word the 64-word program does not have.
- **Test:**
  - Before: `FAIL: USB: SETUP not ACKed` (nine times), `FAIL: USB: device descriptor at the new
    address: 0 bytes`.
  - After: Test 11 passes. Removing the line (mutation) makes it fail again.

## BUG-029 — The USB host model overwrote the OUT payload

- **Where:** `test/tb_usb.sv`, tasks `hs_setup` / `hs_out`.
- **Cause:** both used the queue `u_data`. The test put the vendor-write payload `AA BB CC` in
  it, and `hs_setup` then replaced it with the 8 request bytes. The OUT stage sent those, and
  the RX FIFO trace showed `e1 4b 40 01 00 00 ...`.
- **After:** the OUT payload has its own queue, `out_data`, which `hs_out` copies into
  `u_data` just before sending.
- **Test:** before: `FAIL: USB: vendor write data`. After: the vendor write and read-back pass.

## BUG-030 — A burst read of an RX FIFO could lose a byte

- **Where:** `src/pbe_host_spi.sv` with `src/tt_um_pbe.sv`.
- **Found by:** review, while making the USB firmware read faster. The host port latches the
  byte to send about 3 clocks after the previous byte, and pops when the byte has been sent.
  Suppose the FIFO was empty at the latch, and a byte arrives before the pop:
  - the host gets a stale value;
  - the pop removes the new byte;
  - so the byte is lost.

  Checking the RX-data pin between bytes cannot close that window.
- **After:** `RX_COUNT` registers (and `TX_COUNT`). The host reads the count, then bursts exactly
  that many bytes, which are all in the FIFO. `pbe_fifo` gained a `count` output.
- **Test:** not reproduced in simulation (the byte must land in a window of about 13 clocks).
  The fix is a protocol rule, documented in the register map and followed by the USB firmware
  model, which reads every record by count.

## BUG-031 — A FIFO flush on SETUP dropped the OUT record behind it

- **Where:** the USB firmware model (`test/tb_usb.sv`), and the host port's flush.
- **Cause:** on a SETUP the firmware flushed engine 0's FIFOs to drop a stale IN reply. The
  only flush (CTRL bits 7:6) empties TX *and* RX. A USB host sends the OUT data right after the
  SETUP's ACK, so that record was already arriving: the flush cut it, and the next read found
  `00 00 00 03 00 ab f4 f5 02`.
- **After:** `TX_FLUSH` (0x0E) empties only TX FIFOs; the firmware uses it.
  ```systemverilog
  reg_write(7'h0E, 8'h01);  // drop a stale reply; not the RX FIFO: an OUT may already be arriving
  ```
- **Test:**
  - Before: `FAIL: USB firmware: 9 bytes do not split into records`, `FAIL: USB: vendor write
    data`.
  - After: passes.

## BUG-032 — USB records had no length

- **Where:** `programs/usb_dev.pbe` and the firmware model.
- **Found by:** the first Test 11 run. The firmware drained the RX FIFO slowly, one byte per two
  host transactions, while the host model kept sending. Four records arrived in one read
  (`e1 4b 00 00 02 2d c3 84 06 ...`), and the firmware took them as one, so SET_ADDRESS was
  never answered. A data record's end (the status byte) cannot be found without its length.
- **After:**
  - The data loop counts bytes down in X, and a record ends `[255 − n] [status]`. The firmware
    parses from the end: a status byte is below 0x20, an ACK record is 0xD2.
  - The firmware reads by `RX_COUNT` in one burst.
  - The 3 words this cost came from removing a redundant first instruction and sharing one
    `PUSH` between the ACK record and the status.
  ```
  db:     IN   dm
          JLINE deop
          PUSH
          JMP  X--, db         ; X started at 255
  deop:   MOV  ISR, X
          PUSH                 ; 255 - number of bytes
  ```
- **Test:** before: `FAIL: USB: IN answered with 1 bytes, PID 5a`, `FAIL: USB: status stage is
  not a DATA1 ZLP`. After: Test 11 passes. A step in it holds the firmware while two records
  arrive, and checks they are split apart (`up to 2 at once`).

## BUG-033 — The idle line after a frame looked like a stuffing error

- **Where:** `src/pbe_line.sv`, receive side, modes without SE0.
- **Found by:** `tb_line.sv`, written before the coder ran. After an HDLC- or CAN-style frame
  the line rests at its idle level. To the receiver that is a run of equal bits with no stuff
  bit, so every good frame ended in a stuffing error.
- **Before:**
  ```systemverilog
  if (rstuff) begin
    rstuff <= 1'b0;
    if (r_bit != r_exp) err <= 1'b1;
  ```
- **After:** without pair mode, a stuffing violation at the idle level is the end of the frame
  (HDLC flag or abort, CAN end of frame); anywhere else it is still an error.
  ```systemverilog
  if (r_bit != r_exp) begin
    if (!pair && a_in) begin
      rs        <= R_IDLE;
      frame_end <= 1'b1;
    end else err <= 1'b1;
  end
  ```
- **Test:**
  - Before: `FAIL: CAN-style RX: stuff error on a good frame`, `FAIL: HDLC-style RX: stuff error
    on a good frame`.
  - After: `PASS: line coder`. The USB case, seven 1s in a packet, is still reported.

## BUG-034 — A pile-up test that could not pass

- **Where:** `test/tb_usb.sv`.
- **Cause:** to show that piled-up records can be split, the test held the firmware during two
  bad SETUPs. Two SETUP records are 28 bytes; the RX FIFO holds 16. So the engine stalled with a
  full FIFO, and the test failed (`records did not pile up (1 at most)`) on a limit it should
  have respected.
- **After:** the pile is two corrupted zero-length OUT records (6 bytes each). The design
  decision D42 now states the limit: the firmware must read a SETUP record before the next
  SETUP.
- **Test:** passes; `up to 2 at once`.

## BUG-035 — More Icarus Verilog 12 limits

- **Where:** `test/tb_line.sv`, `test/tb_usb.sv`, `test/tb_engine_ops.sv`.

  | Construct | Icarus | Workaround |
  |---|---|---|
  | A queue as a task argument | `vthread_get_rd_context_item` assertion | A module-level queue |
  | Bit-select of a queue element (`all[i][k]`) | "Array index expressions must be constant" | Copy the element to a variable first |
  | `return` in a task | "Cannot return from tasks" | A named block and `disable` |
  | Array ports on tasks; assigning a whole fixed array | "sorry: not yet supported" | Module-level queue |
  | A ternary on a queue in a port connection | internal error | A task that updates plain variables |
  | `always @*` reading a queue | not woken by queue changes | Update by hand after each change |
  | A declaration after a statement in a block | syntax error | Declarations first |
  | Declaration initializers in blocks (BUG-023) | warning | Caught twice more in new code; the lint step stops it |
- **Test:** all testbenches compile and run to `PASS`.

## BUG-036 — The gate-level regression job could not find the routed netlist

- **Where:** `.github/workflows/gds.yaml`, job `gl_regression`.
- **Found by:** its first run, after the first successful GDS build. It failed at "Install
  the PDK" after 17 seconds. The job log could not be read from this workspace (GitHub serves
  logs from a host the network policy blocks), so the cause was found from Tiny Tapeout's
  action code:
  - the `tt_submission` artifact is uploaded with `src/*`, `docs/*`, `tt_submission/*` and
    `info.yaml`, so it holds its own `tt_submission/` folder;
  - downloading it with `path: tt_submission` put `pdk.json` in
    `tt_submission/tt_submission/`;
  - `jq` failed inside `$(...)`, which an `echo` hides, so the step "passed" with an empty
    PDK name and the next step failed.
- **Before:**
  ```yaml
  with:
    name: tt_submission
    path: tt_submission
  ...
  echo "PDK=$(jq -r '.PDK' pdk.json)" >> $GITHUB_ENV
  ```
- **After:** download into the workspace root, as Tiny Tapeout's `gl_test` does, and fail at once
  if a value is missing:
  ```yaml
  with:
    name: tt_submission
  ...
  set -euo pipefail
  PDK=$(jq -er '.PDK' pdk.json)
  ```
- **Test:** the job's next run.

## BUG-037 — The gate-level regression stopped early; tb_pbe used a variable before declaring it

- **Where:** the gate-level regression job, and `pbe_v1/test/tb_pbe.sv`.
- **Found by:**
  - **Second run:** with BUG-036 fixed, the PDK installed, but `make test-gl` stopped with exit
    code 2 about 40 seconds in. The log could not be read from this workspace, and the
    annotation gave only the exit code.
  - **Third run:** the job by then used Tiny Tapeout's Icarus 13 and reported its output as an
    annotation. `tb_proto` and `tb_usb` **passed on the routed netlist**; `tb_pbe` did not
    compile:
    ```
    tb_pbe.sv:165: error: Could not find variable ``scl_stretched'' in ``tb_pbe''
    tb_pbe.sv:179:      : A symbol with that name was declared here. Check for declaration after use.
    ```
- **Cause:** the I2C peripheral model (line 165) sets `scl_stretched`, which was declared further
  down, with the SCL timing checks. Icarus 12 accepts that; Icarus 13 rightly refuses it. Whether
  the second run's failure had the same cause cannot be told now, because that run used Icarus 12
  and its output was lost.
- **Before:** `bit scl_stretched = 0, scl_after_stretch = 0;` after the model that uses it.
- **After:** the declaration moved above the model.
- **Other changes:**
  - **Same simulator:** the job uses the Icarus build Tiny Tapeout's `gl_test` uses.
  - **Readable failures:** on failure it writes the end of its output as an annotation, which
    the public API returns, and it always writes a pass/fail summary.
  - **Own workflow:** it moved to `gl_regression.yaml`, triggered by each `gds` run and by
    testbench changes, using the netlist of the latest `gds` run. So a fix needs minutes, not a
    2.5-hour rebuild.
- **Test:** `make test` (RTL, Icarus 12) passes, and the next `gl_regression` run compiles
  `tb_pbe` with Icarus 13.

## BUG-038 — 1-Wire: a full RX FIFO delayed the strong pull-up

- **Where:** `pbe_v1/programs/onewire_ctrl.pbe`, the end of a byte.
- **Found by:** review. After the last slot the program did `PUSH` and only then
  `JMP FLAG0, spu`. With the RX FIFO full, `PUSH` blocks until the host reads, so the strong
  pull-up came late or never; a parasite-powered DS18B20 needs it within 10 µs, or its
  conversion fails.
- **Before:**
  ```
          JMP  X--, bit        ; t=64: next slot starts at 65 us
          PUSH                 ; what was on the wire
          JMP  FLAG0, spu      ; FLAG0 set during this byte: strong pull-up
          JMP  idle
  ...
  spu:    PIN  dq, DRV1        ; t=67
          WAIT FLAG 0, LOW
  ```
- **After:** test FLAG0 first; the pull-up path drives DQ high, then pushes (36 words, was 35):
  ```
          JMP  X--, bit        ; t=64: next slot starts at 65 us
          JMP  FLAG0, spu      ; t=65: strong pull-up, before the PUSH
          PUSH                 ; what was on the wire
          JMP  idle
  ...
  spu:    PIN  dq, DRV1        ; t=66
          PUSH                 ; only now: a full RX FIFO must not delay the pull-up
          WAIT FLAG 0, LOW
  ```
- **Test (Test 4, `tb_pbe.sv`):** 6 read slots and a reset leave 7 bytes unread, MATCH ROM adds
  9: the RX FIFO is full (16). Then CONVERT T with FLAG0; the host reads nothing for 700 µs.
  The time from DQ's last rising edge to the start of the strong pull-up must be ≤ 10 µs, and
  the device model's conversion must succeed.
  - Before: `FAIL: 1-Wire: no strong pull-up after CONVERT T with the RX FIFO full`,
    `FAIL: 1-Wire: RX FIFO full: 0 conversions, 1 failed`.
  - After: passes; `strong pull-up 6.0 us after the last slot`.

## BUG-039 — Modbus RTU accepted a frame with a pause of more than 1.5 characters

- **Where:** `pbe_v1/programs/modbus_rtu.pbe` and its `TIMEOUT` setting.
- **Found by:** review. Inside a frame the program waited 3.5 characters for the next start
  bit, so a 2-character pause was accepted; Modbus over serial line §2.5.1.1 says such a frame
  must be discarded. The design decision is D47.
- **Before:** `TIMEOUT` = 3.5 characters + 9 (317 ticks; 1.75 ms above 19200 baud), and
  ```
  tmo:    JMP  FLAG0, fend     ; word 1: a timeout lands here. In a frame: frame complete
  ```
- **After:** `TIMEOUT` = 1.5 characters + 9 (141 ticks, any baud rate), and (62 words, was 56)
  ```
  tmo:    JMP  FLAG0, gap      ; word 1: a timeout lands here. In a frame: frame complete?
  ...
  gap:    SET  X, 87           ; 1.5 characters of silence so far: watch 2 more (88 x 2 ticks)
  gw:     JMP  PIN_LO, bad     ; a start bit: the frame is invalid
          JMP  X--, gw
  fend:   FLAG 0, CLR
  ...
  bad:    FLAG 3, SET          ; invalid frame: tell the host, receive nothing more
          SET  X, 153          ; until 3.5 characters of silence (154 x 2 ticks), then fend
          JMP  gw
  ```
  The testbench's `mb_config` sets the new `TIMEOUT`.
- **Test (Test 5, `tb_pbe.sv`):** the device model can pause before a response byte. Rounds 5
  and 6 pause 2 characters before byte 4 at 19200 and 115200 baud: FLAG3 must be set and only
  the 4 bytes before the pause received. Rounds 7 and 8 pause 1 character: a valid frame.
  - Before: `FAIL: Modbus round 5: frame reported valid`, `FAIL: Modbus round 6: frame reported
    valid` (with the new `TIMEOUT` and the old program, rounds 7 and 8 failed too: the old
    program ended the frame at 1.5 characters).
  - After: all 9 rounds and the RX overflow test pass.

## BUG-040 — USB: a packet with a stuffing error but intact data and CRC was ACKed

- **Where:** `src/pbe_engine.sv` (`STAT`, `JCRCBAD`, `CRCRST`), `pbe_v1/programs/usb_dev.pbe`.
- **Found by:** review. A stuff bit with the wrong value (a 1 where the stuffed 0 belongs) sets
  the line error, but the unstuffer drops the bit, so data and CRC arrive intact. `STAT` cleared
  the line error, and `JCRCBAD` looked only at the CRC: the packet was ACKed. The existing test
  left the stuffed bit out, which shifts the data, so the CRC caught it. Decision: D48.
- **Before:**
  ```systemverilog
                E_STAT: begin
                  isr      <= {3'b0, line_err, rx_ovf, tmo_seen, crc_ok, par_err};
                  par_in   <= 1'b0;
                  tmo_seen <= 1'b0;
                  line_err <= 1'b0;
                end
                E_JCRCBAD: if (!crc_ok) pc <= start_pc + {1'b0, arg[5:0]};
  ```
- **After:**
  ```systemverilog
                E_CRCRST:  if (!l_err) line_err <= 1'b0;  // an error in this very clock stays
                E_STAT: begin
                  isr      <= {3'b0, line_err, rx_ovf, tmo_seen, crc_ok, par_err};
                  par_in   <= 1'b0;
                  tmo_seen <= 1'b0;
                end
                E_JCRCBAD: if (!crc_ok || line_err) pc <= start_pc + {1'b0, arg[5:0]};
  ```
  In `usb_dev.pbe`, `CRCRST` moved to the start of `dat` (before the DATA PID; same word count),
  and the firmware model counts a record with status bit 4 as bad.
- **Test (Test 11, `tb_usb.sv`):** the host model's `h_bad_stuff = 2` sends the stuffed bit as a
  1. A SETUP sent that way must get no ACK, and the firmware must count 3 bad records.
  - Before: `FAIL: USB: device ACKed a packet with a wrong stuff bit (data and CRC intact)`,
    `FAIL: USB: firmware saw 2 bad records, expected 3` (and the ACKed junk SETUP then broke
    the rest of the enumeration).
  - After: passes.

## BUG-041 — USB: an IN packet whose ACK was lost was never sent again

- **Where:** the device firmware model in `pbe_v1/test/tb_usb.sv` (the host side of
  `usb_dev.pbe`).
- **Found by:** review. The engine pops the IN packet as it sends it. If the host's ACK is lost,
  the TX FIFO is empty and FLAG0 still set, so the next IN gets a NAK, forever. Decision: D49.
- **Before:** `fw_queue` wrote the packet to the TX FIFO and forgot it.
- **After:** the packet is kept in `fw_last` until its `[0xD2]` record; a 50 µs timer in the
  firmware loop queues it again (same DATA PID) when `TX_COUNT` = 0 and no ACK came for 100 µs:
  ```systemverilog
    if (fw_unacked) begin
      reg_read(7'h0C, cnt);  // TX_COUNT
      if (cnt != 0) fw_drained_at = 0;
      else if (fw_drained_at == 0) fw_drained_at = $realtime;
      else if ($realtime - fw_drained_at >= 100000 && !uo_out[1]) begin  // no record waiting
        fw_resends++;
        fw_put;
      end
    end
  ```
- **Test (Test 11):** `h_lose_ack` makes the host model skip its ACK once, in the first data
  stage of GET_DESCRIPTOR. The next IN must bring the same 8 bytes as DATA1, the firmware must
  have resent once, and the rest of the transfer (DATA0, DATA1, status) must complete.
  - Before: `FAIL: USB: after a lost ACK the device sent PID 5a (res 0), expected DATA1 again`
    (NAK after 200 tries), `FAIL: USB: firmware resent 0 packets, expected 1`.
  - After: passes.
- **Tool note:** Icarus 12 compiles `in_pkt == first` on two queues but aborts at run time
  (`vvp: vthread.cc: ... Assertion 'sig' failed`), and rejects `continue` in a `for` loop
  (`syntax error`). The tests compare element by element and use `if`/`else`, as BUG-024 did.

## BUG-042 — USB: a bus reset did not bring the address back to 0

- **Where:** the device firmware model in `pbe_v1/test/tb_usb.sv`.
- **Found by:** review. After SET_ADDRESS the program's words 6 and 9 hold the new address; a
  bus reset must return the device to address 0, but nothing watched for one. Decision: D49.
- **Before:** no bus-reset handling.
- **After:** the firmware timer polls `PINS`; SE0 on two reads 2.5 µs or more apart is a reset:
  ```systemverilog
    reg_read(7'h05, p);  // PINS: D- is pin 0, D+ pin 1
    if (p[1:0] == 2'b00) begin
      t = $realtime;
      reg_read(7'h05, p);
      if (p[1:0] == 2'b00 && $realtime - t >= 2500) begin
        if (!fw_in_reset) fw_bus_reset;
        fw_in_reset = 1;
      end
    end else fw_in_reset = 0;
  ```
  `fw_bus_reset` rewrites words 6 and 9 to `0x9000` and `0x9100`, clears FLAG0–2, flushes the TX
  FIFO and resets the firmware state.
- **Test (Test 11):** after SET_ADDRESS(0x15) and the rest of the enumeration, 10 ms of SE0;
  then GET_DESCRIPTOR at address 0 must return the 18-byte descriptor.
  - Before: `FAIL: USB: firmware saw 0 bus resets, expected 1`, `FAIL: USB: SETUP not ACKed`,
    `FAIL: USB: device descriptor at address 0 after a bus reset: 0 bytes`.
  - After: passes.

## BUG-043 — A bubble after every instruction broke the SPI peripheral at 2 MHz

- **Where:** `src/pbe_engine.sv`, the first design of the instruction register (D50).
- **Found by:** the timing review before it was written, then confirmed by running it as a
  mutation of the final design. The draft loaded `instr_q` from `pmem[pc]` every clock, with
  `pc` the current word, and marked it valid one clock after any change of `pc`. So every
  instruction took at least 2 clocks at CLKDIV 0. The SPI peripheral (D35) must get from the
  8th rising SCLK edge to `WAIT sclk, FALL` in a 12-clock half period. It needs 8 instructions
  for that, 8 clocks before and 16 in the draft.
- **Before (draft):**
  ```systemverilog
  if (exec) begin
    if (jump) iv <= 1'b0;
    else iv <= 1'b0;           // every instruction: fetch the next word first
  ...
  if (exec) pc_next = jump ? jump_pc : pc;  // (with pc + 1 applied on the fetch)
  ```
- **After:** `pc` is the word after the current instruction, so it is already read when the
  current one executes. Only a taken jump fetches.
  ```systemverilog
  if (exec) begin
    if (jump) iv <= 1'b0;
    else instr_q <= instr;     // the next word, already read at pc
  ...
  if (exec) pc_next = jump ? jump_pc : pc + 1'b1;
  ```
- **Test:**
  - Before: Test 9 `FAIL: SPI peripheral: MISO changed while SCLK was high`, `FAIL: SPI
    peripheral replies bc 52 ff, expected 3c a5 ff` and 7 more; `tb_fetch` fails 11 timing
    checks at CLKDIV 0. (USB still passed, at 3.19–3.35 bit times.)
  - After: `PASS` (Test 9 and `tb_fetch`).

## BUG-044 — Yosys merged the copies of the read address back into one register

- **Where:** `src/pbe_engine.sv`, the copies of `pc` that share out its fan-out (D50).
- **Found by:** counting flip-flops in a small test before using the copies: 7 instead of 28.
  The copies have the same D input, clock and reset, so `opt_merge` replaced them with one
  register. `(* keep *)` on the variable does not reach the flip-flop cells.
- **Before:**
  ```systemverilog
  (* keep *) logic [20:0] pc_copy;
  ...
  pc_copy <= {3{pc_next}};
  ```
- **After:** the attribute is on the `always_ff`, which Yosys passes on to the flip-flops it
  makes from it. `pc` is in the same block, so it is not merged with a copy either.
  ```systemverilog
  (* keep *)
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      pc      <= '0;
      pc_copy <= '0;
    end else begin
      pc      <= pc_next;
      pc_copy <= {3{pc_next}};
    end
  end
  ```
- **Test:** the small test gives 28 flip-flops; `make synth` gives 3,494 `dfrbpq` flip-flops,
  76 more than before D50 (17 + 21 per engine). Place and route keeps cells as Yosys leaves
  them, but the next routed run should be checked for four `pc` registers per engine.

## BUG-045 — Verilator rejects a default value on a module input

- **Where:** `src/pbe_engine.sv`, the new `pm_wr` input (D50).
- **Cause:** `tb_engine_restart` and `tb_engine_ops` connect the engine by port name and must
  stay unchanged, so `pm_wr` is unconnected there and reads z. In an expression z gives x, and
  an x in `iv` or `pc` would stop the engine. A default (`input logic pm_wr = 1'b0`) is legal
  SystemVerilog, and Icarus 12 and Yosys 0.33 accept it, but the CI lint does not:
  ```
  %Error-UNSUPPORTED: Unsupported: Default value on module input: 'a'
  ```
  (Verilator 5.020, the version Ubuntu 24.04 installs.)
- **Workaround:** `pm_wr` appears only in `if` conditions. There z (or the x it gives in
  `pm_wr && ...`) takes the `else` path, as no write. In the chip it is always driven.
  ```systemverilog
  if (pm_wr && !(exec && jump) && !tmo_hit) pc_next = (iv && !exec) ? pc - 1'b1 : pc;
  ...
  if (pm_wr) iv <= 1'b0;  // see pc_next
  ```
- **Test:** Verilator lint `-Wall` is clean; `tb_engine_restart` and `tb_engine_ops` pass
  unchanged.

## BUG-046 — Python simulator runner can return success after a failed cocotb test (tool/harness, fixed)

- **Where:** verification CLI runners using `cocotb_tools.runner` 2.0.1.
- **Evidence:** the initial line-model run had no HDL timescale and the bus-model run had a
  test-module import error; cocotb logged failures while the Python CLI returned zero.
- **Before:**
  ```python
  runner.test(hdl_toplevel=top, test_module=module)
  ```
- **After (verification only):** require an XML result containing tests and no failure/error;
  build with an explicit picosecond precision. The bus runner also removes stale results.
  ```python
  runner.build(..., timescale=('1ns', '1ps'))
  runner.test(..., results_xml=str(result_path))
  root = ET.parse(result_path).getroot()
  if not root.findall('.//testcase') or root.findall('.//failure') or root.findall('.//error'):
      raise SystemExit('simulation did not pass')
  ```
- **Regression:** `test/bus_models/run.py --stock-spi` reproduces an import failure. Before the
  check the CLI falsely returned zero; after it returns nonzero. Successful simulations still
  return zero. `test/differential/run.py` and `model/check_line_model.py` also validate results.
- **RTL:** unchanged.

## BUG-047 — Top model treated speculative empty-FIFO MISO as an integer and discarded unreset storage (model, fixed)

- **Where:** `pbe_v1/model/top_model.py`, `test/differential/test_diff.py`.
- **Evidence:** seed campaign `--seed 0x504245 --n 3 --cycles 2000`, seed 5259847,
  cycle 22298. After an RX read the host read pipeline speculatively loads the following
  byte. The FIFO may now be empty. Unwritten storage is undefined, and previously written
  storage persists across reset; resetting pointers does not reset the storage array.
- **Before:**
  ```python
  if old_load & 2: self.tx = rd_data  # None on unwritten storage
  def miso(self): return self.tx >> 7  # TypeError
  h = Harness(dut, seed + index)      # model storage lost between reset seeds
  ```
- **After (verification only):** retain known and unknown bits in the host shift register;
  compare an expected unknown MISO bit with the RTL's four-state value while comparing every
  other output bit normally. Carry FIFO backing memory between seed resets.
  ```python
  self.tx = 0 if rd_data is None else rd_data
  self.tx_unknown = 255 if rd_data is None else 0
  def miso(self):
      return None if self.tx_unknown & 128 else self.tx >> 7
  for fifo, memory in zip(h.model.tx + h.model.rx, retained_fifos):
      fifo.mem = list(memory)
  ```
- **Regression:** the saved campaign in `test/differential/regressions.json` failed before
  with `TypeError`, then with an incorrect unknown expectation when storage was discarded.
  After the model corrections the same campaign is required to complete and compare FIFOs,
  flags/status and all pin outputs. Empty data bytes outside a valid read are not interpreted
  as received payload.
- **RTL:** unchanged. This is an oracle/state-lifetime correction, not an RTL defect.

### BUG-047 additional API regressions

Independent review also reproduced the storage-lifetime defect via the public
`PBEModel.reset()` API. It rebuilt FIFO objects and discarded their backing
memory. The API now saves and restores the memory while clearing pointers.
`test_reset_preserves_unreset_backing_storage` fails before and passes after;
`test_host_prefetch_unknown_shift` independently checks unknown MISO and CS reset.
The harness preserves model memory between seed resets for the same reason.

## BUG-048 — Model decoded unspecified program RAM while stopped (model, fixed)

- **Where:** `pbe_v1/model/pbe_model.py`, found by independent model API review.
- **Before:** the second stopped clock of `PBEModel(); edge(); edge()` failed with
  `TypeError`: program RAM legitimately contained `None`, which was shifted during decode.
  ```python
  word = self.instr_q
  op, arg, delay = word >> 13, word >> 4 & 511, word & 15
  ```
- **After (model only):** preserve the unspecified instruction, use a placeholder only for
  inactive decoding, and explicitly reject attempting to execute an unspecified word.
  ```python
  unknown_instruction = self.instr_q is None
  word = 0xd800 if unknown_instruction else self.instr_q
  if unknown_instruction and execute:
      raise ValueError('uninitialized program instruction ...')
  ```
- **Regression:** `test_unwritten_program_is_harmless_while_stopped_and_rejected_when_run`
  fails before with TypeError, and passes after: stopped clocks have no side effects and
  starting the engine produces a descriptive error. See `model/ENGINE_FINDINGS.md`.
- **RTL:** unchanged. No NOP replaces an instruction that would actually execute.

## BUG-049 — Capture extractor lost the initial protocol edge (verification tool, fixed)

- **Before:** a USB packet could begin at the phase-marker timestamp. Reading VCD
  variable order as execution order, then using the first selected levels as the
  initial state, started the extracted file already in USB K. The first SOP was
  lost, and isolated valid SET_ADDRESS decoded as UNKNOWN. This was an extractor
  bug and is distinct from the unfixed full-trace decoder limitations below.
- **Code before** (`tools/sigrok_verify.py`, initial `crop_vcd`):

  ```python
  levels = selected[0][2]
  samples = {0: levels}
  for timestamp, _, values in selected:
      samples[(timestamp-start)//10_000] = values
  ```

- **Code after:** coalesce VCD updates per timestamp; preserve the preceding pin
  state and apply the first in-window event after a 1 us pre-roll:

  ```python
  grouped = {}
  for event in changes:
      grouped[event[0]] = event
  # read_vcd returns list(grouped.values())
  previous = [x for x in changes if x[0] < start]
  levels = previous[-1][2] if previous else selected[0][2]
  samples = {0: levels}
  for timestamp, _, values in selected:
      samples[(timestamp-start)//10_000+head_ns//10] = values
  ```

- **Fail-before/pass-after test:** `python3 -m unittest discover -s test -p
  test_sigrok_extract.py`. Both marker/edge file orders fail if initial levels are
  reverted to `selected[0][2]`; both pass now. Before-fix failure transcript is
  checked in as `evidence/phase2/crop_before_fix.txt`. Valid USB request windows
  then reconstruct all ten expected control requests with no state errors.

## BUG-050 — Stock USB request decoder cannot recover DATA RECEIVED (external tool, unfixed)

- **Version/component:** libsigrokdecode 0.5.3, `decoders/usb_request/pd.py`.
- **Code before** (unchanged third-party code):

  ```python
  if self.transaction_state == 'TOKEN RECEIVED':
      transaction_timeout = self.es_transaction
      transaction_timeout += int((self.es_transaction - self.ss_transaction) / 2)
      if ss > transaction_timeout:
          self.es_transaction = transaction_timeout
          self.handshake = 'timeout'
          self.handle_transfer()
          self.transaction_state = 'IDLE'
  if self.transaction_state != 'IDLE':
      # emits ERR and rejects the new token
      return
  ```

- **Code after:** unchanged; no third-party decoder or RTL fix was made. A proper
  external fix needs timeout/recovery for a data packet whose handshake never
  arrives, with timing validated against USB semantics. That is not a design
  modification authorized by this verification task.
- **Reproduction:** `python3 tools/sigrok_verify.py --vcd-dir test --output
  /tmp/pbe-sigrok-full --full-usb-request`. The full trace misses
  `00 05 15 00 00 00 00 00` after intentionally malformed traffic; isolated
  `usb_clean_address.vcd` reconstructs it, and full-trace `usb_packet` contains it.
- **Regression state:** intentionally still FAIL for the full-trace check; there
  is no claimed pass-after for an unfixed external tool. Before and after this
  verification change, design behavior is identical.

## BUG-051 — Stock USB request decoder counts unacknowledged retry twice (external tool, unfixed)

- **Version/component:** libsigrokdecode 0.5.3, `decoders/usb_request/pd.py`.
- **Code before** (unchanged third-party code):

  ```python
  elif request['type'] == 'SETUP IN' and self.transaction_type == 'IN':
      request['data'] += self.transaction_data
  ```

- **Code after:** unchanged; no third-party decoder or RTL fix was made. An
  external fix needs transfer/PID/ACK history to suppress duplicate retries,
  with valid retransmission and timeout regressions. The verification code
  keeps valid request windows and the full packet-level trace independently
  checked and exposes this request-layer comparison as a strict failing option.
- **Reproduction:** same full-trace command above. Two descriptor requests have
  expected lengths `[18, 18]`; stock decoder produces `[18, 26]`. The extra eight
  bytes are the duplicated DATA1 `12 01 10 01 ff 00 00 08`. The existing USB bench
  explicitly checks identical retransmission and reports PASS.
- **Regression state:** intentionally still FAIL for the full-trace check; no
  claimed pass-after exists for the unfixed external tool. See
  `evidence/phase2/full_results.json` and `full_usb_full_requests.stdout`.

### BUG-046 additional external-tool exit check

Stock sigrok-cli 0.7.2 can also return zero on a libusb initialization error in
this restricted environment, emitting no version or decoded annotations. The
verification driver now requires an actual version banner and nonempty decoder
output before comparisons. Before: exit status alone could count this as success.
After: `sigrok_verify.py` returns nonzero on empty output; running the offline
command where libusb initialization is allowed produces 22 real passing checks.
No decoder or system USB configuration was changed.
