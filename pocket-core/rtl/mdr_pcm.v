// MasterDrive - PCM FIFO and the two wavetable voices (Technical Reference §7)
//
// PCM: each byte written to $07 is one unsigned 8-bit sample (128 = silence),
// queued in a 64-byte FIFO; a byte written while 64 are queued is dropped. $08
// bits 1-0 set the rate: 8,000, 11,025, 16,000 or 22,050 samples a second. The
// output is mono, on both sides, and holds the last sample while the FIFO is
// empty; reset returns it to silence.
//
// Wavetable: two voices of 32 four-bit samples (8 = the centre). $11 bit 5
// selects the voice the other ports address and bits 4-0 the position $12
// writes; $13/$14 bits 3-0 the 12-bit frequency f, $14 bit 7 key on; $15
// bits 3-0 the volume (linear) and bits 5-4 the sides (5 left, 4 right). A
// voice plays while keyed on with f > 0, stepping through its waveform
// f x 102.4 times a second (its 32 samples f x 3.2 times a second).
//
// The rates and the wavetable's pitch are the emulator's, in real time: they
// count clk_sys, which is never held (also in PAL). They are not made from the
// machine clock, and their levels are the emulator's (open question Q27):
// PCM at full scale peaks at 0.2 of the output's full scale, a wavetable voice
// at full volume at 0.12, against 0.16 for a PSG channel at full volume. In the
// units of mdr_psg (8191 for a PSG channel at full volume): PCM (s - 128) x 80,
// a voice (sample - 8) x volume x 51.
`default_nettype none

module mdr_pcm #(
    parameter CLK_HZ = 53693175
) (
    input  wire        clk,
    input  wire        rst,
    input  wire        pcm_wr,          // $07 written (MasterDrive mode, I/O gate open)
    input  wire [7:0]  din,
    input  wire [1:0]  rate,            // $08 bits 1-0
    output wire [6:0]  fill,            // bytes queued, 0-64
    input  wire        wt_wr,           // $11-$15 written
    input  wire [2:0]  wt_reg,          // which: 0 = $11 ... 4 = $15
    output reg  signed [15:0] out_l,
    output reg  signed [15:0] out_r
);
    // ------------------------------------------------------------ PCM
    reg  [7:0]  fifo [0:63];
    reg  [5:0]  rp, wp;
    reg  [6:0]  cnt;
    reg  [7:0]  last;
    reg  [25:0] racc;
    wire [14:0] hz = (rate == 2'd0) ? 15'd8000 : (rate == 2'd1) ? 15'd11025 :
                     (rate == 2'd2) ? 15'd16000 : 15'd22050;
    wire [26:0] racc_next = {1'b0, racc} + {12'd0, hz};
    wire        tick = (racc_next >= CLK_HZ);
    assign fill = cnt;

    always @(posedge clk) begin
        if (rst) begin
            rp <= 6'd0; wp <= 6'd0; cnt <= 7'd0; last <= 8'd128; racc <= 26'd0;
        end else begin
            racc <= tick ? racc_next[25:0] - CLK_HZ[25:0] : racc_next[25:0];
            // a sample leaves on the rate tick; a written byte joins the queue
            if (tick && cnt != 7'd0) begin
                last <= fifo[rp];
                rp <= rp + 6'd1;
            end
            if (pcm_wr && cnt != 7'd64) begin
                fifo[wp] <= din;
                wp <= wp + 6'd1;
            end
            cnt <= cnt - {6'd0, tick && cnt != 7'd0} + {6'd0, pcm_wr && cnt != 7'd64};
        end
    end

    // ------------------------------------------------------------ wavetable
    reg  [3:0]  wram [0:63];            // {voice, position}
    reg         wsel;
    reg  [4:0]  widx;
    reg  [11:0] wf    [0:1];
    reg         wen   [0:1];
    reg  [3:0]  wvol  [0:1];
    reg  [1:0]  wpan  [0:1];
    reg  [29:0] wacc  [0:1];
    reg  [4:0]  wpos  [0:1];
    localparam [29:0] W_STEP = CLK_HZ * 10;        // f x 1024 per clock against 10 x CLK_HZ: f x 102.4 steps a second
    integer v;
    always @(posedge clk) begin
        if (rst) begin
            wsel <= 1'b0; widx <= 5'd0;
            for (v = 0; v < 2; v = v + 1) begin
                wf[v] <= 12'd0; wen[v] <= 1'b0; wvol[v] <= 4'd0; wpan[v] <= 2'd3;
                wacc[v] <= 30'd0; wpos[v] <= 5'd0;
            end
        end else begin
            if (wt_wr) begin
                case (wt_reg)
                3'd0: begin wsel <= din[5]; widx <= din[4:0]; end
                3'd1: wram[{wsel, widx}] <= din[3:0];
                3'd2: wf[wsel] <= {wf[wsel][11:8], din};
                3'd3: begin wf[wsel] <= {din[3:0], wf[wsel][7:0]}; wen[wsel] <= din[7]; end
                3'd4: begin wvol[wsel] <= din[3:0]; wpan[wsel] <= din[5:4]; end
                default: ;
                endcase
            end
            // a voice's position moves only while it plays (keyed on, f > 0)
            for (v = 0; v < 2; v = v + 1) if (wen[v] && wf[v] != 12'd0) begin
                if (wacc[v] + {8'd0, wf[v], 10'd0} >= W_STEP) begin
                    wacc[v] <= wacc[v] + {8'd0, wf[v], 10'd0} - W_STEP;
                    wpos[v] <= wpos[v] + 5'd1;
                end else wacc[v] <= wacc[v] + {8'd0, wf[v], 10'd0};
            end
        end
    end

    // ------------------------------------------------------------ output
    wire signed [15:0] pcm_s = ($signed({8'd0, last}) - 16'sd128) * 16'sd80;
    function signed [15:0] voice;
        input [3:0]  smp;
        input [3:0]  vol;
        input        on;
        begin
            voice = on ? ($signed({12'd0, smp}) - 16'sd8) * $signed({12'd0, vol}) * 16'sd51 : 16'sd0;
        end
    endfunction
    wire signed [15:0] v0 = voice(wram[{1'b0, wpos[0]}], wvol[0], wen[0] && wf[0] != 12'd0);
    wire signed [15:0] v1 = voice(wram[{1'b1, wpos[1]}], wvol[1], wen[1] && wf[1] != 12'd0);
    always @(posedge clk) begin
        out_l <= pcm_s + (wpan[0][1] ? v0 : 16'sd0) + (wpan[1][1] ? v1 : 16'sd0);
        out_r <= pcm_s + (wpan[0][0] ? v0 : 16'sd0) + (wpan[1][0] ? v1 : 16'sd0);
    end
endmodule

`default_nettype wire
