`timescale 1ns/1ps
/*  This file is part of SFTM.  GPLv3 - see LICENSE.

    Palette RAM helper. The original hardware has 15-bit colour (5:5:5) and
    SFTM/020 uses the later 32768-pen xRGB palette path.
*/
module sftm_pal(
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

    // Initialise entry 0 to bright cyan so the screen is non-black on the very
    // first frame.  VRAM defaults to 0x00 everywhere, so every pixel (fg=0,
    // bg=0) looks up palette[0].  The game will overwrite this during its own
    // palette init.  All other entries default to 0 (black) per Quartus BRAM
    // init-to-zero policy for unspecified locations.
    initial mem[0] = 15'h03FF;   // R=0 G=31 B=31  (bright cyan)

    always @(posedge clk) begin
        if( cpu_we ) mem[cpu_addr] <= cpu_dout[14:0];
        cpu_q <= {1'b0, mem[cpu_addr]};
    end

    assign rd_rgb = mem[rd_addr];
endmodule
