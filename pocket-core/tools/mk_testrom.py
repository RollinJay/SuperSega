#!/usr/bin/env python3
"""Build the small test ROMs in roms/ that the simulations and the emulator checks use.

usage: mk_testrom.py outdir

Writes vdp192.sms, vdp224.sms, vdp240.sms, save.sms with save_in.sav, spr12.sms,
tone.sms, fm.sms, fm_tight.sms, ssfeat.sms, ports.sms, and the SG-1000 ROMs tms_g1.sg, tms_g2.sg,
tms_mc.sg and tms_txt.sg for the four TMS9918 picture modes (build_tms). The VDP ROMs are described here; each of the
other builder functions below describes its ROM. Each VDP ROM sets Mode 4 with M2 set,
selects the height with M1 (224) or M3 (240) or neither (192), fills the whole
32x32 name table at $3700 (tall modes) / 32x28 at $3800 (192), places sprites
near the bottom of the screen, one at Y=$D0 (a terminator only in 192-line
mode) and one at Y=$F8 (wraps to the top), and scrolls both axes once per frame
from the frame interrupt. The pictures from the emulator, the RTL machine and
Gearsystem (192/224) are compared frame by frame.
"""
import os
import sys


class Asm:
    def __init__(self):
        self.b = bytearray(0x8000)
        self.pc = 0
        self.labels = {}
        self.fix = []          # (pos, label, kind)

    def org(self, a): self.pc = a
    def label(self, n): self.labels[n] = self.pc
    def db(self, *v):
        for x in v:
            self.b[self.pc] = x & 0xFF; self.pc += 1
    def dw(self, v): self.db(v & 0xFF, v >> 8)
    def ref16(self, n): self.fix.append((self.pc, n, 'abs')); self.db(0, 0)
    def rel(self, n): self.fix.append((self.pc, n, 'rel')); self.db(0)

    def resolve(self):
        for pos, n, kind in self.fix:
            t = self.labels[n]
            if kind == 'abs':
                self.b[pos] = t & 0xFF; self.b[pos + 1] = t >> 8
            else:
                d = t - (pos + 1)
                assert -128 <= d < 128, n
                self.b[pos] = d & 0xFF


def build(height):
    a = Asm()
    r0 = 0x06                                  # M4 + M2
    r1_mode = {192: 0x00, 224: 0x10, 240: 0x08}[height]
    nt = 0x3700 if height != 192 else 0x3800
    r2 = 0xFF
    rows = 32 if height != 192 else 28

    # reset
    a.org(0x0000)
    a.db(0xF3)                                 # DI
    a.db(0xED, 0x56)                           # IM 1
    a.db(0x31); a.dw(0xDFF0)                   # LD SP,$DFF0
    a.db(0xC3); a.ref16('main')                # JP main

    # frame interrupt: count frames, scroll V by 1 and H by 2 per frame
    a.org(0x0038)
    a.db(0xF5)                                 # PUSH AF
    a.db(0xDB, 0xBF)                           # IN A,($BF)   acknowledge
    a.db(0x3A); a.dw(0xC000)                   # LD A,($C000)
    a.db(0x3C)                                 # INC A
    a.db(0x32); a.dw(0xC000)                   # LD ($C000),A
    a.db(0xD3, 0xBF)                           # OUT ($BF),A  value
    a.db(0x3E, 0x89)                           # LD A,$89     -> R9 (V scroll)
    a.db(0xD3, 0xBF)
    a.db(0x3A); a.dw(0xC000)
    a.db(0x87)                                 # ADD A,A
    a.db(0xD3, 0xBF)
    a.db(0x3E, 0x88)                           # -> R8 (H scroll)
    a.db(0xD3, 0xBF)
    a.db(0xF1)                                 # POP AF
    a.db(0xFB)                                 # EI
    a.db(0xED, 0x4D)                           # RETI
    a.org(0x0066)
    a.db(0xED, 0x45)                           # RETN

    a.org(0x0100)
    a.label('main')
    # work RAM frame counter = 0
    a.db(0xAF); a.db(0x32); a.dw(0xC000)       # XOR A ; LD ($C000),A
    # VDP registers (display off while loading)
    a.db(0x21); a.ref16('regs')                # LD HL,regs
    a.db(0x06, 22)                             # LD B,22
    a.db(0x0E, 0xBF)                           # LD C,$BF
    a.db(0xED, 0xB3)                           # OTIR
    # CRAM 0-31
    a.db(0x3E, 0x00, 0xD3, 0xBF, 0x3E, 0xC0, 0xD3, 0xBF)
    a.db(0x21); a.ref16('pal')
    a.db(0x06, 32, 0x0E, 0xBE, 0xED, 0xB3)
    # tiles 1-4 at VRAM $0020
    a.db(0x3E, 0x20, 0xD3, 0xBF, 0x3E, 0x40, 0xD3, 0xBF)
    a.db(0x21); a.ref16('tiles')
    a.db(0x06, 128, 0x0E, 0xBE, 0xED, 0xB3)
    # name table: tile ((row + col) & 3) + 1, palette bit = row & 1
    a.db(0x3E, nt & 0xFF, 0xD3, 0xBF, 0x3E, 0x40 | (nt >> 8), 0xD3, 0xBF)
    a.db(0x16, 0x00)                           # LD D,0
    a.label('row')
    a.db(0x1E, 0x00)                           # LD E,0
    a.label('col')
    a.db(0x7A, 0x83, 0xE6, 0x03, 0x3C)         # LD A,D ; ADD A,E ; AND 3 ; INC A
    a.db(0xD3, 0xBE)
    a.db(0x7A, 0xE6, 0x01, 0x07, 0x07, 0x07)   # LD A,D ; AND 1 ; RLCA x3
    a.db(0xD3, 0xBE)
    a.db(0x1C, 0x7B, 0xFE, 32)                 # INC E ; LD A,E ; CP 32
    a.db(0x20); a.rel('col')
    a.db(0x14, 0x7A, 0xFE, rows)               # INC D ; LD A,D ; CP rows
    a.db(0x20); a.rel('row')
    # sprite Y table at $3F00 (64 entries)
    a.db(0x3E, 0x00, 0xD3, 0xBF, 0x3E, 0x7F, 0xD3, 0xBF)
    a.db(0x21); a.ref16('saty')
    a.db(0x06, 64, 0x0E, 0xBE, 0xED, 0xB3)
    # sprite X/tile at $3F80
    a.db(0x3E, 0x80, 0xD3, 0xBF, 0x3E, 0x7F, 0xD3, 0xBF)
    a.db(0x21); a.ref16('satxt')
    a.db(0x06, 16, 0x0E, 0xBE, 0xED, 0xB3)
    # display on, frame interrupt on, height bits
    a.db(0x3E, 0x60 | r1_mode, 0xD3, 0xBF, 0x3E, 0x81, 0xD3, 0xBF)
    a.db(0xFB)                                 # EI
    a.label('loop')
    a.db(0x18); a.rel('loop')                  # JR loop

    a.label('regs')
    for i, v in enumerate([r0, r1_mode, r2, 0xFF, 0xFF, 0xFF, 0xFB, 0x00, 0x00, 0x00, 0xFF]):
        a.db(v, 0x80 | i)
    a.label('pal')
    # background palette: 16 distinct colours; sprite palette: bright set
    bg = [0x00, 0x03, 0x0C, 0x0F, 0x30, 0x33, 0x3C, 0x3F, 0x01, 0x04, 0x10, 0x05, 0x14, 0x11, 0x15, 0x2A]
    sp = [0x00, 0x3F, 0x0B, 0x2E, 0x38, 0x07, 0x1F, 0x3B, 0x22, 0x0A, 0x28, 0x02, 0x08, 0x20, 0x2F, 0x3A]
    a.db(*bg); a.db(*sp)
    a.label('tiles')
    pats = [
        [0xFF, 0x00, 0x00, 0x00] * 8,                                    # colour 1 solid
        [0x00, 0xFF, 0x00, 0x00, 0xFF, 0xFF, 0x00, 0x00] * 4,            # stripes 2/3
        [0xAA, 0x55, 0xFF, 0x00, 0x55, 0xAA, 0xFF, 0x00] * 4,            # checker
        [0x81, 0x42, 0x24, 0x18, 0x18, 0x24, 0x42, 0x81] * 4,            # diagonal mix
    ]
    for p in pats:
        a.db(*p)
    a.label('saty')
    ys = [0xF8, 0xD0, 200, 215, 100, 100] + [0xE0] * 58
    if height == 192:
        ys = [0xF8, 150, 170, 183, 100, 100] + [0xD0] + [0xE0] * 57
    a.db(*ys)
    a.label('satxt')
    a.db(16, 1, 40, 2, 64, 3, 88, 4, 120, 1, 124, 2, 0, 0, 0, 0)
    a.resolve()

    rom = a.b
    # TMR SEGA header, region 4 (SMS export), 32 KB
    hdr = b'TMR SEGA' + b'\x00\x00'
    rom[0x7FF0:0x7FFA] = hdr
    cs = sum(rom[0:0x7FF0]) & 0xFFFF
    rom[0x7FFA] = cs & 0xFF; rom[0x7FFB] = cs >> 8
    rom[0x7FFC] = 0x00; rom[0x7FFD] = 0x00; rom[0x7FFE] = 0x00
    rom[0x7FFF] = 0x4C
    return bytes(rom)


def build_save():
    """Cartridge RAM test: map cart RAM bank 0 at $8000 ($FFFC = $08) and write
    (address low byte XOR $5A) to $8100-$81FF, leaving the rest of the RAM as
    loaded. The save slot read back over the bridge must show the loaded file
    with only offsets $0100-$01FF replaced."""
    a = Asm()
    a.org(0x0000)
    a.db(0xF3, 0xED, 0x56)                     # DI ; IM 1
    a.db(0x31); a.dw(0xDFF0)                   # LD SP,$DFF0
    a.db(0x3E, 0x08, 0x32); a.dw(0xFFFC)       # LD A,$08 ; LD ($FFFC),A
    a.db(0x21); a.dw(0x8100)                   # LD HL,$8100
    a.db(0x06, 0x00)                           # LD B,0 (256 passes)
    a.label('fill')
    a.db(0x7D, 0xEE, 0x5A, 0x77, 0x23)         # LD A,L ; XOR $5A ; LD (HL),A ; INC HL
    a.db(0x10); a.rel('fill')                  # DJNZ fill
    a.label('loop')
    a.db(0x18); a.rel('loop')
    a.resolve()
    rom = a.b
    rom[0x7FF0:0x7FFA] = b'TMR SEGA' + b'\x00\x00'
    cs = sum(rom[0:0x7FF0]) & 0xFFFF
    rom[0x7FFA] = cs & 0xFF; rom[0x7FFB] = cs >> 8
    rom[0x7FFF] = 0x4C
    return bytes(rom)


def build_sprites():
    """Twelve sprites on the same eight lines (100-107), for the sprite-limit
    boost: stock shows the first 8, the boost shows all 12. Sprite 12 sits on
    lines 120-127 alone. Status is read every frame from the interrupt."""
    a = Asm()
    a.org(0x0000)
    a.db(0xF3, 0xED, 0x56, 0x31); a.dw(0xDFF0)
    a.db(0xC3); a.ref16('main')
    a.org(0x0038)
    # frame interrupt: backdrop = sprite colour 2 if the overflow flag was set
    # during the frame, else colour 1; the masked left column shows it
    a.db(0xF5, 0xDB, 0xBF, 0x32); a.dw(0xC001)  # PUSH AF ; IN A,($BF) ; LD ($C001),A
    a.db(0xE6, 0x40, 0x28, 0x04)               # AND $40 ; JR Z,+4
    a.db(0x3E, 0x02, 0x18, 0x02)               # LD A,2 ; JR +2
    a.db(0x3E, 0x01)                           # LD A,1
    a.db(0xD3, 0xBF, 0x3E, 0x87, 0xD3, 0xBF)   # R7 = A
    a.db(0xF1, 0xFB, 0xED, 0x4D)               # POP AF ; EI ; RETI
    a.org(0x0066)
    a.db(0xED, 0x45)
    a.org(0x0100)
    a.label('main')
    a.db(0x21); a.ref16('regs'); a.db(0x06, 22, 0x0E, 0xBF, 0xED, 0xB3)
    a.db(0x3E, 0x00, 0xD3, 0xBF, 0x3E, 0xC0, 0xD3, 0xBF)       # CRAM 0
    a.db(0x21); a.ref16('pal'); a.db(0x06, 32, 0x0E, 0xBE, 0xED, 0xB3)
    a.db(0x3E, 0x20, 0xD3, 0xBF, 0x3E, 0x40, 0xD3, 0xBF)       # tile 1 at $0020
    a.db(0x21); a.ref16('tile'); a.db(0x06, 32, 0x0E, 0xBE, 0xED, 0xB3)
    a.db(0x3E, 0x00, 0xD3, 0xBF, 0x3E, 0x7F, 0xD3, 0xBF)       # SAT Y at $3F00
    a.db(0x21); a.ref16('saty'); a.db(0x06, 64, 0x0E, 0xBE, 0xED, 0xB3)
    a.db(0x3E, 0x80, 0xD3, 0xBF, 0x3E, 0x7F, 0xD3, 0xBF)       # SAT X/tile at $3F80
    a.db(0x21); a.ref16('satxt'); a.db(0x06, 26, 0x0E, 0xBE, 0xED, 0xB3)
    a.db(0x3E, 0x60, 0xD3, 0xBF, 0x3E, 0x81, 0xD3, 0xBF)       # display + frame IRQ
    a.db(0xFB)
    a.label('loop'); a.db(0x18); a.rel('loop')
    a.label('regs')
    for i, v in enumerate([0x26, 0x00, 0xFF, 0xFF, 0xFF, 0xFF, 0xFB, 0x01, 0x00, 0x00, 0xFF]):
        a.db(v, 0x80 | i)
    a.label('pal')
    a.db(*([0x00, 0x15] + [0x00] * 14))
    a.db(*[0x00, 0x03, 0x0C, 0x30, 0x0F, 0x33, 0x3C, 0x3F, 0x02, 0x08, 0x20, 0x0A, 0x22, 0x28, 0x2A, 0x17])
    a.label('tile')
    a.db(*([0xFF, 0x00, 0x00, 0x00] * 8))      # colour 1 solid
    a.label('saty')
    a.db(*([99] * 12 + [119] + [0xD0] + [0xE0] * 50))
    a.label('satxt')
    for k in range(13):
        a.db(16 + 18 * k if k < 12 else 40, 1)
    a.resolve()
    rom = a.b
    rom[0x7FF0:0x7FFA] = b'TMR SEGA' + b'\x00\x00'
    cs = sum(rom[0:0x7FF0]) & 0xFFFF
    rom[0x7FFA] = cs & 0xFF; rom[0x7FFB] = cs >> 8
    rom[0x7FFF] = 0x4C
    return bytes(rom)


def build_tone():
    """PSG check: tone 0 at period $0FE (3579545 / (32 x 254) = 440.4 Hz) at full
    volume, everything else silent, for the audio capture and pseudo-stereo."""
    a = Asm()
    a.org(0x0000)
    a.db(0xF3, 0x31); a.dw(0xDFF0)
    a.db(0x21); a.ref16('psg'); a.db(0x06, 7, 0x0E, 0x7F, 0xED, 0xB3)   # OTIR to $7F
    a.label('loop'); a.db(0x18); a.rel('loop')
    a.label('psg')
    a.db(0x8E, 0x0F, 0x90, 0xBF, 0xDF, 0xFF, 0xFF)   # tone0 = $0FE, vol0 = 0, others off
    a.resolve()
    rom = a.b
    rom[0x7FF0:0x7FFA] = b'TMR SEGA' + b'\x00\x00'
    cs = sum(rom[0:0x7FF0]) & 0xFFFF
    rom[0x7FFA] = cs & 0xFF; rom[0x7FFB] = cs >> 8
    rom[0x7FFF] = 0x4C
    return bytes(rom)


FM_STEPS = [(10, 1), (20, 3), (30, 2), (40, 0)]     # (frame, $F2 value) after the start in state 0
FM_SLOW = [(60, 1), (120, 3), (180, 2), (240, 0)]   # then, repeated: one second per state


def build_fm(tight=False):
    """FM check (YM2413). Reads $F2 back after writing 1 (stored at $C010), then
    plays the PSG tone of tone.sms (440.4 Hz) and, on FM channel 0, a sine:
    the user instrument with the modulator at its lowest level (TL 63), no
    feedback, instant attack, sustained at full level, F-number 330 in block 5
    (330 x 2^5 x 49716 / 2^19 = 1001.4 Hz) at volume 0 (loudest). $F2 starts at
    0 (PSG only), then takes the values in FM_STEPS at those frame counts:
    1 FM only, 3 both, 2 neither, 0 PSG only again. tools/check_fm_wav.py checks
    a capture of those 50 frames. After them the ROM repeats the four states for
    a second each (FM_SLOW: PSG only, FM only, both, neither), slow enough to
    judge by ear on a Pocket. Register writes keep the chip's waits (12
    master-clock cycles after an address, 84 after data).

    tight=True (fm_tight.sms) writes the registers the way a sound driver does,
    with little to spare at 100 %: 15 T-states from the address write to the
    data write and about 150 from data to the next address. At 200 % turbo that
    is 7.5 and 75 base cycles, too soon for the chip, so the FM sound is heard
    only if the bus synchroniser holds the CPU for the FM chip (run it with the
    turbo boost)."""
    a = Asm()
    a.org(0x0000)
    a.db(0xF3, 0xED, 0x56, 0x31); a.dw(0xDFF0)             # DI ; IM 1 ; LD SP,$DFF0
    a.db(0xC3); a.ref16('main')
    a.org(0x0038)                                          # frame IRQ: count frames at $C000
    a.db(0xF5, 0xDB, 0xBF, 0x3A); a.dw(0xC000); a.db(0x3C, 0x32); a.dw(0xC000)
    a.db(0xF1, 0xFB, 0xED, 0x4D)
    a.org(0x0066)
    a.db(0xED, 0x45)                                       # RETN (Pause)
    a.org(0x0080)
    a.label('main')
    a.db(0xAF, 0x32); a.dw(0xC000)                         # frame count 0
    a.db(0x3E, 0x04, 0xD3, 0xBF, 0x3E, 0x80, 0xD3, 0xBF)  # R0 = $04: Mode 4
    a.db(0x3E, 0x20, 0xD3, 0xBF, 0x3E, 0x81, 0xD3, 0xBF)  # R1 = $20: frame IRQ on, display off
    a.db(0x3E, 0x01, 0xD3, 0xF2, 0xDB, 0xF2, 0xE6, 0x03, 0x32); a.dw(0xC010)   # FM detection read-back
    a.db(0xAF, 0xD3, 0xF2)                                 # $F2 = 0: PSG only
    a.db(0x21); a.ref16('psg'); a.db(0x06, 7, 0x0E, 0x7F, 0xED, 0xB3)   # PSG tone 0
    a.db(0x21); a.ref16('fmregs'); a.db(0x06, 12, 0xCD); a.ref16('fmw')
    a.db(0xDB, 0xBF, 0xFB)                                 # clear a pending frame flag ; EI
    for i, (frame, value) in enumerate(FM_STEPS):
        a.label(f'w{i}')
        a.db(0x3A); a.dw(0xC000); a.db(0xFE, frame, 0x38); a.rel(f'w{i}')   # wait for the frame count
        a.db(0x3E, value, 0xD3, 0xF2)
    a.label('slow'); a.db(0xAF, 0x32); a.dw(0xC000)        # frame count 0, $F2 still 0
    for i, (frame, value) in enumerate(FM_SLOW):
        a.label(f's{i}')
        a.db(0x3A); a.dw(0xC000); a.db(0xFE, frame, 0x38); a.rel(f's{i}')
        a.db(0x3E, value, 0xD3, 0xF2)
    a.db(0x18); a.rel('slow')
    # fmw: B (register, value) pairs from HL to $F0/$F1, with the chip's waits
    a.label('fmw')
    if tight:
        a.db(0x7E, 0x23, 0x4E, 0x23)                       # LD A,(HL) ; INC HL ; LD C,(HL) ; INC HL
        a.db(0xD3, 0xF0, 0x79, 0xD3, 0xF1)                 # OUT ($F0),A ; LD A,C ; OUT ($F1),A
        a.db(0xC5, 0x06, 0x06); a.label('fw1'); a.db(0x10); a.rel('fw1'); a.db(0xC1)
    else:
        a.db(0x7E, 0xD3, 0xF0, 0x23, 0xC5, 0x06, 0x02); a.label('fw1'); a.db(0x10); a.rel('fw1'); a.db(0xC1)
        a.db(0x7E, 0xD3, 0xF1, 0x23, 0xC5, 0x06, 0x08); a.label('fw2'); a.db(0x10); a.rel('fw2'); a.db(0xC1)
    a.db(0x10); a.rel('fmw')
    a.db(0xC9)
    a.label('psg')
    a.db(0x8E, 0x0F, 0x90, 0xBF, 0xDF, 0xFF, 0xFF)         # tone0 = $0FE, vol0 = 0, others off
    a.label('fmregs')
    a.db(0x00, 0x21, 0x01, 0x21,                           # modulator, carrier: sustained, MUL 1
         0x02, 0x3F, 0x03, 0x00,                           # modulator TL 63 ; carrier KSL 0, no feedback
         0x04, 0xF0, 0x05, 0xF0,                           # attack 15, decay 0
         0x06, 0x00, 0x07, 0x00,                           # sustain level 0, release 0
         0x0E, 0x00,                                       # rhythm off
         0x10, 0x4A, 0x30, 0x00,                           # channel 0: F-number low $4A ; user instrument, volume 0
         0x20, 0x1B)                                       # key on, block 5, F-number bit 8
    a.resolve()
    rom = a.b
    rom[0x7FF0:0x7FFA] = b'TMR SEGA' + b'\x00\x00'
    cs = sum(rom[0:0x7FF0]) & 0xFFFF
    rom[0x7FFA] = cs & 0xFF; rom[0x7FFB] = cs >> 8
    rom[0x7FFF] = 0x4C
    return bytes(rom)


def build_ss():
    """Super Sega features: extended register banks (XRB), native 12-bit CRAM,
    extended CRAM (16 palettes, unwritten ones alias to palette AND 1), the
    224-line height through Feature Enable B, 16 sprites per line, and 200 %
    turbo with the bus synchroniser holding VRAM writes made during active
    display. The main loop rewrites a name-table row with OTIR forever, with
    the same data, so the picture is the same whatever the timing."""
    a = Asm()
    a.org(0x0000)
    a.db(0xF3, 0xED, 0x56, 0x31); a.dw(0xDFF0)
    a.db(0xC3); a.ref16('main')
    a.org(0x0038)
    a.db(0xF5, 0xDB, 0xBF, 0xF1, 0xFB, 0xED, 0x4D)          # ack frame IRQ
    a.org(0x0066)
    a.db(0xED, 0x45)
    a.org(0x0100)
    a.label('main')
    a.db(0x21); a.ref16('regs'); a.db(0x06, 30, 0x0E, 0xBF, 0xED, 0xB3)   # 15 register writes
    # native CRAM: palettes 0, 1, 2 (bytes 0-95) and palette 5 (bytes 160-191)
    a.db(0x3E, 0x00, 0xD3, 0xBF, 0x3E, 0xC0, 0xD3, 0xBF)
    a.db(0x21); a.ref16('pal012'); a.db(0x06, 96, 0x0E, 0xBE, 0xED, 0xB3)
    a.db(0x3E, 0xA0, 0xD3, 0xBF, 0x3E, 0xC0, 0xD3, 0xBF)
    a.db(0x21); a.ref16('pal5'); a.db(0x06, 32, 0x0E, 0xBE, 0xED, 0xB3)
    # tiles 1-4
    a.db(0x3E, 0x20, 0xD3, 0xBF, 0x3E, 0x40, 0xD3, 0xBF)
    a.db(0x21); a.ref16('tiles'); a.db(0x06, 128, 0x0E, 0xBE, 0xED, 0xB3)
    # name table $3700: 32 x 32, tile (col & 3) + 1, palette = row & 15
    a.db(0x3E, 0x00, 0xD3, 0xBF, 0x3E, 0x77, 0xD3, 0xBF)
    a.db(0x16, 0x00)
    a.label('row'); a.db(0x1E, 0x00)
    a.label('col')
    a.db(0x7B, 0xE6, 0x03, 0x3C, 0xD3, 0xBE)                 # tile = (E & 3) + 1
    # high byte: bit 3 = row bit 0, bits 7-5 = row bits 3-1
    a.db(0x7A, 0xE6, 0x01, 0x07, 0x07, 0x07, 0x47)           # B = (D & 1) << 3
    a.db(0x7A, 0xE6, 0x0E, 0x07, 0x07, 0x07, 0x07, 0xB0)     # A = ((D & 14) << 4) | B
    a.db(0xD3, 0xBE)
    a.db(0x1C, 0x7B, 0xFE, 32); a.db(0x20); a.rel('col')
    a.db(0x14, 0x7A, 0xFE, 32); a.db(0x20); a.rel('row')
    # sprites: 12 on lines 100-107, sprite 12 alone at 150
    a.db(0x3E, 0x00, 0xD3, 0xBF, 0x3E, 0x7F, 0xD3, 0xBF)
    a.db(0x21); a.ref16('saty'); a.db(0x06, 64, 0x0E, 0xBE, 0xED, 0xB3)
    a.db(0x3E, 0x80, 0xD3, 0xBF, 0x3E, 0x7F, 0xD3, 0xBF)
    a.db(0x21); a.ref16('satxt'); a.db(0x06, 26, 0x0E, 0xBE, 0xED, 0xB3)
    # turbo: Feature Enable A bit 6, then $F3 = 4 (200 %)
    a.db(0x3E, 0x71, 0xD3, 0xBF, 0x3E, 0x8F, 0xD3, 0xBF)
    a.db(0x3E, 0x04, 0xD3, 0xF3)
    # display on + frame IRQ
    a.db(0x3E, 0x60, 0xD3, 0xBF, 0x3E, 0x81, 0xD3, 0xBF)
    a.db(0xFB)
    # forever: rewrite name-table row 20 (identical data) during the display
    a.label('loop')
    a.db(0x3E, 0x00, 0xD3, 0xBF, 0x3E, 0x7C, 0xD3, 0xBF)    # VRAM write at $3700 + 20*64 = $3C00
    a.db(0x21); a.ref16('row20'); a.db(0x06, 64, 0x0E, 0xBE, 0xED, 0xB3)
    a.db(0x18); a.rel('loop')
    a.label('regs')
    # R0..R10 stock, then R15 = $31 (XRB, native CRAM, 16 sprites), then bank 1
    # R2 (Feature Enable B) = $42: 224 lines (bits 7-6 = 01) + extended CRAM
    for i, v in enumerate([0x06, 0x00, 0xFF, 0xFF, 0xFF, 0xFF, 0xFB, 0x00, 0x00, 0x00, 0xFF]):
        a.db(v, 0x80 | i)
    a.db(0x31, 0x8F)
    a.db(0x42, 0x92)
    a.db(0x00, 0x88, 0x00, 0x89)                              # R8, R9 = 0 again
    a.label('pal012')
    for p in range(3):
        for c in range(16):
            r, g, b = (c * 1 + p * 5) & 15, (c * 3 + p * 7) & 15, (15 - c + p * 3) & 15
            a.db((g << 4) | r, b)
    a.label('pal5')
    for c in range(16):
        a.db(((c * 2) & 15) << 4 | 15, c)
    a.label('tiles')
    pats = [
        [0xFF, 0x00, 0x00, 0x00] * 8,
        [0x00, 0xFF, 0x00, 0x00, 0xFF, 0xFF, 0x00, 0x00] * 4,
        [0xAA, 0x55, 0xFF, 0x00, 0x55, 0xAA, 0xFF, 0x00] * 4,
        [0x81, 0x42, 0x24, 0x18, 0x18, 0x24, 0x42, 0x81] * 4,
    ]
    for pt in pats:
        a.db(*pt)
    a.label('saty')
    a.db(*([99] * 12 + [149] + [0xE0] * 51))
    a.label('satxt')
    for k in range(13):
        a.db(16 + 18 * k if k < 12 else 40, (k % 4) + 1)
    a.label('row20')
    for col in range(32):
        a.db((col & 3) + 1, ((20 & 1) << 3) | ((20 & 14) << 4))
    a.resolve()
    rom = a.b
    rom[0x7FF0:0x7FFA] = b'TMR SEGA' + b'\x00\x00'
    cs = sum(rom[0:0x7FF0]) & 0xFFFF
    rom[0x7FFA] = cs & 0xFF; rom[0x7FFB] = cs >> 8
    rom[0x7FFF] = 0x8C                                       # region 8: Super Sega
    return bytes(rom)



PORTS_READ = [0x00, 0x01, 0x05, 0x06, 0x09, 0x0E, 0x16, 0x3F, 0xC0,
              0xC1, 0xDC, 0xDD, 0xF2, 0xF4, 0xFB, 0xFC, 0xFD, 0xFF]


def build_ports():
    """I/O decode check. Writes $A5 to the debug control port $FB, then reads
    the ports in PORTS_READ over and over, showing each as a row of the screen:
    the port number's bits in grey (columns 6-13) and the value read in white
    (columns 16-23), rows 3-20, so the Game Gear window shows them all. Run in
    each machine mode and compare the emulator with the RTL; no input is pressed
    when the frames are taken."""
    a = Asm()
    a.org(0x0000)
    a.db(0xF3, 0xED, 0x56, 0x31); a.dw(0xDFF0)             # DI ; IM 1 ; LD SP,$DFF0
    a.db(0xC3); a.ref16('main')
    a.org(0x0066)
    a.db(0xED, 0x45)                                       # RETN (Pause)
    a.org(0x0080)
    a.label('main')
    a.db(0x21); a.ref16('vdpregs'); a.db(0x06, 22, 0x0E, 0xBF, 0xED, 0xB3)   # OTIR registers
    a.db(0x3E, 0x00, 0xD3, 0xBF, 0x3E, 0xC0, 0xD3, 0xBF)  # CRAM address 0
    a.db(0x3E, 0x00, 0xD3, 0xBE, 0x3E, 0x3F, 0xD3, 0xBE, 0x3E, 0x15, 0xD3, 0xBE)   # black, white, grey
    a.db(0x3E, 0x00, 0xD3, 0xBF, 0x3E, 0x40, 0xD3, 0xBF)  # VRAM $0000
    a.db(0x06, 32, 0xAF); a.label('t0'); a.db(0xD3, 0xBE, 0x10); a.rel('t0')              # tile 0 blank
    a.db(0x06, 8); a.label('t1'); a.db(0x3E, 0xFF, 0xD3, 0xBE, 0xAF, 0xD3, 0xBE, 0xD3, 0xBE, 0xD3, 0xBE, 0x10); a.rel('t1')   # tile 1 colour 1
    a.db(0x06, 8); a.label('t2'); a.db(0xAF, 0xD3, 0xBE, 0x3E, 0xFF, 0xD3, 0xBE, 0xAF, 0xD3, 0xBE, 0xD3, 0xBE, 0x10); a.rel('t2')  # tile 2 colour 2
    a.db(0x3E, 0x00, 0xD3, 0xBF, 0x3E, 0x78, 0xD3, 0xBF)  # VRAM $3800: name table
    a.db(0x11); a.dw(28 * 64)                              # LD DE,1792
    a.label('clr'); a.db(0xAF, 0xD3, 0xBE, 0x1B, 0x7A, 0xB3, 0x20); a.rel('clr')       # clear
    a.db(0x3E, 0x00, 0xD3, 0xBF, 0x3E, 0x7F, 0xD3, 0xBF, 0x3E, 0xD0, 0xD3, 0xBE)   # SAT: no sprites ($3F00 = $D0)
    a.db(0x3E, 0xA5, 0xD3, 0xFB)                           # OUT ($FB),$A5
    a.label('loop')
    # read every port into $C100...
    a.db(0x21); a.ref16('ports'); a.db(0x11); a.dw(0xC100); a.db(0x06, len(PORTS_READ))
    a.label('rd'); a.db(0x4E, 0xED, 0x78, 0x12, 0x23, 0x13, 0x10); a.rel('rd')   # LD C,(HL) ; IN A,(C) ; LD (DE),A ; INC HL ; INC DE ; DJNZ
    # ...then draw them, one row each from row 3
    a.db(0x21); a.dw(0x3800 + 3 * 64 + 6 * 2); a.db(0x22); a.dw(0xC200)   # row address
    a.db(0x21); a.ref16('ports'); a.db(0x22); a.dw(0xC204)
    a.db(0x21); a.dw(0xC100); a.db(0x22); a.dw(0xC206)
    a.db(0x3E, len(PORTS_READ), 0x32); a.dw(0xC202)
    a.label('row')
    a.db(0x2A); a.dw(0xC200); a.db(0x7D, 0xD3, 0xBF, 0x7C, 0xF6, 0x40, 0xD3, 0xBF)   # set VRAM address
    a.db(0x11); a.dw(64); a.db(0x19, 0x22); a.dw(0xC200)                              # next row
    a.db(0x2A); a.dw(0xC204); a.db(0x7E, 0x23, 0x22); a.dw(0xC204)                   # A = port number
    a.db(0x1E, 0x02, 0xCD); a.ref16('drawbyte')                                      # grey bits
    a.db(0xAF, 0xD3, 0xBE, 0xD3, 0xBE, 0xD3, 0xBE, 0xD3, 0xBE)                       # two blank cells
    a.db(0x2A); a.dw(0xC206); a.db(0x7E, 0x23, 0x22); a.dw(0xC206)                   # A = value read
    a.db(0x1E, 0x01, 0xCD); a.ref16('drawbyte')                                      # white bits
    a.db(0x3A); a.dw(0xC202); a.db(0x3D, 0x32); a.dw(0xC202); a.db(0x20); a.rel('row')
    a.db(0xC3); a.ref16('loop')
    # drawbyte: A = byte, E = tile for a set bit; 8 name-table entries, MSB first
    a.label('drawbyte')
    a.db(0x06, 0x08)
    a.label('db1'); a.db(0x07, 0xF5, 0x3E, 0x00, 0x30); a.rel('db0'); a.db(0x7B)    # RLCA ; PUSH AF ; LD A,0 ; JR NC ; LD A,E
    a.label('db0'); a.db(0xD3, 0xBE, 0xAF, 0xD3, 0xBE, 0xF1, 0x10); a.rel('db1')     # OUT ; XOR A ; OUT ; POP AF ; DJNZ
    a.db(0xC9)
    a.label('vdpregs')
    for r, v in enumerate([0x04, 0x40, 0xFF, 0xFF, 0xFF, 0xFF, 0xFB, 0x00, 0x00, 0x00, 0xFF]):
        a.db(v, 0x80 | r)
    a.label('ports')
    a.db(*PORTS_READ)
    a.resolve()
    rom = a.b
    rom[0x7FF0:0x7FFA] = b'TMR SEGA' + b'\x00\x00'
    cs = sum(rom[0:0x7FF0]) & 0xFFFF
    rom[0x7FFA] = cs & 0xFF; rom[0x7FFB] = cs >> 8
    rom[0x7FFF] = 0x4C
    return bytes(rom)


# ---------------------------------------------------------------- TMS9918 modes
def _shape(k, r):
    """One of eight 8x8 shapes, row r."""
    return [0xAA if r % 2 == 0 else 0x55,                    # checker
            0xFF if r in (0, 7) else 0x81,                   # box
            ((0x80 >> r) | (1 << r)) & 0xFF,                 # cross
            0xF0 if r < 4 else 0x0F,                         # quarters
            (0xFF >> r) & 0xFF,                              # wedge
            0xFF if r in (3, 4) else 0x18,                   # plus
            0x3C if 1 <= r <= 6 else 0x00,                   # block
            0x00 if r % 2 else 0xFF][k & 7]                  # stripes


def _ring16():
    """A 16x16 ring as the four 8-byte quadrants of a TMS sprite: top left,
    bottom left, top right, bottom right."""
    rows = []
    for y in range(16):
        bits = 0
        for x in range(16):
            d = (x - 7.5) ** 2 + (y - 7.5) ** 2
            if 20 <= d <= 60:
                bits |= 0x8000 >> x
        rows.append(bits)
    left = [r >> 8 for r in rows]
    right = [r & 0xFF for r in rows]
    return left[0:8] + left[8:16] + right[0:8] + right[8:16]


def build_tms(mode):
    """SG-1000 test ROM for one TMS9918 picture mode: g1 (Graphics I), g2
    (Graphics II), mc (Multicolor) or txt (Text). Tables: names at $3800,
    patterns at $0000 (Multicolor: its colour blocks), colours at $2000,
    sprite attributes at $3B00, sprite patterns at $1800. Sprites are 8x8 in
    g1, 16x16 in g2 and 8x8 magnified in mc; Text has none. The sprites:
      0 and 1 overlap on lines 84-87 (84-95 with 16-line sprites): 1 moves right
        3 pixels a frame across 0,
        so the collision flag is set on the frames where they meet, and 0
        stays on top (the lowest-numbered sprite wins)
      2-6 sit side by side on line 130: the fifth is not drawn and sets the
        overflow flag
      7 at Y = $FA shows its lower rows at the top of the screen
      8 has the early-clock bit, so it starts 32 pixels left of its X
      9 is transparent and overlaps 10: it draws nothing and sets no flag
    The frame interrupt reads the status register and sets the backdrop to
    1 + 4 x (status bits 6-5): black, then light blue (collision), light red
    (overflow) or magenta (both)."""
    a = Asm()
    NT, SAT, SPG, CT = 0x3800, 0x3B00, 0x1800, 0x2000
    r1 = {'g1': 0x80, 'g2': 0x82, 'mc': 0x89, 'txt': 0x90}[mode]
    regs = {'g1':  [0x00, r1, 0x0E, 0x80, 0x00, 0x76, 0x03, 0x01],
            'g2':  [0x02, r1, 0x0E, 0xFF, 0x03, 0x76, 0x03, 0x01],
            'mc':  [0x00, r1, 0x0E, 0x80, 0x00, 0x76, 0x03, 0x01],
            'txt': [0x00, r1, 0x0E, 0x80, 0x00, 0x76, 0x03, 0xF1]}[mode]

    a.org(0x0000)
    a.db(0xF3, 0xED, 0x56)                     # DI ; IM 1
    a.db(0x31); a.dw(0xC3F0)                   # LD SP,$C3F0
    a.db(0xC3); a.ref16('main')
    a.org(0x0038)
    a.db(0xC3); a.ref16('irq')                 # the handler is longer than the room before $0066
    a.org(0x0066)
    a.db(0xED, 0x45)                           # RETN
    a.org(0x0080)
    a.label('irq')
    a.db(0xF5, 0xC5, 0xE5)                     # PUSH AF ; PUSH BC ; PUSH HL
    a.db(0xDB, 0xBF)                           # IN A,($BF)   status: acknowledge, read the flags
    a.db(0x07, 0x07, 0x07, 0xE6, 0x03)         # RLCA x3 ; AND 3    bits 6-5
    a.db(0x87, 0x87, 0xC6, 0x01, 0xF6, 0xF0)   # x4 ; +1 ; OR $F0   (Text: white characters)
    a.db(0xD3, 0xBF, 0x3E, 0x87, 0xD3, 0xBF)   # -> R7
    a.db(0x21); a.dw(0xC000)                   # LD HL,$C000
    a.db(0x34)                                 # INC (HL)     frame counter
    if mode == 'txt':
        a.db(0x3E, NT & 0xFF, 0xD3, 0xBF, 0x3E, 0x40 | (NT >> 8), 0xD3, 0xBF)
        a.db(0x7E, 0xD3, 0xBE)                 # the counter as the first character
    else:
        a.db(0x7E, 0x87, 0x86, 0x47)           # LD A,(HL) ; ADD A,A ; ADD A,(HL) ; LD B,A   X = 3 x frame
        a.db(0x3E, (SAT + 5) & 0xFF, 0xD3, 0xBF, 0x3E, 0x40 | ((SAT + 5) >> 8), 0xD3, 0xBF)
        a.db(0x78, 0xD3, 0xBE)                 # sprite 1 X
    a.db(0xE1, 0xC1, 0xF1, 0xFB, 0xED, 0x4D)   # POP HL ; POP BC ; POP AF ; EI ; RETI
    assert a.pc <= 0x0100

    a.org(0x0100)
    a.label('main')
    a.db(0xAF, 0x32); a.dw(0xC000)             # frame counter = 0
    a.db(0x21); a.ref16('regs')
    a.db(0x06, 16, 0x0E, 0xBF, 0xED, 0xB3)     # registers (display off)
    a.db(0xAF, 0xD3, 0xBF, 0x3E, 0x40, 0xD3, 0xBF)
    a.db(0x01); a.dw(0x4000)                   # clear 16 KB of VRAM
    a.label('clr')
    a.db(0xAF, 0xD3, 0xBE, 0x0B, 0x78, 0xB1, 0x20); a.rel('clr')
    blocks = []

    def block(name, addr, data):
        blocks.append((name, addr, bytes(data)))
        a.db(0x21); a.ref16(name)              # LD HL,data
        a.db(0x11); a.dw(addr)                 # LD DE,vram
        a.db(0x01); a.dw(len(data))            # LD BC,length
        a.db(0xCD); a.ref16('copy')

    if mode == 'g1':
        block('pat', 0x0000, [_shape(n + (n >> 3), r) for n in range(256) for r in range(8)])
        block('col', CT, [(((i * 3 + 2) % 16) << 4) | ((i * 5) % 16) for i in range(32)])
        block('names', NT, [(row + col * 3) & 0xFF for row in range(24) for col in range(32)])
    elif mode == 'g2':
        block('pat', 0x0000, [_shape(n + t * 3, r) for t in range(3) for n in range(256) for r in range(8)])
        block('col', CT, [((((n >> 2) + r + t) % 16) << 4) | ((n + t * 5 + r * 3) % 16)
                          for t in range(3) for n in range(256) for r in range(8)])
        block('names', NT, [(row * 32 + col) & 0xFF for row in range(24) for col in range(32)])
    elif mode == 'mc':
        block('pat', 0x0000, [((n * 7 + r * 0x13) * 37 >> 2) & 0xFF for n in range(256) for r in range(8)])
        block('names', NT, [(row * 32 + col) & 0xFF for row in range(24) for col in range(32)])
    else:
        block('pat', 0x0000, [_shape(n, r) & 0xFC for n in range(256) for r in range(8)])
        block('names', NT, [(row * 3 + col) & 0xFF for row in range(24) for col in range(40)])
    if mode != 'txt':
        block('spat', SPG, [0xFF] * 32 + _ring16())
        sprites = [(79, 100, 0, 0x08), (83, 0, 0, 0x02),
                   (129, 20, 4, 0x04), (129, 60, 4, 0x06), (129, 100, 4, 0x0A), (129, 140, 4, 0x0C),
                   (129, 180, 4, 0x0D),
                   (0xFA, 200, 0, 0x0F), (40, 28, 0, 0x8B),
                   (59, 100, 0, 0x00), (59, 104, 4, 0x09)]
        block('sat', SAT, [v for spr in sprites for v in spr] + [0xD0])
    else:
        # Text mode has no sprites. An empty list all the same, because Gearsystem
        # (the reference) evaluates sprites in Text mode and would set the
        # overflow flag from 32 sprites at Y = 0.
        block('sat', SAT, [0xD0])
    # Clear the frame flag the loading left set, so the first interrupt is a real
    # one: the emulator raises the flag at the end of line 192 and the core at
    # cycle 27 of line 193 (the documented event-timing difference), and a status
    # read between the two would count an extra frame on the core.
    a.db(0xDB, 0xBF)                           # IN A,($BF)
    a.db(0x3E, r1 | 0x60, 0xD3, 0xBF, 0x3E, 0x81, 0xD3, 0xBF)   # display on, frame interrupt on
    a.db(0xFB)
    a.label('loop')
    a.db(0x18); a.rel('loop')

    a.label('copy')                            # HL = data, DE = VRAM address, BC = length
    a.db(0x7B, 0xD3, 0xBF, 0x7A, 0xF6, 0x40, 0xD3, 0xBF)
    a.label('cl')
    a.db(0x7E, 0xD3, 0xBE, 0x23, 0x0B, 0x78, 0xB1, 0x20); a.rel('cl')
    a.db(0xC9)
    a.label('regs')
    for i, v in enumerate(regs):
        a.db(v, 0x80 | i)
    for name, addr, data in blocks:
        a.label(name)
        a.db(*data)
    a.resolve()
    assert a.pc <= 0x8000
    return bytes(a.b)

if __name__ == '__main__':
    out = sys.argv[1]
    os.makedirs(out, exist_ok=True)
    for h in (192, 224, 240):
        open(os.path.join(out, f'vdp{h}.sms'), 'wb').write(build(h))
        print('wrote', f'vdp{h}.sms')
    open(os.path.join(out, 'save.sms'), 'wb').write(build_save())
    # a save file to load first: byte i = (i * 7) & $FF
    open(os.path.join(out, 'save_in.sav'), 'wb').write(bytes((i * 7) & 0xFF for i in range(0x8000)))
    print('wrote save.sms, save_in.sav')
    open(os.path.join(out, 'spr12.sms'), 'wb').write(build_sprites())
    print('wrote spr12.sms')
    open(os.path.join(out, 'tone.sms'), 'wb').write(build_tone())
    print('wrote tone.sms')
    open(os.path.join(out, 'fm.sms'), 'wb').write(build_fm())
    open(os.path.join(out, 'fm_tight.sms'), 'wb').write(build_fm(tight=True))
    print('wrote fm.sms, fm_tight.sms')
    open(os.path.join(out, 'ssfeat.sms'), 'wb').write(build_ss())
    print('wrote ssfeat.sms')
    open(os.path.join(out, 'ports.sms'), 'wb').write(build_ports())
    print('wrote ports.sms')
    for m in ('g1', 'g2', 'mc', 'txt'):
        open(os.path.join(out, f'tms_{m}.sg'), 'wb').write(build_tms(m))
        print(f'wrote tms_{m}.sg')
