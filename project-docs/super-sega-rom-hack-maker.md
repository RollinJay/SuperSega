# Super Sega ROM Hack Maker — Framework Specification

*Draft 1 · 5 October 2026. This document defines the mod-making system inside the Super Sega emulator, the plugin model that adds games to it, and the launch roster. Related document: the Golden Axe Super Sega conversion plan (`golden-axe-super-sega-conversion.md`), which covers converting Golden Axe Warrior and Ax Battler to Super Sega hardware features.*

---

## 1. What the system is

The Super Sega emulator includes a ROM hack maker: tools for making modified versions of existing games, called **mods**. Three rules set its shape.

1. **The maker exists only in the emulator.** The Super Sega console plays modded games. It does not make or apply mods.
2. **Every mod is distributed as a patch.** A patch holds only the differences between the original game and the modded one, and each player applies it to their own copy of the original. No original game data ships with the emulator, a plugin, or a mod.
3. **Games are added through plugins.** A plugin teaches the maker about one game: how to recognise it, where its code and data are, and how to edit them. The project makes the launch plugins. The community makes plugins for other games through the same interface.

Once a patch is applied, the result is an ordinary ROM file, so a mod runs on any hardware its target allows (section 6).

---

## 2. Background and terms

### 2.1 Banks, slots and the fixed region

Master System and Game Gear games are stored in 16 KB **banks**. The console sees only three banks of a game at a time, through three windows called **slots**. A chip on the cartridge, the **mapper**, chooses which bank appears in each slot; the game controls it by writing a bank number to one of its registers:

| Slot | Address range | Bank chosen by writing to |
|---|---|---|
| 0 | `$0000–$3FFF` (its first 1 KB, `$0000–$03FF`, never changes) | `$FFFD` |
| 1 | `$4000–$7FFF` | `$FFFE` |
| 2 | `$8000–$BFFF` | `$FFFF` |

A game swaps (**pages**) banks into slots as it runs. Most games page only slot 2 and leave banks 0 and 1 in slots 0 and 1 permanently. A fourth mapper register, `$FFFC`, can switch battery-backed **save RAM** into slot 2 in place of a ROM bank; that is how cartridges keep saved games.

The **fixed region** is every part of the ROM the game never pages out. New code a mod adds usually lives in a bank of its own, so the game needs a way to reach it at any moment. That way is a **trampoline**: a short routine in the fixed region that pages the mod's bank in, runs the mod code, and restores the game's bank. Free space in the fixed region is therefore the scarcest resource in any hack, and section 7 reports it for every title.

### 2.2 The cartridge header

Most cartridges carry a 16-byte header at `$7FF0` beginning with the text `TMR SEGA`. It holds a **region code** (which console family the cartridge is for), a **size code**, and a **checksum**: a sum of the ROM's bytes that lets a console detect a corrupted or unofficial cartridge.

| Region code | Meaning (name used by tools) |
|---|---|
| 4 | Master System, sold outside Japan (*SMS Export*) |
| 5, 6, 7 | Game Gear: Japan, outside Japan, worldwide (*GG Japan*, *GG Export*, *GG International*) |
| 8 | Super Sega |

The start-up program built into Master Systems sold outside Japan (the **BIOS**) refuses to boot a cartridge whose checksum is wrong. The Game Gear does not check it, and Game Gear games commonly leave it at zero.

### 2.3 Terms

| Term | Meaning |
|---|---|
| ROM | The data of a game cartridge, as a file |
| Base ROM | The exact, unmodified ROM a plugin or mod is built against |
| Hash | A fingerprint of a file's bytes. Identical files have identical hashes. The maker uses CRC32 and SHA-1 |
| Trace | A log the emulator writes of every instruction a game runs, with the bank it ran from. It confirms which code and data a game really uses |
| Plugin | A package adding support for one game to the maker |
| Mod | A modified version of a game |
| Mod project | A mod's editable working form inside the maker |
| Patch | A mod's distributable form. The maker writes **BPS** patches, which record the hashes of the base ROM and of the result, so a BPS patch refuses to apply to the wrong file |
| Support tier | How much of a game a plugin exposes for editing (section 3) |
| Baseline | A game supported well enough that new games can be built from it (tier 3) |
| Target | The hardware a mod is built for: Master System, Game Gear or Super Sega (section 6) |

---

## 3. Support tiers

Each plugin declares a tier. Each tier includes everything below it.

| Tier | The plugin provides | The maker unlocks | Typical effort |
|---|---|---|---|
| **0 · Identified** | Hashes, title, platform and revision of each supported ROM | Raw patch import and creation, header and checksum repair, the emulator's debugger and trace logger | Minutes |
| **1 · Mapped** | Names for the game's RAM variables and ROM routines | Labelled debugging, memory watches, readable traces, gameplay measurement such as attack timing or jump physics | Days to weeks |
| **2 · Hookable** | Where the code, data and free space are; safe places to insert new code; instructions for enlarging the ROM | Code mods: new routines for the console's Z80 processor, assembled by the maker and inserted into the game | Weeks |
| **3 · Editable** | Readers and writers for the game's content — graphics, palettes, maps and levels, text, stat tables — and editors built on them | Content mods made in editors, without writing code | Months |

A game becomes a **baseline** at tier 3. The lower tiers still matter: tier 1 is what makes a game measurable, and tier 2 is what engine changes such as new enemy behaviour need.

**The round-trip gate.** A **codec** is a reader-and-writer pair for one kind of data: it decodes bytes into something editable and encodes them back. Decoding the base ROM's data and re-encoding it unchanged must reproduce the original bytes exactly. The maker runs this test every time a plugin loads and refuses any codec that fails it, because a subtly wrong codec corrupts every mod built with it.

---

## 4. What a plugin contains

A plugin is a folder or zip file holding a manifest and the files the manifest lists. Section 4.1 shows the manifest; sections 4.2–4.7 describe each kind of content in tier order.

### 4.1 Manifest

A tier-0 manifest needs only identification. The values below are the real ones for Astro Warrior from this roster's audit (Appendix A); the field names are a proposal.

```json
{
  "api": 1,
  "plugin": "astro-warrior",
  "title": "Astro Warrior",
  "tier": 0,
  "bases": [
    {
      "id": "aw",
      "name": "Astro Warrior (Japan, USA, Brazil) (En)",
      "platform": "sms",
      "revision": 0,
      "size": 131072,
      "crc32": "299CBB74",
      "sha1": "901697a3535ad70190647f34ad5b30b695d54542"
    }
  ],
  "targets": ["sms", "supersega"]
}
```

`api` is the plugin interface version, so the maker can refuse or adapt plugins written for an older interface. `revision` is the version number in the ROM's header. Higher tiers add one field per base for each file they supply:

| Field | Required from tier | Contents |
|---|---|---|
| `symbols` | 1 | Symbol file (4.3) |
| `regions` | 2 | Region map (4.4) |
| `hooks` | 2 | Hook points (4.5) |
| `expansion` | 2 | Expansion recipe (4.6) |
| `codecs`, `editors` | 3 | Codec and editor definitions (4.7) |

### 4.2 Identification

**A plugin binds to exact ROMs by hash, never by name.** File names are unreliable: the Master System and Game Gear versions of Master of Darkness circulate under near-identical names (CRC32 `96FB4D4B` and `07D0EB42` respectively).

**Each revision is its own base**, with its own addresses, because a revised ROM moves code and data. Fantasy Zone's header marks the supplied ROM as revision 2, so earlier revisions exist; the launch plugin covers revision 2 only.

**One plugin may carry several bases.** Ax Battler's plugin can carry the stock Game Gear ROM; the GG2SMS v1.2 build (the result of a community patch that converts the game to run on a Master System); and, later, the improved engine build — the gameplay overhaul this project plans for Ax Battler, once it is frozen. The Master System and Game Gear versions of Master of Darkness share 6 of their 16 banks byte for byte (banks 7, 8, 10, 13, 14 and 15), so one plugin could carry both and share its data descriptions for those banks. The two versions of Aerial Assault, by contrast, share no banks and use different sound drivers: for a plugin they are effectively two games.

### 4.3 Symbols (tier 1)

Symbols use the WLA-DX `.sym` format: one `bank:address name` entry per line. WLA-DX, a widely used SMS assembler, writes this format and the Emulicious emulator's debugger reads it, so a game built from source gets tier 1 almost for free.

### 4.4 Region map (tier 2)

The region map classifies every range of the ROM as code, data (with its type), free, or unknown. Free ranges carry a confidence:

- **Confirmed** — a trace shows the game never reads or executes the range.
- **Probable** — the range is only filler bytes. A run of `$FF` at the end of a bank is usually free. A run of `$00` is often blank graphics or a zeroed table and needs a trace before use.

The region map also records which slots the game pages after boot, which defines its fixed region, and whether the game uses save RAM.

### 4.5 Hook points (tier 2)

A **hook point** is a place where a mod can divert the game's code into its own routine and then return. Each hook point records:

- its address and bank, and the original bytes the hook overwrites (the maker checks these before patching);
- the registers and flags the mod code must preserve;
- which bank each slot holds when the hook runs;
- any bookkeeping the game expects from code that pages banks.

That last item is easy to miss and fatal when missed. Example from the audit: Ax Battler's frame interrupt (code the console runs every frame) pages slot 2 several times through a routine at `$00B4` that does not update the game's RAM copy of the slot-2 bank number at `$C00C`, then finishes by restoring slot 2 from that copy. Mod code that pages its own bank into slot 2 must therefore either use the game's routine at `$00A9`, which updates `$C00C` too, or keep interrupts disabled until it restores the bank. Otherwise the next interrupt swaps the wrong bank back in mid-routine.

Golden Axe Warrior shows the opposite design. Its frame interrupt (the routine at `$01E3`) reads the current slot-2 bank and save-RAM setting back before switching, and restores both exactly, so mod code in that game can page slot 2 directly. Games that look alike can need opposite rules, which is why every hook point records its game's contract rather than assuming one.

### 4.6 Expansion recipe (tier 2)

How to enlarge the ROM (for example from 256 KB to 512 KB): where new banks begin, where the trampoline lives, and what header changes the larger size needs. Titles with little free space need expansion before any substantial mod.

### 4.7 Codecs and editors (tier 3)

Codecs are pure functions: bytes in, editable data out, and back. Editors are declared rather than programmed wherever possible — a table editor over a record layout, a tile editor, a map editor over a tilemap codec, a text editor over a text codec and its character table. Custom editor code is allowed but discouraged, because declared editors are safer to share and easier to maintain.

### 4.8 Plugin code and safety

Plugins are mostly data. Where a codec needs real code, such as a decompressor, that code runs isolated: no network access and no access to the rest of the emulator — bytes in, bytes out. Community plugins are treated as untrusted.

### 4.9 What a plugin must never contain

Anything copied from a ROM: graphics, text, maps, music or code. A plugin describes where data is and how to read it; the player's own ROM supplies the data. This is what keeps plugins freely distributable.

---

## 5. From edit to patch

1. **Load.** The player opens a ROM. The maker hashes it and finds the matching plugin and base. A ROM no plugin knows opens in raw mode: debugger, trace logger and raw patch creation only.
2. **Edit.** Changes are stored in the mod project as edits to decoded data, plus code and hook entries. The base ROM is never modified in place.
3. **Build.** The maker encodes the edited data, assembles code and places it in free space, applies hooks, enlarges the ROM if the mod needs it, and rewrites the header for the target.
4. **Test.** The built ROM runs in the emulator under the target's own hardware profile.
5. **Make the patch.** The maker writes a BPS patch from the base ROM to the built ROM.
6. **Apply.** Given a patch and a ROM, the maker checks the ROM's hash, applies the patch, and checks the result's hash.

**Header and checksum.** Every build for the Master System target gets a recomputed checksum, because the BIOS checks it (section 2.2). All four Game Gear ROMs audited here leave their checksum at zero. The header's size code is not reliable for anything else: Defenders of Oasis declares 256 KB in a 512 KB ROM, so the maker takes the ROM size from the file.

**Combining mods.** BPS patches cannot be chained. A patch is built against one exact file, and another mod's output is not that file. Mods are therefore combined at the project level: the maker merges mod projects for the same base, reports conflicts (the same data edited twice, overlapping hooks, two mods claiming the same free space), and builds one ROM. A mod can only be combined if its author ships its project file alongside its patch (open decision 6).

**Importing existing hacks.** IPS and BPS patches import as raw changes. IPS patches carry no hashes, so the maker records the result's hash at import and can register the result as a new base. The Ax Battler GG2SMS v1.2 patch is the first case.

---

## 6. Targets

| Target | Header region code | Features allowed | Runs on |
|---|---|---|---|
| Master System | 4 | Stock Master System hardware | Super Sega console, emulator SMS profile, original Master System |
| Game Gear | 5–7 | Stock Game Gear hardware | Super Sega console (Game Gear mode), emulator GG profile, original Game Gear |
| Super Sega | 8 | Super Sega extensions, each opted into as the Super Sega hardware specification requires | Super Sega console and emulator Super Sega profile only |

The test step runs every build under its target's own profile, where Super Sega extensions do not exist, so a Master System or Game Gear mod that accidentally depends on one fails visibly before the patch is made.

The Super Sega machine also has an Analogue Pocket implementation (`../pocket-core/docs/SuperSega_Pocket_Core_Design.md`). Its first milestone, so far checked in simulation only, runs Master System and Game Gear software, but it does not yet draw every Super Sega extension or have the FM unit (Technical Reference v3, §19). The emulator's Super Sega profile therefore stays the reference for testing Super Sega mods (section 5, step 4).

---

## 7. Launch roster

### 7.1 Summary

Free-space figures are probable, from static analysis (definitions in Appendix A). **Trampoline candidates** are filler runs in banks the game never pages: runs of `$FF` of 16 bytes or more, and runs of `$00` of 8 bytes or more in padding positions (the never-paged first 1 KB, or directly before the header). **Genre template** is the kind of game a mod built on the title naturally becomes.

| Title | Platform | Genre template | Size | Probable free space | Trampoline candidates | Save RAM |
|---|---|---|---|---|---|---|
| Golden Axe Warrior | SMS | Top-down action-adventure (*Zelda* style) | 256 KB | 16,484 B | 1,241 B `$00` | yes |
| Ax Battler | Game Gear | Overworld with side-view fights (*Zelda II* style) | 256 KB | 2,231 B | 88 B `$FF`; 59 B `$00` | none found |
| Master of Darkness | SMS | Side-scrolling action platformer (*Castlevania* style) | 256 KB | 15,228 B | 87 B `$00` | none found |
| Astro Warrior | SMS | Vertical-scrolling shooter | 128 KB | 33,058 B | none | none found |
| Fantasy Zone (Rev 2) | SMS | Free-scrolling arena shooter | 128 KB | 2,962 B | 242 B `$FF` | none found |
| Aerial Assault | SMS | Forced-scrolling horizontal shooter | 256 KB | 63,294 B | 549 B `$FF`; 11 B `$00` | none found |
| Defenders of Oasis | Game Gear | Turn-based RPG | 512 KB | 70,207 B | none | yes |
| Super Mario Bros. multicart | SMS | Side-scrolling platformer | per release | per release | per release | yes |

### 7.2 Notes by title

**Golden Axe Warrior.** Planned role: the full-coverage reference plugin, because this one game contains every kind of editor the interface must support — overworld and dungeon maps, text, shops, item and enemy tables. The audit supports that role. The ROM pages slot 2 only and has a valid checksum. Its 16,484 bytes of probable free space are spread over 13 banks, and bank 1 ends in 1,213 zero bytes at `$7B33–$7FEF`, directly before the header: the largest trampoline site on the roster, pending a trace. Its text is plain ASCII in two forms — mixed-case dialogue ending in `$00`, and upper-case story text using `$FF` as a line break — so its text codec is close to trivial. Battery-backed save RAM is switched on by the routine at `$0444`, which first disables interrupts, and off by the one at `$043A`, which re-enables them. Its frame interrupt restores slot 2 exactly (section 4.5), so hooks may page directly.

**Ax Battler.** Bases: the stock Game Gear ROM, where the Super Sega conversion starts, and the GG2SMS v1.2 build. The game contains routines for paging slot 1 (at `$00A2` and `$00B0`), but no `CALL` or `JP` to either exists, and the five places the value `$00B0` appears in bank 1 are the number 176 used as data. Slot 1 is otherwise written only at boot, so bank 1 behaves as fixed; a trace should confirm this. That makes `$7F98–$7FEF` (88 bytes of `$FF`, directly before the header) usable for the trampoline in the stock ROM. The GG2SMS build puts its pad-detection routine at `$7FA0–$7FBB`, leaving 60 bytes. Two zero-filled gaps in the never-paged first 1 KB, `$0053–$0065` and `$00B8–$00DF`, are a fallback once a trace shows nothing uses them. The slot-2 bookkeeping in section 4.5 applies to every hook. Caution: mods built on the stock engine inherit its stiffness; the improved engine becomes a separate base when it is frozen (open decision 5).

**Master of Darkness.** The supplied ROM is the Master System version (header region 4, valid checksum), native 256×192. A Game Gear version was supplied first and set aside. The game pages slot 2 only. Banks 0 and 1 hold no `$FF` free space, but bank 1 ends in 87 zero bytes at `$7F99–$7FEF`, directly before the header: almost certainly padding, and the natural trampoline site once a trace confirms nothing reads it. The Master System version was also sold in Brazil, whose consoles run at 60 Hz, so 60 Hz play is a configuration it shipped in.

**Astro Warrior.** The simplest memory layout on the roster: slot 2 paging only, a valid checksum, and bank 7 entirely empty (16,384 bytes), so substantial mods need no expansion. Its fixed banks hold no trampoline candidates: no `$FF` space at all, and bank 0's zero-filled runs (the largest 108 bytes, at `$1CD4`) sit mid-bank, where they are more likely data. The first hook therefore needs room made for it — for example, by moving an existing routine into the empty bank behind a short stub.

**Fantasy Zone.** Tight on space: 2,962 bytes probably free, second only to Ax Battler's 2,231. Its fixed region has 242 bytes of `$FF`: the unused restart vectors at `$0008–$0037`, then `$003B–$0065` and `$7F59–$7FEF`. Hooks are therefore cheap, but new content needs expansion to 256 KB first. As a template it produces Fantasy Zone-like games — looping stages, enemy bases to destroy, a shop — rather than general shooters.

**Aerial Assault.** The baseline is the Master System version (USA): header region 4, valid checksum, slot 2 paging only, and 63,294 bytes of probable free space, the most of any Master System title on the roster. Bank 1 ends in 479 bytes of `$FF` at `$7E11–$7FEF`, directly before the header: the trampoline site. Its sound driver (bank 7) handles both the PSG and the YM2413 FM chip built into Japanese Master Systems, but the FM half is switched off. The boot routine at `$00D9` writes 0 to the FM control port `$F2` and to the driver's mode flag at `$D000`; no other instruction in the ROM writes either one directly, and the game never reads `$F2` back, so it never checks for an FM unit. That matches its absence from community lists of FM-supporting games. Whether FM music data exists is untested. If it does, a small boot patch could give the game an FM soundtrack on Super Sega, which always has the FM chip; a Master System build would also need real FM detection, since most Master Systems have no FM chip. (The Analogue Pocket implementation of the Super Sega does not have the FM unit yet. A patch that assumes FM without checking would get nothing from the FM chip there, possibly no music at all, until it does; checking for FM, as a Master System build must, would let it fall back to the PSG music.) Test this in the emulator before planning any other audio work for the title. The Game Gear version (World) shares no banks with it, uses a different sound driver, and has only 452 bytes free, so it is identified (tier 0) only.

**Defenders of Oasis.** The most free space on the roster. Banks 25, 26 and 27 each begin with the developers' own marker text, `** Empty Bank **`, and are otherwise `$FF`; together with the end of bank 24 they hold 58,229 bytes. Banks 28–31 are byte-identical copies of banks 12–15, and may be reclaimable once a trace shows the game never maps them. Battery-backed save RAM is switched on by the routine at `$0EF4` and off by the one at `$0EFC`. The game writes slots 1 and 2 together at runtime — in a bank-switch helper starting at `$09F5`, and in register-restoring code at `$04D4` that appears to end its interrupt handler — so only bank 0 should be treated as fixed until a trace shows slot 1 always holds bank 1. Slot 0 is never paged: the `$FFFD` values found elsewhere are the number −3 used as data. Bank 0 has no trampoline candidates — its only gap is 64 zero bytes mid-bank at `$0A8C`. If a trace shows slot 1 always holds bank 1, the 879 zero bytes at `$7C81–$7FEF`, directly before the header, become the obvious site; otherwise the first hook needs room made for it, as with Astro Warrior. As a Game Gear game it raises the screen-size question in section 7.3.

**Super Mario Bros. multicart.** Built from source by this project, so tiers 1 and 2 come almost free (the assembler produces the symbols), and the project's own HTML5 level editor is a ready-made tier-3 editor. Its blocker is distribution, not engineering (open decision 1). The plugin binds to a frozen multicart release; each new release is a new base.

### 7.3 Gaps and alternatives

**Two Game Gear titles.** Ax Battler and Defenders of Oasis run at 160×144. Ax Battler's screen-size question is settled: its new battlefields are authored for the Master System screen. For Defenders it is open, and expanding an RPG is mostly interface relayout — menus, text windows, the battle screen — likely more work than Ax Battler's expansion. If a Master System-resolution RPG matters, **Phantasy Star** (Master System, Sega) is native 256×192 and already has a community disassembly, by lorenzo, hosted by Phantasy Star Cave; whether it reassembles into an identical ROM is unverified. Its first-person 3D dungeons would come with it as part of the template.

**Horizontal shooter — filled.** Astro Warrior scrolls vertically and Fantasy Zone loops in both directions, so neither covered the most common shooter form: a stage that scrolls one way toward a boss. Aerial Assault (Master System, 1990; developed by Sanritsu, published by Sega) now fills it — the same arrangement of outside developer and Sega publisher as Master of Darkness (developed by SIMS).

---

## 8. Launch scope (proposal)

- **Every roster title at tier 0.** Hash lists only — minutes of work each.
- **Astro Warrior to tier 3 first, to prove the whole pipeline.** Verified reasons: the simplest paging on the roster, a valid checksum, and an empty bank, so no expansion is needed. Its data formats are not yet mapped, so its effort is still an estimate.
- **Golden Axe Warrior to tier 3 second, as the full-coverage reference.** Every editor type the interface must support appears in it, and the audit found it easy to hook: plain-ASCII text, a 1,213-byte trampoline site, and an interrupt that restores banks exactly. It remains the first of the two Golden Axe titles, as the conversion plan sets out.
- **The Super Mario Bros. multicart to tier 3 if its distribution is settled** — the fastest title to finish, because its symbols and its editor already exist.
- **The remaining titles advance one tier at a time after launch**, each tier released once its contents are verified against the base ROM (for tier 3, by the round-trip gate).
- **Every first-party plugin is built through the public interface.** If a launch plugin needs a private path into the maker, the interface is not finished.

---

## 9. Open decisions

| # | Decision | Options | Notes |
|---|---|---|---|
| 1 | Super Mario Bros. multicart distribution | First-party launch title, or a separately released plugin built on the public interface | The content is Nintendo's. The SMS port it builds on is currently published without public source or a license statement (v1.10, 1 October 2026; v1.00 shipped with source) |
| 2 | Launch bar | The section 8 proposal, or a different tier per title | Sets the launch date more than any other decision |
| 3 | RPG baseline | Defenders of Oasis at 160×144; Defenders expanded to 256×192; or Phantasy Star | Section 7.3 |
| 4 | Horizontal shooter template | **Decided:** Aerial Assault, Master System version | Sections 7.2 and 7.3 |
| 5 | Ax Battler base ROM | Proposed: stock ROM at launch, improved engine added as a new base when frozen | Resolves whether Ax Battler is a launch or a later title |
| 6 | Combining mods | Let mods ship project files so the maker can merge them | Without it, a player can run only one mod per game at a time |
| 7 | Super Sega mapper limits | Maximum ROM size and save-RAM size | Expansion recipes for the Super Sega target depend on both. Machine profile v7: up to 4 MB is reachable with the stock 8-bit bank registers, so only sizes beyond 4 MB (open question Q2) and the save-RAM size (Q3) remain open (Technical Reference v3, §8 and §17) |

---

## Appendix A. Base ROM audit

**Method.** Static analysis of each ROM file as supplied. Paging comes from direct writes to the mapper registers `$FFFC–$FFFF`; candidate indirect writes were checked by hand, and most turned out to be numbers such as −2 (`$FFFE`) or −3 (`$FFFD`) used as data. **Probable free space** is `$FF` at the end of a bank (runs of 32 bytes or more) plus `$FF` runs of 256 bytes or more elsewhere. Runs of `$00` are listed but not counted, since they are often blank graphics. **Trampoline candidates** are defined in section 7.1. Every finding here is static; a trace is the confirmation step.

**Master System ROMs**

| | Golden Axe Warrior | Master of Darkness | Astro Warrior | Fantasy Zone | Aerial Assault |
|---|---|---|---|---|---|
| File | `Golden Axe Warrior (USA, Europe, Brazil) (En).sms` | `Master of Darkness (Europe).sms` | `Astro Warrior (Japan, USA, Brazil) (En).sms` | `Fantasy Zone (World) (Rev 2).sms` | `Aerial Assault (USA).sms` |
| Size (bytes) | 262,144 | 262,144 | 131,072 | 131,072 | 262,144 |
| CRC32 | `C7DED988` | `96FB4D4B` | `299CBB74` | `65D7E4E0` | `15576613` |
| Header region | 4 (SMS Export) | 4 (SMS Export) | 4 (SMS Export) | 4 (SMS Export) | 4 (SMS Export) |
| Product · revision | 7505 · 0 | 7107 · 0 | 5069 · 0 | 5052 · 2 | 7041 · 0 |
| Declared size | 256 KB | 256 KB | 128 KB | 128 KB | 256 KB |
| Checksum | `$3BF5`, valid | `$6FE6`, valid | `$7511`, valid | `$82EB`, valid | `$D7CF`, valid |
| Slots paged after boot | 2 | 2 | 2 | 2 | 2 |
| Save RAM | yes | none found | none found | none found | none found |
| End-of-bank `$FF` | 16,484 B in 13 banks | 15,228 B in 13 banks | 28,428 B in 6 banks | 1,689 B in 4 banks | 62,815 B in 14 banks |
| Other `$FF` runs ≥ 256 B | — | — | 4,630 B in 6 runs | 1,273 B in 2 runs | 479 B in 1 run |
| `$00` runs ≥ 256 B (not counted) | 1,213 B | 860 B | — | — | 480 B |
| Trampoline candidates | `$7B33–$7FEF`, `$0055–$0065`, `$0075–$007F` `$00` | `$7F99–$7FEF` `$00` | none | `$0008–$0037`, `$003B–$0065`, `$7F59–$7FEF` `$FF` | `$7E11–$7FEF`, `$1FA0–$1FBF`, `$7BEB–$7BFF`, `$7C27–$7C37` `$FF`; `$002D–$0037` `$00` |
| Duplicate banks | none | none | none | none | none |

**Game Gear ROMs**

| | Ax Battler | Defenders of Oasis | Aerial Assault (identified only) |
|---|---|---|---|
| File | `Ax Battler - A Legend of Golden Axe (USA, Europe).gg` | `Defenders of Oasis (USA, Europe).gg` | `Aerial Assault (World).gg` |
| Size (bytes) | 262,144 | 524,288 | 131,072 |
| CRC32 | `663BCF8A` | `E2791CC1` | `3E549B7A` |
| Header region | 6 (GG Export) | 7 (GG International) | 7 (GG International) |
| Product · revision | 2405 · 0 | 2503 · 0 | 3219 · 0 |
| Declared size | 256 KB | 256 KB (file is 512 KB) | 128 KB |
| Checksum | `$0000`, unused | `$0000`, unused | `$0000`, unused |
| Slots paged after boot | 2 (slot-1 routines present, never called) | 1 and 2 | 2 |
| Save RAM | none found | yes | none found |
| End-of-bank `$FF` | 2,231 B in 11 banks | 70,207 B in 21 banks | 452 B in 4 banks |
| Other `$FF` runs ≥ 256 B | — | — | — |
| `$00` runs ≥ 256 B (not counted) | 575 B | 879 B | 367 B |
| Trampoline candidates | `$7F98–$7FEF` `$FF`; `$0053–$0065`, `$00B8–$00DF` `$00` | none | `$7FB3–$7FEF` `$00` |
| Duplicate banks | none | 26 and 27 copy 25 (the empty banks); 28–31 copy 12–15 | none |

File names are as supplied, except Ax Battler's, which was uploaded with underscores in place of spaces and punctuation; the hashes identify it.

**SHA-1 hashes**

| ROM | SHA-1 |
|---|---|
| Golden Axe Warrior | `fbda0486b393708a89756bb57d116ad6007484e4` |
| Ax Battler | `9f5bf2973225b8ee337fcec460829724a0c63d9e` |
| Master of Darkness (SMS) | `ed3569be5d5a49ff5a09b2b04ec0101d4edfa81e` |
| Astro Warrior | `901697a3535ad70190647f34ad5b30b695d54542` |
| Fantasy Zone (Rev 2) | `0278cd120dc3a7707eda9314c46c7f27f9e8fdda` |
| Defenders of Oasis | `07c1167c3b6eea294a73272c256934406f48f9d5` |
| Aerial Assault (SMS) | `e57b1d4476ca33d18d9071e022ddc9cc702d6497` |
| Aerial Assault (Game Gear, identified only) | `cbdbaaeb62a8483d9d5a8757b0f19233dfb9b416` |
| Master of Darkness (Game Gear, set aside) | `f9eabdb7e925360f69b41f5357abcb36f893d72e` |

These are the hashes of the files supplied. Check them against the current No-Intro database before publishing plugins.

---

## Sources

External facts in this document, as checked on 5 October 2026:

- Super Mario Bros. SMS port release status and source availability: [SMS Power! — Super Mario Bros. SMS Port](https://www.smspower.org/Homebrew/SuperMarioBrosSmsPort-SMS)
- Master System BIOS checksum requirement (GG2SMS notes on fixing the checksum for real hardware): [SMS Power! — Ax Battler GG2SMS](https://www.smspower.org/Hacks/AxBattler-GG-GG2SMS)
- Master of Darkness Master System release in Europe and Brazil: [Sega-16 — Master of Darkness review](https://www.sega-16.com/?p=23380), [TASVideos forum — posts by KrazyRasmus](https://tasvideos.org/Forum/Posts/User/KrazyRasmus); Brazil's consoles running at 60 Hz: [TASVideos forum — SMS PAL and NTSC](https://tasvideos.org/Forum/Topics/18369)
- Phantasy Star disassembly: [Phantasy Star Cave — Disassemblies](https://pscave.com/dow/disassemblies/)
- Aerial Assault developer, publisher and release: [Wikipedia — Aerial Assault](https://en.wikipedia.org/wiki/Aerial_Assault)
- Community list of FM-supporting Master System games (Aerial Assault absent): [ConsoleMods — Master System FM Audio Information](https://consolemods.org/wiki/RetroRGB_Migration:Fmaudio)
