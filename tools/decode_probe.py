#!/usr/bin/env python3
"""Decode SFTM In-System Probe samples (docker/read-probe.sh output).

Layout (see jtsftm_game.v):
  [63:56] 0x3C sig   [55:52] lgrm3  [51:48] lgrom1 [47:44] lgrom0
  [43:40] lvram      [39:36] fper   [35:32] bnum   [31:28] bstw
  [27:24] bwait      [23:20] bbusy  [19:16] bwr    [15:8] st_main  [7:0] 0xA5

Units: bwr = writes/8192; bbusy/bwait/bstw/fper = clk/65536.
Reference points: a full background is 92,160 writes = 0xB; a whole frame is
508*286*6 = 871,728 clk = 0xD, which is also what fper must read.
"""
import sys, re, collections

F = {'bwr':(16,'writes /8192'), 'bbusy':(20,'busy clk /65536'),
     'bwait':(24,'GROM stall /65536'), 'bstw':(28,'wrFIFO stall /65536'),
     'bnum':(32,'blits started'), 'fper':(36,'frame period /65536'),
     'lvram':(40,'vram lane'), 'lgrom0':(44,'grom0 lane'),
     'lgrom1':(48,'grom1 lane'), 'lgrm3':(52,'grm3 lane')}

vals=[]
for line in (open(sys.argv[1]) if len(sys.argv)>1 else sys.stdin):
    m=re.match(r'RAW ([01]{64})\s*$', line.strip())
    if m: vals.append(int(m.group(1),2))

if not vals:
    sys.exit("no samples decoded")

bad=[v for v in vals if (v & 0xFF)!=0xA5 or ((v>>56)&0xFF)!=0x3C]
print(f"samples: {len(vals)}   signature failures: {len(bad)}")
if bad:
    print("  !! signatures wrong -- the fabric is not running this bitstream;")
    print("     do not trust anything below.")
print()
hist={k:collections.Counter() for k in F}
for v in vals:
    for k,(sh,_) in F.items(): hist[k][(v>>sh)&0xF]+=1
for k,(sh,desc) in F.items():
    c=hist[k]; mx=max(c); 
    seen=" ".join(f"{p:X}x{n}" for p,n in sorted(c.items()))
    print(f"  {k:<7}{desc:<22} max={mx:X}  {seen}")
print()
mxwr, mxbusy = max(hist['bwr']), max(hist['bbusy'])
mxwait, mxstw = max(hist['bwait']), max(hist['bstw'])
print(f"busiest frame observed: {mxwr*8192:,} writes  (one full background = 92,160 = 0xB)")
print(f"                        {mxbusy*65536:,} clk busy  (a whole frame = 871,728 = 0xD)")
print(f"  GROM fetch stall  {mxwait*65536:,} clk")
print(f"  write-FIFO stall  {mxstw*65536:,} clk")
if mxwait>mxstw:   print("  -> the blitter waits mainly on GROM fetches")
elif mxstw>mxwait: print("  -> the blitter waits mainly on the VRAM write port")
else:              print("  -> neither stall dominates at this resolution")
