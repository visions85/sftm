`timescale 1ns/1ps
/*  This file is part of SFTM.  GPLv3 - see LICENSE.

    Phase 2 blitter verification. The CPU program (real TG68K kernel):
      1. sets color latch 0 = 0x12, programs the blit registers
      2. command 1: raw 4x2 blit from GROM 0x100 to (10,20), TRANSPARENT set;
         GROM holds 01 02 FF 04 / 05 06 07 08 (FF must be skipped)
      3. polls VIDEO_INTSTATE for VIDEOINT_BLITTER, acks it
      4. command 2: RLE blit from GROM 0x200 to (100,50), width 7:
         [83 21 22 23] literal x3, [02 FF] transparent repeat x2,
         [82 31 32] literal x2
      5. command 6: shiftreg copy of row 20 (from x=10) to rows 21 and 22
      6. command 3 at (10,20) 1x1: pokes 0x55 and reads the OLD pen back
         through VIDEO_TRANSFER (CPU is stalled by cpu_wait while the
         read-modify-write runs), stores it to RAM 0x1010
      7. writes 0xCAFE to RAM 0x1020 as a done flag

    Checks (against the behavioral VRAM SDRAM model, init 0x1111):
      row 20: [10]=0x1255 (poked) [11]=0x1202 [12]=0x1111 (transparent)
              [13]=0x1204
      rows 21,22: copies of pre-poke row 20 at [10..13]
      row 50: [100..102]=0x1221,0x1222,0x1223  [103,104]=0x1111
              [105,106]=0x1231,0x1232
      RAM 0x1010 == 0x1201 (old pen readback)
      scanout: scan_pen == 0x1202 when (hcnt,vcnt) pass pixel (11,20)

    Run:
      cd cores/sftm && iverilog -g2012 -o /tmp/tb_phase2.vvp \
          ver/game/tb_phase2_blit.v hdl/sftm_main.v hdl/sftm_video.v \
          hdl/sftm_blit.v hdl/sftm_vram.v \
          hdl/tg68k/TG68KdotC_Kernel_conv.v && vvp /tmp/tb_phase2.vvp
*/

module tb_phase2_blit;

reg clk = 0;
always #5 clk = ~clk;

reg [2:0] cendiv = 0;
always @(posedge clk) cendiv <= cendiv == 3'd5 ? 3'd0 : cendiv + 3'd1;
wire cen     = cendiv[0];
wire pxl_cen = cendiv == 3'd5;

reg rst = 1;
initial begin
    repeat (20) @(posedge clk);
    rst = 0;
end

// ---------------------------------------------------------------------------
// program ROM model (JTFRAME byte order + romrq-style ok latency)
// ---------------------------------------------------------------------------
wire [19:2] rom_addr;
wire        rom_cs;
reg  [ 7:0] rom[0:2047];
wire [31:0] rom_data;
reg         rom_ok = 0;
reg  [19:2] ok_addr;
reg  [ 2:0] ok_cnt;

wire [10:0] ba = {rom_addr[10:2], 2'b00};
assign rom_data = { rom[ba+3], rom[ba+2], rom[ba+1], rom[ba] };

always @(posedge clk) begin
    if( !rom_cs ) begin
        ok_cnt <= 0; rom_ok <= 0;
    end else if( rom_addr != ok_addr ) begin
        ok_addr <= rom_addr; ok_cnt <= 0; rom_ok <= 0;
    end else if( ok_cnt != 3'd4 )
        ok_cnt <= ok_cnt + 3'd1;
    else
        rom_ok <= 1;
end

// program assembler: cursor-based emit
integer pc;
task ew(input [15:0] v); begin
    rom[pc] = v[15:8]; rom[pc+1] = v[7:0]; pc = pc + 2;
end endtask
task movw(input [15:0] imm, input [31:0] a); begin
    ew(16'h33FC); ew(imm); ew(a[31:16]); ew(a[15:0]);
end endtask
task poll_blit_ack; begin
    // L: move.w $500004,d0; andi.w #$40,d0; beq.s L; move.w #$40,$500004
    ew(16'h3039); ew(16'h0050); ew(16'h0004);
    ew(16'h0240); ew(16'h0040);
    ew(16'h67F4);
    movw(16'h0040, 32'h00500004);
end endtask

task w32(input [10:0] a, input [31:0] v); begin
    rom[a]   = v[31:24];  rom[a+1] = v[23:16];
    rom[a+2] = v[15: 8];  rom[a+3] = v[ 7: 0];
end endtask

integer k;
initial begin
    for( k=0; k<2048; k=k+1 ) rom[k] = 8'h00;
    for( k=0; k<16384; k=k+1 ) begin
        u_main.ram_hi[k] = 8'h00;
        u_main.ram_lo[k] = 8'h00;
    end
    w32(11'h000, 32'h0000_7F00);      // SSP
    w32(11'h004, 32'h0080_0100);      // PC

    pc = 'h100;
    movw(16'hFFFF, 32'h00500004);                       // INTACK all
    ew(16'h13FC); ew(16'h0012); ew(16'h0030); ew(16'h0003); // move.b #$12,$300003 (color 0)
    // raw blit
    movw(16'h0001, 32'h0050000C);     // FLAGS = TRANSPARENT
    movw(16'h0004, 32'h0050001C);     // WIDTH 4
    movw(16'h0002, 32'h00500018);     // HEIGHT 2
    movw(16'h0100, 32'h00500020);     // ADDRLO 0x100
    movw(16'h0000, 32'h0050005C);     // ADDRHI 0
    movw(16'h000A, 32'h00500024);     // X 10
    movw(16'h0014, 32'h00500028);     // Y 20
    movw(16'h0100, 32'h00500030);     // SRC_XSTEP
    movw(16'h0100, 32'h0050002C);     // SRC_YSTEP
    movw(16'h0100, 32'h00500034);     // DST_XSTEP
    movw(16'h0100, 32'h00500038);     // DST_YSTEP
    movw(16'h0000, 32'h0050003C);     // YSTEP_PER_X
    movw(16'h0000, 32'h00500040);     // XSTEP_PER_Y
    movw(16'h0001, 32'h00500010);     // COMMAND 1
    poll_blit_ack;
    // rle blit
    movw(16'h0007, 32'h0050001C);     // WIDTH 7
    movw(16'h0001, 32'h00500018);     // HEIGHT 1
    movw(16'h0200, 32'h00500020);     // ADDRLO 0x200
    movw(16'h0064, 32'h00500024);     // X 100
    movw(16'h0032, 32'h00500028);     // Y 50
    movw(16'h0002, 32'h00500010);     // COMMAND 2
    poll_blit_ack;
    // shiftreg: copy row 20 to rows 21,22
    movw(16'h000A, 32'h00500024);     // X 10
    movw(16'h0014, 32'h00500028);     // Y 20
    movw(16'h0003, 32'h00500018);     // HEIGHT 3
    movw(16'h0006, 32'h00500010);     // COMMAND 6
    poll_blit_ack;
    // cmd3 readback at (10,20)
    movw(16'h0001, 32'h0050001C);     // WIDTH 1
    movw(16'h0001, 32'h00500018);     // HEIGHT 1
    movw(16'h0003, 32'h00500010);     // COMMAND 3
    movw(16'h0055, 32'h00500008);     // poke TRANSFER (write 0x55)
    ew(16'h3039); ew(16'h0050); ew(16'h0008);           // move.w $500008,d0
    ew(16'h33C0); ew(16'h0000); ew(16'h1010);           // move.w d0,$001010
    movw(16'hCAFE, 32'h00001020);     // done flag
    ew(16'h60FE);                                       // bra.s *
end

// ---------------------------------------------------------------------------
// GROM model (bank 2): byte stream, data[7:0] = even byte
// ---------------------------------------------------------------------------
wire [24:1] grom_addr;
wire        grom_cs;
reg  [ 7:0] gmem[0:2047];
reg         grom_ok = 0;
reg  [24:1] gok_addr;
reg  [ 1:0] gok_cnt;
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
    // raw source at 0x100
    gmem['h100]=8'h01; gmem['h101]=8'h02; gmem['h102]=8'hFF; gmem['h103]=8'h04;
    gmem['h104]=8'h05; gmem['h105]=8'h06; gmem['h106]=8'h07; gmem['h107]=8'h08;
    // rle stream at 0x200
    gmem['h200]=8'h83; gmem['h201]=8'h21; gmem['h202]=8'h22; gmem['h203]=8'h23;
    gmem['h204]=8'h02; gmem['h205]=8'hFF;
    gmem['h206]=8'h82; gmem['h207]=8'h31; gmem['h208]=8'h32;
end

// ---------------------------------------------------------------------------
// VRAM SDRAM model (jtframe-ish rw bus): init 0x1111
// ---------------------------------------------------------------------------
wire [20:1] vram_addr;
wire [15:0] vram_din;
wire [ 1:0] vram_dsn;
wire        vram_we, vram_cs;
reg  [15:0] vmem[0:1048575];
reg         vram_ok = 0;
reg  [20:1] vok_addr;
reg  [ 1:0] vok_cnt;
reg  [15:0] vram_data_r;
wire [15:0] vram_data = vram_data_r;

initial for( k=0; k<1048576; k=k+1 ) vmem[k] = 16'h1111;

always @(posedge clk) begin
    if( !vram_cs ) begin
        vok_cnt <= 0; vram_ok <= 0;
    end else if( vram_addr != vok_addr ) begin
        vok_addr <= vram_addr; vok_cnt <= 0; vram_ok <= 0;
    end else if( vok_cnt != 2'd3 )
        vok_cnt <= vok_cnt + 2'd1;
    else if( !vram_ok ) begin
        if( vram_we )
            vmem[vram_addr] <= vram_din;
        else
            vram_data_r <= vmem[vram_addr];
        vram_ok <= 1;
    end
end


// vramrd: read-only 32-bit alias of vmem (mem.yaml offset 0); one access
// returns the pixel pair {vmem[2j+1], vmem[2j]}.
localparam [7:0] RDLAT = 8'd3;
wire [20:2] vramrd_addr;
wire        vramrd_cs;
reg         vramrd_ok = 0;
reg  [20:2] rok_addr;
reg  [ 7:0] rok_cnt;
reg  [31:0] vramrd_data_r;
wire [31:0] vramrd_data = vramrd_data_r;
reg         rd_last_cs = 0, rd_busy = 0;
wire        rd_cs_posedge = vramrd_cs && !rd_last_cs;

always @(posedge clk) begin
    rd_last_cs <= vramrd_cs;
    if( !vramrd_cs ) begin
        rok_cnt <= 0; vramrd_ok <= 0; rd_busy <= 0;
    end else if( rd_cs_posedge ) begin
        rok_addr <= vramrd_addr; rok_cnt <= 0; vramrd_ok <= 0; rd_busy <= 1;
    end else if( rd_busy ) begin
        if( rok_cnt != RDLAT ) rok_cnt <= rok_cnt + 8'd1;
        else if( !vramrd_ok ) begin
            vramrd_data_r <= { vmem[{rok_addr,1'b1}], vmem[{rok_addr,1'b0}] };
            vramrd_ok     <= 1;
        end
    end
end

// ---------------------------------------------------------------------------
// DUT
// ---------------------------------------------------------------------------
wire [23:1] cpu_addr;
wire [15:0] cpu_dout, vreg_dout, pal_dout;
wire        cpu_rnw, cpu_uds_n, cpu_lds_n, bus_wstb, vreg_cs, pal_cs, vid_wait;
wire [ 1:0] plane_en, grom_bank;
wire [ 6:0] color_latch0, color_latch1;
wire        vblank_irq, blit_irq, scan_irq;
wire        HS, VS, LHBL, LVBL;
wire [ 4:0] red, green, blue;
wire [ 7:0] snd_latch1, snd_latch2;
wire        snd_pending1, snd_pending2;
wire [ 7:0] st_dout;
wire [18:1] grm3_addr;
wire        grm3_cs;

sftm_main u_main(
    .rst(rst), .clk(clk), .cen(cen),
    .rom_addr(rom_addr), .rom_data(rom_data), .rom_cs(rom_cs), .rom_ok(rom_ok),
    .joystick1(16'hFFFF), .joystick2(16'hFFFF),
    .cab_1p(4'hF), .coin(4'hF), .service(1'b1), .dip_test(1'b1),
    .dipsw_a(8'h00),
    .cpu_addr(cpu_addr), .cpu_dout(cpu_dout), .cpu_rnw(cpu_rnw),
    .cpu_uds_n(cpu_uds_n), .cpu_lds_n(cpu_lds_n), .bus_wstb(bus_wstb),
    .vreg_cs(vreg_cs), .pal_cs(pal_cs),
    .vreg_dout(vreg_dout), .pal_dout(pal_dout), .vid_wait(vid_wait),
    .plane_en(plane_en), .grom_bank(grom_bank),
    .color_latch0(color_latch0), .color_latch1(color_latch1),
    .vblank_irq(vblank_irq), .blit_irq(blit_irq), .scan_irq(scan_irq),
    .LVBL(LVBL),
    .snd_latch1(snd_latch1), .snd_latch2(snd_latch2),
    .snd_pending1(snd_pending1), .snd_pending2(snd_pending2),
    .snd_latch1_rd(1'b0), .snd_latch2_rd(1'b0),
    .debug_bus(8'h00), .st_dout(st_dout)
);

sftm_video u_video(
    .rst(rst), .clk(clk), .pxl_cen(pxl_cen),
    .cpu_addr(cpu_addr), .cpu_dout(cpu_dout),
    .cpu_uds_n(cpu_uds_n), .cpu_lds_n(cpu_lds_n), .bus_wstb(bus_wstb),
    .vreg_cs(vreg_cs), .pal_cs(pal_cs),
    .vreg_dout(vreg_dout), .pal_dout(pal_dout), .cpu_wait(vid_wait),
    .plane_en(plane_en), .grom_bank(grom_bank),
    .color_latch0(color_latch0), .color_latch1(color_latch1),
    .grom_addr(grom_addr), .grom_data(grom_data), .grom_cs(grom_cs), .grom_ok(grom_ok),
    .grm3_addr(grm3_addr), .grm3_data(16'h0000), .grm3_cs(grm3_cs), .grm3_ok(1'b1),
    .vram_addr(vram_addr), .vram_data(vram_data), .vram_din(vram_din),
    .vram_dsn(vram_dsn),     .vram_we(vram_we), .vram_cs(vram_cs), .vram_ok(vram_ok),
    .vramrd_addr(vramrd_addr), .vramrd_data(vramrd_data),
    .vramrd_cs(vramrd_cs), .vramrd_ok(vramrd_ok),
    .vblank_irq(vblank_irq), .blit_irq(blit_irq), .scan_irq(scan_irq),
    .HS(HS), .VS(VS), .LHBL(LHBL), .LVBL(LVBL),
    .red(red), .green(green), .blue(blue),
    .gfx_en(4'hF), .debug_bus(8'h00)
);

// ---------------------------------------------------------------------------
// checks
// ---------------------------------------------------------------------------
function [19:0] vp0(input [9:0] yy, input [8:0] xx);
    vp0 = { 1'b0, yy, xx };            // plane 0 word index {plane,y,x}
endfunction

reg seen_scan = 0;
always @(posedge clk) begin
    if( pxl_cen && u_video.vcnt == 9'd20 && u_video.hcnt == 9'd11 &&
        u_video.scan_pen == 16'h1202 )
        seen_scan <= 1;
end

integer errors = 0;
task check(input cond, input [255:0] name); begin
    if( cond ) $display("PASS: %0s", name);
    else begin  $display("FAIL: %0s", name); errors = errors + 1; end
end endtask

initial begin
    // wait for the done flag, max 20 ms (2+ frames for the scanout check)
    wait( !rst );
    fork : waitdone
        wait( {u_main.ram_hi[12'h810], u_main.ram_lo[12'h810]} == 16'hCAFE );
        #20_000_000;
    join_any
    disable waitdone;
    #10_000_000;   // one more frame for scanout sampling

    check( {u_main.ram_hi[12'h810], u_main.ram_lo[12'h810]} == 16'hCAFE,
           "program completed (done flag 0xCAFE)" );
    // raw blit results (post-cmd3 poke at [10])
    check( vmem[vp0(10'd20, 9'd10)] == 16'h1255, "raw+poke (10,20) == 0x1255" );
    check( vmem[vp0(10'd20, 9'd11)] == 16'h1202, "raw (11,20) == 0x1202" );
    check( vmem[vp0(10'd20, 9'd12)] == 16'h1111, "raw transparent (12,20) untouched" );
    check( vmem[vp0(10'd20, 9'd13)] == 16'h1204, "raw (13,20) == 0x1204" );
    // shiftreg copies of pre-poke row 20
    check( vmem[vp0(10'd21, 9'd10)] == 16'h1201 &&
           vmem[vp0(10'd21, 9'd12)] == 16'h1111 &&
           vmem[vp0(10'd21, 9'd13)] == 16'h1204, "shiftreg row 21 copy" );
    check( vmem[vp0(10'd22, 9'd10)] == 16'h1201 &&
           vmem[vp0(10'd22, 9'd13)] == 16'h1204, "shiftreg row 22 copy" );
    // rle
    check( vmem[vp0(10'd50, 9'd100)] == 16'h1221 &&
           vmem[vp0(10'd50, 9'd101)] == 16'h1222 &&
           vmem[vp0(10'd50, 9'd102)] == 16'h1223, "rle literal run" );
    check( vmem[vp0(10'd50, 9'd103)] == 16'h1111 &&
           vmem[vp0(10'd50, 9'd104)] == 16'h1111, "rle transparent repeat" );
    check( vmem[vp0(10'd50, 9'd105)] == 16'h1231 &&
           vmem[vp0(10'd50, 9'd106)] == 16'h1232, "rle trailing literal" );
    // cmd3 old-pen readback through VIDEO_TRANSFER
    check( {u_main.ram_hi[12'h808], u_main.ram_lo[12'h808]} == 16'h1201,
           "cmd3 old-pen readback == 0x1201" );
    // scanout end-to-end
    check( seen_scan, "scanout: line buffer served pen 0x1202 at (11,20)" );
    check( errors == 0, "ALL PHASE 2 CHECKS" );
    $finish;
end

endmodule
