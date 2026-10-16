# MasterDrive — v7 Reconciliation: Machine vs Emulator

October 2026. Companion to `masterdrive_machine_v7.json` and `MasterDrive_Technical_Reference_v3.md`. Paths below are relative to the top of the repository (`machine/`, `emulator/`, `pocket-core/`). The *October 2026 package* is the set of files (these documents, the emulator and the Pocket core) this repository was first imported from; §7 lists what has changed since.

**Terms used below.** *Feature Enable A, B, C* are the three registers through which new software opts into MasterDrive features (VDP bank 0 R15, bank 1 R2 and R7; "bank1 R3" is register 3 of the extension register bank 1). The *enhancement layer* (AEL) is the set of optional boosts for unmodified software, all off by default except True TMS colours and Start = Pause. The *bus synchroniser* holds the CPU when turbo runs it faster than the video chip, or the FM chip, can accept data. The Technical Reference explains each in full.

## 1. The boundary

Work on MasterDrive has happened in several chats: the machine design itself, the Super Mario Land DX port, the Golden Axe conversion, the ROM hack maker, the MSX porting tools. Each touched either the **machine** or the **emulator**, and sometimes both. This document sorts every change into one or the other.

**The machine** is the console: its chips, the jobs its FPGA does, the behaviour its BIOS exposes. It is defined by two documents, the machine profile (`masterdrive_machine_v7.json`) and the Technical Reference. The machine has three implementations:

| Implementation | What it is |
|---|---|
| The physical console | The hardware design in the earlier chats (315-5535 ASIC plus FPGA) |
| The emulator's machine model | The part of the HTML5 emulator that behaves like the console |
| The Analogue Pocket core | The new RTL in `pocket-core/rtl` plus the Pocket wrapper in `pocket-core/pocket` |

**The emulator** is an application. Besides its machine model it has tools that no console has. They are not part of the machine, so they never go into the machine documents or the Pocket core's machine layer (`pocket-core/rtl/`; the core's other layer, `pocket-core/pocket/`, connects the machine to the Pocket):

| Emulator-only feature | Notes |
|---|---|
| ROM hack maker and its plugins | Making mods. Playing a BPS-patched mod is a machine feature (computer mode applies the patch while writing a card); making one is not |
| MSX porting tools and the MSX2 Lab | MSX support is porting tooling, not a MasterDrive feature |
| AY-3-8910 → PSG translation | Part of the porting tools (moved out of the machine's audio section in Technical Reference v3) |
| Lab composite and merge report | Analysis views |
| Debug tab, self-test, FPGA-job counters | The app's own diagnostics (distinct from the machine's debug unit at $FB–$FF, which *is* a machine feature) |
| Display filters | Presentation |
| Sound Lab: PSG → FM and FM → PSG translation, channel layers, the mixer | Listening and porting tools; they can sound both chips whatever `$F2` selects (M46) |
| FM dual-run capture (in the Sound Lab) | Analysis tool |
| Save states | The console has none; the Pocket core has none in this milestone |
| ROM access what-if: ROM in RAM, and ROM speeds other than 250 ns | The machine reads its cartridge as a 250 ns ROM, with one wait state at 200 % (Q12); these choices show what other timings would do |

**Rule for disagreements.** Where the emulator and the machine documents disagree, the documents win and the emulator is fixed — unless the documents themselves are wrong about stock hardware, in which case both documents are corrected (and any implementation that followed them) and the change is recorded in `v7_changes`.

## 2. Machine changes in v7

All are recorded in the profile's `v7_changes` (20 entries in the package, 56 now; §7 lists the later changes). The ones that change behaviour:

| Change | Source | Emulator | Pocket RTL |
|---|---|---|---|
| Port $00 decoded in MasterDrive mode as well as Game Gear; bits 5–0 read 0 | Golden Axe plan | fixed | yes |
| Ports $01–$05 (GG serial) in GG and MasterDrive modes | machine chats | fixed | yes |
| $3E bit 2 scope: controller decode only, not GG, not $F2 or MasterDrive's $F0–$FF | SML DX port | fixed | yes |
| MasterDrive $07–$16 and $F0–$FA read values | SML DX port | fixed | yes |
| Native 12-bit CRAM byte-latch write order; GG colours | SML DX port | fixed | yes |
| $F2 readback with the I/O chip disabled | SML DX port | fixed | yes |
| VRAM expansion: Feature Enable B bit 4 enables, bank1 R3 bit 0 selects | v6 internal inconsistency | — | CPU access only (render bank not implemented) |
| **Extra-height mode bits** (v6 error): M2 enables, M1 → 224, M3 → 240 | found while testing the RTL | fixed | yes |
| **Codemasters/Korean registers at exact addresses**; Codemasters banks 0,1,0 at power-on | Gearsystem/MAME cross-check | fixed | yes |
| 8255 PPI reset state, mode word clears port C, bit set/reset | cross-check | fixed | yes |
| Enhancement layer behaviour pinned down (pseudo-stereo panning, auto-fire rate), and every boost limited to software in the stock modes | Pocket core request | fixed; turbo for stock software and the VRAM speed-up added | yes |
| Debug unit port reads only in MasterDrive mode; in the stock modes $FB–$FF read as on the stock machine | cross-check of the I/O map | fixed | yes (no debug unit yet; $FB reads back, no host attached) |
| FM detection latch only in Master System and MasterDrive modes | review | fixed | yes |
| Stock-hardware behaviour (CPU, VDP, PSG, I/O) listed in `stock_behaviour` | SML DX port, Gearsystem | fixed | yes |

Open items are in the profile's `open_questions` (Q1–Q14 in the package; Q15–Q25 were added since, §7). New in this round: **Q11**, whether the TMS-colour boost should default off like every other boost (the emulator defaults it on; since resolved, §7); **Q12**, the one-wait-state cartridge access at 200 % turbo (the emulator had it, the Pocket core did not); **Q13**, Feature Enable C bit 4 (ESAT 2-byte) contradicting the 2-byte ESAT decision; **Q14**, the PCM FIFO fill reading at `$08`, which cannot encode a 64-byte FIFO in three bits. The owner has since resolved all four (§7).

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
- Game Gear CRAM (and MasterDrive native CRAM) are byte-latched; every GG title had wrong colours.
- Overlapping sprites: the lowest-numbered sprite is now on top.
- **Extra-height modes:** the mode bits were swapped (M2/M3), the frame buffer held only 192 lines, and the 32×32 name table at `(R2 & $0C) << 10 | $700` was not used.

### Audio
- PSG noise ran an octave high (the shift register advanced on every counter reload instead of every other).
- PSG volume was linear; it is now 2 dB per step.
- Enhancement-layer pseudo-stereo wrote $99, silencing tones 1 and 2; it also applied to MasterDrive software.
- The FM detection latch at `$F2` answered in Game Gear, SC-3000 and SF-7000 modes; it now answers only in Master System and MasterDrive modes.

### I/O and memory
- Low-port reads ($00–$3F) answered from the controller mirror; they return $FF except for decoded registers.
- SG-1000, SC-3000 and SF-7000 writes to $00–$06 reached the Game Gear registers; they now do nothing.
- TR pins configured as outputs read back their level; Game Gear decodes only $C0/$DC and $C1/$DD above $C0.
- SK-1100 keyboard: ghosting closure stopped after three passes; the PPI selected row 0 at reset (SG-1000 pads unreadable); mode words and bit set/reset now behave as an 8255.
- Codemasters and Korean mapper register decode, Codemasters power-on banks.
- Bus synchroniser at turbo: the hold is CPU time and covers VDP reads as well as writes; cartridge wait states lengthen the access.
- DMA from RAM copied from an array nothing wrote.
- The sprite-limit and overflow-flag boosts also applied to MasterDrive software, overriding its own Feature Enable bits; they are now limited to stock software.
- Auto-fire overwrote the pad state, so releasing C mid-toggle left button 2 held; it acted on MasterDrive software, whose C is a button of its own; and it did not reach SG-1000/SC-3000 pads read through the keyboard PPI.
- The debug unit answered reads at $FB–$FD in every mode, where a stock machine returns the controller mirror; it now answers only in MasterDrive mode.

### Enhancement layer
- The turbo boost for stock software and the VRAM speed-up boost were missing. The turbo selector set the same step as software's `$F3` write and acted only in MasterDrive mode. The selector now sets the enhancement layer's step, which acts on stock software; MasterDrive software keeps its own `$F3` step. The VRAM speed-up switch removes the bus synchroniser's VDP access wait for stock software while a turbo step is active (the FM write hold added later, M47 in §7, still applies with it).

### Application-only fixes
Save states and the FM dual-run snapshot now hold work RAM and the new timing state; RAM search/freeze read the work RAM the CPU sees; three self-test checks were wrong (sprite check read the wrong line, height check used the swapped bits, keyboard checks skipped the PPI mode word). The turbo selector, the budget panel and the other turbo displays show the effective step; per-game settings keep the enhancement layer's step and no longer restore the `$F3` step, which software sets.

## 4. How the fixes were checked

| Check | Result |
|---|---|
| Behavioural probes (`emulator/tools/probes_v7.js`) for 41 behaviours, each citing its hardware source. The probes are named after the patch's MODEL fixes (M1–M37 in `emulator/fix_emulator_v7.py`); four fixes have no probe of their own. M11 (Game Gear `$01`–`$06` power-on values) shows only in the I/O test ROM comparison below, in Game Gear mode. M13 (cartridge wait states lengthen the access) is now exercised by M60 and by the wait-state test ROM (§7, Q12); before, headless runs used the emulator's then-default ROM access, a copy in fast RAM. M15 (SG-1000/SC-3000/SF-7000 writes to `$00`–`$06` do nothing) is exercised by no check. M17 (T-states lost during ED/CB instructions) is caught by the bus-synchroniser probe (M12) | 41 of 41 pass on the fixed page, 0 of 41 on the original (twenty-six more since, M38–M63, §7; 67 of 67 pass) |
| The page's own self-test, run headless | 29 of 29 |
| Gearsystem as an independent oracle: Batman Returns SMS (PAL) frames 30, 60, 120, 200, 500, 900, 1500 and GG frames 200, 500, 900, 1500 | identical (GG within Gearsystem's colour rounding: it expands channel value 5 to 86, not 85) |
| `emulator/tools/profile_crosscheck.py` (an earlier chat's check that the emulator implements what the profile claims; its height check updated to the v7 rule) | 47 of 47 claims on the fixed page; the original page fails the height rule (the script has since been rewritten to read every value from the profile: §7) |
| New VDP test ROMs (`pocket-core/tools/mk_testrom.py`): 192/224/240 lines, scrolling, sprites at the bottom edge, $D0 terminator, Y wrap | emulator = Gearsystem (192, 224) = RTL (192, 224, 240) |
| I/O test ROM (`pocket-core/roms/ports.sms`, decoded by `pocket-core/tools/read_ports_ppm.py`): 18 ports read in Master System, Game Gear and MasterDrive modes, idle and with button 1 held | emulator = RTL, except `$FC`/`$FD` bit 7 in MasterDrive mode (the emulator is its own debug host; the core has none). `$F2` differed too until the core had the FM unit |
| SC-3000 BASIC Level 2 / Level 3 / Home BASIC: typing reaches the screen; the SF-7000 IPL boots and polls the floppy controller (`emulator/tools/sc_typing.js`) | pass on the fixed page |

## 5. Known differences between the emulator and the Pocket core

- **Event timing.** The emulator resolves VDP events at line boundaries and reads the H counter as at the start of the instruction that reads it (its bus synchroniser times each port access where it ends: M51). The Pocket core follows Gearsystem's per-cycle event table (status flags, line interrupt, scroll latch at fixed cycle offsets; I/O 10 T-states into IN/OUT). Pictures match; mid-line raster tricks can differ. A refactor of the emulator's frame loop is the follow-up.
- **H counter.** The emulator returns a live count that starts at 0 at its line start; the machine latches the counter when TH rises and starts the line at `$E9` (Gearsystem's model, which the Pocket core follows). Light-gun software can therefore read different values on the two.
- **FM sound.** The emulator's FM synthesis is approximate (no rhythm instruments, no user instrument, no envelopes, linear volume steps; the built-in instruments only resemble the chip's), while the Pocket core's FM is IKAOPLL, which follows the YM2413 itself. The same music sounds different on the two.
- **Not in the Pocket core yet** (Technical Reference §19): PCM and wavetable sound, the DMA engine, the SF-7000 and its floppy controller, the debug unit, the mouse and trackball, a card in the card slot (the Pocket platform loads none), and the drawing side of ESAT, 16×16 and magnified sprites, the window and text layers, line tables and unique-cell mode (their registers are there).
- **Status bits 4–0** read 0 in the emulator and `$1F` in the Pocket core (open question Q18).

## 6. Project documents checked against v7

The four documents that were already in the claude.ai project were read against profile v7 and this reconciliation. The two with machine statements to correct were updated, and are in `project-docs/`; the other two (the Super Mario Land DX port design and the Super Mario Bros. Deluxe options) are not in this repository.

| Document | Result |
|---|---|
| Golden Axe conversion plan | Written against the v5 machine block, and updated: MasterDrive decodes `$00`–`$16` as registers, not `$06`–`$0A`, and no controller mirror answers in `$F0`–`$FF` (not `$F0`–`$FA`), so both ranges of the port-decode audit widen; native 12-bit colour needs Feature Enable A bit 0; its open machine questions now carry v7's answers (ROM size up to 4 MB with the stock bank registers, ESAT format, unique-cell coupling, turbo default, reverting earlier patches) |
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
10. The PAL CPU clock is defined as 3.546893 MHz, as on a PAL Master System. Both implementations now use it (M49 in the emulator; the Pocket core below); before, both ran PAL at the NTSC clock (50.16 Hz frames instead of 49.70 Hz). PAL turbo frequencies were open question Q22 (since decided, item 27).
11. Writes to `$07`–`$16` and to VDP registers 11–15 take effect only in MasterDrive mode, and Q1 now names the real risk: old code run in MasterDrive mode that writes a `$3E`/`$3F` mirror address.
12. Register layouts that only the emulator defines (DMA engine, PCM control, wavetable, slot select, VDP base registers, window split) are recorded as open question Q16.
13. The height cases are written out: with M4 and M2 set, M1 and M3 both set give 192 lines, and so does Feature Enable B height 11.
14. The two risks kept from Technical Reference v2 (VDP registers 11–15 checked against only six titles; keyboard polarity from one source that contradicts itself) are recorded in the profile too, which no longer states the polarity as settled.
15. The FM detection latch rule (Master System and MasterDrive modes only) has its own `v7_changes` entry, so §2's statement that every change in its table is listed there holds.
16. The profile notes that the enhancement-layer design document it cites is not in this repository.
17. Both documents give the standard port mirrors both implementations decode: the PSG (and on the Master System and Game Gear the V and H counters) across `$40`–`$7F`, the VDP across `$80`–`$BF`.
18. Whether Feature Enable B's 224- and 240-line heights apply in the TMS modes is recorded as open question Q17.
19. Both documents say that the SG-1000, SC-3000 and SF-7000 have no `$3E`/`$3F` registers, so writes to `$00`–`$3F` do nothing in those modes (the emulator now follows this: M39).
20. The TMS9918 modes are written down in both documents (Technical Reference §3, profile `video.legacy_modes`): table addresses and Graphics II masks, colour 0 transparent in every mode, the sprite rules (32 sprites, four per line, the lowest-numbered on top, transparent sprites draw and collide with nothing) and when the overflow and collision flags are set. The emulator was corrected to them (M42–M45). Both documents also say which mode bits select which TMS mode. Open question Q18 records what status bits 4–0 read and whether transparent sprites should collide, and Q19 which mode several mode bits together give.
21. Q11 is resolved by the owner: True TMS colours is on at power-on, the one exception to every boost starting off, and it also acts on MasterDrive software's TMS modes. The sprite-limit boost now says what both implementations do in the TMS modes (4 → 16), and the stock-overflow-flag boost that it acts in Mode 4 only.
22. Both documents give the four `$F2` states (0 PSG only, the power-on state; 1 FM only; 2 neither; 3 both), from MAME's `sms_m.cpp`; they said only that bits 1–0 select a mute state. The emulator was corrected to them (M46). Open question Q20 records that the balance of FM and PSG on the original is not known; both implementations make one FM channel at full volume peak at half a PSG channel at full volume.
23. Open question Q21 recorded that at turbo, software written for 100 % can write the FM chip faster than it accepts writes (12 master-clock cycles after an address, 84 after data). The owner decided it: the bus synchroniser holds the CPU on a write to `$F0`/`$F1` until the chip can take it, as it does for the VDP (Technical Reference §1). Both documents give the chip's write timing (§7). The emulator (M47) and the Pocket core do this.
24. The pad in the stock modes is written down (Technical Reference §6, profile `input.stock_mapping`), as the owner decided: the console reads its Mega Drive pad's A as button 1 and B as button 2, and Start is the Game Gear's Start or, through the Start = Pause boost, the Pause button. Start = Pause is now on at power-on, the second boost that starts on (§15). The documents said only that the pad gives B and C with TH high, as a Mega Drive pad does; the emulator already read A and B (M48).
25. Open question Q22 records the turbo frequencies in PAL, which the documents define only at the NTSC clock; both implementations run the same percentages of the PAL clock. The owner has since decided it (item 27).
26. The machine is renamed MasterDrive (formerly Super Sega), the owner's choice: an all-in-one Sega 8-bit computer and console concept, with updates. Both documents, their file names and every implementation follow; the profile's machine id and two keys change with it (`video.mode4.height_selection.masterdrive`, `port_map.masterdrive_read_values`). The emulator keeps the internal code `ss` for MasterDrive mode, so settings and saved states made before still load.
27. Q22 is resolved by the owner: in PAL the turbo steps are the same percentages of the PAL clock, 4.434, 5.320, 6.207 and 7.094 MHz (Technical Reference §1), which both implementations already did; neither changes.
28. Q1 is resolved by the owner: the MasterDrive I/O registers stay inside the `$3E`/`$3F` mirror range, and in MasterDrive mode `$01`–`$17` answer only while Feature Enable A bit 7 is set (the *I/O gate*, Technical Reference §11, profile `port_map.native_gate`). Until then those ports are the `$3E`/`$3F` mirrors and read `$FF`, as on a Master System, and `$00` (Start and region) still answers. The gate is live, and the registers keep what they were set to while it is closed. Both implementations do this; before, `$01`–`$16` answered in MasterDrive mode whatever the bit.
29. Q8 is resolved by the owner: the boot menu can start an export cartridge in MasterDrive mode (the Pocket's System setting, the emulator's machine-mode selector), and a read-only machine ID at `$17` reads `$A7` (high nibble `$A` for MasterDrive, low nibble the machine version) behind the I/O gate (Technical Reference §14, profile `software_detection`). Both implementations do this.
30. Q7 is resolved by the owner: the math unit divides A by B, the quotient in `$0F` and the remainder in `$10`, `$FF`/`$00` for a divide by zero (Technical Reference §9). Both implementations computed `((A << 8) | B) / B` and now do this.
31. Q9 is resolved by the owner: `$0A` reads the selected work RAM bank in bits 3–0 (Technical Reference §2); it read `$FF`. Both implementations do this.
32. Q14 is resolved by the owner: `$08` bits 6–4 read the PCM FIFO's bytes queued divided by 8, saturating at 7 (Technical Reference §7). The emulator returned the fill modulo 8, so a full FIFO read as empty; it now does this. The Pocket core has no PCM yet; its `$08` reads an empty FIFO, which this rule also gives.
33. Q2 is resolved by the owner: the largest cartridge ROM is 4 MB, the stock bank registers' reach; it was specified as 8 MB, which needed a ninth bank bit. The Pocket core's cartridge slot now takes 4 MB (and a copier header). The owner also decided that the console reads the computer side's media, SC-3000 cassettes and SF-7000 disks (Technical Reference §8); how is new open question Q23.
34. Q3 is resolved by the owner: cartridge save RAM is 32 KB, two banks of 16 KB as the 315-5235 maps them (Technical Reference §2, §8). The emulator mirrored two 8 KB banks and the Pocket core used 16 KB of its 32 KB block; both now map 2 × 16 KB. New open question Q24 asks what a save-card profile holds (the first 8 KB of bank 0 today) and what identifies a game on the card.
35. Q12 is resolved by the owner: the cartridge wait state at 200 % is kept, on every read from the cartridge or card slot (`$0000`–`$BFFF`), a halted CPU's M1 reads included, and not on the SF-7000's RAM and IPL (Technical Reference §1). The emulator applied it only with its cartridge-timing setting, which is now its default; the Pocket core adds it. New open question Q25 asks whether cartridge writes take it too.
36. Q13 is resolved by the owner: Feature Enable C bit 4 is retired (reserved) and the ESAT is always 2 bytes per sprite (Technical Reference §5, §10). The emulator dropped the 1-byte layout it used while the bit was clear (M61); the Pocket core does not draw the ESAT yet.
37. Q15 is resolved by the owner: in MasterDrive mode the TMS modes raise the line interrupt, enabled by R0 bit 4 as in Mode 4 (Technical Reference §3, §16). Both implementations already did this; the stock modes stay as stock (M40).
38. Q17 is resolved by the owner: Feature Enable B's 224 and 240 lines apply in the TMS modes too, and the tables carry on below line 192: the name table continues (Text runs past R2's 1 KB), Graphics II takes rows 24–29 from a fourth pattern and colour bank, `$D0` no longer ends the sprite list, and a sprite wraps to the top only when *Y* + 1 is 241 or more, as in Mode 4 (Technical Reference §3). Both implementations already drew the taller picture; both now draw a sprite at Y = `$D0` there and wrap at 241 (M62, M63; Pocket core below).

### Emulator

Fixes to the emulator's model of the machine. M38–M63 each have a probe in `emulator/tools/probes_v7.js` that fails on the page as it was:

- **M38.** In MasterDrive mode, writes to the read-only ports `$0F`, `$10` (math result) and `$16` (multitap) fell through to the `$3E`/`$3F` mirror and changed the memory and I/O control registers. MasterDrive decodes `$07`–`$16` itself, as the Pocket core already did.
- **M39.** In the SG-1000, SC-3000 and SF-7000 modes, writes to `$07`–`$3F` changed the I/O control value, which affects what TH and TR read back. Those machines have no `$3E`/`$3F` registers, and the Pocket core already ignored the writes.
- **M40.** In the TMS9918 modes the line interrupt was raised in every machine mode. As stock only Mode 4 raises it; in MasterDrive mode the TMS modes keep raising it, as the owner later decided (Q15, item 37).
- **M41.** The Start = Pause boost raised Pause in every mode. It now acts only in the Master System, SG-1000 and SC-3000 modes, as the profile's enhancement layer says: the Game Gear has a Start button of its own, and boosts other than True TMS colours never act on MasterDrive software.
- **M42.** In the TMS9918 modes, where sprites overlapped, the highest-numbered was drawn on top. The lowest-numbered is now (Technical Reference §3, Gearsystem).
- **M43.** In the TMS9918 modes, sprites never set the collision flag. Two sprites meeting on a pixel now set it, when the line is drawn.
- **M44.** In Text and Multicolor, colour 0 was drawn black instead of transparent. It now shows the backdrop, as in the other modes and on the TMS9918.
- **M45.** In Graphics II the colour-table mask from R3 bits 6–0 was applied shifted by five bits, so R3 bits 1–0 masked the screen third and bits 6–2 masked nothing. It now masks the colour index as R4 bits 1–0 mask the pattern index. Software that keeps R3 at `$FF`, as most does, saw no difference.
- **M46.** The emulator mixed the PSG and the FM chip whatever `$F2` held. It now plays what `$F2` selects: the PSG only, FM only, neither or both (Technical Reference §7). The Sound Lab's cross-chip tools and dual-run capture, which are emulator-only and sound both chips on purpose, still do. An FM channel at full volume now peaks at half a PSG channel at full volume, the balance both implementations use until Q20 is decided (it was 0.47 of one).
- **M47.** At turbo, writes to the FM chip were never held. The bus synchroniser now holds an FM write until 12 base cycles have passed since an address write, or 84 since a data write (Technical Reference §1, Q21). The emulator's FM takes writes at once, so this changes only the CPU's timing, as on the core.
- **M48.** Start = Pause was off at power-on; it is now on, so Start pauses Master System, SG-1000 and SC-3000 games without a setting. The probe also checks that A and B are buttons 1 and 2 in the stock modes, which the emulator already did.
- **M49.** PAL ran on the NTSC clock. In PAL the base clock is now 3.546893 MHz (Technical Reference §1): frames come at 49.70 a second instead of 50.16, and the PSG and FM chip sound 0.9 % lower, as on a PAL Master System. The page has an NTSC/PAL selector next to the machine mode; changing it restarts the machine, as on the Pocket core.
- **M50.** The bus synchroniser's FM write timing was cleared at the start of every frame, so at turbo an FM write late in one frame never held the first FM write of the next. It now carries over, and reset and loading a state clear it.
- **M51.** The I/O instructions with the `$ED` prefix (`IN r,(C)`, `OUT (C),r`, `INI`, `IND`, `OUTI`, `OUTD` and their repeats `INIR`, `INDR`, `OTIR`, `OTDR`) counted their T-states after the port access, the unprefixed `IN A,(n)` and `OUT (n),A` before it, so at turbo the bus synchroniser measured the gap between two port accesses wrongly when the two kinds were mixed (by 12 T-states for `OUT (C),r`). Each now counts its T-states up to the end of its port access first, so the gap is measured from where each access ends. For `INI` and its kin that is T13, before the memory write (the cycle order of MAME's Z80). The Pocket core's Z80, tv80, ended that port read at T12, one T-state earlier; it now ends it at T13 too (Pocket core below).
- **M52.** The bus synchroniser kept the time of the last VDP access in base cycles worked out with the turbo step of the moment, so a step change between two accesses in one frame (125 % to 200 %, say) made the next wait grow with the time the machine had run (a freeze of about 20 seconds after a minute's play). It also forgot the last access at every frame start, and ignored accesses made at 100 %. It now keeps its references (the last VDP access and the last FM write) in CPU T-states, rescales them when the step changes, notes every access and carries them over frames, as the core's base-cycle counters do.
- **M53.** `IN F,(C)` (`$ED $70`, an undocumented form) did nothing, in 8 T-states. It now reads port (C) and sets the flags from the value without keeping it, in 12 T-states.
- **M54.** In MasterDrive mode `$01`–`$16` answered whatever Feature Enable A held. They now answer only while bit 7 is set (Q1): before, a write there reaches the `$3E`/`$3F` mirrors and a read gives `$FF`; `$00` always answers; clearing the bit closes them again and the registers keep their settings. The probes and the self-test that use these registers now set the bit first.
- **M55.** There was no machine ID. Port `$17` reads `$A7` in MasterDrive mode while the I/O gate is open, and a write to it is ignored; before the gate opens it is a `$3F` mirror (Q8).
- **M56.** The math unit's divide computed `((A << 8) | B) / B`. It now gives A ÷ B, the quotient in `$0F` and the remainder in `$10`, `$FF`/`$00` for a divide by zero (Q7); the probe checks all 65,536 operand pairs.
- **M57.** `$0A` was write-only. It reads the selected work RAM bank in bits 3–0 (Q9).
- **M58.** `$08` returned the PCM FIFO's fill modulo 8, so 8, 16 or 64 bytes read as empty and 7 as nearly full. It now reads the bytes queued divided by 8, saturating at 7 (Q14).
- **M59.** Cartridge save RAM was two 8 KB banks, each mirrored across `$8000`–`$BFFF`. It is now two 16 KB banks (Q3); browser saves, snapshots and save states made with the old layout load with each old bank repeated over its new 16 KB, so a game sees what it saw before.
- **M60.** The cartridge wait state at 200 % applied only when the cartridge-timing setting was chosen; the default copied the ROM to fast RAM, which the machine documents do not have. Cartridge timing is now the default (Q12), so at 200 % a NOP in cartridge ROM takes 5 T-states. The wait also follows a mid-frame `$F3` step change at once (it used to wait for the next frame), applies to a halted CPU's M1 reads in ROM, and no longer applies in SF-7000 mode, where `$0000`–`$BFFF` is the disk system's RAM and IPL.
- **M61.** The ESAT took 1 byte per sprite unless Feature Enable C bit 4 was set, and in that layout byte bits 7–4 picked the palette and magnify and the early clock did nothing. It is now always 2 bytes per sprite, and the bit is retired (Q13).
- **M62.** In the TMS modes at 224 and 240 lines (MasterDrive software), Y = `$D0` still ended the sprite list, so no sprite after it was drawn. It now ends the list only at 192 lines, as in Mode 4 (Q17). The probe also checks that Graphics II takes rows 24–29 from a fourth bank, which the emulator already did, and that the SG-1000 stays at 192 lines.
- **M63.** In the TMS modes at 224 and 240 lines, a sprite wrapped to the top when *Y* + 1 was 225 or more, so one meant for lines 225–239 was drawn above the top of the screen instead. It now wraps at 241 or more, as in Mode 4 (Q17); at 192 lines the rule is unchanged.

Also, without a probe because no program can see it: the Z80 now resets to interrupt mode 0, as the profile's `cpu.reset_state` says; the emulator takes every interrupt at `$0038` whatever the mode.

Application changes: the page runs machine frames at the machine's own rate (59.92 a second NTSC, 49.70 PAL) instead of one per display refresh, so PAL games no longer run at 60 frames a second, and no game runs fast on a 120 Hz screen (the main screen, the MSX2 analysis mode and the MasterDrive Lab alike; on a 60.00 Hz screen a 59.92 Hz machine runs one frame per refresh and skips one about every 13 seconds); the PAL setting is kept in save states and per-game settings, and a game without one of its own runs at the page's setting; per-game settings, cartridge battery images, snapshots and save routing are stored under a CRC-32 of the whole ROM and its length instead of a hash of every 17th byte, which gave ROMs that differ only between those bytes (such as the test ROMs `vdp192.sms` and `vdp224.sms`) one key; what a ROM had stored under its old key is copied to the new one the first time it loads (`tools/romid_test.js`), and the save card's game IDs do not change (Q24); the Sound Lab's dual-run capture saves the bus synchroniser's references and the `$F3` turbo step with the rest of the machine between its two passes, so neither pass sees the other's timing; the ROM access setting (fast RAM or cartridge timing) survives a reset, a mode or video change and a new cartridge, as its selector shows; cartridge timing is the default ROM access setting, and the other choices (ROM in RAM, ROM speeds other than 250 ns) are what-if tools that no console has; the default gamepad layout puts A on the right face button and B on the bottom one, as on the Pocket (C stays on the left and top); save states keep `$F2`, so a state saved during FM music plays FM again when loaded (older states load with the power-on setting, PSG only); gamepad buttons can be rebound in the Controls tab like keys, and keyboard, touch and gamepad input are merged each frame (a connected gamepad used to release keys held on the keyboard). The Pause key and the gamepad's Pause do nothing in Game Gear mode, which has no Pause button. `profile_crosscheck.py` now reads every value it checks from the profile, and the claims about behaviour the profile describes in words check that the code for it is present (59 claims; before, most values were written into the script, so a wrong profile still passed), `probes_v7.js` exits with status 1 when a probe fails, and `controls_test.js` checks the bindings in a browser.

### Pocket core

- The CPU resets with SP = `$DFF0` (a second documented local change to tv80), and the trace harness samples SP after tv80 has written it back.
- In the stock machine modes only Mode 4 now raises the line interrupt, as on stock hardware; in MasterDrive mode the TMS modes still raise it, as Q15 later decided. The same change as M40.
- The controls players remap in the Pocket's Core Settings > Controls menu are labelled correctly in every mode, and `tools/check_core_json.py` checks the core's definition files against the platform's limits and the RTL.
- `pocket/setup.sh` fetches the Analogue core template at the release `core_top.v` was written against (v1.3.0).
- The TMS9918 modes are drawn: Graphics I and II, Text and Multicolor, their sprites, the TMS colours or the Master System approximation, and CRAM colours and the raised sprite limit for MasterDrive software (Feature Enable C bits 0 and 1). SG-1000 and SC-3000 software is no longer a blank screen. Four SG-1000 test ROMs (`roms/tms_*.sg`) compare the core with the emulator in `sim/check.sh`; they also match Gearsystem.
- The core settings menu has the True TMS colours boost, on by default (Q11), so the enhancement layer is complete in the core.
- The FM unit is fitted: IKAOPLL (BSD 2-Clause, `rtl/third_party/ikaopll`, unchanged), a YM2413 core reverse-engineered from die shots of the chip, on the 3.579545 MHz base clock, with the four `$F2` states and the balance of Q20. Software that checks for FM now finds it. An FM test ROM (`roms/fm.sms`) is captured as audio and checked in `sim/check.sh` (`tools/check_fm_wav.py`): each chip heard exactly in the states that select it, the FM pitch and the balance; and in Game Gear mode, which has no FM unit, the PSG alone.
- At turbo the bus synchroniser holds the CPU on FM writes until the chip can take them (Q21). A second FM test ROM (`roms/fm_tight.sms`), whose driver leaves the chip little more than the minimum time at 100 %, is checked at 200 % turbo in `sim/check.sh`; without the hold it played no FM.
- The Pocket's buttons are the console's Mega Drive pad in every mode: A (east) = A, B (south) = B, Y = C. So in the stock modes A is button 1 and B button 2 (they were B and A), and in MasterDrive mode each button keeps its letter (Y was A and A was C). Start = Pause is on by default. `sim/check.sh` reads port `$DC` with each held.
- PAL runs on the PAL clock (3.546893 MHz): in PAL, machine time stands still for one system clock in every 109.63, so every base cycle, the CPU, turbo, the VDP's timing, the PSG and the FM chip run at the PAL rate and frames come at 49.70 a second. The Pocket's pixel clock is not held, so a PAL line reaches its scaler as 345 or 346 pixel clocks instead of 342; nothing else the scaler sees changes. Changing the Video setting restarts the machine. `sim/check.sh` checks the frame timing, PAL FM pitch, PAL at 200 % turbo, the video timing through the Pocket layer, and a switch from PAL to NTSC in the middle of a frame.
- `INI`, `IND`, `INIR` and `INDR` take the Z80's cycles, 4, 5, 4 and 3 T-states and 5 more when they repeat (a third documented local change to tv80, which took 4, 4, 4 and 4), so their port read ends at T13, as in the emulator (M51). `sim/z80` now compares every port access as well as every instruction start; before the change, 7 of its 18 accesses came one T-state early.
- The I/O gate and the machine ID (Q1, Q8) in `rtl/mdr_io.v`: in MasterDrive mode `$01`–`$17` answer only while Feature Enable A bit 7 is set, and `$17` reads `$A7`. `sim/io` checks the gate in MasterDrive, Game Gear and Master System modes, and a new test ROM, `roms/mdports.sms`, reads the ports before and after the gate opens: the core matches the emulator in all three modes and the expected values in MasterDrive mode, and through the Pocket layer an export cartridge runs in MasterDrive mode with System = MasterDrive and in Master System mode with Auto. A change of the System setting now restarts the machine, as a change of Video does; the mode used to follow the setting while the machine ran.
- The math unit divides as Q7 decides, with an 8-bit restoring divider (8 clocks, against at least 82 before the CPU can read the result); `$0A` reads back the work RAM bank (Q9); `$08` follows the Q14 rule. `sim/io` checks the divide over 20,000 operand pairs and the `$0A` and `$08` reads, and a new test ROM, `roms/mdrregs.sms`, multiplies, divides (with a divide by zero) and reads `$0A`, `$08` and `$17`: the core matches the emulator and the expected values.
- Cartridge save RAM is two 16 KB banks (Q3); `roms/save.sms` writes a block in each half of each bank, and `sim/check.sh` reads the save slot back with each block at its 16 KB place. A `.sav` made before keeps working for a game that uses only the first 8 KB of bank 0, as nearly all do; a game that used the second bank finds that data in the upper half of bank 0. The cartridge slot takes 4 MB (Q2), and `tools/check_core_json.py` checks both slot sizes against the profile.
- The cartridge wait state at 200 % (Q12) in `rtl/mdr_top.v`: one TW on every memory read in `$0000`–`$BFFF` at the 200 % step, outside SF-7000 mode. A new test ROM, `roms/romwait.sms`, runs 2,000 NOPs from cartridge ROM and from work RAM at 200 % and 175 %: at 200 % the ROM run ends five lines after the RAM run, at 175 % both end together, on the core and the emulator alike, in NTSC and PAL.
- The TMS modes at 224 and 240 lines (Q17) in `rtl/mdr_vdp.v`: Y = `$D0` ends the sprite list only at 192 lines (it ended it in the TMS modes at every height), and a TMS sprite wraps to the top only when *Y* + 1 is 241 or more at the taller heights. Three new test ROMs (`roms/tms_g2_224.sms`, `tms_g2_240.sms`, `tms_txt_240.sms`) draw Graphics II at both heights and Text at 240, with sprites below line 192, collisions, a fifth sprite on a line, a sprite at Y = `$D0`, the wrap, and line interrupts counted on screen: the core matches the emulator in the Master System colours and in true TMS colours (also through the Pocket layer), and the 240-line ROM on the SG-1000, where it stays at 192 lines.
