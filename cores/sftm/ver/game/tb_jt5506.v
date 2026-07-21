/*  This file is part of JTSFTM.  GPLv3 - see LICENSE.

    Minimal self-checking bench for jt5506. It does not validate audio yet;
    it just exercises the host interface and voice scheduler so the module can
    be linted/simulated standalone (Verilator/iverilog) without JTFRAME.

    Real verification will compare jt5506 output against MAME es5506.cpp for a
    captured register/sample-ROM trace.
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

    integer sample_cnt=0;
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

    initial begin
        repeat(4) @(posedge clk);
        rst = 0;
        repeat(2) @(posedge clk);

        // --- Voice 0 initialisation (page 0) ---
        // Select page 0 (voices 0-31 CR/FC/LVOL/RVOL).
        host_write(6'h3c, 8'h00);   // PAGE = 0
        // CR (addr[5:3]=0): clear both STOP bits so voice 0 runs.
        host_write(6'h00, 8'h00);   // control[0][ 7:0] = 0x00
        host_write(6'h02, 8'h00);   // control[0][15:8] = 0x00
        // FC (addr[5:3]=1): set a non-zero playback frequency.
        host_write(6'h08, 8'h20);   // fc[0][ 7:0] = 0x20
        // LVOL (addr[5:3]=2).
        host_write(6'h10, 8'h40);   // lvol[0][ 7:0] = 0x40
        // RVOL (addr[5:3]=4).
        host_write(6'h20, 8'h40);   // rvol[0][ 7:0] = 0x40

        // --- Voice 0 loop region (page 32, voices 0-31 START/END/ACCUM) ---
        // endp must be > 0; otherwise accum[31:11] >= endp[20:0] triggers
        // immediately and the voice stops on its first sample.
        host_write(6'h3c, 8'h20);   // PAGE = 32 (voice 0 extended regs)
        // END (addr[5:3]=2): write endp[0][23:16] = 0xFF → endp[0][20:0] ≈ 0x0F_00_00
        host_write(6'h12, 8'hff);   // endp[0][23:16] = 0xFF
        host_write(6'h10, 8'hff);   // endp[0][15:8]  = 0xFF

        // let it run long enough for the mixer to emit at least one sample
        repeat(5000) @(posedge clk);

        if( sample_cnt==0 ) begin
            $display("FAIL: no samples produced");
            $finish;
        end
        if( left==16'h0000 && right==16'h0000 ) begin
            $display("FAIL: audio silent after %0d samples", sample_cnt);
            $finish;
        end
        $display("PASS: %0d samples, left=%h right=%h", sample_cnt, left, right);
        $finish;
    end
endmodule
