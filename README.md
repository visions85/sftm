# SFTM — Street Fighter: The Movie (arcade) for MiSTer

An FPGA core for **Street Fighter: The Movie** (`sftm`), the Incredible
Technologies 32-bit ("itech32") arcade platform, built on
[JTFRAME](https://github.com/jotego/jtcores) and ported function-by-function
from the MAME driver.

## Status

**Playable, with bugs still being ironed out.** As of build 119
(2026-08-22) the core runs the game on a real DE10-Nano: it boots, plays,
and renders correctly.

Working:

- **Gameplay.** Boots, takes coins and plays. Cabinet inputs, the operator
  service menu and NVRAM save/restore all work.
- **Graphics are clean.** Across twelve captures of the full attract cycle
  the corruption metric reads 0.0000 in every frame. The factory and cage
  stages — the worst offenders for most of this project — render
  pixel-perfect, as does the high-score table.
- **Data integrity is verified by the game itself.** The service menu's FULL
  GROM CHECKSUM TEST passes with sums identical to the reference baseline.
  A JTAG dump of the loaded ROM matches the MAME set byte for byte. The
  game's own self-tests turned out to be the single most valuable
  verification tool here; they caught a lost-write hazard that meters and
  screenshots could not name.

Known issues, roughly in the order they bite:

- **No sound.** The ES5506 is silent. Audio was confirmed audible on
  hardware back in the SDRAM-banks era (build 53), and the cache-era sound
  path has never been confirmed on hardware since. The sound lane's byte
  order is verified correct in simulation, so a 6809 crashed by swapped
  opcodes is ruled out. This is the largest missing piece.
- **Game speed varies.** Some scenes tick slower than they should. The
  memory side is no longer the wall, so the current suspect is the 68020
  fetching a 1 MB program through a small cache; the main lane was widened
  to 16 KB and a per-frame fetch-stall meter added to tell fetch-bound from
  compute-bound. Unresolved.
- **Transient stale bands during fast camera pans.** Newly exposed columns
  can lag by up to about two frames before catching up. This is the expected
  signature of the bounded-staleness design rather than a defect, but it is
  visible.
- An open bench-only race in the 48 MHz flat testbench, which needs a
  non-perturbing instrument before the relevant fixes can be upstreamed.

Only the parent `sftm` set (v1.12) is targeted. Other itech32 games are not.

## Performance: where the work went

Most of this project's effort went into feeding the blitter, and the numbers
are the clearest way to show it. The measure is *pens drawn on the busiest
frame of the attract cycle*; one full-screen background is 92,160 pens.

| Build | Change | Busiest frame |
|---|---|---|
| b56  | SDRAM banks arbiter | ~65k writes/frame — never cleared one background |
| b69  | cache-lanes conversion | ~98k — one background, barely |
| b106 | pixel-pair coalescing | 24.4 clk per write transaction |
| b110 | 64-bit lanes, hit-skip, write-no-fetch | 12.9 clk/txn, first sub-100% frame |
| b111 | pipelined GROM fetcher | GROM stall 200k → 108k clk |
| b114 | flush race fixed | data integrity restored, checksums pass |
| b116 | 96 MHz SDRAM domain | **340,340 pens — 3.7 backgrounds** |

The original IT42 blitter's envelope was roughly 470k pens/frame, so the core
now supplies about 72% of the real hardware's draw bandwidth — enough that
the corruption metric reads zero across the attract cycle. Write stall fell
to 53% and GROM stall to 11%. Notably the game *expands its draw demand* to
whatever the machine supplies: b116 requested 21% more pens than b114, and
got them.

The 96 MHz arrangement is worth a note for anyone doing something similar.
`JTFRAME_SDRAM96` runs the frame, burst engine and cache stack at 96 MHz
while **all game RTL stays at 48 MHz**, untouched, via a `game_sdram`
template overlay that hands `clk48`/`rst48_h` into the game instance. The
lane ports are the clock crossing, hardened with a held-until-request-drop
`ok` stretcher. The whole campaign was done simulation-first —
`tb_vramlane96` and `tb_cachelane96` run the real stack split across both
clocks — and it landed in a day. Every clock closed positive: 96 MHz domain
+0.59 ns, game +1.24, HDMI +0.30.

## How this was built

The RTL is a **literal, function-level port** of MAME's `itech/itech32.cpp`,
`itech/itech32_v.cpp` and `sound/es5506.cpp`. The porting rules are written
down in [`cores/sftm/doc/PORTING.md`](cores/sftm/doc/PORTING.md), along with
a full bring-up log: every bug found, how it was proved on real silicon, and
the several confident conclusions that turned out to be wrong. If you are
debugging an FPGA arcade core, that log is probably the most useful file
here. Its recurring lessons:

- For anything that changes over time, measure a counter or an accumulator,
  never a single sample. Most wrong turns here came from inferring steady
  state from a snapshot.
- A subsystem that looks broken may just be starved by an upstream one.
  Sound was chased as an ES5506 defect for days before the real cause turned
  out to be a graphics ROM banking bug upstream of it.
- The game's own service-menu self-tests are a first-class verification
  tool. They found a data-integrity hazard that throughput meters and
  screenshots had been misattributing to insufficient bandwidth for five
  builds.
- "Passes in simulation" must be qualified by event-order robustness when a
  bug is timing-flavoured. The lost-write hazard vanished when a *passive
  monitor* was attached to watch it.
- JTFRAME silently ignores some memory attributes rather than rejecting
  them. Always check the *generated* port widths in
  `cores/sftm/mister/jtsftm_game_sdram.v` after editing `cfg/mem.yaml`.
- Grep every Quartus build log for `has no driver`. One such warning sat
  there for many builds while the core produced full-scale audio internally
  and emitted absolute silence.

## Hardware being recreated

| Block        | Part                    | Notes |
|--------------|-------------------------|-------|
| Main CPU     | Motorola MC68EC020 @ 25 MHz | 68020 instruction set, 24-bit address |
| Sound CPU    | Motorola MC6809 @ 2 MHz | command latch from main CPU |
| Sound chip   | Ensoniq ES5506 (OTTO) @ 16 MHz | 32-voice sample playback, stereo (channels swapped) |
| Blitter      | IT42 custom             | scale / flip / clip / transparency, RLE and raw blits |
| VRAM         | single 512x1024 plane   | lives in SDRAM, not BRAM |
| Palette      | 15-bit RGB, 32768 entries | |
| Video        | 384x240 visible, 59.76 Hz | |

The game's protection device needs no PIC emulation — the one protection
read is a main-RAM byte, and MAME's own handling of it is reproduced
directly.

### Memory

ROM footprint is about 36 MB (≈32.5 MB graphics, ≈2.5 MB samples, 1 MB
program, 256 KB sound). The core uses four 16 MB SDRAM banks, so it needs a
**64 MB or 128 MB SDRAM module** — the standard 32 MB module is not enough.
The graphics ROM is split across two banks because no bus may be wider than
the bank it lives in; the comments in `cfg/macros.def` explain why at
length, since violating that rule fails silently and cost this project
several days.

## Repository layout

This tree mimics a `jtcores` checkout (`$JTROOT`) so the core builds with the
standard JTFRAME flow:

```
.
├── cores/sftm/
│   ├── cfg/           # macros.def, files.yaml, mem.yaml, mame2mra.toml
│   ├── hdl/           # sftm_*.v, plus tg68k/ (submodule)
│   ├── syn/           # sftm_96.sdc — jtcore wipes the generated mister dir
│   ├── ver/game/      # simulation testbenches
│   └── doc/           # PORTING.md — porting rules + bring-up log
├── docker/            # Linux/Quartus build environment
├── doc/               # MAME reference fetch, NVRAM and MRA helpers
└── modules/           # JTFRAME lands here (fetched by the build, not committed)
```

## Building

### Prerequisite: NVRAM power-on image

`sftm_main.v` reads `cores/sftm/hdl/nvram_{hi,lo}.hex` at **synthesis** time
to give the 128 KB NVRAM a sane factory state. These are game-derived data
and are not distributed here, so generate them from your own MAME dump first:

```sh
./doc/make_nvram_hex.py ~/mame/nvram/sftm/nvram32 --volume 0x1e
```

Skip this and the NVRAM powers up blank: the volume byte reads zero and the
core is silent. Supply the full 128 KB dump, not the 32 KB that SD-card
persistence covers — the game rejects a partial image and drops into its
setup screen.

### Docker (recommended)

Requires Docker. Place the Quartus 21.1 installer files in
`docker/quartus-installers/` first (see the README there).

```sh
git clone --recursive https://github.com/visions85/sftm
```

```sh
cd sftm && ./docker/run-synth.sh
```

The first run builds the Quartus image (~15 min) and sparse-clones JTFRAME
into `modules/jtframe` by itself; nothing else needs installing. Synthesis
takes roughly 30 minutes after that. Output lands at
`release/mister/sftm.rbf`, and the generated MRA is rewritten to point at it.

### Native (Linux, existing JTFRAME install)

JTFRAME's toolchain is Linux-only (Quartus, Verilator, ghdl).

```sh
git clone --recursive https://github.com/jotego/jtcores
```

```sh
cp -r cores/sftm <path-to-jtcores>/cores/sftm
```

```sh
cd <path-to-jtcores> && source setprj.sh && jtframe mra sftm && jtcore sftm -mister
```

## The 68EC020 CPU

JTFRAME bundles `fx68k`, which is 68000-only and cannot run this game. The
core uses **TG68K.C** in 68020 mode, vendored as a submodule at
`cores/sftm/hdl/tg68k`. It is VHDL: Quartus consumes it directly, but
JTFRAME's Verilator simulation needs a Verilog conversion via `ghdl` (the
command is in `cores/sftm/doc/sftm.txt`). TG68K.C is functional rather than
cycle-exact, so game speed is tuned through the CPU clock enable — which is
one of the two levers currently being tried against the speed variation.

## Contributing

The most useful contributions right now, in order:

1. **The ES5506 silence.** Anyone who knows the itech32 sound path or
   JTFRAME's cache lanes could probably find this faster than a bisect will.
2. **Play it and report what breaks.** Bug reports from real fights are more
   valuable than any meter — the flush race was found exactly that way.
3. Several fixes here are candidates for upstreaming into JTFRAME: hit-skip,
   write-no-fetch, the flush machinery fixes, the `ok` stretcher, and the
   96 MHz burst arrangement.

Please read the relevant section of `cores/sftm/doc/PORTING.md` before filing
a theory — a number of plausible-looking ones are already recorded there as
refuted, with the measurements that refuted them.

## License

RTL authored here is **GPLv3**, to match JTFRAME. The full text is in
[LICENSE](LICENSE).

Third-party components keep their own licenses and their copyright notices
must be preserved:

| Component | License | Copyright |
|---|---|---|
| [JTFRAME](https://github.com/jotego/jtcores) | GPLv3 | Jose Tejada (jotego) |
| [TG68K.C](https://github.com/TobiFlex/TG68K.C) | LGPLv3 | Tobias Gubener |
| `mc6809` | see its header in JTFRAME | |

A synthesised `.rbf` is a combined work of all of the above. Distributing one
is permitted — GPLv3 covers object code — provided the corresponding source
is offered under the same terms, which publishing it alongside this
repository satisfies.

MAME driver source is consulted as a reference only and is not redistributed
here — run `doc/fetch-mame-src.sh` to fetch it locally.

**No ROMs or NVRAM images are included or distributed.** You must supply your
own legally obtained MAME-compatible set. An `.mra` contains only ROM names,
checksums and offsets — no ROM data — which is why it can be distributed
freely while the ROMs themselves cannot.
