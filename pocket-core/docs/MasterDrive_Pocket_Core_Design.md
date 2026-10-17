# MasterDrive — Analogue Pocket Core: Design and Status

October 2026. Milestone 1. **Simulated, and built in Quartus with timing met; not yet run on a Pocket.**

## 1. What this is

An FPGA implementation of the MasterDrive machine (`../machine/masterdrive_machine_v7.json`, `../machine/MasterDrive_Technical_Reference_v3.md`) for the Analogue Pocket's openFPGA platform. Paths in this document are relative to `pocket-core/`. It is the second implementation of the machine alongside the emulator's machine model, and it is checked against the same references.

It is split in two:

| Layer | Files | Role |
|---|---|---|
| **Machine** | `rtl/` | The console: Z80, VDP, PSG, FM chip, memory map, I/O. Platform-independent — it knows nothing about the Pocket |
| **Pocket platform** | `pocket/` | Everything between the Pocket's framework (APF) and the machine: clocks, ROM loading, saves, controllers, video and audio output, the settings menu |

The emulator-only tools (hack maker, MSX porting, Lab, etc.) have no part in either.

**Terms.** The *enhancement layer* (AEL) is the machine's set of optional boosts for unmodified software, such as removing sprite flicker; all but True TMS colours and Start = Pause are off by default (§10). The *bus synchroniser* holds the CPU when turbo makes it faster than the video chip, or the FM chip, can accept data. *ESAT* (extended sprite attributes) and *unique-cell mode* (1024 tiles, one per screen cell) are MasterDrive drawing features; the Technical Reference describes them.

## 2. What runs in milestone 1

| Area | Status |
|---|---|
| Master System and Game Gear software | runs in simulation; every frame compared so far matches Gearsystem (one title, Batman Returns: SMS frames 30–1500, GG frames 200–1500, GG within Gearsystem's colour rounding) |
| MasterDrive software | register banks, native/extended CRAM, the Feature Enable B height, 16 sprites per line, turbo and the bus synchroniser give the same picture as the emulator on a feature test ROM, and so do the picture extensions on two more: the ESAT, 16×16 and magnified sprites, the line tables, the tile and text windows and unique-cell tiles (VRAM expansion: CPU access and unique-cell tiles). Per-sprite collision and bank 1 R4–R6 are not drawn, as in the emulator (Q28). The DMA engine gives the same picture as the emulator on a DMA test ROM and costs the CPU the emulator's time, except a transfer from the cartridge at 125–175 % turbo, which takes longer (§11, Q26) |
| SG-1000 / SC-3000 software | runs in simulation, in all four TMS9918 picture modes (Graphics I and II, Text, Multicolor) with their sprites. Four SG-1000 test ROMs give the same pictures as the emulator and Gearsystem (within the core's 4-bit-per-channel colour output for true TMS colours). MasterDrive software can also run the TMS modes at 224 and 240 lines (Q17), which three test ROMs check against the emulator. A headerless ROM of 64 KB or less starts in SG-1000 mode; SC-3000 cartridges need System set to SC-3000. The keyboard is implemented but not yet tested on the core |
| MasterDrive system registers | all behind the I/O gate: in MasterDrive mode `$01`–`$17` answer only while Feature Enable A bit 7 is set, and until then are the Master System's `$3E`/`$3F` mirrors (Q1, decided; Q-numbers are the machine's open questions, Technical Reference §17). Work RAM banking (`$0A`, read back, Q9); the math unit (`$0C`–`$10`), its divide giving the quotient and the remainder (Q7); multitap detection (`$16`); the machine ID (`$17`, reads `$A7`, Q8); the Game Gear serial registers (`$01`–`$05`), which hold what is written. Slot select (`$09`) and the card bank (`$0B`) are decoded, but the platform loads no card, so the card slot is always empty |
| Sound | PSG with stereo, and the FM unit (the YM2413, as IKAOPLL) in Master System and MasterDrive modes, with the four `$F2` states (PSG only, FM only, neither, both). Games that check for FM find it and play their FM music. FM is checked with a test ROM in simulation, not yet with games. PCM and the two wavetable voices in MasterDrive mode, at the emulator's rates, pitch and levels (Q27), checked with a test ROM in simulation |
| Saves | cartridge RAM, two 16 KB banks (Q3), saved to the SD card (32 KB `.sav`). Save states would be a feature of the Pocket platform layer, not of the machine, and are not planned in this milestone |
| Enhancement-layer boosts | sprite limit (Mode 4 and the TMS modes), stock overflow flag, turbo, VRAM speed-up, auto-fire, pseudo-stereo, Game Gear uncrop — all off by default — and True TMS colours (Q11) and Start = Pause (the pad has no Pause button), on by default. All are switchable in the settings menu and act only on Master System, Game Gear, SG-1000 and SC-3000 software, except True TMS colours, which also acts on MasterDrive software's TMS modes |
| The BIOS | the machine's own menu (Technical Reference §20) runs at every cold reset, from an 8 KB block RAM loaded from `rtl/mdr_bios.hex`; its screens and its first 50,000 instructions are the emulator's in simulation, and every simulation case starts through it (holding Start: the skip path) and runs as the emulator's direct start, counted from the launch. The launch resets every block in the clock before the first base cycle after the VDP's wrap to line 0, so the game's first clock is that of a cold reset (at turbo too); the pixel divider and the VDP's output stage keep their pace. The first cold reset takes the boosts from Core Settings; later ones keep the boosts in effect, which the BIOS may have changed, as the emulator does |
| Not yet | SF-7000 and floppy, debug unit, mouse/trackball, multitap protocols, link cable, loading a card, sleep |

## 3. Clocks

One PLL from the Pocket's 74.25 MHz reference makes three clocks from a single VCO:

| Clock | Frequency | Use |
|---|---|---|
| `clk_sys` | 53.693175 MHz | the whole machine; = 15 × the 3.579545 MHz CPU base clock and 10 × the 5.369318 MHz pixel clock |
| `clk_vid` | 5.369318 MHz | video to the Pocket's scaler |
| `clk_vid_90` | 5.369318 MHz, +90° | the scaler's capture clock |

Inside the machine everything runs on `clk_sys` with clock enables: the CPU enable (every 15 clocks at 100 %, or a fractional accumulator for the turbo steps), the base-cycle enable for the VDP's timing and the FM chip's master clock, the PSG enable (÷16), and the pixel enable (÷10). Because the three PLL outputs share a VCO, the video stage samples the machine's video registers directly; the constraints keep the three clocks in one group so those paths are timed rather than cut.

**PAL.** The machine's PAL CPU clock is 3.546893 MHz (Technical Reference §1). The clocks above stay as they are; instead, in PAL the machine's time stands still for one `clk_sys` in every 109.63 (32,652 in every 3,579,545, an exact accumulator in `mdr_top`). Every base cycle is then 15 or 16 `clk_sys`, 3.546893 MHz on average with no drift, and everything that counts base cycles or machine clocks runs at the PAL rate: the CPU and turbo (so the turbo steps are the same percentages of the PAL clock, as the machine defines them: Technical Reference §1, Q22), the VDP's timing, the PSG and the FM chip. Frames come at 49.70 a second. The pixel enable is never held, so pixels still leave at the fixed 5.369318 MHz pixel clock: the VDP starts each output line at its own line start, and a PAL line is 345 or 346 pixel clocks (§7). The TV standard is taken only while the machine is in reset, and changing the Video setting restarts it (§10). The alternative, a second PLL setting, would change the clocks the Pocket's video scaler and the constraints see and could not be simulated here; it remains the fallback if the scaler does not accept the uneven PAL lines (`mdr_top`'s `PAL_LINE_LOCK = 1` would first try lines of exactly 345, 0.04 % fast).

## 4. Memory

| Content | Where | Size |
|---|---|---|
| Cartridge ROM | PSRAM chip 0, die 0 | up to 4 MB, the largest cartridge the machine takes (Q2) |
| Card ROM (dual slot) | PSRAM chip 0, die 1 (reserved) | up to 512 KB |
| Work RAM | block RAM | 128 KB |
| VRAM | block RAM | 32 KB |
| Cartridge RAM (saves) | block RAM, second port for the save slot | 32 KB |
| CRAM, line buffers | block RAM | small |

The machine reads ROM over a request/acknowledge bus; the platform serves it from PSRAM through agg23's MIT-licensed PSRAM controller. A read takes about 9 machine clocks (170 ns) from the CPU's request to the data. Simulation at 200 % turbo shows the same instruction timing for ROM latencies up to 11 clocks; from 12 clocks the CPU starts to wait, which only slows it slightly. So PSRAM is fast enough with a small margin at the top turbo step and a large one at normal speed. (The memory controller sees the CPU's bus one clock late, for timing, §11; before that the limit was 12 clocks.)

**Block RAM budget.** The Quartus build (§12) uses 213 of the 308 M10K blocks, most of them for the 128 KB work RAM (5 for the FM unit, 8 for the BIOS ROM). The MasterDrive picture extensions, DMA engine, PCM and wavetable fitted beside it; if later features need more block RAM, the work RAM can move to the Pocket's 256 KB SRAM chip.

## 5. Loading a cartridge

1. The Pocket's framework (APF) holds the core in reset, announces data slot 0 with its size, and writes the file over the bridge as 32-bit big-endian words at `$1000_0000`.
2. agg23's `data_loader` brings the words into `clk_sys` and the platform writes them to PSRAM as 16-bit words. A file whose size is 512 bytes over a multiple of 1 KB has a copier header; the first 512 bytes are dropped.
3. The machine starts in its BIOS (Technical Reference §20), which reads the cartridge's header itself through `$3E` and picks the machine: region 5–7 → Game Gear, 8 → MasterDrive, anything else with a header → Master System, no header and 64 KB or less → SG-1000, otherwise Master System. The platform gives it, through the BIOS's settings, the System setting as its first offer (Auto: none), the cartridge's size (log2, rounded up), the mapper, the region and the machines this core runs (all but the SF-7000). SC-3000 carts cannot be told apart from SG-1000 by content: choose SC-3000 in the BIOS menu or in System. **System = MasterDrive** offers MasterDrive mode first, the native-mode option for an export cartridge (Q8). A change of System restarts the machine, so the BIOS offers the new choice. The machine the BIOS launches (`mdr_top`'s `mode_run`) sets the Game Gear window, the Pause button and whether cartridge RAM is saved.
4. The ROM size rounds up to a power of two for the mapper mask, at least 8 KB, so an 8 KB image mirrors in 8 KB. A read beyond the loaded image (from an image whose size is not a power of two) wraps into the image, as the emulator's address modulo the length does, never reaching what PSRAM still holds from an earlier cartridge: the BIOS reads the header at `$7FF0`, `$3FF0` and `$1FF0` whatever the size, and an old header there would start the wrong machine. (One subtraction does it for an image of 4 KB or more; beyond that a smaller image reads `$FF`. What the machine should return is open question Q39.)
5. The APF sends "all complete", writes the saved menu settings, and releases reset. The cartridge slot is required, so the machine starts only once a cartridge has loaded and the BIOS always sees one (its setting 17 bit 0); its no-cartridge page is seen only in the emulator.

**Bridge speed.** The APF sends each 32-bit write as its own SPI transaction (8 bytes at 2 bits per clock), so at most one word every ~431 ns. The loader drains one word every 300 ns. Simulation passes at the maximum rate; at one word every 270 ns (faster than the APF can send) the loader's 4-entry FIFO overflows.

## 6. Saves

Data slot 1 (`Save`, nonvolatile, `.sav`, up to 32 KB) maps to the machine's cartridge RAM, two 16 KB banks: bank 0 is `.sav` `$0000`–`$3FFF` and bank 1 `$4000`–`$7FFF` (Q3). A `.sav` written by an earlier build held two 8 KB banks; a game that uses only the first 8 KB of bank 0, as nearly all do, reads it unchanged:

- **Load**: at start the APF writes the file over the bridge at `$2000_0000`; it goes into the cartridge RAM's second port.
- **Write back**: on quit or power-off the APF reads `$2000_0000`–`$2000_7FFF`. A small read-out block (`pocket/mdr_save_unload.v`) fetches the four bytes of each word in the machine clock domain and hands the word back in one step. (agg23's `data_unloader` was tried first; it assumes the memory side is much faster than the bridge, and with this design it returned the fourth byte of every word four times.)
- **Size**: the save size in the APF's data-slot table is 32 KB once there is something to keep — a save file was loaded, or the game has written its cartridge RAM — and 0 otherwise, so games without saves leave no file. The flag survives a core reset; a zero size would truncate an existing save.

SG-1000/SC-3000 cartridge RAM is not battery-backed and is not saved. The SC-3000's is work RAM banks 4–7, which no other stock mode uses, not the saved cartridge RAM, so a cartridge with a save run as SC-3000 (one choice in the BIOS menu) leaves the save alone; it keeps what it held across a reset (Technical Reference §20, Q38).

## 7. Video

| | |
|---|---|
| Line | 342 pixels at 5.369318 MHz (228 CPU cycles × 1.5); in PAL 345 or 346 pixel clocks, the picture still 342 pixels (§3) |
| Active picture | 256 pixels from pixel 64; Game Gear window 160 × 144 (lines 24–167, pixels 48–207) |
| Latency | the VDP draws line N into a four-line ring buffer; it leaves during VDP line N + 2 |
| Sync | VS: one pixel at the start of VDP line *height* + 2; HS: one pixel at pixel 4 of every line |
| Colour | RGB444 from CRAM (TMS modes: the 16-entry TMS table, or CRAM entries 0–15 with Feature Enable C bit 0), widened to RGB888 by repeating each nibble |

After the last pixel of each line the platform sends the APF's end-of-line word that selects the scaler mode: `rgb[23:13]` = slot, `rgb[2:0]` = 000. The slot follows the number of lines in the previous frame:

| Slot | Mode | Aspect |
|---|---|---|
| 0 | 256 × 192 | 32 : 21 (8:7 pixels) |
| 1 | 256 × 224 | 64 : 49 |
| 2 | 256 × 240 | 128 : 105 |
| 3 | 160 × 144 (Game Gear window) | 10 : 9 |

## 8. Audio

The machine's sound (signed 16-bit, stereo: the PSG, the FM chip, the PCM and the wavetable, mixed as §11 describes) passes through two one-pole low-pass stages (about 21 kHz together) and is sampled at 48 kHz by agg23's `sound_i2s`. It is not a full decimation filter: PSG tones above ~24 kHz still alias, about 10 dB down. The FM chip makes 49,716 samples a second (one every 20 µs) and the machine holds each until the next, so the images of FM sound near 49.7 kHz are reduced only by the same two stages.

## 9. Controls

| Pocket | Mega Drive pad | Master System, Game Gear, SG-1000, SC-3000 | MasterDrive |
|---|---|---|---|
| D-pad | D-pad | D-pad | D-pad |
| A (east) | A | button 1 | A (read with TH low) |
| B (south) | B | button 2 | B (read as button 1 by Master System-style code) |
| Y (west) | C | auto-fire for button 2, with that boost on | C (read as button 2) |
| Start | Start | Start (Game Gear); Pause on SMS/SG/SC with the Start = Pause boost, on by default | Start |
| Select | — | Pause (not in Game Gear mode: the Game Gear has no Pause button) | Pause |

The Pocket's buttons are the console's Mega Drive pad in every mode, so each keeps its letter. The machine reads that pad as the old consoles' controller in the stock modes, A as button 1 and B as button 2 (Technical Reference §6), and as a Mega Drive pad in MasterDrive mode. Which Pocket button is which pad button is the Pocket's choice: A is on the east button and B on the south one, as the owner chose.

**Players set their own layout** in the Pocket's Core Settings > Controls menu. Analogue OS remaps a core's buttons per core (since firmware 1.1-beta-5; for docked controllers since 2.4, still marked beta) and builds that menu from `pocket/dist/Cores/MasterDrive.MasterDrive/input.json`. The OS applies the remap before the core sees the pad, so the core needs no settings of its own for it, and a remap holds in every mode, because the core gives each of its inputs a fixed role per mode whichever Pocket button the player puts it on. `input.json` therefore names each input by its pad button and its role in the stock modes: A (button 1), B (button 2), C (auto-fire), Start and Pause. The d-pad cannot be remapped. X, L and R have no function by default, but the player can move any of the five functions onto them. `tools/check_core_json.py` (run by `sim/check.sh`) keeps `input.json` within the platform's limits and checks that every button it names is one the core reads.

To check on hardware, since the simulations cannot: the Controls menu shows the five entries with these defaults; a button moved to X still acts as its function in both a stock mode and MasterDrive mode; a remap of a docked second pad works; and a remap survives a power cycle.

Docked controllers 1 and 2 are the two pads. A docked USB keyboard (APF controller 3, type 4) is the SK-1100: up to six keys and the modifiers are mapped by position.

| PC key | SK-1100 key |
|---|---|
| letters, digits, `, . / ; - [ ]` | the same key |
| `'` | `:` |
| `` ` `` | `@` |
| `=` | `^` |
| `\` | YEN |
| Enter | CR |
| Backspace, Delete, Insert | INS/DEL |
| Home | HOME/CLR |
| Esc | BREAK |
| Tab | GRAPH |
| F1 / F2 / F3 | FUNC / ENG DIERS / PI |
| Ctrl / Shift | CTRL / SHIFT |
| F12 | RESET (raises NMI) |
| arrows | arrows |

## 10. Settings menu

All settings are marked to persist, so the Pocket keeps them between sessions. Boosts are the machine's enhancement layer and default off, except True TMS colours (Q11) and Start = Pause.

| Entry | Choices |
|---|---|
| Reset | action |
| System | Auto, Master System, Game Gear, MasterDrive, SG-1000, SC-3000: the machine the BIOS menu offers first (Auto: from the header); MasterDrive offers an export cartridge native mode (Q8); a change restarts the machine |
| Region | Export, Japan |
| Video | NTSC 60 Hz, PAL 50 Hz; a change restarts the machine on the new standard |
| Mapper | Sega, Codemasters, Korean, Korean MSX |
| Boost: Sprites/line | Stock (8; 4 in the TMS modes), 16, 16 with the stock overflow flag (a ninth sprite; Mode 4 only); one setting for the BIOS's first two boosts, so a change of it sets both |
| Boost: CPU turbo | Off, 125 %, 150 %, 175 %, 200 % (stock software; MasterDrive titles set their own) |
| Boost: VRAM speed-up | on/off |
| Boost: Start = Pause | on (default) / off |
| Boost: Auto-fire | on/off (the trigger is Y unless the player moves it) |
| Boost: Pseudo-stereo | on/off |
| Boost: True TMS colours | on (default) / off: the TMS9918's own colours, or the Master System's approximation |
| Game Gear screen | LCD 160×144, Full 256×192 |
| Keyboard ghosting | on (stock) / off |
| SC-3000 cart RAM | 16 KB, 32 KB |

The APF shows at most 16 entries; 15 are used. Controls take none: they are the Pocket's own Controls menu (§9). A boost changed here takes effect at once and for the next launch, and the BIOS menu shows it at once; one changed in the BIOS menu takes effect at the launch, while this menu still shows its own value (the core cannot write the Pocket's settings). The machine takes a value once two samples in a row agree, so a setting whose bits cross into the machine's clock in different clocks makes one change.

## 11. Machine RTL notes

- **CPU**: tv80 (MIT, a Verilog translation of T80) behind a wrapper that runs it on clock enables and reports the exact enable at which an I/O access happens. Three small changes are made to tv80 (documented in `rtl/third_party/tv80/LOCAL_CHANGES.md`). With an external WAIT on an I/O cycle, tv80 lingered in T2 after WAIT was released, so the wrapper saw the access twice; this was found when the turbo bus synchroniser hung the CPU, and instruction timing without WAIT is unchanged. And SP resets to `$DFF0`, the value the machine hands to software (Technical Reference §1), instead of tv80's `$FFFF`. And `INI`, `IND`, `INIR` and `INDR` take the Z80's 4, 5, 4 and 3 T-states (5 more when they repeat) instead of tv80's 4, 4, 4 and 4, so their port read ends at T13, as on the Z80 and in the emulator.
- **VDP timing** follows Gearsystem's per-cycle event table (315-5535 column, §16 of the Technical Reference). The renderer draws a line at its render event: next line's sprites first (so overflow and collision flags are ready on time), then this line's background, then the composite through CRAM into the output ring. All line buffers are block RAM with one write and one registered read port; the only flip-flop array is the 512 sprite-present bits used for collisions.
- **Enhancement layer** inputs on `mdr_top`: `ael_sprlimit`, `ael_ovf_stock`, `ael_startpause`, `ael_turbo`, `ael_vramboost`, `ael_autofire`, `ael_pstereo`, `ael_ggwide` (Game Gear uncrop) and `ael_tmscol`, the values in the platform's menu, and `ael_chg`, a one-clock pulse for each boost the platform changes (bit 0–8 for the BIOS's setting 1–9; one setting may pulse several: Sprites/line pulses indices 1 and 2). `mdr_io` keeps each boost's current and next value (taking the platform's on a pulse and at the first cold reset), and the machine acts on the current ones; the Game Gear window comes from the running machine and the current uncrop value. Every boost but `ael_tmscol` is ignored in MasterDrive mode, where software sets those features itself; True TMS colours also acts on MasterDrive software's TMS modes (Q11).
- **Debug unit**: not in this milestone. Its control port `$FB` is written in every mode and reads back in MasterDrive mode; `$FC`/`$FD` read the status of a unit with no debug host attached (`$40`). In the stock modes `$FB`–`$FF` read as the controller mirror, as on the stock machine.
- **FM**: IKAOPLL (BSD 2-Clause, Sehyeon Kim, who signs its LICENSE as Raki; `rtl/third_party/ikaopll`, unchanged, upstream commit in its `VERSION` file), a YM2413 core reverse-engineered from die shots of the chip, runs on the base-cycle enable as the chip's 3.579545 MHz master clock, so it makes a sample every 72 cycles (49.7 kHz). Each `OUT` to `$F0`/`$F1` becomes a chip-select and write pulse 32 clocks long, so IKAOPLL's write-request input, which samples on master-clock edges, catches it; the CPU's next `OUT` comes at least 82 clocks later. The YM2413 data sheet gives the reset pulse as 80 master-clock cycles (typical; it lists no minimum) and IKAOPLL needs 72, longer than the machine reset may be, so the chip's reset is held 96 base cycles (27 µs) after the machine's; a write in that time is lost. The chip needs time between writes (12 master-clock cycles after an address, 84 after data). Software leaves it at 100 %; at turbo the bus synchroniser holds the CPU on an FM write until that time has passed (Technical Reference §1), so a driver written for 100 % keeps its FM music. The mix follows `$F2` bits 1–0 (0 PSG only, the power-on state; 1 FM only; 2 neither; 3 both, Technical Reference §7) and puts the FM output, which is mono, on both sides at 8 times the chip's level, so one FM channel at full volume peaks at half a PSG channel at full volume (the original's balance is open question Q20; IKAOPLL's default weights set the melody and rhythm balance). For headroom the sum is scaled by 41/64 (3.9 dB down), so the 16-bit full scale is 6.25 PSG channels at full volume, as in the emulator: nine FM channels at full volume fit, and only several sources at full volume together can reach the limit, where the output saturates: both chips, or the PSG with the PCM and both wavetable voices. `mdr_top`'s parameter `FM_FITTED` (1) can leave the FM unit out, in which case the `$F2` latch does not answer either.
- **TMS9918 modes** share the renderer's passes with Mode 4. The background pass fetches, for each column, the name, then the pattern and colour bytes (Multicolor: the colour block; Text: 40 columns of 6 pixels between 8-pixel borders) and writes the TMS colour, 0 for transparent. The sprite pass reads the 4-byte entries, keeps the first four on the line (or the boosted limit) and draws them last to first, so the lowest-numbered ends on top; transparent sprites are skipped. The composite looks the colour up in a 16-entry TMS table (true colours rounded to 4 bits per channel, or the Master System approximation), or in CRAM entries 0–15 when Feature Enable C bit 0 is set. The overflow and collision flags are set at the render event, as the emulator and Gearsystem do (Technical Reference §3). At 224 and 240 lines (Feature Enable B, MasterDrive mode; Q17) the passes carry on below line 192 with the same addressing, so Graphics II rows 24–29 come from a fourth bank; Y = `$D0` ends the sprite list only at 192 lines, and a sprite wraps to the top only when *Y* + 1 is 241 or more, as in Mode 4. In MasterDrive mode the TMS modes also raise the line interrupt (R0 bit 4, Q15).
- **MasterDrive picture extensions** (Mode 4, Technical Reference §3 and §5) use the same passes. The sprite scan reads two bytes per sprite, its Y and ESAT byte 0, because that byte sets the height (8 or 16 lines, doubled by R1 bit 0 and again by the ESAT, up to 64); a selected sprite's X, tile and both ESAT bytes are read before its pattern, which for a 16-pixel-wide sprite is two tiles' rows. Drawing goes one screen pixel a clock across the magnified width, and the sprite line buffer keeps each pixel's colour, palette and ESAT priority, so the composite can put a priority sprite behind the background's opaque pixels. Before the background the pass reads the line's scroll-table and vertical-offset bytes; on the window's lines the background stops at the window's X split and the window (tiles, unscrolled) or the text window (40 characters of 6 pixels) fills the rest; the background line buffer keeps an opaque bit for the ESAT priority. The busiest line (16 sprites of 64 × 64 pixels with the text window) finishes within the line's 3,420 clocks.
- **DMA engine** (`rtl/mdr_dma.v`, Technical Reference §9). Writing `$FA` with bit 7 set in MasterDrive mode starts a transfer with the values in `$F4`–`$FA`. The engine takes the memory bus and moves one byte at a time: it reads through the memory controller (source 1 reads the card bank and source 2 the selected work RAM bank, whatever the mapper and `$3E` say), or through the VDP's CPU port for a VRAM-to-VRAM copy, and writes through the VDP's CPU port, a CRAM byte by reading its 12-bit entry and writing it back with the byte in place (while the engine reads the next byte), marking the palette written as a CPU write does. The CPU goes on into the first T-state of its next opcode fetch, whose read the engine makes for it when it hands the bus back, and is held on its WAIT line from that fetch's second T-state until the transfer is done and it has been charged what the emulator charges: one T-state a byte, and the cartridge wait state on each byte read from the cartridge at 200 % (Q26), one wait state for each T-state charged. The fetch's own cartridge wait state is added to the charge, so the two do not overlap. The emulator moves the whole transfer at once and then charges the CPU, so the two take the same time while the engine keeps up with the charge. A byte takes it 2 machine clocks in a fill (4 into CRAM, which waits for the VDP), 5 in a VRAM copy, 7 from work RAM, and from the cartridge about 6 plus the memory's read, 15 with the PSRAM (§4); a T-state is 15 machine clocks at 100 %, 12, 10 and 8.6 at 125 %, 150 % and 175 %, and 7.5 at 200 % (where a cartridge byte is charged two). So a transfer from the cartridge at 125 %, 150 % and 175 % takes about as long as at 100 %, longer than the emulator charges, and at 100 % and 200 % it keeps up with no margin. `sim/check.sh` compares the CPU's time for each transfer in `roms/dma.sms` with the emulator's, instruction by instruction, at 100 % with the PSRAM's latency. The VDP keeps drawing during a transfer, so one made during the active display shows partway down the picture, where the emulator's appears at once.
- **PCM and wavetable** (`rtl/mdr_pcm.v`, Technical Reference §7), in MasterDrive mode with the I/O gate open. `$07` queues a sample in a 64-byte FIFO (a byte written while it is full is dropped); the rate `$08` bits 1–0 select (8,000, 11,025, 16,000 or 22,050 a second) takes one out, and the output holds the last sample while the FIFO is empty; reset returns it to silence. While it is keyed on with *f* above 0, each wavetable voice moves on to its next four-bit sample *f* × 102.4 times a second, so it plays its 32 samples *f* × 3.2 times a second. The rates and the pitch count the 53.7 MHz system clock, so they are in real time in PAL too, as in the emulator. The levels are the emulator's: in the units in which a PSG channel at full volume peaks at 8,191, the PCM is (sample − 128) × 80 and a voice (sample − 8) × volume × 51. The PCM goes to both sides and each voice to the sides `$15` selects, added to the mix before its 41/64 headroom scaling; `$F2` does not mute them, as in the emulator. Rates, pitch, levels and muting are all open in the machine (Q27).
- **Collision flag**: set at Gearsystem's time (22 + X × 228 ÷ 256 into the line), or at the render event if that is earlier. Gearsystem drops collisions that fall after its render event; the hardware does not.
- **Meeting timing at 53.7 MHz.** Everything runs on the one system clock, but the CPU only advances on its clock enable, at most once every 7 clocks (200 % turbo), and never on two clocks in a row. tv80's instruction decoding is too slow for one clock, so `pocket/core_constraints.sdc` gives two clocks to paths from the CPU to itself and to the blocks that take CPU data only on an enable edge (the I/O decode, the VDP, the PSG and the wrapper's bus strobes). The memory controller acts between enable edges, so instead of a relaxed constraint it gets a register stage: it sees the CPU's bus one clock late (§4). Two calculations that were one long chain of logic now take several clocks, with the result ready long before the CPU can read it: the SC-3000 keyboard's ghosting (16 clocks) and the math unit's divide (8 clocks; the CPU's next IN comes at least 82 clocks later).

## 12. Resources and timing

Quartus Prime Lite 18.1 build of the whole core (machine, Pocket platform layer and Analogue's framework) for the Pocket's FPGA, a Cyclone V 5CEBA4F23C8:

| | Used | Of |
|---|---|---|
| Logic (ALMs) | 6,690 (36 %) | 18,480 |
| Registers | 7,434 | |
| Block RAM (M10K) | 213 (69 %) | 308 |
| DSP blocks | 11 | 66 |

The FM unit (IKAOPLL and the sound mix) accounts for about 770 ALMs, 1,250 registers, 5 M10K blocks and 3 DSP blocks (what it added when it went in); the mix's headroom scaling takes 2 more DSP blocks. The DMA engine, PCM and wavetable added about 630 ALMs, 140 registers, 2 M10K blocks and 4 DSP blocks (the PCM and wavetable levels are multiplications). The BIOS ROM takes 8 M10K blocks; its ports, settings and launch, about 100 registers.

Timing is met at all four of Quartus's corners (slow and fast silicon, 0 °C and 85 °C). The 53.7 MHz machine clock has at least 3.0 ns to spare in its 18.6 ns period, and every hold check passes. Getting there needed the changes listed under "Meeting timing" in §11; the first build missed by 68 ns.

`syn/` holds a Yosys estimate of the machine alone (`syn/synth.log`: 213 M10K blocks and about 9,970 LUTs with the FM unit, the picture extensions, the DMA engine, PCM and wavetable, and the BIOS ROM), useful only as a quick check where Quartus is not installed. An earlier version of the VDP read its line buffers combinationally, which turned them into 15,000 flip-flops; restructuring them as block RAM brought the flip-flop count down eightfold.

## 13. Verification

Everything below is simulation (Verilator 5.020, iverilog) except the last row, the Quartus build. Gearsystem is used only as an independent test oracle and is not part of any deliverable.

| Test | Result |
|---|---|
| Z80 wrapper (`sim/z80/run.sh`): the start cycle of 60 instructions (IX/IY, DDCB, block I/O including `INI`, `IND`, `INIR`, `INDR`, `OTIR` and `OTDR`, IN/OUT, CALL/RET) and the T-state, port and value of their 18 port accesses, against the emulator's Z80 | match; the port-access check fails on tv80's original `INI` timing (the read one T-state early) |
| Machine, Batman Returns (Europe) SMS, PAL, frames 30–1500 | identical to Gearsystem |
| Machine, Batman Returns (World) GG, frames 200–1500 | identical to Gearsystem (Gearsystem's GG colour table rounds 5 → 86; compared within 2 levels) |
| VDP test ROMs, 192 / 224 / 240 lines, scrolling both axes, sprites at the bottom, `$D0`, Y wrap | RTL = emulator = Gearsystem (Gearsystem has no 240-line mode) |
| Sprite-limit test ROM: stock / 16 / 16 + stock flag | RTL = emulator, overflow flag as specified |
| MasterDrive feature ROM: register banks, native and extended CRAM with palette aliasing, Feature Enable B 224 lines, 16 sprites, 200 % turbo with VRAM writes during the display | RTL = emulator; the write loop runs 34.7 times a frame (1719 cycles per 64 writes), as the synchroniser's slot spacing predicts |
| Turbo: instructions per frame at 125–200 % | 1.250 / 1.500 / 1.749 / 1.999 ×, picture unchanged |
| ROM latency at 200 % turbo | no memory wait states up to 11 clocks (12 before the memory controller's register stage, §11); the PSRAM path takes about 9. The machine's own cartridge wait state (Q12) adds one T-state to every cartridge read at 200 % |
| Cartridge wait state at 200 % (`roms/romwait.sms`): 2,000 NOPs from cartridge ROM and from work RAM, at 200 % and 175 %, NTSC and PAL | RTL = emulator; at 200 % the ROM run ends five lines after the RAM run, at 175 % both end on the same line |
| PSG: tone `$0FE` | 440.4 Hz (expected 440.4); pseudo-stereo puts it left only in Master System mode and leaves it centred in MasterDrive mode |
| **Pocket platform** (bridge model → loader → PSRAM model → machine → video at the pixel clock) | Batman SMS frames 200/500 and GG 200/500 identical to Gearsystem; scaler slot words correct on every line |
| Cartridge load at the APF's maximum bridge rate | passes |
| Save slot: load a file, game writes cartridge RAM, read back | byte-exact |
| I/O test ROM (`roms/ports.sms`): 18 ports read in Master System, Game Gear and MasterDrive modes, idle and with button 1 held | RTL = emulator, except `$FC`/`$FD` bit 7 in MasterDrive mode (no debug host) |
| I/O gate test ROM (`roms/mdports.sms`): six low ports read before Feature Enable A bit 7 is set, then eleven with it set, after a multiply in the math unit, in MasterDrive, Master System and Game Gear modes; through the Pocket layer with System = MasterDrive and Auto | RTL = emulator in all three modes; MasterDrive mode reads `$FF` with the gate closed, then the registers and `$A7` at `$17`; the Pocket layer runs it in MasterDrive mode with System = MasterDrive and in Master System mode with Auto |
| MasterDrive register test ROM (`roms/mdrregs.sms`): multiply, divide (quotient, remainder, divide by zero), `$0A` written and read back, `$08` and `$17` | RTL = emulator, and the expected values: 200 ÷ 7 = 28 r 4, 200 ÷ 0 = `$FF`/`$00`, `$0A` = the bank in bits 3–0 |
| FM test ROM (`roms/fm.sms`): a PSG tone (440.4 Hz) and an FM sine (user instrument, 1001.4 Hz) while `$F2` steps through 0, 1, 3, 2, 0, captured at 48 kHz and checked by `tools/check_fm_wav.py` | each chip heard exactly in the `$F2` states that select it, on both sides; FM pitch 1001.4 Hz; FM ÷ PSG fundamental 0.390 (planned 0.391); in Game Gear mode the PSG alone in every state |
| FM at turbo (`roms/fm_tight.sms`): the same sounds with a driver that leaves the chip little more than its minimum time at 100 %, run at 200 % turbo | as `fm.sms`: the bus synchroniser holds the FM writes (without the hold, no FM at all) |
| PAL: frame timing, sound and video (`tb_mdr -pal`, `tb_pocket -set 108 1`, `check_fm_wav.py --pal`) | frames every 1,080,310–1,080,320 `clk_sys` (49.70 Hz), NTSC exactly 896,040 (59.92 Hz); base cycles every 15 or 16 clocks in PAL, 15 in NTSC, pixels every 10, CPU enables never on consecutive clocks (an enable check in `mdr_top`, simulation only); PSG 436.4 Hz and FM 992.2 Hz in PAL, also at 200 % turbo; through the Pocket layer PAL lines of 345 or 346 pixel clocks, 313 a frame, the same picture as the machine simulation; a switch from PAL to NTSC mid-frame restarts the machine with no frame longer than 313 lines |
| Auto-fire with C held (`-afire -holdc`) | button 2 toggles every two frames in Master System mode; no effect in MasterDrive mode |
| Pocket buttons held, Master System and MasterDrive modes (`tb_pocket -hold`) | Master System: A reads as button 1 and B as button 2; MasterDrive: B reads as button 1 (the pad's B with TH high) and A only through the TH multiplex. `sim/check.sh` checks all three |
| Verilator lint of `core_top` with the APF's `core_bridge_cmd` (project tree from `pocket/setup.sh`) | elaborates; only style warnings, the substantive ones in the template's own code |
| Identifiers used before their declaration (Quartus rejects these under `default_nettype none`) | none after fixes in `mdr_top`, `mdr_save_unload` and `core_top` |
| I/O unit (`sim/io/run.sh`): SC-3000 keyboard ghosting (4,000 random key patterns), the math unit (20,000 operand pairs, the divide of Q7), the `$0A` and `$08` reads, and the I/O gate and machine ID through the real port writes and reads, against reference models | match; the test catches a closure that skips ghosting and a divide one step short |
| TMS9918 modes: four SG-1000 test ROMs (`roms/tms_*.sg`: Graphics I, Graphics II with 16×16 sprites, Multicolor with magnified sprites, Text), frames 20 to 100, with sprite priority, collision and overflow flags, the early clock, a sprite wrapping at the top and a transparent sprite | RTL = emulator exactly in the Master System colours and within 8 levels in true TMS colours; also with the sprite boost; RTL = emulator = Gearsystem (Gearsystem in true colours, RTL within its 4-bit rounding). Through the Pocket platform layer a headerless TMS ROM starts in SG-1000 mode and matches the machine simulation |
| MasterDrive picture extensions: `roms/mdrgfx.sms` (the ESAT's flips, priority, 16×16, magnify, early clock and palettes, an unwritten palette, the line scroll and vertical-offset tables with R0 bit 6, the tile window, unique-cell tiles, a magnified sprite cut by the left edge) and `roms/mdrtext.sms` (224 lines, the text window, 16×16 sprites magnified by R1 bit 0 and the ESAT, 16 sprites of 64 × 64 pixels on one line), and four random pictures (`roms/gfxfuzz*.sms`: every VRAM byte in both 16 KB halves, part of CRAM and the Mode 4 and MasterDrive video registers from a seeded generator) | RTL = emulator; `mdrtext.sms` also through the Pocket platform layer; no line's render runs late |
| DMA engine: `roms/dma.sms` (a fill of the name table, a copy from the cartridge, three palettes and a fourth into extended CRAM, a copy from work RAM bank 3, a VRAM-to-VRAM copy, a copy from the empty card slot, and a fill that runs on from `$3FE0` into the upper 16 KB, shown as unique-cell tile 512; then transfers of 1 to 16 bytes of six kinds at each turbo step, so that some end in the first T-state of the CPU's next opcode fetch) | RTL = emulator; the CPU's time for each of the first eight transfers equals the emulator's, instruction by instruction (`tools/cmp_cycles.py`, at 100 % with the PSRAM's latency) |
| PCM and wavetable: `roms/pcm.sms` captured as audio (the PCM alone at each of its four rates, the two voices alone, the PCM with the voices, silence) and checked by `tools/check_pcm_wav.py` for each tone's level, pitch and sides | each tone within 2 % of the emulator's level and 0.05 % of its pitch (measured: within 0.3 % and 0.01 %), on the sides it should be on, and absent elsewhere |
| TMS9918 modes at 224 and 240 lines (Q17): three MasterDrive test ROMs (`roms/tms_g2_224.sms`, `tms_g2_240.sms`, `tms_txt_240.sms`: Graphics II with a fourth bank, Text past R2's 1 KB), with sprites below line 192, collision and overflow, a sprite at Y = `$D0`, the Mode 4 wrap and line interrupts counted on screen; the 240-line ROM also on the SG-1000 | RTL = emulator exactly in the Master System colours and within 8 levels in true TMS colours, also through the Pocket platform layer; on the SG-1000 the picture stays at 192 lines |
| The BIOS: its menu screens with scripted input (every page, the controller test, a headerless SG-1000 cartridge, MasterDrive software), its first 50,000 instructions (`tb_mdr -bios`, against `js_dump.js`/`jstrace.js` with `BIOS=1`), a Start held through the launch, its ports and settings (`sim/io`), and every case above started through it; through the Pocket layer, the machine each launch starts (the System setting's or the header's, again after a Video change), an 8 KB and a 24 KB headerless image loaded over PSRAM that holds an earlier cartridge's headers (`tb_pocket -trunc` with `+stale`), and a game with a save run as SC-3000 | RTL = emulator; instruction for instruction, the same time; no Pause from the held Start, one from the next press; the expected machine every time; the save slot reads back as loaded; the first clock after any reset a base cycle with the turbo accumulator at 0; the Pocket's video timing regular across the launch (one frame, across the launch or a restart, has its own length where the picture's height changes) |
| Quartus build (`pocket/build_core.sh`) | compiles; timing met at every corner (§12); the BIOS ROM's contents in the build equal `rtl/mdr_bios.hex` (`pocket/tools/check_bios_mif.py`) |

Not yet done: anything on hardware.

## 14. Building

`pocket/build_core.sh` builds everything in one step (about 15 minutes). It runs `pocket/setup.sh`, which fetches the APF framework files from `github.com/open-fpga/core-template` (they are under Analogue's licence and not kept in the repository) and lays out a Quartus project with the core's sources in `pocket/build/`; compiles it with Quartus Prime Lite 18.1 (`quartus_sh` if it is installed, otherwise the `raetro/quartus:pocket` Docker image); turns the bitstream into the reversed form the Pocket loads (`tools/reverse_rbf.py`); and puts the files for the root of the SD card, with the test ROMs, `TESTING.md` and the licence notices of the third-party code in the bitstream (IKAOPLL, tv80 and the T80 it translates, agg23's utilities), in `pocket/build/sdcard/` and `pocket/build/MasterDrive-pocket.zip`. GitHub runs the same script on every push that changes `pocket-core/` (the "Pocket core build" workflow, `../.github/workflows/pocket-build.yml`) and offers the SD-card files as a download. Games go in `/Assets/masterdrive/common/`.

## 15. Next milestones

1. **Hardware bring-up**: first boot on a Pocket (the user's hands-on testing, guided by `TESTING.md`). The Quartus build and timing are done (§12).
2. SF-7000 and floppy images, debug unit, mouse and trackball, link cable.
3. A proper audio decimation filter.

## 16. Decisions needed

| Decision | Why it matters |
|---|---|
| Core author name | The core is `MasterDrive.MasterDrive` on the SD card: the part before the dot is the APF's author field, here the project's name. The owner may want their own name there; changing it moves the core's folder, so a test install has to be copied again |
| DMA timing (Q26), PCM and wavetable clocks and levels (Q27) | The core's DMA engine, PCM and wavetable follow the emulator's choices (§11 gives where the DMA's timing differs); the machine's answers may change them |

Decided (October 2026):

- **Licence.** The project's own files, the RTL included, are MIT (`../LICENSE`). Third-party code keeps its own licence, and `pocket/build_core.sh` puts the notices of tv80, T80, IKAOPLL and agg23's utilities in the SD-card files.
- **IKAOPLL's provenance.** IKAOPLL is BSD 2-Clause, but its README says its 9-bit digital output design and its VRC7 instrument set were copied from nukeykt's `ym2413.v` in Nuked-SMS-FPGA, which is GPL-2.0-or-later. The owner left the choice to us, and the core keeps IKAOPLL under the BSD licence its author gives it: that is the licence the whole of IKAOPLL is published under, the core never selects the VRC7 instrument set, and IKAOPLL describes itself as reverse-engineered from Yamaha's data sheet and die shots of the chip. The provenance stays recorded (`rtl/third_party/ikaopll/VERSION`). If IKAOPLL's author or nukeykt ever says those parts are GPL, the core can be distributed as a whole under GPL-2.0-or-later (MIT and BSD code may be combined into a GPL work) or the FM core replaced.
