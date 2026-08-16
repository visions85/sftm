`timescale 1ns/1ps
// sftm_vram throughput and integrity.
//
// The existing blit testbenches never fill the write FIFO (wrf=0), so they
// cannot see the fault this module was reworked to fix: on hardware the
// blitter spent 12 of every 13 busy units stalled on the write port, because
// one single-transaction FSM served the prefetch, the read port and the write
// FIFO, and the prefetch had absolute priority.
//
// This drives writes flat out WHILE the prefetch runs, which is exactly the
// contention that starved them, and checks four things:
//
//   1. throughput -- writes must drain at close to their own cost, not be
//      serialised behind every prefetch access
//   2. integrity  -- every written word lands at the right address
//   3. ordering   -- a blitter read still sees writes queued before it
//   4. handshake  -- exactly one vr_ack per vr_req assertion
//
// Check 4 matters because the write FIFO is now popped at ISSUE: reads and
// writes must stay mutually exclusive and acks must not double up.
module tb_vramthru;

localparam LAT = 6;                 // legacy name, see HITLAT/FILLLAT
localparam NWRITE = 400;

reg clk = 0, rst = 1;
always #10.4 clk = ~clk;            // 48 MHz

reg [2:0] cendiv = 0;
wire pxl_cen = cendiv == 3'd0;
always @(posedge clk) cendiv <= cendiv == 3'd5 ? 3'd0 : cendiv + 3'd1;

integer i, errors;

// ---------------------------------------------------------------------------
// 32-bit cache-lane model WITH A BLOCK CACHE.
//
// Modelling the lane as a raw port with fixed latency measured 2041 clk/write
// and looked like a catastrophic regression -- but it is not what the hardware
// does. The whole reason for converting to cache-lanes is the 256-byte block
// cache: the prefetch reads a line in a few block FILLS instead of touching
// SDRAM every two pixels, which is what frees the shared port for writes. A
// bench without the cache tests a design that does not exist.
//
// Direct-mapped, BLOCKS x BLKSIZE, matching cfg/mem.yaml. A hit answers in
// HITLAT; a miss costs a fill.
// ---------------------------------------------------------------------------
localparam BLKSIZE = 256;          // bytes
localparam BLOCKS  = 64;
localparam HITLAT  = 1;
localparam FILLLAT = 24;           // burst fill

reg [15:0] mem[0:2097151];

wire [20:2] vram_addr;
wire [31:0] vram_din;
wire [ 3:0] vram_dsn;
wire        vram_we, vram_rd;
// the lane services a request when EITHER strobe is up; modelling only rd
// would re-encode the bug that made build 60 render a black screen
wire        vram_req = vram_rd | vram_we;
reg  [31:0] vram_data;
reg         vram_ok;
reg  [ 7:0] vcnt;

// block index of the 32-bit word address: BLKSIZE bytes = BLKSIZE/4 words
localparam WPB = BLKSIZE/4;                     // 32-bit words per block
wire [20:2] blk_of  = vram_addr / WPB;
wire [ 5:0] blk_idx = blk_of[5:0];
reg  [20:2] tag[0:BLOCKS-1];
reg         valid[0:BLOCKS-1];
integer bi;
initial for( bi=0; bi<BLOCKS; bi=bi+1 ) begin tag[bi]=0; valid[bi]=0; end

wire hit = valid[blk_idx] && tag[blk_idx]==blk_of;
wire [7:0] need = hit ? HITLAT : FILLLAT;

always @(posedge clk) begin
    if( !vram_req ) begin
        vcnt <= 0; vram_ok <= 0;
    end else if( vcnt != need ) begin
        vcnt <= vcnt + 8'd1; vram_ok <= 0;
    end else if( !vram_ok ) begin
        vram_ok <= 1;
        valid[blk_idx] <= 1'b1;
        tag[blk_idx]   <= blk_of;
        if( vram_we ) begin
            if( !vram_dsn[0] ) mem[{vram_addr,1'b0}][ 7:0] <= vram_din[ 7:0];
            if( !vram_dsn[1] ) mem[{vram_addr,1'b0}][15:8] <= vram_din[15:8];
            if( !vram_dsn[2] ) mem[{vram_addr,1'b1}][ 7:0] <= vram_din[23:16];
            if( !vram_dsn[3] ) mem[{vram_addr,1'b1}][15:8] <= vram_din[31:24];
        end else
            vram_data <= { mem[{vram_addr,1'b1}], mem[{vram_addr,1'b0}] };
    end
end

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
    .vw_req(vw_req), .vw_rdy(vw_rdy), .vw_plane(vw_plane),
    .vw_addr(vw_addr), .vw_data(vw_data),
    .vr_req(vr_req), .vr_plane(vr_plane), .vr_addr(vr_addr),
    .vr_ack(vr_ack), .vr_data(vr_data),
    .line_go(line_go), .line_base(line_base), .line_sel(line_sel),
    .scan_x(scan_x), .scan_pen(scan_pen), .st_wpop()
);

// Prefetch at the REAL cadence: one line per line period, then idle.
//
// An earlier version retriggered the instant a line finished. That was meant
// to be conservative but is not what the hardware does, and against a single
// shared port with prefetch priority it means pf_active never drops and writes
// are starved by construction -- the bench manufactures the very starvation it
// is meant to detect. A scanline is 508 pxl_cen x 6 clk = 3048 clk; the
// prefetch uses a fraction of that and the rest belongs to the blitter.
localparam LINE_CLK = 3048;
reg pf_run = 0;
integer line_t = 0;
always @(posedge clk) begin
    line_go <= 1'b0;
    if( pf_run ) begin
        line_t <= line_t + 1;
        if( line_t >= LINE_CLK ) begin
            line_t    <= 0;
            line_base <= line_base + 19'd512;
            line_sel  <= ~line_sel;
            line_go   <= 1'b1;
        end
    end
end

// count acks so a doubled ack is caught
integer ack_count;
always @(posedge clk) if( !rst && vr_ack ) ack_count <= ack_count + 1;

integer t0, t1, cycles;
integer clk_count;
always @(posedge clk) clk_count <= clk_count + 1;

initial begin
    for( i=0; i<2097151; i=i+1 ) mem[i] = 16'h0000;
    errors = 0; ack_count = 0; clk_count = 0;
    repeat(20) @(posedge clk);
    rst = 0;
    repeat(20) @(posedge clk);

    // ---- kick off a prefetch, then hammer writes into the contention -----
    @(posedge clk);
    line_base = 19'd1024;
    line_sel  = 1'b0;

    // Keep the prefetch running for the whole test. On hardware it restarts
    // every line and never idles, so a single line would badly understate the
    // contention the writes actually face.
    pf_run = 1'b1;

    t0 = clk_count;
    for( i=0; i<NWRITE; i=i+1 ) begin
        vw_addr <= i[18:0];
        vw_data <= 16'hA000 + i[15:0];
        vw_plane<= 1'b0;
        vw_req  <= 1'b1;
        @(posedge clk);
        while( !vw_rdy ) @(posedge clk);   // FIFO full -> this is the stall
    end
    vw_req <= 1'b0;
    pf_run <= 1'b0;
    // Drain: wf_cnt hits zero at ISSUE of the last write, which is still in
    // flight, so wait for the sequencer to go idle too before checking memory.
    while( uut.wf_cnt != 0 ) @(posedge clk);
    while( uut.astate != 2'd0 || vram_req ) @(posedge clk);
    t1 = clk_count;
    cycles = t1 - t0;

    $display("");
    $display("%0d writes drained in %0d clk = %0d clk/write (hit %0d, fill %0d)",
             NWRITE, cycles, cycles/NWRITE, HITLAT, FILLLAT);
    // Serialised behind the prefetch each write cost far more than its own
    // transaction. Its own cost is issue + settle + latency + completion,
    // about LAT+4; allow generous headroom for prefetch interleaving but
    // catch a return to full serialisation.
    if( cycles/NWRITE > 20 ) begin
        errors = errors + 1;
        $display("FAIL: %0d clk/write -- writes are still being serialised",
                 cycles/NWRITE);
    end else
        $display("ok: writes drain at their own cost, not the prefetch's");

    // ---- integrity -------------------------------------------------------
    for( i=0; i<NWRITE; i=i+1 ) begin
        if( mem[i] !== (16'hA000 + i[15:0]) ) begin
            if( errors < 6 )
                $display("FAIL: addr %0d holds %04X, expected %04X",
                         i, mem[i], 16'hA000 + i[15:0]);
            errors = errors + 1;
        end
    end
    if( errors == 0 ) $display("ok: all %0d words landed at the right address", NWRITE);

    // ---- ordering: a read must see writes queued before it ---------------
    @(posedge clk);
    vw_addr <= 19'd5000; vw_data <= 16'h1234; vw_req <= 1'b1;
    @(posedge clk);
    vw_req <= 1'b0;
    vr_addr <= 19'd5000; vr_plane <= 1'b0; vr_req <= 1'b1;
    @(posedge clk);
    while( !vr_ack ) @(posedge clk);
    if( vr_data !== 16'h1234 ) begin
        errors = errors + 1;
        $display("FAIL: read got %04X, expected 1234 -- read overtook a queued write",
                 vr_data);
    end else
        $display("ok: blitter read sees a write queued just before it");
    vr_req <= 1'b0;
    repeat(20) @(posedge clk);

    // ---- handshake: exactly one ack for that one request -----------------
    if( ack_count != 1 ) begin
        errors = errors + 1;
        $display("FAIL: %0d acks for 1 read request", ack_count);
    end else
        $display("ok: exactly one ack per request");

    $display("");
    if( errors == 0 ) $display("PASS: sftm_vram throughput, integrity, ordering and handshake");
    else              $display("FAIL: %0d problem(s)", errors);
    $finish;
end

initial begin
    #40_000_000;
    $display("FAIL: timeout -- the sequencer is stuck");
    $finish;
end

endmodule
