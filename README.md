# JTSFTM — Street Fighter: The Movie (arcade) for MiSTer/JTFRAME

A work-in-progress FPGA core for **Street Fighter: The Movie** (`sftm`), the
Incredible Technologies 32-bit ("itech32") arcade platform, built on top of
[JTFRAME](https://github.com/jotego/jtcores).

> Status: **early scaffold**. This repository contains the core structure,
> configuration and RTL skeletons. The CPU, video/blitter and ES5506 sound
> chip are only partially implemented — see `cores/sftm/doc/sftm.txt` and the
> `TODO:` markers in the RTL. It does **not** yet boot a game.

## Hardware being recreated (from MAME `itech/itech32.cpp`)

| Block        | Part                    | Notes |
|--------------|-------------------------|-------|
| Main CPU     | Motorola MC68EC020 @ 25 MHz | 68020 instruction set, 24-bit address |
| Sound CPU    | Motorola MC6809 @ 2 MHz | command latch from main CPU |
| Sound chip   | Ensoniq ES5506 (OTTO) @ 16 MHz | 32-voice sample playback |
| Blitter      | IT42 custom             | 2 VRAM planes, scale/flip/clip/transparency |
| Palette      | 15-bit RGB              | |
| Video        | ~384x256, ~60 Hz, 15.6 kHz | |

ROM footprint is ~36 MB (≈32.5 MB graphics, ≈2.5 MB samples, 1 MB program,
256 KB sound), which is why the **128 MB SDRAM module** is required (see
`cores/sftm/hdl/mem.yaml`).

## Repository layout

This tree mimics a `jtcores` checkout (`$JTROOT`) so the core can be built with
the standard JTFRAME flow:

```
.
├── cores/
│   └── sftm/
│       ├── cfg/           # macros.def, files.yaml, mame2mra.toml
│       ├── hdl/           # jtsftm_*.v, jt5506.v, mem.yaml
│       ├── ver/game/      # simulation test benches
│       └── doc/           # core notes
└── modules/               # JTFRAME goes here (git submodule)
```

## Building (Linux)

JTFRAME's toolchain is Linux-only (Quartus, Verilator, ghdl). To build:

```sh
# 1. Get jtcores + JTFRAME (which provides setprj.sh and the jtframe tool)
git clone --recursive https://github.com/jotego/jtcores
# 2. Drop this core in place
cp -r cores/sftm  <path-to-jtcores>/cores/sftm
cd <path-to-jtcores>
source setprj.sh
# 3. Generate memory/MRA and compile for MiSTer
jtframe mra sftm
jtcore sftm -mister
```

Alternatively, add JTFRAME here as a submodule under `modules/jtframe` and use
this directory as `$JTROOT`.

## The 68EC020 CPU (TG68K.C)

JTFRAME bundles `fx68k` (68000 only), which cannot run the 68EC020. We use
**TG68K.C** in 68020 mode. It is VHDL, so for JTFRAME's Verilator simulation it
must be converted to Verilog with `ghdl` or `vhd2vl` (see
`cores/sftm/doc/sftm.txt`). TG68K.C is functional (not cycle-exact); game speed
is tuned via the CPU clock-enable.

## License

RTL authored here is GPLv3 to match JTFRAME. Third-party cores keep their own
licenses (TG68K.C: LGPL; mc6809: see its header). No ROMs are included.
