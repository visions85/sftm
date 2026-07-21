/*  This file is part of JTSFTM.  GPLv3 - see LICENSE.

    Main CPU subsystem for Street Fighter: The Movie (itech32, 020 board).

    CPU: Motorola MC68EC020 @ 25 MHz, recreated with TG68K.C in 68020 mode.
    TG68K.C uses a 16-bit external data bus even in 020 mode (dynamic bus
    sizing), so 32-bit program ROM words are fed as two 16-bit halves.

    Memory map: transcribed from MAME src/mame/itech/itech32.cpp
    `itech020_map`. The exact byte offsets below are marked TODO and MUST be
    confirmed against that driver before the core can boot.
*/

module jtsftm_main(
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

    // Video / blitter / palette bus (to jtsftm_video)
    output      [23:1]  cpu_addr,
    output      [15:0]  cpu_dout,
    output              cpu_rnw,
    output reg          vram_cs,
    output reg          vreg_cs,
    output reg          pal_cs,
    input       [15:0]  vram_dout,
    input       [15:0]  vreg_dout,
    input       [15:0]  pal_dout,
    output reg  [ 1:0]  plane_en,
    output reg  [ 8:0]  color_latch,

    // Interrupts from the video block
    input               blit_irq,
    input               vblank_irq,

    // Sound command latch to the 6809 subsystem
    output reg  [ 7:0]  snd_latch,
    output reg          snd_latch_we,

    // NVRAM (battery RAM), backed via mem.yaml nvram interface
    input       [ 7:0]  nvram_din,
    output      [ 7:0]  nvram_dout,
    output      [13:0]  nvram_addr,
    output              nvram_we,

    input       [ 7:0]  debug_bus
);

// ---------------------------------------------------------------------------
// Memory map (TODO: confirm every constant against itech020_map in
// itech32.cpp). Values are the high address bits used for coarse decode.
// ---------------------------------------------------------------------------
// 0x000000-0x00FFFF   main RAM (also NVRAM window)   [confirm size/mirror]
// 0x080000            P1 input / int1 ack
// 0x100000            P2 input
// 0x180000            P3 input / extra
// 0x200000            system / service
// 0x280000            DIP switches
// 0x300000            sound data write (to 6809)
// 0x380000            plane enable / grom bank latch
// 0x400000-0x4000FF   video (blitter) registers
// 0x480000-0x49FFFF   palette RAM
// 0x500000-0x5000FF   VRAM window (blitter draws; CPU can peek)
// 0x600000            watchdog / misc
// 0x800000-0xBFFFFF   program ROM (mirrored)
// ---------------------------------------------------------------------------

localparam [7:0] REG_INP0 = 8'h08, // >>16 of 0x080000
                 REG_INP1 = 8'h10,
                 REG_INP2 = 8'h18,
                 REG_SYS  = 8'h20,
                 REG_DIP  = 8'h28,
                 REG_SND  = 8'h30,
                 REG_PLANE= 8'h38,
                 REG_VIDEO= 8'h40,
                 REG_PAL  = 8'h48,
                 REG_VRAM = 8'h50,
                 REG_MISC = 8'h60;

// ---------------------------------------------------------------------------
// TG68K.C kernel signals
// ---------------------------------------------------------------------------
wire [31:0] cpu_a;
wire [15:0] cpu_din, cpu_do16;
wire [ 1:0] busstate;
wire        cpu_uds_n, cpu_lds_n, cpu_wr_n;
wire        cpu_as = busstate!=2'b01;   // address strobe when accessing bus
reg  [ 2:0] cpu_ipl;
reg         dtack;                       // ready to the kernel (via clkena)

assign cpu_addr = cpu_a[23:1];
assign cpu_dout = cpu_do16;
assign cpu_rnw  = cpu_wr_n;

// clock enable is gated by "bus ready": on ROM accesses wait for rom_ok
wire   bus_busy = rom_cs & ~rom_ok;
wire   clkena   = cen & ~bus_busy;

// ---------------------------------------------------------------------------
// Coarse address decode
// ---------------------------------------------------------------------------
wire [7:0] ahi = cpu_a[23:16];
reg        ram_cs, inp_cs, dip_cs, sys_cs, misc_cs;
reg        prog_sel;

always @(*) begin
    ram_cs   = cpu_a[23:20]==4'h0;          // 0x000000-0x0FFFFF (RAM/NVRAM)
    prog_sel = cpu_a[23]==1'b1;             // 0x800000+ program ROM
    inp_cs   = ahi==REG_INP0 || ahi==REG_INP1 || ahi==REG_INP2;
    sys_cs   = ahi==REG_SYS;
    dip_cs   = ahi==REG_DIP;
    vreg_cs  = ahi==REG_VIDEO;
    pal_cs   = ahi==REG_PAL;
    vram_cs  = ahi==REG_VRAM;
    misc_cs  = ahi==REG_MISC;
end

assign rom_cs   = prog_sel & (busstate==2'b00 || busstate==2'b10);
assign rom_addr = cpu_a[19:2];              // 256K long-words

// 32-bit program ROM -> 16-bit halves for TG68K
wire [15:0] rom_half = cpu_a[1] ? rom_data[15:0] : rom_data[31:16]; // TODO endianness

// ---------------------------------------------------------------------------
// Main RAM (BRAM). Battery-backed portion is mirrored to the nvram interface.
// ---------------------------------------------------------------------------
wire [15:0] ram_dout;
// TODO: instantiate jtframe_ram / dual-port BRAM sized to the real RAM/NVRAM.
// jtframe_ram #(.aw(...),.dw(16)) u_ram(...);
assign ram_dout   = 16'h0;   // placeholder
assign nvram_dout = 8'h0;    // placeholder
assign nvram_addr = 14'h0;
assign nvram_we   = 1'b0;

// ---------------------------------------------------------------------------
// CPU data-in mux
// ---------------------------------------------------------------------------
reg [15:0] inp_mux;
always @(*) begin
    case(1'b1)
        prog_sel: inp_mux = rom_half;
        ram_cs:   inp_mux = ram_dout;
        vram_cs:  inp_mux = vram_dout;
        vreg_cs:  inp_mux = vreg_dout;
        pal_cs:   inp_mux = pal_dout;
        inp_cs:   inp_mux = read_inputs(ahi);
        dip_cs:   inp_mux = {dipsw_b, dipsw_a};
        default:  inp_mux = 16'hffff;
    endcase
end
assign cpu_din = inp_mux;

// input port read helper (bit layout TODO: match itech32 port maps)
function [15:0] read_inputs(input [7:0] sel);
    case(sel)
        REG_INP0: read_inputs = ~{ joystick1[11:0], 4'h0 };
        REG_INP1: read_inputs = ~{ joystick2[11:0], 4'h0 };
        default:  read_inputs = ~{ 12'h0, service, dip_test, coin };
    endcase
endfunction

// ---------------------------------------------------------------------------
// Register writes: sound latch, plane/colour latch
// ---------------------------------------------------------------------------
always @(posedge clk) begin
    snd_latch_we <= 1'b0;
    if( rst ) begin
        plane_en    <= 2'b11;
        color_latch <= 9'd0;
        snd_latch   <= 8'd0;
    end else if( cen && ~cpu_rnw ) begin
        if( ahi==REG_SND ) begin
            snd_latch    <= cpu_do16[7:0];
            snd_latch_we <= 1'b1;
        end
        if( ahi==REG_PLANE ) begin
            plane_en    <= ~cpu_do16[2:1];      // active-low enable latch
            color_latch <= cpu_do16[8:0];
        end
    end
end

// ---------------------------------------------------------------------------
// Interrupt priority: itech32 uses autovector IRQs for blitter & vblank/scan.
// TODO: confirm IPL levels and acknowledge/clear scheme from itech32.cpp.
// ---------------------------------------------------------------------------
always @(posedge clk) begin
    if( rst ) cpu_ipl <= 3'b111;         // no IRQ (active low IPL)
    else begin
        cpu_ipl <= 3'b111;
        if( vblank_irq ) cpu_ipl <= 3'b110; // level 1 (placeholder)
        if( blit_irq   ) cpu_ipl <= 3'b101; // level 2 (placeholder)
    end
end

// DTACK/ready modelling for the kernel is folded into clkena above.
always @(posedge clk) dtack <= ~bus_busy;

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
    .nReset        ( ~rst         ),
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
