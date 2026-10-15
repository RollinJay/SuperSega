#!/usr/bin/env bash
# Super Sega - Pocket core regression checks, run by CI (.github/workflows/checks.yml).
#
#   0. the Pocket definition files (input.json, interact.json) are within the
#      platform's limits and match what pocket/ss_pocket.v reads and decodes
#   1. tools/mk_testrom.py reproduces roms/ byte for byte
#   2. sim/z80: the Z80 wrapper's instruction timing matches the emulator's Z80
#   3. sim/io: the SC-3000 keyboard's ghosting and the math unit's divide, which
#      take several clocks in the core, match reference models
#   4. sim/sys: the machine draws the same frames as the emulator's machine model
#      for the VDP-height (NTSC and PAL), sprite-limit and Super Sega feature test
#      ROMs, for the I/O test ROM in Master System and Game Gear modes, for the
#      VDP-height ROM in Game Gear mode, and for the four TMS9918-mode ROMs on the
#      SG-1000 (Master System colours exactly, true TMS colours within the core's
#      4-bit rounding, and with the sprite boost); and the FM test ROM's sound
#      follows the $F2 mute states with the right FM pitch and level (Master
#      System and Super Sega modes) and has no FM in Game Gear mode
#   5. sim/pocket: through the Pocket platform layer the frames match the machine
#      simulation (a headerless TMS ROM is detected as SG-1000 and drawn in true
#      TMS colours, the default), Pocket B reads as button 1 in Super Sega mode,
#      and the save slot reads back the loaded file with only the bytes the ROM
#      writes changed
#
# usage: sim/check.sh [workdir]     (workdir defaults to a new temporary directory)
# Needs what README.md lists for the simulations: Verilator 5, iverilog,
# Node.js 18 or later, Python 3 with numpy and Pillow.
set -euo pipefail
W=${1:-$(mktemp -d)}
W=$(mkdir -p "$W" && cd "$W" && pwd)
cd "$(dirname "$0")/.."                       # pocket-core/
PC=$(pwd)
PAGE=$PC/../emulator/supersega-emulator.html
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
# name | ROM | mode | frames to run | frames to compare | tb_ss options | js_dump environment
#      | tolerance (empty: exact; the core's true TMS colours are rounded to 4 bits per channel)
SYS_CASES=(
    "v192|vdp192.sms|sms|40|10 37||"
    "v224|vdp224.sms|sms|40|10 37||"
    "v240|vdp240.sms|sms|40|10 37||"
    "v224pal|vdp224.sms|sms|40|37|-pal|PAL=1"
    "spr|spr12.sms|sms|11|10||"
    "spr16|spr12.sms|sms|11|10|-spr16|AEL=sprlimit"
    "spr16ovf|spr12.sms|sms|11|10|-spr16 -ovf|AEL=sprlimit,ovf"
    "ssfeat|ssfeat.sms|ss|12|10 11||"
    "gg192|vdp192.sms|gg|11|10||"
    "smsports|ports.sms|sms|11|10||"
    "ggports|ports.sms|gg|11|10||"
    "tmsg1|tms_g1.sg|sg|61|20 46 60|-tmsapprox|AEL=tmscol=0"
    "tmsg2|tms_g2.sg|sg|61|20 46 60|-tmsapprox|AEL=tmscol=0"
    "tmsmc|tms_mc.sg|sg|61|20 46 60|-tmsapprox|AEL=tmscol=0"
    "tmstxt|tms_txt.sg|sg|61|20 60|-tmsapprox|AEL=tmscol=0"
    "tmsspr|tms_g1.sg|sg|47|46|-tmsapprox -spr16|AEL=tmscol=0,sprlimit"
    "tmstrue|tms_g2.sg|sg|47|46|||8"
)
run_sys_case() {
    local name rom mode n dumps topt jenv tol
    IFS='|' read -r name rom mode n dumps topt jenv tol <<< "$1"
    # shellcheck disable=SC2086  # option and frame lists are meant to split
    (cd "$PC/sim/sys" && ./obj/tb_ss "../../roms/$rom" "$mode" "$n" "$W/sys/$name" $topt $dumps) \
        > "$W/sys/$name.log" 2>&1 || { echo "tb_ss $name failed:"; cat "$W/sys/$name.log"; return 1; }
    # shellcheck disable=SC2086
    env $jenv node "$JSDUMP" "$PAGE" "$PC/roms/$rom" "$mode" "$W/js/$name" $dumps \
        > "$W/js/$name.log" 2>&1 || { echo "js_dump $name failed:"; cat "$W/js/$name.log"; return 1; }
}
export -f run_sys_case
# FM sound: roms/fm.sms captured as audio and checked by tools/check_fm_wav.py,
# in the two modes with the FM unit and in one without it; run alongside the
# frame cases
FM_CASES=("fmsms|sms|" "fmss|ss|" "fmgg|gg|--no-fm")
run_fm_case() {
    local name mode opt
    IFS='|' read -r name mode opt <<< "$1"
    (cd "$PC/sim/sys" && ./obj/tb_ss ../../roms/fm.sms "$mode" 50 "$W/sys/$name" -wav "$W/sys/$name.wav") \
        > "$W/sys/$name.log" 2>&1 || { echo "tb_ss $name failed:"; cat "$W/sys/$name.log"; return 1; }
    # shellcheck disable=SC2086  # opt is empty or one flag
    python3 "$PC/tools/check_fm_wav.py" "$W/sys/$name.wav" $opt > "$W/sys/$name.txt" 2>&1 \
        || { echo "$name: FM sound check failed:"; cat "$W/sys/$name.txt"; return 1; }
}
export -f run_fm_case
printf '%s\0' "${FM_CASES[@]}" | xargs -0 -n 1 -P "$JOBS" bash -c 'run_fm_case "$1"' _ &
fm_pid=$!
printf '%s\0' "${SYS_CASES[@]}" | xargs -0 -n 1 -P "$JOBS" bash -c 'run_sys_case "$1"' _
fail=0
for c in "${SYS_CASES[@]}"; do
    IFS='|' read -r name rom mode n dumps topt jenv tol <<< "$c"
    for f in $dumps; do
        printf '%-9s %-11s %-4s frame %-3s RTL vs emulator: ' "$name" "$rom" "$mode" "$f"
        python3 tools/ppmdiff.py "$W/sys/${name}_$f.ppm" "$W/js/${name}_$f.ppm" ${tol:+--tol "$tol"} || fail=1
    done
done
wait "$fm_pid" || fail=1
for c in "${FM_CASES[@]}"; do
    IFS='|' read -r name mode opt <<< "$c"
    printf '%-9s %-11s %-4s FM sound ($F2 states, pitch, level): ' "$name" fm.sms "$mode"
    tail -n 1 "$W/sys/$name.txt" 2>/dev/null || echo "no result"
done
[ "$fail" = 0 ]

step "5. Pocket platform simulation (sim/pocket)"
build pocket
# name | ROM | frames to run | options and frames to dump
POCKET_CASES=(
    "p224|vdp224.sms|40|37"
    "pss|ssfeat.sms|12|10 11"
    "pggports|ports.sms|11|-system 2 10"
    "pbutton|ports.sms|11|-system 3 -hold 5 10"
    "psave|save.sms|10|-save ../../roms/save_in.sav"
    "ptms|tms_g2.sg|47|46"
)
run_pocket_case() {
    local name rom n args extra=()
    IFS='|' read -r name rom n args <<< "$1"
    if [ "$name" = psave ]; then extra=(-readsave "$W/pocket/back.sav"); fi
    # shellcheck disable=SC2086
    (cd "$PC/sim/pocket" && ./obj/tb_pocket "../../roms/$rom" "$n" "$W/pocket/$name" $args ${extra[@]+"${extra[@]}"}) \
        > "$W/pocket/$name.log" 2>&1 || { echo "tb_pocket $name failed:"; cat "$W/pocket/$name.log"; return 1; }
    grep -q 'slot-word errors 0 ' "$W/pocket/$name.log" \
        || { echo "tb_pocket $name: scaler slot-word errors:"; cat "$W/pocket/$name.log"; return 1; }
}
export -f run_pocket_case
printf '%s\0' "${POCKET_CASES[@]}" | xargs -0 -n 1 -P "$JOBS" bash -c 'run_pocket_case "$1"' _
fail=0
for pair in "p224_37 v224_37" "pss_10 ssfeat_10" "pss_11 ssfeat_11" "pggports_10 ggports_10" "ptms_46 tmstrue_46"; do
    set -- $pair
    printf '%-12s Pocket vs machine simulation: ' "$1"
    python3 tools/ppmdiff.py "$W/pocket/$1.ppm" "$W/sys/$2.ppm" || fail=1
done
[ "$fail" = 0 ]
printf 'pbutton      Super Sega mode, Pocket B held: '
python3 tools/read_ports_ppm.py "$W/pocket/pbutton_10.ppm" > "$W/pocket/pbutton.txt"
grep -qx '\$DC: \$EF' "$W/pocket/pbutton.txt" \
    || { echo "port \$DC should read \$EF (button 1 pressed):"; cat "$W/pocket/pbutton.txt"; exit 1; }
echo 'port $DC reads $EF (button 1)'
printf 'psave        '
python3 - "$PC/roms/save_in.sav" "$W/pocket/back.sav" <<'EOF'
import sys
loaded = open(sys.argv[1], 'rb').read()
back = open(sys.argv[2], 'rb').read()
want = bytearray(loaded)                      # save.sms writes (address low byte ^ $5A) to $0100-$01FF
for i in range(0x100, 0x200):
    want[i] = (i & 0xFF) ^ 0x5A
bad = sum(1 for i in range(min(len(back), len(want))) if back[i] != want[i])
print(f'save slot read back: {len(back)} bytes, {bad} differ from the expected')
sys.exit(0 if len(back) == len(want) and bad == 0 else 1)
EOF

printf '\nAll Pocket core checks passed.\n'
