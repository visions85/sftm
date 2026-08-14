`timescale 1ns/1ps
/*  This file is part of SFTM.
    SFTM is free software: you can redistribute it and/or modify it under the
    terms of the GNU General Public License as published by the Free Software
    Foundation, either version 3 of the License, or (at your option) any later
    version. See the LICENSE file.

    Street Fighter: The Movie -- IT42 blitter. Literal port of the drawing
    functions in MAME src/mame/itech/itech32_v.cpp:

      command 1 -> draw_raw (:410) / draw_raw_widthpix (:520)
      command 2 -> draw_rle (:1151): draw_rle_fast (:914),
                   draw_rle_fast_xflip (:990), draw_rle_slow (:1073)
      command 3 -> transfer setup (handle_video_command case 3, :1254) and
                   the per-write pixel poke in video_w case 0x04 (:1349)
      command 6 -> shiftreg_clear (:1180)
      commands 4/5 -> no-op (flush/reset)

    MAME executes a blit synchronously inside the register write; here it
    takes real time, so sftm_video stalls CPU access to VIDEO_COMMAND /
    VIDEO_TRANSFER while `busy` (the game's own status polling / XINT wait
    covers the normal case). VIDEOINT_BLITTER rises via done_pulse at the
    end of every command, exactly where MAME raises it (:1282).

    All parameters are latched on `start` (MAME's blit is atomic inside the
    register write, so the C code effectively snapshots the registers).
    Loop variables are signed 32-bit, arithmetic is 8.8 fixed point,
    identical to the C. Comments cite itech32_v.cpp line numbers.

    Deviations from MAME (documented in doc/PHASE2-DESIGN.md):
      - shiftreg_clear copies with a vram_mask wrap; MAME's memcpy can read
        the emulator's guard band past the plane instead of wrapping.
*/

module sftm_blit(
    input             rst,
    input             clk,

    // command interface (from sftm_video)
    input             start,        // 1-clk pulse: VIDEO_COMMAND written
    input      [15:0] command,
    output reg        busy,
    output reg        done_pulse,
                                    // -> VIDEO_INTSTATE |= VIDEOINT_BLITTER
    output     [4:0]  st_state,     // bring-up: live FSM state
    output            st_waiting,   // bring-up: stalled on a GROM fetch
    // Diagnostic: transparent skips per 256 RLE literal pixels. The screen
    // shows ~50% of glyph pixels missing while the raw-path background (same
    // GROM fetcher, same VRAM write path) renders correctly, so the fault is
    // confined to the RLE path plus TRANSPARENT. This splits it: ~128 means
    // half the fetched source bytes read as 0xFF and are skipped, ~0 means the
    // data is right and the writes are lost downstream.
    output reg [7:0]  st_rletp,
    // grm3 read-back self-test. The real text glyphs live in grm3 (blits
    // carry bank=2 -> GROM address 0x207xxxx), and a Python decode of the
    // ROM confirms 0x207DE86 begins 81 FF 07 2C. Fetch those four bytes
    // through the normal fetcher before any blit and report which matched,
    // plus byte 0 raw so a wrong byte order is visible.
    output reg [3:0]  st_g3ok,
    output reg [7:0]  st_g3b0,

    // video registers, valid at start (indices are byte offset / 2)
    input      [15:0] r_flags,      // 0x06 VIDEO_TRANSFER_FLAGS
    input      [15:0] r_width,      // 0x0e
    input      [15:0] r_height,     // 0x0c
    input      [15:0] r_addrlo,     // 0x10
    input      [15:0] r_addrhi,     // 0x2e
    input      [15:0] r_x,          // 0x12
    input      [15:0] r_y,          // 0x14
    input      [15:0] r_srcxstep,   // 0x18
    input      [15:0] r_srcystep,   // 0x16
    input      [15:0] r_dstxstep,   // 0x1a
    input      [15:0] r_dstystep,   // 0x1c
    input      [15:0] r_ystepx,     // 0x1e VIDEO_YSTEP_PER_X
    input      [15:0] r_xstepy,     // 0x20 VIDEO_XSTEP_PER_Y
    input      [15:0] r_clipl,      // 0x24
    input      [15:0] r_clipr,      // 0x26
    input      [15:0] r_clipt,      // 0x28
    input      [15:0] r_clipb,      // 0x2a

    input      [ 6:0] color0,       // color latches (7-bit, already >>8)
    input      [ 6:0] color1,
    input      [ 1:0] plane_en,     // enable_latch
    input      [ 1:0] grom_bank_in, // GROM A25:A24

    // command 3 CPU transfer port (sftm_video stalls the CPU while busy)
    input             xfer_wr,      // 1-clk: VIDEO_TRANSFER written, cmd 3
    input      [15:0] xfer_wdata,
    output reg [15:0] xfer_rdata,   // old pixel readback -> VIDEO_TRANSFER
    output            c3_active_o,  // command 3 armed (VIDEO_TRANSFER reads
                                    // return xfer_rdata while set)

    // GROM byte fetch (grom = SDRAM bank 2; grm3 = bank 3, MAME region
    // offset 0x2000000+)
    output reg [24:1] grom_addr,
    input      [15:0] grom_data,
    output reg        grom_cs,
    input             grom_ok,
    output reg [18:1] grm3_addr,
    input      [15:0] grm3_data,
    output reg        grm3_cs,
    input             grm3_ok,

    // VRAM port (to sftm_vram): word address within a plane + plane bit.
    // Writes are queued (vw_rdy = FIFO can accept); reads return vr_ack.
    output reg        vw_req,
    input             vw_rdy,
    output reg        vw_plane,
    output reg [18:0] vw_addr,
    output reg [15:0] vw_data,
    output reg        vr_req,
    output reg        vr_plane,
    output reg [18:0] vr_addr,
    input             vr_ack,
    input      [15:0] vr_data
);

// XFERFLAG bit numbers (itech32_v.cpp:120)
localparam XF_TRANSPARENT = 0,
           XF_XFLIP       = 1,
           XF_YFLIP       = 2,
           XF_DSTXSCALE   = 3,
           XF_DYDXSIGN    = 4,
           XF_DXDYSIGN    = 5,
           XF_CLIP        = 10,
           XF_WIDTHPIX    = 15;

localparam [18:0] VRAM_MASK = 19'h7FFFF;    // 512*1024-1 words

// compute_safe_address(x,y) = ((y & 1023) * 512) + (x & 511)  (:148)
function [18:0] csa(input [31:0] xa, input [31:0] ya);
    csa = { ya[9:0], 9'd0 } + { 10'd0, xa[8:0] };
endfunction

// ADJUSTED_HEIGHT(h) = ((h>>1) & 0x100) | (h & 0xff)  (:146)
function [8:0] adjh(input [15:0] h);
    adjh = { h[9], h[7:0] };
endfunction

function signed [31:0] clamp0(input signed [31:0] v);
    clamp0 = v[31] ? 32'd0 : v;
endfunction

// GROM addresses are taken % grom_length = 0x2080000 (:414). All producers
// stay below 2*0x2080000, so one conditional subtract implements the modulo.
function [25:0] mod_len(input [31:0] a);
    mod_len = a >= 32'h2080000 ? a[25:0] - 26'h2080000 : a[25:0];
endfunction

// ---------------------------------------------------------------------------
// Latched blit parameters
// ---------------------------------------------------------------------------
reg [15:0] flags;
reg signed [31:0] width, height;       // <<8 forms (raw)
reg [15:0] width_px;                   // TRANSFER_WIDTH, pixels
reg [ 8:0] height_px;                  // ADJUSTED_HEIGHT, pixels
reg signed [31:0] xsrcstep, ysrcstep, xdststep, ydststep;
reg signed [31:0] xstepy;              // skew per row
reg signed [31:0] ystep;               // slow-raw per-pixel y step (signed)
reg signed [31:0] sc_minx, sc_maxx, sc_miny, sc_maxy;   // scaled clip (<<8)
reg signed [31:0] cl_minx, cl_maxx;                     // unscaled clip
reg [25:0] grom_base;
reg [11:0] blit_x, blit_y;             // TRANSFER_X/Y & 0xfff
reg        transp_en, widthpix, rle_slow;
reg        pass;
reg [ 2:0] cmd_r;

// loop variables
reg signed [31:0] x, px, sx, sy, ty, startx, y;
reg signed [31:0] xleft, count_r;
reg signed [31:0] rle_lclip, rle_rclip, rle_width;
reg [25:0] src_addr;                   // RLE stream byte address
reg [18:0] dstoffs;
reg [31:0] row_base;
reg        rle_lit;                    // current run is literal (val == -1)
reg [ 7:0] rle_val;                    // repeat-run value
reg [ 1:0] rle_phase;                  // 0=lskip 1=draw 2=rskip 3=row skip
reg [ 9:0] sh_idx;
reg [18:0] sh_srcbase;
reg signed [31:0] sh_y;
reg [ 8:0] sh_row;

// command 3 state (m_xfer_*, :1257)
reg [15:0] c3_xcount, c3_ycount;
reg [11:0] c3_xcur, c3_ycur;
reg        c3_active, c3_pass;
reg [15:0] c3_wdata;

// ---------------------------------------------------------------------------
// FSM states
// ---------------------------------------------------------------------------
localparam [4:0]
    S_IDLE      = 5'd0,
    S_LATCH     = 5'd1,
    S_PLANE     = 5'd2,
    S_PLANE_END = 5'd3,
    S_ROW       = 5'd4,
    S_SKIP      = 5'd5,
    S_DSTOFF    = 5'd6,
    S_PIX       = 5'd7,
    S_ROWEND    = 5'd8,
    S_RLE_ROW   = 5'd9,
    S_RLE_ROW1  = 5'd10,
    S_RLE_RUN   = 5'd11,
    S_RLE_VAL   = 5'd12,
    S_RLE_PIX   = 5'd13,
    S_RLE_ROWEND= 5'd14,
    S_SH_READ   = 5'd15,
    S_SH_WRITE  = 5'd16,
    S_C3_READ   = 5'd17,
    S_C3_WRITE  = 5'd18,
    S_C3_NEXT   = 5'd19,
    S_DONE      = 5'd20;

reg [4:0] state /* synthesis keep */;
assign st_state = state;

// ---------------------------------------------------------------------------
// grm3 read-back self-test (declarations; the logic needs pix/fetch_ok and
// so lives further down). The real text glyphs come from grm3 -- those blits
// carry bank=2, giving GROM address 0x207xxxx -- and a Python decode of the
// ROM shows 0x207DE86 begins 81 FF 07 2C.
// ---------------------------------------------------------------------------
localparam [25:0] G3_BASE = 26'h207DE86;
reg [1:0] g3i;
// One-shot probes keep sampling too early: grm3 is the LAST region of a
// 37 MB download, so it is written many seconds in, and a fixed delay after
// reset is guesswork. Re-run the test about once a second instead, and only
// while the blitter is idle so it never steals a fetch from a real blit.
// The views then show live grm3 contents rather than one early sample.
reg [25:0] g3wait;
reg        g3run;

// ---------------------------------------------------------------------------
// Derived per-cycle values
// ---------------------------------------------------------------------------
wire [6:0] cur_color = pass ? color1 : color0;
wire       plane_on  = pass ? plane_en[1] : plane_en[0];
wire       c3_plane_on = c3_pass ? plane_en[1] : plane_en[0];

// raw source byte address: grom_base + row_base + (x>>8)  (:466)
wire [31:0] raw_src = {6'd0, grom_base} + row_base + {8'd0, x[31:8]};

// GROM fetch request: combinational address per state, so loop-variable
// updates can never leave a stale address in the fetcher
reg         fetch_req;
reg  [25:0] fetch_addr;
always @(*) begin
    fetch_req  = 0;
    fetch_addr = mod_len({6'd0, src_addr});
    if( g3run && state == S_IDLE ) begin
        fetch_req  = 1'b1;
        fetch_addr = G3_BASE + {24'd0, g3i};
    end else
    case( state )
        S_PIX: begin
            fetch_req  = 1;
            fetch_addr = mod_len(raw_src);
        end
        S_RLE_RUN:  fetch_req = (xleft > 0) && (count_r == 0);
        S_RLE_VAL:  fetch_req = 1;
        S_RLE_PIX:  fetch_req = rle_lit && rle_phase == 2'd1;
        default: ;
    endcase
end

// raw loop bound: widthpix counts px, plain counts x (:441 vs :577)
wire signed [31:0] xcmp = widthpix ? px : x;
wire        xin     = xcmp < width;
wire        dst_pos = !xdststep[31];

// slow-raw contains() (:499): inclusive max (MAME rectangle semantics)
wire in_rect = sx >= sc_minx && sx <= sc_maxx && ty >= sc_miny && ty <= sc_maxy;

// row_base = (y>>8) * (width>>8)  (:443)
wire [31:0] rowmul = y[24:8] * width_px;

// RLE derived
wire signed [31:0] rle_w_orig = {16'd0, width_px};
wire [18:0] rle_dst  = rle_slow ? (dstoffs + sx[26:8]) & VRAM_MASK  // (:1124)
                                : dstoffs & VRAM_MASK;              // (:967)
wire        rle_x_ok = !rle_slow || (sx >= sc_minx && sx < sc_maxx);
wire signed [31:0] skip_n = count_r < xleft ? count_r : xleft;

// fetched byte and transparency (:415: transparent pen 0xff only when flagged)
wire [7:0] pix;
wire       fetch_ok;
wire       pix_transp = transp_en && pix == 8'hff;
wire       rle_val_transp = transp_en && rle_val == 8'hff;

// ---------------------------------------------------------------------------
// GROM byte fetcher: one cached 16-bit word. The word address is latched at
// issue time so bulk src_addr jumps during an in-flight fetch cannot
// mislabel the cached data.
// ---------------------------------------------------------------------------
reg  [24:0] cache_waddr, issue_waddr;
reg         cache_valid, fetch_busy, fetch_is3;
reg  [15:0] cache_word;

wire        f_is3 = fetch_addr >= 26'h2000000;
wire [24:0] fword = fetch_addr[25:1];
wire        cache_hit = cache_valid && cache_waddr == fword;
// SDRAM data[7:0] = even byte address (JTFRAME download order)
assign pix      = fetch_addr[0] ? cache_word[15:8] : cache_word[7:0];
assign fetch_ok = cache_hit;
// bring-up: high while the FSM is stalled waiting on a GROM word
assign st_waiting = fetch_req && !fetch_ok;

always @(posedge clk) begin
    if( rst ) begin
        cache_valid <= 0;
        fetch_busy  <= 0;
        grom_cs     <= 0;
        grm3_cs     <= 0;
    end else begin
        if( fetch_req && !cache_hit && !fetch_busy ) begin
            fetch_busy  <= 1;
            issue_waddr <= fword;
            fetch_is3   <= f_is3;
            if( f_is3 ) begin
                grm3_addr <= fetch_addr[18:1];
                grm3_cs   <= 1;
            end else begin
                grom_addr <= fetch_addr[24:1];
                grom_cs   <= 1;
            end
        end else if( fetch_busy ) begin
            if( !fetch_is3 && grom_ok ) begin
                cache_word  <= grom_data;
                cache_waddr <= issue_waddr;
                cache_valid <= 1;
                grom_cs     <= 0;
                fetch_busy  <= 0;
            end
            if( fetch_is3 && grm3_ok ) begin
                cache_word  <= grm3_data;
                cache_waddr <= issue_waddr;
                cache_valid <= 1;
                grm3_cs     <= 0;
                fetch_busy  <= 0;
            end
        end
    end
end

// shiftreg row buffer (512 x 16)
reg [15:0] shrow[0:511];
reg [15:0] shrow_q;

wire vw_free = !vw_req || vw_rdy;

// grm3 self-test logic: fetch four known bytes before any blit can run
wire [7:0] g3_expect = g3i==2'd0 ? 8'h81 :
                       g3i==2'd1 ? 8'hFF :
                       g3i==2'd2 ? 8'h07 : 8'h2C;

always @(posedge clk) begin
    if( rst ) begin
        g3i <= 0; g3run <= 0; st_g3ok <= 0; st_g3b0 <= 0; g3wait <= 0;
    end else begin
        g3wait <= g3wait + 26'd1;
        if( &g3wait ) begin              // ~1.4 s: start a fresh pass
            g3run   <= 1'b1;
            g3i     <= 2'd0;
            st_g3ok <= 4'd0;
        end else if( g3run && state == S_IDLE && fetch_ok ) begin
            if( pix == g3_expect ) st_g3ok[g3i] <= 1'b1;
            if( g3i == 2'd0 ) st_g3b0 <= pix;
            if( g3i == 2'd3 ) g3run <= 1'b0;
            g3i <= g3i + 2'd1;
        end
    end
end

// transparent-skip census over a 256-pixel window of RLE literal runs
reg [7:0] lit_win, tp_win;
wire      lit_step  = state == S_RLE_PIX && rle_phase == 2'd1 && rle_lit
                      && fetch_ok && vw_free;

always @(posedge clk) begin
    if( rst ) begin
        lit_win <= 8'd0; tp_win <= 8'd0; st_rletp <= 8'd0;
    end else if( lit_step ) begin
        lit_win <= lit_win + 8'd1;
        if( lit_win == 8'hFF ) begin
            st_rletp <= tp_win + (pix_transp ? 8'd1 : 8'd0);
            tp_win   <= 8'd0;
        end else if( pix_transp )
            tp_win <= tp_win + 8'd1;
    end
end

// ---------------------------------------------------------------------------
// Main FSM
// ---------------------------------------------------------------------------
always @(posedge clk) begin
    if( rst ) begin
        state      <= S_IDLE;
        busy       <= 0;
        done_pulse <= 0;
        vw_req     <= 0;
        vr_req     <= 0;
        c3_active  <= 0;
        cmd_r      <= 0;
        pass       <= 0;
    end else begin
        done_pulse <= 0;
        if( vw_req && vw_rdy ) vw_req <= 0;

        case( state )
        // -------------------------------------------------------------------
        S_IDLE: begin
            busy <= 0;
            if( start ) begin
                busy  <= 1;
                cmd_r <= command[2:0];
                state <= S_LATCH;
            end else if( xfer_wr && c3_active && c3_ycount != 0 ) begin
                // video_w case 0x04 (:1349)
                busy     <= 1;
                c3_pass  <= 0;
                c3_wdata <= xfer_wdata;
                state    <= S_C3_READ;
            end
        end
        // -------------------------------------------------------------------
        S_LATCH: begin
            flags     <= r_flags;
            transp_en <= r_flags[XF_TRANSPARENT];
            widthpix  <= r_flags[XF_WIDTHPIX];
            width     <= { 8'd0, r_width, 8'd0 };
            width_px  <= r_width;
            height    <= { 15'd0, adjh(r_height), 8'd0 };
            height_px <= adjh(r_height);
            xsrcstep  <= { 16'd0, r_srcxstep };
            ysrcstep  <= { 16'd0, r_srcystep };
            xdststep  <= r_flags[XF_XFLIP]
                       ? -( r_flags[XF_DSTXSCALE] ? {16'd0,r_dstxstep} : 32'h100 )
                       :  ( r_flags[XF_DSTXSCALE] ? {16'd0,r_dstxstep} : 32'h100 );
            ydststep  <= r_flags[XF_YFLIP] ? -{16'd0,r_dstystep} : {16'd0,r_dstystep};
            ystep     <= r_ystepx == 16'd0 ? 32'd0
                       : r_flags[XF_DYDXSIGN] ? -{16'd0,r_ystepx} : {16'd0,r_ystepx};
            xstepy    <= { 16'd0, r_xstepy };
            rle_slow  <= ( r_flags[XF_DSTXSCALE] && r_dstxstep != 16'h100 )
                         || r_xstepy != 16'd0;                       // (:1158)
            cl_minx   <= r_flags[XF_CLIP] ? {20'd0, r_clipl[11:0]} : 32'd0;
            cl_maxx   <= r_flags[XF_CLIP] ? {20'd0, r_clipr[11:0]} : 32'hfff;
            sc_minx   <= r_flags[XF_CLIP] ? {12'd0, r_clipl[11:0], 8'd0} : 32'd0;
            sc_maxx   <= r_flags[XF_CLIP] ? {12'd0, r_clipr[11:0], 8'd0} : 32'hfff00;
            sc_miny   <= r_flags[XF_CLIP] ? {12'd0, r_clipt[11:0], 8'd0} : 32'd0;
            sc_maxy   <= r_flags[XF_CLIP] ? {12'd0, r_clipb[11:0], 8'd0} : 32'hfff00;
            grom_base <= { grom_bank_in, r_addrhi[7:0], r_addrlo };
            blit_x    <= r_x[11:0];
            blit_y    <= r_y[11:0];
            pass      <= 0;

            case( command[2:0] )
                3'd1, 3'd2, 3'd6: state <= S_PLANE;
                3'd3: begin
                    // command 3 setup (:1254)
                    c3_xcount <= r_width;
                    c3_ycount <= {7'd0, adjh(r_height)};
                    c3_xcur   <= r_x[11:0];
                    c3_ycur   <= r_y[11:0];
                    c3_active <= 1;
                    state     <= S_DONE;
                end
                default: state <= S_DONE;   // commands 4, 5, unknown (:1263)
            endcase
        end
        // -------------------------------------------------------------------
        S_PLANE: begin
            if( !plane_on )
                state <= S_PLANE_END;
            else begin
                sy       <= { 12'd0, blit_y, 8'd0 };
                startx   <= { 12'd0, blit_x, 8'd0 };
                y        <= 0;
                src_addr <= grom_base;
                count_r  <= 0;
                rle_lit  <= 0;
                case( cmd_r )
                3'd6: begin
                    // shiftreg_clear (:1180)
                    sh_srcbase <= csa({20'd0,blit_x}, {20'd0,blit_y});
                    sh_y   <= {20'd0, blit_y} + (flags[XF_YFLIP] ? -32'd1 : 32'd1);
                    sh_row <= 9'd1;
                    sh_idx <= 0;
                    state  <= height_px > 9'd1 ? S_SH_READ : S_PLANE_END;
                end
                3'd2: begin
                    // draw_rle fast-path clip precompute (:926 / :1002);
                    // unused by the slow path
                    if( flags[XF_XFLIP] ) begin
                        rle_lclip <= clamp0({20'd0,blit_x} - cl_maxx);
                        rle_rclip <= clamp0(cl_minx - ({20'd0,blit_x} - rle_w_orig));
                    end else begin
                        rle_lclip <= clamp0(cl_minx - {20'd0,blit_x});
                        rle_rclip <= clamp0({20'd0,blit_x} + rle_w_orig - cl_maxx);
                    end
                    state <= S_RLE_ROW;
                end
                default: state <= S_ROW;
                endcase
            end
        end
        S_PLANE_END: begin
            if( pass ) state <= S_DONE;
            else begin
                pass  <= 1;
                state <= S_PLANE;
            end
        end
        // -------------------------------------------------------------------
        // RAW (draw_raw :410 / draw_raw_widthpix :520)
        // -------------------------------------------------------------------
        S_ROW: begin
            if( y >= height )
                state <= S_PLANE_END;
            else begin
                row_base <= rowmul;
                x  <= 0;
                px <= 0;
                sx <= startx;
                ty <= sy;
                if( ystep != 0 )
                    state <= S_PIX;      // slow case: no row-level clip (:491)
                else if( sy < sc_miny || sy >= sc_maxy )
                    state <= S_ROWEND;   // fast-path Y clip (:449)
                else
                    state <= S_SKIP;
            end
        end
        S_SKIP: begin
            // skip pixels outside the near clip edge (:458 / :474)
            if( xin && ( dst_pos ? (sx < sc_minx) : (sx >= sc_maxx) ) ) begin
                x  <= x + xsrcstep;
                px <= px + 32'h100;
                sx <= sx + xdststep;
            end else
                state <= S_DSTOFF;
        end
        S_DSTOFF: begin
            // dstoffs = csa(sx>>8, sy>>8) - (sx>>8)  (:461)
            dstoffs <= csa(sx >>> 8, sy >>> 8) - sx[26:8];
            state   <= S_PIX;
        end
        S_PIX: begin
            if( !( xin && ( ystep != 0 ? (sx < sc_maxx) :
                            dst_pos    ? (sx < sc_maxx) :
                                         (sx >= sc_minx) ) ) )
                state <= S_ROWEND;
            else if( fetch_ok && vw_free ) begin
                if( !pix_transp && ( ystep == 0 || in_rect ) ) begin
                    vw_req   <= 1;
                    vw_plane <= pass;
                    vw_data  <= { 1'b0, cur_color, pix };
                    vw_addr  <= ystep == 0
                              ? (dstoffs + sx[26:8]) & VRAM_MASK      // (:468)
                              : csa(sx >>> 8, ty >>> 8);              // (:503)
                end
                x  <= x + xsrcstep;
                px <= px + 32'h100;
                sx <= sx + xdststep;
                ty <= ty + ystep;
            end
        end
        S_ROWEND: begin
            // skew (:508) + outer-loop increments (:441)
            startx <= flags[XF_DXDYSIGN] ? startx + xstepy : startx - xstepy;
            y  <= y + ysrcstep;
            sy <= sy + ydststep;
            state <= S_ROW;
        end
        // -------------------------------------------------------------------
        // RLE (draw_rle_fast :914 / _xflip :990 / _slow :1073)
        // Run state (count_r/rle_lit/rle_val) survives across rows: the
        // source is one continuous stream per draw call.
        // -------------------------------------------------------------------
        S_RLE_ROW: begin
            // clipped width (fast paths): width -= lclip + rclip (:930)
            rle_width <= rle_w_orig - rle_lclip - rle_rclip;
            if( y >= {23'd0, height_px} )   // rle outer loop counts pixels
                state <= S_PLANE_END;
            else
                state <= S_RLE_ROW1;
        end
        S_RLE_ROW1: begin
            if( rle_slow ) begin
                // draw_rle_slow (:1096): full width, per-pixel scaled clip
                sx      <= startx;
                dstoffs <= csa(cl_minx, sy >>> 8) - cl_minx[18:0];    // (:1109)
                if( sy < sc_miny || sy >= sc_maxy ) begin
                    rle_phase <= 2'd3;
                    xleft     <= rle_w_orig;         // SKIP_RLE(width) (:1103)
                end else begin
                    rle_phase <= 2'd1;
                    xleft     <= rle_w_orig;
                end
            end else begin
                if( sy < sc_miny || sy >= sc_maxy ) begin
                    rle_phase <= 2'd3;               // SKIP_RLE(w+l+r) (:945)
                    xleft     <= rle_width + rle_lclip + rle_rclip;
                end else begin
                    // dstoffs = csa(clipped sx, sy>>8)  (:950 / :1026)
                    dstoffs <= flags[XF_XFLIP]
                             ? csa({20'd0,blit_x} - rle_lclip, sy >>> 8)
                             : csa({20'd0,blit_x} + rle_lclip, sy >>> 8);
                    rle_phase <= 2'd0;
                    xleft     <= rle_lclip;          // left SKIP_RLE (:953)
                end
            end
            state <= S_RLE_RUN;
        end
        S_RLE_RUN: begin
            if( xleft <= 0 ) begin
                case( rle_phase )
                    2'd0: begin           // left skip done -> draw
                        rle_phase <= 2'd1;
                        xleft     <= rle_slow ? rle_w_orig : rle_width;
                    end
                    2'd1: begin           // draw done -> right skip / row end
                        if( rle_slow ) state <= S_RLE_ROWEND;
                        else begin
                            rle_phase <= 2'd2;
                            xleft     <= rle_rclip;   // (:985)
                        end
                    end
                    default: state <= S_RLE_ROWEND;
                endcase
            end else if( count_r == 0 ) begin
                // GET_NEXT_RUN (:876): header byte
                if( fetch_ok ) begin
                    src_addr <= src_addr + 26'd1;
                    if( pix[7] ) begin
                        rle_lit <= 1;                 // literal, val = -1
                        count_r <= { 25'd0, pix[6:0] };
                    end else begin
                        rle_lit <= 0;
                        count_r <= { 24'd0, pix };
                        state   <= S_RLE_VAL;
                    end
                end
            end else
                state <= S_RLE_PIX;
        end
        S_RLE_VAL: begin
            // value byte of a repeat run (also consumed during skips: MAME's
            // SKIP_RLE runs GET_NEXT_RUN in full)
            if( fetch_ok ) begin
                rle_val  <= pix;
                src_addr <= src_addr + 26'd1;
                state    <= S_RLE_RUN;
            end
        end
        S_RLE_PIX: begin
            if( count_r <= 0 || xleft <= 0 )
                state <= S_RLE_RUN;
            else if( rle_phase != 2'd1 ) begin
                // skip phases consume the stream only (SKIP_RLE :893):
                // dstoffs/sx are NOT advanced
                if( rle_lit ) src_addr <= src_addr + skip_n[25:0];
                count_r <= count_r - skip_n;
                xleft   <= xleft   - skip_n;
                state   <= S_RLE_RUN;
            end else if( rle_lit ) begin
                // literal run: one byte per pixel (:962 / :1038 / :1118)
                if( fetch_ok && vw_free ) begin
                    src_addr <= src_addr + 26'd1;
                    if( !pix_transp && rle_x_ok ) begin
                        vw_req   <= 1;
                        vw_plane <= pass;
                        vw_data  <= { 1'b0, cur_color, pix };
                        vw_addr  <= rle_dst;
                    end
                    count_r <= count_r - 32'd1;
                    xleft   <= xleft   - 32'd1;
                    if( rle_slow )             sx <= sx + xdststep;
                    else if( flags[XF_XFLIP] ) dstoffs <= dstoffs - 19'd1;
                    else                       dstoffs <= dstoffs + 19'd1;
                end
            end else if( rle_val_transp ) begin
                // transparent repeats: bulk advance (:981 / :1057 / :1137)
                if( rle_slow ) sx <= sx + xdststep * skip_n;
                else if( flags[XF_XFLIP] ) dstoffs <= dstoffs - skip_n[18:0];
                else                       dstoffs <= dstoffs + skip_n[18:0];
                count_r <= count_r - skip_n;
                xleft   <= xleft   - skip_n;
                state   <= S_RLE_RUN;
            end else begin
                // opaque repeats: one write per pixel (:975 / :1051 / :1131)
                if( vw_free ) begin
                    if( rle_x_ok ) begin
                        vw_req   <= 1;
                        vw_plane <= pass;
                        vw_data  <= { 1'b0, cur_color, rle_val };
                        vw_addr  <= rle_dst;
                    end
                    count_r <= count_r - 32'd1;
                    xleft   <= xleft   - 32'd1;
                    if( rle_slow )             sx <= sx + xdststep;
                    else if( flags[XF_XFLIP] ) dstoffs <= dstoffs - 19'd1;
                    else                       dstoffs <= dstoffs + 19'd1;
                end
            end
        end
        S_RLE_ROWEND: begin
            // fast: y++, sy += ydststep (:938); slow adds skew (:1142)
            y  <= y + 32'd1;
            sy <= sy + ydststep;
            if( rle_slow )
                startx <= flags[XF_DXDYSIGN] ? startx + xstepy : startx - xstepy;
            state <= S_RLE_ROW;
        end
        // -------------------------------------------------------------------
        // shiftreg_clear (:1180): buffer the source row, replicate it
        // -------------------------------------------------------------------
        S_SH_READ: begin
            if( vr_ack ) begin
                vr_req <= 0;
                shrow[sh_idx[8:0]] <= vr_data;
                if( sh_idx == 10'd511 ) begin
                    sh_idx <= 0;
                    state  <= S_SH_WRITE;
                end else
                    sh_idx <= sh_idx + 10'd1;
            end else if( !vr_req ) begin
                vr_req   <= 1;
                vr_plane <= pass;
                vr_addr  <= (sh_srcbase + {10'd0, sh_idx[8:0]}) & VRAM_MASK;
            end
        end
        S_SH_WRITE: begin
            if( vw_free ) begin
                // shrow_q lags sh_idx by one; reload ONLY when advancing so
                // a write-FIFO stall cannot shift the pipeline
                shrow_q <= shrow[sh_idx[8:0]];
                if( sh_idx != 0 ) begin
                    vw_req   <= 1;
                    vw_plane <= pass;
                    vw_data  <= shrow_q;
                    // full 10-bit sh_idx here: at sh_idx==512 the offset is
                    // 511, not the 9-bit wrap to -1
                    vw_addr  <= (csa({20'd0,blit_x}, sh_y)
                                 + {9'd0, sh_idx - 10'd1}) & VRAM_MASK;
                end
                if( sh_idx == 10'd512 ) begin
                    sh_idx <= 0;
                    sh_y   <= sh_y + (flags[XF_YFLIP] ? -32'd1 : 32'd1);
                    if( sh_row == height_px - 9'd1 )
                        state <= S_PLANE_END;
                    else begin
                        sh_row <= sh_row + 9'd1;
                        state  <= S_SH_WRITE;
                    end
                end else
                    sh_idx <= sh_idx + 10'd1;
            end
        end
        // -------------------------------------------------------------------
        // command 3 transfer pixel (video_w case 0x04, :1349)
        // -------------------------------------------------------------------
        S_C3_READ: begin
            if( !c3_plane_on )
                state <= S_C3_NEXT;
            else if( vr_ack ) begin
                vr_req     <= 0;
                xfer_rdata <= vr_data;       // VIDEO_TRANSFER = old (:1355)
                state      <= S_C3_WRITE;
            end else if( !vr_req ) begin
                vr_req   <= 1;
                vr_plane <= c3_pass;
                vr_addr  <= csa({20'd0,c3_xcur}, {20'd0,c3_ycur});
            end
        end
        S_C3_WRITE: begin
            if( vw_free ) begin
                vw_req   <= 1;
                vw_plane <= c3_pass;
                vw_addr  <= csa({20'd0,c3_xcur}, {20'd0,c3_ycur});
                vw_data  <= { 1'b0, c3_pass ? color1 : color0, c3_wdata[7:0] };
                state    <= S_C3_NEXT;
            end
        end
        S_C3_NEXT: begin
            if( !c3_pass ) begin
                c3_pass <= 1;
                state   <= S_C3_READ;
            end else begin
                // counter advance (:1363) -- live register reads, like MAME
                if( c3_xcount != 16'd1 ) begin
                    c3_xcount <= c3_xcount - 16'd1;
                    c3_xcur   <= c3_xcur + 12'd1;
                end else if( c3_ycount != 16'd1 ) begin
                    c3_ycount <= c3_ycount - 16'd1;
                    c3_xcur   <= r_x[11:0];
                    c3_xcount <= r_width;
                    c3_ycur   <= c3_ycur + 12'd1;
                end else
                    c3_ycount <= 16'd0;
                busy  <= 0;
                state <= S_IDLE;
            end
        end
        // -------------------------------------------------------------------
        S_DONE: begin
            done_pulse <= 1;                  // (:1282), every command
            busy       <= 0;
            if( cmd_r != 3'd3 ) c3_active <= 0;
            state      <= S_IDLE;
        end
        default: state <= S_IDLE;
        endcase
    end
end

assign c3_active_o = c3_active;

// verilator lint_off UNUSEDSIGNAL
wire unused = &{ command[15:3], 1'b0 };
// verilator lint_on UNUSEDSIGNAL

endmodule
