#!/bin/sh
# Super Sega - assemble a Quartus project for the Analogue Pocket core.
#
# The Analogue Pocket framework files (apf/, core_bridge_cmd.v, the project
# settings with the Pocket's pin assignments) are under Analogue's licence and
# are not kept in this repository. This script fetches them from the official
# template, github.com/open-fpga/core-template, at the tag core_top.v was
# written against (TEMPLATE_TAG below), and lays out a build tree:
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

# core_top.v's port list matches this template release
TEMPLATE_TAG=v1.3.0
TEMPLATE_COMMIT=da3a021b1eaf742604d86d8dc9b33a6666263e6a
git clone --depth 1 --branch "$TEMPLATE_TAG" https://github.com/open-fpga/core-template "$TMP/core-template"
if [ "$(git -C "$TMP/core-template" rev-parse HEAD)" != "$TEMPLATE_COMMIT" ]; then
  echo "core-template $TEMPLATE_TAG is not commit $TEMPLATE_COMMIT; check the template before using it" >&2
  exit 1
fi
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
# start a new line if the template's last kept line has no line end
if [ -n "$(tail -c 1 "$OUT/src/fpga/ap_core.qsf")" ]; then echo >> "$OUT/src/fpga/ap_core.qsf"; fi
echo 'set_global_assignment -name QIP_FILE core/ss_core.qip' >> "$OUT/src/fpga/ap_core.qsf"
# leave out the simulation-only blocks (`ifndef SYNTHESIS), as the Yosys estimate does
echo 'set_global_assignment -name VERILOG_MACRO "SYNTHESIS=1"' >> "$OUT/src/fpga/ap_core.qsf"

cp -r "$HERE/dist" "$OUT/"
echo "Quartus project: $OUT/src/fpga/ap_core.qpf"
