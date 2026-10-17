// MasterDrive - I/O port decode and system registers
//
// Every IN/OUT is resolved at the CPU's I/O sample point (io_sample), the same
// instant Gearsystem performs the access. Read data is combinational so it is
// valid at that edge.
//
// Port map (machine profile v7):
//   $00      Game Gear Start / region (GG and MasterDrive modes)
//   $01-$06  Game Gear system ports: GG mode; MasterDrive mode once Feature
//            Enable A bit 7 is set (the I/O gate, Q1)
//   $07-$17  MasterDrive registers, MasterDrive mode once the gate is open: PCM,
//            slot select, work RAM bank, card bank, math unit, wavetable,
//            multitap detection, $17 the machine ID ($A7, Q8)
//   $18-$1F  the BIOS's ports, MasterDrive mode while the BIOS ROM is mapped ($3E
//            bit 3 clear, bit 6 set): $18 setting index, $19 setting, $1F launch ($A5)
//   $00-$3F  otherwise: even = memory control ($3E), odd = I/O control ($3F)
//   $40-$7F  write: PSG; read: V counter (even) / H counter (odd)
//   $80-$BF  VDP data (even) / control (odd)
//   $C0-$FF  controllers $DC/$DD (mirrored on SMS); SK-1100 PPI at $DC-$DF when
//            the keyboard is live; FM $F0-$F2; MasterDrive $F3 turbo, $F4-$FA DMA,
//            $FB-$FF debug unit (reads in MasterDrive mode only)
`default_nettype none

module mdr_io (
    input  wire        clk,
    input  wire        rst,              // a cold reset or the BIOS's launch
    input  wire        cold,             // with rst: a cold reset ($3E = $E0: the BIOS is mapped)
    input  wire [2:0]  mode,
    input  wire        jp_region,
    input  wire        fm_present,

    // CPU
    input  wire        io_sample,
    input  wire        io_write,
    input  wire [7:0]  port,
    input  wire [7:0]  wdata,
    output reg  [7:0]  rdata,

    // VDP
    input  wire [7:0]  vdp_rdata,
    output wire        vdp_rd,
    output wire        vdp_wr,
    input  wire [7:0]  vdp_fea,          // Feature Enable A (VDP R15)
    input  wire [7:0]  vdp_fec,          // Feature Enable C (bank 1 R7), 0 if not reachable
    output wire        th_latch,

    // PSG / FM
    output wire        psg_wr,
    output wire        stereo_wr,
    output wire        fm_wr,
    output wire        fm_addr,          // 0 = register select ($F0), 1 = data ($F1)
    output reg  [1:0]  fm_ctl,           // $F2 audio control

    // system registers
    output reg  [7:0]  mem_ctl,          // $3E
    output reg  [7:0]  io_ctl,           // $3F
    output reg  [3:0]  wram_bank,        // $0A
    output reg  [7:0]  slot_sel,         // $09
    output reg  [4:0]  card_bank,        // $0B
    output reg  [2:0]  turbo_step,       // $F3: 0..4 = 100..200 %
    output reg  [7:0]  pcm_ctl,
    output wire        pcm_wr,
    input  wire [6:0]  pcm_fill,         // bytes queued in the PCM FIFO, 0-64
    output wire        wt_wr,            // a wavetable port ($11-$15) written
    output wire [2:0]  wt_reg,           // which: 0 = $11 ... 4 = $15
    output wire        dma_start,        // $FA written with bit 7 set: start a DMA transfer
    output wire [47:0] dma_regs,         // $F9-$F4 as written

    // controllers: {start, c, b(2/TR), a(1/TL), right, left, down, up} active high
    input  wire [7:0]  pad1,
    input  wire [7:0]  pad2,
    input  wire        reset_btn,
    // SK-1100 matrix rows 0-6, 12 columns each (A0-A7, B0-B3), active high
    input  wire [83:0] kb_keys,
    input  wire        kb_ghosting,

    // the BIOS's settings (Technical Reference section 20). The platform gives
    // its machine choice and information, and the boosts as its own menu has
    // them, with a pulse for each boost it changes; the boosts in effect (boost)
    // and for the next launch (nxt) are kept here. Boost fields, by setting
    // index: [0] 1 sprite limit, [1] 2 stock overflow flag, [2] 3 Start = Pause,
    // [5:3] 4 turbo step, [6] 5 VRAM speed-up, [7] 6 auto-fire, [8] 7
    // pseudo-stereo, [9] 8 Game Gear uncrop, [10] 9 true TMS colours.
    input  wire [2:0]  plat_mode,        // index 16: the platform's machine choice ...
    input  wire        plat_auto,        // ... or none ($FF)
    input  wire [7:0]  plat_flags,       // index 17
    input  wire [4:0]  rom_log2,         // index 18
    input  wire [1:0]  mapper,           // index 19
    input  wire [5:0]  machines,         // index 21: the machines the platform runs
    input  wire [10:0] plat_boost,
    input  wire [8:0]  plat_chg,         // the platform changed the boost of index 1-9 (bit 0-8)
    output reg  [10:0] boost,            // in effect
    output reg  [2:0]  boot_mode,        // index 0: the machine the launch starts
    output wire        launch_req        // $A5 written to $1F
);
    localparam M_SMS = 3'd0, M_GG = 3'd1, M_SG = 3'd2, M_SC = 3'd3, M_SF = 3'd4, M_SS = 3'd5;
    wire gg = (mode == M_GG);
    wire ss = (mode == M_SS);
    wire legacy = (mode == M_SG) || (mode == M_SC) || (mode == M_SF);
    wire kb_live = legacy || (ss && vdp_fec[5]);
    // The I/O gate (Q1): in MasterDrive mode $01-$17 are registers only while
    // Feature Enable A bit 7 is set; until then they are the $3E/$3F mirrors and
    // read $FF, as on a Master System. It is live, and what the registers hold
    // stays in force while it is closed.
    wire md_io = ss && vdp_fea[7];
    wire gg_lo = (gg && port <= 8'h06) || (ss && port == 8'h00) || (md_io && port <= 8'h06);
    wire md_lo = md_io && port >= 8'h07 && port <= 8'h17;
    wire bios_lo = ss && !mem_ctl[3] && mem_ctl[6] && port[7:3] == 5'b00011;   // $18-$1F, the BIOS mapped
    localparam [7:0] MACHINE_ID = 8'hA7;   // $A = MasterDrive, 7 = machine version (Q8)

    // ------------------------------------------------------------ registers
    reg [7:0] gg_sio [1:5];
    reg [7:0] math_a, math_b;
    reg [15:0] math_res;
    reg        math_div;                 // the result is the divider's (div_q, div_r)
    reg [7:0]  div_q = 8'd0;
    reg [7:0] dma [0:6];
    reg [7:0] ppi_c, ppi_ctl;
    // Debug unit control port ($FB). The debug unit itself is not in this core
    // yet; the port is written in every mode, read back in MasterDrive mode, and,
    // like the machine's debug unit, survives a machine reset.
    reg [7:0] dbg_ctl = 8'h00;

    // ------------------------------------------------------------ keyboard
    // Column mask held on a row (12 bits) with ghosting: keys held on another
    // row that shares a column with this row's held keys bridge in. The closure
    // is taken over all rows, which is what the diode-less matrix does.
    function [11:0] rowkeys;
        input [2:0] row;
        input [83:0] keys;
        input [7:0] p1, p2;
        begin
            if (row == 3'd7) rowkeys = {p2[5], p2[4], p2[3], p2[2], p2[1], p2[0],
                                        p1[5], p1[4], p1[3], p1[2], p1[1], p1[0]};
            else rowkeys = keys[row*12 +: 12];
        end
    endfunction
    // reorder row 7 to the SK-1100 bit layout: A0 P1U A1 P1D A2 P1L A3 P1R A4 P1TL
    // A5 P1TR A6 P2U A7 P2D B0 P2L B1 P2R B2 P2TL B3 P2TR
    function [11:0] row7;
        input [7:0] p1, p2;
        row7 = {p2[5], p2[4], p2[3], p2[2], p2[1], p2[0], p1[5], p1[4], p1[3], p1[2], p1[1], p1[0]};
    endfunction

    reg [11:0] rm [0:7];
    // Row select: port C bits 2-0 while port C (lower) is an output; as an input
    // (the 8255's state after reset) the pull-ups select row 7, the pads.
    wire [2:0] kb_row = ppi_ctl[0] ? 3'd7 : ppi_c[2:0];
    integer r;
    always @* begin
        for (r = 0; r < 7; r = r + 1) rm[r] = kb_keys[r*12 +: 12];
        rm[7] = row7(pad1, pad2);
    end

    // The closure is built one step per clock, so it is not one long chain of
    // logic: each step adds every row that shares a column with the keys found
    // so far, and seven steps reach all eight rows. It restarts from the
    // selected row every eight clocks, so a change of keys or row shows within
    // sixteen clocks (0.3 us), well before the CPU's next instruction can read it.
    reg [11:0] kb_acc = 12'd0, kb_closed = 12'd0, kb_grow;
    reg [2:0]  kb_step = 3'd0;
    integer g;
    always @* begin
        kb_grow = kb_acc;
        for (g = 0; g < 8; g = g + 1)
            if ((rm[g] & kb_acc) != 12'd0) kb_grow = kb_grow | rm[g];
    end
    always @(posedge clk) begin
        kb_step <= kb_step + 3'd1;
        if (kb_step == 3'd7) begin
            kb_closed <= kb_grow;
            kb_acc <= rm[kb_row];
        end else
            kb_acc <= kb_grow;
    end
    wire [11:0] kb_m = kb_ghosting ? kb_closed : rm[kb_row];

    // ------------------------------------------------------------ pads
    // SMS / GG port $DC and $DD (active low). MasterDrive: Genesis 3-button pads,
    // TH high = U D L R B C, TH low = U D 0 0 A Start.
    wire th_a = io_ctl[5], th_b = io_ctl[7];
    reg [7:0] dc, dd;
    always @* begin
        dc = 8'hFF; dd = 8'hFF;
        if (ss) begin
            dc[0] = ~pad1[0]; dc[1] = ~pad1[1];
            if (th_a) begin dc[2] = ~pad1[2]; dc[3] = ~pad1[3]; dc[4] = ~pad1[5]; dc[5] = ~pad1[6]; end
            else      begin dc[2] = 1'b0;     dc[3] = 1'b0;     dc[4] = ~pad1[4]; dc[5] = ~pad1[7]; end
            dc[6] = ~pad2[0]; dc[7] = ~pad2[1];
            if (th_b) begin dd[0] = ~pad2[2]; dd[1] = ~pad2[3]; dd[2] = ~pad2[5]; dd[3] = ~pad2[6]; end
            else      begin dd[0] = 1'b0;     dd[1] = 1'b0;     dd[2] = ~pad2[4]; dd[3] = ~pad2[7]; end
        end else begin
            dc[0] = ~pad1[0]; dc[1] = ~pad1[1]; dc[2] = ~pad1[2]; dc[3] = ~pad1[3];
            dc[4] = ~pad1[4]; dc[5] = ~pad1[5];
            if (!gg) begin
                dc[6] = ~pad2[0]; dc[7] = ~pad2[1];
                dd[0] = ~pad2[2]; dd[1] = ~pad2[3]; dd[2] = ~pad2[4]; dd[3] = ~pad2[5];
            end
        end
        dd[4] = ~reset_btn;
        if (gg) begin
            dd[7:6] = io_ctl[7:6];
        end else begin
            // TR outputs read back (Gearsystem); TH outputs read back on export
            // machines, 0 on Japanese ones (machine profile, region detection)
            if (!io_ctl[0]) dc[5] = io_ctl[4];
            if (!io_ctl[2]) dd[3] = io_ctl[6];
            if (!io_ctl[1]) dd[6] = jp_region ? 1'b0 : io_ctl[5];
            if (!io_ctl[3]) dd[7] = jp_region ? 1'b0 : io_ctl[7];
        end
    end

    wire [3:0] dmai_w = port[3:0] - 4'd4;   // $F4-$FA -> 0-6
    wire [2:0] dmai = dmai_w[2:0];

    // ------------------------------------------------------------ read mux
    wire io_disabled = mem_ctl[2] && (mode == M_SMS || ss);
    always @* begin
        rdata = 8'hFF;
        if (gg_lo) begin
            if (port == 8'h00)      rdata = {~pad1[7], ~jp_region, 6'b000000};
            else if (port == 8'h06) rdata = 8'hFF;
            else                    rdata = gg_sio[port[2:0]];
        end else if (bios_lo) begin
            if (port == 8'h19) rdata = setting;
        end else if (md_lo) begin
            case (port)
                8'h08: rdata = {1'b0, pcm_fill[6] ? 3'd7 : pcm_fill[5:3], 4'b0000};   // bytes / 8, saturating (Q14)
                8'h09: rdata = slot_sel;
                8'h0A: rdata = {4'b0000, wram_bank};                                    // Q9
                8'h0B: rdata = {3'b000, card_bank};
                8'h0E: rdata = 8'h00;
                8'h0F: rdata = math_div ? div_q : math_res[7:0];     // quotient / product low
                8'h10: rdata = math_div ? div_r : math_res[15:8];    // remainder / product high
                8'h16: rdata = 8'h81;
                8'h17: rdata = MACHINE_ID;
                default: rdata = 8'hFF;
            endcase
        end else if (port == 8'hF2 && fm_present && mode != M_SG) begin
            rdata = {6'b000000, fm_ctl};
        end else if (port < 8'h40) begin
            if (legacy) rdata = port[0] ? dd : dc;     // reference emulator: pad mirror
            else rdata = 8'hFF;                        // Gearsystem: unconnected
        end else if (port < 8'hC0) begin
            rdata = vdp_rdata;
        end else if (ss && port >= 8'hF0 && port <= 8'hFA) begin
            rdata = (port >= 8'hF4) ? dma[dmai] : 8'hFF;
        end else if (ss && port >= 8'hFB) begin
            // Debug unit, MasterDrive mode only (the stock modes read the
            // controller mirror here). $FC/$FD status: bit 7 debug host attached,
            // bit 6 set, bit 0 trace buffer full; this core has neither.
            rdata = (port == 8'hFB) ? dbg_ctl : (port <= 8'hFD) ? 8'h40 : 8'hFF;
        end else if (io_disabled) begin
            rdata = 8'hFF;
        end else if (kb_live && port < 8'hE0) begin
            case (port[1:0])
                2'd0: rdata = ~kb_m[7:0];
                2'd1: rdata = {4'b0110, ~kb_m[11:8]};
                2'd2: rdata = ppi_c;
                default: rdata = 8'hFF;
            endcase
        end else if (gg) begin
            if (port == 8'hC0 || port == 8'hDC) rdata = dc;
            else if (port == 8'hC1 || port == 8'hDD) rdata = dd;
            else rdata = 8'hFF;
        end else begin
            rdata = port[0] ? dd : dc;
        end
    end

    // ------------------------------------------------------------ strobes
    wire rd = io_sample && !io_write;
    wire wr = io_sample && io_write;
    assign vdp_rd = rd && (port[7:6] != 2'b00) && (port < 8'hC0);   // counters and VDP ports
    assign vdp_wr = wr && (port[7:6] == 2'b10);
    assign psg_wr = wr && (port[7:6] == 2'b01);
    assign stereo_wr = wr && (gg || md_io) && port == 8'h06;
    assign fm_wr  = wr && fm_present && (port == 8'hF0 || port == 8'hF1);
    assign fm_addr = port[0];
    assign pcm_wr = wr && md_io && port == 8'h07;
    assign wt_wr  = wr && md_io && port >= 8'h11 && port <= 8'h15;
    wire [7:0] wt_off = port - 8'h11;
    assign wt_reg = wt_off[2:0];
    // DMA: $F4-$FA are fully decoded in MasterDrive mode (not behind the I/O gate)
    assign dma_start = wr && ss && port == 8'hFA && wdata[7];
    assign dma_regs  = {dma[5], dma[4], dma[3], dma[2], dma[1], dma[0]};
    always @(posedge clk) if (wr && port == 8'hFB) dbg_ctl <= wdata;
    // TH latch (Gearsystem rule): a $3F write that leaves a TH pin configured as
    // an input while raising its level bit
    wire lowport = port < 8'h40 && !gg_lo && !md_lo && !bios_lo;
    assign th_latch = wr && lowport && port[0] && !legacy &&
                      ((wdata[1] && wdata[5] && !io_ctl[5]) || (wdata[3] && wdata[7] && !io_ctl[7]));

    // math unit: A x B, or A / B with the quotient in $0F and the remainder in
    // $10, $FF/$00 for a divide by zero (Q7). The divide makes one quotient bit
    // per clock (restoring division), so its result is ready 8 clocks after the
    // $0E write, long before the CPU's next IN can read it (at least 82 clocks
    // later), and the divider is not one long chain of logic. The remainder fits
    // 8 bits because it is less than B.
    wire        div_start = wr && md_io && port == 8'h0E && wdata[0] && math_b != 8'd0;
    reg  [7:0]  div_r = 8'd0, div_d = 8'd0;
    reg  [3:0]  div_n = 4'd0;
    wire [8:0]  div_sh  = {div_r, div_q[7]};
    wire        div_ge  = div_sh >= {1'b0, div_d};
    wire [8:0]  div_sub = div_sh - {1'b0, div_d};
    always @(posedge clk) begin
        if (rst) div_n <= 4'd0;
        else if (div_start) begin
            div_q <= math_a; div_r <= 8'd0; div_d <= math_b; div_n <= 4'd8;
        end else if (div_n != 4'd0) begin
            div_r <= div_ge ? div_sub[7:0] : div_sh[7:0];
            div_q <= {div_q[6:0], div_ge};
            div_n <= div_n - 4'd1;
        end
    end

    integer i;
    always @(posedge clk) begin
        if (rst) begin
            mem_ctl <= cold ? 8'hE0 : 8'hA8; io_ctl <= 8'hFF; wram_bank <= 4'd0; slot_sel <= 8'd0;
            card_bank <= 5'd0; turbo_step <= 3'd0; fm_ctl <= 2'd0; pcm_ctl <= 8'd0;
            gg_sio[1] <= 8'h7F; gg_sio[2] <= 8'hFF; gg_sio[3] <= 8'h00; gg_sio[4] <= 8'hFF; gg_sio[5] <= 8'h00;
            math_a <= 8'd0; math_b <= 8'd0; math_res <= 16'd0; math_div <= 1'b0;
            for (i = 0; i < 7; i = i + 1) dma[i] <= 8'd0;
            ppi_c <= 8'h00; ppi_ctl <= 8'h9B;      // 8255 reset: every port an input
        end else if (wr) begin
            if (gg_lo) begin
                if (port != 8'h00 && port != 8'h06) gg_sio[port[2:0]] <= wdata;
            end else if (bios_lo) begin
                ;                       // the BIOS's ports: below
            end else if (md_lo) begin   // $0F, $10, $16, $17 are read-only: a write is absorbed
                case (port)
                    8'h08: pcm_ctl <= wdata;
                    8'h09: slot_sel <= wdata;
                    8'h0A: wram_bank <= wdata[3:0];
                    8'h0B: card_bank <= wdata[4:0];
                    8'h0C: math_a <= wdata;
                    8'h0D: math_b <= wdata;
                    8'h0E: begin   // divide: div_q, div_r; divide by zero: $FF/$00; multiply: A x B
                        math_res <= wdata[0] ? 16'h00FF : (math_a * math_b);
                        math_div <= wdata[0] && math_b != 8'd0;
                    end
                    default: ;
                endcase
            end else if (port < 8'h40) begin
                if (!legacy) begin
                    if (port[0]) io_ctl <= wdata;
                    else mem_ctl <= wdata;
                end
            end else if (port == 8'hF2) begin
                if (fm_present) fm_ctl <= wdata[1:0];
            end else if (ss && port == 8'hF3) begin
                if (vdp_fea[6] && wdata[2:0] < 3'd5) turbo_step <= wdata[2:0];
            end else if (ss && port >= 8'hF4 && port <= 8'hFA) begin
                dma[dmai] <= wdata;
            end else if (kb_live && port >= 8'hC0 && port < 8'hE0) begin
                if (port[1:0] == 2'd2) ppi_c <= wdata;
                else if (port[1:0] == 2'd3) begin
                    // 8255: a mode word clears the output latches; bit 7 clear
                    // is bit set/reset on port C
                    if (wdata[7]) begin ppi_ctl <= wdata; ppi_c <= 8'h00; end
                    else ppi_c[wdata[3:1]] <= wdata[0];
                end
            end
        end
    end

    // ------------------------------------------------------------ the BIOS's settings
    reg  [7:0]  b_idx;
    reg  [10:0] nxt;                     // the boosts for the next launch
    reg         first = 1'b1;            // the first cold reset since the FPGA was loaded
    reg  [7:0]  setting;
    always @* begin
        case (b_idx)
            8'd0:  setting = {5'd0, boot_mode};
            8'd1:  setting = {7'd0, nxt[0]};
            8'd2:  setting = {7'd0, nxt[1]};
            8'd3:  setting = {7'd0, nxt[2]};
            8'd4:  setting = {5'd0, nxt[5:3]};
            8'd5:  setting = {7'd0, nxt[6]};
            8'd6:  setting = {7'd0, nxt[7]};
            8'd7:  setting = {7'd0, nxt[8]};
            8'd8:  setting = {7'd0, nxt[9]};
            8'd9:  setting = {7'd0, nxt[10]};
            8'd16: setting = plat_auto ? 8'hFF : {5'd0, plat_mode};
            8'd17: setting = plat_flags;
            8'd18: setting = {3'd0, rom_log2};
            8'd19: setting = {6'd0, mapper};
            8'd20: setting = {7'd0, jp_region};
            8'd21: setting = {2'd0, machines};
            default: setting = 8'hFF;
        endcase
    end
    wire        b_val = io_sample && bios_lo && port == 8'h19;   // a read or write of $19
    wire        b_wr  = wr && bios_lo;
    assign launch_req = b_wr && port == 8'h1F && wdata == 8'hA5;
    // a BIOS write to index 1-9: index 4 (turbo) takes 0-4, the others bit 0
    reg  [10:0] nxt_w;
    always @* begin
        nxt_w = nxt;
        if (b_val && io_write) case (b_idx)
            8'd1: nxt_w[0] = wdata[0];
            8'd2: nxt_w[1] = wdata[0];
            8'd3: nxt_w[2] = wdata[0];
            8'd4: if (wdata <= 8'd4) nxt_w[5:3] = wdata[2:0];
            8'd5: nxt_w[6] = wdata[0];
            8'd6: nxt_w[7] = wdata[0];
            8'd7: nxt_w[8] = wdata[0];
            8'd8: nxt_w[9] = wdata[0];
            8'd9: nxt_w[10] = wdata[0];
            default: ;
        endcase
    end
    // A boost the platform changes takes the new value now and for the next launch
    // (and wins over a BIOS write in the same clock); a BIOS write sets only the
    // next launch's; the launch makes the next values current; a cold reset keeps
    // the current values and makes them the next ones. So the last change wins.
    // The first cold reset takes the platform's values.
    wire [10:0] f_chg = {plat_chg[8:4], {3{plat_chg[3]}}, plat_chg[2:0]};
    wire [10:0] boost_p = (boost & ~f_chg) | (plat_boost & f_chg);
    always @(posedge clk) begin
        if (!rst) first <= 1'b0;
        if (rst && cold) begin
            boost <= first ? plat_boost : boost_p; nxt <= first ? plat_boost : boost_p;
            b_idx <= 8'd0;
            boot_mode <= (plat_auto || !machines[plat_mode]) ? 3'd0 : plat_mode;   // a machine it runs
        end else if (rst) begin                   // the launch
            boost <= (nxt & ~f_chg) | (plat_boost & f_chg);
            nxt   <= (nxt & ~f_chg) | (plat_boost & f_chg);
            b_idx <= 8'd0;
        end else begin
            boost <= boost_p;
            nxt   <= (nxt_w & ~f_chg) | (plat_boost & f_chg);
            if (b_wr && port == 8'h18) b_idx <= wdata;
            else if (b_val) begin
                b_idx <= b_idx + 8'd1;
                if (io_write && b_idx == 8'd0 && wdata <= 8'd5 && machines[wdata[2:0]]) boot_mode <= wdata[2:0];
            end
        end
    end
endmodule

`default_nettype wire
