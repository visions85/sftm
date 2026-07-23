# AGENTS.md

This file provides guidance to WARP (warp.dev) when working with code in this repository.

## Project overview

SFTM is a work-in-progress FPGA core for **Street Fighter: The Movie** (Incredible Technologies itech32 arcade platform), built on [JTFRAME](https://github.com/jotego/jtcores) for the MiSTer FPGA target. Status: **startup video diagnostic confirmed working on hardware** — ROM downloads via MRA, 256-frame white screen visible after reset (video pipeline confirmed), then black (game not yet running). All RTL is Verilog (GPLv3) except TG68K.C (VHDL, LGPL), vendored as a git submodule at `cores/sftm/hdl/tg68k/`.

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

### Full build (requires Quartus, Linux x86-64)

```sh
./docker/run.sh jtframe mra sftm        # generate .mra and ROM download descriptor
./docker/run-synth.sh                   # synthesise and build .rbf; output: release/mister/jtsftm.rbf
```

Note: `run-synth.sh` copies `sftm.rbf` → `jtsftm.rbf` to match the `<rbf>jtsftm</rbf>` tag in the MRA.

**If synthesis exits 1 (timing violation)**, the bitstream is still generated but NOT copied to `release/mister/`. Manually copy and deploy:

```sh
cp cores/sftm/mister/output_files/sftm.rbf release/mister/jtsftm.rbf
scp -i ~/.ssh/david_key -o StrictHostKeyChecking=no \
    release/mister/jtsftm.rbf \
    root@10.10.10.98:/media/fat/_Arcade/cores/jtsftm.rbf
# Verify transfer
md5sum release/mister/jtsftm.rbf
ssh -i ~/.ssh/david_key -o StrictHostKeyChecking=no \
    root@10.10.10.98 md5sum /media/fat/_Arcade/cores/jtsftm.rbf
```

After a successful `run-synth.sh` (exit 0), deploy directly:

```sh
scp -i ~/.ssh/david_key -o StrictHostKeyChecking=no \
    release/mister/jtsftm.rbf \
    root@10.10.10.98:/media/fat/_Arcade/cores/jtsftm.rbf
# Verify transfer
md5sum release/mister/jtsftm.rbf
ssh -i ~/.ssh/david_key -o StrictHostKeyChecking=no \
    root@10.10.10.98 md5sum /media/fat/_Arcade/cores/jtsftm.rbf
```

Both `md5sum` outputs must match.

### MiSTer deployment paths

After `./docker/run-synth.sh`, copy to MiSTer via scp:
- RBF: `/media/fat/_Arcade/cores/jtsftm.rbf`
- MRA: `/media/fat/_Arcade/Street Fighter The Movie (v1.12).mra`
- ROM zip: `/media/fat/games/mame/sftm.zip`

Load via MiSTer main menu → `_Arcade` → `Street Fighter The Movie (v1.12)` (NOT direct RBF load — JTFRAME will not download ROM data without MRA).

`./docker/run-synth.sh` uses a separate Docker volume `jtframe-module-amd64` (not `jtframe-module`). Patches in `docker/jtframe-patches/` are applied automatically by `docker/entrypoint.sh` on every container start. Current patches:
- `target/mister/hdl/sys/osd.sv` — replaces behavioral `osd_buffer` with `altsyncram #(.ram_block_type("M10K"))` to force M10K inference (prevents ~40k ALM blowup on Quartus 21.1)
- `arcade_video.v` — GAMMA=0 (removes gamma LUT, saves ~2.2k ALMs)

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
  ghdl -a --std=08 -fsynopsys -frelaxed-rules \
      TG68K_Pack.vhd TG68K_ALU.vhd TG68KdotC_Kernel.vhd TG68K.vhd && \
  ghdl synth --std=08 -fsynopsys -frelaxed-rules --out=verilog TG68KdotC_Kernel \
      > /workspace/cores/sftm/hdl/tg68k/TG68KdotC_Kernel_conv.v
'
```

Post-processing (add dummy Verilog `#(parameter ...)` so `sftm_main.v`'s
`#(.SR_Read(2), ...)` instantiation compiles cleanly):

```sh
python3 -c "
content = open('cores/sftm/hdl/tg68k/TG68KdotC_Kernel_conv.v').read()
old = 'module TG68KdotC_Kernel\\n  (input  clk,'
new = '''module TG68KdotC_Kernel
  #(parameter SR_Read=2, VBR_Stackframe=2, extAddr_Mode=2,
              MUL_Mode=2, DIV_Mode=2, BitField=2,
              BarrelShifter=2, MUL_Hardware=1)
  (input  clk,'''
assert old in content
open('cores/sftm/hdl/tg68k/TG68KdotC_Kernel_conv.v','w').write(content.replace(old, new, 1))
print('PATCHED_OK')
"
```

The resulting `TG68KdotC_Kernel_conv.v` is not committed (listed in `.gitignore`).

Notes on `--std=08 -fsynopsys -frelaxed-rules`: ghdl 4.x bundles a VHDL-93
`std_logic_1164` that defines `=` for `std_logic_vector`, conflicting with
`std_logic_unsigned` (which TG68K_ALU.vhd also uses).  `--std=08` with
`-frelaxed-rules` resolves the ambiguity; `-fsynopsys` permits the Synopsys
package name.  The `libllvm18` package and a `libLLVM-18.so.18.1` symlink are
required — both are supplied by the Dockerfile.

## Architecture

### Module hierarchy

```
sftm_game            (cores/sftm/hdl/sftm_game.v)  — JTFRAME game top
├── sftm_main        — MC68EC020 CPU subsystem
│   ├── TG68KdotC_Kernel  — 68020 CPU (VHDL, vendored at hdl/tg68k/; ghdl synth conversion needed for iverilog sim)
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
- Quartus synthesis fits on 5CSEBA6U23I7: 22,990/41,910 ALMs (55%), 453/553 RAM Blocks (82%), 42/112 DSP Blocks; core loads on MiSTer hardware, ROM downloads via MRA, OSD visible
- ALM reduction: `JTFRAME_NOHQ2X` in `cfg/macros.def` (~9.7k ALMs saved), `JTFRAME_CHEAT` removed (~8k ALMs saved), `NVOICES` reduced 32→4 in `sftm5506.v` (~800 ALMs), filter arithmetic narrowed from 64-bit to 46-bit operands, MLAB annotation on 8KB snd RAM in `sftm_snd.v`
- `docker/jtframe-patches/` patching mechanism: `osd.sv` altsyncram M10K fix + `arcade_video.v` GAMMA=0 applied by `docker/entrypoint.sh` on every `./docker/run-synth.sh` invocation
- Boot vector FSM (copies first 0x80 bytes of prog ROM to RAM before releasing 68020)
- Main RAM/NVRAM BRAM (`sftm_ram`), protection byte snooper (`sftm_prot`)
- Full `itech020_map` address decode, sound latch, VIA null stub; mc6809i port map confirmed and wired (cen_E/cen_Q, nRESET, RnW, ADDR, D/DOut, nIRQ/nFIRQ/nNMI, nHALT, nDMABREQ)
- 6809 sound subsystem address decode (`sftm_snd`): latch at 0x0400, ES5506 at 0x0800–0x08FF
- Video register file (0x00–0x88), CRTC (H/V counters, sync, blank, interrupts), two VRAM planes, 15-bit palette RAM
- IT42 blitter: transparency, X/Y flip, clip rect, SRC_XSTEP (8.8 fp, fractional accumulator), DST_XSTEP (8.8 fp, DSTXSCALE flag), DST_YSTEP (8.8 fp, always active), WIDTHPIX flag decoded
- ES5506 (`sftm5506`): 32-voice scheduler, 8-bit host interface, PAGE/ACTIVE registers, forward loop (LPE), reverse loop (DIR), bidirectional loop (BLE), one-shot stop, bank offset, 4-pole IIR filter (K1/K2 per voice; apply_lowpass/apply_highpass matching MAME es5506.cpp; LP mode from control[9:8]), volume/pan mix, 20-bit saturation; correct OTTO-spec register map (LVRAMP/RVRAMP/ECOUNT/K2 in low pages; K1/K2RAMP/K1RAMP in high pages); envelope/volume ramps (ECOUNT countdown, signed 8-bit LVRAMP/RVRAMP/K1RAMP/K2RAMP deltas applied per sample tick); IRQ vector stacking (one-shot stop + ECOUNT expiry with IRQE fire IRQV; rescan on ack)
- 6 self-checking testbenches (sftm5506 now covers 9 sub-tests), all passing
- `tb_sftm_main_boot` — full-boot bench using real TG68KdotC_Kernel CPU (ghdl-converted); verifies boot-vector copy → CPU reset-vector read → first ROM fetch at 0x800008 (PASS)
- Startup video diagnostic: `sftm_video.v` holds white output for 256 vblanks (~4.3s at 60 Hz) after `game_rst` deasserts post-download; confirms video pipeline alive before game init — **confirmed working on hardware (2026-07-23)**
- `debug_view = debug_bus` wired in `jtsftm_game.v` (was undriven/floating)
- **Black screen root cause found and fixed (2026-07-23)**: LHBL/LVBL were reset to `0` in `sftm_video.v`'s CRTC reset block. `arcade_video.v` latches `VBL` on the first falling edge of HBlank; with LVBL=0 at reset, the latch saw VBlank asserted immediately and held the scan doubler in VBlank forever → black screen. Fix: reset both LHBL and LVBL to `1'b1` (commit `19bd8a5`). Always initialise blanking signals to active (1) in the reset block.

**Not yet implemented / validated:**
- ~~TG68K.C VHDL→Verilog conversion for iverilog sim~~ — DONE (see ghdl command above; `--std=08 -fsynopsys -frelaxed-rules`)
- ~~ROM download via MRA confirmed working~~ — DONE; startup white diagnostic confirmed on hardware (2026-07-23)
- First boot: game does not yet execute (black screen after startup diagnostic — CPU has not yet brought up video)
- ES5506: compressed/u-law sample mode; K1/K2 ramp exact byte-lane scheme (simplified addresses used; validate against MAME register traces); IRQV host_addr 0x38 overlaps K2[7:0] low-byte read (reading 0x38 returns IRQV per current design)
- IT42: YSTEP_PER_X polygon shear, WIDTHPIX source-count-limited row mode
- MRA generation needs `doc/mame.xml` (run `mame -listxml sftm > doc/mame.xml` once MAME is installed; then `./docker/run.sh jtframe mra sftm`)
- NVRAM SD-card persistence, grm3 plane usage

## Validation plan

1. ~~Vendor JTFRAME and TG68K.C~~ — jtframe via `docker/run.sh`; TG68K.C VHDL vendored as submodule at `hdl/tg68k/`; ghdl synth conversion still needed for iverilog sim
2. ~~Run `jtframe mem sftm`~~ — DONE: generated `cores/sftm/mist/sftm_game_sdram.v` and `mem_ports.inc`
3. ~~Hardware build (Quartus)~~ — DONE: 22,990/41,910 ALMs (55%), core loads on MiSTer, ROM downloads via MRA, OSD visible (2026-07-23)
4. ~~Convert TG68K.C for Verilator~~ — DONE: `ghdl synth --std=08 -fsynopsys -frelaxed-rules` produces `TG68KdotC_Kernel_conv.v` (35,339 lines); boot testbench PASS.
5. Run 68020 opcode tests before booting ROM code
6. Log MAME blitter commands and replay into `sftm_blitter` (compare pixel-exact output)
7. ~~ES5506 basic voice scheduler~~ — DONE. Still needed: compare `sftm5506` output against MAME `es5506.cpp` for a captured register/ROM trace
8. ~~Load ROM via MRA~~ — DONE: ROM download progress bar confirmed on hardware (2026-07-23)
9. ~~Verify 256-frame startup white~~ — DONE: white screen confirmed on hardware (2026-07-23); root cause of prior black screen was LHBL/LVBL reset to 0 (fixed in commit `19bd8a5`)
10. Boot to self-test, then attract mode

## Reference

Primary MAME source files used as ground truth:
- `src/mame/itech/itech32.cpp` — CPU/memory map, inputs, protection
- `src/mame/itech/itech32_v.cpp` — IT42 video register semantics
- `src/devices/sound/es5506.cpp` — ES5506 register/voice behaviour
