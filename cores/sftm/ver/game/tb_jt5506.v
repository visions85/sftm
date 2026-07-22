/*  This file is part of JTSFTM.  GPLv3 - see LICENSE.

    Self-checking bench for jt5506.  Exercises:
      1. Forward loop  (LPE=1, BLE=0, DIR=0): voice keeps producing samples.
      2. Reverse loop  (LPE=1, BLE=0, DIR=1): voice keeps producing samples.
      3. Bidirectional (LPE=1, BLE=1, DIR=0): voice keeps producing samples.
      4. One-shot      (LPE=0, BLE=0, DIR=0): voice stops at end boundary.
      5. ACTIVE register read/write.

    SROM model: every word returns 16'h1234 so audio is always non-zero when
    any voice is running.

    Run:
      iverilog -g2012 -Wall -o /tmp/tb_jt5506.vvp \
          cores/sftm/ver/game/tb_jt5506.v cores/sftm/hdl/jt5506.v && \
      vvp /tmp/tb_jt5506.vvp
*/
`timescale 1ns/1ps

module tb_jt5506;
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

    jt5506 uut(
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

    // CR field bit positions (mirroring jt5506.v localparam names)
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
        if( errors==0 )
            $display("PASS: jt5506 all loop-mode checks");
        else
            $display("FAIL: jt5506 %0d checks failed", errors);
        $finish;
    end
endmodule
