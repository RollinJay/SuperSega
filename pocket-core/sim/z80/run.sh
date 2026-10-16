#!/bin/sh
# Z80 wrapper timing test (iverilog): the start cycle of every instruction of a
# short program covering the timing classes (IX/IY, DDCB, block I/O, IN/OUT,
# CALL/RET) on the RTL CPU wrapper, and the T-state, port and value of every
# port access, against the emulator's Z80.
# usage: ./run.sh [emulator page]   (default: ../../../emulator/masterdrive-emulator.html)
set -e
R=../../rtl
PAGE=${1:-../../../emulator/masterdrive-emulator.html}
node gen_prog.js "$PAGE"
iverilog -g2012 -o tb_z80 -I$R/third_party/tv80 tb_z80.v $R/mdr_z80.v $R/third_party/tv80/tv80_core.v \
  $R/third_party/tv80/tv80_alu.v $R/third_party/tv80/tv80_mcode.v $R/third_party/tv80/tv80_reg.v
vvp -n tb_z80 > /dev/null
python3 cmp_logs.py z80_js.log z80_rtl.log
