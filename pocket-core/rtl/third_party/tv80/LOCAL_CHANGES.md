# Local changes to tv80

tv80 (MIT, Guy Hutchison; a Verilog translation of Daniel Wallner's T80),
from https://github.com/hutch31/tv80 at commit 66a131c38d05ef58b3d8c4f1507a72e6e4aa5d65,
is vendored here unchanged except for one line in `tv80_core.v`, marked
"Super Sega local change":

- `Auto_Wait_t1 <= Auto_Wait || iorq_i;` (T80's original form) instead of
  `Auto_Wait || (iorq_i & ~Auto_Wait_t2)`. With an external WAIT holding an
  I/O cycle in T2, tv80's form made `Auto_Wait_t1` toggle, so the cycle did not
  continue on the first enable after WAIT rose. The machine's I/O strobe is
  taken at that enable, so the access happened while the CPU stayed in T2 and
  was repeated. Found with the turbo bus synchroniser (pocket-core/sim/sys, `-turbo 4`).
  Instruction timings without WAIT are unchanged (pocket-core/sim/z80/tb_z80.v).
