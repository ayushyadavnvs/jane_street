#!/usr/bin/env python3
"""Assembler for the Programmable Bit Engine.

Usage:
    pbe_asm.py -o image.hex prog_a.pbe@0:0 prog_b.pbe@1:200

Each engine has its own 256-word program memory (D82). A source is placed in engine E's memory
at word W with @E:W (@W alone means engine 0; no @ means engine 0, word 0). Jump targets are
relative to the program's own start, so the engine running it must have START_PC = W.
The output is a 512-line hex file (one 16-bit word per line, unused words are 0000): lines 0-255
are engine 0's memory, lines 256-511 engine 1's. It can be loaded with $readmemh, and is written
to the program memories over SPI by selecting each engine with PM_ADDR_H (pbe_v1/README.md).

Syntax (case-insensitive, ';' starts a comment):
    .equ name value           define a constant (handy for pin names)
    label:
    PIN  p, DRV0|DRV1|REL|TOG|OUT|OUTOD|OUTPAR   (OUT and OUTOD take an optional ", NOCRC")
    PIN  p, END               line coder: end the frame (pair mode: EOP, then release)
    IN   p [, NOCRC]
    WAIT p, LOW|HIGH|RISE|FALL
    WAIT FLAG n, LOW|HIGH|RISE|FALL
    JMP  [ALWAYS|X--|PIN_HI|PIN_LO|TX_EMPTY|TX_READY|FLAG0|FLAG1,] label
    SET  X|OSR, value
    PULL [NOWAIT] | PUSH      NOWAIT: an empty TX FIFO gives 0xFF instead of waiting
    MARK | REWIND             hold the TX FIFO read position / read again from it (D70)
    FLAG n, SET|CLR|IRQ
    NOP
    MOV  X|OSR|ISR, X|OSR|ISR|0                      (FLAG action 3 with a non-zero move)
    CRCRST | OSRCRC LO|HI [, INV] [, LEFT] | STAT | JCRCBAD label     (opcode 111)
                              LEFT: the CRC left-justified to 16 bits (CRC-15: bits 14..7 high)
    JEQ label | JNE label     jump if ISR == OSR / ISR != OSR    (opcode 111)
    JLINE label               jump if the line coder saw the end of a frame; clears it
    LINECTL W1..W8 [, ARB]    bit-synchronous coder: unit width, arbitration window on (D67)
    LINECTL STUFFOFF|STUFFON|ERROR [, ...]   stuffing off / on, start an error flag
Any instruction may end with [d], d = 0..15 extra ticks of delay.
"""
import argparse
import re
import sys

ENGINES = 2
MEM_WORDS = 256   # each engine's program memory
PROG_WORDS = 64   # one program: jump targets are 6 bits, relative to its start

OPS = {"PIN": 0, "IN": 1, "WAIT": 2, "JMP": 3, "SET": 4, "PULL": 5, "PUSH": 5, "MARK": 5, "REWIND": 5,
       "FLAG": 6, "NOP": 6, "MOV": 6}
PIN_ACT = {"DRV0": 0, "DRV1": 1, "REL": 2, "TOG": 3, "OUT": 4, "OUTOD": 5, "OUTPAR": 6, "END": 7}
EXT_OPS = {"CRCRST": 0, "OSRCRC": 1, "STAT": 2, "JCRCBAD": 3, "JEQ": 4, "JNE": 5, "JLINE": 6, "LINECTL": 7}
LINECTL_ACT = {"STUFFOFF": 1, "STUFFON": 2, "ERROR": 4}
MOV_REG = {"X": 1, "OSR": 2, "ISR": 3}
WAIT_CND = {"LOW": 0, "HIGH": 1, "RISE": 2, "FALL": 3}
JMP_CND = {"ALWAYS": 0, "X--": 1, "PIN_HI": 2, "PIN_LO": 3, "TX_EMPTY": 4, "TX_READY": 5, "FLAG0": 6, "FLAG1": 7}
FLAG_ACT = {"SET": 0, "CLR": 1, "IRQ": 2}


class AsmError(Exception):
    pass


def word(op, arg, dly):
    return (op << 13) | ((arg & 0x1FF) << 4) | (dly & 0xF)


def assemble(text, base, name="<src>"):
    """Return (list of words, dict of labels). Labels are relative to the program start;
    base only matters for error messages."""
    equ, labels, lines = {}, {}, []
    pc = 0
    # pass 1: labels and constants
    for n, raw in enumerate(text.splitlines(), 1):
        line = raw.split(";", 1)[0].strip()
        if not line:
            continue
        m = re.match(r"\.equ\s+(\w+)\s+(\S+)$", line, re.I)
        if m:
            equ[m.group(1).lower()] = int(m.group(2), 0)
            continue
        while True:
            m = re.match(r"(\w+):\s*(.*)$", line)
            if not m:
                break
            labels[m.group(1).lower()] = pc
            line = m.group(2).strip()
        if line:
            lines.append((n, line, pc))
            pc += 1

    def num(tok, n, lo, hi):
        t = tok.lower()
        if t in equ:
            v = equ[t]
        else:
            try:
                v = int(tok, 0)
            except ValueError:
                raise AsmError(f"{name}:{n}: expected a number, got '{tok}'")
        if not lo <= v <= hi:
            raise AsmError(f"{name}:{n}: {v} out of range {lo}..{hi}")
        return v

    def pick(table, tok, n, what):
        try:
            return table[tok.upper()]
        except KeyError:
            raise AsmError(f"{name}:{n}: unknown {what} '{tok}' (expected {', '.join(table)})")

    words = []
    for n, line, addr in lines:
        dly = 0
        m = re.search(r"\[\s*(\w+)\s*\]$", line)
        if m:
            dly = num(m.group(1), n, 0, 15)
            line = line[: m.start()].strip()
        parts = line.split(None, 1)
        mnem = parts[0].upper()
        args = [a.strip() for a in parts[1].split(",")] if len(parts) > 1 else []
        if mnem not in OPS and mnem not in EXT_OPS:
            raise AsmError(f"{name}:{n}: unknown instruction '{parts[0]}'")
        op = OPS.get(mnem, 7)

        def need(k):
            if len(args) != k:
                raise AsmError(f"{name}:{n}: {mnem} takes {k} argument(s)")

        nocrc = len(args) > 0 and args[-1].upper() == "NOCRC"
        if nocrc:
            args = args[:-1]
        if nocrc and not (mnem == "IN" or (mnem == "PIN" and len(args) == 2 and args[1].upper() in ("OUT", "OUTOD"))):
            raise AsmError(f"{name}:{n}: NOCRC only applies to OUT, OUTOD and IN")

        if mnem in EXT_OPS:
            sub = EXT_OPS[mnem] << 6
            if mnem == "OSRCRC":
                mods = [a.upper() for a in args[1:]]
                for m_ in mods:
                    if m_ not in ("INV", "LEFT"):
                        raise AsmError(f"{name}:{n}: OSRCRC takes INV and LEFT, got '{m_}'")
                args = args[:1]
                need(1)
                arg = (sub | (int("LEFT" in mods) << 2) | (int("INV" in mods) << 1)
                       | pick({"LO": 0, "HI": 1}, args[0], n, "CRC byte"))
            elif mnem == "LINECTL":
                if not args:
                    raise AsmError(f"{name}:{n}: LINECTL needs a width (W1..W8) or actions")
                m_ = re.fullmatch(r"W([1-8])", args[0].upper())
                if m_:
                    rest = [a.upper() for a in args[1:]]
                    if rest not in ([], ["ARB"]):
                        raise AsmError(f"{name}:{n}: LINECTL W<n> takes only ARB")
                    arg = sub | (int(m_.group(1)) - 1) | (int(bool(rest)) << 3)
                else:
                    acts = 0
                    for a in args:
                        acts |= pick(LINECTL_ACT, a, n, "LINECTL action")
                    arg = sub | (1 << 4) | acts
            elif mnem in ("JCRCBAD", "JEQ", "JNE", "JLINE"):
                need(1)
                t = args[0].lower()
                arg = sub | (labels[t] if t in labels else num(args[0], n, 0, PROG_WORDS - 1))
            else:
                need(0)
                arg = sub
        elif mnem == "PIN":
            need(2)
            arg = (num(args[0], n, 0, 7) << 6) | (pick(PIN_ACT, args[1], n, "pin action") << 3) | int(nocrc)
        elif mnem == "IN":
            need(1)
            arg = (num(args[0], n, 0, 7) << 6) | (int(nocrc) << 5)
        elif mnem == "WAIT":
            need(2)
            src = args[0].split()
            if src[0].upper() == "FLAG":
                arg = (num(src[1], n, 0, 3) << 6) | (1 << 5)
            else:
                arg = num(args[0], n, 0, 7) << 6
            arg |= pick(WAIT_CND, args[1], n, "wait condition") << 3
        elif mnem == "JMP":
            if len(args) == 1:
                cnd, target = 0, args[0]
            else:
                need(2)
                cnd, target = pick(JMP_CND, args[0], n, "jump condition"), args[1]
            t = target.lower()
            if t in labels:
                dest = labels[t]
            else:
                dest = num(target, n, 0, PROG_WORDS - 1)
            arg = (cnd << 6) | dest
        elif mnem == "SET":
            need(2)
            dst = args[0].upper()
            if dst not in ("X", "OSR"):
                raise AsmError(f"{name}:{n}: SET target must be X or OSR")
            arg = ((1 << 8) if dst == "OSR" else 0) | num(args[1], n, 0, 255)
        elif mnem == "PULL":
            if args and args[0].upper() == "NOWAIT":
                args = args[1:]
                arg = 1 << 6
            else:
                arg = 0
            need(0)
        elif mnem in ("PUSH", "MARK", "REWIND"):
            need(0)
            arg = {"PUSH": 1 << 8, "MARK": 2 << 6, "REWIND": 3 << 6}[mnem]
        elif mnem == "MOV":
            need(2)
            dst = pick(MOV_REG, args[0], n, "MOV destination")
            src = 0 if args[1] == "0" else pick(MOV_REG, args[1], n, "MOV source")
            arg = (3 << 7) | (dst << 4) | (src << 2)
        elif mnem == "FLAG":
            need(2)
            arg = (pick(FLAG_ACT, args[1], n, "flag action") << 7) | num(args[0], n, 0, 3)
        else:  # NOP: FLAG with action 3 and no move, which does nothing
            need(0)
            arg = 3 << 7
        words.append(word(op, arg, dly))
    return words, labels


def parse_spec(spec):
    """file.pbe[@[engine:]word] -> (path, engine, word)."""
    path, _, at = spec.rpartition("@") if "@" in spec else (spec, "", "")
    engine, _, w = at.rpartition(":")
    try:
        engine = int(engine, 0) if engine else 0
        base = int(w, 0) if w else 0
    except ValueError:
        raise AsmError(f"{spec}: the placement must be @word or @engine:word")
    if not 0 <= engine < ENGINES:
        raise AsmError(f"{spec}: engine must be 0..{ENGINES - 1}")
    if not 0 <= base < MEM_WORDS:
        raise AsmError(f"{spec}: word must be 0..{MEM_WORDS - 1}")
    return path, engine, base


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("sources", nargs="+", help="file.pbe[@[engine:]word]")
    ap.add_argument("-o", "--output", required=True)
    a = ap.parse_args()

    image = [None] * (ENGINES * MEM_WORDS)
    try:
        for spec in a.sources:
            path, engine, base = parse_spec(spec)
            with open(path) as f:
                words, labels = assemble(f.read(), base, path)
            if len(words) > PROG_WORDS:
                raise AsmError(f"{path}: {len(words)} words; a program can be at most {PROG_WORDS}")
            if base + len(words) > MEM_WORDS:
                raise AsmError(f"{path}: {len(words)} words at {base} does not fit in {MEM_WORDS}")
            for i, w in enumerate(words):
                at = engine * MEM_WORDS + base + i
                if image[at] is not None:
                    raise AsmError(f"{path}: overlaps another program at engine {engine} word {base + i}")
                image[at] = w
            print(f"{path}: {len(words)} words in engine {engine} at {base}..{base + len(words) - 1}")
    except AsmError as e:
        sys.exit(f"error: {e}")

    with open(a.output, "w") as f:
        for w in image:
            f.write(f"{(w or 0):04x}\n")


if __name__ == "__main__":
    main()
