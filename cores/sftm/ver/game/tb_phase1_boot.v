`timescale 1ns/1ps
/*  This file is part of SFTM.  GPLv3 - see LICENSE.

    Phase 1 boot verification for the literal-MAME-port sftm_main, using the
    real TG68KdotC_Kernel (ghdl-converted). Self-checking; prints PASS/FAIL.

    The ROM model mimics JTFRAME's SDRAM byte order: the ROM image is built
    as big-endian program bytes, and rom_data[7:0] returns the LOWEST byte
    address of the longword (as jtframe_dwnld stores the download stream).
    rom_ok drops for a few cycles on every new address, like jtframe_romrq.

    Test program (hand-assembled 68020):
      - reset SSP=0x7F00, PC=0x800100 (vectors served from RAM via boot copy)
      - writes 0x1234 to RAM 0x1000, reads it back
      - writes 0x69 to RAM 0x7A6A (the sftm v1.12 protection address), reads
        the protection port 0x680002, stores the result to RAM 0x1002
      - kicks the watchdog, lowers the IRQ mask, then loops
      - VINT autovector 25 ISR: acks via write to 0x080000, increments the
        longword at RAM 0x1004, RTE

    Checks:
      1. boot_done rises (vector copy completed)
      2. first instruction fetch happens at 0x800100
      3. RAM word 0x1000 == 0x1234        (RAM write/readback through the CPU)
      4. RAM byte 0x7A6A -> port 0x680002 -> RAM byte 0x1002 == 0x69
                                          (itech020_prot_result_r path)
      5. RAM long 0x1004 >= 2             (VINT taken, acked, retaken)

    Run:
      cd cores/sftm && iverilog -g2012 -o /tmp/tb_phase1.vvp \
          ver/game/tb_phase1_boot.v hdl/sftm_main.v hdl/sftm_video.v \
          hdl/sftm_blit.v hdl/sftm_vram.v \
          hdl/tg68k/TG68KdotC_Kernel_conv.v && vvp /tmp/tb_phase1.vvp
*/

module tb_phase1_boot;

// ---------------------------------------------------------------------------
// Clocks: 10ns "48 MHz" reference; cen every 2 clks (25 MHz-ish),
// pxl_cen every 6 clks (8 MHz-ish). Ratios match the real core.
// ---------------------------------------------------------------------------
reg clk = 0;
always #5 clk = ~clk;

reg [2:0] cendiv = 0;
always @(posedge clk) cendiv <= cendiv == 3'd5 ? 3'd0 : cendiv + 3'd1;
wire cen     = cendiv[0];            // every 2 clks
wire pxl_cen = cendiv == 3'd5;       // every 6 clks

reg rst = 1;
initial begin
    repeat (20) @(posedge clk);
    rst = 0;
end

// ---------------------------------------------------------------------------
// ROM model: byte array in big-endian program order; 32-bit reads return
// JTFRAME byte order (data[7:0] = lowest byte address). rom_ok models
// jtframe_romrq: drops on address change / cs rise, returns after 4 clks.
// ---------------------------------------------------------------------------
wire [19:2] rom_addr;
wire        rom_cs;
reg  [ 7:0] rom[0:1023];             // 1 KB is plenty for the test program
wire [31:0] rom_data;
reg         rom_ok = 0;
reg  [19:2] ok_addr;
reg  [ 2:0] ok_cnt;

wire [9:0] ba = {rom_addr[9:2], 2'b00};
assign rom_data = { rom[ba+3], rom[ba+2], rom[ba+1], rom[ba] };

always @(posedge clk) begin
    if( !rom_cs ) begin
        ok_cnt <= 3'd0;
        rom_ok <= 1'b0;
    end else if( rom_addr != ok_addr ) begin
        ok_addr <= rom_addr;
        ok_cnt  <= 3'd0;
        rom_ok  <= 1'b0;
    end else if( ok_cnt != 3'd4 ) begin
        ok_cnt <= ok_cnt + 3'd1;
    end else
        rom_ok <= 1'b1;
end

// program image
integer k;
task w32(input [9:0] a, input [31:0] v); begin
    rom[a]   = v[31:24];  rom[a+1] = v[23:16];
    rom[a+2] = v[15: 8];  rom[a+3] = v[ 7: 0];
end endtask
task w16(input [9:0] a, input [15:0] v); begin
    rom[a] = v[15:8]; rom[a+1] = v[7:0];
end endtask

initial begin
    // zero-init DUT RAM: real BRAM powers up cleared, but simulation x's
    // would poison the ISR's read-modify-write counter (x+1 = x)
    for( k=0; k<16384; k=k+1 ) begin
        u_main.ram_hi[k] = 8'h00;
        u_main.ram_lo[k] = 8'h00;
    end
    for( k=0; k<1024; k=k+1 ) rom[k] = 8'h00;
    // vector table (copied to RAM by the boot FSM)
    w32(10'h000, 32'h0000_7F00);          // SSP
    w32(10'h004, 32'h0080_0100);          // PC
    w32(10'h064, 32'h0080_0200);          // autovector 25 (VINT)
    // main program @ 0x800100 -> ROM offset 0x100
    w16(10'h100, 16'h33FC); w32(10'h102, 32'h1234_0000); w16(10'h106, 16'h1000); // move.w #$1234,$001000.l
    w16(10'h108, 16'h3039); w32(10'h10A, 32'h0000_1000);                          // move.w $001000.l,d0
    w16(10'h10E, 16'h13FC); w32(10'h110, 32'h0069_0000); w16(10'h114, 16'h7A6A);  // move.b #$69,$007A6A.l
    w16(10'h116, 16'h1039); w32(10'h118, 32'h0068_0002);                          // move.b $680002.l,d0
    w16(10'h11C, 16'h13C0); w32(10'h11E, 32'h0000_1002);                          // move.b d0,$001002.l
    w16(10'h122, 16'h46FC); w16(10'h124, 16'h2000);                               // move.w #$2000,SR
    w16(10'h126, 16'h23C0); w32(10'h128, 32'h0040_0000);                          // move.l d0,$400000.l (watchdog)
    w16(10'h12C, 16'h60FE);                                                       // bra.s *
    // VINT ISR @ 0x800200 -> ROM offset 0x200
    w16(10'h200, 16'h33C0); w32(10'h202, 32'h0008_0000);                          // move.w d0,$080000.l (int1 ack)
    w16(10'h206, 16'h52B9); w32(10'h208, 32'h0000_1004);                          // addq.l #1,$001004.l
    w16(10'h20C, 16'h4E73);                                                       // rte
end

// ---------------------------------------------------------------------------
// DUT: sftm_main + sftm_video (real modules)
// ---------------------------------------------------------------------------
wire [23:1] cpu_addr;
wire [15:0] cpu_dout, vreg_dout, pal_dout;
wire        cpu_rnw, cpu_uds_n, cpu_lds_n, bus_wstb, vreg_cs, pal_cs;
wire [ 1:0] plane_en, grom_bank;
wire [ 6:0] color_latch0, color_latch1;
wire        vblank_irq, blit_irq, scan_irq;
wire        HS, VS, LHBL, LVBL;
wire [ 4:0] red, green, blue;
wire [ 7:0] snd_latch1, snd_latch2;
wire        snd_pending1, snd_pending2;
wire [ 7:0] st_dout;
wire [24:1] grom_addr;
wire [18:1] grm3_addr;
wire        grom_cs, grm3_cs, vid_wait;

// trivial VRAM SDRAM model: always-ready, data zero (no blits in this bench)
wire [20:1] vram_addr;
wire [15:0] vram_din;
wire [ 1:0] vram_dsn;
wire        vram_we, vram_cs;

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
    .debug_bus(8'h00), .st_dout(st_dout),
    // NVRAM persistence ports: idle in these benches
    .ioctl_addr(27'd0), .ioctl_ram(1'b0), .ioctl_wr(1'b0),
    .ioctl_dout(8'h00), .ioctl_din()
);

sftm_video u_video(
    .rst(rst), .clk(clk), .pxl_cen(pxl_cen),
    .cpu_addr(cpu_addr), .cpu_dout(cpu_dout),
    .cpu_uds_n(cpu_uds_n), .cpu_lds_n(cpu_lds_n), .bus_wstb(bus_wstb),
    .vreg_cs(vreg_cs), .pal_cs(pal_cs),
    .vreg_dout(vreg_dout), .pal_dout(pal_dout), .cpu_wait(vid_wait),
    .plane_en(plane_en), .grom_bank(grom_bank),
    .color_latch0(color_latch0), .color_latch1(color_latch1),
    .grom_addr(grom_addr), .grom_data(16'h0000), .grom_cs(grom_cs), .grom_ok(1'b1),
    .grm3_addr(grm3_addr), .grm3_data(16'h0000), .grm3_cs(grm3_cs), .grm3_ok(1'b1),
    .vram_addr(vram_addr), .vram_data(16'h0000), .vram_din(vram_din),
    .vram_dsn(vram_dsn), .vram_we(vram_we), .vram_cs(vram_cs), .vram_ok(1'b1),
    // vramrd: 32-bit read alias used by the scanline prefetch; this bench only
    // needs it to not stall, matching the tied-high vram_ok above.
    .vramrd_addr(), .vramrd_data(32'd0), .vramrd_cs(), .vramrd_ok(1'b1),
    .vblank_irq(vblank_irq), .blit_irq(blit_irq), .scan_irq(scan_irq),
    .HS(HS), .VS(VS), .LHBL(LHBL), .LVBL(LVBL),
    .red(red), .green(green), .blue(blue),
    .gfx_en(4'hF), .debug_bus(8'h00)
);

// ---------------------------------------------------------------------------
// Checks
// ---------------------------------------------------------------------------
reg seen_boot = 0, seen_fetch = 0;
integer errors = 0;

always @(posedge clk) begin
    if( u_main.boot_done && !seen_boot ) begin
        seen_boot = 1;
        $display("[%0t] boot copy done", $time);
    end
    // first instruction fetch after boot: busstate 00 at 0x800100
    if( u_main.boot_done && !seen_fetch && u_main.busstate == 2'b00 &&
        u_main.cpu_a[23:0] == 24'h800100 && u_main.grant ) begin
        seen_fetch = 1;
        $display("[%0t] first fetch at 0x800100", $time);
    end
end

task check(input cond, input [255:0] name); begin
    if( cond ) $display("PASS: %0s", name);
    else begin  $display("FAIL: %0s", name); errors = errors + 1; end
end endtask

initial begin
    // 2.5 simulated frames at ~8.7 ms/frame
    #22_000_000;
    check( seen_boot,  "boot vector copy completed" );
    check( seen_fetch, "reset PC fetched from vectors (0x800100)" );
    check( {u_main.ram_hi[12'h800], u_main.ram_lo[12'h800]} == 16'h1234,
           "RAM write/readback (0x1000 == 0x1234)" );
    check( u_main.ram_hi[12'h801] == 8'h69,
           "protection readback (RAM 0x7A6A -> 0x680002 -> RAM 0x1002)" );
    check( {u_main.ram_hi[12'h803], u_main.ram_lo[12'h803]} >= 16'd2,
           "VINT taken/acked repeatedly (RAM 0x1004 >= 2)" );
    check( errors == 0, "ALL PHASE 1 CHECKS" );
    $finish;
end

endmodule
