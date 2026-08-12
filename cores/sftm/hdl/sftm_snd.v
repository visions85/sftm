`timescale 1ns/1ps
/*  This file is part of SFTM.
    SFTM is free software: you can redistribute it and/or modify it under the
    terms of the GNU General Public License as published by the Free Software
    Foundation, either version 3 of the License, or (at your option) any later
    version. See the LICENSE file.

    Street Fighter: The Movie -- sound board. PHASE 3 IS NOT DONE YET.

    Target (literal port of MAME): MC6809 @ 2 MHz running sound_020_map
    (itech32.cpp:1079: soundlatch reads at 0x0000/0x0400, ES5506 at
    0x0800-0x083f, sound_bank_w at 0x0c00, firq_clear at 0x1400,
    sound_data_buffer_r at 0x1800, RAM 0x2000-0x3fff, banked ROM 0x4000-0x7fff,
    fixed ROM 0x8000-0xffff) plus the ES5506 engine (doc/mame-src/es5506.cpp).

    This stub consumes nothing and outputs silence. The command latches live
    in sftm_main (they are main-CPU state); the latch read strobes below will
    come from the 6809's reads of 0x0000/0x0400 in Phase 3. They are held low
    here, so snd_pending1 stays set after the first sound command -- which
    keeps special_port_r toggling on the main side, matching MAME's behavior
    while the sound CPU is busy. Revisit if the game ever waits for the
    latch to drain.
*/

module sftm_snd(
    input             rst,
    input             clk,
    input             cen,         // 2 MHz (6809 E)
    input             es_cen,      // 16 MHz (ES5506)

    // 6809 program ROM (SDRAM bank 0)
    output     [17:0] rom_addr,
    input      [ 7:0] rom_data,
    output            rom_cs,
    input             rom_ok,

    // ES5506 sample ROM (SDRAM bank 1)
    output     [21:1] srom_addr,
    input      [15:0] srom_data,
    output            srom_cs,
    input             srom_ok,

    // command latches (owned by sftm_main)
    input      [ 7:0] snd_latch1,
    input      [ 7:0] snd_latch2,
    input             snd_pending1,
    input             snd_pending2,
    output            snd_latch1_rd,
    output            snd_latch2_rd,

    output signed [15:0] snd_left,
    output signed [15:0] snd_right,
    output               sample
);

assign rom_addr      = 18'd0;
assign rom_cs        = 1'b0;
assign srom_addr     = {21{1'b0}};
assign srom_cs       = 1'b0;
assign snd_latch1_rd = 1'b0;
assign snd_latch2_rd = 1'b0;
assign snd_left      = 16'd0;
assign snd_right     = 16'd0;
assign sample        = 1'b0;

// verilator lint_off UNUSEDSIGNAL
wire unused = &{ rst, clk, cen, es_cen, rom_data, rom_ok, srom_data, srom_ok,
                 snd_latch1, snd_latch2, snd_pending1, snd_pending2, 1'b0 };
// verilator lint_on UNUSEDSIGNAL

endmodule
