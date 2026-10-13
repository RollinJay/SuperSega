# Super Sega — Technical Reference, v3

October 2026. Consolidated specification of the Super Sega 8-bit machine. Supersedes v2. The machine-readable form is `super_sega_machine_v7.json`; where the two disagree, that is a bug in one of them.

## How to read this document

Super Sega is an 8-bit console in the Sega SG-1000 / Master System / Game Gear family. It runs the software of all three unmodified, and adds new hardware features that new software can opt into.

Two ideas run through everything below:

- **Stock behaviour.** At power-on every extension is off. The machine then behaves exactly like the original hardware — a Master System with the FM sound unit fitted, or a Game Gear, SG-1000 or SC-3000, depending on the mode it boots in.
- **Opt-in extensions.** New software turns extensions on through three *Feature Enable* registers (A, B and C, described in §10). Old software never touches them, so it can never see them.

A third, separate idea is the **enhancement layer** (AEL, §15): optional boosts for *old* software, such as removing sprite flicker. They are user settings, all off by default.

**Notation.** VDP registers come in four banks of 16 (§10). "R7" alone means bank 0 register 7, a stock register; "bank1 R3" means register 3 of bank 1, one of the Super Sega additions. The banks above 0 can only be reached once software sets **XRB** (extended register banks, Feature Enable A bit 5). **TH** and **TR** are two pins of each controller port (§6): TR is button 2, TH the light-gun and multiplexing line.

The machine exists in three forms that must behave the same: the physical console design, the machine model inside the HTML5 emulator, and the Analogue Pocket core. The emulator also has tools that are not part of the machine (the ROM hack maker, MSX porting tools, and others); those are listed in `SuperSega_v7_Reconciliation.md` and are not described here.

**What changed in v3.** Two errors in v2 (also present in machine profile v6) were found while testing the Analogue Pocket core against two independent emulators, Gearsystem and MAME: the bits that select the 224- and 240-line modes were swapped, and the Codemasters and Korean mapper registers were said to respond anywhere in their slot. Both are corrected below and marked **v2 error**. v3 also writes down stock-hardware behaviour the emulator had wrong (§16), adds the enhancement layer (§15), limits the debug unit's port reads to Super Sega mode so that stock software reads its pads as on the original hardware (§13), and replaces v2's "open risks" with the profile's open questions (§17). v2's open risk about sprites not rendering was a fault in the emulator's self-test, not in the machine, and is removed.

---

## 1. Processor and Clocks

| | |
|---|---|
| CPU | Z80, CMOS static (Z84C00 class) |
| Base clock | 3.579545 MHz (NTSC); 3.546893 MHz in PAL, as on a PAL Master System, which gives 49.70 Hz frames of 313 lines |
| State at hand-over to software | PC `$0000`, SP `$DFF0` (where the Master System BIOS leaves it), interrupts disabled, interrupt mode 0 as after a Z80 reset |
| Interrupt mode | IM 1 (`RST 38h`), selected by software; NMI is the Pause button |
| Turbo steps | 100 / 125 / 150 / 175 / 200 % |
| Turbo control | port `$F3`, bits 2–0, step 0–4 |
| Turbo enable | Feature Enable A bit 6 — off at reset; a write to `$F3` takes effect only while it is set, and the step then stays until `$F3` is written again |
| Turbo generation | FPGA PLL, true 4.47 / 5.37 / 6.26 / 7.16 MHz at the NTSC clock (PAL turbo frequencies are not defined yet) |

Turbo gives the CPU more cycles per frame; the video chip (VDP), PSG and FM chip stay at normal speed, so the picture, raster timing and frame rate do not change. A game's frame rate stays governed by its own wait for the vertical blank. Software that does not wait for vertical blank must stay at 100 %.

Turbo sits on `$F3`, outside the `$00`–`$3F` range that old software uses for its I/O control ports, so no unmodified title can reach it.

### Bus synchroniser

With turbo on, the CPU runs faster than the VDP can accept data. The FPGA therefore holds the CPU (with the Z80's WAIT line) until the VDP reaches its next access slot. The official Sega manual gives the slot spacing:

| Period | VDP access slot every |
|---|---|
| Vertical blank | 16 base cycles |
| Active display | 29 base cycles |

An `OUTI` loop takes 16 cycles, so streaming to video memory during vertical blank is free at any turbo step. During active display each access waits for its slot: at 200 %, an access every 58 CPU cycles, so a stream of bare `OUTI` instructions waits 42 cycles per byte. This is the hardware reason Sega's manual forbids two `OUT`s to the VDP back to back without a gap, and why software streams video data during blanking.

Cartridge ROM adds its own wait: a 250 ns ROM is fast enough up to 175 % and needs one wait state per access at 200 % (open question Q12 covers the Pocket core).

---

## 2. Memory

| Resource | Size | Control |
|---|---|---|
| Work RAM | 128 KB, 16 banks of 8 KB | port `$0A` |
| Work RAM window | `$C000`–`$DFFF`, mirrored at `$E000`–`$FFFF` | |
| Video RAM (VRAM) | 16 KB, expandable to 32 KB | Feature Enable B bit 4 enables; bank1 R3 bit 0 selects the bank the CPU reaches |
| Colour RAM (CRAM) | 32 entries, expandable to 256 | bank1 R2 bit 1 |

Bank 0 at reset is the stock 8 KB that Master System software expects. The first 64 KB can be used as one contiguous block, which the SF-7000 disk system needs.

The work RAM bank register cannot be read back yet; interrupt handlers that switch banks need a way to restore the previous bank (open question Q9).

### Port `$3E` — memory enables

Active low: writing 1 to a bit disables that region, which then reads as open bus ($FF).

| Bit | Region |
|---|---|
| 2 | I/O chip (controller ports) — see §11 for exactly what it covers |
| 3 | base 8 KB BIOS ROM |
| 4 | internal 8 KB RAM |
| 5 | card ROM |
| 6 | cartridge ROM |
| 7 | expansion port |

Reset value `$A8`: the state of a machine whose BIOS has handed over to a cartridge — cartridge, RAM and controllers enabled; BIOS, card and expansion disabled.

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

Two families of display modes. The legacy TMS9918 modes (Graphics I, Graphics II, Multicolor, Text) come from the SG-1000, SC-3000 and MSX1. Mode 4 is the Master System's tile mode, and carries all the Super Sega extensions.

### Display height

Mode 4 shows 192, 224 or 240 lines. The four mode bits are spread over two registers: **M1** is R1 bit 4, **M2** is R0 bit 1, **M3** is R1 bit 3, **M4** is R0 bit 2.

| Selection | Result |
|---|---|
| M4 = 1, M2 = 1, M1 = 1, M3 = 0 | 224 lines |
| M4 = 1, M2 = 1, M3 = 1, M1 = 0 | 240 lines |
| M4 = 1 with M2 = 0, or any other combination | 192 lines |
| Feature Enable B bits 7–6 (Super Sega software) | 192 / 224 / 240 (defined for Mode 4; the TMS modes are open question Q17) |

M2 is the switch that allows the taller modes; M1 and M3 then pick the height.

**v2 error:** v2 gave 224 lines for M4 M3 M1 with M2 clear, and 240 for M4 M3 M2 with M1 clear — M2 and M3 swapped. Under that rule a typical game writing R0 = `$36` and setting R1 bit 4 stayed at 192 lines, and R0 = `$04` with R1 bits 4 and 3 set gave 224 lines where hardware shows 192. Source: MAME `sega315_5246`, Gearsystem.

Both selection paths must work: the standard bits are how Master System and Game Gear software reach the tall modes; Super Sega software may use Feature Enable B instead. In the tall modes the screen map is 32 × 32 tiles at `(R2 bits 3–2) × $1000 + $700` instead of 32 × 28 at `(R2 bits 3–1) × $800`, the map wraps every 256 lines instead of 224, and `$D0` no longer ends the sprite list.

### Documented VDP behaviours

| Behaviour | Detail |
|---|---|
| V counter | readable at `$7E`; zero on the first displayed line; jumps once per frame (table in §16) |
| H counter | readable at `$7F`; latched when a TH pin rises (light gun) |
| Sprite collision | status bit 5, cleared when the control port is read |
| Sprite overflow | status bit 6, set by a ninth sprite on a line **by Y alone** — off-screen and transparent sprites count |
| Frame interrupt flag | status bit 7, set early in line *height* + 1 (the second line after the last displayed one, §16); stays set until the status register is read |
| CRAM addressing | high address bits ignored, so the address always lands in CRAM |
| Line interrupt counter | on lines 0 to *height* (one line past the display) it counts down, and on reaching 0 it reloads from R10 and raises the line interrupt; on the other lines it is reloaded from R10. Mode 4 only as stock (the TMS modes raise none); whether Super Sega runs it in the TMS modes is open question Q15 |
| Name-table spare bits | the top three bits of each entry are unused by the VDP; some games keep collision flags there |
| 8×16 sprites | the low bit of the tile index is ignored |
| Registers 11 and above | ignored by real hardware, which is why the Super Sega extensions live there |

---

## 4. Colour

Colours are 12-bit (4 bits each of red, green, blue), the Game Gear format, stored as `0000BBBB GGGGRRRR`. There are two ways to write them:

| Write path | Bytes per colour | How |
|---|---|---|
| Legacy (Master System) | 1 | a 6-bit `BBGGRR` byte; each 2-bit channel is promoted to 4 bits (×5) |
| Native (Game Gear, and Super Sega with Feature Enable A bit 0) | 2 | byte-addressed: a write to an even CRAM address is held in a latch; the write to the next odd address stores both bytes as one entry (entry = address ÷ 2) |

The Game Gear uses the native scheme over 64 bytes (32 entries). With extended CRAM on (256 entries) the native scheme covers 512 bytes.

Sixteen *palette-written* flags let an unwritten palette fall back to palette (index AND 1), so legacy software sees the two palettes it expects.

---

## 5. Sprites

64 sprites; 8 per line as stock, 16 per line with Feature Enable A bit 4. Sizes 8×8, 8×16 and 16×16, each optionally magnified to double size. When sprites overlap, the lowest-numbered sprite is drawn on top.

A sprite whose Y coordinate is *Y* starts on line *Y* + 1. When *Y* + 1 is between 241 and 256 it starts at line *Y* + 1 − 256 instead — above the top of the screen — so a sprite at Y = `$F8` shows its lower rows on the first lines.

The Extended Sprite Attribute Table (ESAT, 2 bytes per sprite) adds per-sprite flip, priority, size, magnification, early clock (32 pixels left) and palette. Per-sprite collision writes result bitmaps to a base set in bank1 R6.

---

## 6. Input

### Controller ports

| Port | Bits |
|---|---|
| `$DC` | port A up, down, left, right, TL (button 1), TR (button 2); port B up, down |
| `$DD` | port B left, right, TL, TR; Reset button; CONT; port A TH; port B TH |

Reset reads 1 when the button is absent. CONT reads 1 on 8-bit hardware and 0 on a Mega Drive. Super Sega uses Mega Drive 3-button pads, multiplexed by the TH line: TH high gives Up Down Left Right B C, TH low gives Up Down 0 0 A Start.

### Port `$3F` — I/O control

| Bits | Function |
|---|---|
| 7–4 | output levels: 7 port B TH, 6 port B TR, 5 port A TH, 4 port A TR |
| 3–0 | direction, 1 = input, 0 = output: 3 port B TH, 2 port B TR, 1 port A TH, 0 port A TR |

Reset value `$FF`: all inputs, with the level bits 7–4 set. A pin set as an output reads back the level written: TR on `$DC` bit 5 (port A) and `$DD` bit 3 (port B); TH on `$DD` bits 6 and 7 — on an export machine. A Japanese machine always reads 0 on TH; this difference is how software detects the region.

### Game Gear differences

Start is on port `$00` (bit 7, 0 = pressed; bit 6 is the region, 1 = export; bits 5–0 read 0). It is decoded in Game Gear **and Super Sega** modes. Above `$C0` the Game Gear answers only `$C0`/`$DC` and `$C1`/`$DD`; on `$DD`, bits 7–6 read back `$3F` bits 7–6.

### SK-1100 keyboard

The SC-3000's 64-key keyboard, read through an 8255 PPI (programmable peripheral interface). Always live in SG-1000 (with the keyboard attached), SC-3000 and SF-7000 modes; on Super Sega it is enabled by Feature Enable C bit 5.

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
| SN76489 PSG (3 tones + noise) | `$7E`/`$7F` write | stereo panning on `$06` (Game Gear and Super Sega modes) |
| YM2413 FM | `$F0` register, `$F1` data, `$F2` control | the FM unit is always fitted |
| PCM FIFO (64 bytes) | `$07` data, `$08` control | Super Sega |
| Two wavetable voices | `$11`–`$15` | Super Sega |

The register layouts of PCM control (`$08` write) and the wavetable are not written down yet (open question Q16).

**PSG details.** Tone counters run at the CPU clock ÷ 16 and flip their output on reaching zero; a period of 0 behaves as 1. The noise counter (rate `$10`, `$20`, `$40`, or tone 2's period) flips a flip-flop, and the 16-bit noise shift register advances on its rising edge — once per two counter periods. White noise taps bits 0 and 3; writing the noise register resets the shift register to `$8000`. Volume is attenuation in 2 dB steps; 15 is silent.

**`$F2` (FM control).** Writes select the mute/enable state in bits 1–0. Reads return bits 1–0 of the last value written (bits 7–5 carry a sync counter on a Japanese Master System; Super Sega returns 0 there). Japanese software disables the I/O chip (`$3E` bit 2) before reading `$F2`, so `$F2` must answer even then — that is how FM detection works.

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
| Super Sega | Master System map plus the extensions |

### Cartridge mappers

| Family | Registers |
|---|---|
| Sega | `$FFFC` RAM/misc, `$FFFD`–`$FFFF` bank for slots 0–2. Reset `$00`, `$00`, `$01`, `$02`. The first 1 KB of slot 0 never banks, keeping the interrupt vectors |
| Codemasters | exactly `$0000`, `$4000`, `$8000`. Power-on banks 0, 1, 0. No vector protection. Bit 7 written to `$4000` maps 8 KB of cartridge RAM at `$A000` |
| Korean | exactly `$A000` selects slot 2; slots 0 and 1 fixed to banks 0 and 1 |
| MSX / Nemesis (Korean MSX ports) | `$0000`–`$0003` select 8 KB banks: 0 → `$8000`, 1 → `$A000`, 2 → `$4000`, 3 → `$6000`. The MSX variant fixes the first 16 KB; the Nemesis variant (last 8 KB bank fixed at `$0000`) is not implemented yet in the emulator or the Pocket core |

Only a Sega-mapper cartridge has hardware at `$FFFC`–`$FFFF`; on the other families those addresses are plain work RAM.

**v2 error:** the Codemasters and Korean registers were said to respond to any address in their slot. Gearsystem and MAME decode the exact address, every known title writes there, and with any-address decoding a write into Codemasters cartridge RAM would also have switched banks.

The Sega mapper's 8-bit bank registers reach 4 MB; the slot is specified for 8 MB, which needs a ninth bank bit (open question Q2). The cartridge-RAM size the machine guarantees is open (Q3).

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

### Storage

32 KB save card: 16 directory slots, 112 sparse 256-byte pages, per-game profiles with their own icons. Cartridge save RAM is snapshotted before a card profile loads, and shutdown flushes the card before restoring the cartridge.

Mods reach real hardware as BPS patches, applied by computer mode while it writes a blank card. The console plays mods; making them is an emulator tool.

---

## 9. DMA Engine and Math Unit

DMA on `$F4`–`$FA`: ROM or RAM to VRAM, VRAM to VRAM, and fill. Its register layout is not written down yet (open question Q16).

| Math port | Function |
|---|---|
| `$0C` | operand A |
| `$0D` | operand B |
| `$0E` | write: bit 0 = 0 multiply, 1 divide; read: 0 (operation complete) |
| `$0F` | result low |
| `$10` | result high |

Multiply is A × B, unsigned 16-bit. **Divide is under-specified** (open question Q7): the emulator computes `((A << 8) | B) / B`, almost certainly not the intent. The proposal on the table is A ÷ B with the quotient in `$0F`, the remainder in `$10`, and divide-by-zero returning `$FF`/`$00`.

---

## 10. Register Map

The VDP register-write command byte is `10bbnnnn`. On stock hardware bits 5–4 are ignored. Super Sega uses them to select one of four register banks — but only when bank 0 register 15 bit 5 (**XRB**, extended register banks) is set. XRB is clear at reset and in all legacy software, so bits 5–4 are discarded exactly as on real silicon. While XRB is clear the bank 1–3 registers also have no effect: they keep their values, but the features they switch on (everything in Feature Enable B and C) are off.

### Bank 0

| Reg | Function |
|---|---|
| 0–10 | stock VDP registers, including the mode bits M1–M4 |
| 11 | line-scroll (horizontal) table base |
| 12 | Extended Sprite Attribute Table base |
| 13 | window X split |
| 14 | window Y split; bit 7 selects side |
| 15 | **Feature Enable A** |

**Feature Enable A** — bit 0 native 12-bit CRAM · bit 1 line-scroll horizontal · bit 2 window layer · bit 3 ESAT · bit 4 16 sprites per line · bit 5 XRB · bit 6 turbo

Registers 11–15 take effect only in Super Sega mode; in the other modes they are ignored, as on the stock VDP.

### Bank 1

| Reg | Function |
|---|---|
| 0 | window tilemap base |
| 1 | line vertical-offset table base |
| 2 | **Feature Enable B** |
| 3 | VRAM bank for CPU access |
| 4 | render bank assignment |
| 5 | sprite palette base |
| 6 | collision result base |
| 7 | **Feature Enable C** |
| 8 | text window pattern base |
| 9 | text window colours |

**Feature Enable B** — bit 0 line vertical offset · bit 1 extended CRAM · bit 2 16×16 sprites · bit 3 per-sprite collision · bit 4 VRAM expansion · bits 7–6 display height (00 from the mode bits, 01 224 lines, 10 240 lines, 11 reserved, giving 192 lines; a 224/240 selection by the mode bits takes precedence)

**Feature Enable C** — bit 0 legacy modes draw from CRAM · bit 1 legacy sprite limit raised · bit 2 text window · bit 3 unique-cell mode (1024 tiles, so every screen cell can have its own; needs VRAM expansion) · bit 4 ESAT 2-byte (see open question Q13) · bit 5 SC-3000 keyboard

Bank 2 unallocated; bank 3 reserved.

---

## 11. I/O Port Map

| Range | Function |
|---|---|
| `$00` | Game Gear Start / region (Game Gear and Super Sega modes) |
| `$01`–`$05` | Game Gear serial (EXT link) registers (Game Gear and Super Sega modes) |
| `$06` | PSG stereo panning (write-only) |
| `$07`–`$08` | PCM FIFO data / control |
| `$09` | slot source select |
| `$0A` | work RAM bank |
| `$0B` | extended card bank |
| `$0C`–`$10` | math unit |
| `$11`–`$15` | wavetable audio |
| `$16` | multitap detection (reads `$81`: pad found, detection complete) |
| `$3E` | memory enables (write) |
| `$3F` | I/O control (write) |
| `$7E`–`$7F` | V / H counters (read); PSG (write) |
| `$BE`–`$BF` | VDP data / control |
| `$C0`–`$FF` | controllers `$DC`/`$DD`, mirrored on every even/odd port except the ranges below; SK-1100 PPI at `$DC`–`$DF` (mirrored through `$C0`–`$DF`) when the keyboard is live |
| `$E0`–`$E7` | SF-7000: floppy controller and second PPI |
| `$F0`–`$F2` | YM2413 FM (Master System and Super Sega modes; elsewhere these read as the controller mirror, or `$FF` on the Game Gear) |
| `$F3` | turbo step |
| `$F4`–`$FA` | DMA engine |
| `$FB` | debug unit control |
| `$FC`–`$FD` | SDSC debug console |
| `$FE`–`$FF` | watchpoint register select / data |

On the Master System every even port in `$00`–`$3E` acts as `$3E` and every odd one as `$3F` (mirrors). On every stock machine the PSG is written at any port in `$40`–`$7F` and the VDP answers across `$80`–`$BF` (even ports data, odd ports control); on the Master System and Game Gear the V counter reads at every even port and the H counter at every odd port in `$40`–`$7F`. The SG-1000, SC-3000 and SF-7000 have no `$3E`/`$3F` registers: in those modes writes to `$00`–`$3F` do nothing. The Game Gear decodes `$00`–`$06` separately, and Super Sega extends that to `$16`. Writes to `$07`–`$16`, like writes to VDP registers 11–15 (§10), take effect only in Super Sega mode; in every other mode they do what they do on the stock machine.

**Reads.** `$00`–`$3F` are write-only on the Master System and read `$FF`; on the Game Gear and Super Sega every port there that is not a register listed above also reads `$FF`. In Super Sega mode, `$07`–`$16` and `$F0`–`$FF` are fully decoded: unreadable ports return `$FF`, never the controller mirror. In the other modes `$FB`–`$FF` read as on the stock machine — the controller mirror, or `$FF` on the Game Gear — because stock software may read its pads there (§13).

**`$3E` bit 2** (I/O chip disable) turns off only the controller decode across `$C0`–`$FF`, and only on the Master System and Super Sega. It has no effect on the Game Gear, and does not affect `$F2` or Super Sega's `$F0`–`$FF`.

The turbo and debug ports sit above `$F0`, outside the `$3E`/`$3F` mirror range, so no old title writing a memory- or I/O-control mirror can reach them; writes to `$F0`–`$FF` do nothing on the stock machines. Whether `$06`–`$16` should move above `$F0` too is open question Q1.

---

## 12. FPGA Partition

A real 315-5535 ASIC draws the base picture; the FPGA owns everything the ASIC has no register for.

**ASIC (5 jobs):** Mode 4 and TMS background · sprites 1–8 per line · CRAM palettes 0–1 · PSG and stereo panning · line and frame interrupts.

**FPGA (27 jobs):** VDP control-port gating · bus synchroniser · clock generation and turbo · cartridge wait states · shadow VDP state · sprites 9–16 · extended sprite attributes · per-sprite collision · line H offset table · line V offset table · window layer · text window · unique-cell mode · extended CRAM · DMA engine · math unit · PCM and wavetable · mapper and slot arbitration · SK-1100 keyboard · mouse and trackball · floppy controller · debug unit · video compositing and output · overlay dialogs · power sequencing · non-volatile storage · player-sprite correlation.

**Control-port gating is the load-bearing job.** A write to register bank 1 or above must be absorbed by the FPGA; the ASIC would otherwise take it as a write to its own register of that number.

**Overlays.** Sitting between the CPU and the VDP, the FPGA can hold the Z80 and draw over anything running, including a cartridge that knows nothing about Super Sega. That is how save dialogs, standby, the debug overlay and the switch between game and computer mode work.

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

**Which modes.** Writes reach the debug unit in every machine mode, since its purpose is inspecting stock software (stock hardware ignores writes to `$FB`–`$FF`). Reads answer from the debug unit only in Super Sega mode: `$FB` returns the control value as written; `$FC` and `$FD` return a status byte (bit 7 a debug host is attached, bit 6 set, bit 0 the trace buffer is full); `$FE` and `$FF` return `$FF`. In the stock modes these ports read as the stock machine reads them (§11).

---

## 14. Software Identification

The `TMR SEGA` header is checked at `$7FF0`, `$3FF0` and `$1FF0`, in that order (8 KB and 16 KB ROMs carry it lower down).

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
| **8** | **Super Sega** |

An export Master System BIOS rejects any cartridge whose region is not 4, so region-8 software will not boot on a stock export console. How one ROM could detect a Super Sega at run time and work on both is open (Q8).

---

## 15. Enhancement Layer

Optional boosts for unmodified software (the Auto-Enhancement Layer, AEL), applied by intercepting the fixed hardware interfaces rather than patching the ROM. **All are off at power-on**, so the machine behaves as stock hardware until the user switches one on. On the console they live in the boot menu, in the emulator in its AEL panel, and on the Analogue Pocket in the core settings menu.

Explicit software intent always wins: every boost acts only on software running in the stock modes (SG-1000, SC-3000, Master System, Game Gear). Super Sega software sets these features itself and reads C as a button of its own. Pseudo-stereo also stops as soon as software writes `$06`. The TMS-colour boost is the one exception today (Q11).

| Boost | Effect |
|---|---|
| Sprite limit | 16 sprites per line instead of 8 (legacy modes 4 → 8/16) — removes most flicker |
| Stock overflow flag | with the raised limit, status bit 6 is still set by a ninth sprite, for software that reads it as logic |
| Start = Pause | Start on the pad raises the Pause NMI (Master System, SG-1000, SC-3000 modes) |
| Turbo | a turbo step for stock software; Super Sega software sets its own through `$F3` |
| VRAM speed-up | no VDP access wait while turbo is active |
| Auto-fire | while C is held, button 2 repeats (toggles every two frames: 15 Hz); releasing C leaves button 2 as the pad has it |
| Pseudo-stereo | until software writes `$06`: tone 0 left, tone 1 right, tone 2 and noise centre |
| Game Gear uncrop | show the full 256 × 192 picture the Game Gear VDP draws, instead of the 160 × 144 window |
| True TMS colours | SG-1000/SC-3000 picture modes use the TMS9918's own colours instead of the Master System's approximation |

The FM unit being present is inherent to the machine, not a switch. Two items of the enhancement-layer design have no switch of their own: *VRAM write reliability* (the emulator and the Pocket core never drop a VDP write, so it is always in effect) and *region speed correction*, which is the machine's 50/60 Hz video setting. Tiers, risks and the per-game override database are in `SuperSega_AutoEnhancement_Layer.md`, an earlier design document that is not in this repository (written against profile v5; where it differs, this section and profile v7 apply).

---

## 16. Stock Behaviour and Timing

Behaviour of the original parts that every implementation must reproduce. These are not Super Sega additions; they are written down because the emulator had them wrong until October 2026 and the Pocket core is checked against them.

### CPU

- An interrupt taken during HALT returns to the instruction after the HALT.
- After EI, interrupts are accepted only once the next instruction has run.
- Maskable interrupts are sampled between instructions.
- DD/FD prefixes add a displacement byte only to instructions that use (HL); (IX+d) costs 8 T-states more than (HL), `LD (IX+d),n` 5 more. DDCB: BIT 20 T-states, the rest 23. A prefix followed by another prefix costs 4.

### VDP

- **Scrolling.** Screen x = map x + R8: the picture moves right as R8 grows. R8 is latched once per line, before the line is drawn; R0 bit 6 exempts the top two rows. R9 (vertical) is latched once per frame.
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
| Q1 | Ports `$06`–`$16` sit in the `$3E`/`$3F` mirror range. They act as registers only in Super Sega mode (`$06` also in Game Gear mode, §11), so stock software in its own mode is unaffected. The risk is old code run in Super Sega mode that writes a mirror address in `$06`–`$16`: a title retagged to region 8 (§14), a converted title, or a stock cartridge started in Super Sega mode (one proposed answer to Q8 is a boot-menu option that does this). Move them above `$F0`? | open |
| Q2 | Maximum ROM size and the mapper register layout above 4 MB | open |
| Q3 | Cartridge save-RAM size the machine guarantees (the 315-5235 maps 2 × 16 KB; the emulator models 2 × 8 KB) | open |
| Q4 | ESAT format | resolved in v6: 2 bytes per sprite |
| Q5 | Unique-cell mode and 32 KB VRAM | resolved in v6: coupled |
| Q6 | Turbo default | resolved: off at reset; a title turns it on itself (Feature Enable A bit 6, then `$F3`). The enhancement layer's turbo is for unmodified software only |
| Q7 | Math unit divide | open (§9) |
| Q8 | Run-time detection of a Super Sega by a single ROM | open (§14) |
| Q9 | Work RAM bank readback at `$0A` | open |
| Q10 | Reverting third-party GG-to-SMS patches | an emulator workflow, not a machine question |
| Q11 | Should the true-TMS-colours boost default off like every other boost, and act only in the stock modes? The emulator defaults it on and also applies it to Super Sega software's legacy modes | open |
| Q12 | One cartridge wait state at 200 % turbo: the emulator applies it; the Pocket core does not yet | open |
| Q13 | Feature Enable C bit 4 (ESAT 2-byte) contradicts ESAT being 2 bytes per sprite (Q4); the emulator still has a 1-byte layout when the bit is clear. Retire the bit or document the 1-byte layout | open |
| Q14 | `$08` reports a 64-byte FIFO's fill in three bits; the emulator returns the fill modulo 8, so a full FIFO reads as empty. Proposal: bytes queued ÷ 8, saturating at 7 | open |
| Q15 | Line interrupts in the TMS9918 modes. The machine profile lists them as a Super Sega enhancement for SG-1000-style software (line interrupts are a Master System addition) but defines no bit that enables them. As stock the TMS modes raise none, and both implementations follow that in the stock modes; in Super Sega mode both raise them in the TMS modes whenever R0 bit 4 is set (the Pocket core does not draw the TMS modes yet). Should the line counter run in the TMS modes on Super Sega, and what enables it? | open |
| Q16 | The register layouts of the DMA engine (`$F4`–`$FA`), PCM control (`$08` write), the wavetable (`$11`–`$15`), slot select (`$09`) the VDP base registers (bank 0 R11 and R12, bank 1 R0, R1, R5 and R6) and the window split (bank 0 R13 and R14) are defined today only by the emulator's code (the Pocket core already follows it for `$09`). They need writing into this document and the profile, and checking, before the Pocket core implements them | open |
| Q17 | Feature Enable B bits 7–6 select 224 or 240 lines for Super Sega software, but this document defines the heights only for Mode 4 (§3). Both implementations also apply them while a TMS9918 mode is selected. Should the machine apply them in the TMS modes, and if so, what do those modes draw below line 192? | open |

Two risks from v2 remain as evidence rather than proof: six commercial titles were checked and none write VDP registers 11–15 (where Feature Enable A lives), which matters for old code run in Super Sega mode, the only mode in which those registers act (§10); and the keyboard's active-low polarity rests on a single source that contradicts itself.

---

## 18. Capability Summary

| Against | Super Sega provides |
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
| Multitap detection (`$16`) | yes | yes |
| Multitap protocols (Sega Team Player, EA 4 Way Play) | not yet | not yet |
| Game Gear serial registers (`$01`–`$05`) | yes (they hold what is written) | yes (the same) |
| Link cable | not yet | not yet |
| Super Sega register banks, native/extended CRAM, 16 sprites per line, turbo and bus synchroniser | yes | yes |
| Work RAM banking (`$0A`) | yes | yes |
| Math unit (`$0C`–`$10`) | yes; divide as §9 describes, until Q7 is decided | the same |
| Card slot: slot select (`$09`) and card bank (`$0B`) | yes | registers and memory decode only: the Pocket platform loads no card, so the slot is always empty |
| VRAM expansion | yes | CPU access only (the render bank, bank1 R4, is not implemented) |
| ESAT, 16×16 and magnified sprites, window/text layers, line tables, unique-cell | yes | registers only, not drawn |
| TMS9918 modes (SG-1000, SC-3000) | yes | not yet |
| YM2413 FM | yes (approximate synthesis) | not yet; the core reports no FM unit so software uses its PSG music |
| PCM, wavetable, DMA engine | yes | not yet |
| SF-7000, floppy, debug unit | yes | not yet |
| PAL CPU clock (3.546893 MHz, §1) | not yet: the CPU runs at the NTSC clock in PAL too, so a PAL frame lasts 1/50.16 s of machine time instead of 1/49.70 s | the same |
| Enhancement layer | all | all except true TMS colours and the legacy-mode sprite limit, which come with the TMS9918 modes |

**Verification.** Batman Returns (Europe) on the Master System in PAL, frames 30, 60, 120, 200, 500, 900 and 1500, and Batman Returns (World) on the Game Gear, frames 200, 500, 900 and 1500: the emulator and the Pocket core (in simulation) both match Gearsystem; Game Gear frames match within Gearsystem's colour rounding (it expands the channel value 5 to 86, not 85). VDP test ROMs at 192, 224 and 240 lines and a Super Sega feature ROM (register banks, native and extended CRAM, Feature Enable B height, 16 sprites, 200 % turbo with the bus synchroniser) give the same pictures on the emulator and the core. An I/O test ROM reads 18 ports in the Master System, Game Gear and Super Sega modes and gets the same values on both, apart from the two differences the implementations are meant to have: the core has no FM unit yet (`$F2`), and no debug host is attached to it (`$FC`/`$FD` bit 7). Nothing has run on a Pocket yet.
