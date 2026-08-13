`timescale 1ns/1ps
/*  This file is part of SFTM.
    SFTM is free software: you can redistribute it and/or modify it under the
    terms of the GNU General Public License as published by the Free Software
    Foundation, either version 3 of the License, or (at your option) any later
    version. See the LICENSE file.

    Street Fighter: The Movie -- main CPU (68EC020) and memory map.

    Literal port of MAME src/mame/itech/itech32.cpp (see doc/mame-src/).
    Every address range and handler below cites the MAME function it mirrors.
    Reference: itech32_state::itech020_map (itech32.cpp:1003):

        0x000000-0x007fff  RAM (main_ram32, holds the vector table)
        0x080000-0x080003  R: P1        W: int1_ack_w
        0x100000-0x100003  R: P2
        0x180000-0x180003  R: P3
        0x200000-0x200003  R: P4
        0x280000-0x280003  R: DIPS
        0x300003           W: color_w<0>   } swapped vs base map by
        0x380003           W: color_w<1>   } init_sftm_common (itech32.cpp:4980)
        0x400000-0x400003  W: watchdog reset
        0x480001           W: sound_data_w
        0x500000-0x5000ff  RW: video registers (bloodstm_video_r/w)
        0x578000-0x57ffff  R: nop (protection touches this)
        0x580000-0x59ffff  RW: palette RAM
        0x600000-0x61ffff  RW: NVRAM (nvram32)
        0x680002           R: itech020_prot_result_r,  0x680000-3 W: nop
        0x680800-0x68083f  R: DUART (stub, reads 0)
        0x700002           W: itech020_plane_w
        0x800000-0xbfffff  ROM ("maindata", 1 MB loaded of 4 MB window)

    Hardware-verified findings carried over from the previous implementation
    (do not regress these -- each cost days of USB-Blaster debugging):

    1. Vector bootstrap: MAME's init_program_rom (itech32.cpp:4893) copies the
       first 0x80 bytes of program ROM into RAM at 0 before the CPU runs,
       because the reset SSP/PC vectors live in RAM here. The boot_copy FSM
       below replicates this before releasing the CPU from reset.

    2. IPL mapping (itech32_state::update_interrupts, itech32.cpp:440, with
       m_irq_base=0 from machine_start):
         VINT (vblank,  generate_int1)    -> IPL1 -> autovector 25 -> RAM 0x64
         XINT (blitter, VIDEOINT_BLITTER) -> IPL2 -> autovector 26 -> RAM 0x68
         QINT (scanline,VIDEOINT_SCANLINE)-> IPL3 -> autovector 27 -> RAM 0x6C
       These are three SEPARATE levels; do not collapse vblank+blitter.

    3. SDRAM byte order: JTFRAME assembles the download stream little-endian
       (rom_data[7:0] = byte address offset 0). The 68020 is big-endian, so a
       16-bit instruction word at BE offset 0 is {rom_data[7:0], rom_data[15:8]}
       and at offset 2 is {rom_data[23:16], rom_data[31:24]}. Depends on
       cfg/mame2mra.toml maindata width=32 with no `reverse`.
*/

module sftm_main #(
    // m_itech020_prot_address for sftm v1.12 (init_sftm, itech32.cpp:4993)
    parameter [23:0] PROT_ADDR = 24'h007a6a
)(
    input             rst,
    input             clk,        // 48 MHz
    input             cen,        // e020_cen, 25 MHz nominal

    // program ROM in SDRAM (bank 0 "main" bus): 1 MB, 32-bit
    output reg [19:2] rom_addr,
    input      [31:0] rom_data,
    output reg        rom_cs,
    input             rom_ok,

    // cabinet inputs (JTFRAME convention: active low, joystick[3:0]={up,down,left,right}
    // is NOT the order -- MiSTer/JTFRAME is bit0=right,1=left,2=down,3=up, buttons from bit4)
    input      [15:0] joystick1,
    input      [15:0] joystick2,
    input      [ 3:0] cab_1p,
    input      [ 3:0] coin,
    input             service,
    input             dip_test,
    input      [ 7:0] dipsw_a,

    // shared CPU bus to sftm_video (video regs + palette)
    output     [23:1] cpu_addr,
    output     [15:0] cpu_dout,
    output            cpu_rnw,
    output            cpu_uds_n,
    output            cpu_lds_n,
    output            bus_wstb,    // 1-clk write strobe, qualified with vreg_cs/pal_cs
    output reg        vreg_cs,
    output reg        pal_cs,
    input      [15:0] vreg_dout,
    input      [15:0] pal_dout,
    input             vid_wait,    // sftm_video: hold this access (blitter busy
                                   // and the CPU touches VIDEO_COMMAND/TRANSFER)

    // latches to video (itech020_plane_w / color_w)
    output reg [ 1:0] plane_en,     // {enable_latch[1], enable_latch[0]}, already inverted
    output reg [ 1:0] grom_bank,    // GROM A25:A24
    output reg [ 6:0] color_latch0, // color_w<0>: palette bank, foreground
    output reg [ 6:0] color_latch1, // color_w<1>: palette bank, background

    // interrupts from video
    input             vblank_irq,   // 1-clk pulse at vblank start (generate_int1)
    input             blit_irq,     // level: VIDEO_INTSTATE & INTENABLE & VIDEOINT_BLITTER
    input             scan_irq,     // level: VIDEO_INTSTATE & INTENABLE & VIDEOINT_SCANLINE
    input             LVBL,         // for DIPS bit 2 (active-low vblank status)

    // sound command latches (sound_data_w, itech32.cpp:676; latches live here,
    // the 6809 side reads them through sftm_snd)
    output reg [ 7:0] snd_latch1,
    output reg [ 7:0] snd_latch2,
    output reg        snd_pending1,
    output reg        snd_pending2,
    input             snd_latch1_rd, // 1-clk strobes from sftm_snd: latch consumed
    input             snd_latch2_rd,

    input      [ 7:0] debug_bus,
    input      [15:0] dbg_intstate,     // live INTSTATE  from sftm_video
    input      [15:0] dbg_intenable,    // live INTENABLE from sftm_video
    input      [15:0] dbg_intsticky,    // OR of every INTSTATE value seen
    input      [15:0] dbg_intscanline,  // INTSCANLINE contents
    input      [ 7:0] dbg_blitflags,    // blitter observation
    input      [15:0] dbg_islmod,       // INTSCANLINE after modulo reduction
    input      [ 7:0] dbg_scanhits,     // saturating count of scanline hits
    input      [ 8:0] dbg_vcntmax,      // highest vcnt the CRT reached
    output     [ 7:0] st_dout
);

// ---------------------------------------------------------------------------
// TG68K.C kernel signals
// ---------------------------------------------------------------------------
wire [31:0] cpu_a       /* synthesis keep */;
wire [15:0] cpu_din;
wire [15:0] cpu_do16;
wire [ 1:0] busstate    /* synthesis keep */;   // 00 fetch, 01 idle, 10 read, 11 write
wire        cpu_wr_n;
reg  [ 2:0] cpu_ipl     /* synthesis keep */;

wire        bus_active = busstate != 2'b01;
wire        bus_read   = busstate == 2'b00 || busstate == 2'b10;
wire        bus_write  = busstate == 2'b11;

assign cpu_addr = cpu_a[23:1];
assign cpu_dout = cpu_do16;
assign cpu_rnw  = cpu_wr_n;

// ---------------------------------------------------------------------------
// Watchdog: MAME instantiates WATCHDOG_TIMER with no period, which defaults
// to 3 seconds (watchdog.cpp). Kicked by any write to 0x400000. On timeout
// the machine soft-resets: here that means CPU + bus FSM, keeping RAM/NVRAM
// contents (vectors persist, so the boot copy re-run is idempotent).
// ---------------------------------------------------------------------------
localparam [27:0] WDOG_TIMEOUT = 28'd144_000_000;  // 3 s @ 48 MHz
reg  [27:0] wdog_cnt;
reg         wdog_rst;
wire        w_rst = rst | wdog_rst;

// ---------------------------------------------------------------------------
// Address decode (itech020_map)
// ---------------------------------------------------------------------------
wire [23:0] A = cpu_a[23:0];

wire ram_cs   = A[23:15] == 9'h000;                 // 0x000000-0x007fff
wire inp_p1   = A[23:2] == 22'h020000;              // 0x080000-3
wire inp_p2   = A[23:2] == 22'h040000;              // 0x100000-3
wire inp_p3   = A[23:2] == 22'h060000;              // 0x180000-3
wire inp_p4   = A[23:2] == 22'h080000;              // 0x200000-3
wire inp_dips = A[23:2] == 22'h0A0000;              // 0x280000-3
wire color0_w = A[23:2] == 22'h0C0000;              // 0x300000-3 (byte 3 only)
wire color1_w = A[23:2] == 22'h0E0000;              // 0x380000-3 (byte 3 only)
wire wdog_w   = A[23:2] == 22'h100000;              // 0x400000-3
wire sndlat_w = A[23:2] == 22'h120000;              // 0x480000-3 (byte 1 only)
wire vreg_sel = A[23:8]  == 16'h5000;               // 0x500000-0x5000ff
wire nopr_sel = A[23:15] == {8'h57, 1'b1};          // 0x578000-0x57ffff
wire pal_sel  = A[23:17] == 7'b0101_100;            // 0x580000-0x59ffff
wire nvram_cs = A[23:17] == 7'b0110_000;            // 0x600000-0x61ffff
wire prot_sel = A[23:2] == 22'h1A0000;              // 0x680000-3 (byte 2 read = prot result)
wire duart_sel= A[23:6] == 18'h1A020;               // 0x680800-0x68083f
wire plane_sel= A[23:2] == 22'h1C0000;              // 0x700000-3 (byte 2 only)
wire prog_sel = A[23:22] == 2'b10;                  // 0x800000-0xbfffff

// ---------------------------------------------------------------------------
// Bus FSM. The kernel is clocked by clkena_in: it holds address/busstate
// stable until we grant a tick, letting us insert wait states per region.
//   DECODE: kernel outputs valid for the pending access
//   WAIT:   1 clk for registered BRAM/reg reads to settle
//   ROM:    hold rom_cs until rom_ok (with a 2-clk settle so we never sample
//           a stale ok from the previous address)
//   GRANT:  assert clkena on the next cen pulse
// ---------------------------------------------------------------------------
localparam [2:0] S_BOOT=3'd0, S_DECODE=3'd1, S_WAIT=3'd2, S_ROM=3'd3, S_GRANT=3'd4;
reg  [2:0] state /* synthesis keep */;
reg  [1:0] rom_settle;
reg        boot_done;

wire grant  = state == S_GRANT && cen;
wire clkena = grant;
assign bus_wstb = grant && bus_write;

// ---------------------------------------------------------------------------
// Boot vector copy (init_program_rom, itech32.cpp:4893): ROM[0x00..0x7f] ->
// RAM[0x00..0x7f], i.e. 32 longwords, before the CPU's first vector fetch.
// ---------------------------------------------------------------------------
reg  [4:0] boot_lw;      // longword index 0..31
reg        boot_phase;   // 0: wait rom_ok, write high word; 1: write low word
reg  [1:0] boot_settle;

// ---------------------------------------------------------------------------
// Main RAM: 32 KB, one RW port muxed between boot FSM / protection readback /
// CPU. Byte lanes: _hi = D15:8 (even byte address), _lo = D7:0 (odd).
// ---------------------------------------------------------------------------
reg [7:0] ram_hi[0:16383], ram_lo[0:16383];
reg [7:0] ram_hi_q, ram_lo_q;

// itech020_prot_result_r (itech32.cpp:637): reads a byte of main RAM at
// PROT_ADDR. No PIC16C54 emulation -- the game itself writes the expected
// value there. PROT_ADDR is even, so the byte sits in the _hi lane.
wire        prot_rd   = prot_sel && bus_read && A[1];
// boot write address: longword lw covers word addresses {lw,0} and {lw,1}
wire [13:0] ram_addr = !boot_done ? {8'd0, boot_lw, boot_phase} :
                       prot_rd    ? PROT_ADDR[14:1] :
                                    A[14:1];

// boot data: BE word 0 of a longword = stream bytes {0,1}, word 1 = {2,3}
wire [15:0] boot_wdata = !boot_phase ? {rom_data[ 7:0], rom_data[15: 8]}
                                     : {rom_data[23:16], rom_data[31:24]};
wire        boot_we    = !boot_done && state==S_BOOT && boot_settle==2'd3 && rom_ok;

wire ram_cpu_we_hi = grant && bus_write && ram_cs && !cpu_uds_n;
wire ram_cpu_we_lo = grant && bus_write && ram_cs && !cpu_lds_n;

always @(posedge clk) begin
    if( boot_we || ram_cpu_we_hi )
        ram_hi[ram_addr] <= boot_we ? boot_wdata[15:8] : cpu_do16[15:8];
    ram_hi_q <= ram_hi[ram_addr];
end
always @(posedge clk) begin
    if( boot_we || ram_cpu_we_lo )
        ram_lo[ram_addr] <= boot_we ? boot_wdata[7:0] : cpu_do16[7:0];
    ram_lo_q <= ram_lo[ram_addr];
end

// ---------------------------------------------------------------------------
// NVRAM: 128 KB BRAM (0x600000-0x61ffff). MAME randomizes uninitialized
// NVRAM (nvram_init, itech32.cpp:848) to force the game's factory init; we
// start it zeroed, which the game also treats as invalid. A known-good MAME
// dump exists at repo root (nvram32) if factory init ever proves insufficient.
// SD-card persistence is deferred (see cfg/mem.yaml).
// ---------------------------------------------------------------------------
reg [7:0] nvram_hi[0:65535], nvram_lo[0:65535];
reg [7:0] nvram_hi_q, nvram_lo_q;
wire [15:0] nvram_addr = A[16:1];

always @(posedge clk) begin
    if( grant && bus_write && nvram_cs && !cpu_uds_n ) nvram_hi[nvram_addr] <= cpu_do16[15:8];
    nvram_hi_q <= nvram_hi[nvram_addr];
end
always @(posedge clk) begin
    if( grant && bus_write && nvram_cs && !cpu_lds_n ) nvram_lo[nvram_addr] <= cpu_do16[7:0];
    nvram_lo_q <= nvram_lo[nvram_addr];
end

// ---------------------------------------------------------------------------
// Input ports (INPUT_PORTS_START(sftm) + itech32_base_32bit, itech32.cpp:1396
// and 1514). All live in D23:16 of the 32-bit port value = D7:0 of the 16-bit
// bus word at A[1]=0. Everything active low except noted; JTFRAME inputs are
// already active low so most bits pass straight through.
// ---------------------------------------------------------------------------
// JTFRAME joystick: bit0=right 1=left 2=down 3=up, buttons from bit4
wire j1_r=joystick1[0], j1_l=joystick1[1], j1_d=joystick1[2], j1_u=joystick1[3];
wire j2_r=joystick2[0], j2_l=joystick2[1], j2_d=joystick2[2], j2_u=joystick2[3];

// P1 (0x080000): bit16 coin1,17 start1,18 btn1,19 btn2,20 right,21 left,22 down,23 up
wire [7:0] p1_byte = { j1_u, j1_d, j1_l, j1_r, joystick1[5], joystick1[4], cab_1p[0], coin[0] };
// P2 (0x100000): same layout, player 2 / coin2
wire [7:0] p2_byte = { j2_u, j2_d, j2_l, j2_r, joystick2[5], joystick2[4], cab_1p[1], coin[1] };
// P3 (0x180000), sftm overlay: btn3-6 interleaved P1/P2
wire [7:0] p3_byte = { joystick2[9], joystick1[9], joystick2[8], joystick1[8],
                       joystick2[7], joystick1[7], joystick2[6], joystick1[6] };
// P4 (0x200000): all unused, active low -> 0xff
wire [7:0] p4_byte = 8'hff;

// DIPS (0x280000):
//   bit16 test (service mode, active low)      bit20 SW1:4 "Video Sync"
//   bit17 service coin (active low)            bit21 SW1:3 Flip Screen
//   bit18 vblank status (active low)           bit22 SW1:2 Freeze Screen
//   bit19 special_port_r (active low)          bit23 SW1:1 Service (ACTIVE_HIGH)
// special_port_r (itech32.cpp:544): toggles on read while soundlatch pending,
// and the toggled value is what the read returns.
reg  special_q;
wire special_ret = special_q ^ snd_pending1;
wire dips_rd     = grant && bus_read && inp_dips && !A[1];

wire [7:0] dips_byte = { dipsw_a[3], dipsw_a[2], dipsw_a[1], dipsw_a[0],
                         ~special_ret, LVBL, service, dip_test };

always @(posedge clk) begin
    if( w_rst ) special_q <= 1'b0;
    else if( dips_rd ) special_q <= special_ret;
end

// ---------------------------------------------------------------------------
// Write-side latches
// ---------------------------------------------------------------------------
// color_w (itech32.cpp:531): latch = (data & 0x7f) << 8; byte address 3 ->
// A[1]=1, LDS lane. sftm mapping (init_sftm_common): 0x300003 -> layer 0,
// 0x380003 -> layer 1.
// itech020_plane_w (itech32_v.cpp:264): byte address 2 -> A[1]=1, UDS lane.
//   enable0 = ~bit1, enable1 = ~bit2, grom_bank = bits 7:6
// sound_data_w (itech32.cpp:676): byte address 1 -> A[1]=0, LDS lane. Writes
// latch2 instead when latch1 is still pending.
always @(posedge clk) begin
    if( w_rst ) begin
        color_latch0 <= 7'd0;
        color_latch1 <= 7'd0;
        // enable_latch reset: {0, 1} for sftm -- m_planes = 1, so latch 1
        // starts off (video_start, itech32_v.cpp:207)
        plane_en     <= 2'b01;
        grom_bank    <= 2'd0;
        snd_latch1   <= 8'd0;
        snd_latch2   <= 8'd0;
        snd_pending1 <= 1'b0;
        snd_pending2 <= 1'b0;
    end else begin
        if( snd_latch1_rd ) snd_pending1 <= 1'b0;
        if( snd_latch2_rd ) snd_pending2 <= 1'b0;
        if( grant && bus_write ) begin
            if( color0_w && A[1] && !cpu_lds_n ) color_latch0 <= cpu_do16[6:0];
            if( color1_w && A[1] && !cpu_lds_n ) color_latch1 <= cpu_do16[6:0];
            if( plane_sel && A[1] && !cpu_uds_n ) begin
                plane_en  <= { ~cpu_do16[10], ~cpu_do16[9] };
                grom_bank <= cpu_do16[15:14];
            end
            if( sndlat_w && !A[1] && !cpu_lds_n ) begin
                if( snd_pending1 ) begin
                    snd_latch2   <= cpu_do16[7:0];
                    snd_pending2 <= 1'b1;
                end else begin
                    snd_latch1   <= cpu_do16[7:0];
                    snd_pending1 <= 1'b1;
                end
            end
        end
    end
end

// ---------------------------------------------------------------------------
// Interrupts (update_interrupts, itech32.cpp:440, m_irq_base=0).
// vint is a latch: set at vblank start (generate_int1), cleared by any write
// to 0x080000 (int1_ack_w). xint/qint are levels owned by sftm_video.
// IPL is active low; priority encode highest level.
// ---------------------------------------------------------------------------
reg vint;
always @(posedge clk) begin
    if( w_rst )                                   vint <= 1'b0;
    else if( vblank_irq )                         vint <= 1'b1;
    else if( grant && bus_write && inp_p1 )       vint <= 1'b0;
end

always @(posedge clk) begin
    if( w_rst )         cpu_ipl <= 3'b111;
    else begin
        cpu_ipl <= scan_irq ? 3'b100 :   // QINT, level 3
                   blit_irq ? 3'b101 :   // XINT, level 2
                   vint     ? 3'b110 :   // VINT, level 1
                              3'b111;
    end
end

// ---------------------------------------------------------------------------
// Watchdog counter
// ---------------------------------------------------------------------------
always @(posedge clk) begin
    if( rst ) begin
        wdog_cnt <= 28'd0;
        wdog_rst <= 1'b0;
    end else begin
        if( grant && bus_write && wdog_w ) wdog_cnt <= 28'd0;
        else if( wdog_cnt >= WDOG_TIMEOUT ) begin
            wdog_cnt <= 28'd0;
            wdog_rst <= 1'b1;
        end else begin
            wdog_cnt <= wdog_cnt + 28'd1;
            wdog_rst <= 1'b0;
        end
    end
end

// ---------------------------------------------------------------------------
// Bus FSM + boot copy
// ---------------------------------------------------------------------------
always @(posedge clk) begin
    if( w_rst ) begin
        state       <= S_BOOT;
        boot_done   <= 1'b0;
        boot_lw     <= 5'd0;
        boot_phase  <= 1'b0;
        boot_settle <= 2'd0;
        rom_settle  <= 2'd0;
        rom_cs      <= 1'b0;
        rom_addr    <= {18{1'b0}};
    end else case( state )

        S_BOOT: begin
            rom_addr <= { 13'd0, boot_lw };
            rom_cs   <= 1'b1;
            if( boot_settle != 2'd3 )
                boot_settle <= boot_settle + 2'd1;
            else if( rom_ok ) begin
                // boot_we writes this cycle (see RAM block)
                if( !boot_phase )
                    boot_phase <= 1'b1;          // same longword, low word next
                else begin
                    boot_phase  <= 1'b0;
                    boot_settle <= 2'd0;         // new address -> resettle
                    if( boot_lw == 5'd31 ) begin
                        boot_done <= 1'b1;
                        rom_cs    <= 1'b0;
                        state     <= S_DECODE;
                    end
                    boot_lw <= boot_lw + 5'd1;
                end
            end
        end

        S_DECODE: begin
            rom_cs <= 1'b0;
            if( !bus_active )
                state <= S_GRANT;
            else if( prog_sel && bus_read ) begin
                rom_addr   <= A[19:2];
                rom_cs     <= 1'b1;
                rom_settle <= 2'd0;
                state      <= S_ROM;
            end else
                state <= S_WAIT;
        end

        // MAME blits are instantaneous inside the register write; ours take
        // real time, so accesses to VIDEO_COMMAND/VIDEO_TRANSFER wait here
        // until the blitter is free (vid_wait). Other accesses never stall.
        S_WAIT: if( !vid_wait ) state <= S_GRANT;

        S_ROM: begin
            if( rom_settle != 2'd2 ) rom_settle <= rom_settle + 2'd1;
            else if( rom_ok )        state <= S_GRANT;
        end

        S_GRANT: if( cen ) begin
            state  <= S_DECODE;
            rom_cs <= 1'b0;
        end

        default: state <= S_DECODE;
    endcase
end

// ---------------------------------------------------------------------------
// CPU read data mux. Unmapped regions and nop reads return 0 (MAME's default
// unmapped value; 0x578000 nopr and the DUART stub rely on this).
// ---------------------------------------------------------------------------
wire [15:0] rom_word = !A[1] ? { rom_data[ 7:0], rom_data[15: 8] }
                             : { rom_data[23:16], rom_data[31:24] };

// video_cs decode outputs to sftm_video
always @(*) begin
    vreg_cs = vreg_sel;
    pal_cs  = pal_sel;
end

assign cpu_din =
    ram_cs    ? { ram_hi_q, ram_lo_q }   :
    prog_sel  ? rom_word                 :
    nvram_cs  ? { nvram_hi_q, nvram_lo_q }:
    vreg_sel  ? vreg_dout                :
    pal_sel   ? pal_dout                 :
    inp_p1    ? ( !A[1] ? {8'h00, p1_byte } : 16'h0000 ) :
    inp_p2    ? ( !A[1] ? {8'h00, p2_byte } : 16'h0000 ) :
    inp_p3    ? ( !A[1] ? {8'h00, p3_byte } : 16'h0000 ) :
    inp_p4    ? ( !A[1] ? {8'h00, p4_byte } : 16'h0000 ) :
    inp_dips  ? ( !A[1] ? {8'h00, dips_byte} : 16'h0000 ) :
    prot_rd   ? { ram_hi_q, ram_hi_q }   :   // byte on both lanes; game reads D15:8
    16'h0000;

// ---------------------------------------------------------------------------
// TG68K.C kernel, 68020 mode. VHDL under hdl/tg68k for Quartus; the
// ghdl-converted TG68KdotC_Kernel_conv.v serves Verilator.
// ---------------------------------------------------------------------------
TG68KdotC_Kernel #(
    .SR_Read       (2), .VBR_Stackframe(2),
    .extAddr_Mode  (2), .MUL_Mode(2), .DIV_Mode(2),
    .BitField      (2), .BarrelShifter(2), .MUL_Hardware(1)
) u_cpu (
    .CPU           ( 2'b11        ),   // 68020
    .clk           ( clk          ),
    .nReset        ( ~w_rst & boot_done ),
    .clkena_in     ( clkena       ),
    .data_in       ( cpu_din      ),
    .IPL           ( cpu_ipl      ),
    .IPL_autovector( 1'b1         ),
    .addr_out      ( cpu_a        ),
    .berr          ( 1'b0         ),
    .data_write    ( cpu_do16     ),
    .busstate      ( busstate     ),
    .nWr           ( cpu_wr_n     ),
    .nUDS          ( cpu_uds_n    ),
    .nLDS          ( cpu_lds_n    ),
    .nResetOut     (              ),
    .skipFetch     (              )
);

// ---------------------------------------------------------------------------
// Hardware bring-up diagnostics (Phase 4, revision 2).
//
// JTFRAME renders st_dout as two hex digits over the game image (debug_view,
// jtframe_debug.v:50; the viewmux defaults to debug_view with sel=0). OSD
// buttons are not reachable over SSH, so the display AUTO-CYCLES 16 views.
// The tag is the WHOLE high nibble and the payload the whole low nibble, so a
// screenshot reads directly as "<view><value>" with no bit juggling:
//
//   0..5 : pc_vec   -- where the CPU JUMPED TO on its first exception,
//                      i.e. the ISR entry address (nibble 0 = bits 3:0)
//   6..B : pc_stuck -- the PC after vint has been asserted continuously for
//                      >100 ms, i.e. where it spins while a vblank is pending
//   C    : which exception vector was fetched: {0x60 spurious, 0x64 VINT,
//          0x68 XINT, 0x6C QINT} -- the previous build lumped 0x60..0x6F into
//          one bit, which could not tell a real autovector from a spurious one
//   D    : sticky writes {vreg, VIDEO_COMMAND, VIDEO_INTENABLE, palette}
//   E    : sticky {int1_ack (ISR completed), plane latch, prot read, snd latch}
//   F    : live {boot_done, vint, blit_irq, scan_irq}
//
// pc_vec/pc_stuck latch on events and then hold forever, so one capture burst
// always reconstructs a single coherent address (the previous revision
// re-snapshotted per cycle and produced mixed nibbles).
// ---------------------------------------------------------------------------
reg [23:0] pc_live, pc_vec, pc_stuck;
reg [23:0] pc_now;           // re-latched each view cycle (coherent nibbles)

// ---------------------------------------------------------------------------
// Game-state snoops. Rather than infer what the game is doing, read its own
// variables by watching CPU writes to known addresses (found by disassembling
// the ROM):
//   0x0FBE  the exception/status code the fault handlers store (the L1/VINT
//           crash trap at 0x800918 writes #$5 here, other handlers write
//           their own codes) -- non-zero means the game took a fault
//   0x0406  frame counter, incremented by the routine the QINT handler calls
//   0x0407  sound-queue READ index   } equal => queue empty => the game has
//   0x0408  sound-queue WRITE index  } never queued a sound command
// Word addresses: byte>>1. 0x0FBE->0x7DF, 0x0406/7->0x203, 0x0408->0x204.
// ---------------------------------------------------------------------------
reg [15:0] dbg_fbe;
reg [ 7:0] dbg_406, dbg_407, dbg_408;
// rev7 snoops, chosen from the disassembly:
//   0x0400  SELF-TEST RESULT. The RAM test at 0x80158A exits via
//           move.w #0/#1/#2,d0 -> jmp 0x800412, and the boot path stores d0
//           here (0 = pass, 1 = pattern mismatch, 2 = address-as-data
//           mismatch). Non-zero means the game thinks my RAM is broken.
//   0x044E  task count for the dispatcher the main loop calls at 0x800802
//   0x1104  raster-split index driving the QINT chain (0,2,4,6)
reg [15:0] dbg_400, dbg_44e, dbg_1104;
// pc_max tracks only the UPPER 12 bits: a full 24-bit magnitude comparator
// cost ~0.2 ns and pushed the design negative (build 6 closed at +0.115
// without it, build 8 hit -0.289 with it). 4 KB granularity is ample for
// identifying which routine the code reached.
reg [11:0] pc_max_hi;
reg        vec_pend, pc_vec_done, pc_stuck_done;
reg [22:0] vint_timer;                  // 100 ms @ 48 MHz = 4.8e6 -> 23 bits
reg [28:0] diag_cnt;
wire [3:0] view = diag_cnt[28:25];      // ~0.7 s per view, ~11 s per cycle

// exception vector longwords (VBR = 0): 0x60 spurious, 0x64/0x68/0x6C autovec
wire vec60 = A[23:2] == 22'h000018;
wire vec64 = A[23:2] == 22'h000019;
wire vec68 = A[23:2] == 22'h00001A;
wire vec6c = A[23:2] == 22'h00001B;
wire vec_rd = grant && bus_read && (vec60 | vec64 | vec68 | vec6c);

reg sf_v60, sf_v64, sf_v68, sf_v6c;
reg sf_vreg_wr, sf_cmd_wr, sf_inten_wr, sf_pal_wr;
reg sf_int_ack, sf_plane_wr, sf_prot_rd, sf_snd_wr;
reg sf_nvram_wr;

// video register index within 0x500000-0x5000ff: registers are 4 bytes apart,
// so k = A[7:2] (sftm_video's cpu_addr keeps [23:1] index numbering, so its
// cpu_addr[7:2] selects these same bits)
wire [5:0] vreg_k = A[7:2];

always @(posedge clk) begin
    if( w_rst ) begin
        pc_live <= 0; pc_vec <= 0; pc_stuck <= 0;
        pc_now <= 0; pc_max_hi <= 0;
        dbg_fbe <= 0; dbg_406 <= 0; dbg_407 <= 0; dbg_408 <= 0;
        dbg_400 <= 0; dbg_44e <= 0; dbg_1104 <= 0;
        vec_pend <= 0; pc_vec_done <= 0; pc_stuck_done <= 0;
        vint_timer <= 0; diag_cnt <= 0;
        { sf_v60, sf_v64, sf_v68, sf_v6c } <= 4'd0;
        { sf_vreg_wr, sf_cmd_wr, sf_inten_wr, sf_pal_wr } <= 4'd0;
        { sf_int_ack, sf_plane_wr, sf_prot_rd, sf_snd_wr } <= 4'd0;
        sf_nvram_wr <= 1'b0;
    end else begin
        diag_cnt <= diag_cnt + 29'd1;
        if( grant && busstate == 2'b00 ) pc_live <= A;
        // compare against the registered copy, never against A itself: the
        // address bus is on the critical path and a 24-bit comparator there
        // would cost timing the design does not have
        if( pc_live[23:12] > pc_max_hi ) pc_max_hi <= pc_live[23:12];
        if( diag_cnt == {29{1'b1}} ) pc_now <= pc_live;

        // --- which vector, and where did it jump to ------------------------
        if( vec_rd ) begin
            if( vec60 ) sf_v60 <= 1'b1;
            if( vec64 ) sf_v64 <= 1'b1;
            if( vec68 ) sf_v68 <= 1'b1;
            if( vec6c ) sf_v6c <= 1'b1;
            if( !pc_vec_done ) vec_pend <= 1'b1;
        end
        // the first instruction fetch after the vector read IS the ISR entry
        if( vec_pend && grant && busstate == 2'b00 ) begin
            pc_vec      <= A;
            pc_vec_done <= 1'b1;
            vec_pend    <= 1'b0;
        end

        // --- where is it spinning while a vblank sits unacknowledged? ------
        if( !vint ) vint_timer <= 23'd0;
        else if( vint_timer != {23{1'b1}} ) vint_timer <= vint_timer + 23'd1;
        if( vint && vint_timer == 23'd4_800_000 && !pc_stuck_done ) begin
            pc_stuck      <= pc_live;
            pc_stuck_done <= 1'b1;
        end

        // --- sticky bus events ---------------------------------------------
        // game-state snoops (see comment at the declarations)
        if( ram_cpu_we_hi && ram_addr == 14'h07DF ) dbg_fbe[15:8] <= cpu_do16[15:8];
        if( ram_cpu_we_lo && ram_addr == 14'h07DF ) dbg_fbe[ 7:0] <= cpu_do16[ 7:0];
        if( ram_cpu_we_hi && ram_addr == 14'h0203 ) dbg_406 <= cpu_do16[15:8];
        if( ram_cpu_we_lo && ram_addr == 14'h0203 ) dbg_407 <= cpu_do16[ 7:0];
        if( ram_cpu_we_hi && ram_addr == 14'h0204 ) dbg_408 <= cpu_do16[15:8];
        if( ram_cpu_we_hi && ram_addr == 14'h0200 ) dbg_400[15:8] <= cpu_do16[15:8];
        if( ram_cpu_we_lo && ram_addr == 14'h0200 ) dbg_400[ 7:0] <= cpu_do16[ 7:0];
        if( ram_cpu_we_hi && ram_addr == 14'h0227 ) dbg_44e[15:8] <= cpu_do16[15:8];
        if( ram_cpu_we_lo && ram_addr == 14'h0227 ) dbg_44e[ 7:0] <= cpu_do16[ 7:0];
        if( ram_cpu_we_hi && ram_addr == 14'h0882 ) dbg_1104[15:8] <= cpu_do16[15:8];
        if( ram_cpu_we_lo && ram_addr == 14'h0882 ) dbg_1104[ 7:0] <= cpu_do16[ 7:0];
        if( grant && bus_write ) begin
            if( vreg_sel  ) sf_vreg_wr  <= 1'b1;
            if( vreg_sel && vreg_k == 6'h04 ) sf_cmd_wr   <= 1'b1;  // COMMAND
            if( vreg_sel && vreg_k == 6'h05 ) sf_inten_wr <= 1'b1;  // INTENABLE
            if( pal_sel   ) sf_pal_wr   <= 1'b1;
            if( plane_sel ) sf_plane_wr <= 1'b1;
            if( inp_p1    ) sf_int_ack  <= 1'b1;   // int1_ack_w: the ISR ran
            if( sndlat_w  ) sf_snd_wr   <= 1'b1;
            if( nvram_cs  ) sf_nvram_wr <= 1'b1;
        end
        if( grant && bus_read && prot_rd ) sf_prot_rd <= 1'b1;
    end
end

// ---------------------------------------------------------------------------
// Debug view map (rev9).
//
// rev8 result: the self-test verdict reads 0 (PASS), scanline_hit saturated
// at 255 and vcnt reaches 285 -- so the scanline compare now fires and the
// CRT is correct. Yet RAM[0x1104] is still pinned at 6, so the QINT handler
// still never runs. The break must therefore be in the short chain
//   scanline_hit -> INTSTATE bit2 -> (AND INTENABLE bit2) -> scan_irq -> IPL3
// and since the XINT handler demonstrably runs at IPL2 the CPU cannot be
// refusing a higher level. The prime suspect is INTENABLE losing bit 2:
// the ROM contains move.w #$20,$500014 at 0x801D06, which would enable
// neither the scanline (0x04) nor the blitter (0x40) source.
//
// So this map restores the two registers rev8 had to drop, keeping just
// enough of the scanline probes to confirm the compare is still firing.
//   0-3 : INTENABLE (live)      4-7 : INTSTATE (live)
//   8-9 : scanline_hit count    A-B : RAM[0x1104] raster index
//   C   : RAM[0x0400] self-test verdict
//   D-E : RAM[0x044E] task count
//   F   : sticky {pal_wr, snd_wr, ints_b2, ints_b6}
// ---------------------------------------------------------------------------
assign st_dout =
    view == 4'h0 ? { 4'h0, dbg_intenable[ 3: 0] } :
    view == 4'h1 ? { 4'h1, dbg_intenable[ 7: 4] } :
    view == 4'h2 ? { 4'h2, dbg_intenable[11: 8] } :
    view == 4'h3 ? { 4'h3, dbg_intenable[15:12] } :
    view == 4'h4 ? { 4'h4, dbg_intstate [ 3: 0] } :
    view == 4'h5 ? { 4'h5, dbg_intstate [ 7: 4] } :
    view == 4'h6 ? { 4'h6, dbg_intstate [11: 8] } :
    view == 4'h7 ? { 4'h7, dbg_intstate [15:12] } :
    view == 4'h8 ? { 4'h8, dbg_scanhits[3:0] } :
    view == 4'h9 ? { 4'h9, dbg_scanhits[7:4] } :
    view == 4'hA ? { 4'hA, dbg_1104[3:0] } :
    view == 4'hB ? { 4'hB, dbg_1104[7:4] } :
    view == 4'hC ? { 4'hC, dbg_400[3:0] } :
    view == 4'hD ? { 4'hD, dbg_44e[3:0] } :
    view == 4'hE ? { 4'hE, dbg_44e[7:4] } :
                   { 4'hF, sf_pal_wr, sf_snd_wr,
                           dbg_intsticky[2], dbg_intsticky[6] };

// verilator lint_off UNUSEDSIGNAL
// nopr_sel/duart_sel document the 0x578000 and 0x680800 read ranges; both
// return 0 through the read mux default, so the decodes are informational.
wire [7:0] unused_dbg = debug_bus;
wire unused_nop = nopr_sel | duart_sel;
// verilator lint_on UNUSEDSIGNAL

endmodule
