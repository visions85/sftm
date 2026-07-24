`ifdef JTFRAME_SRAM
    output    [16:0]  sram_addr,
    output    [15:0]  sram_din,
    input     [15:0]  sram_dout,
    output            sram_wen,
    output    [ 1:0]  sram_dsn,
    input             sram_ok,
`endif
    input e020_cen, // 25000000 = 48000000*25/48 Hz 
    input es_cen, // 16000000 = 48000000*1/3 Hz 
    input snd_cen, // 2000000 = 48000000*1/24 Hz 

    // Audio channels
    
    // Sound output
`ifndef JTFRAME_STEREO
    output  signed [15:0] snd,
`else
    output  signed [15:0] snd_left, snd_right,
`endif
    output          sample,

    // Memory ports
`ifdef JTFRAME_SDRAM_XL
    input   [23:0]  prog_addr,
`elsif JTFRAME_SDRAM_LARGE
    input   [22:0]  prog_addr,
`else
    input   [21:0]  prog_addr,
`endif
    input   [ 7:0]  prog_data,
    input           prog_we,
    input   [ 1:0]  prog_ba,
`ifdef JTFRAME_SDRAM_XL
    input   [26:0]  ioctl_addr,
`else
    input   [25:0]  ioctl_addr,
`endif
    input           prom_we,
`ifdef JTFRAME_HEADER
    input           header,
`endif
`ifdef JTFRAME_IOCTL_RD
    input           ioctl_wr,
    output   [ 7:0] ioctl_din,
    input    [ 7:0] ioctl_dout, `endif
    input           ioctl_ram,
    input           ioctl_cart,
    // Explicit ports
    // Buses to BRAM

    // Buses to SDRAM
    input    [31:0] main_data,
    output          main_cs,
    output   [17:2] main_addr,
    input           main_ok,

    input    [ 7:0] snd_data,
    output          snd_cs,
    output   [17:0] snd_addr,
    input           snd_ok,

    input    [15:0] srom_data,
    output          srom_cs,
    output   [20:1] srom_addr,
    input           srom_ok,

    input    [15:0] grom_data,
    output          grom_cs,
    output   [23:1] grom_addr,
    input           grom_ok,

    input    [15:0] grm3_data,
    output          grm3_cs,
    output   [17:1] grm3_addr,
    input           grm3_ok
