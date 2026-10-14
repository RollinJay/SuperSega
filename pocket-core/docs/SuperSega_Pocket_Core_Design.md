# Super Sega — Analogue Pocket Core: Design and Status

October 2026. Milestone 1. **Simulated, and built in Quartus with timing met; not yet run on a Pocket.**

## 1. What this is

An FPGA implementation of the Super Sega machine (`../machine/super_sega_machine_v7.json`, `../machine/SuperSega_Technical_Reference_v3.md`) for the Analogue Pocket's openFPGA platform. Paths in this document are relative to `pocket-core/`. It is the second implementation of the machine alongside the emulator's machine model, and it is checked against the same references.

It is split in two:

| Layer | Files | Role |
|---|---|---|
| **Machine** | `rtl/` | The console: Z80, VDP, PSG, memory map, I/O. Platform-independent — it knows nothing about the Pocket |
| **Pocket platform** | `pocket/` | Everything between the Pocket's framework (APF) and the machine: clocks, ROM loading, saves, controllers, video and audio output, the settings menu |

The emulator-only tools (hack maker, MSX porting, Lab, etc.) have no part in either.

**Terms.** The *enhancement layer* (AEL) is the machine's set of optional boosts for unmodified software, such as removing sprite flicker; all are off by default (§10). The *bus synchroniser* holds the CPU when turbo makes it faster than the video chip can accept data. *ESAT* (extended sprite attributes) and *unique-cell mode* (1024 tiles, one per screen cell) are Super Sega drawing features; the Technical Reference describes them.

## 2. What runs in milestone 1

| Area | Status |
|---|---|
| Master System and Game Gear software | runs in simulation; every frame compared so far matches Gearsystem (one title, Batman Returns: SMS frames 30–1500, GG frames 200–1500, GG within Gearsystem's colour rounding) |
| Super Sega software | register banks, native/extended CRAM, the Feature Enable B height, 16 sprites per line, turbo and the bus synchroniser give the same picture as the emulator on a feature test ROM. VRAM expansion is CPU access only. ESAT, 16×16/magnified sprites, window/text layers, line tables and unique-cell mode are accepted but **not drawn yet** |
| SG-1000 / SC-3000 software | loads and runs, but the TMS9918 picture modes are **not drawn yet**. The keyboard is implemented but not yet tested on the core |
| Super Sega system registers | work RAM banking (`$0A`); the math unit (`$0C`–`$10`), with divide as the emulator does it until Q7 is decided (Q-numbers are the machine's open questions, Technical Reference §17); multitap detection (`$16`); the Game Gear serial registers (`$01`–`$05`), which hold what is written. Slot select (`$09`) and the card bank (`$0B`) are decoded, but the platform loads no card, so the card slot is always empty |
| Sound | PSG with stereo. **No FM yet**: the core reports no FM unit, so games that check for it play their PSG music. No PCM/wavetable |
| Saves | cartridge RAM saved to the SD card (32 KB `.sav`). Save states would be a feature of the Pocket platform layer, not of the machine, and are not planned in this milestone |
| Enhancement-layer boosts | sprite limit, stock overflow flag, Start = Pause, turbo, VRAM speed-up, auto-fire, pseudo-stereo, Game Gear uncrop — all off by default, switchable in the settings menu, acting only on Master System, Game Gear, SG-1000 and SC-3000 software |
| Not yet | FM, PCM, wavetable, DMA engine, SF-7000 and floppy, debug unit, mouse/trackball, multitap protocols, link cable, loading a card, the PAL CPU clock (§3), sleep |

## 3. Clocks

One PLL from the Pocket's 74.25 MHz reference makes three clocks from a single VCO:

| Clock | Frequency | Use |
|---|---|---|
| `clk_sys` | 53.693175 MHz | the whole machine; = 15 × the 3.579545 MHz CPU base clock and 10 × the 5.369318 MHz pixel clock |
| `clk_vid` | 5.369318 MHz | video to the Pocket's scaler |
| `clk_vid_90` | 5.369318 MHz, +90° | the scaler's capture clock |

Inside the machine everything runs on `clk_sys` with clock enables: the CPU enable (every 15 clocks at 100 %, or a fractional accumulator for the turbo steps), the base-cycle enable for the VDP's timing, the PSG enable (÷16), and the pixel enable (÷10). Because the three PLL outputs share a VCO, the video stage samples the machine's video registers directly; the constraints keep the three clocks in one group so those paths are timed rather than cut.

**PAL.** The machine's PAL CPU clock is 3.546893 MHz (Technical Reference §1). The Pocket core uses the NTSC master clock in PAL mode too, so PAL frames run at 50.16 Hz instead of the PAL console's 49.70 Hz (0.9 % fast). A second PLL setting would fix it; not done.

## 4. Memory

| Content | Where | Size |
|---|---|---|
| Cartridge ROM | PSRAM chip 0, die 0 | up to 8 MB |
| Card ROM (dual slot) | PSRAM chip 0, die 1 (reserved) | up to 512 KB |
| Work RAM | block RAM | 128 KB |
| VRAM | block RAM | 32 KB |
| Cartridge RAM (saves) | block RAM, second port for the save slot | 32 KB |
| CRAM, line buffers | block RAM | small |

The machine reads ROM over a request/acknowledge bus; the platform serves it from PSRAM through agg23's MIT-licensed PSRAM controller. A read takes about 9 machine clocks (170 ns) from the CPU's request to the data. Simulation at 200 % turbo shows the same instruction timing for ROM latencies up to 11 clocks; from 12 clocks the CPU starts to wait, which only slows it slightly. So PSRAM is fast enough with a small margin at the top turbo step and a large one at normal speed. (The memory controller sees the CPU's bus one clock late, for timing, §11; before that the limit was 12 clocks.)

**Block RAM budget.** The Quartus build (§12) uses 200 of the 308 M10K blocks, most of them for the 128 KB work RAM. When FM and the Super Sega render features need block RAM, the work RAM moves to the Pocket's 256 KB SRAM chip.

## 5. Loading a cartridge

1. The Pocket's framework (APF) holds the core in reset, announces data slot 0 with its size, and writes the file over the bridge as 32-bit big-endian words at `$1000_0000`.
2. agg23's `data_loader` brings the words into `clk_sys` and the platform writes them to PSRAM as 16-bit words. A file whose size is 512 bytes over a multiple of 1 KB has a copier header; the first 512 bytes are dropped.
3. While the ROM streams in, the platform looks for `TMR SEGA` at `$7FF0`, `$3FF0` and `$1FF0` and reads the region nibble. **System = Auto** then picks: region 5–7 → Game Gear, 8 → Super Sega, anything else with a header → Master System, no header and 64 KB or less → SG-1000, otherwise Master System. SC-3000 carts cannot be told apart from SG-1000 by content; select SC-3000 in the menu.
4. The ROM size rounds up to a power of two for the mapper mask.
5. The APF sends "all complete", writes the saved menu settings, and releases reset.

**Bridge speed.** The APF sends each 32-bit write as its own SPI transaction (8 bytes at 2 bits per clock), so at most one word every ~431 ns. The loader drains one word every 300 ns. Simulation passes at the maximum rate; at one word every 270 ns (faster than the APF can send) the loader's 4-entry FIFO overflows.

## 6. Saves

Data slot 1 (`Save`, nonvolatile, `.sav`, up to 32 KB) maps to the machine's cartridge RAM:

- **Load**: at start the APF writes the file over the bridge at `$2000_0000`; it goes into the cartridge RAM's second port.
- **Write back**: on quit or power-off the APF reads `$2000_0000`–`$2000_7FFF`. A small read-out block (`pocket/ss_save_unload.v`) fetches the four bytes of each word in the machine clock domain and hands the word back in one step. (agg23's `data_unloader` was tried first; it assumes the memory side is much faster than the bridge, and with this design it returned the fourth byte of every word four times.)
- **Size**: the save size in the APF's data-slot table is 32 KB once there is something to keep — a save file was loaded, or the game has written its cartridge RAM — and 0 otherwise, so games without saves leave no file. The flag survives a core reset; a zero size would truncate an existing save.

SG-1000/SC-3000 cartridge RAM is not battery-backed and is not saved.

## 7. Video

| | |
|---|---|
| Line | 342 pixels at 5.369318 MHz (228 CPU cycles × 1.5) |
| Active picture | 256 pixels from pixel 64; Game Gear window 160 × 144 (lines 24–167, pixels 48–207) |
| Latency | the VDP draws line N into a four-line ring buffer; it leaves during VDP line N + 2 |
| Sync | VS: one pixel at the start of VDP line *height* + 2; HS: one pixel at pixel 4 of every line |
| Colour | RGB444 from CRAM, widened to RGB888 by repeating each nibble |

After the last pixel of each line the platform sends the APF's end-of-line word that selects the scaler mode: `rgb[23:13]` = slot, `rgb[2:0]` = 000. The slot follows the number of lines in the previous frame:

| Slot | Mode | Aspect |
|---|---|---|
| 0 | 256 × 192 | 32 : 21 (8:7 pixels) |
| 1 | 256 × 224 | 64 : 49 |
| 2 | 256 × 240 | 128 : 105 |
| 3 | 160 × 144 (Game Gear window) | 10 : 9 |

## 8. Audio

The machine's PSG output (signed 16-bit, stereo) passes through two one-pole low-pass stages (about 21 kHz together) and is sampled at 48 kHz by agg23's `sound_i2s`. It is not a full decimation filter: PSG tones above ~24 kHz still alias, about 10 dB down. A proper filter can come with the FM mixer.

## 9. Controls

| Pocket | Master System, Game Gear, SG-1000, SC-3000 | Super Sega (Mega Drive pad) |
|---|---|---|
| D-pad | D-pad | D-pad |
| B | button 1 | B (read as button 1 by Master System-style code) |
| A | button 2 | C (read as button 2) |
| Y | auto-fire for button 2, with that boost on | A |
| Start | Start (Game Gear); Pause on SMS/SG/SC with the "Start = Pause" boost | Start |
| Select | Pause (not in Game Gear mode: the Game Gear has no Pause button) | Pause |

Buttons 1 and 2 stay on B and A in every mode, so a game and its Super Sega conversion play with the same buttons. The machine itself sees a Master System pad in the stock modes and a Mega Drive pad in Super Sega mode; only this default layout is the Pocket's choice.

**Players set their own layout** in the Pocket's Core Settings > Controls menu. Analogue OS remaps a core's buttons per core (since firmware 1.1-beta-5; for docked controllers since 2.4, still marked beta) and builds that menu from `pocket/dist/Cores/SuperSega.SuperSega/input.json`. The OS applies the remap before the core sees the pad, so the core needs no settings of its own for it, and a remap holds in every mode, because the core gives each of its inputs a fixed role per mode whichever Pocket button the player puts it on. `input.json` therefore names each input by its role in both kinds of mode: Button 1 (SS: B), Button 2 (SS: C), Auto-fire (SS: A), Start and Pause, where SS is Super Sega mode. The d-pad cannot be remapped. X, L and R have no function by default, but the player can move any of the five functions onto them. `tools/check_core_json.py` (run by `sim/check.sh`) keeps `input.json` within the platform's limits and checks that every button it names is one the core reads.

To check on hardware, since the simulations cannot: the Controls menu shows the five entries with these defaults; a button moved to X still acts as its function in both a stock mode and Super Sega mode; a remap of a docked second pad works; and a remap survives a power cycle.

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

All settings are marked to persist, so the Pocket keeps them between sessions. Boosts are the machine's enhancement layer and default off.

| Entry | Choices |
|---|---|
| Reset | action |
| System | Auto, Master System, Game Gear, Super Sega, SG-1000, SC-3000 |
| Region | Export, Japan |
| Video | NTSC 60 Hz, PAL 50 Hz |
| Mapper | Sega, Codemasters, Korean, Korean MSX |
| Boost: Sprites/line | Stock (8), 16, 16 with the stock overflow flag |
| Boost: CPU turbo | Off, 125 %, 150 %, 175 %, 200 % (stock software; Super Sega titles set their own) |
| Boost: VRAM speed-up | on/off |
| Boost: Start = Pause | on/off |
| Boost: Auto-fire | on/off (the trigger is Y unless the player moves it) |
| Boost: Pseudo-stereo | on/off |
| Game Gear screen | LCD 160×144, Full 256×192 |
| Keyboard ghosting | on (stock) / off |
| SC-3000 cart RAM | 16 KB, 32 KB |

The APF shows at most 16 entries; 14 are used. The two left are for the true-TMS-colour and legacy-sprite-limit boosts, which arrive with the TMS modes. Controls take none: they are the Pocket's own Controls menu (§9).

## 11. Machine RTL notes

- **CPU**: tv80 (MIT, a Verilog translation of T80) behind a wrapper that runs it on clock enables and reports the exact enable at which an I/O access happens. Two lines of tv80 are changed (documented in `rtl/third_party/tv80/LOCAL_CHANGES.md`). With an external WAIT on an I/O cycle, tv80 lingered in T2 after WAIT was released, so the wrapper saw the access twice; this was found when the turbo bus synchroniser hung the CPU, and instruction timing without WAIT is unchanged. And SP resets to `$DFF0`, the value the machine hands to software (Technical Reference §1), instead of tv80's `$FFFF`.
- **VDP timing** follows Gearsystem's per-cycle event table (315-5535 column, §16 of the Technical Reference). The renderer draws a line at its render event: next line's sprites first (so overflow and collision flags are ready on time), then this line's background, then the composite through CRAM into the output ring. All line buffers are block RAM with one write and one registered read port; the only flip-flop array is the 512 sprite-present bits used for collisions.
- **Enhancement layer** inputs on `ss_top`: `ael_sprlimit`, `ael_ovf_stock`, `ael_startpause`, `ael_turbo`, `ael_vramboost`, `ael_autofire`, `ael_pstereo`; Game Gear uncrop is the `gg_crop` input. Every boost is ignored in Super Sega mode, where software sets those features itself.
- **Debug unit**: not in this milestone. Its control port `$FB` is written in every mode and reads back in Super Sega mode; `$FC`/`$FD` read the status of a unit with no debug host attached (`$40`). In the stock modes `$FB`–`$FF` read as the controller mirror, as on the stock machine.
- **FM**: `ss_top` has a parameter `FM_FITTED`, 0 in milestone 1. While it is 0 the `$F2` detection latch does not answer, so software sees a console without the FM unit. With an FM core it becomes 1 and the latch answers in Master System and Super Sega modes.
- **Collision flag**: set at Gearsystem's time (22 + X × 228 ÷ 256 into the line), or at the render event if that is earlier. Gearsystem drops collisions that fall after its render event; the hardware does not.
- **Meeting timing at 53.7 MHz.** Everything runs on the one system clock, but the CPU only advances on its clock enable, at most once every 7 clocks (200 % turbo), and never on two clocks in a row. tv80's instruction decoding is too slow for one clock, so `pocket/core_constraints.sdc` gives two clocks to paths from the CPU to itself and to the blocks that take CPU data only on an enable edge (the I/O decode, the VDP, the PSG and the wrapper's bus strobes). The memory controller acts between enable edges, so instead of a relaxed constraint it gets a register stage: it sees the CPU's bus one clock late (§4). Two calculations that were one long chain of logic now take several clocks, with the result ready long before the CPU can read it: the SC-3000 keyboard's ghosting (16 clocks) and the math unit's divide (16 clocks; the CPU's next IN comes at least 82 clocks later).

## 12. Resources and timing

Quartus Prime Lite 18.1 build of the whole core (machine, Pocket platform layer and Analogue's framework) for the Pocket's FPGA, a Cyclone V 5CEBA4F23C8:

| | Used | Of |
|---|---|---|
| Logic (ALMs) | 4,940 (27 %) | 18,480 |
| Registers | 6,172 | |
| Block RAM (M10K) | 200 (65 %) | 308 |
| DSP blocks | 2 | 66 |

Timing is met at all four of Quartus's corners (slow and fast silicon, 0 °C and 85 °C). The 53.7 MHz machine clock has at least 4.7 ns to spare in its 18.6 ns period, and every hold check passes. Getting there needed the changes listed under "Meeting timing" in §11; the first build missed by 68 ns.

`syn/` holds an earlier Yosys estimate of the machine alone (about 5,600 ALMs and 229 M10K blocks), useful only as a quick check where Quartus is not installed. An earlier version of the VDP read its line buffers combinationally, which turned them into 15,000 flip-flops; restructuring them as block RAM brought the flip-flop count down eightfold.

## 13. Verification

Everything below is simulation (Verilator 5.020, iverilog) except the last row, the Quartus build. Gearsystem is used only as an independent test oracle and is not part of any deliverable.

| Test | Result |
|---|---|
| Z80 wrapper (`sim/z80/run.sh`): the start cycle of 40 instructions (IX/IY, DDCB, block I/O, IN/OUT, CALL/RET) against the emulator's Z80 | match; unchanged by the tv80 fix |
| Machine, Batman Returns (Europe) SMS, PAL, frames 30–1500 | identical to Gearsystem |
| Machine, Batman Returns (World) GG, frames 200–1500 | identical to Gearsystem (Gearsystem's GG colour table rounds 5 → 86; compared within 2 levels) |
| VDP test ROMs, 192 / 224 / 240 lines, scrolling both axes, sprites at the bottom, `$D0`, Y wrap | RTL = emulator = Gearsystem (Gearsystem has no 240-line mode) |
| Sprite-limit test ROM: stock / 16 / 16 + stock flag | RTL = emulator, overflow flag as specified |
| Super Sega feature ROM: register banks, native and extended CRAM with palette aliasing, Feature Enable B 224 lines, 16 sprites, 200 % turbo with VRAM writes during the display | RTL = emulator; the write loop runs 34.7 times a frame (1719 cycles per 64 writes), as the synchroniser's slot spacing predicts |
| Turbo: instructions per frame at 125–200 % | 1.250 / 1.500 / 1.749 / 1.999 ×, picture unchanged |
| ROM latency at 200 % turbo | no wait states up to 11 clocks (12 before the memory controller's register stage, §11); the PSRAM path takes about 9 |
| PSG: tone `$0FE` | 440.4 Hz (expected 440.4); pseudo-stereo puts it left only in Master System mode and leaves it centred in Super Sega mode |
| **Pocket platform** (bridge model → loader → PSRAM model → machine → video at the pixel clock) | Batman SMS frames 200/500 and GG 200/500 identical to Gearsystem; scaler slot words correct on every line |
| Cartridge load at the APF's maximum bridge rate | passes |
| Save slot: load a file, game writes cartridge RAM, read back | byte-exact |
| I/O test ROM (`roms/ports.sms`): 18 ports read in Master System, Game Gear and Super Sega modes, idle and with button 1 held | RTL = emulator, except `$F2` (no FM unit in the core) and `$FC`/`$FD` bit 7 in Super Sega mode (no debug host) |
| Auto-fire with C held (`-afire -holdc`) | button 2 toggles every two frames in Master System mode; no effect in Super Sega mode |
| Pocket buttons B, A and Y held, Master System and Super Sega modes (`tb_pocket -hold`) | B reads as button 1 and A as button 2 in both modes; Y is C (stock) or A (Super Sega) |
| Verilator lint of `core_top` with the APF's `core_bridge_cmd` (project tree from `pocket/setup.sh`) | elaborates; only style warnings, the substantive ones in the template's own code |
| Identifiers used before their declaration (Quartus rejects these under `default_nettype none`) | none after fixes in `ss_top`, `ss_save_unload` and `core_top` |
| I/O unit (`sim/io/run.sh`): SC-3000 keyboard ghosting (4,000 random key patterns) and the math unit (20,000 operand pairs) through the real port writes and reads, against reference models | match; the test catches a closure that skips ghosting and a divide one step short |
| Quartus build (`pocket/build_core.sh`) | compiles; timing met at every corner (§12) |

Not yet done: anything on hardware.

## 14. Building

`pocket/build_core.sh` builds everything in one step (about 15 minutes). It runs `pocket/setup.sh`, which fetches the APF framework files from `github.com/open-fpga/core-template` (they are under Analogue's licence and not kept in the repository) and lays out a Quartus project with the core's sources in `pocket/build/`; compiles it with Quartus Prime Lite 18.1 (`quartus_sh` if it is installed, otherwise the `raetro/quartus:pocket` Docker image); turns the bitstream into the reversed form the Pocket loads (`tools/reverse_rbf.py`); and puts the files for the root of the SD card, with the test ROMs and `TESTING.md`, in `pocket/build/sdcard/` and `pocket/build/SuperSega-pocket.zip`. GitHub runs the same script on every push that changes `pocket-core/` (the "Pocket core build" workflow, `../.github/workflows/pocket-build.yml`) and offers the SD-card files as a download. Games go in `/Assets/supersega/common/`.

## 15. Next milestones

1. **Hardware bring-up**: first boot on a Pocket (the user's hands-on testing, guided by `TESTING.md`). The Quartus build and timing are done (§12).
2. **TMS9918 modes** (SG-1000, SC-3000), with the true-colour and sprite-limit boosts. Whether these modes raise line interrupts on Super Sega is open (Q15).
3. **FM**: a YM2413 core. Candidates are jtopll (GPL-3) and IKAOPLL; the choice depends on the licence decision below.
4. Super Sega render features: ESAT, 16×16 and magnified sprites, window and text layers, line tables, unique-cell.
5. DMA engine, PCM and wavetable (once their register layouts are written down, Q16), and the math unit divide (once Q7 is decided).
6. SF-7000 and floppy images, debug unit, mouse and trackball, link cable.
7. Cartridge wait state at 200 % (Q12), PAL clock, a proper audio decimation filter.

## 16. Decisions needed

| Decision | Why it matters |
|---|---|
| Licence for the Super Sega RTL | Decides which FM core can be used (a GPL-3 core makes the combined core GPL-3) |
| FM core | jtopll vs IKAOPLL (or writing one) |
| Core and author name | `SuperSega.SuperSega` and the `supersega` platform are placeholders |
| Math unit divide (Q7), mirror range (Q1), TMS-colour default (Q11), TMS-mode line interrupts (Q15), register layouts written only in the emulator (Q16), Feature Enable B height in the TMS modes (Q17) | Machine questions that block parts of later milestones |
