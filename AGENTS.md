# AGENTS.md

This file provides guidance to WARP (warp.dev) when working with code in this repository.

## Project overview

JTSFTM is a work-in-progress FPGA core for **Street Fighter: The Movie** (Incredible Technologies itech32 arcade platform), built on [JTFRAME](https://github.com/jotego/jtcores) for the MiSTer FPGA target. Status: **early scaffold** — the core does not yet boot a game. All RTL is Verilog (GPLv3) except TG68K.C (VHDL, LGPL), which is not yet vendored.

## Commands

### Run individual unit tests (iverilog, no JTFRAME required)

Each testbench includes its exact run command as a comment at the top. General pattern:

```sh
# jtsftm_prot
iverilog -g2012 -Wall -o /tmp/tb_jtsftm_prot.vvp \
    cores/sftm/ver/game/tb_jtsftm_prot.v cores/sftm/hdl/jtsftm_prot.v && \
vvp /tmp/tb_jtsftm_prot.vvp

# jtsftm_ram
iverilog -g2012 -Wall -o /tmp/tb_jtsftm_ram.vvp \
    cores/sftm/ver/game/tb_jtsftm_ram.v cores/sftm/hdl/jtsftm_ram.v && \
vvp /tmp/tb_jtsftm_ram.vvp
```

```sh
# jtsftm_blitter
iverilog -g2012 -Wall -o /tmp/tb_jtsftm_blitter.vvp \
    cores/sftm/ver/game/tb_jtsftm_blitter.v cores/sftm/hdl/jtsftm_blitter.v && \
vvp /tmp/tb_jtsftm_blitter.vvp

# jtsftm_main (boot FSM + reset state — uses CPU stubs)
iverilog -g2012 -Wall -o /tmp/tb_jtsftm_main.vvp \
    cores/sftm/ver/game/tb_jtsftm_main.v \
    cores/sftm/hdl/jtsftm_main.v \
    cores/sftm/hdl/jtsftm_ram.v \
    cores/sftm/hdl/jtsftm_prot.v \
    cores/sftm/ver/game/stubs.v && \
vvp /tmp/tb_jtsftm_main.vvp
```

For modules that depend on vendored CPUs (`jtsftm_main`, `jtsftm_snd`, `jtsftm_video`, `jtsftm_game`), include `cores/sftm/ver/game/stubs.v` in the iverilog invocation to satisfy the `TG68KdotC_Kernel` and `mc6809i` black boxes.

### Docker Linux environment (JTFRAME toolchain, ghdl)

A pre-configured Docker image handles `jtframe` commands and `ghdl` on any OS.

```sh
# First run: builds image, sparse-clones jtframe module, compiles jtframe binary
./docker/run.sh

# One-liner commands
./docker/run.sh jtframe mem sftm              # regenerate SDRAM arbiter + mem_ports.inc
./docker/run.sh jtframe mem sftm -target mister  # output to cores/sftm/mister/ instead of mist/
./docker/run.sh jtframe mra sftm              # generate .mra ROM descriptor

# Force image rebuild (after Dockerfile changes)
./docker/run.sh --rebuild
```

The sftm repo is mounted at `/workspace` (= `$JTROOT`). The jtframe module lives in a
persistent Docker volume `jtframe-module` at `/workspace/modules/jtframe`.
Generated output (`cores/sftm/mist/` or `mister/`) is written back to the host repo.

### Full build (requires Quartus, Linux)

```sh
./docker/run.sh jtframe mra sftm        # generate .mra and ROM download descriptor
./docker/run.sh jtcore sftm -mister     # synthesise and build .rbf (needs Quartus)
```

### JTFRAME helper commands

```sh
./docker/run.sh jtframe mem sftm        # regenerate jtsftm_game_sdram.v + mem_ports.inc from cfg/mem.yaml
./docker/run.sh jtframe cfgstr sftm     # evaluate cfg/macros.def
```

### TG68K.C conversion for Verilator simulation

```sh
cd cores/sftm/hdl/tg68k
ghdl -a -fsynopsys TG68K_Pack.vhd TG68K_ALU.vhd TG68KdotC_Kernel.vhd TG68K.vhd
ghdl synth --out=verilog TG68KdotC_Kernel > TG68KdotC_Kernel_conv.v
```

## Architecture

### Module hierarchy

```
jtsftm_game            (cores/sftm/hdl/jtsftm_game.v)  — JTFRAME game top
├── jtsftm_main        — MC68EC020 CPU subsystem
│   ├── TG68KdotC_Kernel  — 68020 CPU (VHDL, not yet vendored; hdl/tg68k/)
│   ├── jtsftm_ram     — byte-lane 16-bit BRAM (main RAM and NVRAM)
│   └── jtsftm_prot    — protection byte snooper (0x680002)
├── jtsftm_video       — IT42 blitter + CRTC + VRAM + palette
│   ├── jtsftm_blitter — GROM→VRAM DMA state machine
│   ├── jtsftm_vram    — dual-port 8-bit plane BRAM (fg + bg instances)
│   └── jtsftm_pal     — 15-bit palette RAM
└── jtsftm_snd         — MC6809 + ES5506 sound
    ├── mc6809i        — JTFRAME-provided 6809 wrapper (not yet vendored)
    └── jt5506         — Ensoniq ES5506 "OTTO" (cores/sftm/hdl/jt5506.v)
```

### Key data flows

**CPU bus**: `jtsftm_main` drives `cpu_addr[23:1]`, `cpu_dout[15:0]`, `cpu_rnw`, `cpu_uds_n/cpu_lds_n` plus chip-select lines (`vram_cs`, `vreg_cs`, `pal_cs`) decoded from the address. `jtsftm_video` receives these and muxes responses back to the main module.

**SDRAM**: Four banks defined in `cfg/mem.yaml`. `jtframe mem sftm` generates the SDRAM arbiter (`cores/sftm/mist/jtsftm_game_sdram.v`) and port stubs (`mem_ports.inc`). Bank 0 = 68020 program + 6809 ROM; bank 1 = ES5506 sample ROM; bank 2 = 32 MB main graphics (GROM); bank 3 = extra graphics (grm3). The 32 MB GROM region requires the 128 MB SDRAM module.

**Blitter (IT42)**: `jtsftm_video` writes blitter parameters into `vregs[]`, then asserts `blit_start`. `jtsftm_blitter` walks GROM sequentially, writes 8-bit pixels to VRAM (with transparency, x/y flip). Scaling and clip rect are TODO.

**Boot vector copy**: On reset, `jtsftm_main` holds the CPU in reset while a FSM copies the first 0x80 bytes of program ROM into main RAM (the 68020 reset SSP/PC must reside at 0x000000, which is RAM on itech32). The CPU is released only after `boot_done`.

**Sound latch**: Main CPU writes to 0x480001 → `snd_latch[7:0]` + `snd_latch_we` pulse → 6809 reads via `jtsftm_snd`.

### Configuration files

| File | Purpose |
|------|---------|
| `cfg/macros.def` | JTFRAME macro flags (core name, video timings, button count, SDRAM config) |
| `cfg/files.yaml` | Source file list; tells JTFRAME what Verilog/VHDL to include for synthesis and simulation |
| `cfg/mame2mra.toml` | ROM download region ordering — must be in bank order (BA0→BA1→BA2→BA3) |
| `cfg/mem.yaml` | SDRAM bank/bus layout; input to `jtframe mem sftm` which generates the SDRAM glue |
| `docker/` | Linux build environment (jtframe toolchain, ghdl) — use `./docker/run.sh` |

### Simulation stubs

`cores/sftm/ver/game/stubs.v` provides non-functional black boxes for `TG68KdotC_Kernel` and `mc6809i`. Include it when simulating any module that instantiates those CPUs before the real cores are vendored.

## Current implementation status

**Implemented:** JTFRAME folder layout, config files, game-top wiring, coarse CPU address decode, boot vector FSM, main RAM/NVRAM BRAM, video register file, CRTC, two VRAM planes, palette RAM, basic unscaled blitter (transparency + flips), sound subsystem skeleton, ES5506 register/voice/basic mix.

**Not yet implemented / validated:** exact `itech020_map` address decode, exact input/DIP bit layout, TG68K.C vendoring, exact MC6809 wrapper port map, ES5506 filters/envelopes/loop modes/IRQ stacking/compressed mode, IT42 scaling/clipping/scroll, MRA generation syntax for installed JTFRAME version, NVRAM SD-card persistence, grm3 plane usage, hardware build.

## Validation plan (from `doc/sftm.txt`)

1. ~~Vendor JTFRAME and TG68K.C~~ — jtframe is accessible via `docker/run.sh`; TG68K.C still needed for full simulation
2. ~~Run `jtframe mem sftm`~~ — DONE: generated `cores/sftm/mist/jtsftm_game_sdram.v` and `mem_ports.inc`
3. Convert TG68K.C for Verilator (ghdl/vhd2vl) or use mixed-language simulation
4. Run 68020 opcode tests before booting ROM code
5. Log MAME blitter commands and replay into `jtsftm_blitter`
6. Unit-test `jt5506` against MAME `es5506.cpp` sample outputs
7. Boot to self-test, then attract mode

## Reference

Primary MAME source files used as ground truth:
- `src/mame/itech/itech32.cpp` — CPU/memory map, inputs, protection
- `src/mame/itech/itech32_v.cpp` — IT42 video register semantics
- `src/devices/sound/es5506.cpp` — ES5506 register/voice behaviour
