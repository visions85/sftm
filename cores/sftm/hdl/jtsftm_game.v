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
// Pixel cens, game-generated (JTFRAME_PXLCLK removed): 16 MHz and 8 MHz
// from the 48 MHz game clock. Under JTFRAME_SDRAM96 the wrapper feeds clk48
// into this module's clk port, so these tick in the same domain as every
// consumer, and the frame's video pipeline locks to the HS/VS outputs.
reg [2:0] pxldiv = 3'd0;
always @(posedge clk) pxldiv <= pxldiv == 3'd5 ? 3'd0 : pxldiv + 3'd1;
assign pxl2_cen = pxldiv == 3'd0 || pxldiv == 3'd3;
assign pxl_cen  = pxldiv == 3'd0;

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
// Hang hunt. The CPU does its init burst (~102 vreg writes, 2 blits) and then
// nothing, on a ~watchdog cadence -- it is stuck waiting for something. This
// samples WHERE.
//
// pc_live changes every instruction, far too fast for an asynchronous ISSP
// read, so it is latched every 2^12 clk (~85 us): stable between latches, so
// a JTAG read almost never tears, and successive reads (~1 ms apart) give an
// unbiased sample of where the CPU spends its time. The modal addresses ARE
// the wait loop.
//
// Also: edge counts of the three video interrupts, and the live IPL/vint, so
// "interrupt never fires" and "interrupt fires but the CPU never takes it"
// are distinguishable at a glance.
// ---------------------------------------------------------------------------
wire [23:0] main_pc;
wire [15:0] main_op;
wire [23:0] main_lastrom, main_firstbad;
wire [31:0] main_vec_sp, main_vec_pc;
wire        main_derail;
wire [ 3:0] main_int;

// SFPC/SFDR probes RETIRED (build 112): the boot-era pc/opcode sampler and
// derail flight recorder earned their keep through b100 and stay in git for
// revival; their area buys the 128-bit vram lane. The meters (SFTM/SFWR),
// JTAG inputs/reset (SFRN), loader (SFLD) and sound triage (SFSN) remain.



// ---------------------------------------------------------------------------
// Sound triage (build 106). The cache core routes both the battery-screen
// timeout and a START press into the service menu -- MAME goes to attract --
// and the two menu actions that no-op (main EXIT, TEST ALL SOUND ROMS) are
// exactly the ones that need the sound CPU. This probe answers, in one read:
// is the 6809 fetching (lane probe), do latch commands flow both ways
// (cmd_wcnt/cmd_rcnt), did the ES5506 init (actv/cr counters), and does
// anything ever play (anyrun/peak).
// ---------------------------------------------------------------------------
wire [127:0] issp_probe6 = {
    8'h6E,              // [127:120] signature
    cmd_wcnt,           // [119:112] 68020 latch1 writes (pending edges)
    cmd_rcnt,           // [111:104] 6809 latch1 reads
    dbg_lsnd,           // [103:100] snd lane probe {req/ok sticky state}
    dbg_lsrom,          // [ 99: 96] srom lane probe
    dbg_eswr,           // [ 95: 88] ES5506 register writes
    dbg_actv,           // [ 87: 83] ES5506 ACTV value
    dbg_anyrun,         // [ 82]     any voice with STOP bits clear
    snd_pending1,       // [ 81]
    snd_pending2,       // [ 80]
    dbg_cr0,            // [ 79: 72] voice-0 CR low byte
    dbg_crn,            // [ 71: 64] CR write count
    dbg_sromn,          // [ 63: 56] ES5506 sample fetches
    dbg_sromd,          // [ 55: 48] last sample byte
    dbg_crv,            // [ 47: 40] last CR value written
    dbg_crp,            // [ 39: 33] page of that write
    dbg_peak,           // [ 32: 17] output peak
    9'd0,               // [ 16:  8] pad
    8'hA5               // [  7:  0] signature tail
};
altsource_probe u_issp6 (
    .probe  ( issp_probe6 ),
    .source (             )
);
defparam
    u_issp6.enable_metastability    = "NO",
    u_issp6.instance_id             = "SFSN",
    u_issp6.probe_width             = 128,
    u_issp6.sld_auto_instance_index = "YES",
    u_issp6.sld_instance_index      = 6,
    u_issp6.source_initial_value    = "0",
    u_issp6.source_width            = 0;


// ---------------------------------------------------------------------------
// JTAG ROM loader.
//
// The SLD hub is reachable only when the FPGA is configured from the .sof over
// JTAG, and that path skips MiSTer's ROM download. SDRAM does not survive the
// ~3 s configure -- measured, the first longword read back 0x00808000 against
// 0x00008000: one bit out, identical across every sample, i.e. retention decay
// rather than noise. So the program ROM is pushed in over JTAG instead.
//
// It writes through the SAME cache lane the CPU reads (mem.yaml main is now
// rw), so the CPU cannot see a stale line -- a separate write lane over the
// same region would need an explicit flush.
//
// Measured ISSP throughput is 8,620 source writes/s, so 1 MB at 4 bytes per
// write is about 30 s.
//
//   src[31: 0]  data (32-bit word)
//   src[49:32]  word address (main_addr is [19:2], so 18 bits = 1 MB)
//   src[50]     toggle: any change performs one write
//   src[51]     loader active -- holds the CPU off the lane
// ---------------------------------------------------------------------------
wire [19:2] cpu_rom_addr;
wire        cpu_rom_rd;

wire [63:0] ld_src;
wire        ld_active = ld_src[51];
wire        ld_toggle = ld_src[50];
wire        ld_rdmode = ld_src[52];   // 1: toggle performs a READ, data in probe3
wire        ld_gr     = ld_src[53];   // 1: the read targets grom0, not main
reg         ld_gr_l   = 1'b0;
wire [19:2] ld_addr   = ld_src[49:32];
wire [31:0] ld_data   = ld_src[31:0];

// ISSP source bits update from the JTAG TCK domain and are NOT mutually
// synchronised: the toggle edge can be observed a core clock before the
// address/data/mode bits have settled. The b91 FSM used those fields
// combinationally in the same cycle it saw the edge, so on hardware reads ran
// as writes (rdmode arrived late; every readback returned ld_rdata's reset
// value of zero) and bulk writes scattered with half-settled addresses --
// while the identical FSM was perfect in simulation, where all bits change on
// one edge. Fix: on the edge, WAIT 15 clocks (the inter-bit skew is bounded by
// one TCK, ~2 core clocks), then LATCH every field, then run the transaction
// from the latches.
//
// The lane still needs its own settle before ok is meaningful: main_ok can be
// high from the previous transaction (sftm_vram's arbiter guards the same
// hazard).
reg        ld_tog_d = 1'b0;
reg [1:0]  ld_st    = 2'd0;
reg [3:0]  ld_wait  = 4'd0;
reg        ld_we    = 1'b0;
reg        ld_rdm_l = 1'b0;
reg [19:2] ld_addr_l= 18'd0;
reg [31:0] ld_data_l= 32'd0;
reg [15:0] ld_done  = 16'd0;   // transactions the lane ACCEPTED
reg [15:0] ld_seen  = 16'd0;   // toggle edges seen
reg [31:0] ld_rdata = 32'd0;   // last readback (ld_rdmode)

always @(posedge clk) begin
    ld_tog_d <= ld_toggle;
    case( ld_st )
        2'd0: if( ld_toggle != ld_tog_d ) begin
                  ld_wait <= 4'd0; ld_st <= 2'd1;
                  if( ~&ld_seen ) ld_seen <= ld_seen + 16'd1;
              end
        2'd1: begin // source-bit settle, then latch all fields
                  ld_wait <= ld_wait + 4'd1;
                  if( &ld_wait ) begin
                      ld_addr_l <= ld_addr;
                      ld_data_l <= ld_data;
                      ld_rdm_l  <= ld_rdmode;
                      ld_gr_l   <= ld_gr;
                      ld_we     <= 1'b1;
                      ld_st     <= 2'd2;
                  end
              end
        2'd2: ld_st <= 2'd3;    // lane settle (stale-ok guard)
        2'd3: if( ld_gr_l ? grom0_ok : main_ok ) begin
                  ld_we <= 1'b0; ld_st <= 2'd0;
                  // grom0 is a 64-bit lane from build 108; readback captures
                  // the low longword of the 8-byte group
                  if( ld_rdm_l ) ld_rdata <= ld_gr_l ? grom0_data[31:0] : main_data;
                  if( ~&ld_done ) ld_done <= ld_done + 16'd1;
              end
    endcase
end

assign main_addr = ld_active ? ld_addr_l : cpu_rom_addr;
assign main_rd   = ld_active ? (ld_we & ld_rdm_l & ~ld_gr_l) : cpu_rom_rd;
assign main_we   = ld_active & ld_we & ~ld_rdm_l;
assign main_din  = ld_data_l;
assign main_dsn  = 4'd0;          // all four bytes

altsource_probe u_issp_ld (
    // Live handshake state, so a failing write is diagnosable without another
    // build: seen counts toggle edges the FSM noticed, done counts writes the
    // LANE ACCEPTED (main_ok). seen>0 with done==0 means the lane never
    // acknowledges; seen==0 means the source writes are not reaching the FSM.
    .probe  ( { 8'hC5, ld_seen[7:0], ld_done, ld_rdata } ),
    .source ( ld_src       )
);
defparam
    u_issp_ld.enable_metastability    = "NO",
    u_issp_ld.instance_id             = "SFLD",
    u_issp_ld.probe_width             = 64,
    u_issp_ld.sld_auto_instance_index = "YES",
    u_issp_ld.sld_instance_index      = 3,
    u_issp_ld.source_initial_value    = "0",
    u_issp_ld.source_width            = 64;

// ---------------------------------------------------------------------------
// grom0 lane readback. The service-menu glyphs render ragged on a static
// screen -- deterministic wrong pixels with zero blit pressure -- so the
// 16-bit lanes are suspected of returning wrong words: the slip compensation
// was MEASURED only on the 32-bit main lane and assumed for the rest. This
// reads grom0 directly over JTAG for comparison against the ROM bytes.
// src[53] selects grom0 for the SFLD transaction FSM (read-only); the
// captured word lands in the same ld_rdata probe.
// ---------------------------------------------------------------------------
wire [23:3] vid_grom0_addr;
wire        vid_grom0_rd;
// probe covers the first 2 MB of grom0: 64-bit GROUP address from src[49:32]
assign grom0_addr = (ld_active & ld_gr_l) ? {3'd0, ld_addr_l} : vid_grom0_addr;
assign grom0_rd   = (ld_active & ld_gr_l) ? (ld_we & ld_rdm_l) : vid_grom0_rd;

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
// src[1]: assert a game reset over JTAG. Toggling 1 -> 0 gives a clean reset
// pulse that re-runs sftm_main's boot vector copy WITHOUT reconfiguring the
// FPGA or re-downloading the ROM -- the only way to make the CPU consume
// content placed by the JTAG loader, since the watchdog cannot be relied on
// and every other reset path destroys SDRAM or re-shifts the download.
wire       force_rst = issp_src[1];
// NVRAM-restore reset hold (b119). The .nvm restore arrives as its OWN hps
// download after dwnld_busy has released the game (game_sdram.v:327 counts
// only ioctl_rom), so it races the running CPU. Every build through b116 won
// that race by accident -- the 4 KB CPU cache made boot crawl. b117's 16 KB
// cache reached the battery-backup checksum before the restore landed:
// deterministic BATTERY BACKUP FAILURE, then the restore overwrote the
// freshly-written defaults mid-flight (the insert-512-coins / doubled-damage
// state). Hold the game in reset while restore writes arrive and ~5 ms past
// the last one, so boot always runs against settled NVRAM. A save
// (hps_upload) raises ioctl_ram with no ioctl_wr pulses and takes no hold.
reg [17:0] nv_hold_cnt = 18'd0;
wire       nv_hold     = nv_hold_cnt != 18'd0;
always @(posedge clk) begin
    if( ioctl_ram && ioctl_wr ) nv_hold_cnt <= 18'h3FFFF;
    else if( nv_hold )          nv_hold_cnt <= nv_hold_cnt - 18'd1;
end

wire       rst_g     = (rst & ~force_run) | force_rst | nv_hold;
// src[2..5]: JTAG-pressable cabinet inputs, so an unattended run can leave
// the battery-failure and service-menu screens without a person at the
// machine: src[2]=P1 start, src[3]=coin 1, src[4]=P1 up, src[5]=P1 down.
// Inputs are active low at this level, so a press pulls the bit low; the
// released state leaves the real controls untouched. The TCK-domain crossing
// is unsynchronised but harmless here: the game samples these continuously
// and a scripted press holds them for hundreds of milliseconds.
wire [15:0] joystick1_g = joystick1 & ~{12'd0, issp_src[4], issp_src[5], 2'b00};
// src[6] = P2 start: the PLAYER CONTROL TEST screen exits only on START1+START2
wire [ 3:0] cab_1p_g    = cab_1p    & ~{ 2'd0, issp_src[6], issp_src[2]};
wire [ 3:0] coin_g      = coin      & ~{ 3'd0, issp_src[3]};

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

    .rom_addr     ( cpu_rom_addr  ),
    .rom_data     ( main_data     ),
    .rom_cs       ( cpu_rom_rd    ),
    .rom_ok       ( main_ok       ),

    .joystick1    ( joystick1_g   ),
    .joystick2    ( joystick2     ),
    .cab_1p       ( cab_1p_g      ),
    .coin         ( coin_g        ),
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

    .st_dout      ( st_main       ),
    .st_pc        ( main_pc       ),
    .st_op        ( main_op       ),
    .st_lastrom   ( main_lastrom  ),
    .st_vec_sp    ( main_vec_sp   ),
    .st_vec_pc    ( main_vec_pc   ),
    .st_firstbad  ( main_firstbad ),
    .st_derail    ( main_derail   ),
    .st_int       ( main_int      )
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

    .grom0_addr   ( vid_grom0_addr),
    .grom0_data   ( grom0_data    ),
    .grom0_rd     ( vid_grom0_rd  ),
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
    .vram_flush   ( vram_flush    ),
    .vram_flushing( vram_flushing ),
    .vram_flush_done( vram_flush_done ),
    .vscan_addr   ( vscan_addr    ),
    .vscan_data   ( vscan_data    ),
    .vscan_rd     ( vscan_rd      ),
    .vscan_ok     ( vscan_ok      ),

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
// The on-screen overlay row draws only while its message is nonzero
// (jtframe_debug_ctrl: view_sel gated on msg_nonz|dbg_nonz), so zero hides
// it. st_main served the bring-up era; every measurement now runs over the
// ISSP probes, and the binary+hex footer confused more than it informed --
// it was mistaken for a game status display for most of a day (PORTING.md
// 2026-08-21). Re-point at st_main if screen-visible state is ever needed
// without a JTAG cable.
assign debug_view = 8'd0;

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
// CPU fetch-stall meter (b117): cycles per frame the main CPU lane has a
// request up without ok -- the direct measure of whether slow game ticks
// are fetch-bound. Latched on vblank_irq like the video counters.
reg [19:0] cpu_stall_acc = 20'd0, stw_cpustall = 20'd0;
always @(posedge clk) begin
    if( vblank_irq ) begin
        stw_cpustall  <= cpu_stall_acc;
        cpu_stall_acc <= 20'd0;
    end else if( cpu_rom_rd && !main_ok && ~&cpu_stall_acc )
        cpu_stall_acc <= cpu_stall_acc + 20'd1;
end

wire [127:0] issp_probe2 = {
    8'h5C,          // [127:120] signature
    8'd0,
    stw_wr,         // [111: 92] VRAM writes this frame, EXACT
    stw_cpustall,   // [ 91: 72] REPURPOSED b117: CPU fetch-stall clk/frame
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
