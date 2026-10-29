# Attribute routed-netlist cells (Tiny Tapeout GL netlist) to the program memory.
# usage: pmem_cost.py tt_submission/<top>.v sg13cmos5l_stdcell_typ_1p20V_25C.lib  (docs/SRAM_INVESTIGATION.md, section 2)
import re, sys, collections
net_txt = open(sys.argv[1]).read()
lib = open(sys.argv[2]).read()
area = {m.group(1): float(m.group(2)) for m in re.finditer(r'cell\s*\(\s*"?(\w+)"?\s*\)\s*\{[^{}]*?area\s*:\s*([\d.]+)', lib)}
OUT = {'X', 'Y', 'Q', 'Q_N', 'L_HI', 'L_LO'}
cells = []  # (type, name, {pin: net})
for m in re.finditer(r'^\s*(sg13cmos5l_\w+)\s+(\S+)\s*\((.*?)\);', net_txt, re.S | re.M):
    pins = dict((p, n.strip()) for p, n in re.findall(r'\.(\w+)\(([^()]*)\)', m.group(3)))
    cells.append((m.group(1), m.group(2), pins))
drv = {}; loads = collections.defaultdict(list)
for i, (t, n, p) in enumerate(cells):
    for pin, net in p.items():
        if not net: continue
        (drv.__setitem__(net, i) if pin in OUT else loads[net].append((i, pin)))
is_ff = lambda i: 'dfrbp' in cells[i][0]
is_pm = lambda net: net.startswith('\\pmem[')
pm_ff = {i for i, (t, n, p) in enumerate(cells) if is_ff(i) and is_pm(p.get('Q', ''))}
def outs(i): return [v for k, v in cells[i][2].items() if k in OUT]
def ins(i): return [v for k, v in cells[i][2].items() if k not in OUT]
# write side: backward cone from pmem flop D pins; keep cells whose every load is in the cone
cone = set(); todo = [cells[i][2]['D'] for i in pm_ff]
while todo:
    net = todo.pop(); j = drv.get(net)
    if j is None or is_ff(j) or j in cone: continue
    cone.add(j); todo += ins(j)
changed = True
while changed:
    changed = False
    for j in list(cone):
        if any(l not in cone and l not in pm_ff for o in outs(j) for l, _ in loads[o]):
            cone.discard(j); changed = True
write = cone
# read side: forward from pmem Q through cells reached by a data (non-select) input
read = set(); todo = [cells[i][2]['Q'] for i in pm_ff]
while todo:
    net = todo.pop()
    for j, pin in loads[net]:
        if j in read or is_ff(j) or j in write: continue
        t = cells[j][0]
        if ('mux' in t and pin.startswith('A')) or 'dlygate' in t or 'buf' in t:
            read.add(j); todo += outs(j)
# select trees: buffers/dlygates whose loads are all read-mux select pins (or such buffers)
sel = set(); changed = True
while changed:
    changed = False
    for j, (t, n, p) in enumerate(cells):
        if j in sel or j in read or j in write or not ('buf' in t or 'dlygate' in t or 'inv' in t): continue
        L = [(l, pin) for o in outs(j) for l, pin in loads[o]]
        if L and all((l in read and pin.startswith('S')) or l in sel for l, pin in L):
            sel.add(j); changed = True
def summ(name, s):
    c = collections.Counter(cells[j][0] for j in s)
    a = sum(area.get(t, 0) * k for t, k in c.items())
    hold = sum(k for t, k in c.items() if 'dlygate' in t)
    ha = sum(area.get(t, 0) * k for t, k in c.items() if 'dlygate' in t)
    print(f"{name:28s} cells {len(s):6d}  area {a:10.0f} um2  (delay cells {hold}, {ha:.0f} um2)  {dict(c.most_common(6))}")
    return a
skip = ('fill', 'decap', 'tie', 'antenna')
std = [j for j, (t, n, p) in enumerate(cells) if not any(s in t for s in skip)]
tot = sum(area.get(cells[j][0], 0) for j in std)
hold_all = [j for j in std if cells[j][1].startswith('hold')]
print(f"standard cells (no fill/decap/tie/antenna): {len(std)}, {tot:.0f} um2; 'hold*' cells {len(hold_all)}, {sum(area[cells[j][0]] for j in hold_all):.0f} um2")
ties = {j for j, (t, n, p) in enumerate(cells) if 'tiehi' in t
        and loads[p.get('L_HI', '')] and all(l in pm_ff for l, _ in loads[p['L_HI']])}
a = summ('pmem flops', pm_ff) + summ('pmem write logic', write) + summ('pmem read muxes', read) + summ('pc select buffer trees', sel) + summ('tie cells on their resets', ties)
tot += sum(area.get(cells[j][0], 0) for j, (t, n, p) in enumerate(cells) if 'tie' in t or 'antenna' in t)
h = [j for j in hold_all if j in write or j in read or j in sel]
print(f"hold* cells on these paths: {len(h)}, {sum(area[cells[j][0]] for j in h):.0f} um2")
print(f"program memory in all: {a:.0f} um2 = {100*a/tot:.1f} % of {tot:.0f} um2 of standard cells (incl. tie/antenna), {100*a/916214:.1f} % of the 6x4 die")
