# Decisions waiting to be applied

The owner answered these on 12 October 2026. They are **decided but not yet applied**: the machine documents (`machine/`), the emulator and the Pocket core still describe and do what they did before. When one is applied, record it the usual way (`CLAUDE.md`) and remove it from this list.

## Machine (open questions in the Technical Reference, §17)

| Question | Decision |
|---|---|
| Q1 port mirror range | Ports `$06`–`$16` answer only after native software sets **Feature Enable A bit 7** (currently unused). Until then they act as the Master System's `$3E`/`$3F` mirrors and read `$FF`. |
| Q2 largest cartridge ROM | **4 MB** (the stock bank registers' reach). The console can also read cassettes and the other media the computer side (SC-3000, SF-7000) uses. |
| Q3 cartridge save RAM | **32 KB** (2 × 16 KB, as the 315-5235 mapper maps it). |
| Q7 math unit divide | A ÷ B, quotient in `$0F`, remainder in `$10`; divide by zero gives `$FF`/`$00`. |
| Q8 detecting the machine | A boot-menu option that runs an export cartridge in native mode, plus a read-only machine ID register. |
| Q9 work RAM bank readback | `$0A` becomes readable (selected bank in bits 3–0). |
| Q12 cartridge wait state at 200 % | Kept; the Pocket core adds it. |
| Q13 Feature Enable C bit 4 | Retired: ESAT is always 2 bytes per sprite; the emulator drops its 1-byte layout. |
| Q14 PCM FIFO fill at `$08` | Bits 6–4 = bytes queued ÷ 8, saturating at 7. |
| Q15 line interrupts in the TMS modes | In native mode, R0 bit 4 enables them (what both implementations already do). |
| Q16 undocumented register layouts | Adopt the emulator's current layouts into the documents. |
| Q17 taller heights in the TMS modes | Yes: the TMS modes extend their tables below line 192 (the name table continues, Graphics II uses a fourth pattern/colour bank, and `$D0` no longer ends the sprite list in the taller modes). |

Still to decide when applying: the machine ID register's port and value (Q8), and the PAL turbo frequencies (they would naturally be the same percentages of the PAL clock).
