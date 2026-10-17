// MasterDrive - machine top level (platform independent)
//
// Everything here is the machine; the platform (Analogue Pocket, simulation)
// supplies the 53.693175 MHz system clock, ROM storage on a request/acknowledge
// bus, controller state, and takes video and audio out.
//
//   clocks   all logic runs on clk_sys with clock enables:
//            base cycle 3.579545 MHz = sys/15 (VDP timing, PSG = base/16,
//            YM2413 master clock); in PAL 3.546893 MHz, machine time being
//            held for one clk_sys in every 109.63
//            CPU 100/125/150/175/200 % of base (turbo: MasterDrive software's
//            $F3, or the enhancement layer's step for stock software)
//            pixel 5.369318 MHz = sys/10, never held
//   bus sync at turbo steps above 100 % the CPU is held on VDP port accesses
//            until the VDP's next access slot: 16 base cycles in blanking,
//            29 in active display (machine profile, official Sega figures),
//            and on FM writes until the YM2413 can take them
//   start-up a cold reset (reset) starts the machine in MasterDrive mode with the
//            BIOS ROM mapped ($3E = $E0). The BIOS launches the game with $A5 at
//            $1F: the CPU is held, and after the VDP's wrap to line 0 every block
//            but the pixel divider and the VDP's output stage is reset
//            (launch_rst) into the machine in the BIOS's setting 0, with $3E =
//            $A8 and the boosts the BIOS left for the launch (Technical
//            Reference section 20)
`default_nettype none

module mdr_top #(
    // The FM unit is part of the machine (a YM2413, IKAOPLL here). FM_FITTED = 0
    // leaves it out: the $F2 detection latch then does not answer, so software
    // that probes for FM falls back to its PSG music instead of playing silence.
    parameter FM_FITTED = 1,
    parameter PAL_LINE_LOCK = 0
) (
    input  wire        clk_sys,
    input  wire        reset,          // a cold reset: the BIOS runs
    // The platform's information for the BIOS (its settings 16-21). Machine codes:
    // 0 SMS, 1 GG, 2 SG-1000, 3 SC-3000, 4 SF-7000, 5 MasterDrive.
    input  wire [2:0]  plat_mode,      // the platform's machine choice ...
    input  wire        plat_auto,      // ... or none (Auto)
    input  wire [7:0]  plat_flags,     // b0 cartridge, b1 card, b2 USB, b3 PAL, b4 own settings menu
    input  wire [4:0]  rom_log2,       // the cartridge's size, log2 rounded up; 0 unknown
    input  wire [5:0]  machines,       // the machines the platform runs, a bit each
    input  wire [1:0]  mapper,
    input  wire        pal,
    input  wire        jp_region,
    input  wire        timing_gg,      // VDP event table: 1 = 315-5535
    input  wire        sc_ram32,
    input  wire [22:0] rom_mask,
    input  wire        card_present,
    input  wire [18:0] card_mask,
    // Enhancement layer (machine profile, AEL), as the platform's own menu sets the
    // boosts; the machine keeps the values in effect, which the BIOS can change
    // for its launch (mdr_io: the last change wins). All off = stock behaviour. Each
    // boost acts only on software in the stock modes (SG-1000, SC-3000, Master
    // System, Game Gear); MasterDrive software sets these features itself. The
    // exception is ael_tmscol, on by default, which also acts on MasterDrive
    // software's TMS modes (open question Q11, decided).
    input  wire        ael_sprlimit,   // 16 sprites per line in Mode 4
    input  wire        ael_ovf_stock,  // ... but the overflow flag still reports the 9th sprite
    input  wire        ael_startpause, // Start raises Pause (SMS, SG-1000, SC-3000)
    input  wire [2:0]  ael_turbo,      // turbo step for stock software (not MasterDrive mode)
    input  wire        ael_vramboost,  // no VDP access wait at turbo
    input  wire        ael_autofire,   // C held repeats button 2 (stock modes)
    input  wire        ael_pstereo,    // pseudo-stereo PSG until software writes $06 (stock modes)
    input  wire        ael_tmscol,     // true TMS9918 colours in the TMS modes, not the SMS approximation
                                       // (on by default; it also acts on MasterDrive software's TMS modes)
    input  wire        ael_ggwide,     // Game Gear uncrop: the full 256 x 192 picture in Game Gear mode
    input  wire [8:0]  ael_chg,        // a pulse when the platform's menu changes a boost (its BIOS
                                       // setting index 1-9 = bit 0-8; one setting may pulse several)
    output wire [2:0]  mode_run,       // the machine running (MasterDrive while the BIOS runs)
    output wire        ggwide_run,     // Game Gear uncrop as in effect

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
    output wire [7:0]  dbg_hc,
    output wire        dbg_launch      // the clock of the launch reset
);
    localparam M_SS = 3'd5;

    // ------------------------------------------------------------ start-up and launch
    // mode: the machine running. A cold reset starts MasterDrive mode (the BIOS);
    // the launch starts the machine in the BIOS's setting 0. The base cycle in
    // which the VDP wraps from its last line to line 0 (hc 227) arms the launch;
    // launch_rst then resets every block in the clock before the next base
    // cycle, so the clock after it is the first clock after a cold reset: a
    // base cycle with the turbo accumulator at 0, the VDP at line 0, cycle 0,
    // where it already is. The pixel divider and the VDP's output stage keep
    // their pace, so the platform sees regular video.
    reg  [2:0]  mode = M_SS;
    reg         launch_pend = 1'b0, launch_arm = 1'b0, launch_rst = 1'b0;
    reg         boot_run = 1'b1;        // the BIOS runs: from a cold reset to the launch
    wire        mreset = reset || launch_rst;
    wire        launch_req;
    wire [2:0]  boot_mode;
    wire [10:0] boost;
    assign mode_run = mode;
    assign dbg_launch = launch_rst;
    // the boosts in effect (setting index order, mdr_io)
    wire        b_sprlimit = boost[0], b_ovf = boost[1], b_startpause = boost[2];
    wire [2:0]  b_turbo = boost[5:3];
    wire        b_vramboost = boost[6], b_autofire = boost[7], b_pstereo = boost[8];
    wire        b_ggwide = boost[9], b_tmscol = boost[10];
    assign ggwide_run = b_ggwide;
    wire        gg_crop = (mode == 3'd1) && !b_ggwide;
    wire ss = (mode == M_SS);
    wire fm_here = FM_FITTED != 0 && (mode == 3'd0 || ss);   // the FM unit: SMS and MasterDrive modes

    // ------------------------------------------------------------ clock enables
    // Machine time. NTSC: every clk_sys is a machine clock and the base cycle is
    // clk_sys / 15 = 3.579545 MHz. PAL: machine time stands still for one clk_sys
    // in every 109.63 (32652 in 3579545, the difference of the two base clocks
    // over the NTSC one), so the machine runs on 15 x 3.546893 MHz on average.
    // Every base cycle is then 15 or 16 clk_sys, 3.546893 MHz on average with no
    // drift, and everything that counts base cycles or machine clocks (CPU and
    // turbo, VDP timing, PSG, FM chip, bus synchroniser) runs at the PAL clock.
    // The pixel enable is NOT held: pixels leave at clk_sys / 10, in step with
    // the platform's fixed pixel clock, and the VDP starts each output line at
    // its own line start, so a PAL line is 345 or 346 pixel clocks long.
    // PAL_LINE_LOCK = 1 holds one clock in 115 instead: every PAL line is then
    // exactly 345 pixel clocks, and the base clock 430 ppm fast.
    localparam [21:0] PAL_ADD = (PAL_LINE_LOCK != 0) ? 22'd1   : 22'd32652;
    localparam [21:0] PAL_MOD = (PAL_LINE_LOCK != 0) ? 22'd115 : 22'd3579545;
    reg  [21:0] pacc = 22'd0;
    reg         hold = 1'b0;           // this clk_sys is not a machine clock
    wire [22:0] pacc_next = {1'b0, pacc} + {1'b0, PAL_ADD};
    always @(posedge clk_sys) begin
        if (mreset || !pal) begin
            pacc <= 22'd0; hold <= 1'b0;
        end else if (pacc_next >= {1'b0, PAL_MOD}) begin
            pacc <= pacc_next[21:0] - PAL_MOD; hold <= 1'b1;
        end else begin
            pacc <= pacc_next[21:0]; hold <= 1'b0;
        end
    end

    reg  [3:0]  div15;
    reg  [3:0]  div10;
    reg  [3:0]  div16;
    reg  [10:0] tacc;
    reg  [31:0] cycles;
    wire        ce_base = !hold && (div15 == 4'd0);
    wire        ce_pix  = (div10 == 4'd0);
    wire        ce_psg  = ce_base && (div16 == 4'd0);
    wire [2:0]  turbo_step;
    // MasterDrive software sets its own step ($F3); the enhancement layer's step
    // applies to stock software only, since explicit software intent wins.
    wire [2:0]  step_eff = ss ? turbo_step : b_turbo;
    wire [7:0]  turbo_rate = (step_eff == 3'd1) ? 8'd125 : (step_eff == 3'd2) ? 8'd150 :
                             (step_eff == 3'd3) ? 8'd175 : (step_eff == 3'd4) ? 8'd200 : 8'd100;
    wire        turbo_on = (step_eff != 3'd0);
    wire [10:0] tacc_next = tacc + {3'd0, turbo_rate};
    wire        ce_turbo = !hold && (tacc_next >= 11'd1500);
    // Two CPU enables are never on consecutive clocks (they can meet only when
    // the turbo step changes), so every CPU register path has at least two
    // clocks; core_constraints.sdc relies on this. None comes in a reset clock,
    // so the first clock after any reset is free to take one.
    reg         ce_cpu_d = 1'b0;
    wire        ce_cpu = (turbo_on ? ce_turbo : ce_base) && !ce_cpu_d && !mreset;
    always @(posedge clk_sys) ce_cpu_d <= ce_cpu;

    // The launch resets everything here as a cold reset does but the pixel
    // divider, which keeps the platform's pixel clock (it comes in the clock
    // before a base cycle, so the base divider takes the value it would anyway)
    always @(posedge clk_sys) begin
        if (reset) div10 <= 4'd0;
        else div10 <= (div10 == 4'd9) ? 4'd0 : div10 + 4'd1;
        if (mreset) begin
            div15 <= 4'd0; div16 <= 4'd0; tacc <= 11'd0; cycles <= 32'd0;
        end else begin
            if (!hold) div15 <= (div15 == 4'd14) ? 4'd0 : div15 + 4'd1;
            if (!hold) tacc <= ce_turbo ? tacc_next - 11'd1500 : tacc_next;
            if (ce_base) begin
                div16 <= div16 + 4'd1;
                cycles <= cycles + 32'd1;
            end
        end
    end
`ifdef VERILATOR
    // Simulation check of the clock enables, reported at the end of the run
    // ("enable check ... 0 violations"; sim/check.sh requires it): a base cycle
    // every 15 clk_sys (15 or 16 in PAL), a pixel every 10, CPU enables never on
    // consecutive clocks (core_constraints.sdc relies on it), the TV standard
    // changing only in reset, and the first clock after a cold reset or the
    // launch alike: a base cycle with the turbo accumulator at 0 and no CPU
    // enable just before it. The base cycle across the launch keeps its
    // length (15 clk_sys, 15 or 16 in PAL), timed by a count the launch does
    // not clear.
    integer sp_b = 0, sp_c = 0, sp_p = 0, viol = 0, sp_l = 0;
    integer mn_b = 99, mx_b = 0, mn_c = 99, mx_c = 0, mn_p = 99, mx_p = 0;
    reg     pal_d = 1'b0, mreset_d = 1'b0, after_launch = 1'b0;
    always @(posedge clk_sys) begin
        pal_d <= pal; mreset_d <= mreset;
        if (!reset && pal != pal_d) viol = viol + 1;
        if (mreset_d && !mreset && !(ce_base && tacc == 11'd0 && !ce_cpu_d)) viol = viol + 1;
        sp_l = sp_l + 1;
        if (launch_rst) after_launch <= 1'b1;
        if (ce_base && !mreset) begin
            if (after_launch && !(sp_l == 15 || (pal && sp_l == 16))) viol = viol + 1;
            after_launch <= 1'b0;
            sp_l = 0;
        end else if (reset) sp_l = 0;
        if (!reset) begin
            sp_b = sp_b + 1; sp_c = sp_c + 1; sp_p = sp_p + 1;
            if (ce_base) begin
                if (cycles > 2) begin
                    if (sp_b < mn_b) mn_b = sp_b;
                    if (sp_b > mx_b) mx_b = sp_b;
                    if (sp_b != 15 && !(pal && sp_b == 16)) viol = viol + 1;
                end
                sp_b = 0;
            end
            if (ce_cpu) begin
                if (cycles > 2) begin
                    if (sp_c < mn_c) mn_c = sp_c;
                    if (sp_c > mx_c) mx_c = sp_c;
                    if (sp_c < 2) viol = viol + 1;
                end
                sp_c = 0;
            end
            if (ce_pix) begin
                if (cycles > 2) begin
                    if (sp_p < mn_p) mn_p = sp_p;
                    if (sp_p > mx_p) mx_p = sp_p;
                    if (sp_p != 10) viol = viol + 1;
                end
                sp_p = 0;
            end
        end
    end
    final $display("enable check (clk_sys between enables): base %0d-%0d cpu %0d-%0d pixel %0d-%0d, %0d violations",
                   mn_b, mx_b, mn_c, mx_c, mn_p, mx_p, viol);
`endif
    assign dbg_cycles = cycles;

    // the launch (see start-up above). launch_rst comes in the clock in which the
    // base divider steps from 14 to 0; mode changes with it, so every block
    // takes the reset of the machine it starts.
    wire launch_go = launch_arm && !reset && !hold && div15 == 4'd13;
    always @(posedge clk_sys) begin
        launch_rst <= launch_go;
        if (reset) begin mode <= M_SS; launch_pend <= 1'b0; launch_arm <= 1'b0; boot_run <= 1'b1; end
        else if (launch_go) begin mode <= boot_mode; launch_arm <= 1'b0; end
        else if (launch_rst) begin launch_pend <= 1'b0; boot_run <= 1'b0; end
        else if (launch_pend && ce_base && dbg_hc == 8'd227 && dbg_line == (pal ? 9'd312 : 9'd261))
            launch_arm <= 1'b1;
        else if (launch_req) launch_pend <= 1'b1;
    end

    // ------------------------------------------------------------ CPU
    wire [15:0] a;
    wire [7:0]  cpu_dout;
    reg  [7:0]  cpu_din;
    wire        mreq_n, iorq_n, rd_n, wr_n, m1_n, rfsh_n, halt_n;
    wire        mem_rd_start, mem_wr_start, io_sample, io_cycle, io_write, int_ack;
    wire        mem_wait_n, sync_wait_n;
    wire        int_n;
    reg         nmi_n;

    wire        cart_wait_n;
    wire        dma_busy, dma_bus;           // DMA: the CPU is held; the engine owns the memory bus
    mdr_z80 u_cpu (
        .clk(clk_sys), .reset_n(~mreset), .cen(ce_cpu),
        .wait_n(mem_wait_n && sync_wait_n && cart_wait_n && !dma_busy && !launch_pend), .int_n(int_n), .nmi_n(nmi_n),
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
    // layer in the modes whose controllers have no Start: SMS, SG-1000, SC-3000).
    // None while the BIOS runs, from a cold reset to its launch: software cannot
    // mask an NMI, and the BIOS has no use for one. A Pause held through the
    // launch is not a press: the game gets one when it is pressed again.
    wire pause_src = pause_btn || (b_startpause && pad1[7] &&
                                   (mode == 3'd0 || mode == 3'd2 || mode == 3'd3));
    reg  pause_held = 1'b0;
    always @(posedge clk_sys) begin
        if (reset) pause_held <= 1'b0;
        else if (launch_rst) pause_held <= 1'b1;
        else if (!pause_src) pause_held <= 1'b0;
    end
    wire pause_any = !boot_run && !pause_held && pause_src;
    always @(posedge clk_sys) begin
        if (mreset) nmi_n <= 1'b1;
        else nmi_n <= ~pause_any;
    end

    // ------------------------------------------------------------ memory
    // The memory controller sees the CPU bus one clock late. The access-start
    // pulse comes from the CPU's instruction decoding in the first clock of T1,
    // and that logic is too deep to reach the controller's registers within the
    // same clock; this register stage delays each access by one clock (19 ns),
    // well inside a T-state.
    // While a DMA transfer owns the bus its reads take the CPU's place. The
    // CPU's next opcode fetch starts during the transfer (its T1 comes before
    // the CPU is held, in T2), so that read is remembered (cpu_rd_pend) and made
    // when the bus is handed back, whether the fetch is still in T1 or waits in
    // T2. Neither the transfer's reads nor that fetch start the cartridge wait
    // state (m_nows): the DMA engine charges them itself.
    reg  [15:0] m_a = 16'd0;
    reg  [7:0]  m_dout = 8'd0;
    reg         m_mreq_n = 1'b1, m_rd_n = 1'b1, m_wr_n = 1'b1, m_rd_start = 1'b0;
    reg  [1:0]  m_dsrc = 2'd0;
    wire [15:0] dma_m_a;
    wire        dma_m_rd;
    wire [1:0]  dma_m_src;
    reg         cpu_rd_pend = 1'b0;
    reg         m_nows = 1'b0;
    always @(posedge clk_sys) begin
        if (mreset || !dma_bus) cpu_rd_pend <= 1'b0;
        else if (mem_rd_start) cpu_rd_pend <= 1'b1;
        m_a <= dma_bus ? dma_m_a : a; m_dout <= cpu_dout;
        m_mreq_n <= dma_bus ? 1'b0 : mreq_n; m_rd_n <= dma_bus ? 1'b0 : rd_n; m_wr_n <= dma_bus ? 1'b1 : wr_n;
        m_rd_start <= dma_bus ? dma_m_rd : (mem_rd_start || cpu_rd_pend);
        m_nows <= dma_busy;
        m_dsrc <= dma_bus ? dma_m_src : 2'd0;
    end
    wire [7:0]  mem_rdata;
    wire [7:0]  mem_ctl, io_ctl, slot_sel;
    wire [3:0]  wram_bank;
    wire [4:0]  card_bank;
    mdr_mem u_mem (
        .clk(clk_sys), .rst(mreset), .mode(mode), .mapper(mapper), .sc_ram32(sc_ram32),
        .rom_mask(rom_mask), .card_present(card_present), .card_mask(card_mask),
        .a(m_a), .dout(m_dout), .mreq_n(m_mreq_n), .rd_n(m_rd_n), .wr_n(m_wr_n),
        .rd_start(m_rd_start), .dma_src(m_dsrc), .rdata(mem_rdata), .wait_n(mem_wait_n),
        .mem_ctl(mem_ctl), .wram_bank(wram_bank), .slot_sel(slot_sel), .card_bank(card_bank),
        .rom_req(rom_req), .rom_addr(rom_addr), .rom_ack(rom_ack), .rom_data(rom_data),
        .sv_clk(sv_clk), .sv_we(sv_we), .sv_addr(sv_addr), .sv_din(sv_din), .sv_dout(sv_dout),
        .page0(), .page1(), .page2(), .ram_sel(), .cram_we(cart_ram_we));

    // ------------------------------------------------------------ I/O
    wire [7:0]  io_rdata, vdp_rdata;
    wire        vdp_rd, vdp_wr, th_latch, psg_wr, stereo_wr, fm_wr, fm_addr, pcm_wr;
    wire        wt_wr, dma_start;
    wire [2:0]  wt_reg;
    wire [47:0] dma_regs;
    wire [6:0]  pcm_fill;
    wire [1:0]  fm_ctl;
    wire [7:0]  pcm_ctl;
    wire [7:0]  vdp_fea, vdp_fec;
    wire        vdp_active;
    // Auto-fire (enhancement layer): while C is held, button 2 toggles every two
    // frames (15 Hz at 60 Hz). Stock modes only: MasterDrive software reads C as
    // a button of its own.
    reg [1:0] af_cnt;
    always @(posedge clk_sys) begin
        if (mreset) af_cnt <= 2'd0;
        else if (vid_vs && vid_ce) af_cnt <= af_cnt + 2'd1;
    end
    wire af_on = b_autofire && !ss;
    wire [7:0] pad1_eff = (af_on && pad1[6]) ? {pad1[7:6], af_cnt[1], pad1[4:0]} : pad1;
    wire [7:0] pad2_eff = (af_on && pad2[6]) ? {pad2[7:6], af_cnt[1], pad2[4:0]} : pad2;

    mdr_io u_io (
        .clk(clk_sys), .rst(mreset), .cold(reset), .mode(mode), .jp_region(jp_region),
        .fm_present(fm_here),
        .io_sample(io_sample), .io_write(io_write), .port(a[7:0]), .wdata(cpu_dout), .rdata(io_rdata),
        .vdp_rdata(vdp_rdata), .vdp_rd(vdp_rd), .vdp_wr(vdp_wr), .vdp_fea(vdp_fea), .vdp_fec(vdp_fec),
        .th_latch(th_latch),
        .psg_wr(psg_wr), .stereo_wr(stereo_wr), .fm_wr(fm_wr), .fm_addr(fm_addr), .fm_ctl(fm_ctl),
        .mem_ctl(mem_ctl), .io_ctl(io_ctl), .wram_bank(wram_bank), .slot_sel(slot_sel),
        .card_bank(card_bank), .turbo_step(turbo_step), .pcm_ctl(pcm_ctl), .pcm_wr(pcm_wr),
        .pcm_fill(pcm_fill), .wt_wr(wt_wr), .wt_reg(wt_reg), .dma_start(dma_start), .dma_regs(dma_regs),
        .pad1(pad1_eff), .pad2(pad2_eff), .reset_btn(reset_btn), .kb_keys(kb_keys), .kb_ghosting(kb_ghosting),
        .plat_mode(plat_mode), .plat_auto(plat_auto), .plat_flags(plat_flags), .rom_log2(rom_log2),
        .mapper(mapper), .machines(machines),
        .plat_boost({ael_tmscol, ael_ggwide, ael_pstereo, ael_autofire, ael_vramboost, ael_turbo,
                     ael_startpause, ael_ovf_stock, ael_sprlimit}), .plat_chg(ael_chg),
        .boost(boost), .boot_mode(boot_mode), .launch_req(launch_req));

    // CPU data in
    always @* begin
        if (int_ack) cpu_din = 8'hFF;
        else if (!iorq_n || io_cycle) cpu_din = io_rdata;
        else cpu_din = mem_rdata;
    end

    // ------------------------------------------------------------ VDP
    mdr_vdp u_vdp (
        .clk(clk_sys), .rst(mreset), .rst_out(reset), .ce_cyc(ce_base),
        .gg_mode(mode == 3'd1), .ss_mode(ss), .pal(pal), .timing_gg(timing_gg),
        // boosts are for stock software: MasterDrive software sets these itself
        .no_spr_limit(b_sprlimit && !ss), .ovf_stock(b_ovf && !ss), .tms_true(b_tmscol),
        .io_rd(vdp_rd), .io_wr(vdp_wr), .io_port(a[7:0]), .io_din(cpu_dout), .io_dout(vdp_rdata),
        .th_latch(th_latch), .int_n(int_n),
        .ce_pix(ce_pix), .vid_rgb(vid_bgr), .vid_de(vid_de), .vid_hs(vid_hs), .vid_vs(vid_vs),
        .vid_frame(vid_frame), .gg_crop(gg_crop),
        .dma_vwe(dma_vwe), .dma_vre(dma_vre), .dma_vaddr(dma_vaddr), .dma_vdin(dma_vdin), .dma_vdout(dma_vdout),
        .dma_cwe(dma_cwe), .dma_caddr(dma_caddr), .dma_cdin(dma_cdin), .dma_cready(dma_cready),
        .out_fea(vdp_fea), .out_fec(vdp_fec), .out_active(vdp_active),
        .dbg_line(dbg_line), .dbg_hc(dbg_hc), .dbg_status());
    assign vid_ce = ce_pix;

    // ------------------------------------------------------------ DMA engine
    wire        dma_vwe, dma_vre, dma_cwe, dma_cready;
    wire [14:0] dma_vaddr;
    wire [7:0]  dma_vdin, dma_vdout, dma_cdin;
    wire [8:0]  dma_caddr;
    // the BIOS ROM is mapped: its reads (the CPU's, or a DMA's from source 0) are not
    // cartridge reads and take no cartridge wait state
    wire       bios_on = !mem_ctl[3] && mem_ctl[6] && (mode == 3'd0 || mode == 3'd1 || ss);
    mdr_dma u_dma (
        .clk(clk_sys), .rst(mreset), .ce_held(ce_cpu && (!mreq_n || !iorq_n)),
        .fetch_ws(dma_busy && mem_rd_start && a < 16'hC000 && mode != 3'd4 && step_eff == 3'd4 && !bios_on), .start(dma_start),
        .r_f4(dma_regs[7:0]), .r_f5(dma_regs[15:8]), .r_f6(dma_regs[23:16]), .r_f7(dma_regs[31:24]),
        .r_f8(dma_regs[39:32]), .r_f9(dma_regs[47:40]), .r_fa(cpu_dout),
        .ws200(step_eff == 3'd4 && mode != 3'd4 && !bios_on),
        .busy(dma_busy), .bus(dma_bus),
        .m_a(dma_m_a), .m_rd(dma_m_rd), .m_src(dma_m_src), .m_wait_n(mem_wait_n), .m_data(mem_rdata),
        .v_we(dma_vwe), .v_re(dma_vre), .v_addr(dma_vaddr), .v_din(dma_vdin), .v_dout(dma_vdout),
        .c_we(dma_cwe), .c_addr(dma_caddr), .c_din(dma_cdin), .c_ready(dma_cready));

    // ------------------------------------------------------------ bus synchroniser
    // Count base cycles since the last VDP port access; at turbo, an access that
    // comes sooner than the VDP's slot is held until the slot.
    reg  [5:0] since_vdp;
    wire [5:0] slot = vdp_active ? 6'd29 : 6'd16;
    wire       vdp_port_cycle = io_cycle && (a[7:6] == 2'b10);
    wire       vdp_hold = turbo_on && !(b_vramboost && !ss) && vdp_port_cycle && since_vdp < slot;
    always @(posedge clk_sys) begin
        if (mreset) since_vdp <= 6'd63;
        else if (io_sample && a[7:6] == 2'b10) since_vdp <= 6'd0;
        else if (ce_base && since_vdp != 6'd63) since_vdp <= since_vdp + 6'd1;
    end
    // The FM chip takes a write only 12 base cycles after an address write and
    // 84 after a data write (YM2413 Application Manual). Software leaves that
    // time at 100 %; at turbo the synchroniser holds an FM write until then
    // (Technical Reference §1).
    wire       fm_port = fm_here && (a[7:1] == 7'b1111000);           // $F0, $F1
    reg  [6:0] since_fm;
    reg        fm_last_data;
    wire       fm_hold = turbo_on && io_cycle && io_write && fm_port &&
                         since_fm < (fm_last_data ? 7'd84 : 7'd12);
    always @(posedge clk_sys) begin
        if (mreset) begin
            since_fm <= 7'd127;
            fm_last_data <= 1'b0;
        end else if (io_sample && io_write && fm_port) begin
            since_fm <= 7'd0;
            fm_last_data <= a[0];
        end else if (ce_base && since_fm != 7'd127) since_fm <= since_fm + 7'd1;
    end
    assign sync_wait_n = !(vdp_hold || fm_hold);

    // ------------------------------------------------------------ cartridge wait state
    // At 200 % a 250 ns cartridge ROM needs one wait state on every read (Q12,
    // kept): each memory read in $0000-$BFFF, the cartridge and card slots,
    // gets one TW. Not in SF-7000 mode, where $0000-$BFFF is the disk system's
    // RAM and IPL. The read is seen in T1 (m_rd_start, one clock after the CPU's
    // pulse); the count steps at each CPU enable, so it is 1, holding wait_n
    // low, exactly at the T2 enable, and the CPU repeats T2 once. The PSRAM
    // answers inside the 200 % window by itself, so this is the machine's wait
    // state, not the memory's. HALT's repeated M1 reads take it too.
    reg  [1:0] cart_ws = 2'd0;
    always @(posedge clk_sys) begin
        if (mreset) cart_ws <= 2'd0;
        else if (m_rd_start && !m_nows && m_a < 16'hC000 && mode != 3'd4 && step_eff == 3'd4 && !bios_on) cart_ws <= 2'd2;
        else if (ce_cpu && cart_ws != 2'd0) cart_ws <= cart_ws - 2'd1;
    end
    assign cart_wait_n = (cart_ws != 2'd1);

    // ------------------------------------------------------------ audio
    wire signed [15:0] psg_l, psg_r;
    mdr_psg u_psg (
        .clk(clk_sys), .rst(mreset), .ce_psg(ce_psg), .wr(psg_wr), .din(cpu_dout),
        .stereo_wr(stereo_wr), .stereo_din(cpu_dout), .pstereo(b_pstereo && !ss),
        .out_l(psg_l), .out_r(psg_r));

    // FM: the YM2413, as IKAOPLL (third_party/ikaopll, BSD-2), on the base
    // cycle like the chip's 3.579545 MHz master clock; it makes a sample every
    // 72 cycles (49.7 kHz). Each OUT to $F0/$F1 becomes a chip-select and write
    // pulse 32 clocks long, so IKAOPLL's write-request input, which samples on
    // master-clock edges, catches it; the CPU's next OUT comes at least 82
    // clocks later (11 T-states at 200 % turbo). The chip's own time between
    // writes (12 master-clock cycles after an address, 84 after data) is left
    // by software at 100 % and by the bus synchroniser at turbo.
    reg        fm_a0 = 1'b0;
    reg  [7:0] fm_d = 8'd0;
    reg  [5:0] fm_wcnt = 6'd0;
    // The YM2413 data sheet gives the reset (IC) pulse as 80 master-clock cycles
    // (typical; it lists no minimum), and IKAOPLL needs 72 to clear its
    // pipelines. The machine reset can be shorter, so IC stays low for 96 base
    // cycles after it (27 us). Writes in that time are lost.
    reg  [6:0] fm_rcnt = 7'd0;
    always @(posedge clk_sys) begin
        if (mreset) begin
            fm_wcnt <= 6'd0;
            fm_rcnt <= 7'd0;
        end else begin
            if (fm_wr) begin
                fm_a0 <= fm_addr;
                fm_d <= cpu_dout;
                fm_wcnt <= 6'd32;
            end else if (fm_wcnt != 6'd0) fm_wcnt <= fm_wcnt - 6'd1;
            if (ce_base && fm_rcnt != 7'd96) fm_rcnt <= fm_rcnt + 7'd1;
        end
    end
    wire               fm_strb;
    wire signed [15:0] fm_acc;
    IKAOPLL #(.FULLY_SYNCHRONOUS(1), .FAST_RESET(0), .ALTPATCH_CONFIG_MODE(0),
              .USE_PIPELINED_MULTIPLIER(1)) u_fm (
        .i_XIN_EMUCLK(clk_sys), .o_XOUT(), .i_phiM_PCEN_n(!ce_base),
        .i_IC_n(fm_rcnt == 7'd96), .i_ALTPATCH_EN(1'b0),
        .i_CS_n(fm_wcnt == 6'd0), .i_WR_n(fm_wcnt == 6'd0), .i_A0(fm_a0), .i_D(fm_d),
        .o_D(), .o_D_OE(), .o_DAC_EN_MO(), .o_DAC_EN_RO(), .o_IMP_NOFLUC_SIGN(),
        .o_IMP_NOFLUC_MAG(), .o_IMP_FLUC_SIGNED_MO(), .o_IMP_FLUC_SIGNED_RO(),
        .i_ACC_SIGNED_MOVOL(5'sd2), .i_ACC_SIGNED_ROVOL(5'sd3),   // IKAOPLL's default melody/rhythm weights (Q20)
        .o_ACC_SIGNED_STRB(fm_strb), .o_ACC_SIGNED(fm_acc));
    reg               fm_strb_d = 1'b0;
    reg signed [15:0] fm_out = 16'sd0;
    always @(posedge clk_sys) begin
        fm_strb_d <= fm_strb;
        if (fm_strb && !fm_strb_d) fm_out <= fm_acc;
    end

    // Mix. $F2 bits 1-0 (Japanese Master System): 0 PSG only (power-on),
    // 1 FM only, 2 both muted, 3 both. Outside the Master System and MasterDrive
    // modes $F2 is never written, so the PSG alone plays. Level: one FM channel
    // at full volume peaks at half a PSG channel at full volume (x8 on the
    // chip's output, about +-510 a channel), as in the emulator; the original's
    // balance is not known (open question Q20). FM is mono, on both sides.
    // Headroom: the sum (20 bits hold any sum) is scaled by 41/64, -3.9 dB, so
    // the 16-bit full scale is 6.25 PSG channels at full volume, as in the
    // emulator. Nine FM channels at full volume then fit; both chips at full
    // volume together can still reach the limit, where the output saturates.
    // PCM and wavetable (MasterDrive mode; $F2 does not mute them, as in the
    // emulator: open question Q27)
    wire signed [15:0] pcm_l, pcm_r;
    mdr_pcm u_pcm (
        .clk(clk_sys), .rst(mreset), .pcm_wr(pcm_wr), .din(cpu_dout), .rate(pcm_ctl[1:0]), .fill(pcm_fill),
        .wt_wr(wt_wr), .wt_reg(wt_reg), .out_l(pcm_l), .out_r(pcm_r));
    wire               psg_on = (fm_ctl == 2'd0) || (fm_ctl == 2'd3);
    wire               fm_on  = fm_ctl[0];
    wire signed [19:0] fm_s   = fm_on ? {{4{fm_out[15]}}, fm_out} <<< 3 : 20'sd0;
    wire signed [19:0] mix_l  = (psg_on ? {{4{psg_l[15]}}, psg_l} : 20'sd0) + fm_s + {{4{pcm_l[15]}}, pcm_l};
    wire signed [19:0] mix_r  = (psg_on ? {{4{psg_r[15]}}, psg_r} : 20'sd0) + fm_s + {{4{pcm_r[15]}}, pcm_r};
    function [15:0] sat16(input signed [19:0] v);
        sat16 = (v > 20'sd32767) ? 16'h7FFF : (v < -20'sd32768) ? 16'h8000 : v[15:0];
    endfunction
    reg  signed [19:0] mix_l_r = 20'sd0, mix_r_r = 20'sd0;
    wire signed [25:0] head_l = mix_l_r * 26'sd41;      // x 41/64 below (>>> 6)
    wire signed [25:0] head_r = mix_r_r * 26'sd41;
    always @(posedge clk_sys) begin
        mix_l_r <= mix_l;
        mix_r_r <= mix_r;
        audio_l <= sat16(head_l[25:6]);
        audio_r <= sat16(head_r[25:6]);
    end

endmodule

`default_nettype wire
