// MasterDrive - Analogue Pocket platform layer
//
// Everything between the Analogue Pocket framework (APF) and the machine:
//   - interact menu settings (bridge writes at $0000_01xx, clk_74a domain)
//   - cartridge download: APF bridge -> data_loader -> PSRAM die 0, with the
//     ROM size taken from the data slot and a 512-byte copier header skipped
//   - system detection from the "TMR SEGA" header seen while the ROM streams in
//   - the machine's ROM bus served from PSRAM
//   - cartridge RAM saves: bridge <-> machine save port (nonvolatile data slot)
//   - controllers: Pocket/dock pads, dock USB keyboard -> SK-1100 matrix
//   - video into the pixel-clock domain, with the end-of-line scaler slot word
//   - audio low-pass before the 48 kHz I2S sampler (in core_top)
//
// It holds no APF code, so it can be simulated with a PSRAM model and a bridge
// model (sim/pocket). core_top.v wires it to the framework.
`default_nettype none

module mdr_pocket (
    input  wire        clk_74a,
    input  wire        clk_sys,          // 53.693175 MHz
    input  wire        clk_vid,          // 5.369318 MHz, same PLL as clk_sys
    input  wire        pll_locked,
    input  wire        apf_reset_n,      // core_bridge_cmd reset_n (clk_74a)

    // bridge (clk_74a)
    input  wire        bridge_endian_little,
    input  wire [31:0] bridge_addr,
    input  wire        bridge_rd,
    input  wire        bridge_wr,
    input  wire [31:0] bridge_wr_data,
    output wire [31:0] save_rd_data,     // read data for bridge addresses $2xxx_xxxx

    input  wire        dataslot_requestwrite,
    input  wire [15:0] dataslot_requestwrite_id,
    input  wire [31:0] dataslot_requestwrite_size,
    input  wire        dataslot_allcomplete,
    output wire        save_present,     // cartridge RAM holds data worth saving (clk_74a)

    // controllers (clk_74a)
    input  wire [31:0] cont1_key,
    input  wire [31:0] cont2_key,
    input  wire [31:0] cont3_key,
    input  wire [31:0] cont3_joy,
    input  wire [15:0] cont3_trig,

    // PSRAM 0
    output wire [21:16] cram0_a,
    inout  wire [15:0] cram0_dq,
    input  wire        cram0_wait,
    output wire        cram0_clk,
    output wire        cram0_adv_n,
    output wire        cram0_cre,
    output wire        cram0_ce0_n,
    output wire        cram0_ce1_n,
    output wire        cram0_oe_n,
    output wire        cram0_we_n,
    output wire        cram0_ub_n,
    output wire        cram0_lb_n,

    // video (clk_vid)
    output reg  [23:0] video_rgb,
    output reg         video_de,
    output reg         video_hs,
    output reg         video_vs,
    output wire        video_skip,

    // audio (clk_sys)
    output reg  signed [15:0] audio_l,
    output reg  signed [15:0] audio_r
);
    // =====================================================================
    // interact settings (clk_74a), written by the APF before reset exit
    // =====================================================================
    // $0000_00F0 action: reset the machine
    // $0000_0100 system      0 auto 1 SMS 2 Game Gear 3 MasterDrive 4 SG-1000 5 SC-3000
    // $0000_0104 region      0 export 1 Japan
    // $0000_0108 video       0 NTSC 60 Hz 1 PAL 50 Hz
    // $0000_010C mapper      0 Sega 1 Codemasters 2 Korean 3 Korean MSX 8 KB
    // $0000_0110 GG screen   0 LCD window 160x144 1 full 256x192 (boost: uncrop)
    // $0000_011C ghosting    1 = SK-1100 matrix ghosting on (stock behaviour)
    // $0000_0120 SC RAM      0 16 KB 1 32 KB cartridge RAM (SC-3000 BASIC carts)
    // $0000_0134 TMS colours 1 = true TMS9918 colours (default), 0 = Master System approximation
    // Boosts: the machine's enhancement layer, all off by default (stock) except
    // TMS colours ($0000_0134, above) and Start = Pause ($0000_0118):
    // $0000_0114 sprites     0 8 per line, 1 16 per line, 2 16 per line with the
    //                        overflow flag still set by a 9th sprite
    // $0000_0118 Start=Pause 1 = Start raises Pause (SMS, SG-1000, SC-3000) (default)
    // $0000_0124 turbo       0 off, 1-4 = 125/150/175/200 % (stock software only)
    // $0000_0128 VRAM boost  1 = no VDP access wait at turbo
    // $0000_012C auto-fire   1 = C held repeats button 2
    // $0000_0130 stereo      1 = pseudo-stereo PSG until software writes $06
    reg [2:0] set_system   = 3'd0;
    reg       set_region   = 1'b0;
    reg       set_pal      = 1'b0;
    reg [1:0] set_mapper   = 2'd0;
    reg       set_ggfull   = 1'b0;
    reg [1:0] set_spr      = 2'd0;
    reg       set_startp   = 1'b1;     // Start = Pause: on at power-on (the pad has no Pause button)
    reg [2:0] set_turbo    = 3'd0;
    reg       set_vboost   = 1'b0;
    reg       set_afire    = 1'b0;
    reg       set_pstereo  = 1'b0;
    reg       set_ghost    = 1'b1;
    reg       set_tmscol   = 1'b1;     // true TMS colours: on by default (open question Q11, decided)
    reg       set_scram32  = 1'b1;
    reg [7:0] reset_req    = 8'd0;     // stretched reset request

    always @(posedge clk_74a) begin
        if (reset_req != 8'd0) reset_req <= reset_req - 8'd1;
        if (bridge_wr && bridge_addr[31:12] == 20'h00000) begin
            case (bridge_addr[11:0])
                12'h0F0: reset_req <= 8'hFF;
                12'h100: begin
                    set_system <= bridge_wr_data[2:0];
                    // a change restarts the machine, so its BIOS starts again and
                    // offers the new choice first, as a change of Video does
                    if (bridge_wr_data[2:0] != set_system) reset_req <= 8'hFF;
                end
                12'h104: set_region  <= bridge_wr_data[0];
                12'h108: begin
                    set_pal <= bridge_wr_data[0];
                    // a change restarts the machine on the new standard (it is
                    // latched only in reset, below)
                    if (bridge_wr_data[0] != set_pal) reset_req <= 8'hFF;
                end
                12'h10C: set_mapper  <= bridge_wr_data[1:0];
                12'h110: set_ggfull  <= bridge_wr_data[0];
                12'h114: set_spr     <= bridge_wr_data[1:0];
                12'h124: set_turbo   <= (bridge_wr_data[2:0] > 3'd4) ? 3'd4 : bridge_wr_data[2:0];
                12'h128: set_vboost  <= bridge_wr_data[0];
                12'h12C: set_afire   <= bridge_wr_data[0];
                12'h130: set_pstereo <= bridge_wr_data[0];
                12'h118: set_startp  <= bridge_wr_data[0];
                12'h11C: set_ghost   <= bridge_wr_data[0];
                12'h120: set_scram32 <= bridge_wr_data[0];
                12'h134: set_tmscol  <= bridge_wr_data[0];
                default: ;
            endcase
        end
    end

    // =====================================================================
    // download tracking (clk_74a)
    // =====================================================================
    // Slot 0 (id 0) is the cartridge at bridge $1000_0000; slot 1 (id 1) the
    // save at $2000_0000.
    reg        downloading = 1'b0;
    reg        rom_loaded  = 1'b0;
    reg        hdr_skip    = 1'b0;      // file carries a 512-byte copier header
    reg [22:0] rom_mask_74 = 23'h7FFF;
    reg [4:0]  rom_log2_74 = 5'd0;      // the BIOS's setting 18
    reg [31:0] rom_bytes   = 32'd0;
    reg [22:0] rom_end_74  = 23'd0;     // the image's size, at most 4 MB
    reg        save_loaded = 1'b0;

    // smallest power of two >= size, minus one; at most 4 MB, the largest
    // cartridge the machine takes (Q2: the Sega mapper's 8-bit banks reach 4 MB)
    function [22:0] pow2mask;
        input [31:0] n;
        reg   [31:0] m;
        begin
            m = (n == 32'd0) ? 32'd0 : n - 32'd1;
            m = m | (m >> 1); m = m | (m >> 2); m = m | (m >> 4);
            m = m | (m >> 8); m = m | (m >> 16);
            if (m < 32'h1FFF) m = 32'h1FFF;          // at least 8 KB, the smallest cartridge
            pow2mask = (m > 32'h3FFFFF) ? 23'h3FFFFF : m[22:0];
        end
    endfunction

    // log2 of the size rounded up (13 = 8 KB, 22 = 4 MB); 0 for an empty file
    function [4:0] log2up;
        input [31:0] n;
        reg   [31:0] m;
        integer      k;
        begin
            m = (n == 32'd0) ? 32'd0 : n - 32'd1;
            log2up = 5'd0;
            for (k = 0; k < 32; k = k + 1) if (m[k]) log2up = k[4:0] + 5'd1;
        end
    endfunction

    wire [31:0] rom_size_net = (dataslot_requestwrite_size[9:0] == 10'd512) ?
                               dataslot_requestwrite_size - 32'd512 : dataslot_requestwrite_size;

    always @(posedge clk_74a) begin
        if (dataslot_requestwrite) begin
            downloading <= 1'b1;
            if (dataslot_requestwrite_id == 16'd0) begin
                rom_loaded  <= 1'b0;
                hdr_skip    <= (dataslot_requestwrite_size[9:0] == 10'd512);
                rom_bytes   <= rom_size_net;
                rom_mask_74 <= pow2mask(rom_size_net);
                rom_log2_74 <= log2up(rom_size_net);
                rom_end_74  <= (rom_size_net > 32'h400000) ? 23'h400000 : rom_size_net[22:0];
            end
        end else if (dataslot_allcomplete) begin
            downloading <= 1'b0;
            rom_loaded  <= 1'b1;
        end
        if (bridge_wr && bridge_addr[31:28] == 4'h2) save_loaded <= 1'b1;
    end

    // =====================================================================
    // clock-domain crossing to clk_sys
    // =====================================================================
    // Settings and download state are quasi-static: two-flop synchronisers.
    // The machine is held in reset while anything is loading.
    // field order matters only between these two blocks
    wire [72:0] s74 = {rom_end_74, rom_log2_74, set_tmscol,                           // 29
                       set_system, set_region, set_pal, set_mapper, set_ggfull,     // 8
                       set_spr, set_startp, set_turbo, set_vboost, set_afire,        // 8
                       set_pstereo, set_ghost, set_scram32,                          // 3
                       rom_mask_74, downloading, rom_loaded};                        // 25
    reg  [72:0] ss1, ss2;
    wire [22:0] s_romend  = ss2[72:50];
    wire [4:0]  s_romlog2 = ss2[49:45];
    wire        s_tmscol  = ss2[44];
    always @(posedge clk_sys) begin ss1 <= s74; ss2 <= ss1; end
    wire [2:0]  s_system  = ss2[43:41];
    wire        s_region  = ss2[40];
    wire        s_pal     = ss2[39];
    wire [1:0]  s_mapper  = ss2[38:37];
    wire        s_ggfull  = ss2[36];
    wire [1:0]  s_spr     = ss2[35:34];
    wire        s_startp  = ss2[33];
    wire [2:0]  s_turbo   = ss2[32:30];
    wire        s_vboost  = ss2[29];
    wire        s_afire   = ss2[28];
    wire        s_pstereo = ss2[27];
    wire        s_ghost   = ss2[26];
    wire        s_scram32 = ss2[25];
    wire [22:0] s_rommask = ss2[24:2];
    wire        s_dl      = ss2[1];
    wire        s_loaded  = ss2[0];

    // The reset request is a count in clk_74a; one flip-flop there gives the
    // synchroniser a single clean bit (a change of the Video setting now uses it).
    reg       rst_ok_74 = 1'b0;
    always @(posedge clk_74a) rst_ok_74 <= apf_reset_n && (reset_req == 8'd0);
    reg [2:0] rst_sync;
    always @(posedge clk_sys) rst_sync <= {rst_sync[1:0], rst_ok_74 && pll_locked};
    wire sys_reset_n = rst_sync[2];

    // =====================================================================
    // cartridge download into PSRAM (clk_sys)
    // =====================================================================
    wire        ld_we;
    wire [27:0] ld_addr;
    wire [15:0] ld_data;
    data_loader #(
        .ADDRESS_MASK_UPPER_4(4'h1),
        .ADDRESS_SIZE(28),
        // One PSRAM write takes 6 cycles; 8 per 16-bit word drains a bridge word
        // every 300 ns. The loader's FIFO is only 4 deep, so draining must keep
        // up with the bridge (tested down to a word every 280 ns in simulation).
        .WRITE_MEM_CLOCK_DELAY(8),
        .OUTPUT_WORD_SIZE(2)
    ) u_romload (
        .clk_74a(clk_74a), .clk_memory(clk_sys),
        .bridge_wr(bridge_wr), .bridge_endian_little(bridge_endian_little),
        .bridge_addr(bridge_addr), .bridge_wr_data(bridge_wr_data),
        .write_en(ld_we), .write_addr(ld_addr), .write_data(ld_data));

    // copier header: drop the first 512 bytes and shift the rest down
    reg hdr_skip_s1, hdr_skip_s2;
    always @(posedge clk_sys) begin hdr_skip_s1 <= hdr_skip; hdr_skip_s2 <= hdr_skip_s1; end
    wire [27:0] ld_off  = hdr_skip_s2 ? ld_addr - 28'd512 : ld_addr;
    wire        ld_keep = ld_we && !(hdr_skip_s2 && ld_addr < 28'd512) && ld_off < 28'h0400000;

    // The machine's BIOS reads the cartridge's header itself; the platform gives
    // it the System setting as its machine choice (Auto: none). System values:
    // 0 Auto, 1 Master System, 2 Game Gear, 3 MasterDrive, 4 SG-1000, 5 SC-3000.
    reg [2:0] plat_mode;
    always @* begin
        case (s_system)
            3'd2: plat_mode = 3'd1;
            3'd3: plat_mode = 3'd5;
            3'd4: plat_mode = 3'd2;
            3'd5: plat_mode = 3'd3;
            default: plat_mode = 3'd0;
        endcase
    end
    wire plat_auto = (s_system == 3'd0) || (s_system > 3'd5);

    // The boosts as Core Settings has them, for the machine (mdr_io keeps the
    // values in effect and the BIOS's): a value is taken once two samples in a
    // row agree, so a setting whose bits cross the synchroniser in different
    // clocks makes one change, and each change pulses the boost's BIOS index.
    // Sprites/line is one setting for two boosts (index 1, the limit, and 2, the
    // stock overflow flag), so it pulses both.
    wire [10:0] bset = {s_tmscol, s_ggfull, s_pstereo, s_afire, s_vboost, s_turbo, s_startp, s_spr};
    reg  [10:0] bset_d, b_ok, b_ok_d;
    always @(posedge clk_sys) begin
        bset_d <= bset;
        if (bset == bset_d) b_ok <= bset;
        b_ok_d <= b_ok;
    end
    wire [10:0] b_x = b_ok ^ b_ok_d;
    wire [8:0]  ael_chg = {b_x[10], b_x[9], b_x[8], b_x[7], b_x[6], |b_x[5:3], b_x[2],
                           {2{|b_x[1:0]}}};
    wire [1:0]  b_spr = b_ok[1:0];

    // =====================================================================
    // the machine
    // =====================================================================
    wire        m_reset = !sys_reset_n || s_dl || !s_loaded;
    // the TV standard is part of the machine: it changes only in reset. The machine
    // running is the machine's own (mdr_top: MasterDrive while the BIOS runs, then
    // the one it launches).
    reg         m_pal = 1'b0;
    always @(posedge clk_sys) if (m_reset) m_pal <= s_pal;
    wire [2:0]  mode;
    wire        ggwide_run;
    wire        rom_req;
    wire [23:0] rom_addr;
    reg         rom_ack;
    reg  [7:0]  rom_data;

    wire        sv_we;
    wire [14:0] sv_addr;
    wire [7:0]  sv_din, sv_dout;

    reg  [7:0]  pad1, pad2;
    reg         pause_btn;
    reg  [83:0] kb_keys;

    wire        vid_ce, vid_de, vid_hs, vid_vs, vid_frame;
    wire        cart_ram_we;
    wire [11:0] vid_bgr;
    wire signed [15:0] m_audio_l, m_audio_r;

    mdr_top u_machine (
        .clk_sys(clk_sys), .reset(m_reset),
        .plat_mode(plat_mode), .plat_auto(plat_auto),
        .plat_flags(8'b0001_0001 | {4'd0, m_pal, 3'd0}),   // a cartridge (the machine runs only with one), own menu, no USB
        .rom_log2(s_romlog2), .machines(6'b101111),         // no SF-7000 on this core
        .mapper(s_mapper), .pal(m_pal), .jp_region(s_region),
        .timing_gg(1'b1), .sc_ram32(s_scram32),
        .rom_mask(s_rommask), .card_present(1'b0), .card_mask(19'd0),
        .ael_sprlimit(b_spr != 2'd0), .ael_ovf_stock(b_spr == 2'd2), .ael_startpause(b_ok[2]),
        .ael_turbo(b_ok[5:3]), .ael_vramboost(b_ok[6]), .ael_autofire(b_ok[7]), .ael_pstereo(b_ok[8]),
        .ael_tmscol(b_ok[10]), .ael_ggwide(b_ok[9]), .ael_chg(ael_chg), .mode_run(mode), .ggwide_run(ggwide_run),
        .rom_req(rom_req), .rom_addr(rom_addr), .rom_ack(rom_ack), .rom_data(rom_data),
        .sv_clk(clk_sys), .sv_we(sv_we), .sv_addr(sv_addr), .sv_din(sv_din), .sv_dout(sv_dout),
        .pad1(pad1), .pad2(pad2), .pause_btn(pause_btn), .reset_btn(1'b0),
        .kb_keys(kb_keys), .kb_ghosting(s_ghost),
        .vid_ce(vid_ce), .vid_bgr(vid_bgr), .vid_de(vid_de), .vid_hs(vid_hs), .vid_vs(vid_vs),
        .vid_frame(vid_frame),
        .audio_l(m_audio_l), .audio_r(m_audio_r), .cart_ram_we(cart_ram_we),
        .dbg_m1(), .dbg_addr(), .dbg_cycles(), .dbg_fetch(), .dbg_op(), .dbg_sp(), .dbg_a(),
        .dbg_f(), .dbg_int_ack(), .dbg_line(), .dbg_hc(), .dbg_launch());

    // =====================================================================
    // PSRAM: downloads write, the machine reads
    // =====================================================================
    reg         ps_rd, ps_wr;
    reg  [21:0] ps_addr;
    reg         ps_bank;
    reg  [15:0] ps_din;
    wire [15:0] ps_dout;
    wire        ps_avail, ps_busy;

    psram #(.CLOCK_SPEED(53.693175)) u_psram (
        .clk(clk_sys),
        .bank_sel(ps_bank), .addr(ps_addr),
        .write_en(ps_wr), .data_in(ps_din), .write_high_byte(1'b1), .write_low_byte(1'b1),
        .read_en(ps_rd), .read_avail(ps_avail), .data_out(ps_dout), .busy(ps_busy),
        .cram_a(cram0_a), .cram_dq(cram0_dq), .cram_wait(cram0_wait), .cram_clk(cram0_clk),
        .cram_adv_n(cram0_adv_n), .cram_cre(cram0_cre), .cram_ce0_n(cram0_ce0_n),
        .cram_ce1_n(cram0_ce1_n), .cram_oe_n(cram0_oe_n), .cram_we_n(cram0_we_n),
        .cram_ub_n(cram0_ub_n), .cram_lb_n(cram0_lb_n));

    // A cartridge read beyond the loaded image (one that is not a power of two
    // long, inside the mask's mirror) wraps into the image, as the emulator's
    // address modulo the image's length does, never reaching what PSRAM still
    // holds there from an earlier cartridge: the BIOS's header search reads
    // $7FF0, $3FF0 and $1FF0 whatever the size. The masked address is below
    // twice the size for an image of 4 KB or more, so one subtraction does;
    // what is still beyond after it (a smaller image) answers $FF. Which value
    // the machine should give is open question Q39.
    wire [22:0] ra      = rom_addr[22:0];
    wire        ra_out  = !rom_addr[23] && ra >= s_romend;
    wire [22:0] ra_w    = ra_out ? ra - s_romend : ra;
    reg rom_req_d, rom_wait, rom_inflight, rom_lsb, rom_beyond;
    always @(posedge clk_sys) begin
        ps_rd <= 1'b0; ps_wr <= 1'b0; rom_ack <= 1'b0;
        rom_req_d <= rom_req;
        if (s_dl) begin
            rom_wait <= 1'b0; rom_inflight <= 1'b0;
            if (ld_keep) begin
                ps_wr <= 1'b1; ps_bank <= 1'b0; ps_addr <= ld_off[22:1]; ps_din <= ld_data;
            end
        end else begin
            if (rom_req && !rom_req_d) rom_wait <= 1'b1;
            if ((rom_wait || (rom_req && !rom_req_d)) && !rom_inflight && !ps_busy && !ps_rd) begin
                ps_rd <= 1'b1; ps_bank <= rom_addr[23]; ps_addr <= ra_w[22:1];
                rom_lsb <= ra_w[0];
                rom_beyond <= ra_out && ra_w >= s_romend;
                rom_wait <= 1'b0; rom_inflight <= 1'b1;
            end
            if (ps_avail && rom_inflight) begin
                rom_data <= rom_beyond ? 8'hFF : rom_lsb ? ps_dout[15:8] : ps_dout[7:0];
                rom_ack <= 1'b1;
                rom_inflight <= 1'b0;
            end
        end
    end

    // =====================================================================
    // cartridge RAM saves (bridge $2xxx_xxxx <-> machine save port)
    // =====================================================================
    wire        svl_we;
    wire [14:0] svl_addr;
    wire [7:0]  svl_data;
    data_loader #(
        .ADDRESS_MASK_UPPER_4(4'h2), .ADDRESS_SIZE(15),
        .WRITE_MEM_CLOCK_DELAY(4), .OUTPUT_WORD_SIZE(1)
    ) u_saveload (
        .clk_74a(clk_74a), .clk_memory(clk_sys),
        .bridge_wr(bridge_wr), .bridge_endian_little(bridge_endian_little),
        .bridge_addr(bridge_addr), .bridge_wr_data(bridge_wr_data),
        .write_en(svl_we), .write_addr(svl_addr), .write_data(svl_data));

    wire        svu_active;
    wire [14:0] svu_addr;
    mdr_save_unload u_saveunload (
        .clk_74a(clk_74a), .bridge_rd(bridge_rd), .bridge_endian_little(bridge_endian_little),
        .bridge_addr(bridge_addr), .bridge_rd_data(save_rd_data),
        .clk_sys(clk_sys), .rd_active(svu_active), .rd_addr(svu_addr), .rd_data(sv_dout));

    assign sv_we   = svl_we;
    assign sv_addr = svl_we ? svl_addr : svu_addr;
    assign sv_din  = svl_data;

    // A save file is worth writing back once one was loaded, or once the game
    // has written its cartridge RAM. Sticky across machine resets (a zero size
    // would truncate an existing save); cleared only by a new download.
    // SG-1000/SC-3000 cartridge RAM is not battery-backed and is not saved.
    reg ram_used;
    always @(posedge clk_sys) begin
        if (s_dl) ram_used <= 1'b0;
        else if (cart_ram_we && (mode == 3'd0 || mode == 3'd1 || mode == 3'd5)) ram_used <= 1'b1;
    end
    reg [1:0] ram_used_74;
    always @(posedge clk_74a) ram_used_74 <= {ram_used_74[0], ram_used};
    assign save_present = save_loaded || ram_used_74[1];

    // =====================================================================
    // controllers
    // =====================================================================
    // The Pocket's buttons are the console's Mega Drive pad in every mode:
    // A (east) = A, B (south) = B, Y (west) = C, Start = Start. Machine pad bits
    // {start, C, B, A, R, L, D, U}. In the stock modes the console reads A as
    // button 1 and B as button 2 (Technical Reference §6), so the same bits are
    // {start, C, button 2, button 1, ...} there; C only drives the auto-fire
    // boost. In MasterDrive mode software reads the pad as a Mega Drive pad (with
    // TH high, B and C are TL and TR). Start is the Game Gear's Start, and Pause
    // on SMS/SG/SC with the Start = Pause setting (on by default); Select = Pause.
    reg [31:0] k1_s1, k1, k2_s1, k2, k3_s1, k3, j3_s1, j3;
    reg [15:0] t3_s1, t3;
    always @(posedge clk_sys) begin
        k1_s1 <= cont1_key; k1 <= k1_s1;
        k2_s1 <= cont2_key; k2 <= k2_s1;
        k3_s1 <= cont3_key; k3 <= k3_s1;
        j3_s1 <= cont3_joy; j3 <= j3_s1;
        t3_s1 <= cont3_trig; t3 <= t3_s1;
    end
    // APF key bits: 0-3 up/down/left/right, 4 A, 5 B, 6 X, 7 Y, 14 Select, 15 Start
    function [7:0] padmap;
        input [31:0] k;
        padmap = (k[31:28] == 4'h4 || k[31:28] == 4'h5) ? 8'h00 :     // keyboard / mouse
                 {k[15], k[7], k[5], k[4], k[3], k[2], k[1], k[0]};
    endfunction
    wire kb_dock = (k3[31:28] == 4'h4);
    reg  f12;
    always @(posedge clk_sys) begin
        pad1 <= padmap(k1);
        pad2 <= padmap(k2);
        // Select = the console's Pause button (NMI). The Game Gear has none, so
        // not in GG mode. Start -> Pause is the machine's enhancement-layer option.
        pause_btn <= (k1[14] || f12) && (mode != 3'd1);
    end

    // ------------------------------------------------------------ keyboard
    // USB HID usage -> SK-1100 matrix {valid, row[2:0], column[3:0]};
    // columns 0-7 are PPI port A bits 0-7, 8-11 port B bits 0-3.
    function [7:0] hid2sk;
        input [7:0] u;
        case (u)
            8'h1E: hid2sk = {1'b1, 3'd0, 4'd0};  // 1
            8'h14: hid2sk = {1'b1, 3'd0, 4'd1};  // q
            8'h04: hid2sk = {1'b1, 3'd0, 4'd2};  // a
            8'h1D: hid2sk = {1'b1, 3'd0, 4'd3};  // z
            8'h3B: hid2sk = {1'b1, 3'd0, 4'd4};  // F2 -> ENG/DIERS
            8'h36: hid2sk = {1'b1, 3'd0, 4'd5};  // ,
            8'h0E: hid2sk = {1'b1, 3'd0, 4'd6};  // k
            8'h0C: hid2sk = {1'b1, 3'd0, 4'd7};  // i
            8'h25: hid2sk = {1'b1, 3'd0, 4'd8};  // 8
            8'h1F: hid2sk = {1'b1, 3'd1, 4'd0};  // 2
            8'h1A: hid2sk = {1'b1, 3'd1, 4'd1};  // w
            8'h16: hid2sk = {1'b1, 3'd1, 4'd2};  // s
            8'h1B: hid2sk = {1'b1, 3'd1, 4'd3};  // x
            8'h2C: hid2sk = {1'b1, 3'd1, 4'd4};  // space
            8'h37: hid2sk = {1'b1, 3'd1, 4'd5};  // .
            8'h0F: hid2sk = {1'b1, 3'd1, 4'd6};  // l
            8'h12: hid2sk = {1'b1, 3'd1, 4'd7};  // o
            8'h26: hid2sk = {1'b1, 3'd1, 4'd8};  // 9
            8'h20: hid2sk = {1'b1, 3'd2, 4'd0};  // 3
            8'h08: hid2sk = {1'b1, 3'd2, 4'd1};  // e
            8'h07: hid2sk = {1'b1, 3'd2, 4'd2};  // d
            8'h06: hid2sk = {1'b1, 3'd2, 4'd3};  // c
            8'h4A: hid2sk = {1'b1, 3'd2, 4'd4};  // Home -> HOME/CLR
            8'h38: hid2sk = {1'b1, 3'd2, 4'd5};  // /
            8'h33: hid2sk = {1'b1, 3'd2, 4'd6};  // ;
            8'h13: hid2sk = {1'b1, 3'd2, 4'd7};  // p
            8'h27: hid2sk = {1'b1, 3'd2, 4'd8};  // 0
            8'h21: hid2sk = {1'b1, 3'd3, 4'd0};  // 4
            8'h15: hid2sk = {1'b1, 3'd3, 4'd1};  // r
            8'h09: hid2sk = {1'b1, 3'd3, 4'd2};  // f
            8'h19: hid2sk = {1'b1, 3'd3, 4'd3};  // v
            8'h49, 8'h4C, 8'h2A:
                   hid2sk = {1'b1, 3'd3, 4'd4};  // Insert / Delete / Backspace -> INS/DEL
            8'h3C: hid2sk = {1'b1, 3'd3, 4'd5};  // F3 -> PI
            8'h34: hid2sk = {1'b1, 3'd3, 4'd6};  // ' -> :
            8'h35: hid2sk = {1'b1, 3'd3, 4'd7};  // ` -> @
            8'h2D: hid2sk = {1'b1, 3'd3, 4'd8};  // -
            8'h22: hid2sk = {1'b1, 3'd4, 4'd0};  // 5
            8'h17: hid2sk = {1'b1, 3'd4, 4'd1};  // t
            8'h0A: hid2sk = {1'b1, 3'd4, 4'd2};  // g
            8'h05: hid2sk = {1'b1, 3'd4, 4'd3};  // b
            8'h51: hid2sk = {1'b1, 3'd4, 4'd5};  // Down
            8'h30: hid2sk = {1'b1, 3'd4, 4'd6};  // ]
            8'h2F: hid2sk = {1'b1, 3'd4, 4'd7};  // [
            8'h2E: hid2sk = {1'b1, 3'd4, 4'd8};  // = -> ^
            8'h23: hid2sk = {1'b1, 3'd5, 4'd0};  // 6
            8'h1C: hid2sk = {1'b1, 3'd5, 4'd1};  // y
            8'h0B: hid2sk = {1'b1, 3'd5, 4'd2};  // h
            8'h11: hid2sk = {1'b1, 3'd5, 4'd3};  // n
            8'h50: hid2sk = {1'b1, 3'd5, 4'd5};  // Left
            8'h28: hid2sk = {1'b1, 3'd5, 4'd6};  // Enter -> CR
            8'h31: hid2sk = {1'b1, 3'd5, 4'd8};  // \ -> YEN
            8'h3A: hid2sk = {1'b1, 3'd5, 4'd11}; // F1 -> FUNC
            8'h24: hid2sk = {1'b1, 3'd6, 4'd0};  // 7
            8'h18: hid2sk = {1'b1, 3'd6, 4'd1};  // u
            8'h0D: hid2sk = {1'b1, 3'd6, 4'd2};  // j
            8'h10: hid2sk = {1'b1, 3'd6, 4'd3};  // m
            8'h4F: hid2sk = {1'b1, 3'd6, 4'd5};  // Right
            8'h52: hid2sk = {1'b1, 3'd6, 4'd6};  // Up
            8'h29: hid2sk = {1'b1, 3'd6, 4'd8};  // Esc -> BREAK
            8'h2B: hid2sk = {1'b1, 3'd6, 4'd9};  // Tab -> GRAPH
            default: hid2sk = 8'h00;
        endcase
    endfunction

    // Scan codes 1-4 in cont3_joy[31:0], 5-6 in cont3_trig[15:0]; modifiers in
    // cont3_key[15:0], little-endian bytes: bit 0 LCtrl, 1 LShift, 4 RCtrl, 5 RShift.
    wire [7:0] sc0 = j3[31:24], sc1 = j3[23:16], sc2 = j3[15:8], sc3 = j3[7:0];
    wire [7:0] sc4 = t3[15:8],  sc5 = t3[7:0];
    wire [15:0] mods = {k3[7:0], k3[15:8]};
    integer kr;
    reg [83:0] kb_next;
    reg [7:0]  m0, m1, m2, m3, m4, m5;
    always @* begin
        kb_next = 84'd0;
        m0 = hid2sk(sc0); m1 = hid2sk(sc1); m2 = hid2sk(sc2);
        m3 = hid2sk(sc3); m4 = hid2sk(sc4); m5 = hid2sk(sc5);
        if (kb_dock) begin
            if (m0[7]) kb_next[m0[6:4]*12 + m0[3:0]] = 1'b1;
            if (m1[7]) kb_next[m1[6:4]*12 + m1[3:0]] = 1'b1;
            if (m2[7]) kb_next[m2[6:4]*12 + m2[3:0]] = 1'b1;
            if (m3[7]) kb_next[m3[6:4]*12 + m3[3:0]] = 1'b1;
            if (m4[7]) kb_next[m4[6:4]*12 + m4[3:0]] = 1'b1;
            if (m5[7]) kb_next[m5[6:4]*12 + m5[3:0]] = 1'b1;
            if (mods[0] || mods[4]) kb_next[6*12 + 10] = 1'b1;   // CTRL
            if (mods[1] || mods[5]) kb_next[6*12 + 11] = 1'b1;   // SHIFT
        end
    end
    always @(posedge clk_sys) begin
        kb_keys <= kb_next;
        // F12 is the SK-1100 RESET key, which raises NMI rather than sitting in the matrix
        f12 <= kb_dock && (sc0 == 8'h45 || sc1 == 8'h45 || sc2 == 8'h45 ||
                           sc3 == 8'h45 || sc4 == 8'h45 || sc5 == 8'h45);
    end

    // =====================================================================
    // video: into the pixel clock domain
    // =====================================================================
    // clk_vid is clk_sys / 10 from the same PLL. The machine's video registers
    // change once per 10 clk_sys cycles (on vid_ce, which PAL never holds), so
    // every clk_sys -> clk_vid path has at least one clk_sys period; the two
    // clocks are constrained as related, not asynchronous (core_constraints.sdc).
    // A PAL line is 345 or 346 pixel clocks (mdr_top: machine time is held one
    // clock in 109.63); the scaler sees regular DE, HS and VS otherwise.
    reg [11:0] v_bgr;
    reg        v_de, v_hs, v_vs;
    always @(posedge clk_vid) begin
        v_bgr <= vid_bgr; v_de <= vid_de; v_hs <= vid_hs; v_vs <= vid_vs;
    end

    // scaler slot: 0 = 256x192, 1 = 256x224, 2 = 256x240, 3 = 160x144 (video.json)
    reg [8:0] lines, lines_last;
    reg       de_d;
    reg [2:0] slot;
    // the Game Gear window: from the machine running and its uncrop boost (clk_sys)
    reg       gg_win_sys = 1'b0;
    reg [1:0] gg_win_v = 2'b00;
    always @(posedge clk_sys) gg_win_sys <= (mode == 3'd1) && !ggwide_run;
    always @(posedge clk_vid) gg_win_v <= {gg_win_v[0], gg_win_sys};
    wire      gg_window = gg_win_v[1];
    always @(posedge clk_vid) begin
        de_d <= v_de;
        if (v_vs) begin lines_last <= lines; lines <= 9'd0; end
        else if (v_de && !de_d) lines <= lines + 9'd1;
        slot <= gg_window ? 3'd3 : (lines_last > 9'd232) ? 3'd2 : (lines_last > 9'd208) ? 3'd1 : 3'd0;
    end

    always @(posedge clk_vid) begin
        video_de <= v_de;
        video_hs <= v_hs;
        video_vs <= v_vs;
        if (v_de)
            video_rgb <= {v_bgr[3:0], v_bgr[3:0], v_bgr[7:4], v_bgr[7:4], v_bgr[11:8], v_bgr[11:8]};
        else if (de_d)
            video_rgb <= {8'h00, slot, 13'h0000};   // end-of-line word: set scaler slot
        else
            video_rgb <= 24'h000000;
    end
    assign video_skip = 1'b0;

    // =====================================================================
    // audio: two one-pole low-pass stages before the I2S sampler picks
    // 48 kHz samples. Updated at clk_sys/16 = 3.36 MHz; a shift of 4 puts each
    // pole near 33 kHz (about 21 kHz for the pair). Not a full decimation
    // filter: PSG tones above ~24 kHz still alias, attenuated by ~10 dB.
    // =====================================================================
    reg  [3:0] adiv;
    reg  signed [19:0] l1, l2, r1, r2;
    wire signed [19:0] in_l = {{2{m_audio_l[15]}}, m_audio_l, 2'b00};
    wire signed [19:0] in_r = {{2{m_audio_r[15]}}, m_audio_r, 2'b00};
    always @(posedge clk_sys) begin
        adiv <= adiv + 4'd1;
        if (adiv == 4'd0) begin
            l1 <= l1 + ((in_l - l1) >>> 4);
            l2 <= l2 + ((l1 - l2) >>> 4);
            r1 <= r1 + ((in_r - r1) >>> 4);
            r2 <= r2 + ((r1 - r2) >>> 4);
        end
        audio_l <= l2[17:2];
        audio_r <= r2[17:2];
    end

endmodule

`default_nettype wire
