`timescale 1ns/1ps
/*  This file is part of SFTM.
    SFTM is free software: you can redistribute it and/or modify it under the
    terms of the GNU General Public License as published by the Free Software
    Foundation, either version 3 of the License, or (at your option) any later
    version. See the LICENSE file.

    Street Fighter: The Movie (Incredible Technologies itech32) - game top.

    Clocks (see hdl/mem.yaml):
        clk        48 MHz reference (clk_rom)
        e020_cen   ~25 MHz   68EC020
        snd_cen     2 MHz    MC6809
        es_cen     16 MHz    ES5506
        pxl_cen    ~8 MHz    pixel clock (HTOTAL 508 * VTOTAL 262 * 59.76Hz)
*/

module jtsftm_game(
    // jtframe_game_ports.inc includes jtframe_common_ports.inc + mem_ports.inc
    // (mem_ports.inc is chosen when JTFRAME_MEMGEN is set by jtframe mem/files)
    `include "jtframe_game_ports.inc"
);

/* verilator lint_off WIDTH */

// ---------------------------------------------------------------------------
// DIP switches: itech32 has 2x DSW(4) banks on the 1083 board.
// ---------------------------------------------------------------------------
wire [7:0] dipsw_a, dipsw_b;
assign { dipsw_b, dipsw_a } = dipsw[15:0];

// ---------------------------------------------------------------------------
// CPU <-> video/blitter/palette bus
// ---------------------------------------------------------------------------
wire [23:1] cpu_addr;
wire [15:0] cpu_dout;
wire [15:0] vram_dout, pal_dout, vreg_dout;
wire        cpu_rnw;
wire        cpu_uds_n, cpu_lds_n;
wire        vram_cs, pal_cs, vreg_cs;   // decoded selects to the video block
wire [ 1:0] plane_en;                   // foreground/background enable latch
wire [ 1:0] grom_bank;                  // high GROM address bank latch
wire [ 6:0] color_latch0;               // foreground palette bank
wire [ 6:0] color_latch1;               // background palette bank

// interrupts
wire        blit_irq, scan_irq, vblank_irq;

// ---------------------------------------------------------------------------
// Sound: main->sound command latch + ES5506 stereo mix
// ---------------------------------------------------------------------------
wire [ 7:0] snd_latch;
wire        snd_latch_we;
wire        snd_irq;                    // ES5506 IRQ -> 6809
wire [15:0] snd_left, snd_right;        // ES5506 stereo PCM

// ---------------------------------------------------------------------------
// Main CPU subsystem (68EC020 via TG68K.C in 020 mode)
// ---------------------------------------------------------------------------
sftm_main u_main(
    .rst        ( rst           ),
    .clk        ( clk           ),
    .cen        ( e020_cen      ),
    // program ROM (32-bit) in SDRAM bank 0 ("main" bus in mem.yaml)
    .rom_addr   ( main_addr     ),
    .rom_data   ( main_data     ),
    .rom_cs     ( main_cs       ),
    .rom_ok     ( main_ok       ),
    // cabinet
    .joystick1  ( joystick1     ),
    .joystick2  ( joystick2     ),
    .cab_1p     ( cab_1p        ),
    .coin       ( coin          ),
    .service    ( service       ),
    .dip_test   ( dip_test      ),
    .dipsw_a    ( dipsw_a       ),
    .dipsw_b    ( dipsw_b       ),
    // video / blitter / palette bus
    .cpu_addr   ( cpu_addr      ),
    .cpu_dout   ( cpu_dout      ),
    .cpu_rnw    ( cpu_rnw       ),
    .cpu_uds_n  ( cpu_uds_n     ),
    .cpu_lds_n  ( cpu_lds_n     ),
    .vram_cs    ( vram_cs       ),
    .vreg_cs    ( vreg_cs       ),
    .pal_cs     ( pal_cs        ),
    .vram_dout  ( vram_dout     ),
    .vreg_dout  ( vreg_dout     ),
    .pal_dout   ( pal_dout      ),
    .plane_en   ( plane_en      ),
    .grom_bank  ( grom_bank     ),
    .color_latch0(color_latch0  ),
    .color_latch1(color_latch1  ),
    // interrupts
    .blit_irq   ( blit_irq      ),
    .scan_irq   ( scan_irq      ),
    .vblank_irq ( vblank_irq    ),
    // sound latch
    .snd_latch  ( snd_latch     ),
    .snd_latch_we(snd_latch_we  ),
    // NVRAM is on-chip BRAM inside sftm_main (persistence deferred)
    .debug_bus  ( debug_bus     )
);

// ---------------------------------------------------------------------------
// Video: IT42 blitter + two VRAM planes + palette + scanout
// ---------------------------------------------------------------------------
sftm_video u_video(
    .rst        ( rst           ),
    .clk        ( clk           ),
    .pxl_cen    ( pxl_cen       ),
    .pxl2_cen   ( pxl2_cen      ),
    // CPU bus
    .cpu_addr   ( cpu_addr      ),
    .cpu_dout   ( cpu_dout      ),
    .cpu_rnw    ( cpu_rnw       ),
    .cpu_uds_n  ( cpu_uds_n     ),
    .cpu_lds_n  ( cpu_lds_n     ),
    .vram_cs    ( vram_cs       ),
    .vreg_cs    ( vreg_cs       ),
    .pal_cs     ( pal_cs        ),
    .vram_dout  ( vram_dout     ),
    .vreg_dout  ( vreg_dout     ),
    .pal_dout   ( pal_dout      ),
    .plane_en   ( plane_en      ),
    .grom_bank  ( grom_bank     ),
    .color_latch0(color_latch0  ),
    .color_latch1(color_latch1  ),
    // graphics ROM (blitter source) in SDRAM banks 2/3
    .grom_addr  ( grom_addr     ),
    .grom_data  ( grom_data     ),
    .grom_cs    ( grom_cs       ),
    .grom_ok    ( grom_ok       ),
    .grm3_addr  ( grm3_addr     ),
    .grm3_data  ( grm3_data     ),
    .grm3_cs    ( grm3_cs       ),
    .grm3_ok    ( grm3_ok       ),
    // interrupts back to CPU
    .blit_irq   ( blit_irq      ),
    .scan_irq   ( scan_irq      ),
    .vblank_irq ( vblank_irq    ),
    // video out
    .HS         ( HS            ),
    .VS         ( VS            ),
    .LHBL       ( LHBL          ),
    .LVBL       ( LVBL          ),
    .red        ( red           ),
    .green      ( green         ),
    .blue       ( blue          ),
    .gfx_en     ( gfx_en        ),
    .debug_bus  ( debug_bus     )
);

// ---------------------------------------------------------------------------
// Sound: MC6809 + ES5506 (OTTO)
// ---------------------------------------------------------------------------
sftm_snd u_snd(
    .rst        ( rst           ),
    .clk        ( clk           ),
    .cen        ( snd_cen       ),
    .es_cen     ( es_cen        ),
    // sound CPU ROM (bank 0)
    .rom_addr   ( snd_addr      ),
    .rom_data   ( snd_data      ),
    .rom_cs     ( snd_cs        ),
    .rom_ok     ( snd_ok        ),
    // ES5506 sample ROM (bank 1)
    .srom_addr  ( srom_addr     ),
    .srom_data  ( srom_data     ),
    .srom_cs    ( srom_cs       ),
    .srom_ok    ( srom_ok       ),
    // command latch from main CPU
    .snd_latch  ( snd_latch     ),
    .snd_latch_we(snd_latch_we  ),
    .snd_irq    ( snd_irq       ),
    // audio out (stereo)
    .snd_left   ( snd_left      ),
    .snd_right  ( snd_right     ),
    .sample     ( sample        )
);

/* verilator lint_on WIDTH */

// debug_view: show boot status and other CPU-side signals
assign debug_view = debug_bus;   // echo debug_bus for now (placeholder)

endmodule
