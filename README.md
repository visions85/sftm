# JTSFTM — Street Fighter: The Movie (arcade) for MiSTer

An in-progress FPGA core for **Street Fighter: The Movie** (`sftm`), the
Incredible Technologies 32-bit ("itech32") arcade platform, built on
[JTFRAME](https://github.com/jotego/jtcores) and ported function-by-function
from the MAME driver.

## Status

**Playable-looking, not yet verified as playable.** As of build 69
(2026-08-16) the core runs on a real DE10-Nano:

- The 68EC020 boots the game ROM and reaches the service/boot screen.
- Attract mode runs with correctly rendered digitised artwork — character
  portraits, the STREETFIGHTER and BISON'S LAIR panels — and animates
  between frames.
- Stereo audio is audible on hardware; the ES5506 mixer reaches near
  full-scale output and the driver cycles through many voices.
- NVRAM persists to SD card, so operator settings (including the volume,
  which starts at zero) survive a power cycle.

What has **not** been confirmed:

- **Gameplay.** Nobody has sat at the machine with a controller yet. Input
  cannot be injected over ssh, so everything above was measured through the
  debug overlay and screenshots. Speed accuracy, input mapping and whether
  visible tearing remains during a fight are all open.
- **Blitter throughput has almost no margin.** The busiest frame now issues
  about 98,300 VRAM writes against the 92,160 needed to clear one full
  background — it clears a background, but only just. Screenshots still show
  horizontal partial-redraw bands; they sit at different heights each frame,
  so they read as mid-frame captures rather than static corruption, but that
  distinction needs a human eye to settle.
- **Timing rides the edge.** Every failing path across builds sits inside the
  vendored TG68K register file. It closes, but placement variance matters —
  see the timing section of `cores/sftm/doc/PORTING.md` before adding
  constraints.
- The core fills roughly 75% of the DE10-Nano's ALMs (31,275).

Only the parent `sftm` set (v1.12) is targeted. Other itech32 games are not.

## How this was built

The RTL is a **literal, function-level port** of MAME's `itech/itech32.cpp`,
`itech/itech32_v.cpp` and `sound/es5506.cpp` — the porting rules are written
down in `cores/sftm/doc/PORTING.md`, along with a full hardware bring-up log:
every bug found, how it was proved on real silicon, and the several
conclusions that turned out to be wrong. If you are debugging an FPGA arcade
core, that log is probably the most useful file in the repository. Recurring
lessons from it, in short:

- For anything that changes over time, measure a counter or an accumulator,
  never a single sample. Most wrong turns here came from inferring steady
  state from a snapshot.
- A subsystem that looks broken may just be starved by an upstream one. Sound
  was chased as an ES5506 defect for days; it fixed itself once the graphics
  ROM banking bug let the game reach real gameplay.
- JTFRAME silently ignores some memory attributes rather than rejecting them.
  Always check the *generated* port widths in
  `cores/sftm/mister/jtsftm_game_sdram.v` after editing `cfg/mem.yaml`.
- Grep every Quartus build log for `has no driver`. One such warning sat in
  the log for many builds while the core produced full-scale audio internally
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
| Video        | 384x240 visible, 59.76 Hz | ~8 MHz pixel clock |

The game's protection device needs no PIC emulation — the one protection
read is a main-RAM byte, and MAME's own handling of it is reproduced directly.

### Memory

ROM footprint is about 36 MB (≈32.5 MB graphics, ≈2.5 MB samples, 1 MB
program, 256 KB sound). The core uses four 16 MB SDRAM banks, so it needs a
**64 MB or 128 MB SDRAM module** — the standard 32 MB module is not enough.
The graphics ROM is split across two banks because no bus may be wider than
the bank it lives in; the RTL comments in `cfg/macros.def` explain why at
length, since violating that rule fails silently.

## Repository layout

This tree mimics a `jtcores` checkout (`$JTROOT`) so the core builds with the
standard JTFRAME flow:

```
.
├── cores/sftm/
│   ├── cfg/           # macros.def, files.yaml, mem.yaml, mame2mra.toml
│   ├── hdl/           # sftm_*.v, plus tg68k/ (submodule)
│   ├── ver/game/      # simulation testbenches
│   └── doc/           # PORTING.md — porting rules + bring-up log
├── docker/            # Linux/Quartus build environment
├── doc/               # MAME reference fetch script, MRA helpers
└── modules/           # JTFRAME lands here (fetched by the build, not committed)
```

## Building

### Prerequisite: NVRAM power-on image

`sftm_main.v` reads `cores/sftm/hdl/nvram_{hi,lo}.hex` at **synthesis** time to
give the 128 KB NVRAM a sane factory state. These are game-derived data and
are not distributed here, so generate them from your own MAME dump first:

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
cycle-exact, so game speed is tuned through the CPU clock enable.

## Contributing

The most valuable contribution right now is **someone with the ROMs, a
DE10-Nano and a controller** reporting what actually happens in a fight —
whether the game is playable, how it feels, and what breaks. Bug reports
against the bring-up log are welcome; please read the relevant section of
`cores/sftm/doc/PORTING.md` first, as several plausible-looking theories are
already recorded there as refuted.

## License

RTL authored here is GPLv3, to match JTFRAME. Third-party cores keep their
own licenses (TG68K.C: LGPL; mc6809: see its header). MAME driver source is
consulted as a reference only and is not redistributed here — run
`doc/fetch-mame-src.sh` to fetch it locally.

**No ROMs or NVRAM images are included or distributed.** You must supply your
own legally obtained MAME-compatible set.
