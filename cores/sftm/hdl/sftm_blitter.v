`timescale 1ns/1ps
/*  This file is part of SFTM.  GPLv3 - see LICENSE.

    IT42 blitter for itech32. Copies a width x height block of 8-bit pixels
    from graphics ROM (GROM) into a VRAM plane, honouring the transfer flags
    from itech32_v.cpp:

        bit0 TRANSPARENT  bit1 XFLIP   bit2 YFLIP   bit3 DSTXSCALE
        bit4 DYDXSIGN     bit5 DXDYSIGN            bit10 CLIP  bit15 WIDTHPIX

    Source stepping (SRC_XSTEP, 8.8 fp, default 0x0100 = 1:1):
      Controls how many GROM bytes are consumed per destination pixel.  The
      fractional part accumulates within a row and resets at each row boundary.

    Destination stepping (DST_XSTEP, 8.8 fp, default 0x0100 = 1:1):
      Active only when DSTXSCALE (flag bit 3) is set.  Controls how far the
      destination X cursor advances per source pixel written.  Values > 0x0100
      stretch the sprite horizontally; values < 0x0100 compress it.  XFLIP
      negates the step.  A fractional accumulator (dst_xfrac) carries the
      sub-pixel remainder across pixels within a row.

    Destination row stepping (DST_YSTEP, 8.8 fp, default 0x0100 = 1:1):
      Always active.  Controls how far the destination Y cursor advances after
      each row.  Values > 0x0100 skip rows (vertical stretch of destination);
      values < 0x0100 compress rows.  YFLIP negates the step direction.
      A fractional accumulator (dst_yfrac) carries the sub-row remainder
      across rows within a blit.

    WIDTHPIX (flag bit 15):
      In MAME draw_raw, row length is counted in source pixels consumed
      (r_width source bytes).  In draw_raw_widthpix, it is counted in
      destination pixels written (r_width dest pixels).  Our blitter always
      counts destination pixels (xcnt += 1 per pixel regardless of SRC_XSTEP)
      which is equivalent to WIDTHPIX mode.  F_WIDTHPIX is decoded so it can
      be checked by future logic, but currently produces the same result as
      the default path.

    Still TODO: YSTEP_PER_X polygon shear and the Driver's Edge skewed-polygon path.
*/

module sftm_blitter(
    input               rst,
    input               clk,

    // parameters (from the video register file)
    input       [15:0]  r_command,
    input       [15:0]  r_flags,
    input       [15:0]  r_width,
    input       [15:0]  r_height,
    input       [15:0]  r_x,
    input       [15:0]  r_y,
    input       [15:0]  r_addrlo,
    input       [15:0]  r_addrhi,
    // clip rect (pixel coordinates, 12-bit; registered from the video reg file)
    input       [11:0]  r_leftclip,
    input       [11:0]  r_rightclip,
    input       [11:0]  r_topclip,
    input       [11:0]  r_botclip,
    // source stepping (8.8 fixed-point; 0x0100 = 1 source byte per dest pixel)
    input       [15:0]  r_srcxstep,
    // destination x-stepping (8.8 fp; used only when DSTXSCALE flag is set)
    input       [15:0]  r_dstxstep,
    // destination y-stepping (8.8 fp; always active; 0x0100 = 1 row per row)
    input       [15:0]  r_dstystep,
    input               start,
    input               plane_sel,
    input       [ 1:0]  grom_bank,

    // GROM read (16-bit, 2 pixels/word)
    // grom_cs is toggled (0->1) at every FETCH entry per jtframe_romrq best practice:
    // addr_ok must go low then high for each new address request, otherwise the
    // bcache will not re-issue a read when the address changes while cs stays high.
    output reg  [23:0]  grom_addr,
    input       [15:0]  grom_data,
    output reg          grom_cs,
    input               grom_ok,

    // VRAM write
    output reg          vram_we,
    output reg  [16:0]  vram_addr,
    output reg  [ 7:0]  vram_data,
    output reg          vram_plane,
    output reg          done
);

localparam F_TRANSP = 0, F_XFLIP = 1, F_YFLIP = 2, F_DSTXSCALE = 3, F_CLIP = 10, F_WIDTHPIX = 15;

localparam [1:0] IDLE=2'd0, FETCH=2'd1, WRITE=2'd2, STEP=2'd3;
reg  [1:0] st;

reg [15:0] xcnt, ycnt;
reg [24:0] src;                       // byte address into GROM
reg [15:0] curx, cury;
reg [ 7:0] src_xfrac;                 // fractional accumulator for SRC_XSTEP
reg [ 7:0] dst_xfrac;                 // fractional accumulator for DST_XSTEP
reg [ 7:0] dst_yfrac;                 // fractional accumulator for DST_YSTEP
// SRC_XSTEP: add to src_xfrac each pixel; carry increments src.
wire [8:0] xfrac_step     = {1'b0, src_xfrac} + {1'b0, r_srcxstep[7:0]};
// DST_XSTEP: add to dst_xfrac each pixel; carry added to integer step.
wire [8:0] dst_xfrac_step = {1'b0, dst_xfrac} + {1'b0, r_dstxstep[7:0]};
// DST_YSTEP: add to dst_yfrac each row; carry added to integer y step.
wire [8:0] dst_yfrac_step = {1'b0, dst_yfrac} + {1'b0, r_dstystep[7:0]};
// Integer destination-x advance for this pixel (includes carry from fraction).
wire [15:0] dst_x_int = r_flags[F_DSTXSCALE]
    ? ({8'd0, r_dstxstep[15:8]} + {15'd0, dst_xfrac_step[8]})
    : 16'd1;
// Integer destination-y advance for this row (always uses DST_YSTEP).
wire [15:0] dst_y_int = {8'd0, r_dstystep[15:8]} + {15'd0, dst_yfrac_step[8]};
wire [7:0] src_pix = src[0] ? grom_data[15:8] : grom_data[7:0];
wire       transp  = r_flags[F_TRANSP] & (src_pix==8'hff);
// Clip rect: bits[15:12] nonzero means coordinate is out of 12-bit range
// (wrapped negative or > 0xfff), so always clip those pixels.
wire       clip_pass = ~r_flags[F_CLIP] |
    (curx[15:12]==4'd0 && curx[11:0]>=r_leftclip && curx[11:0]<r_rightclip &&
     cury[15:12]==4'd0 && cury[11:0]>=r_topclip  && cury[11:0]<r_botclip);

always @(posedge clk) begin
    if( rst ) begin
        st<=IDLE; vram_we<=0; grom_cs<=0; done<=0; src_xfrac<=8'd0; dst_xfrac<=8'd0; dst_yfrac<=8'd0;
    end else begin
        vram_we <= 0;
        done    <= 0;
        case( st )
            IDLE: if( start ) begin
                xcnt      <= 0;
                ycnt      <= 0;
                src       <= { grom_bank[0], r_addrhi[7:0], r_addrlo };
                src_xfrac <= 8'd0;
                dst_xfrac <= 8'd0;
                dst_yfrac <= 8'd0;
                curx      <= r_x;
                cury      <= r_y;
                vram_plane<= plane_sel;
                // grom_cs NOT asserted here; FETCH will produce a clean 0->1
                // rising edge that jtframe_romrq_bcache requires to issue a read.
                st        <= FETCH;
            end
            FETCH: begin
                grom_cs   <= 1;          // (re-)assert: arbiter sees 0->1 on FETCH entry
                grom_addr <= src[24:1];
                if( grom_ok ) st <= WRITE;
            end
            WRITE: begin
                if( !transp && clip_pass ) begin
                    vram_addr <= { cury[7:0], curx[8:0] };
                    vram_data <= src_pix;
                    vram_we   <= 1;
                end
                st <= STEP;
            end
            STEP: begin
                // De-assert grom_cs so the next FETCH produces a clean 0->1 rising
                // edge.  jtframe_romrq_bcache only re-issues a SDRAM read when it
                // sees addr_ok (=grom_cs) transition low->high; keeping cs permanently
                // high causes the cache to return stale data when the address changes.
                grom_cs <= 0;
                // Advance source by SRC_XSTEP (8.8 fixed-point):
                //   integer part  r_srcxstep[15:8] always increments src;
                //   fractional part accumulates in src_xfrac; overflow = +1 extra.
                if( xcnt >= r_width ) begin
                    // End of row: advance src, reset per-row fractional accumulators.
                    src       <= src + {9'd0, r_srcxstep[15:8]} + {24'd0, xfrac_step[8]};
                    src_xfrac <= 8'd0;
                    dst_xfrac <= 8'd0;
                    dst_yfrac <= dst_yfrac_step[7:0];
                    xcnt <= 0;
                    curx <= r_x;
                    // Advance Y by DST_YSTEP (8.8 fp); YFLIP negates direction.
                    cury <= r_flags[F_YFLIP] ? cury - dst_y_int : cury + dst_y_int;
                    if( ycnt >= r_height ) begin
                        done    <= 1;
                        st      <= IDLE;
                    end else begin
                        ycnt <= ycnt + 16'd1;
                        st   <= FETCH;
                    end
                end else begin
                    // Advance source.
                    src       <= src + {9'd0, r_srcxstep[15:8]} + {24'd0, xfrac_step[8]};
                    src_xfrac <= xfrac_step[7:0];
                    xcnt      <= xcnt + 16'd1;
                    // Advance destination X by DST_XSTEP (8.8 fp) when DSTXSCALE
                    // is set, otherwise by 1.  XFLIP negates the direction.
                    dst_xfrac <= r_flags[F_DSTXSCALE] ? dst_xfrac_step[7:0] : 8'd0;
                    curx <= r_flags[F_XFLIP] ? curx - dst_x_int : curx + dst_x_int;
                    st   <= FETCH;
                end
            end
        endcase
    end
end

endmodule
