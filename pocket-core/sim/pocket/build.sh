#!/bin/sh
# Build the Pocket platform-layer simulation (mdr_pocket + machine + PSRAM model).
set -e
R=../../rtl
P=../../pocket
verilator --cc --exe --build -j 2 -O3 --x-assign fast --x-initial fast --noassert \
  -Wno-fatal -Wno-lint -Wno-style -Wno-MULTIDRIVEN -Wno-COMBDLY \
  --top-module tb_pocket_top -Mdir obj -o tb_pocket \
  -I$R -I$R/third_party/tv80 -I$R/third_party/ikaopll -I$P -I$P/third_party/agg23 \
  tb_pocket_top.v psram_model.v dcfifo_model.v \
  $P/mdr_pocket.v $P/mdr_save_unload.v $P/third_party/agg23/data_loader.sv \
  $P/third_party/agg23/psram.sv \
  $R/mdr_top.v $R/mdr_z80.v $R/mdr_mem.v $R/mdr_io.v $R/mdr_vdp.v $R/mdr_psg.v $R/mdr_dpram.v $R/mdr_dma.v $R/mdr_pcm.v \
  $R/third_party/tv80/tv80_core.v $R/third_party/tv80/tv80_alu.v $R/third_party/tv80/tv80_mcode.v $R/third_party/tv80/tv80_reg.v \
  $R/third_party/ikaopll/IKAOPLL*.v \
  tb_pocket.cpp
