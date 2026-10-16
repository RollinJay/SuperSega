// MasterDrive - SN76489 PSG (Sega variant) with Game Gear stereo panning.
//
// Three square-wave tone channels and one noise channel, clocked at the base
// CPU clock / 16. Behaviour follows the Sega part as BlastEm and SMS Power
// document it:
//   - 10-bit tone counters; a counter at 0 reloads and toggles its output, so a
//     tone value of 0 or 1 gives the highest frequency
//   - noise rate $10/$20/$40 or tone 2's value; the 16-bit LFSR shifts once per
//     full period of the noise square wave (on its rising edge)
//   - white noise taps bits 0 and 3; any write to the noise register resets the
//     LFSR to $8000
//   - 2 dB attenuation steps; 15 = off
// Port $06 (Game Gear, MasterDrive) gates each channel to left and right:
// bits 7-4 left (noise, 2, 1, 0), bits 3-0 right.
`default_nettype none

module mdr_psg (
    input  wire        clk,
    input  wire        rst,
    input  wire        ce_psg,        // base CPU clock / 16
    input  wire        wr,            // write strobe
    input  wire [7:0]  din,
    input  wire        stereo_wr,
    input  wire [7:0]  stereo_din,
    input  wire        pstereo,       // enhancement layer: pseudo-stereo while $06 is unused
    output reg  signed [15:0] out_l,
    output reg  signed [15:0] out_r
);
    reg [9:0]  tone [0:2];
    reg [3:0]  vol  [0:3];
    reg [2:0]  noise_ctl;
    reg [1:0]  latch_ch;
    reg        latch_vol;
    reg [9:0]  cnt  [0:3];
    reg [3:0]  outp;                  // square outputs (noise square in [3])
    reg [15:0] lfsr;
    reg [7:0]  stereo;
    reg        stereo_set;            // software has written $06 since reset
    // Pseudo-stereo panning: tone 0 left, tone 1 right, tone 2 and noise centre.
    // Applies only until software writes $06 (explicit intent wins).
    wire [7:0] pan = (pstereo && !stereo_set) ? 8'hDE : stereo;

    // 2 dB steps, full scale 8191 per channel so four channels fit 15 bits
    function [12:0] amp;
        input [3:0] a;
        case (a)
            4'd0:  amp = 13'd8191; 4'd1:  amp = 13'd6506; 4'd2:  amp = 13'd5168;
            4'd3:  amp = 13'd4105; 4'd4:  amp = 13'd3261; 4'd5:  amp = 13'd2590;
            4'd6:  amp = 13'd2057; 4'd7:  amp = 13'd1634; 4'd8:  amp = 13'd1298;
            4'd9:  amp = 13'd1031; 4'd10: amp = 13'd819;  4'd11: amp = 13'd651;
            4'd12: amp = 13'd517;  4'd13: amp = 13'd410;  4'd14: amp = 13'd326;
            default: amp = 13'd0;
        endcase
    endfunction

    wire [9:0] noise_reload = (noise_ctl[1:0] == 2'd0) ? 10'h010 :
                              (noise_ctl[1:0] == 2'd1) ? 10'h020 :
                              (noise_ctl[1:0] == 2'd2) ? 10'h040 : tone[2];

    integer i;
    always @(posedge clk) begin
        if (rst) begin
            for (i = 0; i < 3; i = i + 1) tone[i] <= 10'd0;
            for (i = 0; i < 4; i = i + 1) begin vol[i] <= 4'hF; cnt[i] <= 10'd0; end
            noise_ctl <= 3'd0; latch_ch <= 2'd0; latch_vol <= 1'b0;
            outp <= 4'b0000; lfsr <= 16'h8000; stereo <= 8'hFF; stereo_set <= 1'b0;
        end else begin
            if (stereo_wr) begin stereo <= stereo_din; stereo_set <= 1'b1; end
            if (wr) begin
                if (din[7]) begin
                    latch_ch  <= din[6:5];
                    latch_vol <= din[4];
                    if (din[4]) vol[din[6:5]] <= din[3:0];
                    else if (din[6:5] == 2'd3) begin noise_ctl <= din[2:0]; lfsr <= 16'h8000; end
                    else tone[din[6:5]][3:0] <= din[3:0];
                end else begin
                    if (latch_vol) vol[latch_ch] <= din[3:0];
                    else if (latch_ch == 2'd3) begin noise_ctl <= din[2:0]; lfsr <= 16'h8000; end
                    else tone[latch_ch][9:4] <= din[5:0];
                end
            end
            if (ce_psg) begin
                for (i = 0; i < 3; i = i + 1) begin
                    if (cnt[i] <= 10'd1) begin
                        cnt[i] <= tone[i];
                        outp[i] <= ~outp[i];
                    end else cnt[i] <= cnt[i] - 10'd1;
                end
                if (cnt[3] <= 10'd1) begin
                    cnt[3] <= noise_reload;
                    outp[3] <= ~outp[3];
                    if (!outp[3])     // rising edge of the noise square: shift
                        lfsr <= {noise_ctl[2] ? (lfsr[0] ^ lfsr[3]) : lfsr[0], lfsr[15:1]};
                end else cnt[3] <= cnt[3] - 10'd1;
            end
        end
    end

    // mix: each channel contributes +amp or -amp (noise: LFSR bit 0)
    wire [3:0] level = {lfsr[0], outp[2:0]};
    reg signed [15:0] l, rr;
    reg signed [15:0] v;
    integer c;
    always @* begin
        l = 16'sd0; rr = 16'sd0;
        for (c = 0; c < 4; c = c + 1) begin
            v = level[c] ? $signed({3'b000, amp(vol[c])}) : -$signed({3'b000, amp(vol[c])});
            if (pan[4 + c]) l  = l  + v;
            if (pan[c])     rr = rr + v;
        end
    end
    always @(posedge clk) begin
        out_l <= l;
        out_r <= rr;
    end
endmodule

`default_nettype wire
