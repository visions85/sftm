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
module tb_cachelane;

localparam SDRAM_AW = 24;   // JTFRAME_SDRAM_LARGE

reg clk = 0, rst = 1;
always #10.4 clk = ~clk;    // 48 MHz

// ---------------------------------------------------------------------------
// lane 2 = main: DW=32, AW=20, ENDIAN=1, BA=0, OFFSET=0 (generated values)
// ---------------------------------------------------------------------------
reg  [19:2] addr2 = 0;
reg         rd2 = 0, wr2 = 0;
reg  [31:0] din2 = 0;
wire [31:0] dout2;
wire        ok2;

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
    .ENDIAN2 ( 1 ), .FULL2 ( 0 ), .AW2 ( 20 ), .BLOCKS2 ( 16 ),
    .BLKSIZE2 ( 256 ), .DW2 ( 32 ), .BA2 ( 0 ), .CHIP2 ( 0 ),
    .OFFSET2 ( 'h0 ), .INVAL_MASK2 ( 8'b0 )
) u_mux (
    .rst(rst), .clk(clk),
    .addr0( 19'd0 ), .dout0(), .rd0(1'b0), .wr0(1'b0), .din0(32'd0),
    .wdsn0(4'd0), .ok0(), .flush0(1'b0), .flushing0(), .flush_done0(),
    .addr1( 18'd0 ), .dout1(), .rd1(1'b0), .wr1(1'b0), .din1(16'd0),
    .wdsn1(2'd0), .ok1(), .flush1(1'b0), .flushing1(), .flush_done1(),
    .addr2( lda_act ? ld_addr : addr2 ), .dout2(dout2),
    .rd2( lda_act ? ldr : rd2 ), .wr2( lda_act ? ldw : wr2 ),
    .din2( lda_act ? ld_data : din2 ),
    .wdsn2(4'd0), .ok2(ok2), .flush2(1'b0), .flushing2(), .flush_done2(),
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

// SDRAM pins
wire [15:0] sdram_dq;
wire [12:0] sdram_a;
wire [ 1:0] sdram_ba_pin;
wire sdram_dqml, sdram_dqmh, sdram_nwe, sdram_ncas, sdram_nras, sdram_ncs, sdram_cke;

jtframe_burst_sdram #(
    .AW(SDRAM_AW), .HF(0), .MISTER(1)
) u_ctrl (
    .rst(rst), .clk(clk), .init(sdr_init),
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
    .Dq(sdram_dq), .Addr(sdram_a), .Ba(sdram_ba_pin), .Clk(clk),
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
    .clk(clk), .ioctl_rom(ioctl_rom), .ioctl_addr(ioctl_addr),
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

// real program-ROM head, one hex byte per line (first 64 bytes of the stream)
reg [7:0] prog_head [0:63];
initial $readmemh("cores/sftm/ver/game/prog_head.hex", prog_head);

// memory content: every 16-bit word names its own index
integer i;
initial for( i=0; i<16384; i=i+1 ) u_chip.Bank0[i] = 16'h1000 + i[15:0];

// ---------------------------------------------------------------------------
integer errors = 0;
reg [31:0] got;

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

task cpu_view(input [19:2] lw);
begin
    fetch(lw);
    fetch_even = { got[ 7:0], got[15: 8] };   // rom_word, !A[1]
    fetch_odd  = { got[23:16], got[31:24] };  // rom_word,  A[1]
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

    $display("");
    if( errors == 0 ) $display("PASS: download + lane + rom_word all agree with the image");
    else              $display("FAIL: %0d problem(s)", errors);
    $finish;
end

initial begin #3_000_000; $display("FAIL: timeout"); $finish; end

endmodule
