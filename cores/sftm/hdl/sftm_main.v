`timescale 1ns/1ps
/*  This file is part of SFTM.  GPLv3 - see LICENSE.

    Main CPU subsystem for Street Fighter: The Movie (itech32, 020 board).

    CPU: Motorola MC68EC020 @ 25 MHz, recreated with TG68K.C in 68020 mode.
    TG68K.C uses a 16-bit external data bus even in 020 mode (dynamic bus
    sizing), so 32-bit program ROM words are fed as two 16-bit halves.

    Memory map: transcribed and verified against MAME itech32.cpp `itech020_map`
    and `init_sftm_common`. All offsets cross-checked against MAME source.
*/

module sftm_main(
    input               rst,
    input               clk,
    input               cen,        // ~25 MHz enable

    // Program ROM (32-bit) in SDRAM bank 0
    output      [17:0]  rom_addr,   // long-word address (1 MB / 4 = 256K)
    input       [31:0]  rom_data,
    output              rom_cs,
    input               rom_ok,

    // Cabinet I/O
    input       [15:0]  joystick1,
    input       [15:0]  joystick2,
    input       [ 1:0]  cab_1p,
    input       [ 1:0]  coin,
    input               service,
    input               dip_test,
    input       [ 7:0]  dipsw_a,
    input       [ 7:0]  dipsw_b,

    // Video / blitter / palette bus (to sftm_video)
    output      [23:1]  cpu_addr,
    output      [15:0]  cpu_dout,
    output              cpu_rnw,
    output              cpu_uds_n,
    output              cpu_lds_n,
    output reg          vram_cs,
    output reg          vreg_cs,
    output reg          pal_cs,
    input       [15:0]  vram_dout,
    input       [15:0]  vreg_dout,
    input       [15:0]  pal_dout,
    output reg  [ 1:0]  plane_en,
    output reg  [ 1:0]  grom_bank,
    output reg  [ 6:0]  color_latch0,
    output reg  [ 6:0]  color_latch1,

    // Interrupts from the video block
    input               blit_irq,
    input               scan_irq,
    input               vblank_irq,

    // Sound command latch to the 6809 subsystem
    output reg  [ 7:0]  snd_latch,
    output reg          snd_latch_we,

    // NVRAM is kept in on-chip BRAM (u_nvram); JTFRAME battery persistence
    // is deferred (see hdl/mem.yaml).
    input       [ 7:0]  debug_bus,

    // Diagnostic: goes high on the first CPU write to NVRAM space and stays
    // high. Used by sftm_video to distinguish "stuck before NVRAM init" (RED)
    // from "stuck after NVRAM init" (MAGENTA) in the post-startup diagnostic.
    output reg          nvram_wr_ever,

    // LVBL from sftm_video — used for the DIPS vblank status bit (bit 2,
    // active-low: 1=active display, 0=in vertical blank).
    input               LVBL
);

// Memory map (verified against MAME itech32.cpp `itech020_map`).
// Values are the high address bits used for coarse decode.
// ---------------------------------------------------------------------------
// 0x000000-0x007FFF   main RAM
// 0x080000            P1 input / int1 ack
// 0x100000            P2 input
// 0x180000            P3 input / extra
// 0x200000            system / service
// 0x280000            DIP switches
// 0x300003            colour latch[0] — fg bank (sftm: init_sftm_common overrides base map)
// 0x380003            colour latch[1] — bg bank
// 0x400000            watchdog
// 0x480001            sound data write (to 6809)
// 0x500000-0x5000FF   IT42 video/blitter registers
// 0x578000-0x57FFFF   reads as 0 (touched by protection)
// 0x580000-0x59FFFF   palette RAM
// 0x600000-0x61FFFF   NVRAM
// 0x680002            protection result (main RAM byte @ 0x7A6A)
// 0x700002            plane enable / GROM bank latch
// 0x800000-0xBFFFFF   program ROM
// ---------------------------------------------------------------------------

localparam [7:0] REG_INP0 = 8'h08, // >>16 of 0x080000
                 REG_INP1 = 8'h10,
                 REG_INP2 = 8'h18,
                 REG_SYS  = 8'h20,
                 REG_DIP  = 8'h28,
                 REG_COL1 = 8'h30,
                 REG_COL0 = 8'h38,
                 REG_WDOG = 8'h40,
                 REG_SND  = 8'h48,
                 REG_VIDEO= 8'h50,
                 REG_PAL  = 8'h58,
                 REG_NVRAM= 8'h60,
                 REG_PROT = 8'h68,
                 REG_PLANE= 8'h70;

// ---------------------------------------------------------------------------
// Watchdog timer: CPU must write to 0x400000 (REG_WDOG) at least once every
// ~333 ms (16 M cycles @ 48 MHz) or the core issues a soft reset.
// On real itech32 hardware the CMOS watchdog timer asserts nRESET if not
// kicked; blank NVRAM causes the game to initialise defaults then stall in a
// tight loop waiting for a watchdog-triggered reboot.  Without this timer the
// CPU loops forever (blit_start never fires → RED diagnostic).
//
// w_rst: logically OR'd with the external rst so all CPU-side logic resets on
// both hard reset (JTFRAME) and watchdog timeout.  The NVRAM BRAM (sftm_ram)
// has no reset input, so its contents survive the soft reset — on the second
// boot NVRAM is valid and the game proceeds normally.
// ---------------------------------------------------------------------------
reg  [23:0] wdog_cnt;
reg         wdog_rst;
wire        w_rst = rst | wdog_rst;

// ---------------------------------------------------------------------------
// TG68K.C kernel signals
// ---------------------------------------------------------------------------
wire [31:0] cpu_a;
wire [15:0] cpu_din, cpu_do16;
wire [ 1:0] busstate;
wire        cpu_wr_n;
wire        bus_active = busstate==2'b00 || busstate==2'b10;
wire        cpu_write  = cen & bus_active & ~cpu_wr_n & (~cpu_uds_n | ~cpu_lds_n);
wire        low_byte_we  = ~cpu_lds_n;
wire        high_byte_we = ~cpu_uds_n;
reg  [ 2:0] cpu_ipl;

// Reset-time boot copy: the 020 fetches its reset SSP/PC from 0x000000, which
// is RAM here. MAME's init_program_rom copies the first 0x80 bytes of program
// ROM into main RAM; we do the same before releasing the CPU from reset.
reg  [ 4:0] boot_lw;                     // 0..31 long-word index (32*4 = 0x80)
reg         boot_half;                   // 0 = high word, 1 = low word
reg         boot_done;                   // copy finished, CPU may run

assign cpu_addr = cpu_a[23:1];
assign cpu_dout = cpu_do16;
assign cpu_rnw  = cpu_wr_n;

// clock enable is gated by "bus ready": on ROM accesses wait for rom_ok, and
// the CPU stays held until the boot vector copy has finished.
wire   bus_busy = rom_cs & ~rom_ok;
wire   clkena   = cen & ~bus_busy & boot_done;

// ---------------------------------------------------------------------------
// Coarse address decode
// ---------------------------------------------------------------------------
wire [7:0] ahi = cpu_a[23:16];
reg        ram_cs, inp_cs, dip_cs, sys_cs, nvram_cs;
reg        prot_cs, nopr_cs;
reg        prog_sel;

always @(*) begin
    ram_cs   = cpu_a[23:15]==9'h000;        // 0x000000-0x007fff main RAM
    prog_sel = cpu_a[23:22]==2'b10;         // 0x800000-0xbfffff program ROM
    inp_cs   = ahi==REG_INP0 || ahi==REG_INP1 || ahi==REG_INP2;
    sys_cs   = ahi==REG_SYS;
    dip_cs   = ahi==REG_DIP;
    vreg_cs  = bus_active && cpu_a[23:8]==16'h5000;
    pal_cs   = bus_active && cpu_a[23:17]==7'h2c; // 0x580000-0x59ffff
    vram_cs  = 1'b0;                         // VRAM is accessed via VIDEO_TRANSFER
    nvram_cs = cpu_a[23:17]==7'h30;          // 0x600000-0x61ffff NVRAM
    prot_cs  = cpu_a[23:1]==23'h34_0001;     // 0x680002 protection result byte
    nopr_cs  = cpu_a[23:15]==9'h0af;         // 0x578000-0x57ffff reads as 0
end

// The ROM port is driven by the boot-copy FSM until boot_done, then the CPU.
assign rom_cs   = boot_done ? (prog_sel & bus_active) : 1'b1;
assign rom_addr = boot_done ? cpu_a[19:2]              // 256K long-words
                            : { 13'd0, boot_lw };

// 32-bit program ROM → 16-bit halves for TG68K (big-endian 68020).
// cpu_a[1]=0: upper word (bits[31:16], MSW); cpu_a[1]=1: lower word (bits[15:0], LSW).
wire [15:0] rom_half = cpu_a[1] ? rom_data[15:0] : rom_data[31:16];

// ---------------------------------------------------------------------------
// Main RAM: 0x000000-0x007fff = 32 KB (16K x 16). The write port is shared
// with the reset-time boot copy (the CPU is held in reset until boot_done).
// ---------------------------------------------------------------------------
wire [15:0] ram_dout;
wire [15:0] boot_word = boot_half ? rom_data[15:0] : rom_data[31:16];
wire        boot_we   = ~boot_done & rom_ok;        // write both lanes

wire [13:0] ram_addr  = boot_done ? cpu_a[14:1] : { 8'd0, boot_lw, boot_half };
wire [15:0] ram_din   = boot_done ? cpu_dout    : boot_word;
wire        ram_we_lo = boot_done ? (cpu_write & ram_cs & low_byte_we ) : boot_we;
wire        ram_we_hi = boot_done ? (cpu_write & ram_cs & high_byte_we) : boot_we;

sftm_ram #(.AW(14)) u_ram(
    .clk    ( clk       ),
    .addr   ( ram_addr  ),
    .din    ( ram_din   ),
    .we_lo  ( ram_we_lo ),
    .we_hi  ( ram_we_hi ),
    .dout   ( ram_dout  )
);

// ---------------------------------------------------------------------------
// NVRAM: 0x600000-0x61ffff is a 128 KB battery-backed region on the real
// board. Only 32 KB is backed here (MiSTer's NVRAM dump must stay < 64 KB and
// the game uses only a small part); the upper region aliases down.
// TODO: size to the actual used range and add JTFRAME persistence via a
// bram:{ ioctl:{ save:true } } entry once JTFRAME is vendored.
// ---------------------------------------------------------------------------
wire [15:0] nvram_dout;
wire        nvram_we_lo = cpu_write & nvram_cs & low_byte_we;
wire        nvram_we_hi = cpu_write & nvram_cs & high_byte_we;

always @(posedge clk) begin
    if( rst ) nvram_wr_ever <= 1'b0;
    else if( nvram_we_lo | nvram_we_hi ) nvram_wr_ever <= 1'b1;
end

// NVRAM pre-loaded from MAME: valid bookkeeping data so game skips factory
// reset and goes directly to attract mode.  Paths are relative to the
// Quartus project directory (cores/sftm/mister/) → reach into hdl/.
sftm_ram #(.AW(14),
           .INIT_FILE_HI("../hdl/nvram_hi.hex"),
           .INIT_FILE_LO("../hdl/nvram_lo.hex")) u_nvram(
    .clk    ( clk         ),
    .addr   ( cpu_a[14:1] ),
    .din    ( cpu_dout    ),
    .we_lo  ( nvram_we_lo ),
    .we_hi  ( nvram_we_hi ),
    .dout   ( nvram_dout  )
);

// ---------------------------------------------------------------------------
// Protection: 0x680002 returns a main-RAM byte (MAME itech020_prot_result_r).
// sftm_prot snoops CPU writes to that address (0x7a6a) and latches the byte.
// ---------------------------------------------------------------------------
wire [7:0] prot_byte;

sftm_prot u_prot(
    .clk    ( clk         ),
    .rst    ( rst         ),
    .wr_addr( cpu_a[14:1] ),
    .we_hi  ( cpu_write & ram_cs & high_byte_we ),
    .din    ( cpu_dout    ),
    .result ( prot_byte   )
);

// ---------------------------------------------------------------------------
// CPU data-in mux
// ---------------------------------------------------------------------------
reg [15:0] inp_mux;
always @(*) begin
    case(1'b1)
        prog_sel: inp_mux = rom_half;
        ram_cs:   inp_mux = ram_dout;
        nvram_cs: inp_mux = nvram_dout;
        vram_cs:  inp_mux = vram_dout;
        vreg_cs:  inp_mux = vreg_dout;
        pal_cs:   inp_mux = pal_dout;
        prot_cs:  inp_mux = { prot_byte, 8'hff };
        nopr_cs:  inp_mux = 16'h0000;
        inp_cs:   inp_mux = read_inputs(ahi);
        // P4 (0x200000): bits[7:0] active-low all unused (→ lower half, cpu_a[1]=1).
        sys_cs:   inp_mux = cpu_a[1] ? 16'h00FF : 16'h0000;
        // DIPS (0x280000): MAME itech32_base_020 PORT_BIT definitions, bits[7:0]
        // live in the lower 16-bit half (cpu_a[1]=1, byte offsets +2/+3).
        //   bit0 (0x01): test-mode switch     (active-low)
        //   bit1 (0x02): service coin         (active-low)
        //   bit2 (0x04): VBLANK from screen   (active-low: 1=active display, 0=vblank)
        //   bit3 (0x08): special_port_r       (active-high, 0=idle)
        //   bit4 (0x10): Video Sync DIP       (0=standard)
        //   bit5 (0x20): Flip Screen DIP      (0=off)
        //   bit6 (0x40): Unknown DIP          (0=on/default)
        //   bit7 (0x80): Service Mode DIP     (active-high, 0=normal)
        dip_cs:   inp_mux = cpu_a[1] ? { 8'h00,
                                          dipsw_a[7],    // bit7 service-mode DIP (active-high)
                                          dipsw_a[6],    // bit6 unknown DIP
                                          dipsw_a[5],    // bit5 flip-screen DIP
                                          dipsw_a[4],    // bit4 video-sync DIP
                                          1'b0,          // bit3 special_port_r (idle)
                                          LVBL,          // bit2 vblank (1=active disp, 0=vblank)
                                          ~service,      // bit1 service coin
                                          ~dip_test }    // bit0 test-mode switch
                                       : 16'h0000;       // upper half unused
        default:  inp_mux = 16'hffff;
    endcase
end
assign cpu_din = inp_mux;

// Input port reads.
// MAME itech32_base_020 PORT_BIT definitions place all input bits in bits[7:0]
// of the 32-bit port value (= bytes +2/+3, i.e. the LOWER 16-bit half).
// TG68K 16-bit bus: cpu_a[1]=0 → upper half 16'h0000 (unused),
//                   cpu_a[1]=1 → lower half { 8'h00, io_byte }.
// MAME bit layout for P1/P2 (all active-low):
//   bit7=UP  bit6=DN  bit5=LT  bit4=RT  bit3=B2  bit2=B1  bit1=START  bit0=COIN
// JTFRAME joystick convention: [0]=UP [1]=DN [2]=LT [3]=RT [4]=B1 [5]=B2
function [15:0] read_inputs(input [7:0] sel);
    reg [7:0] io;
    begin
        case(sel)
            // P1 (0x080000): UP,DN,LT,RT,B2,B1,START1,COIN1  (all active-low)
            REG_INP0: io = ~{ joystick1[0], joystick1[1], joystick1[2], joystick1[3],
                               joystick1[5], joystick1[4], cab_1p[0],   coin[0] };
            // P2 (0x100000): same layout for player 2
            REG_INP1: io = ~{ joystick2[0], joystick2[1], joystick2[2], joystick2[3],
                               joystick2[5], joystick2[4], cab_1p[1],   coin[1] };
            // P3 (0x180000): all active-high unused per MAME itech32_base_020 P3.
            // sftm extra punch/kick buttons (BTN3-6) may need PORT_MODIFY here
            // once the exact mapping is confirmed against MAME.
            REG_INP2: io = 8'h00;
            default:  io = 8'hFF;
        endcase
        read_inputs = cpu_a[1] ? { 8'h00, io } : 16'h0000;
    end
endfunction

always @(posedge clk) begin
    wdog_rst <= 1'b0;                          // default: not firing
    if( rst ) begin
        wdog_cnt <= 24'd0;
    end else if( cpu_write && ahi==REG_WDOG ) begin
        wdog_cnt <= 24'd0;                     // kicked: reset timer
    end else if( wdog_cnt == 24'd15_999_999 ) begin
        wdog_rst <= 1'b1;                      // timeout ~333 ms @ 48 MHz
        wdog_cnt <= 24'd0;
    end else begin
        wdog_cnt <= wdog_cnt + 24'd1;
    end
end

// ---------------------------------------------------------------------------
// Register writes: sound latch, colour latches, plane enable and GROM bank.
// Byte writes:
//   0x480001 → sound latch (low byte)
//   0x300003 → color_latch0 (sftm: init_sftm_common puts latch[0] here)
//   0x380003 → color_latch1 (sftm: init_sftm_common puts latch[1] here)
//   0x700002 → plane_en / grom_bank (high byte)
// ---------------------------------------------------------------------------
always @(posedge clk) begin
    snd_latch_we <= 1'b0;
    if( w_rst ) begin
        plane_en    <= 2'b11;
        grom_bank   <= 2'b00;
        color_latch0<= 7'd0;
        color_latch1<= 7'd0;
        snd_latch   <= 8'd0;
    end else if( cpu_write ) begin
        if( ahi==REG_SND && low_byte_we ) begin
            snd_latch    <= cpu_do16[7:0];
            snd_latch_we <= 1'b1;
        end
        // sftm init_sftm_common swaps the latch assignments vs base itech020_map:
        // 0x300003 (REG_COL1) → latch[0], 0x380003 (REG_COL0) → latch[1]
        if( ahi==REG_COL1 && low_byte_we ) begin
            color_latch0 <= cpu_do16[6:0];  // fg palette bank
        end
        if( ahi==REG_COL0 && low_byte_we ) begin
            color_latch1 <= cpu_do16[6:0];  // bg palette bank
        end
        if( ahi==REG_PLANE && high_byte_we ) begin
            plane_en  <= { ~cpu_do16[10], ~cpu_do16[9] }; // data bits 2:1
            grom_bank <= cpu_do16[15:14];                 // data bits 7:6
        end
    end
end

// ---------------------------------------------------------------------------
// Boot vector copy FSM: walk 32 long-words (0x80 bytes) of program ROM into
// main RAM. rom_cs is forced high while !boot_done (see decode), so rom_ok
// pulses when the requested long-word is available. Both byte lanes are
// written; boot_half selects the high/low 16-bit half of each long-word.
// ---------------------------------------------------------------------------
always @(posedge clk) begin
    if( w_rst ) begin
        boot_lw   <= 5'd0;
        boot_half <= 1'b0;
        boot_done <= 1'b0;
    end else if( !boot_done && rom_ok ) begin
        if( !boot_half ) begin
            boot_half <= 1'b1;                       // high word written now
        end else begin
            boot_half <= 1'b0;                       // low word written now
            if( boot_lw == 5'd31 ) boot_done <= 1'b1;
            else                   boot_lw    <= boot_lw + 5'd1;
        end
    end
end

// ---------------------------------------------------------------------------
// Interrupt priority (confirmed from MAME itech32.cpp update_interrupts):
//   vblank   → IPL 1 (active-low 3'b110); ack = read or write to 0x080000
//   blitter  → IPL 2 (active-low 3'b101); ack = VIDEO_INTACK write
//   scanline → IPL 3 (active-low 3'b100); ack = VIDEO_INTACK write
// Higher IPL overrides lower in the priority encoder below.
// ---------------------------------------------------------------------------
reg vint_latch;

// int1_ack: any access (read or write) to 0x080000 clears the vblank latch.
// In MAME, itech020_input_r (the READ handler) calls
// maincpu->set_input_line(M68K_IRQ_1, CLEAR_LINE).  The game ISR reads
// 0x080000 for joystick data — that same read acks the interrupt in MAME.
// Without this the ISR never acks, vint_latch stays set, and the CPU
// re-enters the ISR immediately on every RTE, looping forever.
// itech020_int1_ack_w (the WRITE handler) also acks, so we fire on either.
wire int1_ack = cen & bus_active & (~cpu_uds_n | ~cpu_lds_n) & (ahi==REG_INP0);

always @(posedge clk) begin
    if( w_rst ) begin
        vint_latch <= 1'b0;
    end else begin
        if( vblank_irq ) vint_latch <= 1'b1;
        if( int1_ack   ) vint_latch <= 1'b0;  // ack on read or write
    end
end
always @(posedge clk) begin
    if( w_rst ) cpu_ipl <= 3'b111;         // no IRQ (active low IPL)
    else begin
        cpu_ipl <= 3'b111;
        if( vint_latch ) cpu_ipl <= 3'b110; // level 1 vblank
        if( blit_irq   ) cpu_ipl <= 3'b101; // level 2 blitter
        if( scan_irq   ) cpu_ipl <= 3'b100; // level 3 scanline (highest priority)
    end
end

// ---------------------------------------------------------------------------
// TG68K.C kernel (CPU="11" -> 68020). Instantiated as a black box; the VHDL
// (or ghdl/vhd2vl-converted Verilog) is vendored under hdl/tg68k.
// ---------------------------------------------------------------------------
TG68KdotC_Kernel #(
    .SR_Read       (2), .VBR_Stackframe(2),
    .extAddr_Mode  (2), .MUL_Mode(2), .DIV_Mode(2),
    .BitField      (2), .BarrelShifter(2), .MUL_Hardware(1)
) u_cpu (
    .CPU           ( 2'b11        ),   // 68020 mode
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

endmodule
