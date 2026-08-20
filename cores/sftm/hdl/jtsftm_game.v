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
wire [3:0] dbg_bbusy, dbg_bwait, dbg_bwr, dbg_bgf, dbg_bstw, dbg_fper;
wire [19:0] stw_wr, stw_busy, stw_wait, stw_stw, stw_fper, stw_gf;
wire [ 7:0] stw_num;
wire [19:0] stw_vreg, stw_cmd, stw_xfer, stw_rd;
wire [3:0] dbg_bnum;
wire [14:0] dbg_gpen;
wire        dbg_gseen, dbg_gmulti, dbg_palhit;
wire [ 3:0] dbg_gcnt;
wire [ 7:0] dbg_palcnt;


// ---------------------------------------------------------------------------
// Per-lane liveness probe (cache-lanes bring-up)
//
// Build 62 cleared the main lane: cs, ok, a completed fetch and non-zero data
// were all present, so the 68020 runs and executes from ROM. It still fails to
// kick the watchdog, so it hangs downstream of instruction fetch. Under banks
// the same code runs, so one of the OTHER lanes has stopped answering.
//
// One nibble per lane: {ever requested, ever acked, stuck}. "Stuck" is a
// request held for more than 4096 clocks without an ack -- a lane that never
// answers freezes whatever waits on it, which is exactly how the CPU would
// stall after fetching fine.
//
//   requested=0            nothing ever asks for this lane -- not the culprit
//   requested=1, acked=0   the lane never answers: this is the one
//   requested=1, acked=1, stuck=1   it answers sometimes then wedges
// ---------------------------------------------------------------------------
wire [3:0] dbg_lsnd, dbg_lsrom, dbg_lgrm3, dbg_lgrom0, dbg_lgrom1, dbg_lvram;

// Quartus rejects the NM``_sig token-pasting idiom that iverilog accepts, so
// this is a small module instantiated once per lane rather than a macro.
// ---------------------------------------------------------------------------
// JTAG-controlled reset release, and a ROM-survival check.
//
// The SLD hub is only reachable when the FPGA is configured over JTAG from the
// .sof (see doc/PORTING.md). But JTAG configuration skips MiSTer's ROM
// download, so JTFRAME holds the game in reset and the CPU does nothing --
// which is why every blitter meter read exactly zero.
//
// force_run (ISSP source bit 0) releases the game from reset so it runs with
// whatever is already in SDRAM. The open question is whether the ROM survives
// reconfiguration: the SDRAM controller stops refreshing for the ~3 s a
// configure takes, which is far longer than DRAM retention, so it probably
// does NOT. m_first answers that directly rather than by assumption -- it
// latches the first longword the CPU fetches:
//
//   0x00008000 -> SDRAM kept the ROM; the game should run and be measurable
//   anything else -> the ROM decayed, and this route cannot work
// ---------------------------------------------------------------------------
wire [7:0] issp_src;
wire       force_run = issp_src[0];
wire       rst_g     = rst & ~force_run;

reg [31:0] m_first;
reg        m_got;
reg [15:0] m_cnt;
always @(posedge clk) begin
    if( rst ) begin
        m_first <= 32'd0; m_got <= 1'b0; m_cnt <= 16'd0;
    end else if( main_rd && main_ok ) begin
        if( !m_got ) begin m_first <= main_data; m_got <= 1'b1; end
        if( ~&m_cnt ) m_cnt <= m_cnt + 16'd1;
    end
end

sftm_laneprobe u_lp_snd  (.rst(rst),.clk(clk),.req(snd_rd  ),.ok(snd_ok  ),.st(dbg_lsnd  ));
sftm_laneprobe u_lp_srom (.rst(rst),.clk(clk),.req(srom_rd ),.ok(srom_ok ),.st(dbg_lsrom ));
sftm_laneprobe u_lp_grm3 (.rst(rst),.clk(clk),.req(grm3_rd ),.ok(grm3_ok ),.st(dbg_lgrm3 ));
sftm_laneprobe u_lp_grom0(.rst(rst),.clk(clk),.req(grom0_rd),.ok(grom0_ok),.st(dbg_lgrom0));
sftm_laneprobe u_lp_grom1(.rst(rst),.clk(clk),.req(grom1_rd),.ok(grom1_ok),.st(dbg_lgrom1));
sftm_laneprobe u_lp_vram (.rst(rst),.clk(clk),.req(vram_rd|vram_we),.ok(vram_ok),.st(dbg_lvram));

sftm_main u_main(
    .rst          ( rst_g         ),
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
    .dbg_bstw     ( dbg_bstw      ),
    .dbg_fper     ( dbg_fper      ),
    .dbg_bnum     ( dbg_bnum      ),
    .dbg_lsnd     ( dbg_lsnd      ),
    .dbg_lsrom    ( dbg_lsrom     ),
    .dbg_lgrm3    ( dbg_lgrm3     ),
    .dbg_lgrom0   ( dbg_lgrom0    ),
    .dbg_lgrom1   ( dbg_lgrom1    ),
    .dbg_lvram    ( dbg_lvram     ),
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
    .rst          ( rst_g         ),
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
    .st_bstw      ( dbg_bstw      ),
    .st_fper      ( dbg_fper      ),
    .stw_wr       ( stw_wr        ),
    .stw_busy     ( stw_busy      ),
    .stw_wait     ( stw_wait      ),
    .stw_stw      ( stw_stw       ),
    .stw_fper     ( stw_fper      ),
    .stw_gf       ( stw_gf        ),
    .stw_num      ( stw_num       ),
    .stw_vreg     ( stw_vreg      ),
    .stw_cmd      ( stw_cmd       ),
    .stw_xfer     ( stw_xfer      ),
    .stw_rd       ( stw_rd        ),
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
    .rst          ( rst_g         ),
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

// ---------------------------------------------------------------------------
// In-System Sources and Probes -- read the fabric directly over JTAG.
//
// The on-screen debug overlay has proven untrustworthy: three hardcoded
// constants placed on views 0, 7 and F never appeared, in any build, including
// one loaded directly onto the FPGA over JTAG. Every link in that chain
// verifies (source md5s, files.qip, Quartus warning line numbers, the pinned
// viewmux in the compiled volume) yet the byte on screen is a ~24/s counter.
//
// This bypasses the overlay entirely. `probe` is read with quartus_stp over
// the USB Blaster, no display and no screenshot decoding involved:
//
//     probe[ 7: 0]  st_main   -- the SAME byte the overlay claims to show
//     probe[15: 8]  8'hA5     -- signature
//     probe[23:16]  8'h5C     -- signature
//     probe[31:24]  8'h3C     -- signature
//
// The three signatures are the point. If they read back A5/5C/3C, the fabric
// is running THIS source and st_main is trustworthy -- which would mean the
// overlay rendering is at fault. If they read back anything else, the fabric
// is not running this bitstream and every measurement taken from it, in this
// session and earlier, is void for that reason.
// ---------------------------------------------------------------------------
// Every meter in ONE probe word, read atomically over JTAG.
//
// FULL RESOLUTION. The 4-bit meters are quantised (writes/8192, clk/65536)
// purely to fit the 8-bit on-screen overlay, and at that granularity a screen
// updating a few thousand pixels a frame reads 0 across the board -- which is
// exactly what made the blitter look completely idle while the attract demo
// was visibly animating. These are the raw per-frame counters.
//
// Reference points: one full background = 92,160 writes; a whole frame =
// 508*286*6 = 871,728 clk, which is also what stw_fper must read.
wire [127:0] issp_probe = {
    8'h3C,          // [127:120] signature
    4'd0,
    stw_num,        // [115:108] blits started this frame
    stw_gf,         // [107: 88] blit_gdone pulses
    stw_fper,       // [ 87: 68] frame period, clk  (expect 871,728)
    stw_stw,        // [ 67: 48] write-FIFO stall, clk
    stw_wait,       // [ 47: 28] GROM fetch stall, clk
    stw_busy,       // [ 27:  8] blitter busy, clk
    8'hA5           // [  7:  0] signature
};

// probe1: the CPU's side of the video interface, plus the display base.
wire [127:0] issp_probe2 = {
    8'h5C,          // [127:120] signature
    8'd0,
    stw_wr,         // [111: 92] VRAM writes this frame, EXACT
    stw_rd,         // [ 91: 72] VRAM read strobes
    stw_xfer,       // [ 71: 52] TRANSFER writes (cmd-3 pixel pushes)
    stw_cmd,        // [ 51: 32] COMMAND writes (blit starts)
    stw_vreg,       // [ 31: 12] all CPU video-register writes
    12'h5A5         // [ 11:  0] signature
};

altsource_probe u_issp (
    .probe  ( issp_probe ),
    .source (            )
);
defparam
    u_issp.enable_metastability    = "NO",
    u_issp.instance_id             = "SFTM",
    u_issp.probe_width             = 128,
    u_issp.sld_auto_instance_index = "YES",
    u_issp.sld_instance_index      = 0,
    u_issp.source_initial_value    = "0",
    u_issp.source_width            = 0;

altsource_probe u_issp2 (
    .probe  ( issp_probe2 ),
    .source (             )
);
defparam
    u_issp2.enable_metastability    = "NO",
    u_issp2.instance_id             = "SFWR",
    u_issp2.probe_width             = 128,
    u_issp2.sld_auto_instance_index = "YES",
    u_issp2.sld_instance_index      = 1,
    u_issp2.source_initial_value    = "0",
    u_issp2.source_width            = 0;

// ROM-survival probe + the source that releases reset.
wire [63:0] issp_probe3 = {
    8'h7E,          // [63:56] signature
    7'd0,
    force_run,      // [   48] echo of the source bit
    m_got,          // [   47] a main fetch has completed
    m_cnt[14:0],    // [46:32] completed main fetches (saturating)
    m_first         // [31: 0] FIRST longword the CPU fetched (want 0x00008000)
};

altsource_probe u_issp3 (
    .probe  ( issp_probe3 ),
    .source ( issp_src    )
);
defparam
    u_issp3.enable_metastability    = "NO",
    u_issp3.instance_id             = "SFRN",
    u_issp3.probe_width             = 64,
    u_issp3.sld_auto_instance_index = "YES",
    u_issp3.sld_instance_index      = 2,
    u_issp3.source_initial_value    = "0",
    u_issp3.source_width            = 8;



// verilator lint_off UNUSEDSIGNAL
wire unused = &{ cpu_rnw, 1'b0 };
// verilator lint_on UNUSEDSIGNAL

endmodule

// ---------------------------------------------------------------------------
// One SDRAM lane's liveness: {ever requested, ever acked, stuck, -}.
// "Stuck" is a request held over 4096 clocks without an ack -- a lane that
// stops answering freezes whatever waits on it, which is how the CPU can fetch
// instructions correctly and still hang.
// ---------------------------------------------------------------------------
module sftm_laneprobe(
    input            rst,
    input            clk,
    input            req,
    input            ok,
    output reg [3:0] st
);

reg [12:0] wcnt;

always @(posedge clk) begin
    if( rst ) begin
        st <= 4'd0; wcnt <= 13'd0;
    end else begin
        if( req ) st[3] <= 1'b1;
        if( ok  ) st[2] <= 1'b1;
        if( req && !ok ) begin
            if( ~&wcnt ) wcnt <= wcnt + 13'd1;
            if( wcnt > 13'd4095 ) st[1] <= 1'b1;
        end else
            wcnt <= 13'd0;
    end
end

endmodule
