#!/bin/sh
# Build the Verilator model of the machine.
set -e
R=../../rtl
verilator --cc --exe --build -j 4 -O3 --x-assign fast --x-initial fast --noassert -Wno-fatal -Wno-lint -Wno-style \
  -DVERILATOR --top-module mdr_top -Mdir obj -o tb_mdr \
  -I$R -I$R/third_party/tv80 -I$R/third_party/ikaopll \
  $R/mdr_top.v $R/mdr_z80.v $R/mdr_mem.v $R/mdr_io.v $R/mdr_vdp.v $R/mdr_psg.v $R/mdr_dpram.v $R/mdr_dma.v $R/mdr_pcm.v \
  $R/third_party/tv80/tv80_core.v $R/third_party/tv80/tv80_alu.v $R/third_party/tv80/tv80_mcode.v $R/third_party/tv80/tv80_reg.v \
  $R/third_party/ikaopll/IKAOPLL*.v \
  tb_mdr.cpp
