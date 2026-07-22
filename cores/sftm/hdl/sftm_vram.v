`timescale 1ns/1ps
/*  This file is part of SFTM.  GPLv3 - see LICENSE.

    One VRAM plane: 8-bit indexed pixels, one write port (blitter/CPU) and one
    read port (scanout). Inferred simple dual-port BRAM.
*/
module sftm_vram #(parameter AW=17)(
    input               clk,
    input               we,
    input      [AW-1:0]  waddr,
    input      [ 7:0]    wdata,
    input      [AW-1:0]  raddr,
    output reg [ 7:0]    rdata,
    input      [AW-1:0]  io_addr,
    output reg [ 7:0]    io_data
);
    reg [7:0] mem[0:(1<<AW)-1];
    always @(posedge clk) begin
        if( we ) mem[waddr] <= wdata;
        rdata <= mem[raddr];
        io_data <= mem[io_addr];
    end
endmodule
