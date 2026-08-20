#!/usr/bin/env python3
"""Decode probe2 (id SFRN): did the ROM survive JTAG reconfiguration?"""
import sys, re, collections
def fld(v,hi,lo): return (v>>lo) & ((1<<(hi-lo+1))-1)
vals=[int(m.group(1),2) for m in
      (re.match(r'P3 ([01]{64})\s*$', l.strip()) for l in
       (open(sys.argv[1]) if len(sys.argv)>1 else sys.stdin)) if m]
if not vals: sys.exit("no probe2 samples")
bad=[v for v in vals if fld(v,63,56)!=0x7E]
print(f"samples {len(vals)}  signature failures {len(bad)}")
if bad: sys.exit("  !! signature wrong -- ignore")
fr = collections.Counter(fld(v,48,48) for v in vals)
got= collections.Counter(fld(v,47,47) for v in vals)
cnt= [fld(v,46,32) for v in vals]
first=collections.Counter(fld(v,31,0) for v in vals)
print(f"  force_run echo : {dict(fr)}")
print(f"  m_got          : {dict(got)}")
print(f"  main fetches   : max={max(cnt)}  (0 = CPU not fetching at all)")
print(f"  FIRST longword : " + ", ".join(f"0x{k:08X} x{n}" for k,n in first.most_common(3)))
print()
top=first.most_common(1)[0][0]
if top==0x00008000:
    print("  VERDICT: SDRAM KEPT THE ROM. The game can run under JTAG config --")
    print("           measurement through the ISSP is viable.")
elif max(cnt)==0:
    print("  VERDICT: the CPU never completed a fetch -- still held off, or the")
    print("           main lane is not responding.")
else:
    print(f"  VERDICT: first longword is 0x{top:08X}, not 0x00008000. The ROM did")
    print("           NOT survive reconfiguration, so this route cannot work.")
