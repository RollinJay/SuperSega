#!/bin/sh
# Super Sega - assemble a Quartus project for the Analogue Pocket core.
#
# The Analogue Pocket framework files (apf/, core_bridge_cmd.v, the project
# settings with the Pocket's pin assignments) are under Analogue's licence and
# are not kept in this repository. This script fetches them from the official
# template, github.com/open-fpga/core-template, and lays out a build tree:
#
#   build/src/fpga/ap_core.qpf, ap_core.qsf    project (template settings + ours)
#   build/src/fpga/apf/                        framework (fetched)
#   build/src/fpga/core/                       core_top, platform layer, machine RTL
#   build/dist/                                SD-card files for the core
#
# usage: ./setup.sh [build-dir]
# Then open build/src/fpga/ap_core.qpf in Quartus Prime Lite (the template is
# from 18.1.1; newer Lite versions also work for Cyclone V), compile, and run
# tools/reverse_rbf.py on output_files/ap_core.rbf to make bitstream.rbf_r.
set -e
HERE=$(cd "$(dirname "$0")" && pwd)
OUT=${1:-$HERE/build}
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

git clone --depth 1 https://github.com/open-fpga/core-template "$TMP/core-template"
T="$TMP/core-template/src/fpga"

mkdir -p "$OUT/src/fpga/core"
cp -r "$T/apf" "$OUT/src/fpga/"
cp "$T/ap_core.qpf" "$OUT/src/fpga/"
cp "$T/core/core_bridge_cmd.v" "$OUT/src/fpga/core/"

# our sources
cp "$HERE/core_top.v" "$HERE/ss_pocket.v" "$HERE/ss_pll.v" "$HERE/ss_save_unload.v" \
   "$HERE/core_constraints.sdc" "$HERE/ss_core.qip" "$OUT/src/fpga/core/"
cp -r "$HERE/third_party" "$OUT/src/fpga/core/"
mkdir -p "$OUT/src/fpga/core/rtl"
cp -r "$HERE/../rtl/." "$OUT/src/fpga/core/rtl/"

# project settings: the template's, with its example core files (test-screen
# core_top, its PLL, Signal Tap) replaced by ours
sed -e '/core\/core_top.v/d' -e '/core\/core_bridge_cmd.v/d' -e '/core\/core_constraints.sdc/d' \
    -e '/mf_pllbase/d' -e '/stp1/d' -e '/ENABLE_SIGNALTAP/d' \
    "$T/ap_core.qsf" > "$OUT/src/fpga/ap_core.qsf"
echo 'set_global_assignment -name QIP_FILE core/ss_core.qip' >> "$OUT/src/fpga/ap_core.qsf"

cp -r "$HERE/dist" "$OUT/"
echo "Quartus project: $OUT/src/fpga/ap_core.qpf"
