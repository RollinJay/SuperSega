#!/usr/bin/env python3
"""Build super_sega_machine_v7.json from v6.

v7 folds in the updates to the machine that were made in other chats, the
stock-hardware behaviour the emulator was corrected to follow (which every
implementation of the machine must follow, the Pocket core included), and
internal inconsistencies found in v6. Every change is listed in v7_changes.
Usage: make_profile_v7.py v6.json v7.json
"""
import json, sys, copy

src, dst = sys.argv[1], sys.argv[2]
v6 = json.load(open(src))
p = copy.deepcopy(v6)

p['$schema'] = 'super-sega-machine-block/v7'
p['supersedes'] = 'super_sega_machine_v6.json'
p['scope'] = (
    'This file defines the machine: the console hardware, the jobs its FPGA performs '
    'and the behaviour its BIOS exposes. Implementations of the machine are the physical '
    'console, the HTML5 emulator\'s machine model and the Analogue Pocket core. '
    'Emulator-only features (ROM hack maker, MSX porting tools, Lab composite, merge '
    'report, the app\'s Debug tab, filters, FM dual-run capture, save states) are not '
    'part of the machine and are listed separately in SuperSega_v7_Reconciliation.md.')

changes = []
def change(text): changes.append(text)

# ------------------------------------------------------------------ ports $00-$05
pm = p['port_map']['registers']
pm['0x00'] = ('Game Gear port 0: bit 7 Start (0 = pressed), bit 6 region (1 = export), '
              'bits 5-0 read 0. Decoded in Game Gear AND Super Sega modes.')
pm['0x01-0x05'] = 'Game Gear serial / EXT link registers, Game Gear and Super Sega modes'
change('Port $00 is decoded in Super Sega mode as well as Game Gear mode. v6 said GG mode '
       'only, but the Golden Axe conversion plan reverts Ax Battler\'s GG2SMS Start patch and '
       'relies on the stock $00 read, and the emulator already decoded it in both modes. '
       'Format corrected: bits 5-0 read 0 (the emulator returned 1s, so bit 5 reported PAL).')
change('Ports $01-$05 (Game Gear serial/EXT link) listed explicitly for GG and Super Sega '
       'modes; v6 named the serial link under input.multiplayer but gave no ports.')

p['port_map']['io_chip_disable'] = (
    '$3E bit 2 disables the controller decode (the $DC/$DD mirror across $C0-$FF) on the '
    'Master System and on Super Sega. It has no effect on the Game Gear, even in SMS mode. '
    'It does not affect $F2 (FM detection) or Super Sega\'s fully decoded $F0-$FF window.')
change('$3E bit 2 scope specified: controller decode only; not on Game Gear; not $F2 or Super Sega\'s $F0-$FF.')

p['port_map']['super_sega_read_values'] = {
    '0x07-0x16': 'decoded by the FPGA in Super Sega mode; ports with no readable register return $FF, never the controller mirror',
    '0x08': 'PCM FIFO fill, bits 6-4',
    '0x09': 'slot source select, as written',
    '0x0B': 'extended card bank, as written',
    '0x0E': '0 (operation complete)',
    '0x0F-0x10': 'math result, low then high',
    '0x16': '$81: pad detected, detection complete',
    '0xF0-0xF1, 0xF3': '$FF',
    '0xF4-0xFA': 'DMA registers, as written',
    '0xFB-0xFF': ('debug unit: $FB the control value as written; $FC and $FD status (bit 7 debug host attached, '
                  'bit 6 set, bit 0 trace buffer full); $FE and $FF $FF'),
}
change('Read values of the Super Sega registers inside $07-$16 and $F0-$FA specified. The '
       'emulator answered every read in $07-$16 from the controller mirror, so the math '
       'result, slot readback and multitap detection could not be read.')
pm['0xFB-0xFF'] = 'debug unit (see debug_facility); reads answer only in Super Sega mode'
p['debug_facility']['availability'] = (
    'Writes reach the debug unit in every machine mode, since its purpose is inspecting stock software; stock '
    'hardware ignores writes to $FB-$FF. Reads of $FB-$FF answer from the debug unit only in Super Sega mode. In the '
    'stock modes they read as on the stock machine (the controller mirror; $FF on the Game Gear), because stock '
    'software may read its pads there.')
p['debug_facility']['read_values'] = p['port_map']['super_sega_read_values']['0xFB-0xFF']
change('Debug unit port reads: in the stock modes $FB-$FF read as on the stock machine (the controller mirror; $FF '
       'on the Game Gear), and the debug unit answers reads only in Super Sega mode, which therefore decodes $F0-$FF '
       'fully. Writes reach the debug unit in every mode, as before. The emulator answered $FB-$FD reads in every '
       'mode, so stock software reading its pads at those mirror addresses saw the debug status instead.')

# ------------------------------------------------------------------ colour
cs = p['color_system']
cs['write_modes']['native']['addressing'] = (
    'Byte-addressed as on the Game Gear: a write to an even CRAM address is held in a '
    'latch and the write to the following odd address stores both bytes of the entry '
    '(entry = address >> 1). 64 bytes for 32 entries; 512 bytes for 256 entries when '
    'extended CRAM is on.')
cs['game_gear_mode'] = 'Game Gear mode uses the native byte-addressed scheme over 64 bytes.'
change('Native 12-bit CRAM write order specified as the Game Gear byte-latch scheme. The '
       'emulator indexed entries by byte address while advancing the address per byte, so '
       'sequential writes filled every other entry; and in Game Gear mode it treated each '
       'byte as an SMS 6-bit colour, which gave every GG title wrong colours.')

# ------------------------------------------------------------------ audio
p['audio']['fm']['audio_control'] = {
    'write': '$F2 bits 1-0 select the mute/enable state',
    'read': '$F2 returns bits 1-0 of the last value written (bits 7-5 carry a C-sync '
            'counter on the Japanese SMS; Super Sega returns 0 there)',
    'detection': 'Software disables the I/O chip ($3E bit 2) before reading $F2 so the '
                 'controller decode does not drive the bus; the FM latch must still answer.',
    'source': 'MAME sms.cpp smsj_audio_control_r',
}
change('$F2 readback specified, including that it works with the I/O chip disabled. The '
       'emulator returned $FF in that state, so the standard FM detection failed.')

# ------------------------------------------------------------------ stock behaviour
p['stock_behaviour'] = {
    'note': ('Behaviour of the stock parts that every implementation must reproduce. These '
             'are not Super Sega additions; they are listed because the emulator had them '
             'wrong until October 2026 and the Pocket core is verified against it.'),
    'cpu': {
        'halt': 'An interrupt taken in HALT returns to the instruction after HALT.',
        'ei': 'Interrupts are not accepted until the instruction after EI has executed.',
        'sampling': 'Maskable interrupts are sampled between instructions.',
        'index_prefix': ('DD/FD take a displacement only for the (HL) forms. (IX+d) costs 8 '
                         'T-states more than (HL); LD (IX+d),n costs 5 more. DDCB: BIT 20, '
                         'others 23. A prefix followed by another prefix costs 4.'),
    },
    'vdp': {
        'h_scroll': ('Screen x = map x + R8 (the background moves right as R8 increases). '
                     'Latched once per line before the line is drawn; R0 bit 6 exempts rows 0-1.'),
        'v_scroll': 'R9 is latched once per frame; a write takes effect from the next frame.',
        'sprite_y': ('A sprite starts on line Y+1. When Y+1 is 241-256 it starts at Y+1-256 '
                     'instead, so Y = $F0-$FF shows its lower rows at the top of the screen '
                     '(Gearsystem and MAME; a plain 8-bit compare would differ only for 32-line '
                     'magnified sprites at Y = $E0-$EF).'),
        'extra_height': ('224/240-line modes use a 32x32 name table at (R2 bits 3-2) x $1000 + $700, '
                         'the map wraps at 256 lines instead of 224, and $D0 no longer ends the '
                         'sprite list.'),
        'event_timing': {
            'note': ('Within the 228-cycle line, these happen at fixed cycle offsets (Gearsystem\'s '
                     'model, which passes the SMS VDP test ROMs). The machine uses the 315-5535 column.'),
            'columns': 'event: SMS2 / 315-5535',
            'h_scroll_latch': '14 / 16',
            'v_counter_update': '25 / 27',
            'frame_flag': '25 / 27 (line height+1)',
            'line_interrupt': '27 / 28',
            'sprite_overflow_flag': '25 / 27 (from the previous line\'s sprites)',
            'display_enable_latch': '37 / 20',
            'line_render': '195 / 186 (background of this line, sprites of the next)',
            'collision_flag': ('20 / 22 + X x 228 / 256 of the line after the sprites were drawn, or at the render event if '
                               'that comes first (Gearsystem drops such late collisions; the hardware flags a collision '
                               'anywhere on the line)'),
            'io_access_point': 'IN/OUT reach the port 10 T-states into the instruction (IN A,(n), OUT (n),A)',
        },
        'v_counter': {
            'NTSC_192': '00-DA, D5-FF', 'NTSC_224': '00-EA, E5-FF', 'NTSC_240': '00-FF, 00-05',
            'PAL_192': '00-F2, BA-FF', 'PAL_224': '00-FF, 00-02, CA-FF', 'PAL_240': '00-FF, 00-0A, D2-FF',
            'source': ('Charles MacDonald, Sega Master System VDP documentation (which lists NTSC 240 as 00-FF, 00-06: '
                       '263 values for a 262-line frame; the implementations use 00-05)'),
        },
        'h_counter': '00-93 then E9-FF, one count per two pixels; latched on a TH edge for the light gun.',
        'frame_flag': ('Status bit 7 is set at cycle 25 (SMS2) / 27 (315-5535) of line height + 1, the second line after '
                       'the last displayed one, and stays set until the status register is read.'),
        'line_counter': ('On lines 0 to height inclusive (one line past the display) the counter counts down; '
                         'on reaching 0 it reloads from R10 and raises the line interrupt. On other lines it is '
                         'reloaded from R10. Mode 4 only (TMS modes raise no line interrupt as stock).'),
        'line_timing': '228 CPU cycles per line, 262 lines NTSC, 313 PAL; the overrun of the last instruction of a line belongs to the next line.',
    },
    'psg': {
        'tone': 'Counters run at CPU/16 and toggle the output on reaching zero; a period of 0 behaves as 1.',
        'noise': ('The noise counter (rate $10/$20/$40 or tone 2) toggles a flip-flop; the 16-bit '
                  'shift register advances on its rising edge, once per two counter periods. White '
                  'noise taps bits 0 and 3; writing the noise register resets the register to $8000.'),
        'volume': 'Attenuation 2 dB per step; 15 is silent.',
    },
    'io': {
        'low_port_reads': ('Reads of $00-$3F return $FF on the Master System, and on the Game Gear and '
                           'Super Sega for every port they do not decode as a register.'),
        'tr_readback': ('A TR pin configured as an output ($3F bit 0 or 2 clear) reads back the level '
                        'driven: $DC bit 5 for port A, $DD bit 3 for port B.'),
        'game_gear_decode': ('Above $C0 the Game Gear answers only $C0/$DC (port A) and $C1/$DD (port B, '
                             'with bits 7-6 = $3F bits 7-6); every other port reads $FF, $F2 included (no FM).'),
        'fm_latch': 'The $F2 FM detection latch answers in Master System and Super Sega modes only.',
        'source': 'Gearsystem SmsIOPorts / GameGearIOPorts',
    },
    'verification': ('Batman Returns (Europe) SMS in PAL at frames 30, 60, 120, 200, 500, 900 and 1500, and Batman '
                     'Returns (World) GG at frames 200, 500, 900 and 1500: the emulator and the Pocket core RTL '
                     '(Verilator) both match Gearsystem, Game Gear within Gearsystem\'s colour rounding (it expands '
                     'channel value 5 to 86 rather than 85). Plus VDP test ROMs at 192/224/240 lines (October 2026).'),
}
change('stock_behaviour section added: the CPU and VDP behaviour the emulator was corrected '
       'to follow, from the Super Mario Land DX port work (October 2026). These are the '
       'stock parts, not changes to the machine, but every implementation must follow them.')

# ------------------------------------------------------------------ memory fixes
p['memory']['vram']['expansion_enable'] = ('Feature Enable B (bank1 R2) bit 4 enables the 32 KB '
                                           'map; bank1 R3 bit 0 selects the bank the CPU port reaches')
change('VRAM expansion control corrected: v6 gave "bank1 R3 bit 0" in memory.vram but '
       '"bank1 R2 bit 4" in video.unique_cell_mode. R2 bit 4 enables, R3 bit 0 selects.')

# ------------------------------------------------------------------ math unit
p['math_unit'] = {
    'ports': '0x0C-0x10',
    'source_system': 'NES MMC5',
    'tier': 1,
    'registers': {
        '0x0C': 'operand A', '0x0D': 'operand B',
        '0x0E': 'write: bit 0 = 0 multiply, 1 divide; read: 0',
        '0x0F': 'result low', '0x10': 'result high',
    },
    'multiply': 'A x B, unsigned 16-bit result',
    'divide_open': ('UNDER-SPECIFIED. The emulator computes ((A << 8) | B) / B, which is '
                    'almost certainly not the intent. Proposal: A / B with quotient in $0F and '
                    'remainder in $10, divide by zero returns $FF/$00. Needs a decision.'),
}
change('Math unit register layout written down from the emulator; the divide operation is '
       'flagged as under-specified with a proposal.')

# ------------------------------------------------------------------ media / mapper
p['media']['cartridge_slot']['sega_mapper_reach'] = (
    '8-bit bank registers address 256 x 16 KB = 4 MB. The 8 MB slot figure needs a ninth '
    'bank bit. OPEN: maximum ROM size and the register layout above 4 MB.')
p['media']['mappers']['sega']['cart_ram_open'] = (
    'The 315-5235 maps 2 x 16 KB of cartridge RAM through $FFFC bits 3 and 2. The emulator '
    'models 2 x 8 KB mirrored in the 16 KB window, and the save card format is built on 8 KB '
    'windows. OPEN: which size the machine guarantees.')
change('Cartridge reach and save-RAM size recorded as open, with the facts that bound them.')

# ------------------------------------------------------------------ software detection
p['software_detection'] = {
    'status': 'OPEN',
    'question': ('How does one ROM tell, at run time, that it is on a Super Sega? Extended '
                 'features are reachable only in Super Sega mode, which the header region '
                 '(8) selects, and an export SMS BIOS refuses region 8. A single ROM for both '
                 'machines therefore cannot use region 8.'),
    'options': [
        'Two ROMs from one source (what the Super Mario Land DX port does now).',
        'A boot-menu option to run a region-4 cartridge in Super Sega mode, plus a read-only '
        'machine ID register the ROM can test.',
        'An unlock sequence that switches a running region-4 title into Super Sega mode.',
    ],
    'source': 'Super Mario Land DX port design, distribution question',
}
change('Software detection of the machine recorded as an open question (from the SML DX port).')

# ------------------------------------------------------------------ mods
p['modding'] = {
    'machine_side': ('Computer mode can apply a BPS patch to a cartridge image while writing '
                     'a blank card, which is how a mod reaches real hardware. The console '
                     'plays mods; it does not make them.'),
    'not_machine': 'Making mods (the ROM hack maker and its plugins) is emulator-only.',
    'distribution': 'Mods are distributed only as BPS patches.',
    'source': 'Golden Axe / ROM hack maker work (October 2026)',
}
change('Modding boundary recorded: patch application while writing a card is a machine '
       '(computer mode) feature; making mods is emulator-only.')

# ------------------------------------------------------------------ v6 errors found in v7 review
hs = p['video']['mode4']['height_selection']
hs['standard'] = ('M2 (R0 bit 1) enables the extra heights. With M4 and M2 set, M1 (R1 bit 4) '
                  'gives 224 lines and M3 (R1 bit 3) gives 240; with M2 clear, Mode 4 is 192 '
                  'lines whatever M1 and M3 say. M4 is R0 bit 2.')
hs['source'] = 'MAME sega315_5246 select_extended_res_mode4; Gearsystem'
hs['v6_error'] = ('v6 gave 224 = M4 M3 M1 with M2 clear and 240 = M4 M3 M2 with M1 clear, '
                  'swapping the roles of M2 and M3. Under it, the usual R0 = $36 with R1 bit 4 '
                  'set stayed at 192 lines, and R0 = $04 with R1 bits 4-3 set gave 224 lines '
                  'where hardware shows 192.')
change('Extra-height mode bits corrected (v6 error, also in Technical Reference v2): M2 enables the extra heights; '
       'M1 then selects 224 lines and M3 selects 240. v6 had M2 and M3 swapped. Found while testing the Pocket RTL '
       'against Gearsystem and MAME. Emulator and RTL fixed.')

cm = p['media']['mappers']['codemasters']
cm['registers'] = '0x0000, 0x4000, 0x8000 exactly (Gearsystem and MAME decode the full address)'
cm['v6_error'] = ('v6 said any address within a slot acts as its register. No source supports it; '
                  'with it, a write into the on-cart RAM window\'s slot would also bank-switch.')
p['media']['mappers']['korean']['registers'] = '0xA000 exactly selects slot 2; slots 0 and 1 fixed to banks 0 and 1'
change('Codemasters registers are at exactly $0000, $4000 and $8000, and the Korean register at '
       'exactly $A000 (Gearsystem, MAME). v6 said any address in the slot; the emulator also '
       'powered Codemasters up with banks 0,1,2 instead of the profile\'s 0,1,0. Both fixed.')

kb = p['input']['keyboard']
kb['reset_state'] = ('The 8255 resets with every port an input. Port C\'s pull-ups then select '
                     'row 7, the pads, so SG-1000 software that never touches the PPI still reads '
                     'its controllers with the keyboard attached.')
kb['mode_word'] = ('Writing a mode word (bit 7 set) to $DF clears the output latches, so port C '
                   'selects row 0 until software writes it; with bit 7 clear the write sets or '
                   'clears one port C bit (bit set/reset). Intel 8255A behaviour.')
p['media']['sf7000']['ppi_mode_word'] = ('As on the keyboard PPI, a mode word clears port C, which '
                                         'drives /ROM SEL low and maps the IPL back in.')
change('8255 behaviour specified for both PPIs: reset state (all inputs, row 7 selected by the '
       'pull-ups), a mode word clearing port C, and bit set/reset on the keyboard PPI. The '
       'emulator selected keyboard row 0 at reset, so SG-1000 titles could not read their pads.')

change('Stock behaviour extended: sprite Y wrap rule (Gearsystem/MAME), 224/240-line name table, '
       'per-line VDP event timing, PSG noise rate and 2 dB volume steps, low-port reads, TR '
       'readback and Game Gear port decoding. The emulator had the noise an octave high, a '
       'linear volume curve, the controller mirror answering $00-$3F, and no TR readback.')

# ------------------------------------------------------------------ review fixes (v7 check)
p['glossary'] = {
    'register_banks': ('The VDP register-write command byte is 10bbnnnn. "bank1 R3" means register 3 of '
                       'bank 1, written with bb = 01. Banks 1-3 are reachable only while XRB is set.'),
    'XRB': ('Extended Register Banks: Feature Enable A (bank 0 R15) bit 5. While it is clear, bits 5-4 of a '
            'register-write command are ignored as on stock hardware, and the bank 1-3 registers keep their '
            'values but have no effect (Feature Enable B and C read as 0 to the hardware).'),
    'Feature_Enable_A_B_C': 'The three opt-in registers: A = bank 0 R15, B = bank 1 R2, C = bank 1 R7. All 0 at reset.',
    'TH_TR': 'Controller-port pins: TR is button 2; TH is the light-gun / multiplexing line. Both can be outputs, set through port $3F.',
    'ESAT': 'Extended Sprite Attribute Table: per-sprite flip, priority, size, magnification, early clock and palette.',
    'unique_cell': 'A mode with 1024 tiles, so every cell of the 32x24 screen can have its own tile.',
    'AEL': 'Auto-Enhancement Layer: the optional boosts for stock software (see enhancement_layer).',
    'bus_synchroniser': 'FPGA logic that holds the CPU (Z80 WAIT) until the VDP can accept an access, needed when turbo runs the CPU faster than the VDP.',
    'SDSC': 'A debug-console convention used by Master System homebrew (ports $FC/$FD).',
}
p['vdp_registers']['bank_0']['15'] = ('Feature Enable A - bit0 CRAM native, bit1 line-scroll H, bit2 window, bit3 ESAT, '
                                      'bit4 16 sprites/line, bit5 XRB, bit6 turbo (enables writes to $F3)')
p['vdp_registers']['xrb_semantics'] = p['glossary']['XRB']
p['vdp_registers']['feature_enable_b_height'] = ('Feature Enable B bits 7-6: 00 = height from the mode bits, 01 = 224 lines, '
                                                 '10 = 240 lines, 11 = reserved (192). A 224/240 selection by the mode bits takes precedence.')
p['cpu']['turbo']['enable'] = ('Feature Enable A bit 6 - off at reset. A write to $F3 takes effect only while it is set, so '
                               'unmodified SMS/GG software can never change the clock; the step stays in force until $F3 is written again.')
jobs = p['fpga_partition']['fpga_jobs']
if not any('debug' in j.lower() for j in jobs):
    jobs.insert(jobs.index('video compositing and output') if 'video compositing and output' in jobs else len(jobs), 'debug unit')
p['input']['keyboard']['enable'] = ('Feature Enable C bit 5 on Super Sega; always live in SG-1000 (keyboard attached), '
                                    'SC-3000 and SF-7000 modes')
p['input']['keyboard']['port_c_readback'] = 'Reading port C returns its output latch: the last value written, or 0 after a mode word.'
p['debug_facility']['trace_buffer'] = ('FPGA-side, mirrored to FRAM on a fault, so it outlives the crash that destroyed '
                                       'the program state. It is not cleared by a machine reset.')
p['media']['mappers']['msx_nemesis']['implementation'] = ('The emulator and the Pocket core implement the MSX variant '
                                                           'only; the Nemesis variant is not implemented yet.')
change('Review fixes: Feature Enable A bit 6 (turbo) added to the register table and its write-enable meaning '
       'stated; XRB semantics and the Feature Enable B height encoding written down; "debug unit" added to the '
       'FPGA job list (27 jobs, as the Technical Reference says); the keyboard is also live in SG-1000 mode; '
       'a glossary added for terms used throughout.')

# ------------------------------------------------------------------ enhancement layer
p['enhancement_layer'] = {
    'purpose': ('Optional boosts for unmodified SG-1000, SC-3000, Master System and Game Gear '
                'software, applied by intercepting the fixed hardware interfaces (VDP ports, '
                'PSG, pads) rather than patching the ROM. Full rationale and tiers: '
                'SuperSega_AutoEnhancement_Layer.md.'),
    'default': ('Every boost is off at power-on, so the machine behaves as stock hardware. '
                'Each one is switched independently: on the console from the boot menu, in the '
                'emulator from its AEL panel, on the Analogue Pocket core from the core settings '
                '(Interact) menu.'),
    'precedence': ('Explicit software intent wins. Every boost acts only on software running in the stock modes '
                   '(SG-1000, SC-3000, Master System, Game Gear): Super Sega software sets these features itself and '
                   'reads C as a button of its own. Pseudo-stereo also stops once software writes $06. Start = Pause '
                   'applies in the Master System, SG-1000 and SC-3000 modes (the Game Gear has a Start button of its own). '
                   'The TMS colour boost is the exception today: see Q11.'),
    'boosts': {
        'sprite_limit': '16 sprites per line in Mode 4 instead of 8 (legacy modes: 4 -> 8 or 16).',
        'overflow_stock': 'With the raised limit, status bit 6 is still set by a 9th sprite on a line, for software that reads it as logic.',
        'start_pause': 'Start on the pad raises the Pause NMI (SMS, SG-1000, SC-3000 modes).',
        'turbo': ('A turbo step (125-200 %) for stock software in the SMS, GG, SG-1000 and SC-3000 modes. '
                  'Super Sega software sets its own step through $F3.'),
        'vram_boost': 'No VDP access wait (bus synchroniser bypassed) while a turbo step is active.',
        'autofire': ('While C is held, button 2 repeats: it toggles every two frames (15 Hz at 60 Hz). '
                     'The pad state itself is not changed, so releasing C leaves button 2 as the pad has it.'),
        'pseudo_stereo': ('Until software writes $06, the PSG is panned tone 0 left, tone 1 right, tone 2 '
                          'and noise centre (the $06 value $DE).'),
        'gg_uncrop': 'Game Gear software is shown at the full 256x192 instead of the 160x144 window.',
        'tms_colour': 'SG-1000/SC-3000 picture modes use true TMS9918 colours instead of the Master System approximation.',
        'fm_present': 'Inherent to the machine (the FM unit is always fitted), not a switch.',
    },
    'not_modelled': ('"VRAM write reliability" (AEL doc, tier 1) has no switch: the emulator and the '
                     'Pocket core never drop a VDP write, so they already behave as if it were on.'),
    'region_speed': ('"Region speed correction" (AEL doc, tier 1) is the machine\'s 50/60 Hz video setting '
                     '(the emulator\'s PAL switch, the Pocket core\'s Video setting), not a separate boost.'),
}
change('enhancement_layer section added: the boosts for stock software, all off by default, with '
       'their exact behaviour (pseudo-stereo panning, auto-fire rate), and every boost limited to software '
       'in the stock modes. The emulator\'s pseudo-stereo silenced PSG tones 1 and 2 ($06 = $99); it now uses '
       '$DE. Its auto-fire overwrote the pad state, which left button 2 held when C was released mid-toggle.')

# ------------------------------------------------------------------ open questions
p['open_questions'] = [
    {'id': 'Q1', 'topic': 'Port mirror range', 'status': 'open',
     'detail': 'Registers $06-$16 sit in the $3E/$3F mirror range; relocation above $F0 is the candidate fix.'},
    {'id': 'Q2', 'topic': 'Maximum ROM size and mapper layout above 4 MB', 'status': 'open',
     'detail': 'See media.cartridge_slot.sega_mapper_reach.'},
    {'id': 'Q3', 'topic': 'Cartridge save-RAM size', 'status': 'open',
     'detail': 'See media.mappers.sega.cart_ram_open.'},
    {'id': 'Q4', 'topic': 'ESAT entry format; H-flip per sprite or per tile', 'status': 'resolved in v6',
     'detail': '2 bytes per sprite; byte 0 bit 1 H-flip, bit 0 V-flip, per sprite.'},
    {'id': 'Q5', 'topic': 'Unique-cell mode and 32 KB VRAM: coupled or independent', 'status': 'resolved in v6',
     'detail': 'Coupled: unique-cell mode requires VRAM expansion (Feature Enable B bit 4).'},
    {'id': 'Q6', 'topic': 'Turbo default for retagged ROMs', 'status': 'resolved',
     'detail': ('Off at reset. A title enables it itself (Feature Enable A bit 6, then $F3). The enhancement '
                'layer\'s turbo boost is for unmodified software in the stock modes and does not apply to Super Sega titles.')},
    {'id': 'Q7', 'topic': 'Math unit divide', 'status': 'open', 'detail': 'See math_unit.divide_open.'},
    {'id': 'Q8', 'topic': 'Run-time machine detection', 'status': 'open', 'detail': 'See software_detection.'},
    {'id': 'Q9', 'topic': 'Work RAM bank readback at $0A', 'status': 'open',
     'detail': 'Not readable today. Interrupt handlers that switch banks need to restore the previous one; readback or a documented RAM shadow is needed.'},
    {'id': 'Q10', 'topic': 'Reverting third-party GG2SMS layers', 'status': 'emulator workflow',
     'detail': 'A hack-maker workflow, not a machine question; listed so it is not lost.'},
    {'id': 'Q11', 'topic': 'Default of the TMS colour boost', 'status': 'open',
     'detail': ('The AEL rule is that every boost defaults off, but the emulator starts with true TMS9918 '
                'colours on. Either the emulator default changes to the Master System approximation, or the '
                'AEL doc lists TMS colours as an exception. The emulator also applies it to the legacy modes '
                'of Super Sega software, where no other boost acts. Not changed in v7.')},
    {'id': 'Q13', 'topic': 'Feature Enable C bit 4 (ESAT 2-byte)', 'status': 'open',
     'detail': ('v6 made ESAT 2 bytes per sprite (Q4), but Feature Enable C bit 4 still selects a 2-byte mode and the '
                'emulator implements a 1-byte layout when it is clear. Retire the bit, or document the 1-byte layout.')},
    {'id': 'Q14', 'topic': 'PCM FIFO fill reading at $08', 'status': 'open',
     'detail': ('$08 bits 6-4 report the fill of a 64-byte FIFO, which three bits cannot encode: the emulator returns the '
                'fill modulo 8, so a full FIFO reads as empty. Proposal: bits 6-4 = bytes queued / 8, saturating at 7.')},
    {'id': 'Q12', 'topic': 'Cartridge wait state at 200 % turbo', 'status': 'open',
     'detail': ('The profile gives one wait state per cartridge access at 200 % (250 ns ROM). The emulator '
                'applies it; the Pocket core does not yet (its PSRAM answers in time). Affects only software '
                'running at 200 %.')},
]
change('open_questions section added, consolidating questions from the Golden Axe conversion '
       'plan, the ROM hack maker spec and the SML DX port, with the ones v6 already answers marked resolved.')

p['v7_changes'] = changes
# key order: identification first, then scope, then the v7 summary, then the body
p['open_questions'].sort(key=lambda q: int(q['id'][1:]))
front = ['$schema', 'supersedes', 'scope', 'glossary', 'v7_changes']
out = {k: p[k] for k in front}
out.update({k: v for k, v in p.items() if k not in front})
json.dump(out, open(dst, 'w'), indent=1, ensure_ascii=False)
print(f'{len(changes)} changes; sections: {len(p)}')
