#!/usr/bin/env python3
"""Build masterdrive_machine_v7.json from v6.

v7 folds in the updates to the machine that were made in other chats, the
stock-hardware behaviour the emulator was corrected to follow (which every
implementation of the machine must follow, the Pocket core included), and
internal inconsistencies found in v6. Every change is listed in v7_changes;
those made after the October 2026 package say so. Every edit sets a value, or
inserts one only when it is missing, so run on the committed v7 the script
reproduces it byte for byte.
Usage: make_profile_v7.py v6.json v7.json
"""
import json, sys, copy, re

src, dst = sys.argv[1], sys.argv[2]
v6 = json.load(open(src))
p = copy.deepcopy(v6)

def put_after(d, after, key, value):
    """d[key] = value, with key placed right after d[after] (at the end if there is no such key)."""
    items = [(k, v) for k, v in d.items() if k != key]
    d.clear()
    for k, v in items:
        d[k] = v
        if k == after:
            d[key] = value
    if key not in d:
        d[key] = value

LATER = '(after the October 2026 package) '

p['$schema'] = 'masterdrive-machine-block/v7'
p['supersedes'] = 'super_sega_machine_v6.json'
p['scope'] = (
    'This file defines the machine: the console hardware, the jobs its FPGA performs '
    'and the behaviour its BIOS exposes. Implementations of the machine are the physical '
    'console, the HTML5 emulator\'s machine model and the Analogue Pocket core. '
    'Emulator-only features (ROM hack maker, MSX porting tools, Lab composite, merge '
    'report, the app\'s Debug tab, filters, FM dual-run capture, save states) are not '
    'part of the machine and are listed separately in MasterDrive_v7_Reconciliation.md.')

changes = []
def change(text): changes.append(text)

# ------------------------------------------------------------------ ports $00-$05
pm = p['port_map']['registers']
pm['0x00'] = ('Game Gear port 0: bit 7 Start (0 = pressed), bit 6 region (1 = export), '
              'bits 5-0 read 0. Decoded in Game Gear AND MasterDrive modes.')
pm['0x01-0x05'] = 'Game Gear serial / EXT link registers, Game Gear and MasterDrive modes'
change('Port $00 is decoded in MasterDrive mode as well as Game Gear mode. v6 said GG mode '
       'only, but the Golden Axe conversion plan reverts Ax Battler\'s GG2SMS Start patch and '
       'relies on the stock $00 read, and the emulator already decoded it in both modes. '
       'Format corrected: bits 5-0 read 0 (the emulator returned 1s, so bit 5 reported PAL).')
change('Ports $01-$05 (Game Gear serial/EXT link) listed explicitly for GG and MasterDrive '
       'modes; v6 named the serial link under input.multiplayer but gave no ports.')

p['port_map']['io_chip_disable'] = (
    '$3E bit 2 disables the controller decode (the $DC/$DD mirror across $C0-$FF) on the '
    'Master System and on MasterDrive. It has no effect on the Game Gear, even in SMS mode. '
    'It does not affect $F2 (FM detection) or MasterDrive\'s fully decoded $F0-$FF window.')
change('$3E bit 2 scope specified: controller decode only; not on Game Gear; not $F2 or MasterDrive\'s $F0-$FF.')

p['port_map']['masterdrive_read_values'] = {
    '0x07-0x16': 'decoded by the FPGA in MasterDrive mode; ports with no readable register return $FF, never the controller mirror',
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
change('Read values of the MasterDrive registers inside $07-$16 and $F0-$FA specified. The '
       'emulator answered every read in $07-$16 from the controller mirror, so the math '
       'result, slot readback and multitap detection could not be read.')
pm['0xFB-0xFF'] = 'debug unit (see debug_facility); reads answer only in MasterDrive mode'
p['debug_facility']['availability'] = (
    'Writes reach the debug unit in every machine mode, since its purpose is inspecting stock software; stock '
    'hardware ignores writes to $FB-$FF. Reads of $FB-$FF answer from the debug unit only in MasterDrive mode. In the '
    'stock modes they read as on the stock machine (the controller mirror; $FF on the Game Gear), because stock '
    'software may read its pads there.')
p['debug_facility']['read_values'] = p['port_map']['masterdrive_read_values']['0xFB-0xFF']
change('Debug unit port reads: in the stock modes $FB-$FF read as on the stock machine (the controller mirror; $FF '
       'on the Game Gear), and the debug unit answers reads only in MasterDrive mode, which therefore decodes $F0-$FF '
       'fully. Writes reach the debug unit in every mode, as before. The emulator answered $FB-$FD reads in every '
       'mode, so stock software reading its pads at those mirror addresses saw the debug status instead.')

p['port_map']['mirror_scheme'] = (
    'On SMS hardware every EVEN address 0x00-0x3E mirrors 0x3E and every ODD address 0x01-0x3F mirrors 0x3F. '
    'The Game Gear decodes 0x00-0x06 separately for its own registers. On every stock machine the PSG is '
    'written at any port in 0x40-0x7F and the VDP answers across 0x80-0xBF (even ports data, odd ports '
    'control); on the Master System and Game Gear the V counter reads at every even port and the H counter at '
    'every odd port in 0x40-0x7F. The SG-1000, SC-3000 and SF-7000 have no 0x3E/0x3F registers: in those '
    'modes writes to 0x00-0x3F do nothing.')
change(LATER + 'port_map.mirror_scheme now gives the PSG/counter mirror across $40-$7F and the VDP mirror '
       'across $80-$BF, which both implementations decode and which the stock machines have.')
change(LATER + 'The SG-1000, SC-3000 and SF-7000 modes have no $3E/$3F registers, so writes to $00-$3F do '
       'nothing there (port_map.mirror_scheme). The Pocket core already ignored them; the emulator let writes '
       'to $07-$3F change its I/O control value.')
pm['0x7E'] = 'V counter / gun vertical (read); PSG (write)'
pm['0x7F'] = 'H counter / gun horizontal (read); PSG (write)'
pm['0xC0-0xDF'] = ('controllers: 0xDC/0xDD, mirrored across the range; while the SK-1100 keyboard is live '
                   '(input.keyboard.enable), the PPI at 0xDC-0xDF instead, mirrored across the range')
change(LATER + 'Port map corrected to match the Technical Reference and both implementations: the PSG is '
       'written at $7E as well as $7F (v6 named only $7F), and $C0-$DF is the controller mirror unless the '
       'SK-1100 keyboard is live, when the PPI answers there (v6 named only the PPI).')

put_after(p['port_map'], 'mirror_scheme', 'mode_scope', (
    'Writes to the MasterDrive registers at 0x07-0x16 take effect only in MasterDrive mode, as do writes to VDP '
    'bank 0 R11-R15 (vdp_registers.bank_0_scope). 0x06 is a register in the MasterDrive and Game Gear modes. In '
    'every other mode these ports and registers do what they do on the stock machine.'))
p['port_map']['open_risk'] = (
    'MasterDrive registers at 0x06-0x16 sit inside that mirror range and must be decoded specifically, as the '
    'Game Gear already does. Because they are decoded only in MasterDrive mode (mode_scope), stock software '
    'running in its own mode is unaffected. The risk is old code running in MasterDrive mode - a retagged or '
    'converted title, or a stock cartridge started in MasterDrive mode as software_detection option 2 '
    'proposes - that writes a mirror address in 0x06-0x16 instead of 0x3E/0x3F: it reaches a MasterDrive '
    'register instead. Documentation calls mirror use highly unrecommended for homebrew, which implies '
    'commercial software does it. NOT YET RESOLVED - candidate fix is to relocate these registers above 0xF0 '
    '(open question Q1).')
put_after(p['vdp_registers'], 'bank_0', 'bank_0_scope', (
    'Registers 11-15 take effect only in MasterDrive mode; in the other modes they are ignored, as on the '
    'stock VDP.'))
change(LATER + 'Writes to $07-$16 and to VDP bank 0 R11-R15 stated to take effect only in MasterDrive mode '
       '(port_map.mode_scope, vdp_registers.bank_0_scope), as both implementations do. Q1 and '
       'port_map.open_risk now name the case at risk: old code running in MasterDrive mode that writes a '
       '$3E/$3F mirror address in $06-$16. They said any old title.')

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
            'counter on the Japanese SMS; MasterDrive returns 0 there)',
    'detection': 'Software disables the I/O chip ($3E bit 2) before reading $F2 so the '
                 'controller decode does not drive the bus; the FM latch must still answer.',
    'source': 'MAME sms.cpp smsj_audio_control_r',
}
change('$F2 readback specified, including that it works with the I/O chip disabled. The '
       'emulator returned $FF in that state, so the standard FM detection failed.')

# ------------------------------------------------------------------ stock behaviour
p['stock_behaviour'] = {
    'note': ('Behaviour of the stock parts that every implementation must reproduce. These '
             'are not MasterDrive additions; they are listed because the emulator had them '
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
                         'reloaded from R10. Mode 4 only as stock (TMS modes raise no line interrupt); whether '
                         'MasterDrive runs it in the TMS modes is open question Q15.'),
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
                           'MasterDrive for every port they do not decode as a register.'),
        'tr_readback': ('A TR pin configured as an output ($3F bit 0 or 2 clear) reads back the level '
                        'driven: $DC bit 5 for port A, $DD bit 3 for port B.'),
        'game_gear_decode': ('Above $C0 the Game Gear answers only $C0/$DC (port A) and $C1/$DD (port B, '
                             'with bits 7-6 = $3F bits 7-6); every other port reads $FF, $F2 included (no FM).'),
        'fm_latch': 'The $F2 FM detection latch answers in Master System and MasterDrive modes only.',
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

put_after(p['memory']['port_3E_memory_enables'], 'bit_7', 'reset_value', (
    '0xA8: the state of a machine whose BIOS has handed over to a cartridge - cartridge, RAM and controllers '
    'enabled; BIOS, card and external port disabled'))
p['input']['port_3F']['reset_state'] = '0xFF: every pin an input (bits 3-0 set), level bits 7-4 set'
change(LATER + 'Reset values written down: $3E resets to $A8 (the BIOS has handed over to the cartridge), as '
       'the Technical Reference already said, and $3F to $FF (every pin an input, level bits set), where v6 '
       'said only "low bits set". Both implementations already use these values.')

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
    'question': ('How does one ROM tell, at run time, that it is on a MasterDrive? Extended '
                 'features are reachable only in MasterDrive mode, which the header region '
                 '(8) selects, and an export SMS BIOS refuses region 8. A single ROM for both '
                 'machines therefore cannot use region 8.'),
    'options': [
        'Two ROMs from one source (what the Super Mario Land DX port does now).',
        'A boot-menu option to run a region-4 cartridge in MasterDrive mode, plus a read-only '
        'machine ID register the ROM can test.',
        'An unlock sequence that switches a running region-4 title into MasterDrive mode.',
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
                  'gives 224 lines and M3 (R1 bit 3) gives 240; with both M1 and M3 set it stays 192 '
                  'lines. With M2 clear, Mode 4 is 192 lines whatever M1 and M3 say. M4 is R0 bit 2.')
hs['source'] = 'MAME sega315_5246 select_extended_res_mode4; Gearsystem'
hs['v6_error'] = ('v6 gave 224 = M4 M3 M1 with M2 clear and 240 = M4 M3 M2 with M1 clear, '
                  'swapping the roles of M2 and M3. Under it, the usual R0 = $36 with R1 bit 4 '
                  'set stayed at 192 lines, and R0 = $04 with R1 bits 4-3 set gave 224 lines '
                  'where hardware shows 192.')
change('Extra-height mode bits corrected (v6 error, also in Technical Reference v2): M2 enables the extra heights; '
       'M1 then selects 224 lines and M3 selects 240. v6 had M2 and M3 swapped. Found while testing the Pocket RTL '
       'against Gearsystem and MAME. Emulator and RTL fixed.')
change(LATER + 'Height cases written out: with M4 and M2 set, M1 and M3 both set give 192 lines '
       '(video.mode4.height_selection did not say), and Feature Enable B height 11 gives 192 lines (the '
       'Technical Reference said only "reserved"). Both implementations already do this.')

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

p['media']['sf7000']['port_c_bits'] = '0 FDD /INUSE, 1 FDD /MOTOR ON, 2 FDC TC, 3 FDC RESET, 6 /ROM SEL, 7 printer /STROBE'
change(LATER + 'SF-7000 PPI port C bit 2 is the floppy controller\'s TC (terminal count) input, not the '
       'drive\'s: "2 FDC TC" (v6 had "2 FDD TC"). MAME sg1000.cpp ("PC2 TC signal to FDC") and the '
       'Technical Reference agree.')

kb['polarity'] = ('Taken as active low with pull-ups - a pressed key reads 0, an unused matrix position always '
                  'reads 1. Evidence, not proof: this rests on a single source that contradicts itself (a risk '
                  'from Technical Reference v2 that v3 keeps). Both implementations use it.')
put_after(p['vdp_registers'], 'bank_0_scope', 'bank_0_evidence', (
    'Evidence, not proof (a risk from Technical Reference v2 that v3 keeps): six commercial titles were checked '
    'and none write VDP registers 11-15, where Feature Enable A lives. It matters for old code running in Super '
    'Sega mode, the only mode in which those registers take effect (bank_0_scope).'))
change(LATER + 'Two risks from Technical Reference v2 that v3 keeps are recorded beside the statements they qualify: '
       'VDP registers 11-15 were checked against only six commercial titles (vdp_registers.bank_0_evidence), '
       'and the keyboard\'s active-low polarity rests on one source that contradicts itself '
       '(input.keyboard.polarity, no longer stated as settled).')

change('Stock behaviour extended: sprite Y wrap rule (Gearsystem/MAME), 224/240-line name table, '
       'per-line VDP event timing, PSG noise rate and 2 dB volume steps, low-port reads, TR '
       'readback and Game Gear port decoding. The emulator had the noise an octave high, a '
       'linear volume curve, the controller mirror answering $00-$3F, and no TR readback.')
change(LATER + 'The $F2 FM detection latch answers only in Master System and MasterDrive modes '
       '(stock_behaviour.io.fm_latch); the emulator answered in the Game Gear, SC-3000 and SF-7000 modes too. The '
       'package made this change without listing it here.')

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
    'bus_synchroniser': ('FPGA logic that holds the CPU (Z80 WAIT) until the VDP can accept an access, or the FM chip a '
                         'write, needed when turbo runs the CPU faster than those chips.'),
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
p['input']['keyboard']['enable'] = ('Feature Enable C bit 5 on MasterDrive; always live in SG-1000 (keyboard attached), '
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

cpu = p['cpu']
put_after(cpu, 'base_clock_hz', 'pal_clock_hz', 3546893)
cpu['turbo']['clock_generation'] = ('FPGA PLL generates true 4.47/5.37/6.26/7.16 MHz at the NTSC clock and '
                                    '4.434/5.320/6.207/7.094 MHz at the PAL clock: each step is the same '
                                    'percentage of the base clock in both standards (open question Q22, decided '
                                    'by the owner); VDP, PSG and FM stay at 1x')
put_after(cpu, 'pal_clock_hz', 'clock_standards', (
    'base_clock_hz is the NTSC clock. In PAL the CPU runs at pal_clock_hz, as on a PAL Master System, so a '
    '313-line frame of 228 cycles per line is 49.70 Hz (at the NTSC clock it would be 50.16 Hz).'))
change(LATER + 'PAL CPU clock defined: 3.546893 MHz, as on a PAL Master System, giving 49.70 Hz frames. v6 gave '
       'only the NTSC clock. Both implementations now run PAL on it (they ran it at the NTSC clock, 50.16 Hz). '
       'The turbo frequencies are stated for the NTSC clock; PAL ones are open question Q22.')
put_after(cpu, 'clock_standards', 'reset_state', (
    'At hand-over to software: PC $0000, SP $DFF0 (where the Master System BIOS leaves it), interrupts disabled '
    '(IFF1 = IFF2 = 0) and interrupt mode 0, as after a Z80 reset; software selects IM 1 itself.'))
change(LATER + 'CPU state at hand-over to software defined (cpu.reset_state): PC $0000, SP $DFF0, interrupts '
       'disabled, interrupt mode 0. $DFF0 is where the Master System BIOS leaves SP and where the emulator and '
       'Gearsystem start; the Pocket core\'s CPU reset SP to $FFFF and is changed to match.')
put_after(cpu['turbo'], 'enable', 'cartridge_wait', (
    'A 250 ns cartridge ROM is fast enough up to 175 %; at 200 % each cartridge access takes one wait state '
    '(open question Q12 covers the Pocket core).'))
change(LATER + 'Cartridge wait state at 200 % written into the profile (cpu.turbo.cartridge_wait) as the '
       'Technical Reference gives it; Q12 cited it, but no profile field stated it.')

# ------------------------------------------------------------------ enhancement layer
p['enhancement_layer'] = {
    'purpose': ('Optional boosts for unmodified SG-1000, SC-3000, Master System and Game Gear '
                'software, applied by intercepting the fixed hardware interfaces (VDP ports, '
                'PSG, pads) rather than patching the ROM. Full rationale and tiers: '
                'SuperSega_AutoEnhancement_Layer.md (the "AEL doc" below), an earlier design document that '
                'is not in this repository.'),
    'default': ('Every boost but one is off at power-on, so the machine behaves as stock hardware: True TMS '
                'colours starts on, so SG-1000 and SC-3000 software shows the colours it was made for (Q11). '
                'Each one is switched independently: on the console from the boot menu, in the '
                'emulator from its AEL panel, on the Analogue Pocket core from the core settings '
                '(Interact) menu.'),
    'precedence': ('Explicit software intent wins. Every boost acts only on software running in the stock modes '
                   '(SG-1000, SC-3000, Master System, Game Gear): MasterDrive software sets these features itself and '
                   'reads C as a button of its own. Pseudo-stereo also stops once software writes $06. Start = Pause '
                   'applies in the Master System, SG-1000 and SC-3000 modes (the Game Gear has a Start button of its own). '
                   'The TMS colour boost is the one exception: it also acts on MasterDrive software\'s TMS modes (Q11).'),
    'boosts': {
        'sprite_limit': '16 sprites per line instead of 8 in Mode 4, and instead of 4 in the TMS modes.',
        'overflow_stock': ('With the raised limit, status bit 6 is still set by a 9th sprite on a line, for software that '
                           'reads it as logic. Mode 4 only: in the TMS modes it has no effect.'),
        'start_pause': 'Start on the pad raises the Pause NMI (SMS, SG-1000, SC-3000 modes).',
        'turbo': ('A turbo step (125-200 %) for stock software in the SMS, GG, SG-1000 and SC-3000 modes. '
                  'MasterDrive software sets its own step through $F3.'),
        'vram_boost': ('No VDP access wait while a turbo step is active: the bus synchroniser stops holding VDP '
                       'accesses, but still holds FM writes (cpu.turbo.fm_writes).'),
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
change(LATER + 'The enhancement-layer design document the profile cites (SuperSega_AutoEnhancement_Layer.md, '
       'the "AEL doc") is noted as an earlier document that is not in this repository.')

# ------------------------------------------------------------------ open questions
p['open_questions'] = [
    {'id': 'Q1', 'topic': 'Port mirror range', 'status': 'resolved',
     'detail': ('Registers $06-$16 sit in the $3E/$3F mirror range, a risk for old code running in MasterDrive mode '
                'that writes a mirror address there. Decided by the owner in October 2026: the registers stay, and '
                'in MasterDrive mode $01-$17 answer only while Feature Enable A bit 7 is set; until then those ports '
                'are the $3E/$3F mirrors and read $FF, and $00 still answers (port_map.native_gate).')},
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
                'layer\'s turbo boost is for unmodified software in the stock modes and does not apply to MasterDrive titles.')},
    {'id': 'Q7', 'topic': 'Math unit divide', 'status': 'open', 'detail': 'See math_unit.divide_open.'},
    {'id': 'Q8', 'topic': 'Run-time machine detection', 'status': 'resolved',
     'detail': ('Decided by the owner in October 2026: a boot-menu option runs an export cartridge in MasterDrive '
                'mode, and a read-only machine ID register at $17 reads $A7, behind the I/O gate of Q1 '
                '(software_detection).')},
    {'id': 'Q9', 'topic': 'Work RAM bank readback at $0A', 'status': 'open',
     'detail': 'Not readable today. Interrupt handlers that switch banks need to restore the previous one; readback or a documented RAM shadow is needed.'},
    {'id': 'Q10', 'topic': 'Reverting third-party GG2SMS layers', 'status': 'emulator workflow',
     'detail': 'A hack-maker workflow, not a machine question; listed so it is not lost.'},
    {'id': 'Q11', 'topic': 'Default of the TMS colour boost', 'status': 'resolved',
     'detail': ('Decided by the owner in October 2026: true TMS9918 colours are on at power-on, one of the '
                'two boosts that start on (Start = Pause is the other), and the boost also acts on the TMS modes '
                'of MasterDrive software. The emulator already did both; the Pocket core does the same.')},
    {'id': 'Q13', 'topic': 'Feature Enable C bit 4 (ESAT 2-byte)', 'status': 'open',
     'detail': ('ESAT has been 2 bytes per sprite since v5, and v6 confirmed it (Q4), but Feature Enable C bit 4 still '
                'selects a 2-byte mode and the emulator implements a 1-byte layout when it is clear. Retire the bit, '
                'or document the 1-byte layout.')},
    {'id': 'Q14', 'topic': 'PCM FIFO fill reading at $08', 'status': 'open',
     'detail': ('$08 bits 6-4 report the fill of a 64-byte FIFO, which three bits cannot encode: the emulator returns the '
                'fill modulo 8, so a full FIFO reads as empty. Proposal: bits 6-4 = bytes queued / 8, saturating at 7.')},
    {'id': 'Q12', 'topic': 'Cartridge wait state at 200 % turbo', 'status': 'open',
     'detail': ('cpu.turbo.cartridge_wait gives one wait state per cartridge access at 200 % (250 ns ROM). The '
                'emulator applies it; the Pocket core does not yet (its PSRAM answers in time). Affects only '
                'software running at 200 %.')},
    {'id': 'Q15', 'topic': 'Line interrupts in the TMS9918 (legacy) modes', 'status': 'open',
     'detail': ('v5 made line interrupts in the legacy modes a MasterDrive enhancement '
                '(video.legacy_modes.enhancements.line_interrupts), but no enable bit was ever assigned; as stock, '
                'TMS modes raise none (stock_behaviour.vdp.line_counter), and both implementations follow that in '
                'the stock modes. In MasterDrive mode both raise them in the TMS modes whenever R0 bit 4 is set. '
                'Should the line counter run in the legacy '
                'modes on MasterDrive, and what enables it?')},
    {'id': 'Q16', 'topic': 'Register layouts defined only by the emulator', 'status': 'open',
     'detail': ('The bit layouts of the DMA engine ($F4-$FA), PCM control ($08 write), the wavetable ($11-$15), '
                'slot select ($09), the VDP base registers (bank 0 R11 and R12, bank 1 R0, R1, R5 and R6) and the '
                'window split (bank 0 R13 and R14) are '
                'defined today only by the emulator\'s implementation (the Pocket core already follows it for $09). '
                'They need writing into the profile and the Technical Reference, and checking, before the Pocket '
                'core implements them, as v7 did for the math unit.')},
    {'id': 'Q18', 'topic': 'TMS-mode status bits 4-0 and transparent sprites', 'status': 'open',
     'detail': ('Two details of the sprite flags in the TMS modes are not settled for this VDP. (1) What status bits '
                '4-0 read: the TMS9918A puts the number of the fifth sprite there; Gearsystem does that whenever a TMS '
                'mode is selected (not on the Game Gear) and reads $1F in Mode 4; the Pocket core reads $1F and the '
                'emulator 0 in every mode. '
                '(2) Whether a transparent (colour 0) sprite takes part in collisions: the TMS9918A Data Manual says '
                'it does; Gearsystem, the emulator and the Pocket core leave it out.')},
    {'id': 'Q19', 'topic': 'Several TMS mode bits set at once', 'status': 'open',
     'detail': ('The implementations take M2 (Graphics II) first, then M1 (Text), then M3 (Multicolor); Gearsystem '
                'takes M1, then M3, then M2; on the TMS9918A such combinations give undocumented hybrid modes. '
                'Which picture should the machine show?')},
    {'id': 'Q20', 'topic': 'Balance of FM and PSG', 'status': 'open',
     'detail': ('How loud the FM chip is beside the PSG on the original Japanese Master System, where the two are '
                'mixed in analogue, is not known: MAME gives both chips the same gain, Gearsystem lowers the PSG to '
                '0.8 while both play, and neither cites a measurement. Both implementations make one FM channel '
                'at full volume peak at half a PSG channel at full volume. The chip also has separate melody and '
                'rhythm outputs, whose mix on the console\'s board is not known either; the Pocket core uses '
                'IKAOPLL\'s default weights (2 and 3), and the emulator has no rhythm instruments. What balance '
                'should the machine have?')},
    {'id': 'Q21', 'topic': 'FM register writes at turbo', 'status': 'resolved',
     'detail': ('The YM2413 needs 12 master-clock cycles after an address write and 84 after a data write before '
                'it takes the next write. Software written for 100 % spaces its writes by CPU time, so at turbo '
                'steps above 100 % they can come too close: on the Pocket core a test driver that leaves the chip '
                'little more than the minimum at 100 % played no FM at 200 %. Decided by the owner in October '
                '2026: at turbo the bus synchroniser holds the CPU on a write to $F0/$F1 until the chip can take '
                'it, as it does for the VDP (cpu.turbo.fm_writes). Both implementations do this.')},
    {'id': 'Q22', 'topic': 'PAL turbo clocks', 'status': 'resolved',
     'detail': ('The turbo steps were defined only at the NTSC clock: 4.47, 5.37, 6.26 and 7.16 MHz. Decided by '
                'the owner in October 2026: in PAL they are the same percentages of the PAL clock, 4.434, 5.320, '
                '6.207 and 7.094 MHz (cpu.turbo.clock_generation). Both implementations already did this, because '
                'their turbo is a multiple of the base clock.')},
    {'id': 'Q17', 'topic': 'Feature Enable B height in the TMS modes', 'status': 'open',
     'detail': ('Feature Enable B bits 7-6 select 224 or 240 lines for MasterDrive software, but the documents '
                'define the heights only for Mode 4. Both implementations also apply them while a TMS9918 mode '
                'is selected. Should the machine apply them in the TMS modes, and if so, what do those modes '
                'draw below line 192?')},
]
change('open_questions section added, consolidating questions from the Golden Axe conversion '
       'plan, the ROM hack maker spec and the SML DX port, with the ones v6 already answers marked resolved.')

p['video']['sprites']['esat']['v5_change'] = (
    'widened from 1 byte to 2 to carry magnify and early clock. The v4 single-byte layout is superseded; the '
    'emulator still implements a 1-byte layout while Feature Enable C bit 4 is clear (open question Q13).')
change(LATER + 'Q13 now gives the ESAT history as the profile records it: 2 bytes per sprite since v5, '
       'confirmed in v6 (Q4). It said v6 made the change. video.sprites.esat.v5_change now points to Q13.')

le = p['video']['legacy_modes']['enhancements']['line_interrupts']
le['effect'] = 'VDP register 10 line interrupts, an SMS addition, while running legacy modes (proposed in v5)'
le['enable'] = ('OPEN - no enable bit is defined, and whether the line counter runs in the legacy modes is '
                'undecided (open question Q15)')
p['compatibility']['sg_software'] = (
    'An unmodified SG-1000 ROM renders with the fixed TMS palette, 4 sprites per line and no line interrupts, '
    'exactly as on real hardware, until Feature Enable C bits 0-1 are set. Whether MasterDrive software can '
    'enable line interrupts in the legacy modes is open question Q15.')
order = p['implementation_order']
order[[i for i, s in enumerate(order) if s.startswith('11. ')][0]] = (
    '11. Legacy mode enhancements: CRAM colour, raised sprite limit, line interrupts (open question Q15)')
change(LATER + 'Line interrupts in the legacy (TMS) modes recorded as open question Q15. v5 made them a Super '
       'Sega enhancement but no enable bit was ever assigned, and compatibility.sg_software said Feature Enable '
       'C enables them, which no bit does. The statements that answered the question now point to Q15.')
change(LATER + 'Open question Q17 added: whether Feature Enable B\'s 224/240-line heights apply while a TMS9918 '
       'mode is selected, as both implementations do today.')
p['vdp_registers']['bank_0']['14'] = 'Window Y Split; bit 7 selects side'
change(LATER + 'Open question Q16 added: the register layouts of the DMA engine, PCM control, the wavetable, '
       'slot select, the VDP base registers and the window split are defined only by the emulator\'s '
       'implementation. vdp_registers.bank_0 R14 now gives its bit 7 (side), as the Technical Reference does.')

lm = p['video']['legacy_modes']
lm['selection'] = ('Graphics I with none of M1-M3 set, Text with M1 (R1 bit 4), Graphics II with M2 (R0 bit 1), '
                   'Multicolor with M3 (R1 bit 3); M4 (R0 bit 2) selects Mode 4. Several of M1-M3 together: open '
                   'question Q19.')
lm['tables'] = ('Base addresses as on the SG-1000: name table R2 x $400, colour table R3 x $40, pattern table '
                'R4 x $800, sprite attributes R5 x $80, sprite patterns R6 x $800. In Graphics II, R4 bit 2 and R3 '
                'bit 7 pick the half of VRAM for the pattern and colour tables, and R4 bits 1-0 and R3 bits 6-0 mask '
                'the pattern and colour index, so the thirds of the screen can share tables.')
lm['transparency'] = ('Colour 0 is transparent in every TMS mode, Text and Multicolor included: the backdrop '
                      '(R7 bits 3-0) shows through.')
lm['sprites'] = ('32 sprites of 4 bytes (Y, X, pattern, attribute: bit 7 early clock, 32 pixels left; bits 3-0 '
                 'colour), 8x8 or 16x16 (R1 bit 1), magnified by R1 bit 0; none in Text mode. Y = $D0 ends the '
                 'list. A sprite starts on line Y+1, or Y+1-256 when Y+1 is 225 or more (Gearsystem: 224; the two '
                 'differ only for Y = $DF, off a 192-line screen either way). Four per line as stock. When sprites '
                 'overlap, the lowest-numbered is drawn on top. A transparent sprite counts towards the limit but '
                 'draws nothing; neither implementation lets it take part in collisions, as in Gearsystem, and '
                 'whether it should is open question Q18.')
lm['status_flags'] = ('Status bit 6 is set by a fifth sprite on a displayed line, and status bit 5 when pixels of '
                      'two drawn sprites meet on the screen; both when the line is drawn, not at the Mode 4 event '
                      'times. What status bits 4-0 read is open question Q18.')
lm['source'] = ('TMS9918A Data Manual (Texas Instruments); Gearsystem (Video.cpp, RenderBackgroundTMS9918 and '
                'RenderSpritesTMS9918), which the emulator matches on the Pocket core\'s TMS test ROMs')
change(LATER + 'The TMS9918 modes written down (video.legacy_modes: tables, transparency, sprites, status_flags) '
       'as the Pocket core implements them. The emulator was corrected to them: the lowest-numbered sprite is now '
       'drawn on top, sprites set the collision flag, colour 0 is transparent in Text and Multicolor, and R3 bits '
       '6-0 mask the Graphics II colour index (it applied the mask shifted by five bits). video.legacy_modes.selection '
       'gives the mode bits instead of claiming real-hardware behaviour for every combination. Open questions Q18 '
       '(status bits 4-0, transparent sprites) and Q19 (several mode bits at once) added.')
change(LATER + 'Q11 resolved by the owner: True TMS colours is on at power-on, the one exception to every boost '
       'starting off, and it also acts on MasterDrive software\'s TMS modes. enhancement_layer.default and '
       'precedence say so. The sprite-limit boost now says what both implementations do in the TMS modes '
       '(4 -> 16); it said "4 -> 8 or 16". The stock-overflow-flag boost is stated to act in Mode 4 only.')

fm = p['audio']['fm']
fm['audio_control']['write'] = ('$F2 bits 1-0 select which sound chips are heard: 0 the PSG only (the power-on '
                                'state), 1 the FM chip only, 2 neither, 3 both')
fm['audio_control']['source'] = ('MAME sms_m.cpp (smsj_audio_control_r, smsj_set_audio_control); Gearsystem '
                                 '(Audio.h) does the same for Japanese consoles')
fm['level'] = ('OPEN: the balance of FM and PSG on the original (open question Q20). Both implementations make '
               'one FM channel at full volume peak at half a PSG channel at full volume.')
change(LATER + 'The four $F2 states written out (audio.fm.audio_control.write): 0 PSG only, 1 FM only, 2 neither, '
       '3 both. The profile said only that bits 1-0 "select the mute/enable state"; the emulator mixed both chips '
       'whatever $F2 held, so software that selected FM only still had its PSG heard. The source is MAME '
       'sms_m.cpp, not sms.cpp. Open question Q20 added: the balance of FM and PSG.')

fm['write_timing'] = ('After an address write to $F0 the chip needs 12 master-clock (base) cycles before the data; '
                      'after a data write to $F1, 84 before the next write (YM2413 Application Manual). Software '
                      'leaves this time itself at 100 %; at turbo the bus synchroniser holds the CPU until it has '
                      'passed (cpu.turbo.fm_writes).')
p['cpu']['turbo']['fm_writes'] = ('The FM chip stays at 1x. At turbo steps above 100 % the bus synchroniser holds '
                                  'the CPU on a write to $F0/$F1 until 12 base cycles have passed since an address '
                                  'write, or 84 since a data write (audio.fm.write_timing), so software written '
                                  'for 100 % keeps its FM music. Open question Q21, decided by the owner.')
p['cpu']['bus_synchroniser']['purpose'] = ('Holds the CPU until the VDP reaches a safe access point, and holds an FM '
                                           'write until the FM chip can take it (cpu.turbo.fm_writes), since the CPU '
                                           'clock is decoupled from the VDP and the FM chip under turbo.')
change(LATER + 'Open question Q21 added and decided by the owner: FM register writes at turbo could come faster '
       'than the YM2413 accepts them, so the bus synchroniser holds the CPU on $F0/$F1 until the chip is ready '
       '(cpu.turbo.fm_writes). audio.fm.write_timing gives the chip\'s write timing.')

p['input']['stock_mapping'] = (
    'In the stock modes (Master System, Game Gear, SG-1000, SC-3000) the console presents its Mega Drive pad as '
    'that machine\'s controller: A is button 1 (TL), B is button 2 (TR), and Start is the Game Gear\'s Start, or '
    'the Pause button on the Master System, SG-1000 and SC-3000 (enhancement_layer start_pause, on at power-on). '
    'C is used only by the auto-fire boost. A Mega Drive pad plugged into a Master System gives B and C as '
    'buttons 1 and 2; the console uses A and B so that the pad\'s first two buttons are the old consoles\' two. '
    'MasterDrive software reads the pad as a Mega Drive pad (controller). Decided by the owner, October 2026.')
p['enhancement_layer']['default'] = (
    'Every boost but two is off at power-on, so the machine behaves as stock hardware: True TMS colours starts on, '
    'so SG-1000 and SC-3000 software shows the colours it was made for (Q11), and Start = Pause starts on, because '
    'the console\'s pad has no Pause button (input.stock_mapping). Each one is switched independently: on the '
    'console from the boot menu, in the emulator from its AEL panel, on the Analogue Pocket core from the core '
    'settings (Interact) menu.')
p['enhancement_layer']['boosts']['start_pause'] = ('Start on the pad raises the Pause NMI (SMS, SG-1000, SC-3000 '
                                                   'modes). On at power-on.')
change(LATER + 'Stock-mode controller mapping decided by the owner (input.stock_mapping): the Mega Drive pad\'s A '
       'is button 1 and B is button 2, and Start is the Game Gear\'s Start or, through Start = Pause, the Pause '
       'button; Start = Pause is now on at power-on, the second boost that starts on. The documents said only '
       'that the pad gives B and C with TH high, as a Mega Drive pad does; the emulator already used A and B.')

change(LATER + 'Open question Q22 added: the turbo frequencies in PAL. Both implementations run the turbo '
       'steps as percentages of the PAL clock (cpu.turbo.clock_generation).')

change(LATER + 'The machine is renamed MasterDrive (formerly Super Sega), the owner\'s choice: an all-in-one Sega 8-bit '
       'computer and console concept, with updates. Every name in the profile follows, the machine id and two keys '
       'included (video.mode4.height_selection.masterdrive, port_map.masterdrive_read_values).')

change(LATER + 'Q22 resolved by the owner: in PAL the turbo steps are the same percentages of the PAL clock, '
       '4.434, 5.320, 6.207 and 7.094 MHz (cpu.turbo.clock_generation), as both implementations already ran them.')

# ------------------------------------------------------------------ Q1 and Q8 (decided by the owner, October 2026)
GATE = 'while Feature Enable A bit 7 is set (port_map.native_gate)'
pm['0x00'] = ('Game Gear port 0: bit 7 Start (0 = pressed), bit 6 region (1 = export), bits 5-0 read 0. Decoded in '
              'Game Gear AND MasterDrive modes; in MasterDrive mode it answers whether or not the I/O gate is open.')
pm['0x01-0x05'] = 'Game Gear serial / EXT link registers: Game Gear mode, and MasterDrive mode ' + GATE
pm['0x06'] = 'PSG stereo panning (write-only): Game Gear mode, and MasterDrive mode ' + GATE
put_after(pm, '0x16', '0x17', 'machine ID, read-only, $A7 (software_detection.machine_id): MasterDrive mode ' + GATE)
rv = {}
for k, v in p['port_map']['masterdrive_read_values'].items():
    if k == '0x07-0x16':
        rv['0x01-0x17'] = ('decoded by the FPGA in MasterDrive mode ' + GATE + ': $01-$05 the Game Gear serial '
                           'registers, $06 $FF (write-only), $07-$17 as below; ports with no readable register return '
                           '$FF, never the controller mirror. While the gate is closed they read $FF, as on a Master '
                           'System.')
    else:
        rv[k] = v
    if k == '0x16':
        rv['0x17'] = '$A7: the machine ID (software_detection.machine_id)'
p['port_map']['masterdrive_read_values'] = rv
p['port_map']['mode_scope'] = (
    'In MasterDrive mode the registers at 0x01-0x17 answer only ' + GATE + '; 0x00 always answers. In Game Gear mode '
    '0x00-0x06 are always its registers. Writes to VDP bank 0 R11-R15 take effect only in MasterDrive mode '
    '(vdp_registers.bank_0_scope). In every other case these ports and registers do what they do on the stock machine.')
put_after(p['port_map'], 'mode_scope', 'native_gate', (
    'Decided by the owner, October 2026 (Q1, with Q8): in MasterDrive mode the I/O registers at 0x01-0x17 answer only '
    'while software has Feature Enable A (VDP bank 0 R15) bit 7 set. Until then MasterDrive mode decodes 0x01-0x17 as '
    'the Master System does: an even port writes 0x3E, an odd port writes 0x3F, and a read returns $FF. 0x00 (Start '
    'and region) always answers. Bit 7 is clear at reset. The gate is live: clearing the bit closes the ports again, '
    'and what the registers were set to (work RAM bank, slot select, card bank, stereo, the math operands, PCM and '
    'wavetable) stays in force.'))
p['port_map']['open_risk'] = (
    'RESOLVED by the I/O gate (Q1, native_gate). The MasterDrive registers stay at 0x01-0x17 inside the 0x3E/0x3F '
    'mirror range, and answer only once native software sets Feature Enable A bit 7, so old code running in MasterDrive '
    'mode (a retagged or converted title, or an export cartridge started in MasterDrive mode, software_detection) that '
    'writes a mirror address there reaches memory or I/O control, as on a Master System. What remains: old code that '
    'writes VDP R15 with bit 7 set opens the registers (vdp_registers.bank_0_evidence), and old code in MasterDrive '
    'mode meets the rest of MasterDrive behaviour (software_detection.native_mode).')
p['vdp_registers']['bank_0']['15'] = ('Feature Enable A - bit0 CRAM native, bit1 line-scroll H, bit2 window, bit3 ESAT, '
                                      'bit4 16 sprites/line, bit5 XRB, bit6 turbo (enables writes to $F3), bit7 the '
                                      'MasterDrive I/O registers at $01-$17 (port_map.native_gate)')
p['vdp_registers']['bank_0_evidence'] = (
    'Evidence, not proof (a risk from Technical Reference v2 that v3 keeps): six commercial titles were checked '
    'and none write VDP registers 11-15, where Feature Enable A lives. It matters for old code running in MasterDrive '
    'mode, the only mode in which those registers take effect (bank_0_scope): an old title that set R15 bit 7 there '
    'would also open the I/O registers at $01-$17 (port_map.native_gate).')
p['software_detection'] = {
    'status': 'RESOLVED (Q8, decided by the owner, October 2026)',
    'question': ('How does one ROM tell, at run time, that it is on a MasterDrive? Extended '
                 'features are reachable only in MasterDrive mode, which the header region '
                 '(8) selects, and an export SMS BIOS refuses region 8. A single ROM for both '
                 'machines therefore cannot use region 8.'),
    'options': [
        'Two ROMs from one source (what the Super Mario Land DX port does now).',
        'A boot-menu option to run a region-4 cartridge in MasterDrive mode, plus a read-only '
        'machine ID register the ROM can test.',
        'An unlock sequence that switches a running region-4 title into MasterDrive mode.',
    ],
    'chosen': 'option 2: a boot-menu option and a read-only machine ID register',
    'boot_menu': ('The boot menu can start an export (region 4) cartridge in MasterDrive mode instead of Master System '
                  'mode. It then starts as MasterDrive software does: every extension off, and the I/O registers waiting '
                  'for Feature Enable A bit 7 (port_map.native_gate). On the Analogue Pocket core this is System = '
                  'MasterDrive; in the emulator, the machine-mode selector.'),
    'native_mode': ('Old code started this way meets MasterDrive behaviour: the pad reads as a Mega Drive pad (B and C '
                    'as buttons 1 and 2 with TH high), the enhancement layer does not act, 0xF0-0xFF are fully decoded, '
                    'VDP registers 11-15 take effect, and the TMS modes raise line interrupts when R0 bit 4 is set. '
                    '0x00 reads Start and region. The option is for software that detects the machine; ordinary games '
                    'run in Master System mode.'),
    'machine_id': {
        'port': '0x17',
        'value': '0xA7',
        'encoding': 'high nibble $A = MasterDrive; low nibble = the machine version (7)',
        'access': 'read-only, MasterDrive mode, ' + GATE + '; a write is absorbed',
        'otherwise': ('while the gate is closed a read gives $FF and a write is a 0x3F mirror write; in the other modes '
                      'the port does what it does on the stock machine ($FF on the Master System and Game Gear, the '
                      'controller mirror in the SG-1000, SC-3000 and SF-7000 modes)'),
    },
    'procedure': ('Write VDP R15 with bit 7 set (on a stock VDP register 15 does nothing), then IN A,($17): a '
                  'MasterDrive in MasterDrive mode answers with $A in the high nibble. Test the high nibble rather than '
                  'only for a value other than $FF, since some sources describe open bus at the low ports of stock '
                  'consoles.'),
    'source': 'Super Mario Land DX port design, distribution question',
}
change(LATER + 'Q1 resolved by the owner: in MasterDrive mode the I/O registers at $01-$17 answer only while Feature '
       'Enable A bit 7 is set (port_map.native_gate); until then those ports are the $3E/$3F mirrors and read $FF, as on '
       'a Master System, and $00 still answers. The gate is live and the registers keep their settings while it is '
       'closed. port_map.mode_scope and open_risk and Feature Enable A (bank 0 R15) follow.')
change(LATER + 'Q8 resolved by the owner: a boot-menu option runs an export cartridge in MasterDrive mode, and a read-only '
       'machine ID register at $17 reads $A7 (high nibble $A = MasterDrive, low nibble the machine version), behind '
       'the I/O gate of Q1 (software_detection).')

p['v7_changes'] = changes
# key order: identification first, then scope, then the v7 summary, then the body
p['open_questions'].sort(key=lambda q: int(q['id'][1:]))
front = ['$schema', 'supersedes', 'scope', 'glossary', 'v7_changes']
out = {k: p[k] for k in front}
out.update({k: v for k, v in p.items() if k not in front})

# The machine was called Super Sega until October 2026. Every name inherited from
# v6 is renamed here, so the profile comes out the same from v6 or from itself.
# (The old name is built from parts so that a search for it finds only history.)
OLD = 'Super' + ' Sega'
OLD_KEY = 'super' + '_sega'
OLD_ID = 'SUPER' + '_SEGA'
def renamed(o):
    if isinstance(o, dict):
        return {(k.replace(OLD_KEY, 'masterdrive') if k != 'supersedes' else k): renamed(v) for k, v in o.items()}
    if isinstance(o, list):
        return [renamed(v) for v in o]
    if isinstance(o, str):
        if o == OLD_ID:
            return 'MASTERDRIVE'
        return re.sub(r'(?<!formerly )' + OLD, 'MasterDrive', o)
    return o
out = renamed(out)
json.dump(out, open(dst, 'w'), indent=1, ensure_ascii=False)
print(f'{len(changes)} changes; sections: {len(p)}')
