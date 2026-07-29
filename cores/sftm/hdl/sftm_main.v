`timescale 1ns/1ps
/*  This file is part of SFTM.  GPLv3 - see LICENSE.

    Main CPU subsystem for Street Fighter: The Movie (itech32, 020 board).

    CPU: Motorola MC68EC020 @ 25 MHz, recreated with TG68K.C in 68020 mode.
    TG68K.C uses a 16-bit external data bus even in 020 mode (dynamic bus
    sizing), so 32-bit program ROM words are fed as two 16-bit halves.

    Memory map: transcribed and verified against MAME itech32.cpp `itech020_map`
    and `init_sftm_common`. All offsets cross-checked against MAME source.
*/

module sftm_main #(
    // Diagnostic-only: clk cycles from reset release to the synthetic IPL7
    // test pulse (see ipl7_pulse_ever below). Defaults to ~1s @ 48 MHz for
    // real hardware; testbenches override this to a small value so they
    // don't have to simulate a full second of cycles.
    parameter [27:0] IPL7_DBG_DELAY = 28'd48_000_000
) (
    input               rst,
    input               clk,
    input               cen,        // ~25 MHz enable

    // Program ROM (32-bit) in SDRAM bank 0
    output      [17:0]  rom_addr,   // long-word address (1 MB / 4 = 256K)
    input       [31:0]  rom_data,
    output              rom_cs,
    input               rom_ok,

    // Cabinet I/O
    input       [15:0]  joystick1,
    input       [15:0]  joystick2,
    input       [ 1:0]  cab_1p,
    input       [ 1:0]  coin,
    input               service,
    input               dip_test,
    input       [ 7:0]  dipsw_a,
    input       [ 7:0]  dipsw_b,

    // Video / blitter / palette bus (to sftm_video)
    output      [23:1]  cpu_addr,
    output      [15:0]  cpu_dout,
    output              cpu_rnw,
    output              cpu_uds_n,
    output              cpu_lds_n,
    output reg          vram_cs,
    output reg          vreg_cs,
    output reg          pal_cs,
    input       [15:0]  vram_dout,
    input       [15:0]  vreg_dout,
    input       [15:0]  pal_dout,
    output reg  [ 1:0]  plane_en,
    output reg  [ 1:0]  grom_bank,
    output reg  [ 6:0]  color_latch0,
    output reg  [ 6:0]  color_latch1,

    // Interrupts from the video block
    input               blit_irq,
    input               scan_irq,
    input               vblank_irq,

    // Sound command latch to the 6809 subsystem
    output reg  [ 7:0]  snd_latch,
    output reg          snd_latch_we,

    // NVRAM is kept in on-chip BRAM (u_nvram); JTFRAME battery persistence
    // is deferred (see hdl/mem.yaml).
    input       [ 7:0]  debug_bus,

    // Diagnostic: goes high on the first CPU write to NVRAM space and stays
    // high. Used by sftm_video to distinguish "stuck before NVRAM init" (RED)
    // from "stuck after NVRAM init" (MAGENTA) in the post-startup diagnostic.
    output reg          nvram_wr_ever,

    // Diagnostic: goes high the first time the CPU writes to the watchdog
    // register (0x400000 = REG_WDOG).  This happens inside the outer main
    // loop (jsr $8006BA + wdog kick + loop), so wdog_kick_ever=1 means the
    // outer game loop ran at least once.  Never cleared by watchdog resets
    // (w_rst) — persists until hard rst so diagnostic is cumulative.
    output reg          wdog_kick_ever,

    // Diagnostic: goes high the first time rom_ok fires while boot_done=1 (i.e.
    // the SDRAM served ROM data to the CPU after boot).  B=0 → SDRAM never
    // responded to first CPU ROM fetch (stall/hang in cache module).  B=1 but
    // G=0 → SDRAM OK, CPU got ROM data but crashed before watchdog kick.
    output reg          boot_done_ever,

    // VBlank active latch (set on vblank_irq, cleared by timer). Exported to
    // sftm_video so VR_XFER reads can return bit 6 = vint_latch: the VBlank
    // ISR polls this bit to know when the vblank window has ended.
    output              vint_latch_out,

    // Diagnostic: goes high the first time the CPU performs a READ from the
    // autovector-26/27 exception vector table entries ($68-$6B, $6C-$6F).
    // This is independent of any ROM disassembly knowledge — it fires iff
    // TG68K.C's IPL_autovector logic actually recognized an IPL2/IPL3
    // request and began exception processing. If this NEVER latches while
    // stuck at WHITE, the interrupt path (IPL mapping, vint_latch timing,
    // or SR interrupt mask) is the prime suspect. If it DOES latch, the
    // interrupt mechanism itself works and the hang is inside the ISR or
    // a polling loop instead.
    output reg          isr_vec_fetch_ever,

    // Diagnostic: goes high the first time cpu_ipl leaves 3'b111 (i.e. the
    // FPGA side asserted IPL2/IPL3 for at least one clk), independent of
    // whether the CPU ever actually took the resulting exception. Splits
    // the WHITE-with-no-blink case in two: if this NEVER latches, the
    // FPGA never even asserts the interrupt (vint_latch/blit_irq/scan_irq
    // generation is the prime suspect). If this DOES latch but
    // isr_vec_fetch_ever never does, the FPGA is asserting the interrupt
    // fine but the CPU's SR interrupt mask (set by boot code, normally
    // 7 out of RESET until lowered) is blocking it from ever being taken.
    output reg          ipl_asserted_ever,

    // Diagnostic-only: a synthetic, game-logic-independent level-7 (NMI-
    // equivalent, truly non-maskable on the 68000/68020) interrupt pulse is
    // forced ~1s after reset regardless of vint_latch/blit_irq/scan_irq or
    // any SR mask state. Level 7 CANNOT be masked out by software, so if
    // ipl7_pulse_ever fires but isr_ipl7_fetch_ever never does, the CPU is
    // not actually alive/fetching despite other WHITE evidence (or cpu_ipl
    // wiring itself is broken on real silicon). If BOTH fire, the CPU and
    // the whole IPL/autovector mechanism are proven fully functional, which
    // pins the remaining bug squarely on the real ROM's own boot code never
    // lowering its SR interrupt mask below 7 for the ordinary IPL1/2/3
    // levels used by vint_latch/blit_irq/scan_irq (i.e. the game may be
    // stuck looping earlier in boot, before it ever reaches the
    // "enable interrupts" instruction).
    output reg          ipl7_pulse_ever,
    output reg          isr_ipl7_fetch_ever,

    // Diagnostic: goes high the first time our own watchdog counter times
    // out and forces a soft reboot (wdog_rst). Never cleared by w_rst
    // (only by hard rst), so it distinguishes "stuck on the very first boot
    // attempt, watchdog hasn't fired yet" from "the watchdog HAS fired at
    // least once (a soft reboot happened) and the CPU still ended up back
    // in the exact same stuck state" -- the latter rules out a one-time
    // NVRAM-factory-init retry as the explanation, since the retry itself
    // is proven to have already happened.
    output reg          wdog_fired_ever,

    // Diagnostic: goes high the first time the CPU performs any write
    // (either byte lane) to the NVRAM address region (0x600000-0x61ffff),
    // regardless of whether that write actually persists in the backing
    // BRAM. Never cleared by w_rst (only by hard rst) so it survives any
    // number of soft reboots. Used to determine whether the boot ROM ever
    // attempts to touch NVRAM at all.
    output reg          nvram_region_wr_ever,

    // Diagnostic: goes high the first time the CPU WRITES the high byte of
    // the protection RAM word (0x7A6A, the address itech020_prot_result_r()
    // echoes back through 0x680002 -- see MAME itech32.cpp init_sftm_common).
    // The real board has a PIC 16C54 ("ITSF-1") on this bus; MAME does not
    // emulate it and instead just echoes back whatever the CPU last wrote to
    // that RAM byte. If the boot code follows the same write-then-poll
    // pattern documented for sibling games in this driver (see gt2kp/
    // gtclasscp comments: move.b 680002,d0 / andi / cmpi / bne.s -- spin
    // forever if the result doesn't match), and it never gets the byte it
    // wrote to persist/compare correctly, the CPU could spin here forever,
    // BEFORE ever reaching the code that lowers the SR interrupt mask to
    // admit real IPL1/2/3 -- which would explain every symptom observed so
    // far (deterministic stuck state, IPL7 proven working, real IRQ never
    // taken). Never cleared by w_rst (only by hard rst).
    output reg          prot_wr_ever,

    // Diagnostic: goes high the first time the CPU performs a READ from
    // 0x680002 (the protection result port). If this NEVER latches while
    // stuck, the CPU hasn't even reached the protection check in code --
    // the hang is earlier and unrelated to protection. If it DOES latch,
    // the CPU has executed that read at least once, supporting (but not
    // proving on its own) the protection-poll-loop theory above. Never
    // cleared by w_rst (only by hard rst).
    output reg          prot_rd_ever,

    // Diagnostic: saturating count (0..3) of DISTINCT protection-port read
    // ACCESSES since hard reset -- NOT a raw pulse count. prot_word_rd (the
    // qualifying condition below) is a LEVEL, true for as long as cen &
    // bus_rd & prot_cs hold across a single CPU access (which can span
    // several cen ticks); counting that level directly would wildly
    // over-count a single instruction's read as if it were many. This
    // counter instead increments once per RISING EDGE of that level (see
    // prot_rd_lvl_d below), so it reflects actual distinct read
    // instructions executed, saturating at 3 ("3 or more").
    //   0 = never read (shouldn't occur given prot_rd_ever is already
    //       confirmed 1 on hardware; kept for completeness)
    //   1 = read exactly once, then moved on -- protection check likely
    //       PASSED (or was a one-shot probe), CPU is stuck elsewhere
    //   2 = read exactly twice -- ambiguous, check may have retried once
    //   3 = read 3+ times -- if genuinely spinning in a tight poll loop at
    //       CPU clock speed, this saturates in microseconds; a steady-state
    //       reading of 3 while stuck strongly confirms an ACTIVE spin loop
    //       on this exact read, i.e. protection IS the live blocker.
    // Never cleared by w_rst (only by hard rst).
    output reg [1:0]    prot_rd_count,

    // Diagnostic: saturating count (0..3) of DISTINCT instruction fetches
    // the CPU performs AFTER prot_wr_ever has already latched (i.e. counted
    // strictly since the protection RAM byte at 0x7a6a was written). Answers
    // "is the CPU still alive/executing at all after the write, or did it
    // stop dead (crash/halt) right there?" -- independent of whether it ever
    // reaches the specific wdog-kick or protection-read addresses. Same
    // edge-detected counter pattern as prot_rd_count: the fetch bus state
    // (busstate==2'b00) is a LEVEL that can hold across several cen ticks
    // for one instruction fetch (e.g. ROM wait states), so a rising-edge
    // detector is used to count one increment per distinct fetch, not per
    // cen tick. Saturates at 3 ("3 or more").
    //   0 = zero fetches after the write -- CPU never fetched another
    //       instruction post-write -- consistent with a hard crash/halt
    //       (e.g. double bus fault, CPU truly stopped) right at/after the
    //       protection write.
    //   1-3 = CPU continued fetching instructions after the write (1, 2, or
    //       3-or-more distinct fetches) -- CPU is still alive/executing,
    //       just never reaching the wdog-kick or protection-read addresses
    //       specifically -- points at a loop/branch elsewhere, not a raw
    //       crash.
    // Never cleared by w_rst (only by hard rst).
    output reg [1:0]    post_wr_fetch_count,
    // poll_region: which hardware region the stuck CPU is reading in steady
    // state (sample-and-hold ~5s after hard reset, then frozen). 0=none/still
    // in RAM+ROM only, 1=vreg, 2=inp/sys/dip, 3=duart, 4=nvram, 5=pal/nopr,
    // 6=prot. See the detailed block comment at the logic below.
    output reg [2:0]    poll_region,
    // exc_vec: which exception vector, if any, the CPU fetched. Answers
    // whether the steady-state loop is a fault handler or normal flow.
    // Full category map documented at the exc_vec logic below.
    output reg [2:0]    exc_vec,
    // exc_detail: finer split of exc_vec, now that hardware has narrowed the
    // fault to the privilege/line-A/line-F group. See the logic below.
    output reg [2:0]    exc_detail,
    // Raw captured fault details, for the on-screen bit display in sftm_video.
    // exc_vec_num:     the exact 68k vector number (so no grouping ambiguity).
    // exc_fetch_addr:  byte address of the last instruction fetch before the
    //                  fault, i.e. approximately where the CPU was executing.
    // exc_last_ff:     whether that last fetched word was 0xFFFF.
    output reg [7:0]    exc_vec_num,
    output reg [23:0]   exc_fetch_addr,
    // exc_fetch_word: the DATA of that last fetch, i.e. (approximately) the
    // opcode the CPU choked on. Address alone says where; this says what.
    output reg [15:0]   exc_fetch_word,
    output              exc_last_ff,
    // exc_code_ram: continuously mirrors the CPU's last full-word write to
    // RAM byte address 0x0FBE (word 0x07DF). Every exception handler in
    // this ROM does MOVE.W #code,($0FBE).W before parking in a branch-to-
    // self spin (see AGENTS.md ROM cross-check) -- the game's own verdict.
    // Unlike exc_vec/exc_detail above (sample-and-hold on the first
    // qualifying event, proven unreliable: the power-on RAM self-test
    // sweeps every address including this one and the vector table,
    // tripping address-match latches spuriously), this has no freeze and
    // no "first" bias. The self-test also writes over this address as
    // part of its sweep, but a genuinely stuck CPU never writes anywhere
    // again once parked, so the value naturally settles on the true final
    // answer with no risk of a stale early hit.
    output reg [15:0]   exc_code_ram,

    // pc_snapshot_addr/word: a ONE-SHOT snapshot of last_fetch_addr/
    // last_fetch_data (see the block comment at that always block), taken
    // the instant poll_armed first goes high (~5s after hard reset, the
    // same settle delay poll_region already uses -- reused directly, no new
    // timer). Answers "where is the CPU's PC, right now, in steady state?"
    // directly, with none of the pitfalls that sank exc_vec/exc_fetch_addr:
    // those latched on the FIRST read matching an address range, which the
    // power-on RAM self-test satisfies incidentally while sweeping every RAM
    // address including the vector table (see the ROM CROSS-CHECK and "ROM
    // fetch path cleared" retractions in AGENTS.md). This instead freezes on
    // a fixed TIME, completely independent of which address is touched --
    // if the CPU is genuinely parked in a repeating loop by 5s in (which
    // every established finding this session points toward: it fetches
    // forever, is deterministic across reboots, and never reaches any
    // recorded milestone), the snapshot lands on some instruction inside
    // that loop and reveals exactly where it is.
    output reg [23:0]   pc_snapshot_addr,
    output reg [15:0]   pc_snapshot_word,

    // pc_stable: is the CPU's PC in the SAME place ~10s after reset as it
    // was at the ~5s pc_snapshot_addr/word point? A single sample can't
    // distinguish a genuine repeating loop (matches every established
    // finding: deterministic across reboots, fetches forever) from the CPU
    // merely resting at 0x336BAC once and never being seen there again.
    // A second, later snapshot answers that directly: equal means a fixed
    // loop; different means the PC is roaming (e.g. cycling through
    // unmapped space via repeated line-F exceptions with an uninitialised
    // vector). See pc_snapshot2_addr/word below for the mechanism. Kept as
    // a single bit for now to fit the existing on-screen rows without a
    // layout change; if this reads "different", a follow-up build can
    // expose the full second snapshot the same way pc_snapshot_addr/word
    // already work.
    output              pc_stable,

    // vecC_hi/vecC_lo: live mirror of RAM[0x2C:0x2F], the line-F (vector 11)
    // exception vector table entry -- the 32-bit address a line-F fault
    // would actually jump to right now. See the detailed comment at the
    // implementation below (near EXC_CODE_WORD/VEC_LINEF_HI_WORD).
    output reg [15:0]   vecC_hi,
    output reg [15:0]   vecC_lo,

    // LVBL from sftm_video — used for the DIPS vblank status bit (bit 2,
    // active-low: 1=active display, 0=in vertical blank).
    input               LVBL
);

// Memory map (verified against MAME itech32.cpp `itech020_map`).
// Values are the high address bits used for coarse decode.
// ---------------------------------------------------------------------------
// 0x000000-0x007FFF   main RAM
// 0x080000            P1 input / int1 ack
// 0x100000            P2 input
// 0x180000            P3 input / extra
// 0x200000            system / service
// 0x280000            DIP switches
// 0x300003            colour latch[0] — fg bank (sftm: init_sftm_common overrides base map)
// 0x380003            colour latch[1] — bg bank
// 0x400000            watchdog
// 0x480001            sound data write (to 6809)
// 0x500000-0x5000FF   IT42 video/blitter registers
// 0x578000-0x57FFFF   reads as 0 (touched by protection)
// 0x580000-0x59FFFF   palette RAM
// 0x600000-0x61FFFF   NVRAM
// 0x680002            protection result (main RAM byte @ 0x7A6A)
// 0x700002            plane enable / GROM bank latch
// 0x800000-0xBFFFFF   program ROM
// ---------------------------------------------------------------------------

localparam [7:0] REG_INP0 = 8'h08, // >>16 of 0x080000
                 REG_INP1 = 8'h10,
                 REG_INP2 = 8'h18,
                 REG_SYS  = 8'h20,
                 REG_DIP  = 8'h28,
                 REG_COL1 = 8'h30,
                 REG_COL0 = 8'h38,
                 REG_WDOG = 8'h40,
                 REG_SND  = 8'h48,
                 REG_VIDEO= 8'h50,
                 REG_PAL  = 8'h58,
                 REG_NVRAM= 8'h60,
                 REG_PROT = 8'h68,
                 REG_PLANE= 8'h70;

// ---------------------------------------------------------------------------
// Watchdog timer: fires unconditionally 30 s after every reset.
//
// Design rationale: the itech32 factory-reset path writes NVRAM defaults then
// deliberately spins WITHOUT kicking the watchdog — it expects a forced reset
// from the watchdog chip so the game can re-boot with valid NVRAM.  An
// arm-after-first-kick design would never fire in that path, leaving the CPU
// stuck forever.  The 30 s window covers the longest expected startup time:
//   - boot-vector FSM:   < 1 ms
//   - ROM init/RAM test: ~ 5 s  (300 frames @ 60 fps)
//   - factory reset:     < 5 s  (NVRAM default writes)
// After the first legitimate main-loop kick the counter resets and any
// subsequent 30 s silence triggers another soft reset (hung-game safety net).
//
// w_rst: OR'd with rst; resets all CPU-side logic (boot FSM, cpu_ipl, etc.)
// but NOT the NVRAM BRAM (sftm_ram has no rst pin), so NVRAM survives.
// ---------------------------------------------------------------------------
reg  [30:0] wdog_cnt;   // 31-bit: 1440M-cycle timeout = ~30 s @ 48 MHz
reg         wdog_rst;
wire        w_rst = rst | wdog_rst;

// ---------------------------------------------------------------------------
// TG68K.C kernel signals
// ---------------------------------------------------------------------------
wire [31:0] cpu_a;
wire [15:0] cpu_din, cpu_do16;
wire [ 1:0] busstate;
wire        cpu_wr_n;
// TG68KdotC_Kernel busstate encoding (from VHDL source):
//   00 = fetch code (instruction read)
//   10 = read data
//   11 = write data  ← nWr=0 here; MUST include for cpu_write/vreg_cs/pal_cs writes
//   01 = no mem access (idle)
wire        bus_active = busstate != 2'b01;  // any memory access (read or write)
wire        bus_rd     = busstate == 2'b00 || busstate == 2'b10; // reads only
wire        cpu_write  = cen & bus_active & ~cpu_wr_n & (~cpu_uds_n | ~cpu_lds_n);
wire        low_byte_we  = ~cpu_lds_n;
wire        high_byte_we = ~cpu_uds_n;
reg  [ 2:0] cpu_ipl;

// Interrupt latch and timer — declared here to avoid iverilog forward-reference
// errors from the `assign vint_latch_out = vint_latch` on the next line.
reg         vint_latch;
reg  [ 6:0] vint_timer;  // counts down in clkena cycles after vblank_irq

// Reset-time boot copy: the 020 fetches its reset SSP/PC from 0x000000, which
// is RAM here. MAME's init_program_rom copies the first 0x80 bytes of program
// ROM into main RAM; we do the same before releasing the CPU from reset.
//
// IPL / AUTOVECTOR MAPPING (itech32 LINC chip → TG68K IPL_autovector=1):
//   CORRECTED per MAME src/mame/itech/itech32.cpp (itech32_state::update_interrupts,
//   itech32_state::sftm() machine config, itech32_state::machine_start()):
//     m_maincpu->set_input_line(1 + m_irq_base, vint);  // VINT  = vblank
//     m_maincpu->set_input_line(2 + m_irq_base, xint);  // XINT  = blitter
//     m_maincpu->set_input_line(3 + m_irq_base, qint);  // QINT  = scanline
//   m_irq_base defaults to 0 in itech32_state::machine_start() and is ONLY
//   overridden (to 2) by drivedge_state::machine_reset() for Driver's Edge.
//   sftm() uses the base itech32_state class (see GAME(sftm,...) in
//   itech32.cpp), so m_irq_base stays 0 for Street Fighter: The Movie:
//     VINT (vblank)  → CPU input line 1 → IPL1 → autovector 25 → 0x64
//     XINT (blitter) → CPU input line 2 → IPL2 → autovector 26 → 0x68
//     QINT (scanline)→ CPU input line 3 → IPL3 → autovector 27 → 0x6C
//   vblank and blitter are SEPARATE IPL levels, not shared. Previous notes in
//   this file claimed the disassembled ISR at 0x00801380 (L2/0x68 target) was
//   "the real VBlank ISR" and collapsed vblank+blitter onto IPL2 — that is
//   inconsistent with MAME's authoritative driver mapping above and is the
//   suspected root cause of the CPU never taking the FPGA-asserted interrupt
//   (confirmed on hardware: MAGENTA = ipl_asserted_ever & ~isr_vec_fetch_ever).
//   0x00801380 is very likely the XINT/blitter ISR, not vblank; whatever lives
//   at 0x00800918 (L1/0x64) is the real vblank ISR, not an "unused NMI stub".
reg  [ 4:0] boot_lw;                     // 0..31 long-word index (32*4 = 0x80)
reg         boot_half;                   // 0 = high word, 1 = low word
reg         boot_done;                   // copy finished, CPU may run
reg         boot_cs;                     // rom_cs during boot (toggled per LW)
reg         cpu_rom_gap;                 // 1-cycle rom_cs low gap on CPU ROM addr change
reg  [17:0] cpu_rom_addr_last;           // last CPU ROM long-word address presented to bcache

assign cpu_addr     = cpu_a[23:1];
assign cpu_dout     = cpu_do16;
assign cpu_rnw      = cpu_wr_n;
assign vint_latch_out = vint_latch;

// clock enable is gated by "bus ready": on ROM accesses wait for rom_ok, and
// the CPU stays held until the boot vector copy has finished.
// cpu_rom_gap also stalls: when we force rom_cs low for the bcache edge, we
// must keep clkena=0 so the CPU does not advance with stale rom_data.
wire   bus_busy = (rom_cs & ~rom_ok) | cpu_rom_gap;
wire   clkena   = cen & ~bus_busy & boot_done;

// ---------------------------------------------------------------------------
// Coarse address decode
// ---------------------------------------------------------------------------
wire [7:0] ahi = cpu_a[23:16];
reg        ram_cs, inp_cs, dip_cs, sys_cs, nvram_cs;
reg        prot_cs, nopr_cs, duart_cs;
reg        prog_sel;

always @(*) begin
    ram_cs   = cpu_a[23:15]==9'h000;        // 0x000000-0x007fff main RAM
    prog_sel = cpu_a[23:22]==2'b10;         // 0x800000-0xbfffff program ROM
    inp_cs   = ahi==REG_INP0 || ahi==REG_INP1 || ahi==REG_INP2;
    sys_cs   = ahi==REG_SYS;
    dip_cs   = ahi==REG_DIP;
    vreg_cs  = bus_active && cpu_a[23:8]==16'h5000;
    pal_cs   = bus_active && cpu_a[23:17]==7'h2c; // 0x580000-0x59ffff
    vram_cs  = 1'b0;                         // VRAM is accessed via VIDEO_TRANSFER
    nvram_cs = cpu_a[23:17]==7'h30;          // 0x600000-0x61ffff NVRAM
    prot_cs  = cpu_a[23:1]==23'h34_0001;     // 0x680002 protection result byte
    nopr_cs  = cpu_a[23:15]==9'h0af;         // 0x578000-0x57ffff reads as 0
    // 0x680800-0x68083f: Serial DUART Channel A/B & Top LED sign.
    // MAME's itech020_map decodes this exact range as
    // map(0x680800,0x68083f).readonly().nopw() -- a plain, zero-initialised,
    // read-only backing store (MAME zero-fills auto-allocated RAM regions;
    // no ROM/init data is loaded here). Writes are ignored (.nopw()).
    // Our FPGA previously had NO decode for this range at all, so reads
    // fell through to the catch-all default of 16'hffff (all status/ready
    // bits appearing permanently SET). If the ROM's boot code polls a
    // DUART status/ready bit here waiting for it to go low before it will
    // proceed to enable real (IPL1/2/3) interrupts, an all-1s read would
    // make that poll loop forever on every single boot -- deterministically,
    // regardless of NVRAM state or how many times the watchdog reboots the
    // CPU. Decode it explicitly and return 16'h0000 to match MAME exactly.
    duart_cs = cpu_a[23:6]==18'h1_A020;      // 0x680800-0x68083f
end

// The ROM port is driven by the boot-copy FSM until boot_done, then the CPU.
// jtframe_romrq_bcache works best when addr_ok/CS goes low→high for every new
// address.  The boot FSM pulses boot_cs between long-words.  The CPU path also
// forces a 1-cycle low gap when the CPU changes the ROM long-word address while
// remaining in ROM space; otherwise sequential instruction fetches can reuse
// stale cached data from the previous address and execute garbage.
// Use bus_rd (reads only) — ROM is read-only; don't stall on writes to ROM space.
assign rom_cs   = boot_done ? ((prog_sel & bus_rd) & ~cpu_rom_gap) : boot_cs;
assign rom_addr = boot_done ? cpu_a[19:2]              // CPU access
                            : { 13'd0, boot_lw };

// 32-bit program ROM → 16-bit halves for TG68K (big-endian 68020).
// jtframe_dwnld SWAB=0 stores the ROM little-endian (prom0=D[7:0] first):
//   SDRAM[N]   = {D[15:8], D[7:0]}  (burst word 0 → bcache [15:0])
//   SDRAM[N+1] = {D[31:24], D[23:16]} (burst word 1 → bcache [31:16])
// So rom_data = {D[31:16], D[15:0]}: the full big-endian 32-bit ROM value.
// cpu_a[1]=0: upper word (MSW) = rom_data[31:16]; cpu_a[1]=1: lower = [15:0].
wire [15:0] rom_half = cpu_a[1] ? rom_data[15:0] : rom_data[31:16];

// ---------------------------------------------------------------------------
// Main RAM: 0x000000-0x007fff = 32 KB (16K x 16). The write port is shared
// with the reset-time boot copy (the CPU is held in reset until boot_done).
// ---------------------------------------------------------------------------
wire [15:0] ram_dout;
// Boot copy ROM-to-RAM data selector.
//
// LW0 (SSP=$00008000) and LW1 (PC=$00800400) are hardcoded to bypass any
// SDRAM byte-ordering uncertainty for the critical reset vectors.
// Values derived from the actual SFTM v1.12 ROM chip contents:
//   SSP = $00008000 — top of 32 KB main RAM (first push → $7FFE)
//   PC  = $00800400 — first real code instruction, just past the 1 KB
//                    exception vector table at $800000-$8003FF
//
// LW2..31 still come from ROM (exception vectors for ISR dispatch).
// The condition boot_lw[4:1]==0 covers LW0 and LW1; all other LWs use
// the ROM-sourced word.
wire [15:0] boot_word_rom = boot_half ? rom_data[15:0] : rom_data[31:16];
wire [15:0] boot_word_hc  =
    ({boot_lw[0],boot_half} == 2'b00) ? 16'h0000 :  // SSP[31:16] = $0000
    ({boot_lw[0],boot_half} == 2'b01) ? 16'h8000 :  // SSP[15:0]  = $8000  (was $7FFE)
    ({boot_lw[0],boot_half} == 2'b10) ? 16'h0080 :  // PC[31:16]  = $0080
                                         16'h0400;   // PC[15:0]   = $0400  (was $0008)
wire [15:0] boot_word = (boot_lw[4:1] == 4'd0) ? boot_word_hc : boot_word_rom;
wire        boot_we   = ~boot_done & rom_ok;        // write both lanes

wire [13:0] ram_addr  = boot_done ? cpu_a[14:1] : { 8'd0, boot_lw, boot_half };
wire [15:0] ram_din   = boot_done ? cpu_dout    : boot_word;
wire        ram_we_lo = boot_done ? (cpu_write & ram_cs & low_byte_we ) : boot_we;
wire        ram_we_hi = boot_done ? (cpu_write & ram_cs & high_byte_we) : boot_we;

sftm_ram #(.AW(14)) u_ram(
    .clk    ( clk       ),
    .addr   ( ram_addr  ),
    .din    ( ram_din   ),
    .we_lo  ( ram_we_lo ),
    .we_hi  ( ram_we_hi ),
    .dout   ( ram_dout  )
);

// exc_code_ram: see the port comment above. Gated on a full-word write
// (both lanes together, matching the ROM's MOVE.W) so a stray byte write
// elsewhere can never merge a stale half into the reported value. Gating
// on boot_done is belt-and-braces, not load-bearing: the boot-copy FSM's
// own address range (LW0..31, ram_addr up to 14'h003F) never reaches
// EXC_CODE_WORD, but the check documents that intent explicitly.
localparam [13:0] EXC_CODE_WORD = 14'h07DF; // byte 0x0FBE >> 1
always @(posedge clk) begin
    if( rst )
        exc_code_ram <= 16'd0;
    else if( boot_done && ram_we_lo && ram_we_hi && ram_addr == EXC_CODE_WORD )
        exc_code_ram <= ram_din;
end

// vecC_hi/vecC_lo: live mirror of the line-F (vector 11) exception vector
// table entry, byte address 0x2C-0x2F (a 32-bit jump target address, split
// across word addresses 0x16/0x17 the same way TG68K's 16-bit external bus
// would write it as two separate word cycles for one CPU-side MOVE.L).
//
// This vector is INSIDE the boot-copy FSM's range (LW0-31, ram_addr up to
// 14'h003F -- LW11 = byte 0x2C = word addrs 0x16/0x17), so boot_done
// correctly starts RIGHT after the boot FSM has copied the ROM's own
// line-F vector into RAM (the same mechanism that gives the correct reset
// SSP/PC). Per the ROM CROSS-CHECK disassembly, the ROM's real vector 8/10/
// 11 handler lives at 0x8008F8 -- if this reads that, the vector was copied
// correctly and something else is wrong; if it reads anything else
// (especially something resembling the unmapped region pc_snapshot_addr
// found the CPU roaming in), the most likely explanation is the power-on
// RAM self-test's own write sweep (0x80158A, MOVE.L-per-iteration across
// all 32KB) clobbering the vector table on its way through low RAM -- the
// same mechanism already proven to have produced two prior false positives
// (see the ROM CROSS-CHECK / "ROM fetch path cleared" retractions), just
// now checked directly instead of inferred. Gated identically to
// exc_code_ram (full-word write only, boot_done islands out the boot-copy
// FSM's own legitimate initial write) so this shows the CURRENT value --
// exactly what a fault taken right now would actually jump to.
localparam [13:0] VEC_LINEF_HI_WORD = 14'h0016; // byte 0x2C >> 1
localparam [13:0] VEC_LINEF_LO_WORD = 14'h0017; // byte 0x2E >> 1
always @(posedge clk) begin
    if( rst ) begin
        vecC_hi <= 16'd0;
        vecC_lo <= 16'd0;
    end else if( boot_done && ram_we_lo && ram_we_hi ) begin
        if( ram_addr == VEC_LINEF_HI_WORD ) vecC_hi <= ram_din;
        if( ram_addr == VEC_LINEF_LO_WORD ) vecC_lo <= ram_din;
    end
end

// ---------------------------------------------------------------------------
// NVRAM: 0x600000-0x61ffff is a 128 KB battery-backed region on the real
// board. Only 32 KB is backed here (MiSTer's NVRAM dump must stay < 64 KB and
// the game uses only a small part); the upper region aliases down.
// TODO: size to the actual used range and add JTFRAME persistence via a
// bram:{ ioctl:{ save:true } } entry once JTFRAME is vendored.
// ---------------------------------------------------------------------------
wire [15:0] nvram_dout;
wire        nvram_we_lo = cpu_write & nvram_cs & low_byte_we;
wire        nvram_we_hi = cpu_write & nvram_cs & high_byte_we;

always @(posedge clk) begin
    if( rst ) nvram_wr_ever <= 1'b0;
    // Repurposed as ram_wr_ever: latches first CPU write to main RAM after boot.
    // The game init code clears RAM immediately after boot, so this fires as soon
    // as the CPU is executing real code (not stalled on first ROM fetch).
    else if( boot_done && cpu_write && ram_cs ) nvram_wr_ever <= 1'b1;
end

// NVRAM pre-loaded from MAME: valid bookkeeping data so game skips factory
// reset and goes directly to attract mode.  Paths are relative to the
// Quartus project directory (cores/sftm/mister/) → reach into hdl/.
sftm_ram #(.AW(14),
           .INIT_FILE_HI("../hdl/nvram_hi.hex"),
           .INIT_FILE_LO("../hdl/nvram_lo.hex")) u_nvram(
    .clk    ( clk         ),
    .addr   ( cpu_a[14:1] ),
    .din    ( cpu_dout    ),
    .we_lo  ( nvram_we_lo ),
    .we_hi  ( nvram_we_hi ),
    .dout   ( nvram_dout  )
);

// ---------------------------------------------------------------------------
// Protection: 0x680002 returns a main-RAM byte (MAME itech020_prot_result_r).
// sftm_prot snoops CPU writes to that address (0x7a6a) and latches the byte.
// ---------------------------------------------------------------------------
wire [7:0] prot_byte;

sftm_prot u_prot(
    .clk    ( clk         ),
    .rst    ( rst         ),
    .wr_addr( cpu_a[14:1] ),
    .we_hi  ( cpu_write & ram_cs & high_byte_we ),
    .din    ( cpu_dout    ),
    .result ( prot_byte   )
);

// prot_wr_ever / prot_rd_ever: see port comments above. Mirror the exact
// address/strobe combination fed into u_prot (wr_addr==PROT_WORD && we_hi)
// for the write side; the read side reuses prot_cs (already decodes
// 0x680002 exactly) qualified by cen & bus_rd, the same convention used by
// vec_isr_read/ipl7_vec_read elsewhere in this file.
wire prot_word_wr = (cpu_write & ram_cs & high_byte_we) & (cpu_a[14:1] == 14'h3d35);
wire prot_word_rd = cen & bus_rd & prot_cs;

always @(posedge clk) begin
    if( rst )                  prot_wr_ever <= 1'b0;
    else if( prot_word_wr )    prot_wr_ever <= 1'b1;
end

always @(posedge clk) begin
    if( rst )                  prot_rd_ever <= 1'b0;
    else if( prot_word_rd )    prot_rd_ever <= 1'b1;
end

// prot_rd_count: edge-detected saturating counter. prot_word_rd is a LEVEL
// (holds true across every cen tick for the duration of one CPU access), so
// we sample it into prot_rd_lvl_d each clk and only count RISING edges --
// exactly one count per distinct read access, regardless of how many clk/cen
// ticks that access internally spans. See port comment above for the 0..3
// saturating meaning.
reg prot_rd_lvl_d;
always @(posedge clk) begin
    if( rst ) prot_rd_lvl_d <= 1'b0;
    else      prot_rd_lvl_d <= prot_word_rd;
end
wire prot_rd_edge = prot_word_rd & ~prot_rd_lvl_d;

always @(posedge clk) begin
    if( rst )                                      prot_rd_count <= 2'd0;
    else if( prot_rd_edge && prot_rd_count != 2'd3 ) prot_rd_count <= prot_rd_count + 2'd1;
end

// post_wr_fetch_count: edge-detected saturating counter of instruction
// fetches strictly AFTER the protection write (prot_wr_ever) has latched.
// Same LEVEL-vs-EDGE caveat as prot_rd_count above applies to the fetch bus
// state, so it is sampled and edge-detected the identical way. See port
// comment above for the 0..3 saturating meaning.
wire cpu_fetch_lvl = cen & (busstate == 2'b00);
reg  cpu_fetch_lvl_d;
always @(posedge clk) begin
    if( rst ) cpu_fetch_lvl_d <= 1'b0;
    else      cpu_fetch_lvl_d <= cpu_fetch_lvl;
end
wire cpu_fetch_edge = cpu_fetch_lvl & ~cpu_fetch_lvl_d;

always @(posedge clk) begin
    if( rst )                                                              post_wr_fetch_count <= 2'd0;
    else if( prot_wr_ever && cpu_fetch_edge && post_wr_fetch_count != 2'd3 ) post_wr_fetch_count <= post_wr_fetch_count + 2'd1;
end

// ---------------------------------------------------------------------------
// poll_region: WHICH hardware region is the stuck CPU reading?
//
// State of knowledge going in: the CPU writes the protection byte, keeps
// executing instructions indefinitely (post_wr_fetch_count saturates), never
// reaches the watchdog kick or the protection read, and runs with interrupts
// masked the whole time (confirmed by the forced-IPL7 probe). So it is
// sitting in a spin loop -- and because interrupts are masked, that loop
// CANNOT be waiting on an ISR to set a flag. It must either be polling a
// hardware register that never returns the value it wants, or spinning
// purely in RAM/ROM (a delay loop, or a crash loop on garbage).
//
// This probe distinguishes those cases and, if it is polling, identifies the
// region. Method: wait POLL_SAMPLE_DELAY (~5 s -- long after everything has
// settled into steady state, and well past the ~20-30 s watchdog transition
// being irrelevant here since this latches on hard rst only), then capture
// the region of the FIRST qualifying I/O data read and FREEZE forever.
// Sample-and-hold rather than "most recent" deliberately: a steady-state
// loop repeats, so the first hit after the sample point is representative,
// and freezing avoids a value that oscillates between regions and would make
// the flash count unreadable.
//
// Only DATA reads qualify (busstate==2'b10), never instruction fetches
// (2'b00) -- fetches stream through ROM constantly and would tell us nothing
// about what the loop is inspecting. Main RAM and program ROM are
// deliberately EXCLUDED from the region list for the same reason: stack and
// variable traffic is constant background noise. Codes are priority-encoded,
// though in practice at most one select is active in any single cycle.
//   1 = none captured -- no I/O read at all in the window. CPU is spinning
//       purely in RAM/ROM, touching no hardware register: points at a delay
//       loop or a crash loop on garbage rather than a failed handshake.
//   2 = vreg_cs   (0x500000-0x5000ff video/CRTC registers)  <-- prime suspect:
//       a "wait for vblank/scanline by polling" loop, which is exactly what
//       boot code would use while interrupts are still masked. If our video
//       register read-back never presents the bit the code waits on, it spins
//       forever -- and that would explain every symptom observed so far.
//   3 = inp_cs / sys_cs / dip_cs (inputs, system, DIP switches)
//   4 = duart_cs  (0x680800-0x68083f sound-CPU comms) -- a sound handshake
//       that never completes.
//   5 = nvram_cs  (0x600000-0x61ffff)
//   6 = pal_cs / nopr_cs (palette, read-as-zero region)
//   7 = prot_cs   (0x680002) -- sanity check only; prot_rd_ever is already
//       hardware-confirmed 0, so this should never appear.
localparam [27:0] POLL_SAMPLE_DELAY = 28'd240_000_000; // ~5 s at 48 MHz
reg [27:0] poll_dly_cnt;
wire       poll_armed = poll_dly_cnt == POLL_SAMPLE_DELAY;
always @(posedge clk) begin
    if( rst )              poll_dly_cnt <= 28'd0;
    else if( !poll_armed ) poll_dly_cnt <= poll_dly_cnt + 28'd1;
end

// Data read only (busstate 2'b10), never an instruction fetch (2'b00).
// Edge-detected on the RAW bus state, deliberately NOT gated on cen: the read
// bus state holds for multiple cycles per access, so a cen-gated level would
// produce several pulses for a SINGLE access -- which would let one access
// falsely satisfy the "two consecutive reads" confirmation filter below and
// defeat its entire purpose. Detecting the transition INTO the read state
// yields exactly one pulse per actual read access.
wire poll_rd_lvl = (busstate == 2'b10);
reg  poll_rd_lvl_d;
always @(posedge clk) begin
    if( rst ) poll_rd_lvl_d <= 1'b0;
    else      poll_rd_lvl_d <= poll_rd_lvl;
end
wire poll_rd = poll_rd_lvl & ~poll_rd_lvl_d;

// Combinational region decode of the address currently being read. 0 means
// "not one of the watched I/O regions" (i.e. main RAM or program ROM), which
// is ignored entirely rather than latched.
reg [2:0] rd_code;
always @(*) begin
    if     ( vreg_cs                  ) rd_code = 3'd1;
    else if( inp_cs | sys_cs | dip_cs ) rd_code = 3'd2;
    else if( duart_cs                 ) rd_code = 3'd3;
    else if( nvram_cs                 ) rd_code = 3'd4;
    else if( pal_cs | nopr_cs         ) rd_code = 3'd5;
    else if( prot_cs                  ) rd_code = 3'd6;
    else                                rd_code = 3'd0;
end

// Confirmation filter: require TWO CONSECUTIVE qualifying I/O reads hitting
// the SAME region before latching, rather than trusting a single hit. This
// matters because the watchdog appears to reboot the system repeatedly (that
// is why the ORANGE state persists), so boot code re-runs periodically and a
// single-instant sample could land on incidental start-up traffic instead of
// the spin loop. A genuine polling loop reads its one register over and over,
// so it satisfies this trivially; a boot sequence stepping through different
// regions does not. Intervening RAM/ROM accesses (rd_code==0) are skipped
// rather than breaking the run, since a realistic poll loop interleaves
// register reads with stack/variable traffic.
reg [2:0] poll_cand;
always @(posedge clk) begin
    if( rst ) begin
        poll_region <= 3'd0;
        poll_cand   <= 3'd0;
    end else if( poll_armed && poll_region == 3'd0 && poll_rd && rd_code != 3'd0 ) begin
        if( rd_code == poll_cand ) poll_region <= rd_code; // confirmed, freeze
        else                       poll_cand   <= rd_code; // first sighting
    end
end

// ---------------------------------------------------------------------------
// exc_vec: WHICH exception vector did the CPU fetch, if any?
//
// Hardware has now established that in steady state the CPU performs NO I/O
// data reads whatsoever (poll_region==0) while still fetching instructions
// indefinitely, with interrupts masked, never reaching the watchdog kick or
// the protection read. A loop that touches no hardware register at all is
// very characteristic of a catch-all exception handler -- classically a
// branch-to-self -- or of executing garbage. Note a tight `BRA.S *` self-loop
// performs instruction fetches but zero data reads, matching the observations
// exactly.
//
// So: did the CPU take an exception, and which one? On a 68k the vector table
// lives at byte 0x000-0x3FF (in main RAM here), and vector N is fetched by
// READING byte address 4*N. Boot code WRITES its handlers there, but writes
// are ignored here -- only reads qualify, and a read of that region is
// ROM-content-independent proof that the CPU began exception processing for
// that specific vector. Vectors 0/1 (reset SSP/PC) are excluded since those
// are fetched legitimately at power-on.
//
// BIT-INDEXING HAZARD (caught by tb_excvec, first attempt was wrong): cpu_addr
// is declared `[23:1]`, so although its VALUE is a word address (numerically
// byte_addr>>1, which is why the existing numeric comparisons like
// `cpu_addr==23'h32` for byte 0x64 are correct), its BIT INDICES are the
// literal cpu_a bit positions -- cpu_addr[9] IS cpu_a[9], NOT cpu_a[10].
// So the vector number is cpu_addr[9:2] (== cpu_a[9:2]), and byte address
// < 0x400 is cpu_addr[23:10]==0. Slicing [8:1] instead (the natural mistake
// if you assume the range were [22:0]) yields 2*N and silently misclassifies
// every single vector.
// Sample-and-hold on the FIRST qualifying fetch, then frozen, so we capture
// the ORIGINAL fault rather than whatever it may cascade into. Categories are
// grouped to fit the 1..7 flash range:
//   1 = bus error (vector 2) -- access to an address that does not respond.
//       Would point straight at our own address decoding/SDRAM handling.
//   2 = address error (vector 3) -- misaligned word/long access. Often means
//       the CPU is executing garbage, or a corrupted pointer/stack.
//   3 = illegal instruction (vector 4) -- executing data as code: a wild jump
//       or a corrupted vector/pointer.
//   4 = privilege violation / line-A / line-F (vectors 8, 10, 11) -- also
//       typical of executing garbage, or a 68020-specific opcode our TG68K
//       core does not implement.
//   5 = other exception (5,6,7,9,12-23,32+) -- zero divide, CHK, TRAPV,
//       trace, TRAP #n, etc.
//   6 = interrupt autovector (24-31) -- an interrupt actually being serviced.
//       Expected to be 0 here given interrupts are masked; would be
//       informative if it appeared.
//   0 = no exception vector ever fetched -- the CPU never faulted at all, so
//       the loop is reached by NORMAL program flow. That would make it a
//       deliberate wait/delay loop rather than a crash, and shift suspicion
//       onto whatever condition the code expects something else to change.
// last_fetch_ff: was the most recently fetched instruction word 0xFFFF?
//
// This matters because the CPU data-in mux above ends in
// `default: inp_mux = 16'hffff`, so ANY read of an unmapped address returns
// 0xFFFF -- and 0xFFFF is itself a line-F opcode. That gives a very specific
// and very likely failure mode: if the CPU jumps into unmapped address space,
// every instruction fetch returns 0xFFFF and it immediately takes a line-F
// exception (vector 11). Distinguishing that from a genuine line-F opcode
// inside real code is exactly what separates "our address decoding is wrong /
// the CPU ran off into nothing" from "the game legitimately uses a
// coprocessor instruction TG68K lacks".
//
// Sampled on clkena, which is the exact tick the CPU consumes data_in, and
// only during instruction fetches (busstate==2'b00).
//
// HONEST CAVEAT: the 68k prefetches, and between the faulting opcode and the
// vector read the CPU may fetch further words and push a stack frame. So this
// is strictly "was the LAST fetch before the fault 0xFFFF", not a guaranteed
// capture of the exact faulting word. That is fine for the hypothesis being
// tested: if the CPU is executing in unmapped space then ALL nearby fetches
// return 0xFFFF, so the flag holds regardless of prefetch timing. A single
// stray line-F opcode inside otherwise-valid code could in principle read
// either way, so treat 0xFFFF as strong evidence FOR the unmapped theory but
// non-0xFFFF as only weak evidence against it.
reg last_fetch_ff;
reg [23:0] last_fetch_addr;
reg [15:0] last_fetch_data;
always @(posedge clk) begin
    if( rst ) begin
        last_fetch_ff   <= 1'b0;
        last_fetch_addr <= 24'd0;
        last_fetch_data <= 16'd0;
    end else if( clkena && busstate == 2'b00 ) begin
        last_fetch_ff   <= (cpu_din == 16'hffff);
        last_fetch_addr <= { cpu_addr, 1'b0 };  // word addr -> byte addr
        last_fetch_data <= cpu_din;
    end
end
assign exc_last_ff = last_fetch_ff;

// pc_snapshot_addr/word: see the port comment above. poll_armed is defined
// later in this file (the poll_region block) but is a plain wire, so the
// forward reference is fine. One-shot: only the transition of poll_armed
// 0->1 is captured (guarded by pc_snap_done), not held live -- last_fetch_*
// updates on every single instruction fetch (i.e. every few CPU cycles),
// far faster than the ~60Hz video scan-out, so a live (non-snapshotted)
// display of it would tear/flicker within a single on-screen row as the
// value changed mid-scanline. Freezing once gives a stable, readable value.
reg pc_snap_done;
always @(posedge clk) begin
    if( rst ) begin
        pc_snap_done     <= 1'b0;
        pc_snapshot_addr <= 24'd0;
        pc_snapshot_word <= 16'd0;
    end else if( poll_armed && !pc_snap_done ) begin
        pc_snap_done     <= 1'b1;
        pc_snapshot_addr <= last_fetch_addr;
        pc_snapshot_word <= last_fetch_data;
    end
end

// pc_snapshot2_addr/word: a SECOND one-shot snapshot, ~5s after the first
// (own timer, since POLL_SAMPLE_DELAY already sits close to the 28-bit
// counter's ~5.6s ceiling at 48MHz -- 30 bits gives headroom to ~22s).
// Internal only (not a port): only the single-bit comparison below,
// pc_stable, is exposed to keep this round's on-screen display within the
// existing 5 rows. If pc_stable reads "different" on hardware, these two
// registers already exist and a follow-up build can expose them directly
// the same way pc_snapshot_addr/word do.
localparam [29:0] PC_SNAPSHOT2_DELAY = 30'd480_000_000; // ~10s at 48 MHz
reg [29:0] pc_snap2_dly_cnt;
wire       pc_snap2_armed = pc_snap2_dly_cnt == PC_SNAPSHOT2_DELAY;
always @(posedge clk) begin
    if( rst )                   pc_snap2_dly_cnt <= 30'd0;
    else if( !pc_snap2_armed )  pc_snap2_dly_cnt <= pc_snap2_dly_cnt + 30'd1;
end

reg        pc_snap2_done;
reg [23:0] pc_snapshot2_addr;
reg [15:0] pc_snapshot2_word;
always @(posedge clk) begin
    if( rst ) begin
        pc_snap2_done     <= 1'b0;
        pc_snapshot2_addr <= 24'd0;
        pc_snapshot2_word <= 16'd0;
    end else if( pc_snap2_armed && !pc_snap2_done ) begin
        pc_snap2_done     <= 1'b1;
        pc_snapshot2_addr <= last_fetch_addr;
        pc_snapshot2_word <= last_fetch_data;
    end
end

// pc_stable: see the port comment above. Requires BOTH snapshots to have
// completed before it can read 1 -- by the time the on-screen display is
// actually observed (many seconds into the persistent stuck state), both
// will certainly be done, so this is not a source of ambiguity in practice.
assign pc_stable = pc_snap_done && pc_snap2_done
                  && (pc_snapshot_addr == pc_snapshot2_addr)
                  && (pc_snapshot_word == pc_snapshot2_word);

wire      exc_vec_rd  = poll_rd & (cpu_addr[23:10] == 14'd0) & (cpu_addr[9:2] >= 8'd2);
always @(posedge clk) begin
    if( rst ) begin
        exc_vec        <= 3'd0;
        exc_detail     <= 3'd0;
        exc_vec_num    <= 8'd0;
        exc_fetch_addr <= 24'd0;
        exc_fetch_word <= 16'd0;
    end else if( exc_vec == 3'd0 && exc_vec_rd ) begin
        exc_vec_num    <= cpu_addr[9:2];   // exact vector number
        // Freeze where the CPU was executing when it faulted. This is the
        // single most valuable datum remaining: it distinguishes a wild jump
        // into ROM data, execution out of RAM, and execution in unmapped
        // space from one another.
        exc_fetch_addr <= last_fetch_addr;
        exc_fetch_word <= last_fetch_data;
        // exc_detail: finer-grained follow-up encoding, now that hardware has
        // narrowed the fault to the 8/10/11 group. Splits that group into its
        // individual vectors AND tests the unmapped-fetch theory in the same
        // build, so no extra hardware round trip is needed.
        case( cpu_addr[9:2] )
            8'd8:  exc_detail <= 3'd1;                       // privilege violation
            8'd10: exc_detail <= 3'd2;                       // line-A
            8'd11: exc_detail <= last_fetch_ff ? 3'd3 : 3'd4; // line-F, split by 0xFFFF
            8'd4:  exc_detail <= 3'd5;                       // illegal instruction
            default: exc_detail <= 3'd6;                     // any other vector
        endcase
        case( cpu_addr[9:2] )
            8'd2:                   exc_vec <= 3'd1; // bus error
            8'd3:                   exc_vec <= 3'd2; // address error
            8'd4:                   exc_vec <= 3'd3; // illegal instruction
            8'd8, 8'd10, 8'd11:     exc_vec <= 3'd4; // privilege / line-A / line-F
            default: begin
                if( cpu_addr[9:2] >= 8'd24 && cpu_addr[9:2] <= 8'd31 )
                                    exc_vec <= 3'd6; // interrupt autovector
                else                exc_vec <= 3'd5; // other exception
            end
        endcase
    end
end

// ---------------------------------------------------------------------------
// CPU data-in mux
// ---------------------------------------------------------------------------
reg [15:0] inp_mux;
always @(*) begin
    case(1'b1)
        prog_sel: inp_mux = rom_half;
        ram_cs:   inp_mux = ram_dout;
        nvram_cs: inp_mux = nvram_dout;
        vram_cs:  inp_mux = vram_dout;
        vreg_cs:  inp_mux = vreg_dout;
        pal_cs:   inp_mux = pal_dout;
        prot_cs:  inp_mux = { prot_byte, 8'hff };
        nopr_cs:  inp_mux = 16'h0000;
        // 0x680800-0x68083f DUART/LED-sign range -- see decode comment above.
        // Matches MAME's zero-initialised readonly() storage.
        duart_cs: inp_mux = 16'h0000;
        inp_cs:   inp_mux = read_inputs(ahi);
        // P4 (0x200000): bits[7:0] active-low all unused (→ lower half, cpu_a[1]=1).
        sys_cs:   inp_mux = cpu_a[1] ? 16'h00FF : 16'h0000;
        // DIPS (0x280000): MAME itech32_base_020 PORT_BIT definitions, bits[7:0]
        // live in the lower 16-bit half (cpu_a[1]=1, byte offsets +2/+3).
        //   bit0 (0x01): test-mode switch     (active-low)
        //   bit1 (0x02): service coin         (active-low)
        //   bit2 (0x04): VBLANK from screen   (active-low: 1=active display, 0=vblank)
        //   bit3 (0x08): special_port_r       (active-high, 0=idle)
        //   bit4 (0x10): Video Sync DIP       (0=standard)
        //   bit5 (0x20): Flip Screen DIP      (0=off)
        //   bit6 (0x40): Unknown DIP          (0=on/default)
        //   bit7 (0x80): Service Mode DIP     (active-high, 0=normal)
        dip_cs:   inp_mux = cpu_a[1] ? { 8'h00,
                                          dipsw_a[7],    // bit7 service-mode DIP (active-high)
                                          dipsw_a[6],    // bit6 unknown DIP
                                          dipsw_a[5],    // bit5 flip-screen DIP
                                          dipsw_a[4],    // bit4 video-sync DIP
                                          1'b0,          // bit3 special_port_r (idle)
                                          LVBL,          // bit2 vblank (1=active disp, 0=vblank)
                                          ~service,      // bit1 service coin
                                          ~dip_test }    // bit0 test-mode switch
                                       : 16'h0000;       // upper half unused
        default:  inp_mux = 16'hffff;
    endcase
end
assign cpu_din = inp_mux;

// Input port reads.
// MAME itech32_base_020 PORT_BIT definitions place all input bits in bits[7:0]
// of the 32-bit port value (= bytes +2/+3, i.e. the LOWER 16-bit half).
// TG68K 16-bit bus: cpu_a[1]=0 → upper half 16'h0000 (unused),
//                   cpu_a[1]=1 → lower half { 8'h00, io_byte }.
// MAME bit layout for P1/P2 (all active-low):
//   bit7=UP  bit6=DN  bit5=LT  bit4=RT  bit3=B2  bit2=B1  bit1=START  bit0=COIN
// JTFRAME joystick convention: [0]=UP [1]=DN [2]=LT [3]=RT [4]=B1 [5]=B2
function [15:0] read_inputs(input [7:0] sel);
    reg [7:0] io;
    begin
        case(sel)
            // P1 (0x080000): UP,DN,LT,RT,B2,B1,START1,COIN1  (all active-low)
            REG_INP0: io = ~{ joystick1[0], joystick1[1], joystick1[2], joystick1[3],
                               joystick1[5], joystick1[4], cab_1p[0],   coin[0] };
            // P2 (0x100000): same layout for player 2
            REG_INP1: io = ~{ joystick2[0], joystick2[1], joystick2[2], joystick2[3],
                               joystick2[5], joystick2[4], cab_1p[1],   coin[1] };
            // P3 (0x180000): all active-high unused per MAME itech32_base_020 P3.
            // sftm extra punch/kick buttons (BTN3-6) may need PORT_MODIFY here
            // once the exact mapping is confirmed against MAME.
            REG_INP2: io = 8'h00;
            default:  io = 8'hFF;
        endcase
        read_inputs = cpu_a[1] ? { 8'h00, io } : 16'h0000;
    end
endfunction

always @(posedge clk) begin
    if( rst ) wdog_kick_ever <= 1'b0;
    else if( cpu_write && ahi==REG_WDOG ) wdog_kick_ever <= 1'b1;
end

// isr_vec_fetch_ever: latches the first time the CPU performs a data READ
// from the autovector 25/26/27 exception vector table entries (word
// addresses 0x32/0x33 = byte $64-$67 [IPL1/vblank], 0x34/0x35 = byte
// $68-$6B [IPL2/blitter], 0x36/0x37 = byte $6C-$6F [IPL3/scanline]). With
// IPL_autovector=1 TG68K.C does not do an external IACK bus cycle -- it
// internally forms the vector number and then reads the 4-byte vector table
// entry from memory the normal way. Seeing any of these addresses on the
// bus during a read cycle is a ROM-content-independent proof that the CPU
// actually recognized IPL1/IPL2/IPL3 and began exception processing (SR
// mask allowed it, IPL held long enough).
wire vec_isr_read = cen & bus_rd &
                     (cpu_addr==23'h32 || cpu_addr==23'h33 ||
                      cpu_addr==23'h34 || cpu_addr==23'h35 ||
                      cpu_addr==23'h36 || cpu_addr==23'h37);
always @(posedge clk) begin
    if( rst ) isr_vec_fetch_ever <= 1'b0;
    else if( vec_isr_read ) isr_vec_fetch_ever <= 1'b1;
end

// ipl_asserted_ever: latches the first time cpu_ipl leaves 3'b111, i.e. the
// FPGA side (vint_latch / blit_irq / scan_irq) asserted an interrupt request
// for at least one clk -- independent of whether the CPU ever actually took
// it. See port comment above for how to interpret this alongside
// isr_vec_fetch_ever.
always @(posedge clk) begin
    if( rst ) ipl_asserted_ever <= 1'b0;
    else if( cpu_ipl != 3'b111 ) ipl_asserted_ever <= 1'b1;
end

// ---------------------------------------------------------------------------
// Diagnostic-only synthetic level-7 (non-maskable) interrupt pulse.
// Fires exactly once, ~1s after reset (48,000,000 clk cycles @ 48 MHz),
// completely independent of vint_latch/blit_irq/scan_irq. Level 7 requests
// cannot be masked out by the CPU's SR interrupt mask (68000/68020 spec),
// so if the CPU is truly alive and cpu_ipl/autovector wiring works, this
// MUST be taken regardless of whatever the real ROM's boot code has done
// to its interrupt mask. Held for the same 100-clkena window as vint_latch
// to guarantee TG68K.C reaches an instruction boundary while it's asserted.
// This logic is diagnostic-only and should be removed once the real bug is
// found -- it does not reflect any real itech32 hardware behaviour.
// ---------------------------------------------------------------------------
reg [27:0] ipl7_dbg_cnt;
reg        ipl7_dbg_fired;
reg        ipl7_pulse;
reg [ 6:0] ipl7_timer;

always @(posedge clk) begin
    if( rst ) begin
        ipl7_dbg_cnt   <= 28'd0;
        ipl7_dbg_fired <= 1'b0;
        ipl7_pulse     <= 1'b0;
        ipl7_timer     <= 7'd0;
        ipl7_pulse_ever<= 1'b0;
    end else begin
        if( !ipl7_dbg_fired ) begin
            ipl7_dbg_cnt <= ipl7_dbg_cnt + 28'd1;
            if( ipl7_dbg_cnt == IPL7_DBG_DELAY ) begin
                ipl7_dbg_fired <= 1'b1;
                ipl7_pulse     <= 1'b1;
                ipl7_timer     <= 7'd100;
                ipl7_pulse_ever<= 1'b1;
            end
        end else if( ipl7_pulse ) begin
            if( clkena && ipl7_timer != 7'd0 ) ipl7_timer <= ipl7_timer - 7'd1;
            if( ipl7_timer == 7'd1 && clkena ) ipl7_pulse <= 1'b0;
        end
    end
end

// isr_ipl7_fetch_ever: latches the first time the CPU reads the level-7
// autovector (autovector 31, byte $7C-$7F, word addresses 0x3E/0x3F).
wire ipl7_vec_read = cen & bus_rd & (cpu_addr==23'h3E || cpu_addr==23'h3F);
always @(posedge clk) begin
    if( rst ) isr_ipl7_fetch_ever <= 1'b0;
    else if( ipl7_vec_read ) isr_ipl7_fetch_ever <= 1'b1;
end

// G diagnostic = "rom_ok_ever": latches the first time rom_ok fires while
// boot_done=1 and rom_cs=1.  This requires the SDRAM cache to actually respond
// to a CPU instruction fetch (not just the CPU presenting the address).
//   G=0: SDRAM stall — bcache never served ROM data to CPU after boot
//   G=1: SDRAM responded; CPU advanced past its first ROM wait state
always @(posedge clk) begin
    if( rst )                                   boot_done_ever <= 1'b0;
    else if( boot_done && rom_cs && rom_ok )    boot_done_ever <= 1'b1;
end

always @(posedge clk) begin
    wdog_rst <= 1'b0;                          // default: not firing
    if( rst ) begin
        wdog_cnt <= 31'd0;
    end else if( cpu_write && ahi==REG_WDOG ) begin
        wdog_cnt <= 31'd0;                     // kicked: reset timer
    end else if( wdog_cnt == 31'd1_439_999_999 ) begin
        wdog_rst <= 1'b1;                      // timeout ~30 s @ 48 MHz
        wdog_cnt <= 31'd0;
    end else begin
        wdog_cnt <= wdog_cnt + 31'd1;
    end
end

// wdog_fired_ever: latches the first time our own watchdog counter above
// actually times out and forces a soft reboot (wdog_rst pulses). Reset only
// by hard rst (not w_rst) so it survives across any number of subsequent
// soft reboots -- see port comment for why this matters.
always @(posedge clk) begin
    if( rst )              wdog_fired_ever <= 1'b0;
    else if( wdog_rst )     wdog_fired_ever <= 1'b1;
end

// nvram_region_wr_ever: latches the first time the CPU issues a write
// (low or high byte lane) to the NVRAM address region. Reset only by hard
// rst so it survives across any soft reboots, same rationale as
// wdog_fired_ever above.
always @(posedge clk) begin
    if( rst )                                    nvram_region_wr_ever <= 1'b0;
    else if( nvram_we_lo || nvram_we_hi )         nvram_region_wr_ever <= 1'b1;
end

// CPU ROM bcache gap generator.
//
// When the CPU performs consecutive ROM fetches at different long-word
// addresses, keep clkena low for one cycle and drop rom_cs.  The following
// cycle re-asserts rom_cs with the new address, creating the bcache-required
// low→high edge.  Same long-word high/low half fetches do not gap.
wire [17:0] cpu_rom_addr_cur = cpu_a[19:2];
wire        cpu_rom_req      = boot_done && prog_sel && bus_rd; // reads only

always @(posedge clk) begin
    if( w_rst ) begin
        cpu_rom_gap       <= 1'b0;
        cpu_rom_addr_last <= 18'h3ffff;      // impossible first match
    end else if( !boot_done ) begin
        cpu_rom_gap       <= 1'b0;
        cpu_rom_addr_last <= 18'h3ffff;
    end else begin
        cpu_rom_gap <= 1'b0;
        if( cpu_rom_req && cpu_rom_addr_cur != cpu_rom_addr_last ) begin
            cpu_rom_gap       <= 1'b1;       // one clock with rom_cs=0
            cpu_rom_addr_last <= cpu_rom_addr_cur;
        end
    end
end

// ---------------------------------------------------------------------------
// Register writes: sound latch, colour latches, plane enable and GROM bank.
// Byte writes:
//   0x480001 → sound latch (low byte)
//   0x300003 → color_latch0 (sftm: init_sftm_common puts latch[0] here)
//   0x380003 → color_latch1 (sftm: init_sftm_common puts latch[1] here)
//   0x700002 → plane_en / grom_bank (high byte)
// ---------------------------------------------------------------------------
always @(posedge clk) begin
    snd_latch_we <= 1'b0;
    if( w_rst ) begin
        plane_en    <= 2'b11;
        grom_bank   <= 2'b00;
        color_latch0<= 7'd0;
        color_latch1<= 7'd0;
        snd_latch   <= 8'd0;
    end else if( cpu_write ) begin
        if( ahi==REG_SND && low_byte_we ) begin
            snd_latch    <= cpu_do16[7:0];
            snd_latch_we <= 1'b1;
        end
        // sftm init_sftm_common swaps the latch assignments vs base itech020_map:
        // 0x300003 (REG_COL1) → latch[0], 0x380003 (REG_COL0) → latch[1]
        if( ahi==REG_COL1 && low_byte_we ) begin
            color_latch0 <= cpu_do16[6:0];  // fg palette bank
        end
        if( ahi==REG_COL0 && low_byte_we ) begin
            color_latch1 <= cpu_do16[6:0];  // bg palette bank
        end
        if( ahi==REG_PLANE && high_byte_we ) begin
            plane_en  <= { ~cpu_do16[10], ~cpu_do16[9] }; // data bits 2:1
            grom_bank <= cpu_do16[15:14];                 // data bits 7:6
        end
    end
end

// ---------------------------------------------------------------------------
// Boot vector copy FSM: walk 32 long-words (0x80 bytes) of program ROM into
// main RAM before releasing the CPU from reset.
//
// jtframe_romrq_bcache requires a low→high edge on cs to re-fetch a new
// address (same root cause as the grom_cs stale-cache bug).  boot_cs pulses
// low for exactly one clock cycle whenever boot_lw advances, then re-asserts
// high to trigger the next SDRAM fetch.  Both 16-bit halves of the same LW
// share the same rom_addr so the second half hits the cache without a pulse.
// ---------------------------------------------------------------------------
always @(posedge clk) begin
    if( w_rst ) begin
        boot_lw   <= 5'd0;
        boot_half <= 1'b0;
        boot_done <= 1'b0;
        boot_cs   <= 1'b1;                           // start fetching addr 0
    end else if( !boot_done ) begin
        if( !boot_cs ) begin
            boot_cs <= 1'b1;                         // re-assert after 1-cycle gap
        end else if( rom_ok ) begin
            if( !boot_half ) begin
                boot_half <= 1'b1;                   // high word latched; same addr
            end else begin
                boot_half <= 1'b0;                   // low word latched
                if( boot_lw == 5'd31 ) begin
                    boot_done <= 1'b1;
                end else begin
                    boot_lw <= boot_lw + 5'd1;
                    boot_cs <= 1'b0;                 // 1-cycle gap → cache re-fetches
                end
            end
        end
    end
end

// ---------------------------------------------------------------------------
// Interrupt priority: mapped per MAME's authoritative itech32.cpp driver
// (itech32_state::update_interrupts / sftm() config, m_irq_base=0 for sftm):
//   VINT (vblank)  → CPU line 1 → IPL1 → autovector 25 (0x64) → 0x00800918
//   XINT (blitter) → CPU line 2 → IPL2 → autovector 26 (0x68) → 0x00801380
//   QINT (scanline)→ CPU line 3 → IPL3 → autovector 27 (0x6C) → 0x008012E0
//
// Each source gets its OWN IPL level; they are not shared/collapsed. This
// replaces an earlier, incorrect "vblank+blitter share IPL2" assumption that
// contradicted MAME's driver and is the suspected root cause of the CPU never
// taking the FPGA-asserted interrupt (hardware-confirmed MAGENTA diagnostic:
// ipl_asserted_ever & ~isr_vec_fetch_ever).
// ---------------------------------------------------------------------------
// (vint_latch and vint_timer are declared earlier, near cpu_ipl, to avoid
// iverilog forward-reference errors from the assign vint_latch_out statement.)

// Per MAME's itech020_map (used by sftm), int1_ack_w is mapped at 0x080000
// (shared with the P1 input port read) -- this is the real vblank ack
// address; the VBlank ISR (now understood to live at 0x00800918, the L1/
// IPL1 autovector target) should write there to clear the interrupt.
// As a safety net in case the real ack path differs subtly (timing, a
// second write, etc.), we also auto-clear via a timer: hold vint_latch high
// for 100 CPU-ACTIVE (clkena) cycles even without an explicit ack write.
//
// IMPORTANT: count clkena (= cen & ~bus_busy), NOT cen.
// When the CPU stalls on SDRAM reads, cen still ticks but clkena=0; counting
// cen gives ~25 real CPU advances instead of the required ~100, so TG68K
// never reaches an instruction boundary and misses the interrupt entirely.
//
// With clkena counting:
//   > 88 clkena (longest 68020 instruction) → TG68K always commits
//   < 162 clkena (shortest ISR path A/B to RTE) → latch clears before RTE
// int1_ack is kept as a fast-path in case a future ISR reads 0x080000.
wire int1_ack = cen & bus_active & (~cpu_uds_n | ~cpu_lds_n) & (ahi==REG_INP0);

always @(posedge clk) begin
    if( w_rst ) begin
        vint_latch  <= 1'b0;
        vint_timer  <= 7'd0;
    end else begin
        if( vblank_irq ) begin
            vint_latch <= 1'b1;
            vint_timer <= 7'd100;              // arm 100-clkena window
        end else begin
            if( int1_ack ) vint_latch <= 1'b0;           // fast-path ack
            if( clkena && vint_timer != 7'd0 ) vint_timer <= vint_timer - 7'd1;
            if( vint_latch && vint_timer==7'd1 && clkena ) vint_latch <= 1'b0;
        end
    end
end
// ---------------------------------------------------------------------------
// The forced-IPL7 diagnostic (commits 81cdd14 / e98093a) has now returned its
// answer on hardware: with the priority-inversion bug fixed, the CPU DOES
// take the real vblank request when it is presented as non-maskable. SR
// interrupt masking is therefore CONFIRMED as the reason the real (maskable)
// IPL1 request is never serviced -- the boot code runs with interrupts
// disabled and never reaches the point where it lowers the mask. That probe
// has served its purpose and is REVERTED here back to normal itech32
// behaviour (vint_latch -> IPL1, synthetic ipl7_pulse restored).
// ---------------------------------------------------------------------------
always @(posedge clk) begin
    if( w_rst ) cpu_ipl <= 3'b111;          // no IRQ (active low IPL)
    else begin
        cpu_ipl <= 3'b111;
        // NOTE ON ORDERING: this block resolves ties by "last statement wins"
        // (sequential non-blocking assignment), NOT by numeric priority. The
        // order below is correct because vint_latch drives the LOWEST-priority
        // level (IPL1), so it must be checked FIRST in order to lose to
        // blit_irq/scan_irq when they coincide. Any future change that
        // repoints vint_latch to a HIGHER priority level must also move its
        // check LATER in this chain -- exactly the priority-inversion bug hit
        // by the forced-IPL7 diagnostic in commit 81cdd14 and fixed in
        // e98093a (see /tmp/check_priority.v, /tmp/check_priority2.v).
        if( vint_latch ) cpu_ipl <= 3'b110; // IPL1: vblank  → autovector 25 → 0x00800918
        if( blit_irq   ) cpu_ipl <= 3'b101; // IPL2: blitter → autovector 26 → 0x00801380
        if( scan_irq   ) cpu_ipl <= 3'b100; // IPL3: scanline→ autovector 27 → 0x008012E0
        if( ipl7_pulse ) cpu_ipl <= 3'b000; // IPL7: diagnostic-only, non-maskable test pulse
    end
end

// ---------------------------------------------------------------------------
// TG68K.C kernel (CPU="11" -> 68020). Instantiated as a black box; the VHDL
// (or ghdl/vhd2vl-converted Verilog) is vendored under hdl/tg68k.
// ---------------------------------------------------------------------------
TG68KdotC_Kernel #(
    .SR_Read       (2), .VBR_Stackframe(2),
    .extAddr_Mode  (2), .MUL_Mode(2), .DIV_Mode(2),
    .BitField      (2), .BarrelShifter(2), .MUL_Hardware(1)
) u_cpu (
    .CPU           ( 2'b11        ),   // 68020 mode
    .clk           ( clk          ),
    .nReset        ( ~w_rst & boot_done ),
    .clkena_in     ( clkena       ),
    .data_in       ( cpu_din      ),
    .IPL           ( cpu_ipl      ),
    .IPL_autovector( 1'b1         ),
    .addr_out      ( cpu_a        ),
    .berr          ( 1'b0         ),
    .data_write    ( cpu_do16     ),
    .busstate      ( busstate     ),
    .nWr           ( cpu_wr_n     ),
    .nUDS          ( cpu_uds_n    ),
    .nLDS          ( cpu_lds_n    ),
    .nResetOut     (              ),
    .skipFetch     (              )
);

endmodule
