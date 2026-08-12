`timescale 1ns/1ps
/*  This file is part of SFTM.
    SFTM is free software: you can redistribute it and/or modify it under the
    terms of the GNU General Public License as published by the Free Software
    Foundation, either version 3 of the License, or (at your option) any later
    version. See the LICENSE file.

    Street Fighter: The Movie -- IT42 video. PHASE 2 IS NOT DONE YET.

    What IS implemented (literal from MAME src/mame/itech/itech32_v.cpp):
      - the m_video[] register file with bloodstm addressing: CPU longword
        address 0x500000 + 4*k maps to 16-bit register k, mirrored in both
        halves of the longword (bloodstm_video_w -> video_w(offset/2),
        itech32_v.cpp:1460)
      - video_w side effects (itech32_v.cpp:1335): INTACK (intstate = old &
        ~data), INTENABLE recompute, INTSCANLINE compare
      - video_r (itech32_v.cpp:1438): reg 0 reads (val & ~8) | 4 | 1 =
        "blitter idle"; reg 3 reads 0xef
      - handle_video_command (itech32_v.cpp:1233): commands complete
        instantly and set VIDEOINT_BLITTER, exactly as MAME does
        synchronously -- but NO PIXELS ARE DRAWN yet
      - interrupt levels: scan_irq/blit_irq = INTSTATE & INTENABLE & bit
        (update_interrupts, itech32_v.cpp:367)
      - vblank_irq pulse at vblank start (generate_int1 hook)
      - palette RAM 0x580000-0x59ffff: full 32-bit readback BRAM so the
        game's power-on RAM test passes (MAME maps it as plain .ram())

    NOT implemented (Phase 2): draw_raw, draw_raw_widthpix, draw_rle_*,
    shiftreg_clear, VRAM planes, GROM fetch, dynamic CRTC reconfiguration
    from VIDEO_HTOTAL/VTOTAL et al., screen_update scanout. Output is black.

    Fixed CRT timing meanwhile: 8 MHz pixel clock, HTOTAL 508, VTOTAL 286,
    visible 384x256 (the sftm raw params, itech32.cpp:1785).
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

    // latches from sftm_main (unused until Phase 2 drawing)
    input      [ 1:0] plane_en,
    input      [ 1:0] grom_bank,
    input      [ 6:0] color_latch0,
    input      [ 6:0] color_latch1,

    // graphics ROM buses (unused until Phase 2)
    output     [24:1] grom_addr,
    input      [15:0] grom_data,
    output            grom_cs,
    input             grom_ok,
    output     [18:1] grm3_addr,
    input      [15:0] grm3_data,
    output            grm3_cs,
    input             grm3_ok,

    // interrupts to sftm_main
    output reg        vblank_irq,  // 1-clk pulse
    output            blit_irq,
    output            scan_irq,

    // video out
    output reg        HS,
    output reg        VS,
    output reg        LHBL,
    output reg        LVBL,
    output     [ 4:0] red,
    output     [ 4:0] green,
    output     [ 4:0] blue,
    input      [ 3:0] gfx_en,
    input      [ 7:0] debug_bus
);

// blitter constants (itech32_v.cpp:117)
localparam [15:0] VIDEOINT_SCANLINE = 16'h0004,
                  VIDEOINT_BLITTER  = 16'h0040;

// register indices (itech32_v.cpp:43..109); byte offset / 2
localparam [5:0] R_INTSTATE    = 6'h01,   // 0x02
                 R_COMMAND     = 6'h04,   // 0x08
                 R_INTENABLE   = 6'h05,   // 0x0a
                 R_INTSCANLINE = 6'h16;   // 0x2c

// ---------------------------------------------------------------------------
// Register file
// ---------------------------------------------------------------------------
reg [15:0] vregs[0:63];
reg [15:0] vreg_q;

wire [5:0] ridx = cpu_addr[7:2];
wire       vreg_wr = bus_wstb && vreg_cs;

// video_r special cases (itech32_v.cpp:1438)
assign vreg_dout = ridx == 6'd0 ? ((vreg_q & ~16'h0008) | 16'h0004 | 16'h0001) :
                   ridx == 6'd3 ? 16'h00ef :
                   vreg_q;

assign scan_irq = |(vregs[R_INTSTATE] & vregs[R_INTENABLE] & VIDEOINT_SCANLINE);
assign blit_irq = |(vregs[R_INTSTATE] & vregs[R_INTENABLE] & VIDEOINT_BLITTER);

// ---------------------------------------------------------------------------
// CRT counters: fixed 508 x 286, visible 384 x 256
// ---------------------------------------------------------------------------
reg [8:0] hcnt;
reg [8:0] vcnt;
wire      line_end = hcnt == 9'd507;

wire scanline_hit = pxl_cen && line_end &&
                    vcnt == vregs[R_INTSCANLINE][8:0];

integer i;
always @(posedge clk) begin
    if( rst ) begin
        for( i=0; i<64; i=i+1 ) vregs[i] <= 16'h0000;
        vreg_q <= 16'h0000;
    end else begin
        vreg_q <= vregs[ridx];
        // scanline interrupt: INTSTATE |= SCANLINE when vpos == INTSCANLINE
        // (scanline_interrupt, itech32_v.cpp:380)
        if( scanline_hit )
            vregs[R_INTSTATE] <= vregs[R_INTSTATE] | VIDEOINT_SCANLINE;
        if( vreg_wr ) begin
            case( ridx )
                R_INTSTATE: // VIDEO_INTACK: intstate = old & ~data (itech32_v.cpp:1344)
                    vregs[R_INTSTATE] <= vregs[R_INTSTATE] & ~cpu_dout;
                R_COMMAND: begin
                    vregs[R_COMMAND] <= cpu_dout;
                    // handle_video_command (itech32_v.cpp:1233): Phase 2 will
                    // execute commands 1/2/3/6 here. All commands complete
                    // instantly and flag the blitter interrupt, like MAME.
                    vregs[R_INTSTATE] <= vregs[R_INTSTATE] | VIDEOINT_BLITTER;
                end
                default:
                    vregs[ridx] <= cpu_dout;
            endcase
        end
    end
end

// ---------------------------------------------------------------------------
// Palette RAM: 32768 x 32-bit (0x580000-0x59ffff). Stored full width for
// readback accuracy (MAME maps the region as .ram(); the power-on self test
// writes and reads it back raw). Two 16-bit BRAMs, one per longword half.
// Phase 2 scanout will use pens[14:0] -> xRGB_888-equivalent lookup.
// ---------------------------------------------------------------------------
reg [15:0] pal_hi[0:32767], pal_lo[0:32767];  // hi = D31:16 (A[1]=0)
reg [15:0] pal_hi_q, pal_lo_q;

wire [14:0] pal_addr = cpu_addr[16:2];
wire        pal_wr   = bus_wstb && pal_cs;

always @(posedge clk) begin
    if( pal_wr && !cpu_addr[1] ) begin
        if( !cpu_uds_n ) pal_hi[pal_addr][15:8] <= cpu_dout[15:8];
        if( !cpu_lds_n ) pal_hi[pal_addr][ 7:0] <= cpu_dout[ 7:0];
    end
    pal_hi_q <= pal_hi[pal_addr];
end
always @(posedge clk) begin
    if( pal_wr && cpu_addr[1] ) begin
        if( !cpu_uds_n ) pal_lo[pal_addr][15:8] <= cpu_dout[15:8];
        if( !cpu_lds_n ) pal_lo[pal_addr][ 7:0] <= cpu_dout[ 7:0];
    end
    pal_lo_q <= pal_lo[pal_addr];
end

assign pal_dout = !cpu_addr[1] ? pal_hi_q : pal_lo_q;

// ---------------------------------------------------------------------------
// CRT timing
// ---------------------------------------------------------------------------
always @(posedge clk) begin
    if( rst ) begin
        hcnt <= 9'd0;
        vcnt <= 9'd0;
        HS   <= 1'b0;
        VS   <= 1'b0;
        LHBL <= 1'b0;
        LVBL <= 1'b0;
        vblank_irq <= 1'b0;
    end else begin
        vblank_irq <= 1'b0;
        if( pxl_cen ) begin
            hcnt <= line_end ? 9'd0 : hcnt + 9'd1;
            if( hcnt == 9'd383 ) LHBL <= 1'b0;
            if( line_end )       LHBL <= 1'b1;
            if( hcnt == 9'd419 ) HS <= 1'b1;
            if( hcnt == 9'd457 ) HS <= 1'b0;
            if( line_end ) begin
                vcnt <= vcnt == 9'd285 ? 9'd0 : vcnt + 9'd1;
                if( vcnt == 9'd255 ) begin
                    LVBL       <= 1'b0;
                    vblank_irq <= 1'b1;   // generate_int1 (itech32.cpp:453)
                end
                if( vcnt == 9'd285 ) LVBL <= 1'b1;
                if( vcnt == 9'd262 ) VS <= 1'b1;
                if( vcnt == 9'd265 ) VS <= 1'b0;
            end
        end
    end
end

// Phase 2: real scanout. Black for now.
assign red   = 5'd0;
assign green = 5'd0;
assign blue  = 5'd0;

// GROM buses idle until the blitter exists
assign grom_addr = {24{1'b0}};
assign grom_cs   = 1'b0;
assign grm3_addr = {18{1'b0}};
assign grm3_cs   = 1'b0;

// verilator lint_off UNUSEDSIGNAL
wire unused = &{ plane_en, grom_bank, color_latch0, color_latch1, grom_data,
                 grom_ok, grm3_data, grm3_ok, gfx_en, debug_bus, 1'b0 };
// verilator lint_on UNUSEDSIGNAL

endmodule
