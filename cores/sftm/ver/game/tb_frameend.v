`timescale 1ns/1ps
// Does frame_end fire exactly once per video frame?
//
// bc_busy is reset on frame_end and a frame is 508*286*6 = 871,728 clk, so
// bc_busy[19:16] cannot exceed 13 (0xD). Hardware reports 15 (0xF), which
// means the counter passed 983,040 -- i.e. frame_end did not fire for at least
// one frame and two frames accumulated into one count. Every absolute
// throughput figure is measured over that window, so this has to be settled
// before any of them mean anything.
//
// LVBL falls at vcnt 255 and rises at 285 (sftm_video.v:605-609), both inside
// `if( pxl_cen ) if( line_end )`. frame_end is `lvbl_d && !LVBL` sampled every
// clk. This drives the real module and measures the interval between pulses.
module tb_frameend;

localparam FRAME_CLK = 508*286*6;   // 871,728

reg clk=0, rst=1;
always #10.4 clk=~clk;              // 48 MHz
reg [2:0] cd=0;
wire pxl_cen = cd==3'd0;
always @(posedge clk) cd <= cd==3'd5 ? 3'd0 : cd+3'd1;

wire [23:1] grom0_addr, grom1_addr; wire [18:1] grm3_addr;
wire [20:2] vram_addr; wire [31:0] vram_din; wire [3:0] vram_dsn;
wire vram_we, vram_rd;
wire [15:0] vreg_dout, pal_dout; wire vid_wait;
wire vblank_irq, blit_irq, scan_irq, HS, VS, LHBL, LVBL;
wire [7:0] red, green, blue;
wire [3:0] st_bbusy, st_bwait, st_bwr, st_bgf, st_bnum, st_bstw, st_fper;
wire [14:0] st_gpen; wire st_gseen; wire [3:0] st_gcnt;
wire st_gmulti, st_palhit; wire [7:0] st_palcnt;
wire grom0_cs, grom1_cs, grm3_cs;

sftm_video u_video(
    .rst(rst), .clk(clk), .pxl_cen(pxl_cen),
    .cpu_addr(24'd0), .cpu_dout(16'd0),
    .cpu_uds_n(1'b0), .cpu_lds_n(1'b0), .bus_wstb(1'b0),
    .vreg_cs(1'b0), .pal_cs(1'b0),
    .vreg_dout(vreg_dout), .pal_dout(pal_dout), .cpu_wait(vid_wait),
    .plane_en(2'b11), .grom_bank(3'd0),
    .color_latch0(7'h00), .color_latch1(7'h00),
    .grom0_addr(grom0_addr), .grom0_data(16'd0), .grom0_rd(grom0_cs), .grom0_ok(1'b1),
    .grom1_addr(grom1_addr), .grom1_data(16'd0), .grom1_rd(grom1_cs), .grom1_ok(1'b1),
    .grm3_addr(grm3_addr),   .grm3_data(16'd0),  .grm3_rd(grm3_cs),   .grm3_ok(1'b1),
    .vram_addr(vram_addr), .vram_data(32'd0), .vram_din(vram_din),
    .vram_dsn(vram_dsn), .vram_we(vram_we), .vram_rd(vram_rd), .vram_ok(1'b1),
    .vblank_irq(vblank_irq), .blit_irq(blit_irq), .scan_irq(scan_irq),
    .HS(HS), .VS(VS), .LHBL(LHBL), .LVBL(LVBL),
    .red(red), .green(green), .blue(blue),
    .gfx_en(4'hF), .debug_bus(8'h00),
    .st_bbusy(st_bbusy), .st_bwait(st_bwait), .st_bwr(st_bwr), .st_bgf(st_bgf),
    .st_bnum(st_bnum), .st_bstw(st_bstw), .st_fper(st_fper),
    .st_gpen(st_gpen), .st_gseen(st_gseen), .st_gcnt(st_gcnt),
    .st_gmulti(st_gmulti), .st_palhit(st_palhit), .st_palcnt(st_palcnt)
);

// mirror the DUT's own edge detect
reg lvbl_d=0;
wire frame_end = lvbl_d && !LVBL;
always @(posedge clk) if(!rst) lvbl_d <= LVBL;

integer clk_n=0, last=0, pulses=0, errors=0, i;
integer gap, gmin=0, gmax=0;
always @(posedge clk) if(!rst) begin
    clk_n <= clk_n + 1;
    if( frame_end ) begin
        pulses <= pulses + 1;
        if( pulses > 0 ) begin
            gap = clk_n - last;
            if( pulses == 1 ) begin gmin=gap; gmax=gap; end
            else begin
                if( gap < gmin ) gmin = gap;
                if( gap > gmax ) gmax = gap;
            end
            $display("  frame %0d: %0d clk since previous (expect %0d)",
                     pulses, gap, FRAME_CLK);
        end
        last <= clk_n;
    end
end

initial begin
    repeat(40) @(posedge clk); rst=0;
    // eight frames' worth
    repeat(FRAME_CLK*8) @(posedge clk);
    $display("");
    $display("frame_end pulses in 8 frame periods: %0d (expect 8)", pulses);
    $display("interval min %0d max %0d, expected %0d", gmin, gmax, FRAME_CLK);
    if( pulses < 7 || pulses > 9 ) begin
        errors=errors+1;
        $display("FAIL: frame_end is not firing once per frame");
    end
    if( gmax > FRAME_CLK+64 || (gmin>0 && gmin < FRAME_CLK-64) ) begin
        errors=errors+1;
        $display("FAIL: interval deviates from one frame -- bc_busy can exceed 0xD");
    end
    // the meter the hardware will be read through, checked here first
    $display("st_fper = 0x%0X (expect 0xD = 871,728/65536)", st_fper);
    if( st_fper !== 4'hD ) begin
        errors=errors+1;
        $display("FAIL: frame-period meter reads 0x%0X, not 0xD", st_fper);
    end else
        $display("ok: frame-period meter reads 0xD as designed");

    if( errors==0 )
        $display("PASS: frame_end fires once per frame at the expected interval");
    $finish;
end
initial begin #400_000_000; $display("FAIL: timeout"); $finish; end
endmodule
