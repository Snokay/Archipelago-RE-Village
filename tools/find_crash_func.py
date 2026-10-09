"""Fonction du jeu la plus proche d une adresse de crash (reframework_crash.dmp).
Usage : python tools/find_crash_func.py <il2cpp_dump.json> <adresse hex, base 0x140000000>
Ex. re8.exe+0x41ea5e4 -> 1441ea5e4. Rien de proche = code natif du moteur (pas une methode managee)."""
import re, sys
target = int(sys.argv[2], 16)
typ = meth = None
best = []
rt = re.compile(r'^    "([^"]*)": \{')
rm = re.compile(r'^            "([^"]*)": \{')
rf = re.compile(r'^\s*"function": "([0-9a-fA-Fx]+)"')
with open(sys.argv[1], encoding="utf-8", errors="replace") as f:
    for line in f:
        m = rt.match(line)
        if m: typ = m.group(1); continue
        m = rm.match(line)
        if m: meth = m.group(1); continue
        m = rf.match(line)
        if m:
            try: a = int(m.group(1), 16)
            except ValueError: continue
            if a <= target and target - a < 0x400000:
                best.append((target - a, typ, meth, hex(a)))
best.sort()
for b in best[:8]: print(b)
