# MasterDrive emulator — v7 fixes

`masterdrive-emulator.html` is the emulator with every v7 fix applied, plus the later fixes in section 7 of `../machine/MasterDrive_v7_Reconciliation.md`. `fix_emulator_v7.py` is the v7 round as one patch, for applying to the original (pre-v7) page, `masterdrive-emulator.orig.html`, which is not included in this repository:

```sh
python3 fix_emulator_v7.py masterdrive-emulator.orig.html masterdrive-emulator.v7.html
```

The patch has 108 edits. Each is labelled **MODEL** (the emulator's model of the machine now does what the machine does; 75 edits) or **APP** (the application only; 33 edits). Every anchor is checked in order before anything is written, so a page that does not match stops the script instead of being half-patched. `../machine/MasterDrive_v7_Reconciliation.md` explains the fixes in plain language.

## Changing the emulator

`fix_emulator_v7.py` is the record of the v7 round. It cannot be re-run here, because the original page is not in the repository, so later changes are made to `masterdrive-emulator.html` directly and git history is their record. A fix to the machine model also gets a probe in `tools/probes_v7.js` where one is possible (numbered on from the patch's MODEL fixes: M38 was the first), and a line in section 7 of `../machine/MasterDrive_v7_Reconciliation.md`.

## The BIOS

The page runs the machine's own BIOS (Technical Reference §20): loading a cartridge, Reset, and a change of machine or TV standard start it, and its menu runs before the game; holding Start (Enter by default) as it starts skips the menu. The machine selector is the platform's first offer to the BIOS (Auto leaves it to the cartridge's header), and the page's boost controls set the boosts at once, as the BIOS menu can for its launch. The BIOS's image is the block between `BIOS_BEGIN` and `BIOS_END`, written by `../bios/make_bios.py`; never edit it by hand. The headless tools (`emuload.js`'s `newMachine`, `js_dump.js`, `jstrace.js`) start a game directly, as if the BIOS had launched it; `js_dump.js` and `jstrace.js` run the BIOS itself with `BIOS=1`.

## Checks (Node.js 18 or later, Python 3)

```sh
cd tools && mkdir -p out
node probes_v7.js ../masterdrive-emulator.html          # 89 behavioural probes, each with its hardware source
node selftest.js ../masterdrive-emulator.html           # the page's own Debug-tab self-test, headless (29 checks)
python3 profile_crosscheck.py ../masterdrive-emulator.html ../../machine/masterdrive_machine_v7.json
python3 wiring_audit.py ../masterdrive-emulator.html    # every control wired to code, every subsystem present
node romid_test.js ../masterdrive-emulator.html ../../pocket-core/roms   # ROM keys and the carry-over of stored data
node bios_test.js ../masterdrive-emulator.html ../../pocket-core/roms    # a game started through the BIOS runs as one started directly
node controls_test.js ../masterdrive-emulator.html ../../pocket-core/roms/vdp224.sms   # key and gamepad bindings in a browser
node sc_typing.js ../masterdrive-emulator.html romdir out/   # SC-3000 BASIC typing, SF-7000 IPL (ROMs not included)
PAL=1 node js_dump.js ../masterdrive-emulator.html game.sms sms out/g 200 500   # frames as PPM
node cmp_gs.js ../masterdrive-emulator.html game.sms sms gsPrefix 200 500       # against Gearsystem frames
```

The probes, the self-test, the profile cross-check, the wiring audit, the ROM-key test, the BIOS hand-over test and the controls test exit with status 1 when a check fails; GitHub runs them on every push. `controls_test.js` drives the page in headless Chromium with a simulated gamepad and needs Playwright (`npm install playwright`, then `npx playwright install chromium`). Paths from here on are relative to `tools/`, like the commands. `cmp_gs.js` reads `gsPrefix_N.ppm` and `gsPrefix_N.ram` as written by the Gearsystem runner `gsrun`, which is built from a local Gearsystem checkout as `../../pocket-core/sim/ref/README.md` describes. Prefix `PAL=1` for 50 Hz titles, as for `js_dump.js`.

`emuload.js` runs the page's script headless; the other tools build on it. `jstrace.js` writes an instruction trace that `../../pocket-core/tools/cmp_trace.py` compares with Gearsystem's (`../../pocket-core/sim/ref/gstrace.cpp`). `shots.js` and `smoke.js` are quick render and smoke tests.

The 41 probes written for the v7 fixes also ran against the original page (not included), where none passed.
