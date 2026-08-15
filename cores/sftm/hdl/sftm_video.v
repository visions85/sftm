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
    output            grom0_cs,
    input             grom0_ok,
    output     [23:1] grom1_addr,
    input      [15:0] grom1_data,
    output            grom1_cs,
    input             grom1_ok,
    output     [18:1] grm3_addr,
    input      [15:0] grm3_data,
    output            grm3_cs,
    input             grm3_ok,

    // VRAM SDRAM bus
    output     [21:1] vram_addr,
    input      [15:0] vram_data,
    output     [15:0] vram_din,
    output     [ 1:0] vram_dsn,
    output            vram_we,
    output            vram_cs,
    input             vram_ok,
    output     [21:2] vramrd_addr,   // 32-bit read alias for the prefetch
    input      [31:0] vramrd_data,
    output            vramrd_cs,
    input             vramrd_ok,

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
    output reg [ 3:0] st_bwrf,    // ...of which stalled on the VRAM write port
    output reg [ 3:0] st_bnum     // blits started in that frame (saturating)
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
wire        blit_stallw, blit_waiting;

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
reg [19:0] bc_busy, bc_wait, bc_wrf, bc_best;
reg [ 3:0] bc_num;
reg        lvbl_d, busy_d;
wire       frame_end = lvbl_d && !LVBL;
wire       blit_rise = blit_busy && !busy_d;

always @(posedge clk) begin
    if( rst ) begin
        bc_busy <= 0; bc_wait <= 0; bc_wrf <= 0; bc_best <= 0; bc_num <= 0;
        st_bbusy<= 0; st_bwait<= 0; st_bwrf <= 0; st_bnum <= 0;
        lvbl_d  <= 0; busy_d  <= 0;
    end else begin
        lvbl_d <= LVBL;
        busy_d <= blit_busy;
        if( frame_end ) begin
            if( bc_busy > bc_best ) begin
                bc_best  <= bc_busy;
                st_bbusy <= bc_busy[19:16];
                st_bwait <= bc_wait[19:16];
                st_bwrf  <= bc_wrf [19:16];
                st_bnum  <= bc_num;
            end
            bc_busy <= 0; bc_wait <= 0; bc_wrf <= 0; bc_num <= 0;
        end else begin
            if( blit_busy               && ~&bc_busy ) bc_busy <= bc_busy + 20'd1;
            if( blit_busy && blit_waiting&& ~&bc_wait ) bc_wait <= bc_wait + 20'd1;
            if( blit_stallw             && ~&bc_wrf  ) bc_wrf  <= bc_wrf  + 20'd1;
            if( blit_rise               && ~&bc_num  ) bc_num  <= bc_num  + 4'd1;
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
    .grom0_cs   ( grom0_cs      ),
    .grom0_ok   ( grom0_ok      ),
    .grom1_addr ( grom1_addr    ),
    .grom1_data ( grom1_data    ),
    .grom1_cs   ( grom1_cs      ),
    .grom1_ok   ( grom1_ok      ),
    .grm3_addr  ( grm3_addr     ),
    .grm3_data  ( grm3_data     ),
    .grm3_cs    ( grm3_cs       ),
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
    .vram_cs    ( vram_cs       ),
    .vram_ok    ( vram_ok       ),
    .vramrd_addr( vramrd_addr   ),
    .vramrd_data( vramrd_data   ),
    .vramrd_cs  ( vramrd_cs     ),
    .vramrd_ok  ( vramrd_ok     ),
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
    .scan_pen   ( scan_pen      )
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
