#!/usr/bin/env python3
"""Assembler for the Programmable Bit Engine.

Usage:
    pbe_asm.py -o image.hex prog_a.pbe@0 prog_b.pbe@8

Each source is placed at the given word address (default 0). The output is a
64-line hex file (one 16-bit word per line, unused words are 0000) that can be
loaded with $readmemh or written to program memory over SPI.

Syntax (case-insensitive, ';' starts a comment):
    .equ name value           define a constant (handy for pin names)
    label:
    PIN  p, DRV0|DRV1|REL|TOG|OUT|OUTOD
    IN   p
    WAIT p, LOW|HIGH|RISE|FALL
    WAIT FLAG n, LOW|HIGH|RISE|FALL
    JMP  [ALWAYS|X--|PIN_HI|PIN_LO|TX_EMPTY|TX_READY|FLAG0|FLAG1,] label
    SET  X|OSR, value
    PULL | PUSH
    FLAG n, SET|CLR|IRQ
    NOP
    USB (version 2): UTX [NOCRC] | URX label | UEOP | CRC | OSRCRC LO|HI | STAT | UIDLE | JCRCBAD label
Any instruction may end with [d], d = 0..15 extra ticks of delay.
"""
import argparse
import re
import sys

MEM_WORDS = 64

OPS = {"PIN": 0, "IN": 1, "WAIT": 2, "JMP": 3, "SET": 4, "PULL": 5, "PUSH": 5, "FLAG": 6, "NOP": 6}
USB_OPS = {"UTX": 0, "URX": 1, "UEOP": 2, "CRC": 3, "OSRCRC": 4, "STAT": 5, "UIDLE": 6, "JCRCBAD": 7}
PIN_ACT = {"DRV0": 0, "DRV1": 1, "REL": 2, "TOG": 3, "OUT": 4, "OUTOD": 5}
WAIT_CND = {"LOW": 0, "HIGH": 1, "RISE": 2, "FALL": 3}
JMP_CND = {"ALWAYS": 0, "X--": 1, "PIN_HI": 2, "PIN_LO": 3, "TX_EMPTY": 4, "TX_READY": 5, "FLAG0": 6, "FLAG1": 7}
FLAG_ACT = {"SET": 0, "CLR": 1, "IRQ": 2}


class AsmError(Exception):
    pass


def word(op, arg, dly):
    return (op << 13) | ((arg & 0x1FF) << 4) | (dly & 0xF)


def assemble(text, base, name="<src>"):
    """Return (list of words, dict of labels with absolute addresses)."""
    equ, labels, lines = {}, {}, []
    pc = base
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
        if mnem not in OPS and mnem not in USB_OPS:
            raise AsmError(f"{name}:{n}: unknown instruction '{parts[0]}'")
        op = OPS.get(mnem, 7)

        def need(k):
            if len(args) != k:
                raise AsmError(f"{name}:{n}: {mnem} takes {k} argument(s)")

        def target(tok):
            t = tok.lower()
            return labels[t] if t in labels else num(tok, n, 0, MEM_WORDS - 1)

        if mnem in USB_OPS:
            sub = USB_OPS[mnem] << 6
            if mnem == "UTX":
                if args and args != ["NOCRC"] and [a.upper() for a in args] != ["NOCRC"]:
                    raise AsmError(f"{name}:{n}: UTX takes nothing or NOCRC")
                arg = sub | (1 if args else 0)
            elif mnem in ("URX", "JCRCBAD"):
                need(1)
                arg = sub | target(args[0])
            elif mnem == "OSRCRC":
                need(1)
                arg = sub | pick({"LO": 0, "HI": 1}, args[0], n, "CRC byte")
            else:
                need(0)
                arg = sub
        elif mnem == "PIN":
            need(2)
            arg = (num(args[0], n, 0, 7) << 6) | (pick(PIN_ACT, args[1], n, "pin action") << 3)
        elif mnem == "IN":
            need(1)
            arg = num(args[0], n, 0, 7) << 6
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
                cnd, dest_tok = 0, args[0]
            else:
                need(2)
                cnd, dest_tok = pick(JMP_CND, args[0], n, "jump condition"), args[1]
            arg = (cnd << 6) | target(dest_tok)
        elif mnem == "SET":
            need(2)
            dst = args[0].upper()
            if dst not in ("X", "OSR"):
                raise AsmError(f"{name}:{n}: SET target must be X or OSR")
            arg = ((1 << 8) if dst == "OSR" else 0) | num(args[1], n, 0, 255)
        elif mnem in ("PULL", "PUSH"):
            need(0)
            arg = (1 << 8) if mnem == "PUSH" else 0
        elif mnem == "FLAG":
            need(2)
            arg = (pick(FLAG_ACT, args[1], n, "flag action") << 7) | num(args[0], n, 0, 3)
        else:  # NOP: FLAG with action 3, which does nothing (opcode 111 is USB in v2)
            need(0)
            arg = 3 << 7
        words.append(word(op, arg, dly))
    return words, labels


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("sources", nargs="+", help="file.pbe[@address]")
    ap.add_argument("-o", "--output", required=True)
    a = ap.parse_args()

    image = [None] * MEM_WORDS
    try:
        for spec in a.sources:
            path, _, at = spec.partition("@")
            base = int(at, 0) if at else 0
            with open(path) as f:
                words, labels = assemble(f.read(), base, path)
            if base + len(words) > MEM_WORDS:
                raise AsmError(f"{path}: {len(words)} words at {base} does not fit in {MEM_WORDS}")
            for i, w in enumerate(words):
                if image[base + i] is not None:
                    raise AsmError(f"{path}: overlaps another program at word {base + i}")
                image[base + i] = w
            print(f"{path}: {len(words)} words at {base}..{base + len(words) - 1}")
    except AsmError as e:
        sys.exit(f"error: {e}")

    with open(a.output, "w") as f:
        for w in image:
            f.write(f"{(w or 0):04x}\n")


if __name__ == "__main__":
    main()
