// Headless Gearsystem runner used ONLY as an independent test oracle.
bool g_mcp_stdio_mode = false;
// Gearsystem (GPL-3) is not part of any deliverable; this file links to it locally.
// usage: gsrun rom.sms frames outprefix dumpFrame1 dumpFrame2 ...
//   writes outprefix_N.ppm (RGB) and outprefix_N.ram (8 KB work RAM) for each dump frame
#include "GearsystemCore.h"
#include "Memory.h"
#include "Video.h"
#include "Processor.h"
#include <cstdio>
#include <cstdlib>
#include <vector>
#include <string>
#include <algorithm>
int main(int argc, char** argv) {
    if (argc < 4) { fprintf(stderr, "usage\n"); return 1; }
    const char* rom = argv[1];
    int frames = atoi(argv[2]);
    std::string pre = argv[3];
    std::vector<int> dumps;
    for (int i = 4; i < argc; i++) dumps.push_back(atoi(argv[i]));
    GearsystemCore* core = new GearsystemCore();
    core->Init(GS_PIXEL_RGBA8888);
    if (!core->LoadROM(rom)) { fprintf(stderr, "load failed\n"); return 2; }
    bool gg = core->GetCartridge()->IsGameGear();
    std::vector<u8> fb(GS_RESOLUTION_MAX_WIDTH_WITH_OVERSCAN * GS_RESOLUTION_MAX_HEIGHT_WITH_OVERSCAN * 4);
    std::vector<s16> snd(GS_AUDIO_BUFFER_SIZE * 4);
    for (int f = 0; f < frames; f++) {
        int phase = f % 120;
        // same scripted input as the JS harness: button 1 at phase 90-95;
        // Start (GG only: on SMS it would raise Pause) at phase 60-65
        if (phase == 90) core->KeyPressed(Joypad_1, Key_1);
        if (phase == 96) core->KeyReleased(Joypad_1, Key_1);
        if (gg && phase == 60) core->KeyPressed(Joypad_1, Key_Start);
        if (gg && phase == 66) core->KeyReleased(Joypad_1, Key_Start);
        int n = 0;
        core->RunToVBlank(fb.data(), snd.data(), &n);
        if (std::find(dumps.begin(), dumps.end(), f + 1) != dumps.end()) {
            GS_RuntimeInfo ri; core->GetRuntimeInfo(ri);
            char name[512];
            snprintf(name, sizeof name, "%s_%d.ppm", pre.c_str(), f + 1);
            FILE* o = fopen(name, "wb");
            fprintf(o, "P6\n%d %d\n255\n", ri.screen_width, ri.screen_height);
            for (int i = 0; i < ri.screen_width * ri.screen_height; i++) fwrite(&fb[i*4], 1, 3, o);
            fclose(o);
            snprintf(name, sizeof name, "%s_%d.ram", pre.c_str(), f + 1);
            o = fopen(name, "wb");
            for (int a = 0xC000; a < 0xE000; a++) { u8 v = core->GetMemory()->Retrieve(a); fwrite(&v, 1, 1, o); }
            fclose(o);
        }
    }
    printf("ok gg=%d\n", gg ? 1 : 0);
    return 0;
}
