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

    initial begin
        repeat(4) @(posedge clk);
        rst = 0;
        // write a frequency to voice 0 (page 0, FC reg)
        @(posedge clk); host_addr<=6'h08; host_din<=8'h20; host_we<=1;
        @(posedge clk); host_we<=0;
        // let it run
        repeat(5000) @(posedge clk);
        if( sample_cnt==0 ) begin
            $display("FAIL: no samples produced");
            $finish;
        end
        $display("PASS: %0d samples produced (left=%h right=%h)", sample_cnt, left, right);
        $finish;
    end
endmodule
