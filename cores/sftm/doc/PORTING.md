# Porting strategy: literal function-level port from MAME

This restart replaces the from-scratch/guessed RTL that occupied this tree
previously (custom blitter, video and CPU glue reverse-engineered without a
close MAME reference) with a **literal, function-by-function port** of MAME's
`itech/itech32.cpp` driver. Every register, address range and algorithm in
the new HDL should be traceable back to a specific function and line number
in the MAME source. That source is vendored for reference (not for
redistribution) under `doc/mame-src/`:

| File | Purpose |
|---|---|
| `itech32.cpp` | CPU memory maps, interrupts, inputs, ROM loading, driver init |
| `itech32.h` | `itech32_state` member declarations (register widths, defaults) |
| `itech32_v.cpp` | Blitter/video: register file, blit commands, screen_update |
| `es5506.cpp` / `.h` | Ensoniq ES5506 (OTTO) sound chip |

Fetched from `mamedev/mame` `master` on 2026-08-12. `itech32.cpp` covers many
games on this driver (Time Killers, Bloodstorm, World Class Bowling, Golden
Tee, etc.) — **only the `sftm` machine config path applies to us**:
`itech32_state::sftm()` (machine config), `itech020_map()` (memory map),
`init_sftm()` / `init_sftm_common()` (driver init), `INPUT_PORTS_START(sftm)`
+ `itech32_base_32bit` (inputs).

## What "literal port" means here, precisely

MAME's driver code is two different kinds of thing, and they port
differently:

1. **Register/decode semantics** (address ranges, what each video register
   byte does, the blitter's per-pixel loop math, interrupt bit layout,
   protection shortcut). This is directly, mechanically portable: an HDL
   `case` on address bits mirroring a C `switch`, a pixel-stepping state
   machine mirroring a C `for` loop. Every module below cites the MAME
   function and line number it mirrors.

2. **Bus cycle timing** (DTACK wait states, SDRAM latency, clock-enable
   sequencing). MAME doesn't model this at all — it's a functional emulator,
   not a timing-accurate one. There is nothing to "port" here; this is
   original FPGA integration work, designed against TG68K.C's actual timing
   contract (see `hdl/tg68k/TG68K.vhd`) and JTFRAME's SDRAM controller
   handshake (`*_cs`/`*_ok`). Treat these parts as unverified until they've
   been through simulation (Phase 4) — they cannot be checked against MAME.

## Findings carried over from the previous implementation

Three things were established the hard way (weeks of USB-Blaster/SignalTap
debugging on hardware) and must not regress; they are re-implemented and
documented at the top of `hdl/sftm_main.v`:

1. **Vector-table bootstrap**: `init_program_rom()` (itech32.cpp:4893) copies
   the first 0x80 bytes of program ROM into RAM at 0 before the CPU runs,
   because `sftm` maps `0x000000-0x007fff` as RAM and the reset SSP/PC
   vectors live there. The `S_BOOT` FSM in `sftm_main.v` replicates this
   before deasserting CPU reset.

2. **IPL mapping**: VINT (vblank) → IPL1, XINT (blitter) → IPL2, QINT
   (scanline) → IPL3, `m_irq_base = 0`, autovectored. Three separate levels;
   an earlier theory that collapsed vblank+blitter onto IPL2 was wrong and
   caused the CPU to never take the FPGA's interrupts.

3. **SDRAM byte order**: JTFRAME assembles the download stream little-endian
   (`data[7:0]` = lowest byte address); the 68020 is big-endian, so each
   16-bit fetch swaps bytes within its half of the 32-bit SDRAM word. The
   `0x003C = byteswap(low half)` SignalTap capture (commit `d22fe93`)
   confirmed this on hardware.

## New finding this restart: mem.yaml addr_width was undersized

jtframe's `addr_width` counts **byte**-address bits (generated port is
`[addr_width-1 : log2(data_width/8)]`), but the old `cfg/mem.yaml` treated it
as *word*-address bits. Every SDRAM bus was silently declared at half or a
quarter of its required size — `main` reached only 256KB of the 1MB program
ROM, `grom` only 16MB of 32MB. Any CPU fetch above 0x40000 into the program
region would wrap/alias, which fits the class of "CPU wanders into garbage"
faults seen on hardware. Corrected in this restart (main 20, srom 22, grom
25, grm3 19); `mem_ports.inc`/`*_sdram.v` must be regenerated (Phase 4).

## Protection: no PIC emulation needed

`itech32_state::itech020_prot_result_r()` (itech32.cpp:637) just reads back a
byte from main RAM at a fixed address (`m_itech020_prot_address`, set to
`0x7a6a` for `sftm` v1.12 / `0x7a66` for v1.11 in `init_sftm_common`,
itech32.cpp:4980). MAME doesn't emulate the PIC16C54 at all for this game —
the game code writes an expected value into that RAM location itself, and the
"protection check" at `0x680002` just reads it back. Our port does the same:
`0x680002` reads `main_ram32[prot_addr]`, no MCU model required.

## Module map (target)

| MAME source | HDL module | Phase | Status |
|---|---|---|---|
| `itech020_map`, `update_interrupts`, `generate_int1`, `int1_ack_w`, `color_w`, `sound_data_w`, `itech020_prot_result_r`, `itech020_plane_w`, `init_program_rom`, input ports | `hdl/sftm_main.v` | 1 | done (unverified — needs sim) |
| `itech32_v.cpp` in full: `m_video[]` register file, `handle_video_command`, `command_blit_raw`/`draw_raw*`, `draw_rle*`, `command_shift_reg`/`shiftreg_clear`, `video_r`/`video_w` (incl. dynamic HTOTAL/VTOTAL), `screen_update` | `hdl/sftm_video.v` | 2 | placeholder stub only |
| `sound_020_map`, `sound_bank_w`, `sound_data_buffer_r`, `sound_control_w`, `firq_clear_w` + MC6809 wrapper | `hdl/sftm_snd.v` (CPU glue) | 3 | placeholder stub only |
| `es5506.cpp`/`.h` (32-voice engine, envelopes, filters, loop modes) | `hdl/sftm5506.v` | 3 | not started |

`sftm`-specific machine parameters from `init_sftm_common` /
`itech32_state::sftm()`: `m_vram_height = 1024`, `m_planes = 1` (single VRAM
plane — screen_update has no plane-blend path for this game, simplifying
Phase 2 considerably), palette format `xRGB_888` 32768 entries, CPU020_CLOCK
25 MHz, SOUND_CLOCK 16 MHz.

## Validation plan

1. ~~Phase 1: CPU/memory-map glue~~ (this session, unverified)
2. Phase 2: blitter/video literal port
3. Phase 3: sound (MC6809 glue + ES5506 literal port)
4. Phase 4: regenerate `mem_ports.inc`/`files.qip` via `jtframe mem`/`jtframe
   files`, update `ver/game` testbenches, simulate, then build via
   `docker/run-synth.sh`. Hardware bring-up (SignalTap over the USB Blaster,
   Quartus itself) happens on gamingpc, not this machine.

No ROMs are included. `doc/mame-src/` is a local reference copy of MAME
driver source for porting purposes only — not distributed, gitignored.

---

# Hardware bring-up log (2026-08-12/13)

The core boots on real hardware. Everything below was measured on a
DE10-Nano via the JTFRAME debug overlay (`debug_view`, rendered as two hex
digits) driven by an auto-cycling view mux in `sftm_main.v`, captured by
scripting `screenshot` into `/dev/MiSTer_cmd` and decoding the glyphs.

## Verified working against the game's own behaviour

Each of these is confirmed by the game programming values that match the
hardware spec independently of my expectations:

| Evidence | Meaning |
|---|---|
| `boot_done=1`, bus FSM cycling | vector bootstrap + CPU execution |
| Game writes `HTOTAL=0x01FC`, `VTOTAL=0x011E`, visible 384x256 | CRTC, decode and register file correct |
| Game writes `INTENABLE=0x0144` (MAME's documented startup value) | register file + address decode correct |
| `INTSCANLINE=0x00FF` | scanline compare programmed |
| INTSTATE sticky-OR = `0x0044` | BOTH interrupt sources fire |
| INTSTATE reads 0 live, sticky non-zero | the CPU is acking, i.e. the ISRs run |
| Blitter: `blit_done_ever=1`, idle, never stalled | blitter completes commands |
| `prot_rd=1` | protection readback path exercised |

## Open symptom

`pal_wr`, `snd_wr`, `nvram_wr` are all sticky-zero: the game never writes
the palette, never sends a sound command, never touches NVRAM. Every pen
therefore resolves to black. The ROM does contain palette code (291
absolute references into 0x580000-0x59FFFF), so that code is simply never
reached.

## Timing: the design rides the edge on TG68K

Worst-case setup slack across builds of near-identical logic:
`+0.565, +0.246, -3.690, -0.409, +0.115, -0.020, -0.289`. Every failing
path is inside the vendored `TG68KdotC_Kernel` register file
(`store_in_tmp`/`exec[27]` -> `regfile~*`), i.e. placement variance on an
inherently marginal CPU core, not a regression in this port.

**Do not "fix" this with a blanket multicycle constraint.** TG68K has 13
`rising_edge(clk)` processes and only 9 are gated by `clkena_lw`; several
(VHDL lines 464, 1053, 4010) update every clock regardless of the clock
enable. A multicycle over all TG68K registers would hide genuine
violations on the ungated ones.

Practical rule until this is solved properly: **check
`Worst-case setup slack` BEFORE deploying, and only trust diagnostics
from a build that closes.** A marginal bitstream produces plausible but
untrustworthy readings -- `pc_max` landed in a data region on the
-0.289 ns build, which may be a real runaway or may be a timing artifact,
and there is no way to tell them apart after the fact.

The one genuine timing fix found so far was structural and is already in:
the ES5506 filter was the true critical path (`vn -> fsamp`, -3.690 ns)
because the voice index drove 32-entry array muxes straight into the
multiply and adds in one cycle. Pre-latching the per-voice coefficients
and splitting each pole into multiply/accumulate stages removed it and
*reduced* ALM usage from 85% to 80%.

## Diagnostic technique notes (learned the hard way)

- For anything that can be cleared, measure a **sticky accumulator**, never
  a sample. Reading live INTSTATE between set and ack produced a confident
  but completely wrong conclusion.
- Latch event-triggered captures on a **useful** occurrence, not the first
  one. `pc_stuck` latched during early boot and was blind to steady state.
- Address ranges alone cannot identify a vector fetch: the RAM self-test
  sweeps 0x60-0x6F like any other memory, so a "vector fetched" probe keyed
  on address is a false positive generator.
- The game's own ROM is the ground truth. Disassembling it (capstone,
  `CS_ARCH_M68K`) settled several questions that hardware probes could not:
  the L1/VINT vector points at a deliberate crash trap (`jmp` to itself), so
  this game masks level 1 by design and never writes the `0x080000` ack.

---

## Bring-up status after the rev12 measurement (2026-08-13)

**The interrupt/video/CPU infrastructure is fully working.** Measured on
timing-clean builds (game clock closes at +1.8 ns or better since the TG68K
multicycle constraint landed):

| Measured | Result |
|---|---|
| Game's own RAM self-test, RAM[0x400] | **0 = PASS** |
| INTENABLE | `0x0144` -- the game enables scanline and blitter itself |
| scanline_hit | fires continuously |
| INTSTATE bit2 rising edges | continuous |
| INTACK writes | continuous, value `0x04`, PC = 0x80130C |
| Writes to RAM[0x1104] | **255 (saturated)**, PC = 0x801310 |
| Blitter | completes commands, idles, never stalls |

So: the scanline interrupt fires, the CPU takes it, the QINT handler runs to
completion, and the raster-split chain advances -- which means the deferred
palette flush at 0x800F24 is being called on schedule. It simply finds an
empty queue.

### Correction to earlier entries in this log

Several intermediate conclusions here were wrong and are retained only as a
warning about method:

* "the video block never raises either status bit" -- artifact of reading a
  live register between set and ack. Fixed by an OR-accumulator.
* "the scanline interrupt is not firing / RAM[0x1104] is frozen at 6" --
  **sampling bias**. That word cycles 2->4->6 and 6 dwells longest, because
  the interval from the last raster split back through vblank to the first is
  the longest. A write COUNTER showed 255 writes where single samples had
  looked frozen for four consecutive builds.
* "the game disabled the scanline source (INTENABLE=0x20)" -- refuted; the
  live register reads 0x0144.
* "the CPU executed into a data region" -- misaligned disassembly; 0x8C1xxx
  is real code reached by `jsr $8c1b54` from init.

The recurring lesson: **for anything that changes over time, measure a
counter or an accumulator, never a sample.** Every wrong turn above came
from inferring steady state from a snapshot.

### Genuine bugs found and fixed along the way

1. ES5506 filter was the design's critical path (`vn -> fsamp`, -3.69 ns);
   pre-latching per-voice coefficients and splitting each pole into
   multiply/accumulate stages fixed it and *reduced* ALM usage.
2. INTSTATE had three separate non-blocking writers, so simultaneous
   events silently lost one. Combined into a single expression.
3. INTSCANLINE was compared exactly; MAME normalises modulo screen height.
   Now reduced iteratively (the game can produce 0xFFFF from RAM[0x1118]-1).
4. Palette RAM coding style prevented BRAM inference and crashed quartus_map.
5. `cfg/mem.yaml` addr_width counts BYTE bits -- every SDRAM bus had been
   declared undersized.

### Open question

The dispatcher task count at RAM[0x044E] is 0, nothing queues a palette
change, and nothing queues a sound command -- so the game runs its scheduler
and interrupt handlers but never starts any game work. That is now the only
symptom left, and it is a game-state question rather than a hardware one.
