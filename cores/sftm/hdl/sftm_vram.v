`timescale 1ns/1ps
/*  This file is part of SFTM.
    SFTM is free software: you can redistribute it and/or modify it under the
    terms of the GNU General Public License as published by the Free Software
    Foundation, either version 3 of the License, or (at your option) any later
    version. See the LICENSE file.

    Street Fighter: The Movie -- VRAM in SDRAM (see doc/PHASE2-DESIGN.md).

    2 MB (2 planes x 512x1024 x 16-bit pen) reached through TWO jtframe cache
    lanes over the same bank-3 window (build 109):

      vram  (rw, 64-bit): blitter writes (run-coalesced) and blitter reads.
      vscan (ro, 64-bit): the scanline prefetch, on its own port.

    b107/b108 metering showed the single shared port serialising ~2.5k
    prefetch transactions per frame against the write drain; with the split,
    the write path owns its port and the prefetch runs concurrently.

    Coherency is a once-per-frame contract instead of per-access: sftm_video
    pulses frame_flush at vblank, the vram lane writes back every dirty
    block, and the flush INVALIDATES the vscan lane (mem.yaml
    flush.invalidates), so scanout content is at most one frame old --
    uniformly, which reads as latency, not corruption. The prefetch is idle
    during vblank (line_go fires only for visible lines), so the
    invalidation never races a fill. Blitter READS stay on the rw lane:
    shiftreg source rows and cmd-3 read-modify-write need the queued writes,
    so reads still wait for the FIFO to drain (wf_empty).

    Slot layout (both lanes ENDIAN=0, vram never downloaded, ours to
    define): pen p lives in word[16*p[1:0] +: 16], ascending pens in
    ascending slots.
*/

module sftm_vram(
    input             rst,
    input             clk,

    // jtframe cache lane `vram`, bank 3, 64-bit, rw + flush
    output reg [20:3] vram_addr,     // 64-bit word index within the lane
    input      [63:0] vram_data,     // read data
    output reg [63:0] vram_din,      // write data
    output reg [ 7:0] vram_dsn,      // byte disables, active low
    output reg        vram_we,
    output reg        vram_rd,
    input             vram_ok,
    output reg        vram_flush,    // rising edge starts a flush
    input             vram_flushing,
    input             vram_flush_done,

    // jtframe cache lane `vscan`, bank 3, 64-bit, read-only (scanout)
    output reg [20:3] vscan_addr,
    input      [63:0] vscan_data,
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

// The lanes are placed by `at: offset` in cfg/mem.yaml (word 0x40000 of
// bank 3, byte 0x80000, clear of grm3's 512 kB). No bias here.

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
wire wf_pop;        // driven by the sequencer below (pop at issue)
wire [2:0] wrun;    // entries consumed by this pop (1..4)

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
            wf_rd <= wf_rd + {1'b0, wrun};
        case( {wf_push, wf_pop} )
            2'b10: wf_cnt <= wf_cnt + 5'd1;
            2'b01: wf_cnt <= wf_cnt - {2'd0, wrun};
            2'b11: wf_cnt <= wf_cnt - {2'd0, wrun} + 5'd1;
            default: ;
        endcase
    end
end

// ---------------------------------------------------------------------------
// Run coalescing: up to FOUR FIFO entries that continue head's pen sequence
// inside one 64-bit lane word issue as a single write. A push cannot alias
// the peeked entries: wf_wr = wf_rd + wf_cnt and the peeks are guarded by
// wf_cnt.
// ---------------------------------------------------------------------------
wire [35:0] e0 = wfifo[wf_rd];
wire [35:0] e1 = wfifo[wf_rd + 4'd1];
wire [35:0] e2 = wfifo[wf_rd + 4'd2];
wire [35:0] e3 = wfifo[wf_rd + 4'd3];
wire [19:0] p0 = { e0[35], e0[34:16] };   // {plane, pen}

wire run1 = wf_cnt >= 5'd2 && {e1[35],e1[34:16]} == p0 + 20'd1 && p0[1:0] != 2'd3;
wire run2 = wf_cnt >= 5'd3 && {e2[35],e2[34:16]} == p0 + 20'd2 && !p0[1]   && run1;
wire run3 = wf_cnt >= 5'd4 && {e3[35],e3[34:16]} == p0 + 20'd3 && p0[1:0] == 2'd0 && run2;
assign wrun = run3 ? 3'd4 : run2 ? 3'd3 : run1 ? 3'd2 : 3'd1;

wire [1:0] q0 = p0[1:0];
wire [1:0] q1 = q0 + 2'd1;
wire [1:0] q2 = q0 + 2'd2;
wire [1:0] q3 = q0 + 2'd3;

reg [63:0] wdin;
reg [ 7:0] wdsn;
always @* begin
    wdin = 64'd0;
    wdsn = 8'hFF;
    wdin[16*q0 +: 16] = e0[15:0];
    wdsn[ 2*q0 +:  2] = 2'b00;
    if( wrun >= 3'd2 ) begin
        wdin[16*q1 +: 16] = e1[15:0];
        wdsn[ 2*q1 +:  2] = 2'b00;
    end
    if( wrun >= 3'd3 ) begin
        wdin[16*q2 +: 16] = e2[15:0];
        wdsn[ 2*q2 +:  2] = 2'b00;
    end
    if( wrun == 3'd4 ) begin
        wdin[16*q3 +: 16] = e3[15:0];
        wdsn[ 2*q3 +:  2] = 2'b00;
    end
end

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
// Scanline prefetch: its own sequencer on the read-only vscan lane. 96-97
// word fetches per line against a 3048-clk line budget -- no arbitration
// with the blitter at all any more.
// ---------------------------------------------------------------------------
reg        pf_active;
reg [18:2] pf_j;        // 64-bit word index being fetched (pen index >> 2)
reg [ 9:0] pf_w;        // pens delivered to the line buffer (0..384)
reg [ 1:0] pf_slot;     // next slot of pf_data to unpack
reg [63:0] pf_data;
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
            pf_j      <= line_base[18:2];   // word containing the first pen
            pf_w      <= 0;
            pf_slot   <= line_base[1:0];    // first pen's slot
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
                pf_j     <= pf_j + 17'd1;
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
            if( pf_slot == 2'd3 || pf_w + 10'd1 >= 10'd384 ) begin
                pf_slot <= 2'd0;
                if( pf_w + 10'd1 >= 10'd384 ) pf_active <= 0;
                pstate  <= P_IDLE;
            end else
                pf_slot <= pf_slot + 2'd1;
        end
        default: pstate <= P_IDLE;
        endcase
    end
end

// ---------------------------------------------------------------------------
// Write-lane sequencer: blitter reads and writes only. A blitter READ waits
// for the write FIFO to drain (wf_empty), because the shiftreg and cmd-3
// paths read back pens this same blit just wrote -- reads and writes stay
// mutually exclusive by construction. The FIFO is popped at ISSUE, once the
// head run is latched. rd and wr are SEPARATE request strobes on a cache
// lane (req = rd|wr); asserting rd alongside we makes the lane service a
// READ and silently drop the write -- build 60's black screen.
//
// The once-per-frame flush runs on this lane; while it runs the lane defers
// normal requests internally, so an in-flight write simply waits longer for
// ok -- no special handling here beyond passing the pulse through.
// ---------------------------------------------------------------------------
localparam [1:0] A_IDLE=2'd0, A_WAIT=2'd1;
localparam       OWN_RD=1'b0, OWN_WR=1'b1;
reg [1:0] astate;
reg       owner;
reg       settle, vr_busy;

wire [19:0] rd_pen  = { vr_plane, vr_addr };

wire b_do_rd = astate==A_IDLE && vr_req && !vr_busy && wf_empty;
wire b_do_wr = astate==A_IDLE && !wf_empty;
assign wf_pop = b_do_wr;          // pop at issue
assign st_wpop = wf_pop;

always @(posedge clk) begin
    if( rst ) begin
        astate    <= A_IDLE;
        vram_rd   <= 0;
        vram_we   <= 0;
        vram_dsn  <= 8'hFF;
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
                vram_addr <= rd_pen[19:2];
                vram_rd   <= 1;
                owner     <= OWN_RD;
                settle    <= 0;
                astate    <= A_WAIT;
            end else if( b_do_wr ) begin
                vram_addr <= p0[19:2];
                vram_din  <= wdin;
                vram_dsn  <= wdsn;
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
                    vr_data <= vram_data[16*rd_pen[1:0] +: 16];
                end
                astate <= A_IDLE;
            end
        end
        default: astate <= A_IDLE;
        endcase
    end
end

endmodule
