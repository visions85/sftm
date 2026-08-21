`timescale 1ns/1ps
/*  This file is part of SFTM.
    SFTM is free software: you can redistribute it and/or modify it under the
    terms of the GNU General Public License as published by the Free Software
    Foundation, either version 3 of the License, or (at your option) any later
    version. See the LICENSE file.

    Street Fighter: The Movie -- IT42 video. Literal port of MAME
    src/mame/itech/itech32_v.cpp (see doc/PHASE2-DESIGN.md).

    This module owns:
      - the m_video[] register file with bloodstm addressing: CPU longword
        address 0x500000 + 4*k maps to 16-bit register k, mirrored in both
        halves (bloodstm_video_w -> video_w(offset/2), :1460)
      - video_w side effects (:1335): INTACK, INTENABLE, INTSCANLINE, and
        command dispatch into sftm_blit
      - video_r (:1438): reg 0 = (val & ~8)|4|1, reg 3 = 0xef
      - interrupt levels (update_interrupts, :367)
      - palette RAM (0x580000-0x59ffff, 32-bit readback; pens are xRGB_888,
        itech32.cpp:1902) and the pen->RGB scanout lookup
      - CRT timing (fixed 508x286 / visible 384x256, the sftm raw params,
        itech32.cpp:1785) and single-plane scanout (screen_update :1510;
        sftm has m_planes = 1)

    Drawing lives in sftm_blit; VRAM (SDRAM) access in sftm_vram. Because
    blits take real time here (MAME's are instantaneous), cpu_wait stalls
    CPU access to VIDEO_COMMAND / VIDEO_TRANSFER while the blitter runs.

    Still TODO (acceptable for first light-up): dynamic CRTC reconfiguration
    from VIDEO_HTOTAL/VTOTAL et al. (:1402) -- sftm programs the same
    508x286 the fixed timing implements; XORIGIN2/YORIGIN2/XSCROLL2 (plane 1
    is never scanned out on sftm).
*/

module sftm_video(
    input             rst,
    input             clk,
    input             pxl_cen,     // 8 MHz

    // CPU bus from sftm_main
    input      [23:1] cpu_addr,
    input      [15:0] cpu_dout,
    input             cpu_uds_n,
    input             cpu_lds_n,
    input             bus_wstb,
    input             vreg_cs,
    input             pal_cs,
    output     [15:0] vreg_dout,
    output     [15:0] pal_dout,
    output            cpu_wait,    // stall COMMAND/TRANSFER access while busy

    // latches from sftm_main
    input      [ 1:0] plane_en,
    input      [ 1:0] grom_bank,
    input      [ 6:0] color_latch0,
    input      [ 6:0] color_latch1,

    // graphics ROM buses (blitter source)
    // grom is split across two banks; see sftm_blit.v
    output     [23:1] grom0_addr,
    input      [15:0] grom0_data,
    output            grom0_rd,
    input             grom0_ok,
    output     [23:1] grom1_addr,
    input      [15:0] grom1_data,
    output            grom1_rd,
    input             grom1_ok,
    output     [18:1] grm3_addr,
    input      [15:0] grm3_data,
    output            grm3_rd,
    input             grm3_ok,

    // VRAM SDRAM bus (64-bit cache lane, 4 pens per word)
    output     [20:3] vram_addr,
    input      [63:0] vram_data,
    output     [63:0] vram_din,
    output     [ 7:0] vram_dsn,
    output            vram_we,
    output            vram_rd,
    input             vram_ok,

    // interrupts to sftm_main
    output reg        vblank_irq,  // 1-clk pulse (generate_int1 hook)
    output            blit_irq,
    output            scan_irq,

    // video out
    output reg        HS,
    output reg        VS,
    output reg        LHBL,
    output reg        LVBL,
    output reg [ 4:0] red,
    output reg [ 4:0] green,
    output reg [ 4:0] blue,
    input      [ 3:0] gfx_en,
    input      [ 7:0] debug_bus,

    // Blitter throughput, for the truncated-background investigation. All
    // three counts are in the SAME units (cycles/65536) so they compare
    // directly; a 384x240 frame is 800k clk, i.e. about 12 units.
    output reg [ 3:0] st_bbusy,   // cycles the blitter was busy
    output reg [ 3:0] st_bwait,   // ...of which stalled on a GROM fetch
    // RATE meters, not stall flags. A "stalled on the write port" reading
    // (busy && !vw_free) saturates the moment the blitter runs -- it produces
    // pixels faster than any SDRAM absorbs them, so the FIFO is always full
    // and the reading is 12 whether writes drain at 9 clk or 2227. That is
    // why the arbiter rework showed no change on the old counter. These count
    // work COMPLETED instead, in units of 8192 per frame.
    output reg [ 3:0] st_bwr,     // VRAM writes issued
    output reg [ 3:0] st_bgf,     // GROM words fetched
    output reg [ 3:0] st_bstw,    // ...stalled on the VRAM write FIFO
    output reg [ 3:0] st_fper,    // clk between frame_end pulses / 65536
    // Full-resolution copies of the same per-frame counters, for the JTAG
    // probe. The 4-bit versions above are quantised (writes/8192, clk/65536)
    // only because the on-screen overlay is 8 bits wide; a screen updating a
    // few thousand pixels a frame reads 0 in every one of them, which is
    // exactly what made the blitter look idle while it was plainly drawing.
    output reg [19:0] stw_wr,     // VRAM writes this frame, EXACT
    output reg [19:0] stw_busy,   // blitter busy clk, EXACT
    output reg [19:0] stw_wait,   // ...of which GROM fetch stall
    output reg [19:0] stw_stw,    // ...of which write-FIFO stall
    output reg [19:0] stw_fper,   // frame period in clk
    output reg [19:0] stw_gf,     // blit_gdone pulses
    output reg [ 7:0] stw_num,    // blits started this frame (wider, saturating)
    // Is the CPU talking to the video hardware at ALL? The blitter starts on
    // cmd_stb = vreg_wr && ridx==R_COMMAND (:286), so if the CPU never writes
    // COMMAND no blit can ever run -- which is what a flat-zero blit_busy over
    // 90 s means. These separate "the CPU never asks" from "the blitter is
    // asked and does not start".
    output reg [19:0] stw_vreg,   // CPU video-register writes this frame
    output reg [19:0] stw_cmd,    // ...of which COMMAND (blit starts)
    output reg [19:0] stw_xfer,   // ...of which TRANSFER (cmd-3 pixel pushes)
    output reg [19:0] stw_rd,     // VRAM read strobes (scanout/prefetch)
    output reg [ 3:0] st_bnum,    // blits started in that frame (saturating)
    // background-streak probe, see below
    output reg [14:0] st_gpen,     // pen from the frame with the most green
    output reg        st_gseen,    // green seen at all (control)
    output reg [ 3:0] st_gcnt,     // green pixels that frame / 256
    output reg        st_gmulti,   // >1 distinct pen produced green that frame
    output reg        st_palhit,   // CPU has written palette[st_gpen]
    output reg [ 7:0] st_palcnt
);

// blitter constants (itech32_v.cpp:117)
localparam [15:0] VIDEOINT_SCANLINE = 16'h0004,
                  VIDEOINT_BLITTER  = 16'h0040;

// register indices (byte offset / 2)
localparam [5:0] R_INTSTATE    = 6'h01,   // 0x02
                 R_TRANSFER    = 6'h02,   // 0x04
                 R_COMMAND     = 6'h04,   // 0x08
                 R_INTENABLE   = 6'h05,   // 0x0a
                 R_INTSCANLINE = 6'h16,   // 0x2c
                 R_YORIGIN1    = 6'h22,   // 0x44
                 R_XORIGIN1    = 6'h26;   // 0x4c

// ---------------------------------------------------------------------------
// Register file
// ---------------------------------------------------------------------------
reg [15:0] vregs[0:63];
reg [15:0] vreg_q;

wire [5:0] ridx    = cpu_addr[7:2];
wire       vreg_wr = bus_wstb && vreg_cs;

wire        blit_busy, blit_done, c3_active;
wire        blit_stallw, blit_waiting, blit_gdone, vram_wpop;

// ---------------------------------------------------------------------------
// Blitter throughput measurement.
//
// The fight-stage background is drawn only down to a VARYING row (92/145/144
// on three consecutive frames) and the rest stays black, while every small
// blit -- sprites, HUD, glyphs, character portraits -- is perfect. A varying
// cutoff means the blit is not finishing, so the question is what it is
// waiting for. This counts, per frame, the cycles the blitter was busy and how
// many of those it spent stalled on a GROM read versus stalled on the VRAM
// write port.
//
// Reported from the frame with the LARGEST busy count rather than the latest:
// the background blit happens on some frames and not others, and sampling an
// arbitrary frame would usually catch an idle one. All four values are latched
// together from that same frame so they are always coherent -- an earlier
// diagnostic in this core reported an id and a result from different frames
// and could never be paired.
//
// st_bbusy is also the control: the blitter demonstrably draws sprites every
// frame, so a reading of 0 means the instrument itself is broken, not that the
// blitter is idle.
// ---------------------------------------------------------------------------
reg [19:0] bc_busy, bc_wait, bc_stw;
reg [19:0] fp_cnt;   // clocks since the last frame_end
reg [19:0] bc_wr, bc_gf;
reg [ 3:0] bc_num;
reg [ 7:0] bc_num8;
reg        lvbl_d, busy_d;
wire       frame_end = lvbl_d && !LVBL;
wire       blit_rise = blit_busy && !busy_d;

always @(posedge clk) begin
    if( rst ) begin
        bc_busy <= 0; bc_wait <= 0; bc_wr <= 0; bc_gf <= 0;
        bc_num  <= 0; bc_num8 <= 0; bc_stw <= 0; fp_cnt <= 0; st_fper <= 0;
        st_bbusy<= 0; st_bwait<= 0; st_bwr <= 0; st_bgf <= 0; st_bnum <= 0;
        st_bstw <= 0;
        stw_wr <= 0; stw_busy <= 0; stw_wait <= 0; stw_stw <= 0;
        stw_fper <= 0; stw_gf <= 0; stw_num <= 0;
        lvbl_d  <= 0; busy_d  <= 0;
    end else begin
        lvbl_d <= LVBL;
        busy_d <= blit_busy;
        if( frame_end ) begin
            // EVERY frame, not the best one. These used to latch only when
            // bc_busy beat a running maximum that never decayed, so they froze
            // on the single busiest frame since reset and reported it forever.
            // That peak read bc_busy[19:16]=F, i.e. >=983,040 clk, which is
            // longer than a whole frame (508*286*6 = 871,728) -- an outlier
            // where frame_end was missed and two frames accumulated. Reading
            // typical behaviour off it is not possible.
            //
            // Now [19:12], so one unit is 4096 rather than 8192/65536:
            // SINGLE NIBBLE each, deliberately. Widening these to 8 bits meant
            // showing them as two views, and consecutive views are sampled from
            // different snapshots, so the halves never belonged to the same
            // number -- that is what produced a write count larger than the busy
            // time containing it. One self-contained nibble per view cannot be
            // mispaired.
            //   bwr   in units of 8192 : one full background 92,160 = 11 (0xB)
            //   busy  in units of 65536: a whole frame       871,728 = 13 (0xD)
            //   wait/stw same units as busy, so they compare directly to it
            st_bbusy <= bc_busy[19:16];
            st_bwait <= bc_wait[19:16];
            st_bwr   <= bc_wr[19:13] > 7'd15 ? 4'd15 : bc_wr[16:13];
            st_bgf   <= bc_gf[19:13] > 7'd15 ? 4'd15 : bc_gf[16:13];
            st_bnum  <= bc_num;
            st_bstw  <= bc_stw [19:16];
            bc_busy <= 0; bc_wait <= 0; bc_wr <= 0; bc_gf <= 0; bc_num <= 0;
            bc_stw  <= 0; bc_num8 <= 0;
            // How long a frame ACTUALLY is, measured rather than assumed.
            // 508*286*6 = 871,728 clk at JTFRAME_PXLCLK=8 on a 48 MHz clock,
            // so this must read 13 (0xD). bc_busy is reset here and therefore
            // cannot exceed the same 0xD -- yet hardware reports 0xF for it.
            // Simulation (ver/game/tb_frameend.v) shows frame_end firing once
            // per frame at exactly 871,728 clk, so either the hardware frame is
            // longer than the timing implies or frame_end is being missed
            // there. This nibble distinguishes the two: 0xD means the frame is
            // what it should be and the busy reading is the anomaly; anything
            // larger means the frame itself is longer and busy=0xF is simply a
            // blitter busy the whole of it.
            st_fper <= fp_cnt[19:16];
            stw_wr   <= bc_wr;
            stw_busy <= bc_busy;
            stw_wait <= bc_wait;
            stw_stw  <= bc_stw;
            stw_fper <= fp_cnt;
            stw_gf   <= bc_gf;
            stw_num  <= bc_num8;
            fp_cnt  <= 0;
        end else begin
            if( blit_busy               && ~&bc_busy ) bc_busy <= bc_busy + 20'd1;
            // TWO different stalls, and only the first used to be counted:
            //   blit_waiting = fetch_req && !fetch_ok  -- GROM fetch  (blit:302)
            //   blit_stallw  = busy && !vw_free        -- write FIFO  (blit:359)
            // S_PIX advances one pixel per clock when fetch_ok && vw_free, so
            // busy time is productive + these two. Counting only the GROM
            // stall made the write port -- the original bottleneck -- invisible.
            if( blit_busy && blit_waiting&& ~&bc_wait ) bc_wait <= bc_wait + 20'd1;
            if( blit_stallw             && ~&bc_stw  ) bc_stw  <= bc_stw  + 20'd1;
            if( vram_wpop               && ~&bc_wr   ) bc_wr   <= bc_wr   + 20'd1;
            if( blit_gdone              && ~&bc_gf   ) bc_gf   <= bc_gf   + 20'd1;
            if( blit_rise               && ~&bc_num  ) bc_num  <= bc_num  + 4'd1;
            if( blit_rise               && ~&bc_num8 ) bc_num8 <= bc_num8 + 8'd1;
            if(                            ~&fp_cnt ) fp_cnt  <= fp_cnt  + 20'd1;
        end
    end
end
wire [15:0] xfer_rdata;

// video_r special cases (:1438); VIDEO_TRANSFER reads return the cmd-3 old
// pixel while a transfer is armed (:1355 stores it in the register)
assign vreg_dout = ridx == 6'd0       ? ((vreg_q & ~16'h0008) | 16'h0004 | 16'h0001) :
                   ridx == 6'd3       ? 16'h00ef :
                   ridx == R_TRANSFER && c3_active ? xfer_rdata :
                   vreg_q;


assign scan_irq = |(vregs[R_INTSTATE] & vregs[R_INTENABLE] & VIDEOINT_SCANLINE);
assign blit_irq = |(vregs[R_INTSTATE] & vregs[R_INTENABLE] & VIDEOINT_BLITTER);

// stall CPU access to COMMAND/TRANSFER while a command or transfer runs
assign cpu_wait = vreg_cs && (ridx == R_COMMAND || ridx == R_TRANSFER)
                  && blit_busy;

// command / transfer strobes into the blitter
wire cmd_stb  = vreg_wr && ridx == R_COMMAND;
wire xfer_stb = vreg_wr && ridx == R_TRANSFER;

// ---------------------------------------------------------------------------
// CPU-side video traffic, counted per frame.
//
// Separate block, placed here deliberately: cmd_stb, xfer_stb and line_base are
// all declared below the main counter block, and Verilog will not let that
// block reference them.
//
// blit_busy read EXACTLY zero for 90 s while the attract demo was animating.
// sftm_vram is the only VRAM writer and only the blitter drives its write port,
// so nothing else can be drawing. These say which half is at fault:
//   stw_cmd == 0 -> the CPU never asks for a blit
//   stw_cmd  > 0 -> it asks and the blitter refuses to start
// ---------------------------------------------------------------------------
reg [19:0] bc_vreg, bc_cmd, bc_xfer, bc_rd;

always @(posedge clk) begin
    if( rst ) begin
        bc_vreg  <= 0; bc_cmd  <= 0; bc_xfer  <= 0; bc_rd  <= 0;
        stw_vreg <= 0; stw_cmd <= 0; stw_xfer <= 0; stw_rd <= 0;
    end else if( frame_end ) begin
        stw_vreg <= bc_vreg;  stw_cmd  <= bc_cmd;
        stw_xfer <= bc_xfer;  stw_rd   <= bc_rd;
        bc_vreg  <= 0; bc_cmd <= 0; bc_xfer <= 0; bc_rd <= 0;
    end else begin
        if( vreg_wr  && ~&bc_vreg ) bc_vreg <= bc_vreg + 20'd1;
        if( cmd_stb  && ~&bc_cmd  ) bc_cmd  <= bc_cmd  + 20'd1;
        if( xfer_stb && ~&bc_xfer ) bc_xfer <= bc_xfer + 20'd1;
        if( vram_rd  && ~&bc_rd   ) bc_rd   <= bc_rd   + 20'd1;
    end
end

// ---------------------------------------------------------------------------
// CRT counters: fixed 508 x 286, visible 384 x 256
// ---------------------------------------------------------------------------
reg [8:0] hcnt, vcnt;
wire      line_end = hcnt == 9'd507;

// MAME arms the scanline interrupt with time_until_pos(VIDEO_INTSCANLINE)
// (itech32_v.cpp:383/1399), and screen_device::time_until_pos normalises the
// target modulo the screen height -- so a value past the end of the frame
// still fires, one frame's worth later. An exact compare here would silently
// never match and stall the game's whole raster-split chain (the QINT handler
// reloads INTSCANLINE from a table every split, so one bad value would wedge
// it permanently).
// Reduce iteratively rather than with a couple of conditional subtracts: the
// game computes INTSCANLINE as RAM[0x1118]-1, so an uninitialised source
// yields 0xFFFF, which needs 229 subtractions of 286 -- far beyond what two
// stages reach. INTSCANLINE changes at most a few times per frame, so a
// one-subtract-per-clock reduction settles long before it is next needed.
reg        b2_d;      // delayed INTSTATE bit2, for edge detection
reg [15:0] isl_mod;
always @(posedge clk) begin
    if( rst )
        isl_mod <= 16'd0;
    else if( vreg_wr && ridx == R_INTSCANLINE )
        isl_mod <= cpu_dout;
    else if( isl_mod >= 16'd286 )
        isl_mod <= isl_mod - 16'd286;
end

wire scanline_hit = pxl_cen && line_end && vcnt == isl_mod[8:0];


always @(posedge clk) begin
    if( rst ) begin
        b2_d        <= 1'b0;
    end else begin
        if( vreg_wr && ridx == R_INTSTATE ) begin
        end
        b2_d <= vregs[R_INTSTATE][2];
    end
end


integer i;
always @(posedge clk) begin
    if( rst ) begin
        for( i=0; i<64; i=i+1 ) vregs[i] <= 16'h0000;
        vreg_q <= 16'h0000;
    end else begin
        vreg_q <= vregs[ridx];
        // INTSTATE has three writers -- the scanline compare (:380), blitter
        // completion (:1282) and the CPU's INTACK (:1344). They were three
        // separate non-blocking assignments to the same register, so whenever
        // two landed on one clock the last statement silently won and the
        // other event was LOST. Combine them into a single expression: sets
        // apply, then the ack mask clears, which also matches MAME's ordering
        // (it ORs the bit in, then a later write ANDs it out).
        vregs[R_INTSTATE] <=
            ( vregs[R_INTSTATE]
              | (scanline_hit ? VIDEOINT_SCANLINE : 16'd0)
              | (blit_done    ? VIDEOINT_BLITTER  : 16'd0) )
            & ~( (vreg_wr && ridx == R_INTSTATE) ? cpu_dout : 16'd0 );
        // every other register is a plain write
        if( vreg_wr && ridx != R_INTSTATE )
            vregs[ridx] <= cpu_dout;
    end
end

// ---------------------------------------------------------------------------
// Blitter + VRAM
// ---------------------------------------------------------------------------
wire        vw_req, vw_rdy, vw_plane, vr_req, vr_plane, vr_ack;
wire [18:0] vw_addr, vr_addr;
wire [15:0] vw_data, vr_data;

wire [4:0] blit_state;

sftm_blit u_blit(
    .rst        ( rst           ),
    .clk        ( clk           ),
    .start      ( cmd_stb       ),
    .command    ( cpu_dout      ),
    .busy       ( blit_busy     ),
    .done_pulse ( blit_done     ),
    .st_state   ( blit_state    ),
    .st_waiting ( blit_waiting  ),
    .st_stallw  ( blit_stallw   ),
    .st_gdone   ( blit_gdone    ),


    .r_flags    ( vregs[6'h03]  ),  // 0x06
    .r_width    ( vregs[6'h07]  ),  // 0x0e
    .r_height   ( vregs[6'h06]  ),  // 0x0c
    .r_addrlo   ( vregs[6'h08]  ),  // 0x10
    .r_addrhi   ( vregs[6'h17]  ),  // 0x2e
    .r_x        ( vregs[6'h09]  ),  // 0x12
    .r_y        ( vregs[6'h0a]  ),  // 0x14
    .r_srcxstep ( vregs[6'h0c]  ),  // 0x18
    .r_srcystep ( vregs[6'h0b]  ),  // 0x16
    .r_dstxstep ( vregs[6'h0d]  ),  // 0x1a
    .r_dstystep ( vregs[6'h0e]  ),  // 0x1c
    .r_ystepx   ( vregs[6'h0f]  ),  // 0x1e
    .r_xstepy   ( vregs[6'h10]  ),  // 0x20
    .r_clipl    ( vregs[6'h12]  ),  // 0x24
    .r_clipr    ( vregs[6'h13]  ),  // 0x26
    .r_clipt    ( vregs[6'h14]  ),  // 0x28
    .r_clipb    ( vregs[6'h15]  ),  // 0x2a

    .color0     ( color_latch0  ),
    .color1     ( color_latch1  ),
    .plane_en   ( plane_en      ),
    .grom_bank_in( grom_bank    ),

    .xfer_wr    ( xfer_stb      ),
    .xfer_wdata ( cpu_dout      ),
    .xfer_rdata ( xfer_rdata    ),
    .c3_active_o( c3_active     ),

    .grom0_addr ( grom0_addr    ),
    .grom0_data ( grom0_data    ),
    .grom0_rd   ( grom0_rd      ),
    .grom0_ok   ( grom0_ok      ),
    .grom1_addr ( grom1_addr    ),
    .grom1_data ( grom1_data    ),
    .grom1_rd   ( grom1_rd      ),
    .grom1_ok   ( grom1_ok      ),
    .grm3_addr  ( grm3_addr     ),
    .grm3_data  ( grm3_data     ),
    .grm3_rd    ( grm3_rd       ),
    .grm3_ok    ( grm3_ok       ),

    .vw_req     ( vw_req        ),
    .vw_rdy     ( vw_rdy        ),
    .vw_plane   ( vw_plane      ),
    .vw_addr    ( vw_addr       ),
    .vw_data    ( vw_data       ),
    .vr_req     ( vr_req        ),
    .vr_plane   ( vr_plane      ),
    .vr_addr    ( vr_addr       ),
    .vr_ack     ( vr_ack        ),
    .vr_data    ( vr_data       )
);

// scanline prefetch. At line_end of line L the display of L+1 begins
// immediately, so the line to fetch DURING L+1 is L+2: kick it now.
// Line 0 is fetched during line 285, line 1 during line 0.
// base = csa(XORIGIN1, YORIGIN1 + line)  (screen_update, :1489)
reg        line_go;
reg [18:0] line_base;
reg        line_sel;
wire [8:0] fetch_line = vcnt == 9'd284 ? 9'd0 :
                        vcnt == 9'd285 ? 9'd1 : vcnt + 9'd2;
wire       fetch_vis  = vcnt <= 9'd253 || vcnt >= 9'd284;

wire [15:0] scan_pen;
// active video starts at hcnt 50 (HBLANK_END), so the line-buffer index
// is hcnt-50; the value during blanking is not displayed
wire [ 8:0] scan_x = hcnt - 9'd50;

sftm_vram u_vram(
    .rst        ( rst           ),
    .clk        ( clk           ),
    .vram_addr  ( vram_addr     ),
    .vram_data  ( vram_data     ),
    .vram_din   ( vram_din      ),
    .vram_dsn   ( vram_dsn      ),
    .vram_we    ( vram_we       ),
    .vram_rd    ( vram_rd       ),
    .vram_ok    ( vram_ok       ),
    .vw_req     ( vw_req        ),
    .vw_rdy     ( vw_rdy        ),
    .vw_plane   ( vw_plane      ),
    .vw_addr    ( vw_addr       ),
    .vw_data    ( vw_data       ),
    .vr_req     ( vr_req        ),
    .vr_plane   ( vr_plane      ),
    .vr_addr    ( vr_addr       ),
    .vr_ack     ( vr_ack        ),
    .vr_data    ( vr_data       ),
    .line_go    ( line_go       ),
    .line_base  ( line_base     ),
    .line_sel   ( line_sel      ),
    .scan_x     ( scan_x        ),
    .scan_pen   ( scan_pen      ),
    .st_wpop    ( vram_wpop     )
);

// ---------------------------------------------------------------------------
// Palette RAM: 32768 x 32-bit, full readback (MAME maps it .ram()). Port A:
// CPU. Port B: scanout pen lookup. xRGB_888: R=pal[23:16] G=[15:8] B=[7:0].
//
// Structured as four 8-bit lane arrays, whole-byte writes only, and one
// always block per port: the Quartus true-dual-port inference template.
// The first version used part-select writes into 16-bit arrays with three
// access ports, which quartus_map tried to elaborate as half a million
// discrete registers and died (crash confirmed in Phase 4 bring-up).
// ---------------------------------------------------------------------------
reg [7:0] pal_b3[0:32767];   // D31:24 (A[1]=0, UDS lane)
reg [7:0] pal_b2[0:32767];   // D23:16 = R
reg [7:0] pal_b1[0:32767];   // D15:8  = G
reg [7:0] pal_b0[0:32767];   // D7:0   = B
reg [7:0] pal_b3_qa, pal_b2_qa, pal_b1_qa, pal_b0_qa;   // CPU port
reg [7:0] pal_b2_qb, pal_b1_qb, pal_b0_qb;              // scanout port

wire [14:0] pal_addr = cpu_addr[16:2];
wire        pal_wr   = bus_wstb && pal_cs;
wire [14:0] pen      = scan_pen[14:0];

// port A: CPU read/write
always @(posedge clk) begin
    if( pal_wr && !cpu_addr[1] && !cpu_uds_n ) pal_b3[pal_addr] <= cpu_dout[15:8];
    pal_b3_qa <= pal_b3[pal_addr];
end
always @(posedge clk) begin
    if( pal_wr && !cpu_addr[1] && !cpu_lds_n ) pal_b2[pal_addr] <= cpu_dout[7:0];
    pal_b2_qa <= pal_b2[pal_addr];
end
always @(posedge clk) begin
    if( pal_wr && cpu_addr[1] && !cpu_uds_n ) pal_b1[pal_addr] <= cpu_dout[15:8];
    pal_b1_qa <= pal_b1[pal_addr];
end
always @(posedge clk) begin
    if( pal_wr && cpu_addr[1] && !cpu_lds_n ) pal_b0[pal_addr] <= cpu_dout[7:0];
    pal_b0_qa <= pal_b0[pal_addr];
end
// port B: scanout pen lookup (b3 is the unused x byte, no read port)
always @(posedge clk) begin
    pal_b2_qb <= pal_b2[pen];
    pal_b1_qb <= pal_b1[pen];
    pal_b0_qb <= pal_b0[pen];
end

assign pal_dout = !cpu_addr[1] ? {pal_b3_qa, pal_b2_qa} : {pal_b1_qa, pal_b0_qa};

// ---------------------------------------------------------------------------
// Background-streak probe
//
// The streak pixels are EXACTLY (0,255,0): 2496 of them in one fight capture,
// 2051 in another on a different stage, against 566 distinct colours in the
// same band. Pure green is not in these digitised backgrounds, so those pixels
// carry a wrong pen INDEX landing on one palette slot; the image data is not
// being mangled. Run starts split evenly between even and odd x with mixed
// lengths, so not a 32-bit pairing or byte-enable fault, and tb_svcfont
// decodes real ROM bytes perfectly, so not the RLE decoder.
//
// The first build held the FIRST green pen since reset, which was useless: the
// captured value (0x71, latch 0x03) came from a two-minute window that was
// mostly boot and attract, and every frame captured alongside it had zero
// green pixels. It could have been a boot artifact rather than the fight
// corruption. So report from the frame with the MOST green pixels instead --
// the same worst-frame latching used for the blitter counters -- with the pen
// and the count latched together so they always describe one frame.
//
// Three bits answer the open questions:
//   st_gmulti  more than one distinct pen produced green in that frame.
//              Clear = a single bad index; set = the pen is varying and the
//              "one wrong palette slot" reading is wrong.
//   st_palhit  the CPU has written the palette entry st_gpen points at. If it
//              never does, the pen may be legitimate and the PALETTE UPLOAD is
//              what is incomplete -- which would make this the same root cause
//              as the throughput problem, since cpu_wait starves the 68020.
//   st_gseen   green was seen at all (control).
//
// st_gcnt is green pixels per frame / 256, so the captures' ~2000-2500 should
// read about 8-9. A reading far above that means the gating is wrong again.
//
// st_palcnt counts palette writes overall: it must be non-zero, otherwise a
// clear st_palhit means nothing.
// ---------------------------------------------------------------------------
wire pal_is_green = pal_b2_qb[7:3]==5'd0 && pal_b1_qb[7:3]==5'd31 && pal_b0_qb[7:3]==5'd0;
// same instant and same condition as the scanout's red/green/blue assignment
wire green_disp   = pxl_cen && LVBL && LHBL && gfx_en[0] && pal_is_green;

reg [15:0] gcnt_acc, gcnt_best;
reg [14:0] gpen_first, gpen_last;
reg        gmulti_acc;
reg [19:0] palcnt;

always @(posedge clk) begin
    if( rst ) begin
        st_gpen  <= 0; st_gseen <= 0; st_gcnt <= 0; st_gmulti <= 0;
        st_palhit<= 0; st_palcnt<= 0;
        gcnt_acc <= 0; gcnt_best<= 0; gmulti_acc <= 0;
        gpen_first<= 0; gpen_last <= 0; palcnt <= 0;
    end else begin
        // ---- palette write watch ----
        if( pal_wr ) begin
            if( ~&palcnt ) palcnt <= palcnt + 20'd1;
            if( pal_addr == st_gpen ) st_palhit <= 1'b1;
        end
        st_palcnt <= palcnt[19:12];        // palette writes / 4096

        // ---- green accumulation for this frame ----
        if( green_disp ) begin
            st_gseen <= 1'b1;
            if( gcnt_acc == 0 ) gpen_first <= pen;
            else if( pen != gpen_first ) gmulti_acc <= 1'b1;
            gpen_last <= pen;
            if( ~&gcnt_acc ) gcnt_acc <= gcnt_acc + 16'd1;
        end

        // ---- publish from the frame with the most green ----
        if( frame_end ) begin
            if( gcnt_acc > gcnt_best ) begin
                gcnt_best <= gcnt_acc;
                st_gpen   <= gpen_last;
                st_gcnt   <= |gcnt_acc[15:12] ? 4'd15 : gcnt_acc[11:8]; // /256
                st_gmulti <= gmulti_acc;
                st_palhit <= 1'b0;   // re-arm: it refers to the NEW st_gpen
            end
            gcnt_acc <= 0; gmulti_acc <= 0;
        end
    end
end

// ---------------------------------------------------------------------------
// CRT timing + scanout. Pipeline: scan_x -> scan_pen (1 clk) -> palette
// (1 clk); with pxl_cen every 6 clks both lookups settle within one pixel.
// ---------------------------------------------------------------------------
always @(posedge clk) begin
    if( rst ) begin
        hcnt <= 0;
        vcnt <= 0;
        HS   <= 0;
        VS   <= 0;
        LHBL <= 0;
        LVBL <= 0;
        vblank_irq <= 0;
        line_go    <= 0;
        line_sel   <= 0;
        {red, green, blue} <= 0;
    end else begin
        vblank_irq <= 0;
        line_go    <= 0;
        if( pxl_cen ) begin
            // Horizontal phase follows the CRTC registers literally
            // (itech32_v.cpp:75-78, values at startup):
            //   HTOTAL 0x1FC=508  HBLANK_END 0x32=50  HBLANK_START 0x1B2=434
            //   HSYNC  0x1E4=484
            // so active video is hcnt 50..433 (384 px, matching MAME's
            // visarea max_x = HBSTART-HBEND-1 = 383) and sync runs 484..507:
            // front porch 51, sync 24, back porch 50.
            //
            // This previously normalised active to hcnt 0..383 with sync at
            // 419..457 -- same line length, but a different sync phase and a
            // 39-pixel sync. A scaler that locks to HS and counts a fixed back
            // porch then places the image at the wrong offset, which showed up
            // as the picture wrapping horizontally on the SuperStation One.
            hcnt <= line_end ? 9'd0 : hcnt + 9'd1;
            if( hcnt == 9'd433 ) LHBL <= 1'b0;
            if( hcnt == 9'd483 ) HS   <= 1'b1;
            if( hcnt == 9'd49  ) LHBL <= 1'b1;
            if( line_end ) begin
                HS <= 1'b0;
                vcnt <= vcnt == 9'd285 ? 9'd0 : vcnt + 9'd1;
                if( vcnt == 9'd255 ) begin
                    LVBL       <= 1'b0;
                    vblank_irq <= 1'b1;   // generate_int1 (itech32.cpp:453)
                end
                if( vcnt == 9'd285 ) LVBL <= 1'b1;
                if( vcnt == 9'd262 ) VS <= 1'b1;
                if( vcnt == 9'd265 ) VS <= 1'b0;
                // kick prefetch of the line after the one now starting
                if( fetch_vis ) begin
                    line_go   <= 1'b1;
                    line_sel  <= fetch_line[0];
                    line_base <= { vregs[R_YORIGIN1][9:0] + {1'b0, fetch_line},
                                   9'd0 }                    // wraps mod 1024
                                 + { 10'd0, vregs[R_XORIGIN1][8:0] };
                end
            end
            // output the pixel (single plane, screen_update :1510)
            if( LVBL && LHBL && gfx_en[0] ) begin
                red   <= pal_b2_qb[7:3];              // R = pal[23:16]
                green <= pal_b1_qb[7:3];              // G = pal[15:8]
                blue  <= pal_b0_qb[7:3];              // B = pal[7:0]
            end else
                {red, green, blue} <= 0;
        end
    end
end

// scanout buffer parity: line_sel selects the buffer being FILLED; the
// scanout in sftm_vram reads the other. scan buffer read of current line:
// current visible line vcnt has parity vcnt[0], which was filled while
// line_sel == vcnt[0] -- consistent because line_sel is set to next_line[0]
// one line ahead.

// verilator lint_off UNUSEDSIGNAL
wire unused = &{ debug_bus, gfx_en[3:1], scan_pen[15], 1'b0 };
// verilator lint_on UNUSEDSIGNAL

endmodule
