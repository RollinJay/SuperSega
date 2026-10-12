// Super Sega - I/O port decode and system registers
//
// Every IN/OUT is resolved at the CPU's I/O sample point (io_sample), the same
// instant Gearsystem performs the access. Read data is combinational so it is
// valid at that edge.
//
// Port map (machine profile v7):
//   $00-$06  Game Gear system ports (GG and Super Sega modes)
//   $07-$16  Super Sega registers (Super Sega mode): PCM, slot select, work RAM
//            bank, card bank, math unit, wavetable, multitap detection
//   $00-$3F  otherwise: even = memory control ($3E), odd = I/O control ($3F)
//   $40-$7F  write: PSG; read: V counter (even) / H counter (odd)
//   $80-$BF  VDP data (even) / control (odd)
//   $C0-$FF  controllers $DC/$DD (mirrored on SMS); SK-1100 PPI at $DC-$DF when
//            the keyboard is live; FM $F0-$F2; Super Sega $F3 turbo, $F4-$FA DMA,
//            $FB-$FF debug unit (reads in Super Sega mode only)
`default_nettype none

module ss_io (
    input  wire        clk,
    input  wire        rst,
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
    input  wire [6:0]  pcm_fill,

    // controllers: {start, c, b(2/TR), a(1/TL), right, left, down, up} active high
    input  wire [7:0]  pad1,
    input  wire [7:0]  pad2,
    input  wire        reset_btn,
    // SK-1100 matrix rows 0-6, 12 columns each (A0-A7, B0-B3), active high
    input  wire [83:0] kb_keys,
    input  wire        kb_ghosting
);
    localparam M_SMS = 3'd0, M_GG = 3'd1, M_SG = 3'd2, M_SC = 3'd3, M_SF = 3'd4, M_SS = 3'd5;
    wire gg = (mode == M_GG);
    wire ss = (mode == M_SS);
    wire legacy = (mode == M_SG) || (mode == M_SC) || (mode == M_SF);
    wire kb_live = legacy || (ss && vdp_fec[5]);

    // ------------------------------------------------------------ registers
    reg [7:0] gg_sio [1:5];
    reg [7:0] math_a, math_b;
    reg [15:0] math_res;
    reg [7:0] dma [0:6];
    reg [7:0] ppi_c, ppi_ctl;
    // Debug unit control port ($FB). The debug unit itself is not in this core
    // yet; the port is written in every mode, read back in Super Sega mode, and,
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
    reg [11:0] kb_m;
    reg [7:0]  reach;
    // Row select: port C bits 2-0 while port C (lower) is an output; as an input
    // (the 8255's state after reset) the pull-ups select row 7, the pads.
    wire [2:0] kb_row = ppi_ctl[0] ? 3'd7 : ppi_c[2:0];
    integer r, it;
    always @* begin
        reach = 8'd0;
        for (r = 0; r < 7; r = r + 1) rm[r] = kb_keys[r*12 +: 12];
        rm[7] = row7(pad1, pad2);
        kb_m = rm[kb_row];
        if (kb_ghosting) begin
            reach = 8'd0; reach[kb_row] = 1'b1;
            for (it = 0; it < 7; it = it + 1)
                for (r = 0; r < 8; r = r + 1)
                    if (!reach[r] && (rm[r] & kb_m) != 12'd0) begin
                        reach[r] = 1'b1;
                        kb_m = kb_m | rm[r];
                    end
        end
    end

    // ------------------------------------------------------------ pads
    // SMS / GG port $DC and $DD (active low). Super Sega: Genesis 3-button pads,
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
        if ((gg || ss) && port <= 8'h06) begin
            if (port == 8'h00)      rdata = {~pad1[7], ~jp_region, 6'b000000};
            else if (port == 8'h06) rdata = 8'hFF;
            else                    rdata = gg_sio[port[2:0]];
        end else if (ss && port >= 8'h07 && port <= 8'h16) begin
            case (port)
                8'h08: rdata = {1'b0, pcm_fill[2:0], 4'b0000};
                8'h09: rdata = slot_sel;
                8'h0B: rdata = {3'b000, card_bank};
                8'h0E: rdata = 8'h00;
                8'h0F: rdata = math_res[7:0];
                8'h10: rdata = math_res[15:8];
                8'h16: rdata = 8'h81;
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
            // Debug unit, Super Sega mode only (the stock modes read the
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
    assign stereo_wr = wr && (gg || ss) && port == 8'h06;
    assign fm_wr  = wr && fm_present && (port == 8'hF0 || port == 8'hF1);
    assign fm_addr = port[0];
    assign pcm_wr = wr && ss && port == 8'h07;
    always @(posedge clk) if (wr && port == 8'hFB) dbg_ctl <= wdata;
    // TH latch (Gearsystem rule): a $3F write that leaves a TH pin configured as
    // an input while raising its level bit
    wire lowport = port < 8'h40 && !((gg || ss) && port <= 8'h06) && !(ss && port >= 8'h07 && port <= 8'h16);
    assign th_latch = wr && lowport && port[0] && !legacy &&
                      ((wdata[1] && wdata[5] && !io_ctl[5]) || (wdata[3] && wdata[7] && !io_ctl[7]));

    // math unit (division as the reference emulator does it; profile Q7 open)
    wire [15:0] div_num = {math_a, math_b};

    integer i;
    always @(posedge clk) begin
        if (rst) begin
            mem_ctl <= 8'hA8; io_ctl <= 8'hFF; wram_bank <= 4'd0; slot_sel <= 8'd0;
            card_bank <= 5'd0; turbo_step <= 3'd0; fm_ctl <= 2'd0; pcm_ctl <= 8'd0;
            gg_sio[1] <= 8'h7F; gg_sio[2] <= 8'hFF; gg_sio[3] <= 8'h00; gg_sio[4] <= 8'hFF; gg_sio[5] <= 8'h00;
            math_a <= 8'd0; math_b <= 8'd0; math_res <= 16'd0;
            for (i = 0; i < 7; i = i + 1) dma[i] <= 8'd0;
            ppi_c <= 8'h00; ppi_ctl <= 8'h9B;      // 8255 reset: every port an input
        end else if (wr) begin
            if ((gg || ss) && port <= 8'h06) begin
                if (port != 8'h00 && port != 8'h06) gg_sio[port[2:0]] <= wdata;
            end else if (ss && port >= 8'h07 && port <= 8'h16) begin
                case (port)
                    8'h08: pcm_ctl <= wdata;
                    8'h09: slot_sel <= wdata;
                    8'h0A: wram_bank <= wdata[3:0];
                    8'h0B: card_bank <= wdata[4:0];
                    8'h0C: math_a <= wdata;
                    8'h0D: math_b <= wdata;
                    8'h0E: math_res <= wdata[0] ? ((math_b != 8'd0) ? (div_num / {8'd0, math_b}) : 16'd0)
                                                : (math_a * math_b);
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
endmodule

`default_nettype wire
