`timescale 1ns/1ps
/*  This file is part of SFTM.
    SFTM is free software: you can redistribute it and/or modify it under the
    terms of the GNU General Public License as published by the Free Software
    Foundation, either version 3 of the License, or (at your option) any later
    version. See the LICENSE file.

    Street Fighter: The Movie -- VRAM in SDRAM (see doc/PHASE2-DESIGN.md).

    2 MB (2 planes x 512x1024 x 16-bit pen) on the jtframe rw bus `vram` in
    bank 3. Word address = {plane, offs[18:0]}.

    Clients, priority order:
      1. scanline prefetch: on `line_go`, burst-reads 384 words of plane 0
         starting at line_base (with vram_mask wrap) into the ping-pong line
         buffer selected by line_sel.
      2. blitter read port (vr_*): single-word reads. Reads WAIT until the
         write FIFO is empty, so a read can never overtake a queued write to
         the same address (shiftreg source rows, cmd-3 read-modify-write).
      3. blitter write FIFO (vw_*): depth 16.

    The scanout side reads the OTHER line buffer (the one filled during the
    previous line) at pixel rate.

    SDRAM handshake matches the jtframe convention used by the ROM buses in
    sftm_main: hold cs with a stable address, wait 2 clks, then sample ok;
    drop cs for at least one clk between operations. For writes, `we` and
    `din` are held alongside; `ok` means the controller has committed the
    write. Verify port names/semantics against the regenerated
    jtsftm_game_sdram.v in Phase 4.
*/

module sftm_vram(
    input             rst,
    input             clk,

    // SDRAM rw bus (jtframe `vram` bus, bank 3)
    output reg [21:1] vram_addr,
    input      [15:0] vram_data,     // read data
    output reg [15:0] vram_din,      // write data
    output reg [ 1:0] vram_dsn,      // byte disables (active low select)
    output reg        vram_we,
    output reg        vram_cs,
    input             vram_ok,

    // Read-only 32-bit alias of the same 2 MB (mem.yaml `vramrd`, offset 0).
    // The scanline prefetch reads through this so one SDRAM access yields two
    // pixels: 192 accesses per line instead of 384, doubling the per-word
    // budget from 7.9 to 15.9 clk. Writes still go through the 16-bit rw
    // `vram` port above.
    output reg [21:2] vramrd_addr,
    input      [31:0] vramrd_data,
    output reg        vramrd_cs,
    input             vramrd_ok,

    // blitter write FIFO
    input             vw_req,
    output            vw_rdy,
    input             vw_plane,
    input      [18:0] vw_addr,
    input      [15:0] vw_data,

    // blitter read port
    input             vr_req,
    input             vr_plane,
    input      [18:0] vr_addr,
    output reg        vr_ack,        // 1-clk pulse, vr_data valid
    output reg [15:0] vr_data,

    // scanline prefetch: pulse line_go with line_base; fills buffer line_sel
    input             line_go,
    input      [18:0] line_base,     // csa(XORIGIN1, YORIGIN1 + line)
    input             line_sel,      // buffer to fill
    // scanout read of the other buffer
    input      [ 8:0] scan_x,
    output     [15:0] scan_pen,

    // one pulse per VRAM write issued -- the throughput meter. `!vw_free`
    // only says the FIFO is full, which it always is once the blitter runs,
    // so it cannot show whether the drain RATE improved. This can.
    output            st_wpop
);

localparam [18:0] VRAM_MASK = 19'h7FFFF;

// Bank 3 holds grm3 (the blitter's extra graphics ROM) at word 0, because
// that is where the ROM download writes it and its slot offset is 0. This
// generator cannot express a non-zero slot offset, so VRAM cannot also live
// at 0 -- it did, and the blitter was overwriting the glyph ROM in place
// while grm3 reads returned framebuffer pixels. That was the checkerboard.
// VRAM is therefore biased clear of grm3's 512 KB.
localparam [20:0] VRAM_ORG = 21'h40000;      // 16-bit words (= 512 KB)


// ---------------------------------------------------------------------------
// write FIFO (16 deep)
// ---------------------------------------------------------------------------
reg [35:0] wfifo[0:15];              // {plane, addr[18:0], data[15:0]}
reg [ 3:0] wf_wr, wf_rd;
reg [ 4:0] wf_cnt;

wire wf_full  = wf_cnt == 5'd16;
wire wf_empty = wf_cnt == 5'd0;
assign vw_rdy = !wf_full;

wire wf_push = vw_req && !wf_full;
wire wf_pop;   // driven by the blitter sequencer below (pop at issue)

always @(posedge clk) begin
    if( rst ) begin
        wf_wr  <= 0;
        wf_rd  <= 0;
        wf_cnt <= 0;
    end else begin
        if( wf_push ) begin
            wfifo[wf_wr] <= { vw_plane, vw_addr, vw_data };
            wf_wr <= wf_wr + 4'd1;
        end
        if( wf_pop )
            wf_rd <= wf_rd + 4'd1;
        case( {wf_push, wf_pop} )
            2'b10: wf_cnt <= wf_cnt + 5'd1;
            2'b01: wf_cnt <= wf_cnt - 5'd1;
            default: ;
        endcase
    end
end

wire [35:0] wf_head = wfifo[wf_rd];


// ---------------------------------------------------------------------------
// line buffers (2 x 512 x 16)
// ---------------------------------------------------------------------------
reg [15:0] lbuf0[0:511], lbuf1[0:511];
reg        lb_we;
reg [ 8:0] lb_waddr;
reg [15:0] lb_wdata;
reg [15:0] lb_q0, lb_q1;

// One simple dual-port RAM each: a single write port and a single registered
// read port, in its own always block. Writing both arrays and muxing the two
// reads inside one block kept these out of M10K -- the fitter built 16 Kbit of
// flip-flops instead and sftm_vram cost 7,578 ALMs, which is most of why the
// design stopped fitting. Latency is unchanged: still one clock, with the
// buffer select applied after the RAM rather than inside it.
always @(posedge clk) begin
    if( lb_we && !line_sel ) lbuf0[lb_waddr] <= lb_wdata;
    lb_q0 <= lbuf0[scan_x];
end

always @(posedge clk) begin
    if( lb_we &&  line_sel ) lbuf1[lb_waddr] <= lb_wdata;
    lb_q1 <= lbuf1[scan_x];
end

// scanout reads the buffer NOT being filled
assign scan_pen = line_sel ? lb_q0 : lb_q1;

// ---------------------------------------------------------------------------
// SDRAM sequencers -- one per slot, deliberately INDEPENDENT
// ---------------------------------------------------------------------------
// Bug A: the prefetch needs 384 pixels inside one line (508 pxl_cen x 6 clk =
// 3048 clk). Reading them 32 bits at a time halves that to 192 accesses.
//
// The previous version put the prefetch, the blitter read port and the write
// FIFO through ONE single-transaction state machine. Measured on hardware
// (build 54, per frame, in units of 65536 clk): blitter busy 13 -- the whole
// frame -- with 12 of it stalled on the write port and 0 stalled on GROM
// reads. vw_rdy is just !wf_full, so that reading is literally the 16-deep
// write FIFO standing full because the sequencer could not drain it. The game
// ran at a few frames per second and sprites flashed, because cpu_wait stalls
// the 68020 on COMMAND while the blitter is busy.
//
// Two causes, both fixed here:
//
//  1. `vram` and `vramrd` are SEPARATE jtframe slots that
//     jtframe_ram1_3slots already arbitrates between. Serialising them behind
//     our own FSM threw that concurrency away and let the prefetch -- which
//     had absolute priority and claimed most of every active line -- starve
//     the writes. They are now two independent machines; the slot arbiter
//     interleaves them.
//
//  2. The write FIFO is now popped AT ISSUE instead of at completion. The old
//     A_GAP state existed because wf_pop was registered, so the head only
//     advanced a cycle after the transaction finished and A_IDLE would
//     otherwise re-issue a stale wf_head. Popping at issue -- after the head
//     has been latched into vram_addr/vram_din, so it need not stay stable --
//     removes that hazard structurally rather than by waiting a cycle for it.
//
// The one-cycle `settle` guard before sampling *_ok is kept on both machines.
// It costs a cycle per access and protects against a stale ok left over from
// the previous transaction; this module has produced enough subtle bugs to
// keep it.
// ---------------------------------------------------------------------------

reg        pf_active;
reg [18:0] pf_base;
reg [18:2] pf_j;        // 32-bit word index being fetched
reg [ 9:0] pf_w;        // next line-buffer slot to fill (0..383)
reg        pf_skip;     // odd line_base: discard the low half of the first pair
reg [31:0] pf_data;
reg        pf_half;     // which half of pf_data is being written

// ---- prefetch sequencer: owns vramrd_* and the line-buffer write port -----
localparam [1:0] P_IDLE=2'd0, P_WAIT=2'd1, P_WR=2'd2;
reg [1:0] pstate;
reg       p_settle;

always @(posedge clk) begin
    if( rst ) begin
        pstate    <= P_IDLE;
        vramrd_cs <= 0;
        lb_we     <= 0;
        pf_active <= 0;
        pf_j      <= 0;
        pf_w      <= 0;
        pf_skip   <= 0;
        pf_half   <= 0;
        p_settle  <= 0;
    end else begin
        lb_we <= 0;

        if( line_go ) begin
            pf_active <= 1;
            pf_base   <= line_base;
            pf_j      <= line_base[18:1];   // pair containing the first word
            pf_w      <= 0;
            pf_skip   <= line_base[0];      // odd start: low half is the pixel before
            pf_half   <= 0;
        end

        case( pstate )
        P_IDLE: begin
            vramrd_cs <= 0;
            if( pf_active ) begin
                vramrd_addr <= VRAM_ORG[20:1] + pf_j;   // 32-bit word units
                vramrd_cs   <= 1;
                p_settle    <= 0;
                pstate      <= P_WAIT;
            end
        end
        P_WAIT: begin
            if( !p_settle )
                p_settle <= 1'b1;
            else if( vramrd_ok ) begin
                pf_data   <= vramrd_data;
                pf_half   <= 1'b0;
                pf_j      <= pf_j + 17'd1;
                vramrd_cs <= 0;
                pstate    <= P_WR;
            end
        end
        // Unpack the fetched pair into the line buffer, low half first
        // (jtframe assembles dout with the lower address in [15:0]).
        P_WR: begin
            if( pf_skip && !pf_half ) begin
                pf_skip <= 1'b0;             // odd line_base: drop the low half
                pf_half <= 1'b1;
            end else begin
                if( pf_w < 10'd384 ) begin
                    lb_we    <= 1;
                    lb_waddr <= pf_w[8:0];
                    lb_wdata <= pf_half ? pf_data[31:16] : pf_data[15:0];
                    pf_w     <= pf_w + 10'd1;
                end
                if( pf_half ) begin
                    if( pf_w + 10'd1 >= 10'd384 ) pf_active <= 0;
                    pstate <= P_IDLE;
                end else
                    pf_half <= 1'b1;
            end
        end
        default: pstate <= P_IDLE;
        endcase
    end
end

// ---- blitter sequencer: owns the rw vram_* slot ---------------------------
// A blitter READ must not overtake queued writes -- the shiftreg and c3 modes
// read back pixels this blit has just written -- so a read waits for the FIFO
// to drain. Reads and writes are therefore mutually exclusive by construction
// (one needs wf_empty, the other needs !wf_empty).
//
// vr_busy makes exactly one ack per vr_req assertion: the blitter holds vr_req
// until the cycle AFTER vr_ack, so without it B_IDLE would re-issue the same
// read and hand the blitter a second ack it would consume as the next word.
localparam [1:0] B_IDLE=2'd0, B_WAIT=2'd1;
reg [1:0] bstate;
reg       b_isread, b_settle, vr_busy;

wire b_do_read  = bstate==B_IDLE && vr_req && !vr_busy && wf_empty;
wire b_do_write = bstate==B_IDLE && !wf_empty;

// pop at issue: the head is latched into vram_addr/vram_din this same cycle
assign wf_pop = b_do_write;
assign st_wpop = wf_pop;

always @(posedge clk) begin
    if( rst ) begin
        bstate   <= B_IDLE;
        vram_cs  <= 0;
        vram_we  <= 0;
        vram_dsn <= 2'b00;
        vr_ack   <= 0;
        vr_busy  <= 0;
        b_isread <= 0;
        b_settle <= 0;
    end else begin
        vr_ack <= 0;
        if( !vr_req ) vr_busy <= 1'b0;

        case( bstate )
        B_IDLE: begin
            vram_cs <= 0;
            vram_we <= 0;
            if( b_do_write ) begin
                vram_addr <= VRAM_ORG + { wf_head[35], wf_head[34:16] }; // {plane,addr}
                vram_din  <= wf_head[15:0];
                vram_dsn  <= 2'b00;
                vram_we   <= 1;
                vram_cs   <= 1;
                b_isread  <= 0;
                b_settle  <= 0;
                bstate    <= B_WAIT;
            end else if( b_do_read ) begin
                vram_addr <= VRAM_ORG + { vr_plane, vr_addr };
                vram_we   <= 0;
                vram_cs   <= 1;
                b_isread  <= 1;
                b_settle  <= 0;
                bstate    <= B_WAIT;
            end
        end
        B_WAIT: begin
            if( !b_settle )
                b_settle <= 1'b1;
            else if( vram_ok ) begin
                if( b_isread ) begin
                    vr_ack  <= 1;
                    vr_data <= vram_data;
                    // set busy HERE, not off the registered vr_ack: B_IDLE is
                    // re-entered the very next cycle and vr_req is still high
                    // then, so a busy that lags by one cycle lets the same
                    // read reissue and delivers a second ack the blitter
                    // consumes as the next word (caught by tb_vramthru).
                    vr_busy <= 1'b1;
                end
                vram_cs <= 0;
                vram_we <= 0;
                bstate  <= B_IDLE;
            end
        end
        default: bstate <= B_IDLE;
        endcase
    end
end

endmodule
