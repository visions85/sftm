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
