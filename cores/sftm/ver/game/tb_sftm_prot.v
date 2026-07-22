/*  This file is part of SFTM.  GPLv3 - see LICENSE.

    Self-checking bench for sftm_prot: the protection byte must latch the
    high byte written to main-RAM word 0x3d35 (byte 0x7a6a), ignore writes to
    other addresses, and ignore low-byte-only writes (we_hi deasserted).

    Run:
      iverilog -g2012 -Wall -o /tmp/tb_sftm_prot.vvp \
          cores/sftm/ver/game/tb_sftm_prot.v cores/sftm/hdl/sftm_prot.v && \
      vvp /tmp/tb_sftm_prot.vvp
*/
`timescale 1ns/1ps

module tb_sftm_prot;
    localparam [13:0] PROT_WORD = 14'h3d35;   // 0x7a6a >> 1

    reg              clk, rst;
    reg  [13:0]      wr_addr;
    reg              we_hi;
    reg  [15:0]      din;
    wire [ 7:0]      result;

    integer          errors = 0;

    sftm_prot uut(
        .clk    ( clk     ),
        .rst    ( rst     ),
        .wr_addr( wr_addr ),
        .we_hi  ( we_hi   ),
        .din    ( din     ),
        .result ( result  )
    );

    // 100 MHz test clock
    initial clk = 1'b0;
    always #5 clk = ~clk;

    // One high-byte (UDS) write cycle at the given word address.
    task wr_hi(input [13:0] a, input [15:0] d);
    begin
        @(negedge clk);
        wr_addr = a;
        din     = d;
        we_hi   = 1'b1;
        @(posedge clk);             // sample write
        @(negedge clk);
        we_hi   = 1'b0;
    end
    endtask

    // A write with we_hi deasserted (models a low-byte-only / LDS access).
    task wr_none(input [13:0] a, input [15:0] d);
    begin
        @(negedge clk);
        wr_addr = a;
        din     = d;
        we_hi   = 1'b0;
        @(posedge clk);
        @(negedge clk);
    end
    endtask

    task check(input [7:0] got, input [7:0] exp, input [255:0] name);
    begin
        if( got !== exp ) begin
            $display("FAIL: %0s got=%02h exp=%02h", name, got, exp);
            errors = errors + 1;
        end else begin
            $display("ok  : %0s = %02h", name, got);
        end
    end
    endtask

    initial begin
        wr_addr = 0;
        din     = 0;
        we_hi   = 0;

        // reset clears the latch
        rst = 1'b1;
        @(negedge clk);
        @(negedge clk);
        rst = 1'b0;
        check(result, 8'h00, "reset clears byte");

        // 1) high-byte write at the protection address is captured
        wr_hi(PROT_WORD, 16'hA55A);
        check(result, 8'hA5, "capture @prot");

        // 2) high-byte write elsewhere must not change it
        wr_hi(14'h0123, 16'h1234);
        check(result, 8'hA5, "other addr ignored");

        // 3) low-byte-only access at the protection address must not change it
        wr_none(PROT_WORD, 16'hFF3C);
        check(result, 8'hA5, "low-byte-only ignored");

        // 4) a new high-byte write updates the captured value
        wr_hi(PROT_WORD, 16'h5678);
        check(result, 8'h56, "recapture @prot");

        if( errors == 0 )
            $display("PASS: sftm_prot protection byte");
        else
            $display("FAIL: sftm_prot (%0d errors)", errors);
        $finish;
    end
endmodule
