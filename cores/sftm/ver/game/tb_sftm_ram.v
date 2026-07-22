/*  This file is part of SFTM.  GPLv3 - see LICENSE.

    Self-checking bench for sftm_ram: verifies full-word writes, independent
    high/low byte-lane writes (the other lane must be preserved) and address
    independence, accounting for the 1-cycle registered-read latency.

    Run:
      iverilog -g2012 -Wall -o /tmp/tb_sftm_ram.vvp \
          cores/sftm/ver/game/tb_sftm_ram.v cores/sftm/hdl/sftm_ram.v && \
      vvp /tmp/tb_sftm_ram.vvp
*/
`timescale 1ns/1ps

module tb_sftm_ram;
    localparam AW = 4;              // 16 words is plenty for the checks

    reg              clk;
    reg  [AW-1:0]    addr;
    reg  [15:0]      din;
    reg              we_lo, we_hi;
    wire [15:0]      dout;

    integer          errors = 0;

    sftm_ram #(.AW(AW)) uut(
        .clk    ( clk   ),
        .addr   ( addr  ),
        .din    ( din   ),
        .we_lo  ( we_lo ),
        .we_hi  ( we_hi ),
        .dout   ( dout  )
    );

    // 100 MHz test clock
    initial clk = 1'b0;
    always #5 clk = ~clk;

    // Write with explicit byte-lane enables.
    task ram_write(input [AW-1:0] a, input [15:0] d, input lo, input hi);
    begin
        @(negedge clk);
        addr  = a;
        din   = d;
        we_lo = lo;
        we_hi = hi;
        @(posedge clk);             // sample write
        @(negedge clk);
        we_lo = 1'b0;
        we_hi = 1'b0;
    end
    endtask

    // Point the read port at an address and wait for registered dout.
    task ram_read(input [AW-1:0] a);
    begin
        @(negedge clk);
        addr  = a;
        we_lo = 1'b0;
        we_hi = 1'b0;
        @(posedge clk);             // dout <= mem[addr]
        @(negedge clk);             // dout stable to sample
    end
    endtask

    task check(input [15:0] got, input [15:0] exp, input [255:0] name);
    begin
        if( got !== exp ) begin
            $display("FAIL: %0s got=%04h exp=%04h", name, got, exp);
            errors = errors + 1;
        end else begin
            $display("ok  : %0s = %04h", name, got);
        end
    end
    endtask

    initial begin
        addr  = 0;
        din   = 0;
        we_lo = 0;
        we_hi = 0;

        // 1) full-word write then read back
        ram_write(4'h3, 16'h1234, 1'b1, 1'b1);
        ram_read (4'h3);
        check(dout, 16'h1234, "full word @3");

        // 2) low-byte-only write must preserve the high byte
        ram_write(4'h3, 16'hFFAB, 1'b1, 1'b0);
        ram_read (4'h3);
        check(dout, 16'h12AB, "low-byte lane @3");

        // 3) high-byte-only write must preserve the low byte
        ram_write(4'h3, 16'hCDFF, 1'b0, 1'b1);
        ram_read (4'h3);
        check(dout, 16'hCDAB, "high-byte lane @3");

        // 4) neither lane enabled -> no change
        ram_write(4'h3, 16'h0000, 1'b0, 1'b0);
        ram_read (4'h3);
        check(dout, 16'hCDAB, "no-write hold @3");

        // 5) a different address is independent
        ram_write(4'hA, 16'hBEEF, 1'b1, 1'b1);
        ram_read (4'hA);
        check(dout, 16'hBEEF, "full word @A");
        ram_read (4'h3);
        check(dout, 16'hCDAB, "@3 undisturbed by @A");

        if( errors == 0 )
            $display("PASS: sftm_ram byte-lane RAM");
        else
            $display("FAIL: sftm_ram (%0d errors)", errors);
        $finish;
    end
endmodule
