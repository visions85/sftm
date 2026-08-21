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

## Trace result (rev13, 2026-08-13): the game runs; three regions stay untouched

The disassembly trace established that all game activity depends on one
chain, and hardware measurement then confirmed every link of it:

    QINT handler --(raster wrap, RAM[0x1104]==6)--> 0x80131C
         |-- jsr 0x800F24   flush the deferred palette queue
         |-- jsr 0x8004B6   read inputs, feed the event queue
         \-- addq.w #1,$44a.w   timer tick (0x801332)
    main loop 0x8006BA walks the timer list at $fb6 against that tick
    0x8005C4 installs the boot task at 0x829908

Measured on hardware (all counters, not samples):

| Probe | Result |
|---|---|
| tick writes / value | saturated; value visibly advancing |
| wrap-branch count | saturated |
| RAM[0x1104] writes | saturated |
| `task_ever` (PC in 0x829xxx) | **1 -- the boot task executes** |
| self-test verdict | 0 = PASS |
| pal_wr / snd_wr / nvram_wr | **0 / 0 / 0** |

So the machine boots, self-tests, initialises, services both interrupts,
ticks its timers, dispatches tasks and executes game code -- while never
writing the palette (0x580000), the sound latch (0x480000) or NVRAM
(0x600000). Writes to every other region (RAM, video regs 0x500000,
watchdog 0x400000, colour latches 0x300000/0x380000, plane latch 0x700000)
demonstrably work.

The palette detection itself is verified, not assumed: a dedicated
simulation (`tb_pal`) writes 0x580000 and confirms both that `sf_pal_wr`
asserts and that palette RAM reads back correctly. So the flag is right and
the game really is not writing there.

Also retired here: RAM[0x044E] reading 0 is **correct**. That counter is fed
by input EDGES (0x800516 XORs current inputs against the previous value and
queues one event per changed bit), so with no controls connected zero is the
expected idle value, not a stall.

### Suggested next step

Capture the live PC (`pc_now`, re-latched once per view cycle) and
cross-reference against the disassembly to see which routine the game is
actually executing in steady state. Everything upstream is proven, so the
question is now simply what that code is waiting on before it loads a
palette. The ROM is reconstructed locally and capstone-disassemblable, so
any address it reports can be read directly.

## Root cause found (2026-08-13): the DIPS byte was read from the wrong bits

The blank screen had a single cause, and it was in eight characters of
Verilog. `jtsftm_game.v` did `assign dipsw_a = dipsw[7:0]` when the DIPS
port payload lives at `dipsw[23:16]`.

### How MAME settled it

Two MAME v0.289 reference runs on the same ROM did what four rounds of
hardware probing could not.

**Run 1 -- write tap on the palette window.** MAME writes `0x584000` at
frame 5 from PC `0x82A5F0`; a stack dump at that moment gave the call chain
`0x829908` (boot task) -> `0x82A26E` -> `0x82A30E` -> `0x82A498` ->
`0x82A5F0`. Hardware already showed the core entering `0x829xxx`, so the
failure was somewhere along that chain.

**Run 2 -- read tap over `0x829900-0x82A5FF`, recording opcode fetches until
the palette write.** Only 62 addresses. Disassembling exactly those showed
the path is *straight-line* from `0x82A26E` to `0x82A5F0`: no conditional
branches at all. So the only way to stall is a `jsr` that never returns,
which narrowed the search to five subroutines. `0x802384`, called twice at
`0x82A2FC` and `0x82A302`, is a spin-wait:

```
80238C: btst.b  #$6, $280001.l
802394: beq.b   $8023a2          ; bit clear -> fall through, proceed
802396: move.w  #$1, d0
80239A: jsr     $800710.l        ; coroutine yield: saves A7, jumps to the
8023A0: bra.b   $80238c          ; scheduler at 0x8006f2, never returns
```

`0x280000` is DIPS (`itech020_map`, itech32.cpp:1010), and for sftm MAME
places the 8-bit port payload at bits 16-23 (itech32.cpp:1043,
`m_dips->read() << 16`). A read tap showed MAME returning `0x0F` in that
byte, so bit 6 is clear and the loop falls through on the first test.

### The bug

The MRA was already correct -- it declares the four SW1 switches at dipsw
bits 20-23 with `default="ff,ff,0f"`, which makes the DIPS byte `0x0F`,
bit-identical to MAME. The HDL took `dipsw[7:0]` = `0xFF` instead, setting
bit 6 (SW1:3). The boot task therefore yielded to the scheduler forever and
never reached the palette, the sound latch or NVRAM -- the exact three
regions the rev13 trace found untouched.

`dipsw_a` is now literally MAME's `m_dips->read()` byte. The bit comments in
`sftm_main.v` were also wrong (SW1:1-SW1:4 reversed, and `0x40` labelled
"Freeze Screen"); they now match the actual `PORT_START("DIPS")` block:

| bit  | signal                        | default |
|------|-------------------------------|---------|
| 0x01 | service mode (active low)     | 1       |
| 0x02 | service coin (active low)     | 1       |
| 0x04 | vblank status                 | 1       |
| 0x08 | `special_port_r` (ACTIVE_HIGH)| 1       |
| 0x10 | SW1:1 Video Sync              | 0       |
| 0x20 | SW1:2 Flip Screen             | 0       |
| 0x40 | SW1:3 Violence                | 0       |
| 0x80 | SW1:4 Service (ACTIVE_HIGH)   | 0       |

Note the lower nibble already matched MAME exactly. Only the switch nibble
was wrong, which is why everything upstream -- CPU boot, memory map, both
interrupt sources, the blitter, the timer tick, task dispatch and the game's
own RAM self-test -- passed while the screen stayed blank.

### Method note

The decisive step was not another hardware probe. It was taking a *reference
implementation of the same ROM* and asking it what value the hardware
returns, then diffing against ours. A read tap plus a 62-line disassembly
beat four build-deploy-capture cycles. For a literal port, reach for the
reference emulator before instrumenting the FPGA.

Two hypotheses were killed cheaply the same way, before they cost a build:
- **Input polarity.** `jtframe_board.v:290` compares the joystick nibbles
  against `8'hff` to detect "nothing pressed", so JTFRAME's inputs are
  active low, matching MAME. `p2_byte` reads `0xFF` idle, as intended.
- **Zero task count.** `RAM[0x044E]=0` looked alarming but MAME shows the
  same value; it is normal, not a symptom.

### Hardware result after the fix (build 23, 2026-08-13)

Timing closed first try: game clock setup **+2.788 ns**, hold **+0.242 ns**,
TNS 0.000 on every domain.

The screen is no longer blank. Screenshots went from ~1.7 KB (solid black)
to ~62 KB, and a side-by-side against a MAME snapshot of the same attract
screen shows the **background artwork matches exactly** -- same gargoyle and
hands, same dark blue texture, same palette. The blitter, palette, scanout
and CRT timing are all working on real hardware.

**Remaining defect, now well scoped:** the text/sprite layer draws as a 50%
checkerboard where glyphs should be. MAME's frame reads "STREET FIGHTER /
LIFE-LIKE VIOLENCE - MILD / ..."; ours puts dithered blocks in exactly those
positions, with the correct layout and roughly the right extents. An
alternating-pixel pattern points at pixel *stepping* rather than addressing
-- a candidate list, in order of suspicion:

1. `draw_rle` transparency: every other pixel taking the transparent branch.
2. 4-bit pixel unpacking in the GROM byte fetcher (nibble hi/lo swap or a
   double-advance).
3. `draw_raw_widthpix` stepping two source pixels per destination pixel.

The background uses a different draw path from the glyphs, which is why one
is right and the other is not -- that asymmetry is the main clue.

## Two separate video bugs (2026-08-13)

Chasing the glyph checkerboard turned up a second, unrelated defect. They
are recorded separately because conflating them wasted a cycle.

### Bug A: the scanline prefetch cannot keep up (proven, not yet fixed)

`tb_scanout.v` backdoor-fills one VRAM line with a ramp, runs the CRT, and
captures `scan_pen` across the line. Sweeping the modelled SDRAM read
latency:

| latency | pixels correct | first bad x |
|---------|----------------|-------------|
|  3 clk  | 380 / 384      | 380         |
|  5 clk  | 304 / 384      | 304         |
|  7 clk  | 253 / 384      | 253         |
|  9 clk  | 216 / 384      | 217         |
| 12 clk  | 179 / 384      | 180         |

The failures are always the tail of the line, and the cutoff tracks latency
exactly. This is arithmetic, not a logic error: a line is 508 pxl_cen x 6
clk = 3048 clocks, so 384 words gives a budget of **7.9 clk per word**,
while one random SDRAM read through the `cs`-toggle handshake (A_IDLE +
settle + latency + A_GAP) costs more than that on real hardware. Sustaining
scanout needs 384 x 286 x 60 = 6.6 M words/s, which single-word random
access at 48 MHz cannot deliver.

Single-word reads are the wrong primitive here. The fix is to stop doing
384 independent round-trips per line -- burst reads, a wider read path, or
more buffers so the prefetch has more than one line of time. Reducing the
`settle` count from 2 to 1 is worth ~30% but does not close the gap alone.

### Bug B: the glyph checkerboard (still open)

Not explained by Bug A. Starvation corrupts only high x; pooled over 34
hardware frames the isolated-pixel fraction is uniform across the width:

| x range | bright px | isolated % |
|---------|-----------|------------|
| 0-47    | 571       | 100.0%     |
| 48-95   | 3733      | 88.0%      |
| 96-143  | 30244     | 95.3%      |
| 144-191 | 6424      | 90.1%      |
| 192-239 | 7011      | 90.3%      |
| 240-287 | 17878     | 81.9%      |
| 288-335 | 24269     | 79.0%      |
| 336-383 | 2687      | 99.6%      |

Eliminated so far:
- **Blitter RLE logic.** `tb_rle_long.v` runs a 100-pixel literal run with
  the real parameters captured from MAME (`cmd=2, flags=D581`); all 100
  pixels land, with both planes enabled, and with the VRAM model rewritten
  to match `jtframe_ram_rq`'s "cs must toggle per request" rule. The
  pre-existing RLE tests used 3-pixel runs -- too short to fill the 16-deep
  write FIFO, which is why they never caught anything.
- **The SDRAM write path.** The rev15 on-hardware self-test (write a
  256-word ramp, read it back) reports **0 mismatches**.
- **GROM byte order and the write path generally.** The background is drawn
  by the *raw* path through the same fetcher and the same write path, and it
  matches MAME's artwork.
- **Address-LSB masking.** `jtframe_romrq_bcache` does mask the LSB for
  16-bit slots, but it serves read-only slots; the rw `vram` slot uses
  `jtframe_ram_rq`, which passes the full address.

That confines the fault to the RLE path plus `TRANSPARENT`. rev16 counts
transparent skips per 256 RLE literal pixels (views D/E): ~128 means half
the fetched source bytes read as `0xFF` and are skipped, ~0 means the data
is right and the writes are lost after the blitter.

### Method note

Two hypotheses were stated confidently here and then killed by measurement
-- "letters with gaps" (they are a filled block, and the drawn pens are
exactly MAME's text colour) and "prefetch starvation explains it" (killed
by the x-distribution above). Measure the artifact's *shape* before
theorising about mechanism; an x-histogram would have saved a full cycle.

## Bug A fixed: two pixels per SDRAM access (2026-08-13)

The prefetch budget is fixed by arithmetic: 384 words per line, a line is
508 x 6 = 3048 clk, so 7.9 clk per word. **Buffering cannot fix this** --
more line buffers absorb variance, but the average demand is 384 words per
line no matter how many there are. The per-access cost had to come down.

Two changes, in order of how much they bought:

1. **32-bit reads (the real fix).** `cfg/mem.yaml` declares a second bus,
   `vramrd`: read-only, `data_width: 32`, `offset: 0` -- aliased onto the
   same 2 MB as `vram`. One access returns a pixel pair, so a line costs 192
   accesses instead of 384 and the budget doubles to 15.9 clk/word. Writes
   still use the 16-bit rw `vram` port. The read slot's cache holds two
   entries and the prefetch sweeps linearly, so coherence with blitter
   writes is a non-issue: an address is long evicted before the next frame
   reads it. `sftm_vram` unpacks each pair over two cycles (`A_PFWR`) and
   discards the low half of the first pair when `line_base` is odd.

2. **`settle` 2 -> 1.** `jtframe_ram_rq` assigns `data_ok <= 0` on the same
   cycle it sees the `cs` rising edge, so `ok` is guaranteed low from the
   second cycle; waiting a third was a wasted clock.

Latency at which the whole 384-pixel line is still served:

| version                | holds to | detail                        |
|------------------------|----------|-------------------------------|
| before                 | 3 clk    | 380/384 at 3, 179 at 12       |
| `settle` fix only      | 3 clk    | 384/384 at 3, 190 at 12       |
| with 32-bit reads      | 7 clk    | 384/384 to 7, 380 at 9, 304 at 13 |

### A_GAP is not redundant -- do not remove it again

The first attempt also deleted `A_GAP`, reasoning that `A_IDLE` already
provides the one `cs`-low cycle the slot needs. That is true but beside the
point: `wf_pop` and `vr_ack` are **registered**, so the write-FIFO pop and
the read requester's index advance only take effect the cycle *after*
`A_WAIT` completes. `A_GAP` was absorbing that latency. Without it `A_IDLE`
re-issued the stale `wf_head`, producing 1556 SDRAM writes where 456 were
expected, and the VRAM self-test went from 0 mismatches to 15. The reason is
now a comment in the source.

This was caught only because `tb_rle_long` checks the *exact* write count
and the self-test result, not just the final pixels. A test that asserted
"the pixels are right" would have passed -- the blit output was still
correct; it was the self-test and the write count that exposed it.

### Generator note

`jtframe mem` renders a bus `offset` as `<offset>[SDRAMW-2:0]`, so
`offset: 0` emits `0[SDRAMW-2:0]` -- a bit-select on a bare literal, which
Icarus rejects outright. `jtframe mem` also rewrites the wrapper on every
invocation, so a pre-build patch cannot survive. If Quartus also rejects it,
the options are an offset expression that is a bare identifier evaluating to
zero (`PROM_START` is 0 unless `JTFRAME_PROM_START` is defined, but that is
obscure and fragile), or splitting generation from synthesis in the build
flow.

### Bug A on hardware (build 27)

Synthesised clean with the 3-slot bank 3 and the `PROM_START` offset; timing
closed at setup **+2.418 ns**, hold **+0.248 ns**, TNS 0 on every domain.

On the MiSTer the core still runs correctly -- the full palette call chain
completes (view0 = F), the VRAM self-test still reports 0 mismatches, and
screenshots grew from ~62 KB to ~70 KB. So the change is a clean win with no
regression.

Note on evidence: Bug A's *fix* is verified in simulation, which is the only
place the prefetch's per-line completion can be measured precisely. There is
no hardware probe for "words fetched per line", so the hardware run confirms
only that nothing broke. Adding that probe would be the way to confirm the
prefetch now completes all 384 on real SDRAM.

Bug B is unchanged, as expected -- the isolated-pixel fraction is still
97.0-97.5% against MAME's 0.6%. The two really are independent.

## Bug B found and fixed: overlapping SDRAM buses (2026-08-13)

The glyph checkerboard was a **memory map error, not a blitter bug**.

`jtframe_rom_2slots` and `jtframe_ram1_3slots` both default `SLOTn_OFFSET`
to zero, and `cfg/mem.yaml` declared **no offsets at all**. Every bus in a
bank therefore started at word 0, and the ones sharing a bank overlapped:

| bank | buses | result |
|------|-------|--------|
| 0 | `main` @0, `snd` @0 | the 6809 was fetching the 68020's program ROM |
| 3 | `vram` @0, `grm3` @0 | the blitter overwrote the glyph ROM in place; `grm3` reads returned framebuffer pixels |

### What finally exposed it

A MAME register tap on the *real* text draws. Those blits carry `bank=2`,
so the GROM address is `0x207DE86` -- above `0x2000000`, which means the
glyph data comes from **`grm3`**, not from `grom` in bank 2 where the
background lives. That is precisely the asymmetry the symptom showed all
along: the background is correct because `grom` is the only bus in bank 2,
so its zero offset happens to be right.

Everything else then falls out:
- glyph pixels carried valid palette pens because they *were* framebuffer
  pixels, re-read as RLE data;
- the VRAM self-test passed because it only ever checked self-consistency;
- simulation never reproduced it because every bench ties `grm3_ok` high and
  `grm3_data` to zero, and bank offsets are not modelled in simulation at
  all.

### The fix

`grm3` keeps offset 0 -- that is where the ROM download writes it. VRAM
moves above it instead. `slot0_offset` is hardwired to zero in the generated
wrapper and this generator cannot express a non-zero offset, so the bias
lives in our own HDL and the buses are widened to make room:

| bus | addr_width | bias |
|-----|-----------|------|
| `vram` / `vramrd` | 21 -> 22 (4 MB) | `VRAM_ORG` = `0x40000` words (512 KB, clear of grm3) |
| `snd` | 18 -> 21 (2 MB) | `SND_ORG` = `0x100000` bytes (clear of maindata) |

The ROM download layout is unchanged -- same `JTFRAME_BAn_START` values,
same region sizes -- so **the MRA does not need regenerating**. Only the
slot addressing moved.

The sound overlap is the same class of bug, found while fixing this one. It
means sound has never actually worked on hardware.

### Lesson

Two independent things hid this for many cycles:

1. **The benches stubbed the broken path.** `grm3_ok` tied high and
   `grm3_data` tied to zero meant the glyph source was never simulated even
   once. A stub that never fails is indistinguishable from a path that
   works.
2. **Self-consistent tests prove less than they appear to.** The rev15 VRAM
   self-test wrote and read through the same address computation and
   reported 0 mismatches, which I read as "the memory path is fine". It only
   ever showed that VRAM agreed with itself; it could not see that VRAM was
   sitting on top of somebody else's data.

Widening `rom_addr` also required widening `last_addr` in `sftm_snd`;
leaving it at 18 bits truncated the address-stable comparison and broke
voice playback, which the phase 3 bench caught immediately.

## Bug B FIXED (2026-08-14): two compounding causes

The glyph checkerboard had **two** causes in the SDRAM map, and fixing either
alone was never going to be enough.

### Cause 1: overlapping buses

`jtframe_rom_2slots` and `jtframe_ram1_3slots` default `SLOTn_OFFSET` to
zero and `cfg/mem.yaml` declared no offsets, so buses sharing a bank all
started at word 0:

| bank | buses | effect |
|------|-------|--------|
| 0 | `main` @0, `snd` @0 | the 6809 fetched the 68020's program ROM |
| 3 | `vram` @0, `grm3` @0 | the blitter overwrote the glyph ROM in place |

Fixed by biasing VRAM above grm3 (`VRAM_ORG` = `0x40000` words) and the sound
ROM above maindata (`SND_ORG` = `0x100000` bytes), widening both buses to make
room. This moved the hardware metric from 97% isolated pixels to 51-68% --
real progress, but the glyphs still did not render.

### Cause 2: the rw slot erased the glyph ROM

`jtframe_ram_rq`'s `ERASE` walks `erase_cnt` across the slot's **entire**
address window after reset, writing zeros at `sdram_addr = erase_cnt +
offset`. `SLOT0_ERASE` defaults to 1 and the generated instantiation never
overrides it, so bank 3's `vram` slot (offset 0) zeroed the whole window --
including grm3 at words `0..0x3FFFF` -- immediately after the ROM download
wrote it. A real glyph blit read `0x00` as its first source byte.

This was equally true before the offset fix, when vram's window was 1M words
and still covered grm3. `entrypoint.sh` now patches `SLOT0_ERASE` to 0
alongside the existing GAMMA patch. VRAM needs no erase: the game draws a
full background every frame and never reads VRAM before writing it.

### Result

| build | isolated-pixel fraction |
|-------|------------------------|
| before | 97% |
| overlap fix only | 51-68% |
| **+ erase fix** | **0.0-0.4%** |
| MAME reference | 0.6% |

The high-score table now renders correctly on hardware -- "STREET FIGHTERS"
with its 3D bevel, ranked entries, clean glyphs.

### What actually broke the deadlock

Five probes were built. The first four were hijacking probes that stole the
blitter's shared fetcher and advanced on `fetch_ok`, a cache-hit signal on a
fetcher entangled with the blitter FSM. They failed for four different
reasons -- fired before the ROM download existed, used a guessed delay,
reported a pass id and a result in different views that could never be
paired, and finally read `0xFF` from a bank the blitter demonstrably reads
correctly.

Two things fixed the method:

1. **A control.** Adding a `grom` read on the known-good path immediately
   proved the whole measurement was junk. Without it, the `0x00` readings
   would have been believed.
2. **Passive measurement, verified in simulation first.** The probe that
   worked takes no fetch of its own: it latches the byte as it flows through
   the real RLE path. Proving it in simulation before building -- capturing
   a known `0xE4` header from a modelled grm3 -- is what the previous four
   lacked, and it gave a trustworthy answer on the first hardware run.

---

# SDRAM rule: no bus may be wider than its bank (2026-08-14)

The service-menu font at grom `0x00011A` rendered as garbage while the very
same ROM bytes, fed through the very same decoder, produced a perfect glyph
in simulation (`ver/game/tb_svcfont.v`, 25/25). That mismatch is the whole
diagnosis in miniature: the decoding was right, so the *data* arriving from
SDRAM had to be wrong.

## The defect

`cfg/mem.yaml` declared `grom` as a single 32 MB bus, giving
`grom_addr[24:1]` -- 24 bits of word address. `JTFRAME_SDRAM_LARGE` provides
four **16 MB** banks (`jtframe_emu.sv` sets `SDRAMW=23`, and
`jtframe_mem_ports.inc` sizes `ba*_addr` to `[22:0]` to match), so the bank
carried only 23 of those bits. `jtframe_romrq_bcache.v:114` builds the
address as

```verilog
assign sdram_addr = offset + { {SDRAMW-AW{1'b0}}, addr_req>>(DW==8) };
```

With `AW=24` and `SDRAMW=23` that replication width is **negative**. The
concatenation is then truncated to 23 bits and `grom_addr[24]` is silently
discarded -- no Quartus warning, no lint error, nothing in the build log.

Consequences: every grom address at `0x1000000+` (the `rm1` mask ROMs)
aliased onto `0x0000000+`, and because the downloader walks the stream in
order, `rm1` was written over `rm0`. Every blit that asked for `rm0` got
`rm1`'s bytes.

`macros.def` had also claimed `JTFRAME_SDRAM_LARGE` meant "4 x 32 MB banks".
It means 4 x 16 MB. `JTFRAME_SDRAM_XL` is the 32 MB-bank macro.

## How it was confirmed before anything was changed

A passive probe in `sftm_blit.v` latches the first two source bytes of the
first blit whose `grom_base < 0x10000`, plus that base. It issues no fetch of
its own -- it only observes bytes already flowing through the RLE path -- and
it was proven in simulation first (`tb_svcfont` reads `06 FD @ 0x200`,
matching the ROM) before being trusted on hardware.

Hardware returned `byte0=0x40, byte1=0x40` at a `grom_base` ending `0xCA`.
Checking both candidates against the real ROM: **no** address ending in
`0xCA` anywhere in the low 64 KB of `rm0` holds `40 40`, while `rm1` at
`0x0000CA` holds exactly that, uniquely. That is a positive identification of
the wrong ROM, not merely "the data looks wrong".

## Why JTFRAME_SDRAM_XL is not the fix

XL would give 32 MB banks, but it rejects `JTFRAME_BA*_START` and requires
`header.offset` bank boundaries instead -- and those must land on **MAME
region starts**, because `mra/corerom.go`'s `collect_rom_regions` iterates
MAME's own regions. (That is also why a repeated `grom` entry in
`mame2mra.toml` emits nothing: the loop runs once per MAME region, not once
per toml entry.) Bank 3 has to begin `0x2000000` bytes *inside* the `grom`
region, which no region start can express, so bank 2 would have to swallow
all 32.5 MB of grom -- 512 KB over even an XL bank.

## The fix

`grom_base` is `{grom_bank[1:0], addrhi[7:0], addrlo[15:0]}`, so the VIDEO
transfer bank select *is* address bits `[25:24]`. Split on bit 24 exactly as
`grm3` was already split on bit 25:

| bank | stream offset | contents | size |
|------|---------------|----------|------|
| BA0 | `0x0000000` | `main` + `snd` + `srom` | 3.8 MB |
| BA1 | `0x03D0000` | `grom0` = rm0 | 16 MB, fills the bank |
| BA2 | `0x13D0000` | `grom1` = rm1 | 16 MB, fills the bank |
| BA3 | `0x23D0000` | `grm3` + `vram` + `vramrd` | 1.5 MB |

`srom` moves in beside the CPUs, biased by `SROM_ORG = 0x150000` in
`sftm5506.v`; the offset is even, so the `cur_baddr[0]` byte select is
unaffected. Every bank is now at most 16 MB, which means the core runs on a
64 MB module as well as a 128 MB one.

`ver/game/tb_gromsplit.v` gives each of the three buses its own pen and
asserts that each grom bank reaches its own bus with its own data. It fails
on the old single-bus code.

## The rule

**Check `addr_width` against the bank size for every bus.** A bus that
overflows its bank loses its top address bits in silence. The symptom is
plausible-looking wrong data -- not a crash, not a warning -- and it will be
mistaken for a decoder bug. This is the third bug in this core from SDRAM
address arithmetic, after the missing `SLOTn_OFFSET` overlaps and
`SLOT0_ERASE` wiping `grm3`.

---

# Sound came back with the grom fix (2026-08-14)

Sound was being chased as a separate defect: the 6809 booted and wrote ES5506
registers, the command handshake was healthy, `ACTV` reached 15, but every CR
write carried the STOP bits and no voice ever started. The suspected culprits
were the ES5506 register read path and the interrupt wiring.

Both were wrong, and a MAME comparison is what ruled them out. A Lua tap on
the 6809's ES5506 window (`0x0800-0x083f`) showed the driver does a byte-by-byte
read-modify-write on CR -- read byte i, write byte i, commit on byte 3 -- so
what it writes is a direct function of what the read returns. But the counts
matched ours exactly: 33 CR commits in the first 20 frames, the same per-voice
init loop writing `CR=0x0303`, and the only STOP-clear being the very first
access after reset. The interrupt sources also check out against the driver
config -- IRQ is the input merger `soundlatch1.pending | soundlatch2.pending`
(itech32.cpp:1896-1900) and FIRQ is `irq1_line_assert` at 240 Hz cleared by
`firq_clear_w` (itech32.cpp:1894, 761), both of which sftm_snd.v implements.

The real answer: the driver was doing exactly the right thing and simply never
got past init, because the *game* never got far enough to ask for a sound.
Once the grom bank split let the 68020 reach real gameplay, the sound driver
followed on its own. Measured on the .98 board at the versus screen:

| view | before | after |
|------|--------|-------|
| `anyrun` (a voice ever ran) | 0 | 1 |
| `crn` (CR commits) | 32-33 (init only) | 255, saturated |
| `crp` (page each CR targets) | fixed | cycling 3,4,5,8,9,11,13 |
| `peak` \|snd_left\| top nibble | 0 | 7 |
| `cmdr` (commands read by 6809) | - | 87 and climbing |

`peak = 7` means the mixer is producing near-full-scale output, and `crp`
cycling means the driver is programming many different voices.

The lesson matches the grom bug's: a downstream subsystem that looks broken may
just be starved by an upstream one. Before instrumenting the ES5506 further it
was worth asking whether the game had any reason to make a sound yet.

## ...but the output port still had no driver

Even with the mixer running, the board was silent, because none of that ever
left the game module. `jtframe_mem_ports.inc` gates the audio port on a macro:

    `ifndef JTFRAME_STEREO  output signed [15:0] snd;
    `else                   output signed [15:0] snd_left, snd_right;

JTFRAME_STEREO was not defined, so the game's only audio port was the mono
`snd`, which jtsftm_game.v never drives, and its connections to sftm_snd's
snd_left/snd_right became implicit nets going nowhere. Defining the macro was
the entire fix -- itech32 is genuinely stereo with the channels swapped
(itech32.cpp:1798) and sftm5506.v already applies that swap.

Quartus had been reporting all three facts for many builds:

    Warning (10236): created implicit net for "snd_left"  jtsftm_game.v(224)
    Warning (10236): created implicit net for "snd_right" jtsftm_game.v(225)
    Warning (10034): Output port "snd" at mem_ports.inc(17) has no driver

**Grep every build log for `has no driver` before instrumenting anything.** It
costs seconds and would have skipped the whole ES5506 investigation. Build 53
is clean of snd warnings and audio is confirmed audible on hardware.

---

# The blitter is write-starved, not read-starved (2026-08-14)

With graphics and audio working, the remaining fault is that the game runs far
below speed: sprites flash in and out because they are redrawn every frame and
often do not get drawn, while the background and JTFRAME's own debug text stay
stable because they are drawn once or are independent of the game. The fight
stage background is left truncated at a varying row.

`cpu_wait` stalls the 68020 on COMMAND/TRANSFER while the blitter is busy
(sftm_video.v), so blitter throughput sets the frame rate directly.

## Measurement

Per frame, in units of 65536 clocks (a 384x240 frame is ~800k clk, so ~12
units), published from the frame with the largest busy count:

| quantity | reading |
|----------|---------|
| blitter busy | 13 -- busy the entire frame |
| ...stalled on a GROM read | 0 |
| ...stalled on the VRAM write port | 12 |
| blits started that frame | 0 -- one blit spans many frames |

**The GROM fetcher is not the bottleneck.** The prior hypothesis -- that the
single-outstanding-fetch grom cache was starving the blitter, by analogy with
Bug A -- was wrong, and the measurement killed it before any code was written.

## Cause

`sftm_vram.v` serialises EVERY VRAM access through one single-transaction FSM:

    A_IDLE -> A_WAIT (settle x2 + SDRAM latency) -> A_GAP -> A_IDLE

Two problems compound:

1. **Fixed overhead per access.** Even at zero SDRAM latency an access costs
   ~5 clocks (A_IDLE + 2 settle + A_GAP); with real latency ~13. Nothing is
   pipelined and only one transaction is ever in flight.
2. **The prefetch has absolute priority.** A_IDLE tests `pf_active` first,
   blitter reads second, writes last. At 192 32-bit accesses per line and
   ~13 clk each, the prefetch alone claims roughly 2,500 of a line's 3,048
   clocks, leaving writes the remainder.

The deeper mistake is architectural: `vram` and `vramrd` are already SEPARATE
JTFRAME slots in the same bank, and `jtframe_ram1_3slots` arbitrates between
them. Serialising them behind our own FSM throws that away -- the two could be
in flight at once.

## Fix direction

Stop serialising. Give the write path and the prefetch independent request
logic and let the JTFRAME slot arbiter interleave them, and drop the
settle/gap overhead by tracking outstanding requests instead of idling between
them. That is the same lesson as Bug A one level up: it is not the width of a
single access that hurts, it is refusing to have more than one in flight.

## After the rework: the write path is at its architectural limit

Build 56 replaced the saturating stall flag with rate meters. Measured on the
.98 board, per frame:

| quantity | reading |
|----------|---------|
| blitter busy | 13 -- still the whole frame |
| GROM words fetched | 0 -- fewer than 8192, never the constraint |
| VRAM writes issued | 8-12 units of 8192, i.e. **65k-98k writes/frame** |

A frame is 800k clk, so that is 8-12 clk per write: the arbiter is running at
close to the cost of a single transaction, which is what the rework was for.
The blitter is nonetheless busy the entire frame, because a 384x240 background
alone needs 92,160 writes -- about one full frame of write bandwidth before a
single sprite is drawn. Hence "faster, but not full speed".

The GROM reading confirms the fetcher was never worth rewriting.

### Where the remaining factor of two has to come from

Not from the arbiter: at 8-12 clk per transaction there is little left to
recover (dropping the one-cycle `settle` buys ~10%). It has to come from
issuing FEWER transactions. The blitter writes pixels sequentially along a
row, so adjacent pixels are adjacent VRAM words and can be coalesced into
32-bit writes -- halving the transaction count, exactly the trick the scanline
prefetch already uses on the read side via the `vramrd` alias.

That means widening the `vram` bus to 32 bits with byte enables and having the
write FIFO merge adjacent pixel pairs, with care where transparency skips a
pixel and where the blitter reads back what it has just written.

### The plain rw slot cannot do 32 bits (and says nothing about it)

The obvious fix for the write bottleneck -- widen `vram` to 32 bits and
coalesce adjacent pixels, the way `vramrd` already halves the prefetch's
accesses -- is not available. Setting `data_width: 32` with `rw: true` on a
plain bank bus was tried and `jtframe mem` emitted a 16-bit port anyway:

    wire [21:1] vram_addr;   wire [15:0] vram_din;   wire [1:0] vram_dsn;

No error, no warning; the request is silently dropped. The reason is in
jtframe_ram_rq.v, the module behind an rw slot: it takes read data as
`din[0+:DW]` from the 16-bit `data_read` bus and special-cases only DW==8, so
16 bits is its ceiling. Only the read-only `jtframe_romrq` assembles 32-bit
words, which is why `vramrd` can be 32 bits and `vram` cannot.

That is the same failure mode as the grom bank-width bug: a memory attribute
quietly ignored rather than rejected. Check the GENERATED port widths in
cores/sftm/mister/jtsftm_game_sdram.v after any mem.yaml change; do not assume
the yaml was honoured.

Two routes remain for the remaining factor of two:

* **cache-lanes** (`sdram.cache-lanes` in mem.yaml, JTFRAME_SDRAM_CACHE).
  This is JTFRAME's supported 32-bit rw path -- a block cache in front of
  SDRAM, which coalesces writes naturally. It is the right mechanism and a
  substantial rework: new mem.yaml section, a different port set, and
  sftm_vram talking to a cache rather than a raw slot.
* **FASTWR** on the rw slot, a jtframe_ram_rq parameter that acknowledges a
  write as soon as the slot mux accepts it, allowing one more operation in
  flight. Small and contained, but neither jtframe_ram1_3slots nor the mem.yaml
  schema exposes it, so it needs a jtframe patch (docker/jtframe-patches/
  already exists for this purpose).

### The background streaks: one wrong pen, not corrupted image data

Characterised from a digital capture of a VEGA/BALROG fight (build 56):

* every streak pixel is **exactly (0,255,0)**, pure saturated green -- 2496 of
  them, one single colour. These are digitised photographic backgrounds; RGB555
  (0,31,0) is not in the artwork. The pixels therefore carry a WRONG PEN INDEX
  that lands on one palette slot; the image data itself is not being mangled.
* the runs are **not aligned to 32-bit pairs**: starts split evenly between
  even and odd x (375 vs 354), lengths mostly 1-3 with mixed parity. That rules
  out a write-pairing or byte-enable alignment fault.
* sprites, HUD and all text render perfectly, and tb_svcfont decodes real ROM
  bytes correctly, so neither the RLE decoder nor the small-blit path is at
  fault.

Also measured: the background is drawn in about three horizontal strips. Across
twelve fight frames the filled height clusters at exactly rows 58, 150 and 240,
never in between, so partial frames are whole strips missing rather than a blit
stopping at an arbitrary point.

Next step is to identify which pen maps to (0,255,0) and where it comes from --
an unwritten palette entry, a pen index that escapes its expected range, or a
readback the shiftreg/c3 path uses. The colour being a single exact value makes
this findable: latch the pen whenever the blitter writes one that will resolve
to that palette slot, and capture the source address and blit state with it.

### Resolved: the streaks ARE the throughput problem

The "one wrong pen" reading was wrong, and so was treating the corruption as a
separate defect. Two measurements settled it.

**The pen probe (build 59)** reported pen 0xB8 / colour latch 0x03 with
`gmulti` SET -- several distinct pens resolve to pure green -- and `palhit`
SET, so the CPU does write that palette entry. Both hypotheses died: it is
neither a single bad index nor an uninitialised palette slot. Pure green is
simply the most conspicuous subset of arbitrary wrong pixels, which is why a
photograph of another stage showed orange streaks instead.

**Frame-to-frame comparison** then identified what the wrong pixels are. Across
eight consecutive corrupted fight frames the green-pixel sets overlap by only
0-6%: essentially every corrupt pixel is new each frame, and pixels green in
one frame come back as ordinary dark scene colours in the next. They are not
systematically wrong, they are TRANSIENTLY wrong -- stale content in whichever
region the blitter failed to redraw that frame.

An earlier build-54 measurement found the opposite, 99% overlap. That was
before the arbiter rework, when writes ran at ~2227 clk each and the same
partial state persisted for many frames. At ~12 clk the corruption sweeps
instead of sitting still. Same mechanism, different speed -- and a good warning
that a measurement's meaning can depend on the very defect being fixed.

So the corruption and the frame rate are ONE problem: the blitter cannot finish
a frame's drawing. At ~65k writes/frame against 92,160 for a background alone,
it never will. Fixing write throughput fixes both, and no separate corruption
hunt is needed.

The validated route is cache-lanes (see above): jtframe mem accepts the layout
and the vram lane gives 32-bit data, 32-bit word addressing, four byte enables
and a flush interface. Constraints found: banks and cache-lanes are mutually
exclusive so all seven buses convert, offsets must be hex strings or parameter
names, and rw lanes must be among the first four.

### jtframe bug: cache-lane offsets are emitted as C hex

`jtframe mem` validates `sdram.cache-lanes[].at.offset` as an `0x...` string and
then interpolates that STRING verbatim into the generated wrapper
(`hdl/inc/game_sdram.v:411`), producing

    .OFFSET0  ( 0x80000 ),

which is not Verilog -- iverilog and Quartus both reject it. Every cache lane
with an offset yields an uncompilable file, `0x0` included. Its own unit tests
only cover `( 0 )` and a parameter name, so the hex path was never exercised.
Rewriting the YAML is no escape: the validator DEMANDS the `0x` form while
Verilog demands `'h`, and the two never overlap.

Fixed by patching `src/jtframe/mem/mem.go` to normalise the string to Verilog
hex AFTER `resolve_cache_lane_offset_words()` has consumed the original for its
range check, so only the emitted text changes and parameter-name offsets pass
through untouched. The patch lives in
`docker/jtframe-patches/patch_mem_offsets.py` and is applied by
`docker/entrypoint.sh`, which also deletes the compiled jtframe binary so it
rebuilds. Verified: offsets now emit as `.OFFSET0 ( 'h40000 )`.

Note the entrypoint is baked INTO the sftm-quartus image, so editing
`docker/entrypoint.sh` alone does not affect a running container -- the volume
must be patched directly (or the image rebuilt) for the change to take effect
now.

**`at.offset` is in 16-bit WORDS, not bytes** (`mem.go` computes
`offset_bytes := offset_words << 1`). Byte offsets are twice the YAML value.

### cache-lanes: the CPU does not boot (builds 60/61)

Both cache-lane builds render a black screen with only JTFRAME's own overlay,
which never touches VRAM or the game's ROM lanes.

Diagnosis, from the overlay alone. `view = diag_cnt[28:25]`, 0.7 s per view and
11 s for a full cycle, yet across 20 screenshots spread over 20 REAL seconds --
nearly two cycles -- the counter never got past view 4. So `diag_cnt` is being
reset about every 3.5 s: the core is in a WATCHDOG REBOOT LOOP. The watchdog
only fires when the 68020 fails to kick it, so the CPU is not running.

That clears sftm_vram: the fault is in the ROM lanes, `main` above all, not in
the 32-bit VRAM rewrite. Note the earlier capture that appeared to show the
view counter stuck was a measurement artifact -- the /dev/MiSTer_cmd FIFO
batches queued screenshot requests into a ~3 s burst, so a loop of 14 requests
samples only ~4 consecutive views however long the shell sleeps between them.
Spread captures across real time with one request per ssh call.

Two bugs found and fixed on the way, both real:
  * asserting vram_rd alongside vram_we made the lane service a READ and drop
    the write (jtframe_cache_mux: `wire req0 = rd0 | wr0`, separate strobes);
  * jtframe emits cache-lane offsets as C hex, which is not Verilog.

Still unresolved for the ROM lanes:
  * whether the download lands where the lanes expect (BA*_START placement
    versus each lane's `at: {bank, offset}`);
  * whether the caches can hold pre-download data, i.e. what invalidates them
    when the ROM arrives;
  * the exact `ok` timing on a hit versus a fill -- sftm_main's read handshake
    was written for jtframe_romrq's "hold cs, settle, sample ok" convention and
    a cache lane may not honour it.

The conversion is committed but NOT deployed. Build 59 (banks) is the working
core on hardware.

### The main lane is fine -- the CPU runs, something downstream hangs

Build 62 instrumented rom_cs/rom_ok/rom_data on the main cache lane. Result:

    cs_ever=1  ok_ever=1  got_first=1  data_nonzero=1

with the completed-fetch counter climbing rapidly across samples. The 68020
requests, the lane answers, fetches complete, and the data is real. **The main
ROM lane works under cache-lanes.**

That RETRACTS the previous entry's conclusion. "The CPU is not running" was
inferred from the watchdog reboot loop alone, and the inference was wrong: the
CPU runs and executes from ROM, but still fails to kick the watchdog, so it
hangs somewhere downstream of instruction fetch. Under banks (build 59) the
same code runs, so cache-lanes broke one of the OTHER lanes -- snd, srom, grm3,
grom0/1 -- or the VRAM path, not main.

Instrumentation problem to fix first: `view = diag_cnt[28:25]` gives 0.7 s per
view and 11 s per cycle, but the watchdog resets diag_cnt every ~3 s, so views
5-F can NEVER be reached while the core is looping. Only views 0-4 are legible.
Speeding the counter to roughly diag_cnt[24:21] (~0.04 s per view, ~0.7 s per
cycle) fits a whole cycle inside one watchdog period and makes every view
readable. Do that before adding more probes, or they cannot be read.

### FASTWR: ~2x the write rate, but it breaks pixel correctness

Build 63 enabled FASTWR on the bank-3 rw slot. Measured on hardware:

| | build 59 | build 63 |
|---|---|---|
| VRAM writes/frame | 65,536 | >=122,880 (counter saturated) |
| clk per write | 12.2 | <=6.5 |
| frames per background | 1.41 | 0.75 -- fits in one frame |

The speed is real and better than predicted: the model said 1.3x because it
assumed the port stays occupied for the whole burst after each write, and the
controller evidently pipelines better than that. Every frame now renders full
height (22/22, versus partial frames before) and the green streaks are gone.

But the picture is covered in dense per-pixel speckle, and the HUD TEXT is
corrupted too -- small blits were always perfect before, so this is a global
correctness failure, not a throughput artifact.

The cause is the risk that was reasoned away when the patch went in: blitter
reads wait for the write FIFO to be empty, but with FASTWR the ack arrives when
the slot mux grants the write, so the FIFO drains while writes are still in
flight. The shiftreg and cmd-3 read-modify-write paths then read stale pixels.
The argument that "the slot serialises them behind the in-flight write" was
wrong, and tb_vramthru did not catch it because its ordering check writes ONE
word and reads it back -- with a single write in flight the early ack still
lands before the read is issued. A real test needs a burst of writes followed
immediately by a read of an early address in that burst.

Fix direction: reads must wait for writes to be COMMITTED rather than merely
issued. With an early ack that is no longer observable from the FIFO, so
sftm_vram would need to count outstanding writes and hold reads until the count
reaches zero -- which reclaims some, but not all, of the gain.

Build 59 (no FASTWR) remains the deployed core.

### Why FASTWR cannot be used here

The mechanism, from jtframe_ram_rq:

    if( FASTWR && !req_rnw ) data_ok <= 1;

`req_rnw` is set when a request is ISSUED and persists until the next issue, so
on any slot grant where the LAST ISSUED request was a write, data_ok is forced
high regardless of what the current transaction is. A read that follows a write
therefore gets a spurious immediate ack carrying stale `dout`.

FASTWR is built for a CPU write-behind that only ever writes. The blitter
interleaves reads and writes on one slot -- shiftreg and cmd-3 read back pens
they have just written -- so nearly every read-modify-write blit is corrupted.
That is the dense per-pixel speckle in build 63, HUD text included.

The speed was real: >=122,880 writes/frame against 65,536, <=6.5 clk/write
against 12.2, and a background fitting inside one frame instead of 1.41. It is
simply not correct.

tb_vramthru did NOT catch this, and the reason is worth recording. Its ordering
check was strengthened to write a BURST and read every word back, and the model
was extended so an early-acked write commits LAT cycles later -- both real
improvements, kept. But the bench still passed, because the model makes a read
wait for port occupancy, which incidentally enforces the ordering the hardware
does not. The bench models a hazard of the wrong SHAPE: the fault is not "the
write has not landed yet", it is "the ack does not belong to this transaction".
Reproducing that needs the ack condition itself modelled, keyed on the previous
request's direction rather than the current one.

### No lane is stuck -- the game hangs before its first blit

Build 65 probed every cache lane for {ever requested, ever acked, stuck}:

| lane  | req | ack | stuck | verdict |
|-------|-----|-----|-------|---------|
| main  |  1  |  1  |   -   | healthy, data non-zero |
| snd   |  1  |  1  |   0   | healthy |
| srom  |  0  |  0  |   0   | never requested |
| grm3  |  0  |  0  |   0   | never requested |
| grom0 |  0  |  0  |   0   | never requested |
| grom1 |  0  |  0  |   0   | never requested |

Nothing is stuck, so the hypothesis this probe was built for -- "one of the
other lanes stopped answering" -- is wrong. The 68020 runs, the 6809 runs, and
the blitter's three graphics lanes are never asked for anything, i.e. the game
never issues a single blit. It hangs before drawing at all.

That leaves the obvious gap in the earlier measurement. Build 62 reported
`data_nonzero=1` for the main lane, and "non-zero" was taken as "working" --
but non-zero is not CORRECT. The first fetch must return the reset SP longword
0x00008000 (maindata begins 00 00 80 00 00 80 04 00), and that value was
captured in m_first but never actually read: the view counter was still at
diag_cnt[28:25] then, so views 4-7 were unreachable inside a watchdog period,
and build 65 reassigned those views to the lane probes.

Next measurement: put m_first back on views 4-7, now readable thanks to the
faster counter, and compare against 0x8000/0x0000. A main lane that answers
promptly with the WRONG data explains everything seen so far -- the CPU
executes garbage, never reaches the drawing code, and the watchdog reboots it,
while every lane looks electrically healthy.

### Found it: the main cache lane is off by one 16-bit word

Build 66 read the WHOLE first longword the main lane returns:

    got      0x80000080
    expected 0x00008000     (maindata begins 00 00 80 00, the reset SP)

Read as 16-bit words the ROM starts w0=0x0000, w1=0x8000, w2=0x0080,
w3=0x0400. The lane returned {w1, w2} where address 0 must give {w0, w1}: real
ROM content, shifted by exactly ONE 16-BIT WORD.

That explains everything the earlier probes found and could not explain. The
lane answers promptly (build 62: cs, ok, a completed fetch, non-zero data), so
it looks healthy; but the 68020 gets a garbage reset vector, executes nonsense,
never reaches the drawing code -- hence build 65 finding grom0/grom1/grm3 never
requested at all -- and the watchdog reboots it every ~3 s.

The lesson from the false trail: build 62 checked only `data_nonzero` and that
was read as "the main lane works", which became a retraction of an earlier
conclusion and sent the next build chasing the other lanes. Non-zero is not
correct. When ground truth is available -- and it was, in the ROM image -- the
probe should compare against it rather than against zero.

Fix direction: main is 32 bits with main_addr[19:2] and at.offset "0x0", so the
suspect is how a 32-bit cache lane converts its word address into the 16-bit
SDRAM addresses it assembles the pair from. Confirm by reading the SECOND
fetch too: if it returns {w3, w4} the shift is uniform and the address
conversion is off by one, rather than a one-off at address zero.

## Cache-lanes conversion: what unblocked it (build 68/69, 2026-08-16)

The conversion from SDRAM banks to cache-lanes was stuck for builds 60-66 --
black screen or an init loop. One parameter was responsible.

A DW=32 cache lane fills from 16-bit SDRAM and must choose which half of the
32-bit word each incoming SDRAM word lands in. `jtframe_cache_ctrl.sv` keys
that on ENDIAN in three matching places -- :368 `fill_write_data`, :384
`fill_write_mask`, :401 `wb_ext_word`:

    if( DW == 32 && ENDIAN ) pos = half_idx[0] ? 0 : 1;
    else                     pos = half_idx % HALF_PER_WORD;

Default ENDIAN=0 puts SDRAM word 0 in `dout[15:0]`, so the big-endian 68EC020
reads every longword with its halves swapped. `sdram.big_endian: true` in
cfg/mem.yaml fixes it. jtframe emits it (game_sdram.v:403) as
`ENDIANn ( big_endian && data_width==32 ? 1 : 0 )`, so it reaches EXACTLY the
two 32-bit lanes, main and vram, and leaves grom/srom/grm3 packed as the
working banks build had them. Verify in the generated
`cores/sftm/mister/jtsftm_game_sdram.v`: ENDIAN0 and ENDIAN2 must read 1.

vram needs no matching change. Fill data, fill byte-enables and writeback all
derive from the same `pos`, so the permutation cancels on a lane that only
sftm_vram reads or writes.

### Two wrong turns, both cheap to repeat

1. **`jtframe_romrq_bcache` is NOT the cache-lanes module.** It is the
   banks/slots path. Its `addr` is a 16-bit WORD address, which is why
   `jtframe_rom_2slots` is wired `.slot0_addr({main_addr,1'b0})`.
   `jtframe_cache` -- the cache-lanes module -- instead takes
   `addr [AW-1:AW0]` with `AW0 = DW==32 ? 2 : DW==16 ? 1 : 0`, i.e. a longword
   index, exactly the raw `main_addr[19:2]` the generator wires. The generator
   is right; the two modules just take different units. `ver/game/tb_bcache32.v`
   pins the slot-path convention down so the confusion does not repeat.

2. **`ENDIAN` in `jtframe_dual_ram32` is simulation-only** -- there it feeds
   only `SIMFILE_BYTE`, which byte of a sim hex file seeds each byte-RAM, and
   the data path is straight through (`data0[7:0]`->u_byte0, `we0[0]`,
   `q0[7:0]`) for both values. Reading that file alone says "big_endian cannot
   matter on hardware", which is wrong: the cache CONTROLLER is where 32-bit
   word order is decided. Check the consumer, not the first file the parameter
   appears in.

### Result on hardware

Build 68 boots to the real service/boot screen. Build 69 runs attract mode with
correctly rendered digitised portraits (Sagat vs Chun Li), the STREETFIGHTER
and BISON'S LAIR panels, and animation between frames.

Throughput, read from `dbg_bwr` (VRAM writes in the busiest frame, units of
8192, sftm_video.v:189):

    banks arbiter, build 56   0x8  ~65,536 writes/frame
    cache-lanes,   build 69   0xC  ~98,304 writes/frame
    one full background            92,160 writes

So the peak frame now clears a full background, which the banks arbiter never
did. Screenshots still catch horizontal partial-redraw bands, but they sit at
different heights each frame and the characters animate between them, i.e.
they are mid-frame captures rather than static corruption. Whether any visible
tearing remains during play needs a human at the machine -- controller input
cannot be injected over ssh.

## Where the blitter actually waits (build 73, 2026-08-16)

First self-consistent throughput reading. Views repeat identically across
cycles and satisfy wait+stw <= busy and wr <= busy, which none of builds 69-72
did.

    writes            0xD   106,496  (units of 8192)
    busy              0xF   SATURATED, >=983,040 clk
    GROM fetch stall  0x3   196,608 clk
    write-FIFO stall  0x0   <65,536 clk
    blits started     0x2

**The GROM fetch stall is at least 3x the write-FIFO stall.** Both counters run
over the same window, so that ratio holds even though the window length is in
doubt. The bottleneck is the blitter's source fetch, NOT the VRAM write path
that the whole cache-lanes conversion was aimed at.

CAVEAT: busy saturating is itself a defect. bc_busy resets on frame_end and a
frame is 508*286*6 = 871,728 clk, so it cannot exceed 0xD in one frame.
Reading 0xF means frame_end -- the falling edge of LVBL -- is being missed and
two frames are accumulating. Every ABSOLUTE figure above is therefore over an
ambiguous window; if it is two frames then writes are ~53k per frame, well
under the 92,160 one background needs, which alone would explain a partial
redraw. Fix frame_end before quoting absolutes.

The per-lane liveness views are not trustworthy: grom0 reports req_ever=0 while
sprites are visibly rendering. They predate this work and were never validated.

### How five builds produced no valid measurement

Worth recording, because each fault looked like a result:

1. **Frozen high-water latch.** st_* only latched when bc_busy beat bc_best, a
   maximum that never decayed, so the meters froze on one outlier frame and
   reported it forever. The frame they froze on had busy >= 983,040 clk -- more
   than a whole frame -- i.e. it had already missed a frame_end.
2. **Half the stall uninstrumented.** sftm_blit has two stalls, st_waiting
   (GROM, :302) and st_stallw (write FIFO, :359); only the first was counted,
   so the write port was invisible and "20% stalled" meant 20% on GROM alone.
3. **Cross-frame nibble pairing.** Widening the meters to 8 bits meant showing
   each across two views, and consecutive views are sampled from different
   snapshots -- so the halves never described the same frame. This produced
   bwr > bbusy, a write count larger than the busy time containing it, which
   sftm_blit.v:359 makes impossible.
4. **Fixing the wrong end of 3.** A snapshot register made each single view
   cycle self-consistent, but a screenshot burst spans several cycles, so the
   pairing was still cross-snapshot.
5. **The widening was the bug.** The original 4-bit meters carried one complete
   number per view and could not be mispaired. Reverting to single nibbles is
   what finally produced a consistent reading.

Rule for this core: one view, one self-contained number. Never split a value
across views -- the display cycles far slower than the data changes.

## The debug overlay silently stops showing the game's byte (2026-08-16)

**START + a fire button switches the on-screen debug byte away from the core's
`debug_view` to JTFRAME's own system counters, and nothing indicates it.**

    jtframe_debug_keys.v:51   wire key_toggle = ctrl & shift;
    jtframe_debug_keys.v:52   wire alt_toggle = !start_n && joy_n[1:0]!=3;
    jtframe_debug_viewmux.v   case(sel) default: mux <= debug_view;
                                        SYS_INFO:    mux <= sys_info;
                                        TARGET_INFO: mux <= target_info;

With sel != 0 the overlay shows `jtframe_sys_info` -- a frame counter and
similar state -- which increments steadily. Decoded as "4-bit view tag + 4-bit
payload" it looks exactly like a healthy auto-cycling debug panel: the high
nibble marches 0..F in order and the low nibble varies plausibly. It is
completely convincing and completely fake.

This invalidated five builds of throughput work. Every impossible reading came
from it: busy longer than the frame that resets it, a frame period shorter than
the busy it brackets, a write count larger than the busy containing it. Each
counter was re-verified in simulation and was correct every time -- the RTL was
never the problem.

Rules that follow:

1. **Put a known constant on at least one view, permanently.** Views 0 and F
   carried 5 and A in build 75; they read back 0x0E and 0xF5, which is what
   exposed this. Without a constant there is no way to tell a real panel from
   a counter that happens to look like one.
2. **plain START is safe; START+fire is not.** Clearing the game's
   "PRESS START 1 TO CONTINUE" screen does not toggle the view. Pressing start
   with a button held during play does.
3. `sel` resets to 0 on core load, so a reload always restores the game view.
4. Ctrl+Shift on an attached keyboard does the same thing.

Anything measured through this overlay while the user was holding a controller
should be treated as unverified until re-read with the constant confirming
sel==0.

## The debug overlay does not reflect the deployed core (2026-08-16, unresolved)

**Do not trust any measurement taken through `debug_view` until this is
resolved.** Quantitative proof, not inference:

MiSTer caps screenshots at exactly 1 per second, so the overlay byte's rate is
directly measurable. If the byte is `{4-bit view, 4-bit payload}` it advances 16
counts per view step, so the rate identifies the view period:

    diag_cnt[28:25]  0.699 s/view -> 22.9 /s   (value BEFORE this session)
    diag_cnt[27:24]  0.349 s/view -> 45.8 /s   (build 78 source)
    diag_cnt[26:23]  0.175 s/view -> 91.4 /s   (build 79 source)

    build 78 measured 21.4 /s
    build 79 measured 22.8 /s   <- period halved in source, rate UNCHANGED

Both match the pre-session value. Build 79 deliberately halved the period
precisely so a rate change would be visible without decoding any payload; it
did not move.

Then the control: `sftm_b59_working.rbf` -- the BANKS build, a different memory
architecture with a different debug view map entirely -- was loaded and produced
the same values at the same rate. Two radically different bitstreams, identical
overlay behaviour.

Everything else verifies clean, which is what makes this so expensive:
  - source md5 identical on the Mac and gamingpc after rsync
  - `files.qip` lists exactly one `sftm_main.v`, no duplicate `module sftm_main`
    anywhere in the repo or the jtframe volume
  - Quartus provably read the CURRENT file: its warning line numbers
    (`st_nv14` at 351, `dbg_fbe` at 676) match the current source exactly
  - db/incremental_db/output_files wiped; a fully clean rebuild reproduced a
    bit-identical .rbf
  - fresh .rbf md5 differs per build and matches byte-for-byte on the device
  - the viewmux pin verified applied in the volume after the build

Three constants were placed on views 0, 7 and F (5, 3, A). None ever appeared,
in any build. A hardcoded `4'hA` reading back as `0` cannot happen if the
running logic matches the source -- that single fact is the anchor, and it holds
without any timing assumption.

Consequences:
  - Every throughput figure in this session is void. So is build 56's
    "~65k writes/frame", which is the number that justified the whole
    cache-lanes conversion. The conversion still produced a real, independently
    visible win (the core boots and renders attract mode where the banks build's
    grom was broken) -- but its stated premise was never measured.
  - Changes to GENERATED files do reach hardware: cfg/mem.yaml -> big_endian ->
    the core booting is verified end to end. Only hand-written sftm_main.v
    changes appear not to.

Next step is SignalTap over the USB Blaster: it reads the fabric directly and
bypasses debug_view, the viewmux, the screenshot path and the glyph decoding all
at once. Two .stp files from the August bring-up are in cores/sftm/mister/.
Probe `view`, `st_dout`, `blit_busy`, `st_wpop` and `frame_end` -- `view`'s
toggle rate alone settles whether the fabric is running current logic.

## ROOT CAUSE: scp without sync loaded the PREVIOUS build's bitstream (2026-08-18)

**Always `sync` on the MiSTer after copying an .rbf, before `load_core`.**

`scp` leaves the file in the page cache. `md5sum` on the device then reads it
back from that same cache and reports the NEW checksum -- so every verification
passes -- while MiSTer's core loader gets stale content off the card and
configures the FPGA with the PREVIOUS build. The symptom is a core that is
always exactly one build behind, with a deploy that verifies perfectly.

Proved with the USB Blaster, which reads the fabric directly:

    build 81 rbf deployed + loaded (md5 verified)   -> probe width 32  (build 80)
    build 81 .sof programmed over JTAG              -> probe width 64  (build 81)
    build 81 rbf + `sync` + drop_caches + reload    -> probe width 64  (build 81)

This is the explanation for the whole 2026-08-16/18 measurement disaster. Three
constants placed on debug views 0, 7 and F never appeared, across five builds,
because the FPGA was never running the build that contained them. Every
"impossible" reading -- busy longer than the frame that resets it, a frame
period shorter than the busy it brackets, writes exceeding busy -- was a real
reading of an OLDER build's view map, decoded against the CURRENT build's
layout. The RTL was correct throughout, which is why every simulation check
passed.

Deploy sequence that is actually safe:

    scp sftm.rbf root@<mister>:/media/fat/_Arcade/cores/sftm.rbf
    ssh root@<mister> 'sync'                    # <-- the missing step
    ssh root@<mister> 'load_core menu.rbf ...'  # bounce, then load the MRA

and verify the running bitstream over JTAG rather than by md5 of the file:

    get_insystem_source_probe_instance_info   # {index source_w probe_w id}

### Why the earlier "definitive" staleness proof was still wrong

An earlier pass measured the overlay byte's advance rate (21.4/s and 22.8/s
against a predicted 45.8 and 91.4) and concluded the fabric was stale. The
conclusion was right by accident; the reasoning was not. The overlay was ALSO
not showing debug_view, so that rate was never evidence of anything. Two
independent faults were producing one symptom, and each was capable of
explaining it alone -- which is why single-cause theories kept collapsing.

The only test that ever discriminated was a hardcoded constant read back
through the channel under test. Keep one on a debug view permanently.

## CORRECTION (2026-08-20): the sync theory was wrong, and so was the board

Two earlier entries in this file are WRONG and are retracted here.

**1. "scp without sync loaded the previous build" is NOT the cause.** `sync` and
`echo 3 > /proc/sys/vm/drop_caches` were both applied and the fabric still did
not match the deployed rbf. The evidence that produced that theory (probe width
32 -> 64 after a sync) is better explained by the JTAG programming performed
moments earlier still being resident in the fabric.

**2. The USB Blaster is on 10.10.10.74, not .98.** Proved by polling the JTAG
chain across a cold boot: the chain went GONE and returned exactly in step with
.74 losing power. A warm `reboot` does NOT disambiguate -- it restarts Linux
while the FPGA stays powered, so its TAP stays alive either way.

This mix-up invalidates a whole class of conclusions from 2026-08-16/18: JTAG
reads and .sof programming went to **.74** while rbf deploys, screenshots and
reasoning were about **.98**. Two machines were being cross-referenced as one.
In particular "the blitter is exactly idle while the picture animates, so the
fault is upstream of the blitter" is NOT a finding -- the idle blitter was .74
with no ROM, and the animating picture was .98.

### What IS established, on one board, with a validated channel

Read directly from .74's fabric over JTAG, signatures checked on every sample:

  - `st_main` is CORRECT. The constants placed on debug views 0, 7 and F read
    back as 5, 3 and A.
  - frame period = 871,727 clk, i.e. exactly 508*286*6 minus the frame_end
    clock. The video timing and `frame_end` are right.
  - With the game held in reset (see below): VRAM read strobes 354,252/frame,
    every CPU video-register write 0.

  - **The on-screen overlay does NOT display `debug_view`.** Same board, same
    build: ISSP shows view 0 = 05, while the overlay shows the default arm.
    Reproduced on both .74 and .98. **Every screenshot-derived measurement in
    this project is therefore void**, including build 56's "~65k writes/frame"
    that motivated the cache-lanes conversion.

### The blocker

  HPS-loaded .rbf  -> the game runs, but NO ISSP hub is reachable over JTAG
  JTAG-loaded .sof -> ISSP works, but MiSTer's ROM download never runs and
                     JTFRAME holds the game in reset, so the CPU does nothing

Both were verified on .74 after a cold boot. So there is currently no way to
observe a RUNNING game through a trustworthy channel. Resolving that is the
next task, and everything else is blocked behind it. Options, cheapest first:

  1. Find why the SLD hub is unreachable when the HPS configures the FPGA.
     `jtagconfig -n` lists the chain but no SLD nodes; after `quartus_pgm` of
     the same build's .sof the nodes appear immediately.
  2. Re-trigger MiSTer's ROM download after a JTAG configure, without
     reconfiguring the FPGA from the rbf.
  3. Preload the ROM over JTAG.

### Operational notes

  - The cable name changes with the USB port (`DE-SoC [3-2]` -> `[3-1]`).
    Discover it, never hardcode it: docker/prog_sof.sh does this.
  - JTAG-programming while Linux is running can hang the HPS. It did on .98,
    which then would not boot. Budget a cold boot after each programming.

## Why the SLD hub is invisible with an HPS-loaded rbf (2026-08-20)

**Answer: the JTAG-to-fabric SLD hub is not activated when MiSTer's HPS
configures the FPGA. It is a configuration-path property, not anything in our
RTL or build.** Ruled out, each by direct test:

  - **Not a file or build mismatch.** cores/sftm/mister/output_files/sftm.rbf
    and sftm.sof come from the same assembly (same timestamp), the promoted
    release/mister copy has the same md5, and the device has exactly one
    sftm.rbf which matches it.
  - **Not compression.** The assembler emits a COMPRESSED rbf (4,245,988 B)
    while `quartus_cpf -c sftm.sof out.rbf` gives 7,007,204 B uncompressed --
    a real difference, since stock MiSTer Cyclone V cores are the uncompressed
    kind. Loading the uncompressed rbf changes nothing: still no hub.
  - **Not the JTAG TAP or cable.** `Captured IR after reset = (0555) [14]` is
    byte-identical in both states, so the chain is in the same state either way.
  - **Not a half-configured FPGA.** /sys/class/fpga_manager reports `operating`
    and all three fpga_bridges are `enabled`.
  - **Not the debug-overlay patch.** The viewmux pin applied in build 83 and
    jtframe_debug_viewmux was elaborated into it.

The discriminator is `jtagconfig --debug`:

    HPS-loaded rbf : chain lists SOCVHPS + 5CSEBA6, and NOTHING else
    JTAG .sof      : adds `Design hash 4E429CD5C53699F31C61`
                     + Node 00486E00 Source/Probe #0
                     + Node 00486E01 Source/Probe #1

`Design hash` is itself read out of the hub, so its absence means the hub is not
responding at all -- the fabric is configured and running, but its JTAG debug
path is inert.

### Consequence, and what to do about it

    HPS-loaded .rbf  -> game runs (ROM downloaded), NO ISSP
    JTAG-loaded .sof -> ISSP works, but the ROM download never runs and JTFRAME
                        holds the game in reset, so the CPU does nothing

So a RUNNING game cannot currently be observed through a trustworthy channel.
Options, cheapest first:

  1. Add an ISSP **source** bit that releases the game from reset after a JTAG
     configure, and test whether SDRAM still holds the ROM across
     reconfiguration. One build; settles it either way.
  2. Preload the ROM over JTAG.
  3. Repair the on-screen overlay instead -- but it is independently suspect:
     with the rbf loaded, the overlay's TAG nibble is correct while the PAYLOAD
     is not (view F shows F0 where the build hardcodes FA), which is its own
     unexplained fault.

Operational: JTAG-programming while Linux runs can hang the HPS -- it did on
.98, which then would not boot. Budget a cold boot after each programming.

## ISSP source bit: the JTAG route cannot measure the real game (2026-08-20)

The `force_run` source bit works exactly as designed, and it answers the
question with a clean negative.

Sequence: MRA load (ROM downloaded to SDRAM) -> JTAG configure from the .sof
(hub appears, game held in reset) -> `write_source_data -instance_index 2
-value 1` -> read probe2.

    31 samples, 0 signature failures
    force_run echo   0 on the first sample, then 1        <- the write took
    m_got            1 in every sample
    main fetches     saturated at 32767                   <- CPU running hard
    FIRST longword   0x00808000 in all 31 samples, want 0x00008000

**SDRAM does not survive reconfiguration cleanly.** The first longword is wrong
by exactly one bit (0x00800000) and is *stable* across every sample, so this is
retention decay during the ~3 s configure, not random noise -- the controller
stops refreshing for far longer than DRAM holds charge. Longword 0 is the
68020's initial SP and longword 1 its initial PC, so the CPU starts on a bad
vector table.

With the game released, the meters then read:

    main fetches      saturated      CPU is executing something
    CPU vreg writes   0              ...but never touches the video hardware
    COMMAND / TRANSFER 0
    blitter busy      0
    VRAM read strobes 354,204/frame  scanout healthy
    frame period      871,727 clk    timing exact

A CPU fetching hard while writing no video register is what executing garbage
looks like. So the "the CPU never asks for a blit" verdict this produces is NOT
a statement about the real game -- it is a statement about a CPU running a
decayed ROM. **This route is dead for measuring real behaviour.**

What remains, then:
  1. Preload the program ROM over JTAG after configuring. Only ~1 MB is needed
     to get the CPU running real code, though GROM matters for blitting.
  2. Repair the on-screen overlay, whose own fault is still unexplained: with
     an HPS-loaded rbf the TAG nibble is correct while the PAYLOAD is not
     (view F shows F0 where the build hardcodes FA).
  3. Keep digging on why HPS configuration leaves the SLD hub inert.

### Tooling gotcha worth keeping

`get_insystem_source_probe_instance_info` opens its OWN session. Calling it
between `start_insystem_source_probe` and `end_insystem_source_probe` fails with
"There is already an active In-System Sources and Probes session started",
which reads like stuck global state and is not -- read-probe.sh kept working
throughout. Query instance info in a separate invocation, never inside a
session.

## JTAG ROM loader: working parts and the remaining bug (2026-08-20)

**Working and verified:**
  - USB Blaster on .74, `DE-SoC [3-1]` (the cable name changes with the USB
    port -- discover it, never hardcode).
  - Four ISSP instances enumerate: {0 SFTM} {1 SFWR} {2 SFRN} {3 SFLD}.
  - 64-bit ISSP source writes work: bit 51 (ld_active) and bit 50 (toggle) both
    reach the fabric, confirmed by reading probe3 back.
  - Writes are NOT coalesced. 50 writes with no delay complete in 6 ms and 49
    of 50 are seen by the fabric, so ~8,300 effective writes/s -- 1 MB in ~30 s.
  - The `main` lane is rw and the loader can drive it; spaced single writes
    increment BOTH seen and done (the lane acknowledges).
  - The ROM image is correct: interleaving the four PROMs with prom0 in the MSB
    byte gives first longword 0x00008000, matching ground truth. My first
    ordering gave 0x00800000 and was wrong.

**The remaining bug is in the loader FSM.** Pushing 64 words in one session:

    BEFORE  seen=0 done=0
    AFTER   seen=1 done=0

One toggle edge taken, zero writes completed. The FSM asserts ld_we, enters
state 2, waits for main_ok, and never gets it -- and since the toggle is only
sampled in state 0, every later write is ignored. It is a stall, not a lost
edge.

Why main_ok arrives for spaced single writes (done went 1,2,3) but not in the
burst is NOT yet understood, and that gap is the next thing to establish rather
than patch around.

Fix directions, in order:
  1. Make the FSM unable to wedge: a timeout in state 2, and a pending-write
     latch so a toggle arriving mid-transaction is not dropped.
  2. Probe main_ok itself alongside ld_st, to see whether it is absent or
     merely missed.

### Bugs already fixed here, each of which mimicked a different fault

  1. FSM reset by `rst` -- the GAME reset, asserted the whole time force_run is
     low, i.e. exactly while the loader runs. seen stayed 0 and every write was
     discarded. The loader now takes no reset.
  2. No settle cycle before sampling main_ok, so a stale ok cleared the request
     (sftm_vram's arbiter has the same settle for the same reason).
  3. `write_source_data -value 0` does NOT clear a source; it needs
     `-value_in_hex` like the writes. ld_active stayed high, forcing main_rd
     low, so the CPU could never fetch -- which reads exactly like a dead CPU.

Lesson: every one of these presented as a *different* subsystem failing. The
handshake probe (seen/done) is what made the third one findable in a single
build instead of by guesswork; add that kind of counter before debugging, not
after.

## THE ROOT CAUSE OF EVERYTHING: backup rbf names match MiSTer's core glob (2026-08-20)

**MiSTer resolves `<rbf>sftm</rbf>` by globbing `sftm*.rbf` in _Arcade/cores
and picking the "newest" (date-suffixed) match. Backup files named
`sftm_prev_0814.rbf` and `sftm_b59_working.rbf` MATCH THAT GLOB AND WIN.**
Every "deploy" overwrote `sftm.rbf` while the loader kept running the backup.

Proved on .74: the overlay's view tag advanced at 0.699 s/step -- the Aug-14
core's diag_cnt[28:25], not the deployed build's [26:23] -- and the moment
`sftm_prev_0814.rbf` was moved out of cores/ and the MRA reloaded, the SAME
HPS-loaded sftm.rbf exposed all four ISSP nodes and put the debug constants on
screen.

This retracts, in one stroke:
  - "The SLD hub is not activated when the HPS configures the FPGA" -- WRONG.
    The running rbf simply predated the probes.
  - "The on-screen overlay does not display debug_view" -- WRONG. The overlay
    has worked all along; it was showing a different core's debug_view.
    (Views 0/7/F constants 05/73/FA are now visible on screen.)
  - The .98 stale-bitstream mystery: `sftm_b59_working.rbf` sat in its cores
    dir (and on Zaparoo's command line). sync/page-cache had nothing to do
    with it.
  - The force_run/JTAG-loader route exists only because of this; it is no
    longer needed for measurement (kept: it is still useful tooling).

**RULE: never leave a file matching `sftm*.rbf` in _Arcade/cores. Backups go
in /media/fat/rbf_backups/.** (.98 still has sftm_b59_working.rbf to remove.)

**Consequence for past results:** the backup on .98 was created during the
build-68 deploy, so every .98 observation from build 68 onward -- including
"the cache-lanes core boots and renders attract mode" -- may have been of the
b59 BANKS build. The big_endian conclusion needs re-verification on the now-
trustworthy .74 channel.

## First genuine measurement (build 88, real ROM, HPS-loaded, 2026-08-20)

1,900 probe samples across two runs, zero signature failures, overlay constants
verified on screen simultaneously:

    frame period      871,727 clk every sample
    busiest frame     busy 173,682 clk = 19.9% of a frame
                      GROM fetch stall 171,867 = 99% OF BUSY
                      write-FIFO stall 4,596 = 3%
    COMMAND writes    max 2/frame; most frames zero blits
    VRAM writes       max 147/frame (a background needs 92,160)
    screen            full-frame noise; almost nothing is ever drawn

Two findings:
  1. **The blitter's bottleneck is the GROM fetch path, 99:3 over the write
     FIFO.** The cache-lanes conversion optimised the wrong side.
  2. The game barely blits at all and the screen is uniform garbage -- the
     first trustworthy look at this core running real ROM. Whether that is the
     cache-lanes design misbehaving or a build-88-specific regression (main
     lane rw + loader mux) is THE next question, now answerable with working
     instruments: screenshot + overlay + ISSP all agree on one machine.

## The service-menu wall, NVRAM restore, and JTAG inputs (2026-08-21)

**MAME ground truth (headless, `-str` + Lua input injection):** with fresh
NVRAM and no input, sftm shows the battery-backup-failure screen and then
times out INTO ATTRACT somewhere between 45 s and 120 s. Pressing START at
the battery screen also goes straight to attract. The service menu is never
visited on the ordinary boot path.

**Our cache core diverges:** on .74, both the timeout AND a verified START
press at the visible battery screen land in the MAIN SERVICE MENU (proven on
b100 and b105 -- not a coalescing/JTAG-build regression). Menu navigation
over JTAG works (cursor moves, submenus open), but two actions silently
no-op: EXIT on the main menu (screen unchanged even 180 s later) and TEST
ALL SOUND ROMS. Both plausibly wait on the sound CPU; sftm_snd's 6809 booted
and initialised the ES5506 in banks-era measurements but the cache-era sound
path is unverified on hardware. The snd lane's BYTE ORDER is verified
correct in simulation (tb_cachelane Phase H: real dwnld SWAB=1 stream read
back in order through the real DW=8 lane), so a crashed-by-swapped-opcodes
6809 is ruled out; b102's snd addr-bit0 inversion would have BROKEN it.
jtframe hard-errors on ENDIAN=1 for DW!=32 (jtframe_cache_ctrl), so the 8-
and 16-bit lanes are little-endian selects and the MRA/SWAB packing already
agrees with them.

**Why .98 never showed any of this:** MiSTer restores arcade NVRAM from
`/media/fat/config/nvram/<MRA name>.nvm`. .98 has a valid 32 KB save (from
2026-08-16, banks-era session) and therefore boots STRAIGHT TO ATTRACT --
battery screen and menu never appear, credits even persist across reloads.
The `_Arcade/<name>.nvm` file quarantined earlier is NOT the restore path.
Installing .98's save at the same path on .74 changed nothing: .74 runs a
different/older MiSTer main binary (1,059,560 bytes, Aug 9, vs .98's
1,209,380, Jul 5) which apparently does not restore arcade NVRAM. Aligning
.74's MiSTer binary with .98's is the pending unblock for unattended attract
(and metering) on the bench -- needs the user's sign-off (system software).

**JTAG cabinet inputs (build 105):** SFRN (ISSP instance 2) src[2..5] now
press P1 START / COIN1 / P1 UP / P1 DOWN by pulling the active-low inputs
down. `/tmp/press.sh start|coin|up|down [hold_ms]` on gamingpc. Proven
against the service menu. Note the PLAYER CONTROL TEST screen exits only
with START1+START2 -- src[6] for START2 is the obvious next wire.

**The mystery footer decoded:** the binary+hex byte at the bottom of every
capture is OUR debug overlay's debug_view row (st_main), not a game status
display. It appears on both machines and changes constantly; stop reading
game meaning into it.

**Build 104 pixel-pair coalescing, hardware status:** sim-clean at three
levels (tb_vramthru drain/integrity; tb_cachelane Phase I: dsn=0000
full-word writes on the real ENDIAN=1 lane land identically to the proven
partial-write convention, cache-resident, in the SDRAM chip after eviction,
and on refill; STA all-positive slack). On .98 the b105 attract fight showed
heavy corruption, but so did b100 the same morning on a different scene --
"catastrophically broken" vs "same insufficiency, busier scene" is being
decided by a like-for-like A/B screenshot campaign on .98.

## RESOLVED: the service-menu divergence was a DIP file (2026-08-21, later)

**Retraction of the section above.** The cache core does NOT diverge from
MAME on the boot path, and the sound handshake was never the EXIT blocker.
The cause was one byte of per-machine state: MiSTer stores per-game DIP
overrides in `/media/fat/config/dips/<MRA name>.dip`, and .74's had byte 2 =
0x8F where .98's has 0x0F. Bit 0x80 is MAME's `PORT_SERVICE_DIPLOC(0x0080,
IP_ACTIVE_HIGH, "SW1:4")` -- **.74 had the service DIP switched ON**, saved
by someone in the OSD long ago. With service on, the game (correctly!) boots
into the operator menu, and EXIT (correctly!) re-enters it while the switch
is held on -- explaining every "EXIT does not work" observation. Installing
.98's dip file fixed it: .74 now boots unattended straight into attract.
Lesson: when two machines behave differently on identical rbf+MRA+NVRAM,
diff EVERYTHING under /media/fat/config -- dips/, nvram/, <core>.CFG.

Also done: .74's MiSTer main binary replaced with .98's (user-approved;
backup at /media/fat/MiSTer_backup_aug9), after which the
`config/nvram/<MRA name>.nvm` restore works on .74 -- credits persist
across reloads. The rbf can't be scp'd over a running MiSTer binary
("dest open failure"): upload to a temp name and `mv` over it.

**Sound triage (SFSN, build 106, hardware):** cmd_wcnt increases during
attract and cmd_rcnt is saturated at 255 -- the 68020 writes the latch and
the 6809 reads it; the handshake WORKS. But sromn=0 and peak=0 always: the
ES5506 never fetches samples and the output is silence, consistent with the
banks-era "voices never leave STOP" finding. Real bug, pre-existing,
separate from video. (decode_snd.py: quartus_stp returns probes as BINARY
strings, not hex.)

## First trustworthy coalescing measurement (build 106, .74 attract fight)

900 samples over the attract cycle, busiest frame:

    busy            871,727 clk = 100% of the frame (saturated)
    wrFIFO stall    800,672 = 92% of busy (was 95% pre-coalescing)
    GROM stall      169,664 = 19% of busy
    write txns      35,796 (TRANSACTIONS, st_wpop counts pops not pixels
                    from b104 on; up to ~71.6k pixels if fully paired)
    clk/txn         24.4 (single-write b100 measured 19.2)
    VRAM reads      412,559 strobes/frame vs ~46k words a frame needs

Reading: pairing roughly ~1.6x'd pixel throughput (12-24 clk/pixel vs
19.2), matching the visual A/B (mean corruption 2.03% -> 0.85%, jungle
fight now clean, city stage still saturated). The dominant cost is now the
LANE ROUND TRIP under contention: scanout reads and blit writes share the
vram cache lane and evict each other's blocks (24 clk/txn is a miss+fill+
writeback, not a cache hit), and the read side issues ~9x more strobes than
a frame's worth of words. Next levers, in order of expected value:
  1. account for the read-strobe overcount (probe semantics vs real reads);
  2. stop the scanout/blit thrash -- separate lanes need cross-lane
     invalidation (INVAL_MASK exists in the generated mux) or a proper
     line-buffer scanout that reads each word once;
  3. only then, FIFO depth.

## Build 107: the vram lane contention package, measured (2026-08-21)

Three structural changes landed together -- 64-bit vram lane with quad-run
write coalescing, hit-skip replacement in jtframe_cache_ctrl (whole-file
overlay in docker/jtframe-patches), and a pace-based prefetch yield. Full
verification stack: tb_vramthru (64-bit model), tb_vramlane (NEW: sftm_vram
against the real mux + burst controller + SDRAM model; caught a bench NBA
race that masqueraded as RTL corruption -- wait loops must let nonblocking
updates land before sampling uut state), tb_cachelane Phases A-J.

Hardware, same attract-cycle metering window as b106:

                          b106            b107
    write txns/frame      35,796 (x2 pens) 37,396 (x4 pens)  ~1.5x pixels
    clk/txn               24.4            23.2
    wrFIFO stall          92% of busy     81% of busy
    GROM fetch stall      19% of busy     35% of busy   <-- new bottleneck
    VRAM read strobes     412k            306k
    busiest frame busy    100%            99.7% (moving ~1.5x the pixels)

Visually: FMV attract scenes render PERFECT, the museum stage is clean on
the left half with a corrupted band on the right (the left-to-right redraw
still runs out of frame on the busiest scenes, but much later), fight
scenes show scattered speckle instead of full-screen shredding.

Remaining work, in order: the GROM fetch path is now the bigger stall
(sftm_blit single-word fetches through the grom lanes -- same
transaction-tax structure the vram side just shed); and the fill-on-write-
miss waste (a full-coverage background block still reads 256 bytes from
SDRAM only to overwrite them -- allocate-without-fetch needs per-word valid
bits in jtframe_cache, the one big lever left on the write side). One
open eye: the first b107 boot caught the title logo half-garbled once, not
reproduced across a full attract cycle since -- watch for it.

## Builds 109-111: the frame budget closes (2026-08-21, evening)

The full contention campaign, one number per build (busiest attract frame,
.74 meters, same methodology throughout):

    build  change                        clk/wr-txn  busiest-frame busy
    b106   pair coalescing (baseline)      24.4        100.0% (saturated)
    b107   64-bit lane + quad runs +
           hit-skip + prefetch yield       23.2        100.0%
    b108   64-bit grom lanes (8 px/fetch)  24.7        100.0%
    b109   vscan lane split + vblank
           flush/invalidate                14.9        100.0%
    b110   write-no-fetch (claim+merge)    12.9         98.8%  <-- first
                                                       sub-100% busiest frame

b110 moves ~2.5x the pixels of b106 per busiest frame (66.6k quad-run
transactions vs 35.8k pair transactions). Visually: jungle-stage fights
render clean, the city stage renders fully with scattered residual speckle
(stale pens from the previous scene in the last unfinished bands).

b110 first failed to FIT: the write-no-fetch valid array elaborated on
every 64-bit lane including the three read-only ones, 4196/4191 LABs.
Gated on BLOCKS==64 (the rw vram lane is the only such lane in this map;
upstream form should be a real parameter). Fit note: the fuller device
pushed the HDMI scaler clock to -0.22 ns setup slack (game clock +1.4);
watch for whole-screen HDMI artifacts and re-seed if they appear.

b111 (in flight): pipelined GROM fetcher -- two ping-pong entries with
speculative successor prefetch, hiding the lane round trip behind pixel
consumption on sequential runs. Targets the 200k-clk GROM stall that is
the largest remaining item.

## Build 111 measured; residual characterised (2026-08-21, night)

The pipelined fetcher halves the GROM stall (busiest frame 200k -> 108k,
mean 78k -> 32k); the freed time flows into the write drain, which is now
the entire budget on peak frames (98.6% busy, 12.9 clk/txn, 66.6k txns).

Visual state on b111 (.74, 40 captures over 80 s of attract): 37 frames
essentially clean -- including the city and factory stages that used to
shred -- and 3 consecutive frames showing a transient stale band on the
LEFT EDGE during a camera pan. That is the expected signature of the
bounded-staleness architecture: newly exposed columns lag by up to ~2
frames (1 frame of vscan staleness + up to 1 frame of redraw latency)
during fast scrolls, then catch up. No confetti, no persistent regions.

If the pan-band matters, the next levers are: flush more often than once
per frame (e.g. also at mid-screen, cost ~10k clk each), or trim write
drain further (wb-burst chaining in jtframe_burst_ctrl). Neither started.
