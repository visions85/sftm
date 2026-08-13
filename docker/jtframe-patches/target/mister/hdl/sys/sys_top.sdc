# Specify root clocks
create_clock -period "50.0 MHz"  [get_ports FPGA_CLK1_50]
create_clock -period "50.0 MHz"  [get_ports FPGA_CLK2_50]
create_clock -period "50.0 MHz"  [get_ports FPGA_CLK3_50]
create_clock -period "100.0 MHz" [get_pins -compatibility_mode *|h2f_user0_clk]
create_clock -period "100.0 MHz" [get_pins -compatibility_mode spi|sclk_out] -name spi_sck
create_clock -period "10.0 MHz"  [get_pins -compatibility_mode hdmi_i2c|out_clk] -name hdmi_sck

derive_pll_clocks
derive_clock_uncertainty

# Decouple different clock groups (to simplify routing)
set_clock_groups -exclusive \
   -group [get_clocks { *|pll|pll_inst|altera_pll_i|*[*].*|divclk}] \
   -group [get_clocks { pll_hdmi|pll_hdmi_inst|altera_pll_i|*[0].*|divclk}] \
   -group [get_clocks { pll_audio|pll_audio_inst|altera_pll_i|*[0].*|divclk}] \
   -group [get_clocks { spi_sck}] \
   -group [get_clocks { hdmi_sck}] \
   -group [get_clocks { *|h2f_user0_clk}] \
   -group [get_clocks { FPGA_CLK1_50 }] \
   -group [get_clocks { FPGA_CLK2_50 }] \
   -group [get_clocks { FPGA_CLK3_50 }]

set_false_path -from [get_ports {KEY*}]
set_false_path -from [get_ports {BTN_*}]
set_false_path -to   [get_ports {LED_*}]
set_false_path -to   [get_ports {VGA_*}]
set_false_path -from [get_ports {VGA_EN}]
set_false_path -to   [get_ports {AUDIO_SPDIF}]
set_false_path -to   [get_ports {AUDIO_L}]
set_false_path -to   [get_ports {AUDIO_R}]
set_false_path -from {get_ports {SW[*]}}
set_false_path -to   {cfg[*]}
set_false_path -from {cfg[*]}
set_false_path -from {VSET[*]}
set_false_path -to   {wcalc[*] hcalc[*]}
set_false_path -to   {hdmi_width[*] hdmi_height[*]}
set_false_path -to   {deb_* btn_en btn_up}

set_multicycle_path -to {*_osd|osd_vcnt*} -setup 2
set_multicycle_path -to {*_osd|osd_vcnt*} -hold 1

set_false_path -to   {*_osd|v_cnt*}
set_false_path -to   {*_osd|v_osd_start*}
set_false_path -to   {*_osd|v_info_start*}
set_false_path -to   {*_osd|h_osd_start*}
set_false_path -from {*_osd|v_osd_start*}
set_false_path -from {*_osd|v_info_start*}
set_false_path -from {*_osd|h_osd_start*}
set_false_path -from {*_osd|rot*}
set_false_path -from {*_osd|dsp_width*}
set_false_path -to   {*_osd|half}

set_false_path -to   {WIDTH[*] HFP[*] HS[*] HBP[*] HEIGHT[*] VFP[*] VS[*] VBP[*]}
set_false_path -from {WIDTH[*] HFP[*] HS[*] HBP[*] HEIGHT[*] VFP[*] VS[*] VBP[*]}
set_false_path -to   {FB_BASE[*] FB_BASE[*] FB_WIDTH[*] FB_HEIGHT[*] LFB_HMIN[*] LFB_HMAX[*] LFB_VMIN[*] LFB_VMAX[*]}
set_false_path -from {FB_BASE[*] FB_BASE[*] FB_WIDTH[*] FB_HEIGHT[*] LFB_HMIN[*] LFB_HMAX[*] LFB_VMIN[*] LFB_VMAX[*]}
set_false_path -to   {vol_att[*] scaler_flt[*] led_overtake[*] led_state[*]}
set_false_path -from {vol_att[*] scaler_flt[*] led_overtake[*] led_state[*]}
set_false_path -from {aflt_* acx* acy* areset* arc*}
set_false_path -from {arx* ary*}
set_false_path -from {vs_line*}
set_false_path -from {ColorBurst_Range* PhaseInc* pal_en cvbs yc_en}

set_false_path -from {ascal|o_ihsize*}
set_false_path -from {ascal|o_ivsize*}
set_false_path -from {ascal|o_format*}
set_false_path -from {ascal|o_hdown}
set_false_path -from {ascal|o_vdown}
set_false_path -from {ascal|o_hmin* ascal|o_hmax* ascal|o_vmin* ascal|o_vmax* ascal|o_vrrmax* ascal|o_vrr}
set_false_path -from {ascal|o_hdisp* ascal|o_vdisp*}
set_false_path -from {ascal|o_htotal* ascal|o_vtotal*}
set_false_path -from {ascal|o_hsstart* ascal|o_vsstart* ascal|o_hsend* ascal|o_vsend*}
set_false_path -from {ascal|o_hsize* ascal|o_vsize*}
set_false_path -from {ascal|i_hdown ascal|i_hsize* ascal|i_ohsize*} -to {ascal|i_hburst*}

set_false_path -from {mcp23009|flg_*}
set_false_path -to   {sysmem|fpga_interfaces|clocks_resets|f2h*}

# JTFRAME
set_false_path -to [get_keepers {audio_out:audio_out|cl1[*]}]
set_false_path -to [get_keepers {audio_out:audio_out|cr1[*]}]

# Reset synchronization signal
set_false_path -from [get_keepers {emu:emu|jtframe_mister:u_frame|jtframe_board:u_board|jtframe_reset:u_reset|rst_rom[0]}] -to [get_keepers {emu:emu|jtframe_mister:u_frame|jtframe_board:u_board|jtframe_reset:u_reset|rst_rom_sync}]
set_false_path -to emu:emu|sRESET[0]
set_false_path -to emu:emu|jtframe_mister:u_frame|jtframe_board:u_board|jtframe_reset:u_reset|rst_req_sync[0]
# static signals
set_false_path -from FB_EN
set_false_path -to deb_osd[0]
set_false_path -from emu:emu|jtframe_mister:u_frame|jtframe_board:u_board|jtframe_led:u_led|led

set_false_path  -from  [get_clocks *]  -to  [get_clocks {sysmem|fpga_interfaces|clocks_resets*}]
set_false_path  -from  [get_clocks *]  -to  [get_clocks {sysmem|fpga_interfaces|clocks_resets*}]

set_false_path -from [get_keepers {cfg_ready}] -to [get_keepers {vsd}]
set_false_path -from [get_keepers {cfg_ready}] -to [get_keepers {vsd2}]
set_false_path -from [get_keepers {cfg_ready}] -to [get_keepers {cfg_got}]


# ---------------------------------------------------------------------------
# SFTM: TG68K clock-enable multicycle
#
# The 68020 core advances only when clkena_in is asserted. sftm_main drives
# that from its bus FSM (grant = state==S_GRANT && cen), and the shortest
# route back to a grant is S_GRANT -> S_DECODE -> S_GRANT, so clkena pulses
# are never closer than 2 clocks. Data launched at one enable is therefore
# not captured until the next, at least 2 cycles later.
#
# Verified before relaxing anything (TG68KdotC_Kernel.vhd / TG68K_ALU.vhd):
#   - clkena_lw <= '1' WHEN clkena_in='1' AND memmaskmux(3)='1'  (line 450)
#     i.e. a STRICT SUBSET of clkena_in, so it is never more frequent.
#   - every functional register in the kernel is guarded by clkena_in or
#     clkena_lw: regfile (561), store_in_tmp (750), exec (1264), and the
#     state/PC block (1081/1095).
#   - all five clocked processes in TG68K_ALU are clkena_lw guarded.
#   - the clocked assignments that sit outside those guards are reset
#     branches (1053, 4010) and use_VBR_Stackframe (464), which is a static
#     config bit derived from generics -- not data paths.
#
# Deliberately restricted to kernel-internal paths. Signals entering the CPU
# from sftm_main must NOT be relaxed: data_in is driven by the RAM/ROM output
# registers, which update every clock, so those paths still require full
# single-cycle timing.
#
# Without this, the design sits a few hundred ps negative on
# store_in_tmp/exec -> regfile and every build is a placement gamble.
# ---------------------------------------------------------------------------
set_multicycle_path -setup 2 \
    -from [get_registers {*TG68KdotC_Kernel*}] \
    -to   [get_registers {*TG68KdotC_Kernel*}]
set_multicycle_path -hold 1 \
    -from [get_registers {*TG68KdotC_Kernel*}] \
    -to   [get_registers {*TG68KdotC_Kernel*}]
