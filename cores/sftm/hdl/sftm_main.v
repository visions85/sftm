`timescale 1ns/1ps
/*  This file is part of SFTM.  GPLv3 - see LICENSE.

    Main CPU subsystem for Street Fighter: The Movie (itech32, 020 board).

    CPU: Motorola MC68EC020 @ 25 MHz, recreated with TG68K.C in 68020 mode.
    TG68K.C uses a 16-bit external data bus even in 020 mode (dynamic bus
    sizing), so 32-bit program ROM words are fed as two 16-bit halves.

    Memory map: transcribed and verified against MAME itech32.cpp `itech020_map`
    and `init_sftm_common`. All offsets cross-checked against MAME source.
*/

module sftm_main(
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
//   The LINC chip provides vectors via IACK; we cannot replicate this, but
//   we CAN choose IPL levels so TG68K's autovectors land on the correct ISRs.
//   ROM vector table:
//     L1 autovector (0x64) = 0x00800918 → error-halt code 5 (unused/NMI stub)
//     L2 autovector (0x68) = 0x00801380 → REAL VBlank ISR (MOVEM/frame counter)
//     L3 autovector (0x6C) = 0x008012E0 → Scanline ISR
//   Therefore: vblank + blitter share IPL2; scanline = IPL3.
//   (In MAME, LINC maps vblank at IPL1→vector26, blitter at IPL2→vector26,
//   scanline at IPL3→vector27; we collapse vblank+blitter to IPL2 since the
//   ISR reads VIDEO_INTSTATE to differentiate, and IPL2 autovector = 26 = $00801380.)
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
reg        prot_cs, nopr_cs;
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
// Interrupt priority: mapped to match the LINC chip's IACK vector provision
// via TG68K autovectors (IPL_autovector=1).
//
// LINC maps vblank→vector26, blitter→vector26, scanline→vector27 in real HW.
// Autovector rule: IPL N → vector (24+N).  So:
//   IPL2 autovector → vector 26 (0x68) → 0x00801380  (VBlank/blitter ISR)
//   IPL3 autovector → vector 27 (0x6C) → 0x008012E0  (Scanline ISR)
//
// VBlank + blitter share IPL2; the ISR reads VIDEO_INTSTATE to differentiate.
// Scanline → IPL3.
// ---------------------------------------------------------------------------
// (vint_latch and vint_timer are declared earlier, near cpu_ipl, to avoid
// iverilog forward-reference errors from the assign vint_latch_out statement.)

// The VBlank ISR at 0x00801380 does NOT read 0x080000; it acks via the LINC
// chip's IACK cycle in real hardware (hardware-automatic ack).
// With IPL_autovector=1 there is no IACK bus cycle, so we simulate the LINC
// ack with a timer: hold vint_latch high for 100 CPU-ACTIVE (clkena) cycles.
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
always @(posedge clk) begin
    if( w_rst ) cpu_ipl <= 3'b111;          // no IRQ (active low IPL)
    else begin
        cpu_ipl <= 3'b111;
        if( vint_latch ) cpu_ipl <= 3'b101; // IPL2: vblank → autovector 26 → 0x00801380
        if( blit_irq   ) cpu_ipl <= 3'b101; // IPL2: blitter (same ISR, checks INTSTATE)
        if( scan_irq   ) cpu_ipl <= 3'b100; // IPL3: scanline → autovector 27 → 0x008012E0
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
