`timescale 1ns/1ps
/*  This file is part of SFTM.
    SFTM is free software: you can redistribute it and/or modify it under the
    terms of the GNU General Public License as published by the Free Software
    Foundation, either version 3 of the License, or (at your option) any later
    version. See the LICENSE file.

    Street Fighter: The Movie (Incredible Technologies itech32) - game top.
    Literal port of MAME itech32.cpp / itech32_v.cpp / es5506.cpp; see
    doc/PORTING.md for the module map and porting rules.

    Clocks (see cfg/mem.yaml):
        clk        48 MHz reference (clk_rom)
        e020_cen   25 MHz    68EC020
        snd_cen     2 MHz    MC6809
        es_cen     16 MHz    ES5506
        pxl_cen     8 MHz    pixel clock (JTFRAME_PXLCLK=8)
*/

module jtsftm_game(
    `include "jtframe_game_ports.inc"
);

// DIP switches: SW1(4) on the mainboard; DIPS port bits 20-23
wire [7:0] dipsw_a;
assign dipsw_a = dipsw[7:0];

// CPU <-> video bus
wire [23:1] cpu_addr;
wire [15:0] cpu_dout;
wire [15:0] vreg_dout, pal_dout;
wire        cpu_rnw, cpu_uds_n, cpu_lds_n, bus_wstb, vid_wait;
wire        vreg_cs, pal_cs;
wire [ 1:0] plane_en, grom_bank;
wire [ 6:0] color_latch0, color_latch1;

// interrupts
wire        blit_irq, scan_irq, vblank_irq;

// sound command latches
wire [ 7:0] snd_latch1, snd_latch2;
wire        snd_pending1, snd_pending2;
wire        snd_latch1_rd, snd_latch2_rd;

wire [ 7:0] st_main;

sftm_main u_main(
    .rst          ( rst           ),
    .clk          ( clk           ),
    .cen          ( e020_cen      ),

    .rom_addr     ( main_addr     ),
    .rom_data     ( main_data     ),
    .rom_cs       ( main_cs       ),
    .rom_ok       ( main_ok       ),

    .joystick1    ( joystick1     ),
    .joystick2    ( joystick2     ),
    .cab_1p       ( cab_1p        ),
    .coin         ( coin          ),
    .service      ( service       ),
    .dip_test     ( dip_test      ),
    .dipsw_a      ( dipsw_a       ),

    .cpu_addr     ( cpu_addr      ),
    .cpu_dout     ( cpu_dout      ),
    .cpu_rnw      ( cpu_rnw       ),
    .cpu_uds_n    ( cpu_uds_n     ),
    .cpu_lds_n    ( cpu_lds_n     ),
    .bus_wstb     ( bus_wstb      ),
    .vreg_cs      ( vreg_cs       ),
    .pal_cs       ( pal_cs        ),
    .vreg_dout    ( vreg_dout     ),
    .pal_dout     ( pal_dout      ),
    .vid_wait     ( vid_wait      ),

    .plane_en     ( plane_en      ),
    .grom_bank    ( grom_bank     ),
    .color_latch0 ( color_latch0  ),
    .color_latch1 ( color_latch1  ),

    .vblank_irq   ( vblank_irq    ),
    .blit_irq     ( blit_irq      ),
    .scan_irq     ( scan_irq      ),
    .LVBL         ( LVBL          ),

    .snd_latch1   ( snd_latch1    ),
    .snd_latch2   ( snd_latch2    ),
    .snd_pending1 ( snd_pending1  ),
    .snd_pending2 ( snd_pending2  ),
    .snd_latch1_rd( snd_latch1_rd ),
    .snd_latch2_rd( snd_latch2_rd ),

    .debug_bus    ( debug_bus     ),
    .st_dout      ( st_main       )
);

sftm_video u_video(
    .rst          ( rst           ),
    .clk          ( clk           ),
    .pxl_cen      ( pxl_cen       ),

    .cpu_addr     ( cpu_addr      ),
    .cpu_dout     ( cpu_dout      ),
    .cpu_uds_n    ( cpu_uds_n     ),
    .cpu_lds_n    ( cpu_lds_n     ),
    .bus_wstb     ( bus_wstb      ),
    .vreg_cs      ( vreg_cs       ),
    .pal_cs       ( pal_cs        ),
    .vreg_dout    ( vreg_dout     ),
    .pal_dout     ( pal_dout      ),
    .cpu_wait     ( vid_wait      ),

    .plane_en     ( plane_en      ),
    .grom_bank    ( grom_bank     ),
    .color_latch0 ( color_latch0  ),
    .color_latch1 ( color_latch1  ),

    .grom_addr    ( grom_addr     ),
    .grom_data    ( grom_data     ),
    .grom_cs      ( grom_cs       ),
    .grom_ok      ( grom_ok       ),
    .grm3_addr    ( grm3_addr     ),
    .grm3_data    ( grm3_data     ),
    .grm3_cs      ( grm3_cs       ),
    .grm3_ok      ( grm3_ok       ),

    // VRAM SDRAM bus (mem.yaml `vram`, bank 3; ports appear in
    // mem_ports.inc after `jtframe mem` regeneration -- Phase 4)
    .vram_addr    ( vram_addr     ),
    .vram_data    ( vram_data     ),
    .vram_din     ( vram_din      ),
    .vram_dsn     ( vram_dsn      ),
    .vram_we      ( vram_we       ),
    .vram_cs      ( vram_cs       ),
    .vram_ok      ( vram_ok       ),

    .vblank_irq   ( vblank_irq    ),
    .blit_irq     ( blit_irq      ),
    .scan_irq     ( scan_irq      ),

    .HS           ( HS            ),
    .VS           ( VS            ),
    .LHBL         ( LHBL          ),
    .LVBL         ( LVBL          ),
    .red          ( red           ),
    .green        ( green         ),
    .blue         ( blue          ),
    .gfx_en       ( gfx_en        ),
    .debug_bus    ( debug_bus     )
);

sftm_snd u_snd(
    .rst          ( rst           ),
    .clk          ( clk           ),
    .cen          ( snd_cen       ),
    .es_cen       ( es_cen        ),

    .rom_addr     ( snd_addr      ),
    .rom_data     ( snd_data      ),
    .rom_cs       ( snd_cs        ),
    .rom_ok       ( snd_ok        ),

    .srom_addr    ( srom_addr     ),
    .srom_data    ( srom_data     ),
    .srom_cs      ( srom_cs       ),
    .srom_ok      ( srom_ok       ),

    .snd_latch1   ( snd_latch1    ),
    .snd_latch2   ( snd_latch2    ),
    .snd_pending1 ( snd_pending1  ),
    .snd_pending2 ( snd_pending2  ),
    .snd_latch1_rd( snd_latch1_rd ),
    .snd_latch2_rd( snd_latch2_rd ),

    .snd_left     ( snd_left      ),
    .snd_right    ( snd_right     ),
    .sample       ( sample        )
);

// OSD debug view: main CPU status ({boot_done, vint, blit, scan, state, wdog})
assign debug_view = st_main;

// verilator lint_off UNUSEDSIGNAL
wire unused = &{ cpu_rnw, 1'b0 };
// verilator lint_on UNUSEDSIGNAL

endmodule
