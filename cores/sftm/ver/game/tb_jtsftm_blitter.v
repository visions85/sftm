/*  This file is part of JTSFTM.  GPLv3 - see LICENSE.

    Self-checking bench for jtsftm_blitter. Exercises:
      1. Normal 2x2 blit — pixel values and VRAM addresses verified.
      2. Transparency (F_TRANSP) — 0xFF pixels must not produce a VRAM write.
      3. X-flip (F_XFLIP)       — destination X counts downward.
      4. Y-flip (F_YFLIP)       — destination Y counts downward.
      5. plane_sel propagation.
      6. Clip rect (F_CLIP=bit10):
           6a. F_CLIP set: 4x4 blit clipped to 2x2 window → 4 VRAM writes.
           6b. F_CLIP clear: same blit with same clip regs → all 16 writes.

    GROM model: word address W returns { 2W+1, 2W } so byte address N = N[7:0].
    All pixel values used in the normal/flip tests are < 0xFF (non-transparent).

    Run:
      iverilog -g2012 -Wall -o /tmp/tb_jtsftm_blitter.vvp \
          cores/sftm/ver/game/tb_jtsftm_blitter.v cores/sftm/hdl/jtsftm_blitter.v && \
      vvp /tmp/tb_jtsftm_blitter.vvp
*/
`timescale 1ns/1ps

module tb_jtsftm_blitter;

    // DUT ports
    reg         clk=0, rst=1;
    reg  [15:0] r_command=0, r_flags=0, r_width=0, r_height=0;
    reg  [15:0] r_x=0, r_y=0, r_addrlo=0, r_addrhi=0;
    // Clip rect regs (12-bit pixel coordinates). Default: full range, no clip.
    reg  [11:0] r_leftclip=12'd0, r_rightclip=12'hfff,
                r_topclip =12'd0, r_botclip  =12'hfff;
    // Source / destination x-step (8.8 fixed-point; 0x0100 = 1:1).
    reg  [15:0] r_srcxstep=16'h0100;
    reg  [15:0] r_dstxstep=16'h0100;
    reg         start=0, plane_sel=0;
    reg  [ 1:0] grom_bank=0;

    wire [23:0] grom_addr;
    wire        grom_cs;
    wire        vram_we;
    wire [16:0] vram_addr;
    wire [ 7:0] vram_data;
    wire        vram_plane;
    wire        done;

    // -----------------------------------------------------------------------
    // GROM model: byte address N = N[7:0].  Two bytes per 16-bit word:
    //   word W  →  data = { (2W+1)[7:0], (2W)[7:0] }
    // src_pix for byte N = (N & 1) ? data[15:8] : data[7:0]
    //                    = (N & 1) ? 2W+1        : 2W
    //                    = N[7:0]   in all cases.
    // -----------------------------------------------------------------------
    reg  [15:0] grom_data;
    always @(*)
        grom_data = { (grom_addr[7:0] << 1) + 8'h01,
                      (grom_addr[7:0] << 1) };

    // grom_ok: combinatorial — respond in the same cycle grom_cs is asserted.
    // The FETCH state checks grom_ok on the clock after asserting grom_cs,
    // so using grom_cs directly gives exactly 1 FETCH cycle per pixel.
    jtsftm_blitter uut(
        .rst(rst), .clk(clk),
        .r_command(r_command), .r_flags(r_flags),
        .r_width(r_width), .r_height(r_height),
        .r_x(r_x), .r_y(r_y), .r_addrlo(r_addrlo), .r_addrhi(r_addrhi),
        .r_leftclip(r_leftclip), .r_rightclip(r_rightclip),
        .r_topclip(r_topclip),   .r_botclip(r_botclip),
        .r_srcxstep(r_srcxstep), .r_dstxstep(r_dstxstep),
        .start(start), .plane_sel(plane_sel), .grom_bank(grom_bank),
        .grom_addr(grom_addr), .grom_data(grom_data),
        .grom_cs(grom_cs), .grom_ok(grom_cs),
        .vram_we(vram_we), .vram_addr(vram_addr), .vram_data(vram_data),
        .vram_plane(vram_plane), .done(done)
    );

    // -----------------------------------------------------------------------
    // VRAM shadow — capture every write so we can check pixel values.
    // Initialise to 0xFF (transparent fill) so un-written entries are obvious.
    // -----------------------------------------------------------------------
    reg [7:0] vram [0:131071];   // 2^17 entries
    integer   write_cnt=0, errors=0;
    integer   k;

    initial begin
        for (k=0; k<131072; k=k+1) vram[k] = 8'hff;
    end

    always @(posedge clk) begin
        if (vram_we) begin
            vram[vram_addr] <= vram_data;
            write_cnt       =  write_cnt + 1;
        end
    end

    always #5 clk = ~clk;

    // -----------------------------------------------------------------------
    // Helpers
    // -----------------------------------------------------------------------
    task do_blit;
        input [15:0] px, py, pw, ph;
        input [15:0] alo, ahi, flags;
        input        psel;
        integer      timeout;
    begin
        r_x      = px;  r_y     = py;
        r_width  = pw;  r_height= ph;
        r_addrlo = alo; r_addrhi= ahi;
        r_flags  = flags;
        plane_sel= psel;
        @(negedge clk); start = 1'b1;
        @(posedge clk);
        @(negedge clk); start = 1'b0;
        timeout = 100000;
        while (!done && timeout > 0) begin
            @(posedge clk);
            timeout = timeout - 1;
        end
        if (timeout == 0) begin
            $display("FAIL: blit timed out");
            errors = errors + 1;
        end
        repeat(2) @(posedge clk);   // settle
    end
    endtask

    task check_pix;
        input [16:0] addr;
        input [ 7:0] exp;
        input [255:0] name;
    begin
        if (vram[addr] !== exp) begin
            $display("FAIL: %0s  addr=%05h  got=%02h  exp=%02h",
                     name, addr, vram[addr], exp);
            errors = errors + 1;
        end
    end
    endtask

    // -----------------------------------------------------------------------
    // Test sequence
    // -----------------------------------------------------------------------
    initial begin
        repeat(4) @(posedge clk);
        rst = 0;
        repeat(2) @(posedge clk);

        // === Test 1: 2x2 normal blit at (5,6), GROM byte addr 0 ===
        // r_dstxstep default 0x0100 throughout tests 1-7.
        // r_width=1, r_height=1 → (r_width+1) x (r_height+1) = 2x2 pixels
        // Byte 0 → pixel 0x00 @ vram{6,5}  = 17'h0C05
        // Byte 1 → pixel 0x01 @ vram{6,6}  = 17'h0C06
        // Byte 2 → pixel 0x02 @ vram{7,5}  = 17'h0E05
        // Byte 3 → pixel 0x03 @ vram{7,6}  = 17'h0E06
        write_cnt = 0;
        do_blit(16'h0005, 16'h0006, 16'h0001, 16'h0001,
                16'h0000, 16'h0000, 16'h0000, 1'b0);
        if (write_cnt !== 4) begin
            $display("FAIL: test1 write_cnt=%0d (expected 4)", write_cnt);
            errors = errors + 1;
        end
        check_pix(17'h0C05, 8'h00, "t1 pix(5,6)");
        check_pix(17'h0C06, 8'h01, "t1 pix(6,6)");
        check_pix(17'h0E05, 8'h02, "t1 pix(5,7)");
        check_pix(17'h0E06, 8'h03, "t1 pix(6,7)");

        // === Test 2: transparency (F_TRANSP=bit0) ===
        // GROM word 0 = {0x01, 0x00}: byte0=0x00 (opaque), byte1=0x01 (opaque).
        // Override: use a 1-wide blit starting at GROM byte addr where byte0=0xFF.
        // The GROM model: byte N = N[7:0].  Byte 0xFF = 0xFF → transparent.
        // Set r_addrlo so src byte 0 = byte address 0xFF.
        // src init: src = {grom_bank[0], r_addrhi[7:0], r_addrlo} = {0,0,0xFF}
        // Byte 0xFF (word addr 0x7F): grom_data={0xFF,0xFE}, src[0]=1 → 0xFF (transparent)
        // Byte 0xFE (word addr 0x7F): grom_data={0xFF,0xFE}, src[0]=0 → 0xFE (opaque)
        // Two-pixel blit at y=10: src starts at byte 0xFE (even byte of word 0x7F)
        //   pixel0 src[0]=0 → 0xFE → opaque, write at (5,10)  = vram{10,5}=17'h1405
        //   pixel1 src[0]=1 → 0xFF → transparent, skip
        write_cnt = 0;
        do_blit(16'h0005, 16'h000A, 16'h0001, 16'h0000,
                16'h00FE, 16'h0000, 16'h0001, 1'b0);  // flags[0]=F_TRANSP
        if (write_cnt !== 1) begin
            $display("FAIL: test2 write_cnt=%0d (expected 1, transparent skipped)",
                     write_cnt);
            errors = errors + 1;
        end
        check_pix(17'h1405, 8'hFE, "t2 opaque pix");
        // Transparent pixel at (6,10) must remain 0xFF (unchanged)
        check_pix(17'h1406, 8'hFF, "t2 transparent pix untouched");

        // === Test 3: X-flip (F_XFLIP=bit1) ===
        // 2x1 blit at (10,12), GROM addr 0, flags=2
        // curx starts at 10, decrements each pixel:
        //   pixel0 = byte 0x00 @ (10,12) = vram{12,10} = 17'h180A
        //   pixel1 = byte 0x01 @ ( 9,12) = vram{12, 9} = 17'h1809
        write_cnt = 0;
        do_blit(16'h000A, 16'h000C, 16'h0001, 16'h0000,
                16'h0000, 16'h0000, 16'h0002, 1'b0);  // flags[1]=F_XFLIP
        if (write_cnt !== 2) begin
            $display("FAIL: test3 write_cnt=%0d (expected 2)", write_cnt);
            errors = errors + 1;
        end
        check_pix(17'h180A, 8'h00, "t3 xflip pix0 (10,12)");
        check_pix(17'h1809, 8'h01, "t3 xflip pix1 ( 9,12)");

        // === Test 4: Y-flip (F_YFLIP=bit2) ===
        // 1x2 blit at (5,20), GROM addr 0, flags=4
        // cury starts at 20, decrements each row:
        //   pixel0 = byte 0x00 @ (5,20) = vram{20,5} = 17'h2805
        //   pixel1 = byte 0x01 @ (5,19) = vram{19,5} = 17'h2605
        write_cnt = 0;
        do_blit(16'h0005, 16'h0014, 16'h0000, 16'h0001,
                16'h0000, 16'h0000, 16'h0004, 1'b0);  // flags[2]=F_YFLIP
        if (write_cnt !== 2) begin
            $display("FAIL: test4 write_cnt=%0d (expected 2)", write_cnt);
            errors = errors + 1;
        end
        check_pix(17'h2805, 8'h00, "t4 yflip pix0 (5,20)");
        check_pix(17'h2605, 8'h01, "t4 yflip pix1 (5,19)");

        // === Test 5: plane_sel propagated to vram_plane ===
        // A 1x1 blit on plane 1: check vram_plane stayed 1 throughout
        // (captured at write time; just verify via the done side-effect).
        // We check implicitly: if plane_sel=1 made it through IDLE→start, done fires.
        do_blit(16'h0030, 16'h0030, 16'h0000, 16'h0000,
                16'h0000, 16'h0000, 16'h0000, 1'b1);
        // vram_plane should have been 1 for that write
        // (confirmed by no errors in the done-wait; vram_plane is an output wire)
        if (vram_plane !== 1'b1) begin
            $display("FAIL: test5 vram_plane=%b after plane_sel=1", vram_plane);
            errors = errors + 1;
        end

        // === Test 6a: F_CLIP enabled — 4x4 blit clipped to 2x2 window ===
        // Blit 4x4 pixels at (8,8), GROM addr 0, F_CLIP=1 (bit10).
        // Clip window: left=10, right=12, top=10, bot=12  (→ x∈[10,11], y∈[10,11]).
        //
        // Pixel layout (GROM byte → destination):
        //   row y=8:  bytes 0-3  → (8,8)-(11,8)   all outside top clip
        //   row y=9:  bytes 4-7  → (8,9)-(11,9)   all outside top clip
        //   row y=10: bytes 8-11 → (8,10)-(11,10)  (8,10) and (9,10) outside left clip
        //                          byte10→(10,10) ✓  byte11→(11,10) ✓
        //   row y=11: bytes12-15 → (8,11)-(11,11)  same left clip
        //                          byte14→(10,11) ✓  byte15→(11,11) ✓
        //
        // GROM model: byte N = N[7:0].
        //   byte 10 = 8'h0A  @ vram{10,10} = 17'h140A
        //   byte 11 = 8'h0B  @ vram{10,11} = 17'h140B
        //   byte 14 = 8'h0E  @ vram{11,10} = 17'h160A
        //   byte 15 = 8'h0F  @ vram{11,11} = 17'h160B
        r_leftclip = 12'd10;  r_rightclip = 12'd12;
        r_topclip  = 12'd10;  r_botclip   = 12'd12;
        write_cnt = 0;
        do_blit(16'h0008, 16'h0008, 16'h0003, 16'h0003,
                16'h0000, 16'h0000, 16'h0400, 1'b0);  // F_CLIP=bit10
        if (write_cnt !== 4) begin
            $display("FAIL: t6a write_cnt=%0d (expected 4 clipped writes)", write_cnt);
            errors = errors + 1;
        end
        check_pix(17'h140A, 8'h0A, "t6a clipped (10,10)");
        check_pix(17'h140B, 8'h0B, "t6a clipped (11,10)");
        check_pix(17'h160A, 8'h0E, "t6a clipped (10,11)");
        check_pix(17'h160B, 8'h0F, "t6a clipped (11,11)");
        // Pixels outside clip must be untouched (still 0xFF from init)
        check_pix(17'h1008, 8'hFF, "t6a outside top (8,8)");
        check_pix(17'h1408, 8'hFF, "t6a outside left (8,10)");

        // === Test 6b: F_CLIP clear — same clip regs, all 16 pixels written ===
        // Blit 4x4 at (50,50) (fresh VRAM area), flags=0 (no F_CLIP).
        // clip regs still set to 10-12; they must be ignored.
        write_cnt = 0;
        do_blit(16'h0032, 16'h0032, 16'h0003, 16'h0003,
                16'h0000, 16'h0000, 16'h0000, 1'b0);  // no F_CLIP
        if (write_cnt !== 16) begin
            $display("FAIL: t6b write_cnt=%0d (expected 16, clip disabled)", write_cnt);
            errors = errors + 1;
        end
        // Reset clip to full range for safety
        r_leftclip = 12'd0;   r_rightclip = 12'hfff;
        r_topclip  = 12'd0;   r_botclip   = 12'hfff;

        // === Test 7: SRC_XSTEP=0x200 (2:1 x-scaling) ===
        // 3-pixel blit at (20,30), GROM addr 0, r_srcxstep=0x200.
        // src advances by 2 per dest pixel (skip every other source byte).
        // GROM model: byte N = N[7:0].  With step=2, bytes used: 0, 2, 4.
        //   src=0 (even) → word 0 data[7:0] = 0x00 @ vram{30,20} = 17'h3C14
        //   src=2 (even) → word 1 data[7:0] = 0x02 @ vram{30,21} = 17'h3C15
        //   src=4 (even) → word 2 data[7:0] = 0x04 @ vram{30,22} = 17'h3C16
        r_srcxstep = 16'h0200;
        write_cnt = 0;
        do_blit(16'h0014, 16'h001E, 16'h0002, 16'h0000,
                16'h0000, 16'h0000, 16'h0000, 1'b0);  // r_width=2 → 3 dest pixels
        if (write_cnt !== 3) begin
            $display("FAIL: t7 write_cnt=%0d (expected 3)", write_cnt);
            errors = errors + 1;
        end
        check_pix(17'h3C14, 8'h00, "t7 srcxstep=2 pix0 (20,30)");
        check_pix(17'h3C15, 8'h02, "t7 srcxstep=2 pix1 (21,30)");
        check_pix(17'h3C16, 8'h04, "t7 srcxstep=2 pix2 (22,30)");
        r_srcxstep = 16'h0100;  // restore 1:1

        // === Test 8: DST_XSTEP=0x200 — 2:1 destination stretch, F_DSTXSCALE ===
        // 3-pixel blit at (0,60), GROM addr 0, r_srcxstep=0x100, r_dstxstep=0x200.
        // dest X advances by 2 each pixel:
        //   pixel0 byte0=0x00  @ vram{60, 0} = 17'h7800
        //   pixel1 byte1=0x01  @ vram{60, 2} = 17'h7802
        //   pixel2 byte2=0x02  @ vram{60, 4} = 17'h7804
        // (vram_addr = {cury[7:0], curx[8:0]}; cury=60=0x3c, curx bits [7:0] * 2)
        r_dstxstep = 16'h0200;
        write_cnt = 0;
        do_blit(16'h0000, 16'h003c, 16'h0002, 16'h0000,
                16'h0000, 16'h0000, 16'h0008, 1'b0);  // F_DSTXSCALE=bit3
        if (write_cnt !== 3) begin
            $display("FAIL: t8 write_cnt=%0d (expected 3)", write_cnt);
            errors = errors + 1;
        end
        check_pix(17'h7800, 8'h00, "t8 dstxstep=2 pix0 (0,60)");
        check_pix(17'h7802, 8'h01, "t8 dstxstep=2 pix1 (2,60)");
        check_pix(17'h7804, 8'h02, "t8 dstxstep=2 pix2 (4,60)");
        r_dstxstep = 16'h0100;  // restore 1:1

        // === Test 9: Fractional DST_XSTEP=0x180 (1.5 dest pixels per source) ===
        // 3-pixel blit at (0,65), GROM addr 0, r_srcxstep=0x100, r_dstxstep=0x180.
        // dst_xfrac accumulation (frac byte of 0x180 is 0x80):
        //   pixel0: dst_xfrac=0+0x80=0x80 (no carry); dst_x_int=1; curx: 0→1
        //   pixel1: dst_xfrac=0x80+0x80=0x100→carry; dst_x_int=1+1=2; curx: 1→3
        //   pixel2: (end-of-row check fires at xcnt==r_width, so xcnt=2 terminates)
        //           but pixel2 is written at curx=3 before STEP runs → written ✓
        // Destination positions: 0, 1, 3.
        //   vram{65,0}=17'h8200, {65,1}=17'h8201, {65,3}=17'h8203
        //   (cury=65=0x41, so {0x41,9'h000}=17'h8200, etc.)
        r_dstxstep = 16'h0180;
        write_cnt = 0;
        do_blit(16'h0000, 16'h0041, 16'h0002, 16'h0000,
                16'h0000, 16'h0000, 16'h0008, 1'b0);  // F_DSTXSCALE=bit3
        if (write_cnt !== 3) begin
            $display("FAIL: t9 write_cnt=%0d (expected 3)", write_cnt);
            errors = errors + 1;
        end
        check_pix(17'h8200, 8'h00, "t9 dstxstep=1.5 pix0 (0,65)");
        check_pix(17'h8201, 8'h01, "t9 dstxstep=1.5 pix1 (1,65)");
        check_pix(17'h8203, 8'h02, "t9 dstxstep=1.5 pix2 (3,65)");
        r_dstxstep = 16'h0100;  // restore 1:1

        if (errors == 0)
            $display("PASS: jtsftm_blitter all checks");
        else
            $display("FAIL: jtsftm_blitter %0d checks failed", errors);
        $finish;
    end

endmodule
