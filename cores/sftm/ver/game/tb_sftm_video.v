/*  This file is part of SFTM.  GPLv3 - see LICENSE.

    Self-checking bench for the IT42/video memory-mapped I/O block. It drives
    the CPU-facing register bus directly so it can run before the 68EC020 core
    is vendored.
*/
`timescale 1ns/1ps

module tb_sftm_video;
    localparam VIDEO_STATUS  = 8'h00;
    localparam VIDEO_INTACK  = 8'h02;
    localparam VIDEO_XFER    = 8'h04;
    localparam VIDEO_COMMAND = 8'h08;
    localparam VIDEO_INTEN   = 8'h0a;
    localparam VIDEO_XFERH   = 8'h0c;
    localparam VIDEO_XFERW   = 8'h0e;
    localparam VIDEO_XFERX   = 8'h12;
    localparam VIDEO_XFERY   = 8'h14;

    localparam VIDEOINT_BLITTER = 16'h0040;

    reg         clk=0, rst=1;
    reg         pxl_cen=1, pxl2_cen=1;
    reg [23:1]  cpu_addr=23'd0;
    reg [15:0]  cpu_dout=16'd0;
    reg         cpu_rnw=1;
    reg         cpu_uds_n=1, cpu_lds_n=1;
    reg         vram_cs=0, vreg_cs=0, pal_cs=0;
    wire [15:0] vram_dout, vreg_dout, pal_dout;
    reg [ 1:0]  plane_en=2'b01;       // foreground only for transfer tests
    reg [ 1:0]  grom_bank=2'b00;
    reg [ 6:0]  color_latch0=7'd0, color_latch1=7'd1;

    wire [23:0] grom_addr;
    reg  [15:0] grom_data=16'h3412;
    wire        grom_cs;
    reg         grom_ok=1;
    wire [17:0] grm3_addr;
    reg  [15:0] grm3_data=16'h0;
    wire        grm3_cs;
    reg         grm3_ok=1;

    wire        blit_irq, vblank_irq;
    wire        HS, VS, LHBL, LVBL;
    wire [4:0]  red, green, blue;
    integer     errors=0;
    reg [15:0]  q;

    always #5 clk = ~clk;

    sftm_video uut(
        .rst(rst), .clk(clk), .pxl_cen(pxl_cen), .pxl2_cen(pxl2_cen),
        .cpu_addr(cpu_addr), .cpu_dout(cpu_dout), .cpu_rnw(cpu_rnw),
        .cpu_uds_n(cpu_uds_n), .cpu_lds_n(cpu_lds_n),
        .vram_cs(vram_cs), .vreg_cs(vreg_cs), .pal_cs(pal_cs),
        .vram_dout(vram_dout), .vreg_dout(vreg_dout), .pal_dout(pal_dout),
        .plane_en(plane_en), .grom_bank(grom_bank),
        .color_latch0(color_latch0), .color_latch1(color_latch1),
        .grom_addr(grom_addr), .grom_data(grom_data),
        .grom_cs(grom_cs), .grom_ok(grom_ok),
        .grm3_addr(grm3_addr), .grm3_data(grm3_data),
        .grm3_cs(grm3_cs), .grm3_ok(grm3_ok),
        .blit_irq(blit_irq), .vblank_irq(vblank_irq),
        .HS(HS), .VS(VS), .LHBL(LHBL), .LVBL(LVBL),
        .red(red), .green(green), .blue(blue),
        .gfx_en(4'hf), .debug_bus(8'h00)
    );

    task idle_bus;
        begin
            vram_cs   = 1'b0;
            vreg_cs   = 1'b0;
            pal_cs    = 1'b0;
            cpu_rnw   = 1'b1;
            cpu_uds_n = 1'b1;
            cpu_lds_n = 1'b1;
            cpu_dout  = 16'h0000;
        end
    endtask

    task check16;
        input [15:0] got;
        input [15:0] exp;
        input [1023:0] name;
        begin
            if( got !== exp ) begin
                errors = errors + 1;
                $display("FAIL: %0s got=%04h expected=%04h", name, got, exp);
            end
        end
    endtask

    task check1;
        input got;
        input exp;
        input [1023:0] name;
        begin
            if( got !== exp ) begin
                errors = errors + 1;
                $display("FAIL: %0s got=%b expected=%b", name, got, exp);
            end
        end
    endtask

    task vreg_write_mask;
        input [7:0]  off;
        input [15:0] data;
        input        uds_active;
        input        lds_active;
        begin
            @(negedge clk);
            cpu_addr  = { 16'd0, off[7:1] };
            cpu_dout  = data;
            cpu_rnw   = 1'b0;
            cpu_uds_n = ~uds_active;
            cpu_lds_n = ~lds_active;
            vreg_cs   = 1'b1;
            @(posedge clk);
            #1;
            @(negedge clk);
            idle_bus();
        end
    endtask

    task vreg_write;
        input [7:0]  off;
        input [15:0] data;
        begin
            vreg_write_mask(off, data, 1'b1, 1'b1);
        end
    endtask

    task vreg_read;
        input  [7:0]  off;
        output [15:0] data;
        begin
            @(negedge clk);
            cpu_addr  = { 16'd0, off[7:1] };
            cpu_rnw   = 1'b1;
            cpu_uds_n = 1'b1;
            cpu_lds_n = 1'b1;
            vreg_cs   = 1'b1;
            @(posedge clk);
            #1 data = vreg_dout;
            @(negedge clk);
            idle_bus();
        end
    endtask

    task pal_write;
        input [14:0] idx;
        input [15:0] data;
        begin
            @(negedge clk);
            cpu_addr  = { 8'd0, idx };
            cpu_dout  = data;
            cpu_rnw   = 1'b0;
            cpu_uds_n = 1'b0;
            cpu_lds_n = 1'b0;
            pal_cs    = 1'b1;
            @(posedge clk);
            #1;
            @(negedge clk);
            idle_bus();
        end
    endtask

    task pal_read;
        input  [14:0] idx;
        output [15:0] data;
        begin
            @(negedge clk);
            cpu_addr  = { 8'd0, idx };
            cpu_rnw   = 1'b1;
            pal_cs    = 1'b1;
            @(posedge clk);
            #1 data = pal_dout;
            @(negedge clk);
            idle_bus();
        end
    endtask

    task xfer_write;
        input [7:0] pix;
        begin
            vreg_write(VIDEO_XFER, { 8'h00, pix });
            repeat(2) @(posedge clk); // transfer writes are pipelined into VRAM
        end
    endtask

    initial begin
        idle_bus();
        repeat(5) @(posedge clk);
        rst = 1'b0;
        repeat(3) @(posedge clk);

        vreg_read(VIDEO_STATUS, q);
        check16(q, 16'h0005, "status read constant bits");

        vreg_write(VIDEO_XFERW, 16'h1234);
        vreg_write_mask(VIDEO_XFERW, 16'habcd, 1'b0, 1'b1);
        vreg_read(VIDEO_XFERW, q);
        check16(q, 16'h12cd, "byte-mask low register write");

        pal_write(15'h0123, 16'h2a5a);
        pal_read(15'h0123, q);
        check16(q, 16'h2a5a, "palette CPU write/read");

        vreg_write(VIDEO_INTEN, VIDEOINT_BLITTER);
        vreg_write(VIDEO_COMMAND, 16'h0005);
        repeat(3) @(posedge clk);
        vreg_read(VIDEO_INTACK, q);
        check16(q & VIDEOINT_BLITTER, VIDEOINT_BLITTER, "blitter interrupt state set");
        check1(blit_irq, 1'b1, "blitter IRQ masked on");

        vreg_write(VIDEO_INTACK, VIDEOINT_BLITTER);
        repeat(2) @(posedge clk);
        vreg_read(VIDEO_INTACK, q);
        check16(q & VIDEOINT_BLITTER, 16'h0000, "blitter interrupt ack clear");
        check1(blit_irq, 1'b0, "blitter IRQ masked clear");

        // Command 3 sets up CPU-driven raw transfers through VIDEO_XFER.
        vreg_write(VIDEO_XFERX, 16'h0005);
        vreg_write(VIDEO_XFERY, 16'h0006);
        vreg_write(VIDEO_XFERW, 16'h0002);
        vreg_write(VIDEO_XFERH, 16'h0001);
        vreg_write(VIDEO_COMMAND, 16'h0003);
        repeat(4) @(posedge clk);
        vreg_write(VIDEO_INTACK, VIDEOINT_BLITTER);
        xfer_write(8'ha5);
        xfer_write(8'hb6);

        // Re-run command 3 over the same pixels. Each transfer write should
        // report the previous VRAM byte in VIDEO_XFER before replacing it.
        vreg_write(VIDEO_XFERX, 16'h0005);
        vreg_write(VIDEO_XFERY, 16'h0006);
        vreg_write(VIDEO_XFERW, 16'h0001);
        vreg_write(VIDEO_XFERH, 16'h0001);
        vreg_write(VIDEO_COMMAND, 16'h0003);
        repeat(4) @(posedge clk);
        xfer_write(8'hc3);
        vreg_read(VIDEO_XFER, q);
        check16(q, 16'h00a5, "VIDEO_XFER readback pixel 0");

        vreg_write(VIDEO_XFERX, 16'h0006);
        vreg_write(VIDEO_XFERY, 16'h0006);
        vreg_write(VIDEO_XFERW, 16'h0001);
        vreg_write(VIDEO_XFERH, 16'h0001);
        vreg_write(VIDEO_COMMAND, 16'h0003);
        repeat(4) @(posedge clk);
        xfer_write(8'hd4);
        vreg_read(VIDEO_XFER, q);
        check16(q, 16'h00b6, "VIDEO_XFER readback pixel 1");

        if( errors==0 )
            $display("PASS: sftm_video memory-mapped I/O");
        else
            $display("FAIL: %0d sftm_video checks failed", errors);

        $finish;
    end
endmodule
