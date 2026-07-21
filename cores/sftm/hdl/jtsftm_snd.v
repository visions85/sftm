`timescale 1ns/1ps
/*  This file is part of JTSFTM.  GPLv3 - see LICENSE.

    Sound subsystem for itech32 P/N 1083:
      - MC6809 @ 2 MHz
      - ES5506 (OTTO) @ 16 MHz, 32 voices
      - 8 KB-ish RAM (exact size per board revision; TODO confirm)
      - main-to-sound command latch

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
wire        irq_n = ~snd_latch_we;   // TODO: latch/clear command IRQ correctly

assign rom_cs   = a[15];             // 0x8000-0xffff
assign rom_addr = {2'b00, a[15:0]};

// small RAM
reg [7:0] ram[0:8191];
wire ram_cs = a[15:13]==3'b000;
wire es_cs  = a[15:8] == 8'h20;      // TODO: exact ES5506 location from itech32.cpp
wire latch_cs = a[15:8] == 8'h30;    // TODO: exact sound-latch read location
wire [7:0] es_dout;

always @(posedge clk) if(cen && ram_cs && !rw) ram[a[12:0]] <= dout;

assign din = rom_cs   ? rom_data :
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
