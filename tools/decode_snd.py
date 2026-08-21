#!/usr/bin/env python3
"""Decode SFSN (ISSP instance 6, build 106+): the sound triage probe.

Input: lines of `RAW6 <hex>` from /tmp/read-snd.sh. Layout (128 bits):
  [127:120] 0x6E signature        [ 79: 72] cr0      voice-0 CR low byte
  [119:112] cmd_wcnt  68020 latch1 writes
  [111:104] cmd_rcnt  6809 latch1 reads
  [103:100] lsnd      snd lane probe state
  [ 99: 96] lsrom     srom lane probe state
  [ 95: 88] eswr      ES5506 register writes
  [ 87: 83] actv      ES5506 ACTV
  [ 82]     anyrun    any voice STOP bits clear
  [ 81]     pending1  latch1 pending   [ 80] pending2
  [ 71: 64] crn       CR write count   [ 63: 56] sromn  sample fetches
  [ 55: 48] sromd     last sample byte [ 47: 40] crv    last CR value
  [ 39: 33] crp       page of that CR write
  [ 32: 17] peak      output peak      [  7:  0] 0xA5 signature tail
"""
import sys, collections

def main():
    rows = []
    for line in sys.stdin if len(sys.argv) < 2 else open(sys.argv[1]):
        parts = line.split()
        if len(parts) == 2 and parts[0] == "RAW6":
            # quartus_stp returns the probe as a BINARY string
            v = int(parts[1], 2 if set(parts[1]) <= {"0", "1"} and len(parts[1]) > 32 else 16)
            if (v >> 120) != 0x6E or (v & 0xFF) != 0xA5:
                print(f"BAD SIGNATURE: {parts[1]}")
                continue
            rows.append(v)
    if not rows:
        print("no RAW6 lines")
        return
    f = lambda v, hi, lo: (v >> lo) & ((1 << (hi - lo + 1)) - 1)
    print(f"{len(rows)} samples")
    def col(name, hi, lo, fmt="d"):
        vals = [f(v, hi, lo) for v in rows]
        u = sorted(set(vals))
        shown = ", ".join(format(x, fmt) for x in u[:8])
        print(f"  {name:9s} {shown}{' ...' if len(u) > 8 else ''}")
    col("cmd_wcnt", 119, 112)
    col("cmd_rcnt", 111, 104)
    col("lsnd", 103, 100, "04b")
    col("lsrom", 99, 96, "04b")
    col("eswr", 95, 88)
    col("actv", 87, 83)
    col("anyrun", 82, 82)
    col("pending1", 81, 81)
    col("pending2", 80, 80)
    col("cr0", 79, 72, "02x")
    col("crn", 71, 64)
    col("sromn", 63, 56)
    col("sromd", 55, 48, "02x")
    col("crv", 47, 40, "02x")
    col("crp", 39, 33, "02x")
    col("peak", 32, 17, "04x")
    w = [f(v, 119, 112) for v in rows]
    r = [f(v, 111, 104) for v in rows]
    print()
    if max(w) == 0:
        print("VERDICT: the 68020 never writes the sound latch.")
    elif max(r) == 0:
        print("VERDICT: commands are written but the 6809 NEVER reads the")
        print("         latch -> its IRQ/read path is dead (or the CPU is).")
    elif max(r) < max(w):
        print(f"VERDICT: partial reads ({max(r)} of {max(w)}): the 6809 runs but")
        print("         falls behind or stopped -- look at lsnd/eswr history.")
    else:
        print("VERDICT: latch commands flow both ways; if there is still no")
        print("         audio, the driver declines to key voices (anyrun/peak).")

main()
