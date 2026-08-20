#!/usr/bin/env python3
"""Decode SFPC v2 (128b): PC+opcode pairs, checked against the program image.
[127:120] 0xE7  [119:96] PC  [95:80] opcode  [79:76] {vint,ipl}
[75:68] vbl  [67:60] xint  [59:52] qint  [3:0] 0x5
Usage: decode_pc.py samples.txt [prog.bin]
"""
import sys, re, collections, struct
def fld(v,hi,lo): return (v>>lo)&((1<<(hi-lo+1))-1)
vals=[int(m.group(1),2) for m in
      (re.match(r'PC ([01]{128})\s*$',l.strip()) for l in open(sys.argv[1])) if m]
if not vals: sys.exit("no samples (need 128-bit lines)")
bad=sum(1 for v in vals if fld(v,127,120)!=0xE7 or fld(v,3,0)!=0x5)
print(f"samples {len(vals)}  sig failures {bad}")
img=open(sys.argv[2],'rb').read() if len(sys.argv)>2 else None
pairs=collections.Counter((fld(v,119,96),fld(v,95,80)) for v in vals)
ints=collections.Counter(fld(v,79,76) for v in vals)
print("\n(pc, opcode) histogram, checked against image:")
for (pc,op),n in pairs.most_common(14):
    note=""
    if img is not None and 0x800000<=pc<0x800000+len(img)-4:
        o=pc-0x800000
        exact =struct.unpack('>H',img[o:o+2])[0]
        plus2 =struct.unpack('>H',img[o+2:o+4])[0]
        minus2=struct.unpack('>H',img[o-2:o])[0] if o>=2 else None
        swap  =((exact&0xFF)<<8)|(exact>>8)
        if   op==exact:  note="== image[pc]           FETCH CLEAN"
        elif op==plus2:  note=f"== image[pc+2] (img has {exact:04X})  WORD SKEW +2"
        elif op==minus2: note=f"== image[pc-2] (img has {exact:04X})  WORD SKEW -2"
        elif op==swap:   note=f"== byteswap(image[pc])          BYTE SWAP"
        else:            note=f"image[pc]={exact:04X} +2={plus2:04X}  NO MATCH"
    elif pc<0x8000: note="(RAM -- no image to compare)"
    print(f"  pc=0x{pc:06X} op=0x{op:04X} x{n:<4} {note}")
print(f"\n{{vint,ipl}}: "+" ".join(f"{k:X}x{n}" for k,n in ints.most_common()))
g=vals
for nm,hi,lo in [("vbl",75,68),("xint",67,60),("qint",59,52)]:
    print(f"{nm}_cnt first->last: {fld(g[0],hi,lo)} -> {fld(g[-1],hi,lo)}")
