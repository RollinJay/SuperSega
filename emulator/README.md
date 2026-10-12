# Super Sega emulator — v7 fixes

`supersega-emulator.html` is the emulator with every v7 fix applied. `fix_emulator_v7.py` is the same change as one patch, for applying to the original page:

```sh
python3 fix_emulator_v7.py supersega-emulator.orig.html supersega-emulator.html
```

The patch has 108 edits. Each is labelled **MODEL** (the emulator's model of the machine now does what the machine does; 75 edits) or **APP** (the application only; 33 edits). Every anchor is checked in order before anything is written, so a page that does not match stops the script instead of being half-patched. `../machine/SuperSega_v7_Reconciliation.md` explains the fixes in plain language.

## Checks (Node.js 18 or later, Python 3)

```sh
cd tools
node probes_v7.js ../supersega-emulator.html          # 41 behavioural probes, each with its hardware source
node selftest.js ../supersega-emulator.html           # the page's own Debug-tab self-test, headless (29 checks)
python3 profile_crosscheck.py ../supersega-emulator.html ../../machine/super_sega_machine_v7.json
python3 wiring_audit.py ../supersega-emulator.html    # every control wired to code, every subsystem present
node sc_typing.js ../supersega-emulator.html romdir out/   # SC-3000 BASIC typing, SF-7000 IPL (ROMs not included)
PAL=1 node js_dump.js ../supersega-emulator.html game.sms sms out/g 200 500   # frames as PPM
node cmp_gs.js ../supersega-emulator.html game.sms sms gsPrefix 200 500       # against Gearsystem frames
```

`emuload.js` runs the page's script headless; the other tools build on it. `jstrace.js` writes an instruction trace that `../../pocket-core/tools/cmp_trace.py` compares with Gearsystem's (`../../pocket-core/sim/ref/gstrace.cpp`). `shots.js` and `smoke.js` are quick render and smoke tests.

The probes run against the original page too, where they should fail: 0 of 41 pass there.
