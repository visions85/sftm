`timescale 1ns/1ps
/*  This file is part of JTSFTM.  GPLv3 - see LICENSE.

    Palette RAM helper. The original hardware has 15-bit colour (5:5:5) and
    SFTM/020 uses the later 32768-pen xRGB palette path.
*/
module jtsftm_pal(
    input               clk,
    input       [14:0]  cpu_addr,
    input       [15:0]  cpu_dout,
    input               cpu_we,
    output reg  [15:0]  cpu_q,
    input       [14:0]  rd_idx,
    output      [14:0]  rd_rgb
);
    reg [14:0] mem[0:32767];
    wire [14:0] rd_addr = rd_idx;

    always @(posedge clk) begin
        if( cpu_we ) mem[cpu_addr] <= cpu_dout[14:0];
        cpu_q <= {1'b0, mem[cpu_addr]};
    end

    assign rd_rgb = mem[rd_addr];
endmodule
