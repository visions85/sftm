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
    // after each VBlank. Drives bit 6 of VR_XFER reads so the VBlank ISR at
    // $801380 can poll for end-of-vblank (it loops writing $0040 to VR_XFER
    // and reading $500005 bit 6 until the window expires).
    input               vint_latch,

    // Diagnostic: first watchdog kick by the main CPU outer loop.
    input               wdog_kick_ever,

    // Diagnostic: boot copy completed at least once.
    // B=0 → boot copy stuck (SDRAM issue); B=1+G=0 → CPU crashes after boot.
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
// Encodes two orthogonal progress flags as RGB:
//   R = !wdog_kick_ever   (watchdog NOT yet kicked)
//   G =  wdog_kick_ever   (watchdog kicked = CPU reached main init code)
//   B =  boot_done_ever   (repurposed = rom_ok_ever: SDRAM served CPU ROM fetch)
//                         latches on first rom_ok during prog_sel+bus_active
//
// Resulting colours:
//   RED     (G=0,B=0): no wdog, SDRAM never responded to CPU ROM fetch
//                      → cache/SDRAM hung after boot copy
//   MAGENTA (G=0,B=1): SDRAM served ROM data but CPU never kicked watchdog
//                      → CPU got ROM data but crashed before $8015AA
//                        (wrong instructions? exception? RAM test fail?)
//   GREEN   (G=1,B=0): wdog kicked, no ROM ok? (should be impossible)
//   CYAN    (G=1,B=1): both → CPU running normally, heading toward blitter
wire [4:0] dbg_r = hcnt[6:2];
wire [4:0] dbg_g = vcnt[5:1];
wire [4:0] dbg_b = {hcnt[8], vcnt[7], 3'd0};
wire       show_raster = startup_phase | ~gfx_en[3];
assign red   = startup_phase ? 5'h1F
             : diag_phase    ? (!wdog_kick_ever ? 5'h1F : 5'h00)
             : show_raster   ? dbg_r
             : (gfx_en[0] ? pal_rgb[14:10] : 5'd0);
assign green = startup_phase ? 5'h1F
             : diag_phase    ? ( wdog_kick_ever ? 5'h1F : 5'h00)
             : show_raster   ? dbg_g
             : (gfx_en[0] ? pal_rgb[ 9: 5] : 5'd0);
assign blue  = startup_phase ? 5'h1F
             : diag_phase    ? ( boot_done_ever ? 5'h1F : 5'h00)
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
