#!/bin/sh
# Build the Verilator model of the machine.
set -e
R=../../rtl
verilator --cc --exe --build -j 4 -O3 --x-assign fast --x-initial fast --noassert -Wno-fatal -Wno-lint -Wno-style \
  -DVERILATOR --top-module ss_top -Mdir obj -o tb_ss \
  -I$R -I$R/third_party/tv80 -I$R/third_party/ikaopll \
  $R/ss_top.v $R/ss_z80.v $R/ss_mem.v $R/ss_io.v $R/ss_vdp.v $R/ss_psg.v $R/ss_dpram.v \
  $R/third_party/tv80/tv80_core.v $R/third_party/tv80/tv80_alu.v $R/third_party/tv80/tv80_mcode.v $R/third_party/tv80/tv80_reg.v \
  $R/third_party/ikaopll/IKAOPLL*.v \
  tb_ss.cpp
