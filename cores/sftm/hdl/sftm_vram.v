`timescale 1ns/1ps
/*  This file is part of SFTM.
    SFTM is free software: you can redistribute it and/or modify it under the
    terms of the GNU General Public License as published by the Free Software
    Foundation, either version 3 of the License, or (at your option) any later
    version. See the LICENSE file.

    Street Fighter: The Movie -- VRAM in SDRAM (see doc/PHASE2-DESIGN.md).

    2 MB (2 planes x 512x1024 x 16-bit pen) on the jtframe CACHE LANE `vram`
    in bank 3. Pen address = {plane, offs[18:0]}, a 16-bit-word index; the
    lane is 32 bits wide, so the SDRAM address is that index >> 1 and bit 0
    picks the half.

    A cache lane, not a plain slot, because a plain rw slot is capped at 16
    bits (jtframe_ram_rq reads din[0+:DW] off the 16-bit data_read bus) and
    data_width: 32 on one is silently downgraded. The lane matters less for
    its width than for its BLOCK CACHE: the blitter writes pixels sequentially
    along a row, so a 256-byte block absorbs 128 pens before any SDRAM traffic,
    and the prefetch reads a line in ~3 block fills instead of 192 accesses.
    Build 56 measured ~65k writes/frame against the 92,160 one background
    needs; that shortfall is both the frame rate and the background streaks.

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

    All three clients share the ONE cache port, which looks like a step back
    from the two independent sequencers the plain-slot version needed -- but
    that version's problem was the prefetch consuming most of every line at
    ~13 clk per 2 pixels. Through the cache the prefetch costs a block fill per
    128 pixels, so the port is idle most of the time and there is nothing left
    to starve the writes.

    Sharing one cache also removes the read/write coherency question: the
    prefetch, the blitter reads and the blitter writes all see the same data,
    so no flush interface is needed and none is declared in mem.yaml.
*/

module sftm_vram(
    input             rst,
    input             clk,

    // jtframe cache lane `vram`, bank 3, 32-bit
    output reg [20:2] vram_addr,     // 32-bit word index within the lane
    input      [31:0] vram_data,     // read data
    output reg [31:0] vram_din,      // write data
    output reg [ 3:0] vram_dsn,      // byte disables, active low
    output reg        vram_we,
    output reg        vram_rd,
    input             vram_ok,

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
// No VRAM_ORG bias: the cache lane is placed by `at: offset` in cfg/mem.yaml
// (word 0x40000 of bank 3, i.e. byte 0x80000, clear of grm3's 512 kB). Adding
// a bias here would double-count that offset.


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
// Cache-lane sequencer
// ---------------------------------------------------------------------------
// One port, three clients, priority prefetch > blitter read > blitter write.
//
// The plain-slot version had to run the prefetch and the writes as two
// INDEPENDENT sequencers, because a single one let the prefetch -- tested
// first, so absolute priority -- consume most of every active line and starve
// the writes to ~2227 clk each. That is fixed here by economics rather than by
// arbitration: through a 256-byte block cache the prefetch fills a block per
// 128 pixels instead of touching SDRAM every 2, so it barely uses the port.
//
// A blitter READ still waits for the write FIFO to drain (wf_empty), because
// the shiftreg and cmd-3 paths read back pens this same blit just wrote. Reads
// and writes are therefore mutually exclusive by construction.
//
// vr_busy makes exactly one ack per vr_req assertion: the blitter holds vr_req
// until the cycle AFTER vr_ack, so a busy flag that lagged would let the same
// read reissue and hand it a second ack it would consume as the next word.
// (tb_vramthru catches this.)
//
// The write FIFO is popped at ISSUE, once the head is latched into
// vram_addr/vram_din and no longer has to stay stable. Popping at completion
// needed an extra idle state to let the registered pop land before the next
// issue could read the head.
// ---------------------------------------------------------------------------

reg        pf_active;
reg [18:0] pf_base;
reg [18:1] pf_j;        // 32-bit word index being fetched (pen index >> 1)
reg [ 9:0] pf_w;        // next line-buffer slot to fill (0..383)
reg        pf_skip;     // odd line_base: discard the low half of the first pair
reg [31:0] pf_data;
reg        pf_half;     // which half of pf_data is being written

localparam [1:0] A_IDLE=2'd0, A_WAIT=2'd1, A_PFWR=2'd2;
localparam [1:0] OWN_PF=2'd0, OWN_RD=2'd1, OWN_WR=2'd2;
reg [1:0] astate, owner;
reg       settle, vr_busy;

// pen index -> lane address. {plane,addr} counts 16-bit pens; the lane is
// 32 bits, so drop the low bit and remember it to pick the half.
wire [19:0] rd_pen  = { vr_plane, vr_addr };
wire [19:0] wr_pen  = { wf_head[35], wf_head[34:16] };

wire b_do_rd = astate==A_IDLE && !pf_active && vr_req && !vr_busy && wf_empty;
wire b_do_wr = astate==A_IDLE && !pf_active && !wf_empty;
assign wf_pop = b_do_wr;          // pop at issue
assign st_wpop = wf_pop;

always @(posedge clk) begin
    if( rst ) begin
        astate    <= A_IDLE;
        vram_rd   <= 0;
        vram_we   <= 0;
        vram_dsn  <= 4'hF;
        vr_ack    <= 0;
        vr_busy   <= 0;
        lb_we     <= 0;
        pf_active <= 0;
        pf_j      <= 0;
        pf_w      <= 0;
        pf_skip   <= 0;
        pf_half   <= 0;
        settle    <= 0;
        owner     <= OWN_PF;
    end else begin
        vr_ack <= 0;
        lb_we  <= 0;
        if( !vr_req ) vr_busy <= 1'b0;

        if( line_go ) begin
            pf_active <= 1;
            pf_base   <= line_base;
            pf_j      <= line_base[18:1];   // pair containing the first pen
            pf_w      <= 0;
            pf_skip   <= line_base[0];      // odd start: low half precedes it
            pf_half   <= 0;
        end

        case( astate )
        A_IDLE: begin
            vram_rd <= 0;
            vram_we <= 0;
            if( pf_active ) begin
                vram_addr <= { 1'b0, pf_j };   // pen>>1 already
                vram_rd   <= 1;
                owner     <= OWN_PF;
                settle    <= 0;
                astate    <= A_WAIT;
            end else if( b_do_rd ) begin
                vram_addr <= rd_pen[19:1];
                vram_rd   <= 1;
                owner     <= OWN_RD;
                settle    <= 0;
                astate    <= A_WAIT;
            end else if( b_do_wr ) begin
                vram_addr <= wr_pen[19:1];
                // place the pen in its half and enable only those two bytes
                vram_din  <= wr_pen[0] ? { wf_head[15:0], 16'd0 }
                                       : { 16'd0, wf_head[15:0] };
                vram_dsn  <= wr_pen[0] ? 4'b0011 : 4'b1100;
                vram_we   <= 1;
                vram_rd   <= 1;
                owner     <= OWN_WR;
                settle    <= 0;
                astate    <= A_WAIT;
            end
        end
        A_WAIT: begin
            if( !settle )
                settle <= 1'b1;
            else if( vram_ok ) begin
                vram_rd <= 0;
                vram_we <= 0;
                case( owner )
                    OWN_PF: begin
                        pf_data <= vram_data;
                        pf_half <= 1'b0;
                        pf_j    <= pf_j + 18'd1;
                        astate  <= A_PFWR;
                    end
                    OWN_RD: begin
                        vr_ack  <= 1;
                        vr_busy <= 1;
                        vr_data <= rd_pen[0] ? vram_data[31:16] : vram_data[15:0];
                        astate  <= A_IDLE;
                    end
                    default: astate <= A_IDLE;
                endcase
            end
        end
        // unpack the fetched pair into the line buffer, low half first
        A_PFWR: begin
            if( pf_skip && !pf_half ) begin
                pf_skip <= 1'b0;
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
                    astate <= A_IDLE;
                end else
                    pf_half <= 1'b1;
            end
        end
        default: astate <= A_IDLE;
        endcase
    end
end

endmodule
