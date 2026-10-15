# Super Sega

Super Sega is a design for an 8-bit games console in the family of Sega's SG-1000 (and the SC-3000, its home-computer version), Master System and Game Gear. It runs their software unmodified, and adds new hardware features that new software can opt into.

This repository holds the console's specification, an emulator that runs in a web browser, and an FPGA implementation of the console (a *core*) for the Analogue Pocket, a handheld that loads hardware designs through its openFPGA platform. It describes machine version 7 (October 2026).

## Three things, kept apart

**The machine** is the console itself: its chips, its registers, what software sees. It is defined by two documents in `machine/`: the machine profile (`super_sega_machine_v7.json`, machine-readable) and the Technical Reference (`SuperSega_Technical_Reference_v3.md`, the same for people). Where the two disagree, one of them has a bug.

**The emulator** (`emulator/`) is an application. Part of it models the machine; the rest is tooling that no console has — the ROM hack maker, the MSX porting tools, the Super Sega Lab (which compares two builds of one game), the Sound Lab (which translates music between the two sound chips), the Debug tab, display filters, save states. That tooling is not part of the machine, so it never goes into the machine documents or the Pocket core's machine layer (`pocket-core/rtl/`; the core's other layer, `pocket-core/pocket/`, connects the machine to the Pocket).

**The Pocket core** (`pocket-core/`) is a second implementation of the machine, in Verilog, for the Analogue Pocket's openFPGA platform. It contains none of the emulator's tooling.

When the emulator and the machine documents disagree, the documents win and the emulator is fixed. When the documents turn out to be wrong about the original hardware, both documents are corrected (and any implementation that followed them) and the change is recorded in the profile's `v7_changes`. `machine/SuperSega_v7_Reconciliation.md` sorts every change made in v7 into machine and emulator, and lists how each was checked.

## What is where

```
machine/
  super_sega_machine_v7.json            machine profile v7 (42 recorded changes; questions Q1-Q21, 15 still open)
  SuperSega_Technical_Reference_v3.md   the machine for readers; supersedes v2
  SuperSega_v7_Reconciliation.md        machine vs emulator: what changed, where, how it was checked
  tools/make_profile_v7.py              builds the v7 profile from v6 (super_sega_machine_v6.json, not included)
emulator/
  supersega-emulator.html               the emulator with every v7 fix applied
  fix_emulator_v7.py                    the one patch: original page (not included) -> fixed page (108 labelled edits)
  tools/                                headless checks: behavioural probes, self-test, Gearsystem comparison,
                                        profile cross-check, wiring audit, key and gamepad bindings (browser),
                                        SC-3000 typing
pocket-core/
  README.md                             layout, running the simulations, building for the Pocket
  docs/SuperSega_Pocket_Core_Design.md  design, status, verification, decisions needed
  rtl/  pocket/  sim/  syn/  tools/  roms/
project-docs/                           the two project documents corrected against v7 (Golden Axe
                                        conversion plan, ROM hack maker)
.github/workflows/checks.yml            the checks run on every push (see Checks below)
```

## Status

Two terms used below. **Gearsystem** is an independent Master System and Game Gear emulator, used only as a reference to test against. The **enhancement layer** is a set of optional boosts for unmodified software, such as removing sprite flicker; every boost is off by default except True TMS colours and Start = Pause.

- **Machine:** profile v7 and Technical Reference v3 are complete for everything decided so far. Fifteen of the twenty-one numbered questions (Q1–Q21) are still open (Q4–Q6, Q11 and Q21 are resolved, and Q10 is an emulator workflow rather than a machine question). The ones that block later work are the math unit's divide (Q7; the math unit is the console's hardware multiplier and divider), the port mirror range (Q1; whether some new I/O registers must move to other port addresses), the register layouts that so far only the emulator defines (Q16), and, for the TMS9918 picture modes on Super Sega, whether they raise line interrupts (Q15) and which heights they show (Q17). Corrections made since the repository was first imported (the October 2026 package) are listed in section 7 of `machine/SuperSega_v7_Reconciliation.md`.
- **Emulator:** the v7 patch made 108 edits (75 to its model of the machine, 33 to the application), and thirteen machine-model fixes have followed (Reconciliation section 7). All 53 behavioural probes pass: 41 written for the v7 fixes, none of which passed on the original page, and twelve for the later fixes (the thirteenth, the Z80's reset interrupt mode, changes nothing a program can see). The page's own self-test passes. Players set their keyboard keys and gamepad buttons in its Controls tab. Batman Returns matches Gearsystem on every frame compared: on the Master System in PAL, frames 30, 60, 120, 200, 500, 900 and 1500; on the Game Gear, frames 200, 500, 900 and 1500, within Gearsystem's colour rounding.
- **Pocket core, milestone 1:** runs Master System and Game Gear software, and SG-1000 test ROMs for all four TMS9918 picture modes, in simulation, identical to Gearsystem on the frames compared (Game Gear within Gearsystem's colour rounding, SG-1000 within the core's 4-bit-per-channel colour output), and Super Sega software up to the features listed in its design document. Every enhancement-layer boost is in its settings menu, all off by default except True TMS colours (SG-1000 and SC-3000 graphics in their original colours) and Start = Pause (the console's Mega Drive pad has no Pause button), which start on. The boosts act only on Master System, Game Gear, SG-1000 and SC-3000 software; True TMS colours also acts on Super Sega software's TMS9918 modes. Players set its controls in the Pocket's own Core Settings > Controls menu, which remaps the core's buttons. It builds with Quartus (Altera's FPGA tools) and meets timing (its logic is fast enough for its clock), and GitHub builds the SD-card files on every change to the core (`pocket-core/README.md`), but **it has not been run on a Pocket yet**: `pocket-core/TESTING.md` explains how to try it and what to expect. It has the FM sound unit (the YM2413 chip, through IKAOPLL, an open-source copy of it), so games that support FM play their FM music; that has been checked with a test ROM in simulation, not yet with games.

## Checks

Every push and pull request runs the checks in `.github/workflows/checks.yml` on GitHub Actions:

- **Machine and emulator:** the machine profile must be valid JSON and its generator must reproduce it exactly; the behavioural probes, the page's self-test, the profile cross-check (every value it checks is read from the profile) and the wiring audit must pass; and a headless browser with a simulated gamepad must find the key and gamepad bindings working.
- **Pocket core** (`pocket-core/sim/check.sh`): the core's Pocket definition files must stay within the platform's limits and match what the core reads; the test ROMs must regenerate byte for byte; the core's Z80 processor must start each instruction of a timing test program on the same cycle as the emulator's; the machine simulation must draw the same frames as the emulator for the video, sprite, Super Sega feature and I/O test ROMs, and the FM test ROM, which switches the FM chip and the original sound chip on and off in turn, must be heard playing only the chips it has on, at the right FM pitch and level; and the Pocket platform simulation must draw the same frames as the machine simulation, read the Pocket's B button as button 1 in Super Sega mode, and read the save slot back byte-exact.

The same commands, and the checks that need commercial ROMs or a local Gearsystem build, are in `emulator/README.md` and `pocket-core/README.md`.

## Licences

- The project's own files are under the MIT licence (`LICENSE`): anyone may use, change and share them, keeping the copyright notice.
- Third-party code in the core: tv80 (MIT, two lines changed and documented; it translates Daniel Wallner's T80, whose BSD-style notice is kept with it), IKAOPLL (BSD 2-Clause, unchanged; its README says two parts were copied from a GPL-2.0-or-later core, and why the core keeps it under BSD is in `pocket-core/docs/SuperSega_Pocket_Core_Design.md` §16) and agg23's analogue-pocket-utils (MIT). Each keeps its own licence, and their notices go with the core's SD-card files. Analogue's framework files are fetched by `pocket-core/pocket/setup.sh` and are not included.
- Gearsystem (GPL-3) was used only as an independent test oracle. Nothing from it is included; `pocket-core/sim/ref/` holds the two small runner programs that were linked to a local copy.
- No commercial ROMs are included. The test ROMs in `pocket-core/roms/` are generated by `pocket-core/tools/mk_testrom.py`.
