`timescale 1ns/1ps
/*  This file is part of JTSFTM.  GPLv3 - see LICENSE.

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

    TODO:
      - exact byte-lane latch semantics from es5506.cpp
      - 4-pole filter and K1/K2 ramps
      - envelope counters and volume ramps
      - all loop modes, reverse/bidirectional loops and IRQ vector stacking
      - compressed/u-law sample mode
      - six serial channels; SFTM routes to stereo only
      - 20-bit clamp/saturation exactly like real ES5506
*/

module jt5506(
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

reg [ 5:0] page;
reg [ 4:0] active;       // active voices-1, default 31
reg [ 7:0] irqv;

// host write latch: ES5506 registers are 32-bit addressed through byte lanes.
// This simplified path writes the selected byte directly.
integer i;
always @(posedge clk) begin
    if( rst ) begin
        page   <= 6'd0;
        active <= 5'd31;
        irqv   <= 8'h80;
        irq    <= 1'b0;
        for(i=0;i<32;i=i+1) begin
            control[i] <= 16'h0003; // stopped
            fc[i]      <= 17'd0;
            startp[i]  <= 25'd0;
            endp[i]    <= 25'd0;
            accum[i]   <= 32'd0;
            lvol[i]    <= 16'd0;
            rvol[i]    <= 16'd0;
        end
    end else begin
        if( host_we ) write_reg(page, host_addr, host_din);
        if( host_re && host_addr==6'h38 ) begin
            irq  <= 1'b0;       // IRQ vector read acknowledges
            irqv <= 8'h80;
        end
    end
end

always @(*) begin
    host_dout = 8'hff;
    case(host_addr)
        6'h38: host_dout = irqv;      // IRQV (low byte) - spec loc H70 / host fold
        6'h3c: host_dout = {2'b0,page};
        default: host_dout = read_reg(page, host_addr);
    endcase
end

task write_reg(input [5:0] pg, input [5:0] addr, input [7:0] data);
begin
    // global PAGE register (spec loc H78)
    if( addr==6'h3c ) page <= data[5:0];
    else if( pg < 32 ) begin
        case(addr[5:3])
            3'h0: control[pg][ (addr[1] ? 15:7) -: 8 ] <= data; // CR
            3'h1: fc[pg][ (addr[1] ? 15:7) -: 8 ]      <= data; // FC low 16
            3'h2: lvol[pg][ (addr[1] ? 15:7) -: 8 ]    <= data; // LVOL
            3'h4: rvol[pg][ (addr[1] ? 15:7) -: 8 ]    <= data; // RVOL
            default: ;
        endcase
    end else if( pg>=32 && pg<64 ) begin
        case(addr[5:3])
            3'h1: startp[pg[4:0]][ (addr[1] ? 23:15) -: 8 ] <= data; // START
            3'h2: endp  [pg[4:0]][ (addr[1] ? 23:15) -: 8 ] <= data; // END
            3'h3: accum [pg[4:0]][ (addr[1] ? 31:23) -: 8 ] <= data; // ACCUM
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
            3'h4: read_reg = addr[1] ? rvol[pg][15:8]    : rvol[pg][7:0];
            default: ;
        endcase
    end
end
endfunction

// ---------------------------------------------------------------------------
// Voice scheduler and mixer. One voice per cen. A complete output sample is
// emitted after active+1 voices have been accumulated.
// ---------------------------------------------------------------------------
reg [4:0]  vidx;
reg signed [31:0] mix_l, mix_r;
wire voice_running = control[vidx][CTRL_STOP1:CTRL_STOP0] == 2'b00;
wire [1:0] bank = {control[vidx][CTRL_BS1], control[vidx][CTRL_BS0]};
// Bank offset: MAME ES5506 has 4 independent 21-bit ROM banks (bank0..3).
// For SFTM: bank0 = srom0 (2 MB = 1 Mword, SDRAM offset 0),
//           bank3 = srom3 (512 KB = 256 Kword, SDRAM offset 0x100000).
// Banks 1 and 2 are unused by SFTM; they alias to bank 0.
// Combinatorial: address is valid in the same cen cycle srom_cs is asserted.
wire [20:0] bank_base = (bank == 2'b11) ? 21'h100000 : 21'h000000;
assign srom_addr = accum[vidx][31:11] + bank_base;

always @(posedge clk) begin
    sample  <= 1'b0;
    srom_cs <= 1'b0;

    if( rst ) begin
        vidx <= 0; mix_l <= 0; mix_r <= 0; left <= 0; right <= 0;
    end else if( cen ) begin
        srom_cs   <= voice_running;
        if( voice_running && srom_ok ) begin
            // TODO: interpolation uses current+next samples and frac bits.
            mix_l <= mix_l + (($signed(srom_data) * $signed({1'b0,lvol[vidx][14:0]})) >>> 14);
            mix_r <= mix_r + (($signed(srom_data) * $signed({1'b0,rvol[vidx][14:0]})) >>> 14);
            accum[vidx] <= accum[vidx] + {15'd0, fc[vidx]}; // 17-bit FC -> 32-bit acc

            // crude loop/stop; exact modes TODO
            if( accum[vidx][31:11] >= endp[vidx][20:0] ) begin
                if( control[vidx][CTRL_LPE] ) accum[vidx] <= {startp[vidx][20:0], 11'd0};
                else control[vidx][CTRL_STOP0] <= 1'b1;
            end
        end

        if( vidx==active ) begin
            left   <= sat16(mix_l);
            right  <= sat16(mix_r);
            sample <= 1'b1;
            mix_l  <= 0;
            mix_r  <= 0;
            vidx   <= 0;
        end else vidx <= vidx + 5'd1;
    end
end

function [15:0] sat16(input signed [31:0] v);
begin
    if( v >  32'sd32767 ) sat16 = 16'h7fff;
    else if( v < -32'sd32768 ) sat16 = 16'h8000;
    else sat16 = v[15:0];
end
endfunction

endmodule
