# Golden Axe 8-bit Titles — Super Sega Conversion Plan

Covers Golden Axe Warrior (SMS) and Ax Battler: A Legend of Golden Axe (Game Gear), retargeted from stock hardware to the Super Sega profile.

Feature references follow the Super Sega machine profile v7 (`claude/super_sega_machine_v7.json`) and Technical Reference v3 (`claude/SuperSega_Technical_Reference_v3.md`). The plan was first written against the v5 machine block; the October 2026 check against v7 changed the points marked **v7** and settled the one value the plan had marked **confirm**, the ROM size ceiling (§4). Machine values that are still open are named where they matter, with their open-question numbers from the profile (Q1–Q14).

Related: the ROM hack maker framework specification (`claude/super-sega-rom-hack-maker.md`), which covers how mods for these and the other roster titles are made, tested and distributed.

---

## 1. Which source ROM each conversion starts from

**Ax Battler starts from the stock Game Gear ROM, not the GG2SMS build.**

The v1.2 GG2SMS patch performs four functions plus one small fix. Three of the functions are unnecessary or actively harmful under Super Sega:

| v1.2 behaviour | Super Sega disposition | Reason |
|---|---|---|
| Palette conversion hook at $160C, 12-bit to 6-bit, 32 entries from $C200 | **Revert** | Super Sega CRAM is 12-bit natively. The hook destroys colour depth the target hardware supports. **v7:** native 12-bit writes need Feature Enable A bit 0, which the conversion sets at boot; until then Super Sega mode takes Master System 6-bit writes |
| Three `LD C,$06` / `OUT ($06),A` sites redirected to $7F | **Revert** | Super Sega adopts the GG low-port scheme: $06 is the stereo register, as on the Game Gear. Stereo PSG returns at no cost |
| Start-button support: pad detection at boot ($7FA0, sets $DFF8 to $FF when a Mega Drive pad is found) and a Start-poll routine at $1670 that replaces the Game Gear's port $00 read at $3531 | **Revert** | The Genesis 3-button pad provides Start directly |
| Header region/size/checksum at $7FFA | **Replace** | Region nibble becomes `8`; checksum recomputed |
| Small fix: the fill value at $3C5A changed from $00 to $FF, for a routine that fills the first $400 bytes of VRAM (tiles 0–31); presumably the "less garbage" fix in the v1.2 notes | **Review** | Keep only if the stock value shows garbage under Super Sega |

**Golden Axe Warrior starts from the stock SMS ROM.** No prior conversion layer exists or is needed.

---

## 2. Ax Battler conversion

### 2.1 Viewport

The 160×144 to 256×192 expansion is required regardless of target, and its cost does not change under Super Sega. The work is the same: patch the column and row redraw to maintain a wider band, and widen offscreen spawn and cull ranges.

The balance consequence is unchanged and is the real expense. Enemy spawn triggers, camera bounds and ambush distances all assume a 160-pixel-wide window. Every engagement's timing shifts. Budget a systematic retune pass, not a flag change.

Because new battlefields are already committed to SMS screen dimensions, this expansion is a prerequisite to stage authoring rather than a parallel task.

### 2.2 Feature mapping for the three gameplay goals

**Visible field enemies — sprite budget.** Stock SMS and GG allow 8 sprites per scanline. An overworld carrying several visible enemies plus the player exceeds that immediately on any horizontal line where two actors align. ESAT, 16×16 sprites and the raised per-line limit remove the constraint. Per-sprite magnification additionally allows larger field markers without consuming extra tiles.

**Preset battlefield layouts — tile and VRAM budget.** The SMS exposes roughly 448 usable background tiles after sprite allocation. Distinct terrain across many battlefields exhausts that quickly, which is the structural reason the stock game uses flat repeated fields. The 1024-tile unique-cell mode and the 32 KB VRAM expansion raise the ceiling enough for genuinely distinct layouts. DMA copy and fill handles the inter-battle swap without a visible load pause.

**Enemy and boss attack patterns — CPU budget.** Multiple simultaneous AI actors running real state machines is the classic cause of frame drops on a 3.58 MHz Z80. Turbo at 125% exists to absorb exactly this, and applies without altering frame rate because the VDP and PSG stay at 1× and pacing is governed by the game's own VBlank wait.

This is a three-for-three mapping. Each stated goal is blocked by a different stock-hardware ceiling, and each ceiling is one the profile already raises.

### 2.3 Additional gains available at low cost

- Palettes carry over with no re-authoring, since GG CRAM is the native format (with Feature Enable A bit 0 set; **v7**)
- Stereo PSG returns via the reverted $06 sites, and panning can be authored per channel
- FM tracks at $F0/$F1 can replace or layer over the PSG soundtrack, but this is not a data-only change: the game's sound driver has no FM code, so it needs an FM driver — written for the project, or used under a licence that allows redistribution — as well as new music
- Window layer carries the status display, freeing the main tilemap and removing any row-lock or line-interrupt HUD trick

---

## 3. Golden Axe Warrior conversion

Already 256×192. No viewport work. Every item below is additive, which makes this the lower-risk of the two conversions and a better first target for validating the toolchain.

**Ranked by visible return per unit of effort:**

1. **Palette re-authoring, 64 colours to 12-bit.** Largest visual change available. Affects every screen.
2. **ESAT with H-flip.** A top-down game with four-facing sprite sets stores mirrored walk cycles as separate tiles. Replacing the mirrored halves with H-flip attributes typically recovers 30–50% of sprite tile space. That recovered space directly funds enemy variety.
3. **DMA copy and fill for room transitions.** The game is screen-flip in the Zelda 1 idiom, meaning a full-screen tile swap on every room boundary. This is the single largest per-frame VRAM workload in the game and the most direct DMA target.
4. **Window layer for the status bar.** Removes whatever row-lock or line-interrupt arrangement currently holds the HUD, and returns those scanlines to normal scroll.
5. **Stereo PSG panning.** The game's sound driver is Sega's shared Master System/Game Gear driver and already contains the Game Gear stereo command — the same routine Ax Battler's driver uses (its write is in bank 6, at $1875D). On a stock Master System that write would reach memory control, which suggests the game's music never issues it. On Super Sega, where $06 is the stereo register, panning can likely be added in the music data without driver changes. Confirm the command path in the emulator first.
6. **FM soundtrack at $F0/$F1.** Layered FM over retained PSG is the expected arrangement, but this is not a data-only upgrade: the game's sound driver has no FM code (no writes to $F0 or $F1 anywhere in the ROM), so it needs an FM driver — written for the project, or used under a licence that allows redistribution — as well as new music. That cost is why it ranks below panning.
7. **Line-scroll table.** Only if any existing effect uses line interrupts for parallax; otherwise skip.

Turbo is not expected to be needed. The game's per-frame load is low and its slowdown, where it occurs, is not AI-driven.

---

## 4. Shared hazards

**High-range port decoding.** Super Sega fully decodes $F0–$FF (**v7**; v5 said $F0–$FA: in Super Sega mode the debug unit at $FB–$FF answers reads too), so the SMS mirror of $DC/$DD across $C0–$FF no longer functions in that window. Any controller read routed through a mirror address in that range silently reads a Super Sega register instead. This is the highest-severity conversion hazard because it fails without an obvious symptom.

Byte-level scanning cannot resolve this — a 256 KB binary produces `DB`/`D3` false positives throughout its data. Detection requires a disassembly pass over real code. The `SMS_AnnotatePorts.py` script bookmarks every access it can resolve to $F0–$FA or $06–$0A under a "Super Sega decode review" category, and every access whose port it cannot resolve under "Port unresolved". Checking both categories is this audit, and it should run before any other conversion step on both titles. **v7:** the script's ranges predate v7 and must widen to $F0–$FF and $00–$16 before the audit runs.

**Low-range port decoding.** Super Sega decodes $00–$16 as registers (**v7**; v5 had $06–$0A) — the Game Gear registers at $00–$06 and the Super Sega registers at $07–$16 — while keeping $3E/$3F functional. An SMS ROM writing memory or I/O control through a low mirror in that range reaches one of those registers instead (a write to $00 does nothing). A byte-level scan of Golden Axe Warrior found one genuine low-port write: `OUT ($06),A` in its sound driver's stereo command (bank 6, $1875D). Super Sega treats $06 as the stereo register, so that write does what its authors intended; every other candidate was data. Ax Battler's low-port writes are the known Game Gear stereo sites. A disassembly pass is still needed on both titles to rule out writes through (C). If that scan covered only v5's $06–$0A, ports $00–$05 and $0B–$16 need the same check. Where the Super Sega registers at $07–$16 finally live is still open (Q1; the candidate is above $F0), so the audit covers both ranges until that is decided.

**ROM size ceiling.** Ax Battler requires expansion beyond the stock image: it has 2,231 bytes of probable free space (end-of-bank $FF runs of 32 bytes or more) across eleven paged banks, reachable only through a trampoline in the fixed region — 88 bytes at $7F98–$7FEF in the stock ROM. Golden Axe Warrior has 16,484 bytes of probable free space across 13 banks, and a 1,213-byte zero-filled gap directly before its header (bank 1, $7B33–$7FEF) for the trampoline. The Super Sega mapper's maximum addressable ROM is a machine value, not a fixed constraint, and had to be settled before bank layout is designed. **v7:** the Sega mapper's 8-bit bank registers reach 4 MB; only sizes beyond that are open (machine open question Q2), so expanding either title to 512 KB or 1 MB needs no new mapper.

---

## 5. Build sequencing

Golden Axe Warrior first, despite Ax Battler being the more interesting project.

Rationale: GAW requires no viewport work and no reverting of a third-party patch, so it exercises the palette pipeline, ESAT conversion, DMA path, window layer, stereo and FM work in isolation. Each of those is then a known-good procedure when applied to Ax Battler, where they would otherwise be entangled with viewport expansion and gameplay rewriting.

1. Port-decode hazard audit on both ROMs
2. Golden Axe Warrior: header retag, palette re-authoring, ESAT conversion
3. Golden Axe Warrior: DMA transitions, window-layer HUD, stereo panning, then FM driver and tracks
4. Ax Battler: strip v1.2, retag header, verify stock GG palettes and stereo under Super Sega
5. Ax Battler: viewport expansion to 256×192 and encounter-distance retune
6. Ax Battler: gameplay work per the separate feel audit, then the stage-format work

---

## 6. Machine questions and v7's answers

The plan listed these as open against the v5 document. Machine profile v7 answers them as follows; two answers leave a part open, as noted (the profile's open questions are numbered Q1–Q14):

- **Maximum ROM size and mapper register layout for expanded images.** Up to 4 MB with the stock Sega mapper registers; the layout above 4 MB is still open (Q2).
- **ESAT entry format, and whether H-flip is per-sprite or per-tile.** 2 bytes per sprite, with H-flip and V-flip per sprite (Q4, resolved in v6). One loose end: Feature Enable C bit 4 still selects a "2-byte" mode, and the emulator uses a 1-byte layout while that bit is clear. Either the bit is retired or the 1-byte layout is documented (Q13); a conversion should set the bit until then.
- **Whether 1024-tile unique-cell mode and the 32 KB VRAM expansion are independently selectable or coupled.** Coupled: unique-cell mode needs VRAM expansion (Feature Enable B bit 4) (Q5).
- **Turbo default state for retagged ROMs, and whether it is profile-set or per-title.** Off at reset. A retagged ROM that wants turbo turns it on itself (Feature Enable A bit 6, then the step on $F3). The enhancement layer's turbo boost is for unmodified software only and never applies to a Super Sega title (Q6).
- **Whether reverting a prior conversion patch is expected to be a documented workflow**, given that other GG titles carry similar third-party GG2SMS layers. An emulator (hack maker) workflow, not a machine question (Q10).
