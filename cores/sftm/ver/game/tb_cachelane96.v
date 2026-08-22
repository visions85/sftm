`timescale 1ns/1ps
// Does the DW=32 cache lane return {w2n, w2n+1} or {w2n+1, w2n+2}?
//
// Hardware (build 90, PC+opcode probe over JTAG, trustworthy channel) showed
// the main lane's even-word fetches skewed +4 bytes while odd-word fetches
// were clean -- algebraically, the lane returns SDRAM words {2n+1, 2n+2} for
// longword n instead of {2n, 2n+1}. That is the build-66 measurement, still
// alive: sdram.big_endian never fixed it, and its "hardware confirmation" was
// the wrong core loading (see doc/PORTING.md).
//
// This bench reproduces the whole REAL lane path with no invented protocol:
//   jtframe_cache_mux (exact generated params, lane 2 = main)
//     -> jtframe_burst_sdram -> Micron mt48lc16m16a2 model
// The only test code is the stimulus and the memory preload: Bank0[i]=0x1000+i,
// so whatever words the lane fetches identify themselves.
module tb_cachelane96;

localparam SDRAM_AW = 24;   // JTFRAME_SDRAM_LARGE

// 96 MHz campaign: clk96 primary, clk (48) divided and edge-aligned.
// Mux, burst engine, SDRAM chip and the download path run at 96; every
// consumer FSM in this bench (CPU-view tasks, loader FSM, hammer) stays at
// 48 and crosses at the lane ports, as jtsftm_game will on silicon.
reg clk96 = 0, rst = 1;
always #5.2 clk96 = ~clk96;
reg clk = 0;
always @(posedge clk96) clk <= ~clk;

// ---------------------------------------------------------------------------
// lane 2 = main: DW=32, AW=20, ENDIAN=1, BA=0, OFFSET=0 (generated values)
// ---------------------------------------------------------------------------
reg  [19:2] addr2 = 0;
reg         rd2 = 0, wr2 = 0;
reg  [31:0] din2 = 0;
wire [31:0] dout2;
wire        ok2;

// lane 3 = snd: DW=8, AW=19, ENDIAN=0 (jtframe forbids ENDIAN on DW!=32),
// BA=0, OFFSET=0x80000 halfwords = byte 0x100000 (generated values)
reg  [18:0] addr3 = 0;
reg         rd3 = 0;
wire [ 7:0] dout3;
wire        ok3;

// lane 5 = grom0 (Phase K): the widened 64-bit source-pixel lane
reg  [23:3] addr5 = 0;
reg         rd5 = 0;
wire [63:0] dout5;
wire        ok5;

// lane 0 direct drive (Phase I): the vram lane's write path, DW=32 ENDIAN=1.
// l0_mode=0 leaves the lane to the Phase G hammer.
reg         l0_mode = 0, l0_rd = 0, l0_wr = 0;
reg  [20:2] l0_addr = 0;
reg  [31:0] l0_din = 0;
reg  [ 3:0] l0_dsn = 4'hF;
wire [31:0] l0_dout;

// SDRAM side
wire [23:1] mux_addr;
wire [ 1:0] mux_ba;
wire        mux_rd, mux_wr;
wire [15:0] mux_dout, sdr_dout;
wire        sdr_ack, sdr_dst, sdr_dok, sdr_rdy, sdr_init;

jtframe_cache_mux #(
    .SDRAM_AW ( SDRAM_AW ),
    .ENDIAN   ( 0 ),
    // lane 0 = vram (idle here)
    .ENDIAN0 ( 1 ), .FULL0 ( 0 ), .AW0 ( 21 ), .BLOCKS0 ( 64 ),
    .BLKSIZE0 ( 256 ), .DW0 ( 32 ), .BA0 ( 3 ), .CHIP0 ( 0 ),
    .OFFSET0 ( 'h40000 ), .INVAL_MASK0 ( 8'b0 ),
    // lane 1 = grm3 (idle)
    .ENDIAN1 ( 0 ), .FULL1 ( 0 ), .AW1 ( 19 ), .BLOCKS1 ( 8 ),
    .BLKSIZE1 ( 256 ), .DW1 ( 16 ), .BA1 ( 3 ), .CHIP1 ( 0 ),
    .OFFSET1 ( 'h0 ), .INVAL_MASK1 ( 8'b0 ),
    // lane 2 = main -- THE LANE UNDER TEST
    .ENDIAN2 ( 1 ), .FULL2 ( 0 ), .AW2 ( 20 ), .BLOCKS2 ( 64 ),
    .BLKSIZE2 ( 256 ), .DW2 ( 32 ), .BA2 ( 0 ), .CHIP2 ( 0 ),
    .OFFSET2 ( 'h0 ), .INVAL_MASK2 ( 8'b0 ),
    // lane 3 = snd -- the 6809 byte lane (Phase H)
    .ENDIAN3 ( 0 ), .FULL3 ( 0 ), .AW3 ( 19 ), .BLOCKS3 ( 8 ),
    .BLKSIZE3 ( 256 ), .DW3 ( 8 ), .BA3 ( 0 ), .CHIP3 ( 0 ),
    .OFFSET3 ( 'h80000 ), .INVAL_MASK3 ( 8'b0 ),
    // lane 5 = grom0, build-108 widening: DW=64 (Phase K byte-order check)
    .ENDIAN5 ( 0 ), .FULL5 ( 0 ), .AW5 ( 24 ), .BLOCKS5 ( 32 ),
    .BLKSIZE5 ( 256 ), .DW5 ( 64 ), .BA5 ( 1 ), .CHIP5 ( 0 ),
    .OFFSET5 ( 'h0 ), .INVAL_MASK5 ( 8'b0 )
) u_mux (
    .rst(rst), .clk(clk96),
    .addr0( l0_mode ? l0_addr : vh_addr ), .dout0( l0_dout ),
    .rd0( l0_mode ? l0_rd : vh_rd ), .wr0( l0_mode & l0_wr ), .din0( l0_din ),
    .wdsn0( l0_dsn ), .ok0(), .flush0(1'b0), .flushing0(), .flush_done0(),
    .addr1( 18'd0 ), .dout1(), .rd1(1'b0), .wr1(1'b0), .din1(16'd0),
    .wdsn1(2'd0), .ok1(), .flush1(1'b0), .flushing1(), .flush_done1(),
    .addr2( lda_act ? ld_addr : addr2 ), .dout2(dout2),
    .rd2( lda_act ? ldr : rd2 ), .wr2( lda_act ? ldw : wr2 ),
    .din2( lda_act ? ld_data : din2 ),
    .wdsn2(4'd0), .ok2(ok2), .flush2(1'b0), .flushing2(), .flush_done2(),
    .addr3( addr3 ), .dout3( dout3 ), .rd3( rd3 ), .wr3(1'b0), .din3(8'd0),
    .wdsn3(1'd0), .ok3( ok3 ), .flush3(1'b0), .flushing3(), .flush_done3(),
    .addr4( 23'd0 ), .dout4(), .rd4(1'b0), .ok4(), .flush4(1'b0),
    .flushing4(), .flush_done4(),
    .addr5( addr5 ), .dout5( dout5 ), .rd5( rd5 ), .ok5( ok5 ), .flush5(1'b0),
    .flushing5(), .flush_done5(),
    .addr6( 23'd0 ), .dout6(), .rd6(1'b0), .ok6(), .flush6(1'b0),
    .flushing6(), .flush_done6(),
    .addr7( 23'd0 ), .dout7(), .rd7(1'b0), .ok7(), .flush7(1'b0),
    .flushing7(), .flush_done7(),
    .addr(mux_addr), .ba(mux_ba), .rd(mux_rd), .wr(mux_wr),
    .din(sdr_dout), .dout(mux_dout),
    .ack(sdr_ack), .dst(sdr_dst), .dok(sdr_dok), .rdy(sdr_rdy)
);

// SDRAM pins
wire [15:0] sdram_dq;
wire [12:0] sdram_a;
wire [ 1:0] sdram_ba_pin;
wire sdram_dqml, sdram_dqmh, sdram_nwe, sdram_ncas, sdram_nras, sdram_ncs, sdram_cke;

jtframe_burst_sdram #(
    .AW(SDRAM_AW), .HF(1), .MISTER(1)
) u_ctrl (
    .rst(rst), .clk(clk96), .init(sdr_init),
    // emu wires the mux's 23-bit halfword address zero-extended into 24 bits
    .addr( {1'b0, mux_addr} ), .ba(mux_ba), .rd(mux_rd), .wr(mux_wr),
    .din(mux_dout), .dout(sdr_dout),
    .ack(sdr_ack), .dst(sdr_dst), .dok(sdr_dok), .rdy(sdr_rdy),
    .prog_en(prog_en),
    .prog_addr( use_dwnld ? {1'b0, raw_addr} : prog_addr ),
    .prog_rd  ( use_dwnld ? raw_rd  : 1'b0 ),
    .prog_wr  ( use_dwnld ? raw_we  : prog_wr ),
    .prog_din ( use_dwnld ? raw_data : prog_din ),
    .prog_dsn ( use_dwnld ? raw_mask : prog_dsn ),
    .prog_ba  ( use_dwnld ? raw_ba   : 2'd0 ),
    .prog_dst(), .prog_dok(), .prog_rdy(), .prog_ack(prog_ack),
    .rfsh(1'b0),
    .sdram_dq(sdram_dq), .sdram_a(sdram_a), .sdram_dqml(sdram_dqml),
    .sdram_dqmh(sdram_dqmh), .sdram_ba(sdram_ba_pin), .sdram_nwe(sdram_nwe),
    .sdram_ncas(sdram_ncas), .sdram_nras(sdram_nras), .sdram_ncs(sdram_ncs),
    .sdram_cke(sdram_cke)
);

mt48lc16m16a2 #(.col_bits(10), .mem_sizes((1<<23)-1)) u_chip (
    .Dq(sdram_dq), .Addr(sdram_a), .Ba(sdram_ba_pin), .Clk(clk96),
    .Cke(sdram_cke), .Cs_n(sdram_ncs), .Ras_n(sdram_nras),
    .Cas_n(sdram_ncas), .We_n(sdram_nwe), .Dqm({sdram_dqmh, sdram_dqml}),
    .downloading(1'b0), .VS(1'b0), .frame_cnt(32'd0)
);

// ---------------------------------------------------------------------------
// Phase A writer: the REAL jtframe_dwnld, parameterised exactly as generated
// (SDRAMW=24, SWAB=1, real BA starts), fed a byte stream like MiSTer ioctl.
// ---------------------------------------------------------------------------
reg         ioctl_rom = 0, ioctl_wr = 0;
reg  [26:0] ioctl_addr = 0;
reg  [ 7:0] ioctl_dout = 0;
wire [23:1] raw_addr;
wire [15:0] raw_data;
wire [ 1:0] raw_mask, raw_ba;
wire        raw_we, raw_rd;

jtframe_dwnld #(
    .SDRAMW(24), .SWAB(1),
    .BA1_START(27'h3D0000), .BA2_START(27'h13D0000), .BA3_START(27'h23D0000)
) u_dwnld (
    .clk(clk96), .ioctl_rom(ioctl_rom), .ioctl_addr(ioctl_addr),
    .ioctl_dout(ioctl_dout), .ioctl_wr(ioctl_wr),
    .prog_addr(raw_addr), .prog_data(raw_data), .prog_mask(raw_mask),
    .prog_we(raw_we), .prog_rd(raw_rd), .prog_ba(raw_ba),
    .gfx4_en(1'b0), .gfx8_en(1'b0), .gfx16_en(1'b0), .gfx16b_en(1'b0),
    .gfx16c_en(1'b0),
    .prom_we(), .header(), .sdram_ack(prog_ack)
);

reg use_dwnld = 0;
reg                 prog_en = 0, prog_wr = 0;
reg  [SDRAM_AW-1:0] prog_addr = 0;
reg  [15:0]         prog_din = 0;
reg  [ 1:0]         prog_dsn = 2'b11;
wire                prog_ack;

// Write one BYTE exactly as jtframe_dwnld does: halfword address, data on both
// lanes, dsn masking the untouched byte (even stream byte -> low lane, mask
// 2'b10; odd -> high lane, mask 2'b01), prog_wr held until prog_ack.
task prog_byte(input [SDRAM_AW-1:0] hw_addr, input odd, input [7:0] b);
integer g;
begin
    @(posedge clk);
    prog_addr <= hw_addr;
    prog_din  <= {b, b};
    prog_dsn  <= odd ? 2'b01 : 2'b10;
    prog_wr   <= 1'b1;
    g = 0;
    @(posedge clk);
    while( !prog_ack && g < 20000 ) begin @(posedge clk); g = g + 1; end
    if( g >= 20000 ) begin $display("FAIL: prog_ack timeout"); errors = errors + 1; end
    prog_wr <= 1'b0;
    @(posedge clk);
end endtask

// ---------------------------------------------------------------------------
// VERBATIM replica of jtsftm_game's b91 JTAG-loader FSM, driven by a src reg
// the way quartus_stp drives the ISSP source. Phase E replays the exact
// hardware sequence that returned all-zero readbacks.
// ---------------------------------------------------------------------------
reg  [63:0] ld_srcr = 64'd0;
wire        lda_act   = ld_srcr[51];
wire        ld_togl   = ld_srcr[50];
wire        ld_rdm    = ld_srcr[52];
wire [19:2] ld_addr   = ld_srcr[49:32];
wire [31:0] ld_data   = ld_srcr[31:0];
reg         ld_tog_d = 1'b0;
reg  [1:0]  ld_st    = 2'd0;
reg         ld_we    = 1'b0;
reg  [15:0] ld_done  = 16'd0;
reg  [15:0] ld_seen  = 16'd0;
reg  [31:0] ld_rdata = 32'd0;
wire        ldr = ld_we &  ld_rdm;
wire        ldw = ld_we & ~ld_rdm;
always @(posedge clk) begin
    ld_tog_d <= ld_togl;
    case( ld_st )
        2'd0: if( ld_togl != ld_tog_d ) begin
                  ld_we <= 1'b1; ld_st <= 2'd1;
                  if( ~&ld_seen ) ld_seen <= ld_seen + 16'd1;
              end
        2'd1: ld_st <= 2'd2;
        2'd2: if( ok2 ) begin
                  ld_we <= 1'b0; ld_st <= 2'd0;
                  if( ld_rdm ) ld_rdata <= dout2;
                  if( ~&ld_done ) ld_done <= ld_done + 16'd1;
              end
    endcase
end

integer lg;
task ld_xact(input rw, input [17:0] a, input [31:0] d);
begin
    // one ISSP source write: all fields change on the same "edge"
    @(posedge clk);
    ld_srcr <= { 11'd0, rw, 1'b1, ~ld_srcr[50], a, d };
    // quartus_stp gap between writes is huge; model 200 clk
    lg = 0;
    repeat(200) @(posedge clk);
    if( ld_st != 2'd0 ) $display("  (loader FSM stuck in state %0d after xact)", ld_st);
end endtask

// ---------------------------------------------------------------------------
// Lane-0 hammer: continuous fill traffic on the vram lane, as on real hardware
// where scanout drives ~390k reads/frame through the same mux. Every
// single-lane path is proven clean; concurrency is the one structural
// difference the hardware always has.
// ---------------------------------------------------------------------------
reg          vh_on = 0;
reg  [20:2]  vh_addr = 0;
reg          vh_rd = 0;
wire         ok0_w = u_mux.ok0;
reg  [1:0]   vh_st = 0;
reg  [7:0]   vh_blk = 0;
always @(posedge clk) begin
    if( !vh_on ) begin
        vh_rd <= 0; vh_st <= 0;
    end else case( vh_st )
        2'd0: begin
            // stride blocks so most accesses are FILLS, like scanout
            vh_addr <= { 3'd0, vh_blk, 8'd0 };
            vh_rd   <= 1'b1;
            vh_st   <= 2'd1;
        end
        2'd1: vh_st <= 2'd2;
        2'd2: if( ok0_w ) begin
            vh_rd  <= 1'b0;
            vh_blk <= vh_blk + 8'd1;
            vh_st  <= 2'd3;
        end
        2'd3: vh_st <= 2'd0;
    endcase
end

// real program-ROM head, one hex byte per line (first 64 bytes of the stream)
reg [7:0] prog_head [0:63];
initial $readmemh("cores/sftm/ver/game/prog_head.hex", prog_head);

// memory content: every 16-bit word names its own index
integer i;
initial for( i=0; i<16384; i=i+1 ) u_chip.Bank0[i] = 16'h1000 + i[15:0];

// ---------------------------------------------------------------------------
integer errors = 0;
reg [31:0] got;

// free-running cycle counter for the Phase J throughput measurement
reg [31:0] cycles = 0;
always @(posedge clk) cycles <= cycles + 32'd1;
integer phj_c0, phj_cyc, ph;

task fetch(input [19:2] lw);
integer guard;
begin
    @(posedge clk);
    addr2 <= lw; rd2 <= 1'b1;
    guard = 0;
    @(posedge clk); @(posedge clk);      // settle, as sftm_main does
    while( !ok2 && guard < 20000 ) begin @(posedge clk); guard = guard + 1; end
    got = dout2;
    rd2 <= 1'b0;
    if( guard >= 20000 ) begin
        $display("FAIL: no ok2 for longword %0d", lw);
        errors = errors + 1;
    end
    repeat(6) @(posedge clk);
end endtask

task check(input [19:2] lw, input [160*8-1:0] tag);
reg [15:0] w0c, w1c;
begin
    fetch(lw);
    w0c = 16'h1000 + {lw,1'b0};          // word 2n
    w1c = 16'h1000 + {lw,1'b1};          // word 2n+1
    if( got === {w0c, w1c} )
        $display("  lw %0d: %08X  CORRECT {w2n,w2n+1}  [%0s]", lw, got, tag);
    else if( got === {w1c, w0c} )
        begin $display("  lw %0d: %08X  HALF-SWAPPED {w2n+1,w2n}  [%0s]", lw, got, tag); errors=errors+1; end
    else if( got === {16'h1001+{lw,1'b0}, 16'h1002+{lw,1'b0}} )
        begin $display("  lw %0d: %08X  SHIFT +1 WORD {w2n+1,w2n+2}  <-- build-66 bug  [%0s]", lw, got, tag); errors=errors+1; end
    else
        begin $display("  lw %0d: %08X  OTHER (want %04X%04X)  [%0s]", lw, got, w0c, w1c, tag); errors=errors+1; end
end endtask

integer guard2;
reg [7:0] exp_b0, exp_b1, exp_b2, exp_b3;

// what the 68020 sees through sftm_main's rom_word mux (copied verbatim)
reg [15:0] fetch_even, fetch_odd, want_even, want_odd;
task lane_write(input [19:2] lw, input [31:0] v);
integer g;
begin
    @(posedge clk);
    addr2 <= lw; din2 <= v; wr2 <= 1'b1;
    g = 0;
    @(posedge clk); @(posedge clk);
    while( !ok2 && g < 20000 ) begin @(posedge clk); g = g + 1; end
    if( g >= 20000 ) begin $display("FAIL: write ok2 timeout lw %0d", lw); errors=errors+1; end
    wr2 <= 1'b0;
    repeat(6) @(posedge clk);
end endtask

reg [7:0] got8;
task snd_fetch(input [18:0] a);
integer g;
begin
    @(posedge clk);
    addr3 <= a; rd3 <= 1'b1;
    g = 0;
    @(posedge clk); @(posedge clk);
    while( !ok3 && g < 20000 ) begin @(posedge clk); g = g + 1; end
    got8 = dout3;
    rd3 <= 1'b0;
    if( g >= 20000 ) begin
        $display("FAIL: no ok3 for snd byte %0d", a);
        errors = errors + 1;
    end
    repeat(6) @(posedge clk);
end endtask

reg [31:0] l0_got;
task l0_xact(input rd, input [20:2] a, input [31:0] d, input [3:0] m);
integer g;
begin
    @(posedge clk);
    l0_addr <= a; l0_din <= d; l0_dsn <= m;
    l0_rd <= rd; l0_wr <= !rd;
    g = 0;
    @(posedge clk); @(posedge clk);
    while( !u_mux.ok0 && g < 20000 ) begin @(posedge clk); g = g + 1; end
    l0_got = l0_dout;
    l0_rd <= 0; l0_wr <= 0;
    if( g >= 20000 ) begin $display("FAIL: no ok0 (a=%0d rd=%0d)", a, rd); errors = errors + 1; end
    repeat(6) @(posedge clk);
end endtask

reg [63:0] got64;
task grom_fetch(input [23:3] a);
integer g;
begin
    @(posedge clk);
    addr5 <= a; rd5 <= 1'b1;
    g = 0;
    @(posedge clk); @(posedge clk);
    while( !ok5 && g < 20000 ) begin @(posedge clk); g = g + 1; end
    got64 = dout5;
    rd5 <= 1'b0;
    if( g >= 20000 ) begin
        $display("FAIL: no ok5 for grom0 group %0d", a);
        errors = errors + 1;
    end
    repeat(6) @(posedge clk);
end endtask

task cpu_view(input [19:2] lw);
begin
    fetch(lw);
    // PROPOSED FIX under test: the halves exchanged relative to the old mux.
    // Old (written for the little-endian lane packing): even from D[15:0],
    // odd from D[31:16]. With ENDIAN=1 packing the first word is the HIGH
    // half, so even must come from D[31:16] and odd from D[15:0].
    fetch_even = { got[23:16], got[31:24] };  // rom_word FIXED, !A[1]
    fetch_odd  = { got[ 7:0], got[15: 8] };   // rom_word FIXED,  A[1]
    want_even  = { prog_head[{lw,2'b00}], prog_head[{lw,2'b01}] };
    want_odd   = { prog_head[{lw,2'b10}], prog_head[{lw,2'b11}] };
    $display("  lw %0d: lane=%08X  cpu even=%04X (want %04X %0s)  odd=%04X (want %04X %0s)",
        lw, got,
        fetch_even, want_even, fetch_even===want_even ? "CLEAN":"WRONG",
        fetch_odd,  want_odd,  fetch_odd ===want_odd  ? "CLEAN":"WRONG");
    if( fetch_even !== want_even || fetch_odd !== want_odd ) errors = errors + 1;
end endtask
initial begin
    repeat(30) @(posedge clk);
    rst = 0;
    // SDRAM init sequence
    guard2 = 0;
    while( sdr_init && guard2 < 100000 ) begin @(posedge clk); guard2 = guard2 + 1; end
    if( sdr_init ) begin $display("FAIL: controller never left init"); $finish; end
    repeat(100) @(posedge clk);
    // -----------------------------------------------------------------------
    // Phase A FIRST (so the lane never caches stale content for lw 0..3):
    // the real jtframe_dwnld writes the real first 64 ROM bytes.
    // -----------------------------------------------------------------------
    $display("");
    $display("Phase A: real jtframe_dwnld (SWAB=1) writes the real ROM head");
    use_dwnld = 1'b1; prog_en = 1'b1; ioctl_rom = 1'b1;
    repeat(8) @(posedge clk);
    for( i = 0; i < 64; i = i + 1 ) begin
        ioctl_addr <= i[26:0];
        ioctl_dout <= prog_head[i];
        ioctl_wr   <= 1'b1;
        @(posedge clk);
        ioctl_wr   <= 1'b0;
        repeat(47) @(posedge clk);   // ~1 us/byte, like real ioctl
    end
    repeat(40) @(posedge clk);
    ioctl_rom = 1'b0; prog_en = 1'b0; use_dwnld = 1'b0;

    // -----------------------------------------------------------------------
    // Phase B: lane sanity on preloaded pattern, far from the download
    // -----------------------------------------------------------------------
    $display("");
    $display("Phase B: SDRAM word i = 0x1000+i. Longword n must read {0x1000+2n, 0x1001+2n}.");
    check(18'd2048, "fill");
    check(18'd2049, "hit, same block");
    check(18'd2048, "hit, revisit");
    check(18'd2112, "second block fill");

    // -----------------------------------------------------------------------
    // Phase C: the CPU's view of the downloaded ROM. This is the hardware
    // experiment (build 90) reproduced in simulation: on .74 the even words
    // came back +4 bytes and the odd words clean.
    // -----------------------------------------------------------------------
    $display("");
    $display("Phase C: what the 68020 fetches from the downloaded ROM");
    $display("  image words: %02X%02X %02X%02X %02X%02X %02X%02X ...",
        prog_head[0],prog_head[1],prog_head[2],prog_head[3],
        prog_head[4],prog_head[5],prog_head[6],prog_head[7]);
    cpu_view(18'd0);
    cpu_view(18'd1);
    cpu_view(18'd2);
    cpu_view(18'd3);

    // -----------------------------------------------------------------------
    // Phase D: LANE WRITES -- the one path never tested, used by both the JTAG
    // ROM loader and (in vram's identical DW=32/ENDIAN=1 configuration) every
    // blitter pixel. Write V, read it back, and check both NEIGHBOURS still
    // hold the preload pattern so a +/-1-halfword placement error is caught.
    // -----------------------------------------------------------------------
    $display("");
    $display("Phase D: lane WRITE path (cold block, then cached block)");
    // cold block write
    lane_write(18'd3000, 32'hA1B2C3D4);
    fetch(18'd3000);
    if( got === 32'hA1B2C3D4 ) $display("  wr lw3000 cold: readback %08X CORRECT", got);
    else begin $display("  wr lw3000 cold: readback %08X WRONG (want A1B2C3D4)", got); errors=errors+1; end
    fetch(18'd2999);
    if( got === {16'h1000+16'd5998, 16'h1000+16'd5999} ) $display("  neighbour lw2999 intact");
    else begin $display("  neighbour lw2999 = %08X CLOBBERED (want %04X%04X)", got, 16'h1000+16'd5998, 16'h1000+16'd5999); errors=errors+1; end
    fetch(18'd3001);
    if( got === {16'h1000+16'd6002, 16'h1000+16'd6003} ) $display("  neighbour lw3001 intact");
    else begin $display("  neighbour lw3001 = %08X CLOBBERED (want %04X%04X)", got, 16'h1000+16'd6002, 16'h1000+16'd6003); errors=errors+1; end
    // cached-block write: read first so the block is resident, then write
    fetch(18'd3100);
    lane_write(18'd3100, 32'h55AA66BB);
    fetch(18'd3100);
    if( got === 32'h55AA66BB ) $display("  wr lw3100 cached: readback %08X CORRECT", got);
    else begin $display("  wr lw3100 cached: readback %08X WRONG (want 55AA66BB)", got); errors=errors+1; end
    fetch(18'd3101);
    if( got === {16'h1000+16'd6202, 16'h1000+16'd6203} ) $display("  neighbour lw3101 intact");
    else begin $display("  neighbour lw3101 = %08X CLOBBERED (want %04X%04X)", got, 16'h1000+16'd6202, 16'h1000+16'd6203); errors=errors+1; end
    // sequential burst of writes, loader-style (back to back, cold region)
    for( i = 0; i < 8; i = i + 1 ) lane_write( 18'd3200+i[15:0], 32'hC0000000 + i[15:0] );
    for( i = 0; i < 8; i = i + 1 ) begin
        fetch( 18'd3200+i[15:0] );
        if( got !== 32'hC0000000 + i[15:0] ) begin
            $display("  burst wr lw%0d readback %08X WRONG (want %08X)", 3200+i, got, 32'hC0000000+i[15:0]);
            errors=errors+1;
        end
    end
    $display("  burst of 8 sequential writes checked");

    // -----------------------------------------------------------------------
    // Phase F: WRITEBACK path. Phase D's readbacks were cache hits -- the
    // written blocks were never evicted, so SDRAM was never re-read. Hardware
    // bulk-load readback showed observed[i] = intended[i+1] (one halfword
    // early) while single write->read (pure cache) was exact: the suspect is
    // eviction writeback + refill. Write one block, evict it by touching 20
    // other blocks (the lane has 16), then read back through a refill.
    // -----------------------------------------------------------------------
    $display("");
    $display("Phase F: write block, force eviction, re-read through refill");
    for( i = 0; i < 8; i = i + 1 ) lane_write( 18'd4000+i[15:0], 32'hE0E00000 + i[15:0] );
    // evict: touch 20 distinct blocks (64 longwords apart)
    for( i = 0; i < 20; i = i + 1 ) fetch( 18'd8000 + i[15:0]*64 );
    // refill and check
    for( i = 0; i < 8; i = i + 1 ) begin
        fetch( 18'd4000+i[15:0] );
        if( got === 32'hE0E00000 + i[15:0] )
            $display("  F lw%0d after evict: %08X CORRECT", 4000+i, got);
        else begin
            $display("  F lw%0d after evict: %08X WRONG (want %08X)", 4000+i, got, 32'hE0E00000+i[15:0]);
            errors = errors + 1;
        end
    end
    // neighbours of the written block, refetched after eviction
    fetch( 18'd3999 );
    if( got === {16'h1000+16'd7998, 16'h1000+16'd7999} ) $display("  F neighbour lw3999 intact");
    else begin $display("  F neighbour lw3999 = %08X CLOBBERED", got); errors=errors+1; end
    fetch( 18'd4008 );
    if( got === {16'h1000+16'd8016, 16'h1000+16'd8017} ) $display("  F neighbour lw4008 intact");
    else begin $display("  F neighbour lw4008 = %08X CLOBBERED (want %04X%04X)", got, 16'h1000+16'd8016, 16'h1000+16'd8017); errors=errors+1; end

    // -----------------------------------------------------------------------
    // Phase E: the b91 loader FSM replica, replaying the hardware sequence
    // that read back all zeros: a burst of writes, a clear, then reads.
    // -----------------------------------------------------------------------
    $display("");
    $display("Phase E: b91 JTAG-loader FSM replica (write burst, then reads)");
    for( i = 0; i < 8; i = i + 1 ) ld_xact(1'b0, 18'd8+i[15:0], 32'hD0D00000 + i[15:0]);
    @(posedge clk); ld_srcr <= 64'd0;   // the script's clear
    repeat(50) @(posedge clk);
    for( i = 0; i < 4; i = i + 1 ) begin
        ld_xact(1'b1, 18'd8+i[15:0], 32'd0);
        if( ld_rdata === 32'hD0D00000 + i[15:0] )
            $display("  E rd lw%0d: rdata=%08X CORRECT", 8+i, ld_rdata);
        else begin
            $display("  E rd lw%0d: rdata=%08X WRONG (want %08X)", 8+i, ld_rdata, 32'hD0D00000+i[15:0]);
            errors = errors + 1;
        end
    end
    @(posedge clk); ld_srcr <= 64'd0;
    repeat(20) @(posedge clk);

    // -----------------------------------------------------------------------
    // Phase G: everything again, WITH the vram lane hammering concurrently.
    // -----------------------------------------------------------------------
    $display("");
    $display("Phase G: lane-2 traffic with continuous lane-0 fills (concurrency)");
    vh_on = 1'b1;
    repeat(60) @(posedge clk);
    check(18'd2560, "G fill under hammer");
    check(18'd2561, "G hit under hammer");
    check(18'd2624, "G second fill under hammer");
    for( i = 0; i < 8; i = i + 1 ) lane_write( 18'd4400+i[15:0], 32'hF0F00000 + i[15:0] );
    for( i = 0; i < 20; i = i + 1 ) fetch( 18'd12000 + i[15:0]*64 );  // evict
    for( i = 0; i < 8; i = i + 1 ) begin
        fetch( 18'd4400+i[15:0] );
        if( got === 32'hF0F00000 + i[15:0] )
            $display("  G wb lw%0d: %08X CORRECT", 4400+i, got);
        else begin
            $display("  G wb lw%0d: %08X WRONG (want %08X)", 4400+i, got, 32'hF0F00000+i[15:0]);
            errors = errors + 1;
        end
    end
    vh_on = 1'b0;
    repeat(20) @(posedge clk);

    // -----------------------------------------------------------------------
    // Phase H: the snd lane's byte order. The 6809 is dead on hardware
    // (service menu: sound-dependent actions no-op; boot diverges from MAME
    // at the point the game first needs the sound board). The MRA streams
    // the snd ROM as a PLAIN part, jtframe_dwnld SWAB=1 puts the first
    // stream byte in the SDRAM word's HIGH half, and the DW=8 lane cannot
    // take ENDIAN=1 -- so the question is which byte position addr bit 0
    // actually selects. Stream distinct bytes through the REAL download at
    // the snd window (ioctl byte 0x100000+i) and read them back on lane 3.
    // -----------------------------------------------------------------------
    $display("");
    $display("Phase H: snd lane (DW=8) byte order vs the download stream");
    use_dwnld = 1'b1; prog_en = 1'b1; ioctl_rom = 1'b1;
    repeat(8) @(posedge clk);
    for( i = 0; i < 32; i = i + 1 ) begin
        ioctl_addr <= 27'h100000 + i[26:0];
        ioctl_dout <= 8'hB0 + i[7:0];
        ioctl_wr   <= 1'b1;
        @(posedge clk);
        ioctl_wr   <= 1'b0;
        repeat(47) @(posedge clk);
    end
    repeat(40) @(posedge clk);
    ioctl_rom = 1'b0; prog_en = 1'b0; use_dwnld = 1'b0;
    for( i = 0; i < 8; i = i + 1 ) begin
        snd_fetch( i[18:0] );
        if( got8 === 8'hB0 + i[7:0] )
            $display("  H snd[%0d] = %02X CORRECT (stream byte %0d)", i, got8, i);
        else if( got8 === 8'hB0 + (i[7:0]^8'd1) )
            begin $display("  H snd[%0d] = %02X PAIR-SWAPPED (stream byte %0d)", i, got8, i^1); errors=errors+1; end
        else
            begin $display("  H snd[%0d] = %02X OTHER (want %02X)", i, got8, 8'hB0+i[7:0]); errors=errors+1; end
    end

    // -----------------------------------------------------------------------
    // Phase I: full-word (wdsn=0000) writes on the ENDIAN=1 vram lane vs the
    // proven two-partial-write convention. Build 104's pixel-pair coalescing
    // issues dsn=0000 writes -- a path no working build ever used -- and on
    // hardware the screen shredded into 2-pixel-wide garbage. If the lane
    // handles ENDIAN differently for masked and unmasked writes, a pair lands
    // halfword-swapped. Method A (partial, b100-proven) defines the correct
    // SDRAM layout; method B (full) must match it, cache-resident, in the
    // chip after eviction, and on refill readback.
    // -----------------------------------------------------------------------
    $display("");
    $display("Phase I: dsn=0000 full-word write vs two partial writes (ENDIAN=1 lane)");
    l0_mode = 1;
    // method A at word 100: even half 0x1234 (din[15:0], dsn 1100),
    // odd half 0x5678 (din[31:16], dsn 0011) -- exactly sftm_vram's singles
    l0_xact(0, 19'd100, {16'h0000, 16'h1234}, 4'b1100);
    l0_xact(0, 19'd100, {16'h5678, 16'h0000}, 4'b0011);
    // method B at word 101: same logical packing in ONE write, dsn 0000
    l0_xact(0, 19'd101, {16'hDEF0, 16'h9ABC}, 4'b0000);
    // cache-resident readback
    l0_xact(1, 19'd100, 32'd0, 4'hF);
    if( l0_got === 32'h5678_1234 ) $display("  I rd100 cached: %08X CORRECT", l0_got);
    else begin $display("  I rd100 cached: %08X WRONG (want 56781234)", l0_got); errors=errors+1; end
    l0_xact(1, 19'd101, 32'd0, 4'hF);
    if( l0_got === 32'hDEF0_9ABC ) $display("  I rd101 cached: %08X CORRECT", l0_got);
    else begin $display("  I rd101 cached: %08X WRONG (want DEF09ABC)", l0_got); errors=errors+1; end
    // evict: lane 0 has 64 blocks of 256 bytes = 64 words apart; touch 70
    for( i = 0; i < 70; i = i + 1 ) l0_xact(1, 19'd8192 + i[15:0]*64, 32'd0, 4'hF);
    // the chip itself: method B's halfword order must match method A's
    $display("  I chip @A: hw[%0d]=%04X hw[%0d]=%04X   (word 100)",
        'h40000+200, u_chip.Bank3['h40000+200], 'h40000+201, u_chip.Bank3['h40000+201]);
    $display("  I chip @B: hw[%0d]=%04X hw[%0d]=%04X   (word 101)",
        'h40000+202, u_chip.Bank3['h40000+202], 'h40000+203, u_chip.Bank3['h40000+203]);
    if( u_chip.Bank3['h40000+200] === 16'h1234 && u_chip.Bank3['h40000+202] !== 16'h9ABC ||
        u_chip.Bank3['h40000+200] === 16'h5678 && u_chip.Bank3['h40000+202] !== 16'hDEF0 ) begin
        $display("  I CHIP LAYOUT MISMATCH: full write ordered opposite to partials");
        errors = errors + 1;
    end
    // refill readback
    l0_xact(1, 19'd100, 32'd0, 4'hF);
    if( l0_got === 32'h5678_1234 ) $display("  I rd100 refill: %08X CORRECT", l0_got);
    else begin $display("  I rd100 refill: %08X WRONG (want 56781234)", l0_got); errors=errors+1; end
    l0_xact(1, 19'd101, 32'd0, 4'hF);
    if( l0_got === 32'hDEF0_9ABC ) $display("  I rd101 refill: %08X CORRECT", l0_got);
    else begin $display("  I rd101 refill: %08X WRONG (want DEF09ABC)", l0_got); errors=errors+1; end
    l0_mode = 0;

    // -----------------------------------------------------------------------
    // Phase J: the vram-lane thrash, reproduced and measured. Hardware (b106)
    // shows 24.4 clk per write transaction where a cache hit costs ~4: the
    // scanout stream and the blitter's write stream share the lane's 16 sets
    // x 4 ways, and the round-robin replacement pointer advances only on
    // fills, so a streaming reader evicts the writer's hot block within a few
    // fills no matter how recently it was written. Model: a writer streams
    // 256 sequential full-word writes through sets 0..3 while a reader
    // interleaves reads from FOUR aliasing regions (same sets, distinct
    // tags) -- 5 tags competing for 4 ways. Measure clk per write.
    // -----------------------------------------------------------------------
    $display("");
    $display("Phase J: writer + 4-way aliasing reader on the ENDIAN=1 lane");
    l0_mode = 1;
    phj_c0 = cycles;
    for( i = 0; i < 256; i = i + 1 ) begin
        l0_xact(0, 19'd32768 + i[15:0], 32'hAB00_0000 + i[15:0], 4'b0000);
        if( i[0] )
            l0_xact(1, 19'd32768 + 19'd1024 + {7'd0, i[3:2], 10'd0} + i[15:0], 32'd0, 4'hF);
    end
    phj_cyc = cycles - phj_c0;
    $display("  J: 256 writes + 128 aliasing reads in %0d clk = %0d clk/write",
             phj_cyc, phj_cyc/256);
    for( i = 0; i < 8; i = i + 1 ) begin
        l0_xact(1, 19'd32768 + i[15:0]*31, 32'd0, 4'hF);
        if( l0_got !== 32'hAB00_0000 + i[15:0]*31 ) begin
            $display("  J integrity FAIL @+%0d: %08X (want %08X)",
                     i*31, l0_got, 32'hAB00_0000 + i[15:0]*31);
            errors = errors + 1;
        end
    end
    $display("  J integrity: 8 spot readbacks checked");
    l0_mode = 0;

    // -----------------------------------------------------------------------
    // Phase K: the widened grom0 lane's byte order vs the real download.
    // Build 102 once byte-swapped the grom data on an unvalidated assumption
    // and turned readable text into soup; this phase makes the 16->64-bit
    // widening safe by construction. Stream distinct bytes into the BA1
    // window through the real SWAB=1 download and check byte i of group g
    // reads at dout[8*i +: 8] -- the exact select sftm_blit now uses.
    // -----------------------------------------------------------------------
    $display("");
    $display("Phase K: grom0 64-bit lane byte order vs the download stream");
    use_dwnld = 1'b1; prog_en = 1'b1; ioctl_rom = 1'b1;
    repeat(8) @(posedge clk);
    for( i = 0; i < 32; i = i + 1 ) begin
        ioctl_addr <= 27'h3D0000 + i[26:0];
        ioctl_dout <= 8'h40 + i[7:0];
        ioctl_wr   <= 1'b1;
        @(posedge clk);
        ioctl_wr   <= 1'b0;
        repeat(47) @(posedge clk);
    end
    repeat(40) @(posedge clk);
    ioctl_rom = 1'b0; prog_en = 1'b0; use_dwnld = 1'b0;
    for( i = 0; i < 4; i = i + 1 ) begin
        grom_fetch( i[20:0] );
        for( ph = 0; ph < 8; ph = ph + 1 ) begin
            if( got64[8*ph +: 8] !== 8'h40 + i[7:0]*8 + ph[7:0] ) begin
                $display("  K grp%0d byte%0d = %02X WRONG (want %02X)",
                         i, ph, got64[8*ph +: 8], 8'h40 + i[7:0]*8 + ph[7:0]);
                errors = errors + 1;
            end
        end
        $display("  K group %0d: %016X  (bytes ascend %02X..%02X)",
                 i, got64, 8'h40+i[7:0]*8, 8'h47+i[7:0]*8);
    end

    $display("");
    if( errors == 0 ) $display("PASS: download + lane + rom_word all agree with the image");
    else              $display("FAIL: %0d problem(s)", errors);
    $finish;
end

initial begin #5_000_000; $display("FAIL: timeout"); $finish; end

endmodule
