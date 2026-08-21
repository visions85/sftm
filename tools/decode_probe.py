#!/usr/bin/env python3
"""Decode SFTM In-System Probe samples at FULL resolution.

probe0 (128 bit, id SFTM):
  [127:120] 0x3C sig  [115:108] blits  [107:88] gdone  [87:68] frame period
  [67:48] wrFIFO stall  [47:28] GROM stall  [27:8] busy clk  [7:0] 0xA5 sig
probe1 (128 bit, id SFWR):
  [127:120] 0x5C sig  [111:92] VRAM writes  [91:72] VRAM reads  [71:52] TRANSFER  [51:32] COMMAND
  [31:12] all CPU video-reg writes  [11:0] 0x5A5 sig

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
bad1 = [v for v in p1 if fld(v,127,120)!=0x5C or fld(v,11,0)!=0x5A5]
print(f"probe0 samples {len(p0)} (sig fail {len(bad0)})   probe1 samples {len(p1)} (sig fail {len(bad1)})")
if bad0 or bad1:
    print("  !! signatures wrong -- fabric is not running this bitstream; ignore the numbers.")
    sys.exit(1)

rows=[]
for v in p0:
    rows.append(dict(busy=fld(v,27,8), wait=fld(v,47,28), stw=fld(v,67,48),
                     fper=fld(v,87,68), gf=fld(v,107,88), blits=fld(v,115,108)))
vreg = [fld(v,31,12) for v in p1]
cmd  = [fld(v,51,32) for v in p1]
xfer = [fld(v,71,52) for v in p1]
rds  = [fld(v,91,72) for v in p1]
wrx  = [fld(v,111,92) for v in p1]

def stat(name, xs, unit=""):
    xs=[x for x in xs if True]
    if not xs: return
    nz=[x for x in xs if x]
    print(f"  {name:<18} max={max(xs):>7,}{unit}  mean={sum(xs)//len(xs):>7,}  "
          f"nonzero {len(nz)}/{len(xs)}")

FRAME=871728; BG=92160
print()
stat("frame period clk", [r['fper'] for r in rows]); print(f"     (a whole frame is {FRAME:,} clk)")
stat("blitter busy clk", [r['busy'] for r in rows])
stat("GROM fetch stall", [r['wait'] for r in rows])
stat("wrFIFO stall",     [r['stw']  for r in rows])
stat("blits started",    [r['blits'] for r in rows])
stat("VRAM writes",      wrx);  print(f"     (one full background is {BG:,} writes)")
print()
print("  -- CPU side of the video interface --")
stat("CPU vreg writes",  vreg)
stat("  COMMAND (blits)", cmd)
stat("  pens accepted  ", xfer)
stat("VRAM read strobes", rds)
print()
mb=max(r['busy'] for r in rows); mc=max(cmd) if cmd else 0
if mc==0:
    print("VERDICT: the CPU never wrote the COMMAND register -> it never asks for a")
    print("         blit. The fault is upstream of the blitter.")
elif mb==0:
    print("VERDICT: the CPU asks for blits but the blitter never goes busy ->")
    print("         blitter start/handshake fault.")
else:
    mw=max(r['wait'] for r in rows); ms=max(r['stw'] for r in rows); mwr=max(wrx) if wrx else 0
    print(f"busiest frame: busy {mb:,} clk = {100*mb/FRAME:.1f}% of a frame")
    print(f"   GROM stall {mw:,} ({100*mw/mb:.0f}% of busy)   wrFIFO stall {ms:,} ({100*ms/mb:.0f}% of busy)")
    if mwr: print(f"   writes {mwr:,} = {100*mwr/BG:.0f}% of a background   {mb/mwr:.1f} clk/write")
