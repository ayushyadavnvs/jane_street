# Round 2: independent CRC catalogue vectors

The unchanged **real `pbe_crc` RTL** passes 22 distinct configurations spanning
widths 3–16 against fixed [CRC RevEng catalogue](https://reveng.sourceforge.io/crc-catalogue/all.htm)
check/residue records and the independent `crccheck==1.3.1` implementation.
The suite includes USB CRC5/CRC16, Modbus CRC16, 1-Wire CRC8 and inverted CRC16,
and SMBus PEC CRC8, plus 16 additional configurations. Three more catalogue
entries are explicitly unsupported because their arbitrary initial seed cannot
be loaded by the unit; they are not counted as RTL passes.

## Running and scope

From `pbe_v1/`:

```sh
../.venv/bin/python -m pip install -r ../verify/vectors/crc/requirements.txt
../.venv/bin/python ../verify/vectors/crc/run.py
# Longer reproducible payload sweep:
../.venv/bin/python ../verify/vectors/crc/run.py --seed 0x435243 --random-cases 100
```

Dependencies are pinned. No target installs packages automatically. The runner
builds only `src/pbe_crc.sv` under Icarus, drives its public ports, and checks the
cocotb result XML so absent/failing tests return nonzero. It uses a 20,832 ps
even clock period and no internal RTL peeks or PBE golden-model imports.
This validates the CRC primitive; full engine/program integration remains covered
by the existing engine/protocol suites, not claimed by this direct-unit test.

Default seed `0x435243` gives, per supported configuration: `123456789`, an empty
payload and eight random payloads of 0–32 bytes. The independent library's raw
state is checked after every byte; idle clocks must preserve state; unused width
bits must remain zero; init wins over simultaneous step. Every payload's full
CRC field is then appended **without byte padding**, checking the catalogue
residue and the raw `CRC_GOOD` comparator. Wrong comparator values must reject.
One extra standard-payload codeword per configuration has a transmitted CRC bit
flipped and must fail `ok`. This is 220 valid payload/codeword cases plus 22
corrupted-codeword cases.

## Representations kept distinct

The unit consumes bits in wire order and shifts left using the catalogue's
normal polynomial. `refin` means feed each payload byte LSB first; otherwise feed
MSB first. `out_rev=refout` selects whether the numeric output is reflected.
The published check is `value XOR xorout`, masked to the configured width.
The final XOR is an explicit test-side output transformation; `pbe_crc` itself
has no xorout register.

For each completed codeword the catalogue residue is compared to the unit's
output **before xorout**. The hardware `good` input instead compares the raw,
unreflected register, so `good=reflect(residue,width)` when refout is true.
USB therefore correctly has catalogue residue **B001** and raw `CRC_GOOD`
**800D**; USB CRC5 similarly has catalogue residue **06**, raw good **0C**.
These differing representations are not a CRC defect.

Input and output reflection are independent settings; the selected
CRC-12/UMTS case explicitly exercises `refin=false, refout=true`. The core does
not restrict refin/refout combinations. The input stream's byte/bit order must
be configured correctly by its caller.

## Configurations and results

All check values below are for ASCII `123456789`; all residue values are in the
catalogue's output orientation, with no final XOR. The complete poly/init/
reflection/xorout metadata and source anchors are pinned in
`verify/vectors/crc/catalogue.json`. These numerical facts were checked against
the primary catalogue, accessed 2026-10-29, and the pinned library's metadata.

| Configuration | Width | Check | Catalogue residue | Raw CRC_GOOD | Result |
|---|---:|---:|---:|---:|---|
| CRC-3/GSM | 3 | 4 | 2 | 2 | PASS |
| CRC-3/ROHC | 3 | 6 | 0 | 0 | PASS |
| CRC-4/G-704 | 4 | 7 | 0 | 0 | PASS |
| CRC-4/INTERLAKEN | 4 | B | 2 | 2 | PASS |
| CRC-5/USB | 5 | 19 | 06 | 0C | PASS |
| CRC-6/CDMA2000-A | 6 | 0D | 0 | 0 | PASS |
| CRC-6/DARC | 6 | 26 | 0 | 0 | PASS |
| CRC-7/MMC | 7 | 75 | 0 | 0 | PASS |
| CRC-8/MAXIM-DOW (1-Wire) | 8 | A1 | 0 | 0 | PASS |
| CRC-8/SMBUS (PEC) | 8 | F4 | 0 | 0 | PASS |
| CRC-8/I-432-1 | 8 | A1 | AC | AC | PASS raw core + software XOR 55 |
| CRC-10/ATM | 10 | 199 | 0 | 0 | PASS |
| CRC-11/UMTS | 11 | 061 | 0 | 0 | PASS |
| CRC-12/UMTS | 12 | DAF | 0 | 0 | PASS |
| CRC-13/BBC | 13 | 04FA | 0 | 0 | PASS |
| CRC-14/DARC | 14 | 082D | 0 | 0 | PASS |
| CRC-15/CAN | 15 | 059E | 0 | 0 | PASS |
| CRC-16/USB | 16 | B4C8 | B001 | 800D | PASS |
| CRC-16/MODBUS | 16 | 4B37 | 0 | 0 | PASS |
| CRC-16/MAXIM-DOW (1-Wire inverted CRC16) | 16 | 44C2 | B001 | 800D | PASS |
| CRC-16/IBM-3740 | 16 | 29B1 | 0 | 0 | PASS |
| CRC-16/KERMIT | 16 | 2189 | 0 | 0 | PASS |

The unchanged USB program checks the supported address/token's constant CRC5
pattern rather than configuring its dynamic CRC unit to CRC5. Testing CRC5 here
establishes primitive capability, not a new dynamic-token feature in that program.

## Limits, unsupported entries and tools

- Initial seed can be only zero or all ones. CRC-5/EPC-C1G2 (`init=09`),
  CRC-11/FLEXRAY (`init=01A`) and CRC-16/RIELLO (`init=B2AA`) are reported as
  unsupported native seed configurations. Their metadata and independent
  library checks are verified, but no arbitrary seed is forced into the RTL.
- Arbitrary xorout is not directly programmable. Engine `OSRCRC INV` can supply
  whole-byte inversion (mask as needed for widths below 8); the tested
  CRC-8/I-432-1 xorout 55 requires host/software transformation. No claim is made
  that an unchanged protocol program performs it automatically.
- The selected set spans 3–16 bits but does not contain every catalogue variant
  or every possible polynomial. No new hardware feature is proposed or added.

Tools: Python 3.10.12, cocotb 2.0.1, Icarus/vvp 12.0, crccheck 1.3.1.
Evidence: `evidence/round2/crc/results.json`, simulator log, result
XML and provenance receipt. No RTL/spec disagreement was found by these vectors.


## Python version provenance correction (BUG-073)

The original receipt copied `3.10.14` from cocotb's startup banner. A live
launcher query and a separate test executing `sys.version` inside cocotb instead
report **3.10.12**. Both original banner logs and old receipts are preserved;
the report now uses the independently measured runtime. No mechanism is claimed
for the banner discrepancy. The corrected receipt captures the live value
rather than hard-coding a version. Reproduction scripts, runtime JSON, logs and
fail-before/pass-after receipt checks are under
`evidence/round2/python_runtime/`. This changes tool provenance,
not any RTL, stimulus, comparison or recorded verification result.
