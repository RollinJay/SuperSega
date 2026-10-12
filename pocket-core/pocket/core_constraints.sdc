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
