# Super Sega — v7 Reconciliation: Machine vs Emulator

October 2026. Companion to `super_sega_machine_v7.json` and `SuperSega_Technical_Reference_v3.md`. Paths below are relative to the top of the repository (`machine/`, `emulator/`, `pocket-core/`).

**Terms used below.** *Feature Enable A, B, C* are the three registers through which new software opts into Super Sega features (VDP bank 0 R15, bank 1 R2 and R7; "bank1 R3" is register 3 of the extension register bank 1). The *enhancement layer* (AEL) is the set of optional boosts for unmodified software, all off by default. The *bus synchroniser* holds the CPU when turbo runs it faster than the video chip can accept data. The Technical Reference explains each in full.

## 1. The boundary

Work on Super Sega has happened in several chats: the machine design itself, the Super Mario Land DX port, the Golden Axe conversion, the ROM hack maker, the MSX porting tools. Each touched either the **machine** or the **emulator**, and sometimes both. This document sorts every change into one or the other.

**The machine** is the console: its chips, the jobs its FPGA does, the behaviour its BIOS exposes. It is defined by two documents, the machine profile (`super_sega_machine_v7.json`) and the Technical Reference. The machine has three implementations:

| Implementation | What it is |
|---|---|
| The physical console | The hardware design in the earlier chats (315-5535 ASIC plus FPGA) |
| The emulator's machine model | The part of the HTML5 emulator that behaves like the console |
| The Analogue Pocket core | The new RTL in `pocket-core/rtl` plus the Pocket wrapper in `pocket-core/pocket` |

**The emulator** is an application. Besides its machine model it has tools that no console has and that never go into the Pocket core or the machine documents:

| Emulator-only feature | Notes |
|---|---|
| ROM hack maker and its plugins | Making mods. Playing a BPS-patched mod is a machine feature (computer mode applies the patch while writing a card); making one is not |
| MSX porting tools and the MSX2 Lab | MSX support is porting tooling, not a Super Sega feature |
| AY-3-8910 → PSG translation | Part of the porting tools (moved out of the machine's audio section in Technical Reference v3) |
| Lab composite and merge report | Analysis views |
| Debug tab, self-test, FPGA-job counters | The app's own diagnostics (distinct from the machine's debug unit at $FB–$FF, which *is* a machine feature) |
| Display filters | Presentation |
| FM dual-run capture | Analysis tool |
| Save states | The console has none; the Pocket core has none in this milestone |

**Rule for disagreements.** Where the emulator and the machine documents disagree, the documents win and the emulator is fixed — unless the documents themselves are wrong about stock hardware, in which case both are corrected together and the change is recorded in `v7_changes`.

## 2. Machine changes in v7

All are recorded in the profile's `v7_changes` (20 entries). The ones that change behaviour:

| Change | Source | Emulator | Pocket RTL |
|---|---|---|---|
| Port $00 decoded in Super Sega mode as well as Game Gear; bits 5–0 read 0 | Golden Axe plan | fixed | yes |
| Ports $01–$05 (GG serial) in GG and Super Sega modes | machine chats | fixed | yes |
| $3E bit 2 scope: controller decode only, not GG, not $F2 or Super Sega's $F0–$FF | SML DX port | fixed | yes |
| Super Sega $07–$16 and $F0–$FA read values | SML DX port | fixed | yes |
| Native 12-bit CRAM byte-latch write order; GG colours | SML DX port | fixed | yes |
| $F2 readback with the I/O chip disabled | SML DX port | fixed | yes |
| VRAM expansion: Feature Enable B bit 4 enables, bank1 R3 bit 0 selects | v6 internal inconsistency | — | CPU access only (render bank not implemented) |
| **Extra-height mode bits** (v6 error): M2 enables, M1 → 224, M3 → 240 | found while testing the RTL | fixed | yes |
| **Codemasters/Korean registers at exact addresses**; Codemasters banks 0,1,0 at power-on | Gearsystem/MAME cross-check | fixed | yes |
| 8255 PPI reset state, mode word clears port C, bit set/reset | cross-check | fixed | yes |
| Enhancement layer behaviour pinned down (pseudo-stereo panning, auto-fire rate), and every boost limited to software in the stock modes | Pocket core request | fixed; turbo for stock software and the VRAM speed-up added | yes |
| Debug unit port reads only in Super Sega mode; in the stock modes $FB–$FF read as on the stock machine | cross-check of the I/O map | fixed | yes (no debug unit yet; $FB reads back, no host attached) |
| FM detection latch only in Master System and Super Sega modes | review | fixed | yes (the core reports no FM until it has an FM core) |
| Stock-hardware behaviour (CPU, VDP, PSG, I/O) listed in `stock_behaviour` | SML DX port, Gearsystem | fixed | yes |

Open items are in the profile's `open_questions` (Q1–Q14). New in this round: **Q11**, whether the TMS-colour boost should default off like every other boost (the emulator defaults it on); **Q12**, the one-wait-state cartridge access at 200 % turbo (emulator has it, Pocket core does not yet); **Q13**, Feature Enable C bit 4 (ESAT 2-byte) contradicting the 2-byte ESAT decision; **Q14**, the PCM FIFO fill reading at `$08`, which cannot encode a 64-byte FIFO in three bits.

## 3. Emulator machine-model fixes

One consolidated patch, `emulator/fix_emulator_v7.py`, takes the original page to the fixed page in one step. Every edit is labelled **MODEL** (the emulator's model of the machine now does what the machine does) or **APP** (application only). Each anchor is checked before it is applied, in order, so a stale anchor stops the script instead of silently missing an edit. 108 edits: 75 MODEL, 33 APP.

### CPU (Z80)
- An interrupt taken in HALT returned to the second byte of the instruction after the HALT (the program counter was advanced twice); it now returns to the instruction after the HALT.
- EI took effect immediately; interrupts are now accepted only after the following instruction.
- DD/FD prefixes read a displacement byte for opcodes that have none (`LD IXH,n` ate its operand); (IX+d) timings corrected; DDCB timings 20/23; a prefix followed by a prefix costs 4.
- T-states added while an ED/CB instruction ran (bus-synchroniser holds, wait states) were lost because `tc += f()` read `tc` before `f` ran.

### VDP
- Horizontal scroll moved the background the wrong way; scroll registers are latched per line (H) and per frame (V).
- Sprite Y wrap follows Gearsystem/MAME (Y+1 of 241–256 starts above the top).
- V counter jump tables and H counter; frame interrupt flag kept until read; interrupts taken between instructions, line overrun carried into the next line.
- Game Gear CRAM (and Super Sega native CRAM) are byte-latched; every GG title had wrong colours.
- Overlapping sprites: the lowest-numbered sprite is now on top.
- **Extra-height modes:** the mode bits were swapped (M2/M3), the frame buffer held only 192 lines, and the 32×32 name table at `(R2 & $0C) << 10 | $700` was not used.

### Audio
- PSG noise ran an octave high (the shift register advanced on every counter reload instead of every other).
- PSG volume was linear; it is now 2 dB per step.
- Enhancement-layer pseudo-stereo wrote $99, silencing tones 1 and 2; it also applied to Super Sega software.
- The FM detection latch at `$F2` answered in Game Gear and SC-3000 modes; it now answers only in Master System and Super Sega modes.

### I/O and memory
- Low-port reads ($00–$3F) answered from the controller mirror; they return $FF except for decoded registers.
- SG-1000, SC-3000 and SF-7000 writes to $00–$06 reached the Game Gear registers; they now do nothing.
- TR pins configured as outputs read back their level; Game Gear decodes only $C0/$DC and $C1/$DD above $C0.
- SK-1100 keyboard: ghosting closure stopped after three passes; the PPI selected row 0 at reset (SG-1000 pads unreadable); mode words and bit set/reset now behave as an 8255.
- Codemasters and Korean mapper register decode, Codemasters power-on banks.
- Bus synchroniser at turbo: the hold is CPU time and covers VDP reads as well as writes; cartridge wait states lengthen the access.
- DMA from RAM copied from an array nothing wrote.
- The sprite-limit and overflow-flag boosts also applied to Super Sega software, overriding its own Feature Enable bits; they are now limited to stock software.
- Auto-fire overwrote the pad state, so releasing C mid-toggle left button 2 held; it acted on Super Sega software, whose C is a button of its own; and it did not reach SG-1000/SC-3000 pads read through the keyboard PPI.
- The debug unit answered reads at $FB–$FD in every mode, where a stock machine returns the controller mirror; it now answers only in Super Sega mode.

### Enhancement layer
- The turbo boost for stock software and the VRAM speed-up boost were missing. The turbo selector set the same step as software's `$F3` write and acted only in Super Sega mode. The selector now sets the enhancement layer's step, which acts on stock software; Super Sega software keeps its own `$F3` step. The VRAM speed-up switch removes the bus synchroniser's wait for stock software while a turbo step is active.

### Application-only fixes
Save states and the FM dual-run snapshot now hold work RAM and the new timing state; RAM search/freeze read the work RAM the CPU sees; three self-test checks were wrong (sprite check read the wrong line, height check used the swapped bits, keyboard checks skipped the PPI mode word). The turbo selector, the budget panel and the other turbo displays show the effective step; per-game settings keep the enhancement layer's step and no longer restore the `$F3` step, which software sets.

## 4. How the fixes were checked

| Check | Result |
|---|---|
| Behavioural probes (`emulator/tools/probes_v7.js`) for 41 behaviours, each citing its hardware source. The probes are named after the patch's MODEL fixes (M1–M37 in `emulator/fix_emulator_v7.py`); four fixes have no probe of their own. M11 (Game Gear `$01`–`$06` power-on values) shows only in the I/O test ROM comparison below, in Game Gear mode. M13 (cartridge wait states lengthen the access) is exercised by no check: headless runs use the emulator's default ROM access, a copy in fast RAM, and even with its other setting, cartridge timing, a wait state arises only at the 200 % turbo step. M15 (SG-1000/SC-3000/SF-7000 writes to `$00`–`$06` do nothing) is exercised by no check. M17 (T-states lost during ED/CB instructions) is caught by the bus-synchroniser probe (M12) | 41 of 41 pass on the fixed page, 0 of 41 on the original |
| The page's own self-test, run headless | 29 of 29 |
| Gearsystem as an independent oracle: Batman Returns SMS (PAL) frames 30, 60, 120, 200, 500, 900, 1500 and GG frames 200, 500, 900, 1500 | identical (GG within Gearsystem's colour rounding: it expands channel value 5 to 86, not 85) |
| `emulator/tools/profile_crosscheck.py` (an earlier chat's check that the emulator implements what the profile claims; its height check updated to the v7 rule) | 47 of 47 claims on the fixed page; the original page fails the height rule |
| New VDP test ROMs (`pocket-core/tools/mk_testrom.py`): 192/224/240 lines, scrolling, sprites at the bottom edge, $D0 terminator, Y wrap | emulator = Gearsystem (192, 224) = RTL (192, 224, 240) |
| I/O test ROM (`pocket-core/roms/ports.sms`, decoded by `pocket-core/tools/read_ports_ppm.py`): 18 ports read in Master System, Game Gear and Super Sega modes, idle and with button 1 held | emulator = RTL, except `$F2` (the core has no FM unit yet) and `$FC`/`$FD` bit 7 in Super Sega mode (the emulator is its own debug host; the core has none) |
| SC-3000 BASIC Level 2 / Level 3 / Home BASIC: typing reaches the screen; the SF-7000 IPL boots and polls the floppy controller (`emulator/tools/sc_typing.js`) | pass on the fixed page |

## 5. Known differences between the emulator and the Pocket core

- **Event timing.** The emulator resolves VDP events at line boundaries and performs I/O at the start of an instruction. The Pocket core follows Gearsystem's per-cycle event table (status flags, line interrupt, scroll latch at fixed cycle offsets; I/O 10 T-states into IN/OUT). Pictures match; mid-line raster tricks can differ. A refactor of the emulator's frame loop is the follow-up.
- **H counter.** The emulator returns a live count that starts at 0 at its line start; the machine latches the counter when TH rises and starts the line at `$E9` (Gearsystem's model, which the Pocket core follows). Light-gun software can therefore read different values on the two.
- **TMS9918 modes** render in the emulator but not yet in the Pocket core.
- **Not in the Pocket core yet** (Technical Reference §19): the FM unit, PCM and wavetable sound, the DMA engine, the SF-7000 and its floppy controller, the debug unit, and the drawing side of ESAT, 16×16 and magnified sprites, the window and text layers, line tables and unique-cell mode (their registers are there).
- The TMS-colour boost default (Q11) is left as it is until decided.

## 6. Project documents checked against v7

The four documents that were already in the claude.ai project were read against profile v7 and this reconciliation. The two with machine statements to correct were updated, and are in `project-docs/`; the other two (the Super Mario Land DX port design and the Super Mario Bros. Deluxe options) are not in this repository.

| Document | Result |
|---|---|
| Golden Axe conversion plan | Written against the v5 machine block, and updated: Super Sega decodes `$00`–`$16` as registers, not `$06`–`$0A`, and no controller mirror answers in `$F0`–`$FF` (not `$F0`–`$FA`), so both ranges of the port-decode audit widen; native 12-bit colour needs Feature Enable A bit 0; its open machine questions now carry v7's answers (ROM size up to 4 MB with the stock bank registers, ESAT format, unique-cell coupling, turbo default, reverting earlier patches) |
| ROM hack maker specification | Its machine statements hold. Added: the Pocket core does not have the FM unit yet (it matters for the Aerial Assault FM idea); which implementations run each target; v7's position on open decision 7 (mapper limits) |
| Super Mario Land DX port design | No conflict. Its second-emulator validator (`ssemu.js`) needs the CPU and VDP fixes it lists, and those are in the v7 patch (M1–M9; the document describes the HALT fault correctly). Its figures were produced on an earlier fixed page, and v7 changes more (sprite priority, PSG, Game Gear colour, low-port reads), so its lockstep runs are worth repeating on the v7 page |
| Super Mario Bros. Deluxe options | No machine statements |

The enhancement-layer design (`SuperSega_AutoEnhancement_Layer.md`, from an earlier chat, written against v5, not in this repository) lists two items that have no switch in v7: VRAM write reliability, which both implementations always provide, and region speed correction, which is the 50/60 Hz video setting. The Technical Reference (§15) and the profile now say so.
