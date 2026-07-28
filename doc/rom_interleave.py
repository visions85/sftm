#!/usr/bin/env python3
"""Assemble the sftm 68EC020 program ROM from its four byte-lane PROMs.

MAME loads these with ROM_LOAD32_BYTE into a ROM_REGION32_BE, so byte N of
the program image comes from file (N mod 4) at index (N div 4). Rather than
TRUST that lane order, we test all 24 permutations and score each by whether
the resulting reset vector is plausible: on itech32 the 68020 boots because
the driver copies the first 0x80 bytes of ROM into main RAM at address 0, so
image[0:4] is the initial SSP and image[4:8] is the initial PC. A correct
interleave must put the PC inside the program ROM window 0x800000-0xbfffff.
"""
import itertools, struct, sys

files = [open(f"/home/user/workspace/rom/prom{i}.bin", "rb").read() for i in range(4)]
n = len(files[0])
assert all(len(f) == n for f in files), "PROMs differ in size"


def interleave(order):
    out = bytearray(n * 4)
    for lane, src in enumerate(order):
        out[lane::4] = files[src]
    return bytes(out)


RAM_END = 0x008000
ROM_LO, ROM_HI = 0x800000, 0xC00000

print(f"each PROM = {n} bytes ({n//1024} KB); image = {n*4} bytes ({n*4//1024} KB)\n")
print("permutation scoring (lane0,lane1,lane2,lane3 <- prom index):")
best = []
for order in itertools.permutations(range(4)):
    img = interleave(order)
    ssp, pc = struct.unpack(">II", img[0:8])
    score = 0
    notes = []
    if ROM_LO <= pc < ROM_HI:
        score += 10
        notes.append("PC in ROM")
    if pc % 2 == 0:
        score += 1
        notes.append("PC even")
    if ssp % 2 == 0:
        score += 1
        notes.append("SSP even")
    if ssp <= RAM_END:
        score += 3
        notes.append("SSP in RAM")
    # A real vector table's entries should mostly be even and in a sane range.
    vecs = struct.unpack(">64I", img[0:256])
    sane = sum(1 for v in vecs if v % 2 == 0 and (v < RAM_END or ROM_LO <= v < ROM_HI))
    score += sane // 8
    print(f"  {order}  SSP={ssp:08X}  PC={pc:08X}  sane_vecs={sane}/64  "
          f"score={score:2d}  {', '.join(notes)}")
    best.append((score, order))

best.sort(reverse=True)
top, order = best[0]
if best[1][0] == top:
    print("\n!! AMBIGUOUS: multiple permutations tie. Not guessing.")
    sys.exit(1)
print(f"\nWINNER (unique): lane order {order}, score {top}")

img = interleave(order)
open("/home/user/workspace/rom/prog.bin", "wb").write(img)
print("wrote /home/user/workspace/rom/prog.bin")
