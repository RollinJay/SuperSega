// Gearsystem instruction tracer (test oracle only; links GPL-3 Gearsystem locally).
// usage: gstrace rom N out.bin   -> N records: u16 pc, u16 sp, u8 a, u8 f, u32 cycle(T-states since power-on), u16 vline
#include "GearsystemCore.h"
#include "Processor.h"
#include "Video.h"
#include "Audio.h"
#include "Memory.h"
#include <cstdio>
#include <cstdlib>
#include <vector>
bool g_mcp_stdio_mode = false;
#pragma pack(push,1)
struct Rec { unsigned short pc, sp; unsigned char a, f; unsigned int cyc; unsigned short line; };
#pragma pack(pop)
int main(int argc, char** argv) {
    GearsystemCore* core = new GearsystemCore();
    core->Init(GS_PIXEL_RGBA8888);
    if (!core->LoadROM(argv[1])) return 2;
    long n = atol(argv[2]);
    FILE* o = fopen(argv[3], "wb");
    Processor* P = core->GetProcessor();
    Video* V = core->GetVideo();
    Audio* A = core->GetAudio();
    std::vector<unsigned char> fb(320 * 288 * 4);
    unsigned long long cyc = 0;
    for (long i = 0; i < n; i++) {
        Processor::ProcessorState* s = P->GetState();
        Rec r; r.pc = s->PC->GetValue(); r.sp = s->SP->GetValue();
        r.a = s->AF->GetHigh(); r.f = s->AF->GetLow(); r.cyc = (unsigned int)cyc;
        r.line = (unsigned short)V->GetVCounter();
        fwrite(&r, sizeof r, 1, o);
        unsigned int c = P->RunFor(1);
        cyc += c;
        V->Tick(c);
        A->Tick(c);
    }
    fclose(o);
    printf("traced %ld\n", n);
    return 0;
}
