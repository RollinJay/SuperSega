// MasterDrive - memory map
//
// Decodes every CPU memory access by machine mode and cartridge mapper, and
// owns the work RAM and cartridge RAM. ROM (cartridge, card) lives outside the
// machine on a request/acknowledge bus, so the platform can keep it in PSRAM,
// SDRAM or block RAM.
//
// Modes: 0 SMS, 1 GG, 2 SG-1000, 3 SC-3000, 5 MasterDrive. (4 = SF-7000 is not in
// this milestone; it reads as open bus.)
// Mappers (SMS/GG/MasterDrive): 0 Sega, 1 Codemasters, 2 Korean, 3 Korean MSX 8 KB.
//
// Behaviour follows the machine profile and the reference emulator's model:
//  - Sega mapper registers at $FFFC-$FFFF (Sega family only); the write also
//    lands in work RAM. First 1 KB of slot 0 never banks.
//  - Codemasters registers at exactly $0000/$4000/$8000, power-on banks 0,1,0;
//    Korean register at exactly $A000 (Gearsystem and MAME decode the full
//    address).
//  - $FFFC bit 3 maps cartridge RAM over $8000-$BFFF; bit 2 picks one of two
//    8 KB banks, mirrored in the 16 KB window (profile open question Q3).
//  - $3E bit 6 disables the cartridge, bit 4 work RAM: reads see $FF. Bit 3
//    clear with bit 6 set maps the 8 KB BIOS ROM over $0000-$BFFF (repeated);
//    with both enabled the cartridge answers (Technical Reference section 20). Its image is
//    pocket-core/rtl/mdr_bios.hex, written by bios/make_bios.py; the file name
//    is MDR_BIOS_FILE (the Quartus project's path by default; the simulations
//    give their own).
//  - MasterDrive: port $0A selects one of 16 work RAM banks of 8 KB; port $09
//    routes slot 1 / slot 2 to the card, bank from port $0B.
//  - SG-1000: linear ROM, 1 KB RAM mirrored from $C000. SC-3000: ROM $0000-$7FFF
//    (mirrored), cart RAM $8000-$BFFF (16 KB) or $8000-$FFFF (32 KB, no work
//    RAM), 2 KB work RAM mirrored. The SC-3000's cart RAM is work RAM banks 4-7,
//    which no other stock mode uses, not the battery-saved cartridge RAM: a
//    cartridge with a save run as SC-3000 (the BIOS's machine choice, or System)
//    leaves its save alone.
`default_nettype none
`ifndef MDR_BIOS_FILE
`define MDR_BIOS_FILE "core/rtl/mdr_bios.hex"
`endif

module mdr_mem (
    input  wire        clk,
    input  wire        rst,
    input  wire [2:0]  mode,
    input  wire [1:0]  mapper,
    input  wire        sc_ram32,       // SC-3000 32 KB cart RAM configuration
    input  wire [22:0] rom_mask,       // ROM size - 1 (power of two)
    input  wire        card_present,
    input  wire [18:0] card_mask,

    // CPU
    input  wire [15:0] a,
    input  wire [7:0]  dout,           // CPU write data
    input  wire        mreq_n,
    input  wire        rd_n,
    input  wire        wr_n,
    input  wire        rd_start,       // T1 of a memory read
    input  wire [1:0]  dma_src,        // a DMA read: 1 the card (bank $0B), 2 work RAM (the selected bank)
    output reg  [7:0]  rdata,
    output wire        wait_n,

    // registers owned by the I/O block
    input  wire [7:0]  mem_ctl,        // port $3E
    input  wire [3:0]  wram_bank,      // port $0A
    input  wire [7:0]  slot_sel,       // port $09
    input  wire [4:0]  card_bank,      // port $0B

    // external ROM bus: cartridge at 0x000000, card at 0x800000
    output reg         rom_req,
    output reg  [23:0] rom_addr,
    input  wire        rom_ack,
    input  wire [7:0]  rom_data,

    // cartridge RAM port for save upload/download (platform side)
    input  wire        sv_clk,
    input  wire        sv_we,
    input  wire [14:0] sv_addr,
    input  wire [7:0]  sv_din,
    output wire [7:0]  sv_dout,

    // state for the debugger / savestates
    output reg  [7:0]  page0, page1, page2,
    output reg  [7:0]  ram_sel,
    output wire        cram_we         // CPU write to cartridge RAM
);
    localparam M_SMS = 3'd0, M_GG = 3'd1, M_SG = 3'd2, M_SC = 3'd3, M_SF = 3'd4, M_SS = 3'd5;

    // ------------------------------------------------------------ mapper state
    reg [7:0] k8 [0:3];               // MSX 8 KB banks
    reg       cm_ram;                 // Codemasters on-cart RAM enable

    wire mark3 = (mode == M_SMS) || (mode == M_GG) || (mode == M_SS);
    wire ss    = (mode == M_SS);

    // ------------------------------------------------------------ decode
    localparam T_ROM = 3'd0, T_CARD = 3'd1, T_WRAM = 3'd2, T_CRAM = 3'd3, T_OPEN = 3'd4, T_BIOS = 3'd5;
    reg [2:0]  tgt;
    reg [22:0] roff;                  // ROM byte offset
    reg [16:0] woff;                  // work RAM offset (128 KB)
    reg [14:0] coff;                  // cartridge RAM offset (32 KB)

    function [22:0] rom16;            // 16 KB bank + offset
        input [7:0] bank;
        input [13:0] off;
        rom16 = {1'b0, bank, off};
    endfunction
    function [22:0] rom8;             // 8 KB bank + offset
        input [7:0] bank;
        input [12:0] off;
        rom8 = {2'b00, bank, off};
    endfunction

    always @* begin
        tgt = T_OPEN; roff = 23'd0; woff = 17'd0; coff = 15'd0;
        case (mode)
        M_SG: begin
            if (a < 16'hC000) begin tgt = T_ROM; roff = {7'd0, a}; end
            else begin tgt = T_WRAM; woff = {7'd0, a[9:0]}; end
        end
        M_SC: begin
            if (a < 16'h8000) begin tgt = T_ROM; roff = {7'd0, a}; end
            else if (sc_ram32) begin tgt = T_WRAM; woff = {2'b01, a[14:0]}; end
            else if (a < 16'hC000) begin tgt = T_WRAM; woff = {3'b010, a[13:0]}; end
            else begin tgt = T_WRAM; woff = {6'd0, a[10:0]}; end
        end
        M_SMS, M_GG, M_SS: begin
            if (a >= 16'hC000) begin
                tgt = T_WRAM; woff = {(ss ? wram_bank : 4'd0), a[12:0]};
            end else begin
                tgt = T_ROM;
                case (mapper)
                2'd1: begin // Codemasters
                    if (a < 16'h4000) roff = rom16(page0, a[13:0]);
                    else if (a < 16'h8000) roff = rom16(page1, a[13:0]);
                    else if (cm_ram && a >= 16'hA000) begin tgt = T_CRAM; coff = {2'b00, a[12:0]}; end
                    else roff = rom16(page2, a[13:0]);
                end
                2'd2: begin // Korean
                    if (a < 16'h4000) roff = rom16(8'd0, a[13:0]);
                    else if (a < 16'h8000) roff = rom16(8'd1, a[13:0]);
                    else roff = rom16(page2, a[13:0]);
                end
                2'd3: begin // Korean MSX, 8 KB banks, first 16 KB fixed
                    if (a < 16'h4000) roff = {9'd0, a[13:0]};
                    else if (a < 16'h6000) roff = rom8(k8[2], a[12:0]);
                    else if (a < 16'h8000) roff = rom8(k8[3], a[12:0]);
                    else if (a < 16'hA000) roff = rom8(k8[0], a[12:0]);
                    else roff = rom8(k8[1], a[12:0]);
                end
                default: begin // Sega
                    if (a < 16'h0400) roff = {13'd0, a[9:0]};
                    else if (a < 16'h4000) roff = rom16(page0, a[13:0]);
                    else if (a < 16'h8000) begin
                        if (ss && slot_sel[0] && card_present) tgt = T_CARD;
                        roff = (ss && slot_sel[0] && card_present) ? {4'd0, card_bank, a[13:0]} : rom16(page1, a[13:0]);
                    end else begin
                        // $FFFC bit 3 maps cartridge RAM over $8000-$BFFF, bit 2 picks one
                        // of two 16 KB banks: 32 KB (Q3)
                        if (ram_sel[3]) begin tgt = T_CRAM; coff = {ram_sel[2], a[13:0]}; end
                        else if (ss && slot_sel[1] && card_present) begin tgt = T_CARD; roff = {4'd0, card_bank, a[13:0]}; end
                        else roff = rom16(page2, a[13:0]);
                    end
                end
                endcase
            end
            // $3E enables: disabled regions read open bus; the BIOS ROM where the cartridge is off
            if (a >= 16'hC000 && mem_ctl[4]) tgt = T_OPEN;
            if (a <  16'hC000 && mem_ctl[6] && !card_present) tgt = T_OPEN;
            if (a <  16'hC000 && !mem_ctl[3] && mem_ctl[6]) tgt = T_BIOS;
        end
        default: tgt = T_OPEN;
        endcase
        // DMA sources 1 and 2 (Technical Reference section 9) read the card or the
        // selected work RAM bank directly, whatever the mapper, $09 and $3E say
        if (dma_src == 2'd1) begin tgt = card_present ? T_CARD : T_OPEN; roff = {4'd0, card_bank, a[13:0]}; end
        if (dma_src == 2'd2) begin tgt = T_WRAM; woff = {wram_bank, a[12:0]}; end
    end

    // ------------------------------------------------------------ RAMs
    reg         w_we;
    reg  [16:0] w_addr;
    reg  [7:0]  w_din;
    wire [7:0]  w_dout;
    mdr_dpram #(.AW(17), .DW(8)) u_wram (
        .clk_a(clk), .we_a(w_we), .addr_a(w_addr), .din_a(w_din), .dout_a(w_dout),
        .clk_b(clk), .we_b(1'b0), .addr_b(17'd0), .din_b(8'h00), .dout_b());

    reg         c_we;
    assign cram_we = c_we;
    reg  [14:0] c_addr;
    reg  [7:0]  c_din;
    wire [7:0]  c_dout;
    mdr_dpram #(.AW(15), .DW(8)) u_cartram (
        .clk_a(clk), .we_a(c_we), .addr_a(c_addr), .din_a(c_din), .dout_a(c_dout),
        .clk_b(sv_clk), .we_b(sv_we), .addr_b(sv_addr), .din_b(sv_din), .dout_b(sv_dout));

    // the BIOS ROM: 8 KB, read like the RAMs (one clock)
    reg  [7:0]  bios [0:8191];
    reg  [12:0] b_addr;
    reg  [7:0]  b_dout;
    initial $readmemh(`MDR_BIOS_FILE, bios);
    always @(posedge clk) b_dout <= bios[b_addr];

    // ------------------------------------------------------------ read path
    reg [2:0]  rd_tgt;
    reg [1:0]  rd_pipe;               // BRAM latency
    reg        rd_busy;
    reg        wr_d;                  // write strobe edge detect

    wire mem_wr = !mreq_n && !wr_n;
    wire mem_rd = !mreq_n && !rd_n;
    // hold the CPU in T2 until the data is there
    assign wait_n = !(rd_busy && mem_rd);

    always @(posedge clk) begin
        w_we <= 1'b0; c_we <= 1'b0;
        if (rst) begin
            rd_busy <= 1'b0; rd_pipe <= 2'b00; rom_req <= 1'b0; wr_d <= 1'b0;
            page0 <= 8'd0; page1 <= 8'd1; page2 <= (mapper == 2'd1) ? 8'd0 : 8'd2;
            ram_sel <= 8'd0; cm_ram <= 1'b0;
            k8[0] <= 8'd0; k8[1] <= 8'd1; k8[2] <= 8'd2; k8[3] <= 8'd3;
            rdata <= 8'hFF;
        end else begin
            // ------------------------------------------------ reads
            rd_pipe <= {rd_pipe[0], 1'b0};
            if (rd_start) begin
                rd_tgt <= tgt;
                rd_busy <= 1'b1;
                case (tgt)
                T_ROM:  begin rom_req <= 1'b1; rom_addr <= {1'b0, roff & rom_mask}; end
                T_CARD: begin rom_req <= 1'b1; rom_addr <= {1'b1, 4'd0, roff[18:0] & card_mask}; end
                T_WRAM: begin w_addr <= woff; rd_pipe <= 2'b01; end
                T_CRAM: begin c_addr <= coff; rd_pipe <= 2'b01; end
                T_BIOS: begin b_addr <= a[12:0]; rd_pipe <= 2'b01; end
                default: begin rdata <= 8'hFF; rd_busy <= 1'b0; end
                endcase
            end
            if (rom_req && rom_ack) begin
                rom_req <= 1'b0;
                rdata <= rom_data;
                rd_busy <= 1'b0;
            end
            if (rd_pipe[1]) begin
                rdata <= (rd_tgt == T_WRAM) ? w_dout : (rd_tgt == T_BIOS) ? b_dout : c_dout;
                rd_busy <= 1'b0;
            end

            // ------------------------------------------------ writes
            wr_d <= mem_wr;
            if (mem_wr && !wr_d) begin
                case (mode)
                M_SG: if (a >= 16'hC000) begin w_we <= 1'b1; w_addr <= {7'd0, a[9:0]}; w_din <= dout; end
                M_SC: begin
                    if (a >= 16'h8000) begin
                        if (sc_ram32) begin w_we <= 1'b1; w_addr <= {2'b01, a[14:0]}; w_din <= dout; end
                        else if (a < 16'hC000) begin w_we <= 1'b1; w_addr <= {3'b010, a[13:0]}; w_din <= dout; end
                        else begin w_we <= 1'b1; w_addr <= {6'd0, a[10:0]}; w_din <= dout; end
                    end
                end
                M_SMS, M_GG, M_SS: begin
                    if (a >= 16'hC000) begin
                        w_we <= 1'b1; w_addr <= {(ss ? wram_bank : 4'd0), a[12:0]}; w_din <= dout;
                    end
                    case (mapper)
                    2'd1: begin
                        if (a == 16'h0000) page0 <= dout;
                        else if (a == 16'h4000) begin page1 <= dout; cm_ram <= dout[7]; end
                        else if (a == 16'h8000) page2 <= dout;
                        else if (cm_ram && a >= 16'hA000 && a < 16'hC000) begin
                            c_we <= 1'b1; c_addr <= {2'b00, a[12:0]}; c_din <= dout;
                        end
                    end
                    2'd2: if (a == 16'hA000) page2 <= dout;
                    2'd3: if (a <= 16'h0003) k8[a[1:0]] <= dout;
                    default: begin
                        if (a >= 16'hFFFC) begin
                            case (a[1:0])
                            2'd0: ram_sel <= dout;
                            2'd1: page0 <= dout;
                            2'd2: page1 <= dout;
                            2'd3: page2 <= dout;
                            endcase
                        end else if (a >= 16'h8000 && a < 16'hC000 && ram_sel[3]) begin
                            c_we <= 1'b1; c_addr <= {ram_sel[2], a[13:0]}; c_din <= dout;
                        end
                    end
                    endcase
                end
                default: ;
                endcase
            end
        end
    end
endmodule

`default_nettype wire
