`timescale 1ns/1ps
/*  This file is part of SFTM.  GPLv3 - see LICENSE.

    Phase 3 sound verification: real mc6809i running a program out of the
    modeled SDRAM snd bus, talking to the real sftm5506 engine.

    The 6809 program (fixed ROM, region offset 0x8000+):
      1. reads the command latch at 0x0000 (clears pending in the harness),
         stores it to RAM 0x2000
      2. reads sound_data_buffer_r (0x1800) AFTER the latch read, stores to
         RAM 0x2001 (should have bit7 clear: pending was consumed)
      3. tests banked ROM: sets bank 1 (0x0c00), reads 0x4000 (region
         0x14000 = 0xB1 in the model), stores to RAM 0x2002
      4. programs ES5506 voice 0 via the byte-serial host interface:
         page 0x20: START = 0 (word 0), END = 0x00040000 (word 128<<11... in
         accum format: end = 0x40 << 11 = 32 samples), ACCUM = 0
         page 0x00: FC = 0x800 (half-speed), LVOL = RVOL = 0xFFF0 (max),
         ECOUNT = 0, K2 = 0xFFFF (filters wide open), K1 = 0xFFFF,
         CR = 0x0000 (run, forward, bank 0, no loop)
         ACTV: left at reset value 31
      5. reads back the ES5506 CR (page 0, reg 0) byte 3, stores to 0x2003
      6. waits for FIRQ (firq handler at 0x9000 clears 0x1400, increments
         RAM 0x2004), then loops forever

    Sample ROM model: bank 0 bytes = address ramp (byte N = N & 0x7f), so
    the engine should produce a nonzero, changing output once voice 0 runs.

    Checks:
      1. RAM 0x2000 == 0x5A     (latch consumed via IRQ or poll)
      2. latch pending cleared  (snd_latch1_rd fired, harness flag)
      3. RAM 0x2001 bit7 == 0   (sound_data_buffer_r after consumption)
      4. RAM 0x2002 == 0xB1     (banked ROM page 1)
      5. RAM 0x2003 == 0x00     (ES5506 CR readback low byte, still 0)
      6. RAM 0x2004 >= 2        (FIRQ fires repeatedly and is cleared)
      7. snd_left/right become nonzero (voice 0 playing the ramp)

    Run:
      cd cores/sftm && iverilog -g2012 -o /tmp/tb_phase3.vvp \
          ver/game/tb_phase3_snd.v hdl/sftm_snd.v hdl/sftm5506.v \
          /path/to/mc6809i.v && vvp /tmp/tb_phase3.vvp
    (mc6809i.v comes from jtframe: modules/jtframe/hdl/cpu/mc6809i.v)
*/

module tb_phase3_snd;

reg clk = 0;
always #10.4 clk = ~clk;    // ~48 MHz

// cens: 4 MHz (every 12 clks), 16 MHz (every 3 clks)
reg [3:0] c12 = 0;
reg [1:0] c3  = 0;
always @(posedge clk) begin
    c12 <= c12 == 4'd11 ? 4'd0 : c12 + 4'd1;
    c3  <= c3  == 2'd2  ? 2'd0 : c3  + 2'd1;
end
wire cen4  = c12 == 0;
wire cen16 = c3 == 0;

reg rst = 1;
initial begin
    repeat (30) @(posedge clk);
    rst = 0;
end

// ---------------------------------------------------------------------------
// snd ROM model (SDRAM bank 0 style: 8-bit, ok latency)
// ---------------------------------------------------------------------------
wire [20:0] rom_addr;   // biased by SND_ORG (see cfg/mem.yaml)
wire        rom_cs;
reg  [ 7:0] rom[0:262143];
reg         rom_ok = 0;
reg  [20:0] ok_addr = 0;
reg  [ 2:0] ok_cnt = 0;
wire [ 7:0] rom_data = rom[ok_addr[17:0]];

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

// program assembler
integer pc;
task e(input [7:0] b); begin rom[pc] = b; pc = pc + 1; end endtask
task ldab_ext(input [15:0] a); begin e(8'hB6); e(a[15:8]); e(a[7:0]); end endtask // LDA ext
task stab_ext(input [15:0] a); begin e(8'hB7); e(a[15:8]); e(a[7:0]); end endtask // STA ext
task ldai(input [7:0] v);      begin e(8'h86); e(v); end endtask                  // LDA #
// write one ES5506 32-bit register: reg index r (0-15), value v
task esw(input [3:0] r, input [31:0] v); begin
    ldai(v[31:24]); stab_ext({8'h08, 2'b00, r, 2'b00});
    ldai(v[23:16]); stab_ext({8'h08, 2'b00, r, 2'b01});
    ldai(v[15: 8]); stab_ext({8'h08, 2'b00, r, 2'b10});
    ldai(v[ 7: 0]); stab_ext({8'h08, 2'b00, r, 2'b11});
end endtask

integer k;
initial begin
    for( k=0; k<262144; k=k+1 ) rom[k] = 8'h00;
    // banked page 1 marker: region 0x10000 + 1*0x4000 + 0 = 0x14000
    rom['h14000] = 8'hB1;

    // ---- main program at region 0x8000 (CPU 0x8000) ----
    pc = 'h8000;
    // 1) read command latch, store
    ldab_ext(16'h0000); stab_ext(16'h2000);
    // 2) read status after consumption
    ldab_ext(16'h1800); stab_ext(16'h2001);
    // 3) banked ROM: bank 1, read 0x4000
    ldai(8'h01); stab_ext(16'h0c00);
    ldab_ext(16'h4000); stab_ext(16'h2002);
    // 4) ES5506 voice 0 setup. PAGE reg = 0xF (byte offsets 0x3c-0x3f)
    esw(4'hF, 32'h0000_0020);              // page 0x20 (high bank, voice 0)
    esw(4'h1, 32'h0000_0000);              // START = 0
    esw(4'h2, 32'h0002_0000);              // END: word 64 (64<<11 = 0x20000)
    esw(4'h3, 32'h0000_0000);              // ACCUM = 0
    esw(4'hF, 32'h0000_0000);              // page 0x00 (low bank, voice 0)
    esw(4'h1, 32'h0000_0800);              // FC = 0x800 (half speed)
    esw(4'h2, 32'h0000_FFF0);              // LVOL max
    esw(4'h4, 32'h0000_FFF0);              // RVOL max
    esw(4'h6, 32'h0000_0000);              // ECOUNT 0
    esw(4'h7, 32'h0000_FFFF);              // K2 wide open
    esw(4'h9, 32'h0000_FFFF);              // K1 wide open
    esw(4'h0, 32'h0000_0000);              // CR = 0: run forward, bank 0
    // 5) read back CR byte 3 (low byte of control)
    ldab_ext(16'h0803);                    // triggers latch load at byte0? no:
                                           // byte 3 read returns rlatch[7:0];
                                           // do a byte0 read first
    ldab_ext(16'h0800);                    // load read latch (CR)
    ldab_ext(16'h0803);                    // CR[7:0]
    stab_ext(16'h2003);
    // 6) enable FIRQ (ANDCC #$BF clears F mask... 6809: FIRQ mask is CC bit 6)
    e(8'h1C); e(8'hAF);                    // ANDCC #$AF (clear F and I)
    // idle loop
    e(8'h20); e(8'hFE);                    // BRA *

    // ---- FIRQ handler at 0x9000 ----
    pc = 'h9000;
    stab_ext(16'h1400);                    // firq_clear_w (any write)
    e(8'h7C); e(8'h20); e(8'h04);          // INC $2004
    e(8'h3B);                              // RTI

    // ---- vectors ----
    rom['hFFF6] = 8'h90; rom['hFFF7] = 8'h00;   // FIRQ -> 0x9000
    rom['hFFF8] = 8'h80; rom['hFFF9] = 8'h00;   // IRQ  -> 0x8000 (unused; masked)
    rom['hFFFE] = 8'h80; rom['hFFFF] = 8'h00;   // RESET -> 0x8000
end

// ---------------------------------------------------------------------------
// srom model (bank 0 = address ramp)
// ---------------------------------------------------------------------------
wire [21:1] srom_addr;
wire        srom_cs;
reg         srom_ok = 0;
reg  [21:1] sok_addr = 0;
reg  [ 1:0] sok_cnt = 0;
// byte N = (N & 0x7f) -- positive ramp; word = {odd byte, even byte}
wire [15:0] srom_data = { {1'b0, sok_addr[7:1], 1'b1} & 8'h7f,
                          {1'b0, sok_addr[7:1], 1'b0} & 8'h7f };

always @(posedge clk) begin
    if( !srom_cs ) begin
        sok_cnt <= 0; srom_ok <= 0;
    end else if( srom_addr != sok_addr ) begin
        sok_addr <= srom_addr; sok_cnt <= 0; srom_ok <= 0;
    end else if( sok_cnt != 2'd3 )
        sok_cnt <= sok_cnt + 2'd1;
    else
        srom_ok <= 1;
end

// ---------------------------------------------------------------------------
// harness latch (plays sftm_main's role)
// ---------------------------------------------------------------------------
reg  [7:0] latch1 = 8'h5A;
reg        pending1 = 1;
reg        latch_was_read = 0;
wire       latch1_rd, latch2_rd;

always @(posedge clk) begin
    if( latch1_rd ) begin
        pending1 <= 0;
        latch_was_read <= 1;
    end
end

// ---------------------------------------------------------------------------
// DUT
// ---------------------------------------------------------------------------
wire signed [15:0] snd_left, snd_right;
wire sample;

sftm_snd u_snd(
    .rst(rst), .clk(clk), .cen(cen4), .es_cen(cen16),
    .rom_addr(rom_addr), .rom_data(rom_data), .rom_cs(rom_cs), .rom_ok(rom_ok),
    .srom_addr(srom_addr), .srom_data(srom_data), .srom_cs(srom_cs), .srom_ok(srom_ok),
    .snd_latch1(latch1), .snd_latch2(8'h00),
    .snd_pending1(pending1), .snd_pending2(1'b0),
    .snd_latch1_rd(latch1_rd), .snd_latch2_rd(latch2_rd),
    .snd_left(snd_left), .snd_right(snd_right), .sample(sample)
);

reg seen_audio = 0;
always @(posedge clk)
    if( sample && (snd_left != 0 || snd_right != 0) ) seen_audio <= 1;

// ---------------------------------------------------------------------------
// checks
// ---------------------------------------------------------------------------
integer errors = 0;
task check(input cond, input [255:0] name); begin
    if( cond ) $display("PASS: %0s", name);
    else begin  $display("FAIL: %0s", name); errors = errors + 1; end
end endtask

initial begin
    for( k=0; k<8192; k=k+1 ) u_snd.ram[k] = 8'h00;
    #30_000_000;   // 30 ms: several FIRQ periods, many sample periods
    check( u_snd.ram[13'h0000] == 8'h5A, "latch value read (0x5A)" );
    check( latch_was_read,               "latch consumed (pending cleared)" );
    check( u_snd.ram[13'h0001][7] == 1'b0, "status bit7 clear after consume" );
    check( u_snd.ram[13'h0002] == 8'hB1, "banked ROM page 1 read" );
    check( u_snd.ram[13'h0003] == 8'h00, "ES5506 CR readback == 0" );
    check( u_snd.ram[13'h0004] >= 8'd2,  "FIRQ taken and cleared repeatedly" );
    check( seen_audio,                   "voice 0 produces nonzero audio" );
    check( errors == 0, "ALL PHASE 3 CHECKS" );
    $finish;
end

endmodule
