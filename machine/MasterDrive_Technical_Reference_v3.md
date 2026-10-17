# MasterDrive — Technical Reference, v3

October 2026. Consolidated specification of the MasterDrive 8-bit machine. Supersedes v2. The machine-readable form is `masterdrive_machine_v7.json`; where the two disagree, that is a bug in one of them.

## How to read this document

MasterDrive is an 8-bit console in the Sega SG-1000 / Master System / Game Gear family. It runs the software of all three unmodified, and adds new hardware features that new software can opt into.

Two ideas run through everything below:

- **Stock behaviour.** At power-on the machine runs its own BIOS, a menu that starts the game (§20). The game then finds every extension off, and the machine behaves exactly like the original hardware — a Master System with the FM sound unit fitted, or a Game Gear, SG-1000 or SC-3000, depending on the mode the BIOS starts it in.
- **Opt-in extensions.** New software turns extensions on through three *Feature Enable* registers (A, B and C, described in §10). Old software never touches them, so it can never see them. MasterDrive's own I/O registers are opened the same way, by Feature Enable A bit 7 (§11).

A third, separate idea is the **enhancement layer** (AEL, §15): optional boosts for *old* software, such as removing sprite flicker. They are user settings, all off by default except True TMS colours and Start = Pause (§15).

**Notation.** VDP registers come in four banks of 16 (§10). "R7" alone means bank 0 register 7, a stock register; "bank1 R3" means register 3 of bank 1, one of the MasterDrive additions. The banks above 0 can only be reached once software sets **XRB** (extended register banks, Feature Enable A bit 5). **TH** and **TR** are two pins of each controller port (§6): TR is button 2, TH the light-gun and multiplexing line.

The machine exists in three forms that must behave the same: the physical console design, the machine model inside the HTML5 emulator, and the Analogue Pocket core. The emulator also has tools that are not part of the machine (the ROM hack maker, MSX porting tools, and others); those are listed in `MasterDrive_v7_Reconciliation.md` and are not described here.

**What changed in v3.** Two errors in v2 (also present in machine profile v6) were found while testing the Analogue Pocket core against two independent emulators, Gearsystem and MAME: the bits that select the 224- and 240-line modes were swapped, and the Codemasters and Korean mapper registers were said to respond anywhere in their slot. Both are corrected below and marked **v2 error**. v3 also writes down stock-hardware behaviour the emulator had wrong (§16), adds the enhancement layer (§15), limits the debug unit's port reads to MasterDrive mode so that stock software reads its pads as on the original hardware (§13), and replaces v2's "open risks" with the profile's open questions (§17). v2's open risk about sprites not rendering was a fault in the emulator's self-test, not in the machine, and is removed.

---

## 1. Processor and Clocks

| | |
|---|---|
| CPU | Z80, CMOS static (Z84C00 class) |
| Base clock | 3.579545 MHz (NTSC); 3.546893 MHz in PAL, as on a PAL Master System, which gives 49.70 Hz frames of 313 lines |
| State at hand-over to software (the BIOS's launch, §20) | PC `$0000`, SP `$DFF0` (where the Master System BIOS leaves it), interrupts disabled, interrupt mode 0, I and R 0 (as a Z80 reset sets them), AF `$FFFF` (as real Z80s come out of reset, though Zilog does not document it), AF' `$FFFF` (a Z80 reset leaves it; the BIOS sets it); BC, DE, HL, IX, IY, BC', DE' and HL' zero (a Z80 reset leaves them; the BIOS clears them). The emulator and the Pocket core also set SP and AF' in their CPU reset; how the console reaches SP `$DFF0` is open (Q32) |
| Interrupt mode | IM 1 (`RST 38h`), selected by software; NMI is the Pause button |
| Turbo steps | 100 / 125 / 150 / 175 / 200 % |
| Turbo control | port `$F3`, bits 2–0, step 0–4 |
| Turbo enable | Feature Enable A bit 6 — off at reset; a write to `$F3` takes effect only while it is set, and the step then stays until `$F3` is written again |
| Turbo generation | FPGA PLL, true 4.47 / 5.37 / 6.26 / 7.16 MHz at the NTSC clock; in PAL the same percentages of the PAL clock, 4.434 / 5.320 / 6.207 / 7.094 MHz (Q22, decided October 2026) |

Turbo gives the CPU more cycles per frame; the video chip (VDP), PSG and FM chip stay at normal speed, so the picture, raster timing and frame rate do not change. A game's frame rate stays governed by its own wait for the vertical blank. Software that does not wait for vertical blank must stay at 100 %.

Turbo sits on `$F3`, outside the `$00`–`$3F` range that old software uses for its I/O control ports, so no unmodified title can reach it.

### Bus synchroniser

With turbo on, the CPU runs faster than the VDP can accept data. The FPGA therefore holds the CPU (with the Z80's WAIT line) until the VDP reaches its next access slot. The official Sega manual gives the slot spacing:

| Period | VDP access slot every |
|---|---|
| Vertical blank | 16 base cycles |
| Active display | 29 base cycles |

An `OUTI` loop takes 16 cycles, so streaming to video memory during vertical blank is free at any turbo step. During active display each access waits for its slot: at 200 %, an access every 58 CPU cycles, so a stream of bare `OUTI` instructions waits 42 cycles per byte. This is the hardware reason Sega's manual forbids two `OUT`s to the VDP back to back without a gap, and why software streams video data during blanking.

Cartridge ROM adds its own wait: a 250 ns ROM is fast enough up to 175 %, and at 200 %, in PAL as in NTSC, every read from the cartridge or card slot (`$0000`–`$BFFF`) takes one wait state, a halted CPU's repeated M1 reads included (Q12, decided October 2026: kept). Code that runs from cartridge ROM therefore gains little at 200 % over 175 %; code in work RAM runs at the full 200 %. The SF-7000's RAM and IPL are not a cartridge and take no wait, nor does the BIOS ROM (§20). Whether cartridge writes take it too is open question Q25.

The FM chip also needs time between register writes (§7): 12 base cycles after an address write, 84 after a data write. Software written for 100 % leaves that time itself, but at turbo it would write too soon, so the synchroniser also holds the CPU on a write to `$F0`/`$F1` until that time has passed (open question Q21, decided October 2026).

---

## 2. Memory

| Resource | Size | Control |
|---|---|---|
| Work RAM | 128 KB, 16 banks of 8 KB | port `$0A` (once Feature Enable A bit 7 is set, §11) |
| Work RAM window | `$C000`–`$DFFF`, mirrored at `$E000`–`$FFFF` | |
| Video RAM (VRAM) | 16 KB, expandable to 32 KB | Feature Enable B bit 4 enables; bank1 R3 bit 0 selects the bank the CPU reaches |
| Colour RAM (CRAM) | 32 entries, expandable to 256 | bank1 R2 bit 1 |
| Cartridge save RAM | 32 KB, 2 banks of 16 KB, at `$8000`–`$BFFF` | Sega mapper `$FFFC`: bit 3 maps it, bit 2 selects the bank (§8) |
| BIOS ROM | 8 KB, repeated through `$0000`–`$BFFF` | `$3E` bit 3 (below, §20) |

Bank 0 at reset is the stock 8 KB that Master System software expects. The first 64 KB can be used as one contiguous block, which the SF-7000 disk system needs.

`$0A` reads back the selected bank in bits 3–0 (bits 7–4 read 0), so an interrupt handler that switches banks can save and restore it (Q9, decided October 2026).

### Port `$3E` — memory enables

Active low: writing 1 to a bit disables that region, which then reads as open bus ($FF).

| Bit | Region |
|---|---|
| 2 | I/O chip (controller ports) — see §11 for exactly what it covers |
| 3 | base 8 KB BIOS ROM: the machine's own BIOS (§20) |
| 4 | internal 8 KB RAM |
| 5 | card ROM |
| 6 | cartridge ROM |
| 7 | expansion port |

Reset values: `$E0` at a cold reset — the BIOS ROM, RAM and controllers enabled; cartridge, card and expansion disabled — so the machine starts in its BIOS (§20); `$A8` when the BIOS launches a game, the state of a machine whose BIOS has handed over to a cartridge — cartridge, RAM and controllers enabled; BIOS, card and expansion disabled. The BIOS ROM answers only while the cartridge is disabled: with bits 3 and 6 both clear the cartridge answers.

---

## 3. Video

The VDP (video display processor) is the Game Gear's single-chip ASIC, the 315-5535, with the FPGA adding everything it has no register for (§12).

### Power-on register values

From the official manual:

| R0 | R1 | R2 | R3 | R4 | R5 | R6 | R7 | R8 | R9 | R10 |
|---|---|---|---|---|---|---|---|---|---|---|
| `$36` | `$A0` | `$FF` | `$FF` | `$FF` | `$FF` | `$FB` | `$00` | `$00` | `$00` | `$FF` |

R1 `$A0` has the display-enable bit clear, so the display is off at power-on. R2 `$FF` puts the screen map at `$3800`, R5 `$FF` the sprite table at `$3F00`, R6 `$FB` the sprite patterns in the first 8 KB.

### Mode families

Two families of display modes. The legacy TMS9918 modes (Graphics I, Graphics II, Multicolor, Text) come from the SG-1000, SC-3000 and MSX1. Mode 4 is the Master System's tile mode, and carries all the MasterDrive extensions.

### Display height

Mode 4 shows 192, 224 or 240 lines. The four mode bits are spread over two registers: **M1** is R1 bit 4, **M2** is R0 bit 1, **M3** is R1 bit 3, **M4** is R0 bit 2.

| Selection | Result |
|---|---|
| M4 = 1, M2 = 1, M1 = 1, M3 = 0 | 224 lines |
| M4 = 1, M2 = 1, M3 = 1, M1 = 0 | 240 lines |
| M4 = 1 with M2 = 0, or any other combination | 192 lines |
| Feature Enable B bits 7–6 (MasterDrive software) | 192 / 224 / 240, in Mode 4 and in the TMS9918 modes (see *TMS9918 modes* below) |

M2 is the switch that allows the taller modes; M1 and M3 then pick the height.

**v2 error:** v2 gave 224 lines for M4 M3 M1 with M2 clear, and 240 for M4 M3 M2 with M1 clear — M2 and M3 swapped. Under that rule a typical game writing R0 = `$36` and setting R1 bit 4 stayed at 192 lines, and R0 = `$04` with R1 bits 4 and 3 set gave 224 lines where hardware shows 192. Source: MAME `sega315_5246`, Gearsystem.

Both selection paths must work: the standard bits are how Master System and Game Gear software reach the tall modes; MasterDrive software may use Feature Enable B instead. In the tall modes the screen map is 32 × 32 tiles at `(R2 bits 3–2) × $1000 + $700` instead of 32 × 28 at `(R2 bits 3–1) × $800`, the map wraps every 256 lines instead of 224, and `$D0` no longer ends the sprite list.

### Documented VDP behaviours

| Behaviour | Detail |
|---|---|
| V counter | readable at `$7E`; zero on the first displayed line; jumps once per frame (table in §16) |
| H counter | readable at `$7F`; latched when a TH pin rises (light gun) |
| Sprite collision | status bit 5, cleared when the control port is read |
| Sprite overflow | status bit 6, set by a ninth sprite on a line **by Y alone** — off-screen and transparent sprites count |
| Frame interrupt flag | status bit 7, set early in line *height* + 1 (the second line after the last displayed one, §16); stays set until the status register is read |
| CRAM addressing | high address bits ignored, so the address always lands in CRAM |
| Line interrupt counter | on lines 0 to *height* (one line past the display) it counts down, and on reaching 0 it reloads from R10 and raises the line interrupt; on the other lines it is reloaded from R10. Mode 4 only as stock (the TMS modes raise none); in MasterDrive mode the TMS modes raise it too, enabled by R0 bit 4 as in Mode 4 (Q15) |
| Name-table spare bits | the top three bits of each entry are unused by the VDP; some games keep collision flags there |
| 8×16 sprites | the low bit of the tile index is ignored |
| Registers 11 and above | ignored by real hardware, which is why the MasterDrive extensions live there |

### TMS9918 modes

The SG-1000 and SC-3000 picture modes draw from tables in VRAM whose base addresses come from registers 2 to 6, as on the SG-1000: the *name table* (which character goes in each screen cell) at R2 × `$400`, the *colour table* at R3 × `$40`, the *pattern table* (the characters' pixels) at R4 × `$800`, the sprite attributes at R5 × `$80` and the sprite patterns at R6 × `$800`.

The mode bits defined above select the mode: Graphics I with none of M1–M3 set, Text with M1, Graphics II with M2, Multicolor with M3 (M4 selects Mode 4). Which mode several of them together give is open (Q19).

| Mode | Picture |
|---|---|
| Graphics I | 32 × 24 characters of 8 × 8 pixels; one colour byte (foreground and background) for each group of 8 characters |
| Graphics II | 32 × 24 characters; each third of the screen has its own 256 patterns, and every pattern row its own colour byte. R4 bit 2 and R3 bit 7 pick the half of VRAM for the pattern and colour tables; R4 bits 1–0 and R3 bits 6–0 mask the pattern and colour index, so the thirds can share tables |
| Multicolor | 64 × 48 blocks of 4 × 4 pixels, each one colour |
| Text | 40 columns of 6 × 8 characters between 8-pixel borders, in the two colours of R7; no sprites |

- **Colour 0 is transparent** in every mode, Text and Multicolor included: the backdrop colour (R7 bits 3–0) shows through.
- **Sprites:** 32, each 4 bytes (Y, X, pattern, and an attribute byte: bit 7 *early clock*, which moves the sprite 32 pixels left; bits 3–0 its one colour), 8 × 8 or 16 × 16 (R1 bit 1), magnified to double size by R1 bit 0. Y = `$D0` ends the list. A sprite starts on line *Y* + 1, or *Y* + 1 − 256 when *Y* + 1 is 225 or more. Four per line as stock. When sprites overlap, the lowest-numbered is drawn on top. A transparent (colour 0) sprite counts towards the limit but draws nothing. Neither implementation lets it take part in collisions, as in Gearsystem; whether it should is open (Q18).
- **Flags:** status bit 6 is set by a fifth sprite on a displayed line, and status bit 5 when pixels of two drawn sprites meet on the screen. Both are set when the line is drawn, not at the Mode 4 event times (§16). What status bits 4–0 read is open (Q18).
- **Colours:** the TMS9918's own colours, or the Master System's 2-bit approximation of them (the enhancement layer's *True TMS colours* boost, on at power-on, §15). MasterDrive software can make them CRAM entries 0–15 instead (Feature Enable C bit 0).
- **Line interrupts:** as stock the TMS modes raise none. In MasterDrive mode the line counter runs in them as in Mode 4, and R0 bit 4 enables the interrupt (Q15).

**At 224 and 240 lines.** MasterDrive software can give the TMS modes the taller heights with Feature Enable B bits 7–6 (§10), as it can Mode 4 (Q17). In the other machine modes they stay at 192 lines, since the M1/M3 height selection needs M4. The tables carry on below line 192:

| | At 224 and 240 lines |
|---|---|
| Name table | continues past row 23: 28 or 30 rows of 32 names in Graphics I, Graphics II and Multicolor; of 40 in Text, which then runs past the 1 KB that R2 places (1,120 or 1,200 bytes) |
| Graphics II | rows 24–29 take their patterns and colours from a fourth bank, as each third takes them from its own: with R4 bits 1–0 and R3 bits 6–5 all set, at the pattern and colour bases + `$1800`; clearing them shares a bank, as for the thirds |
| Graphics I, Multicolor | Graphics I keeps one colour byte per 8 characters; Multicolor rows carry on cycling through each character's 8 bytes |
| Sprites | Y = `$D0` no longer ends the list, and a sprite wraps to the top only when *Y* + 1 is 241 or more, as in Mode 4 (§5); the limit and the flags work on every displayed line |
| Timing | as Mode 4 at the same height: the frame interrupt flag on line *height* + 1, the line counter on lines 0 to *height* (§16) |
| VRAM | the tables stay in the first 16 KB, as on the SG-1000 |

Sources: TMS9918A Data Manual (Texas Instruments); Gearsystem (`RenderBackgroundTMS9918`, `RenderSpritesTMS9918`), which gives the same pictures as the emulator on the Pocket core's four TMS test ROMs.

### Line tables and the window layer

These are MasterDrive additions to Mode 4, for MasterDrive software. Their registers are in §10; *base* registers give a VRAM address in their bits 5–0, shifted left by 8 (so a base is a multiple of `$100`).

- **Line scroll table** (Feature Enable A bit 1). One byte per line, at bank 0 R11's base: on line *y* the background's horizontal scroll is the byte at base + *y*, in place of R8, the horizontal scroll register (§16). The top two rows that R0 bit 6 exempts stay unscrolled.
- **Line vertical-offset table** (Feature Enable B bit 0). One byte per line, at bank 1 R1's base: on line *y* the byte at base + *y* is added to the vertical scroll (R9), modulo 256. Screen x 192 and right, which R0 bit 7 exempts (§16), stay unscrolled.
- **Window layer** (Feature Enable A bit 2). A second, fixed tile layer over part of the background. It covers screen *x* from 8 × bank 0 R13 (bits 4–0) to the right edge, on the lines bank 0 R14 selects: bits 4–0 give the split row (8 lines each), and bit 7 set puts the window above the split, clear from the split down. Its tilemap, at bank 1 R0's base, holds 32 × 32 entries of 2 bytes in the Mode 4 name-table format. The window does not scroll: the cell at screen row *r*, column *c* shows entry (*r*, *c*). In its area it replaces the background, priority bits included, and sprites are drawn over it as over the background.
- **Text window** (Feature Enable C bit 2). The window area shows 40 columns of 6-pixel characters instead of tiles: the area is filled with the background colour of bank 1 R9 (bits 7–4; bits 3–0 are the characters' colour, both from palette 0), then the characters are drawn from its left edge. Their patterns are at bank 1 R8's base, 8 bytes each, one byte a row: bits 7–2 are the row's six pixels, bit 7 leftmost, and bits 1–0 are not drawn. Their name table is at bank 1 R0's base, 40 bytes a row, with row 0 at the window's top edge.

The tile window counts its rows from the top of the screen and the text window from its own top edge, the window can lie only right of the X split, and it reads bank 1 R0 even while XRB is clear (§10); all three are open (Q29).

---

## 4. Colour

Colours are 12-bit (4 bits each of red, green, blue), the Game Gear format, stored as `0000BBBB GGGGRRRR`. There are two ways to write them:

| Write path | Bytes per colour | How |
|---|---|---|
| Legacy (Master System) | 1 | a 6-bit `BBGGRR` byte; each 2-bit channel is promoted to 4 bits (×5) |
| Native (Game Gear, and MasterDrive with Feature Enable A bit 0) | 2 | byte-addressed: a write to an even CRAM address is held in a latch; the write to the next odd address stores both bytes as one entry (entry = address ÷ 2) |

The Game Gear uses the native scheme over 64 bytes (32 entries). With extended CRAM on (256 entries) the native scheme covers 512 bytes.

Sixteen *palette-written* flags let an unwritten palette fall back to palette (index AND 1), so legacy software sees the two palettes it expects. A cold reset and the BIOS's launch clear the flags. CRAM itself need not be cleared by a cold reset (the Pocket core's does not clear it, the emulator's does), and the launch keeps it: the BIOS clears entries 0–31 before it starts a game (§20, Q38).

---

## 5. Sprites

64 sprites; 8 per line as stock, 16 per line with Feature Enable A bit 4. Sizes 8×8, 8×16 and 16×16, each optionally magnified to double size. When sprites overlap, the lowest-numbered sprite is drawn on top.

A sprite whose Y coordinate is *Y* starts on line *Y* + 1. When *Y* + 1 is between 241 and 256 it starts at line *Y* + 1 − 256 instead — above the top of the screen — so a sprite at Y = `$F8` shows its lower rows on the first lines.

The *Extended Sprite Attribute Table* (ESAT) adds per-sprite flip, priority, size, magnification, early clock (32 pixels left) and palette. Feature Enable A bit 3 turns it on (§10), and it holds 2 bytes for each of the 64 sprites, sprite *n* at the ESAT base (bank 0 R12 bits 5–0, shifted left by 8) + 2*n*:

| Byte | Bits |
|---|---|
| 0 | bit 0 vertical flip · bit 1 horizontal flip · bit 2 priority · bit 3 16 × 16 · bit 4 magnify to double size · bit 5 early clock (32 pixels left) · bits 7–6 reserved |
| 1 | bits 3–0 the sprite's palette in extended CRAM (with Feature Enable B bit 1; otherwise the sprite palette) · bits 7–4 reserved |

The ESAT has been 2 bytes per sprite since v5 (Q4). Feature Enable C bit 4, which once selected that layout, is retired, and no bit selects a 1-byte layout (Q13).

Per-sprite collision (Feature Enable B bit 3) is meant to write hit bitmaps at a base set in bank 1 R6, and bank 1 R5 is named the sprite palette base, but neither implementation does anything with them, so what they hold is open (Q28).

---

## 6. Input

### Controller ports

| Port | Bits |
|---|---|
| `$DC` | port A up, down, left, right, TL (button 1), TR (button 2); port B up, down |
| `$DD` | port B left, right, TL, TR; Reset button; CONT; port A TH; port B TH |

Reset reads 1 when the button is absent. CONT reads 1 on 8-bit hardware and 0 on a Mega Drive. MasterDrive uses Mega Drive 3-button pads, multiplexed by the TH line: TH high gives Up Down Left Right B C, TH low gives Up Down 0 0 A Start.

**The pad in the stock modes.** In the Master System, Game Gear, SG-1000 and SC-3000 modes the console presents the pad as that machine's own controller: A is button 1 (TL), B is button 2 (TR), and Start is the Game Gear's Start, or the Pause button on the Master System, SG-1000 and SC-3000 (the Start = Pause setting, on at power-on, §15). C is used only by the auto-fire boost. A Mega Drive pad plugged into a Master System would give B and C as buttons 1 and 2; the console uses A and B so that the pad's first two buttons are the old consoles' two (decided by the owner, October 2026). MasterDrive software reads the pad as a Mega Drive pad.

### Port `$3F` — I/O control

| Bits | Function |
|---|---|
| 7–4 | output levels: 7 port B TH, 6 port B TR, 5 port A TH, 4 port A TR |
| 3–0 | direction, 1 = input, 0 = output: 3 port B TH, 2 port B TR, 1 port A TH, 0 port A TR |

Reset value `$FF`: all inputs, with the level bits 7–4 set. A pin set as an output reads back the level written: TR on `$DC` bit 5 (port A) and `$DD` bit 3 (port B); TH on `$DD` bits 6 and 7 — on an export machine. A Japanese machine always reads 0 on TH; this difference is how software detects the region.

### Game Gear differences

Start is on port `$00` (bit 7, 0 = pressed; bit 6 is the region, 1 = export; bits 5–0 read 0). It is decoded in Game Gear **and MasterDrive** modes. Above `$C0` the Game Gear answers only `$C0`/`$DC` and `$C1`/`$DD`; on `$DD`, bits 7–6 read back `$3F` bits 7–6.

### SK-1100 keyboard

The SC-3000's 64-key keyboard, read through an 8255 PPI (programmable peripheral interface). Always live in SG-1000 (with the keyboard attached), SC-3000 and SF-7000 modes; on MasterDrive it is enabled by Feature Enable C bit 5.

| Port | Function |
|---|---|
| `$DC` | PPI port A, input: 8 bits of matrix data |
| `$DD` | PPI port B, input: matrix data in bits 3–0; bits 7, 6, 5 read 0, 1, 1 with nothing attached |
| `$DE` | PPI port C, output: row select in bits 2–0 (through a 74LS145); bit 3 cassette out; bits 5–7 printer |
| `$DF` | PPI control; not readable (returns `$FF`) |

Eight rows: 0–6 the keyboard, 7 the two gamepads. Inputs are active low with pull-ups, so a pressed key reads 0 (evidence, not proof: §17). Reading port C returns its output latch: the last value written, or 0 after a mode word.

The 8255 behaves as the Intel part does:

- **At reset** every port is an input. Port C's pull-ups then select row 7, the pads — which is why SG-1000 games that never touch the PPI still read their controllers with a keyboard attached.
- **A mode word** (a write to `$DF` with bit 7 set) clears the output latches, so port C selects row 0 until software writes it. Software conventionally writes `$92` to `$DF`, then `$07` to `$DE`.
- **Bit set/reset**: a write to `$DF` with bit 7 clear sets or clears one bit of port C.

**Matrix ghosting** is real behaviour and is modelled: the matrix has no diodes, so held keys connect rows and columns, and every key reachable through held keys reads as pressed. Some software cannot cope, so ghosting can be switched off.

One key (RESET) raises an NMI instead of appearing in the matrix.

### Pointing devices

| Device | Interface |
|---|---|
| Mega Drive mouse | TH-clocked serial, 3 buttons, relative movement. Four ID nibbles (`0,B,F,F`), then sign/overflow, buttons and two bytes of movement. Answers on port B |
| Sports Pad trackball | TH-clocked, strobe on `$3F` bit 5 (player 1) or bit 7 (player 2). Two 8-bit **absolute** counters that wrap. Clocked out X7–X4 strobe low, X3–X0 strobe high, Y7–Y4 low, Y3–Y0 high, on port A bits 3–0, with buttons on bits 4 and 5 |

### Multiplayer

A multitap on the pad port (Sega Team Player MK-1654 or EA 4 Way Play protocol), detected through `$16` (§11); and, for Game Gear multiplayer, a machine-to-machine serial link cable on the Game Gear EXT registers `$01`–`$05`.

---

## 7. Audio

| Source | Ports | Notes |
|---|---|---|
| SN76489 PSG (3 tones + noise) | `$7E`/`$7F` write | stereo panning on `$06` (Game Gear mode, and MasterDrive mode once Feature Enable A bit 7 is set, §11) |
| YM2413 FM | `$F0` register, `$F1` data, `$F2` control | the FM unit is always fitted |
| PCM FIFO (64 bytes) | `$07` data, `$08` control (write) and fill (read) | MasterDrive |
| Two wavetable voices | `$11`–`$15` | MasterDrive |

**PCM.** Each byte written to `$07` is one unsigned 8-bit sample (128 is silence), queued in a 64-byte FIFO. A write to `$08` sets the sample rate in bits 1–0: 0 = 8,000, 1 = 11,025, 2 = 16,000, 3 = 22,050 samples a second (bits 7–2 reserved). The output is mono, on both sides; while the FIFO is empty it holds the last sample, and reset returns it to silence. Reading `$08` gives the FIFO's fill: bits 6–4 are the bytes queued divided by 8, saturating at 7 (56–64 bytes read 7); the other bits read 0. A byte written to `$07` while 64 are queued is dropped (Q14, decided October 2026).

**Wavetable.** Two voices, each playing a waveform of 32 four-bit samples (8 is the centre). The ports are write-only (they read `$FF`):

| Port | Bits |
|---|---|
| `$11` | bit 5 the voice (0 or 1) that `$11`–`$15` address · bits 4–0 the waveform position `$12` writes |
| `$12` | bits 3–0 the sample at that position (the position does not advance) |
| `$13` | frequency, low 8 bits |
| `$14` | bits 3–0 frequency, high 4 bits · bit 7 key on (1 plays, 0 silences) |
| `$15` | bits 3–0 volume, 0 silent to 15 full, linear · bits 5–4 the sides it is heard on (bit 5 left, bit 4 right; both at reset) |

A voice with frequency 0 is silent. How the frequency maps to a pitch and how the PCM rates are made from the machine clock, and how loud both are beside the PSG and FM chip, are open (Q27). The bits not listed are reserved.

**PSG details.** Tone counters run at the CPU clock ÷ 16 and flip their output on reaching zero; a period of 0 behaves as 1. The noise counter (rate `$10`, `$20`, `$40`, or tone 2's period) flips a flip-flop, and the 16-bit noise shift register advances on its rising edge — once per two counter periods. White noise taps bits 0 and 3; writing the noise register resets the shift register to `$8000`. Volume is attenuation in 2 dB steps; 15 is silent.

**`$F2` (FM control).** Writes select which sound chips are heard, in bits 1–0: 0 the PSG only (the power-on state), 1 the FM chip only, 2 neither, 3 both (MAME, `sms_m.cpp`; Gearsystem does the same for Japanese consoles). Software that never writes `$F2` therefore keeps its PSG sound. Reads return bits 1–0 of the last value written (bits 7–5 carry a sync counter on a Japanese Master System; MasterDrive returns 0 there). Japanese software disables the I/O chip (`$3E` bit 2) before reading `$F2`, so `$F2` must answer even then — that is how FM detection works.

**FM write timing.** After writing a register address to `$F0` the chip needs 12 master-clock cycles (base cycles) before the data, and after writing data to `$F1` 84 before the next write (YM2413 Application Manual). Software leaves that time itself at 100 %; at turbo the bus synchroniser holds the CPU until it has passed (§1).

**FM and PSG balance.** How loud the FM chip is beside the PSG on the original is not known (open question Q20). Both implementations make one FM channel at full volume peak at half a PSG channel at full volume.

---

## 8. Media

### Machine modes

| Mode | Memory map |
|---|---|
| SG-1000 | linear ROM, no mapper, 1 KB work RAM mirrored from `$C000` |
| SC-3000 | **the cartridge sets the map:** ROM `$0000`–`$7FFF`; cartridge RAM `$8000`–`$BFFF` (16 KB), or `$8000`–`$FFFF` (32 KB) with work RAM disabled; work RAM 2 KB, mirrored |
| Master System | Sega mapper, standard map |
| Game Gear | as Master System, with Game Gear port decoding |
| SF-7000 | see below |
| MasterDrive | Master System map plus the extensions; the machine's BIOS runs in it (§20), and its menu can also start an export cartridge in this mode (§14) |

### Cartridge mappers

| Family | Registers |
|---|---|
| Sega | `$FFFC` RAM/misc (bit 3 maps cartridge RAM over `$8000`–`$BFFF`, bit 2 selects its bank), `$FFFD`–`$FFFF` bank for slots 0–2. Reset `$00`, `$00`, `$01`, `$02`. The first 1 KB of slot 0 never banks, keeping the interrupt vectors |
| Codemasters | exactly `$0000`, `$4000`, `$8000`. Power-on banks 0, 1, 0. No vector protection. Bit 7 written to `$4000` maps 8 KB of cartridge RAM at `$A000` |
| Korean | exactly `$A000` selects slot 2; slots 0 and 1 fixed to banks 0 and 1 |
| MSX / Nemesis (Korean MSX ports) | `$0000`–`$0003` select 8 KB banks: 0 → `$8000`, 1 → `$A000`, 2 → `$4000`, 3 → `$6000`. The MSX variant fixes the first 16 KB; the Nemesis variant (last 8 KB bank fixed at `$0000`) is not implemented yet in the emulator or the Pocket core |

Only a Sega-mapper cartridge has hardware at `$FFFC`–`$FFFF`; on the other families those addresses are plain work RAM.

**v2 error:** the Codemasters and Korean registers were said to respond to any address in their slot. Gearsystem and MAME decode the exact address, every known title writes there, and with any-address decoding a write into Codemasters cartridge RAM would also have switched banks.

**Card slot.** MasterDrive mode can read the card slot alongside the cartridge. `$09` bit 0 set maps the card at `$4000`–`$7FFF`, bit 1 at `$8000`–`$BFFF` (cartridge RAM mapped by `$FFFC` bit 3 comes first); each reads the card bank `$0B` selects (bits 4–0: 32 banks of 16 KB, 512 KB). Clear, they read the cartridge through its mapper. `$09` acts only with a Sega-mapper cartridge: with the Codemasters, Korean and Korean MSX mappers, `$4000`–`$BFFF` reads the cartridge whatever `$09` holds. `$0000`–`$3FFF` is always the cartridge, except while the BIOS ROM is mapped (§20). Bits 7–2 of `$09` are kept and read back but do nothing, and `$09` acts only with a card inserted. How it combines with the slot enables in `$3E` (§2) is open (Q30).

The Sega mapper's 8-bit bank registers reach 4 MB, and 4 MB is the largest cartridge ROM the machine takes (Q2, decided October 2026; the slot was once specified for 8 MB, which would have needed a ninth bank bit). Cartridge save RAM is 32 KB, two 16 KB banks as the 315-5235 maps them (Q3, decided October 2026).

### SF-7000 disk system

| | |
|---|---|
| RAM | 64 KB |
| IPL ROM | 8 KB |
| ROM overlay | with `/ROM SEL` low, the IPL appears over `$0000`–`$3FFF` (mirrored from 8 KB) for **reads**; writes still land in RAM |
| PPI | `$E4` port A in (disk and printer status), `$E5` port B (printer), `$E6` port C out, `$E7` control |
| Port C bits | 0 drive /INUSE, 1 drive /MOTOR ON, 2 controller TC, 3 controller RESET, 6 `/ROM SEL`, 7 printer /STROBE |

The IPL drives `/ROM SEL` with 8255 bit set/reset on `$E7`. As on the keyboard PPI, a mode word clears port C, which drives `/ROM SEL` low and maps the IPL back in.

The floppy controller (uPD765 class, `$E0` status, `$E1` data, 40 tracks × 16 sectors × 256 bytes) is implemented in the FPGA and backed by disk images.

### Other media

The console also reads the media of its computer side: SC-3000 cassettes and SF-7000 disks (Q2, decided October 2026). How it reads them — in which modes, through which ports, and whether the boot menu loads an image or software reads the signal — is open question Q23.

### Storage

32 KB save card: 16 directory slots, 112 sparse 256-byte pages, per-game profiles with their own icons. A profile holds the first 8 KB of bank 0 of the game's cartridge RAM; whether it should hold all 32 KB, and what identifies a game on the card, is open question Q24. Cartridge save RAM is snapshotted before a card profile loads, and shutdown flushes the card before restoring the cartridge.

Mods reach real hardware as BPS patches, applied by computer mode while it writes a blank card. The console plays mods; making them is an emulator tool.

---

## 9. DMA Engine and Math Unit

DMA on `$F4`–`$FA`, in MasterDrive mode (these ports are fully decoded, like `$F0`–`$F3`, so Feature Enable A bit 7, the I/O gate that opens the registers at `$01`–`$17` (§11), does not cover them): memory to VRAM or CRAM, VRAM to VRAM, and fill.

| Port | Bits |
|---|---|
| `$F4` | source address, low byte; in fill mode, the fill byte |
| `$F5` | source address, high byte |
| `$F6` | bits 1–0 the source of a memory transfer: 0 the CPU address space (as the CPU reads it, the BIOS ROM included while it is mapped, §20), 1 the card (card bank `$0B`, address bits 13–0), 2 work RAM (the selected 8 KB bank, address bits 12–0) · bits 3–2 the mode: 0 memory to VRAM or CRAM, 1 VRAM to VRAM, 2 fill |
| `$F7` | destination address, low byte |
| `$F8` | bits 5–0 destination address, high bits (a transfer starts in VRAM `$0000`–`$3FFF`) · bit 6 set: the destination is CRAM (address bits 8–0, its 512 bytes) |
| `$F9` | length, low byte |
| `$FA` | bits 5–0 length, high bits · bit 7 written as 1 starts the transfer. A length of 0 (`$F9` and `$FA` bits 5–0 all clear) means 16,384 bytes |

The bits not listed, source 3 and mode 3 are reserved. A transfer moves *length* bytes, source and destination each counting up by one. A VRAM destination counts on past `$3FFF` into the upper 16 KB (address bits 14–0), and VRAM to VRAM reads source address bits 14–0, whether or not VRAM expansion is on. The registers keep what was written (the addresses do not advance) and read back at `$F4`–`$FA`. A transfer to CRAM stores the bytes as CRAM holds them (the Game Gear 12-bit format, two bytes per entry, whatever the CRAM write mode, §4) and marks each palette it writes as written. How long a transfer takes, whether the CPU waits and whether it may write VRAM during the display are open, as is how far the destination should reach (Q26): the emulator completes a transfer at once and charges the CPU one T-state per byte, plus, for a transfer from the CPU address space, the cartridge wait state (§1) on each byte it reads from `$0000`–`$BFFF` at 200 % (not on the BIOS ROM's).

| Math port | Function |
|---|---|
| `$0C` | operand A |
| `$0D` | operand B |
| `$0E` | write: bit 0 = 0 multiply, 1 divide; read: 0 (operation complete) |
| `$0F` | result low: the product's low byte, or the quotient |
| `$10` | result high: the product's high byte, or the remainder |

Multiply is A × B, unsigned 16-bit. Divide is A ÷ B, unsigned: the quotient in `$0F` and the remainder in `$10`. A divide by zero gives `$FF` in `$0F` and `$00` in `$10`, which 255 ÷ 1 also gives, so software that must tell them apart tests B (Q7, decided October 2026). The result is ready for the next instruction. Like the other MasterDrive registers, the math unit answers once Feature Enable A bit 7 is set (§11).

---

## 10. Register Map

The VDP register-write command byte is `10bbnnnn`. On stock hardware bits 5–4 are ignored. MasterDrive uses them to select one of four register banks — but only when bank 0 register 15 bit 5 (**XRB**, extended register banks) is set. XRB is clear at reset and in all legacy software, so bits 5–4 are discarded exactly as on real silicon. While XRB is clear the bank 1–3 registers also have no effect: they keep their values, but the features they switch on (everything in Feature Enable B and C) are off. One exception: the window layer (Feature Enable A bit 2) reads its tilemap base from bank 1 R0 whether or not XRB is set (Q29).

At a cold reset and at the BIOS's launch (§20), bank 0 R11–R15 and every bank 1–3 register are 0, as are `$09`, `$0B`, the math unit (`$0C`–`$10`) and the DMA registers (`$F4`–`$FA`); R0–R10 take the power-on values of §3.

### Bank 0

| Reg | Function |
|---|---|
| 0–10 | stock VDP registers, including the mode bits M1–M4 |
| 11 | line-scroll (horizontal) table base (bits 5–0, §3) |
| 12 | Extended Sprite Attribute Table base (bits 5–0, §5) |
| 13 | window X split: bits 4–0 the first window column (§3) |
| 14 | window Y split: bits 4–0 the split row; bit 7 set, the window is above it (§3) |
| 15 | **Feature Enable A** |

**Feature Enable A** — bit 0 native 12-bit CRAM · bit 1 line-scroll horizontal · bit 2 window layer · bit 3 ESAT · bit 4 16 sprites per line · bit 5 XRB · bit 6 turbo · bit 7 MasterDrive I/O registers `$01`–`$17` (§11)

Registers 11–15 take effect only in MasterDrive mode; in the other modes they are ignored, as on the stock VDP.

### Bank 1

| Reg | Function |
|---|---|
| 0 | window tilemap base (bits 5–0, §3) |
| 1 | line vertical-offset table base (bits 5–0, §3) |
| 2 | **Feature Enable B** |
| 3 | VRAM bank for CPU access |
| 4 | render bank assignment (not defined yet, Q28) |
| 5 | sprite palette base (not defined yet, Q28) |
| 6 | collision result base (not defined yet, Q28) |
| 7 | **Feature Enable C** |
| 8 | text window pattern base |
| 9 | text window colours |

**Feature Enable B** — bit 0 line vertical offset · bit 1 extended CRAM · bit 2 16×16 sprites · bit 3 per-sprite collision · bit 4 VRAM expansion · bits 7–6 display height (00 from the mode bits, 01 224 lines, 10 240 lines, 11 reserved, giving 192 lines; a 224/240 selection by the mode bits takes precedence)

**Feature Enable C** — bit 0 legacy modes draw from CRAM · bit 1 legacy sprite limit raised · bit 2 text window · bit 3 unique-cell mode (1024 tiles, so every screen cell can have its own; needs VRAM expansion) · bit 4 reserved (it selected a 2-byte ESAT; the ESAT is always 2 bytes, Q13) · bit 5 SC-3000 keyboard

Bank 2 unallocated; bank 3 reserved.

---

## 11. I/O Port Map

| Range | Function |
|---|---|
| `$00` | Game Gear Start / region (Game Gear and MasterDrive modes) |
| `$01`–`$05` | Game Gear serial (EXT link) registers (Game Gear mode; MasterDrive mode once Feature Enable A bit 7 is set) |
| `$06` | PSG stereo panning (write-only; Game Gear mode, and MasterDrive mode once Feature Enable A bit 7 is set) |
| `$07`–`$08` | PCM FIFO data / control (write) and fill (read) |
| `$09` | slot source select: bit 0 card at `$4000`–`$7FFF`, bit 1 at `$8000`–`$BFFF` (§8) |
| `$0A` | work RAM bank (reads back in bits 3–0) |
| `$0B` | extended card bank |
| `$0C`–`$10` | math unit |
| `$11`–`$15` | wavetable audio |
| `$16` | multitap detection (reads `$81`: pad found, detection complete) |
| `$17` | machine ID, read-only: `$A7` (§14) |
| `$18`–`$1F` | the BIOS's ports, in MasterDrive mode while the BIOS ROM is mapped (§20): `$18` setting index, `$19` setting, `$1F` launch; the rest read `$FF` and ignore writes; otherwise mirrors |
| `$3E` | memory enables (write) |
| `$3F` | I/O control (write) |
| `$7E`–`$7F` | V / H counters (read); PSG (write) |
| `$BE`–`$BF` | VDP data / control |
| `$C0`–`$FF` | controllers `$DC`/`$DD`, mirrored on every even/odd port except the ranges below; SK-1100 PPI at `$DC`–`$DF` (mirrored through `$C0`–`$DF`) when the keyboard is live |
| `$E0`–`$E7` | SF-7000: floppy controller and second PPI |
| `$F0`–`$F2` | YM2413 FM (Master System and MasterDrive modes; elsewhere these read as the controller mirror, or `$FF` on the Game Gear) |
| `$F3` | turbo step |
| `$F4`–`$FA` | DMA engine |
| `$FB` | debug unit control |
| `$FC`–`$FD` | SDSC debug console |
| `$FE`–`$FF` | watchpoint register select / data |

On the Master System every even port in `$00`–`$3E` acts as `$3E` and every odd one as `$3F` (mirrors). On every stock machine the PSG is written at any port in `$40`–`$7F` and the VDP answers across `$80`–`$BF` (even ports data, odd ports control); on the Master System and Game Gear the V counter reads at every even port and the H counter at every odd port in `$40`–`$7F`. The SG-1000, SC-3000 and SF-7000 have no `$3E`/`$3F` registers: in those modes writes to `$00`–`$3F` do nothing. The Game Gear decodes `$00`–`$06` separately, and MasterDrive extends that to `$17`, but only once software has set Feature Enable A bit 7: this *I/O gate* (Q1) keeps old code run in MasterDrive mode from reaching the new registers. Until the bit is set, in MasterDrive mode `$01`–`$17` act as the `$3E`/`$3F` mirrors and read `$FF`, as on a Master System, and only `$00` (Start and region) answers. While the BIOS ROM is mapped, MasterDrive mode also takes `$18`–`$1F` out of the mirrors for the BIOS's ports (§20). The gate is live: clearing the bit closes the ports again, and what the registers were set to (work RAM bank, slot select, card bank, stereo, the math operands, PCM and wavetable) stays in force. In every other mode these ports do what they do on the stock machine; writes to VDP registers 11–15 (§10) likewise take effect only in MasterDrive mode.

**Reads.** `$00`–`$3F` are write-only on the Master System and read `$FF`; on the Game Gear and MasterDrive every port there that is not a register listed above also reads `$FF`. In MasterDrive mode, `$01`–`$17` (while the I/O gate is open) and `$F0`–`$FF` are fully decoded: unreadable ports return `$FF`, never the controller mirror. In the other modes `$FB`–`$FF` read as on the stock machine — the controller mirror, or `$FF` on the Game Gear — because stock software may read its pads there (§13).

**`$3E` bit 2** (I/O chip disable) turns off only the controller decode across `$C0`–`$FF`, and only on the Master System and MasterDrive. It has no effect on the Game Gear, and does not affect `$F2` or MasterDrive's `$F0`–`$FF`.

The turbo and debug ports sit above `$F0`, outside the `$3E`/`$3F` mirror range, so no old title writing a memory- or I/O-control mirror can reach them; writes to `$F0`–`$FF` do nothing on the stock machines. `$01`–`$17` stay inside that range; the I/O gate is what keeps old code from reaching them (Q1, decided).

---

## 12. FPGA Partition

A real 315-5535 ASIC draws the base picture; the FPGA owns everything the ASIC has no register for.

**ASIC (5 jobs):** Mode 4 and TMS background · sprites 1–8 per line · CRAM palettes 0–1 · PSG and stereo panning · line and frame interrupts.

**FPGA (28 jobs):** VDP control-port gating · bus synchroniser · clock generation and turbo · cartridge wait states · shadow VDP state · sprites 9–16 · extended sprite attributes · per-sprite collision · line H offset table · line V offset table · window layer · text window · unique-cell mode · extended CRAM · DMA engine · math unit · PCM and wavetable · mapper and slot arbitration · BIOS ROM and launch · SK-1100 keyboard · mouse and trackball · floppy controller · debug unit · video compositing and output · overlay dialogs · power sequencing · non-volatile storage · player-sprite correlation.

**Control-port gating is the load-bearing job.** A write to register bank 1 or above must be absorbed by the FPGA; the ASIC would otherwise take it as a write to its own register of that number.

**Overlays.** Sitting between the CPU and the VDP, the FPGA can hold the Z80 and draw over anything running, including a cartridge that knows nothing about MasterDrive. That is how save dialogs, standby, the debug overlay and the switch between game and computer mode work.

(On the Analogue Pocket the whole machine, ASIC jobs included, is one FPGA design; the partition still describes which parts are stock.)

---

## 13. Debug Facility

Four capabilities that a debugger running on the Z80 cannot provide, each following from the FPGA's position on the bus.

| Capability | Why the FPGA |
|---|---|
| Debug UART | USB on hardware; the Z80 has no serial port. Implements the SDSC console convention (a debug-output convention used by Master System homebrew), so existing homebrew debug output works unchanged |
| Bus trace buffer | records every cycle at no cost to the program |
| Survives reset | the buffer is outside the Z80's memory, so it outlives the crash |
| Watchpoints | a bus condition, not a program-counter value, so it fires on the access itself |

| Port | Function |
|---|---|
| `$FB` | control: bits 1–0 trace mode (off / ports / VDP / both), bit 2 arm watchpoint, bit 3 raise overlay, bit 4 clear trace, bit 5 emit marker |
| `$FC` | SDSC console control; 2 clears the console |
| `$FD` | character output |
| `$FE` | watchpoint register select, bits 2–0; kind in bits 7–6 (VRAM / port / CPU write / CRAM) |
| `$FF` | watchpoint register data |

Watchpoint fields: address low and high, range end low and high, value to match, flags (bit 0 match value, bit 1 one-shot), ignore count. A single address on a busy port such as `$BE` fires tens of thousands of times a second; range, value, ignore count and one-shot together reduce that to the one hit that matters.

The power-on self test runs before the CPU leaves reset, with ten documented codes, also blinked on the power LED for a machine that cannot reach video.

**Which modes.** Writes reach the debug unit in every machine mode, since its purpose is inspecting stock software (stock hardware ignores writes to `$FB`–`$FF`). Reads answer from the debug unit only in MasterDrive mode: `$FB` returns the control value as written; `$FC` and `$FD` return a status byte (bit 7 a debug host is attached, bit 6 set, bit 0 the trace buffer is full); `$FE` and `$FF` return `$FF`. In the stock modes these ports read as the stock machine reads them (§11).

---

## 14. Software Identification

The `TMR SEGA` header is checked at `$7FF0`, `$3FF0` and `$1FF0`, in that order (8 KB and 16 KB ROMs carry it lower down). The machine's BIOS reads it and offers the machine the region asks for (§20).

| Offset | Contents |
|---|---|
| +0..+7 | `TMR SEGA` |
| +8..+9 | reserved |
| +10..+11 | 16-bit checksum, little-endian |
| +12..+13 | product code, BCD, last four digits, high pair in the second byte |
| +14 | high nibble: remaining product digits; low nibble: version |
| +15 | high nibble: region; low nibble: checksum range |

| Region | Machine |
|---|---|
| 3 / 4 | Master System Japan / Export |
| 5 / 6 / 7 | Game Gear Japan / Export / International |
| **8** | **MasterDrive** |

An export Master System BIOS rejects any cartridge whose region is not 4, so region-8 software will not boot on a stock export console. One ROM can still work on both (Q8, decided October 2026):

- **Native mode.** The BIOS menu (§20) can start an export (region 4) cartridge in MasterDrive mode instead of Master System mode: its Machine item. It then starts as MasterDrive software does, every extension off. On the Analogue Pocket core the System setting MasterDrive makes it the menu's first offer; in the emulator, the machine selector does.
- **Machine ID.** Port `$17` reads `$A7` in MasterDrive mode once Feature Enable A bit 7 is set (§11): the high nibble `$A` means MasterDrive, the low nibble is the machine version (7). It is read-only; a write is ignored. Before the bit is set, and on stock consoles, `$17` reads `$FF` (the controller mirror in the SG-1000, SC-3000 and SF-7000 modes).

To detect the machine, software writes VDP register 15 with bit 7 set (a stock VDP ignores register 15), then reads `$17` and tests the high nibble for `$A`, rather than only for a value other than `$FF`, since some sources describe open bus at the low ports of stock consoles.

Old code started in native mode meets MasterDrive behaviour: the pad reads as a Mega Drive pad (B and C as buttons 1 and 2 with TH high), the enhancement layer (§15) does not act, `$F0`–`$FF` are fully decoded, VDP registers 11–15 take effect, and the TMS modes raise line interrupts when R0 bit 4 is set. The option is for software that detects the machine; ordinary games run in Master System mode.

---

## 15. Enhancement Layer

Optional boosts for unmodified software (the Auto-Enhancement Layer, AEL), applied by intercepting the fixed hardware interfaces rather than patching the ROM. **All but two are off at power-on**, so the machine behaves as stock hardware until the user switches one on. The exceptions are True TMS colours, which starts on so SG-1000 and SC-3000 software shows the colours it was made for (Q11), and Start = Pause, which starts on because the console's pad has no Pause button (§6). On the console they live in the BIOS menu; the emulator (its AEL panel) and the Analogue Pocket (its core settings menu) have them in their own menus too, and the last change wins (§20). "Off at power-on" means a first start: a platform keeps the boosts in effect across a Reset, and where the console keeps them is open (Q33).

Explicit software intent always wins: every boost acts only on software running in the stock modes (SG-1000, SC-3000, Master System, Game Gear). MasterDrive software sets these features itself and reads C as a button of its own. Pseudo-stereo also stops as soon as software writes `$06`. The TMS-colour boost is the one exception: it also acts on MasterDrive software's TMS modes (Q11).

| Boost | Effect |
|---|---|
| Sprite limit | 16 sprites per line instead of 8 in Mode 4, and instead of 4 in the TMS modes — removes most flicker |
| Stock overflow flag | with the raised limit, status bit 6 is still set by a ninth sprite, for software that reads it as logic. Mode 4 only: in the TMS modes it has no effect |
| Start = Pause | Start on the pad raises the Pause NMI (Master System, SG-1000, SC-3000 modes). On at power-on |
| Turbo | a turbo step for stock software; MasterDrive software sets its own through `$F3` |
| VRAM speed-up | no VDP access wait while turbo is active (the bus synchroniser still holds FM writes, §1) |
| Auto-fire | while C is held, button 2 repeats (toggles every two frames: 15 Hz); releasing C leaves button 2 as the pad has it |
| Pseudo-stereo | until software writes `$06`: tone 0 left, tone 1 right, tone 2 and noise centre |
| Game Gear uncrop | show the full 256 × 192 picture the Game Gear VDP draws, instead of the 160 × 144 window |
| True TMS colours | SG-1000/SC-3000 picture modes use the TMS9918's own colours instead of the Master System's approximation. On at power-on |

The FM unit being present is inherent to the machine, not a switch. Two items of the enhancement-layer design have no switch of their own: *VRAM write reliability* (the emulator and the Pocket core never drop a VDP write, so it is always in effect) and *region speed correction*, which is the machine's 50/60 Hz video setting. Tiers, risks and the per-game override database are in `SuperSega_AutoEnhancement_Layer.md`, an earlier design document that is not in this repository (written against profile v5; where it differs, this section and profile v7 apply).

---

## 16. Stock Behaviour and Timing

Behaviour of the original parts that every implementation must reproduce. These are not MasterDrive additions; they are written down because the emulator had them wrong until October 2026 and the Pocket core is checked against them.

### CPU

- An interrupt taken during HALT returns to the instruction after the HALT.
- After EI, interrupts are accepted only once the next instruction has run.
- Maskable interrupts are sampled between instructions.
- DD/FD prefixes add a displacement byte only to instructions that use (HL); (IX+d) costs 8 T-states more than (HL), `LD (IX+d),n` 5 more. DDCB: BIT 20 T-states, the rest 23. A prefix followed by another prefix costs 4.

### VDP

- **Scrolling.** Screen x = map x + R8: the picture moves right as R8 grows. R8 is latched once per line, before the line is drawn; R0 bit 6 exempts the top two rows. R9 (vertical) is latched once per frame; R0 bit 7 exempts screen x 192 to the right edge, by screen position whatever the horizontal scroll (Gearsystem).
- **Line timing.** 228 CPU cycles per line; 262 lines (NTSC) or 313 (PAL).
- **V counter** values (it is 8 bits, so it jumps once per frame):

| | 192 lines | 224 lines | 240 lines |
|---|---|---|---|
| NTSC | 00–DA, D5–FF | 00–EA, E5–FF | 00–FF, 00–05 |
| PAL | 00–F2, BA–FF | 00–FF, 00–02, CA–FF | 00–FF, 00–0A, D2–FF |

- **H counter**: `$E9` at the start of the line; 171 counts per 228 cycles (00–93, then E9–FF).
- **Events within a line**, at fixed cycle offsets (the machine uses the 315-5535 column; the SMS2 column is for comparison):

| Event | SMS2 | 315-5535 |
|---|---|---|
| H scroll latched | 14 | 16 |
| V counter updated; frame flag (on line height + 1); sprite overflow flag | 25 | 27 |
| Line interrupt | 27 | 28 |
| Display enable latched | 37 | 20 |
| Line drawn (background of this line, sprites of the next) | 195 | 186 |
| Collision flag (X = first overlapping pixel) | 20 + X × 228 ÷ 256 | 22 + X × 228 ÷ 256 |

- If the collision time falls at or after the line's render event, the flag is set at the render event. (Gearsystem drops such late collisions; the hardware flags a collision anywhere on the line.)
- **I/O timing**: `IN A,(n)` and `OUT (n),A` reach the port 10 T-states into the instruction.

Sources: Charles MacDonald's VDP documentation (which lists NTSC 240 as 00–FF, 00–06 — 263 values for a 262-line frame; the implementations use 00–05); Gearsystem's timing model, which passes the SMS VDP test ROMs.

---

## 17. Open Questions

| # | Question | Status |
|---|---|---|
| Q1 | Ports `$06`–`$16` sit in the `$3E`/`$3F` mirror range. They act as registers only in MasterDrive mode (`$06` also in Game Gear mode, §11), so stock software in its own mode is unaffected. The risk is old code run in MasterDrive mode that writes a mirror address in `$06`–`$16`: a title retagged to region 8 (§14), a converted title, or a stock cartridge started in MasterDrive mode (one proposed answer to Q8 is a boot-menu option that does this). Move them above `$F0`? | resolved (owner, October 2026): they stay; in MasterDrive mode `$01`–`$17` answer only while Feature Enable A bit 7 is set (the I/O gate, §11), and `$00` always answers. Both implementations do this |
| Q2 | Maximum ROM size and the mapper register layout above 4 MB | resolved (owner, October 2026): 4 MB, the stock bank registers' reach (§8); the console also reads the computer side's media, how is Q23 |
| Q3 | Cartridge save-RAM size the machine guarantees (the 315-5235 maps 2 × 16 KB; the emulator models 2 × 8 KB) | resolved (owner, October 2026): 32 KB, two banks of 16 KB (§2, §8). Both implementations do this |
| Q4 | ESAT format | resolved in v6: 2 bytes per sprite |
| Q5 | Unique-cell mode and 32 KB VRAM | resolved in v6: coupled |
| Q6 | Turbo default | resolved: off at reset; a title turns it on itself (Feature Enable A bit 6, then `$F3`). The enhancement layer's turbo is for unmodified software only |
| Q7 | Math unit divide | resolved (owner, October 2026): A ÷ B, the quotient in `$0F` and the remainder in `$10`, `$FF`/`$00` for a divide by zero (§9). Both implementations do this |
| Q8 | Run-time detection of a MasterDrive by a single ROM | resolved (owner, October 2026): a boot-menu option runs an export cartridge in MasterDrive mode, and a read-only machine ID at `$17` reads `$A7` behind the I/O gate (§14). Both implementations do this |
| Q9 | Work RAM bank readback at `$0A` | resolved (owner, October 2026): `$0A` reads the selected bank in bits 3–0 (§2). Both implementations do this |
| Q10 | Reverting third-party GG-to-SMS patches | an emulator workflow, not a machine question |
| Q11 | Should the true-TMS-colours boost default off like every other boost, and act only in the stock modes? | resolved (owner, October 2026): on at power-on, one of the two boosts that start on (Start = Pause is the other), and it also acts on MasterDrive software's TMS modes (§15). Both implementations do this |
| Q12 | One cartridge wait state at 200 % turbo: the emulator applies it; the Pocket core does not yet | resolved (owner, October 2026): kept, and the Pocket core adds it (§1). Both implementations apply it to every cartridge read |
| Q13 | Feature Enable C bit 4 (ESAT 2-byte) contradicts ESAT being 2 bytes per sprite (Q4); the emulator still had a 1-byte layout when the bit was clear. Retire the bit or document the 1-byte layout | resolved (owner, October 2026): the bit is retired (reserved) and the ESAT is always 2 bytes per sprite (§5, §10); the emulator dropped its 1-byte layout |
| Q14 | `$08` reports a 64-byte FIFO's fill in three bits; the emulator returns the fill modulo 8, so a full FIFO reads as empty. Proposal: bytes queued ÷ 8, saturating at 7 | resolved (owner, October 2026): the proposal (§7). Both implementations do this |
| Q15 | Line interrupts in the TMS9918 modes. The machine profile lists them as a MasterDrive enhancement for SG-1000-style software (line interrupts are a Master System addition) but defines no bit that enables them. As stock the TMS modes raise none, and both implementations follow that in the stock modes; in MasterDrive mode both raise them in the TMS modes whenever R0 bit 4 is set. Should the line counter run in the TMS modes on MasterDrive, and what enables it? | resolved (owner, October 2026): in MasterDrive mode R0 bit 4 enables them, as in Mode 4 (§3, §16). Both implementations already did this |
| Q16 | The register layouts of the DMA engine (`$F4`–`$FA`), PCM control (`$08` write), the wavetable (`$11`–`$15`), slot select (`$09`) the VDP base registers (bank 0 R11 and R12, bank 1 R0, R1, R5 and R6) and the window split (bank 0 R13 and R14) are defined today only by the emulator's code (the Pocket core already follows it for `$09`). They need writing into this document and the profile, and checking, before the Pocket core implements them | resolved (owner, October 2026): the emulator's layouts are adopted (§3, §5, §7, §8, §9, §10), with four clear faults fixed: a fill wrote the mode register instead of a chosen byte, a transfer to CRAM left its palettes marked unwritten, with the background scrolled, part of the screen left of the window showed the backdrop, and reset left the PCM output at its last sample. What the emulator does not settle is Q26–Q30 |
| Q17 | Feature Enable B bits 7–6 select 224 or 240 lines for MasterDrive software, but this document defines the heights only for Mode 4 (§3). Both implementations also apply them while a TMS9918 mode is selected. Should the machine apply them in the TMS modes, and if so, what do those modes draw below line 192? | resolved (owner, October 2026): yes; the tables carry on below line 192, Graphics II takes a fourth bank, and `$D0` no longer ends the sprite list (§3). Both implementations do this |
| Q18 | Two details of the sprite flags in the TMS modes (§3). What status bits 4–0 read: the TMS9918A puts the number of the fifth sprite there, Gearsystem does that whenever a TMS mode is selected (not on the Game Gear) and reads `$1F` in Mode 4, the Pocket core reads `$1F` and the emulator 0 in every mode. And whether a transparent (colour 0) sprite takes part in collisions: the TMS9918A Data Manual says it does; Gearsystem and both implementations leave it out | open |
| Q19 | Several TMS mode bits set at once (§3). The implementations take M2 (Graphics II) first, then M1 (Text), then M3 (Multicolor); Gearsystem takes M1, then M3, then M2; on the TMS9918A such combinations give undocumented hybrid modes. Which picture should the machine show? | open |
| Q20 | The balance of FM and PSG (§7). On the original Japanese Master System the two chips are mixed in analogue, and how loud each is is not known: MAME gives both the same gain, Gearsystem lowers the PSG to 0.8 while both play, and neither cites a measurement. Both implementations make one FM channel at full volume peak at half a PSG channel at full volume. The chip also has separate melody and rhythm outputs, whose mix on the console's board is not known either; the Pocket core uses IKAOPLL's default weights (2 and 3), and the emulator has no rhythm instruments. What balance should the machine have? | open |
| Q21 | FM register writes at turbo (§1). The YM2413 needs 12 master-clock cycles after an address write and 84 after a data write before it takes the next write. Software written for 100 % spaces its writes by CPU time, so at turbo steps above 100 % they can come too close: on the Pocket core a test driver that leaves the chip little more than the minimum at 100 % played no FM at 200 %. Should the bus synchroniser hold the CPU on `$F0`/`$F1` until the FM chip is ready, as it does for the VDP? | resolved (owner, October 2026): yes (§1). Both implementations do this, and the test driver now plays at 200 % |
| Q22 | PAL turbo clocks (§1). The turbo steps are defined at the NTSC clock: 4.47, 5.37, 6.26 and 7.16 MHz. In PAL both implementations run the same percentages of the PAL clock, 4.434, 5.320, 6.207 and 7.094 MHz, because their turbo is a multiple of the base clock. Should PAL turbo be those, or the NTSC frequencies? | resolved (owner, October 2026): the same percentages of the PAL clock (§1). Both implementations do this |
| Q23 | Reading cassettes and disks (§8). The console reads SC-3000 cassettes and SF-7000 disks (Q2). In which modes, through which ports, and does the boot menu load an image or does software read the signal? Does it write them too? | open |
| Q24 | The save card (§8). A profile holds the first 8 KB of bank 0 of a game's cartridge RAM, which is 32 KB (Q3), and each card entry carries a 32-bit game ID that the machine does not define: the emulator derives it from a sampled hash of the ROM, so two ROMs of the same size that differ only between sampled bytes share their card saves. Should a profile hold all 32 KB, and what identifies a game: a CRC-32 of the whole ROM, the header's product code, version and region (SG-1000 and SC-3000 cartridges have no header), or something else? How do existing cards carry over? | open |
| Q25 | Cartridge writes at 200 % (§1). The cartridge wait state applies to reads, which a 250 ns ROM limits, and both implementations apply it to reads only. Should writes to the cartridge slot (cartridge RAM at `$8000`–`$BFFF`, the mapper registers) take it too? | open |
| Q26 | DMA timing and reach (§9). The emulator completes a transfer as soon as `$FA` bit 7 is written and charges the CPU one T-state per byte (with the cartridge wait state on bytes read from the cartridge at 200 %), whatever the display is doing, and the bus synchroniser does not take part. How long should a transfer take, does the CPU wait for it, and may it write VRAM during the active display? The destination register reaches only `$0000`–`$3FFF`, but a transfer counts on into the upper 16 KB, even without VRAM expansion: should it wrap at `$3FFF`, follow bank 1 R3, or have a fifteenth address bit? | open |
| Q27 | PCM and wavetable clocks and levels (§7). The PCM rates (8,000, 11,025, 16,000 and 22,050 samples a second) and the wavetable's pitch (the emulator plays a voice's waveform *f* × 3.2 times a second) are not made from the machine clock: none of the four rates is a whole fraction of 3.579545 MHz. Their level beside the PSG and FM chip is the emulator's choice: PCM at full scale peaks at 0.2 of the output's full scale, a wavetable voice at full volume at 0.12, a PSG channel at full volume at 0.16. Which clocks and levels should the machine have, and does `$F2` mute them? | open |
| Q28 | Render bank (bank 1 R4), sprite palette base (bank 1 R5), collision result base (bank 1 R6) and per-sprite collision (Feature Enable B bit 3, which is meant to write hit bitmaps at the R6 base, §5). The documents name them, but neither implementation does anything with them, so their layouts and behaviour are not defined. What do they hold? | open |
| Q29 | Window rows and side (§3). The tile window reads its tilemap by screen row, so a window from row 20 down starts at tilemap row 20, while the text window counts its rows from the window's top edge. R14 bit 7 picks the side of the Y split, but R13 has no side bit, so the window can lie only right of the X split. And the window reads its tilemap base, bank 1 R0, even while XRB is clear, when the bank 1 registers are otherwise without effect (§10). Which row rule should both use, should the window be able to lie left of the X split, and should its tilemap base need XRB? The BIOS's menu relies on the text window's rule (§20): settling Q29 the other way changes the BIOS too. | open |
| Q30 | Slot select and the `$3E` slot enables (§2, §8). `$09` maps the card into `$4000`–`$BFFF` by itself. On the stock Master System `$3E` bit 5 enables the card slot and bit 6 the cartridge slot; the emulator ignores bit 5, and ignores bit 6 whenever a card is inserted, and the Pocket core decodes `$09` and `$0B` but loads no card. How should `$09` and `$3E` bits 5–6 combine, and what does `$0000`–`$3FFF` read when `$3E` disables the cartridge? | open |
| Q31 | Identifying a headerless cartridge on the console (§20). Without a `TMR SEGA` header the BIOS takes a cartridge of 64 KB or less as SG-1000 software, otherwise as Master System software. That needs the size, which the Pocket core and the emulator know from the file but a console cannot read from a cartridge (setting 18 reads 0), so on the console Auto plays every headerless cartridge as Master System software. How should the console tell SG-1000 and SC-3000 cartridges, and headerless Japanese Master System ones, apart? | open |
| Q32 | How the console holds and starts its BIOS (§20). The owner's plans keep the BIOS in SPI flash, which the Z80 cannot run from, so the console's FPGA must present it as the 8 KB BIOS ROM (from block RAM, say). And a Z80 reset leaves SP at `$FFFF` on real parts, not the hand-over `$DFF0` (§1), which the emulator and the Pocket core set in their reset (the BIOS sets AF' itself). How does the console's launch reach that state: does the FPGA give the CPU a few instructions (`LD SP,$DFF0`, `JP $0000`) after the reset, or something else? | open |
| Q33 | Where the console keeps the BIOS's choices (§20). A platform with its own settings menu keeps the boosts the BIOS sets until they change again; the console has no such menu. Where does it keep them (the plans' FRAM, per title or for all)? And the BIOS's machine choice lasts one launch: should it outlast a Reset, as the boosts do? | open |
| Q34 | The console's region (§20). The Pocket core and the emulator have a region setting (export or Japan), which the BIOS reads (setting 20) and which port `$00` bit 6 and the TH read-back follow (§6). The documents do not say which region the console is, or whether it has a switch. | open |
| Q35 | The BIOS ROM's size (§20). The BIOS ROM is 8 KB, as the Master System's base BIOS ROM behind `$3E` bit 3, and the menu uses about half of it. The owner's plans add a save card manager, USB import and export and a computer mode, which will not fit: should the BIOS ROM grow, be paged (and through which register), or should those tools live elsewhere? | open |
| Q36 | `$3E` bit 3 after the launch (§2, §20). Both implementations keep the BIOS ROM reachable after the launch: in Master System, Game Gear and MasterDrive modes a `$3E` write with bit 3 clear and bit 6 set maps it over `$0000`–`$BFFF` again, and in MasterDrive mode the BIOS's ports answer too, so software could start another machine with `$A5` at `$1F`. On the stock machines the BIOS behind bit 3 is the Master System's own (the Game Gear maps only `$0000`–`$03FF`). Should the MasterDrive BIOS stay reachable after the launch, in which modes, and should its launch port then work? | open |
| Q37 | The launch on the console (§20). The launch resets every block at the VDP's wrap to line 0, so that the first clock after it is that of a cold reset. The Pocket core does this in its own logic and the emulator at a frame boundary. On the console the VDP and PSG are inside the 315-5535: can the FPGA reset them at that moment, or must it rewrite their registers, and how does the raster's phase come out? | open |
| Q38 | Memory the BIOS does not clear (§20). Work RAM banks 1–15, VRAM `$4000`–`$7FFF`, CRAM entries 32–255, the wavetable waveforms, SC-3000 cartridge RAM and the SF-7000's RAM keep what they held across a cold reset and the launch, so a game can find what an earlier game left; the emulator's cold reset clears VRAM, CRAM and the waveforms. Should a cold reset or the launch clear them, and should both implementations then do the same? | open |
| Q39 | Reading past a cartridge's ROM (§8, §20). A cartridge image need not be a power of two long. Reads beyond it inside the cartridge's address range wrap into the image in both implementations (the address taken modulo the image's length), except in the emulator's SG-1000 mode, which reads `$FF` there and never mirrors; the Pocket core mirrors a power-of-two image through its size in every mode. On a real cartridge it depends on how the board decodes the address. What should a read beyond a cartridge's ROM return, in each mode? | open |

Two risks from v2 remain as evidence rather than proof: six commercial titles were checked and none write VDP registers 11–15 (where Feature Enable A lives), which matters for old code run in MasterDrive mode, the only mode in which those registers act (§10): an old title that set R15 bit 7 there would also open the I/O registers (§11); and the keyboard's active-low polarity rests on a single source that contradicts itself.

---

## 18. Capability Summary

| Against | MasterDrive provides |
|---|---|
| SG-1000 / SC-3000 | full compatibility, including the SC-3000's cartridge-set memory map and the SK-1100 keyboard |
| Master System | full compatibility, plus 16 sprites per line, 16×16 sprites, ESAT, extended CRAM, window and text layers, unique-cell mode, line offset tables, DMA, math unit, turbo |
| Game Gear | full compatibility in the 160 × 144 window; the full 256 × 192 picture is an enhancement-layer option |
| SF-7000 | 64 KB, IPL overlay, floppy controller backed by disk images |
| MSX1 | shares the TMS9918 modes. MSX software is brought over with the emulator's porting tools; the console does not run MSX software |

---

## 19. Implementation Status (October 2026)

| | Emulator machine model | Analogue Pocket core |
|---|---|---|
| Z80, Mode 4 VDP (192/224/240), Game Gear CRAM, PSG | yes | yes |
| Mappers | Sega, Codemasters, Korean, Korean MSX (MSX variant) | the same |
| Controllers, SK-1100 keyboard | yes | yes (keyboard not yet tested on the core) |
| Mega Drive mouse, Sports Pad trackball | yes | not yet |
| I/O gate (Feature Enable A bit 7, `$01`–`$17`) and machine ID (`$17`) | yes | yes |
| The BIOS (§20): menu, launch, `$3E` bit 3, ports `$18`, `$19`, `$1F` | yes | yes (no SF-7000 to launch) |
| Native mode for an export cartridge (Q8) | the BIOS menu; the machine selector offers it first | the BIOS menu; the System setting offers it first |
| Multitap detection (`$16`) | yes | yes |
| Multitap protocols (Sega Team Player, EA 4 Way Play) | not yet | not yet |
| Game Gear serial registers (`$01`–`$05`) | yes (they hold what is written) | yes (the same) |
| Link cable | not yet | not yet |
| MasterDrive register banks, native/extended CRAM, 16 sprites per line, turbo and bus synchroniser | yes | yes |
| Work RAM banking (`$0A`) | yes | yes |
| Cartridge save RAM, 2 × 16 KB | yes | yes (saved as a 32 KB `.sav`) |
| Cartridge wait state at 200 % | yes | yes |
| Math unit (`$0C`–`$10`) | yes | yes |
| Card slot: slot select (`$09`) and card bank (`$0B`) | yes | registers and memory decode only: the Pocket platform loads no card, so the slot is always empty |
| VRAM expansion | CPU access (bank 1 R3) and unique-cell tiles; the render bank (bank 1 R4) is not defined (Q28) | the same |
| ESAT, 16×16 and magnified sprites, window/text layers, line tables, unique-cell | yes | yes |
| TMS9918 modes (SG-1000, SC-3000), and at 224 and 240 lines for MasterDrive software | yes | yes |
| YM2413 FM | yes (approximate synthesis: no rhythm instruments; the user instrument, `$00`–`$07`, is not read; no envelopes, so a note holds its level until key-off; volume steps are linear, not the chip's 3 dB; the built-in instruments only resemble the chip's) | yes (IKAOPLL, a YM2413 core reverse-engineered from die shots of the chip) |
| PCM, wavetable, DMA engine | yes | yes, with the emulator's rates, pitch and levels (Q27) and DMA charge (Q26), except that a DMA transfer from the cartridge at 125–175 % turbo takes longer than the emulator charges |
| SF-7000, floppy, debug unit | yes | not yet |
| PAL CPU clock (3.546893 MHz, §1) | yes: PAL frames come at 49.70 a second, and the PSG and FM chip run on the PAL clock | yes, the same (the Pocket's video clock stays fixed, so a PAL line reaches its scaler as 345 or 346 pixel clocks; not yet seen on a Pocket) |
| Enhancement layer | all | all |

**Verification.** Batman Returns (Europe) on the Master System in PAL, frames 30, 60, 120, 200, 500, 900 and 1500, and Batman Returns (World) on the Game Gear, frames 200, 500, 900 and 1500: the emulator and the Pocket core (in simulation) both match Gearsystem; Game Gear frames match within Gearsystem's colour rounding (it expands the channel value 5 to 86, not 85). VDP test ROMs at 192, 224 and 240 lines and a MasterDrive feature ROM (register banks, native and extended CRAM, Feature Enable B height, 16 sprites, 200 % turbo with the bus synchroniser) give the same pictures on the emulator and the core. An I/O test ROM reads 18 ports in the Master System, Game Gear and MasterDrive modes and gets the same values on both, apart from the one difference the implementations are meant to have: no debug host is attached to the core (`$FC`/`$FD` bit 7, MasterDrive mode). An I/O gate test ROM reads MasterDrive's low ports before and after setting Feature Enable A bit 7: in MasterDrive mode they read `$FF` while the gate is closed, then the registers answer and `$17` reads `$A7`; in Master System and Game Gear modes the gate never opens. The emulator and the core agree in all three modes. A MasterDrive register test ROM multiplies and divides in the math unit (with a divide by zero) and reads `$0A`, `$08` and `$17` back: both give the values §2, §7, §9 and §14 define. A wait-state test ROM runs the same 2,000 NOPs from cartridge ROM and from work RAM at 200 % and 175 %: at 200 % the ROM run ends five lines later, at 175 % both end together, the same on both implementations, in NTSC and PAL. An FM test ROM plays a PSG tone and an FM sine and steps `$F2` through its four states: on the core each chip is heard exactly in the states that select it, at the expected pitch and at the balance above (Q20). The emulator's `$F2` states are checked by a probe; its FM sound is approximate, so the two sound different. Four SG-1000 test ROMs, one per TMS9918 mode (sprite priority, collisions, the fifth-sprite limit, the early clock, transparency), give the same pictures on the emulator and Gearsystem, and on the core (exactly in the Master System colours; in true TMS colours within the core's 4-bit-per-channel output). Three MasterDrive test ROMs draw the TMS modes at 224 and 240 lines (Graphics II at both, Text at 240, with sprites below line 192, a sprite at Y = `$D0`, the Mode 4 wrap and line interrupts): the emulator and the core give the same pictures, and on the SG-1000 the same ROM stays at 192 lines. Two MasterDrive test ROMs draw the picture extensions of §3 and §5 (the ESAT's flips, priority, sizes, magnification, early clock and palettes; the line tables; the tile and text windows; unique-cell tiles; and the busiest line the renderer meets, 16 sprites of 64 × 64 pixels): the emulator and the core give the same pictures, as they do for four random pictures (every VRAM byte, part of CRAM and the video registers set from a seeded generator). A DMA test ROM fills VRAM, copies from the cartridge, work RAM, VRAM and the empty card slot, loads palettes into CRAM and runs a fill on past `$3FFF`: the emulator and the core give the same picture, and the CPU's time for each transfer is the same on both, instruction by instruction. A sound test ROM plays the PCM at each of its four rates and the two wavetable voices: on the core each is heard on the sides it selects, at the pitch and level the emulator gives it. The BIOS (§20): in the emulator every test ROM started through it, NTSC and PAL, runs as the same ROM started directly, frame for frame; on the core its menu screens match the emulator's, and its first 50,000 instructions take the emulator's time, instruction for instruction. Nothing has run on a Pocket yet.

---

## 20. Start-up and the BIOS

The **BIOS** is the machine's own start-up program: Z80 software in the 8 KB BIOS ROM that `$3E` bit 3 maps (§2). It shows a menu before every game, and holding Start while switching on skips the menu. It was written for this project (its source is `bios/` at the top of the repository, under the MIT licence) and contains no Sega code, logo or wording. The owner decided, in October 2026: a full menu before every game, the same on the console, in the emulator and on the Analogue Pocket; both the BIOS menu and a platform's own settings menu set the machine and the boosts, the last change winning; the menu waits for the player to choose PLAY.

### Cold reset

A **cold reset** is switching on; on the Pocket also the core starting, Reset, a new cartridge, or a change of the System or Video setting; in the emulator also Reset, loading a cartridge, or a change of machine or TV standard. Every block takes its reset value, except that the machine starts in **MasterDrive mode** with `$3E` = `$E0`: the BIOS ROM, work RAM and the controllers enabled; the cartridge, card and expansion port disabled. The CPU starts at `$0000`, in the BIOS, in the state of §1. No Pause (NMI) is raised from a cold reset until the launch below: software cannot mask an NMI, and the BIOS has no use for one.

### The BIOS ROM

While `$3E` bit 3 is clear and bit 6 is set, `$0000`–`$BFFF` reads the BIOS ROM, its 8 KB repeated through the range. With bits 3 and 6 both clear the cartridge answers, not the BIOS, so software that writes `$3E` = `$04` (bit 2 set, disabling the I/O chip before it reads `$F2`, §7, and the other bits clear) keeps running from its own ROM. BIOS reads, by the CPU or by a DMA transfer from source 0 (§9), take no cartridge wait state (§1), and the BIOS writes nothing below `$C000`. Both implementations keep the BIOS ROM reachable this way after the launch too; whether it should be is open (Q36).

To read the cartridge's header (§14), the BIOS copies a short routine to work RAM, which switches `$3E` to `$A8` (cartridge on, BIOS off), copies the 16 bytes at `$7FF0`, `$3FF0` or `$1FF0`, and switches back to `$E0`, as the Master System BIOS does. After a cold reset every mapper has ROM offsets `$0000`–`$7FFF` at those addresses (§8).

### The BIOS's ports and settings

In MasterDrive mode, while the BIOS ROM is mapped, `$18`–`$1F` in the `$3E`/`$3F` mirror range belong to the BIOS, which uses three of them; otherwise they are mirrors as before (§11).

| Port | Direction | Function |
|---|---|---|
| `$18` | write | setting index (reads `$FF`) |
| `$19` | read/write | the setting at the index; the index then steps by one |
| `$1F` | write | `$A5` launches the game (below); other values do nothing (reads `$FF`) |
| `$1A`–`$1E` | | read `$FF`; writes do nothing |

| Index | Setting |
|---|---|
| 0 | the machine to launch: 0 Master System, 1 Game Gear, 2 SG-1000, 3 SC-3000, 4 SF-7000, 5 MasterDrive. After a cold reset: the platform's choice (index 16) if the platform runs that machine (index 21), otherwise 0. A write of a machine the platform does not run (index 21), or of a larger value, is ignored |
| 1–9 | the boosts for the next launch, in §15's order: sprite limit, stock overflow flag, Start = Pause, turbo step (0–4), VRAM speed-up, auto-fire, pseudo-stereo, Game Gear uncrop, True TMS colours. Index 4 ignores values above 4; the others keep bit 0 |
| 16 | read only: the platform's machine choice, `$FF` for none (Auto) |
| 17 | read only: bit 0 a cartridge is inserted, bit 1 a card is inserted, bit 2 the platform has USB, bit 3 PAL video, bit 4 the platform has its own settings menu |
| 18 | read only: the cartridge's size as log2 of its byte count, rounded up (13 = 8 KB, 22 = 4 MB); 0 if unknown (Q31) |
| 19 | read only: the platform's mapper setting (0 Sega, 1 Codemasters, 2 Korean, 3 Korean MSX), `$FF` if unknown |
| 20 | read only: the region, 0 export, 1 Japan (Q34) |
| 21 | read only: the machines the platform runs, bit *n* for machine *n* |
| others | read `$FF`; writes do nothing |

### The boosts: two menus, the last change wins

Each boost of §15 has a **current** value, the one in effect, and a **next** value, the one for the next launch; the first cold reset after the platform starts takes the platform's own values for both. A change in a platform's own menu (the Pocket's Core Settings, the emulator's controls) sets both at once, in the BIOS menu or during a game. A write to index 1–9 sets only the next value, and the launch makes every next value current. A later cold reset keeps each current value and makes it the next value too, so a change made in the BIOS menu and not yet launched is dropped. Between cold resets, whichever changed a boost last therefore wins. The BIOS reads indices 1–9 every frame, so a platform change shows in its menu at once, and writes a boost only when the player changes it there. The machine chosen in the BIOS menu lasts one launch (Q33).

### Which machine

The BIOS offers first the platform's choice (index 16) if it has one, except that with a cartridge inserted a choice of the SF-7000, which does not play the cartridge, counts as none. Otherwise it reads the header's region nibble (§14): 3 or 4 Master System, 5–7 Game Gear, 8 MasterDrive, other values Master System. With no header it takes a cartridge of 64 KB or less as SG-1000 software if the size (index 18) is known, and any other as Master System software (Q31). The checksum is shown, never enforced: the BIOS refuses no cartridge.

### The launch

When `$A5` is written to `$1F`, the CPU runs no further instruction. At the VDP's next wrap to line 0, whichever line the write came on, every block is reset as at a cold reset, except that the machine is the one in index 0, `$3E` is `$A8` and the boosts' next values become current; the first clock after the launch is that of a cold reset, so the game's timing, turbo included, starts as after one. Memory is not touched: VRAM, CRAM, work RAM and cartridge RAM stay as the BIOS left them, and so do the CPU registers a Z80 reset does not set. The game starts at `$0000` in the state of §1. A Pause held through the launch (the Pause button, or Start with Start = Pause on) is not a press: the game gets a Pause when it is pressed again. How the console does all this with the VDP and PSG inside its 315-5535 is open (Q37).

Before the launch the BIOS leaves things as a direct start would find them: it turns the display and its interrupts off, clears VRAM `$0000`–`$3FFF`, the 32 CRAM entries and work RAM bank 0, sets AF' to `$FFFF` and BC, DE, HL, IX, IY, BC', DE' and HL' to zero (the CPU reset sets AF to `$FFFF` itself). The launch waits until the button that asked for it has read released in two frames running (Start on the skip path; from the menu both Start and B, whichever launched), so the game does not start with it held. The BIOS checks this before its clears, which take about seven frames; a button pressed during them is held at the launch. Other buttons may stay held, so a game can still read a combination held at switch-on.

**Memory at hand-over.** Work RAM bank 0, VRAM `$0000`–`$3FFF` and CRAM entries 0–31 are zero, cleared by the BIOS, and the palette-written flags (§4) are clear, reset by the launch. Work RAM banks 1–15, VRAM `$4000`–`$7FFF`, CRAM entries 32–255, the wavetable waveforms, SC-3000 cartridge RAM and the SF-7000's RAM are cleared neither by a cold reset nor by the launch: software must not assume them zero. (The emulator's cold reset happens to clear VRAM, CRAM and the waveforms; the Pocket core's, whose memories are block RAM, does not.) Whether they should be cleared is open (Q38).

### The menu

Rows 0–2 of the screen are Mode 4 tiles: the name, the BIOS version and the device row, CART, CARD, USB and SYSTEM, with the current device in yellow. Below them the text window (§3) shows the device's page in 40 columns of 6-pixel characters, from x = 8, with a status line at the bottom. A sprite arrow marks the selected item. Left and right change device, up and down move, B changes an item, C goes to the top, and Start plays from any device when a cartridge is inserted. With no cartridge, Start plays only when the platform's choice is the SF-7000 and the platform runs one (index 21): the SF-7000 starts from its own ROM and disks.

- **CART:** what the header says (the kind of software, product code, version, region, the checksum as stored, the size when known; or "No header found: plays as …"), PLAY, the machine (Auto, or one the platform runs, but not the SF-7000, which does not play the cartridge) and the boosts. A boost that does not act on the machine PLAY starts (§15: the stock overflow flag on the SG-1000 and SC-3000, Start = Pause on the Game Gear, the uncrop anywhere but the Game Gear) is marked "(no effect)". For MasterDrive software only True TMS colours is listed, the one boost that also acts on it (Q11).
- **CARD:** whether a card is inserted.
- **USB:** "This machine has no USB port." where the platform has none.
- **SYSTEM:** the BIOS version, the machine ID (`$17`, §14), the video standard and region, a controller test (B starts it; every button then shows while held, and no button acts until Start and A are held together), and how to skip the menu.

The BIOS silences the PSG when it starts. The menu uses the stock colours only and has no animation. It draws a page into the text window's name table that is not on screen (it keeps two, at `$3000` and `$3400`) and shows it from a vertical blank, so a page change goes from one frame to the next, never half of each page. With the display on, its VDP data writes are at least 29 T-states apart, as the stock VDP needs at 100 % (§1). It relies on the text window counting its rows from its top edge (Q29).

Not in this round, each waiting on an open question or on hardware the implementations lack: per-title settings, the save card manager, USB, computer mode, firmware update, the POST display, PLAY's region, video, controller and slot options, a SETTINGS page, the SYSTEM memory and video tests, FPGA configuration and card health, the offer at power-on to restore a cartridge's save, the return to the BIOS from a running game, and cassettes and disks.
