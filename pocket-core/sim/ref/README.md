# Gearsystem runners (test oracle only)

Two small programs that run a ROM on Gearsystem, Ignacio Sanchez's Master System / Game Gear emulator, as an independent reference for the RTL and the Super Sega emulator:

| Program | Writes |
|---|---|
| `gsrun.cpp` | frames as PPM and the 8 KB work RAM at chosen frames, with the same scripted input as the RTL and emulator harnesses (button 1 at frames 90–95 of every 120; Start at 60–65 on the Game Gear) |
| `gstrace.cpp` | an instruction trace (PC, SP, A, F, cycle count, line) in the record format `sim/sys/tb_ss` writes with `-trace`, for cycle-level comparison with `tools/cmp_trace.py` |

Gearsystem is GPL-3. Nothing from it is in this repository or in the core; these runners are built against a local checkout and the binaries are not distributed. The comparisons in this milestone used Gearsystem commit `125c8d2dec5daa73046397764ea7bb9ad28706df` (12 October 2026).

```sh
git clone https://github.com/drhelius/Gearsystem
SRC=Gearsystem/src
MZ=Gearsystem/platforms/shared/dependencies/miniz
EM=$SRC/audio/emu2413
gcc -O2 -c $MZ/miniz.c $EM/emu2413.c
g++ -O2 -I$SRC -I$SRC/audio -I$EM -I$MZ -o gsrun   gsrun.cpp   $SRC/*.cpp $SRC/audio/*.cpp miniz.o emu2413.o
g++ -O2 -I$SRC -I$SRC/audio -I$EM -I$MZ -o gstrace gstrace.cpp $SRC/*.cpp $SRC/audio/*.cpp miniz.o emu2413.o
mkdir -p out
./gsrun game.sms 600 out/gs 200 500          # frames 200 and 500
./gstrace game.sms 100000 out/gs_trace.bin    # first 100,000 instructions
```

Gearsystem has no 240-line mode, so the 240-line test ROM is compared between the RTL and the emulator only.
