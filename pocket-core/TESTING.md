# Testing the core on an Analogue Pocket

This is the first build of the core that can be put on a Pocket. Everything below "should work" was checked in simulation, and the build meets timing in Quartus's analysis (its logic is fast enough for its clock, with margin), but **nothing has run on real hardware yet**, so treat this as a first test.

## Install

1. Get `MasterDrive-pocket.zip` (built by `pocket/build_core.sh`, or from the latest run of the "Pocket core build" workflow on GitHub, under Artifacts).
2. Unzip it onto the root of the SD card. It adds `Cores/MasterDrive.MasterDrive/`, `Platforms/masterdrive.json` and `Assets/masterdrive/common/test-roms/`.
3. Put your games (`.sms`, `.gg`, `.sg`, `.sc`) in `Assets/masterdrive/common/`.
4. The Pocket needs firmware 1.1 or later; remapping docked controllers needs 2.4 or later.
5. On the Pocket: Cores, MasterDrive, then pick a file.

## First check: the test ROMs

The zip includes the repository's own test ROMs (no commercial code), in `test-roms/`:

| ROM | What you should see or hear |
|---|---|
| `vdp192.sms`, `vdp224.sms`, `vdp240.sms` | a tiled pattern scrolling diagonally, 192, 224 and 240 lines tall, with sprites near the bottom |
| `spr12.sms` | twelve sprites on one row: with Boost: Sprites/line at Stock (8) only 8 show, at 16 all 12 (the backdrop colour shows the sprite-overflow flag) |
| `tone.sms` | a steady 440 Hz tone (A4) |
| `fm.sms` | a black screen and, after a quick burst of sound in the first second, a cycle of one second each, repeated: a 440 Hz buzz alone (the PSG), a purer tone of about 1 kHz alone (the FM chip), both together, then silence. If the 1 kHz tone never sounds, FM is not working |
| `fm_tight.sms` | the same sounds as `fm.sms`, from a driver that writes the FM chip as fast as it allows. With Boost: CPU turbo at 200% it should still sound the same: the console holds the CPU until the FM chip can take each write |
| `ports.sms` | rows of port numbers and the values read from them; holding a button changes the `$DC` row |
| `mdports.sms` | rows of port numbers and values, read before and after the ROM opens MasterDrive's I/O registers: with System = MasterDrive the first six rows read all ones (`$FF`) and the `$17` row below them `$A7`; with System = Auto (Master System mode) every row reads `$FF` |
| `mdrregs.sms` | rows of port numbers and values from MasterDrive's math unit and registers (it starts in MasterDrive mode by itself): 200 × 100, 200 ÷ 7, a divide by zero, the work RAM bank read back, and `$A7` at `$17` |
| `romwait.sms` | four rows of line-counter values (it starts in MasterDrive mode by itself): the same code run from the cartridge and from work RAM at 200 % (the cartridge row reads higher: its reads take a wait state) and at 175 % (the two rows match) |
| `mdrfeat.sms` | a coloured pattern drawn with the MasterDrive extensions (it starts in MasterDrive mode by itself) |
| `mdrgfx.sms` | the MasterDrive picture extensions (it starts in MasterDrive mode by itself): a tile pattern scrolled in a zigzag, line by line; a fixed panel of tiles in the top right corner (the window); near the top a row of F-shaped sprites: plain, mirrored left to right, upside down, 16 × 16, doubled in size, doubled 16 × 16, one cut by the left edge, one in another palette; lower down, sprites half hidden behind the background |
| `mdrtext.sms` | more MasterDrive picture extensions: the lower part of the screen is a panel of 40-column text in two colours (the text window); large F-shaped sprites, one four times its size; a row of sixteen large sprites side by side across the middle |
| `dma.sms` | a screen drawn by MasterDrive's DMA engine (it starts in MasterDrive mode by itself): eight rows of patterned tiles in three colour sets across the top (copied from the cartridge), then four bands on a blue patterned background: red and white tiles (copied from work RAM), yellow-green tiles (copied within video memory), a plain dark grey band (copied from the empty card slot) and yellow stripes (a fill that runs into the upper video memory) |
| `pcm.sms` | MasterDrive's own sound (it starts in MasterDrive mode by itself): a blank screen and a cycle of half a second each, repeated: a 250 Hz buzz on both sides (PCM samples), a pure 400 Hz tone on both sides with an 800 Hz buzz on the left only (the two wavetable voices), all three together, then silence |
| `save.sms` | writes four blocks to cartridge RAM, two in each 16 KB bank; a `.sav` file appears after you quit |
| `tms_g2_224.sms`, `tms_g2_240.sms`, `tms_txt_240.sms` | the SG-1000 picture modes at the taller heights MasterDrive software can give them (they start in MasterDrive mode by themselves): a busy patterned screen, or white characters for Text, filling 224 or 240 lines. In Graphics II, a cyan ring in the upper half and, below where an SG-1000 screen ends, a white block, a red ring in front of a green block, and a row of four blocks (a fifth is hidden by the sprite limit; at 224 lines only their top edge shows); a block wrapped from the bottom shows at the top right. With System = SG-1000, `tms_g2_240.sms` stays 192 lines tall and shows no sprites: there the first sprite's Y of `$D0` ends the list |
| `tms_g1.sg`, `tms_g2.sg`, `tms_mc.sg`, `tms_txt.sg` | the four SG-1000 picture modes: patterned screens with sprites (Graphics I, Graphics II, Multicolor) and a screen of white characters (Text). On a row lower down, four ring sprites (quarter rings in Graphics I and Multicolor) show and a fifth is hidden by the sprite limit. A green block slides right over a red one and passes behind it (the red one is sprite 0, so it stays in front). Wherever the background is transparent the backdrop colour shows, and it reports the sprite flags: with Boost: Sprites/line at Stock, light red while the limit hides a sprite (most of the time) and magenta for the few frames the two blocks touch; at 16 the fifth ring shows and the backdrop is black, light blue on contact. Text mode has no sprites, so its backdrop and borders stay black |

If these work, the core loads, draws, plays both sound chips and reads the buttons. The `tms_*` ROMs load as SG-1000 cartridges by themselves (no "TMR SEGA" header and 64 KB or less).

## Should work

- **Master System and Game Gear games:** picture in the 192-, 224- and 240-line modes, PSG sound (stereo on the Game Gear), both controllers when docked.
- **FM sound** (Master System and MasterDrive modes): games that support the FM unit of the Japanese Master System find it and play their FM music. Checked with the repository's FM test ROM, not yet with games.
- **SG-1000 games:** all four picture modes and their sprites (checked with the repository's test ROMs, not yet with commercial games), in the TMS9918's own colours (Core Settings, "Boost: True TMS colours", on by default; off gives the Master System's approximation).
- **Game Gear screen:** the 160 × 144 LCD window by default, or the full 256 × 192 picture (Core Settings, "Game Gear screen").
- **Saves:** cartridge RAM is saved to the SD card (`.sav`).
- **Controls:** A = button 1, B = button 2, Start = the Game Gear's Start or the Master System's Pause, Select = Pause too (no Pause on the Game Gear). In MasterDrive mode the buttons are the Mega Drive pad's: A, B, and C on Y. Move any of them in Core Settings > Controls.
- **Settings:** system, region, NTSC/PAL, mapper, and the boosts (more sprites per line to stop flicker, CPU turbo, auto-fire, pseudo-stereo, Start = Pause), all off by default except True TMS colours and Start = Pause.
- **MasterDrive titles:** register banks, extended colours, the taller screen modes, 16 sprites per line, turbo, and the picture extensions (extended sprite attributes, 16 × 16 and magnified sprites, line tables, window and text layers, unique-cell tiles), PCM and wavetable sound, and the DMA engine.

## Needs a setting first

- **Codemasters games** (Micro Machines, Cosmic Spacehead and others) and **Korean-mapper games:** set Core Settings > Mapper, then Reset. The core does not detect the mapper.
- **SC-3000 cartridges:** set System to SC-3000 (they look the same as SG-1000 cartridges). The SK-1100 keyboard is implemented but untested on the Pocket.
- **A Master System game without a "TMR SEGA" header** (a few Japanese ones) of 64 KB or less starts as SG-1000: set System to Master System.
- **PAL-only games:** set Video to PAL 50 Hz. Changing Video restarts the game.

## Won't work yet

- The SF-7000 and floppy disks, cards, cassettes, the mouse and trackball, multitaps, the link cable.
- Pocket save states (Memories) and sleep.

## Unknown until it runs

- Whether the core loads at all. Quartus's timing analysis passes at every temperature and voltage it models, so timing is not expected to be the problem, but only the hardware proves it.
- Loading large ROMs (the biggest Master System games are 1 MB) from the Pocket's memory.
- Picture scaling and aspect on the Pocket's screen and on a TV through the Dock.
- PAL: whether the picture is steady. The core keeps the Pocket's video clock fixed and makes PAL lines slightly uneven (345 or 346 pixel clocks); the Pocket's Developer > Statistics overlay should show 49.70 frames a second in PAL and 59.92 in NTSC.
- Audio level, clicks or pops, and whether FM music is too loud or too quiet beside the PSG (the balance is a provisional choice: open question Q20 in the Technical Reference); the same for the PCM and wavetable (Q27).
- How the Pocket's own button remapping behaves with this core.

## What to report

If something goes wrong, note the game, the System setting, docked or handheld, the firmware version, and what you saw (a photo helps): a core that does not appear, a crash on load, a black or garbled picture, wrong colours, or no or bad sound.
