/*  This file is part of JTSFTM.  GPLv3 - see LICENSE.

    Self-checking bench for jtsftm_main. Tests:
      1. Boot vector copy FSM — rom_cs goes high on reset release, then drops
         to 0 once all 32 long-words (64 rom_ok pulses) have been copied.
      2. Reset-state outputs — plane_en=11, grom_bank=00, snd_latch_we=0,
         chip-select lines idle after boot.

    The TG68KdotC_Kernel stub (stubs.v) drives addr=0 and busstate=2'b01
    (inactive), so the CPU bus is quiet throughout and no address-decode
    outputs assert after boot.

    Run:
      iverilog -g2012 -Wall -o /tmp/tb_jtsftm_main.vvp \
          cores/sftm/ver/game/tb_jtsftm_main.v \
          cores/sftm/hdl/jtsftm_main.v \
          cores/sftm/hdl/jtsftm_ram.v \
          cores/sftm/hdl/jtsftm_prot.v \
          cores/sftm/ver/game/stubs.v && \
      vvp /tmp/tb_jtsftm_main.vvp
*/
`timescale 1ns/1ps

module tb_jtsftm_main;

    reg          clk=0, rst=1, cen=1;

    // Program ROM — always ready, arbitrary data
    wire [17:0]  rom_addr;
    reg  [31:0]  rom_data = 32'hDEAD_BEEF;
    wire         rom_cs;
    reg          rom_ok = 1'b1;   // immediate response; boots in exactly 64 clocks

    // Cabinet I/O (tied off)
    reg  [15:0]  joystick1=0, joystick2=0;
    reg  [ 1:0]  cab_1p=0, coin=0;
    reg          service=0, dip_test=0;
    reg  [ 7:0]  dipsw_a=8'hFF, dipsw_b=8'hFF;

    // Video bus (driven from testbench as video side, all zeroes)
    wire [23:1]  cpu_addr;
    wire [15:0]  cpu_dout;
    wire         cpu_rnw, cpu_uds_n, cpu_lds_n;
    wire         vram_cs, vreg_cs, pal_cs;
    reg  [15:0]  vram_dout=0, vreg_dout=0, pal_dout=0;
    wire [ 1:0]  plane_en, grom_bank;
    wire [ 6:0]  color_latch0, color_latch1;

    // Interrupts (deasserted)
    reg          blit_irq=0, scan_irq=0, vblank_irq=0;

    // Sound latch outputs
    wire [ 7:0]  snd_latch;
    wire         snd_latch_we;

    reg  [ 7:0]  debug_bus=0;

    integer      errors=0, boot_cycles=0;

    always #5 clk = ~clk;

    jtsftm_main uut(
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

    // -----------------------------------------------------------------------
    // Check helpers
    // -----------------------------------------------------------------------
    task check1;
        input        got;
        input        exp;
        input [255:0] name;
    begin
        if (got !== exp) begin
            $display("FAIL: %0s  got=%b  exp=%b", name, got, exp);
            errors = errors + 1;
        end else
            $display("ok  : %0s = %b", name, got);
    end
    endtask

    task check2;
        input [ 1:0] got;
        input [ 1:0] exp;
        input [255:0] name;
    begin
        if (got !== exp) begin
            $display("FAIL: %0s  got=%02b  exp=%02b", name, got, exp);
            errors = errors + 1;
        end else
            $display("ok  : %0s = %02b", name, got);
    end
    endtask

    // -----------------------------------------------------------------------
    // Test sequence
    // -----------------------------------------------------------------------
    initial begin
        // Hold reset for 4 cycles, then release.
        repeat(4) @(posedge clk);
        rst = 0;

        // === Test 1: rom_cs asserts immediately on reset release ===
        @(posedge clk);   // let FFs settle on first post-reset edge
        check1(rom_cs, 1'b1, "rom_cs high at boot start");

        // === Test 2: boot FSM completes within a bounded cycle count ===
        // With rom_ok=1 always, each of the 32 long-words requires 2 clock
        // cycles (one per boot_half). Total: 64 cycles.
        begin : boot_wait
            integer timeout;
            timeout = 0;
            while (rom_cs === 1'b1 && timeout < 100) begin
                @(posedge clk);
                timeout = timeout + 1;
            end
            boot_cycles = timeout;
        end

        if (rom_cs !== 1'b0) begin
            $display("FAIL: boot FSM timed out (rom_cs still 1 after 100 cycles)");
            errors = errors + 1;
        end else begin
            $display("ok  : boot done in %0d cycles", boot_cycles);
            // Expect exactly 63 loop iterations (one clock was consumed by
            // the check above, so FSM ran 1 + 63 = 64 steps total).
            if (boot_cycles < 60 || boot_cycles > 70) begin
                $display("FAIL: unexpected boot cycle count %0d", boot_cycles);
                errors = errors + 1;
            end
        end

        // Give one more clock for combinatorial paths to settle.
        repeat(2) @(posedge clk);

        // === Test 3: reset-state register outputs ===
        // plane_en resets to 2'b11 (both planes enabled)
        check2(plane_en,     2'b11, "plane_en reset");
        // grom_bank resets to 2'b00
        check2(grom_bank,    2'b00, "grom_bank reset");
        // snd_latch_we is de-asserted (no CPU write in flight)
        check1(snd_latch_we, 1'b0,  "snd_latch_we idle");

        // === Test 4: chip selects idle after boot (TG68K stub bus inactive) ===
        // busstate=2'b01 → bus_active=0, so no CS lines should fire.
        check1(vreg_cs, 1'b0, "vreg_cs idle");
        check1(pal_cs,  1'b0, "pal_cs idle");
        // vram_cs is hardwired 0 in this implementation.
        check1(vram_cs, 1'b0, "vram_cs hardwired 0");

        if (errors == 0)
            $display("PASS: jtsftm_main boot FSM and reset state");
        else
            $display("FAIL: jtsftm_main %0d checks failed", errors);
        $finish;
    end

endmodule
