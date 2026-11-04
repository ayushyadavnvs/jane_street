"""Classic CAN (CAN 2.0A) bit-stream model, written from ISO 11898-1 and the pbe_bsync /
LINECTL specification text (src/pbe_bsync.sv header, D66-D68), not from the RTL.

Frame: SOF, 11-bit ID, RTR, IDE = 0, r0 = 0, DLC (4), data (min(DLC, 8) bytes, none for a
remote frame), CRC-15 (x^15+x^14+x^10+x^8+x^7+x^4+x^3+1, init 0) over SOF..data; bit
stuffing (a complement bit after 5 equal bits) from SOF to the end of the CRC; then CRC
delimiter (1), ACK slot, ACK delimiter (1), 7 EOF bits (1).
"""


def crc15(bits):
    crc = 0
    for b in bits:
        fb = b ^ (crc >> 14 & 1)
        crc = (crc << 1) & 0x7FFF
        if fb:
            crc ^= 0x4599
    return crc


def frame_bits(fid, rtr, dlc, data):
    """The destuffed bits from SOF to the last CRC bit."""
    bits = [0] + [fid >> i & 1 for i in range(10, -1, -1)] + [rtr, 0, 0]
    bits += [dlc >> i & 1 for i in range(3, -1, -1)]
    for byte in ([] if rtr else data[:min(dlc, 8)]):
        bits += [byte >> i & 1 for i in range(7, -1, -1)]
    c = crc15(bits)
    return bits + [c >> i & 1 for i in range(14, -1, -1)]


def stuff(bits):
    """Line levels for the stuffed region, and for each the destuffed index (None = stuff)."""
    line, index, run, last = [], [], 0, None
    for i, b in enumerate(bits):
        line.append(b)
        index.append(i)
        run = run + 1 if b == last else 1
        last = b
        if run == 5:
            line.append(1 - b)
            index.append(None)
            last, run = 1 - b, 1
    return line, index


def destuff(line):
    """Destuffed bits of a stuffed line; raises ValueError on a stuff error."""
    out, run, last, expect_stuff = [], 0, None, False
    for b in line:
        if expect_stuff:
            if b == last:
                raise ValueError('stuff error')
            last, run, expect_stuff = b, 1, False
            continue
        out.append(b)
        run = run + 1 if b == last else 1
        last = b
        expect_stuff = run == 5
    return out


def units(bits, widths):
    """Split destuffed bits into IN units (MSB first, right-justified), widths in order."""
    out, i = [], 0
    for w in widths:
        if i + w > len(bits):
            break
        v = 0
        for b in bits[i:i + w]:
            v = v << 1 | b
        out.append(v)
        i += w
    return out


TAIL = 10   # CRC delimiter, ACK slot, ACK delimiter, 7 EOF bits
