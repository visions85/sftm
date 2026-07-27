# AGENTS.md

This file provides guidance to WARP (warp.dev) when working with code in this repository.

## Project overview

SFTM is a work-in-progress FPGA core for **Street Fighter: The Movie** (Incredible Technologies itech32 arcade platform), built on [JTFRAME](https://github.com/jotego/jtcores) for the MiSTer FPGA target. Status: **CPU executing and writing RAM — WHITE confirmed (2026-07-27)** — root cause of all prior stuck-CPU symptoms found and fixed: `bus_active` excluded TG68K write cycles (`busstate=11`), silently dropping every CPU write. Fix: `bus_active = (busstate != 2'b01)`. Diagnostic: R=`!wdog_kick_ever`, G=`boot_done_ever` (rom_ok), B=`ram_wr_ever`. Current build md5 `01f3fa2c16a7f89dd8c352ea702d8915`. **Must load via MRA** to use correct SWAB=0 ROM layout. Next: watch for CYAN (wdog kick = outer main loop). All RTL is Verilog (GPLv3) except TG68K.C (VHDL, LGPL), vendored as a git submodule at `cores/sftm/hdl/tg68k/`.

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

Note: `run-synth.sh` promotes `cores/sftm/mister/output_files/sftm.rbf` → `release/mister/sftm.rbf` → `jtsftm.rbf`. This explicit promotion step is necessary because jtcore looks for `output_files/jtsftm.rbf` (with `jt`-prefix) but our Quartus project is named `sftm`, so jtcore's own copy step silently fails.

Use `;` (not `&&`) when chaining the deploy so it runs even on timing-violation exit 1:

```sh
./docker/run-synth.sh; \
  scp -i ~/.ssh/david_key -o StrictHostKeyChecking=no \
    release/mister/jtsftm.rbf \
    root@10.10.10.98:/media/fat/_Arcade/cores/jtsftm.rbf && \
  md5sum release/mister/jtsftm.rbf && \
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

**Status: WHITE confirmed on hardware (2026-07-27)** — CPU is executing real code and writing main RAM. Watchdog kick not yet observed; game is still in init/boot phase. Next target: CYAN (wdog_kick_ever=1 = outer main loop running).

Current diagnostic (sftm_video.v post-startup window):
- **R** = `!wdog_kick_ever` (watchdog register never written)
- **G** = `boot_done_ever` = rom_ok after boot copy — SDRAM served ROM to CPU
- **B** = `nvram_wr_ever` (repurposed) = `ram_wr_ever` — CPU wrote main RAM ($000000–$007FFF)

Color meanings:
- **RED** (G=0,B=0): SDRAM stall — ROM never fetched after boot copy
- **YELLOW** (G=1,B=0): ROM fetch OK but CPU never wrote RAM → crashed within first instructions
- **WHITE** (G=1,B=1,R=1): CPU executing and writing RAM — not yet in outer main loop ← **current hardware state**
- **CYAN** (R→0): wdog kicked → outer main loop running → game booted

**Implemented:**
- JTFRAME folder layout, config files (`cfg/macros.def`, `cfg/mem.yaml`, `cfg/mame2mra.toml`, `cfg/files.yaml`), game-top wiring
- Docker Linux environment (`docker/`) — `./docker/run.sh jtframe mem sftm` generates `cores/sftm/mist/sftm_game_sdram.v` and `mem_ports.inc`
- Quartus synthesis fits on 5CSEBA6U23I7: 23,417/41,910 ALMs (56%), 453/553 RAM Blocks (82%), 42/112 DSP Blocks; core loads on MiSTer hardware, ROM downloads via MRA, OSD visible; timing slack −1.053 ns (consistent across builds — bitstream functional)
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
- **I/O port fixes (commit `e22f31e`, deployed 2026-07-24)**: Three bugs fixed in `sftm_main.v`: (1) All I/O bytes were in the wrong 16-bit half — itech32 `PORT_BIT` places bits 0-7 in the lower half (`cpu_a[1]=1`); our code returned them in the upper half so every input read returned 0x0000. (2) DIPS bit 2 (active-low vblank) was hardwired 0, causing the CPU to spin forever in the vblank-wait loop; fixed by wiring `LVBL` from `sftm_video` into `sftm_main`. (3) Joystick direction bits were transposed (UP↔RIGHT, DOWN↔LEFT); corrected to match MAME layout. `jtsftm_game.v` updated to wire `LVBL` output.
- **CRTC shadow registers (commit `a83fc5b`, deployed 2026-07-24)**: `sftm_video.v` `r_htotal`/`r_vtotal`/`r_hbstart`/`r_vbstart` hold the last non-zero value written to the four CRTC timing registers. Guards `hblank_v`/`vblank_v` were optimised away by Quartus (registers start non-zero at reset); explicit flip-flops survive. Prevents LHBL/LVBL going to 0 when the CPU clears all video registers before reprogramming at boot — same `arcade_video` VBL-latch black-screen mechanism as the original LHBL/LVBL=0 reset bug.
- **3-color blit diagnostic (commit `5a7dd76`, deployed 2026-07-24, md5 `d43c9e7a4e42cdfe07da2d63a791a913`)**: 300-frame post-startup window shows RED/YELLOW/GREEN: RED = blit_start never fired; YELLOW = blit_start fired, blit_done never; GREEN = blit completed.
- **RED confirmed (2026-07-24)**: blit_start never fired in 300 frames; root cause = blank NVRAM causes game to initialise factory defaults then spin in a tight loop waiting for hardware watchdog reset (which was not implemented).
- **Watchdog timer (commit `36a5972`)**: 31-bit counter in `sftm_main.v`; wdog fires after 30 s (`1_439_999_999` cycles @ 48 MHz). `w_rst = rst | wdog_rst` resets all CPU-side logic but NOT NVRAM BRAM (`sftm_ram` has no rst pin). Originally arm-after-first-kick (`wdog_armed` gate) — this was wrong: the itech32 factory-reset path spins without kicking wdog, expecting a hardware reset; with `wdog_armed`, the wdog never fired and the CPU was stuck in MAGENTA forever.
- **Unconditional watchdog (commit `f7259d5`, deployed 2026-07-26, md5 `d89ce5a3925566a9cd36f7016311e270`)**: Removed `wdog_armed` gate; wdog fires after 30 s from every reset regardless of first kick.
- **CPU ROM bcache gap + correct reset vectors (commit `4010b17`, deployed 2026-07-26, md5 `49091add20504fb384770658f9be6a61`)**: Fixed `cpu_rom_gap` (1-cycle rom_cs low pulse on each new ROM LW address change) to prevent bcache stale-data on sequential instruction fetches. Hardcoded reset vectors bypassing SDRAM uncertainty: SSP=`$00008000`, PC=`$00800400` (derived from actual prom chip data). Diagnostic: R=`!wdog_kick_ever`, G=`boot_done_ever` (rom_ok_ever), B=`ram_wr_ever`. Observed: **YELLOW** (G=1, B=0) — ROM fetched but no RAM write.
- **Root cause found — bus_active excluded write cycles (commit `1aca3c8`, deployed 2026-07-27, md5 `01f3fa2c16a7f89dd8c352ea702d8915`)**: TG68K busstate encoding (from VHDL source): `00`=fetch code, `10`=read data, `11`=**write data**, `01`=idle. `nWr <= '0' WHEN state="11"`. Previous `bus_active = (busstate==2'b00 || busstate==2'b10)` excluded write cycles (`busstate=11`), silently dropping **every CPU write**: RAM write-enables always 0 (stack/data writes failed), vreg_cs/pal_cs=0 during writes (no blitter/palette writes), wdog kick writes never detected. This was the root cause of all prior stuck-CPU symptoms — RED/YELLOW persisted because the CPU was running but its writes were invisible. Fix: `bus_active = (busstate != 2'b01)` (any memory access); `bus_rd = (busstate==2'b00 || busstate==2'b10)` used for ROM-only read gating. **WHITE confirmed on hardware (2026-07-27)**: CPU writing RAM.

- **IPL7 non-maskable CPU-alive diagnostic (commit `27cece2`, deployed 2026-07-27)**: Added a synthetic, unconditional level-7 interrupt pulse (`ipl7_pulse`, `IPL7_DBG_DELAY` ≈1s after reset) that fires regardless of the ROM's SR interrupt mask (IPL7/NMI is non-maskable by 68k spec) plus `isr_ipl7_fetch_ever` latch watching for the CPU taking the level-7 autovector. sftm_video.v: BLUE = pulse fired but never taken (CPU/autovector wiring itself broken); MAGENTA (unchanged meaning at time of that commit) = pulse taken (CPU proven alive and correctly autovectoring) but no real IPL1/2/3 interrupt ever taken. **MAGENTA confirmed on hardware again (2026-07-27), sustained for several minutes** — this is diagnostically stronger than the earlier MAGENTA report because it now proves the CPU core, IPL priority encoder, and autovector fetch path are all functioning correctly on real silicon; the stuck state is isolated to either (a) the ROM's own interrupt-mask/enable sequence never executing, or (b) some other real IPL1/2/3 assertion condition never being satisfied.
- **Watchdog-fired-ever diagnostic (commit `8875218`, deployed 2026-07-27)**: Existing diagnostic latches (`isr_vec_fetch_ever`, `ipl_asserted_ever`, `ipl7_pulse_ever`, `isr_ipl7_fetch_ever`, `boot_done_ever`, `nvram_wr_ever`) reset only on hard `rst`, not on `w_rst` (which includes the watchdog-triggered soft reboot `wdog_rst`) — meaning a MAGENTA reading is cumulative across any number of soft reboots within one power cycle and cannot by itself distinguish "stuck on attempt #1, watchdog hasn't fired yet" from "watchdog has already fired one or more times and the CPU deterministically lands back in the identical stuck state on every retry." Added new latch `wdog_fired_ever` in `sftm_main.v` (also reset only on hard `rst`, set on the first `wdog_rst` pulse) and a new ORANGE diagnostic colour in `sftm_video.v`: **ORANGE** = same stuck condition as MAGENTA (IPL7 proven taken, real interrupt never taken) but `wdog_fired_ever=1` — rules out "just needs one NVRAM-factory-init retry" since that retry has demonstrably already happened and the CPU still ended up in the same place. Plain **MAGENTA** now specifically means "still on the very first boot attempt, our own watchdog hasn't fired even once." **ORANGE confirmed on hardware (2026-07-27)**: watchdog has already fired at least once (soft reboot happened) and the CPU deterministically returns to the identical stuck state (real IPL1/2/3 interrupt never taken) on every subsequent attempt. This conclusively rules out the NVRAM-factory-init-retry theory — the ROM's boot code is unconditionally blocked from ever enabling real interrupts, on every single boot, regardless of NVRAM/watchdog state. Verified in simulation (`iverilog`) that `wdog_fired_ever` latches correctly on a forced watchdog timeout and survives a subsequent soft reboot (`w_rst`); all pre-existing testbenches continue to pass with no regressions. Boot vector-copy FSM (`boot_lw`/`boot_half`/`boot_done`/`boot_we`) confirmed to reset and correctly restart on `w_rst`.
- **DUART/LED-sign zero-read decode (commit `c8f3d66`, deployed 2026-07-27)**: MAME's `itech020_map` (line 1021 of `itech32.cpp`) decodes `0x680800`–`0x68083f` ("Serial DUART Channel A/B & Top LED sign") as `readonly().nopw()` — a zero-initialised, read-only backing store, so real hardware/MAME always returns `0x0000` for reads there. Our FPGA had no decode at all for this range — reads fell through to the catch-all default of `16'hffff`. Added explicit `duart_cs` decode (`cpu_a[23:6]==18'h1_A020`) returning `16'h0000` on read. New standalone testbench `/tmp/tb_duart.v` confirmed the decode boundary exactly. All five testbenches passed with no regressions. **STILL ORANGE confirmed on hardware (2026-07-27)** — this fix did NOT resolve the symptom. The DUART range was not the poll the boot code is stuck on (or it is, but zero was already effectively what it was reading via some other path, or the actual block is a completely different address range/mechanism). Ruled out as sole root cause; the real interrupt is still never taken and the CPU still deterministically returns to the same stuck state every boot.
- **NVRAM pre-load path-resolution investigation — RESOLVED, not a bug (this session)**: Re-examined the long-standing open question of whether the relative path `../hdl/nvram_hi.hex`/`../hdl/nvram_lo.hex` (used in `sftm_ram.v`'s `$readmemh` calls, added in commit `0c94376`) actually resolves correctly at real Quartus synthesis time, given that `iverilog` simulation runs always print `$readmemh: Unable to open ... for reading` for these files (CWD differs between simulation and Quartus). Found and read the real Quartus build log `log/mister/sftm.log` (Fri Jul 24 17:28-17:48 2026): `Info: Project Name = /workspace/cores/sftm/mister/sftm` confirms Quartus's working directory is `cores/sftm/mister/`, so the RTL's relative path correctly resolves to `cores/sftm/hdl/nvram_hi.hex`/`nvram_lo.hex`. Further confirmed via the `u_nvram` `altsyncram` megafunction instantiation parameters in the same log: `Parameter "INIT_FILE" = "db/sftm.ram1_sftm_ram_6064f7c.hdl.mif"` (mem_lo) and `"db/sftm.ram0_sftm_ram_6064f7c.hdl.mif"` (mem_hi) — Quartus's internal `.mif` conversion of the source `.hex` files, proving `$readmemh` DID find and load them at synthesis time. No "Unable to open" error appears anywhere in the real build log. **Conclusion: the NVRAM pre-load path resolution is correct and was never actually broken** — the `iverilog` warning is a harmless simulation-only artifact (different CWD) and this theory is ruled out as a cause of the ORANGE symptom.
- **New lead found while checking the same build log — inconclusive**: `log/mister/sftm.log` lines 2659-2660 show `Warning (18550): Found RAM instances implemented as ROM because the write logic is disabled` naming one specific atom: `...sftm_ram:u_nvram|altsyncram:mem_hi_rtl_0|altsyncram_p2r1:auto_generated|ram_block1a13`. This warning appears exactly once in the whole log, and affects only one physical M10K sub-block of the NVRAM **high-byte** lane specifically (not `mem_lo`, not the main-RAM `u_ram` instance, not PAL/VRAM). Could not determine from the log alone whether this reflects a genuine narrow hardware bug (one address sub-range of NVRAM's high byte can never be written) or a benign Quartus BRAM-partitioning optimizer artifact. Treated as inconclusive; motivated adding an empirical write-detection diagnostic rather than committing to it as root cause.
- **NVRAM-write-ever diagnostic added (this session, uncommitted RTL pending push)**: Added new latch `nvram_region_wr_ever` in `sftm_main.v` (reset only on hard `rst`, same rationale as `wdog_fired_ever`; set the first time `nvram_we_lo || nvram_we_hi` fires, i.e. any CPU write — either byte lane — to the NVRAM address region `0x600000`-`0x61ffff`) and two new diagnostic colours in `sftm_video.v`, using the same proven single-partial-channel-swap technique as ORANGE (swapping to a partial BLUE channel instead of partial GREEN to keep the four "stuck" states maximally distinct): **MAROON** (`show_stuck & wdog_fired_ever & nvram_region_wr_ever`, R=0x1F/G=0x00/B=0x0A) = stuck, watchdog has fired at least once, AND the CPU has written the NVRAM region at least once; **LILAC** (`show_stuck & ~wdog_fired_ever & nvram_region_wr_ever`, R=0x1F/G=0x0A/B=0x1F) = stuck, watchdog never fired, AND NVRAM has been written at least once. ORANGE and MAGENTA are now additionally gated on `~nvram_region_wr_ever` (unchanged meaning otherwise: ORANGE = stuck + wdog fired + NVRAM never written; MAGENTA = stuck + wdog never fired + NVRAM never written). New standalone testbench `/tmp/tb_nvramwr.v` confirms: (a) the latch stays low before the test program's `MOVE.W #$1234,(0x600000).L` executes, (b) it correctly goes high immediately after that write executes and the write actually lands in the backing store (`mem_lo[0]==8'h34` verified), (c) it survives a subsequent forced watchdog soft reboot (`w_rst`), never cleared except by hard `rst`. All six testbenches (`tb_masked`, `tb_isr`, `tb_ipl7`, `tb_wdogfired`, `tb_duart`, `tb_nvramwr`) pass with no regressions. `sftm_video.v` and `sftm_main.v` both re-elaborate cleanly standalone (`iverilog -t null`) with the new ports. Purpose: disambiguate whether the ROM's boot code ever attempts to touch NVRAM at all on this stuck path — ORANGE (unchanged) would mean NVRAM is never written, pointing at the ROM's own boot-sequence logic or a completely different unimplemented range; MAROON would mean NVRAM IS written at least once, keeping NVRAM-persistence/aliasing/checksum theories alive (including the inconclusive `Warning (18550)` lead above) despite the watchdog having already fired. **STILL ORANGE confirmed on hardware (2026-07-27)** — after an initial uncertain report (briefly described as a dark purple, tentatively read as MAROON), the user re-checked and confirmed on reflection it is the same ORANGE as before, unchanged. This means `nvram_region_wr_ever` is reading 0: **the CPU never writes the NVRAM region at all on this stuck boot path.** This conclusively rules out the entire family of NVRAM-write/persistence/aliasing/checksum-verification theories (including the `Warning (18550)` high-byte-lane lead — moot if NVRAM is never written to begin with) as an explanation for the stuck state. Combined with the DUART fix also not resolving it, the block must be either (a) in the ROM's own interrupt-mask/enable sequence executing before it would ever reach NVRAM or interrupts, or (b) gated on a completely different, still-unimplemented I/O range/condition the boot code polls earlier in its sequence. Next direction: trace the itech32 boot/init sequence in MAME source more carefully to find what specific condition gates the transition into interrupt-enabled operation, rather than adding further NVRAM-focused diagnostics.
- **Colour-perception risk noted**: the user's report of this result went through some uncertainty (dark purple → tentatively MAROON → re-confirmed ORANGE) before settling. This is a signal that even solid, single-partial-channel-swap colours sharing a common dominant channel (ORANGE/MAGENTA/MAROON/LILAC all share full RED, varying only which secondary channel gets a partial value) may not be reliably distinguishable in practice on the real display. Any future diagnostic colour added to this same stuck-state family should lean toward maximally different hues (e.g. spatially separating indicators, or using totally different colour families) rather than another subtle partial-channel variant, to avoid repeating this ambiguity.

**Not yet implemented / validated:**
- ~~TG68K.C VHDL→Verilog conversion for iverilog sim~~ — DONE (see ghdl command above; `--std=08 -fsynopsys -frelaxed-rules`)
- ~~ROM download via MRA confirmed working~~ — DONE; startup white diagnostic confirmed on hardware (2026-07-23)
- **Light-blue screen confirmed (2026-07-24, md5 `73a9446b49a49730f779d1aee428e628`)**: After 256-frame white diagnostic, game transitions to solid light-blue background. CPU is executing game code, writing palette RAM (background colour visible), CRTC/blanking working. Blitter/sprite layer not yet rendering — no graphics drawn over background.
- **grom_cs toggle fix + blit diagnostic (commit `e0f72b7`, deployed 2026-07-24, md5 `c9e5a35e3ef76956005be6856b34ffae`)**: Root cause found — `jtframe_romrq_bcache` comment states `addr_ok` must go low→high for each new address request; blitter was keeping `grom_cs` permanently high throughout the entire blit, so the SDRAM cache never re-issued reads when `grom_addr` changed between pixels (returned stale cache data or no response). Fix: `grom_cs <= 0` in STEP state, `grom_cs <= 1` in FETCH state — clean rising edge on every pixel request. Post-startup diagnostic added: 60 frames of GREEN after the white startup = blitter completed ≥1 blit; RED = no blits completed. Awaiting hardware observation.
- **RED confirmed (wdog_kick_ever=0, pal_wr_ever=0, 2026-07-25)**: CPU never executed. Root cause: `rom_cs` was hardwired `1'b1` during the 32-LW boot copy FSM — same `jtframe_romrq_bcache` stale-cache bug as grom_cs. Cache returned addr-0 data for all 32 words (no cs rising edge to trigger re-fetch), so the 68020 reset vector was all copies of LW-0 → CPU branched to a garbage address and crashed before any observable write. **boot_cs fix (commit `3d77bb5`, deployed 2026-07-25, md5 `5ffa5bf3681d580a55711b5392376ae5`)**: Added `boot_cs` register; pulses low for 1 cycle when `boot_lw` increments, re-asserts high to trigger next SDRAM fetch. Diagnostic: R=`!wdog_kick_ever`, G=`wdog_kick_ever`, B=`pal_wr_ever`. Expected: GREEN (watchdog kicked) once CPU starts. Awaiting hardware observation.
- ES5506: compressed/u-law sample mode; K1/K2 ramp exact byte-lane scheme (simplified addresses used; validate against MAME register traces); IRQV host_addr 0x38 overlaps K2[7:0] low-byte read (reading 0x38 returns IRQV per current design)
- IT42: YSTEP_PER_X polygon shear, WIDTHPIX source-count-limited row mode
- MRA generation needs `doc/mame.xml` (run `mame -listxml sftm > doc/mame.xml` once MAME is installed; then `./docker/run.sh jtframe mra sftm`)
- NVRAM SD-card persistence, grm3 plane usage

## Validation plan

1. ~~Vendor JTFRAME and TG68K.C~~ — jtframe via `docker/run.sh`; TG68K.C VHDL vendored as submodule at `hdl/tg68k/`; ghdl synth conversion still needed for iverilog sim
2. ~~Run `jtframe mem sftm`~~ — DONE: generated `cores/sftm/mist/sftm_game_sdram.v` and `mem_ports.inc`
3. ~~Hardware build (Quartus)~~ — DONE: 23,417/41,910 ALMs (56%), core loads on MiSTer, ROM downloads via MRA, OSD visible; timing slack −1.281 ns (consistent — bitstream functional); I/O port fix + CRTC shadow registers deployed 2026-07-24 (md5 `73a9446b49a49730f779d1aee428e628`)
4. ~~Convert TG68K.C for Verilator~~ — DONE: `ghdl synth --std=08 -fsynopsys -frelaxed-rules` produces `TG68KdotC_Kernel_conv.v` (35,339 lines); boot testbench PASS.
5. Run 68020 opcode tests before booting ROM code
6. Log MAME blitter commands and replay into `sftm_blitter` (compare pixel-exact output)
7. ~~ES5506 basic voice scheduler~~ — DONE. Still needed: compare `sftm5506` output against MAME `es5506.cpp` for a captured register/ROM trace
8. ~~Load ROM via MRA~~ — DONE: ROM download progress bar confirmed on hardware (2026-07-23)
9. ~~Verify 256-frame startup white~~ — DONE: white screen confirmed on hardware (2026-07-23); root cause of prior black screen was LHBL/LVBL reset to 0 (fixed in commit `19bd8a5`)
10. ~~Boot past white screen~~ — DONE: light-blue background confirmed (2026-07-24); CPU running game code, palette RAM functional
11. ~~grom_cs fix deployed~~ — RED confirmed: blit_start never fired; NVRAM spin loop identified
11a. **VBlank ISR fixes deployed (commit `ef70dd5`, 2026-07-24)** — observe diagnostic: GREEN = blitter works; YELLOW = blit_start fired but SDRAM issue; RED = still stuck.
12. Boot to self-test, then attract mode (blitter rendering graphics over blue background)

## Reference

Primary MAME source files used as ground truth:
- `src/mame/itech/itech32.cpp` — CPU/memory map, inputs, protection
- `src/mame/itech/itech32_v.cpp` — IT42 video register semantics
- `src/devices/sound/es5506.cpp` — ES5506 register/voice behaviour
