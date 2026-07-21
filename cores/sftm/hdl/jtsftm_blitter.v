/*  This file is part of JTSFTM.  GPLv3 - see LICENSE.

    IT42 blitter for itech32. Copies a width x height block of 8-bit pixels
    from graphics ROM (GROM) into a VRAM plane, honouring the transfer flags
    from itech32_v.cpp:

        bit0 TRANSPARENT  bit1 XFLIP   bit2 YFLIP   bit3 DSTXSCALE
        bit4 DYDXSIGN     bit5 DXDYSIGN            bit10 CLIP  bit15 WIDTHPIX

    This first cut implements the unscaled path (1:1) with transparency, flips
    and rectangular clipping. Scaling (SRC/DST steps, YSTEP_PER_X ...) and the
    skewed polygon path used by Driver's Edge are left as TODO.
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

localparam F_TRANSP = 0, F_XFLIP = 1, F_YFLIP = 2;

localparam [1:0] IDLE=2'd0, FETCH=2'd1, WRITE=2'd2, STEP=2'd3;
reg  [1:0] st;

reg [15:0] xcnt, ycnt;
reg [24:0] src;                       // byte address into GROM
reg [15:0] curx, cury;
wire [7:0] src_pix = src[0] ? grom_data[15:8] : grom_data[7:0];
wire       transp  = r_flags[F_TRANSP] & (src_pix==8'hff);

always @(posedge clk) begin
    if( rst ) begin
        st<=IDLE; vram_we<=0; grom_cs<=0; done<=0;
    end else begin
        vram_we <= 0;
        done    <= 0;
        case( st )
            IDLE: if( start ) begin
                xcnt      <= 0;
                ycnt      <= 0;
                src       <= { grom_bank[0], r_addrhi[7:0], r_addrlo };
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
                if( !transp ) begin
                    // TODO: apply clip rect + display origin; flips adjust
                    // the destination coordinate rather than the source walk.
                    vram_addr <= { cury[7:0], curx[8:0] };
                    vram_data <= src_pix;
                    vram_we   <= 1;
                end
                st <= STEP;
            end
            STEP: begin
                src  <= src + 25'd1;                 // TODO: SRC_XSTEP scaling
                if( xcnt >= r_width ) begin
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
                    xcnt <= xcnt + 16'd1;
                    curx <= r_flags[F_XFLIP] ? curx-16'd1 : curx+16'd1;
                    st   <= FETCH;
                end
            end
        endcase
    end
end

endmodule
