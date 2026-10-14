#
# Super Sega - timing constraints (core side; the APF supplies its own)
#
# The machine clock (53.693175 MHz) and the two video clocks (5.369318 MHz,
# 0 and 90 degrees) come from one PLL VCO and are kept in ONE group: the video
# stage samples the machine's video registers directly, and those paths must be
# timed, not cut. Every clk_sys -> clk_vid path has at least one clk_sys period.
# The 74.25 MHz inputs and the bridge SPI clock are unrelated to the PLL; the
# crossings to and from them go through synchronisers and dual-clock FIFOs.
#
set_clock_groups -asynchronous \
 -group { bridge_spiclk } \
 -group { clk_74a } \
 -group { clk_74b } \
 -group { ic|mp1|altera_pll_i|general[0].gpll~PLL_OUTPUT_COUNTER|divclk \
          ic|mp1|altera_pll_i|general[1].gpll~PLL_OUTPUT_COUNTER|divclk \
          ic|mp1|altera_pll_i|general[2].gpll~PLL_OUTPUT_COUNTER|divclk }

derive_clock_uncertainty

# The CPU runs on a clock enable (ce_cpu in rtl/ss_top.v): at most once every
# 7 system clocks (200 % turbo), and never on two consecutive clocks. Every
# register in the CPU core (tv80) changes only on an enable edge. The CPU
# wrapper's bus strobes and data latch, the I/O decode, the VDP and the PSG take
# what the CPU drives only on an enable edge too (the I/O sample point), so
# paths from the CPU core to them have two clocks. The memory controller acts
# between enable edges and keeps the one-clock requirement (ss_top registers
# the CPU bus for it).
set ss_cpu [get_registers {*|ss_z80:u_cpu|tv80_core:u_core|*}]
set ss_cpu_side [get_registers {*|ss_z80:u_cpu|tv80_core:u_core|* *|ss_z80:u_cpu|rd_n* *|ss_z80:u_cpu|wr_n* *|ss_z80:u_cpu|iorq_n* *|ss_z80:u_cpu|mreq_n* *|ss_z80:u_cpu|di_reg* *|ss_top:u_machine|ss_io:u_io|* *|ss_top:u_machine|ss_vdp:u_vdp|* *|ss_top:u_machine|ss_psg:u_psg|*}]
set_multicycle_path -setup -end 2 -from $ss_cpu -to $ss_cpu_side
set_multicycle_path -hold  -end 1 -from $ss_cpu -to $ss_cpu_side
