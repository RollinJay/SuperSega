// Super Sega - Video Display Processor
//
// Mode 4 VDP (Master System / Game Gear) with the Super Sega register file.
//
// Timing model. The VDP counts base CPU cycles (228 per line) whatever the turbo
// step. Per-line events happen at fixed cycle offsets, following Gearsystem's
// model, which passes the SMS VDP test ROMs. Two tables are provided: the SMS2
// and the Game Gear single-ASIC (315-5535), the part the machine profile names.
//
//   event        SMS2   GG 315-5535
//   H scroll       14     16      latch R8 for this line
//   V counter      25     27      V counter takes the new line number
//   frame flag     25     27      status bit 7 on line (height + 1)
//   line IRQ       27     28      line counter decrement / reload / fire
//   overflow flag  25     27      status bit 6, from the previous line's sprites
//   display latch  37     20      R1 bit 6 sampled for this line
//   render        195    186      background of this line, sprites of the next
//
// Rendering. At the render event the renderer draws this line's background,
// composites it with this line's sprites (evaluated during the previous line),
// looks colours up in CRAM, and writes RGB444 to a line buffer; then it evaluates
// and draws the sprites of the next line. The line buffer is shown during the
// following line, so video leaves the VDP one line late. Which VRAM, CRAM and
// register values a line uses therefore matches Gearsystem's atomic render.
//
// Implemented in this milestone: Mode 4 at 192/224/240 lines, Game Gear CRAM,
// Super Sega register banks and gating, native and extended CRAM, VRAM banking,
// 16 sprites per line. The other Super Sega render features (ESAT, 16x16 and
// magnified sprites, window, line scroll tables, unique-cell, text window) and
// the legacy TMS9918 modes read and write their registers but do not render yet.
`default_nettype none

module ss_vdp (
    input  wire        clk,
    input  wire        rst,
    input  wire        ce_cyc,        // one pulse per base CPU cycle
    input  wire        gg_mode,       // Game Gear native mode
    input  wire        ss_mode,       // Super Sega mode: extensions reachable
    input  wire        pal,
    input  wire        timing_gg,     // 1 = 315-5535 event table
    input  wire        no_spr_limit,  // enhancement layer: 16 per line for stock software
    input  wire        ovf_stock,     // enhancement layer: overflow flag still set by a 9th sprite

    // CPU side: strobes at the I/O sample point
    input  wire        io_rd,
    input  wire        io_wr,
    input  wire [7:0]  io_port,
    input  wire [7:0]  io_din,
    output reg  [7:0]  io_dout,       // combinational
    input  wire        th_latch,      // latch the H counter (TH edge)
    output wire        int_n,

    // video out, sys clock domain, one pixel per pix_ce
    input  wire        ce_pix,
    output reg  [11:0] vid_rgb,       // RGB444
    output reg         vid_de,
    output reg         vid_hs,
    output reg         vid_vs,
    output reg         vid_frame,     // first pixel of a frame, for the scaler slot write
    input  wire        gg_crop,       // show only the Game Gear 160x144 window

    // register values other blocks need
    output wire [7:0]  out_fea,       // Feature Enable A (R15)
    output wire [7:0]  out_fec,       // Feature Enable C (bank 1 R7), 0 unless reachable
    output wire        out_active,    // display enabled and in the active lines

    // debug / test
    output wire [8:0]  dbg_line,
    output wire [7:0]  dbg_hc,
    output wire [7:0]  dbg_status
);

    // =====================================================================
    // registers
    // =====================================================================
    reg  [7:0] r [0:63];             // 4 banks x 16
    wire [7:0] r0 = r[0], r1 = r[1], r2 = r[2], r5 = r[5], r6 = r[6], r7 = r[7];
    wire [7:0] r8 = r[8], r9 = r[9], r10 = r[10];
    wire [7:0] fea = r[15];
    wire       xrb = ss_mode && fea[5];
    wire [7:0] feb = xrb ? r[16+2] : 8'h00;
    wire       ext_cram  = ss_mode && feb[1];
    wire       vram_bank_en = ss_mode && feb[4];
    wire       native_cram  = ss_mode && fea[0];
    wire       spr16_line   = (ss_mode && fea[4]) || no_spr_limit;

    // display height from the mode bits (SMS2) or Feature Enable B bits 7-6.
    // M2 enables the extra heights; then M1 gives 224 lines and M3 gives 240
    // (MAME sega315_5246, Gearsystem). With M2 clear Mode 4 is 192 lines.
    wire m1 = r1[4], m2 = r0[1], m3 = r1[3], m4 = r0[2];
    reg  [8:0] height;
    always @* begin
        height = 9'd192;
        if (m4 && m2 && m1 && !m3) height = 9'd224;
        else if (m4 && m2 && m3 && !m1) height = 9'd240;
        else if (ss_mode && feb[7:6] == 2'd1) height = 9'd224;
        else if (ss_mode && feb[7:6] == 2'd2) height = 9'd240;
    end
    wire ext_height = (height != 9'd192);

    // =====================================================================
    // memories
    // =====================================================================
    // VRAM 32 KB. Port A: CPU data port. Port B: renderer.
    reg         va_we;
    reg  [14:0] va_addr;
    reg  [7:0]  va_din;
    wire [7:0]  va_dout;
    reg  [14:0] vb_addr;
    wire [7:0]  vb_dout;
    ss_dpram #(.AW(15), .DW(8)) u_vram (
        .clk_a(clk), .we_a(va_we), .addr_a(va_addr), .din_a(va_din), .dout_a(va_dout),
        .clk_b(clk), .we_b(1'b0), .addr_b(vb_addr), .din_b(8'h00), .dout_b(vb_dout));

    // CRAM: 256 entries of RGB444 (12 bits). Port A: CPU. Port B: renderer.
    reg         ca_we;
    reg  [7:0]  ca_addr;
    reg  [11:0] ca_din;
    wire [11:0] ca_dout_unused;
    reg  [7:0]  cb_addr;
    wire [11:0] cb_dout;
    ss_dpram #(.AW(8), .DW(12)) u_cram (
        .clk_a(clk), .we_a(ca_we), .addr_a(ca_addr), .din_a(ca_din), .dout_a(ca_dout_unused),
        .clk_b(clk), .we_b(1'b0), .addr_b(cb_addr), .din_b(12'h000), .dout_b(cb_dout));
    reg [15:0] pal_written;          // per 16-entry palette, for extended-CRAM aliasing

    // =====================================================================
    // line timing
    // =====================================================================
    reg  [7:0] hc;                   // CPU cycle within the line, 0..227
    reg  [8:0] ln;                   // line being processed, 0..lines-1
    reg  [8:0] vc;                   // V counter line number (changes at the V event)
    wire [8:0] lines = pal ? 9'd313 : 9'd262;

    wire [7:0] ev_xscroll = timing_gg ? 8'd16  : 8'd14;
    wire [7:0] ev_vcount  = timing_gg ? 8'd27  : 8'd25;
    wire [7:0] ev_flag    = timing_gg ? 8'd27  : 8'd25;
    wire [7:0] ev_hint    = timing_gg ? 8'd28  : 8'd27;
    wire [7:0] ev_ovr     = timing_gg ? 8'd27  : 8'd25;
    wire [7:0] ev_display = timing_gg ? 8'd20  : 8'd37;
    wire [7:0] ev_render  = timing_gg ? 8'd186 : 8'd195;
    wire [7:0] col_offset = timing_gg ? 8'd22  : 8'd20;

    reg  [7:0] hs_latch;             // H scroll for this line
    reg  [7:0] vs_latch;             // V scroll for this frame
    reg        disp_en;              // display enable for this line
    reg  [7:0] line_ctr;
    reg        line_irq;
    reg  [7:0] status;               // bits 7..5 used
    reg  [7:0] hcount_latched;

    // H counter values per CPU cycle of the line (Gearsystem table: $E9 at cycle 0).
    function [7:0] hcount_of;
        input [7:0] c;
        reg [9:0] p;
        begin
            // 171 counts per 228 cycles (3 per 4): $E9..$FF, then $00..$93
            p = ({2'b00, c} * 10'd3 + 10'd1) >> 2;
            if (p < 10'd23) hcount_of = 8'hE9 + p[7:0];
            else hcount_of = p[7:0] - 8'd23;
        end
    endfunction

    // V counter mapping (jump table)
    function [7:0] vcount_map;
        input [8:0] v;
        input       is_pal;
        input [8:0] h;
        reg   [8:0] t;
        begin
            t = v;
            if (!is_pal) begin
                if (h == 9'd192)      t = (v <= 9'h0DA) ? v : v - 9'd6;
                else if (h == 9'd224) t = (v <= 9'h0EA) ? v : v - 9'd6;
            end else begin
                if (h == 9'd192)      t = (v <= 9'h0F2) ? v : v - 9'd57;
                else if (h == 9'd224) t = (v <= 9'h102) ? v : v - 9'd57;
                else                  t = (v <= 9'h10A) ? v : v - 9'd57;
            end
            vcount_map = t[7:0];
        end
    endfunction

    wire render_go = ce_cyc && (hc == ev_render);

    // =====================================================================
    // CPU port
    // =====================================================================
    reg        latch_first;          // 1 = next control write is the first byte
    reg [13:0] addr;
    reg [1:0]  code;
    reg [7:0]  rbuf;
    reg [1:0]  rbuf_fill;            // VRAM read in flight for the read buffer
    reg [7:0]  cram_lo;

    wire       port_ctrl = io_port[0];
    wire       port_vdp  = (io_port[7:6] == 2'b10);
    wire       port_cnt  = (io_port[7:6] == 2'b01);
    wire [14:0] cpu_vaddr = {vram_bank_en ? r[16+3][0] : 1'b0, addr};

    // read data (combinational, valid at the sample point)
    always @* begin
        io_dout = 8'hFF;
        if (port_cnt) io_dout = port_ctrl ? hcount_latched : vcount_map(vc, pal, height);
        else if (port_vdp) io_dout = port_ctrl ? (status | 8'h1F) : rbuf;
    end

    // IRQ
    assign int_n = ~((status[7] && r1[5]) || (line_irq && r0[4]));

    // CRAM write helpers
    wire [11:0] sms_col = {io_din[5:4], io_din[5:4], io_din[3:2], io_din[3:2], io_din[1:0], io_din[1:0]};
    // RGB444 from 6-bit BBGGRR: each 2-bit channel x5 -> 4 bits (0,5,10,15) = {c,c}
    wire [11:0] gg_col = {io_din[3:0], cram_lo[7:4], cram_lo[3:0]};   // B G R

    integer i;
    always @(posedge clk) begin
        va_we <= 1'b0;
        ca_we <= 1'b0;
        if (rst) begin
            for (i = 0; i < 64; i = i + 1) r[i] <= 8'h00;
            r[0] <= 8'h36; r[1] <= 8'hA0; r[2] <= 8'hFF; r[3] <= 8'hFF; r[4] <= 8'hFF;
            r[5] <= 8'hFF; r[6] <= 8'hFB; r[7] <= 8'h00; r[8] <= 8'h00; r[9] <= 8'h00;
            r[10] <= 8'hFF;
            latch_first <= 1'b1; addr <= 14'd0; code <= 2'd0; rbuf <= 8'h00;
            rbuf_fill <= 2'b00; cram_lo <= 8'h00; pal_written <= 16'h0000;
            hcount_latched <= 8'h00;
        end else begin
            // finish a read-buffer fill: address registered, then one cycle of
            // block-RAM latency
            rbuf_fill <= {rbuf_fill[0], 1'b0};
            if (rbuf_fill[1]) rbuf <= va_dout;
            if (th_latch) hcount_latched <= hcount_of(hc);

            if (io_wr && port_vdp) begin
                if (port_ctrl) begin
                    if (latch_first) begin
                        latch_first <= 1'b0;
                        addr[7:0] <= io_din;
                    end else begin
                        latch_first <= 1'b1;
                        addr[13:8] <= io_din[5:0];
                        code <= io_din[7:6];
                        if (io_din[7:6] == 2'd0) begin
                            // read-ahead: buffer = VRAM[addr], addr++
                            va_addr <= {vram_bank_en ? r[16+3][0] : 1'b0, io_din[5:0], addr[7:0]};
                            rbuf_fill <= 2'b01;
                            addr <= {io_din[5:0], addr[7:0]} + 14'd1;
                        end else if (io_din[7:6] == 2'd2) begin
                            // register write; bits 5-4 select a bank when XRB is on
                            if (xrb)
                                r[{io_din[5:4], io_din[3:0]}] <= addr[7:0];
                            else
                                r[{2'b00, io_din[3:0]}] <= addr[7:0];
                        end
                    end
                end else begin
                    latch_first <= 1'b1;
                    if (code == 2'd3) begin
                        // CRAM
                        if (gg_mode || native_cram) begin
                            if (!addr[0]) cram_lo <= io_din;
                            else begin
                                ca_we   <= 1'b1;
                                ca_addr <= gg_mode ? {3'b000, addr[5:1]}
                                                   : (ext_cram ? addr[8:1] : {3'b000, addr[5:1]});
                                ca_din  <= gg_col;
                                pal_written[gg_mode ? 4'd0 : (ext_cram ? addr[8:5] : 4'd0)] <= 1'b1;
                            end
                        end else begin
                            ca_we   <= 1'b1;
                            ca_addr <= ext_cram ? addr[7:0] : {3'b000, addr[4:0]};
                            ca_din  <= sms_col;
                            pal_written[ext_cram ? addr[7:4] : 4'd0] <= 1'b1;
                        end
                    end else begin
                        va_we   <= 1'b1;
                        va_addr <= cpu_vaddr;
                        va_din  <= io_din;
                    end
                    rbuf <= io_din;
                    addr <= addr + 14'd1;
                end
            end

            if (io_rd && port_vdp) begin
                latch_first <= 1'b1;
                if (!port_ctrl) begin
                    // data read returns the buffer, refills it, advances
                    va_addr <= cpu_vaddr;
                    rbuf_fill <= 2'b01;
                    addr <= addr + 14'd1;
                end
            end
        end
    end

    // =====================================================================
    // line events
    // =====================================================================
    reg [8:0] ln_next;
    always @* ln_next = (ln == lines - 9'd1) ? 9'd0 : ln + 9'd1;


    // sprite-pass results for a line: overflow and collision requests. The pass
    // that evaluates line L+1 may finish just before or just after the boundary.
    reg       spr_done;              // pulse from the renderer
    reg       spr_ovr, spr_col;
    reg [7:0] spr_colx;
    reg [8:0] spr_for;               // line the results belong to
    reg       pend, pend_ovr, pend_col;
    reg [7:0] pend_colx;
    reg       ovr_req_line, col_req_line;
    reg [7:0] col_x_line;

    // sprite collision flag time: col_offset + X * 228 / 256
    wire [15:0] col_cycle_w = {8'h00, col_offset} + ((col_x_line * 16'd228) >> 8);

    always @(posedge clk) begin
        if (rst) begin
            hc <= 8'd0; ln <= 9'd0; vc <= (pal ? 9'd312 : 9'd261);
            hs_latch <= 8'd0; vs_latch <= 8'd0; disp_en <= 1'b0;
            line_ctr <= 8'hFF; line_irq <= 1'b0; status <= 8'h00;
            pend <= 1'b0; ovr_req_line <= 1'b0; col_req_line <= 1'b0; col_x_line <= 8'd0;
        end else begin
            // a status read clears the flags and the pending line interrupt; an
            // event in the same cycle wins, so it is applied after this
            if (io_rd && port_vdp && port_ctrl) begin
                status <= 8'h00;
                line_irq <= 1'b0;
            end
            if (spr_done) begin
                if (spr_for == ln) begin
                    ovr_req_line <= spr_ovr; col_req_line <= spr_col; col_x_line <= spr_colx;
                end else begin
                    pend <= 1'b1; pend_ovr <= spr_ovr; pend_col <= spr_col; pend_colx <= spr_colx;
                end
            end
            if (ce_cyc) begin
                if (hc == ev_xscroll) hs_latch <= r8;
                if (hc == ev_vcount) begin
                    vc <= ln;
                    if (ln == 9'd0) vs_latch <= r9;
                end
                if (hc == ev_flag && ln == height + 9'd1) status[7] <= 1'b1;
                if (hc == ev_ovr && ovr_req_line) status[6] <= 1'b1;
                if (hc == ev_hint) begin
                    if (ln <= height) begin
                        if (line_ctr == 8'd0) begin
                            line_ctr <= r10;
                            line_irq <= 1'b1;
                        end else line_ctr <= line_ctr - 8'd1;
                    end else line_ctr <= r10;
                end
                if (hc == ev_display) disp_en <= r1[6];
                // Collision flag at col_offset + X*228/256 (Gearsystem). When that
                // falls at or after the render event, the flag is set at the render
                // event instead: Gearsystem drops such late collisions, but the
                // hardware flags a collision anywhere on the line.
                if (col_req_line && hc <= ev_render && ({8'h00, hc} >= col_cycle_w || hc == ev_render)) begin
                    status[5] <= 1'b1;
                    col_req_line <= 1'b0;
                end
                if (hc == 8'd227) begin
                    hc <= 8'd0;
                    ln <= ln_next;
                    ovr_req_line <= pend ? pend_ovr : 1'b0;
                    col_req_line <= pend ? pend_col : 1'b0;
                    col_x_line   <= pend_colx;
                    pend <= 1'b0;
                end else hc <= hc + 8'd1;
            end
        end
    end

    assign out_fea = fea;
    assign out_fec = xrb ? r[16+7] : 8'h00;
    assign out_active = r1[6] && (ln < height);
    assign dbg_line = ln;
    assign dbg_hc = hc;
    assign dbg_status = status;

    // =====================================================================
    // renderer
    // =====================================================================
    // One pass per line, started at the render event of line L:
    //   1. evaluate and draw the sprites of line L+1 into sprite buffer (L+1)&1
    //      (first, so the overflow and collision flags are ready for line L+1)
    //   2. fetch the background of line L into bg_line
    //   3. composite line L with sprite buffer L&1 (clearing it for reuse), look
    //      the colours up in CRAM and write RGB444 to output line L&1
    // Line buffers. The three arrays are block RAM with one write port and one
    // registered read port each; the sprite "pixel present" bits are
    // flip-flops because drawing reads them for the collision test.
    reg  [8:0]   bg_line  [0:255];   // {prio, cram index[7:0]}
    reg  [3:0]   spr_pix  [0:511];   // sprite colour, two lines
    reg  [511:0] spr_valid;          // sprite pixel present, two lines
    reg  [11:0]  out_line [0:1023];  // RGB444 {B,G,R}, four lines (ring)

`ifndef SYNTHESIS
    integer k;
    initial begin
        for (k = 0; k < 512; k = k + 1) spr_pix[k] = 4'd0;
        for (k = 0; k < 1024; k = k + 1) out_line[k] = 12'd0;
        for (k = 0; k < 256; k = k + 1) bg_line[k] = 9'd0;
    end
`endif

    localparam R_IDLE = 4'd0, R_SCAN = 4'd1, R_ATTR = 4'd2, R_PAT = 4'd3, R_DRAW = 4'd4,
               R_BG_START = 4'd5, R_BG_FETCH = 4'd6, R_BG_PIX = 4'd7, R_COMP = 4'd8, R_DONE = 4'd9;
    reg [3:0]  rs;
    reg [3:0]  rsub;
    reg [8:0]  rline;                // line whose background is drawn
    reg [8:0]  sline;                // line whose sprites are drawn
    reg [8:0]  comp_line;            // last line written to the output ring (checks)
    reg [8:0]  x;
    reg        rdisp;
    reg [7:0]  rhs, rvs;
    // background tile cache
    reg [14:0] tc_name;
    reg [2:0]  tc_fy;
    reg        tc_valid;
    reg [7:0]  tc_lo, tc_hi;
    reg [7:0]  tc_p0, tc_p1, tc_p2, tc_p3;

    wire        lock_row  = r0[6] && (rline < 9'd16);
    wire [7:0]  origin_x  = lock_row ? 8'd0 : rhs;
    wire [7:0]  map_x     = x[7:0] - origin_x;
    wire        lock_col  = r0[7] && (x >= 9'd192);
    wire [8:0]  my_raw    = rline + (lock_col ? 9'd0 : {1'b0, rvs});
    wire [8:0]  map_y     = ext_height ? {1'b0, my_raw[7:0]} : ((my_raw >= 9'd224) ? my_raw - 9'd224 : my_raw);
    wire [13:0] nt_base   = ext_height ? {r2[3:2], 12'h700} : {r2[3:1], 11'h000};
    wire [14:0] name_addr = {1'b0, nt_base + {3'b000, map_y[7:3], map_x[7:3], 1'b0}};
    wire [2:0]  fine_y    = map_y[2:0];

    wire        t_hf      = tc_hi[1];
    wire [2:0]  bitsel    = t_hf ? map_x[2:0] : (3'd7 - map_x[2:0]);
    wire [3:0]  t_col     = {tc_p3[bitsel], tc_p2[bitsel], tc_p1[bitsel], tc_p0[bitsel]};
    // palette: bit 3 of the name entry; with extended CRAM bits 7-5 extend it to
    // 16 palettes, and a palette never written aliases to palette (index AND 1)
    wire [3:0]  t_pal_raw = ext_cram ? {tc_hi[7:5], tc_hi[3]} : {3'b000, tc_hi[3]};
    wire [3:0]  t_pal     = (ext_cram && !pal_written[t_pal_raw]) ? {3'b000, t_pal_raw[0]} : t_pal_raw;

    // sprites
    reg  [6:0]  sidx;                // scan index, issue side
    reg  [6:0]  sidx_d1, sidx_d2;    // the index whose Y is on vb_dout
    reg         sv_d1, sv_d2;        // a scan read is in flight
    reg         scan_end;
    reg  [4:0]  scount;
    reg  [5:0]  ssel [0:15];
    reg  [4:0]  sdraw;
    reg  [7:0]  s_y, s_x, s_tile;
    reg  [7:0]  s_p0, s_p1, s_p2, s_p3;
    reg  [4:0]  s_tx;
    reg         col_found;
    reg  [7:0]  col_x_found;
    reg         ovr_found;
    wire [13:0] sat_base   = {r5[6:1], 8'h00};
    wire        spr_tall   = r1[1];
    wire        spr_zoom   = r1[0];
    wire [5:0]  spr_h      = (spr_tall ? 6'd16 : 6'd8) << spr_zoom;
    wire [4:0]  spr_limit  = spr16_line ? 5'd16 : 5'd8;
    wire [13:0] spr_pbase  = r6[2] ? 14'h2000 : 14'h0000;

    // Y test for the sprite whose Y byte is on vb_dout (Gearsystem rule: a sprite
    // whose Y+1 is in 241..256 also counts from Y+1-256, so it can wrap to the top)
    wire [9:0]  sy_n    = {2'b00, vb_dout} + 10'd1;
    wire signed [10:0] sy_s   = $signed({1'b0, sy_n});
    wire signed [10:0] sy_off = (sy_n > 10'd240) ? (sy_s - 11'sd256) : sy_s;
    wire signed [10:0] sl_s   = $signed({2'b00, sline});
    wire signed [10:0] sh_s   = $signed({5'b0, spr_h});
    wire        on_line = ((sl_s >= sy_s) && (sl_s < sy_s + sh_s)) ||
                          ((sl_s >= sy_off) && (sl_s < sy_off + sh_s));

    // drawn sprite
    wire [8:0]  spr_y1     = {1'b0, s_y} + 9'd1;
    wire signed [10:0] spr_ystart = ((spr_y1 > 9'd240) && (sline < height)) ? ($signed({2'b00, spr_y1}) - 11'sd256)
                                                                           : $signed({2'b00, spr_y1});
    wire signed [10:0] spr_dy = $signed({2'b00, sline}) - spr_ystart;
    wire [3:0]  spr_row_w  = spr_zoom ? spr_dy[4:1] : spr_dy[3:0];
    wire signed [10:0] spr_px = $signed({3'b000, s_x}) - (r0[3] ? 11'sd8 : 11'sd0) + $signed({6'd0, s_tx});
    wire [2:0]  spr_bit    = 3'd7 - (spr_zoom ? s_tx[3:1] : s_tx[2:0]);
    wire [3:0]  spr_c      = {s_p3[spr_bit], s_p2[spr_bit], s_p1[spr_bit], s_p0[spr_bit]};
    // The sprite buffer halves alternate per pass, not per line parity: PAL has
    // an odd line count, so line 312 and line 0 share a parity.
    reg         sb;                  // half composited this pass; the other is drawn
    wire [8:0]  spr_wa     = {~sb, spr_px[7:0]};

    // composite pipeline: stage 0 reads the line buffers at cx, stage 1 picks
    // the CRAM entry, stage 2 reads CRAM, stage 3 writes the output line
    reg  [8:0]  cx;
    reg  [8:0]  cx_d1, cx_d2, cx_d3;
    reg         cwr_d1, cwr_d2, cwr_d3;
    reg         sv_d;                // sprite pixel present at cx_d1
    reg  [8:0]  bgc;                 // bg_line[cx], registered read
    reg  [3:0]  spc;                 // spr_pix[{sb, cx}], registered read
    always @(posedge clk) begin
        bgc <= bg_line[cx[7:0]];
        spc <= spr_pix[{sb, cx[7:0]}];
    end

    always @(posedge clk) begin
        if (rst) begin
            rs <= R_IDLE; tc_valid <= 1'b0; spr_done <= 1'b0;
            sv_d1 <= 1'b0; sv_d2 <= 1'b0; sb <= 1'b0; comp_line <= 9'd0;
            spr_valid <= 512'd0;
            cwr_d1 <= 1'b0; cwr_d2 <= 1'b0; cwr_d3 <= 1'b0;
        end else begin
            spr_done <= 1'b0;
            sv_d1 <= 1'b0; sv_d2 <= sv_d1; sidx_d1 <= sidx; sidx_d2 <= sidx_d1;
            case (rs)
            R_IDLE: begin
                if (render_go) begin
                    rline <= ln;
                    sline <= ln_next;
                    rdisp <= disp_en;
                    rhs   <= hs_latch;
                    rvs   <= vs_latch;
                    sidx  <= 7'd0;
                    scount <= 5'd0;
                    scan_end <= 1'b0;
                    ovr_found <= 1'b0;
                    col_found <= 1'b0;
                    rs <= R_SCAN;
                end
            end

            // ------------------------------------------------ sprite scan
            // one SAT read per cycle; the Y byte arrives two cycles later
            R_SCAN: begin
                if (!scan_end && sidx < 7'd64) begin
                    vb_addr <= {1'b0, sat_base} + {8'd0, sidx};
                    sv_d1 <= 1'b1;
                    sidx <= sidx + 7'd1;
                end
                if (sv_d2 && !scan_end) begin
                    if (!ext_height && vb_dout == 8'hD0) scan_end <= 1'b1;
                    else if (on_line) begin
                        if (scount >= spr_limit) begin
                            if (sline < height) ovr_found <= 1'b1;
                            scan_end <= 1'b1;
                        end else begin
                            // stock overflow report while the limit is raised
                            if (ovf_stock && scount == 5'd8 && sline < height) ovr_found <= 1'b1;
                            ssel[scount[3:0]] <= sidx_d2[5:0];
                            scount <= scount + 5'd1;
                        end
                    end
                end
                if ((scan_end || sidx == 7'd64) && !sv_d1 && !sv_d2) begin
                    sdraw <= scount;
                    rsub <= 4'd0;
                    rs <= R_ATTR;
                end
            end
            // draw the selected sprites from the last to the first; a later write
            // wins, so sprite 0 ends on top (Gearsystem order, which fixes the
            // reported collision X)
            R_ATTR: begin
                if (sdraw == 5'd0) begin
                    rs <= R_BG_START;
                end else begin
                    case (rsub)
                    4'd0: begin vb_addr <= {1'b0, sat_base} + {9'd0, ssel[sdraw[3:0] - 4'd1]}; rsub <= 4'd1; end
                    4'd1: begin vb_addr <= {1'b0, sat_base} + 15'h80 + {8'd0, ssel[sdraw[3:0] - 4'd1], 1'b0}; rsub <= 4'd2; end
                    4'd2: begin s_y <= vb_dout; vb_addr <= vb_addr + 15'd1; rsub <= 4'd3; end
                    4'd3: begin s_x <= vb_dout; rsub <= 4'd4; end
                    4'd4: begin s_tile <= spr_tall ? (vb_dout & 8'hFE) : vb_dout; rsub <= 4'd0; rs <= R_PAT; end
                    default: rsub <= 4'd0;
                    endcase
                end
            end
            R_PAT: begin
                case (rsub)
                4'd0: begin
                    vb_addr <= {1'b0, spr_pbase} + {2'd0, s_tile, 5'd0} + {9'd0, spr_row_w, 2'b00};
                    rsub <= 4'd1;
                end
                4'd1: begin vb_addr <= vb_addr + 15'd1; rsub <= 4'd2; end
                4'd2: begin s_p0 <= vb_dout; vb_addr <= vb_addr + 15'd1; rsub <= 4'd3; end
                4'd3: begin s_p1 <= vb_dout; vb_addr <= vb_addr + 15'd1; rsub <= 4'd4; end
                4'd4: begin s_p2 <= vb_dout; rsub <= 4'd5; end
                4'd5: begin s_p3 <= vb_dout; s_tx <= 5'd0; rsub <= 4'd0; rs <= R_DRAW; end
                default: rsub <= 4'd0;
                endcase
            end
            R_DRAW: begin
                if (s_tx >= (spr_zoom ? 5'd16 : 5'd8) || spr_px > 11'sd255) begin
                    sdraw <= sdraw - 5'd1;
                    rsub <= 4'd0;
                    rs <= R_ATTR;
                end else begin
                    if (spr_px >= 11'sd0 && !(r0[5] && spr_px < 11'sd8) && spr_c != 4'd0) begin
                        if (spr_valid[spr_wa] && !col_found) begin
                            col_found <= 1'b1;
                            col_x_found <= spr_px[7:0];
                        end
                        spr_valid[spr_wa] <= 1'b1;
                        spr_pix[spr_wa]   <= spr_c;
                    end
                    s_tx <= s_tx + 5'd1;
                end
            end

            // ------------------------------------------------ background
            R_BG_START: begin
                // hand the sprite results for line L+1 to the event logic
                spr_done <= 1'b1;
                spr_ovr  <= ovr_found;
                spr_col  <= col_found;
                spr_colx <= col_x_found;
                spr_for  <= sline;
                x <= 9'd0;
                tc_valid <= 1'b0;
                rsub <= 4'd0;
                if (rdisp && rline < height) rs <= R_BG_PIX;
                else begin cx <= 9'd0; rs <= R_COMP; end
            end
            R_BG_FETCH: begin
                case (rsub)
                4'd0: begin vb_addr <= name_addr;          rsub <= 4'd1; end
                4'd1: begin vb_addr <= name_addr + 15'd1;  rsub <= 4'd2; end
                4'd2: begin tc_lo <= vb_dout;               rsub <= 4'd3; end
                4'd3: begin
                    tc_hi <= vb_dout;
                    vb_addr <= {1'b0, vb_dout[0], tc_lo, 5'b00000} +
                               {10'd0, (vb_dout[2] ? 3'd7 - fine_y : fine_y), 2'b00};
                    rsub <= 4'd4;
                end
                4'd4: begin vb_addr <= vb_addr + 15'd1; rsub <= 4'd5; end
                4'd5: begin tc_p0 <= vb_dout; vb_addr <= vb_addr + 15'd1; rsub <= 4'd6; end
                4'd6: begin tc_p1 <= vb_dout; vb_addr <= vb_addr + 15'd1; rsub <= 4'd7; end
                4'd7: begin tc_p2 <= vb_dout; rsub <= 4'd8; end
                4'd8: begin
                    tc_p3 <= vb_dout;
                    tc_name <= name_addr; tc_fy <= fine_y; tc_valid <= 1'b1;
                    rsub <= 4'd0;
                    rs <= R_BG_PIX;
                end
                default: rsub <= 4'd0;
                endcase
            end
            R_BG_PIX: begin
                if (!tc_valid || tc_name != name_addr || tc_fy != fine_y) begin
                    rsub <= 4'd0;
                    rs <= R_BG_FETCH;
                end else begin
                    bg_line[x[7:0]] <= {tc_hi[4] && (t_col != 4'd0), t_pal, t_col};
                    if (x == 9'd255) begin cx <= 9'd0; rs <= R_COMP; end
                    x <= x + 9'd1;
                end
            end

            // ------------------------------------------------ composite
            R_COMP: begin
                // stage 0: buffers are read at cx (bgc/spc next cycle)
                if (cx <= 9'd255) begin
                    sv_d <= spr_valid[{sb, cx[7:0]}];
                    spr_valid[{sb, cx[7:0]}] <= 1'b0;         // free for the pass after next
                    cx <= cx + 9'd1;
                end
                cx_d1 <= cx; cwr_d1 <= (cx <= 9'd255);
                // stage 1: choose the CRAM entry
                if (cwr_d1) begin
                    if (!rdisp || rline >= height || (r0[5] && cx_d1 < 9'd8))
                        cb_addr <= {4'b0001, r7[3:0]};
                    else if (sv_d && !bgc[8])
                        cb_addr <= {4'b0001, spc};
                    else
                        cb_addr <= bgc[7:0];
                end
                cx_d2 <= cx_d1; cwr_d2 <= cwr_d1;
                // stage 2: CRAM read; stage 3: write the output line
                cx_d3 <= cx_d2; cwr_d3 <= cwr_d2;
                if (cwr_d3) out_line[{rline[1:0], cx_d3[7:0]}] <= cb_dout;
                if (cx > 9'd255 && !cwr_d1 && !cwr_d2 && !cwr_d3) rs <= R_DONE;
            end
            R_DONE: begin sb <= ~sb; comp_line <= rline; rs <= R_IDLE; end
            default: rs <= R_IDLE;
            endcase
        end
    end

    // =====================================================================
    // video out: line N is shown during VDP line N+2
    // =====================================================================
    // Raster: 342 pixels per line (228 base cycles x 1.5); active 256 pixels from
    // pixel PX_ACTIVE. The composite of line N starts at line N's render event and
    // can run into line N+1 (up to ~80 pixels with 16 magnified sprites), so the
    // output ring holds four lines and line N is read a whole line later, during
    // VDP line N+2. Nothing the CPU sees depends on this delay.
    reg [8:0] px;                    // pixel within the line
    localparam PX_ACTIVE = 9'd64;
    wire [8:0] out_ln = (ln >= 9'd2) ? ln - 9'd2 : ln + lines - 9'd2;
    wire [8:0] px_rel = px - PX_ACTIVE;
    // registered read of the output ring; px is stable for ten clocks before
    // each pixel enable, so ol_q always holds the pixel at px
    reg [11:0] ol_q;
    always @(posedge clk) ol_q <= out_line[{out_ln[1:0], px_rel[7:0]}];

    always @(posedge clk) begin
        if (rst) begin
            px <= 9'd0; vid_de <= 1'b0; vid_hs <= 1'b0; vid_vs <= 1'b0; vid_rgb <= 12'h000;
            vid_frame <= 1'b0;
        end else begin
            if (ce_cyc && hc == 8'd227) px <= 9'd0;           // realign at each line start
            if (ce_pix) begin
                vid_hs <= 1'b0; vid_vs <= 1'b0; vid_frame <= 1'b0; vid_de <= 1'b0; vid_rgb <= 12'h000;
                if (px < 9'd341) px <= px + 9'd1;
                // VS at pixel 0 of VDP line (height + 2), after the last active
                // line has left (during line height + 1); HS at pixel 4 of every line
                if (px == 9'd0 && ln == height + 9'd2) vid_vs <= 1'b1;
                if (px == 9'd4) vid_hs <= 1'b1;
                if (px >= PX_ACTIVE && px < PX_ACTIVE + 9'd256 && out_ln < height) begin
                    if (!gg_crop || (out_ln >= 9'd24 && out_ln < 9'd168 &&
                                     px_rel >= 9'd48 && px_rel < 9'd208)) begin
                        vid_de  <= 1'b1;
                        vid_rgb <= ol_q;
                        if (out_ln == (gg_crop ? 9'd24 : 9'd0) &&
                            px_rel == (gg_crop ? 9'd48 : 9'd0)) vid_frame <= 1'b1;
                    end
                end
            end
        end
    end

`ifdef VERILATOR
    // debug: +cramlog prints every CRAM write, +vdplog every port access
    reg log_cram, log_vdp;
    initial begin log_cram = $test$plusargs("cramlog"); log_vdp = $test$plusargs("vdplog"); end
    always @(posedge clk) begin
        if (log_cram && ca_we) $display("CRAM[%0d] <= %03h  (line %0d)", ca_addr, ca_din, ln);
        if (log_vdp && io_wr && port_vdp) $display("VDP %s <= %02h  (line %0d hc %0d)", port_ctrl ? "ctl" : "dat", io_din, ln, hc);
    end

    // check: when line N starts to leave, its composite has finished and the
    // composite of N+2 (same ring slot) has not started
    integer late_count = 0;
    always @(posedge clk) begin
        if (!rst && ce_pix && px == PX_ACTIVE && out_ln < height) begin
            if (!(comp_line == out_ln || comp_line == ((out_ln + 9'd1 == lines) ? 9'd0 : out_ln + 9'd1))) begin
                if (late_count < 5) $display("ss_vdp: output line %0d read with composite at line %0d", out_ln, comp_line);
                late_count = late_count + 1;
            end
        end
    end
`endif

endmodule

`default_nettype wire
