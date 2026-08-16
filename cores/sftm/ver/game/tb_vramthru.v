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

localparam LAT     = 6;             // SDRAM round trip
// FASTWR acks a write when the slot mux GRANTS it, while the burst -- and the
// actual commit -- happens later. Modelling an early ack that commits in the
// SAME cycle cannot represent the hazard at all, so the ordering check could
// never fail. Here an early-acked write goes to a pending slot and lands LAT
// cycles later, so a read issued in between correctly sees STALE data.
localparam FASTWR  = 0;   // see docker/entrypoint.sh: unsafe on this slot
localparam WRACK   = FASTWR ? 1 : LAT;
localparam NWRITE = 400;

reg clk = 0, rst = 1;
always #10.4 clk = ~clk;            // 48 MHz

reg [2:0] cendiv = 0;
wire pxl_cen = cendiv == 3'd0;
always @(posedge clk) cendiv <= cendiv == 3'd5 ? 3'd0 : cendiv + 3'd1;

integer i, errors, ord;

// ---------------------------------------------------------------------------
// two independent SDRAM slot models over one memory
// ---------------------------------------------------------------------------
reg [15:0] mem[0:4194303];

wire [21:1] vram_addr;
wire [15:0] vram_din;
wire [ 1:0] vram_dsn;
wire        vram_we, vram_cs;
reg  [15:0] vram_data;
reg         vram_ok;
reg  [ 3:0] vcnt;

reg [3:0] occ = 0;
always @(posedge clk) if( occ != 0 ) occ <= occ - 4'd1;

reg        pw_v = 0;
reg [21:1] pw_a;
reg [15:0] pw_d;
reg [ 1:0] pw_dsn;
reg [ 3:0] pw_t = 0;
always @(posedge clk) begin
    if( pw_v ) begin
        if( pw_t != 0 ) pw_t <= pw_t - 4'd1;
        else begin
            if( !pw_dsn[0] ) mem[pw_a][ 7:0] <= pw_d[ 7:0];
            if( !pw_dsn[1] ) mem[pw_a][15:8] <= pw_d[15:8];
            pw_v <= 1'b0;
        end
    end
end

always @(posedge clk) begin
    if( !vram_cs ) begin
        vcnt <= 0; vram_ok <= 0;
    end else if( occ != 0 ) begin
        vram_ok <= 0;
    end else if( vcnt != (vram_we ? WRACK : LAT) ) begin
        vcnt <= vcnt + 4'd1; vram_ok <= 0;
    end else if( !vram_ok ) begin
        vram_ok <= 1;
        if( vram_we ) begin
            if( FASTWR ) begin
                pw_v<=1; pw_a<=vram_addr; pw_d<=vram_din; pw_dsn<=vram_dsn;
                pw_t<=LAT[3:0]; occ<=LAT[3:0];
            end else begin
                if( !vram_dsn[0] ) mem[vram_addr][ 7:0] <= vram_din[ 7:0];
                if( !vram_dsn[1] ) mem[vram_addr][15:8] <= vram_din[15:8];
            end
        end else
            vram_data <= mem[vram_addr];
    end
end

wire [21:2] vramrd_addr;
wire        vramrd_cs;
reg  [31:0] vramrd_data;
reg         vramrd_ok;
reg  [ 3:0] rcnt;

always @(posedge clk) begin
    if( !vramrd_cs ) begin
        rcnt <= 0; vramrd_ok <= 0;
    end else if( rcnt != LAT ) begin
        rcnt <= rcnt + 4'd1; vramrd_ok <= 0;
    end else begin
        vramrd_ok   <= 1;
        vramrd_data <= { mem[{vramrd_addr,1'b1}], mem[{vramrd_addr,1'b0}] };
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
    .vram_dsn(vram_dsn), .vram_we(vram_we), .vram_cs(vram_cs), .vram_ok(vram_ok),
    .vramrd_addr(vramrd_addr), .vramrd_data(vramrd_data),
    .vramrd_cs(vramrd_cs), .vramrd_ok(vramrd_ok),
    .vw_req(vw_req), .vw_rdy(vw_rdy), .vw_plane(vw_plane),
    .vw_addr(vw_addr), .vw_data(vw_data),
    .vr_req(vr_req), .vr_plane(vr_plane), .vr_addr(vr_addr),
    .vr_ack(vr_ack), .vr_data(vr_data),
    .line_go(line_go), .line_base(line_base), .line_sel(line_sel),
    .scan_x(scan_x), .scan_pen(scan_pen), .st_wpop()
);

// continuous prefetch: retrigger as soon as the previous line completes
reg pf_run = 0;
always @(posedge clk) begin
    line_go <= 1'b0;
    if( pf_run && !uut.pf_active && !line_go ) begin
        line_base <= line_base + 19'd512;
        line_sel  <= ~line_sel;
        line_go   <= 1'b1;
    end
end

// count acks so a doubled ack is caught
integer ack_count;
always @(posedge clk) if( !rst && vr_ack ) ack_count <= ack_count + 1;

integer t0, t1, cycles;
integer clk_count;
always @(posedge clk) clk_count <= clk_count + 1;

initial begin
    for( i=0; i<4194303; i=i+1 ) mem[i] = 16'h0000;
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
    while( uut.bstate != 2'd0 || vram_cs || pw_v ) @(posedge clk);
    t1 = clk_count;
    cycles = t1 - t0;

    $display("");
    $display("%0d writes drained in %0d clk = %0d clk/write (SDRAM latency %0d)",
             NWRITE, cycles, cycles/NWRITE, LAT);
    // Serialised behind the prefetch each write cost far more than its own
    // transaction. Its own cost is issue + settle + latency + completion,
    // about LAT+4; allow generous headroom for prefetch interleaving but
    // catch a return to full serialisation.
    if( cycles/NWRITE > (LAT+10) ) begin
        errors = errors + 1;
        $display("FAIL: %0d clk/write -- writes are still being serialised",
                 cycles/NWRITE);
    end else
        $display("ok: writes drain at their own cost, not the prefetch's");

    // ---- integrity -------------------------------------------------------
    for( i=0; i<NWRITE; i=i+1 ) begin
        if( mem[21'h40000 + i] !== (16'hA000 + i[15:0]) ) begin
            if( errors < 6 )
                $display("FAIL: addr %0d holds %04X, expected %04X",
                         i, mem[21'h40000+i], 16'hA000 + i[15:0]);
            errors = errors + 1;
        end
    end
    if( errors == 0 ) $display("ok: all %0d words landed at the right address", NWRITE);

    // ---- ordering: a read must see writes queued before it ---------------
    // A BURST, then read it straight back. The old check wrote ONE word: with
    // a single write in flight even an early ack precedes the read, so it
    // passed under FASTWR while hardware corrupted every read-modify-write
    // blit. A burst leaves later writes uncommitted when the FIFO reports
    // empty, which is the real hazard.
    ord = 0;
    for( i=0; i<24; i=i+1 ) begin
        vw_addr <= 19'd6000 + i[18:0];
        vw_data <= 16'h5500 + i[15:0];
        vw_plane<= 1'b0;
        vw_req  <= 1'b1;
        @(posedge clk);
        while( !vw_rdy ) @(posedge clk);
    end
    vw_req <= 1'b0;
    @(posedge clk);
    for( i=23; i>=0; i=i-1 ) begin      // newest first: most likely uncommitted
        vr_addr <= 19'd6000 + i[18:0]; vr_plane <= 1'b0; vr_req <= 1'b1;
        @(posedge clk);
        while( !vr_ack ) @(posedge clk);
        if( vr_data !== (16'h5500 + i[15:0]) ) begin
            if( ord < 3 )
                $display("FAIL: read %0d got %04X, expected %04X -- read overtook an uncommitted write",
                         6000+i, vr_data, 16'h5500 + i[15:0]);
            ord = ord + 1;
        end
        vr_req <= 1'b0;
        @(posedge clk);
    end
    if( ord == 0 ) $display("ok: reads see every write of a burst, committed");
    else begin
        errors = errors + ord;
        $display("FAIL: %0d of 24 reads returned stale data", ord);
    end

    // ---- handshake: exactly one ack for that one request -----------------
    if( ack_count != 24 ) begin
        errors = errors + 1;
        $display("FAIL: %0d acks for 24 read requests", ack_count);
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
