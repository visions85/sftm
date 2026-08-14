`timescale 1ns/1ps
/*  This file is part of SFTM.
    SFTM is free software: you can redistribute it and/or modify it under the
    terms of the GNU General Public License as published by the Free Software
    Foundation, either version 3 of the License, or (at your option) any later
    version. See the LICENSE file.

    Ensoniq ES5506 (OTTO) -- literal port of MAME src/devices/sound/es5506.cpp.
    Comments cite es5506.cpp line numbers.

    ES5506 parameters (device_start :232, get_accum_mask :502): 21-bit
    integer / 11-bit fraction addressing gives address_acc_shift = 0, so the
    accumulator is a plain 32-bit value that wraps naturally. Volume is
    16-bit with a 4-bit exponent / 8-bit mantissa lookup (compute_tables
    :442), volume_acc_shift = (16+15)-20 = 11. Filter coefficients are
    16-bit used at 12 (FILTER_SHIFT = 4, :109); the C filter math divides
    with truncation toward zero, which divt() reproduces exactly.

    Engine: time-multiplexed, one voice at a time, one pass per sample
    period (sample rate = clk16 / (16 * (active_voices+1)), :1157). At
    48 MHz there are >1500 clks per 31.25 kHz sample against ~32 voices x
    ~15 clks per pass, so timing closes comfortably.

    Host interface (write :1328, read :1537): 8-bit bus, 32-bit registers
    assembled MSB-first; writes commit on byte offset 3, reads load a latch
    on byte offset 0. Register writes and the IRQV-read side effect queue
    into the engine so all voice state has a single writer; the 6809 leaves
    >= 20 clks between commits, far more than the engine needs to drain.

    sftm specifics: channels = 1, so every voice mixes into one stereo pair
    (get_ca % 1 == 0, :1028); the ES5506 IRQ pin is not wired on itech32
    (IRQV/IRQE semantics still implemented for readback); PAR reads 0.
    Output routing is swapped stereo (itech32.cpp:1798): stream channel 0
    (lvol side) goes to the right speaker.

    Sample memory: CR[15:14] selects region banks (:185). sftm populates
    ensoniq.0 (2 MB) and ensoniq.3 (512 KB), loaded with ROM_LOAD16_BYTE:
    8-bit sample data in the high byte of each 16-bit word. The SDRAM srom
    stream holds the packed bytes, so region word address W = SDRAM byte
    address W (bank 3 at +0x200000), sample = {byte, 8'h00}. Banks 1/2 and
    out-of-range addresses read 0 (unmapped / ERASE00 regions).
*/

module sftm5506(
    input             rst,
    input             clk,         // 48 MHz
    input             es_cen,      // 16 MHz master-clock enable

    // host interface (6809): 64-byte window, reg = addr[5:2], byte = addr[1:0]
    input      [ 5:0] host_addr,
    input      [ 7:0] host_din,
    output     [ 7:0] host_dout,
    input             host_wr,     // 1-clk strobe
    input             host_rd,     // 1-clk strobe (side effects on byte 0)

    // sample ROM (SDRAM bank 1, packed bytes)
    output reg [21:1] srom_addr,
    input      [15:0] srom_data,
    output reg        srom_cs,
    input             srom_ok,

    // Sample-ROM observation. The 6809 now programs the chip (ES5506
    // register writes saturate on hardware) but audio output stays 0, so
    // split the remaining possibilities: no fetches at all means the voices
    // were never started, fetches returning zero means the srom mapping or
    // the ROM itself is wrong, and live nonzero data means the fault is
    // downstream in the voice/mix pipeline.
    output reg [ 7:0] st_sromn,     // saturating count of completed fetches
    output reg [ 7:0] st_sromd,     // last sample byte fetched

    // stereo output, refreshed once per sample period
    output reg signed [15:0] snd_left,
    output reg signed [15:0] snd_right,
    output reg               sample
);

// CONTROL bit numbers (es5506.cpp:116)
localparam CR_CMPD  = 13;
localparam CR_IRQ   = 7;
localparam CR_DIR   = 6;
localparam CR_IRQE  = 5;
localparam CR_BLE   = 4;
localparam CR_LPE   = 3;
localparam CR_LEI   = 2;
localparam CR_STOP1 = 1;
localparam CR_STOP0 = 0;

// ---------------------------------------------------------------------------
// voice state (es550x_voice, es5506.h:44). Filter poles are full-width
// signed, like MAME's s32 members; only readback masks to 18 bits.
// ---------------------------------------------------------------------------
reg [15:0] v_control [0:31];
reg [16:0] v_freq    [0:31];   // FC & 0x1ffff (:1104)
reg [31:0] v_start   [0:31];   // & 0xfffff800 (:1193)
reg [31:0] v_end     [0:31];   // & 0xffffff80 (:1198)
reg [31:0] v_accum   [0:31];
reg [15:0] v_lvol    [0:31];
reg [15:0] v_rvol    [0:31];
reg [ 7:0] v_lvramp  [0:31];
reg [ 7:0] v_rvramp  [0:31];
reg [ 8:0] v_ecount  [0:31];
reg [15:0] v_k1      [0:31];
reg [15:0] v_k2      [0:31];
reg [ 8:0] v_k1ramp  [0:31];   // {slow_bit, ramp[7:0]} (:1150)
reg [ 8:0] v_k2ramp  [0:31];
reg [ 7:0] v_filtc   [0:31];
reg signed [31:0] v_o1n1[0:31], v_o2n1[0:31], v_o2n2[0:31];
reg signed [31:0] v_o3n1[0:31], v_o3n2[0:31], v_o4n1[0:31];

// globals
reg [ 6:0] page;
reg [ 4:0] active_voices;
reg [ 4:0] mode;
reg [ 7:0] irqv;               // 0x80 = no IRQ pending
reg [ 6:0] wst, wend, lrend;

// ---------------------------------------------------------------------------
// u-law lookup (compute_tables :448); index = top 8 bits of the sample word
// ---------------------------------------------------------------------------
reg signed [15:0] ulaw_lut[0:255];
integer i;
reg [15:0] t_raw, t_man;
reg [ 2:0] t_exp;
initial begin
    for( i=0; i<256; i=i+1 ) begin
        t_raw = (i[7:0] << 8) | 16'h0080;
        t_exp = t_raw[15:13];
        t_man = (t_raw << 3) & 16'hffff;
        if( t_exp == 0 )
            ulaw_lut[i] = $signed(t_man) >>> 7;
        else begin
            t_man = (t_man >> 1) | (~t_man & 16'h8000);
            ulaw_lut[i] = $signed(t_man) >>> (7 - t_exp);
        end
    end
end

// volume lookup (:478): idx = vol>>4; ((man|0x100) << 7) >> (16 - exp)
function [15:0] vol_lut(input [15:0] vol);
    reg [24:0] t;
    begin
        t = {16'd0, 1'b1, vol[11:4]} << 7;
        vol_lut = t >> (5'd16 - {1'b0, vol[15:12]});
    end
endfunction

// get_sample (:107): (sample * volume) >>> 11
function signed [31:0] vol_apply(input signed [31:0] s, input [15:0] vol);
    reg signed [47:0] p;
    begin
        p = s * $signed({1'b0, vol_lut(vol)});
        vol_apply = p >>> 11;
    end
endfunction

// C truncating division by 2^n for signed values
function signed [45:0] divt(input signed [45:0] v, input [3:0] n);
    divt = v[45] ? -((-v) >>> n) : v >>> n;
endfunction

// apply_lowpass (:534): (k>>4)*(out - in)/4096 + in
function signed [31:0] f_lp(input signed [31:0] s, input [15:0] k,
                            input signed [31:0] o);
    reg signed [45:0] p;
    begin
        p = $signed({2'b0, k[15:4]}) * (s - o);
        f_lp = divt(p, 4'd12) + o;
    end
endfunction

// apply_highpass (:539): out - prev + (k>>4)*in/8192 + in/2
function signed [31:0] f_hp(input signed [31:0] s, input [15:0] k,
                            input signed [31:0] o, input signed [31:0] prev);
    reg signed [45:0] p;
    begin
        p = $signed({2'b0, k[15:4]}) * o;
        f_hp = s - prev + divt(p, 4'd13) + divt({{14{o[31]}}, o}, 4'd1);
    end
endfunction

// envelope ramps (:625/:641): value += (int8)ramp, clamp 0..0xffff
function [15:0] ramp16(input [15:0] v, input [7:0] rmp);
    reg signed [17:0] t;
    begin
        t = $signed({2'd0, v}) + $signed({{10{rmp[7]}}, rmp});
        ramp16 = t[17] ? 16'd0 : (t > 18'sh0FFFF ? 16'hFFFF : t[15:0]);
    end
endfunction

function signed [19:0] clamp20(input signed [31:0] v);
    clamp20 = v > 32'sh0007FFFF ? 20'sh7FFFF :
              v < -32'sh00080000 ? -20'sh80000 : v[19:0];
endfunction

// get_integer_addr (:105)
function [20:0] int_addr(input [31:0] a, input [0:0] bias);
    int_addr = (a + {20'd0, bias, 11'd0}) >> 11;
endfunction

// ---------------------------------------------------------------------------
// host interface
// ---------------------------------------------------------------------------
reg [31:0] wlatch, rlatch;
reg        hw_pend;
reg [ 6:0] hw_page;
reg [ 3:0] hw_reg;
reg [31:0] hw_data;
reg        irqv_ack;

// combinational register read (reg_read_low/high/test, :1363)
reg  [31:0] rd_val;
wire [ 4:0] rd_v   = page[4:0];
wire [ 3:0] rd_reg = host_addr[5:2];
always @(*) begin
    rd_val = 32'd0;
    if( page < 7'h20 ) case( rd_reg )
        4'h0: rd_val = {16'd0, v_control[rd_v]};
        4'h1: rd_val = {15'd0, v_freq[rd_v]};
        4'h2: rd_val = {16'd0, v_lvol[rd_v]};
        4'h3: rd_val = {8'd0, v_lvramp[rd_v], 16'd0} >> 8;   // ramp << 8
        4'h4: rd_val = {16'd0, v_rvol[rd_v]};
        4'h5: rd_val = {8'd0, v_rvramp[rd_v], 16'd0} >> 8;
        4'h6: rd_val = {23'd0, v_ecount[rd_v]};
        4'h7: rd_val = {16'd0, v_k2[rd_v]};
        4'h8: rd_val = {16'd0, v_k2ramp[rd_v][7:0], 7'd0, v_k2ramp[rd_v][8]};
        4'h9: rd_val = {16'd0, v_k1[rd_v]};
        4'hA: rd_val = {16'd0, v_k1ramp[rd_v][7:0], 7'd0, v_k1ramp[rd_v][8]};
        4'hB: rd_val = {27'd0, active_voices};
        4'hC: rd_val = {27'd0, mode};
        4'hD: rd_val = 32'd0;                    // PAR: no port on itech32
        4'hE: rd_val = {24'd0, irqv};
        4'hF: rd_val = {25'd0, page};
    endcase
    else if( page < 7'h40 ) case( rd_reg )
        4'h0: rd_val = {16'd0, v_control[rd_v]};
        4'h1: rd_val = v_start[rd_v];
        4'h2: rd_val = v_end[rd_v];
        4'h3: rd_val = v_accum[rd_v];
        4'h4: rd_val = {14'd0, v_o4n1[rd_v][17:0]};
        4'h5: rd_val = {14'd0, v_o3n1[rd_v][17:0]};
        4'h6: rd_val = {14'd0, v_o3n2[rd_v][17:0]};
        4'h7: rd_val = {14'd0, v_o2n1[rd_v][17:0]};
        4'h8: rd_val = {14'd0, v_o2n2[rd_v][17:0]};
        4'h9: rd_val = {14'd0, v_o1n1[rd_v][17:0]};
        4'hA: rd_val = {25'd0, wst};
        4'hB: rd_val = {25'd0, wend};
        4'hC: rd_val = {25'd0, lrend};
        4'hD: rd_val = 32'd0;
        4'hE: rd_val = {24'd0, irqv};
        4'hF: rd_val = {25'd0, page};
    endcase
    else case( rd_reg )
        4'hE: rd_val = {24'd0, irqv};
        4'hF: rd_val = {25'd0, page};
        default: rd_val = 32'd0;
    endcase
end

assign host_dout = host_addr[1:0] == 2'd0 ? rd_val[31:24] :
                   host_addr[1:0] == 2'd1 ? rlatch[23:16] :
                   host_addr[1:0] == 2'd2 ? rlatch[15: 8] : rlatch[7:0];

wire        hw_commit = host_wr && host_addr[1:0] == 2'd3;
wire [31:0] wfull     = { wlatch[31:8], host_din };

always @(posedge clk) begin
    if( rst ) begin
        wlatch <= 0;
        rlatch <= 0;
    end else begin
        if( host_rd && host_addr[1:0] == 2'd0 )
            rlatch <= rd_val;
        if( host_wr ) case( host_addr[1:0] )   // MSB-first assembly (:1334)
            2'd0: wlatch[31:24] <= host_din;
            2'd1: wlatch[23:16] <= host_din;
            2'd2: wlatch[15: 8] <= host_din;
            default: ;
        endcase
    end
end

// ---------------------------------------------------------------------------
// sample-period tick: clk16 / (16 * (active+1))  (:1157)
// ---------------------------------------------------------------------------
reg [ 9:0] cen_cnt;
wire [9:0] cen_top = { 1'b0, active_voices, 4'hF };
reg        tick;

always @(posedge clk) begin
    if( rst ) begin
        cen_cnt <= 0;
        tick    <= 0;
    end else begin
        tick <= 0;
        if( es_cen ) begin
            if( cen_cnt >= cen_top ) begin
                cen_cnt <= 0;
                tick    <= 1;
            end else
                cen_cnt <= cen_cnt + 10'd1;
        end
    end
end

// ---------------------------------------------------------------------------
// engine
// ---------------------------------------------------------------------------
localparam [4:0]
    E_IDLE  = 5'd0,
    E_VOICE = 5'd1,
    E_ADDR1 = 5'd2,
    E_ADDR2 = 5'd3,
    E_WAITF = 5'd4,
    E_INTERP= 5'd5,
    // Each filter pole is split into a multiply stage (xxA) and an
    // accumulate stage (xxB). Combined with the pre-latched coefficients
    // below this keeps the 32:1 voice-array muxes and the multiplier off
    // the same path -- that combination was the design's critical path
    // (vn -> fsamp, -3.69 ns) during Phase 4 bring-up.
    E_F1A   = 5'd6,  E_F1B = 5'd7,
    E_F2A   = 5'd8,  E_F2B = 5'd9,
    E_F3A   = 5'd10, E_F3B = 5'd11,
    E_F4A   = 5'd12, E_F4B = 5'd13,
    E_ENV   = 5'd14,
    E_ACCUM = 5'd15,
    E_LOOP  = 5'd16,
    E_NEXT  = 5'd17,
    E_OUT   = 5'd18;

reg [4:0]  estate;
reg [4:0]  vn;
// per-voice values latched once at E_VOICE so the filter stages read plain
// registers instead of 32:1 muxes indexed by vn
reg [15:0] k1_r, k2_r;
reg signed [31:0] o1_r, o2a_r, o2b_r, o3a_r, o3b_r, o4_r;
reg [ 1:0] lp_r;
reg signed [45:0] prod;      // multiply stage output
reg signed [31:0] acc_l, acc_r;
reg [31:0] accum;
reg [15:0] ctrl;
reg signed [31:0] val1, val2, fsamp;
reg        fetch2, running;
reg [ 1:0] srom_settle;
reg [21:0] cur_baddr;

wire [ 1:0] bank      = ctrl[15:14];
wire [20:0] addr_int1 = int_addr(accum, 1'b0);
wire [20:0] addr_int2 = int_addr(accum, 1'b1);
wire        bank_ok1  = bank == 2'd0 ? addr_int1 < 21'h100000 :
                        bank == 2'd3 ? addr_int1 < 21'h080000 : 1'b0;
wire        bank_ok2  = bank == 2'd0 ? addr_int2 < 21'h100000 :
                        bank == 2'd3 ? addr_int2 < 21'h080000 : 1'b0;

// region word addr -> SDRAM byte addr: bank0 at 0, bank3 at +0x200000
function [21:0] srom_baddr(input [1:0] b, input [20:0] w);
    srom_baddr = b == 2'd0 ? {1'b0, w} : 22'h200000 + {3'd0, w[18:0]};
endfunction

wire [ 7:0] srom_byte = cur_baddr[0] ? srom_data[15:8] : srom_data[7:0];
wire signed [15:0] fetched = ctrl[CR_CMPD] ? ulaw_lut[srom_byte]  // (:837)
                                           : {srom_byte, 8'h00};  // (:919)
wire [10:0] frac = accum[10:0];

integer j;
always @(posedge clk) begin
    if( rst ) begin
        estate  <= E_IDLE;
        srom_cs <= 0;
        st_sromn <= 8'd0;
        st_sromd <= 8'd0;
        hw_pend <= 0;
        irqv_ack<= 0;
        page    <= 0;
        active_voices <= 5'h1f;      // device_reset (:314)
        mode    <= 5'h17;
        irqv    <= 8'h80;
        wst     <= 0; wend <= 0; lrend <= 0;
        acc_l   <= 0; acc_r <= 0;
        snd_left<= 0; snd_right <= 0;
        sample  <= 0;
        vn      <= 0;
        for( j=0; j<32; j=j+1 ) begin
            v_control[j] <= 16'h0003;             // STOPMASK (:490)
            v_lvol[j]    <= 16'h8000;             // (:491)
            v_rvol[j]    <= 16'h8000;
            v_freq[j]    <= 0;  v_start[j] <= 0;  v_end[j]   <= 0;
            v_accum[j]   <= 0;  v_lvramp[j]<= 0;  v_rvramp[j]<= 0;
            v_ecount[j]  <= 0;  v_k1[j]    <= 0;  v_k2[j]    <= 0;
            v_k1ramp[j]  <= 0;  v_k2ramp[j]<= 0;  v_filtc[j] <= 0;
            v_o1n1[j] <= 0; v_o2n1[j] <= 0; v_o2n2[j] <= 0;
            v_o3n1[j] <= 0; v_o3n2[j] <= 0; v_o4n1[j] <= 0;
        end
    end else begin
        sample <= 0;

        // host write commit -> queue
        if( hw_commit ) begin
            hw_page <= page;
            hw_reg  <= host_addr[5:2];
            hw_data <= wfull;
            hw_pend <= 1;
        end
        if( host_rd && host_addr[1:0] == 2'd0 && host_addr[5:2] == 4'hE )
            irqv_ack <= 1;           // IRQV read side effect (:1429)

        // apply queued host ops between voices (single writer for arrays)
        if( (estate == E_IDLE || estate == E_VOICE || estate == E_NEXT)
            && hw_pend ) begin
            hw_pend <= 0;
            if( hw_reg == 4'hF )
                page <= hw_data[6:0];             // PAGE, any bank (:1177)
            else if( hw_page < 7'h20 ) case( hw_reg )   // reg_write_low (:1094)
                4'h0: v_control[hw_page[4:0]] <= hw_data[15:0];
                4'h1: v_freq   [hw_page[4:0]] <= hw_data[16:0];
                4'h2: v_lvol   [hw_page[4:0]] <= hw_data[15:0];
                4'h3: v_lvramp [hw_page[4:0]] <= hw_data[15:8];
                4'h4: v_rvol   [hw_page[4:0]] <= hw_data[15:0];
                4'h5: v_rvramp [hw_page[4:0]] <= hw_data[15:8];
                4'h6: begin                              // ECOUNT (:1128)
                    v_ecount[hw_page[4:0]] <= hw_data[8:0];
                    v_filtc [hw_page[4:0]] <= 0;
                end
                4'h7: v_k2     [hw_page[4:0]] <= hw_data[15:0];
                4'h8: v_k2ramp [hw_page[4:0]] <= {hw_data[0], hw_data[15:8]};
                4'h9: v_k1     [hw_page[4:0]] <= hw_data[15:0];
                4'hA: v_k1ramp [hw_page[4:0]] <= {hw_data[0], hw_data[15:8]};
                4'hB: active_voices <= hw_data[4:0];     // ACTV (:1156)
                4'hC: mode <= hw_data[4:0];
                default: ;
            endcase
            else if( hw_page < 7'h40 ) case( hw_reg )   // reg_write_high (:1183)
                4'h0: v_control[hw_page[4:0]] <= hw_data[15:0];
                4'h1: v_start  [hw_page[4:0]] <= hw_data & 32'hfffff800;
                4'h2: v_end    [hw_page[4:0]] <= hw_data & 32'hffffff80;
                4'h3: v_accum  [hw_page[4:0]] <= hw_data;
                4'h4: v_o4n1   [hw_page[4:0]] <= {{14{hw_data[17]}}, hw_data[17:0]};
                4'h5: v_o3n1   [hw_page[4:0]] <= {{14{hw_data[17]}}, hw_data[17:0]};
                4'h6: v_o3n2   [hw_page[4:0]] <= {{14{hw_data[17]}}, hw_data[17:0]};
                4'h7: v_o2n1   [hw_page[4:0]] <= {{14{hw_data[17]}}, hw_data[17:0]};
                4'h8: v_o2n2   [hw_page[4:0]] <= {{14{hw_data[17]}}, hw_data[17:0]};
                4'h9: v_o1n1   [hw_page[4:0]] <= {{14{hw_data[17]}}, hw_data[17:0]};
                4'hA: wst   <= hw_data[6:0];
                4'hB: wend  <= hw_data[6:0];
                4'hC: lrend <= hw_data[6:0];
                default: ;
            endcase
            // pages >= 0x40: test registers, no-op (:1262)
        end
        if( (estate == E_IDLE || estate == E_VOICE || estate == E_NEXT)
            && irqv_ack ) begin
            irqv_ack <= 0;
            irqv     <= 8'h80;       // update_internal_irq_state (:420)
        end

        case( estate )
        E_IDLE: if( tick ) begin
            vn    <= 0;
            acc_l <= 0;
            acc_r <= 0;
            estate<= E_VOICE;
        end
        E_VOICE: begin
            // special case: start == end stops the voice (:1024)
            ctrl   <= (v_start[vn] == v_end[vn]) ? v_control[vn] | 16'h0001
                                                 : v_control[vn];
            accum  <= v_accum[vn];
            // snapshot everything the filter stages need
            k1_r <= v_k1[vn];  k2_r <= v_k2[vn];  lp_r <= v_control[vn][9:8];
            o1_r <= v_o1n1[vn];
            o2a_r<= v_o2n1[vn]; o2b_r<= v_o2n2[vn];
            o3a_r<= v_o3n1[vn]; o3b_r<= v_o3n2[vn];
            o4_r <= v_o4n1[vn];
            estate <= E_ADDR1;
        end
        E_ADDR1: begin
            running <= !(ctrl[CR_STOP1] || ctrl[CR_STOP0]);
            if( ctrl[CR_STOP1] || ctrl[CR_STOP0] )
                estate <= E_ENV;         // stopped: envelopes only (:968)
            else if( !bank_ok1 ) begin
                val1   <= 0;
                estate <= E_ADDR2;
            end else begin
                cur_baddr   <= srom_baddr(bank, addr_int1);
                srom_addr   <= srom_baddr(bank, addr_int1) >> 1;
                srom_cs     <= 1;
                srom_settle <= 0;
                fetch2      <= 0;
                estate      <= E_WAITF;
            end
        end
        E_ADDR2: begin
            if( !bank_ok2 ) begin
                val2   <= 0;
                estate <= E_INTERP;
            end else begin
                cur_baddr   <= srom_baddr(bank, addr_int2);
                srom_addr   <= srom_baddr(bank, addr_int2) >> 1;
                srom_cs     <= 1;
                srom_settle <= 0;
                fetch2      <= 1;
                estate      <= E_WAITF;
            end
        end
        E_WAITF: begin
            if( srom_settle != 2'd2 )
                srom_settle <= srom_settle + 2'd1;
            else if( srom_ok ) begin
                srom_cs <= 0;
                if( st_sromn != 8'hFF ) st_sromn <= st_sromn + 8'd1;
                if( srom_byte != 8'd0 ) st_sromd <= srom_byte;
                if( !fetch2 ) begin
                    val1   <= fetched;
                    estate <= E_ADDR2;
                end else begin
                    val2   <= fetched;
                    estate <= E_INTERP;
                end
            end
        end
        E_INTERP: begin
            // interpolate (:517), then accum +/- freqcount (:842/:872)
            fsamp <= ( val1 * $signed({20'd0, 12'd2048 - {1'b0, frac}})
                     + val2 * $signed({21'd0, frac}) ) >>> 11;
            accum <= ctrl[CR_DIR] ? accum - {15'd0, v_freq[vn]}
                                  : accum + {15'd0, v_freq[vn]};
            estate <= E_F1A;
        end
        // 4-pole filter (:556): poles 1/2 always low-pass with K1.
        // xxA computes the product only; xxB does the shift/add and the
        // pole write-back. mulhi()/lp_add()/hp_add() mirror apply_lowpass
        // and apply_highpass exactly, including truncating division.
        E_F1A: begin
            prod   <= $signed({2'b0, k1_r[15:4]}) * (fsamp - o1_r);
            estate <= E_F1B;
        end
        E_F1B: begin
            fsamp  <= divt(prod, 4'd12) + o1_r;
            estate <= E_F2A;
        end
        E_F2A: begin
            v_o1n1[vn] <= fsamp;                        // update_pole (:560)
            prod   <= $signed({2'b0, k1_r[15:4]}) * (fsamp - o2a_r);
            estate <= E_F2B;
        end
        E_F2B: begin
            fsamp  <= divt(prod, 4'd12) + o2a_r;
            estate <= E_F3A;
        end
        E_F3A: begin
            v_o2n2[vn] <= o2a_r;                        // update_2_pole (:564)
            v_o2n1[vn] <= fsamp;
            // pole 3: LP with K1 (LP3), LP with K2 (LP4/LP3|LP4), else HP K2
            prod <= lp_r == 2'b00 ? $signed({2'b0, k2_r[15:4]}) * o3a_r
                  : lp_r == 2'b01 ? $signed({2'b0, k1_r[15:4]}) * (fsamp - o3a_r)
                  :                 $signed({2'b0, k2_r[15:4]}) * (fsamp - o3a_r);
            estate <= E_F3B;
        end
        E_F3B: begin
            fsamp  <= lp_r == 2'b00
                    ? fsamp - o2b_r + divt(prod, 4'd13) + divt({{14{o3a_r[31]}}, o3a_r}, 4'd1)
                    : divt(prod, 4'd12) + o3a_r;
            estate <= E_F4A;
        end
        E_F4A: begin
            v_o3n2[vn] <= o3a_r;
            v_o3n1[vn] <= fsamp;
            // pole 4: HP with K2 for lp modes 00/01, else LP with K2
            prod <= (lp_r == 2'b00 || lp_r == 2'b01)
                  ? $signed({2'b0, k2_r[15:4]}) * o4_r
                  : $signed({2'b0, k2_r[15:4]}) * (fsamp - o4_r);
            estate <= E_F4B;
        end
        E_F4B: begin
            fsamp  <= (lp_r == 2'b00 || lp_r == 2'b01)
                    ? fsamp - o3b_r + divt(prod, 4'd13) + divt({{14{o4_r[31]}}, o4_r}, 4'd1)
                    : divt(prod, 4'd12) + o4_r;
            estate <= E_ENV;
        end
        E_ENV: begin
            if( running ) v_o4n1[vn] <= fsamp;
            // update_envelopes (:618), gated on ecount != 0 (:848)
            if( v_ecount[vn] != 0 ) begin
                v_ecount[vn] <= v_ecount[vn] - 9'd1;
                if( v_lvramp[vn] != 0 )
                    v_lvol[vn] <= ramp16(v_lvol[vn], v_lvramp[vn]);
                if( v_rvramp[vn] != 0 )
                    v_rvol[vn] <= ramp16(v_rvol[vn], v_rvramp[vn]);
                if( v_k1ramp[vn] != 0 &&
                    ( !v_k1ramp[vn][8] || v_filtc[vn][2:0] == 3'd0 ) )
                    v_k1[vn] <= ramp16(v_k1[vn], v_k1ramp[vn][7:0]);
                if( v_k2ramp[vn] != 0 &&
                    ( !v_k2ramp[vn][8] || v_filtc[vn][2:0] == 3'd0 ) )
                    v_k2[vn] <= ramp16(v_k2[vn], v_k2ramp[vn][7:0]);
                v_filtc[vn] <= v_filtc[vn] + 8'd1;
            end
            estate <= running ? E_ACCUM : E_NEXT;
        end
        E_ACCUM: begin
            acc_l  <= acc_l + vol_apply(fsamp, v_lvol[vn]);
            acc_r  <= acc_r + vol_apply(fsamp, v_rvol[vn]);
            estate <= E_LOOP;
        end
        E_LOOP: begin
            // check_for_end_forward / _reverse (:675 / :712)
            if( !ctrl[CR_DIR] ) begin
                if( accum > v_end[vn] && !ctrl[CR_LEI] ) begin
                    if( ctrl[CR_IRQE] ) ctrl[CR_IRQ] <= 1'b1;
                    case( {ctrl[CR_BLE], ctrl[CR_LPE]} )
                        2'b00: ctrl[CR_STOP0] <= 1'b1;
                        2'b01: accum <= v_start[vn] + (accum - v_end[vn]);
                        2'b10: begin                     // trans-wave (:698)
                            accum <= v_start[vn] + (accum - v_end[vn]);
                            {ctrl[CR_BLE], ctrl[CR_LPE]} <= 2'b00;
                            ctrl[CR_LEI] <= 1'b1;
                        end
                        2'b11: begin                     // bi-directional
                            accum <= v_end[vn] - (accum - v_end[vn]);
                            ctrl[CR_DIR] <= ~ctrl[CR_DIR];
                        end
                    endcase
                end
            end else begin
                if( accum < v_start[vn] && !ctrl[CR_LEI] ) begin
                    if( ctrl[CR_IRQE] ) ctrl[CR_IRQ] <= 1'b1;
                    case( {ctrl[CR_BLE], ctrl[CR_LPE]} )
                        2'b00: ctrl[CR_STOP0] <= 1'b1;
                        2'b01: accum <= v_end[vn] - (v_start[vn] - accum);
                        2'b10: begin
                            accum <= v_end[vn] - (v_start[vn] - accum);
                            {ctrl[CR_BLE], ctrl[CR_LPE]} <= 2'b00;
                            ctrl[CR_LEI] <= 1'b1;
                        end
                        2'b11: begin
                            accum <= v_start[vn] + (v_start[vn] - accum);
                            ctrl[CR_DIR] <= ~ctrl[CR_DIR];
                        end
                    endcase
                end
            end
            estate <= E_NEXT;
        end
        E_NEXT: begin
            v_accum[vn] <= running ? accum : v_accum[vn];
            // generate_irq (:983): latch vector only if previous acked
            if( ctrl[CR_IRQ] && irqv[7] ) begin
                irqv          <= {3'd0, vn};
                v_control[vn] <= ctrl & ~(16'h0080);
            end else
                v_control[vn] <= ctrl;
            if( vn == active_voices )
                estate <= E_OUT;
            else begin
                vn     <= vn + 5'd1;
                estate <= E_VOICE;
            end
        end
        E_OUT: begin
            // clamp +-2^19 (:1043). Swapped stereo (itech32.cpp:1798):
            // stream ch0 (lvol) -> right, ch1 (rvol) -> left. 20 -> 16 bit.
            snd_right <= clamp20(acc_l) >>> 4;
            snd_left  <= clamp20(acc_r) >>> 4;
            sample    <= 1;
            estate    <= E_IDLE;
        end
        default: estate <= E_IDLE;
        endcase
    end
end

endmodule
