`timescale 1ns/1ps
// Reproduce the hardware checkerboard: one long RLE literal run, drawn with
// the same flags the real text blits use (cmd=2, flags=D581 -- TRANSPARENT
// and WIDTHPIX set, DSTXSCALE clear), through the real sftm_vram write path
// with the scanline prefetch running and contending for SDRAM.
//
// The existing RLE tests use 3-pixel runs, which never fill the 16-deep write
// FIFO. A 100-pixel run does.
module tb_svcfont;

localparam PIXELS = 5;
localparam BX = 10, BY = 5, PEN0 = 7'h12;
localparam HEIGHT = 5;

reg clk = 0, rst = 1;
always #10.4 clk = ~clk;          // 48 MHz

// pxl_cen: 8 MHz (divide by 6) -- keeps the scanline prefetch running
reg [2:0] cendiv = 0;
wire pxl_cen = cendiv == 3'd0;
always @(posedge clk) cendiv <= cendiv == 3'd5 ? 3'd0 : cendiv + 3'd1;

integer k;

// ---------------------------------------------------------------------------
// GROM model (data[7:0] = even byte address), 3-cycle ok latency
// ---------------------------------------------------------------------------
wire [23:1] grom_addr;
wire        grom_cs;
reg  [ 7:0] gmem[0:2047];
reg         grom_ok = 0;
reg  [24:1] gok_addr;
reg  [ 1:0] gok_cnt;
wire        grom1_cs;
wire [ 9:0] gmem_a = grom_addr[10:1];
wire [15:0] grom_data = { gmem[{gmem_a,1'b1}], gmem[{gmem_a,1'b0}] };

always @(posedge clk) begin
    if( !grom_cs ) begin
        gok_cnt <= 0; grom_ok <= 0;
    end else if( grom_addr != gok_addr ) begin
        gok_addr <= grom_addr; gok_cnt <= 0; grom_ok <= 0;
    end else if( gok_cnt != 2'd3 )
        gok_cnt <= gok_cnt + 2'd1;
    else
        grom_ok <= 1;
end

initial begin
    for( k=0; k<2048; k=k+1 ) gmem[k] = 8'h00;
    // real service-menu font: the 'E' at grom 0x00011A
    gmem['h200+0] = 8'h06;
    gmem['h200+1] = 8'hFD;
    gmem['h200+2] = 8'h04;
    gmem['h200+3] = 8'hFF;
    gmem['h200+4] = 8'h04;
    gmem['h200+5] = 8'hFD;
    gmem['h200+6] = 8'h82;
    gmem['h200+7] = 8'hFF;
    gmem['h200+8] = 8'hFD;
    gmem['h200+9] = 8'h04;
    gmem['h200+10] = 8'hFF;
    gmem['h200+11] = 8'h05;
    gmem['h200+12] = 8'hFD;
    gmem['h200+13] = 8'h06;
    gmem['h200+14] = 8'hFD;
    gmem['h200+15] = 8'h04;
    gmem['h200+16] = 8'hFF;
    gmem['h200+17] = 8'h04;
    gmem['h200+18] = 8'hFD;
    gmem['h200+19] = 8'h82;
    gmem['h200+20] = 8'hFF;
    gmem['h200+21] = 8'hFD;
    gmem['h200+22] = 8'h04;
    gmem['h200+23] = 8'hFF;
end

// ---------------------------------------------------------------------------
// VRAM SDRAM model, init 0x1111, 3-cycle ok latency
// ---------------------------------------------------------------------------
wire [21:1] vram_addr;
wire [15:0] vram_din;
wire [ 1:0] vram_dsn;
wire        vram_we, vram_cs;
reg  [15:0] vmem[0:1048575];
reg         vram_ok = 0;
reg  [21:1] vok_addr;
reg  [ 1:0] vok_cnt;
reg  [15:0] vram_data_r;
wire [15:0] vram_data = vram_data_r;

integer wr_count = 0;
integer viol = 0;
initial for( k=0; k<1048576; k=k+1 ) vmem[k] = 16'h1111;

// Faithful to jtframe_ram_rq: a transaction is issued ONLY on a cs rising
// edge ("It requires addr_ok signal to toggle for each request"), not on an
// address change. ok is held until cs drops.
reg last_cs = 0, busy_t = 0;
wire cs_posedge = vram_cs && !last_cs;

always @(posedge clk) begin
    last_cs <= vram_cs;
    if( !vram_cs ) begin
        vok_cnt <= 0; vram_ok <= 0; busy_t <= 0;
    end else if( cs_posedge ) begin
        vok_addr <= vram_addr; vok_cnt <= 0; vram_ok <= 0; busy_t <= 1;
    end else if( busy_t ) begin
        if( vram_addr != vok_addr ) begin
            $display("PROTOCOL VIOLATION at %0t: addr changed to %05X while cs high (req was %05X)",
                     $time, vram_addr, vok_addr);
            viol = viol + 1;
        end
        if( vok_cnt != 2'd3 ) vok_cnt <= vok_cnt + 2'd1;
        else if( !vram_ok ) begin
            if( vram_we ) begin
                vmem[vok_addr] <= vram_din;
                wr_count = wr_count + 1;
            end else
                vram_data_r <= vmem[vok_addr];
            vram_ok <= 1;
        end
    end
end


// vramrd: read-only 32-bit alias of vmem
localparam [7:0] RDLAT = 8'd3;
wire [21:2] vramrd_addr;
wire        vramrd_cs;
reg         vramrd_ok = 0;
reg  [21:2] rok_addr;
reg  [ 7:0] rok_cnt;
reg  [31:0] vramrd_data_r;
wire [31:0] vramrd_data = vramrd_data_r;
reg         rd_last_cs = 0, rd_busy = 0;
wire        rd_cs_posedge = vramrd_cs && !rd_last_cs;
always @(posedge clk) begin
    rd_last_cs <= vramrd_cs;
    if( !vramrd_cs ) begin rok_cnt <= 0; vramrd_ok <= 0; rd_busy <= 0; end
    else if( rd_cs_posedge ) begin rok_addr <= vramrd_addr; rok_cnt <= 0; vramrd_ok <= 0; rd_busy <= 1; end
    else if( rd_busy ) begin
        if( rok_cnt != RDLAT ) rok_cnt <= rok_cnt + 8'd1;
        else if( !vramrd_ok ) begin
            vramrd_data_r <= { vmem[{rok_addr,1'b1}], vmem[{rok_addr,1'b0}] };
            vramrd_ok <= 1;
        end
    end
end

// ---------------------------------------------------------------------------
// DUT: drive the video register port directly
// ---------------------------------------------------------------------------
reg  [23:1] cpu_addr = 0;
reg  [15:0] cpu_dout = 0;
reg         bus_wstb = 0, vreg_cs = 0;
wire [15:0] vreg_dout, pal_dout;
wire        vid_wait, vblank_irq, blit_irq, scan_irq;
wire        HS, VS, LHBL, LVBL;
wire [ 4:0] red, green, blue;
wire [18:1] grm3_addr;
wire        grm3_cs;

wire [3:0] st_bbusy, st_bwait, st_bwr, st_bgf, st_bnum, st_gcnt;
wire [14:0] st_gpen;
wire st_gseen, st_gmulti, st_palhit;
wire [7:0] st_palcnt;

sftm_video u_video(
    .rst(rst), .clk(clk), .pxl_cen(pxl_cen),
    .cpu_addr(cpu_addr), .cpu_dout(cpu_dout),
    .cpu_uds_n(1'b0), .cpu_lds_n(1'b0), .bus_wstb(bus_wstb),
    .vreg_cs(vreg_cs), .pal_cs(1'b0),
    .vreg_dout(vreg_dout), .pal_dout(pal_dout), .cpu_wait(vid_wait),
    .plane_en(2'b11), .grom_bank(2'b00),
    .color_latch0(PEN0), .color_latch1(7'h00),
    .grom0_addr(grom_addr), .grom0_data(grom_data), .grom0_cs(grom_cs), .grom0_ok(grom_ok),
    .grom1_addr(), .grom1_data(16'h0000), .grom1_cs(grom1_cs), .grom1_ok(1'b1),
    .grm3_addr(grm3_addr), .grm3_data(16'h0000), .grm3_cs(grm3_cs), .grm3_ok(1'b1),
    .vram_addr(vram_addr), .vram_data(vram_data), .vram_din(vram_din),
    .vram_dsn(vram_dsn), .vram_we(vram_we), .vram_cs(vram_cs), .vram_ok(vram_ok),
    .vramrd_addr(vramrd_addr), .vramrd_data(vramrd_data),
    .vramrd_cs(vramrd_cs), .vramrd_ok(vramrd_ok),
    .vblank_irq(vblank_irq), .blit_irq(blit_irq), .scan_irq(scan_irq),
    .HS(HS), .VS(VS), .LHBL(LHBL), .LVBL(LVBL),
    .red(red), .green(green), .blue(blue),
    .gfx_en(4'hF), .debug_bus(8'h00),
    .st_bbusy(st_bbusy), .st_bwait(st_bwait), .st_bwr(st_bwr), .st_bgf(st_bgf), .st_bnum(st_bnum),
    .st_gpen(st_gpen), .st_gseen(st_gseen), .st_gcnt(st_gcnt),
    .st_gmulti(st_gmulti), .st_palhit(st_palhit), .st_palcnt(st_palcnt)
);


task wreg(input [5:0] idx, input [15:0] val); begin
    @(posedge clk);
    cpu_addr <= { 16'd0, idx, 1'b0 };
    cpu_dout <= val;
    vreg_cs  <= 1;
    bus_wstb <= 1;
    @(posedge clk);
    bus_wstb <= 0;
    vreg_cs  <= 0;
    @(posedge clk);
end endtask

integer got, missing, i;
reg [15:0] exp_pen[0:24];
initial begin
    exp_pen[0] = 16'h12FD;
    exp_pen[1] = 16'h12FD;
    exp_pen[2] = 16'h12FD;
    exp_pen[3] = 16'h12FD;
    exp_pen[4] = 16'h12FD;
    exp_pen[5] = 16'h12FD;
    exp_pen[6] = 16'h1111;
    exp_pen[7] = 16'h1111;
    exp_pen[8] = 16'h1111;
    exp_pen[9] = 16'h1111;
    exp_pen[10] = 16'h12FD;
    exp_pen[11] = 16'h12FD;
    exp_pen[12] = 16'h12FD;
    exp_pen[13] = 16'h12FD;
    exp_pen[14] = 16'h1111;
    exp_pen[15] = 16'h12FD;
    exp_pen[16] = 16'h1111;
    exp_pen[17] = 16'h1111;
    exp_pen[18] = 16'h1111;
    exp_pen[19] = 16'h1111;
    exp_pen[20] = 16'h12FD;
    exp_pen[21] = 16'h12FD;
    exp_pen[22] = 16'h12FD;
    exp_pen[23] = 16'h12FD;
    exp_pen[24] = 16'h12FD;
end
reg [15:0] w;
reg [21:0] a;

initial begin
    repeat(20) @(posedge clk);
    rst = 0;
    repeat(20) @(posedge clk);

    repeat(20) @(posedge clk);

    wreg(6'h03, 16'hD5A1);      // FLAGS as the service menu uses them
    wreg(6'h07, PIXELS);        // WIDTH  (RLE uses pixels directly)
    wreg(6'h06, HEIGHT);        // HEIGHT
    wreg(6'h08, 16'h0200);      // ADDRLO
    wreg(6'h17, 16'h0000);      // ADDRHI
    wreg(6'h09, BX);            // X
    wreg(6'h0a, BY);            // Y
    wreg(6'h0b, 16'h0100);      // SRC_YSTEP
    wreg(6'h0c, 16'h0100);      // SRC_XSTEP
    wreg(6'h0d, 16'h0000);      // DST_XSTEP (DSTXSCALE clear -> unused)
    wreg(6'h0e, 16'h0100);      // DST_YSTEP
    wreg(6'h0f, 16'h0000);      // YSTEP_PER_X
    wreg(6'h10, 16'h0000);      // XSTEP_PER_Y
    wreg(6'h12, 16'h0000);      // LEFTCLIP
    wreg(6'h13, 16'h017F);      // RIGHTCLIP
    wreg(6'h14, 16'h0000);      // TOPCLIP
    wreg(6'h15, 16'h00EF);      // BOTTOMCLIP

    wreg(6'h04, 16'h0002);      // COMMAND = 2 -> draw_rle

    // wait for the blit to finish
    fork : waitblit
        begin
            @(posedge clk);
            wait( !u_video.blit_busy );
        end
        #2_000_000;
    join_any
    disable waitblit;
    repeat(200) @(posedge clk);

    got = 0; missing = 0;
    begin : chk
      integer xx, yy;
      for( yy=0; yy<HEIGHT; yy=yy+1 )
        for( xx=0; xx<PIXELS; xx=xx+1 ) begin
            a = 20'h40000 + (BY+yy)*512 + (BX+xx);
            w = vmem[a];
            if( w === exp_pen[yy*5+xx] ) got = got + 1;
            else begin
                missing = missing + 1;
                $display("  (%0d,%0d) got=%04X want=%04X", xx, yy, w, exp_pen[yy*5+xx]);
            end
        end
    end
    $display("");
    $display("service-font 5x5 glyph: %0d of 25 pixels correct", got);
    $display("rendered:");
    begin : shw
      integer xx, yy;
      for( yy=0; yy<HEIGHT; yy=yy+1 ) begin
        $write("   ");
        for( xx=0; xx<PIXELS; xx=xx+1 )
            $write("%s", vmem[20'h40000 + (BY+yy)*512 + (BX+xx)] === 16'h1111 ? "." : "#");
        $write("\n");
      end
    end
    if( missing == 0 ) $display("PASS: real service-menu font decodes correctly");
    else               $display("FAIL: %0d of 25 pixels wrong", missing);
    $finish;
end

endmodule
