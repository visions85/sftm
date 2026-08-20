#!/usr/bin/env python3
"""Decode SFPC samples: PC histogram + interrupt state.
[63:56] 0xE7 sig  [55:32] PC  [31:28] {vint,ipl}  [27:20] vbl_cnt
[19:12] xint_cnt  [11:4] qint_cnt  [3:0] 0x5 sig
"""
import sys, re, collections
def fld(v,hi,lo): return (v>>lo)&((1<<(hi-lo+1))-1)
vals=[int(m.group(1),2) for m in
      (re.match(r'PC ([01]{64})\s*$',l.strip()) for l in
       (open(sys.argv[1]) if len(sys.argv)>1 else sys.stdin)) if m]
if not vals: sys.exit("no samples")
bad=[v for v in vals if fld(v,63,56)!=0xE7 or fld(v,3,0)!=0x5]
print(f"samples {len(vals)}  sig failures {len(bad)}")
good=[v for v in vals if v not in bad]
pcs=collections.Counter(fld(v,55,32) for v in good)
ints=collections.Counter(fld(v,31,28) for v in good)
print("\nPC histogram (top 12):")
for pc,n in pcs.most_common(12):
    print(f"  0x{pc:06X}  x{n}")
print(f"\n{{vint,ipl}} states: " + " ".join(f"{k:X}x{n}" for k,n in ints.most_common()))
f=[fld(good[0],27,20), fld(good[-1],27,20)]
x=[fld(good[0],19,12), fld(good[-1],19,12)]
q=[fld(good[0],11,4),  fld(good[-1],11,4)]
n=len(good)
print(f"vbl_cnt  first->last: {f[0]} -> {f[1]}  (mod-256; ~57/s if VINT firing)")
print(f"xint_cnt first->last: {x[0]} -> {x[1]}  (blitter XINT edges)")
print(f"qint_cnt first->last: {q[0]} -> {q[1]}  (scanline QINT edges)")
