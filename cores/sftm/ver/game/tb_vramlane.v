`timescale 1ns/1ps
// sftm_vram against the REAL 64-bit cache lane -- the full stack:
//   sftm_vram -> jtframe_cache_mux (lane 0 = vram, DW=64, ENDIAN=0, the
//   build-107 generated params) -> jtframe_burst_sdram -> Micron model.
//
// tb_vramthru drives a MODEL of the lane; build 104 taught that the model
// passing is necessary but not sufficient. Build 109 splits scanout onto its
// own read-only vscan lane with a per-frame flush of the rw lane that also
// INVALIDATES vscan (INVAL_MASK), so this bench drives both lanes and the
// flush handshake. It checks, through the real cache:
//   1. slot layout round trip: pens written through the FIFO come back
//      through the blitter read port AND land in the line buffer at the
//      right x -- for all four line_base[1:0] phases
//   2. run coalescing integrity under a real fill/writeback engine
//   3. throughput: clk/write with the prefetch running at line cadence
//   4. eviction: written pens survive a working-set sweep and refill
module tb_vramlane;

localparam SDRAM_AW = 24;

reg clk = 0, rst = 1;
always #10.4 clk = ~clk;    // 48 MHz

// ---------------------------------------------------------------------------
// lane 0 = vram, build-107 params: DW=64, ENDIAN=0, AW=21, 64 x 256B blocks,
// BA=3, OFFSET=0x40000. Other lanes idle.
// ---------------------------------------------------------------------------
wire [20:3] vram_addr;
wire [63:0] vram_din, vram_data;
wire [ 7:0] vram_dsn;
wire        vram_we, vram_rd, vram_ok;
wire        vram_flush, vram_flushing, vram_flush_done;
wire [20:3] vscan_addr;
wire [63:0] vscan_data;
wire        vscan_rd, vscan_ok;
reg         frame_flush = 0;

wire [23:1] mux_addr;
wire [ 1:0] mux_ba;
wire        mux_rd, mux_wr;
wire [15:0] mux_dout, sdr_dout;
wire        sdr_ack, sdr_dst, sdr_dok, sdr_rdy, sdr_init;

jtframe_cache_mux #(
    .SDRAM_AW ( SDRAM_AW ),
    .ENDIAN   ( 0 ),
    .ENDIAN0 ( 0 ), .FULL0 ( 0 ), .AW0 ( 21 ), .BLOCKS0 ( 64 ),
    .BLKSIZE0 ( 256 ), .DW0 ( 64 ), .BA0 ( 3 ), .CHIP0 ( 0 ),
    .OFFSET0 ( 'h40000 ), .INVAL_MASK0 ( 8'b00000010 ),
    // lane 1 = vscan: scanout's read-only view of the same window
    .ENDIAN1 ( 0 ), .FULL1 ( 0 ), .AW1 ( 21 ), .BLOCKS1 ( 8 ),
    .BLKSIZE1 ( 256 ), .DW1 ( 64 ), .BA1 ( 3 ), .CHIP1 ( 0 ),
    .OFFSET1 ( 'h40000 ), .INVAL_MASK1 ( 8'b0 )
) u_mux (
    .rst(rst), .clk(clk),
    .addr0( vram_addr ), .dout0( vram_data ), .rd0( vram_rd ),
    .wr0( vram_we ), .din0( vram_din ), .wdsn0( vram_dsn ), .ok0( vram_ok ),
    .flush0( vram_flush ), .flushing0( vram_flushing ),
    .flush_done0( vram_flush_done ),
    .addr1( vscan_addr ), .dout1( vscan_data ), .rd1( vscan_rd ),
    .wr1(1'b0), .din1(64'd0),
    .wdsn1(8'd0), .ok1( vscan_ok ), .flush1(1'b0), .flushing1(), .flush_done1(),
    .addr2( 20'd0 ), .dout2(), .rd2(1'b0), .wr2(1'b0), .din2(32'd0),
    .wdsn2(4'd0), .ok2(), .flush2(1'b0), .flushing2(), .flush_done2(),
    .addr3( 23'd0 ), .dout3(), .rd3(1'b0), .wr3(1'b0), .din3(8'd0),
    .wdsn3(1'd0), .ok3(), .flush3(1'b0), .flushing3(), .flush_done3(),
    .addr4( 23'd0 ), .dout4(), .rd4(1'b0), .ok4(), .flush4(1'b0),
    .flushing4(), .flush_done4(),
    .addr5( 23'd0 ), .dout5(), .rd5(1'b0), .ok5(), .flush5(1'b0),
    .flushing5(), .flush_done5(),
    .addr6( 23'd0 ), .dout6(), .rd6(1'b0), .ok6(), .flush6(1'b0),
    .flushing6(), .flush_done6(),
    .addr7( 23'd0 ), .dout7(), .rd7(1'b0), .ok7(), .flush7(1'b0),
    .flushing7(), .flush_done7(),
    .addr(mux_addr), .ba(mux_ba), .rd(mux_rd), .wr(mux_wr),
    .din(sdr_dout), .dout(mux_dout),
    .ack(sdr_ack), .dst(sdr_dst), .dok(sdr_dok), .rdy(sdr_rdy)
);

wire [15:0] sdram_dq;
wire [12:0] sdram_a;
wire [ 1:0] sdram_ba_pin;
wire sdram_dqml, sdram_dqmh, sdram_nwe, sdram_ncas, sdram_nras, sdram_ncs, sdram_cke;

jtframe_burst_sdram #(
    .AW(SDRAM_AW), .HF(0), .MISTER(1)
) u_ctrl (
    .rst(rst), .clk(clk), .init(sdr_init),
    .addr( {1'b0, mux_addr} ), .ba(mux_ba), .rd(mux_rd), .wr(mux_wr),
    .din(mux_dout), .dout(sdr_dout),
    .ack(sdr_ack), .dst(sdr_dst), .dok(sdr_dok), .rdy(sdr_rdy),
    .prog_en(1'b0), .prog_addr({SDRAM_AW{1'b0}}), .prog_rd(1'b0),
    .prog_wr(1'b0), .prog_din(16'd0), .prog_dsn(2'b11), .prog_ba(2'd0),
    .prog_dst(), .prog_dok(), .prog_rdy(), .prog_ack(),
    .rfsh(1'b0),
    .sdram_dq(sdram_dq), .sdram_a(sdram_a), .sdram_dqml(sdram_dqml),
    .sdram_dqmh(sdram_dqmh), .sdram_ba(sdram_ba_pin), .sdram_nwe(sdram_nwe),
    .sdram_ncas(sdram_ncas), .sdram_nras(sdram_nras), .sdram_ncs(sdram_ncs),
    .sdram_cke(sdram_cke)
);

mt48lc16m16a2 #(.col_bits(10), .mem_sizes((1<<23)-1)) u_chip (
    .Dq(sdram_dq), .Addr(sdram_a), .Ba(sdram_ba_pin), .Clk(clk),
    .Cke(sdram_cke), .Cs_n(sdram_ncs), .Ras_n(sdram_nras),
    .Cas_n(sdram_ncas), .We_n(sdram_nwe), .Dqm({sdram_dqmh, sdram_dqml}),
    .downloading(1'b0), .VS(1'b0), .frame_cnt(32'd0)
);

// ---------------------------------------------------------------------------
reg         vw_req = 0, vw_plane = 0;
reg  [18:0] vw_addr = 0;
reg  [15:0] vw_data = 0;
wire        vw_rdy;
reg         vr_req = 0, vr_plane = 0;
reg  [18:0] vr_addr = 0;
wire        vr_ack;
wire [15:0] vr_data;
reg         line_go = 0, line_sel = 0;
reg  [18:0] line_base = 0;
reg  [ 8:0] scan_x = 0;
wire [15:0] scan_pen;

sftm_vram uut(
    .rst(rst), .clk(clk),
    .vram_addr(vram_addr), .vram_data(vram_data), .vram_din(vram_din),
    .vram_dsn(vram_dsn), .vram_we(vram_we), .vram_rd(vram_rd), .vram_ok(vram_ok),
    .vram_flush(vram_flush), .vram_flushing(vram_flushing),
    .vram_flush_done(vram_flush_done),
    .vscan_addr(vscan_addr), .vscan_data(vscan_data),
    .vscan_rd(vscan_rd), .vscan_ok(vscan_ok),
    .frame_flush(frame_flush),
    .vw_req(vw_req), .vw_rdy(vw_rdy), .vw_plane(vw_plane),
    .vw_addr(vw_addr), .vw_data(vw_data),
    .vr_req(vr_req), .vr_plane(vr_plane), .vr_addr(vr_addr),
    .vr_ack(vr_ack), .vr_data(vr_data),
    .line_go(line_go), .line_base(line_base), .line_sel(line_sel),
    .scan_x(scan_x), .scan_pen(scan_pen), .st_wpop()
);

integer i, errors = 0;
integer guard;
reg [31:0] clk_count = 0;
always @(posedge clk) clk_count <= clk_count + 32'd1;
integer t0, cyc;

task wpush(input [18:0] a, input [15:0] d);
begin
    @(posedge clk);
    while( !vw_rdy ) @(posedge clk);
    vw_addr <= a; vw_data <= d; vw_plane <= 1'b0; vw_req <= 1'b1;
    @(posedge clk);
    vw_req <= 1'b0;
end endtask

task wdrain;
begin
    // let NBA updates land before sampling internal state (a wait loop that
    // reads uut.* right after an edge sees pre-update values and can exit
    // before the machinery has even started)
    repeat(3) @(posedge clk);
    guard = 0;
    while( (uut.wf_cnt != 0 || uut.astate != 2'd0) && guard < 100000 ) begin
        @(posedge clk); guard = guard + 1;
    end
    if( guard >= 100000 ) begin $display("FAIL: drain timeout"); errors = errors + 1; end
    repeat(4) @(posedge clk);
end endtask

// pulse frame_flush and wait for the lane to finish writing back
task fflush;
begin
    @(posedge clk);
    frame_flush <= 1'b1;
    @(posedge clk);
    frame_flush <= 1'b0;
    repeat(4) @(posedge clk);
    guard = 0;
    while( vram_flushing && guard < 200000 ) begin @(posedge clk); guard = guard + 1; end
    if( guard >= 200000 ) begin $display("FAIL: flush timeout"); errors = errors + 1; end
    repeat(4) @(posedge clk);
end endtask

reg [15:0] rgot;
task bread(input [18:0] a);
begin
    @(posedge clk);
    vr_addr <= a; vr_plane <= 1'b0; vr_req <= 1'b1;
    guard = 0;
    @(posedge clk);
    while( !vr_ack && guard < 100000 ) begin @(posedge clk); guard = guard + 1; end
    rgot = vr_data;
    vr_req <= 1'b0;
    if( guard >= 100000 ) begin $display("FAIL: read timeout"); errors = errors + 1; end
    repeat(2) @(posedge clk);
end endtask

// run one prefetch line and wait for it to finish
task pfline(input [18:0] base, input sel);
begin
    @(posedge clk);
    line_base <= base; line_sel <= sel; line_go <= 1'b1;
    @(posedge clk);
    line_go <= 1'b0;
    repeat(3) @(posedge clk);   // let pf_active assert before polling it
    guard = 0;
    while( (uut.pf_active || uut.astate != 2'd0) && guard < 200000 ) begin
        @(posedge clk); guard = guard + 1;
    end
    if( guard >= 200000 ) begin $display("FAIL: prefetch timeout"); errors = errors + 1; end
    repeat(4) @(posedge clk);
end endtask

task scanchk(input [8:0] x, input [15:0] want, input sel);
begin
    @(posedge clk);
    scan_x <= x;
    @(posedge clk); @(posedge clk);
    if( (sel ? uut.lb_q1 : uut.lb_q0) !== want ) begin
        $display("FAIL: line buffer[%0d] = %04X, want %04X",
                 x, sel ? uut.lb_q1 : uut.lb_q0, want);
        errors = errors + 1;
    end
end endtask

integer ph;
initial begin
    repeat(30) @(posedge clk);
    rst = 0;
    guard = 0;
    while( sdr_init && guard < 100000 ) begin @(posedge clk); guard = guard + 1; end
    repeat(100) @(posedge clk);

    // ---- 1. slot layout: write 16 pens spanning word boundaries, read back
    $display("");
    $display("1: slot layout round trip through the real lane");
    for( i = 0; i < 16; i = i + 1 ) wpush( 19'd1000 + i[18:0], 16'hC0DE + i[15:0] );
    wdrain;
    for( i = 0; i < 16; i = i + 1 ) begin
        bread( 19'd1000 + i[18:0] );
        if( rgot !== 16'hC0DE + i[15:0] ) begin
            $display("FAIL: pen %0d read %04X want %04X", 1000+i, rgot, 16'hC0DE+i[15:0]);
            errors = errors + 1;
        end
    end
    $display("  16 pens round-tripped");

    // ---- 2. prefetch phases: all four line_base[1:0] alignments ----------
    $display("2: line buffer fill at every base alignment");
    // pens 2048..2447 hold their own index
    for( i = 0; i < 400; i = i + 1 ) wpush( 19'd2048 + i[18:0], 16'h1000 + i[15:0] );
    wdrain;
    fflush;      // writes reach SDRAM and vscan drops any stale blocks
    for( ph = 0; ph < 4; ph = ph + 1 ) begin
        pfline( 19'd2048 + ph[18:0], ph[0] );
        scanchk( 9'd0,   16'h1000 + ph[15:0],          ph[0] );
        scanchk( 9'd1,   16'h1001 + ph[15:0],          ph[0] );
        scanchk( 9'd383, 16'h117F + ph[15:0],          ph[0] );
    end
    $display("  4 alignments checked at x=0,1,383");

    // ---- 3. throughput under line-cadence prefetch -----------------------
    $display("3: 512 sequential writes with prefetch at line cadence");
    fork
        begin : pfcad
            integer L;
            for( L = 0; L < 3; L = L + 1 ) begin
                @(posedge clk);
                line_base <= 19'd2048; line_sel <= ~line_sel; line_go <= 1'b1;
                @(posedge clk);
                line_go <= 1'b0;
                repeat(3046) @(posedge clk);
            end
        end
        begin : wrs
            t0 = clk_count;
            for( i = 0; i < 512; i = i + 1 )
                wpush( 19'd8192 + i[18:0], 16'hB000 + i[15:0] );
            wdrain;
            cyc = clk_count - t0;
        end
    join
    $display("  512 writes in %0d clk = %0d clk/write under prefetch", cyc, cyc/512);
    if( cyc/512 > 12 ) begin
        $display("FAIL: writes serialised behind the prefetch again");
        errors = errors + 1;
    end

    // ---- 4. eviction survival --------------------------------------------
    $display("4: written pens survive a 70-block sweep and refill");
    for( i = 0; i < 70; i = i + 1 ) bread( 19'd65536 + i[18:0]*128 );
    for( i = 0; i < 8; i = i + 1 ) begin
        bread( 19'd8192 + i[18:0]*63 );
        if( rgot !== 16'hB000 + i[15:0]*63 ) begin
            $display("FAIL: pen %0d after evict %04X want %04X",
                     8192+i*63, rgot, 16'hB000+i[15:0]*63);
            errors = errors + 1;
        end
    end
    $display("  8 spot pens survived eviction");

    // ---- 5. the flush contract: stale before, fresh after ----------------
    $display("5: vscan coherency across the frame flush");
    // prefetch once so vscan caches the line, then overwrite the pens
    fflush;
    pfline( 19'd2048, 1'b0 );
    for( i = 0; i < 8; i = i + 1 ) wpush( 19'd2048 + i[18:0], 16'h2000 + i[15:0] );
    wdrain;
    // no flush yet: vscan may serve its cached (old) line -- not asserted,
    // the contract only promises freshness AFTER the flush
    fflush;
    pfline( 19'd2048, 1'b0 );
    scanchk( 9'd0, 16'h2000, 1'b0 );
    scanchk( 9'd7, 16'h2007, 1'b0 );
    scanchk( 9'd8, 16'h1008, 1'b0 );   // unwritten pen keeps phase-2 data
    $display("  post-flush prefetch sees the new pens");

    // ---- 6. write-no-fetch: claim, read-merge, eviction-merge ------------
    $display("6: write-no-fetch claim and merge paths");
    fflush;   // everything dirty reaches SDRAM; wvalid state settles
    // one full word (pens 2052..2055) CLAIMS the block holding pens 2048+
    for( i = 0; i < 4; i = i + 1 ) wpush( 19'd2052 + i[18:0], 16'h3000 + i[15:0] );
    wdrain;
    // reading an unwritten pen of the claimed block forces a merge fill;
    // it must return the phase-2 value that the flush put in SDRAM
    bread( 19'd2060 );
    if( rgot !== 16'h100C ) begin
        $display("FAIL: merge read got %04X, want 100C (old SDRAM content)", rgot);
        errors = errors + 1;
    end
    bread( 19'd2052 );
    if( rgot !== 16'h3000 ) begin
        $display("FAIL: claimed pen got %04X, want 3000", rgot);
        errors = errors + 1;
    end
    // evict everything, then re-read: the merged block's writeback must
    // carry BOTH the new pens and the preserved old ones
    for( i = 0; i < 70; i = i + 1 ) bread( 19'd65536 + i[18:0]*128 );
    bread( 19'd2052 );
    if( rgot !== 16'h3000 ) begin
        $display("FAIL: post-evict claimed pen %04X, want 3000", rgot);
        errors = errors + 1;
    end
    bread( 19'd2060 );
    if( rgot !== 16'h100C ) begin
        $display("FAIL: post-evict merged pen %04X, want 100C", rgot);
        errors = errors + 1;
    end
    $display("  claim + read-merge + eviction writeback verified");

    $display("");
    if( errors == 0 ) $display("PASS: sftm_vram on the real 64-bit lane");
    else              $display("FAIL: %0d problem(s)", errors);
    $finish;
end

initial begin #60_000_000; $display("FAIL: timeout"); $finish; end

`ifdef PFDBG
integer dbgn = 0;
always @(posedge clk) if( uut.lb_we && dbgn < 30 ) begin
    $display("  DBG lbwr[%0d] = %04X  (pf_w=%0d pf_slot=%0d pf_j=%0d)",
             uut.lb_waddr, uut.lb_wdata, uut.pf_w, uut.pf_slot, uut.pf_j);
    dbgn = dbgn + 1;
end
`endif
endmodule
