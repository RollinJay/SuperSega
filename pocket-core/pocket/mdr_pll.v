// MasterDrive - clock generation for the Analogue Pocket (Cyclone V altera_pll)
//
//   outclk_0  53.693175 MHz  machine clock: 15 x 3.579545 MHz (CPU base),
//                            10 x 5.369318 MHz (pixel)
//   outclk_1   5.369318 MHz  video clock to the APF scaler
//   outclk_2   5.369318 MHz  same, +90 degrees (46557 ps), for the scaler's DDR capture
//
// All three come from one VCO, so they are phase-related: the machine's video
// registers (clk_sys) are sampled directly in the video domain, and the timing
// constraints treat the three as one clock group (core_constraints.sdc).
//
// Written by hand rather than generated: Quartus picks the M/N/C counters
// (fractional VCO) at compile time and reports the frequencies it achieved.
// Check the fitter report that outclk_0 is within a few ppm of 53.693175 MHz.
`timescale 1 ps / 1 ps
module mdr_pll (
    input  wire refclk,      // 74.25 MHz
    input  wire rst,
    output wire outclk_0,
    output wire outclk_1,
    output wire outclk_2,
    output wire locked
);
    altera_pll #(
        .fractional_vco_multiplier("true"),
        .reference_clock_frequency("74.25 MHz"),
        .operation_mode("normal"),
        .number_of_clocks(3),
        .output_clock_frequency0("53.693175 MHz"),
        .phase_shift0("0 ps"),
        .duty_cycle0(50),
        .output_clock_frequency1("5.369318 MHz"),
        .phase_shift1("0 ps"),
        .duty_cycle1(50),
        .output_clock_frequency2("5.369318 MHz"),
        .phase_shift2("46557 ps"),
        .duty_cycle2(50),
        .output_clock_frequency3("0 MHz"),  .phase_shift3("0 ps"),  .duty_cycle3(50),
        .output_clock_frequency4("0 MHz"),  .phase_shift4("0 ps"),  .duty_cycle4(50),
        .output_clock_frequency5("0 MHz"),  .phase_shift5("0 ps"),  .duty_cycle5(50),
        .output_clock_frequency6("0 MHz"),  .phase_shift6("0 ps"),  .duty_cycle6(50),
        .output_clock_frequency7("0 MHz"),  .phase_shift7("0 ps"),  .duty_cycle7(50),
        .output_clock_frequency8("0 MHz"),  .phase_shift8("0 ps"),  .duty_cycle8(50),
        .output_clock_frequency9("0 MHz"),  .phase_shift9("0 ps"),  .duty_cycle9(50),
        .output_clock_frequency10("0 MHz"), .phase_shift10("0 ps"), .duty_cycle10(50),
        .output_clock_frequency11("0 MHz"), .phase_shift11("0 ps"), .duty_cycle11(50),
        .output_clock_frequency12("0 MHz"), .phase_shift12("0 ps"), .duty_cycle12(50),
        .output_clock_frequency13("0 MHz"), .phase_shift13("0 ps"), .duty_cycle13(50),
        .output_clock_frequency14("0 MHz"), .phase_shift14("0 ps"), .duty_cycle14(50),
        .output_clock_frequency15("0 MHz"), .phase_shift15("0 ps"), .duty_cycle15(50),
        .output_clock_frequency16("0 MHz"), .phase_shift16("0 ps"), .duty_cycle16(50),
        .output_clock_frequency17("0 MHz"), .phase_shift17("0 ps"), .duty_cycle17(50),
        .pll_type("General"),
        .pll_subtype("General")
    ) altera_pll_i (
        .rst      (rst),
        .outclk   ({outclk_2, outclk_1, outclk_0}),
        .locked   (locked),
        .fboutclk (),
        .fbclk    (1'b0),
        .refclk   (refclk)
    );
endmodule
