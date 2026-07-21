/*  This file is part of JTSFTM.  GPLv3 - see LICENSE.

    Palette RAM helper. The original hardware has 15-bit colour (5:5:5) and
    MAME models it as 8192 pens for most itech32 games. Some older boards use
    96 KB palette RAM; SFTM/020 uses the later palette path.
*/
module jtsftm_pal(
    input               clk,
    input       [12:0]  cpu_addr,
    input       [15:0]  cpu_dout,
    input               cpu_we,
    output reg  [15:0]  cpu_q,
    input       [16:0]  rd_idx,
    output      [14:0]  rd_rgb
);
    reg [14:0] mem[0:8191];
    wire [12:0] rd_addr = rd_idx[12:0];

    always @(posedge clk) begin
        if( cpu_we ) mem[cpu_addr] <= cpu_dout[14:0];
        cpu_q <= {1'b0, mem[cpu_addr]};
    end

    assign rd_rgb = mem[rd_addr];
endmodule
