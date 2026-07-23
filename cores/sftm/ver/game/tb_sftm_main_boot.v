/*  This file is part of SFTM.  GPLv3 - see LICENSE.

    Full-boot testbench for sftm_main using the real TG68KdotC_Kernel CPU
    (TG68KdotC_Kernel_conv.v, produced by ghdl synth).  Unlike tb_sftm_main.v
    which uses a CPU stub (busstate always inactive), this bench exercises the
    complete boot path:

      1. Boot vector copy FSM — ROM LW[0..31] copied to main RAM
      2. CPU released (nReset deasserts)
      3. CPU reads reset vector from RAM (SSP at 0x000000, PC at 0x000004)
      4. CPU jumps to PC (0x800008, first real instruction in ROM space)
      5. CPU fetches a NOP (0x4E71) and continues executing

    ROM image supplied:
      LW[0] = 0x0000_7FFE  — SSP (top of 32 KB main RAM)
      LW[1] = 0x0080_0008  — PC  (byte offset 8 = first instruction in ROM)
      LW[2..31] = 0x4E71_4E71 — NOP NOP (32-bit packing of two 16-bit NOPs)
      LW[32+] = 0x4E71_4E71  — infinite NOP sled (CPU loops here)

    Run:
      iverilog -g2012 -Wall -o /tmp/tb_sftm_main_boot.vvp \
          cores/sftm/ver/game/tb_sftm_main_boot.v \
          cores/sftm/hdl/sftm_main.v \
          cores/sftm/hdl/sftm_ram.v \
          cores/sftm/hdl/sftm_prot.v \
          cores/sftm/hdl/tg68k/TG68KdotC_Kernel_conv.v && \
      vvp /tmp/tb_sftm_main_boot.vvp
*/
`timescale 1ns/1ps

module tb_sftm_main_boot;

// ---------------------------------------------------------------------------
// Clocks and reset
// ---------------------------------------------------------------------------
reg clk = 0;
reg rst = 1;
reg cen = 0;         // gated CPU enable (50 % duty, every other edge)

always #5  clk = ~clk;          // 100 MHz sim clock (10 ns period)
always @(posedge clk) cen <= ~cen; // 50 MHz CPU enable (every other clock)

// ---------------------------------------------------------------------------
// ROM model: responds with proper reset vectors + NOP sled.
// rom_ok stays permanently high (immediate response) so the boot FSM and the
// CPU see data on the SAME cycle they assert rom_cs.  rom_data is purely
// combinatorial on rom_addr so the address-to-data path has no pipeline delay
// (avoids an off-by-one where the registered address lags the FSM update).
// ---------------------------------------------------------------------------
wire [17:0]  rom_addr;
reg          rom_ok = 1'b1;    // always-ready: no SDRAM latency modelled
wire         rom_cs;
reg  [31:0]  rom_data;

// ROM contents.  boot FSM drives rom_addr = {13'd0, boot_lw} so LW[0]=SSP,
// LW[1]=PC.  After boot the CPU drives rom_addr = cpu_a[19:2] so LW[2+]=code.
always @(*) begin
    case (rom_addr)
        18'd0:   rom_data = 32'h0000_7FFE;   // SSP = 0x0000_7FFE
        18'd1:   rom_data = 32'h0080_0008;   // PC  = 0x0080_0008
        default: rom_data = 32'h4E71_4E71;   // NOP NOP
    endcase
end

// ---------------------------------------------------------------------------
// Tied-off cabinet / video bus signals
// ---------------------------------------------------------------------------
reg  [15:0]  joystick1=0, joystick2=0;
reg  [ 1:0]  cab_1p=0, coin=0;
reg          service=0, dip_test=0;
reg  [ 7:0]  dipsw_a=8'hFF, dipsw_b=8'hFF;

wire [23:1]  cpu_addr;
wire [15:0]  cpu_dout;
wire         cpu_rnw, cpu_uds_n, cpu_lds_n;
wire         vram_cs, vreg_cs, pal_cs;
reg  [15:0]  vram_dout=0, vreg_dout=0, pal_dout=0;
wire [ 1:0]  plane_en, grom_bank;
wire [ 6:0]  color_latch0, color_latch1;

reg          blit_irq=0, scan_irq=0, vblank_irq=0;
wire [ 7:0]  snd_latch;
wire         snd_latch_we;
reg  [ 7:0]  debug_bus=0;

// ---------------------------------------------------------------------------
// DUT
// ---------------------------------------------------------------------------
sftm_main uut(
    .rst(rst),         .clk(clk),        .cen(cen),
    .rom_addr(rom_addr), .rom_data(rom_data),
    .rom_cs(rom_cs),   .rom_ok(rom_ok),
    .joystick1(joystick1), .joystick2(joystick2),
    .cab_1p(cab_1p),   .coin(coin),
    .service(service), .dip_test(dip_test),
    .dipsw_a(dipsw_a), .dipsw_b(dipsw_b),
    .cpu_addr(cpu_addr), .cpu_dout(cpu_dout),
    .cpu_rnw(cpu_rnw), .cpu_uds_n(cpu_uds_n), .cpu_lds_n(cpu_lds_n),
    .vram_cs(vram_cs), .vreg_cs(vreg_cs),   .pal_cs(pal_cs),
    .vram_dout(vram_dout), .vreg_dout(vreg_dout), .pal_dout(pal_dout),
    .plane_en(plane_en), .grom_bank(grom_bank),
    .color_latch0(color_latch0), .color_latch1(color_latch1),
    .blit_irq(blit_irq), .scan_irq(scan_irq), .vblank_irq(vblank_irq),
    .snd_latch(snd_latch), .snd_latch_we(snd_latch_we),
    .debug_bus(debug_bus)
);

// ---------------------------------------------------------------------------
// Check helpers
// ---------------------------------------------------------------------------
integer errors = 0;

task check_eq32;
    input [31:0] got;
    input [31:0] exp;
    input [255:0] name;
begin
    if (got !== exp) begin
        $display("FAIL: %0s  got=%08h  exp=%08h", name, got, exp);
        errors = errors + 1;
    end else
        $display("ok  : %0s = %08h", name, got);
end
endtask

// ---------------------------------------------------------------------------
// Test sequence
// ---------------------------------------------------------------------------
// ROM space: cpu_a[23:22] == 2'b10 → 0x800000-0xBFFFFF
// First ROM fetch after reset should be at PC = 0x800008 (byte) → cpu_addr = cpu_a[23:1] = 23'h40_0004
localparam [22:0] EXP_PC_WORD = 23'h40_0004;   // cpu_a[23:1] for 0x800008

integer  cyc;
reg      saw_pc_fetch;

initial begin
    // Hold reset for 6 clock edges.
    repeat(6) @(posedge clk);
    rst = 0;

    // --- Phase 1: wait for boot FSM to complete (rom_cs must go low) ---
    cyc = 0;
    while (rom_cs === 1'b1 && cyc < 500) begin
        @(posedge clk);
        cyc = cyc + 1;
    end
    if (rom_cs !== 1'b0) begin
        $display("FAIL: boot FSM timed out — rom_cs still high after %0d cycles", cyc);
        errors = errors + 1;
    end else
        $display("ok  : boot vector copy done in ~%0d cycles", cyc);

    // --- Phase 2: wait for CPU to fetch from ROM space (PC = 0x800008) ---
    saw_pc_fetch = 0;
    for (cyc = 0; cyc < 5000 && !saw_pc_fetch; cyc = cyc + 1) begin
        @(posedge clk);
        // cpu_addr = cpu_a[23:1].  ROM space starts at 0x800000 → word addr 0x400000.
        // We look for the CPU asserting rom_cs and presenting the PC address.
        if (rom_cs && (cpu_addr == EXP_PC_WORD)) begin
            saw_pc_fetch = 1;
            $display("ok  : CPU first ROM fetch at cpu_addr=%06h (0x800008) after %0d cycles",
                     cpu_addr, cyc);
        end
    end
    if (!saw_pc_fetch) begin
        $display("FAIL: CPU never fetched from 0x800008 within 5000 cycles");
        $display("      last cpu_addr=%06h  rom_cs=%b", cpu_addr, rom_cs);
        errors = errors + 1;
    end

    // --- Summary ---
    if (errors == 0)
        $display("PASS: sftm_main full boot path — boot copy + CPU reset vector + ROM fetch");
    else
        $display("FAIL: %0d checks failed", errors);
    $finish;
end

// Watchdog: bail after 100000 cycles in case of deadlock.
initial begin
    #1000000;
    $display("TIMEOUT: simulation ran >100000 cycles — deadlock?");
    $finish;
end

endmodule
