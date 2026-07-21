/*  This file is part of JTSFTM.  GPLv3 - see LICENSE.

    Street Fighter: The Movie protection stand-in.

    The itech32 020 board carries a security PIC. MAME does not emulate it;
    instead itech020_prot_result_r() returns the main-RAM byte at a fixed,
    per-game address (m_itech020_prot_address). The game's own protection
    routine writes the value it expects into that RAM location and then reads it
    back through the 0x680002 port, so echoing the byte back is enough to pass
    the check.

    For the parent sftm set the address is 0x7a6a (init_sftm ->
    init_sftm_common(0x7a6a) in src/mame/itech/itech32.cpp). 0x7a6a is an even
    byte address, i.e. the high / UDS byte of 16-bit main-RAM word 0x3d35.

    This module snoops CPU byte writes into main RAM and latches the byte at
    that address; jtsftm_main presents it on D[15:8] when 0x680002 is read.
*/
module jtsftm_prot(
    input               clk,
    input               rst,
    input      [13:0]   wr_addr,    // main RAM word address (cpu_a[14:1])
    input               we_hi,      // high byte (UDS / D[15:8]) write strobe
    input      [15:0]   din,        // CPU write data
    output     [ 7:0]   result      // protection byte
);
    localparam [13:0] PROT_WORD = 14'h3d35;   // 0x7a6a >> 1 (even => high byte)

    reg [7:0] pbyte;

    always @(posedge clk) begin
        if( rst )                              pbyte <= 8'd0;
        else if( wr_addr==PROT_WORD && we_hi ) pbyte <= din[15:8];
    end

    assign result = pbyte;
endmodule
