#!/usr/bin/env python3
"""Build the project website (D105) into one static folder for GitHub Pages.

Everything on the page comes from the repository, so it stays current without hand edits:
  - protocols and verification layers: the tables in README.md
  - design decisions, bugs, testbenches: counted in docs/ and pbe_v1/test/
  - block diagrams and the instruction table: diagrams/pbe-diagrams.html (one source)
  - layout numbers: metrics.csv from the latest gds run (if given), else the values below

Usage: python3 site/build.py --out _site [--metrics metrics.csv] [--render gds_render.png]
                             [--viewer] [--run-url URL] [--commit SHA]
"""
import argparse
import csv
import html
import re
import shutil
from datetime import datetime, timezone
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SITE = Path(__file__).resolve().parent
REPO_URL = "https://github.com/ayushyadavnvs/jane_street"

# Fallback layout numbers (GDS run 43698688003, commit d5e4461), used when no metrics.csv is given.
FALLBACK = {
    "setup_slow": 1.194, "setup_typ": 2.526, "setup_fast": 3.365,
    "hold_slow": 0.605, "hold_typ": 0.286, "hold_fast": 0.107,
    "util": 36.9, "stdcell": 389114, "macros": 56254, "cells": 101053,
    "drc": 0, "lvs": 0, "antenna": 0,
}

# How each protocol uses the hardware (by its number in README.md's table). Groups:
#   a: a program only, written after the engine existed, with no RTL change
#   b: a program on the general hardware (the first protocols shaped that hardware)
#   c: a program that uses hardware added later, but general and shared by other protocols
#   d: a program that needs protocol-specific hardware
GROUP = {1: "b", 2: "b", 3: "b", 4: "b", 5: "b", 6: "b", 7: "b", 8: "b", 9: "b",
         10: "c", 11: "d", 12: "a", 13: "a", 14: "a", 15: "a", 16: "a", 17: "a", 18: "a", 19: "c"}
GROUP_LABEL = {
    "a": ("Program only", "Added after the engine existed, with no RTL change"),
    "b": ("General hardware", "A program on the shared CRC, parity, timeout and FIFO hardware"),
    "c": ("New, general hardware", "Uses hardware added later that other protocols share (line coding, CRC-32)"),
    "d": ("Protocol hardware", "Needs protocol-specific hardware (CAN's bit-synchronous block)"),
}


def md_inline(text):
    """The little Markdown the README tables use: code spans and links."""
    text = html.escape(text, quote=False)
    text = re.sub(r"\[([^\]]+)\]\(([^)]+)\)", lambda m: m.group(1), text)
    return re.sub(r"`([^`]+)`", r"<code>\1</code>", text)


def md_table(md, heading):
    """Rows of the first table after a '## heading' line, as lists of cells."""
    part = md.split(heading, 1)[1]
    rows = []
    for line in part.splitlines():
        if line.startswith("|"):
            cells = [c.strip() for c in line.strip().strip("|").split("|")]
            if set("".join(cells)) <= set("-: "):
                continue
            rows.append(cells)
        elif rows:
            break
    return rows[1:]  # without the header


def read_metrics(path):
    if not path:
        return dict(FALLBACK)
    m = {}
    with open(path) as f:
        for row in csv.reader(f):
            if len(row) == 2:
                m[row[0]] = row[1]
    c = "__corner:nom_{}"
    corners = {"slow": "slow_1p08V_125C", "typ": "typ_1p20V_25C", "fast": "fast_1p32V_m40C"}
    out = {}
    for k, v in corners.items():
        out["setup_" + k] = float(m["timing__setup__ws" + c.format(v)])
        out["hold_" + k] = float(m["timing__hold__ws" + c.format(v)])
    out["util"] = round(float(m["design__instance__utilization"]) * 100, 1)
    out["stdcell"] = round(float(m["design__instance__area__stdcell"]))
    out["macros"] = round(float(m.get("design__instance__area__macros", 0)))
    out["cells"] = int(float(m.get("design__instance__count", 0)))
    out["drc"] = int(float(m.get("route__drc_errors", 0)))
    out["lvs"] = int(float(m.get("design__lvs_error__count", 0)))
    out["antenna"] = int(float(m.get("antenna__violating__nets", 0)))
    return out


def diagram_parts():
    src = (ROOT / "diagrams" / "pbe-diagrams.html").read_text()
    svgs = re.findall(r"<svg\b.*?</svg>", src, flags=re.S)
    style = re.search(r"<style>(.*?)</style>", src, flags=re.S).group(1)
    svg_css = "\n".join(l for l in style.splitlines() if l.strip().startswith("svg "))
    isa = re.search(r"<thead><tr><th>OP</th>.*?</tbody>", src, flags=re.S).group(0)
    return svgs, svg_css, isa


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", default="_site")
    ap.add_argument("--metrics")
    ap.add_argument("--render")
    ap.add_argument("--viewer", action="store_true", help="a 3D viewer is published at viewer/")
    ap.add_argument("--run-url", default="")
    ap.add_argument("--commit", default="")
    a = ap.parse_args()

    readme = (ROOT / "README.md").read_text()
    protos = md_table(readme, "## Protocols")
    layers = md_table(readme, "## Verification in brief")
    decisions = len(re.findall(r"^## D\d+", (ROOT / "docs/DESIGN_DECISIONS.md").read_text(), re.M))
    bugs = len(re.findall(r"^## BUG-\d+", (ROOT / "docs/BUG_LOG.md").read_text(), re.M))
    benches = len(list((ROOT / "pbe_v1/test").glob("tb_*.sv")))
    m = read_metrics(a.metrics)
    svgs, svg_css, isa = diagram_parts()

    words = []
    cards = []
    for row in protos:
        num, name, prog, tested = row[0], row[1], row[2], row[3]
        n = int(num)
        g = GROUP.get(n, "b")
        sizes = [int(x) for x in re.findall(r"\((\d+)\)", prog)]
        words += sizes
        size = " + ".join(str(s) for s in sizes) + " words" if sizes else md_inline(prog)
        cards.append(
            f'<article class="proto g{g}" data-group="{g}">'
            f'<div class="ptop"><span class="pnum">{n:02d}</span><span class="badge b{g}">{GROUP_LABEL[g][0]}</span></div>'
            f"<h3>{md_inline(name)}</h3>"
            f'<p class="psize">{size}</p>'
            f'<p class="ptest">{md_inline(tested)}</p></article>')
    counts = {g: sum(1 for r in protos if GROUP.get(int(r[0])) == g) for g in "abcd"}

    layer_cards = "".join(
        f'<div class="layer"><h3>{md_inline(l[0])}</h3><p>{md_inline(l[1])}</p></div>' for l in layers)

    out = Path(a.out)
    if out.exists():
        shutil.rmtree(out)
    (out / "assets").mkdir(parents=True)
    render_name = "assets/gds_render.jpg"
    if a.render:
        from PIL import Image  # pip install pillow
        Image.MAX_IMAGE_PIXELS = None
        im = Image.open(a.render).convert("RGB")
        im.thumbnail((2200, 2200))
        im.save(out / render_name, quality=86, optimize=True)
    else:
        shutil.copy(SITE / "assets" / "gds_render.jpg", out / render_name)
    shutil.copy(ROOT / "diagrams" / "pbe-diagrams.html", out / "diagrams.html")
    shutil.copy(SITE / "assets" / "favicon.svg", out / "assets" / "favicon.svg")

    def ns(x):
        return f"{x:+.2f} ns"

    built = datetime.now(timezone.utc).strftime("%d %b %Y")
    commit = a.commit[:7]
    viewer_btn = ('<a class="btn" href="viewer/">3D layout viewer</a>' if a.viewer else "")
    run_link = (f' · <a href="{a.run_url}">GDS run</a>' if a.run_url else "")
    page = (SITE / "template.html").read_text()
    repl = {
        "SVG_CSS": svg_css,
        "FIG1": svgs[0], "FIG2": svgs[1], "FIG3": svgs[2], "ISA": isa,
        "PROTOS": "\n".join(cards), "LAYERS": layer_cards,
        "N_PROTOS": str(len(protos)), "N_DECISIONS": str(decisions), "N_BUGS": str(bugs),
        "N_BENCHES": str(benches), "MIN_WORDS": str(min(words)), "MAX_WORDS": str(max(words)),
        "N_A": str(counts["a"]), "N_B": str(counts["b"]), "N_C": str(counts["c"]), "N_D": str(counts["d"]),
        "N_AB": str(counts["a"] + counts["b"]),
        "SETUP_SLOW": ns(m["setup_slow"]), "SETUP_TYP": ns(m["setup_typ"]), "SETUP_FAST": ns(m["setup_fast"]),
        "HOLD_SLOW": ns(m["hold_slow"]), "HOLD_TYP": ns(m["hold_typ"]), "HOLD_FAST": ns(m["hold_fast"]),
        "UTIL": f'{m["util"]:.1f}', "STDCELL": f'{m["stdcell"]:,}', "MACROS": f'{m["macros"]:,}',
        "CELLS": f'{m["cells"]:,}', "DRC": str(m["drc"]), "LVS": str(m["lvs"]), "ANTENNA": str(m["antenna"]),
        "VIEWER_BTN": viewer_btn, "RUN_LINK": run_link, "BUILT": built,
        "COMMIT": (f'<a href="{REPO_URL}/commit/{a.commit}">{commit}</a>' if commit else "main"),
        "REPO": REPO_URL,
    }
    for k, v in repl.items():
        page = page.replace("{{" + k + "}}", v)
    left = re.findall(r"\{\{[A-Z_0-9]+\}\}", page)
    if left:
        raise SystemExit(f"unfilled placeholders: {left}")
    (out / "index.html").write_text(page)
    (out / ".nojekyll").write_text("")
    print(f"built {out}/index.html: {len(protos)} protocols, {decisions} decisions, {bugs} bugs, "
          f"{benches} benches, slow setup {ns(m['setup_slow'])}")


if __name__ == "__main__":
    main()
