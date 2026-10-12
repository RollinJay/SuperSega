# Super Sega — Analogue Pocket core (milestone 1)

Design, status and verification: `docs/SuperSega_Pocket_Core_Design.md`. The machine it implements is defined by `../machine/super_sega_machine_v7.json` and `../machine/SuperSega_Technical_Reference_v3.md`.

```
rtl/                  the machine (platform-independent)
  ss_top.v            clocks enables, CPU, memory, I/O, VDP, PSG, bus synchroniser, enhancement layer
  ss_z80.v            tv80 wrapper: clock enables, exact I/O sample point
  ss_mem.v            memory map, mappers, work RAM, cartridge RAM
  ss_io.v             port decode, Game Gear and Super Sega registers, pads, SK-1100 PPI
  ss_vdp.v            Mode 4 VDP with the Super Sega register file
  ss_psg.v            SN76489 (Sega) with stereo panning
  ss_dpram.v          inferred dual-port block RAM
  third_party/tv80/   Z80 core (MIT); one local change, see LOCAL_CHANGES.md
pocket/               Analogue Pocket platform layer
  core_top.v          APF top level (port list from the APF template)
  ss_pocket.v         settings, ROM loading, system detection, PSRAM, saves, controls, video, audio
  ss_save_unload.v    save-slot read-out for the bridge
  ss_pll.v            53.693175 / 5.369318 / 5.369318+90 MHz
  core_constraints.sdc, ss_core.qip
  third_party/agg23/  data_loader, sound_i2s, sync_fifo, psram (MIT)
  dist/               SD-card files (core JSON, platform JSON)
  setup.sh            fetches the APF framework and assembles a Quartus project
  tools/reverse_rbf.py
sim/
  z80/                Z80 wrapper timing test (iverilog)
  sys/                machine simulation (Verilator): frames, traces, audio capture
  pocket/             platform simulation: APF bridge model, PSRAM model, saves
  ref/                Gearsystem runners used as a test oracle (sources only; see ref/README.md)
syn/                  Yosys resource estimate (synth.ys, synth.log)
tools/                test ROM generator, frame comparison, I/O test decoder
roms/                 the generated test ROMs (homebrew, made by tools/mk_testrom.py)
```

## Running the simulations

Requires Verilator 5, iverilog, Python 3 with numpy and Pillow.

```sh
python3 tools/mk_testrom.py roms/            # vdp192/224/240, spr12, save, tone, ssfeat, ports test ROMs
cd sim/sys && ./build.sh && mkdir -p out
./obj/tb_ss ../../roms/vdp224.sms sms 40 out/v224 10 37        # frames 10 and 37 as PPM
./obj/tb_ss game.sms sms 600 out/g -pal 200 500                 # PAL
./obj/tb_ss game.gg gg 600 out/gg 200 500                       # Game Gear
#   boosts: -spr16 -ovf -turbo N -vboost -afire -pstereo ; hold C: -holdc ; audio: -wav file.wav
./obj/tb_ss ../../roms/ports.sms ss 11 out/io 10                # I/O decode test; decode with:
python3 ../../tools/read_ports_ppm.py out/io_10.ppm [other.ppm]
cd ../pocket && ./build.sh && mkdir -p out
./obj/tb_pocket ../../roms/vdp224.sms 40 out/p 37               # through the Pocket layer
./obj/tb_pocket ../../roms/save.sms 10 out/s -save ../../roms/save_in.sav -readsave out/back.sav
./obj/tb_pocket ../../roms/ports.sms 11 out/k -system 3 -hold 5 10   # Super Sega mode, Pocket B held
python3 ../../tools/ppmdiff.py a.ppm b.ppm [side_by_side.png] [--tol 2]
```

## Building for the Pocket

```sh
cd pocket && ./setup.sh              # needs network access to github.com/open-fpga/core-template
# open build/src/fpga/ap_core.qpf in Quartus Prime Lite, compile, then
python3 tools/reverse_rbf.py build/src/fpga/output_files/ap_core.rbf bitstream.rbf_r
```

Copy `build/dist/*` to the SD card, put `bitstream.rbf_r` in `Cores/SuperSega.SuperSega/`, and ROMs in `/Assets/supersega/common/`.

## Licences

- tv80: MIT (Guy Hutchison; derived from Daniel Wallner's T80). One line changed, documented.
- agg23 analogue-pocket-utils: MIT (Adam Gastineau).
- APF framework files: Analogue's licence; fetched by `setup.sh`, not included.
- Gearsystem (GPL-3): used only as a test oracle through `sim/ref`; nothing from it is in the core.
- Super Sega RTL: **licence not yet chosen** (see the design doc, §16).
