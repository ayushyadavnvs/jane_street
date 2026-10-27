# Bug log

Every bug found in the design, the tests or the tools: what was wrong (with the code before),
how it was found, the fix (with the code after), and the test that now guards it.

Keep this file current: add an entry for every bug, including test and tool bugs, and never
delete an entry. Where possible, a bug gets a test that fails before the fix and passes
after it.

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

