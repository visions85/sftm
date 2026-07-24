`timescale 1ns/1ps
/*  This file is part of SFTM.  GPLv3 - see LICENSE.

    Generic synchronous work-RAM with a 16-bit word bus and independent high /
    low byte write enables, matching the MC68EC020's UDS/LDS byte strobes.

    Inferred single-port BRAM with registered read data (1-cycle latency),
    following the same style as sftm_vram / sftm_pal. One access per clock;
    the itech32 CPU never reads and writes the same RAM in the same cycle.
*/
// INIT_FILE_HI / INIT_FILE_LO: optional $readmemh files to pre-load the
// byte lanes at power-on.  Used for the NVRAM instance so the game boots
// with valid bookkeeping data and skips the factory-reset path.
// Leave as empty strings (default) for normal uninitialised RAM.
module sftm_ram #(parameter AW=14,
                  parameter INIT_FILE_HI="",
                  parameter INIT_FILE_LO="")(
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

    // Pre-load from files when provided (simulation and Quartus BRAM init).
    initial begin
        if (INIT_FILE_HI != "") $readmemh(INIT_FILE_HI, mem_hi);
        if (INIT_FILE_LO != "") $readmemh(INIT_FILE_LO, mem_lo);
    end

    always @(posedge clk) begin
        if( we_lo ) mem_lo[addr] <= din[ 7:0];
        if( we_hi ) mem_hi[addr] <= din[15:8];
        dout <= { mem_hi[addr], mem_lo[addr] };
    end
endmodule
