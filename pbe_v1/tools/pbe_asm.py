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
    .org n                    continue at program word n (0..255), filling the gap with NOP
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
    PAGE p                    the next instruction's jump goes to page p (0..3) (D83)
Any instruction may end with [d], d = 0..15 extra ticks of delay.

Pages (D83): a program may be up to 256 words, four pages of 64. A jump's target is 6 bits in
the page of the jump itself; for a label in another page the assembler inserts PAGE p just
before the jump and reports it (`PAGE p inserted at word w`). The inserted word takes the
jump's labels, and is one more instruction: (DLY + 1) ticks, DLY 0. With --no-auto-page such a
jump is an error instead. An explicit PAGE before a jump is checked against the jump's target.
The timeout vector (TIMEOUT_PC) is always in page 0.
"""
import argparse
import re
import sys

ENGINES = 2
MEM_WORDS = 256   # each engine's program memory
PAGE_WORDS = 64   # a jump's 6-bit target reaches a 64-word page; PAGE p picks another (D83)

OPS = {"PIN": 0, "IN": 1, "WAIT": 2, "JMP": 3, "SET": 4, "PULL": 5, "PUSH": 5, "MARK": 5, "REWIND": 5,
       "FLAG": 6, "NOP": 6, "MOV": 6}
PIN_ACT = {"DRV0": 0, "DRV1": 1, "REL": 2, "TOG": 3, "OUT": 4, "OUTOD": 5, "OUTPAR": 6, "END": 7}
EXT_OPS = {"CRCRST": 0, "OSRCRC": 1, "STAT": 2, "JCRCBAD": 3, "JEQ": 4, "JNE": 5, "JLINE": 6, "LINECTL": 7,
           "PAGE": 7}
LINECTL_ACT = {"STUFFOFF": 1, "STUFFON": 2, "ERROR": 4}
MOV_REG = {"X": 1, "OSR": 2, "ISR": 3}
WAIT_CND = {"LOW": 0, "HIGH": 1, "RISE": 2, "FALL": 3}
JMP_CND = {"ALWAYS": 0, "X--": 1, "PIN_HI": 2, "PIN_LO": 3, "TX_EMPTY": 4, "TX_READY": 5, "FLAG0": 6, "FLAG1": 7}
FLAG_ACT = {"SET": 0, "CLR": 1, "IRQ": 2}


class AsmError(Exception):
    pass


def word(op, arg, dly):
    return (op << 13) | ((arg & 0x1FF) << 4) | (dly & 0xF)


JUMPS = ("JMP", "JCRCBAD", "JEQ", "JNE", "JLINE")


def split_line(line):
    """'MNEM a, b [d]' -> (MNEM, [a, b], delay token or None)."""
    dly = None
    m = re.search(r"\[\s*(\w+)\s*\]$", line)
    if m:
        dly = m.group(1)
        line = line[: m.start()].strip()
    parts = line.split(None, 1)
    args = [a.strip() for a in parts[1].split(",")] if len(parts) > 1 else []
    return parts[0].upper(), args, dly


def assemble(text, base, name="<src>", auto_page=True):
    """Return (list of words, dict of labels, list of inserted PAGE words). Labels are relative
    to the program start (0..255); base only matters for error messages.

    A program may use its engine's whole 256-word memory (D83). A jump reaches the 64-word page
    of the program it is in; a jump to a label in another page needs a PAGE prefix, which the
    assembler inserts just before the jump (it takes the jump's labels, so jumps to the jump
    also run it). Each inserted PAGE is one more instruction: it costs (DLY + 1) ticks like any
    other, with DLY 0. With auto_page=False such a jump is an error instead."""
    equ, labels, items = {}, {}, []
    pending = []
    # pass 1: constants, and each instruction with the labels in front of it
    for n, raw in enumerate(text.splitlines(), 1):
        line = raw.split(";", 1)[0].strip()
        if not line:
            continue
        m = re.match(r"\.equ\s+(\w+)\s+(\S+)$", line, re.I)
        if m:
            equ[m.group(1).lower()] = int(m.group(2), 0)
            continue
        m = re.match(r"\.org\s+(\S+)$", line, re.I)
        if m:
            items.append((n, ".org " + m.group(1), []))
            continue
        while True:
            m = re.match(r"(\w+):\s*(.*)$", line)
            if not m:
                break
            pending.append(m.group(1).lower())
            line = m.group(2).strip()
        if line:
            items.append((n, line, pending))
            pending = []

    def org_of(line):
        if not line.startswith(".org "):
            return None
        tok = line[5:].strip()
        v = equ.get(tok.lower())
        return v if v is not None else int(tok, 0)

    def target_of(line):
        if line.startswith(".org "):
            return None
        mnem, args, _ = split_line(line)
        if mnem not in JUMPS or not args:
            return None
        return args[-1]

    def resolve(tok, n):
        t = tok.lower()
        if t in labels:
            return labels[t]
        if t in equ:
            return equ[t]
        try:
            return int(tok, 0)
        except ValueError:
            raise AsmError(f"{name}:{n}: unknown label '{tok}'")

    # pass 2: addresses, inserting PAGE before jumps to another 64-word page until nothing
    # changes (an inserted word can move a label into another page; insertions only grow)
    paged = set()
    while True:
        labels.clear()
        addr, iaddr = 0, []
        for i, (n, line, names) in enumerate(items):
            org = org_of(line)
            if org is not None:
                if org < addr:
                    raise AsmError(f"{name}:{n}: .org {org} is behind word {addr}")
                addr = org
                iaddr.append(addr)
                continue
            for nm in names:
                labels[nm] = addr
            if i in paged:
                addr += 1
            iaddr.append(addr)
            addr += 1
        for nm in pending:  # labels after the last instruction
            labels[nm] = addr
        grew = False
        for i, (n, line, names) in enumerate(items):
            tok = target_of(line)
            if tok is None or i in paged:
                continue
            dest = resolve(tok, n)
            if not 0 <= dest < MEM_WORDS:
                raise AsmError(f"{name}:{n}: jump target {dest} out of range 0..{MEM_WORDS - 1}")
            explicit = i > 0 and not items[i - 1][1].startswith(".org ") and split_line(items[i - 1][1])[0] == "PAGE"
            if dest >> 6 != iaddr[i] >> 6 and not explicit:
                if not auto_page:
                    raise AsmError(f"{name}:{n}: jump to {tok} (word {dest}, page {dest >> 6}) from "
                                   f"page {iaddr[i] >> 6} needs a PAGE {dest >> 6} before it")
                paged.add(i)
                grew = True
        if not grew:
            break
    lines = [(n, line, iaddr[i]) for i, (n, line, names) in enumerate(items)]
    NOP = word(6, 3 << 7, 0)

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

    words, inserted = [], []
    for i, (n, line, addr) in enumerate(lines):
        if org_of(line) is not None:  # .org: NOPs up to the given word
            words.extend([NOP] * (addr - len(words)))
            continue
        if i in paged:
            dest = resolve(target_of(line), n)
            inserted.append((addr - 1, dest >> 6, n))
            words.append(word(7, (EXT_OPS["PAGE"] << 6) | (1 << 5) | (dest >> 6), 0))
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
                arg = sub | (resolve(args[0], n) & 63)  # the page: the jump's own or a PAGE's
            elif mnem == "PAGE":
                need(1)
                p_ = num(args[0], n, 0, MEM_WORDS // 64 - 1)
                if i + 1 < len(lines) and target_of(lines[i + 1][1]) is not None:
                    tok = target_of(lines[i + 1][1])
                    if tok is not None and resolve(tok, n) >> 6 != p_:
                        raise AsmError(f"{name}:{n}: PAGE {p_} before a jump to {tok} "
                                       f"(page {resolve(tok, n) >> 6})")
                arg = sub | (1 << 5) | p_
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
            arg = (cnd << 6) | (resolve(target, n) & 63)  # the page: the jump's own or a PAGE's
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
    return words, labels, inserted


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
    ap.add_argument("--no-auto-page", action="store_true",
                    help="a jump to another 64-word page without an explicit PAGE is an error")
    a = ap.parse_args()

    image = [None] * (ENGINES * MEM_WORDS)
    try:
        for spec in a.sources:
            path, engine, base = parse_spec(spec)
            with open(path) as f:
                words, labels, inserted = assemble(f.read(), base, path, auto_page=not a.no_auto_page)
            for at, page, n in inserted:
                print(f"{path}:{n}: PAGE {page} inserted at word {at} (one more instruction time)")
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
