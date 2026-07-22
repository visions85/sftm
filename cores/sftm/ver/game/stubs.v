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

module mc6809i
#( parameter ILLEGAL_INSTRUCTIONS="GHOST" )
(
    input         clk,
    input         cen_E,
    input         cen_Q,
    input         nRESET,
    output        RnW,
    output [15:0] ADDR,
    input  [ 7:0] D,
    output [ 7:0] DOut,
    input         nIRQ,
    input         nFIRQ,
    input         nNMI,
    input         nHALT,
    input         nDMABREQ,
    output        BS,
    output        BA,
    output        AVMA,
    output        BUSY,
    output        LIC,
    output reg    OP,
    output [111:0] RegData
);
    assign RnW=1, ADDR=16'hffff, DOut=8'h00;
    assign BS=0, BA=0, AVMA=0, BUSY=0, LIC=0, OP=0, RegData=0;
endmodule
