#!/usr/bin/env python3
"""Generate the NVRAM power-on images the core synthesises with.

cores/sftm/hdl/sftm_main.v does

    $readmemh("../hdl/nvram_hi.hex", nvram_hi);
    $readmemh("../hdl/nvram_lo.hex", nvram_lo);

to give the 128 KB NVRAM a sane factory state at power-on. Those two .hex
files are game-derived data and are NOT distributed with this repository, so
you must generate them from your own NVRAM dump before synthesising.

Where to get the input: run the `sftm` set in MAME once, quit, and take the
128 KB file MAME writes to its nvram directory (nvram/sftm/nvram32).

    ./doc/make_nvram_hex.py path/to/nvram32

A factory dump leaves the volume at 0x05, which is inaudible. Either set the
volume in the game's operator menu before quitting MAME, or pass --volume to
patch byte 0x14 directly:

    ./doc/make_nvram_hex.py path/to/nvram32 --volume 0x1e

0x1e is the value the core was brought up with. The rest of the operator
settings are whatever your dump carries; they do not affect bring-up.

MAME's region is 32-bit big-endian, so file byte 0 is the HIGH byte of word 0:
even byte offsets belong to nvram_hi, odd to nvram_lo. That split is what keeps
a dump taken back off the SD card byte-identical to MAME's own.

Initialise the WHOLE 128 KB, not just the low 32 KB that SD-card persistence
covers. A partial image is inconsistent by construction -- the game rejects it
and drops into its setup screen. Without any image at all the NVRAM powers up
blank, the volume byte reads zero, and the core is silent.
"""
import argparse
import sys
from pathlib import Path

SIZE = 128 * 1024
VOLUME_OFS = 0x14
HDL = Path(__file__).resolve().parent.parent / "cores" / "sftm" / "hdl"


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("dump", help="128 KB MAME nvram32 dump")
    ap.add_argument("--volume", type=lambda s: int(s, 0), default=None,
                    help="patch the volume byte at 0x14 (e.g. 0x1e)")
    args = ap.parse_args()

    src = Path(args.dump)
    data = bytearray(src.read_bytes())
    if len(data) != SIZE:
        print(f"error: {src} is {len(data)} bytes, expected {SIZE} "
              f"(a full 128 KB dump, not the persisted low 32 KB)")
        return 1

    if args.volume is not None:
        if not 0 <= args.volume <= 0xFF:
            print(f"error: --volume {args.volume:#x} out of range")
            return 1
        print(f"volume 0x{data[VOLUME_OFS]:02X} -> 0x{args.volume:02X}")
        data[VOLUME_OFS] = args.volume
    elif data[VOLUME_OFS] == 0x05:
        print("warning: volume byte is 0x05 (factory default, inaudible); "
              "pass --volume 0x1e or set it in the operator menu")

    for name, lane in (("nvram_hi.hex", data[0::2]), ("nvram_lo.hex", data[1::2])):
        out = HDL / name
        out.write_text("".join(f"{b:02X}\n" for b in lane))
        print(f"wrote {out} ({len(lane)} bytes)")

    return 0


if __name__ == "__main__":
    sys.exit(main())
