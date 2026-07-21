/*  This file is part of JTSFTM.  GPLv3 - see LICENSE.

    Video subsystem for Street Fighter: The Movie (itech32 IT42 blitter).

    Register offsets and semantics are taken from MAME
    src/mame/itech/itech32_v.cpp (VIDEO_* defines). This module holds:
      - the 0x00..0x88 video register file (word addressed)
      - the programmable CRTC (H/V total, sync, blank) and scanout counters
      - two 512-wide VRAM planes (foreground / background) in BRAM
      - 15-bit palette RAM
      - the IT42 blitter (jtsftm_blitter) that copies GROM -> VRAM
*/

module jtsftm_video(
    input               rst,
    input               clk,
    input               pxl_cen,
    input               pxl2_cen,

    // CPU bus
    input       [23:1]  cpu_addr,
    input       [15:0]  cpu_dout,
    input               cpu_rnw,
    input               vram_cs,
    input               vreg_cs,
    input               pal_cs,
    output      [15:0]  vram_dout,
    output reg  [15:0]  vreg_dout,
    output      [15:0]  pal_dout,
    input       [ 1:0]  plane_en,
    input       [ 8:0]  color_latch,

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
    input       [ 7:0]  debug_bus
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
           VR_XFERY    = 7'h14>>1, VR_INTLINE = 7'h2c>>1,
           VR_ADDRHI   = 7'h2e>>1,
           VR_VTOTAL   = 7'h32>>1, VR_VSYNC   = 7'h34>>1,
           VR_VBSTART  = 7'h36>>1, VR_VBEND   = 7'h38>>1,
           VR_HTOTAL   = 7'h3a>>1, VR_HSYNC   = 7'h3c>>1,
           VR_HBSTART  = 7'h3e>>1, VR_HBEND   = 7'h40>>1;

reg  [15:0] vregs[0:63];             // 0x00..0x7e
wire [ 5:0] vreg_a = cpu_addr[6:1];

// CPU register read/write
always @(posedge clk) begin
    if( vreg_cs & ~cpu_rnw ) vregs[vreg_a] <= cpu_dout;
    vreg_dout <= vregs[vreg_a];
end

// ---------------------------------------------------------------------------
// CRTC counters (run on pxl_cen). Generate sync/blank + interrupts.
// ---------------------------------------------------------------------------
reg [9:0] hcnt, vcnt;
always @(posedge clk) if(pxl_cen) begin
    if( hcnt >= vregs[VR_HTOTAL][9:0] ) begin
        hcnt <= 0;
        vcnt <= (vcnt >= vregs[VR_VTOTAL][9:0]) ? 10'd0 : vcnt + 10'd1;
    end else hcnt <= hcnt + 10'd1;

    HS   <= hcnt >= vregs[VR_HSYNC][9:0];
    VS   <= vcnt >= vregs[VR_VSYNC][9:0];
    LHBL <= ~(hcnt>=vregs[VR_HBSTART][9:0] || hcnt<vregs[VR_HBEND][9:0]);
    LVBL <= ~(vcnt>=vregs[VR_VBSTART][9:0] || vcnt<vregs[VR_VBEND][9:0]);
end

// scanline & vblank interrupts (VIDEOINT_SCANLINE=0x04, BLITTER=0x40)
always @(posedge clk) begin
    if( rst ) begin vblank_irq<=0; end
    else if(pxl_cen) begin
        vblank_irq <= (vcnt==vregs[VR_VBSTART][9:0]) && hcnt==0;
        // scanline match int: vcnt==VR_INTLINE (routed via INTEN mask) - TODO
    end
end

// ---------------------------------------------------------------------------
// VRAM: two planes, 8-bit indexed pixels, 512 wide. Dual port: blitter writes
// / CPU access on one port, scanout reads on the other.
// ---------------------------------------------------------------------------
wire [16:0] blt_waddr;   wire [7:0] blt_wdata; wire blt_we; wire blt_plane;
wire [16:0] scan_addr;   wire [7:0] fg_pix, bg_pix;

jtsftm_vram #(.AW(17)) u_fg(
    .clk(clk), .we( blt_we & ~blt_plane ),
    .waddr(blt_waddr), .wdata(blt_wdata),
    .raddr(scan_addr), .rdata(fg_pix) );

jtsftm_vram #(.AW(17)) u_bg(
    .clk(clk), .we( blt_we &  blt_plane ),
    .waddr(blt_waddr), .wdata(blt_wdata),
    .raddr(scan_addr), .rdata(bg_pix) );

assign vram_dout = 16'hffff;   // TODO: CPU read-back path into VRAM window
assign scan_addr = { vcnt[7:0], hcnt[8:0] }; // TODO: apply display origin/scroll

// plane priority: foreground pixel unless transparent (0xff), else background
wire [7:0] px = (fg_pix!=8'hff) ? fg_pix : bg_pix;

// ---------------------------------------------------------------------------
// Palette RAM: 15-bit colour. bloodstm-style: MSB used in game mode.
// index = { color_latch bank bits, pixel }
// ---------------------------------------------------------------------------
wire [14:0] pal_rgb;
jtsftm_pal u_pal(
    .clk    ( clk       ),
    .cpu_addr(cpu_addr[13:1]),
    .cpu_dout(cpu_dout  ),
    .cpu_we ( pal_cs & ~cpu_rnw ),
    .cpu_q  ( pal_dout  ),
    .rd_idx ( { color_latch, px } ),  // TODO: exact index composition
    .rd_rgb ( pal_rgb   )
);

assign red   = gfx_en[0] ? pal_rgb[14:10] : 5'd0;
assign green = gfx_en[0] ? pal_rgb[ 9: 5] : 5'd0;
assign blue  = gfx_en[0] ? pal_rgb[ 4: 0] : 5'd0;

// ---------------------------------------------------------------------------
// IT42 blitter
// ---------------------------------------------------------------------------
wire blit_done;
jtsftm_blitter u_blitter(
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
    .start      ( vreg_cs & ~cpu_rnw & (vreg_a==VR_COMMAND) ),
    .plane_sel  ( 1'b0               ),    // TODO: derive target plane
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

always @(posedge clk) blit_irq <= blit_done; // TODO: latch + INTEN mask + ack

// grm3 not used in first pass
assign grm3_addr = 18'd0;
assign grm3_cs   = 1'b0;

endmodule
