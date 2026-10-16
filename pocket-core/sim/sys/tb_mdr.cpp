// MasterDrive machine - Verilator system harness.
//
// Runs a ROM on the RTL machine with the same scripted input as the reference
// tools (button 1 at frames 90-95 of every 120; Start at 60-65 in GG mode),
// captures frames, and optionally writes an instruction trace in the record
// format of ../ref/gstrace.cpp so the CPU/VDP timing can be compared with
// Gearsystem cycle for cycle.
//
// usage: tb_mdr rom mode(sms|gg|ss) frames outprefix [options] [dumpframes...]
//   options: -pal  -gg1 (315-5535 timing; default for all modes)  -sms2 (SMS2 timing)
//            enhancement layer: -spr16 -ovf -turbo N -vboost -afire -pstereo
//                            -tmsapprox (TMS modes in the SMS approximation; true TMS colours by default)
//                            (-turbo N: N = 1-4 for 125/150/175/200 %; sms/gg only)
//            -holdc          hold C throughout (auto-fire checks)
//            -wav FILE       48 kHz stereo capture of the audio output
//            -trace N file   write the first N instruction starts
//            -lat N          ROM bus latency in system cycles (default 4)
#include "Vmdr_top.h"
#include "verilated.h"
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <vector>
#include <string>
#include <set>
#include <cstdint>

static std::vector<uint8_t> load(const char* p) {
    FILE* f = fopen(p, "rb");
    if (!f) { perror(p); exit(2); }
    std::vector<uint8_t> v;
    uint8_t buf[65536];
    size_t n;
    while ((n = fread(buf, 1, sizeof buf, f)) > 0) v.insert(v.end(), buf, buf + n);
    fclose(f);
    if (v.size() % 1024 == 512) v.erase(v.begin(), v.begin() + 512);
    return v;
}

#pragma pack(push, 1)
struct Rec { uint16_t pc, sp; uint8_t a, f; uint32_t cyc; uint16_t line; };
#pragma pack(pop)

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    if (argc < 5) { fprintf(stderr, "usage\n"); return 1; }
    std::vector<uint8_t> rom = load(argv[1]);
    std::string mode = argv[2];
    long frames = atol(argv[3]);
    std::string pre = argv[4];
    bool pal = false, sms2 = false, hold_c = false;
    long trace_n = 0; FILE* trace_f = nullptr;
    int lat = 4;
    int ael_spr = 0, ael_ovf = 0, ael_turbo = 0, ael_vboost = 0, ael_afire = 0, ael_pst = 0, ael_tmscol = 1;
    FILE* wav_f = nullptr; std::vector<int16_t> wav; uint64_t wav_acc = 0;
    std::set<long> dumps;
    for (int i = 5; i < argc; i++) {
        if (!strcmp(argv[i], "-pal")) pal = true;
        else if (!strcmp(argv[i], "-sms2")) sms2 = true;
        else if (!strcmp(argv[i], "-gg1")) sms2 = false;
        else if (!strcmp(argv[i], "-trace")) { trace_n = atol(argv[++i]); trace_f = fopen(argv[++i], "wb"); }
        else if (!strcmp(argv[i], "-lat")) lat = atoi(argv[++i]);
        else if (!strcmp(argv[i], "-spr16")) ael_spr = 1;
        else if (!strcmp(argv[i], "-ovf")) ael_ovf = 1;
        else if (!strcmp(argv[i], "-turbo")) ael_turbo = atoi(argv[++i]);
        else if (!strcmp(argv[i], "-vboost")) ael_vboost = 1;
        else if (!strcmp(argv[i], "-afire")) ael_afire = 1;
        else if (!strcmp(argv[i], "-holdc")) hold_c = true;
        else if (!strcmp(argv[i], "-pstereo")) ael_pst = 1;
        else if (!strcmp(argv[i], "-tmsapprox")) ael_tmscol = 0;
        else if (!strcmp(argv[i], "-wav")) wav_f = fopen(argv[++i], "wb");
        else dumps.insert(atol(argv[i]));
    }
    uint32_t pow2 = 1; while (pow2 < rom.size()) pow2 <<= 1;

    Vmdr_top* t = new Vmdr_top;
    t->mode = (mode == "gg") ? 1 : (mode == "ss") ? 5 : (mode == "sg") ? 2 : (mode == "sc") ? 3 : 0;
    t->mapper = 0; t->pal = pal; t->jp_region = 0; t->timing_gg = !sms2; t->sc_ram32 = 0;
    t->rom_mask = pow2 - 1; t->card_present = 0; t->card_mask = 0; t->gg_crop = (mode == "gg");
    t->ael_sprlimit = ael_spr; t->ael_startpause = 0; t->ael_ovf_stock = ael_ovf; t->ael_turbo = ael_turbo;
    t->ael_vramboost = ael_vboost; t->ael_autofire = ael_afire; t->ael_pstereo = ael_pst; t->ael_tmscol = ael_tmscol;
    t->pad1 = 0; t->pad2 = 0; t->pause_btn = 0; t->reset_btn = 0; t->kb_ghosting = 1;
    for (int i = 0; i < 3; i++) t->kb_keys[i] = 0;
    t->sv_clk = 0; t->sv_we = 0; t->sv_addr = 0; t->sv_din = 0;
    t->rom_ack = 0; t->rom_data = 0;

    // reset
    t->reset = 1;
    for (int i = 0; i < 40; i++) { t->clk_sys = 0; t->eval(); t->clk_sys = 1; t->eval(); }
    t->reset = 0;

    const int W = 256, H = 240;
    std::vector<uint32_t> fb(W * H, 0);
    int fx = 0, fy = 0; bool de_prev = false;
    long frame = 0;
    int rom_cnt = -1; bool req_prev = false;
    long traced = 0; uint32_t cyc0 = 0; bool have_cyc0 = false;
    int pstate = 0; bool pend = false; Rec pr = {};
    long dumped = 0;
    uint64_t sys = 0;

    while (frame < frames) {
        // inputs for this frame
        int phase = frame % 120;
        uint8_t p1 = 0;
        if (phase >= 90 && phase < 96) p1 |= 0x10;          // button 1 / A... TL
        if (mode == "gg" && phase >= 60 && phase < 66) p1 |= 0x80;  // Start
        if (hold_c) p1 |= 0x40;                              // C held throughout
        t->pad1 = p1;

        // one system clock
        t->clk_sys = 0; t->eval();
        t->clk_sys = 1; t->eval();
        sys++;

        // audio: 48 kHz samples of the machine's (unfiltered) output
        if (wav_f) {
            wav_acc += 48000;
            if (wav_acc >= 53693175ULL) { wav_acc -= 53693175ULL; wav.push_back((int16_t)t->audio_l); wav.push_back((int16_t)t->audio_r); }
        }

        // ROM bus: fixed latency
        if (t->rom_req && !req_prev) rom_cnt = lat;
        req_prev = t->rom_req;
        t->rom_ack = 0;
        if (rom_cnt > 0) rom_cnt--;
        else if (rom_cnt == 0) {
            uint32_t a = t->rom_addr;
            t->rom_data = (a & 0x800000) ? 0xFF : rom[(a & (pow2 - 1)) % rom.size()];
            t->rom_ack = 1;
            rom_cnt = -1;
        }

        // trace. An M1 begins at dbg_m1 (T1); whether it starts an instruction is
        // known when its opcode is latched (dbg_fetch, end of T2):
        //   after nothing     -> start;  DD/FD -> IX state;  ED/CB -> one continuation
        //   in IX state       -> DD/FD starts anew (the first prefix acted alone),
        //                        CB ends the M1 sequence (DDCB d op), ED continues once
        if (trace_f && traced < trace_n) {
            if (t->dbg_m1 && !t->dbg_int_ack) {
                pend = true;
                pr.pc = t->dbg_addr; pr.sp = t->dbg_sp; pr.a = t->dbg_a; pr.f = t->dbg_f;
                pr.cyc = t->dbg_cycles; pr.line = t->dbg_line;
            }
            if (t->dbg_fetch && pend) {
                // SP is taken here, not at T1: tv80 writes the high byte of a
                // 16-bit SP load during the next instruction's T1.
                pr.sp = t->dbg_sp;
                uint8_t op = t->dbg_op;
                bool halted = false;
                bool start = (pstate == 0) || (pstate == 1 && (op == 0xDD || op == 0xFD));
                if (pstate == 0) pstate = (op == 0xDD || op == 0xFD) ? 1 : (op == 0xED || op == 0xCB) ? 2 : 0;
                else if (pstate == 1) pstate = (op == 0xDD || op == 0xFD) ? 1 : (op == 0xED) ? 2 : 0;
                else pstate = 0;
                (void)halted;
                if (start) {
                    if (!have_cyc0) { cyc0 = pr.cyc; have_cyc0 = true; }
                    pr.cyc -= cyc0;
                    fwrite(&pr, sizeof pr, 1, trace_f);
                    traced++;
                }
                pend = false;
            }
        }

        // frame timing: clk_sys and base cycles between VS pulses
        if (t->vid_ce && t->vid_vs) {
            static uint64_t vs_sys = 0; static uint32_t vs_cyc = 0; static long nvs = 0;
            static uint64_t mn = ~0ull, mx = 0, tot = 0; static uint32_t cmn = ~0u, cmx = 0; static long nmeas = 0;
            if (nvs >= 2) {
                uint64_t d = sys - vs_sys; uint32_t c = t->dbg_cycles - vs_cyc;
                if (d < mn) mn = d; if (d > mx) mx = d; if (c < cmn) cmn = c; if (c > cmx) cmx = c;
                tot += d; nmeas++;
                if (frame + 1 == frames)
                    printf("frame timing over %ld frames: clk_sys %llu-%llu (mean %.3f, %.4f Hz at 53693175), base cycles %u-%u\n",
                           nmeas, (unsigned long long)mn, (unsigned long long)mx, (double)tot / nmeas,
                           53693175.0 * nmeas / tot, cmn, cmx);
            }
            vs_sys = sys; vs_cyc = t->dbg_cycles; nvs++;
        }
        // video capture
        if (t->vid_ce) {
            if (t->vid_vs) {
                if (dumps.count(frame + 1)) {
                    // width from the crop; height = active lines seen this frame
                    int w = (mode == "gg") ? 160 : 256, h = (fy > 0 && fy <= H) ? fy : 192;
                    char name[512]; snprintf(name, sizeof name, "%s_%ld.ppm", pre.c_str(), frame + 1);
                    FILE* o = fopen(name, "wb");
                    if (!o) { perror(name); exit(1); }
                    fprintf(o, "P6\n%d %d\n255\n", w, h);
                    for (int y = 0; y < h; y++) for (int x = 0; x < w; x++) {
                        uint32_t v = fb[y * W + x];
                        uint8_t px[3] = { (uint8_t)((v & 15) * 17), (uint8_t)(((v >> 4) & 15) * 17), (uint8_t)(((v >> 8) & 15) * 17) };
                        fwrite(px, 1, 3, o);
                    }
                    fclose(o);
                    dumped++;
                }
                frame++;
                fy = 0; fx = 0;
            }
            if (t->vid_de) {
                if (fx < W && fy < H) fb[fy * W + fx] = t->vid_bgr;
                fx++;
            } else if (de_prev) { fx = 0; fy++; }
            de_prev = t->vid_de;
        }
    }
    if (trace_f) fclose(trace_f);
    if (wav_f) {
        uint32_t n = (uint32_t)wav.size() * 2;
        auto w32 = [&](uint32_t v) { fwrite(&v, 4, 1, wav_f); };
        auto w16 = [&](uint16_t v) { fwrite(&v, 2, 1, wav_f); };
        fwrite("RIFF", 1, 4, wav_f); w32(36 + n); fwrite("WAVEfmt ", 1, 8, wav_f);
        w32(16); w16(1); w16(2); w32(48000); w32(48000 * 4); w16(4); w16(16);
        fwrite("data", 1, 4, wav_f); w32(n); fwrite(wav.data(), 2, wav.size(), wav_f);
        fclose(wav_f);
    }
    printf("frames %ld sys %llu dumped %ld traced %ld\n", frame, (unsigned long long)sys, dumped, traced);
    t->final();
    delete t;
    return 0;
}
