`timescale 1ns/1ps
// Verify the horizontal phase matches the CRTC registers exactly:
//   HTOTAL 508, active hcnt 50..433 (384 px), HSYNC 484..507
module tb_htime;
reg clk=0, rst=1;
always #10.4 clk=~clk;
reg [2:0] cd=0;
wire pxl_cen = cd==3'd0;
always @(posedge clk) cd <= cd==3'd5 ? 3'd0 : cd+3'd1;
integer k;
wire [24:1] grom_addr; wire grom_cs;
wire [18:1] grm3_addr; wire grm3_cs;
wire [21:1] vram_addr; wire [15:0] vram_din; wire [1:0] vram_dsn;
wire vram_we, vram_cs;
wire [21:2] vramrd_addr; wire vramrd_cs;
wire [15:0] vreg_dout, pal_dout;
wire vid_wait, vblank_irq, blit_irq, scan_irq, HS, VS, LHBL, LVBL;
wire [4:0] red,green,blue;
sftm_video u_video(
    .rst(rst), .clk(clk), .pxl_cen(pxl_cen),
    .cpu_addr(23'd0), .cpu_dout(16'd0), .cpu_uds_n(1'b0), .cpu_lds_n(1'b0),
    .bus_wstb(1'b0), .vreg_cs(1'b0), .pal_cs(1'b0),
    .vreg_dout(vreg_dout), .pal_dout(pal_dout), .cpu_wait(vid_wait),
    .plane_en(2'b01), .grom_bank(2'b00), .color_latch0(7'h00), .color_latch1(7'h00),
    .grom_addr(grom_addr), .grom_data(16'h0), .grom_cs(grom_cs), .grom_ok(1'b1),
    .grm3_addr(grm3_addr), .grm3_data(16'h0), .grm3_cs(grm3_cs), .grm3_ok(1'b1),
    .vram_addr(vram_addr), .vram_data(16'h0), .vram_din(vram_din),
    .vram_dsn(vram_dsn), .vram_we(vram_we), .vram_cs(vram_cs), .vram_ok(1'b1),
    .vramrd_addr(vramrd_addr), .vramrd_data(32'h0), .vramrd_cs(vramrd_cs), .vramrd_ok(1'b1),
    .vblank_irq(vblank_irq), .blit_irq(blit_irq), .scan_irq(scan_irq),
    .HS(HS), .VS(VS), .LHBL(LHBL), .LVBL(LVBL),
    .red(red), .green(green), .blue(blue), .gfx_en(4'hF), .debug_bus(8'h00));

reg hs_at[0:511];
reg ac_at[0:511];
integer k2, hs_lo, hs_hi, ac_lo, ac_hi, nact, nhs, errors;
initial for( k2=0; k2<512; k2=k2+1 ) begin hs_at[k2]=0; ac_at[k2]=0; end

// sample every active pixel tick; a full line overwrites each slot once
always @(posedge clk) if( pxl_cen ) begin
    hs_at[u_video.hcnt] <= HS;
    ac_at[u_video.hcnt] <= LHBL;
end

initial begin
    repeat(20) @(posedge clk); rst=0;
    repeat(40000) @(posedge clk);          // several full lines
    hs_lo=-1; hs_hi=-1; ac_lo=-1; ac_hi=-1; nact=0; nhs=0;
    for( k=0; k<508; k=k+1 ) begin
        if( hs_at[k] ) begin
            if( hs_lo<0 ) hs_lo=k;
            hs_hi=k; nhs=nhs+1;
        end
        if( ac_at[k] ) begin
            if( ac_lo<0 ) ac_lo=k;
            ac_hi=k; nact=nact+1;
        end
    end
    errors=0;
    $display("");
    $display("active window : hcnt %0d..%0d  (%0d px)   expect 50..433 / 384", ac_lo, ac_hi, nact);
    $display("hsync  window : hcnt %0d..%0d  (%0d px)   expect 484..507 / 24", hs_lo, hs_hi, nhs);
    if( ac_lo!=50  || ac_hi!=433 || nact!=384 ) begin $display("FAIL: active window"); errors=errors+1; end
    if( hs_lo!=484 || hs_hi!=507 || nhs !=24  ) begin $display("FAIL: hsync window");  errors=errors+1; end
    if( errors==0 ) $display("PASS: horizontal phase matches the CRTC registers");
    $finish;
end
endmodule
