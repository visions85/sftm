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
    output reg [20:1] vram_addr,
    input      [15:0] vram_data,     // read data
    output reg [15:0] vram_din,      // write data
    output reg [ 1:0] vram_dsn,      // byte disables (active low select)
    output reg        vram_we,
    output reg        vram_cs,
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
    output reg [15:0] scan_pen,

    // startup VRAM self-test result: {done, 3'd0, mismatch count saturating at 15}
    output     [ 7:0] st_vtest
);

localparam [18:0] VRAM_MASK = 19'h7FFFF;

// ---------------------------------------------------------------------------
// Startup VRAM self-test.
//
// Simulation (scratchpad tb_rle_long.v) shows the blitter and this module
// write every pixel of a 100-pixel RLE literal run correctly, including the
// two-plane pass and with a model faithful to jtframe_ram_rq's "cs must
// toggle per request" rule. Hardware still draws every other pixel. That
// leaves the real SDRAM path as the only untested link, so measure it
// directly: before the CPU can have issued any blit, write a known ramp and
// read it back, counting mismatches.
//
// A nonzero count proves writes (or reads) are being lost in the SDRAM path
// rather than in the blitter.
// ---------------------------------------------------------------------------
localparam [8:0] TEST_N = 9'd256;
localparam [18:0] TEST_BASE = 19'h01000;

reg  [1:0] ts;              // 0=write 1=drain 2=read 3=done
reg  [8:0] ti;
reg  [3:0] tbad;
reg        t_wreq, t_rreq;
wire       tdone = ts == 2'd3;
wire [15:0] t_expect = { 8'hA5, ti[7:0] };

assign st_vtest = { tdone, 3'd0, tbad };

// ---------------------------------------------------------------------------
// write FIFO (16 deep)
// ---------------------------------------------------------------------------
reg [35:0] wfifo[0:15];              // {plane, addr[18:0], data[15:0]}
reg [ 3:0] wf_wr, wf_rd;
reg [ 4:0] wf_cnt;

wire wf_full  = wf_cnt == 5'd16;
wire wf_empty = wf_cnt == 5'd0;
assign vw_rdy = !wf_full && tdone;

wire        f_req  = tdone ? vw_req  : t_wreq;
wire        f_plane= tdone ? vw_plane : 1'b0;
wire [18:0] f_addr = tdone ? vw_addr : (TEST_BASE + {10'd0, ti});
wire [15:0] f_data = tdone ? vw_data : t_expect;

wire wf_push = f_req && !wf_full;
reg  wf_pop;

always @(posedge clk) begin
    if( rst ) begin
        wf_wr  <= 0;
        wf_rd  <= 0;
        wf_cnt <= 0;
    end else begin
        if( wf_push ) begin
            wfifo[wf_wr] <= { f_plane, f_addr, f_data };
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

always @(posedge clk) begin
    if( rst ) begin
        ts <= 2'd0; ti <= 9'd0; tbad <= 4'd0;
        t_wreq <= 0; t_rreq <= 0;
    end else case( ts )
        2'd0: begin                       // write the ramp
            t_wreq <= 1;
            if( t_wreq && !wf_full ) begin
                if( ti == TEST_N-9'd1 ) begin
                    t_wreq <= 0; ti <= 9'd0; ts <= 2'd1;
                end else
                    ti <= ti + 9'd1;
            end
        end
        2'd1: if( wf_empty ) begin ts <= 2'd2; t_rreq <= 1; end
        2'd2: begin                       // read back and compare
            if( vr_ack ) begin
                if( vr_data != t_expect && tbad != 4'hF ) tbad <= tbad + 4'd1;
                if( ti == TEST_N-9'd1 ) begin t_rreq <= 0; ts <= 2'd3; end
                else ti <= ti + 9'd1;
            end
        end
        default: ;
    endcase
end

// ---------------------------------------------------------------------------
// line buffers (2 x 512 x 16)
// ---------------------------------------------------------------------------
reg [15:0] lbuf0[0:511], lbuf1[0:511];
reg        lb_we;
reg [ 8:0] lb_waddr;
reg [15:0] lb_wdata;

always @(posedge clk) begin
    if( lb_we ) begin
        if( line_sel ) lbuf1[lb_waddr] <= lb_wdata;
        else           lbuf0[lb_waddr] <= lb_wdata;
    end
    // scanout reads the buffer NOT being filled
    scan_pen <= line_sel ? lbuf0[scan_x] : lbuf1[scan_x];
end

// ---------------------------------------------------------------------------
// arbiter / SDRAM sequencer
// ---------------------------------------------------------------------------
localparam [2:0] A_IDLE=3'd0, A_ISSUE=3'd1, A_WAIT=3'd2, A_GAP=3'd3;
reg [2:0] astate;
reg [1:0] settle;
reg [1:0] owner;                     // 0 = prefetch, 1 = read, 2 = write
reg       pf_active;
reg [ 8:0] pf_idx;
reg [18:0] pf_base;

always @(posedge clk) begin
    if( rst ) begin
        astate    <= A_IDLE;
        vram_cs   <= 0;
        vram_we   <= 0;
        vram_dsn  <= 2'b00;
        vr_ack    <= 0;
        wf_pop    <= 0;
        lb_we     <= 0;
        pf_active <= 0;
        pf_idx    <= 0;
    end else begin
        vr_ack <= 0;
        wf_pop <= 0;
        lb_we  <= 0;

        if( line_go ) begin
            pf_active <= 1;
            pf_idx    <= 0;
            pf_base   <= line_base;
        end

        case( astate )
        A_IDLE: begin
            vram_cs <= 0;
            vram_we <= 0;
            if( pf_active ) begin
                owner     <= 2'd0;
                vram_addr <= { 1'b0, (pf_base + {10'd0, pf_idx}) & VRAM_MASK };
                vram_we   <= 0;
                vram_cs   <= 1;
                settle    <= 0;
                astate    <= A_WAIT;
            end else if( (tdone ? vr_req : t_rreq) && wf_empty ) begin
                owner     <= 2'd1;
                vram_addr <= tdone ? { vr_plane, vr_addr }
                                   : { 1'b0, (TEST_BASE + {10'd0, ti}) };
                vram_we   <= 0;
                vram_cs   <= 1;
                settle    <= 0;
                astate    <= A_WAIT;
            end else if( !wf_empty ) begin
                owner     <= 2'd2;
                vram_addr <= { wf_head[35], wf_head[34:16] };   // {plane, addr}
                vram_din  <= wf_head[15:0];
                vram_dsn  <= 2'b00;
                vram_we   <= 1;
                vram_cs   <= 1;
                settle    <= 0;
                astate    <= A_WAIT;
            end
        end
        A_WAIT: begin
            if( settle != 2'd2 )
                settle <= settle + 2'd1;
            else if( vram_ok ) begin
                case( owner )
                    2'd0: begin
                        lb_we    <= 1;
                        lb_waddr <= pf_idx;
                        lb_wdata <= vram_data;
                        if( pf_idx == 9'd383 ) pf_active <= 0;
                        pf_idx   <= pf_idx + 9'd1;
                    end
                    2'd1: begin
                        vr_ack  <= 1;
                        vr_data <= vram_data;
                    end
                    default: wf_pop <= 1;
                endcase
                vram_cs <= 0;
                vram_we <= 0;
                astate  <= A_GAP;
            end
        end
        A_GAP: astate <= A_IDLE;     // 1-clk cs gap between operations
        default: astate <= A_IDLE;
        endcase
    end
end

endmodule
