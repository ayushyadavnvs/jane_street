#!/usr/bin/env python3
"""Check the SRAM floorplan in sram/config.json against the macro LEF, without EDA tools (D55).

For every macro instance in MACROS it computes the Metal4 PDN stripes that cross it, from the
FP_PDN_* keys, and checks that
  - each stripe lies inside supply-pin columns of its own net (VPWR on VDD!/VDDARRAY!, VGND
    on VSS!), with at least MARGIN um to the column edges;
  - every supply net of the macro carries at least one stripe;
  - the macro is inside the core, N or FS, and clear of the other macros by twice the halo.
With --gds (needs gdstk) it also checks that no Metal4, Via3 or TopMetal1 shape of the macro
lies under a VPWR stripe in the gap between the VDD! and VDDARRAY! columns, where the LEF has
only an obstruction.

The stripe position follows OpenROAD pdngen, as the passing reference projects use it: the
first POWER stripe's centre is at core x min + FP_PDN_VOFFSET, then every FP_PDN_VPITCH; its
GROUND stripe's centre is FP_PDN_VWIDTH + FP_PDN_VSPACING to the right. pdn_cfg.tcl repeats
the check on the real stripes in the flow.

usage: python3 sram/check_sram_floorplan.py [--gds]
"""
import json
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
CORE_X0, CORE_Y0 = 2.88, 3.78          # tt_block_6x4_pgvdd.def: first row origin
DIE = (1289.28, 710.64)                # tile_sizes.yaml, 6x4
MARGIN = 0.01
HALO = 10.0                            # LibreLane FP_MACRO_*_HALO default
POWER = {"VDD!": "VPWR", "VDDARRAY!": "VPWR", "VSS!": "VGND"}


def lef_macro(path):
    text = open(path).read()
    size = re.search(r"\bSIZE ([\d.]+) BY ([\d.]+)", text)
    cols = []
    for pin, net in POWER.items():
        body = re.search(r"PIN " + re.escape(pin) + r"\s(.*?)END " + re.escape(pin), text, re.S)
        for layer, rects in re.findall(r"LAYER (\w+) ;(.*?)END", body.group(1), re.S):
            if layer != "Metal4":
                continue
            for r in re.findall(r"RECT ([\d.]+) ([\d.]+) ([\d.]+) ([\d.]+)", rects):
                cols.append((net, pin) + tuple(float(v) for v in r))
    return float(size.group(1)), float(size.group(2)), cols


def stripes(cfg, x_end):
    w, sp, pitch, off = (cfg[k] for k in ("FP_PDN_VWIDTH", "FP_PDN_VSPACING", "FP_PDN_VPITCH",
                                          "FP_PDN_VOFFSET"))
    c = CORE_X0 + off
    while c + w + sp + w / 2 <= x_end:
        yield "VPWR", c - w / 2, c + w / 2
        yield "VGND", c + w + sp - w / 2, c + w + sp + w / 2
        c += pitch


def main():
    cfg = json.load(open(os.path.join(HERE, "config.json")))
    errors = []
    boxes = []
    for name, m in cfg["MACROS"].items():
        lef = os.path.join(ROOT, m["lef"][0].replace("dir::../", ""))
        mw, mh, cols = lef_macro(lef)
        for inst, place in m["instances"].items():
            x0, y0 = place["location"]
            orient = place["orientation"]
            if orient not in ("N", "FS"):
                errors.append(f"{inst}: orientation {orient}, use N or FS")
            if x0 < CORE_X0 or y0 < CORE_Y0 or x0 + mw > DIE[0] - CORE_X0 or y0 + mh > DIE[1] - CORE_Y0:
                errors.append(f"{inst}: outside the core")
            boxes.append((inst, x0, y0, x0 + mw, y0 + mh))
            seen = set()
            for net, sx0, sx1 in stripes(cfg, DIE[0] - CORE_X0):
                if sx1 <= x0 or sx0 >= x0 + mw:
                    continue
                lx0, lx1 = sx0 - x0, sx1 - x0      # macro-local x (N and FS keep x)
                under = [c for c in cols if c[2] - MARGIN < lx1 and c[4] + MARGIN > lx0]
                inside = [c for c in under if c[2] + MARGIN <= lx0 and lx1 <= c[4] - MARGIN]
                wrong = [c for c in under if c[0] != net]
                if wrong or not inside:
                    errors.append(f"{inst}: {net} stripe at local x {lx0:.2f}..{lx1:.2f} is on "
                                  f"{sorted({c[1] for c in under}) or 'no pin'}")
                    continue
                seen |= {c[1] for c in inside}
                gap = min(c[2] + MARGIN - lx0 for c in inside), min(c[4] - MARGIN - lx1 for c in inside)
                print(f"{inst}: {net} stripe local x {lx0:7.2f}..{lx1:7.2f} on "
                      f"{'/'.join(sorted({c[1] for c in inside}))}, edge margins "
                      f"{-gap[0] + MARGIN:.2f} / {gap[1] + MARGIN:.2f} um")
            for pin in POWER:
                if pin not in seen:
                    errors.append(f"{inst}: no stripe on {pin}")
            if "--gds" in sys.argv:
                errors += gds_check(os.path.join(ROOT, m["gds"][0].replace("dir::../", "")),
                                    cfg, x0, mw, inst)
    for i, a in enumerate(boxes):
        for b in boxes[i + 1:]:
            if a[1] < b[3] + 2 * HALO and b[1] < a[3] + 2 * HALO and a[2] < b[4] + 2 * HALO and b[2] < a[4] + 2 * HALO:
                errors.append(f"{a[0]} and {b[0]} are closer than two halos")
    for e in errors:
        print("ERROR:", e)
    print("OK" if not errors else f"{len(errors)} error(s)")
    return 1 if errors else 0


def gds_check(path, cfg, x0, mw, inst):
    import gdstk
    top = gdstk.read_gds(path).top_level()[0]
    polys = [p for p in top.get_polygons() if p.layer in (49, 50, 126)]  # Via3, Metal4, TopMetal1
    _, _, cols = lef_macro(path.replace(".gds", ".lef"))
    vdd_top = max(c[5] for c in cols if c[1] == "VDD!" and c[5] < mh_of(cols))
    varr_bot = min(c[3] for c in cols if c[1] == "VDDARRAY!")
    out = []
    for net, sx0, sx1 in stripes(cfg, DIE[0] - CORE_X0):
        if net != "VPWR" or sx1 <= x0 or sx0 >= x0 + mw:
            continue
        lx0, lx1 = sx0 - x0 - 1.0, sx1 - x0 + 1.0
        n = 0
        for p in polys:
            (a, b), (c, d) = p.bounding_box()
            if a < lx1 and c > lx0 and b < varr_bot and d > vdd_top:
                n += 1
        print(f"{inst}: GDS shapes on Metal4/Via3/TopMetal1 under the VPWR stripe at local x "
              f"{lx0 + 1:.2f} in the split y {vdd_top}..{varr_bot}: {n}")
        if n:
            out.append(f"{inst}: {n} shape(s) under the VPWR stripe in the VDD!/VDDARRAY! split")
    return out


def mh_of(cols):
    return max(c[5] for c in cols)


if __name__ == "__main__":
    sys.exit(main())
