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

// DIP switches. sftm reads DIPS as a 32-bit port whose payload MAME places
// at bits 16-23 (itech32.cpp:1043, `m_dips->read() << 16`), so dipsw_a here
// is literally MAME's m_dips->read() byte. The MRA declares the four SW1
// switches at dipsw bits 20-23 with default "ff,ff,0f", which makes this
// byte 0x0F at power-on -- the exact value a MAME reference run returns.
// Taking dipsw[7:0] instead yielded 0xFF and hung the boot task: 0x802384
// spins on `btst.b #6,$280001` (SW1:3), yielding to the scheduler forever,
// which is why the palette at 0x82A5F0 was never reached.
wire [7:0] dipsw_a;
assign dipsw_a = dipsw[23:16];

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
wire [ 7:0] dbg_eswr, dbg_sromn, dbg_sromd, dbg_cr0, dbg_crn, dbg_crv;
wire [ 6:0] dbg_crp;
wire [ 4:0] dbg_actv;
wire        dbg_anyrun;
wire [15:0] dbg_peak;
wire [ 3:0] dbg_bbusy, dbg_bwait, dbg_bwr, dbg_bgf, dbg_bnum;
wire [14:0] dbg_gpen;
wire        dbg_gseen, dbg_gmulti, dbg_palhit;
wire [ 3:0] dbg_gcnt;
wire [ 7:0] dbg_palcnt;

sftm_main u_main(
    .rst          ( rst           ),
    .clk          ( clk           ),
    .cen          ( e020_cen      ),

    .rom_addr     ( main_addr     ),
    .rom_data     ( main_data     ),
    .rom_cs       ( main_rd       ),
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
    .dbg_eswr     ( dbg_eswr      ),
    .dbg_peak     ( dbg_peak      ),
    .dbg_sromn    ( dbg_sromn     ),
    .dbg_sromd    ( dbg_sromd     ),
    .dbg_actv     ( dbg_actv      ),
    .dbg_cmdw     ( cmd_wcnt      ),
    .dbg_cmdr     ( cmd_rcnt      ),
    .dbg_bbusy    ( dbg_bbusy     ),
    .dbg_bwait    ( dbg_bwait     ),
    .dbg_bwr      ( dbg_bwr       ),
    .dbg_bgf      ( dbg_bgf       ),
    .dbg_bnum     ( dbg_bnum      ),
    .dbg_gpen     ( dbg_gpen      ),
    .dbg_gseen    ( dbg_gseen     ),
    .dbg_gcnt     ( dbg_gcnt      ),
    .dbg_gmulti   ( dbg_gmulti    ),
    .dbg_palhit   ( dbg_palhit    ),
    .dbg_palcnt   ( dbg_palcnt    ),
    .dbg_anyrun   ( dbg_anyrun    ),
    .dbg_cr0      ( dbg_cr0       ),
    .dbg_crn      ( dbg_crn       ),
    .dbg_crv      ( dbg_crv       ),
    .dbg_crp      ( dbg_crp       ),
    .ioctl_addr   ( ioctl_addr    ),
    .ioctl_ram    ( ioctl_ram     ),
    .ioctl_wr     ( ioctl_wr      ),
    .ioctl_dout   ( ioctl_dout    ),
    .ioctl_din    ( ioctl_din     ),

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

    .grom0_addr   ( grom0_addr    ),
    .grom0_data   ( grom0_data    ),
    .grom0_rd     ( grom0_rd      ),
    .grom0_ok     ( grom0_ok      ),
    .grom1_addr   ( grom1_addr    ),
    .grom1_data   ( grom1_data    ),
    .grom1_rd     ( grom1_rd      ),
    .grom1_ok     ( grom1_ok      ),
    .grm3_addr    ( grm3_addr     ),
    .grm3_data    ( grm3_data     ),
    .grm3_rd      ( grm3_rd       ),
    .grm3_ok      ( grm3_ok       ),

    // VRAM SDRAM bus (mem.yaml `vram`, bank 3; ports appear in
    // mem_ports.inc after `jtframe mem` regeneration -- Phase 4)
    .vram_addr    ( vram_addr     ),
    .vram_data    ( vram_data     ),
    .vram_din     ( vram_din      ),
    .vram_dsn     ( vram_dsn      ),
    .vram_we      ( vram_we       ),
    .vram_rd      ( vram_rd       ),
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
    .st_bbusy     ( dbg_bbusy     ),
    .st_bwait     ( dbg_bwait     ),
    .st_bwr       ( dbg_bwr       ),
    .st_bgf       ( dbg_bgf       ),
    .st_bnum      ( dbg_bnum      ),
    .st_gpen      ( dbg_gpen      ),
    .st_gseen     ( dbg_gseen     ),
    .st_gcnt      ( dbg_gcnt      ),
    .st_gmulti    ( dbg_gmulti    ),
    .st_palhit    ( dbg_palhit    ),
    .st_palcnt    ( dbg_palcnt    ),
    .debug_bus    ( debug_bus     )

);

sftm_snd u_snd(
    .rst          ( rst           ),
    .clk          ( clk           ),
    .cen          ( snd_cen       ),
    .es_cen       ( es_cen        ),

    .rom_addr     ( snd_addr      ),
    .rom_data     ( snd_data      ),
    .rom_cs       ( snd_rd        ),
    .rom_ok       ( snd_ok        ),

    .srom_addr    ( srom_addr     ),
    .srom_data    ( srom_data     ),
    .srom_rd      ( srom_rd       ),
    .srom_ok      ( srom_ok       ),

    .snd_latch1   ( snd_latch1    ),
    .snd_latch2   ( snd_latch2    ),
    .snd_pending1 ( snd_pending1  ),
    .snd_pending2 ( snd_pending2  ),
    .snd_latch1_rd( snd_latch1_rd ),
    .snd_latch2_rd( snd_latch2_rd ),

    .snd_left     ( snd_left      ),
    .snd_right    ( snd_right     ),
    .sample       ( sample        ),
    .st_eswr      ( dbg_eswr      ),
    .st_peak      ( dbg_peak      ),
    .st_sromn     ( dbg_sromn     ),
    .st_sromd     ( dbg_sromd     ),
    .st_actv      ( dbg_actv      ),
    .st_anyrun    ( dbg_anyrun    ),
    .st_cr0       ( dbg_cr0       ),
    .st_crn       ( dbg_crn       ),
    .st_crv       ( dbg_crv       ),
    .st_crp       ( dbg_crp       )
);

// ---------------------------------------------------------------------------
// Sound command handshake. Hardware says the 6809 boots, completes its ES5506
// init and sets ACTV, but never clears a voice's STOP bits -- so it is idle,
// waiting for a command. The main CPU does write the latch (sf_snd_wr is set
// in the video debug view), so count both ends: writes by the 68020 and reads
// by the 6809. Writes without reads means the IRQ/read path is broken; both
// nonzero means commands flow and the driver is declining to play.
// ---------------------------------------------------------------------------
reg [7:0] cmd_wcnt, cmd_rcnt;
reg       pend_d;
always @(posedge clk) begin
    if( rst ) begin
        cmd_wcnt <= 8'd0; cmd_rcnt <= 8'd0; pend_d <= 1'b0;
    end else begin
        pend_d <= snd_pending1;
        if( snd_pending1 && !pend_d && cmd_wcnt != 8'hFF ) cmd_wcnt <= cmd_wcnt + 8'd1;
        if( snd_latch1_rd          && cmd_rcnt != 8'hFF ) cmd_rcnt <= cmd_rcnt + 8'd1;
    end
end

// OSD debug view: main CPU status ({boot_done, vint, blit, scan, state, wdog})
assign debug_view = st_main;

// verilator lint_off UNUSEDSIGNAL
wire unused = &{ cpu_rnw, 1'b0 };
// verilator lint_on UNUSEDSIGNAL

endmodule
