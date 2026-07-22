/*  This file is part of SFTM.  GPLv3 - see LICENSE.

    SIMULATION/LINT-ONLY black-box stubs for the vendored CPUs. These are NOT
    the real cores; they only expose matching port names so the surrounding
    RTL can be elaborated for syntax checking before JTFRAME/TG68K.C are
    vendored. Do not synthesize with these.
*/
`timescale 1ns/1ps

module TG68KdotC_Kernel #(
    parameter SR_Read=2, VBR_Stackframe=2, extAddr_Mode=2,
              MUL_Mode=2, DIV_Mode=2, BitField=2,
              BarrelShifter=2, MUL_Hardware=1
)(
    input  [1:0]  CPU,
    input         clk,
    input         nReset,
    input         clkena_in,
    input  [15:0] data_in,
    input  [2:0]  IPL,
    input         IPL_autovector,
    output [31:0] addr_out,
    input         berr,
    output [15:0] data_write,
    output [1:0]  busstate,
    output        nWr,
    output        nUDS,
    output        nLDS,
    output        nResetOut,
    output        skipFetch
);
    assign addr_out=0, data_write=0, busstate=2'b01,
           nWr=1, nUDS=1, nLDS=1, nResetOut=1, skipFetch=0;
endmodule

module mc6809i(
    input         clk,
    input         cen,
    input         rst,
    output        rw,
    output [15:0] addr,
    input  [ 7:0] datai,
    output [ 7:0] datao,
    input         irq,
    input         firq,
    input         nmi
);
    assign rw=1, addr=16'hffff, datao=8'h00;
endmodule
