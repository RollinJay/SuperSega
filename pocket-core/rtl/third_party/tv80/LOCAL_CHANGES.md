# Local changes to tv80

tv80 (MIT, Guy Hutchison; a Verilog translation of Daniel Wallner's T80),
from https://github.com/hutch31/tv80 at commit 66a131c38d05ef58b3d8c4f1507a72e6e4aa5d65,
is vendored here unchanged except for two lines in `tv80_core.v`, each marked
"MasterDrive local change":

- `Auto_Wait_t1 <= Auto_Wait || iorq_i;` (T80's original form) instead of
  `Auto_Wait || (iorq_i & ~Auto_Wait_t2)`. With an external WAIT holding an
  I/O cycle in T2, tv80's form made `Auto_Wait_t1` toggle, so the cycle did not
  continue on the first enable after WAIT rose. The machine's I/O strobe is
  taken at that enable, so the access happened while the CPU stayed in T2 and
  was repeated. Found with the turbo bus synchroniser (pocket-core/sim/sys, `-turbo 4`).
  Instruction timings without WAIT are unchanged (pocket-core/sim/z80/tb_z80.v).
- `SP <= 16'hDFF0;` instead of `16'hFFFF` in the reset block. The machine
  hands software the CPU with SP = $DFF0, where the Master System BIOS leaves
  it (machine profile `cpu.reset_state`); the emulator and Gearsystem start
  there too, so the three can be compared by instruction trace from the first
  instruction (pocket-core/tools/cmp_trace.py).

One file is added, not changed: `LICENSE-T80`, the licence notice of T80, which tv80 translates.
T80's licence asks for its notice to go with synthesized forms, so `pocket/build_core.sh` puts it
in the SD-card files with tv80's own notice (the header of its source files).
