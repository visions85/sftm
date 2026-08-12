# Phase 2 design: IT42 video/blitter literal port

Target: replace the `sftm_video.v` stub's no-op blit commands with a literal
port of `itech32_v.cpp` drawing, plus real scanout. The register file,
interrupt semantics, palette RAM and CRT skeleton in the stub are already
correct and verified by `ver/game/tb_phase1_boot.v` — build on them, do not
rewrite them.

## Constraint that shapes everything: VRAM must live in SDRAM

MAME stores a **16-bit pen per VRAM pixel** (`pixel(8) | color_latch(7)<<8`,
see `draw_raw`, itech32_v.cpp:410: `base[...] = pixel | color`). The color
half is applied per pixel at *blit* time, not at scanout, so it cannot be
factored out. One 512x1024 plane is therefore 1 MB — far beyond the Cyclone
V's ~700 KB of total BRAM (which also holds main RAM 32K + NVRAM 128K +
palette 128K). VRAM goes to SDRAM:

- Add to `cfg/mem.yaml` bank 3 (shared with the small, rarely-read grm3):
  ```yaml
  - name: vram
    addr_width: 21        # 2 MB: 2 planes x 512x1024 x 16-bit
    data_width: 16
    rw: true
  ```
  (regenerates `mem_ports.inc` with vram_addr/vram_din/vram_dout/vram_we...)
- sftm uses `m_planes = 1` (init_sftm_common): **only plane 0 is scanned
  out** (screen_update, itech32_v.cpp:1510, single-plane branch). Plane 1
  still accepts blit writes when enabled (enable_latch[1] via
  itech020_plane_w) but nothing reads it — implement writes to it literally
  (cheap, same datapath) but do not implement the two-plane blend scanout.
- Bandwidth check @ 48 MHz, 16-bit SDRAM bus, bank 3:
  scanout needs 8 Mpix/s x 2 B = 16 MB/s sustained (burst reads into a
  scanline buffer during LHBL); blitter writes are bursty but the CPU stalls
  on VIDEO_STATUS polling anyway (MAME blits are instantaneous; we only need
  to be "fast enough that the game never notices", and the game polls the
  blitter-done bit / takes XINT). grm3 traffic is negligible. This fits.

## Scanout

- Double scanline buffer in BRAM (512 x 16-bit x 2). During each line,
  prefetch line y+1 of plane 0 from SDRAM: base address
  `compute_safe_address(XORIGIN1, YORIGIN1 + y)` (itech32_v.cpp:1489,148):
  `((y & ymask) * 512 + (x & xmask))`, ymask=1023, xmask=511.
- Pen -> color: pen[14:0] indexes palette BRAM (already in sftm_video);
  palette format xRGB_888 (sftm machine config, itech32.cpp:1902) written by
  the CPU as 32-bit longwords: R = pal[23:16], G = pal[15:8], B = pal[7:0].
  JTFRAME_COLORW=5 -> output top 5 bits of each channel.
  NOTE: the current palette BRAM stores hi/lo 16-bit halves in separate
  arrays; scanout needs both halves of one longword per pen — one read port
  each, same address, no conflict with CPU (CPU has priority; scanout
  fetches during blanking or steals idle cycles).
- CRTC: keep fixed 508x286 timing for first hardware light-up; then
  implement the dynamic reconfiguration from VIDEO_HTOTAL/VTOTAL etc.
  (video_w, itech32_v.cpp:1402-1433) with MAME's sanity checks, since sftm
  programs 508x286 anyway (itech32.cpp:1785 comment).

## Blitter: one FSM per MAME function, shared pixel pipeline

Dispatch on `VIDEO_COMMAND` write (handle_video_command, itech32_v.cpp:1233).
The stub currently sets VIDEOINT_BLITTER immediately; Phase 2 sets it when
the FSM actually finishes (the CPU polls VIDEO_STATUS bit 0/2 or waits for
XINT — video_r already fakes "idle", which must then return real busy state:
`(val & ~8) | 4 | 1` keeps working if we only flip an internal busy flag
into bit 3).

Commands (only what sftm uses; log-and-ignore the rest like MAME):
1. **command 1 blit raw** -> `draw_raw` (itech32_v.cpp:410) and
   `draw_raw_widthpix` (:520) when XFERFLAG_WIDTHPIX. Per-pixel loop with
   8.8 fixed-point stepping: src x steps by SRC_XSTEP, dst x by 0x100 or
   DST_XSTEP (XFERFLAG_DSTXSCALE), y by SRC_YSTEP/DST_YSTEP, XY skew via
   YSTEP_PER_X/XSTEP_PER_Y, flips negate steps, clip window from
   LEFT/RIGHT/TOP/BOTTOMCLIP (<<8), XFERFLAG_CLIP gates clipping
   (disable_clipping sets 0..0xfff), transparent pen 0xff when
   XFERFLAG_TRANSPARENT.
2. **command 2 blit RLE** -> `draw_rle` dispatch (:1151):
   `draw_rle_fast` (:914), `draw_rle_fast_xflip` (:990), `draw_rle_slow`
   (:1073 — when DSTXSCALE with DST_XSTEP != 0x100, or XSTEP_PER_Y != 0).
   RLE format (GET_NEXT_RUN, :876): count byte; bit7 set -> literal run of
   (count&0x7f) bytes following; bit7 clear -> repeat next byte count
   times; value 0xff run = transparent skip. Rows are pixel-exact
   (SKIP_RLE consumes the remainder on clipped lines).
3. **command 3 raw transfer setup** + VIDEO_TRANSFER write path
   (video_w case 0x04, :1349): CPU-driven pixel-at-a-time VRAM write with
   readback of the old pixel into VIDEO_TRANSFER.
4. **commands 4/5**: no-op (flush/reset).
5. **command 6 shift-register copy** -> `shiftreg_clear` (:1180): copies the
   row at (TRANSFER_X, TRANSFER_Y) to `height-1` successive rows (whole
   512-pixel rows) — used for fast screen clears.

GROM source: byte stream at
`(grom_bank<<24 | (ADDRHI&0xff)<<16 | ADDRLO) % grom_length` (:414), i.e.
25-bit byte address into the 32 MB grom SDRAM bus (16-bit: fetch a word,
consume both bytes; RLE needs a small byte FIFO since runs consume at
variable rate). `grom_bank` comes from itech020_plane_w bits 7:6
(`m_grom_bank_mask`: grom length 0x2080000 >> 24 = 2 -> mask 3,
video_start :199).
NOTE sftm's grm3 lives at MAME grom offset 0x2000000, which our SDRAM split
puts in bank 3 — blit source addresses >= 0x2000000 must fetch from the
grm3 bus instead of grom. Decode on address bit 25 with the modulo
`% 0x2080000` applied first.

Pixel pipeline shared by all draw FSMs:
  src fetch (grom/grm3 byte) -> transparent test -> pen = pixel | color ->
  clip test -> VRAM write queue (SDRAM). draw_raw's inner loop computes
  `dstoffs = compute_safe_address(sx>>8, sy>>8)` with wrap masks — implement
  exactly (`& vram_mask` = & 0x7ffff after the *512 add).

The "reflect final values into registers" tail of drivedge's draw_raw
(:860) is drivedge-only — skip. But draw_raw/draw_rle for itech32_state do
NOT write back registers; keep registers unmodified after a blit.

## Interrupt wiring (already in place)

The FSM completion sets `VIDEO_INTSTATE |= VIDEOINT_BLITTER` and the
scanline compare sets VIDEOINT_SCANLINE — both feed the existing
`blit_irq`/`scan_irq` level outputs (INTSTATE & INTENABLE), consumed by
sftm_main as XINT (IPL2) / QINT (IPL3). Nothing to change in sftm_main.

## Verification plan (before hardware)

1. Extend `tb_phase1_boot.v` ROM program: program the video regs for a
   small raw blit from a synthetic GROM model, then read VRAM back via
   command 3 transfer reads; check pixels land where MAME's loop puts them
   (hand-compute a 4x4 case with clip + transparency).
2. RLE: encode a tiny sprite in the TB GROM, blit, compare against a
   software decode in the TB.
3. Instrument MAME (or use its blitter logging, LOG_BLITTER) to dump real
   sftm boot blit register writes and replay the first N blits in sim once
   ROMs are available on gamingpc.
4. Scanout: check the scanline buffer against VRAM contents, LVBL/LHBL
   alignment vs JTFRAME_WIDTH/HEIGHT.

## Module plan

- `sftm_video.v` stays the top: register file, palette, CRT, scanout mux.
- `sftm_blit.v` (new): command dispatch + draw FSMs + GROM byte fetcher.
- `sftm_vram.v` (new): SDRAM VRAM port arbitration (scanline prefetch has
  hard priority during its burst; blitter otherwise) + the two scanline
  buffers.
