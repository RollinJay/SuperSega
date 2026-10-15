# Testing the core on an Analogue Pocket

This is the first build of the core that can be put on a Pocket. Everything below "should work" was checked in simulation, and the build meets timing in Quartus's analysis (its logic is fast enough for its clock, with margin), but **nothing has run on real hardware yet**, so treat this as a first test.

## Install

1. Get `SuperSega-pocket.zip` (built by `pocket/build_core.sh`, or from the latest run of the "Pocket core build" workflow on GitHub, under Artifacts).
2. Unzip it onto the root of the SD card. It adds `Cores/SuperSega.SuperSega/`, `Platforms/supersega.json` and `Assets/supersega/common/test-roms/`.
3. Put your games (`.sms`, `.gg`, `.sg`, `.sc`) in `Assets/supersega/common/`.
4. The Pocket needs firmware 1.1 or later; remapping docked controllers needs 2.4 or later.
5. On the Pocket: Cores, Super Sega, then pick a file.

## First check: the test ROMs

The zip includes the repository's own test ROMs (no commercial code), in `test-roms/`:

| ROM | What you should see or hear |
|---|---|
| `vdp192.sms`, `vdp224.sms`, `vdp240.sms` | a tiled pattern scrolling diagonally, 192, 224 and 240 lines tall, with sprites near the bottom |
| `spr12.sms` | twelve sprites on one row: with Boost: Sprites/line at Stock (8) only 8 show, at 16 all 12 (the backdrop colour shows the sprite-overflow flag) |
| `tone.sms` | a steady 440 Hz tone (A4) |
| `ports.sms` | rows of port numbers and the values read from them; holding a button changes the `$DC` row |
| `ssfeat.sms` | a coloured pattern drawn with the Super Sega extensions (it starts in Super Sega mode by itself) |
| `save.sms` | writes to cartridge RAM; a `.sav` file appears after you quit |
| `tms_g1.sg`, `tms_g2.sg`, `tms_mc.sg`, `tms_txt.sg` | the four SG-1000 picture modes: patterned screens with sprites (Graphics I, Graphics II, Multicolor) and a screen of white characters (Text). On a row lower down, four ring sprites (quarter rings in Graphics I and Multicolor) show and a fifth is hidden by the sprite limit. A green block slides right over a red one and passes behind it (the red one is sprite 0, so it stays in front). Wherever the background is transparent the backdrop colour shows, and it reports the sprite flags: with Boost: Sprites/line at Stock, light red while the limit hides a sprite (most of the time) and magenta for the few frames the two blocks touch; at 16 the fifth ring shows and the backdrop is black, light blue on contact. Text mode has no sprites, so its backdrop and borders stay black |

If these work, the core loads, draws, plays sound and reads the buttons. The `tms_*` ROMs load as SG-1000 cartridges by themselves (no "TMR SEGA" header and 64 KB or less).

## Should work

- **Master System and Game Gear games:** picture in the 192-, 224- and 240-line modes, PSG sound (stereo on the Game Gear), both controllers when docked.
- **SG-1000 games:** all four picture modes and their sprites (checked with the repository's test ROMs, not yet with commercial games), in the TMS9918's own colours (Core Settings, "Boost: True TMS colours", on by default; off gives the Master System's approximation).
- **Game Gear screen:** the 160 × 144 LCD window by default, or the full 256 × 192 picture (Core Settings, "Game Gear screen").
- **Saves:** cartridge RAM is saved to the SD card (`.sav`).
- **Controls:** B = button 1, A = button 2, Start, Select = Pause (no Pause on the Game Gear). Move any of them in Core Settings > Controls.
- **Settings:** system, region, NTSC/PAL, mapper, and the boosts (more sprites per line to stop flicker, CPU turbo, auto-fire, pseudo-stereo, Start = Pause), all off by default except True TMS colours.
- **Super Sega titles:** register banks, extended colours, the taller screen modes, 16 sprites per line and turbo.

## Needs a setting first

- **Codemasters games** (Micro Machines, Cosmic Spacehead and others) and **Korean-mapper games:** set Core Settings > Mapper, then Reset. The core does not detect the mapper.
- **SC-3000 cartridges:** set System to SC-3000 (they look the same as SG-1000 cartridges). The SK-1100 keyboard is implemented but untested on the Pocket.
- **A Master System game without a "TMR SEGA" header** (a few Japanese ones) of 64 KB or less starts as SG-1000: set System to Master System.
- **PAL-only games:** set Video to PAL 50 Hz.

## Won't work yet

- **FM sound:** games that support the FM unit play their ordinary (PSG) music instead.
- **Super Sega graphics extensions:** extended sprite attributes, 16 × 16 and magnified sprites in Mode 4 (the Master System's picture mode), window and text layers, line tables and unique-cell mode.
- PCM and wavetable sound, the DMA engine, the SF-7000 and floppy disks, cards, cassettes, the mouse and trackball, multitaps, the link cable.
- Pocket save states (Memories) and sleep.
- PAL games run very slightly fast (50.16 frames a second instead of 49.70).

## Unknown until it runs

- Whether the core loads at all. Quartus's timing analysis passes at every temperature and voltage it models, so timing is not expected to be the problem, but only the hardware proves it.
- Loading large ROMs (the biggest Master System games are 1 MB) from the Pocket's memory.
- Picture scaling and aspect on the Pocket's screen and on a TV through the Dock.
- Audio level, clicks or pops.
- How the Pocket's own button remapping behaves with this core.

## What to report

If something goes wrong, note the game, the System setting, docked or handheld, the firmware version, and what you saw (a photo helps): a core that does not appear, a crash on load, a black or garbled picture, wrong colours, or no or bad sound.
