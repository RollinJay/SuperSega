// MasterDrive - Pocket platform-layer simulation.
//
// Drives tb_pocket_top (mdr_pocket + machine + PSRAM model) the way the APF
// does: the core is held in reset, the cartridge is written over the bridge
// (data slot 0 at $1000_0000, 32-bit big-endian words), optionally a save
// (slot 1 at $2000_0000), the persisted interact settings are written, then
// reset is released. Frames are captured from the scaler-side video bus
// (pixel clock domain) and the end-of-line scaler-slot word is checked.
//
// The machine starts in its BIOS (Technical Reference section 20): the harness
// holds Start for the first two frames after every cold reset, the BIOS's skip
// path, and counts frames (and the input script and -setat) from the BIOS's
// first launch, as tb_mdr does. Each launch prints the machine it starts
// ("launch: machine N", 0 SMS, 1 GG, 2 SG-1000, 3 SC-3000, 5 MasterDrive).
//
// usage: tb_pocket rom frames outprefix [options] [dumpframes...]
//   -pal             interact Video = PAL
//   -system N        interact System (0 auto ... 5 SC-3000)
//   -set ADDR VAL    any interact write (hex address, decimal value)
//   -gap N           clk_74a cycles between bridge words (default 32: the APF maximum)
//   -save FILE       load FILE into the save slot before reset is released
//   -readsave FILE   after the last frame, read the save slot back over the bridge
//   -hold BIT        hold APF controller-1 key BIT throughout (4 A, 5 B, 7 Y)
//   -setat F D A V   in frame F, D clk_sys cycles in, make interact write A = V
//                    (a setting changed while the machine runs, e.g. Video)
//   -trunc N         load only the first N bytes of the ROM file
//   +stale           (psram_model) PSRAM starts with an earlier cartridge's headers
//
// After the last frame it prints a timing line for the video bus: the HS
// period in clk_vid cycles (with a histogram of the periods seen more than
// twice), the VS period and frame rate, HS pulses per frame, the DE run per
// line, DE lines per frame, the shortest VS-to-HS gap, the clk_vid cycles in
// which HS or VS stayed high for more than one cycle, and the clk_vid cycles
// with video_skip set. The frame lengths (VS period, HS and DE lines per frame)
// leave out a VS period in which the machine was reset or its BIOS launched the
// game: the VDP starts again at line 0 there, and the picture's height can change
// (the BIOS's 192 lines, the game's 224 or 240), so that one frame has its own
// length; the line timing (HS period) is measured throughout. The count of
// periods left out ends the line. Then a line with the frames run and dumped, the last
// scaler slot, the slot-word errors and save_present (sim/check.sh requires
// 0 errors), with -readsave a line naming the file, and last the machine's
// enable check (mdr_top, Verilator only; sim/check.sh requires 0 violations).
#include "Vtb_pocket_top.h"
#include "verilated.h"
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <cstdint>
#include <string>
#include <vector>
#include <set>
#include <map>

static std::vector<uint8_t> load(const char* p) {
    FILE* f = fopen(p, "rb");
    if (!f) { perror(p); exit(2); }
    std::vector<uint8_t> v; uint8_t b[65536]; size_t n;
    while ((n = fread(b, 1, sizeof b, f)) > 0) v.insert(v.end(), b, b + n);
    fclose(f);
    return v;
}

static Vtb_pocket_top* t;
static uint64_t now = 0;                       // ps
static const uint64_t P74 = 13468, PSYS = 18624;
static uint64_t n74 = 0, nsys = 0;
static int sys_phase = 0;                      // counts clk_sys half periods for clk_vid
static bool vid_rose = false;

// advance to the next clock edge; returns which clock moved
static void step() {
    if (n74 <= nsys) {
        now = n74; t->clk_74a = !t->clk_74a; n74 += P74 / 2;
    } else {
        now = nsys; t->clk_sys = !t->clk_sys; nsys += PSYS / 2;
        // clk_vid = clk_sys / 10, rising with every tenth rising edge of clk_sys
        sys_phase = (sys_phase + 1) % 20;
        if (sys_phase == 1) { t->clk_vid = 1; vid_rose = true; }
        else if (sys_phase == 11) t->clk_vid = 0;
    }
    t->eval();
}
// run until the next rising edge of clk_74a has been evaluated
static void on_vid_edge();
static void tick74() {
    for (;;) {
        bool was = t->clk_74a; step();
        if (vid_rose) { vid_rose = false; on_vid_edge(); }
        if (!was && t->clk_74a) return;
    }
}

// video capture state
static const int W = 256, H = 240;
static std::vector<uint32_t> fb(W * H);
static int fx = 0, fy = 0; static bool de_prev = false;
static long frame = 0; static std::set<long> dumps; static std::string pre;
static int slot_word = -1, slot_errors = 0, last_slot = -1;
static long dumped = 0;
static int frame_w = 0;

// scaler-side timing, in clk_vid cycles
static uint64_t vcyc = 0, last_hs = 0, last_vs = 0;
static long hs_n = 0, vs_n = 0, hs_mn = 1 << 30, hs_mx = 0, vs_mn = 1 << 30, vs_mx = 0;
static long ln_mn = 1 << 30, ln_mx = 0, lines_in_frame = 0, de_run = 0, de_mn = 1 << 30, de_mx = 0;
static long del_mn = 1 << 30, del_mx = 0, de_lines = 0, vshs_mn = 1 << 30, wide = 0, skips = 0;
static std::map<long, long> hs_hist;
static bool hs_prev = false, vs_prev = false;
static bool restart = false; static long left_out = 0;     // a reset or launch since the last VS
static void timing_edge() {
    vcyc++;
    bool hs = t->video_hs, vs = t->video_vs, de = t->video_de;
    if (t->video_skip) skips++;
    if ((hs && hs_prev) || (vs && vs_prev)) wide++;                 // HS and VS must be one cycle
    if (vs && !vs_prev) {
        if (vs_n >= 2 && restart) left_out++;
        else if (vs_n >= 2) {
            long d = (long)(vcyc - last_vs);
            if (d < vs_mn) vs_mn = d; if (d > vs_mx) vs_mx = d;
            if (lines_in_frame < ln_mn) ln_mn = lines_in_frame; if (lines_in_frame > ln_mx) ln_mx = lines_in_frame;
            if (de_lines < del_mn) del_mn = de_lines; if (de_lines > del_mx) del_mx = de_lines;
        }
        last_vs = vcyc; vs_n++; lines_in_frame = 0; de_lines = 0; restart = false;
    }
    if (hs && !hs_prev) {
        if (vs_n >= 2) { long d = (long)(vcyc - last_hs); if (d < hs_mn) hs_mn = d; if (d > hs_mx) hs_mx = d; hs_hist[d]++; }
        if (vs_n >= 1) { long g = (long)(vcyc - last_vs); if (g < vshs_mn && g < 400) vshs_mn = g; }
        last_hs = vcyc; hs_n++; lines_in_frame++;
    }
    if (de) de_run++;
    else if (de_run) { if (vs_n >= 2) { if (de_run < de_mn) de_mn = de_run; if (de_run > de_mx) de_mx = de_run; } de_run = 0; de_lines++; }
    hs_prev = hs; vs_prev = vs;
}
static void on_vid_edge() {
    timing_edge();
    if (t->video_vs) {
        if (dumps.count(frame + 1)) {
            int w = frame_w ? frame_w : 256, h = fy ? fy : 192;
            char name[512]; snprintf(name, sizeof name, "%s_%ld.ppm", pre.c_str(), frame + 1);
            FILE* o = fopen(name, "wb");
            if (!o) { perror(name); exit(1); }
            fprintf(o, "P6\n%d %d\n255\n", w, h);
            for (int y = 0; y < h; y++) for (int x = 0; x < w; x++) {
                uint32_t v = fb[y * W + x];
                uint8_t px[3] = { (uint8_t)(v >> 16), (uint8_t)(v >> 8), (uint8_t)v };
                fwrite(px, 1, 3, o);
            }
            fclose(o); dumped++;
        }
        frame++; fy = 0; fx = 0; frame_w = 0;
    }
    if (t->video_de) {
        if (fx < W && fy < H) fb[fy * W + fx] = t->video_rgb;
        fx++;
    } else if (de_prev) {
        // first cycle after DE: the end-of-line word must carry a scaler slot
        uint32_t v = t->video_rgb;
        if ((v & 0x1FFF) != 0 || (v >> 16) != 0) slot_errors++;
        last_slot = (v >> 13) & 7;
        if (fx > frame_w) frame_w = fx;
        fx = 0; fy++;
    }
    de_prev = t->video_de;
}

static bool launched = false; static long bios_frames = 0;
static bool in_bios = true, mreset_d = true; static long start_until = 2;   // Start held in the BIOS until this frame
static void run_sys_cycles(long n) {
    // run n clk_sys rising edges, servicing video
    long c = 0;
    while (c < n) {
        bool was = t->clk_sys; step();
        if (vid_rose) { vid_rose = false; on_vid_edge(); }
        if (!was && t->clk_sys) {
            c++;
            if (t->dbg_launch || t->dbg_mreset) restart = true;
            if (mreset_d && !t->dbg_mreset) { in_bios = true; start_until = frame + 2; }   // a cold reset ends
            mreset_d = t->dbg_mreset;
            if (t->dbg_launch) {
                in_bios = false;
                printf("launch: machine %d\n", (int)t->dbg_mode);
            }
            if (!launched && t->dbg_launch) {        // the game starts: count from here
                launched = true; bios_frames = frame; frame = 0; fx = 0; fy = 0; frame_w = 0;
            }
        }
    }
}

// The APF bridge sends each 32-bit write as its own SPI transaction: 4 address
// and 4 data bytes at 2 bits per clock, 32 clocks of at most 74.25 MHz, so a
// write every 431 ns at the fastest. 32 clk_74a cycles models that rate.
static int gap = 32;
static void bridge_write(uint32_t addr, uint32_t data) {
    t->bridge_addr = addr; t->bridge_wr_data = data; t->bridge_wr = 1;
    tick74();
    t->bridge_wr = 0;
    for (int i = 0; i < gap; i++) tick74();
}
static uint32_t bridge_read(uint32_t addr) {
    t->bridge_addr = addr; t->bridge_rd = 1;
    tick74();
    t->bridge_rd = 0;
    for (int i = 0; i < 120; i++) tick74();
    return t->save_rd_data;
}
static void slot_load(uint16_t id, uint32_t base, const std::vector<uint8_t>& d) {
    t->dataslot_requestwrite = 1; t->dataslot_requestwrite_id = id;
    t->dataslot_requestwrite_size = (uint32_t)d.size();
    tick74(); t->dataslot_requestwrite = 0;
    for (int i = 0; i < 20; i++) tick74();
    for (size_t o = 0; o < d.size(); o += 4) {
        uint32_t w = 0;
        for (int k = 0; k < 4; k++) w = (w << 8) | (o + k < d.size() ? d[o + k] : 0);
        bridge_write(base + (uint32_t)o, w);
    }
}

static long setat_f = -1, setat_d = 0; static uint32_t setat_a = 0, setat_v = 0;
int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    if (argc < 4) { fprintf(stderr, "usage: tb_pocket rom frames outprefix [options] [dumps...]\n"); return 1; }
    std::vector<uint8_t> rom = load(argv[1]);
    long frames = atol(argv[2]);
    pre = argv[3];
    std::vector<std::pair<uint32_t, uint32_t>> sets;
    std::string savefile, readsave;
    uint32_t hold = 0;
    for (int i = 4; i < argc; i++) {
        if (!strcmp(argv[i], "-pal")) sets.push_back({0x108, 1});
        else if (!strcmp(argv[i], "-system")) sets.push_back({0x100, (uint32_t)atoi(argv[++i])});
        else if (!strcmp(argv[i], "-set")) { uint32_t a = strtoul(argv[i + 1], 0, 16); uint32_t v = atoi(argv[i + 2]); i += 2; sets.push_back({a, v}); }
        else if (!strcmp(argv[i], "-gap")) gap = atoi(argv[++i]);
        else if (!strcmp(argv[i], "-setat")) { setat_f = atol(argv[i + 1]); setat_d = atol(argv[i + 2]);
            setat_a = strtoul(argv[i + 3], 0, 16); setat_v = atoi(argv[i + 4]); i += 4; }
        else if (!strcmp(argv[i], "-save")) savefile = argv[++i];
        else if (!strcmp(argv[i], "-readsave")) readsave = argv[++i];
        else if (!strcmp(argv[i], "-hold")) hold |= 1u << atoi(argv[++i]);
        else if (!strcmp(argv[i], "-trunc")) { size_t n = atol(argv[++i]); if (n < rom.size()) rom.resize(n); }
        else if (argv[i][0] == '+') ;           // a plusarg, for the models
        else dumps.insert(atol(argv[i]));
    }
    bool gg = rom.size() > 0 && std::string(argv[1]).size() > 3 &&
              std::string(argv[1]).substr(std::string(argv[1]).size() - 3) == ".gg";

    t = new Vtb_pocket_top;
    t->clk_74a = 0; t->clk_sys = 0; t->clk_vid = 0;
    t->pll_locked = 0; t->apf_reset_n = 0;
    t->bridge_addr = 0; t->bridge_rd = 0; t->bridge_wr = 0; t->bridge_wr_data = 0;
    t->dataslot_requestwrite = 0; t->dataslot_requestwrite_id = 0; t->dataslot_requestwrite_size = 0;
    t->dataslot_allcomplete = 0;
    t->cont1_key = 0x10000000; t->cont2_key = 0; t->cont3_key = 0; t->cont3_joy = 0; t->cont3_trig = 0;
    t->eval();
    for (int i = 0; i < 50; i++) tick74();
    t->pll_locked = 1;
    for (int i = 0; i < 50; i++) tick74();

    // APF: load the data slots while the core is held in reset
    slot_load(0, 0x10000000, rom);
    if (!savefile.empty()) slot_load(1, 0x20000000, load(savefile.c_str()));
    t->dataslot_allcomplete = 1; tick74(); t->dataslot_allcomplete = 0;
    for (int i = 0; i < 20; i++) tick74();
    // persisted interact values, then Reset Exit
    for (auto& s : sets) bridge_write(s.first, s.second);
    t->apf_reset_n = 1;

    // frames, with the same scripted input as the other harnesses; in the BIOS,
    // Start for its first two frames
    while (!launched || frame < frames) {
        if (!launched && frame > 200) { fprintf(stderr, "tb_pocket: the BIOS did not launch in 200 frames\n"); return 1; }
        long phase = frame % 120;
        uint32_t k = 0x10000000 | hold;
        if (in_bios) { if (frame < start_until) k |= 1u << 15; }
        else {
            if (phase >= 90 && phase < 96) k |= 1u << 4;        // face_a = pad A (button 1), as tb_mdr
            if (gg && phase >= 60 && phase < 66) k |= 1u << 15; // Start
        }
        t->cont1_key = k;
        if (launched && setat_f >= 0 && frame == setat_f) {
            run_sys_cycles(setat_d);
            printf("interact write $%03X = %u in frame %ld\n", setat_a, setat_v, frame);
            bridge_write(setat_a, setat_v);
            setat_f = -1;
        }
        run_sys_cycles(1000);
    }
    printf("timing: HS period %ld-%ld", hs_mn, hs_mx);
    for (auto& h : hs_hist) if (h.second > 2) printf(" [%ld x%ld]", h.first, h.second);
    printf("; VS period %ld-%ld (%.4f-%.4f Hz); HS per frame %ld-%ld; DE run %ld-%ld; DE lines %ld-%ld; VS->HS min %ld; wide HS/VS %ld; skip %ld; frames across a reset or launch %ld\n",
           vs_mn, vs_mx, 5369317.5 / vs_mx, 5369317.5 / vs_mn, ln_mn, ln_mx, de_mn, de_mx, del_mn, del_mx, vshs_mn, wide, skips, left_out);
    printf("BIOS launched after %ld frames\n", bios_frames);
    printf("frames %ld dumped %ld slot %d slot-word errors %d save_present %d\n",
           frame, dumped, last_slot, slot_errors, (int)t->save_present);

    if (!readsave.empty()) {
        FILE* o = fopen(readsave.c_str(), "wb");
        for (uint32_t a = 0; a < 0x8000; a += 4) {
            uint32_t v = bridge_read(0x20000000 + a);
            uint8_t b[4] = { (uint8_t)(v >> 24), (uint8_t)(v >> 16), (uint8_t)(v >> 8), (uint8_t)v };
            fwrite(b, 1, 4, o);
        }
        fclose(o);
        printf("save read back to %s\n", readsave.c_str());
    }
    t->final();                                  // runs the enable check's final report
    delete t;
    return 0;
}
