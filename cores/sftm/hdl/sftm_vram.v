`timescale 1ns/1ps
/*  This file is part of SFTM.
    SFTM is free software: you can redistribute it and/or modify it under the
    terms of the GNU General Public License as published by the Free Software
    Foundation, either version 3 of the License, or (at your option) any later
    version. See the LICENSE file.

    Street Fighter: The Movie -- VRAM in SDRAM (see doc/PHASE2-DESIGN.md).

    2 MB (2 planes x 512x1024 x 16-bit pen) reached through TWO jtframe cache
    lanes over the same bank-3 window:

      vram  (rw, 128-bit): blitter writes and blitter reads.
      vscan (ro, 128-bit): the scanline prefetch, on its own port.

    128-bit from build 112: EIGHT pens per transaction. The write side no
    longer peeks runs at the pop side (an 8-deep async peek was too much mux
    for a 99%-full device); instead an OPEN-ENTRY COMBINER assembles words
    at push time: incoming pens merge into an open {word, data, dsn} register
    while they target the same 128-bit word, and the FIFO stores only closed
    words, one transaction each. A short linger (CLOSE_LINGER clk) before an
    idle entry self-closes lets sequential runs batch even when the port is
    keeping up; under backpressure entries fill to 8 pens naturally. Merging
    only ever touches the newest, not-yet-issued entry, and entries issue in
    order, so write ordering is exact; a later entry to the same word simply
    wins on its slots, as the pen stream did.

    Coherency is a once-per-frame contract: sftm_video pulses frame_flush at
    vblank, the vram lane writes back every dirty block, and the flush
    INVALIDATES the vscan lane (mem.yaml flush.invalidates), so scanout
    content is at most one frame old -- uniformly, which reads as latency,
    not corruption. The prefetch is idle during vblank, so the invalidation
    never races a fill. Blitter READS stay on the rw lane and wait for the
    write side to drain completely (wf_empty covers the open entry), so
    shiftreg source rows and cmd-3 read-modify-write see every queued write.

    Slot layout (both lanes ENDIAN=0, vram never downloaded, ours to
    define): pen p lives in word[16*p[2:0] +: 16], ascending pens in
    ascending slots.
*/

module sftm_vram(
    input             rst,
    input             clk,

    // jtframe cache lane `vram`, bank 3, 128-bit, rw + flush
    output reg [20:4] vram_addr,     // 128-bit word index within the lane
    input      [127:0] vram_data,
    output reg [127:0] vram_din,
    output reg [15:0] vram_dsn,      // byte disables, active low
    output reg        vram_we,
    output reg        vram_rd,
    input             vram_ok,
    output reg        vram_flush,    // rising edge starts a flush
    input             vram_flushing,
    input             vram_flush_done,

    // jtframe cache lane `vscan`, bank 3, 128-bit, read-only (scanout)
    output reg [20:4] vscan_addr,
    input      [127:0] vscan_data,
    output reg        vscan_rd,
    input             vscan_ok,

    // one pulse per frame at vblank start: flush the write lane
    input             frame_flush,

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

    // one pulse per VRAM write TRANSACTION issued -- the throughput meter
    output            st_wpop
);

localparam [18:0] VRAM_MASK = 19'h7FFFF;
localparam [ 3:0] CLOSE_LINGER = 4'd12;  // clk an idle open entry waits

// The lanes are placed by `at: offset` in cfg/mem.yaml (word 0x40000 of
// bank 3, byte 0x80000, clear of grm3's 512 kB). No bias here.

// ---------------------------------------------------------------------------
// Open-entry combiner + word FIFO (16 closed entries)
// ---------------------------------------------------------------------------
reg [160:0] wfifo[0:15];             // {word[16:0], dsn[15:0], data[127:0]}
reg [ 3:0]  wf_wr, wf_rd;
reg [ 4:0]  wf_cnt;                  // CLOSED entries only

reg         open_vld;
reg [16:0]  open_word;               // {plane, pen[18:3]}
reg [127:0] open_data;
reg [15:0]  open_dsn;
reg [ 3:0]  open_age;                // counts down to the idle self-close

wire wf_full  = wf_cnt == 5'd16;
wire wf_empty = wf_cnt == 5'd0 && !open_vld;
assign vw_rdy = !wf_full;

wire [16:0] pen_word = { vw_plane, vw_addr[18:3] };
wire [ 2:0] pen_slot = vw_addr[2:0];

wire wf_pop;                          // pop at issue (sequencer below)
wire push       = vw_req && !wf_full;
wire push_merge = push &&  open_vld && open_word == pen_word;
wire push_new   = push && !push_merge;
// close the open entry: displaced by a new word, or idle long enough --
// never into a full FIFO (the displaced case is already gated by vw_rdy)
wire close_out  = open_vld && !wf_full && ( push_new ||
                                (open_age == 4'd0 && !push_merge) );

always @(posedge clk) begin
    if( rst ) begin
        wf_wr    <= 0;
        wf_rd    <= 0;
        wf_cnt   <= 0;
        open_vld <= 0;
        open_dsn <= 16'hFFFF;
    end else begin
        if( close_out ) begin
            wfifo[wf_wr] <= { open_word, open_dsn, open_data };
            wf_wr        <= wf_wr + 4'd1;
            if( !push_new ) open_vld <= 1'b0;
        end
        if( push_new ) begin
            open_vld  <= 1'b1;
            open_word <= pen_word;
            open_data <= {8{vw_data}};
            open_dsn  <= 16'hFFFF & ~(16'h0003 << {pen_slot, 1'b0});
            open_age  <= CLOSE_LINGER;
        end else if( push_merge ) begin
            open_data[16*pen_slot +: 16] <= vw_data;
            open_dsn [ 2*pen_slot +:  2] <= 2'b00;
            open_age  <= CLOSE_LINGER;
        end else if( open_vld && open_age != 4'd0 )
            open_age <= open_age - 4'd1;

        if( wf_pop )
            wf_rd <= wf_rd + 4'd1;
        case( {close_out, wf_pop} )
            2'b10: wf_cnt <= wf_cnt + 5'd1;
            2'b01: wf_cnt <= wf_cnt - 5'd1;
            default: ;
        endcase
    end
end

wire [160:0] head = wfifo[wf_rd];

// ---------------------------------------------------------------------------
// line buffers (2 x 512 x 16)
// ---------------------------------------------------------------------------
reg [15:0] lbuf0[0:511], lbuf1[0:511];
reg        lb_we;
reg [ 8:0] lb_waddr;
reg [15:0] lb_wdata;
reg [15:0] lb_q0, lb_q1;

// One simple dual-port RAM each -- see the M10K note in the git history of
// this file: muxing the reads inside one block cost 7,578 ALMs in flip-flops.
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
// Scanline prefetch: its own sequencer on the read-only vscan lane. 48-49
// word fetches per line against a 3048-clk line budget.
// ---------------------------------------------------------------------------
reg        pf_active;
reg [18:3] pf_j;        // 128-bit word index being fetched (pen index >> 3)
reg [ 9:0] pf_w;        // pens delivered to the line buffer (0..384)
reg [ 2:0] pf_slot;     // next slot of pf_data to unpack
reg [127:0] pf_data;
reg        psettle;

localparam [1:0] P_IDLE=2'd0, P_WAIT=2'd1, P_UNPK=2'd2;
reg [1:0] pstate;

always @(posedge clk) begin
    if( rst ) begin
        pstate    <= P_IDLE;
        vscan_rd  <= 0;
        lb_we     <= 0;
        pf_active <= 0;
        pf_j      <= 0;
        pf_w      <= 0;
        pf_slot   <= 0;
        psettle   <= 0;
    end else begin
        lb_we <= 0;

        if( line_go ) begin
            pf_active <= 1;
            pf_j      <= line_base[18:3];   // word containing the first pen
            pf_w      <= 0;
            pf_slot   <= line_base[2:0];    // first pen's slot
        end

        case( pstate )
        P_IDLE: begin
            vscan_rd <= 0;
            if( pf_active ) begin
                vscan_addr <= { 1'b0, pf_j };   // plane 0
                vscan_rd   <= 1;
                psettle    <= 0;
                pstate     <= P_WAIT;
            end
        end
        P_WAIT: begin
            if( !psettle )
                psettle <= 1'b1;
            else if( vscan_ok ) begin
                vscan_rd <= 0;
                pf_data  <= vscan_data;
                pf_j     <= pf_j + 16'd1;
                pstate   <= P_UNPK;
            end
        end
        P_UNPK: begin
            if( pf_w < 10'd384 ) begin
                lb_we    <= 1;
                lb_waddr <= pf_w[8:0];
                lb_wdata <= pf_data[16*pf_slot +: 16];
                pf_w     <= pf_w + 10'd1;
            end
            if( pf_slot == 3'd7 || pf_w + 10'd1 >= 10'd384 ) begin
                pf_slot <= 3'd0;
                if( pf_w + 10'd1 >= 10'd384 ) pf_active <= 0;
                pstate  <= P_IDLE;
            end else
                pf_slot <= pf_slot + 3'd1;
        end
        default: pstate <= P_IDLE;
        endcase
    end
end

// ---------------------------------------------------------------------------
// Write-lane sequencer: blitter reads and writes only. A blitter READ waits
// for the write side to drain completely (wf_empty includes the open
// entry), because the shiftreg and cmd-3 paths read back pens this same
// blit just wrote. The FIFO is popped at ISSUE. rd and wr are SEPARATE
// request strobes on a cache lane (req = rd|wr); asserting rd alongside we
// makes the lane service a READ and silently drop the write -- build 60's
// black screen. The once-per-frame flush runs on this lane; while it runs
// the lane defers normal requests internally.
// ---------------------------------------------------------------------------
localparam [1:0] A_IDLE=2'd0, A_WAIT=2'd1;
localparam       OWN_RD=1'b0, OWN_WR=1'b1;
reg [1:0] astate;
reg       owner;
reg       settle, vr_busy;

wire [19:0] rd_pen  = { vr_plane, vr_addr };

wire b_do_rd = astate==A_IDLE && vr_req && !vr_busy && wf_empty;
wire b_do_wr = astate==A_IDLE && wf_cnt != 5'd0;
assign wf_pop = b_do_wr;          // pop at issue
assign st_wpop = wf_pop;

always @(posedge clk) begin
    if( rst ) begin
        astate    <= A_IDLE;
        vram_rd   <= 0;
        vram_we   <= 0;
        vram_dsn  <= 16'hFFFF;
        vram_flush<= 0;
        vr_ack    <= 0;
        vr_busy   <= 0;
        settle    <= 0;
        owner     <= OWN_WR;
    end else begin
        vr_ack     <= 0;
        vram_flush <= frame_flush;   // 1-clk pulse; the lane edge-detects it
        if( !vr_req ) vr_busy <= 1'b0;

        case( astate )
        A_IDLE: begin
            vram_rd <= 0;
            vram_we <= 0;
            if( b_do_rd ) begin
                vram_addr <= rd_pen[19:3];
                vram_rd   <= 1;
                owner     <= OWN_RD;
                settle    <= 0;
                astate    <= A_WAIT;
            end else if( b_do_wr ) begin
                vram_addr <= head[160:144];
                vram_dsn  <= head[143:128];
                vram_din  <= head[127:0];
                vram_we   <= 1;
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
                if( owner == OWN_RD ) begin
                    vr_ack  <= 1;
                    vr_busy <= 1;
                    vr_data <= vram_data[16*rd_pen[2:0] +: 16];
                end
                astate <= A_IDLE;
            end
        end
        default: astate <= A_IDLE;
        endcase
    end
end

endmodule
