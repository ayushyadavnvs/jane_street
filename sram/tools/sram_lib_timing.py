# Summarise port-A timing of IHP SRAM Liberty files: access (clk->DOUT, the largest table entry), setup
# and hold per pin group. usage: sram_lib_timing.py <lib files>  (docs/SRAM_INVESTIGATION.md, section 1.2)
import re, sys, glob, os
def scan(path):
    t = open(path).read()
    res = {}; owner = None
    for m in re.finditer(r'(?<!pg_)\b(pin|bus)\s*\(\s*"?([\w\[\]:]+)"?\s*\)|\btiming\s*\(\s*\)\s*\{', t):
        if m.group(1):
            owner = re.sub(r'\[.*', '', m.group(2)); continue
        i = m.end(); d = 1
        while d:
            c = t[i]; d += (c == '{') - (c == '}'); i += 1
        body = t[m.end():i]
        rp = re.search(r'related_pin\s*:\s*"?(\w+)', body); ty = re.search(r'timing_type\s*:\s*"?(\w+)', body)
        if not rp or rp.group(1) != 'A_CLK' or not ty: continue
        nums = []
        for v in re.findall(r'values\s*\((.*?)\)\s*;', body, re.S):
            nums += [float(x) for x in re.findall(r'-?\d+\.\d+', v)]
        if nums: res.setdefault((owner, ty.group(1)), []).extend(nums)
    return res
for f in sys.argv[1:]:
    r = scan(f); n = os.path.basename(f)[:-4]
    def g(p, ty, fn=max):
        v = r.get((p, ty)); return f'{fn(v):.2f}' if v else '-'
    print(f"{n}: clk->DOUT {g('A_DOUT','rising_edge',min)}..{g('A_DOUT','rising_edge')} ns; setup ADDR {g('A_ADDR','setup_rising')} DIN {g('A_DIN','setup_rising')} WEN {g('A_WEN','setup_rising')} REN {g('A_REN','setup_rising')} MEN {g('A_MEN','setup_rising')}; hold ADDR {g('A_ADDR','hold_rising')} DIN {g('A_DIN','hold_rising')} MEN {g('A_MEN','hold_rising')}; min pulse {g('A_CLK','min_pulse_width')}")
