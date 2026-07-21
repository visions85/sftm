/*  This file is part of JTSFTM.  GPLv3 - see LICENSE.

    Generic synchronous work-RAM with a 16-bit word bus and independent high /
    low byte write enables, matching the MC68EC020's UDS/LDS byte strobes.

    Inferred single-port BRAM with registered read data (1-cycle latency),
    following the same style as jtsftm_vram / jtsftm_pal. One access per clock;
    the itech32 CPU never reads and writes the same RAM in the same cycle.
*/
module jtsftm_ram #(parameter AW=14)(
    input               clk,
    input      [AW-1:0] addr,       // word address
    input      [15:0]   din,
    input               we_lo,      // write low  byte (LDS / D[7:0])
    input               we_hi,      // write high byte (UDS / D[15:8])
    output reg [15:0]   dout
);
    // Split byte lanes so UDS/LDS can be written independently.
    reg [7:0] mem_lo[0:(1<<AW)-1];
    reg [7:0] mem_hi[0:(1<<AW)-1];

    always @(posedge clk) begin
        if( we_lo ) mem_lo[addr] <= din[ 7:0];
        if( we_hi ) mem_hi[addr] <= din[15:8];
        dout <= { mem_hi[addr], mem_lo[addr] };
    end
endmodule
