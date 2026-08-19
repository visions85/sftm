#!/usr/bin/env python3
"""Decode SFTM In-System Probe samples at FULL resolution.

probe0 (128 bit, id SFTM):
  [127:120] 0x3C sig  [115:108] blits  [107:88] gdone  [87:68] frame period
  [67:48] wrFIFO stall  [47:28] GROM stall  [27:8] busy clk  [7:0] 0xA5 sig
probe1 (32 bit, id SFWR):
  [31:24] 0x5C sig  [19:0] VRAM writes

Reference: one full background = 92,160 writes; a frame = 871,728 clk.
"""
import sys, re

def fld(v, hi, lo): return (v >> lo) & ((1 << (hi-lo+1)) - 1)

p0, p1 = [], []
for line in (open(sys.argv[1]) if len(sys.argv) > 1 else sys.stdin):
    m = re.match(r'RAW(\d) ([01]+)\s*$', line.strip())
    if not m: continue
    (p0 if m.group(1) == '0' else p1).append(int(m.group(2), 2))

if not p0: sys.exit("no probe0 samples")
bad0 = [v for v in p0 if fld(v,7,0)!=0xA5 or fld(v,127,120)!=0x3C]
bad1 = [v for v in p1 if fld(v,31,24)!=0x5C]
print(f"probe0 samples {len(p0)} (sig fail {len(bad0)})   probe1 samples {len(p1)} (sig fail {len(bad1)})")
if bad0 or bad1:
    print("  !! signatures wrong -- fabric is not running this bitstream; ignore the numbers.")
    sys.exit(1)

rows=[]
for v in p0:
    rows.append(dict(busy=fld(v,27,8), wait=fld(v,47,28), stw=fld(v,67,48),
                     fper=fld(v,87,68), gf=fld(v,107,88), blits=fld(v,115,108)))
wr = [fld(v,19,0) for v in p1]

def stat(name, xs, unit=""):
    xs=[x for x in xs if True]
    if not xs: return
    nz=[x for x in xs if x]
    print(f"  {name:<18} max={max(xs):>7,}{unit}  mean={sum(xs)//len(xs):>7,}  "
          f"nonzero {len(nz)}/{len(xs)}")

FRAME=871728; BG=92160
print()
stat("frame period clk", [r['fper'] for r in rows])
print(f"     (a whole frame is {FRAME:,} clk)")
stat("blitter busy clk", [r['busy'] for r in rows])
stat("GROM fetch stall", [r['wait'] for r in rows])
stat("wrFIFO stall",     [r['stw']  for r in rows])
stat("blits started",    [r['blits'] for r in rows])
stat("gdone pulses",     [r['gf'] for r in rows])
if wr: stat("VRAM writes",  wr)
print(f"     (one full background is {BG:,} writes)")

mb=max(r['busy'] for r in rows)
if mb:
    mw=max(r['wait'] for r in rows); ms=max(r['stw'] for r in rows)
    print()
    print(f"busiest frame: busy {mb:,} clk = {100*mb/FRAME:.1f}% of a frame")
    print(f"   GROM stall {mw:,} ({100*mw/mb:.0f}% of busy)   "
          f"wrFIFO stall {ms:,} ({100*ms/mb:.0f}% of busy)")
    if wr:
        mwr=max(wr)
        print(f"   writes {mwr:,} = {100*mwr/BG:.0f}% of a full background")
        if mwr: print(f"   -> {mb/mwr:.1f} clk per write")
