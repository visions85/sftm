/*  This file is part of JTSFTM.  GPLv3 - see LICENSE.

    One VRAM plane: 8-bit indexed pixels, one write port (blitter/CPU) and one
    read port (scanout). Inferred simple dual-port BRAM.
*/
module jtsftm_vram #(parameter AW=17)(
    input               clk,
    input               we,
    input      [AW-1:0]  waddr,
    input      [ 7:0]    wdata,
    input      [AW-1:0]  raddr,
    output reg [ 7:0]    rdata
);
    reg [7:0] mem[0:(1<<AW)-1];
    always @(posedge clk) begin
        if( we ) mem[waddr] <= wdata;
        rdata <= mem[raddr];
    end
endmodule
