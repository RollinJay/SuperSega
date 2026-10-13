#!/bin/sh
# Super Sega - build the Analogue Pocket core and the SD-card files.
#
#   1. setup.sh assembles the Quartus project in build/ (fetching the APF framework)
#   2. Quartus compiles it: quartus_sh from PATH if there is one, otherwise in the
#      raetro/quartus:pocket Docker image (Quartus Prime Lite 18.1)
#   3. tools/reverse_rbf.py turns ap_core.rbf into bitstream.rbf_r, the form the
#      Pocket loads
#   4. build/sdcard/ gets the files to copy to the root of the SD card, and
#      build/SuperSega-pocket.zip the same as one zip
#
# usage: ./build_core.sh        (from anywhere; about 15 minutes)
set -e
HERE=$(cd "$(dirname "$0")" && pwd)
OUT=$HERE/build
CORE=SuperSega.SuperSega
IMAGE=raetro/quartus:pocket

rm -rf "$OUT"
"$HERE/setup.sh" "$OUT"

if command -v quartus_sh > /dev/null 2>&1; then
    (cd "$OUT/src/fpga" && quartus_sh --flow compile ap_core)
else
    docker run --rm -v "$OUT:/build" -w /build/src/fpga "$IMAGE" quartus_sh --flow compile ap_core
fi

RBF=$OUT/src/fpga/output_files/ap_core.rbf
test -s "$RBF" || { echo "no bitstream: $RBF" >&2; exit 1; }

SD=$OUT/sdcard
mkdir -p "$SD/Assets/supersega/common/test-roms"
cp -r "$OUT/dist/." "$SD/"
cp "$HERE"/../roms/*.sms "$SD/Assets/supersega/common/test-roms/"
cp "$HERE/../TESTING.md" "$SD/Cores/$CORE/"
python3 "$HERE/tools/reverse_rbf.py" "$RBF" "$SD/Cores/$CORE/bitstream.rbf_r"
(cd "$SD" && rm -f ../SuperSega-pocket.zip && python3 -c "
import os, zipfile
with zipfile.ZipFile('../SuperSega-pocket.zip', 'w', zipfile.ZIP_DEFLATED) as z:
    for d, _, fs in os.walk('.'):
        if d != '.': z.write(d, os.path.relpath(d, '.'))
        for f in fs: z.write(os.path.join(d, f), os.path.relpath(os.path.join(d, f), '.'))
")
echo "SD-card files: $SD"
echo "zip:           $OUT/SuperSega-pocket.zip"
