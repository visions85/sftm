`timescale 1ns/1ps
// The 32 MB grom region is split across two SDRAM banks because a bus wider
// than its 16 MB bank silently loses its top address bit (see cfg/macros.def).
// grom_base is {grom_bank[1:0], addrhi[7:0], addrlo[15:0]}, so the VIDEO
// transfer bank select IS address bits [25:24]:
//
//   bank 0 -> grom0 (rm0, grom 0x0000000-0x0FFFFFF)
//   bank 1 -> grom1 (rm1, grom 0x1000000-0x1FFFFFF)
//   bank 2 -> grm3  (bit 25 set)
//
// This asserts that each bank reaches the RIGHT bus at the RIGHT offset. The
// old single-bus code sent banks 0 and 1 to the same 24-bit port, where bit 24
// was dropped and rm1 aliased onto rm0 -- exactly the bug this test pins down.
module tb_gromsplit;

localparam PIXELS = 5, BX = 10, BY = 5, HEIGHT = 5;
localparam PEN0 = 7'h12;

reg clk = 0, rst = 1;
always #10.4 clk = ~clk;          // 48 MHz

reg [2:0] cendiv = 0;
wire pxl_cen = cendiv == 3'd0;
always @(posedge clk) cendiv <= cendiv == 3'd5 ? 3'd0 : cendiv + 3'd1;

integer k;

// ---------------------------------------------------------------------------
// Three independent memory models. Each holds the SAME glyph stream but a
// DIFFERENT pen, so the rendered colour identifies which bus was read.
// ---------------------------------------------------------------------------
wire [23:1] grom0_addr, grom1_addr;
wire [18:1] grm3_addr;
wire        grom0_cs, grom1_cs, grm3_cs;

reg [7:0] m0[0:2047], m1[0:2047], m3[0:2047];

// glyph 'E' from the real service font, with the pen byte parameterised
task load(input integer sel, input [7:0] pen);
    integer b;
    begin
        for( b=0; b<2048; b=b+1 )
            if( sel==0 ) m0[b] = 8'h00; else if( sel==1 ) m1[b] = 8'h00; else m3[b] = 8'h00;
        // 06 <pen> 04 FF 04 <pen> 82 FF ...  (FF = transparent)
        wr(sel,'h200+0,8'h06); wr(sel,'h200+1,pen);   wr(sel,'h200+2,8'h04);
        wr(sel,'h200+3,8'hFF); wr(sel,'h200+4,8'h04); wr(sel,'h200+5,pen);
        wr(sel,'h200+6,8'h82); wr(sel,'h200+7,8'hFF); wr(sel,'h200+8,pen);
        wr(sel,'h200+9,8'h04); wr(sel,'h200+10,8'hFF);wr(sel,'h200+11,8'h04);
        wr(sel,'h200+12,pen);  wr(sel,'h200+13,8'h86);wr(sel,'h200+14,8'hFF);
        wr(sel,'h200+15,pen);  wr(sel,'h200+16,8'h05);wr(sel,'h200+17,8'hFF);
        wr(sel,'h200+18,8'h06); wr(sel,'h200+19,pen);
    end
endtask
task wr(input integer sel, input integer a, input [7:0] d);
    if( sel==0 ) m0[a]=d; else if( sel==1 ) m1[a]=d; else m3[a]=d;
endtask

// 3-cycle ok latency per bus, same shape as tb_svcfont's model
`define BUSMODEL(NM, MEM, AW)                                                 \
    reg        NM``_ok = 0;                                                   \
    reg [AW:1] NM``_last;                                                     \
    reg [ 1:0] NM``_cnt;                                                      \
    wire [9:0] NM``_a = NM``_addr[10:1];                                      \
    wire [15:0] NM``_data = { MEM[{NM``_a,1'b1}], MEM[{NM``_a,1'b0}] };       \
    always @(posedge clk) begin                                               \
        if( !NM``_cs ) begin NM``_cnt <= 0; NM``_ok <= 0; end                 \
        else if( NM``_addr != NM``_last ) begin                               \
            NM``_last <= NM``_addr; NM``_cnt <= 0; NM``_ok <= 0;              \
        end else if( NM``_cnt != 2'd3 ) NM``_cnt <= NM``_cnt + 2'd1;          \
        else NM``_ok <= 1;                                                    \
    end

`BUSMODEL(grom0, m0, 23)
`BUSMODEL(grom1, m1, 23)
`BUSMODEL(grm3,  m3, 18)

// which buses were exercised during the current blit
reg g0_seen, g1_seen, g3_seen;
always @(posedge clk) begin
    if( grom0_cs ) g0_seen <= 1;
    if( grom1_cs ) g1_seen <= 1;
    if( grm3_cs  ) g3_seen <= 1;
end

// ---------------------------------------------------------------------------
// VRAM model (write side only; the read port returns the stored word)
// ---------------------------------------------------------------------------
// 32-bit cache lane. vmem stays 16-bit-per-pen so the checks below are
// unchanged; the lane addresses PAIRS of pens.
wire [20:2] vram_addr;
wire [31:0] vram_data, vram_din;
wire [ 3:0] vram_dsn;
wire        vram_we, vram_rd;
// the lane services a request when EITHER strobe is up; modelling only rd
// would re-encode the bug that made build 60 render a black screen
wire        vram_req = vram_rd | vram_we;
reg         vram_ok = 1;

reg [15:0] vmem[0:1048575];
assign vram_data = { vmem[{vram_addr,1'b1}], vmem[{vram_addr,1'b0}] };
always @(posedge clk) if( vram_req && vram_we ) begin
    if( !vram_dsn[0] ) vmem[{vram_addr,1'b0}][ 7:0] <= vram_din[ 7:0];
    if( !vram_dsn[1] ) vmem[{vram_addr,1'b0}][15:8] <= vram_din[15:8];
    if( !vram_dsn[2] ) vmem[{vram_addr,1'b1}][ 7:0] <= vram_din[23:16];
    if( !vram_dsn[3] ) vmem[{vram_addr,1'b1}][15:8] <= vram_din[31:24];
end

reg  [23:1] cpu_addr = 0;
reg  [15:0] cpu_dout = 0;
reg         vreg_cs = 0, bus_wstb = 0;
wire [15:0] vreg_dout, pal_dout;
wire        vid_wait, vblank_irq, blit_irq, scan_irq, HS, VS, LHBL, LVBL;
wire [ 4:0] red, green, blue;
reg  [ 1:0] grom_bank = 0;

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
    .plane_en(2'b11), .grom_bank(grom_bank),
    .color_latch0(PEN0), .color_latch1(7'h00),
    .grom0_addr(grom0_addr), .grom0_data(grom0_data), .grom0_rd(grom0_cs), .grom0_ok(grom0_ok),
    .grom1_addr(grom1_addr), .grom1_data(grom1_data), .grom1_rd(grom1_cs), .grom1_ok(grom1_ok),
    .grm3_addr(grm3_addr),   .grm3_data(grm3_data),   .grm3_rd(grm3_cs),   .grm3_ok(grm3_ok),
    .vram_addr(vram_addr), .vram_data(vram_data), .vram_din(vram_din),
    .vram_dsn(vram_dsn), .vram_we(vram_we), .vram_rd(vram_rd), .vram_ok(vram_ok),
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
    cpu_addr <= { 16'd0, idx, 1'b0 }; cpu_dout <= val;
    vreg_cs <= 1; bus_wstb <= 1;
    @(posedge clk); bus_wstb <= 0; vreg_cs <= 0;
    @(posedge clk);
end endtask

integer fails; integer yy, xx;
reg [15:0] got;
reg [21:0] a;
reg [19:0] sb, sw, sf;
reg [15:0] gsave;
reg [ 3:0] sn;

// draw the glyph from `bank` at row `row` and check the pen that came back
task run_case(input [1:0] bank, input integer row, input [7:0] want_pen,
              input integer want_bus, input [80*8:1] label);
    begin
        g0_seen = 0; g1_seen = 0; g3_seen = 0;
        grom_bank = bank;
        wreg(6'h03, 16'hD5A1);       // FLAGS as the service menu uses them
        wreg(6'h07, PIXELS);
        wreg(6'h06, HEIGHT);
        wreg(6'h08, 16'h0200);       // ADDRLO
        wreg(6'h17, 16'h0000);       // ADDRHI
        wreg(6'h09, BX);
        wreg(6'h0a, row[15:0]);
        wreg(6'h0b, 16'h0100); wreg(6'h0c, 16'h0100);
        wreg(6'h0d, 16'h0000); wreg(6'h0e, 16'h0100);
        wreg(6'h0f, 16'h0000); wreg(6'h10, 16'h0000);
        wreg(6'h12, 16'h0000); wreg(6'h13, 16'h017F);
        wreg(6'h14, 16'h0000); wreg(6'h15, 16'h00EF);
        wreg(6'h04, 16'h0002);       // COMMAND = draw_rle
        fork : wb
            begin @(posedge clk); wait( !u_video.blit_busy ); end
            #2_000_000;
        join_any
        disable wb;
        repeat(200) @(posedge clk);

        // top-left pixel of the glyph is always opaque -> carries the pen
        a   = row*512 + BX;
        got = vmem[a];
        if( got[7:0] !== want_pen ) begin
            fails = fails + 1;
            $display("  FAIL %0s: pen %02X, expected %02X", label, got[7:0], want_pen);
        end
        if( (want_bus==0 && !(g0_seen && !g1_seen && !g3_seen)) ||
            (want_bus==1 && !(g1_seen && !g0_seen && !g3_seen)) ||
            (want_bus==3 && !(g3_seen && !g0_seen && !g1_seen)) ) begin
            fails = fails + 1;
            $display("  FAIL %0s: wrong bus (g0=%0d g1=%0d g3=%0d)",
                     label, g0_seen, g1_seen, g3_seen);
        end
        if( fails == 0 )
            $display("  ok   %0s: pen %02X from the expected bus", label, got[7:0]);
    end
endtask

initial begin
    for( k=0; k<1048576; k=k+1 ) vmem[k] = 16'h1111;
    load(0, 8'hFD);      // grom0 -> pen FD
    load(1, 8'hE1);      // grom1 -> pen E1
    load(2, 8'hC7);      // grm3  -> pen C7
    fails = 0;
    repeat(40) @(posedge clk);
    rst = 0;
    repeat(40) @(posedge clk);

    $display("grom bank -> bus routing:");
    run_case(2'd0, BY,    8'hFD, 0, "bank 0 -> grom0 (rm0)");
    run_case(2'd1, BY+8,  8'hE1, 1, "bank 1 -> grom1 (rm1)");
    run_case(2'd2, BY+16, 8'hC7, 3, "bank 2 -> grm3");

    $display("");
    // ---- verify the throughput instrument -------------------------------
    // Two separate things have to work: the per-frame ACCUMULATORS, and the
    // LATCH that publishes them. The latch fires on the LVBL falling edge,
    // once per 16.7 ms frame -- far longer than this testbench runs -- so
    // sample the accumulators directly, then force one LVBL edge to exercise
    // the latch path. Reading only the published outputs would show zeros and
    // say nothing about whether the counting works.
    $display("");
    sb = u_video.bc_busy; sw = u_video.bc_wait;
    sf = u_video.bc_wr;   sn = u_video.bc_num;
    $display("accumulators after %0d blits: busy=%0d gromwait=%0d writes=%0d nblit=%0d",
             sn, sb, sw, sf, sn);
    if( sb == 0 || sn != 3 ) begin
        fails = fails + 1;
        $display("INSTRUMENT-FAIL: accumulators did not count the blits");
    end
    if( sw == 0 ) begin
        fails = fails + 1;
        $display("INSTRUMENT-FAIL: no GROM stall counted despite 3-cycle bus latency");
    end
    if( sf == 0 ) begin
        fails = fails + 1;
        $display("INSTRUMENT-FAIL: rate meter counted zero VRAM writes");
    end

    #1 force u_video.LVBL = 1'b1; repeat(4) @(posedge clk);
    #1 force u_video.LVBL = 1'b0; repeat(4) @(posedge clk);
    #1 release u_video.LVBL;      repeat(4) @(posedge clk);

    $display("after a forced frame edge: busy=%0d gromwait=%0d writes=%0d nblit=%0d",
             st_bbusy, st_bwait, st_bwr, st_bnum);
    if( st_bnum !== sn[3:0] || st_bbusy !== sb[19:16] || st_bwait !== sw[19:16] ) begin
        fails = fails + 1;
        $display("INSTRUMENT-FAIL: latch did not publish the accumulated values");
    end else
        $display("INSTRUMENT-OK: accumulators count and the frame latch publishes them");

    // ---- verify the green-pen probe (AFTER the instrument check: forcing a
    // frame edge here publishes and resets the blitter counters, which broke
    // the instrument's own comparison when this ran first) ---------------
    if( st_gseen !== 1'b0 ) begin
        fails = fails + 1;
        $display("PROBE-FAIL: green flagged on a clean image");
    end
    // Hold scan_pen forced until AFTER the frame-end publish: releasing it
    // early leaves pen undefined and the published value comes back X.
    // The capture now mirrors the scanout output stage, so the test must too:
    // it only counts when a pixel is actually being emitted. Without LVBL/LHBL
    // forced this silently captures nothing -- which is the whole point of the
    // fix, since ungated it was latching unwritten line-buffer slots (0x7FFF)
    // during blanking.
    #1 force u_video.scan_pen  = 16'h12FD;
    force u_video.pal_b2_qb = 8'h00;
    force u_video.pal_b1_qb = 8'hFF;
    force u_video.pal_b0_qb = 8'h00;
    force u_video.LVBL = 1'b1;
    force u_video.LHBL = 1'b1;
    repeat(20) @(posedge clk);       // needs a pxl_cen tick (1 in 6)
    #1 release u_video.LHBL;
    if( st_gseen !== 1'b1 ) begin
        fails = fails + 1;
        $display("PROBE-FAIL: green not flagged");
    end
    // publish happens at frame end, from the frame with the most green
    #1 force u_video.LVBL = 1'b1; repeat(3) @(posedge clk);
    #1 force u_video.LVBL = 1'b0; repeat(3) @(posedge clk);
    #1 release u_video.LVBL;
    release u_video.pal_b2_qb; release u_video.pal_b1_qb; release u_video.pal_b0_qb;
    release u_video.scan_pen;
    repeat(3) @(posedge clk);
    if( st_gpen !== 15'h12FD ) begin
        fails = fails + 1;
        $display("PROBE-FAIL: published pen %04X, expected 12FD", st_gpen);
    end else
        $display("PROBE-OK: worst-frame latch published pen 12FD");

    // st_palhit must actually respond: a permanently clear bit looks exactly
    // like the finding being hunted (palette entry never written).
    if( st_palhit !== 1'b0 ) begin
        fails = fails + 1;
        $display("PROBE-FAIL: palhit set before any palette write");
    end
    // cpu_addr is declared [23:1], so literal bit i lands on cpu_addr[i+1];
    // pal_addr is cpu_addr[16:2] = literal[15:1], hence 12FD<<1.
    @(posedge clk);
    cpu_addr <= 23'h25FA;
    cpu_dout <= 16'h0000;
    #1 force u_video.pal_cs = 1'b1;
    bus_wstb <= 1;
    @(posedge clk);
    bus_wstb <= 0;
    #1 release u_video.pal_cs;
    repeat(4) @(posedge clk);
    if( st_palhit !== 1'b1 ) begin
        fails = fails + 1;
        $display("PROBE-FAIL: palhit did not set on a write to palette[12FD]");
    end else
        $display("PROBE-OK: palhit responds to a write at the captured pen");
    if( u_video.palcnt === 16'd0 ) begin
        fails = fails + 1;
        $display("PROBE-FAIL: palette-write counter never moved");
    end else
        $display("PROBE-OK: palette-write counter moved (%0d)", u_video.palcnt);

    // Regression guard for the build-58 fault: green during BLANKING must be
    // ignored. Ungated, this incremented and latched an off-screen pen.
    gsave = u_video.gcnt_acc;
    #1 force u_video.scan_pen  = 16'h7FFF;
    force u_video.pal_b2_qb = 8'h00;
    force u_video.pal_b1_qb = 8'hFF;
    force u_video.pal_b0_qb = 8'h00;
    force u_video.LVBL = 1'b0;          // blanking
    force u_video.LHBL = 1'b0;
    repeat(20) @(posedge clk);
    #1 release u_video.pal_b2_qb; release u_video.pal_b1_qb; release u_video.pal_b0_qb;
    release u_video.scan_pen; release u_video.LVBL; release u_video.LHBL;
    repeat(3) @(posedge clk);
    if( u_video.gcnt_acc !== gsave ) begin
        fails = fails + 1;
        $display("PROBE-FAIL: counted green during blanking (%0d -> %0d)",
                 gsave, u_video.gcnt_acc);
    end else
        $display("PROBE-OK: green during blanking is ignored");

    if( fails == 0 ) $display("PASS: each grom bank reaches its own SDRAM bus");
    else             $display("FAIL: %0d check(s) failed", fails);
    $finish;
end

endmodule
