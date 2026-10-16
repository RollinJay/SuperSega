#!/usr/bin/env bash
# MasterDrive - Pocket core regression checks, run by CI (.github/workflows/checks.yml).
#
#   0. the Pocket definition files (input.json, interact.json) are within the
#      platform's limits and match what pocket/mdr_pocket.v reads and decodes
#   1. tools/mk_testrom.py reproduces roms/ byte for byte
#   2. sim/z80: the Z80 wrapper's instruction and port-access timing matches the emulator's Z80
#   3. sim/io: the SC-3000 keyboard's ghosting and the math unit's divide, which
#      take several clocks in the core, match reference models, $0A and $08
#      read back, and the MasterDrive I/O gate and machine ID answer as Q1 and
#      Q8 decide
#   4. sim/sys: the machine draws the same frames as the emulator's machine model
#      for the VDP-height (NTSC and PAL), sprite-limit and MasterDrive feature test
#      ROMs, for the I/O test ROM in Master System and Game Gear modes, for the
#      I/O gate ROM (mdports.sms) in MasterDrive, Master System and Game Gear
#      modes (in MasterDrive mode also against the expected values), for the
#      MasterDrive register ROM (mdrregs.sms: the math unit's multiply and
#      divide, $0A and $08 read back, also against the expected values), for the
#      cartridge wait state at 200 % (romwait.sms, NTSC and PAL, NTSC also
#      against the expected values), for the
#      VDP-height ROM in Game Gear mode, for the four TMS9918-mode ROMs on the
#      SG-1000 (Master System colours exactly, true TMS colours within the core's
#      4-bit rounding, and with the sprite boost), and for the TMS9918 modes at 224
#      and 240 lines in MasterDrive mode (Q17: Graphics II at both heights, Text at
#      240, true TMS colours at 240, and the 240-line ROM on the SG-1000, where it
#      stays at 192 lines), and for the MasterDrive picture extensions (mdrgfx.sms:
#      the ESAT, line tables, tile window, unique-cell tiles; mdrtext.sms: the
#      text window, 16x16 and four-times magnified sprites, the renderer's
#      busiest line; gfxfuzz*.sms: random registers, VRAM and CRAM), and for
#      the DMA engine (dma.sms: fills and copies from each source into VRAM and
#      CRAM, and short transfers at each turbo step; the CPU's time for each
#      transfer against the emulator's, instruction by instruction); the PCM
#      and wavetable ROM's sound has each tone at the emulator's pitch and level
#      on the sides it selects, the PCM at all four rates (pcm.sms); and the
#      FM test ROM's sound
#      follows the $F2 mute states with the right FM pitch and level (Master
#      System and MasterDrive modes) and has no FM in Game Gear mode, and a
#      tightly timed FM driver still plays at 200 % turbo; in PAL, frames come at
#      49.70 Hz and the FM and PSG pitch follow the PAL clock; and the clock
#      enables keep their spacing (a check inside mdr_top)
#   5. sim/pocket: through the Pocket platform layer the frames match the machine
#      simulation, NTSC and PAL (a headerless TMS ROM is detected as SG-1000 and
#      drawn in true TMS colours, the default; a TMS mode at 240 lines in
#      MasterDrive mode, the same; and mdrtext.sms); the video timing the scaler sees
#      is regular (PAL lines 345 or 346 pixel clocks), also across a switch from
#      PAL to NTSC; an export cartridge runs in MasterDrive mode with System =
#      MasterDrive and in Master System mode with Auto (mdports.sms); Pocket A
#      and B read as buttons 1 and 2 in Master System mode
#      and B as button 1 in MasterDrive mode; and the save slot reads back the
#      loaded file with only the bytes the ROM writes changed
#
# usage: sim/check.sh [workdir]     (workdir defaults to a new temporary directory)
# Needs what README.md lists for the simulations: Verilator 5, iverilog,
# Node.js 18 or later, Python 3 with numpy and Pillow.
set -euo pipefail
W=${1:-$(mktemp -d)}
W=$(mkdir -p "$W" && cd "$W" && pwd)
cd "$(dirname "$0")/.."                       # pocket-core/
PC=$(pwd)
PAGE=$PC/../emulator/masterdrive-emulator.html
JSDUMP=$PC/../emulator/tools/js_dump.js
mkdir -p "$W/roms" "$W/sys" "$W/js" "$W/pocket"
JOBS=$(nproc 2>/dev/null || echo 2)
export PC PAGE JSDUMP W
echo "work directory: $W"

step() { printf '\n== %s\n' "$*"; }
build() {                                     # build <sim dir>: quiet unless it fails
    (cd "sim/$1" && ./build.sh > "$W/build_$1.log" 2>&1) || { cat "$W/build_$1.log"; return 1; }
}

step "0. Pocket definition files"
python3 tools/check_core_json.py

step "1. test ROMs are reproducible"
python3 tools/mk_testrom.py "$W/roms" > /dev/null
diff -r "$W/roms" roms
echo "roms/ matches tools/mk_testrom.py"

step "2. Z80 wrapper timing (sim/z80)"
(cd sim/z80 && ./run.sh)

step "3. I/O unit against reference models (sim/io)"
(cd sim/io && ./run.sh > "$W/io.log") || { cat "$W/io.log"; exit 1; }
grep -v '^PASS$\|finish called' "$W/io.log"

step "4. machine simulation against the emulator (sim/sys)"
build sys
# name | ROM | mode | frames to run | frames to compare | tb_mdr options | js_dump environment
#      | tolerance (empty: exact; the core's true TMS colours are rounded to 4 bits per channel)
SYS_CASES=(
    "v192|vdp192.sms|sms|40|10 37||"
    "v224|vdp224.sms|sms|40|10 37||"
    "v240|vdp240.sms|sms|40|10 37||"
    "v224pal|vdp224.sms|sms|40|37|-pal|PAL=1"
    "spr|spr12.sms|sms|11|10||"
    "spr16|spr12.sms|sms|11|10|-spr16|AEL=sprlimit"
    "spr16ovf|spr12.sms|sms|11|10|-spr16 -ovf|AEL=sprlimit,ovf"
    "mdrfeat|mdrfeat.sms|ss|12|10 11||"
    "gg192|vdp192.sms|gg|11|10||"
    "smsports|ports.sms|sms|11|10||"
    "ggports|ports.sms|gg|11|10||"
    "mdports|mdports.sms|ss|11|10||"
    "smsmdports|mdports.sms|sms|11|10||"
    "ggmdports|mdports.sms|gg|11|10||"
    "mdrregs|mdrregs.sms|ss|11|10||"
    "romwait|romwait.sms|ss|14|13||"
    "romwaitpal|romwait.sms|ss|14|13|-pal|PAL=1"
    "tmsg1|tms_g1.sg|sg|61|20 46 60|-tmsapprox|AEL=tmscol=0"
    "tmsg2|tms_g2.sg|sg|61|20 46 60|-tmsapprox|AEL=tmscol=0"
    "tmsmc|tms_mc.sg|sg|61|20 46 60|-tmsapprox|AEL=tmscol=0"
    "tmstxt|tms_txt.sg|sg|61|20 60|-tmsapprox|AEL=tmscol=0"
    "tmsspr|tms_g1.sg|sg|47|46|-tmsapprox -spr16|AEL=tmscol=0,sprlimit"
    "tmstrue|tms_g2.sg|sg|47|46|||8"
    "tmsg2t224|tms_g2_224.sms|ss|61|46 60|-tmsapprox|AEL=tmscol=0"
    "tmsg2t240|tms_g2_240.sms|ss|61|46 60|-tmsapprox|AEL=tmscol=0"
    "tmstxt240|tms_txt_240.sms|ss|61|60|-tmsapprox|AEL=tmscol=0"
    "tmstallsg|tms_g2_240.sms|sg|61|60|-tmsapprox|AEL=tmscol=0"
    "tmstrue240|tms_g2_240.sms|ss|61|60|||8"
    "mdrgfx|mdrgfx.sms|ss|21|20||"
    "mdrtext|mdrtext.sms|ss|21|20||"
    "gfxfuzz1|gfxfuzz1.sms|ss|71|70||"
    "gfxfuzz6|gfxfuzz6.sms|ss|71|70||"
    "gfxfuzz25|gfxfuzz25.sms|ss|71|70||"
    "gfxfuzz38|gfxfuzz38.sms|ss|71|70||"
    "dma|dma.sms|ss|11|10||"
)
run_sys_case() {
    local name rom mode n dumps topt jenv tol
    IFS='|' read -r name rom mode n dumps topt jenv tol <<< "$1"
    # shellcheck disable=SC2086  # option and frame lists are meant to split
    (cd "$PC/sim/sys" && ./obj/tb_mdr "../../roms/$rom" "$mode" "$n" "$W/sys/$name" $topt $dumps) \
        > "$W/sys/$name.log" 2>&1 || { echo "tb_mdr $name failed:"; cat "$W/sys/$name.log"; return 1; }
    grep -q ', 0 violations' "$W/sys/$name.log" \
        || { echo "tb_mdr $name: clock enable check failed:"; grep 'enable check' "$W/sys/$name.log"; return 1; }
    # shellcheck disable=SC2086
    env $jenv node "$JSDUMP" "$PAGE" "$PC/roms/$rom" "$mode" "$W/js/$name" $dumps \
        > "$W/js/$name.log" 2>&1 || { echo "js_dump $name failed:"; cat "$W/js/$name.log"; return 1; }
}
export -f run_sys_case
# Sound: test ROMs captured as audio and checked by a tool. The FM test ROMs
# (tools/check_fm_wav.py) in the two modes with the FM unit and in one without
# it, the tightly timed driver at 200 % turbo (the bus synchroniser must hold its
# writes), and both ROMs again on the PAL machine (pitches at 3.546893 MHz); the
# PCM and wavetable ROM (tools/check_pcm_wav.py, seven phases of 20 frames). Run
# alongside the frame cases.
# name | ROM | mode | frames | tb_mdr options | check tool | its options
SOUND_CASES=("fmsms|fm.sms|sms|50||check_fm_wav.py|" "fmss|fm.sms|ss|50||check_fm_wav.py|"
             "fmgg|fm.sms|gg|50||check_fm_wav.py|--no-fm" "fmturbo|fm_tight.sms|sms|50|-turbo 4|check_fm_wav.py|"
             "fmpal|fm.sms|sms|50|-pal|check_fm_wav.py|--pal"
             "fmturbopal|fm_tight.sms|sms|50|-pal -turbo 4|check_fm_wav.py|--pal"
             "pcm|pcm.sms|ss|142||check_pcm_wav.py|")
run_sound_case() {
    local name rom mode n topt tool opt
    IFS='|' read -r name rom mode n topt tool opt <<< "$1"
    rm -f "$W/sys/$name.wav" "$W/sys/$name.txt"   # a reused work directory must not show an old result
    # shellcheck disable=SC2086  # topt is empty or a list of options
    (cd "$PC/sim/sys" && ./obj/tb_mdr "../../roms/$rom" "$mode" "$n" "$W/sys/$name" -wav "$W/sys/$name.wav" $topt) \
        > "$W/sys/$name.log" 2>&1 || { echo "tb_mdr $name failed:"; cat "$W/sys/$name.log"; return 1; }
    grep -q ', 0 violations' "$W/sys/$name.log" \
        || { echo "tb_mdr $name: clock enable check failed:"; grep 'enable check' "$W/sys/$name.log"; return 1; }
    # shellcheck disable=SC2086  # opt is empty or one flag
    python3 "$PC/tools/$tool" "$W/sys/$name.wav" $opt > "$W/sys/$name.txt" 2>&1 \
        || { echo "$name: sound check failed:"; cat "$W/sys/$name.txt"; return 1; }
}
export -f run_sound_case
printf '%s\0' "${SOUND_CASES[@]}" | xargs -0 -n 1 -P "$JOBS" bash -c 'run_sound_case "$1"' _ &
sound_pid=$!
sys_ok=1
printf '%s\0' "${SYS_CASES[@]}" | xargs -0 -n 1 -P "$JOBS" bash -c 'run_sys_case "$1"' _ || sys_ok=0
sound_ok=1
wait "$sound_pid" || sound_ok=0               # never leave the sound runs behind
[ "$sys_ok" = 1 ] || exit 1                   # the failing case has printed its log
fail=0
for c in "${SYS_CASES[@]}"; do
    IFS='|' read -r name rom mode n dumps topt jenv tol <<< "$c"
    for f in $dumps; do
        printf '%-9s %-11s %-4s frame %-3s RTL vs emulator: ' "$name" "$rom" "$mode" "$f"
        python3 tools/ppmdiff.py "$W/sys/${name}_$f.ppm" "$W/js/${name}_$f.ppm" ${tol:+--tol "$tol"} || fail=1
    done
done
[ "$sound_ok" = 1 ] || fail=1
for c in "${SOUND_CASES[@]}"; do
    IFS='|' read -r name rom mode n topt tool opt <<< "$c"
    case "$tool" in
        check_fm_wav.py) what='FM sound ($F2 states, pitch, level)' ;;
        *) what='PCM and wavetable (sides, pitch, level)' ;;
    esac
    printf '%-9s %-12s %-4s %-9s %s: ' "$name" "$rom" "$mode" "$topt" "$what"
    tail -n 1 "$W/sys/$name.txt" 2>/dev/null || echo "no result"
done
# frame timing: NTSC 262 lines of 228 base cycles (3420 clk_sys each); PAL 313
# lines at 3.546893 MHz, so 1080310-1080320 clk_sys a frame (49.70 Hz)
for c in "v224|clk_sys 896040-896040|59.92 Hz" "v224pal|clk_sys 1080310-1080320|49.70 Hz"; do
    IFS='|' read -r name want hz <<< "$c"
    printf '%-9s frame timing %s: ' "$name" "$hz"
    if grep -qF "$want" "$W/sys/$name.log"; then echo "$want"; else echo "WRONG:"; grep 'frame timing' "$W/sys/$name.log"; fail=1; fi
done
# The port ROMs' rows are read with sed, which reads to the end: head would close the
# pipe early and fail the decoder when Python's output is unbuffered.
# the MasterDrive I/O gate and machine ID (Q1, Q8): mdports.sms reads six ports
# before Feature Enable A bit 7 is set ($FF), then, with it set, the registers,
# 200 x 100 from the math unit and $A7 at $17
printf '%-9s I/O gate and machine ID (MasterDrive mode): ' mdports
python3 tools/read_ports_ppm.py "$W/sys/mdports_10.ppm" | sed -n 1,17p | tr '\n' ' ' > "$W/sys/mdports.txt"
want='$01: $FF $06: $FF $09: $FF $0F: $FF $16: $FF $17: $FF $00: $C0 $01: $7F $06: $FF $09: $00 $0E: $00 $0F: $20 $10: $4E $16: $81 $17: $A7 $18: $FF $DC: $FF '
if [ "$(cat "$W/sys/mdports.txt")" = "$want" ]; then echo 'closed $FF, open $17 = $A7'; else echo "WRONG:"; cat "$W/sys/mdports.txt"; echo; fail=1; fi
# the MasterDrive registers (Q7, Q9, Q14): mdrregs.sms multiplies and divides
# (quotient, remainder, divide by zero $FF/$00), reads the work RAM bank back at
# $0A and the empty PCM FIFO at $08
printf '%-9s math unit, $0A and $08 (MasterDrive mode): ' mdrregs
python3 tools/read_ports_ppm.py "$W/sys/mdrregs_10.ppm" | sed -n 1,17p | tr '\n' ' ' > "$W/sys/mdrregs.txt"
want='$0F: $20 $10: $4E $0F: $1C $10: $04 $0F: $0F $10: $0F $0F: $00 $10: $05 $0F: $FF $10: $00 $0F: $01 $10: $FE $0A: $0B $0A: $0F $08: $00 $0E: $00 $17: $A7 '
if [ "$(cat "$W/sys/mdrregs.txt")" = "$want" ]; then echo '200 / 7 = 28 r 4, 200 / 0 = $FF/$00, $0A reads back'; else echo "WRONG:"; cat "$W/sys/mdrregs.txt"; echo; fail=1; fi
# the cartridge wait state at 200 % (Q12): romwait.sms runs 2,000 NOPs from ROM
# and from work RAM and reads the V counter after them: at 200 % the ROM run
# ends five lines later (5 T-states a NOP against 4), at 175 % both end together
printf '%-9s cartridge wait state at 200 %%: ' romwait
python3 tools/read_ports_ppm.py "$W/sys/romwait_13.ppm" | sed -n 1,4p | tr '\n' ' ' > "$W/sys/romwait.txt"
want='$04: $37 $14: $32 $03: $35 $13: $35 '
if [ "$(cat "$W/sys/romwait.txt")" = "$want" ]; then echo 'ROM line $37, RAM $32 at 200 %; both $35 at 175 %'; else echo "WRONG:"; cat "$W/sys/romwait.txt"; echo; fail=1; fi
# the DMA charge (Q26: the emulator's): dma.sms traced instruction by instruction
# on the core, with the Pocket's PSRAM latency (9 clocks), and on the emulator,
# up to its first turbo step; each transfer must cost the CPU the same time
printf '%-9s DMA charge, 100 %%, PSRAM latency: ' dmatime
if (cd "$PC/sim/sys" && ./obj/tb_mdr ../../roms/dma.sms ss 2 "$W/sys/dmatime" -lat 9 -trace 4000 "$W/sys/dmatime_rt.bin") \
       > "$W/sys/dmatime.log" 2>&1 &&
   node "$PC/../emulator/tools/jstrace.js" "$PAGE" "$PC/roms/dma.sms" ss 4000 "$W/js/dmatime_js.bin" >> "$W/sys/dmatime.log" 2>&1; then
    python3 tools/cmp_cycles.py "$W/sys/dmatime_rt.bin" "$W/js/dmatime_js.bin" roms/dma.sms || fail=1
else echo "FAILED:"; cat "$W/sys/dmatime.log"; fail=1; fi
[ "$fail" = 0 ]

step "5. Pocket platform simulation (sim/pocket)"
build pocket
# name | ROM | frames to run | options and frames to dump | video timing to expect
#   ntsc: every line 342 pixel clocks, every frame 89604; pal: lines of 345 or
#   346 (machine time is held, the pixel clock is not), frames 108031-108032,
#   313 lines; toggle: PAL switched to NTSC mid-frame restarts the machine:
#   lines of both kinds appear, and every frame has 262 to 313 lines
POCKET_CASES=(
    "p224|vdp224.sms|40|37|ntsc"
    "pss|mdrfeat.sms|12|10 11|ntsc"
    "pggports|ports.sms|11|-system 2 10|ntsc"
    "pmdports|mdports.sms|11|-system 3 10|ntsc"
    "pmdauto|mdports.sms|11|10|ntsc"
    "pbutton|ports.sms|11|-system 3 -hold 5 10|ntsc"
    "pbtn1|ports.sms|11|-system 1 -hold 4 10|ntsc"
    "pbtn2|ports.sms|11|-system 1 -hold 5 10|ntsc"
    "psave|save.sms|10|-save ../../roms/save_in.sav|ntsc"
    "ptms|tms_g2.sg|47|46|ntsc"
    "ptms240|tms_g2_240.sms|61|60|ntsc"
    "pgfx|mdrtext.sms|21|20|ntsc"
    "p224pal|vdp224.sms|40|-set 108 1 37|pal"
    "ptoggle|vdp224.sms|30|-set 108 1 -setat 20 200000 108 0|toggle"
)
run_pocket_case() {
    local name rom n args tim tline x extra=() need=()
    IFS='|' read -r name rom n args tim <<< "$1"
    if [ "$name" = psave ]; then extra=(-readsave "$W/pocket/back.sav"); fi
    # shellcheck disable=SC2086
    (cd "$PC/sim/pocket" && ./obj/tb_pocket "../../roms/$rom" "$n" "$W/pocket/$name" $args ${extra[@]+"${extra[@]}"}) \
        > "$W/pocket/$name.log" 2>&1 || { echo "tb_pocket $name failed:"; cat "$W/pocket/$name.log"; return 1; }
    grep -q 'slot-word errors 0 ' "$W/pocket/$name.log" \
        || { echo "tb_pocket $name: scaler slot-word errors:"; cat "$W/pocket/$name.log"; return 1; }
    grep -q ', 0 violations' "$W/pocket/$name.log" \
        || { echo "tb_pocket $name: clock enable check failed:"; grep 'enable check' "$W/pocket/$name.log"; return 1; }
    tline=$(grep '^timing:' "$W/pocket/$name.log")
    case "$tim" in
        ntsc) need=('HS period 342-342' 'VS period 89604-89604') ;;
        pal)  need=('HS period 345-346' 'VS period 108031-108032' 'HS per frame 313-313') ;;
        toggle) need=('[345 x' '[342 x' 'HS per frame 262-313;') ;;
    esac
    need+=('wide HS/VS 0;' 'skip 0')
    for x in "${need[@]}"; do
        grep -qF -- "$x" <<< "$tline" || { echo "tb_pocket $name: video timing, expected '$x':"; echo "$tline"; return 1; }
    done
}
export -f run_pocket_case
printf '%s\0' "${POCKET_CASES[@]}" | xargs -0 -n 1 -P "$JOBS" bash -c 'run_pocket_case "$1"' _
fail=0
for pair in "p224_37 v224_37" "pss_10 mdrfeat_10" "pss_11 mdrfeat_11" "pggports_10 ggports_10" "ptms_46 tmstrue_46" \
            "ptms240_60 tmstrue240_60" "pgfx_20 mdrtext_20" "p224pal_37 v224pal_37" "pmdports_10 mdports_10" "pmdauto_10 smsmdports_10"; do
    set -- $pair
    printf '%-12s Pocket vs machine simulation: ' "$1"
    python3 tools/ppmdiff.py "$W/pocket/$1.ppm" "$W/sys/$2.ppm" || fail=1
done
[ "$fail" = 0 ]
# Pocket button -> port $DC: MasterDrive mode, B = the pad's B (button 1 with TH
# high); Master System mode, A = button 1 and B = button 2 (Technical Reference §6)
for c in 'pbutton|MasterDrive mode, Pocket B held|$EF|button 1' \
         'pbtn1|Master System, Pocket A held|$EF|button 1' \
         'pbtn2|Master System, Pocket B held|$DF|button 2'; do
    IFS='|' read -r name what want btn <<< "$c"
    printf '%-12s %s: ' "$name" "$what"
    python3 tools/read_ports_ppm.py "$W/pocket/${name}_10.ppm" > "$W/pocket/$name.txt"
    grep -qxF "\$DC: $want" "$W/pocket/$name.txt" \
        || { echo "port \$DC should read $want ($btn pressed):"; cat "$W/pocket/$name.txt"; exit 1; }
    echo "port \$DC reads $want ($btn)"
done
printf 'psave        '
python3 - "$PC/roms/save_in.sav" "$W/pocket/back.sav" <<'EOF'
import sys
loaded = open(sys.argv[1], 'rb').read()
back = open(sys.argv[2], 'rb').read()
want = bytearray(loaded)                      # save.sms (SAVE_BLOCKS): two 16 KB banks (Q3)
for bank, addr, key in ((0, 0x8100, 0x00), (0, 0xA200, 0x11), (1, 0x8300, 0x22), (1, 0xA400, 0x33)):
    for k in range(256):
        want[bank * 0x4000 + addr - 0x8000 + k] = ((addr + k) & 0xFF) ^ 0x5A ^ key
bad = sum(1 for i in range(min(len(back), len(want))) if back[i] != want[i])
print(f'save slot read back: {len(back)} bytes, {bad} differ from the expected')
sys.exit(0 if len(back) == len(want) and bad == 0 else 1)
EOF

printf '\nAll Pocket core checks passed.\n'
