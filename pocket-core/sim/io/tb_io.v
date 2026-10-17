// MasterDrive - I/O unit test (iverilog).
//
// Two calculations in rtl/mdr_io.v take several clocks so that the core meets
// timing (docs/MasterDrive_Pocket_Core_Design.md §11). This test checks each
// against a reference model through the real port writes and reads:
//
//   keyboard  SC-3000 mode: random keys and pads, a row selected through the
//             8255 (OUT $DF mode word, OUT $DE row), ports $DC/$DD read 16
//             clocks later, with and without ghosting. The reference is the
//             closure as one combinational loop, the core's earlier form.
//   math unit MasterDrive mode: OUT $0C (A), $0D (B), $0E (operation), then
//             $0F/$10 read 16 clocks later. Divide: A / B, the quotient in $0F
//             and the remainder in $10, $FF/$00 when B = 0 (Q7); multiply: A x B.
//   registers MasterDrive mode: $0A reads the work RAM bank (Q9), $08 the
//             PCM FIFO fill / 8, saturating at 7 (Q14).
//   I/O gate  MasterDrive mode: $01-$17 are the $3E/$3F mirrors and read $FF
//             until Feature Enable A bit 7 is set (Q1), then the registers,
//             $17 reading the machine ID $A7 (Q8); Game Gear and Master System
//             modes are unaffected by the bit.
//   BIOS      the BIOS's ports (Technical Reference section 20): a cold reset
//             gives $3E = $E0 and a launch $A8; $18/$19 answer only while the
//             BIOS is mapped ($3E bit 3 clear, bit 6 set); the platform's
//             information reads back; index 0 starts as the platform's
//             choice if the platform runs it, and refuses a machine it does not run, index 4 a turbo step
//             above 4; a BIOS write changes only the next launch's boost, a
//             platform change both; $A5 at $1F asks for the launch, and the
//             launch makes the next values current; the first cold reset takes
//             the platform's boosts, a later one keeps those in effect (and
//             drops a BIOS change not yet launched); a platform change wins over
//             a BIOS write in the same clock and over the launch's.
//
// The CPU cannot read sooner than 16 clocks after the OUT: its next IN comes at
// least 11 T-states (82 system clocks at 200 % turbo) later.
`timescale 1ns/1ps
`default_nettype none

module tb;
    reg clk = 1'b0;
    always #5 clk = ~clk;

    reg        rst = 1'b1;
    reg        cold = 1'b1;                // the first reset is a cold one
    reg  [2:0] mode = 3'd3;
    reg  [10:0] pb = 11'b101_0001_0001;  // the platform's boosts: at the first cold reset sprite limit,
                                         // turbo step 2, pseudo-stereo and true TMS colours
    reg  [8:0]  pc = 9'd0;               // the platform changed index 1-9
    reg         p_auto = 1'b1;
    reg  [2:0]  p_mode = 3'd1;           // the platform's machine choice when p_auto is clear
    wire [10:0] boost;
    wire [2:0]  boot_mode;
    wire        launch_req;
    reg         saw_launch = 1'b0;
    always @(posedge clk) if (launch_req) saw_launch <= 1'b1;
    reg        io_sample = 1'b0, io_write = 1'b0;
    reg  [7:0] port = 8'h00, wdata = 8'h00;
    reg  [83:0] keys = 84'd0;
    reg  [7:0] p1 = 8'h00, p2 = 8'h00;
    reg        ghost = 1'b0;
    reg  [7:0] fea = 8'h00;
    reg  [6:0] fill = 7'd0;
    wire [7:0] rdata, mem_ctl, io_ctl;
    wire [3:0] wram_bank;
    wire       stereo_wr;

    mdr_io u_io (.clk(clk), .rst(rst), .mode(mode), .jp_region(1'b0), .fm_present(1'b0),
        .io_sample(io_sample), .io_write(io_write), .port(port), .wdata(wdata), .rdata(rdata),
        .vdp_rdata(8'h00), .vdp_rd(), .vdp_wr(), .vdp_fea(fea), .vdp_fec(8'h00), .th_latch(),
        .psg_wr(), .stereo_wr(stereo_wr), .fm_wr(), .fm_addr(), .fm_ctl(), .mem_ctl(mem_ctl), .io_ctl(io_ctl),
        .wram_bank(wram_bank), .slot_sel(), .card_bank(), .turbo_step(), .pcm_ctl(), .pcm_wr(),
        .pcm_fill(fill), .pad1(p1), .pad2(p2), .reset_btn(1'b0), .kb_keys(keys),
        .kb_ghosting(ghost), .cold(cold),
        .plat_mode(p_mode), .plat_auto(p_auto), .plat_flags(8'h11), .rom_log2(5'd15), .mapper(2'd0),
        .machines(6'b101111), .plat_boost(pb), .plat_chg(pc), .boost(boost), .boot_mode(boot_mode),
        .launch_req(launch_req));

    task out(input [7:0] p, input [7:0] d);
        begin
            @(negedge clk); port = p; wdata = d; io_write = 1'b1; io_sample = 1'b1;
            @(negedge clk); io_sample = 1'b0; io_write = 1'b0;
        end
    endtask

    // a write that must (st = 1) or must not (st = 0) raise the stereo strobe
    reg saw_st;
    task out_st(input [7:0] p, input [7:0] d);
        begin
            @(negedge clk); port = p; wdata = d; io_write = 1'b1; io_sample = 1'b1;
            #1 saw_st = stereo_wr;
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

    integer n, k, bad_kb, bad_math, bad_gate, bad_reg, bad_bios, ghosted, a, b, op;
    reg [2:0]  row;
    reg [7:0]  lo, hi;
    reg [11:0] want_kb;
    reg [15:0] got, want;
    initial begin
        bad_kb = 0; bad_math = 0; bad_gate = 0; bad_reg = 0; bad_bios = 0; ghosted = 0;
        repeat (3) @(negedge clk);
        rst = 1'b0; cold = 1'b0;

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

        // ---- math unit, MasterDrive mode, with the I/O gate open
        mode = 3'd5; fea = 8'h80;
        for (n = 0; n < 20000; n = n + 1) begin
            a = (n < 256) ? n : $urandom % 256;
            b = (n < 256) ? (n * 7) % 256 : $urandom % 256;
            if (n % 37 == 0) b = 0;
            op = (n % 5 == 0) ? 0 : 1;
            out(8'h0C, a); out(8'h0D, b); out(8'h0E, op);
            repeat (16) @(negedge clk);
            in(8'h0F, got[7:0]); in(8'h10, got[15:8]);
            want = op ? ((b != 0) ? {a[7:0] % b[7:0], a[7:0] / b[7:0]} : 16'h00FF) : a[7:0] * b[7:0];
            if (got !== want) begin
                bad_math = bad_math + 1;
                if (bad_math <= 5) $display("math: A %0d B %0d op %0d read %h, expected %h", a, b, op, got, want);
            end
        end
        $display("math unit: %0d cases, %0d wrong", n, bad_math);

        // ---- $0A work RAM bank (Q9) and $08 PCM fill (Q14), gate open
        mode = 3'd5; fea = 8'h80;
        for (n = 0; n < 256; n = n + 1) begin
            out(8'h0A, n);
            in(8'h0A, lo);
            if (lo !== {4'h0, n[3:0]} || wram_bank !== n[3:0]) bad_reg = bad_reg + 1;
        end
        for (n = 0; n <= 64; n = n + 1) begin
            fill = n;
            in(8'h08, lo);
            if (lo !== {1'b0, (n >= 56) ? 3'd7 : n[5:3], 4'h0}) bad_reg = bad_reg + 1;
        end
        fill = 7'd0;
        out(8'h0A, 8'h00);
        $display("registers ($0A, $08): %0d wrong", bad_reg);

        // ---- the I/O gate (Q1) and the machine ID (Q8)
        mode = 3'd5; fea = 8'h00;                               // MasterDrive, gate closed
        out(8'h0C, 8'h55); if (mem_ctl !== 8'h55) bad_gate = bad_gate + 1;   // $3E mirror
        out(8'h17, 8'hF5); if (io_ctl !== 8'hF5) bad_gate = bad_gate + 1;    // $3F mirror
        out(8'h05, 8'h12); if (io_ctl !== 8'h12) bad_gate = bad_gate + 1;
        out_st(8'h06, 8'hA9); if (saw_st || mem_ctl !== 8'hA9) bad_gate = bad_gate + 1;
        in(8'h0F, lo); if (lo !== 8'hFF) bad_gate = bad_gate + 1;
        in(8'h16, lo); if (lo !== 8'hFF) bad_gate = bad_gate + 1;
        in(8'h17, lo); if (lo !== 8'hFF) bad_gate = bad_gate + 1;
        in(8'h03, lo); if (lo !== 8'hFF) bad_gate = bad_gate + 1;
        in(8'h00, lo); if (lo[5:0] !== 6'd0 || lo === 8'hFF) bad_gate = bad_gate + 1;   // Start / region: always
        out(8'h3E, 8'hA8); out(8'h3F, 8'hFF);
        fea = 8'h80;                                            // gate open
        in(8'h17, lo); if (lo !== 8'hA7) bad_gate = bad_gate + 1;
        in(8'h16, lo); if (lo !== 8'h81) bad_gate = bad_gate + 1;
        out(8'h17, 8'h12); if (io_ctl !== 8'hFF) bad_gate = bad_gate + 1;    // read-only: absorbed
        out(8'h0C, 8'h55); if (mem_ctl !== 8'hA8) bad_gate = bad_gate + 1;
        out_st(8'h06, 8'h0F); if (!saw_st || mem_ctl !== 8'hA8) bad_gate = bad_gate + 1;
        mode = 3'd1; fea = 8'h00;                               // Game Gear: $06 needs no gate
        out_st(8'h06, 8'h0F); if (!saw_st) bad_gate = bad_gate + 1;
        mode = 3'd0; fea = 8'h80;                               // Master System: the mirrors, bit or no bit
        in(8'h17, lo); if (lo !== 8'hFF) bad_gate = bad_gate + 1;
        out(8'h0C, 8'h55); if (mem_ctl !== 8'h55) bad_gate = bad_gate + 1;
        $display("I/O gate and machine ID: %0d wrong", bad_gate);

        // ---- the BIOS's ports and settings
        mode = 3'd5; fea = 8'h00;
        // the first cold reset (at the start) took the platform's boosts, with no change pulse
        if (boost !== 11'b101_0001_0001) bad_bios = bad_bios + 1;
        pb = 11'b100_0000_0100;                                  // true TMS colours and Start = Pause on,
        cold = 1'b1; rst = 1'b1; pc = 9'h1FF; @(negedge clk);    // changed during a cold reset
        pc = 9'd0; @(negedge clk); rst = 1'b0; cold = 1'b0;
        @(negedge clk);
        if (mem_ctl !== 8'hE0 || boost !== pb) bad_bios = bad_bios + 1;
        out(8'h18, 8'd21); in(8'h19, lo); if (lo !== 8'h2F) bad_bios = bad_bios + 1;   // machines run
        out(8'h18, 8'd16); in(8'h19, lo); if (lo !== 8'hFF) bad_bios = bad_bios + 1;   // Auto
        out(8'h18, 8'd18); in(8'h19, lo); if (lo !== 8'd15) bad_bios = bad_bios + 1;   // 32 KB
        out(8'h18, 8'd0); out(8'h19, 8'd4);                      // the SF-7000: not run here
        out(8'h18, 8'd0); in(8'h19, lo); if (lo !== 8'd0) bad_bios = bad_bios + 1;
        out(8'h18, 8'd0); out(8'h19, 8'd1); out(8'h19, 8'd3);    // Game Gear; index 1 = 3 (bit 0)
        if (boot_mode !== 3'd1 || boost[0] !== 1'b0) bad_bios = bad_bios + 1;           // not current yet
        out(8'h18, 8'd1); in(8'h19, lo); if (lo !== 8'd1) bad_bios = bad_bios + 1;
        out(8'h18, 8'd4); out(8'h19, 8'd7); out(8'h18, 8'd4); in(8'h19, lo); if (lo !== 8'd0) bad_bios = bad_bios + 1;
        out(8'h18, 8'd4); out(8'h19, 8'd3);                      // turbo step 3 for the launch
        out(8'h18, 8'd2); out(8'h19, 8'd1);                      // the BIOS: overflow flag on ...
        pb[2] = 1'b0; pc = 9'b0_0000_0100; @(negedge clk); pc = 9'd0; @(negedge clk);   // ... the platform: Start = Pause off
        if (boost[2] !== 1'b0) bad_bios = bad_bios + 1;          // a platform change acts at once
        pb[3] = 1'b1; @(negedge clk); if (boost[3] !== 1'b0) bad_bios = bad_bios + 1;  // a value with no change pulse is not taken
        pb[3] = 1'b0;
        pc = 9'b0_0000_0010; @(negedge clk); pc = 9'd0; @(negedge clk);   // and later the platform's overflow flag: off
        // a BIOS write and a platform change of the same boost in one clock: the platform's wins
        out(8'h18, 8'd7); pb[8] = 1'b1; pc = 9'b0_0100_0000; out(8'h19, 8'd0); pc = 9'd0;
        out(8'h18, 8'd7); in(8'h19, lo); if (lo !== 8'd1 || boost[8] !== 1'b1) bad_bios = bad_bios + 1;
        if (saw_launch) bad_bios = bad_bios + 1;
        out(8'h1F, 8'hA4); if (saw_launch) bad_bios = bad_bios + 1;
        out(8'h1F, 8'hA5); if (!saw_launch) bad_bios = bad_bios + 1;
        rst = 1'b1; pb[10] = 1'b0; pc = 9'b1_0000_0000;          // the launch's reset, and in its clock
        @(negedge clk); rst = 1'b0; pc = 9'd0; @(negedge clk);    // the platform's true TMS colours: off
        if (mem_ctl !== 8'hA8 || boot_mode !== 3'd1) bad_bios = bad_bios + 1;
        if (boost !== {1'b0, 1'b0, 1'b1, 1'b0, 1'b0, 3'd3, 1'b0, 1'b0, 1'b1}) bad_bios = bad_bios + 1;
        // a later cold reset keeps the boosts in effect and offers them for the next launch; a
        // BIOS change not yet launched is dropped
        out(8'h3E, 8'hE0); out(8'h18, 8'd4); out(8'h19, 8'd1);    // the BIOS mapped again: turbo 1 next
        pb = 11'd0; cold = 1'b1; rst = 1'b1; @(negedge clk); @(negedge clk); rst = 1'b0; cold = 1'b0;
        @(negedge clk);
        if (mem_ctl !== 8'hE0 || boost !== {1'b0, 1'b0, 1'b1, 1'b0, 1'b0, 3'd3, 1'b0, 1'b0, 1'b1})
            bad_bios = bad_bios + 1;
        out(8'h18, 8'd4); in(8'h19, lo); if (lo !== 8'd3) bad_bios = bad_bios + 1;
        out(8'h18, 8'd0); in(8'h19, lo); if (lo !== 8'd0) bad_bios = bad_bios + 1;   // Auto: the Master System
        out(8'h3E, 8'hA8);
        out(8'h18, 8'h5A); if (mem_ctl !== 8'h5A) bad_bios = bad_bios + 1;   // bit 3 set: $18 is the $3E mirror again
        out(8'h3E, 8'h20);                                       // bits 3 and 6 clear: the cartridge answers ...
        out(8'h18, 8'h24); if (mem_ctl !== 8'h24) bad_bios = bad_bios + 1;   // ... and $18 is the mirror
        // index 0 after a cold reset: the platform's choice if it runs that machine, else 0
        p_auto = 1'b0; p_mode = 3'd1; cold = 1'b1; rst = 1'b1; @(negedge clk); rst = 1'b0; cold = 1'b0;
        if (boot_mode !== 3'd1) bad_bios = bad_bios + 1;         // Game Gear
        p_mode = 3'd4; cold = 1'b1; rst = 1'b1; @(negedge clk); rst = 1'b0; cold = 1'b0;
        if (boot_mode !== 3'd0) bad_bios = bad_bios + 1;         // the SF-7000, which it does not run
        p_auto = 1'b1;
        $display("BIOS ports and settings: %0d wrong", bad_bios);

        if (bad_kb == 0 && bad_math == 0 && bad_gate == 0 && bad_reg == 0 && bad_bios == 0) $display("PASS");
        else $display("FAIL");
        $finish;
    end
endmodule

`default_nettype wire
