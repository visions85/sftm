`timescale 1ns/1ps
// What address units does a DW=32 cache lane expect?
//
// The banks build wires the CPU as  .slot0_addr({main_addr,1'b0})  -- main_addr
// is [19:2], a LONGWORD index, so the slot is handed a 16-bit WORD address --
// and that build boots. The cache-lanes generator instead wires
// .addr2(main_addr) RAW. If the lane also wants a word address, every main
// fetch lands at half the intended address, which is the class of fault behind
// build 66's wrong first longword.
//
// This drives the real jtframe_romrq_bcache with the real first bytes of the
// SFTM program ROM and prints what each convention returns, so the answer comes
// from the module itself rather than from reading it.
module tb_bcache32;

localparam SDRAMW = 23, AW = 20, DW = 32;

reg clk = 0, rst = 1;
always #10 clk = ~clk;

// first 8 16-bit words of the program ROM (verified against the ROM file)
reg [15:0] rom[0:15];
initial begin
    rom[0]=16'h0000; rom[1]=16'h8000; rom[2]=16'h0080; rom[3]=16'h0400;
    rom[4]=16'h0080; rom[5]=16'h08F0; rom[6]=16'h0080; rom[7]=16'h0900;
    rom[8]=16'h0080; rom[9]=16'h0910; rom[10]=16'h0080; rom[11]=16'h0920;
    rom[12]=16'h0080; rom[13]=16'h0930; rom[14]=16'h0080; rom[15]=16'h0940;
end

reg  [AW-1:0] addr = 0;
reg           addr_ok = 0;
wire [DW-1:0] dout;
wire          data_ok, req;
wire [SDRAMW-1:0] sdram_addr;
reg  [15:0]   din = 0;
reg           din_ok = 0, dst = 0, we = 0;

jtframe_romrq_bcache #(.SDRAMW(SDRAMW),.AW(AW),.DW(DW)) uut(
    .rst(rst), .clk(clk), .clr(1'b0), .offset({SDRAMW{1'b0}}),
    .din(din), .din_ok(din_ok), .dst(dst), .we(we), .req(req),
    .sdram_addr(sdram_addr),
    .addr(addr), .addr_ok(addr_ok), .data_ok(data_ok), .dout(dout)
);

// ---------------------------------------------------------------------------
// SDRAM burst model, ONE process.
//
// A first attempt drove dst/we/din from both an always block and a task, so
// the two processes raced and every fetch came back 00000000 -- which made
// both address conventions look identical and the comparison meaningless.
// Single FSM, single driver.
//
// Protocol per the bcache: while we=1, the word marked dst is the first of the
// pair and the following word is the second.
// ---------------------------------------------------------------------------
reg [2:0] mst = 0;
reg [3:0] wait_c = 0;
reg [SDRAMW-1:0] burst_a = 0;

always @(posedge clk) begin
    if( rst ) begin
        mst <= 0; we <= 0; dst <= 0; din_ok <= 0;
    end else case( mst )
        3'd0: begin
            we <= 0; dst <= 0; din_ok <= 0;
            if( req ) begin burst_a <= sdram_addr; wait_c <= 0; mst <= 3'd1; end
        end
        3'd1: if( wait_c == 4'd3 ) mst <= 3'd2; else wait_c <= wait_c + 4'd1;
        3'd2: begin
            din <= rom[burst_a[3:0]];
            din_ok <= 1; dst <= 1; we <= 1; mst <= 3'd3;
        end
        3'd3: begin
            din <= rom[burst_a[3:0] + 4'd1];
            din_ok <= 1; dst <= 0; we <= 1; mst <= 3'd4;
        end
        3'd4: begin we <= 0; din_ok <= 0; mst <= 3'd0; end
    endcase
end

// ---------------------------------------------------------------------------
task fetch(input [AW-1:0] a, output [31:0] got);
integer guard;
begin
    @(posedge clk);
    addr <= a; addr_ok <= 1;
    guard = 0;
    while( !data_ok && guard < 400 ) begin @(posedge clk); guard = guard + 1; end
    if( guard >= 400 ) $display("  (no data_ok for addr %0d)", a);
    got = dout;
    @(posedge clk);
    addr_ok <= 0;
    @(posedge clk);
end endtask

reg [31:0] g0, g1;
integer errors = 0;

initial begin
    repeat(8) @(posedge clk);
    rst = 0;
    repeat(8) @(posedge clk);

    $display("");
    $display("ROM words: w0=%04X w1=%04X w2=%04X w3=%04X w4=%04X",
             rom[0],rom[1],rom[2],rom[3],rom[4]);
    $display("68k longword 0 = %04X%04X, longword 1 = %04X%04X",
             rom[0],rom[1],rom[2],rom[3]);
    $display("");

    // Sanity FIRST: the model must deliver real ROM content. Two builds were
    // lost to a bench that compared one broken path against another.
    fetch(20'd0, g0);
    if( g0 === 32'd0 || g0 === 32'hxxxxxxxx ) begin
        $display("FAIL: burst model returned %08X -- bench is broken, no verdict", g0);
        $finish;
    end
    $display("model delivers real content: word addr 0 -> %08X", g0);
    $display("");

    // ---- convention A: RAW longword index (what the cache-lanes generator does)
    fetch(20'd0, g0);
    fetch(20'd1, g1);
    $display("RAW longword index   : addr=0 -> %08X   addr=1 -> %08X", g0, g1);
    if( g0 === g1 ) begin
        $display("   ^ addr 0 and addr 1 return the SAME longword:");
        $display("     the lane cleared bit 0, so consecutive CPU longwords alias.");
        errors = errors + 1;
    end

    // ---- convention B: word address (what the working banks build passes)
    fetch(20'd0, g0);
    fetch(20'd2, g1);
    $display("word address {a,1'b0}: addr=0 -> %08X   addr=2 -> %08X", g0, g1);
    $display("");

    if( errors == 0 )
        $display("PASS: the DW=32 lane accepts a raw longword index");
    else begin
        $display("FAIL: the DW=32 lane needs a 16-bit WORD address, not a longword index");
        $display("      -> the generator must wire .addrN({name_addr,1'b0})");
    end
    $finish;
end

initial begin #500000; $display("FAIL: timeout"); $finish; end

endmodule
