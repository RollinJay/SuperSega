#!/bin/sh
# I/O unit test (iverilog): the SC-3000 keyboard's ghosting and the math unit's
# divide, which take several clocks in the core, against reference models, the
# MasterDrive register reads ($0A, $08), and the I/O gate and machine ID.
set -e
iverilog -g2012 -o tb_io tb_io.v ../../rtl/mdr_io.v
vvp -n tb_io | tee tb_io.log
grep -q '^PASS$' tb_io.log
