# AGENTS.md

This file provides guidance to WARP (warp.dev) when working with code in this repository.

## Project overview

SFTM is a work-in-progress FPGA core for **Street Fighter: The Movie** (Incredible Technologies itech32 arcade platform), built on [JTFRAME](https://github.com/jotego/jtcores) for the MiSTer FPGA target. Status (2026-07-30): CPU is confirmed alive and executing indefinitely, but never reaches its outer main loop **on real hardware** — deterministic hang, same on every boot. **Major update this session**: a corrected, full-ROM iverilog simulation (the complete real 1MB ROM image reconstructed from the four PROM dumps, not an excerpted window like every earlier simulation) with RAM properly zero-initialised boots cleanly through the RAM self-test, reads real hardware/DIP ports (independently cross-checked byte-for-byte against MAME's actual `itech020_map`), and **reaches and sustains the documented outer main loop for ~25 million instruction fetches** (many, many watchdog kicks) — the exact opposite of every hardware symptom (`wdog_kick_ever` never fires on real silicon). This is strong new evidence the root cause is **not** a logic bug reachable by behavioural RTL simulation — it must be something simulation cannot model: real synthesis timing, a TG68K VHDL→Verilog conversion discrepancy between simulated and synthesised behaviour, SDRAM/BRAM inference timing, or a genuine board issue. The earlier `genuine_exc_fetch_addr=0x800410`/`word=0x003C` hardware capture was flagged mid-session as methodologically suspect (`genuine_exc_*` latches only on hard `rst`, never `w_rst`, and could in principle be silently consumed by the design's own forced IPL7 diagnostic pulse before any real game exception) — but a follow-up diagnostic **closed that concern in the CPU's favour**: a new `genuine_exc_*2` capture that re-arms on every watchdog soft reboot and is structurally immune to IPL7 latch-theft (`exc_vec_rd` now excludes the interrupt-autovector range) read back **byte-identical** on real hardware — `vec=11`/`0x800410`/`0x003C`, exactly matching the original. `0x800410`/`0x003C` is not a stale one-off; it is what real hardware faults on, reproducibly. Combined with the clean full-ROM simulation result, every alternative explanation (stale capture, IPL7 theft, RAM-test false-positive, missing timing constraints) is now ruled out — what's left is squarely in real-hardware-only territory (synthesis timing, a TG68K conversion discrepancy, SDRAM/BRAM inference). **Recommended next direction**: SignalTap (real in-system capture) is the clearly necessary next tool — a USB Blaster clone has been ordered; a SignalTap `.stp` capture file (`sftm_ram_fault.stp`, triggered on `genuine_exc_seen2`) is already built and its node references verified correct against the real project, staged via `docker/jtframe-patches/`, but **enabling it through the scripted jtcore build fails** (structural incompatibility with jtcore's per-stage-separate-process methodology, confirmed across four different mechanisms — see the dated entry below); the practical path is enabling it through Quartus's own GUI on gamingpc once the Blaster arrives, which compiles as one session rather than separate CLI invocations. Also useful for that capture: the ROM's own internal crash handler (`0x8008F0`-`0x800930`, `jmp $800930.l` self-halt) records its exception code to RAM `0x0FBE` — the existing `exc_code_ram` diagnostic mirrors this live; its hardware reading (`0x2700`, reconfirmed) is a RAM-test-sweep artifact, not evidence real hardware ever reaches this handler. **Must load via MRA** to use correct SWAB=0 ROM layout. All RTL is Verilog (GPLv3) except TG68K.C (VHDL, LGPL), vendored as a git submodule at `cores/sftm/hdl/tg68k/`.

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
- **MAME itech32.cpp interrupt/protection investigation (this session)**: Traced `itech32_state::update_interrupts(vint,xint,qint)` (line 440) — with the default `m_irq_base=0` (set in `machine_start()`, line 480; only `drivedge_state` overrides it to `2`, and `sftm` uses the base `itech32_state`, confirming real IPL1/2/3 map to vint/xint/qint exactly as our FPGA already assumes — the earlier VBlank=IPL1 fix in commit `b794e86` remains correct, does NOT need to be reopened). `generate_int1` (line 458) fires `update_interrupts(1,-1,-1)` on VBLANK — matches our existing `int1_ack`/vint wiring. **Bigger lead found**: `sftm` (and all itech32/itech020-family games in this driver) have a genuine **PIC 16C54 protection microcontroller** on the real PCB (labeled `ITSF-1` for Street Fighter: The Movie — see `GAME()` macro comment, line 5239). MAME does not emulate the PIC; `itech32_state::itech020_prot_result_r()` (line 637) simply echoes back whatever byte the CPU last wrote to a fixed main-RAM address (`m_itech020_prot_address`, `0x7a6a` for the primary `sftm` set per `init_sftm()`→`init_sftm_common(0x7a6a)`, line 4993) through the `0x680002` port. Sibling games in the same driver (`gt2kp`/`gtclasscp`, lines ~5136-5175) document the disassembled protection-check pattern verbatim: `move.b 680002,d0 ; andi.b #mask,d0 ; cmpi.b #expected,d0 ; Label1: bne.s Label1` — an infinite self-loop if the echoed byte doesn't match what the code expects. This is structurally identical to our stuck symptom (deterministic hang, same state every boot, before ever reaching the interrupt-enable instruction) and was previously completely unexamined — our `sftm_prot.v` module already implements the write-then-echo mechanism correctly (matches MAME's `itech020_prot_result_r` behaviour exactly: snoops the write to RAM word `0x3d35` high byte, presents it on `0x680002` read), so the mechanism itself is not suspected of being wrong — the goal instead is to observe empirically whether the real ROM's boot code ever reaches and exercises this write/read pair at all.
- **Protection write/read diagnostic added (this session, commits pending)**: Added two new cumulative `_ever` latches in `sftm_main.v`, following the identical convention as `wdog_fired_ever`/`nvram_region_wr_ever` (reset only on hard `rst`, set-and-hold on hard `rst`-only, never cleared by `w_rst`/soft reboot): `prot_wr_ever` (set the first time the CPU writes the high byte of RAM word `0x3d35`, i.e. address `0x7a6a` — mirrors the exact `wr_addr==PROT_WORD && we_hi` condition already fed into `sftm_prot.v`'s `u_prot` instance) and `prot_rd_ever` (set the first time the CPU performs a qualified read — `cen & bus_rd & prot_cs` — from port `0x680002`). Wired through `jtsftm_game.v` (`sftm_main` → `sftm_video`) following the same pattern as all prior diagnostic signals.
  - **New display mechanism — counted WHITE flashes, not another colour**: Given the colour-perception risk noted above, this diagnostic deliberately does NOT add a fifth/sixth same-hue-family colour. Instead, while in the existing `show_stuck` state (any of ORANGE/MAGENTA/MAROON/LILAC), the display now overlays a sequence of brief solid-WHITE flashes on top of the base colour, timed off `vblank_irq` (~60 Hz): `N = 1 + {prot_wr_ever, prot_rd_ever}` (range 1-4). Each flash is ~0.5 s ON (WHITE) / ~0.5 s OFF (back to base colour); after completing N flashes there is a longer ~1.5 s steady hold at the base colour before the count repeats, giving a clear, countable, unambiguous readout: **N=1** → protection port never written AND never read (boot code hasn't reached the protection check in code at all — hang is earlier and unrelated to protection); **N=2** → written but never read back (RAM write happened, the `0x680002` poll never followed — unexpected); **N=3** → read without ever being written first (also unexpected — port polled with nothing supplied to echo); **N=4** → both write and read observed at least once (protection hand-off completed at least once; if still stuck despite this, the loop likely needs more than a single write/read pass, e.g. comparing against an incrementing/rotating target value, or the true hang is elsewhere).
  - New standalone testbench `/tmp/tb_prot.v` (169 lines) injects a `MOVE.W #$1234,($7A6A).L` followed by `MOVE.B ($680002).L,D0` then a `BRA.S -2` spin at the hardcoded boot PC; confirms both latches read 0 immediately after reset, `prot_wr_ever` sets after the write executes (while `prot_rd_ever` is still checked at that same later checkpoint), `prot_rd_ever` sets after the read executes, and both remain latched (never clear) while the CPU continues spinning — PASS, no errors. Re-ran all six pre-existing testbenches (`tb_ipl7`, `tb_masked`, `tb_isr`, `tb_wdogfired`, `tb_duart`, `tb_nvramwr`) — all still PASS, no regressions. Both `sftm_main.v` and `sftm_video.v` re-elaborate cleanly standalone (`iverilog -t null`) with the new ports/logic. **Awaiting hardware observation of the flash count.**
- **HARDWARE RESULT (commit `0db0286`, 2026-07-27): N=3 (`prot_wr_ever=0`, `prot_rd_ever=1`)**. Base colour confirmed unchanged ORANGE (watchdog fired at least once, NVRAM region never written, real interrupt never taken). The new flash count reveals: the CPU genuinely reaches and executes a read of the protection port `0x680002` — the protection check IS reached in code — but the RAM byte at `0x7a6a` (word `0x3d35` high byte) it's supposed to echo back was **never written first**, contrary to the write-then-poll pattern documented for sibling games (`gt2kp`/`gtclasscp`). Checked whether this is a ROM-revision address mismatch: `init_sftm()` uses `0x7a6a` for the primary `sftm` v1.12 set (and Japan/Korea siblings) while `init_sftm110()` uses `0x7a66` for v1.11/v1.10 — but `AGENTS.md`'s own MRA target is explicitly v1.12, matching our `0x7a6a` assumption on paper, so a simple revision mismatch is not yet confirmed (the actual loaded ROM data could still differ from MAME's "sftm" set despite a similarly-named MRA). Independently re-verified the byte-lane/address math end-to-end (MAME's `result >>= (~m_itech020_prot_address & 3) * 8` shift-by-address-parity logic vs. our `cpu_a[14:1]==14'h3d35` + `high_byte_we` decode) and confirmed both derivations agree: byte address `0x7a6a` maps to the HIGH byte of 16-bit word `0x3d35` exactly as our RTL already assumes — ruled out a byte-lane/address decode bug on our side.
- **New question raised by N=3, and new diagnostic added to answer it (this session, commit pending)**: N=3 alone is ambiguous — it could mean the CPU is genuinely stuck spinning forever on this exact read (protection is the live, direct blocker), OR it could mean the check's real semantics don't require a prior write at all (e.g. comparing the echoed byte against a fixed constant like zero, which our `sftm_prot.v` already returns by default before any write), in which case the check may have already PASSED via a single read and the CPU is stuck somewhere completely different downstream — making the read/write asymmetry an interesting side-fact rather than the actual hang point. To disambiguate, added a new **saturating counter** `prot_rd_count` (2 bits, 0-3, saturating at 3 = "3 or more") in `sftm_main.v`, counting DISTINCT protection-port read *accesses* since hard reset (reset only on hard `rst`, same `_ever`-family convention). Critically, this required **edge detection**, not a level count: the existing `prot_word_rd` qualifying condition (`cen & bus_rd & prot_cs`) is a level that can stay true across several `cen` ticks for a single CPU bus access (confirmed via the `tb_isr.v` trace showing `busstate` held constant across multiple consecutive samples before a bus strobe completes) — counting that level directly would have wildly over-counted even a single instruction's read as if it were many. Added `prot_rd_lvl_d` (previous-cycle sample of the level) and `prot_rd_edge = prot_word_rd & ~prot_rd_lvl_d` to count only rising edges, i.e. exactly one increment per distinct read instruction executed, regardless of how many internal cycles that access spans. A tight poll loop running at CPU clock speed would saturate this counter within microseconds, so a steady-state reading of 3 while the display is stuck is strong, near-conclusive evidence of an active spin loop at this exact read — versus a steady 1 (read once, moved on) which would rule protection out as the live blocker entirely. **The flash-count overlay in `sftm_video.v` has been REPURPOSED** to display `1 + prot_rd_count` (still 1-4 flashes, same WHITE-flash mechanism, timing unchanged) since the older `prot_wr_ever`/`prot_rd_ever` boolean pair has already been fully answered by the N=3 result above and is now a settled, documented fact rather than a live question: **N=1** = never read (shouldn't occur, kept for completeness); **N=2** = read exactly once then moved on (protection likely PASSED or was a one-shot probe — NOT the live blocker); **N=3** = read exactly twice (ambiguous, possible single retry); **N=4** = read 3+ times / saturated (near-certain active spin loop on this exact read — protection IS the live blocker). New standalone testbench `/tmp/tb_protcount.v` (194 lines, two phases separated by a hard-reset pulse): Phase 1 injects a single `MOVE.B ($680002).L,D0` followed by `BRA.S -2` (self-loop that does NOT re-touch the port) — confirms `prot_rd_count` settles at exactly 1 and, critically, does **not** climb further even after 200,000+ additional clock cycles of spinning on the unrelated self-branch (the key regression this test guards against). Phase 2 injects the same read followed by `BRA.S -8` (branches back to the read, tight re-read loop) — confirms the counter climbs and correctly saturates at 3, and stays at 3 (never wraps) after prolonged further looping. All 6 checks PASS. Re-ran all 7 pre-existing testbenches (`tb_ipl7`, `tb_masked`, `tb_isr`, `tb_wdogfired`, `tb_duart`, `tb_nvramwr`, `tb_prot`) — all still PASS, no regressions. **Awaiting hardware observation of the new flash count.**
- **CORRECTION -- bit-order bug in interpretation, not in hardware (2026-07-27)**: The commit-`0db0286` build's `flash_count = 1 + {prot_wr_ever, prot_rd_ever}` was implemented correctly, but the AGENTS.md table above (and what the user was told) mis-stated what the concatenation means. Verilog `{A,B}` makes `A` the MSB (weight 2) and `B` the LSB (weight 1), so the ACTUAL mapping was `N=1->(wr=0,rd=0)`, `N=2->(wr=0,rd=1)`, `N=3->(wr=1,rd=0)`, `N=4->(wr=1,rd=1)` -- verified directly with a standalone `iverilog` check (`/tmp/check_concat.v`). The hardware report of "N=3" therefore actually meant **`prot_wr_ever=1`, `prot_rd_ever=0`**: the CPU DOES write the protection RAM byte at `0x7a6a`, but NEVER reads the `0x680002` port afterward -- the **opposite** of what was previously documented and told to the user ("read but never written"). The `init_sftm`/`init_sftm110` ROM-revision address check and the byte-lane/address math re-verification recorded above remain valid and correctly ruled out (they don't depend on which of wr/rd was 1 vs 0), but the framing "CPU reaches the protection check, RAM byte never supplied" is backwards -- it should read "CPU supplies the RAM byte via a write, but never goes on to read it back." The commit-`1981076` build's `prot_rd_count` diagnostic (built on the mistaken premise that reads were happening and needed counting) reported **N=1**, i.e. `prot_rd_count==0` -- never read -- which is fully CONSISTENT with this corrected reading: both builds agree the write happens and the read never does. `prot_rd_count`'s own logic (edge-detection, saturation) is unaffected by this bug and remains correctly implemented and tested; only the flash-count *formula/table*, and the resulting interpretation, were affected.
- **New diagnostic: does the CPU stay alive after the protection write? (commit pending)**: With read now confirmed 0 by two independently-decoded, consistent results, the live question shifts from "how many times is the read repeated" to: does the CPU keep running normally after the protection write and reach its real main loop (which kicks the game's own watchdog register `REG_WDOG`, per the disassembled `jsr $8006BA` + wdog-kick + loop pattern already latched as `wdog_kick_ever`), or does it stall/crash right around the write and never get that far? Both `prot_wr_ever` and `wdog_kick_ever` were already wired into `sftm_video.v` from earlier diagnostics, so this needed only a formula change (no new ports): `flash_count = 1 + {prot_wr_ever, wdog_kick_ever}`, bit order re-verified via a fresh standalone `iverilog` check (`/tmp/check_concat2.v`) before writing the table this time. **N=1**: `wr=0,kick=0` -- write never happened AND CPU never reached its main loop -- stuck very early, before both. **N=2**: `wr=0,kick=1` -- CPU reaches/kicks its main loop repeatedly, but the protection write never happened -- would mean the write finding doesn't hold on this run, or the write lies on a path the main loop doesn't take. **N=3**: `wr=1,kick=0` -- confirms the write happens, but the CPU never reaches its main loop afterward -- strongly suggests it stalls or crashes shortly after the write, before ever reaching the real game loop (and thus before the protection read too). **N=4**: `wr=1,kick=1` -- write happens AND the CPU is alive, cycling through its real main loop -- yet still never executes the protection read, pointing at the read living on a conditional/DIP-gated path rather than a CPU crash. `sftm_video.v` re-elaborates cleanly standalone (`iverilog -t null`); all 8 testbenches (`tb_ipl7`, `tb_masked`, `tb_isr`, `tb_wdogfired`, `tb_duart`, `tb_nvramwr`, `tb_prot`, `tb_protcount`) still pass, no regressions (this change only touches the video-side flash formula, not any of the latches those testbenches exercise). **Awaiting hardware observation of the corrected flash count.**
- **HARDWARE RESULT (commit `6a58cf2`, 2026-07-27): N=3 (`prot_wr_ever=1`, `wdog_kick_ever=0`)**. This confirms, on real hardware, what the corrected read of the earlier result already implied: the protection write to `0x7a6a` genuinely happens, but the CPU never reaches its main loop (never kicks `REG_WDOG`) afterward. Still ambiguous between "CPU crashed/halted outright right after the write" and "CPU is alive but looping somewhere in between that just never touches the watchdog register or the protection read."
- **New diagnostic to resolve that ambiguity: is the CPU still fetching instructions at all after the write? (this commit)**: Added `post_wr_fetch_count` in `sftm_main.v` -- a saturating (0-3) edge-detected counter of DISTINCT instruction fetches (`busstate==2'b00`, edge-detected the same way as `prot_rd_count` since the fetch bus state is a LEVEL that can hold across several `cen` ticks per access) counted only once `prot_wr_ever` has already latched. This is a genuinely new signal, not a re-use of an already-answered one, and it does not depend on any specific downstream address (unlike `wdog_kick_ever`, which requires reaching one particular register write) -- it answers "does the CPU keep executing ANY instructions past the write" directly. Wired through `jtsftm_game.v` (both `u_main` and `u_video` instances) identically to prior diagnostics. `sftm_video.v`'s flash overlay REPURPOSED again: `flash_count = 1 + post_wr_fetch_count`. **N=1** (`post_wr_fetch_count==0`) = zero fetches after the write -- strongly indicates a hard crash/halt (e.g. double bus fault) right at/after the write. **N=2/N=3** (`==1`/`==2`) = one or two more fetches then nothing further -- consistent with trapping into an exception vector and then also stopping. **N=4** (`==3`, saturated) = CPU keeps fetching well past the write -- it is alive and executing, just looping somewhere that never reaches the watchdog-kick or protection-read addresses -- points at a loop/branch elsewhere in the boot code, not a raw CPU fault. New standalone testbench `/tmp/tb_postwrfetch.v` (195 lines, two phases separated by a hard-reset pulse): Phase 0 runs an immediate self-loop that NEVER writes the protection byte -- confirms `post_wr_fetch_count` stays at 0 through 200,000+ cycles of unrelated fetch activity, proving the counter is correctly gated on `prot_wr_ever` and does not free-run off raw fetch activity alone (the key regression this test guards against). Phase 1 injects the actual `MOVE.W #$1234,($7A6A).L` write followed by a `BRA.S -2` self-loop -- confirms the counter stays 0 through the write instruction's own multi-word fetch/execute, then starts incrementing from the first fetch strictly after the write completes, saturating at 3 and staying there through prolonged further looping. All 9 checks PASS. Re-ran all 8 pre-existing testbenches (`tb_ipl7`, `tb_masked`, `tb_isr`, `tb_wdogfired`, `tb_duart`, `tb_nvramwr`, `tb_prot`, `tb_protcount`) -- all still PASS, no regressions. Both `sftm_main.v` and `sftm_video.v` re-elaborate cleanly standalone (`iverilog -t null`). **Awaiting hardware observation of the flash count.**

- **HARDWARE RESULT (commit `c9231b1`, 2026-07-27): N=4 (`post_wr_fetch_count==3`, saturated)**. Confirms the CPU is alive and continues executing (3 or more) instructions strictly after the protection write -- this is NOT a hard crash/halt. It never reaches the watchdog-kick or protection-read addresses specifically, but it is doing *something* -- most likely looping somewhere in the boot code between the write and those two checkpoints.
- **New diagnostic, pivoting to a more fundamental question raised much earlier in the session (this commit)**: Combining "CPU alive after the write" with the pre-existing, still-unresolved fact `ipl_asserted_ever=1 & isr_vec_fetch_ever=0` (FPGA asserts an interrupt, CPU never vectors it) suggested a hypothesis: the boot code enters an interrupt-wait spin loop after the write that never exits because the real (maskable) vblank interrupt is never taken. Before pursuing that further, re-examined the much-earlier IPL7 (non-maskable) diagnostic build (commit `27cece2`) whose hardware result was reported as "magenta", not "blue". `show_blue = white_now & ~show_green & ipl7_pulse_ever & ~isr_ipl7_fetch_ever` in `sftm_video.v` -- seeing magenta instead of blue only proves NOT(`ipl7_pulse_ever` AND NOT `isr_ipl7_fetch_ever`), which is ambiguous between two very different explanations: (a) the CPU DID take the guaranteed-unmaskable IPL7 test pulse (`isr_ipl7_fetch_ever=1`), meaning the core's basic autovector/vector-fetch mechanism works fine and the earlier failure to take IPL1/2/3 is a game-specific masking/timing issue; or (b) the one-shot pulse (fires once, ~1s after hard power-on, held 100 clkena cycles, gated on hard `rst` only) simply never got a chance to be observed. Both `ipl7_pulse_ever` and `isr_ipl7_fetch_ever` already exist and are already wired into `sftm_video.v` (no new RTL signals needed) -- this is a pure formula change in the flash overlay, repurposing it again: `flash_count = 1 + {ipl7_pulse_ever, isr_ipl7_fetch_ever}`, bit order re-verified via a fresh standalone `iverilog` check (`/tmp/check_concat3.v`) before writing this table. **N=1**: `pulse=0,taken=0` -- the pulse hasn't fired yet; should not occur after more than a couple seconds of runtime. **N=2**: `pulse=0,taken=1` -- should be impossible (can't take a vector fetch that never had a pulse to trigger it); flags a logic bug in this diagnostic if ever seen. **N=3**: `pulse=1,taken=0` -- DEFINITIVE: the guaranteed unmaskable pulse fired and held for its full window, but the CPU never performed the level-7 autovector read -- points at a fundamental CPU-core/autovector wiring problem affecting ALL interrupt levels uniformly, independent of the game's own masking or the protection sequence entirely. **N=4**: `pulse=1,taken=1` -- the CPU DOES take a forced, guaranteed unmaskable interrupt correctly -- proving the core's basic autovector mechanism works, and any earlier IPL1/2/3 failure must be down to game-specific factors (SR mask, assertion timing/duration, vector-table contents) rather than a CPU-interrupt-interface bug. This change touches only the `sftm_video.v` flash-count formula (no new ports, no new latches) -- reused signals' own latching behavior is independently validated by the pre-existing `tb_ipl7.v` testbench (still passes, confirms in simulation that `ipl7_pulse_ever` fires and `isr_ipl7_fetch_ever` latches correctly when a real level-7 pulse is asserted, even while ordinary IPL1 stays masked). Re-ran the full existing test suite (`tb_ipl7`, `tb_masked`, `tb_isr`, `tb_wdogfired`, `tb_wdogfired_dbg`, `tb_duart`, `tb_nvramwr`, `tb_prot`, `tb_protcount`, `tb_postwrfetch`, `tb_wdog`, `tb_patched`, `tb_color`) against the modified files -- all still PASS (`tb_blinkcount`'s pre-existing failures are unrelated: that test doesn't touch `sftm_video.v` at all and was already failing before this change, left over from the deprecated blink-rate display scheme). Both `sftm_main.v` (unchanged this commit) and `sftm_video.v` re-elaborate cleanly standalone (`iverilog -t null`). **Awaiting hardware observation of the flash count.**

- **HARDWARE RESULT (commit `b50c19f`, 2026-07-27): N=4 (`ipl7_pulse_ever=1`, `isr_ipl7_fetch_ever=1`)**. Also newly observed this round: the base colour started MAGENTA (very likely what was described as "purple" -- the two are easily confused, an already-established caveat this session) for the first ~20-30 seconds, then transitioned to ORANGE. This is EXPECTED, not a new symptom: `show_magenta` is exactly the pre-`wdog_fired_ever` state (still on the first boot attempt, before our own internal diagnostic watchdog has timed out even once), and `show_orange` is the post-`wdog_fired_ever` state. Since `wdog_fired_ever` is a permanent `_ever` latch that never clears once set, every *previous* observation session simply started more than ~20-30s after power-on and only ever caught the already-latched ORANGE state; this is the first time the transition itself was watched from power-on. Confirms the CPU DOES correctly take a forced, guaranteed-unmaskable interrupt -- the core's basic autovector/vector-fetch mechanism works. This rules out a fundamental CPU-interrupt-interface wiring bug and narrows the investigation to game-specific factors (SR interrupt mask, assertion timing/duration, vector-table contents) for why the real IPL1/2/3 requests are never taken.
- **New diagnostic to test the leading such factor directly: is the SR interrupt mask simply never open whenever the real vblank request asserts? (commit pending)**: In `sftm_main.v`, the REAL `vint_latch` request now drives `cpu_ipl` to level 7 (non-maskable, `3'b000`) instead of level 1 (`3'b110`) for this diagnostic build only, and the old synthetic one-shot `ipl7_pulse` no longer drives `cpu_ipl` at all (that line commented out) so `isr_ipl7_fetch_ever`'s meaning is unambiguous this round -- it can now ONLY be set by the real, periodically-recurring (~60 Hz) vblank request. **This is the first diagnostic build this session that changes real interrupt-priority routing, not just a passive counter/display formula** -- as a consequence, `show_blue` in `sftm_video.v` was hardwired to `1'b0` (it depended on the now-repurposed `ipl7_pulse_ever`/`isr_ipl7_fetch_ever` pair meaning something different, and `ipl7_pulse_ever` will still latch on its own untouched ~1s timer regardless of this round's outcome -- leaving the old formula active would have let it wrongly override `show_stuck`, which also gates the flash overlay itself). Flash overlay REPURPOSED again: `flash_count = 1 + {ipl_asserted_ever, isr_ipl7_fetch_ever}`, bit order re-verified via a fresh standalone `iverilog` check (`/tmp/check_concat4.v`). **N=1**: `assert=0,taken=0` -- the vblank request itself never asserts (already known false from earlier in the session; included only as a sanity check). **N=2**: `assert=0,taken=1` -- should be impossible; flags a logic bug if seen. **N=3**: `assert=1,taken=0` -- the real vblank request keeps asserting periodically, but even forced non-maskable, the CPU still never takes it -- would point at something specific to the real `vint_latch` signal path (distinct from the synthetic test that DID succeed) rather than SR masking. **N=4**: `assert=1,taken=1` -- CONFIRMS SR interrupt masking (not any wiring/signal-path issue) is exactly why the real IPL1 request is ignored: the boot code runs with interrupts disabled and never reaches the point where it re-enables them -- matching the "CPU alive but looping" `post_wr_fetch_count` finding perfectly. **Known, deliberate regression-suite exceptions for this build**: `tb_ipl7.v` and `tb_isr.v` now FAIL when run against this build -- both are EXPECTED failures, not bugs: `tb_ipl7.v` directly forces the old `ipl7_pulse` signal and checks that it drives `cpu_ipl`, which it deliberately no longer does this round; `tb_isr.v` exercises the normal unmasked-IPL1 round trip (vblank → `cpu_ipl=IPL1` → read at `0x64-0x67` → ISR → watchdog kick), which necessarily breaks because `vint_latch` now drives level 7 and the vector read lands at `0x3E/0x3F` instead, where this minimal testbench's ROM stub has no ISR set up. All other testbenches (`tb_masked`, `tb_wdogfired`, `tb_wdogfired_dbg`, `tb_duart`, `tb_nvramwr`, `tb_prot`, `tb_protcount`, `tb_postwrfetch`, `tb_wdog`, `tb_patched`) still PASS unaffected. Both `sftm_main.v` and `sftm_video.v` re-elaborate cleanly standalone (`iverilog -t null`). **This build is diagnostic-only and intentionally reroutes real interrupt-priority behaviour -- it must be reverted back to normal IPL1 routing (and `ipl7_pulse` restored) once this result is in, regardless of outcome.** **Awaiting hardware observation of the flash count.**

- **HARDWARE RESULT (commit `81cdd14`, 2026-07-27): N=3 (`ipl_asserted_ever=1`, `isr_ipl7_fetch_ever=0`)**. Base colour showed the same MAGENTA(~30s)->ORANGE transition, with the flash count staying 3 across both phases (confirms the flash-count logic is correctly independent of `wdog_fired_ever`/`nvram_region_wr_ever`, as intended). At face value this is the "genuinely surprising" outcome: the real vblank request keeps asserting periodically, but even forced non-maskable, the CPU still never takes it.
- **Before trusting that result: found and fixed a genuine self-inflicted bug in the previous commit's diagnostic edit, via inspection + a standalone `iverilog` check (`/tmp/check_priority.v`)**. The `cpu_ipl` priority-encoding block in `sftm_main.v` resolves ties between `vint_latch`/`blit_irq`/`scan_irq` by "last statement wins" (sequential non-blocking assignment, not numeric priority) -- correct in the ORIGINAL code, where `vint_latch` legitimately drove the lowest-priority level (IPL1) and being checked first meant it correctly lost to `blit_irq`/`scan_irq` if they coincided. But the previous commit repointed `vint_latch` to level 7 (highest priority) WITHOUT moving it later in the chain, so any cycle where `blit_irq` or `scan_irq` happened to coincide with the forced level-7 request would incorrectly overwrite it down to level 2/3 -- confirmed by `/tmp/check_priority.v` (`vint_latch` alone -> `000` as expected, but `vint_latch`+`scan_irq` together -> wrongly `100`, and `vint_latch`+`blit_irq` together -> wrongly `101`). **Fixed (this commit)** by moving the `vint_latch` check to be applied LAST in the block, so it now always wins regardless of `blit_irq`/`scan_irq` state -- reverified with `/tmp/check_priority2.v` (all three coincidence cases now correctly show `000`, and `blit_irq`/`scan_irq` alone, without `vint_latch`, still correctly produce `101`/`100` as before -- normal operation unaffected). This means the previous N=3 result may have been an artifact of this bug rather than a genuine finding about SR masking -- **re-running the exact same test (no other changes) against the fix to see if the result changes.** Re-ran the full regression suite against the fix: `tb_ipl7` and `tb_isr` still show the same EXPECTED failures documented in the previous entry (they exercise paths this diagnostic build intentionally reroutes); all other testbenches (`tb_masked`, `tb_wdogfired`, `tb_wdogfired_dbg`, `tb_duart`, `tb_nvramwr`, `tb_prot`, `tb_protcount`, `tb_postwrfetch`, `tb_wdog`, `tb_patched`) still PASS, confirming the fix is isolated to the diagnostic-only priority path and introduces no new regressions. `sftm_main.v` re-elaborates cleanly standalone (`iverilog -t null`). **Awaiting hardware observation of the flash count with this fix applied.**

- **HARDWARE RESULT (commit `e98093a`, 2026-07-28): N=4 (`ipl_asserted_ever=1`, `isr_ipl7_fetch_ever=1`)** -- same MAGENTA(~30 s)->ORANGE base transition as before. **The previous N=3 was indeed an artifact of the priority-inversion bug, and with it fixed the answer flips: the CPU DOES take the real vblank request when it is presented as non-maskable.** So the real `vint_latch` signal path is fine, and **SR interrupt masking is CONFIRMED as the reason the real (maskable) IPL1 request is never serviced** -- the boot code runs with interrupts disabled and never reaches the point where it lowers the mask. (Note this probe was never expected to make the game *progress*: forced to level 7, the request vectors through autovector 31 at `0x7C`, not the game's real vblank handler at `0x64`/`0x00800918`, so the CPU jumps to whatever garbage that entry holds. It answers the masking question only.)
- **Forced-IPL7 probe REVERTED (this commit)**, as the previous entry required: `vint_latch` back to `3'b110` (IPL1), synthetic `ipl7_pulse` restored to driving level 7, and `show_blue` in `sftm_video.v` restored to its original formula. A permanent NOTE ON ORDERING comment was left on the `cpu_ipl` block recording *why* its statement order is correct as written (`vint_latch` drives the LOWEST priority level, so it must be checked FIRST to lose ties) and warning that any future change repointing it to a higher level must also move it later in the chain. Confirms the revert is complete and correct: `tb_ipl7` and `tb_isr`, which were EXPECTED failures for the two forced-IPL7 builds, both **PASS again**.
- **Synthesis of everything established so far, and the question it forces**: the CPU (a) writes the protection byte at `0x7a6a`, (b) keeps fetching/executing instructions indefinitely afterwards (`post_wr_fetch_count` saturated -- not a crash or halt), (c) never reaches the watchdog kick or the protection-port read, and (d) runs with interrupts masked the entire time. Point (d) **eliminates the leading hypothesis from earlier in the session** -- the loop cannot be an "await first vsync" spin waiting on a RAM flag that only the VBlank ISR would set, because with interrupts masked that ISR can never run and such a loop could never have been intended to exit. So the CPU must instead be either **polling a hardware register that never returns the value it wants**, or **spinning purely in RAM/ROM** (a delay loop, or a crash loop on garbage).
- **New diagnostic to distinguish those and localise the poll: `poll_region` (this commit)**. New 3-bit signal in `sftm_main.v`, wired through `jtsftm_game.v` into `sftm_video.v` following the same pattern as prior diagnostics. Watches CPU **data reads only** (`busstate==2'b10`; instruction fetches `2'b00` are excluded since they stream through ROM constantly and say nothing about what the loop inspects), classifies each by the existing address decode into one of six I/O regions, and deliberately **ignores main RAM and program ROM** (stack/variable traffic is constant background noise). Arms after `POLL_SAMPLE_DELAY` (~5 s at 48 MHz, hard-`rst`-gated only) then captures and **freezes** -- sample-and-hold rather than "most recent", because a value that oscillated between regions would make the flash count unreadable. **Confirmation filter**: requires **two consecutive qualifying I/O reads hitting the SAME region** before latching, since the watchdog appears to reboot the system repeatedly (which is why ORANGE persists), so boot code re-runs periodically and a single-instant sample could land on incidental start-up traffic rather than the spin loop; a genuine polling loop satisfies this trivially, a boot sequence stepping through varied regions does not. Intervening RAM/ROM reads are skipped rather than breaking the run. **The `poll_rd` qualifier is edge-detected on the RAW bus state and deliberately NOT `cen`-gated** -- a `cen`-gated level yields several pulses per single access, which would let ONE access falsely satisfy the two-read filter and defeat its entire purpose (lesson 9 again, and the specific trap this design had to avoid). Flash overlay repurposed: `flash_count = 1 + poll_region`, now using the overlay's **full 1..7 range** for the first time (verified the existing `flash_done`/`flash_count` timing logic handles 7 correctly: `flash_done` reaches 6, `6+1>=7` terminates the cycle, no 3-bit overflow; `poll_region` is never assigned 7 so `flash_count` cannot wrap to 0). **N=1**: no I/O read at all -- spinning purely in RAM/ROM, touching no hardware register (delay loop or crash loop on garbage). **N=2**: video/CRTC registers `0x500000-0x5000ff` -- **PRIME SUSPECT**, a "wait for vblank/scanline by polling" loop, exactly what boot code would use while interrupts are still masked; if our video register read-back never presents the bit the code waits on it spins forever, which would explain every symptom observed. **N=3**: inputs/system/DIP. **N=4**: DUART `0x680800-0x68083f` -- a sound-CPU handshake that never completes. **N=5**: NVRAM. **N=6**: palette / read-as-zero region. **N=7**: protection port -- sanity check only, should never appear since `prot_rd_ever` is hardware-confirmed 0. New testbench `/tmp/tb_pollregion.v` (175 lines, 7 phases, drives the DUT's internal selects and bus state via `force`/`release`): verifies the arming delay is respected; RAM/ROM-only reads never capture; alternating regions do NOT confirm; two consecutive same-region reads DO confirm; the value is frozen once latched (later different-region reads cannot overwrite); **a single access whose read state is held 40 cycles does NOT self-confirm** (the level-vs-edge hazard, the single most important regression here); and interleaved RAM reads don't break a genuine run. All 9 checks PASS. **Full regression: all 13 testbenches PASS** (`tb_ipl7`, `tb_isr`, `tb_masked`, `tb_wdogfired`, `tb_wdogfired_dbg`, `tb_duart`, `tb_nvramwr`, `tb_prot`, `tb_protcount`, `tb_postwrfetch`, `tb_wdog`, `tb_patched`, `tb_pollregion`) -- no expected-failure carve-outs needed this time, unlike the two forced-IPL7 builds. Both `sftm_main.v` and `sftm_video.v` re-elaborate cleanly standalone (`iverilog -t null`). **Awaiting hardware observation of the flash count (now 1..7, so count carefully -- the cycle is ~8.5 s at 7 flashes, 0.5 s on / 0.5 s off per flash, followed by a ~1.5 s steady hold before repeating).**

- **HARDWARE RESULT (commit `6748cc9`, 2026-07-28): N=1, i.e. `poll_region==0` -- the CPU performs NO I/O data read of ANY kind in steady state.** This rules out the video/CRTC prime suspect and every other region simultaneously: **the stuck loop is not a failed hardware handshake at all.** It is not polling a register that fails to return the expected value, because it is not polling anything. Note the confirmation filter means this is a genuine "no qualifying I/O read" and not a single-sample fluke, and it was captured with the arming delay and freeze behaviour validated by `tb_pollregion`.
- **Combined picture, which is now quite tightly constrained**: the CPU (a) writes the protection byte, (b) fetches instructions indefinitely, (c) reads no hardware register whatsoever, (d) has interrupts masked, (e) never kicks the watchdog, (f) never reads the protection port. A loop that fetches forever but performs zero data reads is the exact signature of a **branch-to-self**, which is the classic body of a catch-all exception handler. The leading hypothesis is therefore that **the CPU took an unexpected exception and landed in a dead-end handler** -- alternatively that it is executing garbage that happens to loop. Notably, the reset SR on a 68k is `0x2700` (mask=7, all interrupts disabled), which is fully consistent with finding (d) by the simple explanation that **the boot code never got far enough to lower the mask** -- masking need not be a separate fault, just a consequence of never reaching the point where interrupts are enabled.
- **New diagnostic: `exc_vec` (this commit)** -- did the CPU take an exception, and which one? On a 68k the vector table lives at byte `0x000-0x3FF` (main RAM here) and vector N is fetched by READING byte `4*N`. A read of that region is ROM-content-independent proof that exception processing began for that specific vector -- the same proven mechanism as the existing `vec_isr_read`, generalised to the whole table. **Only reads qualify**: boot code installs handlers by WRITING there, so a write-sensitive probe would fire spuriously on every boot. **Vectors 0/1 (reset SSP/PC) are excluded**, since those are fetched legitimately at power-on and would otherwise latch immediately every time and mask any real fault. Sample-and-hold on the FIRST qualifying read then frozen, so we capture the ORIGINAL fault rather than whatever it cascades into. Reuses the same edge-detected, non-`cen`-gated `poll_rd` per-access pulse. `flash_count = 1 + exc_vec`. **N=1**: no exception vector ever fetched -- the CPU never faulted, so it reached the loop by NORMAL program flow, making it a deliberate wait/delay loop; since it reads no hardware and no interrupt can fire, it would then be waiting on something that can never change, implying a wrong branch earlier. **N=2**: BUS ERROR (vec 2) -- an access to an address that did not respond; would point directly at our own address decode / SDRAM handling, i.e. a core bug. **N=3**: ADDRESS ERROR (vec 3) -- misaligned access; corrupted pointer/stack or executing garbage. **N=4**: ILLEGAL INSTRUCTION (vec 4) -- executing data as code via a wild jump or uninitialised vector. **N=5**: PRIVILEGE VIOLATION / LINE-A / LINE-F (vecs 8, 10, 11) -- executing garbage, **or a 68020-specific opcode TG68K does not implement, which is a very plausible and highly actionable outcome given this is a 68020 game running on a core that is not a full 68020**. **N=6**: OTHER (zero divide, CHK, TRAPV, trace, TRAP #n...). **N=7**: INTERRUPT AUTOVECTOR (vecs 24-31) -- should never appear given interrupts are masked.
- **BIT-INDEXING BUG found and fixed BEFORE reaching hardware, by the new testbench (a direct win for the "verify slices by simulation" rule).** First attempt sliced the vector number as `cpu_addr[8:1]`, on the assumption that `cpu_addr` is a `[22:0]` word address. It is actually declared **`output [23:1] cpu_addr`**: its VALUE is a word address (numerically `byte_addr>>1`, which is why existing numeric comparisons such as `cpu_addr==23'h32` for byte `0x64` are correct), but its **BIT INDICES are the literal `cpu_a` bit positions** -- `cpu_addr[9]` IS `cpu_a[9]`, not `cpu_a[10]`. The wrong slice yielded exactly **2*N**, silently misclassifying every vector (`tb_excvec` showed vector 2 reported as illegal-instruction, vector 4 as privilege-violation, reset vector 1 latching as bus-error, etc. -- 15 failures). Correct form is `cpu_addr[9:2]` for the vector number and `cpu_addr[23:10]==0` for the table region; a permanent comment records the hazard at the logic. **This is the third bit-ordering/priority-semantics defect this session (after the `{}` concat order bug in `0db0286` and the `cpu_ipl` priority inversion in `81cdd14`), and the first one caught before it could produce a misleading hardware reading.**
- New testbench `/tmp/tb_excvec.v` (156 lines, 6 phases, **21 checks, all PASS**): reset vectors 0/1 never latch; writes to the vector table do not trigger; reads at/above `0x400` do not trigger (including the protection byte at `0x7a6a`); all category mappings verified individually across vectors 2, 3, 4, 8, 10, 11, 24, 25, 31, 5, 9, 23, 32, 47, 255 (both boundaries of the autovector range included); the odd word of a long-word vector fetch at byte `4N+2` decodes to the SAME vector as `4N` so a real two-word read cannot be misattributed; and the first fault is held rather than overwritten by later ones. **Full regression: all 14 testbenches PASS.** Both `sftm_main.v` and `sftm_video.v` elaborate cleanly standalone. `poll_region` is left in place (now answered, harmless) with its result recorded. **Awaiting hardware flash count.**

- **HARDWARE RESULT (commit `00f0035`, 2026-07-28): N=5, i.e. `exc_vec==4` -- the CPU DID take an exception, in the PRIVILEGE VIOLATION / LINE-A / LINE-F group (vector 8, 10 or 11).** This **confirms the branch-to-self hypothesis**: the steady-state loop IS a dead-end fault handler, not a wait loop. So the chain is now: boot runs → something faults → the fault handler is a dead end → the CPU loops there forever fetching but never reading hardware → the watchdog is never kicked → periodic reboot → repeat. Every previously observed symptom (`wdog_kick_ever=0`, `prot_rd_ever=0`, `post_wr_fetch_count` saturated, interrupts still masked, no I/O polling) follows from this single cause.
- **Also worth recording: TG68K is instantiated in full 68020 mode** -- `.CPU(2'b11)` with `MUL_Mode(2)`, `DIV_Mode(2)`, `BitField(2)`, `extAddr_Mode(2)`, `BarrelShifter(2)`, `SR_Read(2)`, `VBR_Stackframe(2)`. So the common "unimplemented 68020 integer instruction" explanations (32-bit MUL/DIV, bitfield ops, scaled/memory-indirect addressing) are already covered and are NOT the likely cause. Coprocessor (F-line) instructions remain unimplemented.
- **KEY OBSERVATION about our own RTL that makes one cause far more likely than the others**: the CPU data-in mux in `sftm_main.v` ends in **`default: inp_mux = 16'hffff`**, so **any read of an unmapped address returns `0xFFFF`** -- and **`0xFFFF` is itself a line-F opcode**. That yields a very specific and very plausible failure mode: **if the CPU jumps into unmapped address space, every instruction fetch returns `0xFFFF` and it takes a line-F exception (vector 11) immediately.** This is a much more likely explanation than the game genuinely using an FPU/coprocessor instruction, and it is a bug on our side rather than a missing CPU feature.
- **New diagnostic: `exc_detail` (this commit)** -- splits the 8/10/11 group into individual vectors **and tests the unmapped-fetch theory in the SAME build**, so no extra hardware round trip is spent on disambiguation alone. Adds `last_fetch_ff`, which records whether the most recently fetched instruction word was `0xFFFF`, sampled on `clkena` (the exact tick the CPU consumes `data_in`) during fetches only (`busstate==2'b00`). `flash_count = 1 + exc_detail`. **N=1**: no fault captured -- would CONTRADICT the N=5 result and mean the failure is non-deterministic between runs (itself an important finding, not a null result). **N=2**: PRIVILEGE VIOLATION (vec 8) -- privileged instruction executed in user mode, implying the CPU is not in supervisor state when it should be; would point at S-bit / RTE / stack-frame handling. **N=3**: LINE-A (vec 10) -- `0xAxxx` is unused on the 68k and appears in no real compiler output, so this means executing garbage data as code. **N=4**: LINE-F **with last fetch == `0xFFFF`** -- **STRONGEST DIAGNOSIS: the CPU has jumped into UNMAPPED address space and is fetching the mux default**; the bug is then in our address decode / ROM mapping or in whatever computed that jump target, and is directly chaseable. **N=5**: LINE-F with last fetch != `0xFFFF` -- a genuine `0xFxxx` coprocessor opcode the core lacks. **N=6**: ILLEGAL INSTRUCTION (vec 4) -- would contradict N=5. **N=7**: any other vector -- also contradicts N=5; suggests non-determinism or a probe problem.
- **HONEST CAVEAT recorded in the RTL comment and repeated here**: the 68k prefetches, and between the faulting opcode and the vector read the CPU may fetch further words and push a stack frame, so `last_fetch_ff` is strictly "was the LAST fetch before the fault `0xFFFF`", not a guaranteed capture of the exact faulting word. This does not weaken the positive case -- if the CPU is executing in unmapped space then ALL nearby fetches return `0xFFFF`, so the flag holds regardless of prefetch timing -- but a non-`0xFFFF` reading is only **weak** evidence against the unmapped theory, and must not be treated as ruling it out.
- `tb_excvec.v` extended to **32 checks, all PASS**: all the original 21, plus each `exc_detail` mapping verified individually (vectors 8, 10, 11-with-`0xFFFF`, 11-without, 4, 2, 25), **the `0xFFFF` flag verified to affect ONLY line-F and not to leak into the privilege / line-A / illegal categories**, and `exc_detail` verified to be sample-and-held like `exc_vec` (frozen after the first fault, not overwritten by subsequent different faults). Note the testbench must force `clkena` directly, since it is `cen & ~bus_busy & boot_done` and would otherwise never assert in this harness. **Full regression: all 14 testbenches PASS.** Both modules elaborate cleanly. **Awaiting hardware flash count.**

- **HARDWARE RESULT (commit `8dec7e4`, 2026-07-28): N=5 again.** On the `exc_detail` table that decodes to **LINE-F (vector 11) with last fetch != `0xFFFF`**, i.e. a genuine `0xFxxx` opcode rather than a fetch from unmapped space. **But this reading must be treated as UNCONFIRMED**, because the previous build ALSO read 5 with a completely different meaning, and the user reported it as "same as before". A repeated identical count across two builds with different encodings is exactly the collision that can silently validate a wrong conclusion -- it is not possible to tell from the count alone whether the new core was actually running. **Recorded as ambiguous and deliberately not acted on.**
- **PROCESS CHANGE (this commit): flash-counting replaced by an ON-SCREEN BIT DISPLAY, and a BUILD ID added.** Flash counting costs one full hardware round trip per single small integer, requires the user to count reliably, and has now produced one genuine ambiguity. The new display in `sftm_video.v` renders several multi-bit values simultaneously as rows of blocks during `diag_phase`, so a single flash yields the exact vector number *and* the faulting address *and* a build identifier at once:
  - **Row 1** (upper, 8 bits): exact 68k vector number (`exc_vec_num`) -- no grouping, no decoding table.
  - **Row 2** (middle, 24 bits): `exc_fetch_addr`, the byte address of the last instruction fetch before the fault, frozen at fault time. **This is the single most valuable datum remaining**: it distinguishes a wild jump into ROM data, execution out of RAM, and execution in unmapped space from one another, and turns "something faulted somewhere" into a specific address to chase.
  - **Row 3** (lower, 8 bits): `{ exc_last_ff, exc_detail[2:0], BUILD_ID[3:0] }` with **`BUILD_ID = 0x5`**. The build ID is hardcoded and incremented whenever the display changes, which **permanently removes the "is the new core actually loaded?" question** that this round raised. Every future reading is self-identifying.
  - Encoding: 8px blocks (6px lit, 2px gutter), **MSB leftmost**, one-bit = white, zero-bit = dark with the shade **alternating every 4 bits** (navy/maroon) so nibble groups can be read straight off as hex digits. The whole-screen flash overlay is suppressed while the display is active (`BITS_MODE`), since it would periodically white out the rows.
- **Two guards in the display logic that would each have produced a wrong-but-plausible reading**, both explicitly commented and tested: (1) `hcnt >= BITS_H0`, because `bits_x` underflows and wraps to a large value left of the origin; (2) `bits_x < 192`, because `bit_slot` is sliced as `bits_x[7:3]` and therefore **ALIASES every 256 pixels** -- without it the rows are redrawn further right and the duplicate blocks would be misread as additional data bits.
- New testbench `/tmp/tb_bitdisp.v` (202 lines, **all checks PASS**), the first testbench to simulate `sftm_video.v` rather than just elaborate it. Drives the raster with `force` on `hcnt`/`vcnt` and `diag_phase`/`startup_phase`, then verifies: MSB-leftmost ordering on all three rows; row widths 8/24/8 respected; gutter pixels dark; nothing rendered left of the origin; **no 256px aliasing**; all vertical inter-row gaps clear; display off outside `diag_phase`; nibble-group shading alternation; one-bits full white on all three channels; all-zero and all-`0xFFFFFF` addresses; and a **walking single set bit across all 24 positions with both neighbours checked clear** -- the strongest ordering test, since symmetric patterns hide off-by-one and reversal errors. Asymmetric test values (`0x0B`, `0xA5C3F0`, `0xC5`) were chosen so any nibble swap or reversal is unmissable. **No ordering defect found this time** -- the first bit-order-sensitive diagnostic in this project to be correct on the first attempt. **Full regression: all 14 testbenches PASS** plus `tb_bitdisp` = 15. Both modules elaborate cleanly. **Awaiting the three rows read off the screen.**

- **HARDWARE RESULT (commit `9fc0c34`, 2026-07-28) — the bit display WORKED, read from a photo of the CRT.** The three rows were decoded programmatically rather than by eye (fit a periodic block grid to the photo, then sampled each block centre; the CRT's moiré defeats naive thresholding, and the initial grid fit landed one block early, which was caught precisely because two of the three rows had checkable expected content). Decoded:
  - **Row 1 = `0000 1011` = `0x0B` = vector 11 → LINE-F, confirmed exactly.** No grouping, no decode table, no ambiguity. The exception identity is now settled.
  - **Row 3 = `1100 0101` = `0xC5`** → `exc_last_ff=1`, `exc_detail=4`, **`BUILD_ID=0101=5` ✓ — the new core WAS running**, so the repeated "5 flashes" was a genuine coincidence and not a stale build. The build-stamp mechanism paid for itself on its first use.
  - **Row 2 = `1 0000 0000 000 1 0000 ??????`** → `exc_fetch_addr = 0x800400..0x80043F` (low 6 bits unreadable, see below). **The faulting fetch was in PROGRAM ROM (`prog_sel` = `0x800000-0xbfffff`), about `0x400` bytes in.**
- **`exc_detail=4` vs `exc_last_ff=1` is NOT a contradiction, and the distinction matters**: `exc_detail` is **frozen at the first fault**, whereas `exc_last_ff` is a **live** signal. So at the moment of the original fault the fetched word was **not** `0xFFFF` (consistent with `0x800400` being mapped ROM), but **right now, in steady state, the CPU's most recent fetch IS `0xFFFF`** — i.e. **the CPU is currently executing in UNMAPPED space.** Reconciling: boot reaches ROM around `0x800400`, takes a line-F exception there, and subsequently ends up in unmapped address space where every fetch returns the `inp_mux` default `0xFFFF` — itself a line-F opcode, so it faults repeatedly. **This also explains `poll_region==0` without contradiction**: a repeating line-F exception reads its vector at `0x2C`, which is in main RAM, and `poll_region` deliberately ignores main RAM. Every finding is now mutually consistent.
- **DISPLAY WIDTH BUG found from the photo**: although the active area is 384 px (`VR_HBSTART=384`), only roughly the **left half (~192 px)** actually reaches the monitor — the image is being stretched about **2x horizontally**. Derived from the photo geometry: 8 blocks (64 core px) spanned exactly one third of the screen width, giving ~192 visible core px starting at hcnt≈0. Vertically the full ~240 lines are visible, so **only the horizontal axis is affected**. The 24-block address row ran from x=48 to x=240 and so had its **last ~6 blocks cut off**, which is exactly why the low bits of the address are unknown. (Whether the 2x stretch is itself a video-timing bug worth fixing is a separate question, noted but not chased.)
- **Display reworked (this commit) to fit, and the faulting OPCODE added.** New layout, all inside x=24..152 with margin at both edges, `BUILD_ID` bumped to **`0x6`**:
  - **Row 1** (16 bits): `{ BUILD_ID[3:0], exc_vec_num[7:0], exc_last_ff, exc_detail[2:0] }` — build stamp is the **leftmost nibble** so it can be checked at a glance.
  - **Row 2** (12 bits): `exc_fetch_addr[23:12]` — upper 3 hex digits.
  - **Row 3** (12 bits): `exc_fetch_addr[11:0]` — lower 3 hex digits, the part that was cut off before.
  - **Row 4** (16 bits): **`exc_fetch_word`, new** — the data word of that last fetch, i.e. approximately **the opcode the CPU choked on**. The address says *where*; this says *what*. Together they should identify whether the ROM genuinely contains an `0xFxxx` word at that offset (implying a wild jump into data, or a ROM-loading/byte-order fault in our core) or whether our fetch path is corrupting it.
  - The address is split across two 12-bit rows purely to respect the width limit.
- `tb_bitdisp.v` updated and extended (**all checks PASS**), now including an **explicit assertion that nothing renders beyond x=176** — swept across every column from 176 to 383 on all four rows, so the clipping bug that cost us the address low bits cannot recur silently. Also re-verified: MSB-leftmost on all four rows at widths 16/12/12/16; walking single set bit across the opcode row and across both address rows; the build stamp readable independently of the other fields; dark gutters; no origin underflow; no 256px aliasing; all eight inter-row vertical gaps clear; display off outside `diag_phase`. **Full regression: all 14 testbenches PASS plus `tb_bitdisp` = 15.** Both modules elaborate cleanly.
- **Open next step**: with `exc_fetch_addr` complete and `exc_fetch_word` in hand, cross-check against the actual ROM image — the real ROM is available on the user's own machine even though it is not in this repo, so the bytes at ROM offset `addr - 0x800000` can be dumped directly and compared with what the CPU fetched. That distinguishes "the ROM really contains this word there" from "our ROM mapping/byte order delivers the wrong word", **without another hardware round trip**.

### ROM CROSS-CHECK (2026-07-28) — the faulting address is the RESET ENTRY POINT

The real romset was located on the user's machine (`~/Library/Application Support/mame/roms/sftm.zip`) and the four program PROMs (`sfm_prom0..3_v1.12`, 256 KB each = 1 MB) were pulled locally and MD5-verified against the source. **The ROM itself is deliberately NOT committed** (copyrighted); the assembly script is committed as `doc/rom_interleave.py` so this is reproducible from any romset.

- **Byte-lane order was PROVEN, not assumed.** `doc/rom_interleave.py` builds all 24 lane permutations and scores each on whether the resulting reset vector is plausible. Lane order `(0,1,2,3)` — i.e. plain `ROM_LOAD32_BYTE` into a big-endian region, byte N from file `N mod 4` at index `N div 4` — wins **uniquely and by a wide margin**: 63/64 sane vector-table entries vs 37 for the runner-up. Independently corroborated three ways: the exception handlers disassemble as coherent code, the 68020 reset PC lands in the program-ROM window, and the non-`0xFFFF` line-F word density comes out at 5.1% (essentially the 1/16 = 6.25% random expectation), whereas a wrong interleave would skew it.
- **`ROM[4..7]` = `0x00800400`. The 68020 reset PC IS `0x800400` — exactly the faulting address read off the CRT.** (The 68020 boots from RAM address 0 because the driver/our core copies the first `0x80` bytes of ROM into main RAM; `ROM[0..3]` = `0x00008000` = initial SSP, the top of the 32 KB main RAM, which independently confirms the interleave.) **So the CPU is dying in its earliest initialisation, not deep in the game.**
- **The ROM contains NO line-F opcode there.** The first three instructions read as:
  ```
  800400: 007C 2700            ORI    #$2700,SR        ; supervisor, mask all interrupts
  800404: 21FC 00000000 100C    MOVE.L #$0,($100C).W
  80040C: 4EF9 0080158A        JMP    $0080158A
  ```
  All valid. **Critically, the longword at `0x800400` is `0x007C2700` — its four bytes are `00 7C 27 00`, and NOT ONE of them has a high nibble of `F`. Therefore NO byte permutation, half-word swap, or endian error of that longword can possibly produce an `0xFxxx` word.** This **rules out byte-order/endianness as the cause** and means the CPU is being handed data from the **wrong address**, or **stale/not-yet-valid** data — not correctly-addressed data in the wrong order. That is a much narrower target: `rom_addr` generation, the `cpu_rom_gap`/`bus_busy` handshake, or the region's base offset in SDRAM.
- **A wrong-address fetch is highly likely to look like line-F: 21.3% of the 1 MB image is `0xFFFF` filler and another 5.1% are other `0xFxxx` words, so ~26% of random ROM words would trigger exactly this fault.** The observed symptom is therefore fully consistent with a mis-addressed fetch and needs no exotic explanation.
- **FINDING #3 IS RETRACTED — `prot_wr_ever=1` is a FALSE POSITIVE.** It was previously read as "the CPU writes the protection byte at `0x7a6a` but never reads back `0x680002`", implying the game had reached its protection handshake. The ROM shows otherwise: the early init code at `0x800414`-`0x80042E` is a ROM→RAM vector copy (`MOVEA.L #$00800000,A0` / `MOVEA.L #$0,A1` / `MOVE.L (A0)+,(A1)+` / `CMPA.L #$00800100,A0` / `BLT`), immediately followed by a loop bounded by `CMPA.L #$00007C00,A0` — **a bulk RAM clear/test that sweeps straight across `0x7a6a`.** `prot_word_wr` only checks `cpu_a[14:1]==0x3d35 && cpu_write && ram_cs && high_byte_we`, so a blanket RAM sweep trips it incidentally. **The CPU never intentionally wrote a protection value, and `prot_rd_ever=0` is therefore expected, not a symptom.** Lesson: an address-match diagnostic on a RAM location cannot distinguish a deliberate write from a bulk memory sweep passing over it.
- **This also reconciles `post_wr_fetch_count==3`** (CPU alive for 3+ fetches after the "protection write"): it is simply still iterating that RAM-clear loop. Nothing about it implies progress into game logic.
- **Why the fault address was ambiguous**: `0x800400`-`0x80043F` contains BOTH the reset entry AND that vector-copy/RAM-clear init, so the six unreadable low address bits genuinely mattered. Build `0x6` reports the full 24-bit address plus the fetched word, which will say exactly which fetch dies and what the CPU saw.
- **Useful spare lead**: every ROM exception handler is `MOVE.W #code,($0FBE).W` followed by a branch (`0x8008F0`→code 0, `0x8008F8`→code 1 [line-A and line-F and illegal all vector here], `0x800900`→code 2, `0x800908`→code 3). **The game records its own exception code in main RAM at `0x0FBE`**, so a future diagnostic row could display that word straight from RAM and read the game's own verdict.

### ROM fetch path cleared in simulation -- and findings #10/#11 RETRACTED

`cores/sftm/ver/romfetch/tb_romfetch.v` is the first testbench that lets TG68K
run **freely** from reset against a model of the real 1 MB program ROM, checking
every instruction fetch byte-for-byte. Two memory models were run:

* `MODE=0`, ideal always-ready memory: boot copy done in 96 clk, **3694 fetches,
  0 wrong words.**
* `MODE=1`, bcache-like model that starts a fetch only on a LOW->HIGH edge of
  `rom_cs` and deliberately returns stale data if `rom_addr` changes while
  `rom_cs` stays high -- the exact hazard `cpu_rom_gap` exists to prevent:
  boot copy done in 251 clk, **1628 fetches, 0 wrong words.**

In both cases the boot copy lands SSP=`00008000` and PC=`00800400` in RAM
correctly. **`rom_addr`, `rom_half` and the `cpu_rom_gap` handshake are
correct. The ROM read path is not the bug.**

**Findings #10 (`exc_vec==4`) and #11 (`exc_vec_num==11` -> LINE-F) are FALSE
POSITIVES and are hereby retracted.**

The reset code at `0x800400` ends in `JMP $0080158A`, and `0x80158A` is the
power-on **RAM test**:

```
80158A: 41F8 0000        LEA     ($0000).W,A0     ; A0 = 0  <-- starts at the vector table
80158E: 363C 1FFF        MOVE.W  #$1FFF,D3        ; 8192 longwords = all 32 KB
801592: 45F9 0080157A    LEA     $0080157A,A2     ; pattern table
801598: 241A             MOVE.L  (A2)+,D2
80159A: 221A             MOVE.L  (A2)+,D1
80159C: 2081             MOVE.L  D1,(A0)          ; write pattern
80159E: 2010             MOVE.L  (A0),D0          ; READ IT BACK
8015A0: B280             CMP.L   D0,D1
8015A2: 6636             BNE.S   error
8015A4: 51CA FFF4        DBF     D2,*-12
```

`exc_vec_rd` is `poll_rd & (cpu_addr[23:10]==0) & (cpu_addr[9:2]>=2)`, i.e. any
**read** of bytes `0x008`-`0x3FF`. The RAM test reads every longword of RAM
starting at 0, so it sweeps straight through the vector table and trips the
latch. The simulation tracer proves it:

```
vec-table READ #1: byte 00000008 (vector 2) busstate=10, last instr fetch was 8015a0
vec-table READ #4: byte 0000000c (vector 3) busstate=10, last instr fetch was 8015a0
vec-table READ #7: byte 00000010 (vector 4) busstate=10, last instr fetch was 8015a0
```

`busstate=10` is a **data** read, the address marches sequentially upward, and
the instruction responsible is the same RAM-test loop every time. A genuine
exception vector fetch would be a single read at one address with the last
instruction fetch sitting at the faulting instruction. It reports vector 2 only
because vectors 0 and 1 are excluded by the `>=2` guard, so `0x008` is the first
address in an ascending sweep that qualifies.

This is the **second** time this exact class of mistake has bitten us (see the
retraction of finding #3). Restating the lesson, because it keeps costing us
days:

> **An address-match diagnostic on a low RAM location proves nothing.** This
> game writes *and reads back* all 32 KB of main RAM from address 0 during
> power-on self-test. Any diagnostic that watches a fixed RAM address will fire
> during that sweep. Only a diagnostic that inspects *what the program itself
> concluded* is trustworthy.

Also note: the `FFF4`/`FFE0` words previously flagged as "line-F" at
`0x8015A6`/`0x8015B2` are the 16-bit **displacements** of `DBF` instructions
(`51CA FFF4`), not opcodes. Counting fetched words against the `F000` mask
without decoding cannot distinguish an opcode from an operand.

**Consequently there is currently NO evidence that the CPU takes any exception
at all.** In simulation it runs the RAM test healthily for thousands of fetches.
The whole "LINE-F at 0x800400" narrative rested on the retracted latch.

**Next diagnostic (the only trustworthy one left):** every exception handler in
this ROM is `MOVE.W #code,($0FBE).W` followed by a branch -- `8008F0`->0,
`8008F8`->1 (illegal/lineA/lineF), `800900`->2, `800908`->3. **The game records
its own exception code in RAM at `0x0FBE`.** Displaying `RAM[0x0FBE]` reads the
program's own verdict and cannot be faked by a memory sweep. Note the RAM test
overwrites `0x0FBE`, so the display must be latched, or read after the test.

### `exc_code_ram` diagnostic implemented (this session) -- RAM[0x0FBE] on screen, build 0x7

Implemented the "only trustworthy diagnostic left" from the previous entry.
New signal `exc_code_ram` (`sftm_main.v`) is a **live, continuously-updated**
mirror of the CPU's last full-word write to RAM byte `0x0FBE` (word `0x07DF`):
`if( boot_done && ram_we_lo && ram_we_hi && ram_addr==EXC_CODE_WORD ) exc_code_ram <= ram_din;`.
Deliberately **not** a sample-and-hold/`_ever` latch like `exc_vec`/`exc_detail`
-- those were proven unreliable twice this session (findings #3 and #10/#11
retractions) specifically because freezing on the *first* qualifying event lets
the power-on RAM self-test's sweep win the race. A live mirror sidesteps the
whole failure class: the self-test also writes over `0x0FBE` as part of its
sweep, but a CPU that is genuinely parked in a dead-end handler never writes
anywhere again, so the value naturally settles on the true final answer with
no freeze-timing risk at all. Gated on a **full word write only**
(`ram_we_lo && ram_we_hi` together, matching the ROM's `MOVE.W`) so a stray
byte-only write elsewhere can never merge a stale half into the reported value.

Wired through `jtsftm_game.v` (`sftm_main` → `sftm_video`) following the
existing pattern. `sftm_video.v`'s on-screen bit display gets a **fifth row**
(`vcnt` 200-224, same 16-bit layout as rows 1/4) showing `exc_code_ram`
directly -- no decode table, no ambiguity. `BUILD_ID` bumped to `0x7`. Rows
1-4 (`exc_vec_num`/`exc_fetch_addr`/`exc_fetch_word`) are left in place for
reference but are **not trustworthy** per the retraction above; row 5 is the
only one to read now.

**Pre-existing bug found and fixed while wiring this up, unrelated to the new
diagnostic**: `sftm_video.v`'s `flash_white` wire (`show_stuck & flash_on &
~BITS_MODE`) referenced the `BITS_MODE` localparam roughly 45 lines before
that localparam's own declaration. This is silently accepted by some tools
but iverilog refuses to bind it (`Unable to bind wire/reg/memory 'BITS_MODE'
... declared here: check for declaration after use`), which meant **the
committed `tb_sftm_video.v` testbench has not actually been able to elaborate
in this environment** -- confirmed by reverting to unmodified HEAD and
reproducing the identical failure. Fixed by moving just the `BITS_MODE`
declaration up before `flash_white`; `BUILD_ID`/`BITS_H0` stay declared
together with the row logic below. **Also newly exposed by fixing the
elaboration failure**: `tb_sftm_video.v` itself now runs but reports 2
pre-existing failures (`VIDEO_XFER readback pixel 0/1 got=00X0`), and
`tb_sftm_main.v` reports 1 pre-existing failure (`unexpected boot cycle count
2`) -- both reproduced identically against unmodified HEAD with only the
elaboration-order fix applied, so neither is caused by `exc_code_ram`. Not
investigated further this session (out of scope for the exception-code work);
flagged here since AGENTS.md's own history claims these testbenches were
passing, which is no longer true in this environment and should be
re-verified before trusting them again.

New testbench `/tmp/tb_excoderam.v` (drives `uut.ram_addr`/`ram_din`/
`ram_we_lo`/`ram_we_hi` directly via `force`/`release`, the same technique as
`tb_pollregion.v`/`tb_excvec.v`, since exercising the real write path needs
the ghdl-converted TG68K kernel which is Docker-only and not built in this
environment): confirms `exc_code_ram` is 0 after boot; a write to an unrelated
word does not update it; a partial byte-lane-only write to the target word
does not update it (both lo-only and hi-only checked); a genuine full-word
write latches it; a **second** full-word write overwrites it with the new
value (proving this is live, not first-hit -- the entire point versus
`exc_vec`); unrelated writes afterward leave it undisturbed; a simulated
RAM-test sweep write followed by a real exception-code write settles on the
real code, not the sweep's pattern (the exact false-positive scenario this
diagnostic exists to avoid); and hard reset clears it. **All 9 checks PASS.**
Re-ran `tb_sftm_prot`, `tb_sftm_ram`, `tb_sftm_blitter`, `tb_sftm5506` (the
testbenches unaffected by the `BITS_MODE` fix) -- all still PASS, no
regressions.

- **HARDWARE RESULT (2026-07-28): row 5 (`exc_code_ram`) = `0x2700`.** Read two
  independent ways and cross-checked: (1) a CRT photo, decoded programmatically
  by fitting a shared block grid (pitch + left edge) across all 5 rows via
  gutter/trough detection in the blue channel, calibrated against the known
  `BUILD_ID=0x7` in row 1 as ground truth (a wide, stable alignment plateau at
  the independently-measured pitch converged on `0111`, not an isolated lucky
  match); (2) the user's own direct visual read of row 5
  ("black, black, white, black, blue, white, white, white, black, black,
  black, black, blue, blue, blue, blue") decoded by hand. **Both agree
  bit-for-bit**, including the maroon("black")/navy("blue") nibble-shading
  pattern, which independently confirms the nibble grouping (bit_slot[2])
  alongside the raw bit values -- strong double confirmation.
  - `0x2700` is **not** one of the four codes the ROM's exception handlers
    write (`0`-`3` via `MOVE.W #code,($0FBE).W`, see the ROM CROSS-CHECK
    section above). It is suspiciously exactly the SR immediate value from
    `ORI #$2700,SR`, the very first instruction executed at the reset entry
    point `0x800400`.
  - **Reading**: the CPU most likely never actually executed any of the four
    documented exception handlers on this stuck path. `RAM[0x0FBE]` is
    showing leftover/stale content (from the power-on RAM self-test sweep or
    other RAM traffic), not a genuine handler write. This **rules out** the
    "stuck in a dead-end exception handler" hypothesis that motivated this
    entire diagnostic, and reopens the question of what else could produce
    the branch-to-self signature (fetches forever, zero data reads, SR
    interrupt-masked) established earlier in the ROM CROSS-CHECK section.
    Not yet investigated further this session.

### `pc_snapshot_addr`/`pc_snapshot_word` implemented -- live PC, sampled once (this session, build 0x8)

`exc_code_ram=0x2700` reopened the question of where the CPU actually is,
without falling back into the address-match trap that sank `exc_vec`/
`exc_fetch_addr` twice already. Re-examined the established facts against a
hypothesis that was never actually ruled out: **the CPU may simply still be
inside the power-on RAM self-test loop** (`0x80158A`-`0x8015A6` per the ROM
CROSS-CHECK disassembly above). Every finding is consistent with it: fetches
forever (loops fetch their own few instructions repeatedly); `poll_region==0`
(the RAM test only reads *main RAM*, which `poll_region` deliberately
excludes -- this was never evidence against the theory); interrupts masked
throughout (`ORI #$2700,SR` runs once, before the test, which never touches
SR); `tb_romfetch` simulation shows the RAM test running healthily for
thousands of fetches with a perfect RAM model, while real hardware has a
recorded timing violation (`slack −1.053ns`, "Quartus synthesis fits" section
above) that iverilog cannot model -- a marginal timing fault on the exact
write-then-read-back pair the test relies on would be silent in sim and
deterministic on real silicon; and `exc_code_ram=0x2700` is fully explained
as an ordinary RAM-test pattern-table byte (the test's `MOVE.L` writes sweep
every address in RAM including `0x0FBE`) rather than requiring the earlier
"stale SR value" coincidence theory.

Added `pc_snapshot_addr`/`pc_snapshot_word` in `sftm_main.v`: a **one-shot**
snapshot of the already-existing, always-live `last_fetch_addr`/
`last_fetch_data` registers (these update on every single instruction fetch
regardless of exception state -- `exc_fetch_addr`/`exc_fetch_word` already
latched FROM them, just gated on the retracted trigger). The snapshot fires
once, on the 0->1 transition of `poll_armed` (`sftm_main.v`'s existing ~5s
post-reset settle timer, reused directly -- no new timer). This is
deliberately **time-triggered, not address-triggered**: immune to the
address-sweep trap by construction, since it doesn't condition on which
address is touched at all -- it just grabs whatever the PC is doing at a
fixed point in time, which should land inside whatever loop the CPU is
steady-state parked in.

**Why not just display `last_fetch_addr` live, continuously?** It updates on
every CPU fetch (every few cycles, far faster than the ~60Hz video scan-out),
so a non-snapshotted display would tear/flicker within a single on-screen row
as the value changed mid-scanline. Freezing once gives a stable, readable
value -- same reasoning as the sample-and-hold in the retracted `exc_vec`,
but without that mechanism's fatal flaw: freezing on a fixed TIME can't be
fooled by an incidental first-touch, whereas freezing on the first ADDRESS
match can (and did, twice).

`sftm_video.v`'s bit display: rows 2-4 (previously `exc_fetch_addr[23:12]`/
`exc_fetch_addr[11:0]`/`exc_fetch_word`, both retracted) now show
`pc_snapshot_addr[23:12]`/`pc_snapshot_addr[11:0]`/`pc_snapshot_word`
instead -- same row positions and widths, so the already-validated grid
alignment from `BUILD_ID`/row 5 carries over directly. Row 1 (`BUILD_ID`/
`exc_vec_num`/`exc_last_ff`/`exc_detail`) and row 5 (`exc_code_ram`) are
unchanged. `BUILD_ID` bumped to `0x8`.

New testbench `/tmp/tb_pcsnapshot.v` (drives `uut.last_fetch_addr`/
`last_fetch_data`/`poll_armed` directly via `force`/`release`, since the
real ~5s delay is impractical to simulate and the stub CPU can't produce
realistic fetch traffic): confirms the snapshot stays 0 while `last_fetch_*`
changes before `poll_armed` fires; captures exactly what `last_fetch_*` holds
at the instant `poll_armed` transitions high (the critical case -- proves it
samples "right now", not something stale); does not update again on later
`last_fetch_*` changes while `poll_armed` stays high (one-shot); and clears
on hard reset. **All 5 checks PASS.** Re-ran `tb_sftm_prot`, `tb_sftm_ram`,
`tb_sftm_blitter`, `tb_sftm5506`, `tb_sftm_main`, `tb_excoderam`, and the
committed `tb_sftm_video` -- all still PASS (or fail with the same
pre-existing, already-documented failures) -- no new regressions. Both
`sftm_main.v` and `sftm_video.v` elaborate cleanly standalone.

- **HARDWARE RESULT (2026-07-28): `pc_snapshot_addr=0x336BAC`,
  `pc_snapshot_word=0xFFFF`.** Read via the same photo-decode method as
  before (gutter/trough detection, joint least-squares fit of pitch and left
  edge across all 5 rows pooled together, resolved against `BUILD_ID=0x8` as
  ground truth -- the correct alignment produced a 26px-wide completely
  stable plateau across rows 2-5, not an isolated lucky match). `row1`
  confirmed `BUILD_ID=1000=0x8` exactly as expected, and `row4` (all 16
  blocks solid white = `0xFFFF`) was independently confirmed by direct user
  observation of the physical screen -- both cross-checks agree.
  `exc_code_ram` (row 5) read `0x2700` again, identical to the previous
  boot -- a good reproducibility signal.
  - **`0xFFFF` is exactly the unmapped-read signature**: `sftm_main.v`'s CPU
    data-in mux ends `default: inp_mux = 16'hffff`, so any read of an address
    with no chip-select match returns `0xFFFF`. The last instruction fetch
    before the snapshot returned that default.
  - **`0x336BAC` is not in any mapped region**: main RAM is
    `0x000000-0x007FFF`, program ROM is `0x800000`+. `0x336BAC` is outside
    both.
  - **Reading**: 5 seconds after reset, the CPU's PC was executing from
    genuinely unmapped address space, reading the bus's default filler
    value. This is direct evidence for the *original* "CPU ran off into
    nothing" theory -- the one `last_fetch_ff`/`exc_last_ff` was built to
    test, before the retracted `exc_vec` mechanism conflated it with an
    unreliable address-match trigger. It **reopens** (does not confirm) the
    RAM-test-loop theory from the previous entry: that hypothesis predicted
    a PC sitting inside `0x80158A-0x8015A6` (mapped ROM), which this is not.
  - **Not yet resolved**: whether the CPU reaches unmapped space via a single
    wild jump early in boot and then stays there, or via a repeating cycle
    (e.g. taking a line-F exception on the `0xFFFF` it fetches, reading a
    vector table entry that itself hasn't been properly initialised, and
    landing back in unmapped space each time -- which would still fetch
    forever, read no I/O, and stay interrupt-masked, matching every existing
    observation). `0x336BAC` is a single one-shot sample; it does not by
    itself distinguish a fixed loop from a single resting point reached once
    and never left. Next diagnostic should determine which.

### `pc_stable` implemented -- second PC snapshot, ~5s after the first (this session, build 0x9)

Directly answers the question the previous entry left open: is
`0x336BAC`/`0xFFFF` a fixed loop or a single resting point? Added a second
one-shot snapshot in `sftm_main.v`, `pc_snapshot2_addr`/`pc_snapshot2_word`
(own 30-bit delay counter, `PC_SNAPSHOT2_DELAY = 480_000_000` cycles, ~10s at
48MHz -- a new counter rather than reusing `poll_dly_cnt`, since
`POLL_SAMPLE_DELAY` at 28 bits already sits close to that width's ~5.6s
ceiling). These two registers are internal only (not ports) -- to keep this
round's on-screen display within the existing 5 rows, only a single derived
comparison bit is exposed: `pc_stable = pc_snap_done && pc_snap2_done &&
(pc_snapshot_addr==pc_snapshot2_addr) && (pc_snapshot_word==pc_snapshot2_word)`.
If hardware reads "different" (`pc_stable=0`), the full second snapshot
already exists in the RTL and a follow-up build can expose it the same way
`pc_snapshot_addr`/`word` do now.

`sftm_video.v` row 1 repurposed: the low 3 bits (previously `exc_detail`,
retracted along with the rest of `exc_vec`) are now `{2'b00, pc_stable}` --
only the last bit carries a signal, the other two are spare/zero. Rows 2-5
unchanged. `BUILD_ID` bumped to `0x9`.

New testbench `/tmp/tb_pcstable.v` (same `force`/`release` technique as
`tb_pcsnapshot.v`): confirms `pc_stable` stays 0 until both snapshots have
fired; **scenario A** (PC hasn't moved -- both snapshots see the same
`last_fetch_addr`/`data`) reads `pc_stable=1`; **scenario B** (PC has moved
between the two sample points) reads `pc_stable=0`. **All 6 checks PASS.**
Re-ran `tb_sftm_main`, `tb_excoderam`, `tb_pcsnapshot`, `tb_sftm_prot`,
`tb_sftm_ram`, `tb_sftm_blitter`, `tb_sftm5506`, and the committed
`tb_sftm_video` -- all still PASS (or fail with the same pre-existing,
already-documented failures) -- no new regressions. Both `sftm_main.v` and
`sftm_video.v` elaborate cleanly standalone. **Awaiting hardware observation
of row 1's last bit** (should render as one extra light/dark block at the
end of row 1, block 15).

- **HARDWARE RESULT (2026-07-29): `pc_stable=0` -- the PC is ROAMING, not a
  fixed loop.** Read via the same photo-decode method (joint gutter fit
  across all 5 rows, resolved against `BUILD_ID=1001=0x9` -- the correct
  alignment produced a 27px-wide stable plateau, ~45x wider than any
  incidental match at the wrong alignment) and independently confirmed by
  direct user observation of row 1's last block (dark). Full row 1:
  `BUILD_ID=0x9` (bits 0-3) ✓, `exc_vec_num`/`exc_last_ff` (retracted/
  unreliable, unchanged from before), spare bits 0 as expected, `pc_stable`
  (last bit) = **0**.
  - **This rules out a fixed repeating loop at `0x336BAC`.** The CPU's PC at
    the ~5s and ~10s marks within the SAME boot were at different addresses.
  - **Independent corroboration from the OTHER rows this same reading**:
    `pc_snapshot_addr` (the first, ~5s snapshot) this boot read
    `0x336BAA` -- close to but NOT identical to the previous boot's
    `0x336BAC` (differs by 2). `exc_code_ram` (row 5) and `pc_snapshot_word`
    (row 4, `0xFFFF`) were identical to the previous boot both times.
    A PC that lands at slightly different-but-nearby unmapped addresses
    across separate power cycles, combined with moving between two
    time-separated samples within one power cycle, is consistent with the
    CPU genuinely drifting/roaming through unmapped space rather than
    resting at one fixed address -- not just measurement noise (the
    address is stable to the byte in the high 20 bits across every
    reading so far; only the low few bits vary).
  - **Leading explanation, matches every fact gathered so far**: the CPU is
    likely cycling through unmapped space via repeated line-F exceptions.
    Every fetch in unmapped space returns `0xFFFF` (the bus default), which
    is itself a line-F opcode; if the line-F vector table entry (a fixed
    address in main RAM, byte `0x2C`) hasn't been properly initialised by
    this point in boot, each exception reads back whatever garbage sits
    there and jumps to it -- landing back in unmapped space, at a slightly
    different address depending on stack/timing state, and immediately
    faulting again. This explains fetching forever, zero I/O reads (main-RAM
    vector-table reads are excluded from `poll_region` the same way they
    always have been), interrupts staying masked (never reached), AND now
    the roaming behaviour, all from one mechanism.
  - **Next diagnostic**: expose the full second snapshot
    (`pc_snapshot2_addr`/`pc_snapshot2_word`, already implemented internally
    in `sftm_main.v` this session, just not yet wired to the display) to see
    exactly where the PC moved to by the ~10s mark -- confirming whether it's
    bouncing between a small number of nearby unmapped addresses (consistent
    with the line-F/uninitialised-vector cycle above) or drifting further
    afield. Also worth checking: `RAM[0x2C]` (the line-F vector itself) via
    the same kind of live/one-shot-snapshot technique used for
    `exc_code_ram`/`pc_snapshot_addr`, which would confirm or rule out the
    "uninitialised vector" mechanism directly rather than inferring it.

### `vecC_hi`/`vecC_lo` implemented -- live mirror of the line-F vector table entry (this session, build 0xA)

Checks the leading theory directly rather than continuing to infer it:
`RAM[0x2C:0x2F]` is the line-F (vector 11) exception vector table entry, a
32-bit jump target address. Added `vecC_hi`/`vecC_lo` in `sftm_main.v`,
following `exc_code_ram`'s exact live-mirror pattern (full-word write only,
`boot_done`-gated) but split across two word addresses (`0x16`/`0x17` for
byte `0x2C`/`0x2E`) since this is a 32-bit value on a 16-bit bus.

**Important wrinkle documented in the RTL**: unlike `exc_code_ram` (word
`0x07DF`, safely outside the boot-copy FSM's own address range), this vector
sits INSIDE it -- `LW11` (byte `0x2C`) is within the `LW0-31` span the boot
FSM copies from ROM before releasing the CPU, the same mechanism that
supplies the correct reset SSP/PC. That's exactly the right behaviour here:
`boot_done`-gating means the tracker starts right after the boot FSM has
already written the ROM's real vector, so what's displayed is the CURRENT
value post-boot -- if the RAM self-test's write sweep later clobbers it (the
same mechanism already proven to cause two prior false positives, see the
retractions above), that's what shows, which is exactly what we want to
know: what would a fault actually jump to right now. Per the ROM
CROSS-CHECK disassembly, the ROM's real vector 8/10/11 handler lives at
`0x8008F8` -- if this reads that, the vector is intact and something else
is wrong; if it reads something else (especially anything resembling the
`~0x336Bxx` unmapped region `pc_snapshot_addr` already found the CPU roaming
in), that's strong confirmation of the clobbered-vector theory.

`sftm_video.v` gets two new rows (6-7) showing `vecC_hi`/`vecC_lo`. To fit
7 rows total in the 240-line active area, ALL rows were retimed from a 40px
to a 32px period (24px-tall blocks + 8px gap, was 16px) -- ends at the same
vcnt 224 the old 5-row layout did. Row Y-position is independent of the
horizontal grid (`BITS_H0`/block pitch), so this carries no risk to the
already hardware-validated X alignment; the row Y-bands are also detected
programmatically (not hardcoded) by whichever photo-decode script reads the
result. `BUILD_ID` bumped to `0xA`.

New testbench `/tmp/tb_vecC.v` (same `force`/`release` technique as
`tb_excoderam.v`): confirms both halves are 0 right after boot (nothing
written post-boot yet -- indirectly demonstrates the boot-copy FSM's own
legitimate write is correctly NOT captured, since capturing it would show
something other than RAM's power-on 0); a write to an unrelated word doesn't
update either half; a partial (byte-lane-only) write doesn't update; a
full-word write to the hi-word address updates only `vecC_hi`; a full-word
write to the lo-word address updates only `vecC_lo` (`vecC_hi` unchanged,
combining to the expected `0x008008F8` test value); a later write beats an
earlier sweep-like write (the same regression `tb_excoderam.v` guards
against); and hard reset clears both. **All 7 checks PASS.** Re-ran
`tb_sftm_main`, `tb_excoderam`, `tb_pcsnapshot`, `tb_pcstable`,
`tb_sftm_prot`, `tb_sftm_ram`, `tb_sftm_blitter`, `tb_sftm5506`, and the
committed `tb_sftm_video` -- all still PASS (or fail with the same
pre-existing, already-documented failures) -- no new regressions. Both
`sftm_main.v` and `sftm_video.v` elaborate cleanly standalone.

- **HARDWARE RESULT (2026-07-29): `{vecC_hi,vecC_lo} = 0x002C2700` -- the
  line-F vector table entry is CONFIRMED CORRUPTED, not the ROM's real
  `0x8008F8` handler.** Read via photo-decode (block-by-block, this photo
  had heavier moiré than previous ones so the automated grid-fit alone was
  lower-confidence -- resolved by asking the user to read rows 6 and 7 off
  directly, which matched the photo-decode exactly on both rows, block for
  block: `row6 = 0000000000101100 = 0x002C`, `row7 = 0010011100000000 =
  0x2700`).
  - **This directly confirms the leading theory from the previous two
    entries** (inferred from `pc_snapshot_addr`/`pc_stable`, now verified at
    the source): the line-F vector genuinely does not point to the ROM's
    real handler. A line-F fault taken right now would jump to (an
    address-decoded view of) `0x002C2700`, which is not in main RAM or
    program ROM -- consistent with the CPU's PC being found roaming in
    unmapped territory (`~0x336Bxx`).
  - **`vecC_lo = 0x2700` is identical to `exc_code_ram` (row 5)**, a second,
    independent address (`0x0FBE`) holding the exact same 16-bit value.
    Given the RAM self-test writes 32-bit patterns drawn sequentially from a
    pattern table across all 8192 longwords of RAM, and vector 11's
    longword (`0x2C-0x2F`) and `exc_code_ram`'s word are swept at very
    different points in that sequence, an exact match on the low half is a
    real coincidence worth noting but does not change the core finding --
    `vecC_hi=0x002C` (NOT matching `exc_code_ram`) already proves this is
    sweep-pattern data, not the ROM's vector, regardless of how the low
    half happens to line up.
  - **Open question, not yet resolved**: this pins down the SYMPTOM (the
    vector table has been overwritten with test-pattern data by the time a
    fault reads it) but not the root cause. The power-on RAM self-test
    overwriting its own low-RAM vector table is not inherently a bug --
    vectors are only read when an exception actually fires, and if no
    exception were expected during/after the test, a stale vector table
    would be harmless. The real question is why an exception fires AT ALL
    at a point where the vector table has already been swept over. Two
    non-exclusive possibilities: (a) this is normal ROM behaviour and real
    hardware also takes some exception here but recovers via a path our
    core doesn't replicate correctly, or (b) something specific to this
    core (timing, an SDRAM/RAM-test interaction, or another RTL bug)
    triggers a fault the real chip would never take at this point. Next
    diagnostic should determine which vector is actually taken first (not
    necessarily line-F -- ANY vector clobbered by the same sweep would
    produce the same downstream roaming-into-unmapped-space symptom once
    read), and whether it happens during the RAM test's own execution or
    afterward.

### `genuine_exc_vec_num`/`fault_in_ramtest` implemented -- a CORRECTED exc_vec, build 0xB

Answers exactly what the previous entry left open, using a filter that
actually fixes the flaw that sank the original `exc_vec` (rather than the
narrower fixes tried before, which only ever addressed *symptoms* of that
flaw): a genuine exception's stack push is at a completely different address
than the vector-table read that follows it, while the RAM self-test's verify
step (`MOVE.L D1,(A0)` then `MOVE.L (A0),D0`) always reads back the *exact
same* address it just wrote. Requiring the two addresses to differ cleanly
separates "the CPU is verifying its own RAM-test write" from "the CPU is
genuinely taking an exception" -- something the original mechanism (which
only checked "was a data read observed in the vector-table region") could
never distinguish, no matter how the trigger's timing was tuned.

New in `sftm_main.v`: `last_write_addr`, an edge-detected (on raw `busstate`,
not `cen`-gated, same lesson as every prior edge-detector in this file)
tracker of the most recent CPU data-write address, reset to a sentinel
(`24'hFFFFFF`) so no real low address can spuriously match before the first
write. `genuine_exc_vec_num` (sample-and-hold, frozen on first hit, mirrors
`exc_vec_num`'s convention but gated on `exc_vec_rd & (last_write_addr !=
read_addr)` instead of `exc_vec_rd` alone) and `fault_in_ramtest` (compares
the internally-held `genuine_exc_fetch_addr` -- `last_fetch_addr` captured
at the same instant -- against `RAM_TEST_LO..HI = 0x801580..0x8015C0`, the
self-test's own loop body per the ROM CROSS-CHECK disassembly, with a few
bytes of slack for the prefetch caveat already documented at
`last_fetch_ff`) answer "which vector, genuinely" and "during the RAM test
or after it" in one build, no extra hardware round trip needed to
disambiguate.

**No new on-screen rows needed.** `genuine_exc_vec_num` (8 bits) and
`fault_in_ramtest` (1 bit) exactly replace `exc_vec_num`/`exc_last_ff` in row
1, which were the only remaining un-trustworthy fields there -- row 1 is now
fully reliable end to end. `BUILD_ID` bumped to `0xB`.

New testbench `/tmp/tb_genexc.v` (drives `uut.busstate`/`uut.cpu_a` directly
via `force`/`release` to synthesize bus cycles without a real CPU, plus
`uut.last_fetch_addr`): the two checks that matter most are that a
same-address write-then-read (the RAM-test verify pattern, repeated several
times at different vector-table addresses to mimic the sweep) never
triggers, while a write-elsewhere-then-vector-table-read does, correctly
capturing `vec_num=11` (line-F). Also checks: a bare re-read of the
last-written address (no new write) doesn't trigger; `fault_in_ramtest`
reads 1 when the captured fetch address is inside `RAM_TEST_LO..HI` and 0
when it's outside (using this session's own `0x336BAC` finding as the
"outside" test value); sample-and-hold freezes on the first genuine event
and a second one doesn't overwrite it; and hard reset clears both. **All 10
checks PASS.** Re-ran `tb_sftm_main`, `tb_excoderam`, `tb_pcsnapshot`,
`tb_pcstable`, `tb_vecC`, `tb_sftm_prot`, `tb_sftm_ram`, `tb_sftm_blitter`,
`tb_sftm5506`, and the committed `tb_sftm_video` -- all still PASS (or fail
with the same pre-existing, already-documented failures) -- no new
regressions. Both `sftm_main.v` and `sftm_video.v` elaborate cleanly
standalone.

- **HARDWARE RESULT (2026-07-29): `genuine_exc_vec_num=11` (LINE-F),
  `fault_in_ramtest=0`, `pc_stable=0`.** Read from the user's direct block
  read of row 1 ("white, black, white, white, blue, blue, blue, blue,
  white, black, white, white, blue, blue, blue, blue"), decoded by hand:
  `BUILD_ID=1011=0xB` ✓ confirms the build, `genuine_exc_vec_num=00001011=11`,
  `fault_in_ramtest=0`, spare bits `00` as expected, `pc_stable=0` (still
  roaming, consistent with the earlier finding).
  - **This is a GENUINELY confirmed line-F exception**, not a repeat of the
    retracted false positive -- this mechanism was specifically built and
    simulation-verified to reject the RAM self-test's write-then-readback
    pattern that fooled the original `exc_vec`.
  - **`fault_in_ramtest=0` means the fault happens AFTER the RAM test's own
    loop body completes, not while still inside it.** Combined with
    `vecC_hi/lo` from the previous entry (the vector table is already
    corrupted by the time this fault reads it), the picture is now: the RAM
    self-test runs and finishes, incidentally clobbering the low-RAM vector
    table on the way (including line-F's entry) as an ordinary side effect
    of testing all of RAM -- harmless BY ITSELF, since vectors are only read
    on a real fault -- but SOMETHING after the test genuinely executes a
    line-F-triggering instruction, and because the vector table was never
    re-established first, that fault jumps into garbage instead of a real
    handler.
  - **Leading explanation for the fault itself**: `sftm_main.v`'s existing
    "Also worth recording" note (see the earlier `exc_detail`/`0xFFFF`
    section of this log) already established TG68K is instantiated in full
    68020 integer mode (`MUL_Mode`/`DIV_Mode`/`BitField`/`extAddr_Mode`/
    `BarrelShifter` all `=2`), ruling out the common "missing 68020 integer
    instruction" explanations -- but **coprocessor (F-line) instructions
    remain unimplemented**. A ROM that legitimately executes an F-line
    opcode shortly after the RAM test (a real 68020 program construct, not
    necessarily a bug in the ROM) would explain a genuine, otherwise-
    survivable line-F trap that only becomes fatal here because the vector
    table hasn't been re-initialised yet.
  - **Next diagnostic**: expose `genuine_exc_fetch_addr` (already computed
    internally this session, just not yet a port/row) -- the exact ROM
    address executing right before this fault. That address can be looked
    up directly in the ROM disassembly to identify the actual opcode,
    turning "TG68K probably lacks some F-line instruction" into a specific,
    actionable instruction to confirm or implement.

### `genuine_exc_fetch_addr`/`genuine_exc_fetch_word` exposed -- exact fault location, build 0xC

Promotes `genuine_exc_fetch_addr` (already computed internally last commit)
to a port, and adds a matching `genuine_exc_fetch_word` capturing the actual
opcode fetched there (same trigger, same freeze, same prefetch caveat
already documented at `last_fetch_ff`). Together these identify the exact
faulting instruction directly against the ROM disassembly -- confirms or
refutes the "missing F-line/coprocessor instruction" theory precisely
instead of by inference.

**No new rows needed**: repurposed rows 5-7 (`exc_code_ram`/`vecC_hi`/
`vecC_lo`), all three already answered and confirmed on hardware this
session (`0x2700` and `0x002C2700` respectively). Their underlying
live-tracking logic in `sftm_main.v` is untouched, just no longer given
screen space. Row 5/6 switch from 16-bit to 12-bit width (address split,
same treatment as rows 2-3's `pc_snapshot_addr`); row 7 stays 16-bit for
the opcode word. `BUILD_ID` bumped to `0xC`.

Extended `/tmp/tb_genexc.v` (was `/tmp/tb_genexc.v` from last commit) with
address/word capture: both genuine-exception scenarios now also assert
`genuine_exc_fetch_addr`/`word` match exactly what was forced into
`last_fetch_addr`/`last_fetch_data` at the trigger instant; the
sample-and-hold check now also confirms the address/word freeze alongside
the vector number; hard reset clears both. **All 13 checks PASS** (up from
10). Re-ran `tb_sftm_main`, `tb_excoderam`, `tb_pcsnapshot`, `tb_pcstable`,
`tb_vecC`, `tb_sftm_prot`, `tb_sftm_ram`, `tb_sftm_blitter`, `tb_sftm5506`,
and the committed `tb_sftm_video` -- all still PASS (or fail with the same
pre-existing, already-documented failures) -- no new regressions. Both
`sftm_main.v` and `sftm_video.v` elaborate cleanly standalone.

- **HARDWARE RESULT (2026-07-29): `genuine_exc_fetch_addr=0x800410`,
  `genuine_exc_fetch_word=0x003C`** (read from the user's direct colour
  transcription of rows 6-7, no independent photo cross-check this round).
  `0x800410` is exactly the tail two bytes of the already-disassembled
  `JMP $0080158A` (`4EF9 0080158A`, spanning `0x80040C-0x800411`) -- a
  precise, meaningful match: the confirmed genuine line-F exception fires
  right as the CPU finishes fetching that JMP's own target-address operand.
  But the REAL ROM word at `0x800410` (extracted directly from the actual
  PROMs at `~/Library/Application Support/mame/roms/sftm.zip` on the user's
  machine, assembled with `doc/rom_interleave.py`'s validated lane order) is
  `0x158A`, not `0x003C` -- and `0x003C` doesn't match any nearby real ROM
  word either; it IS the exact byte-swap of `0x3C00`, the real word at the
  NEXT address, `0x800412`.
- **Simulation check with the REAL TG68K kernel (this session) -- the
  discrepancy does NOT reproduce.** Built `cores/sftm/hdl/tg68k/TG68KdotC_Kernel_conv.v`
  locally (ghdl, `--std=08 -fsynopsys -frelaxed-rules`; required rebuilding
  the Docker image with `--platform linux/amd64` explicitly -- the plain
  `docker build`/`docker/run.sh` default to the host's native arch, and on
  Apple Silicon that's arm64, where the Dockerfile's hardcoded
  `/usr/lib/x86_64-linux-gnu/libLLVM.so.18.1` symlink source doesn't exist;
  also needed `git submodule update --init --recursive` first, since
  `cores/sftm/hdl/tg68k/` was an uninitialised empty submodule). New
  testbench `/tmp/tb_fetch_desync.v`: a ROM model built from the ACTUAL
  extracted PROM bytes for `0x800400-0x800444`, running the real kernel from
  reset through the boot copy, the `ORI`/`MOVE.L`/`JMP` sequence, and several
  instructions past the jump target, tracing every instruction-fetch bus
  cycle. Confirms `cpu_din` correctly delivers `0x158A` the instant
  `cpu_addr` hits `0x800410` (the ROM-fetch data path is not the bug), and
  -- after fixing an off-by-one sampling bug in the testbench itself (reading
  `last_fetch_addr`/`last_fetch_data` in the SAME cycle as the match, before
  `sftm_main.v`'s own non-blocking assignment for that cycle had landed,
  rather than the cycle after) -- that `last_fetch_addr`/`last_fetch_data`
  correctly pair as `0x800410`/`0x158A`, fully self-consistent. **Neither the
  ROM-fetch data path nor the capture logic in `sftm_main.v` is buggy for
  this exact scenario, at least under an idealised always-ready ROM model.**
- **Two explanations remain, not yet distinguished**: (a) this specific
  hardware reading was a transcription error (plausible -- unlike every
  other reading this session, it wasn't independently cross-checked against
  a photo-decode); or (b) a genuine SDRAM/bcache timing hazard specific to
  real hardware that this idealised simulation (constant `rom_ok=1`, no real
  latency) cannot reproduce -- notably, `0x800410` is exactly a ROM
  LONGWORD-boundary crossing (a new `rom_addr` request, the first word of a
  fresh 32-bit burst), precisely the kind of transition `cpu_rom_gap`/the
  `jtframe_romrq_bcache` module exist to handle carefully, and which a prior
  entry in this log (`grom_cs`/`boot_cs` stale-cache bugs, both fixed
  earlier) already showed this general class of hazard is not hypothetical
  in this codebase. Next step: re-observe `genuine_exc_fetch_word` on
  hardware once more, this time with a photo for independent verification,
  before concluding either way.

- **RECONFIRMED (2026-07-29), via photo this time: `genuine_exc_fetch_word`
  is STILL `0x003C`.** Photo-decoded independently (14.8px-wide stable
  plateau against `BUILD_ID=0xC`, the widest of hundreds of candidate
  alignments) and it matches the earlier plain-text colour transcription
  exactly, block for block. **This rules out a transcription error** -- the
  reading is reproducible across two independent observation methods.
  `pc_snapshot_addr`/`word` also reconfirmed (`0x336BAA`/`0xFFFF`, matching
  the previous boot).
  - **Refined hypothesis**: `0x003C` is not simply a byte-swap of `0x3C00`
    (the real word at `0x800412`, the next address) -- it is exactly
    `zero_extend(0x3C)`, i.e. the LOW BYTE ALONE of that next longword's low
    half, with the high byte reading zero. That is a more specific signature
    than a generic word-swap: right at this ROM longword-boundary crossing,
    only one byte lane of the 16-bit bus appears to be validly captured.
  - Since this reproduces consistently on real hardware but did NOT
    reproduce in the idealised (`rom_ok` constant-1, zero-latency) simulation
    from the previous entry, the leading explanation is now a genuine
    SDRAM/bcache timing hazard specific to real latency at this exact
    transition -- not a bug in `sftm_main.v`'s own logic (already cleared),
    but potentially in the surrounding `jtframe_romrq_bcache` timing/byte-lane
    assembly under real wait states. Not yet investigated further this
    session; would need a more realistic (non-zero-latency) ROM model in
    simulation to test directly.

### Missing SDC constraints fixed and verified with a full rebuild (this session)

Chased the "real SDRAM/bcache timing hazard" hypothesis from the previous
entry as far as it goes with the tooling available. Found something more
fundamental first: **every Quartus build of this project has been running
with NO timing constraints at all.** `mister.qsf` references `SDC_FILE
sys_top.sdc` (bare filename, resolved relative to the Quartus project
directory) with the comment "SDC file is copied and edited in the target
folder" -- but nothing in the stock jtframe/jtcore project-generation flow
actually performs that copy for this project, so every build reported
`Critical Warning (332012): ... file not found: 'sys_top.sdc'` and proceeded
with no `create_clock`/`derive_pll_clocks` for the entire design. This is
separate from (but related to) the already-known `-1.15ns` PLL slack: that
number was measured under this same unconstrained condition and, as it
turns out, wasn't even the real worst path once constraints were correctly
applied (see below).

**Fix**: extended `build_id.tcl` (jtframe's own `PRE_FLOW_SCRIPT_FILE` hook,
already used for the build-ID/CDF generation) to copy the vendored
`sys_top.sdc` into the project directory before the rest of the flow runs.
Applied via the existing `docker/jtframe-patches/` mechanism (same pattern
as the `osd.sv`/`arcade_video.v` patches, copied over the jtframe module by
`docker/entrypoint.sh` on every container start) -- see
`docker/jtframe-patches/target/mister/hdl/sys/build_id.tcl`.

**Also found and fixed while chasing this**: `sftm-quartus` is a fully
standalone image (`Dockerfile.quartus`, not layered on `sftm-build`) with
its own `entrypoint.sh` baked in at image-build time. The copy of that image
present locally predated the jtframe-patches mechanism in its current form,
so a full local rebuild was required to pick up the current logic --
Quartus's own installer files (`docker/quartus-installers/`, 1.7GB + 600MB,
gitignored, must be downloaded manually per Intel's CDN blocking automated
downloads) weren't available on the machine this was first attempted on;
completed instead on `gamingpc` (reachable via Tailscale, `100.89.211.23`,
new SSH config alias `gamingpc-ts`) where they were already present.

**Verified with a full rebuild (2026-07-29, gamingpc, ~10 minutes on native
x86_64 hardware)**: `log/mister/sftm.log` line 35 now reads `Info: Copied
.../sys_top.sdc -> .../cores/sftm/mister/sys_top.sdc`, no "file not found"
warning, and the build completed (`Full Compilation was successful`,
`release/mister/sftm.rbf` md5 `cedbb41eda02815e77bdfba7321633a3`, not yet
deployed to hardware).

**The timing picture changed, but not in the direction the previous entry's
hypothesis needed.** Worst-case setup slack improved from `-1.150ns`
(unconstrained, `pll_hdmi` internal counter) to `-0.339ns` (properly
constrained) -- but the new worst path is `emu|pll|pll_inst`'s OWN internal
PLL output-counter (`altera_pll_i|general[0].gpll~PLL_OUTPUT_COUNTER|divclk`),
still a PLL-internal generator path, not a user-logic path. **None of the
six worst-case setup-slack endpoints in the properly-constrained report
reference `sftm_main`, `TG68KdotC_Kernel`, or anything in the ROM-fetch data
path.** This weakens (does not fully rule out -- Quartus's summary only
lists the worst few paths per category, not an exhaustive report) the
"undetected real timing violation on the CPU/ROM path" theory from the
previous entry: under correct constraints, that path is not among the worst
in the design.

**Where this leaves `genuine_exc_fetch_word`**: still unexplained. Neither
idealised RTL simulation (multiple latencies, real TG68K kernel, real ROM
bytes) nor a properly-constrained Quartus timing report point at a cause.
The only way to fully close this loop now is to deploy this freshly-built,
properly-constrained `.rbf` to real hardware and re-observe
`genuine_exc_fetch_word` directly -- if it now reads `0x158A`, the missing
constraints were somehow implicated after all (e.g. via a placement/routing
difference Quartus made once it had real optimisation targets, not visible
in the static slack summary alone); if it still reads `0x003C`, the mystery
continues and the SDC fix, while a genuine and valuable infrastructure fix
in its own right, is not the explanation.

- **HARDWARE RESULT (2026-07-29): deployed the properly-constrained `.rbf`
  (md5 `cedbb41eda02815e77bdfba7321633a3`) and re-observed. `BUILD_ID=1100=0xC`
  confirmed (same build, SDC fix doesn't touch the diagnostic display), and
  rows 5-7 read the EXACT SAME values as before the fix:
  `genuine_exc_fetch_addr=0x800410`, `genuine_exc_fetch_word=0x003C`. This
  **definitively rules out the missing timing constraints as the cause** --
  the bug is byte-for-bit identical on hardware that now has correct
  `create_clock`/`derive_pll_clocks` applied and passes Full Compilation.
  Combined with the earlier findings (idealised simulation: no desync;
  latency-swept simulation 1-20 cycles: no desync; static timing analysis:
  CPU/ROM path not among the worst even when properly constrained), every
  avenue reachable through RTL simulation and static analysis is now
  exhausted without an explanation.
  - **What's left**: SignalTap (Intel's in-system logic analyzer,
    `jtcore --signaltap` support already exists per its own `--help` output
    -- "Merge syn/signaltap.qsf and enable SignalTap") would capture the
    ACTUAL internal signals (`rom_data`, `rom_ok`, `cpu_a`, `cpu_din`)
    cycle-by-cycle on real hardware during the real fault, with no
    simulation modelling assumptions at all -- the only tool left that could
    plausibly resolve this. Substantial additional setup (a `signaltap.qsf`
    defining capture signals/trigger conditions, a rebuild, and JTAG access
    to read back the captured waveform) not yet attempted this session.
  - Given the effort already spent without resolution, and that
    `genuine_exc_fetch_word`'s exact value doesn't change the ALREADY-SOLID
    finding that the CPU takes a genuine, confirmed line-F exception at
    `~0x800410` after the RAM test with a corrupted vector table (see the
    `genuine_exc_vec_num`/`vecC_hi`/`vecC_lo` entries above, all of which
    stand independent of this specific byte value), this specific
    sub-mystery may be worth setting aside in favour of pursuing the
    original, larger question directly: WHY does the ROM take an F-line
    trap at all right after the RAM test. That question doesn't depend on
    resolving the `0x003C` discrepancy first.

- **Real control-flow disassembly past the RAM test, and a full-ROM simulation that reaches the main loop (this session, 2026-07-30)**: Picking up the "why does the ROM take an F-line trap right after the RAM test" question directly (per the prior session's recommendation), used `capstone` (`CS_ARCH_M68K`/`CS_MODE_M68K_020`) against the real reconstructed ROM (four PROM dumps, validated `(0,1,2,3)` byte-lane order) to trace the ACTUAL post-RAM-test control flow for the first time, rather than reasoning about it secondhand.
  - **RAM self-test fully disassembled** (`0x80158A`-`0x8016D0`): a proper march test — phase 1 (`0x80158A`-`0x8015B0`, outer `d3=0x1FFF`/8192, table-driven inner pattern write+verify, address-marker write) sweeps all 32 KB; phase 2 (`0x8015B4`-`0x8015CE`, same outer count) verifies the address markers and clears; phase 3 (`0x8015EE`-`0x8016C6`) is four small (`d3≤0xF`) byte/word/misaligned-word/misaligned-long addressing-mode sub-tests. All exit paths converge on the shared continuation at `0x800412` with the result code in D0/D6.
  - **`0x800412` traced through in full**: ROM→RAM vector copy (`0x800414`-`0x80042E`, 64 longwords), RAM clear `0x400`-`0x7C00` (`0x800430`-`0x800444`, byte-at-a-time, 31,232 iterations), a hardware-port read (`0x80044A`: `move.b $80001.l,d0`) gating a flag at `$1020.w`, then `jsr $80102C` (nine further subroutine calls) and `jsr $800802`, converging on `0x80046C`: `jsr $8006BA` + watchdog kick (`move.b d0,$400000.l`) + `bra.b $80046c` — **exactly** the already-documented outer-main-loop pattern `wdog_kick_ever` watches for.
  - **Correction to a suspicion raised mid-session**: `sub_800614` (`0x800614`-`0x800670`) builds two composite hardware-config words from six byte reads — `$80001.l`, `$100001.l`, `$180001.l`, `$200001.l`, `$280001.l`, `$780001.l` — that looked at first like unmapped-address reads. Checked directly against MAME's real `itech32.cpp` (`itech020_map`, the actual memory map `sftm`'s machine config uses, confirmed via its `GAME()` macro entry): the first five map address-for-address onto our own `REG_INP0/INP1/INP2/SYS/DIP` (`ahi==0x08/0x10/0x18/0x20/0x28`) — legitimately mapped on both sides, not a decode gap. `$780001.l` (`ahi==0x78`) is genuinely absent from `itech020_map` too (a similarly-named `EXTRA` port at that address only exists in the unrelated `bloodstm_map`, used by different games) — so both real hardware and our FPGA return the same unmapped-bus default there. This lead is closed; not the bug.
  - **Methodological gap found**: `genuine_exc_vec_num`/`genuine_exc_fetch_addr`/`genuine_exc_fetch_word` (`sftm_main.v`) reset only on hard `rst`, never on watchdog-triggered `w_rst` — by design, to "capture the ORIGINAL fault". That means the frozen `0x800410`/`0x003C` hardware capture reflects only the CPU's first-ever qualifying vector-table read since power-on, and nothing after it is ever observed again, however many soft reboots follow.
  - **Full-ROM simulation, attempt 1 (apparent hang, later found to be a testbench artifact)**: built `/tmp/tb_full_rom.v` loading the COMPLETE 1MB ROM via `$readmemh` (every earlier testbench this project has used only modelled a small hand-picked address window and NOP-filled everything else, so none of them ever actually executed the real RAM test or post-test code). This design's bus timing model costs roughly 1,000-4,000 clock cycles per instruction fetch in iverilog, making the unpatched ~40,000-iteration RAM-test+clear-loop impractical to simulate in real time, so the two `0x1FFF` march-test loop bounds and the RAM-clear loop's `$7C00` bound were patched down to tiny values in the simulated ROM copy only (same instruction sequence, far fewer iterations). First run appeared to hang permanently at `0x8C1B86` (inside `sub_8C1B6C`, part of the protection-chip interaction: builds an index from the protection shadow byte at `$7A6A`, looks up palette RAM at `$580000`, writes the result to the protection port `$680002`) — `busstate` itself went permanently `x` (undefined) shortly after. Traced via cycle-level tracing to a self-inflicted bug: shrinking the RAM-clear loop's bound for speed also left RAM addresses beyond `0x408` — including `$7A6A` — as simulator-X forever (`sftm_ram.v`'s work-RAM instance has no reset/init by design; only the NVRAM instance uses `$readmemh` preload), and that X propagated through the protection/palette-index computation until the CPU's internal state corrupted. A real hardware clear loop would have zeroed that location; this was purely an artifact of the speed patch, not a finding.
  - **Full-ROM simulation, attempt 2 (fixed, and a real result)**: added a testbench-level zero-init of `uut.u_ram.mem_lo`/`mem_hi` (16,384 entries each) at time 0, reproducing the END STATE the real, unpatched clear loop would produce without paying its iteration cost. With that fix, the simulated CPU **boots cleanly, passes the RAM test, correctly reads the hardware/DIP ports, and reaches and sustains the real outer main loop for 25,677,889 instruction fetches** (roughly 1 second of simulated runtime) — repeatedly cycling through `0x8006BA`/`0x800802`/`0x80046C` with a watchdog kick every iteration. Along the way, `genuine_exc_seen` DID latch, but on `vec=31` (level-7 autovector) at `fetch_addr=0x80070C` — the design's own forced, deliberate IPL7 test pulse (`ipl7_pulse_ever`, ~1s post-reset) firing during otherwise-normal execution, not a real fault; this independently confirms the one-shot latch can be consumed by the diagnostic's own test mechanism before any real exception, undermining confidence that the hardware-captured `0x800410`/`0x003C` reflects the actual recurring failure rather than some other early, possibly transient, first-ever event. The run eventually lands in the ROM's own documented crash handler (`0x8008F0`-`0x800930`, `jmp $800930.l` self-halt, records the vector 0-6 to RAM `$0FBE` — see the pre-existing `exc_code_ram` diagnostic) roughly 25 million fetches in; this is most likely an artifact of this testbench's own oversimplified stimulus (`LVBL` tied permanently to `1'b1`, never toggling, unlike real ~60 Hz video timing) rather than a new finding, and is not being treated as one.
  - **Conclusion**: this is the most complete, most faithful simulation of this boot sequence run to date — full real ROM content, correctly-initialised RAM, real hardware/DIP port decode cross-checked against MAME source — and it cleanly reaches and sustains the real main loop, which is the opposite of every established hardware symptom. Combined with the already-exhausted idealised/latency-swept simulation and static timing analysis from the prior session, this substantially raises confidence that the bug is **not** reachable through behavioural RTL simulation at all. **SignalTap is now the clearly necessary next step**, not just the recommended one. `exc_code_ram` (RAM `0x0FBE`, already wired to the on-screen diagnostic) is a ready-made, ROM-provided trigger/observation point for it: if real hardware ever reaches the ROM's own crash handler, that word will hold a small number (0-6) rather than a RAM-test-sweep artifact like the previously-observed `0x2700`.

- **`genuine_exc_*2` (w_rst-resetting, IPL7-excluded) hardware result: byte-identical to the original capture (this session, 2026-07-30)**: Implemented the fixes described above (`exc_vec_rd` excludes vectors 24-31; new `genuine_exc_vec_num2`/`fault_in_ramtest2`/`genuine_exc_fetch_addr2`/`genuine_exc_fetch_word2` reset on `w_rst` instead of only hard `rst`), validated in simulation (new `/tmp/tb_genexc2.v`, 10 checks: interrupt-exclusion boundary at vectors 23/31, and the core w_rst-vs-rst regression — all pre-existing testbenches re-run clean, no regressions), rebuilt on gamingpc (0 errors, 272 warnings, worst-case setup slack -0.645 ns — consistent with every prior build), and deployed via scp gamingpc→mister (`root@10.10.10.98`, using the `mister` SSH alias with the legacy KEX/hostkey algorithms its older sshd needs — a bare IP with default settings fails auth). **HARDWARE RESULT, photo-decoded and cross-validated (row 2-3 vs row 6-7 both read independently and agree exactly)**: `genuine_exc_vec_num2=11` (line-F), `fault_in_ramtest2=0`, `genuine_exc_fetch_addr2=0x800410`, `genuine_exc_fetch_word2=0x003C` — **byte-identical to the original, hard-rst-only `genuine_exc_fetch_addr`/`word` capture**, read simultaneously in the same photo (rows 6-7 = `0x800410`, matching rows 2-3 exactly). `exc_code_ram` (row 5) again read `0x2700`, the same RAM-test-sweep artifact as every prior check — the ROM's own internal crash handler is still never reached.
  - **This closes out the methodological concern raised earlier in this session, in the CPU's favour**: the worry was that the frozen hard-rst-only capture might reflect a stale, one-time, possibly-spurious event from the very first boot attempt (e.g. consumed by the IPL7 test pulse, per the full-ROM simulation finding above) rather than the genuinely recurring fault. This result rules that out directly: a capture that (a) re-arms on every watchdog soft reboot rather than freezing forever, and (b) is structurally immune to IPL7 latch-theft, landed on the exact same address and opcode word anyway. `0x800410`/`0x003C` is not a fluke of attempt #1 — it is what real hardware faults on, reproducibly, on whatever boot attempt this reading came from.
  - **Combined with the full-ROM simulation result above, this is now about as strong a case as RTL simulation and on-screen diagnostics can build without an actual capture**: idealised, full-ROM, correctly-initialised simulation runs this exact code path cleanly with no fault anywhere near `0x800410` and reaches the real main loop; real hardware faults there consistently, immune to every alternative explanation tested so far (stale one-shot capture, IPL7 latch theft, RAM-test false-positive, missing timing constraints — see the SDC fix entry above, re-verified byte-identical post-fix). The remaining candidates are all things only real in-system capture can distinguish: genuine synthesis/placement timing violation on this specific path, a TG68K VHDL→Verilog conversion discrepancy between simulated and synthesised behaviour, or an SDRAM/BRAM inference timing edge case. SignalTap is the tool for exactly this kind of question.

- **SignalTap prep: `.stp` file built and verified, but scripted enable is structurally incompatible with jtcore's build methodology (this session, 2026-07-30)**: A USB Blaster clone was ordered (2-day shipping) to make real in-system capture possible; this entry covers the prep done while waiting for it to arrive, so the capture can start immediately once JTAG hardware exists.
  - **No `::quartus::stp` Tcl package exists** in this Quartus install (confirmed via `package require` inside the container) — there is no API for building a SignalTap `.stp` file programmatically, only for enabling/pointing a project at one that already exists (`ENABLE_SIGNALTAP`/`USE_SIGNALTAP_FILE`/`SIGNALTAP_FILE` global assignments). The `.stp` format itself is a plain, human-readable XML file, though, so it can be hand-authored directly — done here against a real reference `.stp` from an unrelated open-source DE10-Nano project (`nullobject/de10-nano-sprite`, same 5CSEBA6 device), not guessed from scratch.
  - **`cores/sftm/mister/sftm_ram_fault.stp`** (staged via the same `docker/jtframe-patches/` + `build_id.tcl` PRE_FLOW_SCRIPT_FILE mechanism already used for the SDC fix, since `cores/*/mister/` is entirely gitignored/regenerated every build and a file placed there directly would never survive a rebuild): captures `rom_addr[17:0]`/`rom_data[31:0]`/`rom_cs`/`rom_ok`/`cen`/`clkena`/`busstate[1:0]`/`cpu_addr[23:1]`/`cpu_din[15:0]`/`exc_vec_rd` (~161 bits/sample), sample depth 1024 (comfortably inside the design's free M10K budget — 44 of 553 blocks free per the last non-SignalTap build), triggered on `genuine_exc_seen2` rising edge — the *2 (w_rst-resetting) capture specifically, so the trigger re-arms on every watchdog soft reboot instead of needing a fresh power cycle per capture attempt. Hierarchy paths (`emu:emu|jtsftm_game_sdram:u_game|jtsftm_game:u_game|sftm_main:u_main|...`) and the clock net name (`emu:emu|clk_sys`) were confirmed against the real project's own `sftm.map.rpt` from an actual successful build, not guessed. `sftm_main.v`: added `/* synthesis keep */` to `busstate`/`cpu_din`/`exc_vec_rd` (pure internal wires that could otherwise be optimised away or renamed before probing) — `cpu_addr` needed no change, already a top-level port.
  - **Node references and `.stp` structure ARE confirmed correct**: across four separate build attempts with SignalTap enabled, Analysis & Synthesis and Fitter both accepted every probed node without error every time (0 errors on those stages in every attempt) — the file itself, the hierarchy paths, and the trigger condition are all genuinely right.
  - **But actually enabling it through jtcore's scripted build consistently fails**: tried four different mechanisms to set `ENABLE_SIGNALTAP`/`USE_SIGNALTAP_FILE`/`SIGNALTAP_FILE` — (1) `set_global_assignment` calls inside `build_id.tcl`'s existing `project_open`/`project_close` block, (2) the same but guarded to be idempotent (only assign if not already set), (3) dropping an accompanying `export_assignments` call in case that was the trigger, (4) bypassing the assignment API entirely and appending the three lines directly to the `.qsf` text file before the very first `project_open`, matching `copySysTopSdc`'s own proven-safe "touch files directly" style. **All four failed identically**: every individual stage (Analysis & Synthesis, Fitter, Assembler, Timing Analyzer) reports success on its own, but the overall flow then reports `Error (125085): The Quartus Prime Settings File changed outside of the Quartus Prime software...` followed by `Error (293034): Current flow Full Compilation ended unexpectedly`. A controlled A/B (commenting out just the one `enableSignalTap` call, nothing else changed) restores a clean 0-error build every time.
  - **Conclusion**: this is a genuine structural incompatibility between SignalTap and jtcore's build methodology — each Quartus stage is invoked as a **separate process** (`quartus_map`, then `quartus_fit`, then `quartus_asm`, then `quartus_sta`, each a fresh `docker run`/CLI invocation per `docker/run-synth.sh`), and SignalTap's own cross-stage state tracking does not tolerate that, regardless of when or how the enable flag gets into the `.qsf`. Not a bug in this session's Tcl code four times over — a real mismatch between SignalTap and this project's build tooling.
  - **`enableSignalTap` is left defined but NOT called** in `build_id.tcl` (commented out at the call site, not deleted) so normal scripted builds stay clean; `copyStpFile` still runs unconditionally, so `sftm_ram_fault.stp` is present and current in the project directory on every build regardless.
  - **Practical path once the Blaster arrives**: gamingpc has a real desktop (KDE/Wayland, confirmed running) capable of hosting the Quartus GUI directly. The GUI's "Start Compilation" runs the whole flow as a single session (`execute_flow` within one process), not separate CLI invocations, and should not hit this specific issue. Import the already-verified `sftm_ram_fault.stp` there (Assignments → Settings → SignalTap Logic Analyzer, or File → Open on the `.stp` directly), compile, program via the Blaster, and run the capture — no further scripting investigation needed first; the file and its node references are already validated correct.

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
