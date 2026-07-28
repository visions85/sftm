`timescale 1ns/1ps
/*  This file is part of SFTM.  GPLv3 - see LICENSE.

    Video subsystem for Street Fighter: The Movie (itech32 IT42 blitter).

    Register offsets and semantics are taken from MAME
    src/mame/itech/itech32_v.cpp (VIDEO_* defines). This module holds:
      - the 0x00..0x88 video register file (word addressed)
      - the programmable CRTC (H/V total, sync, blank) and scanout counters
      - two 512-wide VRAM planes (foreground / background) in BRAM
      - 15-bit palette RAM
      - the IT42 blitter (sftm_blitter) that copies GROM -> VRAM
*/

module sftm_video(
    input               rst,
    input               clk,
    input               pxl_cen,
    input               pxl2_cen,

    // CPU bus
    input       [23:1]  cpu_addr,
    input       [15:0]  cpu_dout,
    input               cpu_rnw,
    input               cpu_uds_n,
    input               cpu_lds_n,
    input               vram_cs,
    input               vreg_cs,
    input               pal_cs,
    output      [15:0]  vram_dout,
    output reg  [15:0]  vreg_dout,
    output      [15:0]  pal_dout,
    input       [ 1:0]  plane_en,
    input       [ 1:0]  grom_bank,
    input       [ 6:0]  color_latch0,
    input       [ 6:0]  color_latch1,

    // Graphics ROM (blitter source) - SDRAM banks 2/3
    output      [23:0]  grom_addr,
    input       [15:0]  grom_data,
    output              grom_cs,
    input               grom_ok,
    output      [17:0]  grm3_addr,
    input       [15:0]  grm3_data,
    output              grm3_cs,
    input               grm3_ok,

    // Interrupts to the CPU
    output reg          blit_irq,
    output reg          scan_irq,
    output reg          vblank_irq,

    // Video output
    output reg          HS,
    output reg          VS,
    output reg          LHBL,
    output reg          LVBL,
    output      [ 4:0]  red,
    output      [ 4:0]  green,
    output      [ 4:0]  blue,
    input       [ 3:0]  gfx_en,
    input       [ 7:0]  debug_bus,

    // Diagnostic: latched in sftm_main when CPU first writes NVRAM.
    input               nvram_wr_ever,

    // VBlank active latch from sftm_main: held high for ~100 CPU-active cycles
    // after each VBlank. Drives bit 6 of VR_XFER reads so an ISR can poll for
    // end-of-vblank (loops writing $0040 to VR_XFER and reading $500005 bit 6
    // until the window expires).
    // NOTE: per MAME's itech32.cpp, vblank (VINT) maps to IPL1 (autovector
    // 25, $00800918), not IPL2. The routine at $801380 (IPL2 autovector,
    // $68) is the blitter/XINT ISR, not the VBlank ISR -- it may still poll
    // this bit as a secondary condition, but it is not the vblank handler.
    input               vint_latch,

    // Diagnostic: first watchdog kick by the main CPU outer loop.
    input               wdog_kick_ever,

    // diagnostic: CPU ever read the IPL2/IPL3 autovector table entry
    // ($68-$6F). Blinks the diag-phase colour when set, independent of
    // ROM-content knowledge -- proves whether the interrupt path itself
    // was ever taken by the CPU.
    input               isr_vec_fetch_ever,
    input               ipl_asserted_ever,

    // Diagnostic-only: a synthetic, game-logic-independent level-7 (non-
    // maskable) interrupt pulse fired once ~1s after reset by sftm_main,
    // and whether the CPU actually took it. Level 7 cannot be masked by
    // software, so ipl7_pulse_ever & ~isr_ipl7_fetch_ever proves the CPU
    // (or the cpu_ipl/autovector wiring) is not functioning at all on real
    // hardware, independent of the real ROM's own interrupt-mask handling.
    input               ipl7_pulse_ever,
    input               isr_ipl7_fetch_ever,

    // Diagnostic: sftm_main's own watchdog counter has timed out and forced
    // a soft reboot at least once. Distinguishes "stuck on the very first
    // boot attempt" from "the CPU HAS already been soft-rebooted at least
    // once and still ends up in the identical stuck state" -- see
    // sftm_main port comment for the full rationale.
    input               wdog_fired_ever,

    // Diagnostic: the CPU has issued at least one write (either byte lane)
    // to the NVRAM address region (0x600000-0x61ffff). Reset only by hard
    // rst. Used to disambiguate whether the boot ROM ever attempts to
    // touch NVRAM at all -- see sftm_main port comment for rationale.
    input               nvram_region_wr_ever,

    // Diagnostic: protection RAM byte (0x7A6A) write / port (0x680002) read
    // -- see sftm_main.v port comments. Used below to drive a counted-flash
    // overlay instead of another same-hue-family colour swap (colour
    // perception of ORANGE vs MAROON/LILAC proved unreliable in practice).
    input               prot_wr_ever,
    input               prot_rd_ever,

    // Diagnostic: saturating count (0..3) of DISTINCT protection-port read
    // accesses -- see sftm_main.v port comment. CORRECTED: an earlier
    // version of this comment mis-stated the hardware result as
    // wr=0,rd=1 due to a Verilog concatenation bit-order error -- the true
    // result (re-verified in simulation, see AGENTS.md) is wr=1,rd=0: the
    // protection write happens, the read never does. That question is now
    // settled; this counter (still correctly wired/edge-detected) is no
    // longer driving the flash overlay below but is kept available.
    input      [ 1:0]   prot_rd_count,

    // Diagnostic: saturating count (0..3) of DISTINCT instruction fetches
    // the CPU performs strictly AFTER prot_wr_ever has latched -- see
    // sftm_main.v port comment. Drives the flash-count overlay below,
    // answering whether the CPU is still alive/executing at all after the
    // protection write (as opposed to a hard crash/halt right there).
    input      [ 1:0]   post_wr_fetch_count,
    input      [ 2:0]   poll_region,
    input      [ 2:0]   exc_vec,
    input      [ 2:0]   exc_detail,
    input      [ 7:0]   exc_vec_num,
    input      [23:0]   exc_fetch_addr,
    input      [15:0]   exc_fetch_word,
    input               exc_last_ff,
    // exc_code_ram: live mirror of RAM[0x0FBE], where this ROM's exception
    // handlers record their own exception code before parking. See the
    // detailed port comment in sftm_main.v. Unlike exc_vec/exc_detail
    // above (retracted as false positives -- see AGENTS.md ROM cross-check
    // -- because the power-on RAM self-test sweeps the vector table and
    // trips any address-match latch on a first-hit basis), this is a live
    // value with no freeze, so it settles on the true final answer.
    input      [15:0]   exc_code_ram,
    // pc_snapshot_addr/word: one-shot snapshot of the CPU's instruction
    // fetch address/word ~5s after reset. See the detailed port comment in
    // sftm_main.v. Drives rows 2-4 below, replacing the retracted
    // exc_fetch_addr/exc_fetch_word (rows 2-4 previously showed those; see
    // the ROM CROSS-CHECK / "ROM fetch path cleared" retractions in
    // AGENTS.md for why that data was unreliable).
    input      [23:0]   pc_snapshot_addr,
    input      [15:0]   pc_snapshot_word,

    // Diagnostic: boot copy completed at least once.
    // G=0 → CPU never accessed ROM after boot copy (wrong reset vector or SDRAM issue).
    // G=1 → CPU entered ROM address space.
    input               boot_done_ever
);

localparam VRAM_W = 512, VRAM_H = 256;   // TODO: confirm plane height vs HW

// ---------------------------------------------------------------------------
// Video register file (see itech32_v.cpp). Word indices = byte offset >> 1.
// ---------------------------------------------------------------------------
localparam VR_STATUS   = 7'h00>>1, VR_INT     = 7'h02>>1,
           VR_XFER     = 7'h04>>1, VR_XFERFLG = 7'h06>>1,
           VR_COMMAND  = 7'h08>>1, VR_INTEN   = 7'h0a>>1,
           VR_XFERH    = 7'h0c>>1, VR_XFERW   = 7'h0e>>1,
           VR_ADDRLO   = 7'h10>>1, VR_XFERX   = 7'h12>>1,
           VR_XFERY    = 7'h14>>1, VR_SRCYSTEP= 7'h16>>1,
           VR_SRCXSTEP = 7'h18>>1, VR_DSTXSTEP= 7'h1a>>1,
           VR_DSTYSTEP = 7'h1c>>1, VR_YSTEPX  = 7'h1e>>1,
           VR_XSTEPY   = 7'h20>>1, VR_LEFTCLIP= 7'h24>>1,
           VR_RIGHTCLIP= 7'h26>>1, VR_TOPCLIP = 7'h28>>1,
           VR_BOTCLIP  = 7'h2a>>1, VR_INTLINE = 7'h2c>>1,
           VR_ADDRHI   = 7'h2e>>1,
           VR_VTOTAL   = 7'h32>>1, VR_VSYNC   = 7'h34>>1,
           VR_VBSTART  = 7'h36>>1, VR_VBEND   = 7'h38>>1,
           VR_HTOTAL   = 7'h3a>>1, VR_HSYNC   = 7'h3c>>1,
           VR_HBSTART  = 7'h3e>>1, VR_HBEND   = 7'h40>>1,
           VR_DYORG1   = 7'h44>>1, VR_DYORG2  = 7'h46>>1,
           VR_DYSCROLL2= 7'h48>>1, VR_DXORG1  = 7'h4c>>1,
           VR_DXORG2   = 7'h4e>>1, VR_DXSCROLL2=7'h50>>1,
           VR_STARTSTEP= 8'h80>>1, VR_LEFTSTEPLO=8'h82>>1,
           VR_LEFTSTEPHI=8'h84>>1, VR_RIGHTSTEPLO=8'h86>>1,
           VR_RIGHTSTEPHI=8'h88>>1;

localparam [15:0] VIDEOINT_SCANLINE = 16'h0004,
                  VIDEOINT_BLITTER  = 16'h0040;

reg  [15:0] vregs[0:127];            // 0x00..0xfe
wire [ 6:0] vreg_a = cpu_addr[7:1];
wire        vreg_we = vreg_cs & ~cpu_rnw & (~cpu_uds_n | ~cpu_lds_n);
wire [15:0] cpu_mask = { {8{~cpu_uds_n}}, {8{~cpu_lds_n}} };
wire [15:0] vreg_wr_val = merge16(vregs[vreg_a], cpu_dout, cpu_mask);

reg  [15:0] int_state, int_state_n;
reg  [15:0] xfer_xcount, xfer_ycount, xfer_xcur, xfer_ycur;
reg         cpu_xfer_we, blit_start, cmd_done;
reg  [16:0] cpu_xfer_waddr;
reg  [ 7:0] cpu_xfer_wdata;
reg  [ 1:0] cpu_xfer_plane_en;
reg  [ 9:0] hcnt, vcnt;
reg         blit_busy;           // set on blit_start, cleared on blit_done
reg  [ 8:0] startup_cnt;         // counts vblanks; startup_phase = bit8 clear
wire        blit_done;
wire [16:0] cpu_xfer_addr;
// startup_phase=1 for the first 256 vblanks (~4s) after game_rst deasserts.
// Root cause of original black screen: LHBL/LVBL were reset to 0 (blanked),
// causing arcade_video to latch VBL=1 on the very first frame edge.  Fixed by
// initialising LHBL/LVBL to 1 (active) in the CRTC reset block below.
wire        startup_phase = ~startup_cnt[8]; // first 256 frames (~4s): diagnostic raster
// blit_start_ever: latches the first blit_start pulse
// blit_done_ever:  latches the first blit_done pulse
reg         blit_start_ever;     // latches the first blit_start forever
reg         blit_done_ever;      // latches the first blit_done forever
reg         vreg_cmd_ever;       // latches first VR_COMMAND write (any value)
reg         pal_wr_ever;          // latches first CPU write to palette RAM ($580000-$59FFFF)
// Diagnostic: show until first blit_done, then switch to game output.
// No fixed time window — the cooperative-multitasking boot sequence takes an
// unpredictable number of frames (ROM analysis: task $829908 goes through
// many coroutine yields before first screen-clear at $8027A0; the attract
// mode intro can take 1000+ frames before any blitting starts).
// Colours: RED=blit_start never fired; MAGENTA=cmd written no blit_start;
//          YELLOW=blit_start fired, done never; GREEN=blit done (OK).
wire        diag_phase = !blit_done_ever && !startup_phase;
integer     i;

function [15:0] merge16;
    input [15:0] oldv;
    input [15:0] newv;
    input [15:0] mask;
    begin
        merge16 = (oldv & ~mask) | (newv & mask);
    end
endfunction

function [15:0] adjusted_height;
    input [15:0] h;
    begin
        adjusted_height = { 7'd0, h[9], h[7:0] };
    end
endfunction

wire scanline_hit = pxl_cen && hcnt==10'd0 && vcnt==vregs[VR_INTLINE][9:0];

always @(*) begin
    int_state_n = int_state;
    if( blit_done || cmd_done ) int_state_n = int_state_n | VIDEOINT_BLITTER;
    if( scanline_hit )          int_state_n = int_state_n | VIDEOINT_SCANLINE;
    // VR_INT writes clear bits; VR_XFER writes also clear int_state bits
    // (the VBlank ISR writes $0004/$0040/$003A to VR_XFER to ack interrupts;
    //  without this, VIDEOINT_SCANLINE accumulates and scan_irq stays asserted).
    if( vreg_we && (vreg_a==VR_INT || vreg_a==VR_XFER) )
        int_state_n = int_state_n & ~(cpu_dout & cpu_mask);
end

// CPU register read/write and transfer-port side effects.
always @(posedge clk) begin
    if( rst ) begin
        blit_busy   <= 1'b0;
        // startup_cnt reset is handled in its own always block below.
        for( i=0; i<128; i=i+1 ) vregs[i] <= 16'd0;
        // Set source/dest step registers to 1:1 scale (0x0100 = 1.0 in 8.8 fp).
        // Game writes correct values before blitting; reset values prevent
        // src-stall (src_xfrac never overflows if srcxstep=0).
        vregs[VR_SRCXSTEP] <= 16'h0100;
        vregs[VR_SRCYSTEP] <= 16'h0100;
        vregs[VR_DSTYSTEP] <= 16'h0100;
        // Pre-load CRTC timing with itech32 hardware values so HS/VS oscillate
        // from reset even before the CPU programs them (all-zeros → stuck at DC).
        // Values from MAME itech32.xml: htotal=508 vtotal=262 hbstart=384 vbstart=240.
        vregs[VR_HTOTAL]  <= 16'd507;   // hcnt wraps at 507 → 508 pixels/line
        vregs[VR_HSYNC]   <= 16'd452;   // HS starts at pixel 452
        vregs[VR_HBSTART] <= 16'd384;   // active pixels 0-383
        vregs[VR_HBEND]   <= 16'd0;
        vregs[VR_VTOTAL]  <= 16'd261;   // vcnt wraps at 261 → 262 lines/frame
        vregs[VR_VSYNC]   <= 16'd254;   // VS starts at line 254
        vregs[VR_VBSTART] <= 16'd240;   // active lines 0-239
        vregs[VR_VBEND]   <= 16'd0;
        int_state   <= 16'd0;
        xfer_xcount <= 16'd0;
        xfer_ycount <= 16'd0;
        xfer_xcur   <= 16'd0;
        xfer_ycur   <= 16'd0;
        cpu_xfer_we <= 1'b0;
        cpu_xfer_waddr <= 17'd0;
        cpu_xfer_wdata <= 8'd0;
        cpu_xfer_plane_en <= 2'b00;
        blit_start  <= 1'b0;
        cmd_done    <= 1'b0;
        vreg_dout   <= 16'hffff;
    end else begin
        int_state   <= int_state_n;
        cpu_xfer_we <= 1'b0;
        blit_start  <= 1'b0;
        cmd_done    <= 1'b0;
        if( blit_start )                    blit_busy <= 1'b1;
        else if( blit_done )                blit_busy <= 1'b0;

        if( vreg_we ) begin
            case( vreg_a )
                VR_INT: begin
                    // INTACK clears bits in VIDEO_INTSTATE via int_state_n.
                end

                VR_XFER: begin
                    if( vregs[VR_COMMAND]==16'd3 && xfer_ycount!=16'd0 ) begin
                        cpu_xfer_we     <= 1'b1;
                        cpu_xfer_waddr  <= cpu_xfer_addr;
                        cpu_xfer_wdata  <= cpu_dout[7:0];
                        cpu_xfer_plane_en <= plane_en;
                vregs[VR_XFER]  <= 16'h0000;  // pixel readback removed (io_data port removed)
                        if( xfer_xcount > 16'd1 ) begin
                            xfer_xcount <= xfer_xcount - 16'd1;
                            xfer_xcur   <= xfer_xcur + 16'd1;
                        end else if( xfer_ycount > 16'd1 ) begin
                            xfer_ycount <= xfer_ycount - 16'd1;
                            xfer_xcount <= vregs[VR_XFERW];
                            xfer_xcur   <= vregs[VR_XFERX];
                            xfer_ycur   <= xfer_ycur + 16'd1;
                        end else begin
                            xfer_xcount <= 16'd0;
                            xfer_ycount <= 16'd0;
                        end
                    end else begin
                        vregs[VR_XFER] <= vreg_wr_val;
                    end
                end

                VR_COMMAND: begin
                    vregs[VR_COMMAND] <= vreg_wr_val;
                    if( vreg_wr_val==16'd3 ) begin
                        xfer_xcount <= vregs[VR_XFERW];
                        xfer_ycount <= adjusted_height(vregs[VR_XFERH]);
                        xfer_xcur   <= vregs[VR_XFERX] & 16'h0fff;
                        xfer_ycur   <= vregs[VR_XFERY] & 16'h0fff;
                        cmd_done    <= 1'b1;
                    end else if( vreg_wr_val==16'd1 || vreg_wr_val==16'd2 ||
                                 vreg_wr_val==16'd6 || vreg_wr_val==16'hff ) begin
                        // Command 0xFF is the IT42 "blit/fill" command used by
                        // the SFTM ROM for screen clears and sprite drawing.
                        if( ~blit_busy ) blit_start <= 1'b1;
                        else             cmd_done   <= 1'b1;   // busy: ack only
                    end else begin
                        cmd_done    <= 1'b1;
                    end
                end

                default: begin
                    vregs[vreg_a] <= vreg_wr_val;
                end
            endcase
        end

        case( vreg_a )
            // VR_STATUS: bit7 set when vregs[VR_STATUS][7]=1 (game writes $8F
            // in JSR#0); bit3 = blit busy; bits 2,0 always 1. Bit 6 from int_state
            // so VR_STATUS bit 6 reflects blitter/transfer completion for the
            // render-queue polling loop at $8019E6 (MOVE.W $500000, D0 / BTST #6).
            VR_STATUS:  vreg_dout <= (vregs[VR_STATUS] & 16'hFFF0)
                                   | (int_state & VIDEOINT_BLITTER)
                                   | {12'd0, blit_busy, 3'b101};
            VR_INT:     vreg_dout <= int_state;
            // VR_XFER reads: bit 6 = vint_latch (VBlank active window from the
            // LINC chip) OR any blitter/cmd pending in int_state.  The VBlank ISR
            // polls this bit to detect end-of-vblank; the VR_XFER write value
            // must NOT be reflected here (the IT42 controls the readback).
            VR_XFER:    vreg_dout <= int_state
                                   | (vint_latch ? VIDEOINT_BLITTER : 16'd0);
            VR_XFERFLG: vreg_dout <= 16'h00ef; // MAME returns current scanline-1 here
            default:    vreg_dout <= vregs[vreg_a];
        endcase
    end
end

// ---------------------------------------------------------------------------
// CRTC shadow registers: hold the last *non-zero* value written to the four
// timing registers that feed the counter wraps and blanking logic.
//
// Why:  The CPU clears all 128 video registers to 0 before reprogramming them
// at boot.  With VR_VBSTART=0 the expression ~(vcnt>=0 || vcnt<0) evaluates
// to 0 permanently (same failure as the original LHBL/LVBL=0 reset bug);
// arcade_video latches VBL=1 on the first HBLANK falling edge and outputs
// black forever.  Guard combinational wires are optimised away by Quartus
// because the registers start non-zero after reset — the only way to survive
// the CPU clear-then-reprogram sequence is to use separate registered copies
// that ignore zero writes.
// ---------------------------------------------------------------------------
reg [9:0] r_htotal, r_vtotal, r_hbstart, r_vbstart;

always @(posedge clk) begin
    if( rst ) begin
        r_htotal  <= 10'd507;
        r_vtotal  <= 10'd261;
        r_hbstart <= 10'd384;
        r_vbstart <= 10'd240;
    end else if( vreg_we ) begin
        if( vreg_a==VR_HTOTAL  && vreg_wr_val[9:0]!=10'd0 ) r_htotal  <= vreg_wr_val[9:0];
        if( vreg_a==VR_VTOTAL  && vreg_wr_val[9:0]!=10'd0 ) r_vtotal  <= vreg_wr_val[9:0];
        if( vreg_a==VR_HBSTART && vreg_wr_val[9:0]!=10'd0 ) r_hbstart <= vreg_wr_val[9:0];
        if( vreg_a==VR_VBSTART && vreg_wr_val[9:0]!=10'd0 ) r_vbstart <= vreg_wr_val[9:0];
    end
end

// CRTC counters (run on pxl_cen). Generate sync/blank + interrupts.
always @(posedge clk) begin
    if( rst ) begin
        hcnt <= 10'd0;
        vcnt <= 10'd0;
        HS   <= 1'b0;
        VS   <= 1'b0;
        LHBL <= 1'b1;   // start active; avoids 1-frame blank window post-reset
        LVBL <= 1'b1;   // start active
    end else if(pxl_cen) begin
        if( hcnt >= r_htotal ) begin
            hcnt <= 0;
            vcnt <= (vcnt >= r_vtotal) ? 10'd0 : vcnt + 10'd1;
        end else hcnt <= hcnt + 10'd1;

        HS   <= hcnt >= vregs[VR_HSYNC][9:0];
        VS   <= vcnt >= vregs[VR_VSYNC][9:0];
        LHBL <= ~(hcnt >= r_hbstart || hcnt < vregs[VR_HBEND][9:0]);
        LVBL <= ~(vcnt >= r_vbstart || vcnt < vregs[VR_VBEND][9:0]);
    end
end

// scanline & vblank interrupts (VIDEOINT_SCANLINE=0x04, BLITTER=0x40)
always @(posedge clk) begin
    if( rst ) begin vblank_irq<=0; end
    else if(pxl_cen) begin
        vblank_irq <= (vcnt==vregs[VR_VBSTART][9:0]) && hcnt==0;
        // scanline INT bit is set via scanline_hit (see int_state_n above)
    end else vblank_irq <= 1'b0;
end

// Startup diagnostic frame counter: counts vblank pulses.
// For the first 256 frames (~4s, startup_phase=1) we force solid white so
// the user can confirm the video pipeline is alive right after ROM download.
// After 256 frames the core switches to normal game output.
always @(posedge clk) begin
    if( rst ) startup_cnt <= 9'd0;
    else if( vblank_irq && startup_phase ) startup_cnt <= startup_cnt + 9'd1;
end
// blit_start_ever / blit_done_ever: latch first occurrence, never reset.
always @(posedge clk) begin
    if( rst )            blit_start_ever <= 1'b0;
    else if( blit_start ) blit_start_ever <= 1'b1;
end
always @(posedge clk) begin
    if( rst )           blit_done_ever <= 1'b0;
    else if( blit_done ) blit_done_ever <= 1'b1;
end
// vreg_cmd_ever: set on any CPU write to VR_COMMAND (regardless of value).
// Distinguishes "VR_COMMAND never written" (RED, no blue) from "VR_COMMAND
// written but blit_start didn't fire" (MAGENTA = hardware bug).
always @(posedge clk) begin
    if( rst )                                  vreg_cmd_ever <= 1'b0;
    else if( vreg_we && vreg_a==VR_COMMAND )   vreg_cmd_ever <= 1'b1;
end
// diag_cnt removed (diagnostic window is now open-ended until blit_done_ever).
// pal_wr_ever: set the first time the CPU writes to palette RAM.
// Palette writes happen during early display init, long before the first blit.
// If pal_wr_ever=1 but wdog_kick_ever=0 the CPU IS running but the wdog
// detection is broken (or the watchdog address decode is wrong).
always @(posedge clk) begin
    if( rst )                                       pal_wr_ever <= 1'b0;
    else if( pal_cs & ~cpu_rnw & (~cpu_uds_n | ~cpu_lds_n) ) pal_wr_ever <= 1'b1;
end

// ---------------------------------------------------------------------------
// VRAM: two planes, 8-bit indexed pixels, 512 wide. Dual port: blitter writes
// / CPU access on one port, scanout reads on the other.
// ---------------------------------------------------------------------------
wire [16:0] blt_waddr;   wire [7:0] blt_wdata; wire blt_we; wire blt_plane;
wire [16:0] fg_scan_addr, bg_scan_addr;
wire [16:0] vram_waddr;
wire [ 7:0] vram_wdata;
wire [ 7:0] fg_pix, bg_pix;
wire        fg_vram_we, bg_vram_we;

assign cpu_xfer_addr = { xfer_ycur[7:0], xfer_xcur[8:0] };
assign vram_waddr    = cpu_xfer_we ? cpu_xfer_waddr : blt_waddr;
assign vram_wdata    = cpu_xfer_we ? cpu_xfer_wdata : blt_wdata;
assign fg_vram_we    = (blt_we & ~blt_plane) | (cpu_xfer_we & cpu_xfer_plane_en[0]);
assign bg_vram_we    = (blt_we &  blt_plane) | (cpu_xfer_we & cpu_xfer_plane_en[1]);

sftm_vram #(.AW(17)) u_fg(
    .clk(clk), .we( fg_vram_we ),
    .waddr(vram_waddr), .wdata(vram_wdata),
    .raddr(fg_scan_addr), .rdata(fg_pix) );

sftm_vram #(.AW(17)) u_bg(
    .clk(clk), .we( bg_vram_we ),
    .waddr(vram_waddr), .wdata(vram_wdata),
    .raddr(bg_scan_addr), .rdata(bg_pix) );

// vram_dout: vram_cs is hardwired 0 in sftm_main so this is never read by CPU.
assign vram_dout = 16'h0000;

wire [8:0] fg_scan_x = hcnt[8:0] + vregs[VR_DXORG1][8:0];
wire [7:0] fg_scan_y = vcnt[7:0] + vregs[VR_DYORG1][7:0];
wire [8:0] bg_scan_x = hcnt[8:0] + vregs[VR_DXORG2][8:0] + vregs[VR_DXSCROLL2][8:0];
wire [7:0] bg_scan_y = vcnt[7:0] + vregs[VR_DYORG2][7:0] + vregs[VR_DYSCROLL2][7:0];
assign fg_scan_addr = { fg_scan_y, fg_scan_x };
assign bg_scan_addr = { bg_scan_y, bg_scan_x };

// plane priority: foreground pixel unless transparent (0xff), else background
wire       fg_opaque = fg_pix!=8'hff;
wire [7:0] px = fg_opaque ? fg_pix : bg_pix;
wire [6:0] px_color = fg_opaque ? color_latch0 : color_latch1;

// ---------------------------------------------------------------------------
// Palette RAM: 15-bit colour. bloodstm-style: MSB used in game mode.
// index = { color_latch bank bits, pixel }
// ---------------------------------------------------------------------------
wire [14:0] pal_rgb;
sftm_pal u_pal(
    .clk    ( clk       ),
    .cpu_addr(cpu_addr[15:1]),
    .cpu_dout(cpu_dout  ),
    .cpu_we ( pal_cs & ~cpu_rnw ),
    .cpu_q  ( pal_dout  ),
    .rd_idx ( { px_color, px } ),
    .rd_rgb ( pal_rgb   )
);

// Startup diagnostic: solid white for the first 256 vblank periods (~4s)
// after core load.  This is completely independent of CPU, VRAM, palette and
// hcnt/vcnt — if the MiSTer display chain is working we MUST see a white
// screen.  After the startup window the normal game output appears.
// gfx_en[3]=0 in the OSD restores the hcnt/vcnt gradient at any time.
//
// Post-startup progress diagnostic (diag_phase = active until first blit_done).
// Encodes three progress flags as RGB:
//   R = !wdog_kick_ever  (watchdog NOT yet kicked)
//   G =  boot_done_ever  = rom_ok_ever: SDRAM served ROM data to CPU post-boot
//   B =  nvram_wr_ever   = ram_wr_ever: CPU wrote to main RAM ($000000-$007FFF)
//                          (repurposed names kept to avoid port churn)
//
// Resulting colours:
//   RED    (G=0,B=0): SDRAM stall — rom_ok never fired after boot copy
//   YELLOW (G=1,B=0): SDRAM responded but CPU never wrote RAM → crashes within
//                     first 1-2 instructions before any stack push or RAM clear
//   WHITE  (G=1,B=1): CPU executing real code (wrote RAM), crashes before wdog
//   CYAN   (R→0): wdog kicked → outer main loop running → game running!
wire [4:0] dbg_r = hcnt[6:2];
wire [4:0] dbg_g = vcnt[5:1];
wire [4:0] dbg_b = {hcnt[8], vcnt[7], 3'd0};
wire       show_raster = startup_phase | ~gfx_en[3];

// Instead of blinking WHITE (hard to judge ~1Hz vs ~4Hz by eye), swap in a
// completely different SOLID colour once the CPU has evidence of taking an
// interrupt. This only overrides the exact WHITE combination (R=G=B=1F,
// i.e. wdog never kicked + boot done + RAM written) -- RED/YELLOW/CYAN are
// untouched. MAGENTA and pure GREEN never occur naturally in the normal
// RED->YELLOW->WHITE->CYAN progression (B only turns on after G is already
// on; R only turns off -> CYAN after both G and B are already on), so they
// are safe, unambiguous stand-ins:
//   WHITE   : neither latch ever set -- FPGA never asserted IPL1/2/3 at all
//   MAGENTA : ipl_asserted_ever set, isr_vec_fetch_ever NOT set, and the
//             diagnostic IPL7 test (below) WAS taken -- FPGA correctly
//             asserted a real (IPL1/2/3) interrupt and the CPU/autovector
//             mechanism is proven to work (it took the non-maskable IPL7
//             test pulse), but the CPU never took the real one. This means
//             the real ROM's own boot code never lowered its SR interrupt
//             mask enough to admit IPL1/2/3, and is the prime remaining
//             suspect (e.g. still spinning on a protection/init check).
//   BLUE    : the diagnostic IPL7 test pulse fired (sftm_main forces this
//             ~1s after reset, unconditionally, non-maskable by spec) but
//             was NEVER taken by the CPU. This rules out the ROM's SR mask
//             entirely -- it proves the CPU itself (or the cpu_ipl /
//             IPL_autovector wiring to the vendored core) is not
//             functioning on real hardware. Takes priority over ORANGE/MAGENTA.
//   ORANGE  : same condition as MAGENTA (IPL7 proven taken, real interrupt
//             never taken) but ALSO wdog_fired_ever is set -- our own
//             watchdog has ALREADY forced at least one soft reboot during
//             this session, and the CPU still ended up back in the exact
//             same stuck state on a subsequent boot attempt. This rules out
//             "just needs one NVRAM-factory-init retry" as the explanation,
//             since that retry has demonstrably already happened.
//   MAGENTA : IPL7 proven taken, real interrupt never taken, and
//             wdog_fired_ever is NOT set -- still on the very first boot
//             attempt (our own watchdog hasn't fired even once yet).
//   GREEN   : isr_vec_fetch_ever set -- CPU actually took a real (IPL1/2/3)
//             autovectored interrupt at least once (best outcome, takes
//             priority over BLUE/ORANGE/MAGENTA)
wire white_now     = !wdog_kick_ever & boot_done_ever & nvram_wr_ever;
wire show_green    = white_now & isr_vec_fetch_ever;
// show_blue RESTORED to its original formula: the forced-IPL7 diagnostic
// (which had temporarily repurposed the meaning of these two signals, and so
// required hardwiring this to 0) has returned its answer and been reverted in
// sftm_main.v, so ipl7_pulse_ever / isr_ipl7_fetch_ever once again mean what
// they originally did -- the synthetic one-shot level-7 test pulse.
// For the record, that test's confirmed hardware answer was
// isr_ipl7_fetch_ever=1 (the CPU DOES take a forced unmaskable interrupt), so
// this term is expected to stay 0 in practice and not mask show_stuck.
wire show_blue      = white_now & ~show_green & ipl7_pulse_ever & ~isr_ipl7_fetch_ever;
wire show_stuck     = white_now & ~show_green & ~show_blue & ipl_asserted_ever & ~isr_vec_fetch_ever;
// show_stuck splits into 4 combinations of (wdog_fired_ever, nvram_region_wr_ever).
// Each new colour is built by swapping ORANGE/MAGENTA's existing "partial"
// channel from green to blue (same brightness, 0x0A), matching the same
// single-partial-channel encoding technique already confirmed reliable for
// ORANGE -- rather than blending a third channel in, which would be a much
// smaller (harder to judge) visual delta from the existing colours:
//   ORANGE (wdog=1, nvram_wr=0): unchanged meaning from before this
//           diagnostic was added -- watchdog fired at least once, CPU never
//           wrote NVRAM. R=1F G=0A B=00 (partial GREEN).
//   MAGENTA(wdog=0, nvram_wr=0): unchanged meaning -- still on first boot
//           attempt, CPU never wrote NVRAM. R=1F G=00 B=1F.
//   MAROON (wdog=1, nvram_wr=1): NEW -- watchdog fired at least once AND the
//           CPU DID write to the NVRAM region at least once. Rules out "ROM
//           never touches NVRAM" -- keeps the NVRAM-checksum / aliasing /
//           path-resolution theories alive as the leading explanation.
//           R=1F G=00 B=0A (partial BLUE instead of partial GREEN --
//           visually a muted red/brick colour, not orange).
//   LILAC  (wdog=0, nvram_wr=1): NEW -- still on first boot attempt, but the
//           CPU already wrote NVRAM at least once before getting stuck.
//           R=1F G=0A B=1F (MAGENTA + partial GREEN -- visually a pale
//           pink/lilac, not a pure magenta).
wire show_orange    = show_stuck &  wdog_fired_ever & ~nvram_region_wr_ever;
wire show_magenta   = show_stuck & ~wdog_fired_ever & ~nvram_region_wr_ever;
wire show_maroon    = show_stuck &  wdog_fired_ever &  nvram_region_wr_ever;
wire show_lilac     = show_stuck & ~wdog_fired_ever &  nvram_region_wr_ever;

// ---------------------------------------------------------------------------
// Counted-flash overlay: encodes a 2-bit diagnostic combo as a COUNT of
// distinct WHITE flashes against the stuck-state colour, instead of yet
// another same-hue-family colour swap. Both blink RATE and subtle partial-
// channel hue swaps (ORANGE vs MAROON/LILAC) have proven unreliable for the
// user to judge by eye -- counting a small number of clearly separated
// flashes, each with a distinct steady-colour gap before/after, is far more
// robust. Timed off vblank_irq (~60 Hz):
//   Each flash: 30 frames (~0.5s) WHITE ON, then 30 frames back to the base
//   stuck colour. After N flashes: 90 frames (~1.5s) steady at the base
//   stuck colour as a clear "reset" gap before the next counting cycle.
//
// CORRECTED HISTORY -- IMPORTANT: the commit-0db0286 build used
// N = 1 + {prot_wr_ever, prot_rd_ever} and its AGENTS.md table mis-stated
// the meaning of N=2 and N=3 (swapped). Verilog concatenation {A,B} makes A
// the MSB (weight 2) and B the LSB (weight 1), so that formula actually
// meant: N=1->(wr=0,rd=0), N=2->(wr=0,rd=1), N=3->(wr=1,rd=0), N=4->(wr=1,rd=1)
// -- verified directly in simulation (/tmp/check_concat.v). The hardware
// report of "N=3" therefore really meant **wr=1, rd=0**: the CPU DOES write
// the protection RAM byte at 0x7A6A, but NEVER reads the 0x680002 port
// afterward -- the OPPOSITE of what was previously told to the user (who
// was told "read but never written"). The commit-1981076 build then added
// prot_rd_count (still correctly wired/edge-detected) and reported N=1,
// i.e. prot_rd_count==0 -- never read -- which is CONSISTENT with this
// corrected reading (both builds agree: write happens, read never does).
//
// Given read is now confirmed 0 by two independent, consistently-decoded
// results, the next most valuable question is no longer "how many times is
// the read repeated" (it isn't happening at all) but: does the CPU keep
// running normally AFTER the write, reaching its real main loop (which
// kicks the game's own watchdog register, REG_WDOG, per the disassembled
// jsr $8006BA + wdog-kick + loop pattern), or does it stall/crash right
// around the write and never get that far? wdog_kick_ever answers exactly
// this and is already wired into this module. New encoding, bit order
// re-verified via /tmp/check_concat2.v before writing this table:
//   N = 1 + {prot_wr_ever, wdog_kick_ever}   (1..4 flashes per cycle)
//     N=1: wr=0, kick=0 -- protection write never happened AND the CPU
//          never reached its main loop either -- stuck very early in boot,
//          well before both of these.
//     N=2: wr=0, kick=1 -- CPU reaches/kicks its main loop repeatedly, but
//          the protection RAM byte was never written -- would mean the
//          earlier "write" finding does not hold on this run, or the write
//          instruction lies on a path the main loop doesn't take.
//     N=3: wr=1, kick=0 -- confirms the write happens, but the CPU NEVER
//          reaches its main loop afterward -- strongly suggests the CPU
//          stalls or crashes shortly after the protection write, before
//          ever getting to the real game loop (and thus before the
//          protection read too).
//     N=4: wr=1, kick=1 -- the write happens AND the CPU is alive, cycling
//          through its real main loop (kicking the watchdog) -- yet still
//          never executes the protection read. Would point at the read
//          living on a conditional/DIP-gated path never taken, rather than
//          a CPU crash.
//
// HARDWARE RESULT (this build, 2026-07-27): N=3, i.e. wr=1, kick=0 --
// CONFIRMS the protection write happens, but the CPU NEVER reaches its
// main loop (never kicks the watchdog) afterward. This narrows the hang to
// somewhere between the protection write and the main loop, but is still
// ambiguous between "CPU crashed/halted outright" and "CPU is alive but
// looping somewhere in between that never touches the watchdog register".
// REPURPOSED AGAIN to resolve exactly that ambiguity, using a brand-new
// signal (post_wr_fetch_count -- not a re-use of an already-answered one):
//   N = 1 + post_wr_fetch_count   (1..4 flashes per cycle)
//     N=1: post_wr_fetch_count==0 -- ZERO instruction fetches after the
//          write -- the CPU never fetched another instruction post-write.
//          Strongly indicates a hard crash/halt (e.g. double bus fault,
//          CPU well and truly stopped) right at/after the protection write.
//     N=2: post_wr_fetch_count==1 -- exactly one more fetch after the
//          write, then nothing further -- CPU took one more step (likely
//          trapped into an exception vector fetch) then also stopped.
//     N=3: post_wr_fetch_count==2 -- two more fetches -- similar to above,
//          slightly further before stopping.
//     N=4: post_wr_fetch_count==3 (saturated, "3 or more") -- CPU keeps
//          fetching instructions well past the write -- it is NOT a raw
//          crash/halt; it is alive and executing, just looping somewhere
//          that never reaches the watchdog-kick or protection-read
//          addresses specifically. Points at a loop/branch elsewhere in
//          the boot code, not a CPU fault.
//
// HARDWARE RESULT (this build, 2026-07-27): N=4, i.e. post_wr_fetch_count
// saturated at 3 ("3 or more") -- the CPU keeps fetching instructions well
// past the protection write. It is NOT a raw crash/halt; it is alive and
// executing, just never reaching the watchdog-kick or protection-read
// addresses specifically.
// REPURPOSED AGAIN to pursue a more fundamental, unrelated question raised
// by the much-earlier IPL7 (non-maskable) diagnostic build, whose hardware
// result ("magenta", i.e. NOT show_blue) was ambiguous: show_blue requires
// BOTH ipl7_pulse_ever==1 AND isr_ipl7_fetch_ever==0, so seeing magenta
// instead of blue only proves NOT(pulse fired AND never taken) -- it does
// not distinguish "pulse fired and the CPU DID take it" from "pulse never
// got a chance to fire". Both signals already exist and are already wired
// into this module (ipl7_pulse_ever, isr_ipl7_fetch_ever) -- no new RTL
// signals needed, this is a pure formula change. Bit order re-verified via
// /tmp/check_concat3.v before writing this table:
//   N = 1 + {ipl7_pulse_ever, isr_ipl7_fetch_ever}   (1..4 flashes)
//     N=1: pulse=0, taken=0 -- the guaranteed one-shot IPL7 test pulse
//          (fires once, ~1s after hard power-on, held 100 clkena cycles)
//          has not fired yet. Should not occur after more than a couple
//          seconds of runtime; would indicate a measurement problem if seen.
//     N=2: pulse=0, taken=1 -- CPU took a vector fetch that, per the logic,
//          could not have happened without the pulse having fired first.
//          Should be impossible; flags a logic bug in this diagnostic if
//          ever observed.
//     N=3: pulse=1, taken=0 -- DEFINITIVE: the pulse fired and was held for
//          its full window, but the CPU NEVER performed the level-7
//          autovector read. Since level 7 cannot be masked out by the SR
//          on a real 68000/68020, this would point at a fundamental
//          CPU-core/autovector wiring problem affecting ALL interrupt
//          levels uniformly -- independent of the game's own interrupt
//          masking or vector-table contents, and independent of the
//          protection sequence entirely.
//     N=4: pulse=1, taken=1 -- the CPU DOES take a forced, guaranteed
//          unmaskable interrupt when one is correctly asserted -- proving
//          the core's basic autovector/vector-fetch mechanism works. Any
//          earlier failure to take IPL1/2/3 must then be down to
//          game-specific factors (SR interrupt mask, assertion timing/
//          duration, or vector-table contents) rather than a fundamental
//          CPU-interrupt-interface bug.
//
// HARDWARE RESULT (this build, 2026-07-27): N=4, i.e. pulse=1, taken=1 --
// the CPU DOES take a forced, guaranteed unmaskable interrupt correctly.
// The core's basic autovector/vector-fetch mechanism works. Narrows the
// investigation to game-specific factors for why real IPL1/2/3 requests
// are never taken -- not a fundamental CPU/wiring bug.
// REPURPOSED AGAIN to test the leading such factor directly: is the SR
// interrupt mask simply never open (<=0) whenever the REAL vint_latch/
// vblank request asserts as IPL1? In sftm_main.v (this same commit), the
// REAL vint_latch request now drives cpu_ipl to level 7 (non-maskable)
// instead of level 1 for this build only, and the old synthetic ipl7_pulse
// no longer drives cpu_ipl at all -- so isr_ipl7_fetch_ever's meaning is
// now "the real, periodically-recurring (~60 Hz) vblank request was taken
// when presented as non-maskable", not the old one-shot synthetic test.
// show_blue has been hardwired to 0 this build (see above) so the base
// colour/flash-overlay gating stays driven purely by show_stuck, unaffected
// by ipl7_pulse_ever's own independent timer still latching as before.
// Bit order re-verified via /tmp/check_concat4.v before writing this table:
//   N = 1 + {ipl_asserted_ever, isr_ipl7_fetch_ever}   (1..4 flashes)
//     N=1: assert=0, taken=0 -- the vblank interrupt request itself never
//          even asserts. Would be a brand-new finding (already known false
//          from earlier in the session, where ipl_asserted_ever was
//          confirmed 1 -- included here only as a sanity check).
//     N=2: assert=0, taken=1 -- should be impossible (can't take a vector
//          fetch without an assert happening first via this path); flags a
//          logic bug in this diagnostic if ever observed.
//     N=3: assert=1, taken=0 -- the real vblank request keeps asserting
//          periodically, but even forced NON-MASKABLE, the CPU still never
//          takes it. This would be a genuinely surprising new finding,
//          pointing at something specific to the real vint_latch signal
//          path (distinct from the synthetic ipl7_pulse test that DID
//          succeed) rather than SR masking.
//     N=4: assert=1, taken=1 -- CONFIRMS: when the real vblank request is
//          forced non-maskable, the CPU takes it. This proves SR interrupt
//          masking -- not any core wiring or signal-path issue -- is
//          exactly why the real (maskable) IPL1 request is ignored: the
//          boot code runs with interrupts disabled and never reaches the
//          point where it re-enables them, matching the "CPU alive but
//          looping" post_wr_fetch_count finding perfectly.
//
// HARDWARE RESULT (2026-07-28, commit e98093a, i.e. with the priority-
// inversion bug fixed): N=4 -- assert=1, taken=1. CONFIRMED: SR interrupt
// masking is why the real IPL1 vblank request is never serviced. The earlier
// N=3 reading against commit 81cdd14 was indeed an artifact of that bug. The
// forced-IPL7 probe has served its purpose and the interrupt rerouting has
// been REVERTED to normal IPL1 behaviour in sftm_main.v; show_blue is
// restored to its original formula above.
//
// REPURPOSED AGAIN, to the question this all now points at: the CPU is in a
// spin loop with interrupts masked, so it CANNOT be waiting on an ISR flag.
// It must be polling a hardware register that never returns what it wants,
// or spinning purely in RAM/ROM. `poll_region` (new signal in sftm_main.v,
// sample-and-hold ~5 s after hard reset then frozen) identifies which.
// Full rationale and region map are documented at the poll_region logic in
// sftm_main.v. Bit order is a plain 3-bit value here, not a concatenation,
// so no {} ordering hazard applies -- but the +1 offset still does, hence:
//   N = 1 + poll_region   (1..7 flashes)
//     N=1: no I/O read at all -- spinning purely in RAM/ROM.
//     N=2: video/CRTC. N=3: inp/sys/dip. N=4: DUART. N=5: NVRAM.
//     N=6: palette/read-as-zero. N=7: protection port.
//
// HARDWARE RESULT (commit 6748cc9, 2026-07-28): **N=1**. The CPU performs NO
// I/O data read of any kind in steady state -- it is not polling any hardware
// register at all, so this is NOT a failed hardware handshake. It rules out
// the video/CRTC prime suspect and every other region at once. Combined with
// "still fetching instructions indefinitely" and "interrupts masked", this is
// highly characteristic of a catch-all exception handler (classically a
// branch-to-self, which fetches forever but reads no data), or of executing
// garbage.
//
// REPURPOSED AGAIN, to that question: did the CPU take an EXCEPTION, and
// which one? `exc_vec` (new signal in sftm_main.v) watches for READS of the
// 68k vector table at byte 0x000-0x3FF, which are ROM-content-independent
// proof that exception processing began for a specific vector. Full rationale
// and category map are documented at the exc_vec logic in sftm_main.v.
//   N = 1 + exc_vec   (1..7 flashes)
//     N=1: NO exception vector ever fetched -- the CPU never faulted, so it
//          reached this loop by normal program flow. That makes it a
//          deliberate wait/delay loop, and since it reads no hardware and no
//          interrupt can fire, it would be waiting on something that can
//          never change -- suggesting the code took a wrong branch earlier.
//     N=2: BUS ERROR (vector 2) -- an access to an address that did not
//          respond. Would point directly at our own address decoding or
//          SDRAM/bus handling, i.e. a core bug rather than a game behaviour.
//     N=3: ADDRESS ERROR (vector 3) -- misaligned word/long access; usually a
//          corrupted pointer or stack, or executing garbage.
//     N=4: ILLEGAL INSTRUCTION (vector 4) -- executing data as code, i.e. a
//          wild jump through a bad pointer or an uninitialised vector.
//     N=5: PRIVILEGE VIOLATION / LINE-A / LINE-F (vectors 8, 10, 11) -- also
//          typical of executing garbage, OR a 68020-specific opcode that our
//          TG68K core does not implement (this is a 68020 game on a core
//          that is not a full 68020, so this outcome is quite plausible and
//          would be very actionable).
//     N=6: OTHER exception (zero divide, CHK, TRAPV, trace, TRAP #n, ...).
//     N=7: INTERRUPT AUTOVECTOR (vectors 24-31) -- an interrupt actually
//          serviced. Expected never to appear given interrupts are masked.
//
// HARDWARE RESULT (commit 00f0035, 2026-07-28): **N=5** -- the CPU DID take an
// exception, in the PRIVILEGE VIOLATION / LINE-A / LINE-F group (vector 8, 10
// or 11). So the steady-state loop IS a dead-end fault handler, confirming the
// branch-to-self hypothesis. Since that category covers three quite different
// causes it must now be split.
//
// REPURPOSED AGAIN to `exc_detail`, which splits that group into individual
// vectors AND simultaneously tests the strongest remaining hypothesis, so no
// extra hardware round trip is spent. That hypothesis: the CPU data-in mux in
// sftm_main.v ends in `default: inp_mux = 16'hffff`, so ANY read of an
// UNMAPPED address returns 0xFFFF -- and 0xFFFF is itself a line-F opcode.
// If the CPU jumps into unmapped space, every fetch returns 0xFFFF and it
// takes a line-F exception immediately. `last_fetch_ff` records whether the
// last fetched word was 0xFFFF, which separates that from a real coprocessor
// opcode in valid code. Full rationale, and an honest caveat about 68k
// prefetch weakening the non-0xFFFF direction, are at the logic in sftm_main.v.
//   N = 1 + exc_detail   (1..7 flashes)
//     N=1: no fault captured at all. Would CONTRADICT the N=5 result above and
//          mean the failure is non-deterministic between runs -- itself an
//          important finding rather than a null result.
//     N=2: PRIVILEGE VIOLATION (vector 8) -- a privileged instruction executed
//          in user mode. Would imply the CPU is not in supervisor state when
//          it should be, pointing at S-bit / RTE / stack-frame handling.
//     N=3: LINE-A (vector 10) -- an 0xAxxx opcode, which is unused on the 68k
//          and appears in no real compiler output, so this means executing
//          garbage data as code.
//     N=4: LINE-F (vector 11) **with the last fetch == 0xFFFF** -- STRONGEST
//          DIAGNOSIS: the CPU has jumped into UNMAPPED address space and is
//          fetching the mux default. The bug is then in our address decoding /
//          ROM mapping, or in whatever computed that jump target -- a core
//          bug, and one we can chase directly.
//     N=5: LINE-F (vector 11) with the last fetch NOT 0xFFFF -- a genuine
//          0xFxxx coprocessor/extension opcode. TG68K is instantiated in
//          68020 mode with MUL/DIV/BitField/extAddr extensions enabled, but
//          coprocessor (F-line) instructions are still unimplemented, so this
//          would mean the game really does use one. Treat with the prefetch
//          caveat in mind: this does not fully exclude the unmapped theory.
//     N=6: ILLEGAL INSTRUCTION (vector 4) -- would contradict N=5 above.
//     N=7: any OTHER vector -- also contradicts N=5; suggests
//          non-determinism or a probe problem.
localparam [5:0] FLASH_ON  = 6'd30;
localparam [5:0] FLASH_SEG = 6'd60;
localparam [6:0] FLASH_HOLD = 7'd90;

wire [2:0] flash_count = 3'd1 + exc_detail;

reg        flash_state;    // 0 = flashing, 1 = holding (steady, no flash)
reg [5:0]  flash_seg_pos;  // 0..59 within the current 60-frame flash segment
reg [2:0]  flash_done;     // number of completed flashes so far this cycle
reg [6:0]  flash_hold_pos; // 0..89 within the post-cycle hold period

always @(posedge clk) begin
    if( rst ) begin
        flash_state    <= 1'b0;
        flash_seg_pos  <= 6'd0;
        flash_done     <= 3'd0;
        flash_hold_pos <= 7'd0;
    end else if( vblank_irq ) begin
        if( !flash_state ) begin
            if( flash_seg_pos == FLASH_SEG - 6'd1 ) begin
                flash_seg_pos <= 6'd0;
                if( flash_done + 3'd1 >= flash_count ) begin
                    flash_done  <= 3'd0;
                    flash_state <= 1'b1;
                end else begin
                    flash_done <= flash_done + 3'd1;
                end
            end else begin
                flash_seg_pos <= flash_seg_pos + 6'd1;
            end
        end else begin
            if( flash_hold_pos == FLASH_HOLD - 7'd1 ) begin
                flash_hold_pos <= 7'd0;
                flash_state    <= 1'b0;
            end else begin
                flash_hold_pos <= flash_hold_pos + 7'd1;
            end
        end
    end
end

wire flash_on    = !flash_state && (flash_seg_pos < FLASH_ON);

// BITS_MODE must be declared before flash_white below, which reads it --
// iverilog will not bind a localparam referenced in a continuous assign
// ahead of its own declaration, even though it is otherwise a compile-time
// constant. (Pre-existing ordering bug found while adding exc_code_ram;
// unrelated to that change -- the same failure reproduces on unmodified
// HEAD.) The rest of the ON-SCREEN BIT DISPLAY block below still declares
// BUILD_ID/BITS_H0 and the row logic in one place for readability.
localparam       BITS_MODE = 1'b1;

// Flash overlay SUPPRESSED while the bit display is active: it whites out the
// whole screen periodically, which would obscure the bit rows below.
wire flash_white = show_stuck & flash_on & ~BITS_MODE;

// ---------------------------------------------------------------------------
// ON-SCREEN BIT DISPLAY
//
// Flash-counting has carried the diagnosis a long way but costs one hardware
// round trip per single small integer, and the last two rounds both happened
// to read 5 with DIFFERENT meanings, which is exactly the kind of collision
// that can silently invalidate a conclusion. This renders several multi-bit
// values simultaneously as rows of blocks, so one flash gives the exact vector
// number AND the faulting address AND a build ID, with no counting and no
// ambiguity about which build is loaded.
//
// Layout: rows of 8px-wide blocks (6px lit, 2px gutter), MSB at the LEFT. A
// one-bit reads WHITE. A zero-bit reads dark, and the dark shade ALTERNATES
// every 4 bits (navy / maroon) so nibble groups are visually obvious and can
// be read straight off as hex digits.
//
// WIDTH CONSTRAINT LEARNED FROM HARDWARE (2026-07-28): although the active
// area is 384 px wide (VR_HBSTART=384), a photo of the real monitor showed
// only roughly the LEFT HALF (~192 px) actually reaching the screen -- the
// display is being stretched about 2x horizontally. The previous 24-block row
// started at x=48 and ran to x=240, so its last ~6 blocks were CUT OFF and the
// low bits of the address were unreadable. Everything here must therefore fit
// inside about x=0..176. Max row is 16 blocks = 128 px starting at x=24, so it
// ends at x=152, leaving margin at both edges.
//
//   Row 1: 16 bits = { BUILD_ID[3:0], exc_vec_num[7:0], exc_last_ff,
//                      exc_detail[2:0] }   <- build stamp is the LEFTMOST
//                      nibble, so it can be checked at a glance. Only
//                      BUILD_ID and exc_last_ff (bits 11 and the low 3 of
//                      exc_detail's slot -- see caveat below) are trustworthy
//                      here; exc_vec_num/exc_detail share exc_vec's
//                      RETRACTED first-hit-on-address-match latch mechanism.
//   Row 2: 12 bits = pc_snapshot_addr[23:12] (upper 3 hex digits)
//   Row 3: 12 bits = pc_snapshot_addr[11:0]  (lower 3 hex digits)
//   Row 4: 16 bits = pc_snapshot_word        (instruction word fetched there)
//   Row 5: 16 bits = exc_code_ram            (RAM[0x0FBE] -- the game's OWN
//                     recorded exception code; see sftm_main.v port comment)
//
// Rows 2-4 previously showed exc_fetch_addr/exc_fetch_word, RETRACTED as
// unreliable (AGENTS.md ROM CROSS-CHECK / "ROM fetch path cleared"): that
// mechanism froze on the FIRST read matching an address range, which the
// power-on RAM self-test satisfies incidentally while sweeping every RAM
// address. pc_snapshot_addr/word instead freeze on a fixed TIME (~5s after
// reset, sftm_main.v's poll_armed) regardless of which address is touched,
// so they cannot be fooled the same way -- see the port comment there.
//
// The address is split across two 12-bit rows rather than one 24-bit row
// purely to respect the width limit above.
//
// BUILD_ID is hardcoded and incremented whenever this display changes, so
// every reading is self-identifying and the "is the new core actually loaded?"
// ambiguity can never recur.
localparam [3:0] BUILD_ID  = 4'h8;
localparam [9:0] BITS_H0   = 10'd24;

wire [9:0] bits_x    = hcnt - BITS_H0;
wire [4:0] bit_slot  = bits_x[7:3];        // which block: (hcnt-BITS_H0)/8
wire [2:0] bits_sub  = bits_x[2:0];        // position within the block

wire bits_row1 = (vcnt >= 10'd40)  && (vcnt < 10'd64);
wire bits_row2 = (vcnt >= 10'd80)  && (vcnt < 10'd104);
wire bits_row3 = (vcnt >= 10'd120) && (vcnt < 10'd144);
wire bits_row4 = (vcnt >= 10'd160) && (vcnt < 10'd184);
wire bits_row5 = (vcnt >= 10'd200) && (vcnt < 10'd224);

wire [4:0]  bits_n   = (bits_row2 || bits_row3) ? 5'd12 : 5'd16;
wire [23:0] bits_val = bits_row1 ? { 8'd0, BUILD_ID, exc_vec_num, exc_last_ff, exc_detail }
                     : bits_row2 ? { 12'd0, pc_snapshot_addr[23:12] }
                     : bits_row3 ? { 12'd0, pc_snapshot_addr[11:0]  }
                     : bits_row4 ? { 8'd0,  pc_snapshot_word }
                     :             { 8'd0,  exc_code_ram };

// Two guards that are easy to get wrong and would each produce a WRONG but
// plausible-looking display:
//  1. hcnt >= BITS_H0, because bits_x underflows and wraps to a large value
//     to the left of the display origin.
//  2. bits_x < 192, because bit_slot is sliced as bits_x[7:3] and therefore
//     ALIASES every 256 pixels -- without this the rows would be redrawn a
//     second time further right, which could easily be misread as extra bits.
wire bits_active = BITS_MODE && diag_phase
                   && (bits_row1 || bits_row2 || bits_row3 || bits_row4 || bits_row5)
                   && (hcnt >= BITS_H0) && (bits_x < 10'd128)
                   && (bit_slot < bits_n) && (bits_sub < 3'd6);
wire bits_one    = bits_val[ bits_n - 5'd1 - bit_slot ];   // MSB leftmost

assign red   = startup_phase ? 5'h1F
             : bits_active   ? (bits_one ? 5'h1F : (bit_slot[2] ? 5'h00 : 5'h0C))
             : diag_phase    ? (flash_white ? 5'h1F : show_green ? 5'h00 : show_blue ? 5'h00 : show_orange ? 5'h1F : show_magenta ? 5'h1F : show_maroon ? 5'h1F : show_lilac ? 5'h1F : (!wdog_kick_ever ? 5'h1F : 5'h00))
             : show_raster   ? dbg_r
             : (gfx_en[0] ? pal_rgb[14:10] : 5'd0);
assign green = startup_phase ? 5'h1F
             : bits_active   ? (bits_one ? 5'h1F : 5'h00)
             : diag_phase    ? (flash_white ? 5'h1F : show_green ? 5'h1F : show_blue ? 5'h00 : show_orange ? 5'h0A : show_magenta ? 5'h00 : show_maroon ? 5'h00 : show_lilac ? 5'h0A : ( boot_done_ever ? 5'h1F : 5'h00))
             : show_raster   ? dbg_g
             : (gfx_en[0] ? pal_rgb[ 9: 5] : 5'd0);
assign blue  = startup_phase ? 5'h1F
             : bits_active   ? (bits_one ? 5'h1F : (bit_slot[2] ? 5'h0C : 5'h00))
             : diag_phase    ? (flash_white ? 5'h1F : show_green ? 5'h00 : show_blue ? 5'h1F : show_orange ? 5'h00 : show_magenta ? 5'h1F : show_maroon ? 5'h0A : show_lilac ? 5'h1F : ( nvram_wr_ever ? 5'h1F : 5'h00))
             : show_raster   ? dbg_b
             : (gfx_en[0] ? pal_rgb[ 4: 0] : 5'd0);

// ---------------------------------------------------------------------------
// IT42 blitter
// ---------------------------------------------------------------------------
sftm_blitter u_blitter(
    .rst        ( rst           ),
    .clk        ( clk           ),
    // command / parameters from the register file
    .r_command  ( vregs[VR_COMMAND]  ),
    .r_flags    ( vregs[VR_XFERFLG]  ),
    .r_width    ( vregs[VR_XFERW]    ),
    .r_height   ( vregs[VR_XFERH]    ),
    .r_x        ( vregs[VR_XFERX]    ),
    .r_y        ( vregs[VR_XFERY]    ),
    .r_addrlo   ( vregs[VR_ADDRLO]   ),
    .r_addrhi   ( vregs[VR_ADDRHI]   ),
    // clip rect (registered pixel coordinates)
    .r_leftclip ( vregs[VR_LEFTCLIP][11:0]  ),
    .r_rightclip( vregs[VR_RIGHTCLIP][11:0] ),
    .r_topclip  ( vregs[VR_TOPCLIP][11:0]   ),
    .r_botclip  ( vregs[VR_BOTCLIP][11:0]   ),
    // source / destination stepping
    .r_srcxstep ( vregs[VR_SRCXSTEP]        ),
    .r_dstxstep ( vregs[VR_DSTXSTEP]        ),
    .r_dstystep ( vregs[VR_DSTYSTEP]        ),
    .start      ( blit_start          ),
    .plane_sel  ( plane_en[1] & ~plane_en[0] ),
    .grom_bank  ( grom_bank          ),
    // GROM read
    .grom_addr  ( grom_addr     ),
    .grom_data  ( grom_data     ),
    .grom_cs    ( grom_cs       ),
    .grom_ok    ( grom_ok       ),
    // VRAM write
    .vram_we    ( blt_we        ),
    .vram_addr  ( blt_waddr     ),
    .vram_data  ( blt_wdata     ),
    .vram_plane ( blt_plane     ),
    .done       ( blit_done     )
);

// scan_irq and blit_irq are driven directly from int_state without VR_INTEN
// gating. On real itech32 hardware, interrupt routing is handled by the LINC
// chip (external to the IT42). The IT42's VR_INTEN register is NOT what gates
// the CPU interrupts; the LINC chip always enables them. Without this fix,
// VR_INTEN = 0 (never written) would suppress both IRQs forever.
always @(posedge clk) begin
    if( rst ) begin blit_irq <= 1'b0; scan_irq <= 1'b0; end
    else begin
        blit_irq <= |(int_state_n & VIDEOINT_BLITTER);
        scan_irq <= |(int_state_n & VIDEOINT_SCANLINE);
    end
end

// grm3 not used in first pass
assign grm3_addr = 18'd0;
assign grm3_cs   = 1'b0;

endmodule
