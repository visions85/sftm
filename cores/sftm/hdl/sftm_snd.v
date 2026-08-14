`timescale 1ns/1ps
/*  This file is part of SFTM.
    SFTM is free software: you can redistribute it and/or modify it under the
    terms of the GNU General Public License as published by the Free Software
    Foundation, either version 3 of the License, or (at your option) any later
    version. See the LICENSE file.

    Street Fighter: The Movie -- Rev 2 sound board: MC6809 @ 2 MHz + ES5506.
    Literal port of MAME itech32.cpp sound_020_map (:1079):

        0x0000        R: soundlatch  (command byte from the main CPU)
        0x0400        R: soundlatch2 (second buffered command)
        0x0800-0x083f RW: ES5506 (mirror 0x80)
        0x0c00        W: sound_bank_w
        0x1400        W: firq_clear_w
        0x1800        R: sound_data_buffer_r (latch1 pending << 7), W: nop
        0x1c00        W: sound_control_w (nop, :704)
        0x2000-0x3fff RAM (8 KB)
        0x4000-0x7fff banked ROM (16 KB pages from region offset 0x10000,
                      machine_start :479)
        0x8000-0xffff fixed ROM (region offset 0x8000, the ROM_CONTINUE
                      chunk of sfm_snd_v1.u23)

    Interrupts (sftm machine config, itech32.cpp:1894):
        IRQ  = soundlatch pending | soundlatch2 pending (INPUT_MERGER)
        FIRQ = periodic 4*60 Hz assert, cleared by firq_clear_w (:759)
        NMI  = unused on the Rev 2 board

    The command latches live in sftm_main (main-CPU state); this module
    raises snd_latchN_rd for one clk when the 6809 consumes them.

    CPU: jtframe's mc6809i (clk + cen_E/cen_Q quadrature enables). `cen`
    here is a 4 MHz enable (see cfg/mem.yaml); E and Q alternate on it for a
    2 MHz bus clock. Both enables freeze while a ROM fetch waits on SDRAM.
*/

module sftm_snd(
    input             rst,
    input             clk,
    input             cen,         // 4 MHz enable -> 2 MHz E clock
    input             es_cen,      // 16 MHz enable (ES5506)

    // 6809 program ROM (SDRAM bank 0, "snd" bus = MAME soundcpu region)
    output     [20:0] rom_addr,
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
    output reg        snd_latch1_rd,
    output reg        snd_latch2_rd,

    output signed [15:0] snd_left,
    output signed [15:0] snd_right,
    output               sample,

    // Sound verification. The 6809 spent the whole project fetching the
    // 68020's program ROM (snd and main both sat at bank-0 word 0 -- see
    // cfg/mem.yaml), so sound has never actually run. st_eswr counts ES5506
    // register writes, which requires the CPU to boot and execute its init
    // correctly; st_peak is the largest |snd_left| seen, which additionally
    // requires the sample ROM path to work.
    output reg [ 7:0] st_eswr,
    output reg [15:0] st_peak
);

// ---------------------------------------------------------------------------
// E/Q generation with SDRAM wait
// ---------------------------------------------------------------------------
wire [15:0] A;
wire [ 7:0] cpu_dout;
wire        RnW;

// decode (exact addresses, as MAME maps them)
wire latch1_cs = A == 16'h0000;
wire latch2_cs = A == 16'h0400;
wire es_cs     = A[15:8] == 8'h08 && !A[6];      // 0x0800-0x083f mirror 0x80
wire bank_cs   = A == 16'h0c00;
wire firq_cs   = A == 16'h1400;
wire status_cs = A == 16'h1800;
wire ram_cs    = A[15:13] == 3'b001;             // 0x2000-0x3fff
wire brom_cs   = A[15:14] == 2'b01;              // 0x4000-0x7fff banked
wire from_cs   = A[15];                          // 0x8000-0xffff fixed
wire rom_sel   = brom_cs || from_cs;

// ROM data validator: require rom_ok with the address stable for 2+ clks
// (jtframe_romrq drops ok a cycle after an address change)
reg [20:0] last_addr;   // must match rom_addr's width (biased by SND_ORG)
reg [ 1:0] addr_stable;
wire       rom_good = rom_ok && addr_stable == 2'd2;

reg [7:0] bank;      // sound_bank_w (:663)
// Bank 0 holds maindata at word 0 and soundcpu right after it, at byte
// 0x100000. jtframe_rom_2slots defaults SLOT1_OFFSET to 0 and this generator
// cannot express a non-zero one, so the bias is applied here -- without it
// the 6809 fetched the 68020's program ROM. See cfg/mem.yaml.
localparam [20:0] SND_ORG = 21'h100000;
// MAME builds this region with a ROM_CONTINUE:
//     ROM_LOAD( "sfm_snd_v1.u23", 0x10000, 0x38000 )
//     ROM_CONTINUE(               0x08000, 0x08000 )
// so region 0x10000.. holds the file's first 0x38000 bytes and region
// 0x08000-0x0FFFF -- the 6809's FIXED window, which carries the reset vector
// -- holds the file's LAST 32 KB.
//
// The MRA cannot express ROM_CONTINUE: it emits 0x10000 of FF padding and
// then the whole 0x40000 file linearly, so region 0x8000-0xFFFF was reading
// FF and the 6809 never booted (ES5506 register writes measured 0 on
// hardware). The banked window was already correct.
//
// Region offset R therefore holds file[R - 0x10000], and the two windows map
// to file offsets directly:
//     banked 0x4000-0x7FFF -> file bank*0x4000 + A[13:0]
//     fixed  0x8000-0xFFFF -> file 0x38000 + (A - 0x8000)
localparam [20:0] FIX_ORG = 21'h48000;   // region base of the file's last 32 KB
assign rom_addr = SND_ORG +
                  ( brom_cs ? 21'h10000 + {7'd0, bank, A[13:0]}
                            : FIX_ORG   + {6'd0, A[14:0]} );
assign rom_cs   = rom_sel;

always @(posedge clk) begin
    if( rst ) begin
        last_addr   <= 0;
        addr_stable <= 0;
    end else if( rom_addr != last_addr ) begin
        last_addr   <= rom_addr;
        addr_stable <= 0;
    end else if( addr_stable != 2'd2 )
        addr_stable <= addr_stable + 2'd1;
end

wire pause = rom_sel && !rom_good;
reg  eq_phase;
wire cen_Q = cen && !pause && !eq_phase;
wire cen_E = cen && !pause &&  eq_phase;

always @(posedge clk) begin
    if( rst ) eq_phase <= 0;
    else if( cen && !pause ) eq_phase <= ~eq_phase;
end

// ---------------------------------------------------------------------------
// RAM
// ---------------------------------------------------------------------------
reg [7:0] ram[0:8191];
reg [7:0] ram_q;
always @(posedge clk) begin
    if( cen_E && ram_cs && !RnW ) ram[A[12:0]] <= cpu_dout;
    ram_q <= ram[A[12:0]];
end

// ---------------------------------------------------------------------------
// interrupts
// ---------------------------------------------------------------------------
localparam [17:0] FIRQ_PERIOD = 18'd200_000;   // 48 MHz / (4*60 Hz)
reg [17:0] firq_cnt;
reg        firq;

always @(posedge clk) begin
    if( rst ) begin
        firq_cnt <= 0;
        firq     <= 0;
    end else begin
        if( firq_cnt == FIRQ_PERIOD-1 ) begin
            firq_cnt <= 0;
            firq     <= 1;                      // periodic assert (:1894)
        end else
            firq_cnt <= firq_cnt + 18'd1;
        if( cen_E && firq_cs && !RnW )
            firq <= 0;                          // firq_clear_w (:759)
    end
end

wire irq_n  = ~(snd_pending1 | snd_pending2);   // INPUT_MERGER (:1896)
wire firq_n = ~firq;

// ---------------------------------------------------------------------------
// ES5506
// ---------------------------------------------------------------------------
wire [7:0] es_dout;
wire       es_wr = cen_E && es_cs && !RnW;

wire signed [15:0] sl_probe = snd_left;
wire        [15:0] sl_mag   = sl_probe[15] ? (~sl_probe + 16'd1) : sl_probe;

always @(posedge clk) begin
    if( rst ) begin
        st_eswr <= 8'd0;
        st_peak <= 16'd0;
    end else begin
        if( es_wr && st_eswr != 8'hFF ) st_eswr <= st_eswr + 8'd1;
        if( sample && sl_mag > st_peak ) st_peak <= sl_mag;
    end
end
wire       es_rd = cen_E && es_cs &&  RnW;

sftm5506 u_es(
    .rst       ( rst        ),
    .clk       ( clk        ),
    .es_cen    ( es_cen     ),
    .host_addr ( A[5:0]     ),
    .host_din  ( cpu_dout   ),
    .host_dout ( es_dout    ),
    .host_wr   ( es_wr      ),
    .host_rd   ( es_rd      ),
    .srom_addr ( srom_addr  ),
    .srom_data ( srom_data  ),
    .srom_cs   ( srom_cs    ),
    .srom_ok   ( srom_ok    ),
    .snd_left  ( snd_left   ),
    .snd_right ( snd_right  ),
    .sample    ( sample     )
);

// ---------------------------------------------------------------------------
// misc registers / latch consumption
// ---------------------------------------------------------------------------
always @(posedge clk) begin
    if( rst ) begin
        bank          <= 0;
        snd_latch1_rd <= 0;
        snd_latch2_rd <= 0;
    end else begin
        snd_latch1_rd <= 0;
        snd_latch2_rd <= 0;
        if( cen_E ) begin
            if( bank_cs && !RnW )  bank <= cpu_dout;   // sound_bank_w
            if( latch1_cs && RnW ) snd_latch1_rd <= 1; // latch read clears pending
            if( latch2_cs && RnW ) snd_latch2_rd <= 1;
        end
    end
end

// ---------------------------------------------------------------------------
// CPU read mux. Unmapped reads return 0 (MAME default).
// ---------------------------------------------------------------------------
wire [7:0] cpu_din =
    latch1_cs ? snd_latch1 :
    latch2_cs ? snd_latch2 :
    es_cs     ? es_dout :
    status_cs ? {snd_pending1, 7'd0} :   // sound_data_buffer_r (:698)
    ram_cs    ? ram_q :
    rom_sel   ? rom_data :
    8'h00;

// ---------------------------------------------------------------------------
// MC6809
// ---------------------------------------------------------------------------
mc6809i u_cpu(
    .clk      ( clk      ),
    .cen_E    ( cen_E    ),
    .cen_Q    ( cen_Q    ),
    .D        ( cpu_din  ),
    .DOut     ( cpu_dout ),
    .ADDR     ( A        ),
    .RnW      ( RnW      ),
    .BS       (          ),
    .BA       (          ),
    .nIRQ     ( irq_n    ),
    .nFIRQ    ( firq_n   ),
    .nNMI     ( 1'b1     ),
    .AVMA     (          ),
    .BUSY     (          ),
    .LIC      (          ),
    .nHALT    ( 1'b1     ),
    .nRESET   ( ~rst     ),
    .nDMABREQ ( 1'b1     ),
    .OP       (          ),
    .RegData  (          )
);

endmodule
