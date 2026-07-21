`timescale 1ns/1ps
/*  This file is part of JTSFTM.  GPLv3 - see LICENSE.

    IT42 blitter for itech32. Copies a width x height block of 8-bit pixels
    from graphics ROM (GROM) into a VRAM plane, honouring the transfer flags
    from itech32_v.cpp:

        bit0 TRANSPARENT  bit1 XFLIP   bit2 YFLIP   bit3 DSTXSCALE
        bit4 DYDXSIGN     bit5 DXDYSIGN            bit10 CLIP  bit15 WIDTHPIX

    Source stepping:
      SRC_XSTEP (8.8 fixed-point, default 0x0100 = 1:1) controls how many
      GROM bytes are consumed per destination pixel.  The fractional part is
      accumulated across pixels within each row and reset at each row boundary.
      SRC_YSTEP (y-axis skip) is handled implicitly: a 2x SRC_XSTEP advances
      the GROM pointer through 2 source rows per destination row.

    Still TODO: DST_XSTEP destination x-stride, YSTEP_PER_X polygon shear,
    WIDTHPIX flag, and the Driver's Edge skewed-polygon path.
*/

module jtsftm_blitter(
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
    input               start,
    input               plane_sel,
    input       [ 1:0]  grom_bank,

    // GROM read (16-bit, 2 pixels/word)
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

localparam F_TRANSP = 0, F_XFLIP = 1, F_YFLIP = 2, F_CLIP = 10;

localparam [1:0] IDLE=2'd0, FETCH=2'd1, WRITE=2'd2, STEP=2'd3;
reg  [1:0] st;

reg [15:0] xcnt, ycnt;
reg [24:0] src;                       // byte address into GROM
reg [15:0] curx, cury;
reg [ 7:0] src_xfrac;                 // fractional accumulator for SRC_XSTEP
// Fractional step: add SRC_XSTEP to src_xfrac each pixel; carry increments src.
wire [8:0] xfrac_step = {1'b0, src_xfrac} + {1'b0, r_srcxstep[7:0]};
wire [7:0] src_pix = src[0] ? grom_data[15:8] : grom_data[7:0];
wire       transp  = r_flags[F_TRANSP] & (src_pix==8'hff);
// Clip rect: bits[15:12] nonzero means coordinate is out of 12-bit range
// (wrapped negative or > 0xfff), so always clip those pixels.
wire       clip_pass = ~r_flags[F_CLIP] |
    (curx[15:12]==4'd0 && curx[11:0]>=r_leftclip && curx[11:0]<r_rightclip &&
     cury[15:12]==4'd0 && cury[11:0]>=r_topclip  && cury[11:0]<r_botclip);

always @(posedge clk) begin
    if( rst ) begin
        st<=IDLE; vram_we<=0; grom_cs<=0; done<=0; src_xfrac<=8'd0;
    end else begin
        vram_we <= 0;
        done    <= 0;
        case( st )
            IDLE: if( start ) begin
                xcnt      <= 0;
                ycnt      <= 0;
                src       <= { grom_bank[0], r_addrhi[7:0], r_addrlo };
                src_xfrac <= 8'd0;
                curx      <= r_x;
                cury      <= r_y;
                vram_plane<= plane_sel;
                grom_cs   <= 1;
                st        <= FETCH;
            end
            FETCH: begin
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
                // Advance source by SRC_XSTEP (8.8 fixed-point):
                //   integer part  r_srcxstep[15:8] always increments src;
                //   fractional part accumulates in src_xfrac; overflow = +1 extra.
                if( xcnt >= r_width ) begin
                    // End of row: advance src and reset fractional accumulator.
                    src       <= src + {9'd0, r_srcxstep[15:8]} + {24'd0, xfrac_step[8]};
                    src_xfrac <= 8'd0;
                    xcnt <= 0;
                    curx <= r_x;
                    cury <= r_flags[F_YFLIP] ? cury-16'd1 : cury+16'd1;
                    if( ycnt >= r_height ) begin
                        grom_cs <= 0;
                        done    <= 1;
                        st      <= IDLE;
                    end else begin
                        ycnt <= ycnt + 16'd1;
                        st   <= FETCH;
                    end
                end else begin
                    src       <= src + {9'd0, r_srcxstep[15:8]} + {24'd0, xfrac_step[8]};
                    src_xfrac <= xfrac_step[7:0];
                    xcnt <= xcnt + 16'd1;
                    curx <= r_flags[F_XFLIP] ? curx-16'd1 : curx+16'd1;
                    st   <= FETCH;
                end
            end
        endcase
    end
end

endmodule
