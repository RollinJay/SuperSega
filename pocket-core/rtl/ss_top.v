// Super Sega - machine top level (platform independent)
//
// Everything here is the machine; the platform (Analogue Pocket, simulation)
// supplies the 53.693175 MHz system clock, ROM storage on a request/acknowledge
// bus, controller state, and takes video and audio out.
//
//   clocks   all logic runs on clk_sys with clock enables:
//            base cycle 3.579545 MHz = sys/15 (VDP timing, PSG = base/16)
//            CPU 100/125/150/175/200 % of base (turbo, Super Sega only)
//            pixel 5.369318 MHz = sys/10
//   bus sync at turbo steps above 100 % the CPU is held on VDP port accesses
//            until the VDP's next access slot: 16 base cycles in blanking,
//            29 in active display (machine profile, official Sega figures)
`default_nettype none

module ss_top #(
    // The FM unit is part of the machine, but milestone 1 has no YM2413 core.
    // While FM_FITTED is 0 the $F2 detection latch does not answer, so software
    // that probes for FM falls back to its PSG music instead of playing silence.
    parameter FM_FITTED = 0
) (
    input  wire        clk_sys,
    input  wire        reset,
    input  wire [2:0]  mode,           // 0 SMS, 1 GG, 2 SG-1000, 3 SC-3000, 5 Super Sega
    input  wire [1:0]  mapper,
    input  wire        pal,
    input  wire        jp_region,
    input  wire        timing_gg,      // VDP event table: 1 = 315-5535
    input  wire        sc_ram32,
    input  wire [22:0] rom_mask,
    input  wire        card_present,
    input  wire [18:0] card_mask,
    input  wire        gg_crop,
    // Enhancement layer (machine profile, AEL). All off = stock behaviour. Each
    // boost acts only on software in the stock modes (SG-1000, SC-3000, Master
    // System, Game Gear); Super Sega software sets these features itself.
    input  wire        ael_sprlimit,   // 16 sprites per line in Mode 4
    input  wire        ael_ovf_stock,  // ... but the overflow flag still reports the 9th sprite
    input  wire        ael_startpause, // Start raises Pause (SMS, SG-1000, SC-3000)
    input  wire [2:0]  ael_turbo,      // turbo step for stock software (not Super Sega mode)
    input  wire        ael_vramboost,  // no VDP access wait at turbo
    input  wire        ael_autofire,   // C held repeats button 2 (stock modes)
    input  wire        ael_pstereo,    // pseudo-stereo PSG until software writes $06 (stock modes)

    // ROM bus
    output wire        rom_req,
    output wire [23:0] rom_addr,
    input  wire        rom_ack,
    input  wire [7:0]  rom_data,

    // cartridge RAM (saves)
    input  wire        sv_clk,
    input  wire        sv_we,
    input  wire [14:0] sv_addr,
    input  wire [7:0]  sv_din,
    output wire [7:0]  sv_dout,

    // controls: {start, c, b, a, right, left, down, up}
    input  wire [7:0]  pad1,
    input  wire [7:0]  pad2,
    input  wire        pause_btn,
    input  wire        reset_btn,
    input  wire [83:0] kb_keys,
    input  wire        kb_ghosting,

    // video (clk_sys domain, one pixel per vid_ce)
    output wire        vid_ce,
    output wire [11:0] vid_bgr,
    output wire        vid_de,
    output wire        vid_hs,
    output wire        vid_vs,
    output wire        vid_frame,

    // audio
    output reg  signed [15:0] audio_l,
    output reg  signed [15:0] audio_r,

    // cartridge RAM written (platform: decides whether a save file is needed)
    output wire        cart_ram_we,

    // debug
    output wire        dbg_m1,         // pulse: instruction (or prefix) fetch starts
    output wire [15:0] dbg_addr,
    output wire [31:0] dbg_cycles,     // base cycles since reset
    output wire        dbg_fetch,
    output wire [7:0]  dbg_op,
    output wire [15:0] dbg_sp,
    output wire [7:0]  dbg_a,
    output wire [7:0]  dbg_f,
    output wire        dbg_int_ack,
    output wire [8:0]  dbg_line,
    output wire [7:0]  dbg_hc
);
    localparam M_SS = 3'd5;
    wire ss = (mode == M_SS);

    // ------------------------------------------------------------ clock enables
    reg  [3:0]  div15;
    reg  [3:0]  div10;
    reg  [3:0]  div16;
    reg  [10:0] tacc;
    reg  [31:0] cycles;
    wire        ce_base = (div15 == 4'd0);
    wire        ce_pix  = (div10 == 4'd0);
    wire        ce_psg  = ce_base && (div16 == 4'd0);
    wire [2:0]  turbo_step;
    // Super Sega software sets its own step ($F3); the enhancement layer's step
    // applies to stock software only, since explicit software intent wins.
    wire [2:0]  step_eff = ss ? turbo_step : ael_turbo;
    wire [7:0]  turbo_rate = (step_eff == 3'd1) ? 8'd125 : (step_eff == 3'd2) ? 8'd150 :
                             (step_eff == 3'd3) ? 8'd175 : (step_eff == 3'd4) ? 8'd200 : 8'd100;
    wire        turbo_on = (step_eff != 3'd0);
    wire [10:0] tacc_next = tacc + {3'd0, turbo_rate};
    wire        ce_turbo = (tacc_next >= 11'd1500);
    wire        ce_cpu = turbo_on ? ce_turbo : ce_base;

    always @(posedge clk_sys) begin
        if (reset) begin
            div15 <= 4'd0; div10 <= 4'd0; div16 <= 4'd0; tacc <= 11'd0; cycles <= 32'd0;
        end else begin
            div15 <= (div15 == 4'd14) ? 4'd0 : div15 + 4'd1;
            div10 <= (div10 == 4'd9) ? 4'd0 : div10 + 4'd1;
            if (ce_base) begin
                div16 <= div16 + 4'd1;
                cycles <= cycles + 32'd1;
            end
            tacc <= ce_turbo ? tacc_next - 11'd1500 : tacc_next;
        end
    end
    assign dbg_cycles = cycles;

    // ------------------------------------------------------------ CPU
    wire [15:0] a;
    wire [7:0]  cpu_dout;
    reg  [7:0]  cpu_din;
    wire        mreq_n, iorq_n, rd_n, wr_n, m1_n, rfsh_n, halt_n;
    wire        mem_rd_start, mem_wr_start, io_sample, io_cycle, io_write, int_ack;
    wire        mem_wait_n, sync_wait_n;
    wire        int_n;
    reg         nmi_n;

    ss_z80 u_cpu (
        .clk(clk_sys), .reset_n(~reset), .cen(ce_cpu),
        .wait_n(mem_wait_n && sync_wait_n), .int_n(int_n), .nmi_n(nmi_n),
        .a(a), .dout(cpu_dout), .din(cpu_din),
        .mreq_n(mreq_n), .iorq_n(iorq_n), .rd_n(rd_n), .wr_n(wr_n),
        .m1_n(m1_n), .rfsh_n(rfsh_n), .halt_n(halt_n),
        .mem_rd_start(mem_rd_start), .mem_wr_start(mem_wr_start),
        .io_sample(io_sample), .io_cycle(io_cycle), .io_write(io_write), .int_ack(int_ack),
        .dbg_fetch(dbg_fetch), .dbg_op(dbg_op), .dbg_sp(dbg_sp), .dbg_a(dbg_a), .dbg_f(dbg_f));
    assign dbg_int_ack = int_ack;

    reg m1_d;
    always @(posedge clk_sys) m1_d <= m1_n;
    assign dbg_m1 = m1_d && !m1_n;
    assign dbg_addr = a;

    // Pause: NMI on press (machine Pause button, or Start through the enhancement
    // layer in the modes whose controllers have no Start: SMS, SG-1000, SC-3000)
    wire pause_any = pause_btn || (ael_startpause && pad1[7] &&
                                   (mode == 3'd0 || mode == 3'd2 || mode == 3'd3));
    always @(posedge clk_sys) begin
        if (reset) nmi_n <= 1'b1;
        else nmi_n <= ~pause_any;
    end

    // ------------------------------------------------------------ memory
    wire [7:0]  mem_rdata;
    wire [7:0]  mem_ctl, io_ctl, slot_sel;
    wire [3:0]  wram_bank;
    wire [4:0]  card_bank;
    ss_mem u_mem (
        .clk(clk_sys), .rst(reset), .mode(mode), .mapper(mapper), .sc_ram32(sc_ram32),
        .rom_mask(rom_mask), .card_present(card_present), .card_mask(card_mask),
        .a(a), .dout(cpu_dout), .mreq_n(mreq_n), .rd_n(rd_n), .wr_n(wr_n),
        .rd_start(mem_rd_start), .rdata(mem_rdata), .wait_n(mem_wait_n),
        .mem_ctl(mem_ctl), .wram_bank(wram_bank), .slot_sel(slot_sel), .card_bank(card_bank),
        .rom_req(rom_req), .rom_addr(rom_addr), .rom_ack(rom_ack), .rom_data(rom_data),
        .sv_clk(sv_clk), .sv_we(sv_we), .sv_addr(sv_addr), .sv_din(sv_din), .sv_dout(sv_dout),
        .page0(), .page1(), .page2(), .ram_sel(), .cram_we(cart_ram_we));

    // ------------------------------------------------------------ I/O
    wire [7:0]  io_rdata, vdp_rdata;
    wire        vdp_rd, vdp_wr, th_latch, psg_wr, stereo_wr, fm_wr, fm_addr, pcm_wr;
    wire [1:0]  fm_ctl;
    wire [7:0]  pcm_ctl;
    wire [7:0]  vdp_fea, vdp_fec;
    wire        vdp_active;
    // Auto-fire (enhancement layer): while C is held, button 2 toggles every two
    // frames (15 Hz at 60 Hz). Stock modes only: Super Sega software reads C as
    // a button of its own.
    reg [1:0] af_cnt;
    always @(posedge clk_sys) begin
        if (reset) af_cnt <= 2'd0;
        else if (vid_vs && vid_ce) af_cnt <= af_cnt + 2'd1;
    end
    wire af_on = ael_autofire && !ss;
    wire [7:0] pad1_eff = (af_on && pad1[6]) ? {pad1[7:6], af_cnt[1], pad1[4:0]} : pad1;
    wire [7:0] pad2_eff = (af_on && pad2[6]) ? {pad2[7:6], af_cnt[1], pad2[4:0]} : pad2;

    ss_io u_io (
        .clk(clk_sys), .rst(reset), .mode(mode), .jp_region(jp_region),
        .fm_present(FM_FITTED != 0 && (mode == 3'd0 || ss)),   // SMS and Super Sega modes only
        .io_sample(io_sample), .io_write(io_write), .port(a[7:0]), .wdata(cpu_dout), .rdata(io_rdata),
        .vdp_rdata(vdp_rdata), .vdp_rd(vdp_rd), .vdp_wr(vdp_wr), .vdp_fea(vdp_fea), .vdp_fec(vdp_fec),
        .th_latch(th_latch),
        .psg_wr(psg_wr), .stereo_wr(stereo_wr), .fm_wr(fm_wr), .fm_addr(fm_addr), .fm_ctl(fm_ctl),
        .mem_ctl(mem_ctl), .io_ctl(io_ctl), .wram_bank(wram_bank), .slot_sel(slot_sel),
        .card_bank(card_bank), .turbo_step(turbo_step), .pcm_ctl(pcm_ctl), .pcm_wr(pcm_wr),
        .pcm_fill(7'd0),
        .pad1(pad1_eff), .pad2(pad2_eff), .reset_btn(reset_btn), .kb_keys(kb_keys), .kb_ghosting(kb_ghosting));

    // CPU data in
    always @* begin
        if (int_ack) cpu_din = 8'hFF;
        else if (!iorq_n || io_cycle) cpu_din = io_rdata;
        else cpu_din = mem_rdata;
    end

    // ------------------------------------------------------------ VDP
    ss_vdp u_vdp (
        .clk(clk_sys), .rst(reset), .ce_cyc(ce_base),
        .gg_mode(mode == 3'd1), .ss_mode(ss), .pal(pal), .timing_gg(timing_gg),
        // boosts are for stock software: Super Sega software sets these itself
        .no_spr_limit(ael_sprlimit && !ss), .ovf_stock(ael_ovf_stock && !ss),
        .io_rd(vdp_rd), .io_wr(vdp_wr), .io_port(a[7:0]), .io_din(cpu_dout), .io_dout(vdp_rdata),
        .th_latch(th_latch), .int_n(int_n),
        .ce_pix(ce_pix), .vid_rgb(vid_bgr), .vid_de(vid_de), .vid_hs(vid_hs), .vid_vs(vid_vs),
        .vid_frame(vid_frame), .gg_crop(gg_crop),
        .out_fea(vdp_fea), .out_fec(vdp_fec), .out_active(vdp_active),
        .dbg_line(dbg_line), .dbg_hc(dbg_hc), .dbg_status());
    assign vid_ce = ce_pix;

    // ------------------------------------------------------------ bus synchroniser
    // Count base cycles since the last VDP port access; at turbo, an access that
    // comes sooner than the VDP's slot is held until the slot.
    reg  [5:0] since_vdp;
    wire [5:0] slot = vdp_active ? 6'd29 : 6'd16;
    wire       vdp_port_cycle = io_cycle && (a[7:6] == 2'b10);
    assign sync_wait_n = !(turbo_on && !(ael_vramboost && !ss) && vdp_port_cycle && since_vdp < slot);
    always @(posedge clk_sys) begin
        if (reset) since_vdp <= 6'd63;
        else if (io_sample && a[7:6] == 2'b10) since_vdp <= 6'd0;
        else if (ce_base && since_vdp != 6'd63) since_vdp <= since_vdp + 6'd1;
    end

    // ------------------------------------------------------------ audio
    wire signed [15:0] psg_l, psg_r;
    ss_psg u_psg (
        .clk(clk_sys), .rst(reset), .ce_psg(ce_psg), .wr(psg_wr), .din(cpu_dout),
        .stereo_wr(stereo_wr), .stereo_din(cpu_dout), .pstereo(ael_pstereo && !ss),
        .out_l(psg_l), .out_r(psg_r));
    // FM: not in this milestone. A Japanese-SMS FM unit mutes the PSG when bit 0
    // of $F2 is set; with no FM core yet the PSG stays audible.
    always @(posedge clk_sys) begin
        audio_l <= psg_l;
        audio_r <= psg_r;
    end

endmodule

`default_nettype wire
