// tb_romfetch -- run the REAL CPU against the REAL program ROM and check that
// every instruction fetch returns the byte-exact word the ROM actually holds.
//
// This is the first testbench to let TG68K run FREELY from reset instead of
// forcing bus signals, and the first to use the genuine SFTM v1.12 program
// image (assembled by doc/rom_interleave.py, lane order proven by reset-vector
// scoring). Hardware says the CPU takes a LINE-F exception with its faulting
// fetch inside 0x800400-0x80043F, yet the ROM holds only valid instructions
// there -- so either our ROM read path mis-addresses the fetch or it hands the
// CPU stale data. This reproduces that in simulation.
//
// Two ROM models, selected by MODE:
//   MODE_IDEAL  -- rom_ok always high, rom_data combinational from rom_addr.
//                  Any failure here is OUR OWN addressing/half-select logic.
//   MODE_BCACHE -- mimics jtframe_romrq_bcache: a fetch starts only on a
//                  LOW->HIGH edge of rom_cs, takes LATENCY cycles, and -- the
//                  crucial hazard -- if rom_addr changes while rom_cs STAYS
//                  high, NO refetch happens and rom_ok remains high while
//                  rom_data is STALE. The cpu_rom_gap logic exists to prevent
//                  exactly this; this model tests whether it actually does.
`timescale 1ns/1ps

module tb_romfetch;

    parameter MODE    = 0;      // 0 = ideal, 1 = bcache-like
    parameter LATENCY = 4;
    parameter RUNLEN  = 20000;
    parameter DEBUG   = 0;

    reg clk = 0;
    always #5 clk = ~clk;       // 100 MHz sim clock

    reg cen = 0;                // ~ half rate, like the real 25 MHz enable
    always @(posedge clk) cen <= ~cen;

    reg rst = 1;

    // ---- program ROM image -------------------------------------------------
    reg [31:0] rom[0:262143];   // 256K long-words = 1 MB
    initial $readmemh("/tmp/prog32.hex", rom);

    wire [17:0] rom_addr;
    wire        rom_cs;
    reg  [31:0] rom_data;
    reg         rom_ok;

    // ---- ideal model -------------------------------------------------------
    // Always-ready memory: data for the CURRENTLY presented address, no cache
    // semantics at all. Isolates our own logic -- if the CPU still faults
    // here, the defect is ours alone and nothing to do with the SDRAM cache.
    //
    // Registered rather than combinational on purpose: a plain `always @(*)`
    // reading a 256K-entry array makes iverilog build a sensitivity list over
    // every element, which blows up elaboration (learned the hard way).
    // rom_ok is asserted only once the registered data provably belongs to the
    // address being presented, so it is still a truthful "always ready" model.
    reg [31:0] ideal_d = 0;
    reg [17:0] ideal_a = 18'h3ffff;
    always @(posedge clk) begin
        ideal_d <= rom[rom_addr];
        ideal_a <= rom_addr;
    end
    always @(*) if( MODE == 0 ) begin
        rom_data = ideal_d;
        rom_ok   = (ideal_a == rom_addr);
    end

    // ---- bcache-like model -------------------------------------------------
    reg         cs_q    = 1'b0;
    integer     cnt     = 0;
    reg         busy    = 0;
    reg  [17:0] held    = 0;    // address actually latched by the "cache"
    integer     stale_hits = 0; // times the CPU consumed data for a DIFFERENT
                                // address than the one it is presenting

    always @(posedge clk) if( MODE == 1 ) begin
        cs_q <= rom_cs;
        // Use case-equality: on the very first cycle cs_q is X, and a plain
        // `!cs_q` yields X, so the initial edge was never detected and the model
        // deadlocked with rom_ok stuck low. Learned the hard way.
        if( rom_cs === 1'b1 && cs_q !== 1'b1 ) begin  // LOW->HIGH edge: fetch
            busy   <= 1'b1;
            cnt    <= 0;
            rom_ok <= 1'b0;
            held   <= rom_addr;
        end else if( busy ) begin
            if( cnt >= LATENCY ) begin
                busy     <= 1'b0;
                rom_data <= rom[held];
                rom_ok   <= 1'b1;
            end else cnt <= cnt + 1;
        end
        // NOTE: deliberately NO refetch when rom_addr changes while rom_cs
        // stays high. rom_ok stays high and rom_data stays stale -- the exact
        // hazard cpu_rom_gap is supposed to cover.
    end

    initial if( MODE == 1 ) begin rom_ok = 1'b0; rom_data = 32'h0; end

    // ---- DUT ---------------------------------------------------------------
    wire [ 2:0] exc_vec, exc_detail;
    wire [ 7:0] exc_vec_num;
    wire [23:0] exc_fetch_addr;
    wire [15:0] exc_fetch_word;
    wire        exc_last_ff;

    sftm_main u_dut(
        .rst            ( rst            ),
        .clk            ( clk            ),
        .cen            ( cen            ),
        .rom_addr       ( rom_addr       ),
        .rom_data       ( rom_data       ),
        .rom_cs         ( rom_cs         ),
        .rom_ok         ( rom_ok         ),
        .exc_vec        ( exc_vec        ),
        .exc_detail     ( exc_detail     ),
        .exc_vec_num    ( exc_vec_num    ),
        .exc_fetch_addr ( exc_fetch_addr ),
        .exc_fetch_word ( exc_fetch_word ),
        .exc_last_ff    ( exc_last_ff    )
    );

    // ---- fetch monitor -----------------------------------------------------
    integer fetches   = 0;
    integer mismatch  = 0;
    integer linef     = 0;
    integer first_bad = -1;
    reg [23:0] a;
    reg [15:0] got, exp;
    reg [31:0] lw;

    always @(posedge clk) begin
        if( !rst && u_dut.clkena && u_dut.busstate == 2'b00 ) begin
            a   = u_dut.cpu_a;
            got = u_dut.cpu_din;
            if( a[23:22] == 2'b10 ) begin          // program ROM space
                lw  = rom[a[19:2]];
                exp = a[1] ? lw[15:0] : lw[31:16];
                fetches = fetches + 1;
                if( got !== exp ) begin
                    mismatch = mismatch + 1;
                    if( first_bad < 0 ) first_bad = fetches;
                    if( mismatch <= 12 )
                        $display("  MISMATCH #%0d at %06X: got %04X, ROM has %04X",
                                 mismatch, a, got, exp);
                end
                if( (got & 16'hF000) == 16'hF000 ) begin
                    linef = linef + 1;
                    if( linef <= 6 )
                        $display("  LINE-F word fetched at %06X: %04X (ROM has %04X)",
                                 a, got, exp);
                end
            end
        end
    end

    // ---- exc_vec_rd tracer -------------------------------------------------
    // The whole exc_vec diagnostic family keys off READS of byte 0x008-0x3FF.
    // Show what the CPU is actually doing at each such read: busstate 2'b10 is
    // a DATA read, 2'b00 an instruction fetch. An exception vector fetch is a
    // data read too, so the discriminator is WHERE the code doing it lives.
    integer vrd = 0;
    always @(posedge clk) if( !rst && u_dut.exc_vec_rd ) begin
        vrd = vrd + 1;
        if( vrd <= 8 )
            $display("  vec-table READ #%0d: byte %06X (vector %0d) busstate=%b, last instr fetch was %06X",
                     vrd, u_dut.cpu_a, u_dut.cpu_addr[9:2], u_dut.busstate,
                     u_dut.last_fetch_addr);
    end

    integer boot_cycles = 0;

    // Boot-progress tracer: the bcache model made the boot copy stall, so show
    // exactly what the handshake is doing instead of guessing.
    integer dbg = 0;
    reg wrst_q = 0;
    always @(posedge clk) if( DEBUG ) begin
        if( u_dut.w_rst && !wrst_q )
            $display("  [%0t] w_rst ASSERTED (boot_lw=%0d)", $time, u_dut.boot_lw);
        wrst_q <= u_dut.w_rst;
        dbg = dbg + 1;
        if( dbg < 40 || dbg % 2000 == 0 )
            $display("  [%0d] boot_lw=%2d half=%b boot_cs=%b rom_cs=%b rom_ok=%b busy=%b cnt=%0d addr=%05X done=%b wrst=%b",
                     dbg, u_dut.boot_lw, u_dut.boot_half, u_dut.boot_cs, rom_cs,
                     rom_ok, busy, cnt, rom_addr, u_dut.boot_done, u_dut.w_rst);
    end

    initial begin
        repeat(8) @(posedge clk);
        rst = 0;

        // Let the boot copy finish, then run.
        while( !u_dut.boot_done && boot_cycles < 20000 ) begin
            @(posedge clk); boot_cycles = boot_cycles + 1;
        end
        if( !u_dut.boot_done ) begin
            $display("tb_romfetch[MODE=%0d]: BOOT COPY NEVER COMPLETED", MODE);
            $finish;
        end
        $display("tb_romfetch[MODE=%0d]: boot copy done after %0d clk", MODE, boot_cycles);
        $display("  RAM byte 0..3 (SSP) = %02X%02X%02X%02X   RAM byte 4..7 (PC) = %02X%02X%02X%02X",
                 u_dut.u_ram.mem_hi[0], u_dut.u_ram.mem_lo[0],
                 u_dut.u_ram.mem_hi[1], u_dut.u_ram.mem_lo[1],
                 u_dut.u_ram.mem_hi[2], u_dut.u_ram.mem_lo[2],
                 u_dut.u_ram.mem_hi[3], u_dut.u_ram.mem_lo[3]);

        repeat(RUNLEN) @(posedge clk);

        $display("tb_romfetch[MODE=%0d] RESULTS:", MODE);
        $display("  ROM fetches observed : %0d", fetches);
        $display("  wrong data returned  : %0d%s", mismatch,
                 first_bad >= 0 ? "" : "  <-- ROM read path is byte-exact");
        if( first_bad >= 0 )
            $display("  first wrong fetch    : #%0d", first_bad);
        $display("  line-F words fetched : %0d", linef);
        $display("  exception latched    : exc_vec=%0d vec_num=%0d(0x%02X) detail=%0d",
                 exc_vec, exc_vec_num, exc_vec_num, exc_detail);
        if( exc_vec != 0 )
            $display("  faulting fetch       : addr=%06X word=%04X last_ff=%b",
                     exc_fetch_addr, exc_fetch_word, exc_last_ff);
        if( mismatch == 0 && exc_vec == 0 )
            $display("tb_romfetch[MODE=%0d]: PASS -- no bad data, no exception", MODE);
        else
            $display("tb_romfetch[MODE=%0d]: REPRODUCED A DEFECT", MODE);
        $finish;
    end

endmodule
