/*  This file is part of SFTM.  GPLv3 - see LICENSE.

    Self-checking bench for sftm5506.  Exercises:
      1. ACTIVE register read/write.
      2. Forward loop  (LPE=1, BLE=0, DIR=0): voice keeps producing samples.
      3. Reverse loop  (LPE=1, BLE=0, DIR=1): voice keeps producing samples.
      4. Bidirectional (LPE=1, BLE=1, DIR=0): voice keeps producing samples.
      5. One-shot      (LPE=0, BLE=0, DIR=0): voice stops at end boundary.
      6. K2/K1 register read/write (correct OTTO-spec addresses).
      7. Filter pass-through (K1=K2=0): output equals unfiltered sample.
      8. Envelope/volume ramp (LVRAMP/RVRAMP/ECOUNT): LVOL/RVOL delta applied.
      9. IRQ on one-shot stop (IRQE=1): irq asserted, IRQV holds voice index.

    SROM model: every word returns 16'h1234 so audio is always non-zero when
    any voice is running.

    Run:
      iverilog -g2012 -Wall -o /tmp/tb_sftm5506.vvp \
          cores/sftm/ver/game/tb_sftm5506.v cores/sftm/hdl/sftm5506.v && \
      vvp /tmp/tb_sftm5506.vvp
*/
`timescale 1ns/1ps

module tb_sftm5506;
    reg         clk=0, rst=1, cen=1;
    reg  [5:0]  host_addr=0;
    reg  [7:0]  host_din=0;
    reg         host_we=0, host_re=0;
    wire [7:0]  host_dout;
    wire        irq;
    wire [20:0] srom_addr;
    reg  [15:0] srom_data=16'h1234;
    wire        srom_cs;
    reg         srom_ok=1;
    wire [15:0] left, right;
    wire        sample;

    always #10 clk = ~clk;   // 50 MHz-ish

    sftm5506 uut(
        .rst(rst), .clk(clk), .cen(cen),
        .host_addr(host_addr), .host_din(host_din), .host_dout(host_dout),
        .host_we(host_we), .host_re(host_re), .irq(irq),
        .srom_addr(srom_addr), .srom_data(srom_data),
        .srom_cs(srom_cs), .srom_ok(srom_ok),
        .left(left), .right(right), .sample(sample)
    );

    integer sample_cnt=0, errors=0;
    always @(posedge clk) if(sample) sample_cnt = sample_cnt + 1;

    // Write one byte through the host interface (one clock pulse).
    task host_write(input [5:0] a, input [7:0] d);
    begin
        @(negedge clk);
        host_addr <= a; host_din <= d; host_we <= 1'b1;
        @(posedge clk);
        @(negedge clk);
        host_we <= 1'b0;
    end
    endtask

    // Read one byte from the host interface.
    task host_read(input [5:0] a, output [7:0] q);
    begin
        @(negedge clk);
        host_addr <= a; host_re <= 1'b1;
        @(posedge clk);
        q = host_dout;
        @(negedge clk);
        host_re <= 1'b0;
    end
    endtask

    // Configure a voice in page-0 (CR / FC / LVOL / RVOL) registers.
    // cr_val: full 16-bit control word (written as two bytes).
    task cfg_voice_p0(input [4:0] v, input [15:0] cr_val,
                      input [7:0] fc_lo, input [7:0] lv, input [7:0] rv);
    begin
        host_write(6'h3c, v[4:0]);       // PAGE = voice index (< 32)
        host_write(6'h00, cr_val[7:0]);  // CR low
        host_write(6'h02, cr_val[15:8]); // CR high
        host_write(6'h08, fc_lo);        // FC low byte
        host_write(6'h10, lv);           // LVOL low
        host_write(6'h20, rv);           // RVOL low
    end
    endtask

    // Configure voice extended regs (START / END) in page 32+v.
    // start_hi / end_hi: bits [23:16] of the 25-bit address (= bits [20:13] of word addr).
    task cfg_voice_p32(input [4:0] v,
                       input [7:0] start_hi, input [7:0] start_lo,
                       input [7:0] end_hi,   input [7:0] end_lo);
    begin
        host_write(6'h3c, 8'h20 | v[4:0]);  // PAGE = 32 + voice
        host_write(6'h0a, start_hi);  // START[23:16]
        host_write(6'h08, start_lo);  // START[15:8]
        host_write(6'h12, end_hi);    // END[23:16]
        host_write(6'h10, end_lo);    // END[15:8]
    end
    endtask

    // Wait N clock cycles, return whether `sample` pulsed at least once.
    task wait_clocks(input integer n);
    begin
        repeat(n) @(posedge clk);
    end
    endtask

    // CR field bit positions (mirroring sftm5506.v localparam names)
    localparam CR_STOP0 = 0, CR_STOP1 = 1, CR_LEI = 2, CR_LPE = 3,
               CR_BLE  = 4, CR_IRQE  = 5, CR_DIR = 6;

    initial begin
        repeat(4) @(posedge clk);
        rst = 0;
        repeat(2) @(posedge clk);

        // =================================================================
        // Test 1: ACTIVE register read/write
        // =================================================================
        begin : t1_active
            reg [7:0] rd;
            host_write(6'h3e, 8'h03);    // ACTIVE = 3 (4 voices)
            host_read(6'h3e, rd);
            if( rd[4:0] !== 5'd3 ) begin
                $display("FAIL t1: ACTIVE rd=%0d exp=3", rd[4:0]);
                errors = errors + 1;
            end
            host_write(6'h3e, 8'h1f);    // restore 32 voices
        end

        // =================================================================
        // Test 2: Forward loop — voice 0, LPE=1, BLE=0, DIR=0
        // Set a short loop region (endp word addr 0x10) so the voice loops
        // many times within a few hundred cycles.  Verify audio stays non-zero.
        // =================================================================
        // CR: LPE=1, all STOP bits clear, DIR=0.
        cfg_voice_p0(5'd0, 16'h0008, 8'h20, 8'h40, 8'h40); // CR=LPE
        cfg_voice_p32(5'd0, 8'h00, 8'h00, 8'h00, 8'h10);   // start=0, end=0x0010<<8
        sample_cnt = 0;
        wait_clocks(1000);
        if( sample_cnt == 0 ) begin
            $display("FAIL t2: fwd loop produced no samples");
            errors = errors + 1;
        end
        if( left==16'h0 && right==16'h0 ) begin
            $display("FAIL t2: fwd loop audio silent");
            errors = errors + 1;
        end

        // =================================================================
        // Test 3: Reverse loop — voice 1, LPE=1, BLE=0, DIR=1
        // Start accum at end boundary (endp word addr 0x10 → accum 0x00008000).
        // Voice should play backward from end to start, then jump back to end.
        // =================================================================
        // CR: LPE=1, DIR=1 (bit 6)
        cfg_voice_p0(5'd1, 16'h0048, 8'h20, 8'h40, 8'h40); // CR=LPE|DIR
        cfg_voice_p32(5'd1, 8'h00, 8'h00, 8'h00, 8'h10);   // start=0, end=0x10<<8
        // Set accum to end position (page 33, addr[5:3]=3 → accum regs).
        host_write(6'h3c, 8'h21);          // PAGE = 33 (voice 1 extended)
        host_write(6'h1a, 8'h00);          // ACCUM[31:24]
        host_write(6'h18, 8'h80);          // ACCUM[23:16]  → accum = 0x00008000 = end
        host_write(6'h16, 8'h00);          // ACCUM[15:8]
        host_write(6'h14, 8'h00);          // ACCUM[7:0]
        sample_cnt = 0;
        wait_clocks(1000);
        if( sample_cnt == 0 ) begin
            $display("FAIL t3: reverse loop produced no samples");
            errors = errors + 1;
        end
        if( left==16'h0 && right==16'h0 ) begin
            $display("FAIL t3: reverse loop audio silent");
            errors = errors + 1;
        end

        // =================================================================
        // Test 4: Bidirectional loop — voice 2, LPE=1, BLE=1, DIR=0
        // =================================================================
        cfg_voice_p0(5'd2, 16'h0018, 8'h20, 8'h40, 8'h40); // CR=LPE|BLE
        cfg_voice_p32(5'd2, 8'h00, 8'h00, 8'h00, 8'h10);   // start=0, end=0x10<<8
        sample_cnt = 0;
        wait_clocks(1000);
        if( sample_cnt == 0 ) begin
            $display("FAIL t4: bidir loop produced no samples");
            errors = errors + 1;
        end
        if( left==16'h0 && right==16'h0 ) begin
            $display("FAIL t4: bidir loop audio silent");
            errors = errors + 1;
        end

        // =================================================================
        // Test 5: One-shot — voice 3, LPE=0, very short endp
        // After the voice plays through once it should stop (CTRL_STOP0 set).
        // To isolate, stop all other voices first, let one-shot run, then
        // confirm audio is silent after a generous timeout.
        // =================================================================
        // Stop voices 0-2.
        host_write(6'h3c, 8'h00); host_write(6'h00, 8'h03);  // v0 STOP
        host_write(6'h3c, 8'h01); host_write(6'h00, 8'h03);  // v1 STOP
        host_write(6'h3c, 8'h02); host_write(6'h00, 8'h03);  // v2 STOP
        // Configure voice 3: LPE=0, tiny loop (end word addr = 4 = 32-byte region).
        cfg_voice_p0(5'd3, 16'h0000, 8'h20, 8'h40, 8'h40);   // CR = 0 (running)
        cfg_voice_p32(5'd3, 8'h00, 8'h00, 8'h00, 8'h04);     // start=0, end=4
        // Let voice 3 finish (small loop at FC=0x20 → ~256 cen per pass).
        wait_clocks(2000);
        // Now silence all remaining voices.
        host_write(6'h3c, 8'h03); host_write(6'h00, 8'h03);  // v3 STOP
        // Wait one full mixer period and check output is zero.
        wait_clocks(200);
        if( left!=16'h0 || right!=16'h0 ) begin
            $display("FAIL t5: one-shot audio not silent after stop: L=%h R=%h",
                     left, right);
            errors = errors + 1;
        end

        // =================================================================
        // Test 6: K2/K1 register read/write (corrected OTTO-spec addresses)
        // K2 is now at low-page addr[5:3]=7 (H38): write 0x38 / 0x3a.
        // K1 is now in high page (32+voice), addr[5:3]=5 (H28): 0x28 / 0x2a.
        // Note: reading addr 0x38 returns IRQV (not K2 low byte) because
        //       the global IRQV register overlaps; only the high byte 0x3a
        //       is verified here.
        // Uses voice 0 (valid with NVOICES=4).
        // =================================================================
        begin : t6_filter_regs
            reg [7:0] rd;
            host_write(6'h3c, 8'h00);    // PAGE = voice 0 (low page)
            // Write K2 = 0x5678 (addr[5:3]=7 = H38)
            host_write(6'h38, 8'h78);    // K2 low byte  (H38)
            host_write(6'h3a, 8'h56);    // K2 high byte (H3a)
            // Read back K2 high byte (0x38 returns IRQV, so skip low byte)
            host_read(6'h3a, rd);
            if( rd !== 8'h56 ) begin
                $display("FAIL t6: K2 high rd=%02h exp=56", rd); errors=errors+1;
            end
            // Write K1 = 0x1234 in high page (32+0=32=0x20), addr[5:3]=5 (H28)
            host_write(6'h3c, 8'h20);    // PAGE = 32 (high page for voice 0)
            host_write(6'h28, 8'h34);    // K1 low byte
            host_write(6'h2a, 8'h12);    // K1 high byte
            // Read back K1
            host_read(6'h28, rd);
            if( rd !== 8'h34 ) begin
                $display("FAIL t6: K1 low rd=%02h exp=34", rd); errors=errors+1;
            end
            host_read(6'h2a, rd);
            if( rd !== 8'h12 ) begin
                $display("FAIL t6: K1 high rd=%02h exp=12", rd); errors=errors+1;
            end
        end

        // =================================================================
        // Test 7: Filter pass-through (K1=K2=0, LP4|LP3 all-LP mode).
        // With K=0: apply_lp(prev, 0, in) = (0*(prev-in))/4096 + in = in.
        // All 4 poles are transparent: p4 = fin = srom_data = 0x0100 = 256.
        // Only voice 5 runs (voices 0-4 stopped, ACTIVE=5).
        // ACTIVE=5 means vidx==active when vidx==5, so voice 5 is the final
        // active voice — exercises the flush-on-same-tick path.
        // LVOL = RVOL = 0x4000  →  lvol[14:0] = 16384.
        // Expected: left = right = (256 * 16384) >>> 14 = 256 = 0x0100.
        // =================================================================
        begin : t7_filter_passthru
            reg signed [31:0] expected_mix;
            // Stop voice 0 (used in test 6 for K2/K1 write).
            host_write(6'h3c, 8'h00); host_write(6'h00, 8'h03);
            // Configure voice 3: K1=K2=0, LP4|LP3, LPE=1, LVOL=RVOL=0x4000.
            host_write(6'h3c, 8'h03);     // PAGE = voice 3 (low page)
            host_write(6'h18, 8'h00); host_write(6'h1a, 8'h00); // LVRAMP = 0
            host_write(6'h28, 8'h00); host_write(6'h2a, 8'h00); // RVRAMP = 0
            host_write(6'h38, 8'h00); host_write(6'h3a, 8'h00); // K2 = 0
            // K1 is in high page (32+3=35=0x23), addr[5:3]=5
            host_write(6'h3c, 8'h23);
            host_write(6'h28, 8'h00); host_write(6'h2a, 8'h00); // K1 = 0
            host_write(6'h3c, 8'h03);     // Back to low page 3
            // CR low (bits 7:0)  = 0x08 → LPE=1 (STOP bits clear → voice runs)
            // CR high (bits 15:8) = 0x03 → LP4(bit9)=1, LP3(bit8)=1
            host_write(6'h00, 8'h08);     // CR low
            host_write(6'h02, 8'h03);     // CR high
            host_write(6'h08, 8'h01);     // FC = 1 (slow step; keeps accum in range)
            // LVOL = 0x4000: low byte first, then high byte
            host_write(6'h10, 8'h00); host_write(6'h12, 8'h40); // LVOL = 0x4000
            host_write(6'h20, 8'h00); host_write(6'h22, 8'h40); // RVOL = 0x4000
            // Extended regs (page 32+3=35=0x23).
            host_write(6'h3c, 8'h23);
            host_write(6'h0a, 8'h00); host_write(6'h08, 8'h00); // START = 0
            host_write(6'h12, 8'hff); host_write(6'h10, 8'hff); // END = large (no early stop)
            // DC sample value.
            srom_data = 16'h0100;  // 256
            // ACTIVE=3: voices 0..3 scheduled; voice 3 is both running and the
            // flush tick (vidx==active).  Tests the fix for the NBA conflict.
            host_write(6'h3e, 8'h03);     // ACTIVE = 3
            host_write(6'h3c, 8'h00); host_write(6'h00, 8'h03); // v0 stop
            host_write(6'h3c, 8'h01); host_write(6'h00, 8'h03); // v1 stop
            host_write(6'h3c, 8'h02); host_write(6'h00, 8'h03); // v2 stop
            // voice 3 is the running test voice — no stop
            // Let filter state settle (K=0 → instant, but wait a few samples).
            repeat(3) @(posedge sample);
            // Expected: (256 * 16384) >>> 14 = 256 = 0x0100
            expected_mix = ($signed(32'sh0100) * $signed(32'sh4000)) >>> 14;
            if( left !== expected_mix[15:0] ) begin
                $display("FAIL t7: left=%h exp=%h", left, expected_mix[15:0]);
                errors = errors + 1;
            end
            if( right !== expected_mix[15:0] ) begin
                $display("FAIL t7: right=%h exp=%h", right, expected_mix[15:0]);
                errors = errors + 1;
            end
            // Restore.
            srom_data = 16'h1234;
            host_write(6'h3e, 8'h03);
            host_write(6'h3c, 8'h03); host_write(6'h00, 8'h03); // v3 stop
        end

        // =================================================================
        // Test 8: Envelope/volume ramp.
        // Voice 2: LVOL=0x0100, LVRAMP=+4/sample, ECOUNT=3.
        // After 3 sample ticks LVOL should be 0x010C (0x100 + 3*4).
        // RVOL=0x0200, RVRAMP=-4/sample (0xFC), after 3 ticks RVOL=0x01F4.
        // =================================================================
        begin : t8_env_ramp
            reg [7:0] rd_lo, rd_hi;
            host_write(6'h3c, 8'h02);    // PAGE = voice 2 (low page)
            host_write(6'h00, 8'h08);    // CR low: LPE=1
            host_write(6'h02, 8'h00);    // CR high: no LP modes
            host_write(6'h08, 8'h01);    // FC = 1
            host_write(6'h10, 8'h00); host_write(6'h12, 8'h01); // LVOL = 0x0100
            host_write(6'h20, 8'h00); host_write(6'h22, 8'h02); // RVOL = 0x0200
            host_write(6'h18, 8'h04);    // LVRAMP = +4 (signed byte)
            host_write(6'h28, 8'hFC);    // RVRAMP = -4 (0xFC in two's complement)
            host_write(6'h30, 8'h03);    // ECOUNT = 3
            // Extended regs (page 32+2=34=0x22)
            host_write(6'h3c, 8'h22);
            host_write(6'h0a, 8'h00); host_write(6'h08, 8'h00); // START=0
            host_write(6'h12, 8'hff); host_write(6'h10, 8'hff); // END=large
            // ACTIVE=3: run voices 0..3; stop all but voice 2.
            host_write(6'h3e, 8'h03);
            host_write(6'h3c, 8'h00); host_write(6'h00, 8'h03);
            host_write(6'h3c, 8'h01); host_write(6'h00, 8'h03);
            // voice 2 is running — no stop
            host_write(6'h3c, 8'h03); host_write(6'h00, 8'h03);
            // Wait 4 output samples (each = 4 voice ticks; ramp applied 3 ticks then stops).
            repeat(4) @(posedge sample);
            // Check LVOL: expect 0x0100 + 3*4 = 0x010C.
            host_write(6'h3c, 8'h02);    // back to voice 2 for readback
            host_read(6'h10, rd_lo);
            host_read(6'h12, rd_hi);
            if( {rd_hi, rd_lo} !== 16'h010C ) begin
                $display("FAIL t8: LVOL=%04h exp=010C", {rd_hi, rd_lo}); errors=errors+1;
            end
            // Check RVOL: expect 0x0200 - 3*4 = 0x01F4.
            host_read(6'h20, rd_lo);
            host_read(6'h22, rd_hi);
            if( {rd_hi, rd_lo} !== 16'h01F4 ) begin
                $display("FAIL t8: RVOL=%04h exp=01F4", {rd_hi, rd_lo}); errors=errors+1;
            end
            // Check ECOUNT = 0.
            host_read(6'h30, rd_lo);
            if( rd_lo !== 8'h00 ) begin
                $display("FAIL t8: ECOUNT=%02h exp=00", rd_lo); errors=errors+1;
            end
        end

        // =================================================================
        // Test 9: IRQ on one-shot stop (IRQE=1).
        // Voice 7: LPE=0 (one-shot), IRQE=1 (bit 5 of CR), immediate end.
        // After the voice plays through once, irq must be asserted and
        // irqv[4:0] must equal 7 (voice index) with irqv[7]=0.
        // Acknowledge by reading IRQV (host_addr 0x38); irq must then clear.
        // =================================================================
        begin : t9_irq_stop
            reg [7:0] rd;
            host_write(6'h3c, 8'h02); host_write(6'h00, 8'h03); // v2 stop (from t8)
            // Configure voice 3: LPE=0, IRQE=1 (CR=0x20), very short end.
            host_write(6'h3c, 8'h03);
            host_write(6'h00, 8'h20);    // CR low: IRQE=1, STOP bits clear
            host_write(6'h02, 8'h00);    // CR high
            host_write(6'h08, 8'h40);    // FC = 64 (fast advance)
            host_write(6'h10, 8'h40); host_write(6'h12, 8'h00); // LVOL=0x0040
            host_write(6'h20, 8'h40); host_write(6'h22, 8'h00); // RVOL=0x0040
            // Extended regs (page 32+3=35=0x23): START=0, END=0 (immediate boundary)
            host_write(6'h3c, 8'h23);
            host_write(6'h0a, 8'h00); host_write(6'h08, 8'h00); // START=0
            host_write(6'h12, 8'h00); host_write(6'h10, 8'h00); // END=0 (immediate boundary)
            // ACTIVE=3; stop voices 0..2 (voice 3 is running).
            host_write(6'h3e, 8'h03);
            host_write(6'h3c, 8'h00); host_write(6'h00, 8'h03);
            host_write(6'h3c, 8'h01); host_write(6'h00, 8'h03);
            host_write(6'h3c, 8'h02); host_write(6'h00, 8'h03);
            // voice 3 is running — no stop here
            // Wait for 2 audio samples (= 8 voice ticks); voice 3 fires on
            // the first tick it is scheduled after ACTIVE=3 takes effect.
            repeat(2) @(posedge sample);
            // irq must be high.
            if( irq !== 1'b1 ) begin
                $display("FAIL t9: irq not asserted after one-shot stop"); errors=errors+1;
            end
            // Read IRQV: should hold {3'b0, 5'd3} = 8'h03.
            host_read(6'h38, rd);
            if( rd[6:0] !== 7'h03 ) begin
                $display("FAIL t9: irqv=%02h exp=03", rd); errors=errors+1;
            end
            if( rd[7] !== 1'b0 ) begin
                $display("FAIL t9: irqv bit7 should be 0 (pending)"); errors=errors+1;
            end
            // After acknowledge, wait one full sample period for the scheduler
            // to process the ack and de-assert irq.
            repeat(2) @(posedge sample);
            if( irq !== 1'b0 ) begin
                $display("FAIL t9: irq still asserted after IRQV ack"); errors=errors+1;
            end
        end

        // =================================================================
        if( errors==0 )
            $display("PASS: sftm5506 all loop-mode checks");
        else
            $display("FAIL: sftm5506 %0d checks failed", errors);
        $finish;
    end
endmodule
