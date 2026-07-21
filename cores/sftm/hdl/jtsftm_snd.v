`timescale 1ns/1ps
/*  This file is part of JTSFTM.  GPLv3 - see LICENSE.

    Sound subsystem for itech32 P/N 1066 REV 2 sound board:
      - MC6809 @ 2 MHz
      - ES5506 OTTO @ 16 MHz, 32 voices
      - 8 KB RAM (0x2000-0x3FFF)
      - main-to-sound command latch

    Address map from MAME itech32.cpp sound_map (Rev 1 board layout):
      0x0000        sound_return_w (write-only)
      0x0400        soundlatch read
      0x0800-0x083F ES5506 registers (mirror at 0x0880-0x08BF)
      0x0C00        sound bank register (write-only)
      0x1000        no-op (noisy)
      0x1400-0x140F VIA 6522 (TODO)
      0x2000-0x3FFF RAM (8 KB)
      0x4000-0x7FFF banked ROM (16 KB window, up to 256 banks)
      0x8000-0xFFFF fixed ROM

    The MC6809 wrapper name/port map must be adjusted to the exact JTFRAME
    `mc6809i` module in the target jtcores revision.
*/

module jtsftm_snd(
    input               rst,
    input               clk,
    input               cen,        // 2 MHz MC6809 enable
    input               es_cen,     // 16 MHz ES5506 enable

    // Sound CPU ROM (8-bit)
    output      [17:0]  rom_addr,
    input       [ 7:0]  rom_data,
    output              rom_cs,
    input               rom_ok,

    // ES5506 sample ROM
    output      [20:0]  srom_addr,  // word address
    input       [15:0]  srom_data,
    output              srom_cs,
    input               srom_ok,

    // command latch from main CPU
    input       [ 7:0]  snd_latch,
    input               snd_latch_we,
    output              snd_irq,

    // audio out to JTFRAME mixer
    output      [15:0]  snd_left,
    output      [15:0]  snd_right,
    output              sample
);

// ---------------------------------------------------------------------------
// 6809 bus (placeholder wrapper; exact mc6809i port map can vary by revision)
// ---------------------------------------------------------------------------
wire [15:0] a;
wire [ 7:0] din, dout;
wire        rw;

// ---------------------------------------------------------------------------
// Sound latch IRQ: assert when main CPU writes a command, clear on 6809 read.
// MAME: GENERIC_LATCH_8 with data_pending_callback -> M6809_IRQ_LINE.
// ---------------------------------------------------------------------------
reg irq_pending;
always @(posedge clk) begin
    if (rst)
        irq_pending <= 1'b0;
    else if (snd_latch_we)
        irq_pending <= 1'b1;         // main CPU wrote command
    else if (latch_cs && rw && cen)  // 6809 read clears pending flag
        irq_pending <= 1'b0;
end
wire irq_n = ~irq_pending;           // active-low to mc6809i

// ---------------------------------------------------------------------------
// Address decode (MAME sound_map)
// ---------------------------------------------------------------------------
//  0x0400        soundlatch read
wire latch_cs  = (a == 16'h0400);
//  0x0800-0x083F ES5506 (mirror at 0x0880; 0x80 apart so bit6 is don't-care)
wire es_cs     = (a[15:7] == 9'b0_0000_1000);  // 0x0800-0x087F incl. mirror
//  0x0C00        bank register write
wire bank_cs   = (a == 16'h0C00);
//  0x2000-0x3FFF RAM (8 KB)
wire ram_cs    = (a[15:13] == 3'b001);         // 0x2000-0x3FFF
//  0x4000-0x7FFF banked ROM window (16 KB)
wire brom_cs   = (a[15:14] == 2'b01);          // 0x4000-0x7FFF
//  0x8000-0xFFFF fixed ROM (32 KB)
assign rom_cs  = a[15];                         // 0x8000-0xFFFF

// ---------------------------------------------------------------------------
// Bank register (written at 0x0C00 by 6809)
// MAME configures 256 banks of 16 KB starting at soundcpu ROM offset 0x10000.
// snd_addr for banked ROM = 0x10000 + bank*0x4000 + a[13:0]
// ---------------------------------------------------------------------------
reg [7:0] rom_bank;
always @(posedge clk) begin
    if (rst)
        rom_bank <= 8'd0;
    else if (cen && bank_cs && !rw)
        rom_bank <= dout;
end

// ROM address mux:
//   fixed   (0x8000-0xFFFF): ROM byte-addr = 0x8000 + a[14:0]  -> snd_addr[14:0] = a[14:0], bit15=1
//   banked  (0x4000-0x7FFF): ROM byte-addr = 0x10000 + bank*0x4000 + a[13:0]
// Both fit in 18-bit snd_addr (max 256 KB).
assign rom_addr = brom_cs ? { 2'b01, rom_bank[1:0], a[13:0] }   // banked (TODO: 18-bit bank)
                           : { 3'b001, a[14:0] };                // fixed 0x8000-0xFFFF

// ---------------------------------------------------------------------------
// RAM (8 KB)
// ---------------------------------------------------------------------------
reg [7:0] ram[0:8191];
always @(posedge clk) if (cen && ram_cs && !rw) ram[a[12:0]] <= dout;

wire [7:0] es_dout;

assign din = rom_cs   ? rom_data :
             brom_cs  ? rom_data :    // banked window uses same SDRAM port
             ram_cs   ? ram[a[12:0]] :
             es_cs    ? es_dout :
             latch_cs ? snd_latch :
                        8'hff;

// TODO: replace with exact mc6809i instantiation once JTFRAME is vendored.
mc6809i u_cpu(
    .clk    ( clk     ),
    .cen    ( cen     ),
    .rst    ( rst     ),
    .rw     ( rw      ),
    .addr   ( a       ),
    .datai  ( din     ),
    .datao  ( dout    ),
    .irq    ( irq_n   ),
    .firq   ( 1'b1    ),
    .nmi    ( 1'b1    )
);

jt5506 u_otto(
    .rst        ( rst              ),
    .clk        ( clk              ),
    .cen        ( es_cen           ),
    // 6809 host interface (8-bit)
    .host_addr  ( a[5:0]           ),
    .host_din   ( dout             ),
    .host_dout  ( es_dout          ),
    .host_we    ( es_cs & ~rw & cen),
    .host_re    ( es_cs &  rw & cen),
    .irq        ( snd_irq          ),
    // sample ROM
    .srom_addr  ( srom_addr        ),
    .srom_data  ( srom_data        ),
    .srom_cs    ( srom_cs          ),
    .srom_ok    ( srom_ok          ),
    // audio
    .left       ( snd_left         ),
    .right      ( snd_right        ),
    .sample     ( sample           )
);

endmodule
