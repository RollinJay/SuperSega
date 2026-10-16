// Simulation top: the Pocket platform layer and machine with a PSRAM model on
// cram0. The C++ harness drives the clocks, the APF bridge and the controllers.
`timescale 1ns/1ps
module tb_pocket_top (
    input  wire        clk_74a,
    input  wire        clk_sys,
    input  wire        clk_vid,
    input  wire        pll_locked,
    input  wire        apf_reset_n,
    input  wire [31:0] bridge_addr,
    input  wire        bridge_rd,
    input  wire        bridge_wr,
    input  wire [31:0] bridge_wr_data,
    output wire [31:0] save_rd_data,
    input  wire        dataslot_requestwrite,
    input  wire [15:0] dataslot_requestwrite_id,
    input  wire [31:0] dataslot_requestwrite_size,
    input  wire        dataslot_allcomplete,
    output wire        save_present,
    input  wire [31:0] cont1_key,
    input  wire [31:0] cont2_key,
    input  wire [31:0] cont3_key,
    input  wire [31:0] cont3_joy,
    input  wire [15:0] cont3_trig,
    output wire [23:0] video_rgb,
    output wire        video_de,
    output wire        video_hs,
    output wire        video_vs,
    output wire        video_skip,
    output wire signed [15:0] audio_l,
    output wire signed [15:0] audio_r
);
    wire [21:16] a;
    wire [15:0]  dq;
    wire         wt, pclk, adv_n, cre, ce0_n, ce1_n, oe_n, we_n, ub_n, lb_n;

    mdr_pocket u_pocket (
        .clk_74a(clk_74a), .clk_sys(clk_sys), .clk_vid(clk_vid),
        .pll_locked(pll_locked), .apf_reset_n(apf_reset_n),
        .bridge_endian_little(1'b0), .bridge_addr(bridge_addr), .bridge_rd(bridge_rd),
        .bridge_wr(bridge_wr), .bridge_wr_data(bridge_wr_data), .save_rd_data(save_rd_data),
        .dataslot_requestwrite(dataslot_requestwrite), .dataslot_requestwrite_id(dataslot_requestwrite_id),
        .dataslot_requestwrite_size(dataslot_requestwrite_size), .dataslot_allcomplete(dataslot_allcomplete),
        .save_present(save_present),
        .cont1_key(cont1_key), .cont2_key(cont2_key), .cont3_key(cont3_key),
        .cont3_joy(cont3_joy), .cont3_trig(cont3_trig),
        .cram0_a(a), .cram0_dq(dq), .cram0_wait(wt), .cram0_clk(pclk), .cram0_adv_n(adv_n),
        .cram0_cre(cre), .cram0_ce0_n(ce0_n), .cram0_ce1_n(ce1_n), .cram0_oe_n(oe_n),
        .cram0_we_n(we_n), .cram0_ub_n(ub_n), .cram0_lb_n(lb_n),
        .video_rgb(video_rgb), .video_de(video_de), .video_hs(video_hs), .video_vs(video_vs),
        .video_skip(video_skip), .audio_l(audio_l), .audio_r(audio_r));

    psram_model #(.AW(20)) u_psram (
        .a(a), .dq(dq), .wait_o(wt), .clk(pclk), .adv_n(adv_n), .cre(cre),
        .ce0_n(ce0_n), .ce1_n(ce1_n), .oe_n(oe_n), .we_n(we_n), .ub_n(ub_n), .lb_n(lb_n));
endmodule
