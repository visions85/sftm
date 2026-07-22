`timescale 1ns/1ps
/*  This file is part of SFTM.  GPLv3 - see LICENSE.

    Ensoniq ES5506 "OTTO" sample synthesizer.

    References:
      - MAME src/devices/sound/es5506.cpp
      - ENSONIQ OTTO Technical Specification Rev 2.3

    Implemented here:
      - 8-bit 68000-compatible host interface via PAGE register
      - 32 voices, 32-bit registers, bank-select bits
      - active-voice scheduler
      - 21.11 accumulator -> sample ROM address
      - basic 16-bit sample fetch and volume/pan mix

    Implemented:
      - 4-pole IIR filter: K1/K2 coefficients per voice; apply_lowpass /
        apply_highpass matching MAME es5506.cpp apply_filters() exactly;
        LP mode selected by control[9:8] = {LP4, LP3}.

    Implemented (Phase 4):
      - Correct low-page register map (per OTTO spec §4):
          addr[5:3]: 0=CR, 1=FC, 2=LVOL, 3=LVRAMP, 4=RVOL, 5=RVRAMP, 6=ECOUNT, 7=K2
      - Correct high-page (32-63) additions:
          addr[5:3]=5=K1, 6=K2RAMP, 7=K1RAMP
      - Envelope/volume ramps: LVRAMP/RVRAMP applied to LVOL/RVOL each sample tick
        while ECOUNT > 0; K1RAMP/K2RAMP applied similarly to K1/K2.
      - IRQ vector stacking: voice events (one-shot stop, ECOUNT expiry with IRQE)
        push to IRQV; stacked IRQs re-fire after IRQV is acknowledged.

    TODO:
      - compressed/u-law sample mode
      - six serial channels; SFTM routes to stereo only
      - 20-bit clamp/saturation exactly like real ES5506
*/

module sftm5506(
    input               rst,
    input               clk,
    input               cen,          // 16 MHz master enable

    // 8-bit host interface
    input       [ 5:0]  host_addr,
    input       [ 7:0]  host_din,
    output reg  [ 7:0]  host_dout,
    input               host_we,
    input               host_re,
    output reg          irq,

    // sample ROM (16-bit word addressed)
    output      [20:0]  srom_addr,  // combinatorial: accum[vidx][31:11]
    input       [15:0]  srom_data,
    output reg          srom_cs,
    input               srom_ok,

    // stereo PCM to JTFRAME mixer
    output reg  [15:0]  left,
    output reg  [15:0]  right,
    output reg          sample
);

// control bits (MAME es5506.cpp)
localparam CTRL_BS1   = 15, CTRL_BS0 = 14, CTRL_CMPD = 13,
           CTRL_CA2   = 12, CTRL_CA1 = 11, CTRL_CA0  = 10,
           CTRL_LP4   = 9,  CTRL_LP3 = 8,  CTRL_IRQ  = 7,
           CTRL_DIR   = 6,  CTRL_IRQE= 5,  CTRL_BLE  = 4,
           CTRL_LPE   = 3,  CTRL_LEI = 2,  CTRL_STOP1= 1,
           CTRL_STOP0 = 0;

// voice registers (logical 32-bit; not all bits used)
reg [15:0] control [0:31];
reg [16:0] fc      [0:31];
reg [24:0] startp  [0:31];
reg [24:0] endp    [0:31];
reg [31:0] accum   [0:31];
reg [15:0] lvol    [0:31];
reg [15:0] rvol    [0:31];
// Filter coefficients (16-bit unsigned; K>>4 gives 12-bit cutoff factor)
reg [15:0] k1      [0:31];
reg [15:0] k2      [0:31];
// Envelope/ramp registers (16-bit; ramp value in bits [7:0] as signed 8-bit)
reg [15:0] lvramp  [0:31];  // LVRAMP: left-vol  ramp signed delta per sample
reg [15:0] rvramp  [0:31];  // RVRAMP: right-vol ramp signed delta per sample
reg [15:0] ecount  [0:31];  // ECOUNT: ramp countdown (0 = idle)
reg [15:0] k1ramp  [0:31];  // K1RAMP: K1 signed delta per sample (high-page)
reg [15:0] k2ramp  [0:31];  // K2RAMP: K2 signed delta per sample (high-page)
// 4-pole IIR filter state (32-bit signed; 6 delay-line registers per voice)
reg signed [31:0] o1n1 [0:31];  // pole-1 output n-1
reg signed [31:0] o2n1 [0:31];  // pole-2 output n-1
reg signed [31:0] o3n1 [0:31];  // pole-3 output n-1
reg signed [31:0] o4n1 [0:31];  // pole-4 output n-1

reg [ 5:0] page;
reg [ 4:0] active;       // active voices-1, default 31
reg [ 7:0] irqv;         // IRQV register (bit 7 = empty / no-IRQ-pending)
reg        host_irqv_ack; // pulsed for one clk when host reads IRQV

// All clocked state in a single always block to satisfy Quartus
// single-driver requirement.  host_irqv_ack is still registered (set in
// the same cycle the host reads IRQV, applied to control[] the next cycle).
integer i;

// Force register arrays into the sensitivity list.  iverilog does not always
// infer array element dependencies from function calls in always @(*), so we
// read a XOR-reduction of every voice's key registers here.  Excluded from
// Quartus via translate_off since it uses static analysis and doesn't need this.
// synthesis translate_off
wire _sens_k2    = ^{k2   [0],k2   [1],k2   [2],k2   [3],k2   [4],k2   [5],k2   [6],k2   [7],
                     k2   [8],k2   [9],k2  [10],k2  [11],k2  [12],k2  [13],k2  [14],k2  [15],
                     k2  [16],k2  [17],k2  [18],k2  [19],k2  [20],k2  [21],k2  [22],k2  [23],
                     k2  [24],k2  [25],k2  [26],k2  [27],k2  [28],k2  [29],k2  [30],k2  [31]};
wire _sens_k1    = ^{k1   [0],k1   [1],k1   [2],k1   [3],k1   [4],k1   [5],k1   [6],k1   [7],
                     k1   [8],k1   [9],k1  [10],k1  [11],k1  [12],k1  [13],k1  [14],k1  [15],
                     k1  [16],k1  [17],k1  [18],k1  [19],k1  [20],k1  [21],k1  [22],k1  [23],
                     k1  [24],k1  [25],k1  [26],k1  [27],k1  [28],k1  [29],k1  [30],k1  [31]};
wire _sens_lvol  = ^{lvol [0],lvol [1],lvol [2],lvol [3],lvol [4],lvol [5],lvol [6],lvol [7],
                     lvol [8],lvol [9],lvol[10],lvol[11],lvol[12],lvol[13],lvol[14],lvol[15],
                     lvol[16],lvol[17],lvol[18],lvol[19],lvol[20],lvol[21],lvol[22],lvol[23],
                     lvol[24],lvol[25],lvol[26],lvol[27],lvol[28],lvol[29],lvol[30],lvol[31]};
wire _sens_rvol  = ^{rvol [0],rvol [1],rvol [2],rvol [3],rvol [4],rvol [5],rvol [6],rvol [7],
                     rvol [8],rvol [9],rvol[10],rvol[11],rvol[12],rvol[13],rvol[14],rvol[15],
                     rvol[16],rvol[17],rvol[18],rvol[19],rvol[20],rvol[21],rvol[22],rvol[23],
                     rvol[24],rvol[25],rvol[26],rvol[27],rvol[28],rvol[29],rvol[30],rvol[31]};
wire _sens_ecnt  = ^{ecount[0],ecount[1],ecount[2],ecount[3],ecount[4],ecount[5],ecount[6],ecount[7],
                     ecount[8],ecount[9],ecount[10],ecount[11],ecount[12],ecount[13],ecount[14],ecount[15],
                     ecount[16],ecount[17],ecount[18],ecount[19],ecount[20],ecount[21],ecount[22],ecount[23],
                     ecount[24],ecount[25],ecount[26],ecount[27],ecount[28],ecount[29],ecount[30],ecount[31]};
/* verilator lint_off UNUSED */
wire _sens_all = _sens_k2 ^ _sens_k1 ^ _sens_lvol ^ _sens_rvol ^ _sens_ecnt;
/* verilator lint_on UNUSED */
// synthesis translate_on

// Inline combinatorial read: all array accesses are in this always @(*) block
// so iverilog includes every voice register in the sensitivity list.
always @(*) begin
    host_dout = 8'hff;
    case(host_addr)
        6'h38: host_dout = irqv;
        6'h3c: host_dout = {2'b0,page};
        6'h3e: host_dout = {3'b0,active};
        default: begin
            if( page < 32 ) begin
                case(host_addr[5:3])
                    3'h0: host_dout = host_addr[1] ? control[page][15:8]  : control[page][7:0];
                    3'h1: host_dout = host_addr[1] ? fc[page][15:8]       : fc[page][7:0];
                    3'h2: host_dout = host_addr[1] ? lvol[page][15:8]     : lvol[page][7:0];
                    3'h3: host_dout = host_addr[1] ? lvramp[page][15:8]   : lvramp[page][7:0];
                    3'h4: host_dout = host_addr[1] ? rvol[page][15:8]     : rvol[page][7:0];
                    3'h5: host_dout = host_addr[1] ? rvramp[page][15:8]   : rvramp[page][7:0];
                    3'h6: host_dout = host_addr[1] ? ecount[page][15:8]   : ecount[page][7:0];
                    3'h7: host_dout = host_addr[1] ? k2[page][15:8]       : k2[page][7:0];
                    default: ;
                endcase
            end else if( page >= 6'h20 ) begin  // pages 32-63 (6-bit: 6'h40 overflows)
                case(host_addr[5:3])
                    3'h1: host_dout = host_addr[1] ? startp[page[4:0]][23:16] : startp[page[4:0]][15:8];
                    3'h2: host_dout = host_addr[1] ? endp  [page[4:0]][23:16] : endp  [page[4:0]][15:8];
                    3'h3: host_dout = host_addr[1] ? accum [page[4:0]][31:24] : accum [page[4:0]][23:16];
                    3'h5: host_dout = host_addr[1] ? k1    [page[4:0]][15:8]  : k1    [page[4:0]][7:0];
                    3'h6: host_dout = host_addr[1] ? k2ramp[page[4:0]][15:8]  : k2ramp[page[4:0]][7:0];
                    3'h7: host_dout = host_addr[1] ? k1ramp[page[4:0]][15:8]  : k1ramp[page[4:0]][7:0];
                    default: ;
                endcase
            end
        end
    endcase
end

task write_reg(input [5:0] pg, input [5:0] addr, input [7:0] data);
begin
    // global PAGE register (spec loc H78)
    if( addr==6'h3c ) page <= data[5:0];
    // ACTIVE register (spec loc H7C): number of active voices - 1
    else if( addr==6'h3e ) active <= data[4:0];
    else if( pg < 32 ) begin
        // Low pages 0-31: voice per-sample registers.
        // Layout per OTTO spec §4 (byte offset H00..H38, addr[5:3] selects reg).
        case(addr[5:3])
            3'h0: control[pg][ (addr[1] ? 15:7) -: 8 ]  <= data; // H00 CR
            3'h1: fc[pg][ (addr[1] ? 15:7) -: 8 ]       <= data; // H08 FC
            3'h2: lvol[pg][ (addr[1] ? 15:7) -: 8 ]     <= data; // H10 LVOL
            3'h3: lvramp[pg][ (addr[1] ? 15:7) -: 8 ]   <= data; // H18 LVRAMP
            3'h4: rvol[pg][ (addr[1] ? 15:7) -: 8 ]     <= data; // H20 RVOL
            3'h5: rvramp[pg][ (addr[1] ? 15:7) -: 8 ]   <= data; // H28 RVRAMP
            3'h6: ecount[pg][ (addr[1] ? 15:7) -: 8 ]   <= data; // H30 ECOUNT
            3'h7: k2[pg][ (addr[1] ? 15:7) -: 8 ]       <= data; // H38 K2
        endcase
    end else if( pg>=32 && pg<64 ) begin
        // High pages 32-63: address/accumulator + remaining coefficients.
        case(addr[5:3])
            3'h1: startp[pg[4:0]][ (addr[1] ? 23:15) -: 8 ] <= data; // H08 START
            3'h2: endp  [pg[4:0]][ (addr[1] ? 23:15) -: 8 ] <= data; // H10 END
            3'h3: accum [pg[4:0]][ (addr[1] ? 31:23) -: 8 ] <= data; // H18 ACCUM
            3'h5: k1    [pg[4:0]][ (addr[1] ? 15:7)  -: 8 ] <= data; // H28 K1
            3'h6: k2ramp[pg[4:0]][ (addr[1] ? 15:7)  -: 8 ] <= data; // H30 K2RAMP
            3'h7: k1ramp[pg[4:0]][ (addr[1] ? 15:7)  -: 8 ] <= data; // H38 K1RAMP
            default: ;
        endcase
    end
end
endtask

function [7:0] read_reg(input [5:0] pg, input [5:0] addr);
begin
    read_reg = 8'hff;
    if( pg < 32 ) begin
        case(addr[5:3])
            3'h0: read_reg = addr[1] ? control[pg][15:8] : control[pg][7:0];
            3'h1: read_reg = addr[1] ? fc[pg][15:8]      : fc[pg][7:0];
            3'h2: read_reg = addr[1] ? lvol[pg][15:8]    : lvol[pg][7:0];
            3'h3: read_reg = addr[1] ? lvramp[pg][15:8]  : lvramp[pg][7:0];
            3'h4: read_reg = addr[1] ? rvol[pg][15:8]    : rvol[pg][7:0];
            3'h5: read_reg = addr[1] ? rvramp[pg][15:8]  : rvramp[pg][7:0];
            3'h6: read_reg = addr[1] ? ecount[pg][15:8]  : ecount[pg][7:0];
            3'h7: read_reg = addr[1] ? k2[pg][15:8]      : k2[pg][7:0];
            default: ;
        endcase
    end else if( pg>=32 && pg<64 ) begin
        case(addr[5:3])
            3'h1: read_reg = addr[1] ? startp[pg[4:0]][23:16] : startp[pg[4:0]][15:8];
            3'h2: read_reg = addr[1] ? endp  [pg[4:0]][23:16] : endp  [pg[4:0]][15:8];
            3'h3: read_reg = addr[1] ? accum [pg[4:0]][31:24] : accum [pg[4:0]][23:16];
            3'h5: read_reg = addr[1] ? k1    [pg[4:0]][15:8]  : k1    [pg[4:0]][7:0];
            3'h6: read_reg = addr[1] ? k2ramp[pg[4:0]][15:8]  : k2ramp[pg[4:0]][7:0];
            3'h7: read_reg = addr[1] ? k1ramp[pg[4:0]][15:8]  : k1ramp[pg[4:0]][7:0];
            default: ;
        endcase
    end
end
endfunction

// ---------------------------------------------------------------------------
// Voice index register — declared here so filter wires below can reference it.
// ---------------------------------------------------------------------------
reg [4:0]  vidx;
reg signed [31:0] mix_l, mix_r;

// ---------------------------------------------------------------------------
// 4-pole IIR filter (MAME es5506.cpp apply_filters).
//
// apply_lowpass(state_prev, k, input):
//   result = (k>>4) * (state_prev - input) / 4096 + input
// apply_highpass(cur_input, k, state_prev, prev_prev):
//   result = cur_input - prev_prev + (k>>4) * state_prev / 8192 + state_prev / 2
//
// All arithmetic is signed.  Multiplies are done as 64-bit (widened from the
// 12-bit coefficient × 32-bit state) to avoid Verilog truncation.
// ---------------------------------------------------------------------------

// K coefficients, right-shifted by 4 (= FILTER_SHIFT), zero-extended to 64 b.
// This produces the 12-bit integer multiplier used in the formulas above.
wire signed [63:0] fk1_64 = {48'd0, k1[vidx][15:4]};
wire signed [63:0] fk2_64 = {48'd0, k2[vidx][15:4]};

// LP mode from control register bits 9:8 = {LP4, LP3}.
//   2'b00: pole3=HP K2, pole4=HP K2
//   2'b01: pole3=LP K1, pole4=HP K2
//   2'b10: pole3=LP K2, pole4=LP K2
//   2'b11: pole3=LP K1, pole4=LP K2
wire [1:0] lp_mode = {control[vidx][CTRL_LP4], control[vidx][CTRL_LP3]};

// Sign-extended 16-bit sample → 32-bit.
wire signed [31:0] fin = {{16{srom_data[15]}}, srom_data};

// --- Pole 1: always LP using K1 ---
// result = fk1*(o1n1 - fin)/4096 + fin
wire signed [63:0] p1_diff_64 = {{32{o1n1[vidx][31]}}, o1n1[vidx]}
                                - {{32{fin[31]}}, fin};
wire signed [63:0] p1_prod    = fk1_64 * p1_diff_64;
wire signed [31:0] p1         = $signed(p1_prod[43:12]) + fin;

// --- Pole 2: always LP using K1 ---
wire signed [63:0] p2_diff_64 = {{32{o2n1[vidx][31]}}, o2n1[vidx]}
                                - {{32{p1[31]}}, p1};
wire signed [63:0] p2_prod    = fk1_64 * p2_diff_64;
wire signed [31:0] p2         = $signed(p2_prod[43:12]) + p1;

// --- Pole 3: LP K1 variant (lp_mode=2'b01 or 2'b11) ---
wire signed [63:0] p3_lpk1_diff = {{32{o3n1[vidx][31]}}, o3n1[vidx]}
                                  - {{32{p2[31]}}, p2};
wire signed [63:0] p3_lpk1_prod = fk1_64 * p3_lpk1_diff;
wire signed [31:0] p3_lpk1      = $signed(p3_lpk1_prod[43:12]) + p2;

// --- Pole 3: LP K2 variant (lp_mode=2'b10) ---
wire signed [63:0] p3_lpk2_diff = {{32{o3n1[vidx][31]}}, o3n1[vidx]}
                                  - {{32{p2[31]}}, p2};
wire signed [63:0] p3_lpk2_prod = fk2_64 * p3_lpk2_diff;
wire signed [31:0] p3_lpk2      = $signed(p3_lpk2_prod[43:12]) + p2;

// --- Pole 3: HP K2 variant (lp_mode=2'b00) ---
// apply_hp(p2, k2, o3n1, prev=o2n1)
wire signed [63:0] p3_hpk2_prod = fk2_64 * {{32{o3n1[vidx][31]}}, o3n1[vidx]};
wire signed [31:0] p3_hpk2      = p2 - o2n1[vidx]
                                  + $signed(p3_hpk2_prod[44:13])
                                  + (o3n1[vidx] >>> 1);

wire signed [31:0] p3 = lp_mode[1] ? (lp_mode[0] ? p3_lpk1 : p3_lpk2)
                                    : (lp_mode[0] ? p3_lpk1 : p3_hpk2);

// --- Pole 4: LP K2 variant (lp_mode=2'b10 or 2'b11) ---
wire signed [63:0] p4_lpk2_diff = {{32{o4n1[vidx][31]}}, o4n1[vidx]}
                                  - {{32{p3[31]}}, p3};
wire signed [63:0] p4_lpk2_prod = fk2_64 * p4_lpk2_diff;
wire signed [31:0] p4_lpk2      = $signed(p4_lpk2_prod[43:12]) + p3;

// --- Pole 4: HP K2 variant (lp_mode=2'b00 or 2'b01) ---
// apply_hp(p3, k2, o4n1, prev=o3n1 [becomes new o3n2 after pole-3 update])
wire signed [63:0] p4_hpk2_prod = fk2_64 * {{32{o4n1[vidx][31]}}, o4n1[vidx]};
wire signed [31:0] p4_hpk2      = p3 - o3n1[vidx]
                                  + $signed(p4_hpk2_prod[44:13])
                                  + (o4n1[vidx] >>> 1);

wire signed [31:0] p4 = lp_mode[1] ? p4_lpk2 : p4_hpk2;

// ---------------------------------------------------------------------------
// Per-voice contribution (combinatorial; used by both flush and accumulate
// paths to avoid the NBA conflict when vidx==active and voice is running).
// ---------------------------------------------------------------------------
wire signed [31:0] contrib_l = (p4 * $signed({1'b0,lvol[vidx][14:0]})) >>> 14;
wire signed [31:0] contrib_r = (p4 * $signed({1'b0,rvol[vidx][14:0]})) >>> 14;

// ---------------------------------------------------------------------------
// Envelope ramp wires (18-bit signed; compute clamped result for current vidx).
// Each ramp value is the signed 8-bit delta in bits [7:0] of its register.
// Result is clamped to [0, 0xFFFF]: negative → 0, >0xFFFF → 0xFFFF.
// ---------------------------------------------------------------------------
wire signed [17:0] env_lv_s = $signed({2'b00,lvol[vidx]}) + $signed({{10{lvramp[vidx][7]}},lvramp[vidx][7:0]});
wire signed [17:0] env_rv_s = $signed({2'b00,rvol[vidx]}) + $signed({{10{rvramp[vidx][7]}},rvramp[vidx][7:0]});
wire signed [17:0] env_k1_s = $signed({2'b00,k1[vidx]})   + $signed({{10{k1ramp[vidx][7]}},k1ramp[vidx][7:0]});
wire signed [17:0] env_k2_s = $signed({2'b00,k2[vidx]})   + $signed({{10{k2ramp[vidx][7]}},k2ramp[vidx][7:0]});
wire [15:0] env_lv_c = env_lv_s[17] ? 16'h0000 : env_lv_s[16] ? 16'hFFFF : env_lv_s[15:0];
wire [15:0] env_rv_c = env_rv_s[17] ? 16'h0000 : env_rv_s[16] ? 16'hFFFF : env_rv_s[15:0];
wire [15:0] env_k1_c = env_k1_s[17] ? 16'h0000 : env_k1_s[16] ? 16'hFFFF : env_k1_s[15:0];
wire [15:0] env_k2_c = env_k2_s[17] ? 16'h0000 : env_k2_s[16] ? 16'hFFFF : env_k2_s[15:0];

// ---------------------------------------------------------------------------
// Voice scheduler and mixer. One voice per cen. A complete output sample is
// emitted after active+1 voices have been accumulated.
// ---------------------------------------------------------------------------
wire voice_running = control[vidx][CTRL_STOP1:CTRL_STOP0] == 2'b00;
wire [1:0] bank = {control[vidx][CTRL_BS1], control[vidx][CTRL_BS0]};
// Bank offset: MAME ES5506 has 4 independent 21-bit ROM banks (bank0..3).
// For SFTM: bank0 = srom0 (2 MB = 1 Mword, SDRAM offset 0),
//           bank3 = srom3 (512 KB = 256 Kword, SDRAM offset 0x100000).
// Banks 1 and 2 are unused by SFTM; they alias to bank 0.
// Combinatorial: address is valid in the same cen cycle srom_cs is asserted.
wire [20:0] bank_base = (bank == 2'b11) ? 21'h100000 : 21'h000000;
assign srom_addr = accum[vidx][31:11] + bank_base;

// ---------------------------------------------------------------------------
// Loop mode combinatorial logic (evaluated for the current voice each cen).
//
// CTRL_DIR (bit 6): 0 = forward (accum += FC), 1 = reverse (accum -= FC).
// CTRL_LPE (bit 3): loop enable.  0 = one-shot (stop at boundary).
// CTRL_BLE (bit 4): bidirectional loop.  DIR toggles at each boundary.
//
// Boundary positions as 32-bit accumulator values:
//   {word_address[20:0], 11'd0}  (word_address = srom word index)
// ---------------------------------------------------------------------------
wire       dir  = control[vidx][CTRL_DIR];
wire       lpe  = control[vidx][CTRL_LPE];
wire       ble  = control[vidx][CTRL_BLE];

// Direction-aware next accumulator (32-bit; use signed comparison for reverse).
wire [31:0] next_acc = dir
    ? (accum[vidx] - {15'd0, fc[vidx]})
    : (accum[vidx] + {15'd0, fc[vidx]});

// Loop boundary as accumulator integer positions.
wire [31:0] acc_at_start = {startp[vidx][20:0], 11'd0};
wire [31:0] acc_at_end   = {endp[vidx][20:0],   11'd0};

// Boundary hit detection on next_acc.
// Forward: integer part of next_acc >= end word address.
// Reverse: signed next_acc < start position (correctly handles underflow past 0).
wire at_fwd_end  = ~dir & (next_acc[31:11] >= endp[vidx][20:0]);
wire at_rev_end  =  dir & ($signed(next_acc) < $signed(acc_at_start));
wire at_boundary = at_fwd_end | at_rev_end;

always @(posedge clk) begin
    sample  <= 1'b0;
    srom_cs <= 1'b0;

    if( rst ) begin
        // ---- reset everything (merged from both original always blocks) ----
        page   <= 6'd0;
        active <= 5'd31;
        host_irqv_ack <= 1'b0;
        for(i=0;i<32;i=i+1) begin
            control[i] <= 16'h0003; // stopped
            fc[i]      <= 17'd0;
            startp[i]  <= 25'd0;
            endp[i]    <= 25'd0;
            accum[i]   <= 32'd0;
            lvol[i]    <= 16'd0;
            rvol[i]    <= 16'd0;
            k1[i]      <= 16'd0;
            k2[i]      <= 16'd0;
            lvramp[i]  <= 16'd0;
            rvramp[i]  <= 16'd0;
            ecount[i]  <= 16'd0;
            k1ramp[i]  <= 16'd0;
            k2ramp[i]  <= 16'd0;
            o1n1[i]    <= 32'd0;
            o2n1[i]    <= 32'd0;
            o3n1[i]    <= 32'd0;
            o4n1[i]    <= 32'd0;
        end
        vidx  <= 0; mix_l <= 0; mix_r <= 0; left <= 0; right <= 0;
        irqv  <= 8'h80;
        irq   <= 1'b0;
    end else begin
        // ---- host interface ----
        host_irqv_ack <= 1'b0;  // default: deassert each cycle
        if( host_we ) write_reg(page, host_addr, host_din);
        if( host_re && host_addr==6'h38 ) host_irqv_ack <= 1'b1;

        // ---- IRQV acknowledge (uses host_irqv_ack registered last cycle) ----
        if( host_irqv_ack ) begin
            if( !irqv[7] ) control[irqv[4:0]][CTRL_IRQ] <= 1'b0;
            irqv <= 8'h80;
            irq  <= 1'b0;
        end
    end

    if( !rst && cen ) begin
        srom_cs <= voice_running;

        // IRQ rescan: if current voice has a stacked CTRL_IRQ and irqv is free,
        // deliver it now.  This re-fires pending IRQs after IRQV acknowledge.
        if( control[vidx][CTRL_IRQ] && irqv[7] ) begin
            irqv <= {3'b000, vidx};
            irq  <= 1'b1;
        end

        // Filter state and accumulator advance (both flush and non-flush paths).
        if( voice_running && srom_ok ) begin
            // Update filter state (update_pole / update_2_pole from MAME).
            // Note: HP prev_prev uses pre-update o2n1/o3n1 read combinatorially
            // above, so o2n2/o3n2 delay registers are not needed.
            o1n1[vidx] <= p1;
            o2n1[vidx] <= p2;
            o3n1[vidx] <= p3;
            o4n1[vidx] <= p4;

            // Advance accumulator and handle loop/stop.
            if( at_boundary ) begin
                if( lpe ) begin
                    if( ble ) begin
                        // Bidirectional: flip direction and pin to boundary.
                        control[vidx][CTRL_DIR] <= ~dir;
                        accum[vidx] <= dir ? acc_at_start : acc_at_end;
                    end else begin
                        // Unidirectional loop: jump to the opposite boundary.
                        accum[vidx] <= dir ? acc_at_end : acc_at_start;
                    end
                end else begin
                    // One-shot: stop the voice and optionally fire IRQ.
                    control[vidx][CTRL_STOP0] <= 1'b1;
                    if( control[vidx][CTRL_IRQE] ) begin
                        control[vidx][CTRL_IRQ] <= 1'b1;
                        if( irqv[7] ) begin   // irqv free — deliver immediately
                            irqv <= {3'b000, vidx};
                            irq  <= 1'b1;
                        end
                    end
                end
            end else begin
                accum[vidx] <= next_acc;
            end

            // Envelope ramp: apply signed 8-bit deltas to LVOL/RVOL/K1/K2.
            if( ecount[vidx] != 16'd0 ) begin
                lvol[vidx]  <= env_lv_c;
                rvol[vidx]  <= env_rv_c;
                k1[vidx]    <= env_k1_c;
                k2[vidx]    <= env_k2_c;
                ecount[vidx] <= ecount[vidx] - 16'd1;
                // Fire IRQ when envelope expires (if IRQE set).
                if( ecount[vidx] == 16'd1 && control[vidx][CTRL_IRQE] ) begin
                    control[vidx][CTRL_IRQ] <= 1'b1;
                    if( irqv[7] ) begin
                        irqv <= {3'b000, vidx};
                        irq  <= 1'b1;
                    end
                end
            end
        end

        // Mixer: separate flush and accumulate paths so the final voice
        // (vidx==active) is included before mix_l/mix_r are reset.
        // contrib_l/contrib_r are combinatorial — no NBA conflict.
        // TODO: interpolation uses current+next samples and frac bits.
        if( vidx == active ) begin
            left   <= sat16((voice_running && srom_ok) ? mix_l + contrib_l : mix_l);
            right  <= sat16((voice_running && srom_ok) ? mix_r + contrib_r : mix_r);
            sample <= 1'b1;
            mix_l  <= 0;
            mix_r  <= 0;
            vidx   <= 0;
        end else begin
            if( voice_running && srom_ok ) begin
                mix_l <= mix_l + contrib_l;
                mix_r <= mix_r + contrib_r;
            end
            vidx <= vidx + 5'd1;
        end
    end // cen
end

function [15:0] sat16(input signed [31:0] v);
begin
    if( v >  32'sd32767 ) sat16 = 16'h7fff;
    else if( v < -32'sd32768 ) sat16 = 16'h8000;
    else sat16 = v[15:0];
end
endfunction

endmodule
