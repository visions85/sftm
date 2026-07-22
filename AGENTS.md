# AGENTS.md

This file provides guidance to WARP (warp.dev) when working with code in this repository.

## Project overview

SFTM is a work-in-progress FPGA core for **Street Fighter: The Movie** (Incredible Technologies itech32 arcade platform), built on [JTFRAME](https://github.com/jotego/jtcores) for the MiSTer FPGA target. Status: **early scaffold** — the core does not yet boot a game. All RTL is Verilog (GPLv3) except TG68K.C (VHDL, LGPL), which is not yet vendored.

## Commands

### Run individual unit tests (iverilog, no JTFRAME required)

Each testbench includes its exact run command as a comment at the top. General pattern:

```sh
# sftm_prot
iverilog -g2012 -Wall -o /tmp/tb_sftm_prot.vvp \
    cores/sftm/ver/game/tb_sftm_prot.v cores/sftm/hdl/sftm_prot.v && \
vvp /tmp/tb_sftm_prot.vvp

# sftm_ram
iverilog -g2012 -Wall -o /tmp/tb_sftm_ram.vvp \
    cores/sftm/ver/game/tb_sftm_ram.v cores/sftm/hdl/sftm_ram.v && \
vvp /tmp/tb_sftm_ram.vvp
```

```sh
# sftm_blitter
iverilog -g2012 -Wall -o /tmp/tb_sftm_blitter.vvp \
    cores/sftm/ver/game/tb_sftm_blitter.v cores/sftm/hdl/sftm_blitter.v && \
vvp /tmp/tb_sftm_blitter.vvp

# sftm_main (boot FSM + reset state — uses CPU stubs)
iverilog -g2012 -Wall -o /tmp/tb_sftm_main.vvp \
    cores/sftm/ver/game/tb_sftm_main.v \
    cores/sftm/hdl/sftm_main.v \
    cores/sftm/hdl/sftm_ram.v \
    cores/sftm/hdl/sftm_prot.v \
    cores/sftm/ver/game/stubs.v && \
vvp /tmp/tb_sftm_main.vvp

# sftm5506 (ES5506 voice scheduler, loop modes, and 4-pole filter)
iverilog -g2012 -Wall -o /tmp/tb_sftm5506.vvp \
    cores/sftm/ver/game/tb_sftm5506.v cores/sftm/hdl/sftm5506.v && \
vvp /tmp/tb_sftm5506.vvp

# sftm_video (register file, CRTC, VRAM, blitter integration)
iverilog -g2012 -Wall -o /tmp/tb_sftm_video.vvp \
    cores/sftm/ver/game/tb_sftm_video.v \
    cores/sftm/hdl/sftm_video.v \
    cores/sftm/hdl/sftm_blitter.v \
    cores/sftm/hdl/sftm_vram.v \
    cores/sftm/hdl/sftm_pal.v && \
vvp /tmp/tb_sftm_video.vvp
```

For modules that depend on vendored CPUs (`sftm_main`, `sftm_snd`, `sftm_video`, `sftm_game`), include `cores/sftm/ver/game/stubs.v` in the iverilog invocation to satisfy the `TG68KdotC_Kernel` and `mc6809i` black boxes.

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
./docker/run.sh jtframe mem sftm        # regenerate sftm_game_sdram.v + mem_ports.inc from cfg/mem.yaml
./docker/run.sh jtframe cfgstr sftm     # evaluate cfg/macros.def
```

### TG68K.C conversion for Verilator simulation

TG68K.C is vendored as a git submodule at `cores/sftm/hdl/tg68k/`
(source: `https://github.com/TobiFlex/TG68K.C`).  For Quartus synthesis the
VHDL files are included directly (mixed-language synthesis).  For iverilog/
Verilator simulation, convert using `ghdl synth` inside Docker (Docker image
now uses `ghdl-llvm` which supports synthesis):

```sh
./docker/run.sh bash -c '
  cd /workspace/cores/sftm/hdl/tg68k && \
  ghdl -a -fsynopsys TG68K_Pack.vhd TG68K_ALU.vhd TG68KdotC_Kernel.vhd TG68K.vhd && \
  ghdl synth --out=verilog TG68KdotC_Kernel > TG68KdotC_Kernel_conv.v
'
```

The resulting `TG68KdotC_Kernel_conv.v` is not committed (generated artifact).

## Architecture

### Module hierarchy

```
sftm_game            (cores/sftm/hdl/sftm_game.v)  — JTFRAME game top
├── sftm_main        — MC68EC020 CPU subsystem
│   ├── TG68KdotC_Kernel  — 68020 CPU (VHDL, not yet vendored; hdl/tg68k/)
│   ├── sftm_ram     — byte-lane 16-bit BRAM (main RAM and NVRAM)
│   └── sftm_prot    — protection byte snooper (0x680002)
├── sftm_video       — IT42 blitter + CRTC + VRAM + palette
│   ├── sftm_blitter — GROM→VRAM DMA state machine
│   ├── sftm_vram    — dual-port 8-bit plane BRAM (fg + bg instances)
│   └── sftm_pal     — 15-bit palette RAM
└── sftm_snd         — MC6809 + ES5506 sound
    ├── mc6809i        — JTFRAME-provided 6809 wrapper (not yet vendored)
    └── sftm5506         — Ensoniq ES5506 "OTTO" (cores/sftm/hdl/sftm5506.v)
```

### Key data flows

**CPU bus**: `sftm_main` drives `cpu_addr[23:1]`, `cpu_dout[15:0]`, `cpu_rnw`, `cpu_uds_n/cpu_lds_n` plus chip-select lines (`vram_cs`, `vreg_cs`, `pal_cs`) decoded from the address. `sftm_video` receives these and muxes responses back to the main module.

**SDRAM**: Four banks defined in `cfg/mem.yaml`. `jtframe mem sftm` generates the SDRAM arbiter (`cores/sftm/mist/sftm_game_sdram.v`) and port stubs (`mem_ports.inc`). Bank 0 = 68020 program + 6809 ROM; bank 1 = ES5506 sample ROM; bank 2 = 32 MB main graphics (GROM); bank 3 = extra graphics (grm3). The 32 MB GROM region requires the 128 MB SDRAM module.

**Blitter (IT42)**: `sftm_video` writes blitter parameters into `vregs[]`, then asserts `blit_start`. `sftm_blitter` walks GROM sequentially, writes 8-bit pixels to VRAM. Implemented: transparency, X/Y flip, clip rect, SRC_XSTEP (8.8 fp source-side horizontal scaling with fractional accumulator), DST_XSTEP (8.8 fp destination-side horizontal stretch, active when DSTXSCALE flag set), DST_YSTEP (8.8 fp destination row stride, always active), WIDTHPIX flag decoded. Not yet: YSTEP_PER_X polygon shear, WIDTHPIX source-count mode.

**Boot vector copy**: On reset, `sftm_main` holds the CPU in reset while a FSM copies the first 0x80 bytes of program ROM into main RAM (the 68020 reset SSP/PC must reside at 0x000000, which is RAM on itech32). The CPU is released only after `boot_done`.

**Sound latch**: Main CPU writes to 0x480001 → `snd_latch[7:0]` + `snd_latch_we` pulse → 6809 reads via `sftm_snd`.

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

**Implemented:**
- JTFRAME folder layout, config files (`cfg/macros.def`, `cfg/mem.yaml`, `cfg/mame2mra.toml`, `cfg/files.yaml`), game-top wiring
- Docker Linux environment (`docker/`) — `./docker/run.sh jtframe mem sftm` generates `cores/sftm/mist/sftm_game_sdram.v` and `mem_ports.inc`
- Boot vector FSM (copies first 0x80 bytes of prog ROM to RAM before releasing 68020)
- Main RAM/NVRAM BRAM (`sftm_ram`), protection byte snooper (`sftm_prot`)
- Coarse CPU address decode, sound latch, VIA null stub
- Video register file (0x00–0x88), CRTC (H/V counters, sync, blank, interrupts), two VRAM planes, 15-bit palette RAM
- IT42 blitter: transparency, X/Y flip, clip rect, SRC_XSTEP (8.8 fp, fractional accumulator), DST_XSTEP (8.8 fp, DSTXSCALE flag), DST_YSTEP (8.8 fp, always active), WIDTHPIX flag decoded
- ES5506 (`sftm5506`): 32-voice scheduler, 8-bit host interface, PAGE/ACTIVE registers, forward loop (LPE), reverse loop (DIR), bidirectional loop (BLE), one-shot stop, bank offset, 4-pole IIR filter (K1/K2 per voice; apply_lowpass/apply_highpass matching MAME es5506.cpp; LP mode from control[9:8]), volume/pan mix, 20-bit saturation
- 6 self-checking testbenches, all passing

**Not yet implemented / validated:**
- Exact `itech020_map` address decode and input/DIP bit layout
- TG68K.C VHDL→Verilog conversion for iverilog sim (VHDL is vendored; use `ghdl synth` inside Docker — see above)
- Exact MC6809 wrapper port map
- ES5506: K1/K2 ramps, envelope/volume ramps, IRQ vector stacking, compressed/u-law sample mode
- IT42: YSTEP_PER_X polygon shear, WIDTHPIX source-count-limited row mode
- `jtframe mra sftm` MRA generation not yet validated
- NVRAM SD-card persistence, grm3 plane usage, hardware build (Quartus)

## Validation plan

1. ~~Vendor JTFRAME and TG68K.C~~ — jtframe via `docker/run.sh`; TG68K.C VHDL vendored as submodule at `hdl/tg68k/`; ghdl synth conversion still needed for iverilog sim
2. ~~Run `jtframe mem sftm`~~ — DONE: generated `cores/sftm/mist/sftm_game_sdram.v` and `mem_ports.inc`
3. Convert TG68K.C for Verilator — run `ghdl synth` inside Docker (Dockerfile now uses `ghdl-llvm`; see the command above). Produces `TG68KdotC_Kernel_conv.v` for iverilog/Verilator sim.
4. Run 68020 opcode tests before booting ROM code
5. Log MAME blitter commands and replay into `sftm_blitter` (compare pixel-exact output)
6. ~~ES5506 basic voice scheduler~~ — DONE. Still needed: compare `sftm5506` output against MAME `es5506.cpp` for a captured register/ROM trace
7. Boot to self-test, then attract mode

## Reference

Primary MAME source files used as ground truth:
- `src/mame/itech/itech32.cpp` — CPU/memory map, inputs, protection
- `src/mame/itech/itech32_v.cpp` — IT42 video register semantics
- `src/devices/sound/es5506.cpp` — ES5506 register/voice behaviour
