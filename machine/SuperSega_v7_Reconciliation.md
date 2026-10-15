# Super Sega — v7 Reconciliation: Machine vs Emulator

October 2026. Companion to `super_sega_machine_v7.json` and `SuperSega_Technical_Reference_v3.md`. Paths below are relative to the top of the repository (`machine/`, `emulator/`, `pocket-core/`). The *October 2026 package* is the set of files (these documents, the emulator and the Pocket core) this repository was first imported from; §7 lists what has changed since.

**Terms used below.** *Feature Enable A, B, C* are the three registers through which new software opts into Super Sega features (VDP bank 0 R15, bank 1 R2 and R7; "bank1 R3" is register 3 of the extension register bank 1). The *enhancement layer* (AEL) is the set of optional boosts for unmodified software, all off by default except True TMS colours. The *bus synchroniser* holds the CPU when turbo runs it faster than the video chip can accept data. The Technical Reference explains each in full.

## 1. The boundary

Work on Super Sega has happened in several chats: the machine design itself, the Super Mario Land DX port, the Golden Axe conversion, the ROM hack maker, the MSX porting tools. Each touched either the **machine** or the **emulator**, and sometimes both. This document sorts every change into one or the other.

**The machine** is the console: its chips, the jobs its FPGA does, the behaviour its BIOS exposes. It is defined by two documents, the machine profile (`super_sega_machine_v7.json`) and the Technical Reference. The machine has three implementations:

| Implementation | What it is |
|---|---|
| The physical console | The hardware design in the earlier chats (315-5535 ASIC plus FPGA) |
| The emulator's machine model | The part of the HTML5 emulator that behaves like the console |
| The Analogue Pocket core | The new RTL in `pocket-core/rtl` plus the Pocket wrapper in `pocket-core/pocket` |

**The emulator** is an application. Besides its machine model it has tools that no console has. They are not part of the machine, so they never go into the machine documents or the Pocket core's machine layer (`pocket-core/rtl/`; the core's other layer, `pocket-core/pocket/`, connects the machine to the Pocket):

| Emulator-only feature | Notes |
|---|---|
| ROM hack maker and its plugins | Making mods. Playing a BPS-patched mod is a machine feature (computer mode applies the patch while writing a card); making one is not |
| MSX porting tools and the MSX2 Lab | MSX support is porting tooling, not a Super Sega feature |
| AY-3-8910 → PSG translation | Part of the porting tools (moved out of the machine's audio section in Technical Reference v3) |
| Lab composite and merge report | Analysis views |
| Debug tab, self-test, FPGA-job counters | The app's own diagnostics (distinct from the machine's debug unit at $FB–$FF, which *is* a machine feature) |
| Display filters | Presentation |
| Sound Lab: PSG → FM and FM → PSG translation, channel layers, the mixer | Listening and porting tools; they can sound both chips whatever `$F2` selects (M46) |
| FM dual-run capture (in the Sound Lab) | Analysis tool |
| Save states | The console has none; the Pocket core has none in this milestone |

**Rule for disagreements.** Where the emulator and the machine documents disagree, the documents win and the emulator is fixed — unless the documents themselves are wrong about stock hardware, in which case both documents are corrected (and any implementation that followed them) and the change is recorded in `v7_changes`.

## 2. Machine changes in v7

All are recorded in the profile's `v7_changes` (20 entries in the package, 42 now; §7 lists the later changes). The ones that change behaviour:

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
| FM detection latch only in Master System and Super Sega modes | review | fixed | yes |
| Stock-hardware behaviour (CPU, VDP, PSG, I/O) listed in `stock_behaviour` | SML DX port, Gearsystem | fixed | yes |

Open items are in the profile's `open_questions` (Q1–Q14 in the package; Q15–Q21 were added since, §7). New in this round: **Q11**, whether the TMS-colour boost should default off like every other boost (the emulator defaults it on; since resolved, §7); **Q12**, the one-wait-state cartridge access at 200 % turbo (emulator has it, Pocket core does not yet); **Q13**, Feature Enable C bit 4 (ESAT 2-byte) contradicting the 2-byte ESAT decision; **Q14**, the PCM FIFO fill reading at `$08`, which cannot encode a 64-byte FIFO in three bits.

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
- The FM detection latch at `$F2` answered in Game Gear, SC-3000 and SF-7000 modes; it now answers only in Master System and Super Sega modes.

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
| Behavioural probes (`emulator/tools/probes_v7.js`) for 41 behaviours, each citing its hardware source. The probes are named after the patch's MODEL fixes (M1–M37 in `emulator/fix_emulator_v7.py`); four fixes have no probe of their own. M11 (Game Gear `$01`–`$06` power-on values) shows only in the I/O test ROM comparison below, in Game Gear mode. M13 (cartridge wait states lengthen the access) is exercised by no check: headless runs use the emulator's default ROM access, a copy in fast RAM, and even with its other setting, cartridge timing, a wait state arises only at the 200 % turbo step. M15 (SG-1000/SC-3000/SF-7000 writes to `$00`–`$06` do nothing) is exercised by no check. M17 (T-states lost during ED/CB instructions) is caught by the bus-synchroniser probe (M12) | 41 of 41 pass on the fixed page, 0 of 41 on the original (twelve more since, M38–M49, §7; 53 of 53 pass) |
| The page's own self-test, run headless | 29 of 29 |
| Gearsystem as an independent oracle: Batman Returns SMS (PAL) frames 30, 60, 120, 200, 500, 900, 1500 and GG frames 200, 500, 900, 1500 | identical (GG within Gearsystem's colour rounding: it expands channel value 5 to 86, not 85) |
| `emulator/tools/profile_crosscheck.py` (an earlier chat's check that the emulator implements what the profile claims; its height check updated to the v7 rule) | 47 of 47 claims on the fixed page; the original page fails the height rule (the script has since been rewritten to read every value from the profile: §7) |
| New VDP test ROMs (`pocket-core/tools/mk_testrom.py`): 192/224/240 lines, scrolling, sprites at the bottom edge, $D0 terminator, Y wrap | emulator = Gearsystem (192, 224) = RTL (192, 224, 240) |
| I/O test ROM (`pocket-core/roms/ports.sms`, decoded by `pocket-core/tools/read_ports_ppm.py`): 18 ports read in Master System, Game Gear and Super Sega modes, idle and with button 1 held | emulator = RTL, except `$FC`/`$FD` bit 7 in Super Sega mode (the emulator is its own debug host; the core has none). `$F2` differed too until the core had the FM unit |
| SC-3000 BASIC Level 2 / Level 3 / Home BASIC: typing reaches the screen; the SF-7000 IPL boots and polls the floppy controller (`emulator/tools/sc_typing.js`) | pass on the fixed page |

## 5. Known differences between the emulator and the Pocket core

- **Event timing.** The emulator resolves VDP events at line boundaries and performs I/O at the start of an instruction. The Pocket core follows Gearsystem's per-cycle event table (status flags, line interrupt, scroll latch at fixed cycle offsets; I/O 10 T-states into IN/OUT). Pictures match; mid-line raster tricks can differ. A refactor of the emulator's frame loop is the follow-up.
- **H counter.** The emulator returns a live count that starts at 0 at its line start; the machine latches the counter when TH rises and starts the line at `$E9` (Gearsystem's model, which the Pocket core follows). Light-gun software can therefore read different values on the two.
- **FM sound.** The emulator's FM synthesis is approximate (no rhythm instruments, no user instrument, no envelopes, linear volume steps; the built-in instruments only resemble the chip's), while the Pocket core's FM is IKAOPLL, which follows the YM2413 itself. The same music sounds different on the two.
- **Not in the Pocket core yet** (Technical Reference §19): PCM and wavetable sound, the DMA engine, the SF-7000 and its floppy controller, the debug unit, the mouse and trackball, a card in the card slot (the Pocket platform loads none), and the drawing side of ESAT, 16×16 and magnified sprites, the window and text layers, line tables and unique-cell mode (their registers are there).
- **Status bits 4–0** read 0 in the emulator and `$1F` in the Pocket core (open question Q18).

## 6. Project documents checked against v7

The four documents that were already in the claude.ai project were read against profile v7 and this reconciliation. The two with machine statements to correct were updated, and are in `project-docs/`; the other two (the Super Mario Land DX port design and the Super Mario Bros. Deluxe options) are not in this repository.

| Document | Result |
|---|---|
| Golden Axe conversion plan | Written against the v5 machine block, and updated: Super Sega decodes `$00`–`$16` as registers, not `$06`–`$0A`, and no controller mirror answers in `$F0`–`$FF` (not `$F0`–`$FA`), so both ranges of the port-decode audit widen; native 12-bit colour needs Feature Enable A bit 0; its open machine questions now carry v7's answers (ROM size up to 4 MB with the stock bank registers, ESAT format, unique-cell coupling, turbo default, reverting earlier patches) |
| ROM hack maker specification | Its machine statements hold. Added: whether the Pocket core has the FM unit, which matters for the Aerial Assault FM idea (it has since been added); which implementations run each target; v7's position on open decision 7 (mapper limits) |
| Super Mario Land DX port design | No conflict. Its second-emulator validator (`ssemu.js`) needs the CPU and VDP fixes it lists, and those are in the v7 patch (M1–M9; the document describes the HALT fault correctly). Its figures were produced on an earlier fixed page, and v7 changes more (sprite priority, PSG, Game Gear colour, low-port reads), so its lockstep runs are worth repeating on the v7 page |
| Super Mario Bros. Deluxe options | No machine statements |

The enhancement-layer design (`SuperSega_AutoEnhancement_Layer.md`, from an earlier chat, written against v5, not in this repository) lists two items that have no switch in v7: VRAM write reliability, which both implementations always provide, and region speed correction, which is the 50/60 Hz video setting. The Technical Reference (§15) and the profile now say so.

## 7. Changes after the October 2026 package

The repository corrected the following after the package was imported; each machine change is also in `v7_changes`, marked "after the October 2026 package".

### Machine

1. SF-7000 PPI port C bit 2 is the floppy controller's TC signal, not the drive's: the profile now agrees with the Technical Reference and MAME.
2. The CPU state when software starts is defined: PC `$0000`, SP `$DFF0` (where the Master System BIOS leaves it), interrupts disabled, interrupt mode 0.
3. The profile's port map now matches the Technical Reference and both implementations: the PSG is written at `$7E` and `$7F`, and `$C0`–`$DF` is the controller mirror unless the SK-1100 keyboard is live.
4. Line interrupts in the TMS9918 modes are recorded as open question Q15; the profile statements that answered it now point there.
5. The cartridge wait state at 200 % turbo is now stated in the profile (`cpu.turbo.cartridge_wait`), as Q12 assumed.
6. Reset values are in both documents: `$3E` resets to `$A8` and `$3F` to `$FF`.
7. Q13 gives the ESAT history as the profile records it: 2 bytes per sprite since v5.
8. Technical Reference §19 has rows for the math unit, work RAM banking, the card slot, multitap, the Game Gear serial registers, mouse and trackball, the link cable and the PAL clock, and the Pocket design document's §2 matches (implementation status, not a machine change).
9. Save states are no longer listed as a missing Pocket core feature: they would belong to the Pocket platform layer, not the machine, and are not planned in this milestone (Pocket design document only).
10. The PAL CPU clock is defined as 3.546893 MHz, as on a PAL Master System. Neither implementation uses it yet: both run PAL at the NTSC clock (50.16 Hz frames instead of 49.70 Hz). PAL turbo frequencies are not defined yet.
11. Writes to `$07`–`$16` and to VDP registers 11–15 take effect only in Super Sega mode, and Q1 now names the real risk: old code run in Super Sega mode that writes a `$3E`/`$3F` mirror address.
12. Register layouts that only the emulator defines (DMA engine, PCM control, wavetable, slot select, VDP base registers, window split) are recorded as open question Q16.
13. The height cases are written out: with M4 and M2 set, M1 and M3 both set give 192 lines, and so does Feature Enable B height 11.
14. The two risks kept from Technical Reference v2 (VDP registers 11–15 checked against only six titles; keyboard polarity from one source that contradicts itself) are recorded in the profile too, which no longer states the polarity as settled.
15. The FM detection latch rule (Master System and Super Sega modes only) has its own `v7_changes` entry, so §2's statement that every change in its table is listed there holds.
16. The profile notes that the enhancement-layer design document it cites is not in this repository.
17. Both documents give the standard port mirrors both implementations decode: the PSG (and on the Master System and Game Gear the V and H counters) across `$40`–`$7F`, the VDP across `$80`–`$BF`.
18. Whether Feature Enable B's 224- and 240-line heights apply in the TMS modes is recorded as open question Q17.
19. Both documents say that the SG-1000, SC-3000 and SF-7000 have no `$3E`/`$3F` registers, so writes to `$00`–`$3F` do nothing in those modes (the emulator now follows this: M39).
20. The TMS9918 modes are written down in both documents (Technical Reference §3, profile `video.legacy_modes`): table addresses and Graphics II masks, colour 0 transparent in every mode, the sprite rules (32 sprites, four per line, the lowest-numbered on top, transparent sprites draw and collide with nothing) and when the overflow and collision flags are set. The emulator was corrected to them (M42–M45). Both documents also say which mode bits select which TMS mode. Open question Q18 records what status bits 4–0 read and whether transparent sprites should collide, and Q19 which mode several mode bits together give.
21. Q11 is resolved by the owner: True TMS colours is on at power-on, the one exception to every boost starting off, and it also acts on Super Sega software's TMS modes. The sprite-limit boost now says what both implementations do in the TMS modes (4 → 16), and the stock-overflow-flag boost that it acts in Mode 4 only.
22. Both documents give the four `$F2` states (0 PSG only, the power-on state; 1 FM only; 2 neither; 3 both), from MAME's `sms_m.cpp`; they said only that bits 1–0 select a mute state. The emulator was corrected to them (M46). Open question Q20 records that the balance of FM and PSG on the original is not known; both implementations make one FM channel at full volume peak at half a PSG channel at full volume.
23. Open question Q21 recorded that at turbo, software written for 100 % can write the FM chip faster than it accepts writes (12 master-clock cycles after an address, 84 after data). The owner decided it: the bus synchroniser holds the CPU on a write to `$F0`/`$F1` until the chip can take it, as it does for the VDP (Technical Reference §1). Both documents give the chip's write timing (§7). The emulator (M47) and the Pocket core do this.
24. The pad in the stock modes is written down (Technical Reference §6, profile `input.stock_mapping`), as the owner decided: the console reads its Mega Drive pad's A as button 1 and B as button 2, and Start is the Game Gear's Start or, through the Start = Pause boost, the Pause button. Start = Pause is now on at power-on, the second boost that starts on (§15). The documents said only that the pad gives B and C with TH high, as a Mega Drive pad does; the emulator already read A and B (M48).

### Emulator

Fixes to the emulator's model of the machine. M38–M49 each have a probe in `emulator/tools/probes_v7.js` that fails on the page as it was:

- **M38.** In Super Sega mode, writes to the read-only ports `$0F`, `$10` (math result) and `$16` (multitap) fell through to the `$3E`/`$3F` mirror and changed the memory and I/O control registers. Super Sega decodes `$07`–`$16` itself, as the Pocket core already did.
- **M39.** In the SG-1000, SC-3000 and SF-7000 modes, writes to `$07`–`$3F` changed the I/O control value, which affects what TH and TR read back. Those machines have no `$3E`/`$3F` registers, and the Pocket core already ignored the writes.
- **M40.** In the TMS9918 modes the line interrupt was raised in every machine mode. As stock only Mode 4 raises it; in Super Sega mode the question is open (Q15), and the emulator keeps raising it there.
- **M41.** The Start = Pause boost raised Pause in every mode. It now acts only in the Master System, SG-1000 and SC-3000 modes, as the profile's enhancement layer says: the Game Gear has a Start button of its own, and boosts other than True TMS colours never act on Super Sega software.
- **M42.** In the TMS9918 modes, where sprites overlapped, the highest-numbered was drawn on top. The lowest-numbered is now (Technical Reference §3, Gearsystem).
- **M43.** In the TMS9918 modes, sprites never set the collision flag. Two sprites meeting on a pixel now set it, when the line is drawn.
- **M44.** In Text and Multicolor, colour 0 was drawn black instead of transparent. It now shows the backdrop, as in the other modes and on the TMS9918.
- **M45.** In Graphics II the colour-table mask from R3 bits 6–0 was applied shifted by five bits, so R3 bits 1–0 masked the screen third and bits 6–2 masked nothing. It now masks the colour index as R4 bits 1–0 mask the pattern index. Software that keeps R3 at `$FF`, as most does, saw no difference.
- **M46.** The emulator mixed the PSG and the FM chip whatever `$F2` held. It now plays what `$F2` selects: the PSG only, FM only, neither or both (Technical Reference §7). The Sound Lab's cross-chip tools and dual-run capture, which are emulator-only and sound both chips on purpose, still do. An FM channel at full volume now peaks at half a PSG channel at full volume, the balance both implementations use until Q20 is decided (it was 0.47 of one).
- **M47.** At turbo, writes to the FM chip were never held. The bus synchroniser now holds an FM write until 12 base cycles have passed since an address write, or 84 since a data write (Technical Reference §1, Q21). The emulator's FM takes writes at once, so this changes only the CPU's timing, as on the core.
- **M48.** Start = Pause was off at power-on; it is now on, so Start pauses Master System, SG-1000 and SC-3000 games without a setting. The probe also checks that A and B are buttons 1 and 2 in the stock modes, which the emulator already did.
- **M49.** PAL ran on the NTSC clock. In PAL the base clock is now 3.546893 MHz (Technical Reference §1): frames come at 49.70 a second instead of 50.16, and the PSG and FM chip sound 0.9 % lower, as on a PAL Master System.

Also, without a probe because no program can see it: the Z80 now resets to interrupt mode 0, as the profile's `cpu.reset_state` says; the emulator takes every interrupt at `$0038` whatever the mode.

Application changes: the page runs machine frames at the machine's own rate (59.92 a second NTSC, 49.70 PAL) instead of one per display refresh, so PAL games no longer run at 60 frames a second, and no game runs fast on a 120 Hz screen; the default gamepad layout puts A on the right face button and B on the bottom one, as on the Pocket (C stays on the left and top); save states keep `$F2`, so a state saved during FM music plays FM again when loaded (older states load with the power-on setting, PSG only); gamepad buttons can be rebound in the Controls tab like keys, and keyboard, touch and gamepad input are merged each frame (a connected gamepad used to release keys held on the keyboard). The Pause key and the gamepad's Pause do nothing in Game Gear mode, which has no Pause button. `profile_crosscheck.py` now reads every value it checks from the profile, and the claims about behaviour the profile describes in words check that the code for it is present (49 claims; before, most values were written into the script, so a wrong profile still passed), `probes_v7.js` exits with status 1 when a probe fails, and `controls_test.js` checks the bindings in a browser.

### Pocket core

- The CPU resets with SP = `$DFF0` (a second documented local change to tv80), and the trace harness samples SP after tv80 has written it back.
- In the stock machine modes only Mode 4 now raises the line interrupt, as on stock hardware; in Super Sega mode the TMS modes still raise it (open question Q15). The same change as M40.
- The controls players remap in the Pocket's Core Settings > Controls menu are labelled correctly in every mode, and `tools/check_core_json.py` checks the core's definition files against the platform's limits and the RTL.
- `pocket/setup.sh` fetches the Analogue core template at the release `core_top.v` was written against (v1.3.0).
- The TMS9918 modes are drawn: Graphics I and II, Text and Multicolor, their sprites, the TMS colours or the Master System approximation, and CRAM colours and the raised sprite limit for Super Sega software (Feature Enable C bits 0 and 1). SG-1000 and SC-3000 software is no longer a blank screen. Four SG-1000 test ROMs (`roms/tms_*.sg`) compare the core with the emulator in `sim/check.sh`; they also match Gearsystem.
- The core settings menu has the True TMS colours boost, on by default (Q11), so the enhancement layer is complete in the core.
- The FM unit is fitted: IKAOPLL (BSD 2-Clause, `rtl/third_party/ikaopll`, unchanged), a YM2413 core reverse-engineered from die shots of the chip, on the 3.579545 MHz base clock, with the four `$F2` states and the balance of Q20. Software that checks for FM now finds it. An FM test ROM (`roms/fm.sms`) is captured as audio and checked in `sim/check.sh` (`tools/check_fm_wav.py`): each chip heard exactly in the states that select it, the FM pitch and the balance; and in Game Gear mode, which has no FM unit, the PSG alone.
- At turbo the bus synchroniser holds the CPU on FM writes until the chip can take them (Q21). A second FM test ROM (`roms/fm_tight.sms`), whose driver leaves the chip little more than the minimum time at 100 %, is checked at 200 % turbo in `sim/check.sh`; without the hold it played no FM.
- The Pocket's buttons are the console's Mega Drive pad in every mode: A (east) = A, B (south) = B, Y = C. So in the stock modes A is button 1 and B button 2 (they were B and A), and in Super Sega mode each button keeps its letter (Y was A and A was C). Start = Pause is on by default. `sim/check.sh` reads port `$DC` with each held.
