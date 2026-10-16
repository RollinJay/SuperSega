# Super Sega — notes for working in this repository

Read `README.md` first: it explains the machine, the emulator and the Pocket core, and why they are kept apart.

## Rules

- **The machine documents win.** `machine/super_sega_machine_v7.json` (the profile) and `machine/SuperSega_Technical_Reference_v3.md` define the machine. When the emulator or the Pocket core disagrees with them, fix the implementation. When the documents are wrong about the original hardware, correct both documents (and any implementation that followed them) and record the change in `v7_changes`. Do not decide an open hardware question; add it to the open questions (Q1–Q22 so far) in both documents.
- **Profile edits go through the generator too.** `machine/tools/make_profile_v7.py` must reproduce the profile exactly when run on it (CI checks this). Make each profile change in the script as well; a machine correction also gets a `change(...)` entry, which lands in `v7_changes`.
- **Emulator edits go straight into `emulator/supersega-emulator.html`.** `fix_emulator_v7.py` is the record of the v7 round and cannot be re-run here. A machine-model fix gets a probe in `emulator/tools/probes_v7.js` where one is possible (numbered on from the highest there, M49 so far) and a line in section 7 of `machine/SuperSega_v7_Reconciliation.md`.
- **Emulator-only tooling stays out of the machine documents and the Pocket core's machine layer (`pocket-core/rtl/`).** The README lists it.
- **Vendored code:** changes to `pocket-core/rtl/third_party/tv80` are marked "Super Sega local change" and listed in its `LOCAL_CHANGES.md`. The agg23 and IKAOPLL files are unchanged.
- **Never commit** commercial ROMs, system ROMs, Analogue's APF framework files (`pocket-core/pocket/setup.sh` fetches them), or Gearsystem code or binaries. The repository is public.
- **Licence:** the project's own files are MIT (`LICENSE`). Third-party code keeps its own licence; never relicense it, and keep its notices in the SD-card files (`pocket-core/pocket/build_core.sh`).
- **Documents are for a general reader:** introduce an idea before using it, keep cross-references and counts in step across every file that states them.

## Checks

CI (`.github/workflows/checks.yml`) runs them on every push. Locally:

```sh
cd emulator/tools
node probes_v7.js ../supersega-emulator.html
node selftest.js ../supersega-emulator.html
python3 profile_crosscheck.py ../supersega-emulator.html ../../machine/super_sega_machine_v7.json
python3 wiring_audit.py ../supersega-emulator.html
node controls_test.js ../supersega-emulator.html ../../pocket-core/roms/vdp224.sms   # needs Playwright
cd ../../machine && python3 tools/make_profile_v7.py super_sega_machine_v7.json /tmp/p.json && cmp /tmp/p.json super_sega_machine_v7.json
cd .. && pocket-core/sim/check.sh        # Pocket core: about four minutes
pocket-core/pocket/build_core.sh         # Quartus build and SD-card files: about 15 minutes, needs Docker (GitHub runs it too)
```
