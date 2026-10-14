// Super Sega - I/O unit test (iverilog).
//
// Two calculations in rtl/ss_io.v take several clocks so that the core meets
// timing (docs/SuperSega_Pocket_Core_Design.md §11). This test checks each
// against a reference model through the real port writes and reads:
//
//   keyboard  SC-3000 mode: random keys and pads, a row selected through the
//             8255 (OUT $DF mode word, OUT $DE row), ports $DC/$DD read 16
//             clocks later, with and without ghosting. The reference is the
//             closure as one combinational loop, the core's earlier form.
//   math unit Super Sega mode: OUT $0C (A), $0D (B), $0E (operation), then
//             $0F/$10 read 16 clocks later. Divide: {A, B} / B, 0 when B = 0;
//             multiply: A x B.
//
// The CPU cannot read sooner than 16 clocks after the OUT: its next IN comes at
// least 11 T-states (82 system clocks at 200 % turbo) later.
`timescale 1ns/1ps
`default_nettype none

module tb;
    reg clk = 1'b0;
    always #5 clk = ~clk;

    reg        rst = 1'b1;
    reg  [2:0] mode = 3'd3;
    reg        io_sample = 1'b0, io_write = 1'b0;
    reg  [7:0] port = 8'h00, wdata = 8'h00;
    reg  [83:0] keys = 84'd0;
    reg  [7:0] p1 = 8'h00, p2 = 8'h00;
    reg        ghost = 1'b0;
    wire [7:0] rdata;

    ss_io u_io (.clk(clk), .rst(rst), .mode(mode), .jp_region(1'b0), .fm_present(1'b0),
        .io_sample(io_sample), .io_write(io_write), .port(port), .wdata(wdata), .rdata(rdata),
        .vdp_rdata(8'h00), .vdp_rd(), .vdp_wr(), .vdp_fea(8'h00), .vdp_fec(8'h00), .th_latch(),
        .psg_wr(), .stereo_wr(), .fm_wr(), .fm_addr(), .fm_ctl(), .mem_ctl(), .io_ctl(),
        .wram_bank(), .slot_sel(), .card_bank(), .turbo_step(), .pcm_ctl(), .pcm_wr(),
        .pcm_fill(7'd0), .pad1(p1), .pad2(p2), .reset_btn(1'b0), .kb_keys(keys),
        .kb_ghosting(ghost));

    task out(input [7:0] p, input [7:0] d);
        begin
            @(negedge clk); port = p; wdata = d; io_write = 1'b1; io_sample = 1'b1;
            @(negedge clk); io_sample = 1'b0; io_write = 1'b0;
        end
    endtask

    task in(input [7:0] p, output [7:0] d);
        begin
            port = p; #1 d = rdata;
        end
    endtask

    // keyboard reference: every row reachable from the selected one through
    // shared columns (the diode-less matrix), as one combinational loop
    function [11:0] kb_ref(input [2:0] row, input g);
        reg [11:0] rm [0:7];
        reg [11:0] m;
        reg [7:0]  reach;
        integer r, it;
        begin
            for (r = 0; r < 7; r = r + 1) rm[r] = keys[r*12 +: 12];
            rm[7] = {p2[5], p2[4], p2[3], p2[2], p2[1], p2[0], p1[5], p1[4], p1[3], p1[2], p1[1], p1[0]};
            m = rm[row];
            if (g) begin
                reach = 8'd0; reach[row] = 1'b1;
                for (it = 0; it < 7; it = it + 1)
                    for (r = 0; r < 8; r = r + 1)
                        if (!reach[r] && (rm[r] & m) != 12'd0) begin
                            reach[r] = 1'b1;
                            m = m | rm[r];
                        end
            end
            kb_ref = m;
        end
    endfunction

    integer n, k, bad_kb, bad_math, ghosted, a, b, op;
    reg [2:0]  row;
    reg [7:0]  lo, hi;
    reg [11:0] want_kb;
    reg [15:0] got, want;
    initial begin
        bad_kb = 0; bad_math = 0; ghosted = 0;
        repeat (3) @(negedge clk);
        rst = 1'b0;

        // ---- keyboard, SC-3000 mode
        mode = 3'd3;
        out(8'hDF, 8'h92);                     // 8255 mode word: port C lower is an output
        for (n = 0; n < 4000; n = n + 1) begin
            keys = 84'd0;
            for (k = 0; k < 1 + ($urandom % 8); k = k + 1) keys[$urandom % 84] = 1'b1;
            if (n % 3 == 0) begin p1 = $urandom; p2 = $urandom; end
            else begin p1 = 8'h00; p2 = 8'h00; end
            ghost = (n % 4) != 0;
            row = $urandom % 8;
            out(8'hDE, {5'd0, row});
            repeat (16) @(negedge clk);
            in(8'hDC, lo); in(8'hDD, hi);
            want_kb = kb_ref(row, ghost);
            if (want_kb != kb_ref(row, 1'b0)) ghosted = ghosted + 1;
            if (lo !== ~want_kb[7:0] || hi[3:0] !== ~want_kb[11:8]) begin
                bad_kb = bad_kb + 1;
                if (bad_kb <= 5) $display("keyboard: row %0d ghosting %0d read %h %h, expected %h", row, ghost, hi, lo, want_kb);
            end
        end
        $display("keyboard: %0d cases (%0d where ghosting adds keys), %0d wrong", n, ghosted, bad_kb);

        // ---- math unit, Super Sega mode
        mode = 3'd5;
        for (n = 0; n < 20000; n = n + 1) begin
            a = (n < 256) ? n : $urandom % 256;
            b = (n < 256) ? (n * 7) % 256 : $urandom % 256;
            if (n % 37 == 0) b = 0;
            op = (n % 5 == 0) ? 0 : 1;
            out(8'h0C, a); out(8'h0D, b); out(8'h0E, op);
            repeat (16) @(negedge clk);
            in(8'h0F, got[7:0]); in(8'h10, got[15:8]);
            want = op ? ((b != 0) ? ({a[7:0], b[7:0]} / b[7:0]) : 16'd0) : a[7:0] * b[7:0];
            if (got !== want) begin
                bad_math = bad_math + 1;
                if (bad_math <= 5) $display("math: A %0d B %0d op %0d read %h, expected %h", a, b, op, got, want);
            end
        end
        $display("math unit: %0d cases, %0d wrong", n, bad_math);

        if (bad_kb == 0 && bad_math == 0) $display("PASS");
        else $display("FAIL");
        $finish;
    end
endmodule

`default_nettype wire
