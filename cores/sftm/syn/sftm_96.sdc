# SFTM 96 MHz campaign timing constraints (build 116+).
#
# 1. SDRAM_CLK pin model: the pin is driven from the pll clk96sh tap; the
#    STA model is the 96 MHz core clock shifted 180 degrees, exactly as
#    jtframe's own sdram_clk96.sdc declares for its SDRAM96 cores. Without
#    this the SDRAM I/O is unconstrained -- the family of hazard behind the
#    48 MHz one-halfword slip saga.
create_generated_clock -name SDRAM_CLK -source \
    [get_pins {emu|pll|pll_inst|altera_pll_i|general[4].gpll~PLL_OUTPUT_COUNTER|divclk}] \
    -divide_by 1 -phase 180 \
    [get_ports SDRAM_CLK]

set_multicycle_path -setup -end 2 -from [get_clocks {SDRAM_CLK}] \
    -to [get_clocks {emu|pll|pll_inst|altera_pll_i|general[4].gpll~PLL_OUTPUT_COUNTER|divclk}]
set_multicycle_path -hold -end 2 -from [get_clocks {SDRAM_CLK}] \
    -to [get_clocks {emu|pll|pll_inst|altera_pll_i|general[4].gpll~PLL_OUTPUT_COUNTER|divclk}]

# 2. The 96 -> 48 lane-port crossing: lane dout/ok are registered in the 96
#    domain and held stable until the 48-domain requester deasserts (the ok
#    stretcher guarantees it), so the transfer has a full 48 MHz period.
#    Same-PLL aligned clocks; relax setup and hold to the 2-cycle window.
set_multicycle_path -setup -end 2 \
    -from [get_clocks {emu|pll|pll_inst|altera_pll_i|general[4].gpll~PLL_OUTPUT_COUNTER|divclk}] \
    -to   [get_clocks {emu|pll|pll_inst|altera_pll_i|general[0].gpll~PLL_OUTPUT_COUNTER|divclk}]
set_multicycle_path -hold -end 2 \
    -from [get_clocks {emu|pll|pll_inst|altera_pll_i|general[4].gpll~PLL_OUTPUT_COUNTER|divclk}] \
    -to   [get_clocks {emu|pll|pll_inst|altera_pll_i|general[0].gpll~PLL_OUTPUT_COUNTER|divclk}]
