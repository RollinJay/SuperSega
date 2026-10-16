#!/usr/bin/env python3
"""Build the small test ROMs in roms/ that the simulations and the emulator checks use.

usage: mk_testrom.py outdir

Writes vdp192.sms, vdp224.sms, vdp240.sms, save.sms with save_in.sav, spr12.sms,
tone.sms, fm.sms, fm_tight.sms, mdrfeat.sms, ports.sms, mdports.sms, mdrregs.sms, romwait.sms, tms_g2_224.sms, tms_g2_240.sms,
tms_txt_240.sms (the TMS9918 modes at 224 and 240 lines, build_tms_tall), mdrgfx.sms and mdrtext.sms (the MasterDrive
picture extensions, build_mdrgfx), gfxfuzz*.sms (random pictures, build_gfxfuzz), dma.sms (the DMA engine,
build_dma), pcm.sms (PCM and wavetable sound, build_pcm), and the SG-1000 ROMs tms_g1.sg, tms_g2.sg,
tms_mc.sg and tms_txt.sg for the four TMS9918 picture modes (build_tms). The VDP ROMs are described here; each of the
other builder functions below describes its ROM. Each VDP ROM sets Mode 4 with M2 set,
selects the height with M1 (224) or M3 (240) or neither (192), fills the whole
32x32 name table at $3700 (tall modes) / 32x28 at $3800 (192), places sprites
near the bottom of the screen, one at Y=$D0 (a terminator only in 192-line
mode) and one at Y=$F8 (wraps to the top), and scrolls both axes once per frame
from the frame interrupt. The pictures from the emulator, the RTL machine and
Gearsystem (192/224) are compared frame by frame.
"""
import math
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


# save.sms: (bank, address, key) of each 256-byte block it writes; the byte at
# address A is (A low byte) XOR $5A XOR key. Cartridge RAM is two 16 KB banks
# (Q3), so the blocks land at .sav offsets $0100, $2200, $4300 and $6400.
SAVE_BLOCKS = [(0, 0x8100, 0x00), (0, 0xA200, 0x11), (1, 0x8300, 0x22), (1, 0xA400, 0x33)]


def build_save():
    """Cartridge RAM test: map cart RAM ($FFFC = $08 for bank 0, $0C for bank 1)
    and write the SAVE_BLOCKS, leaving the rest of the RAM as loaded. The save
    slot read back over the bridge must show the loaded file with only those
    blocks replaced, each at bank x 16 KB + (address - $8000)."""
    a = Asm()
    a.org(0x0000)
    a.db(0xF3, 0xED, 0x56)                     # DI ; IM 1
    a.db(0x31); a.dw(0xDFF0)                   # LD SP,$DFF0
    for i, (bank, addr, key) in enumerate(SAVE_BLOCKS):
        a.db(0x3E, 0x08 | (bank << 2), 0x32); a.dw(0xFFFC)   # LD A,$08/$0C ; LD ($FFFC),A
        a.db(0x21); a.dw(addr)                 # LD HL,addr
        a.db(0x06, 0x00)                       # LD B,0 (256 passes)
        a.label(f'fill{i}')
        a.db(0x7D, 0xEE, 0x5A ^ key, 0x77, 0x23)   # LD A,L ; XOR ($5A ^ key) ; LD (HL),A ; INC HL
        a.db(0x10); a.rel(f'fill{i}')          # DJNZ
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
    """MasterDrive features: extended register banks (XRB), native 12-bit CRAM,
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
    rom[0x7FFF] = 0x8C                                       # region 8: MasterDrive
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
    return _ports_rom([], False, PORTS_READ)


# mdports.sms: the MasterDrive I/O gate (Q1) and machine ID (Q8). The first rows
# are read once, before Feature Enable A bit 7 is set; then the ROM sets it
# (R15 = $80), and if $17 reads $Ax (a MasterDrive) multiplies 200 x 100 in the
# math unit; then it reads the rest every frame. In MasterDrive mode the first rows read $FF and the $17 row after them
# $A7; in the other modes the gate never opens.
MDPORTS_FIRST = [0x01, 0x06, 0x09, 0x0F, 0x16, 0x17]
MDPORTS_EVERY = [0x00, 0x01, 0x06, 0x09, 0x0E, 0x0F, 0x10, 0x16, 0x17, 0x18, 0xDC]


def build_mdports():
    """The MasterDrive I/O gate and machine ID check (MDPORTS_FIRST, MDPORTS_EVERY)."""
    return _ports_rom(MDPORTS_FIRST, True, MDPORTS_EVERY)


# mdrregs.sms: the MasterDrive registers decided in Q7, Q9 and Q14. Region 8, so
# it starts in MasterDrive mode; it opens the I/O gate, then each row writes its
# ports and reads one: (writes, port read). Expected values in the comments.
MDRREGS_ROWS = [
    ([(0x0C, 200), (0x0D, 100), (0x0E, 0)], 0x0F),   # 200 x 100 = $4E20: $20
    ([], 0x10),                                       # $4E
    ([(0x0C, 200), (0x0D, 7), (0x0E, 1)], 0x0F),     # 200 / 7: quotient 28 ($1C)
    ([], 0x10),                                       # remainder 4
    ([(0x0C, 255), (0x0D, 16), (0x0E, 1)], 0x0F),    # 255 / 16: $0F
    ([], 0x10),                                       # $0F
    ([(0x0C, 5), (0x0D, 9), (0x0E, 1)], 0x0F),       # 5 / 9: 0
    ([], 0x10),                                       # 5
    ([(0x0C, 200), (0x0D, 0), (0x0E, 1)], 0x0F),     # divide by zero: $FF
    ([], 0x10),                                       # $00
    ([(0x0C, 255), (0x0D, 255), (0x0E, 0)], 0x0F),   # 255 x 255 = $FE01: $01
    ([], 0x10),                                       # $FE
    ([(0x0A, 0x0B)], 0x0A),                           # work RAM bank 11: $0B (bank 0 restored at once)
    ([(0x0A, 0xFF)], 0x0A),                           # bank 15: $0F
    ([], 0x08),                                       # PCM FIFO empty: $00
    ([], 0x0E),                                       # $00
    ([], 0x17),                                       # machine ID: $A7
]


def build_mdrregs():
    """The MasterDrive register check (MDRREGS_ROWS), in the ports.sms layout."""
    return _ports_rom([], True, [], rows=MDRREGS_ROWS, region=0x8C)


# romwait.sms: the cartridge wait state at 200 % (Q12). Region 8; Feature Enable A
# bit 6 lets it set the turbo step. Each case sets the step, waits for the start
# of line $21, runs ROMWAIT_NOPS NOPs (in ROM, or the same block copied to work
# RAM at $C200) and reads the V counter. Row label: high nibble 0 ROM, 1 RAM; low
# nibble the $F3 step (4 = 200 %, 3 = 175 %). At 200 % a NOP in ROM takes 5
# T-states and in RAM 4, so the ROM rows end about four lines later; at 175 % no
# wait applies and the two rows read the same.
ROMWAIT_NOPS = 2000
ROMWAIT_CASES = [(4, 'rom'), (4, 'ram'), (3, 'rom'), (3, 'ram')]


def build_romwait():
    """The cartridge wait state check (ROMWAIT_CASES), in the ports.sms layout."""
    def run(a):
        for i, (step, where) in enumerate(ROMWAIT_CASES):
            a.db(0x3E, step, 0xD3, 0xF3)                   # LD A,step ; OUT ($F3),A
            a.label(f'ws{i}a'); a.db(0xDB, 0x7E, 0xFE, 0x20, 0x20); a.rel(f'ws{i}a')   # wait for line $20
            a.label(f'ws{i}b'); a.db(0xDB, 0x7E, 0xFE, 0x20, 0x28); a.rel(f'ws{i}b')   # ...then for line $21
            if where == 'rom':
                a.db(0xCD); a.ref16('nops')                # CALL nops
            else:
                a.db(0xCD); a.dw(0xC200)                   # CALL $C200
            a.db(0xDB, 0x7E, 0x32); a.dw(0xC100 + i)       # IN A,($7E) ; LD ($C100+i),A
        a.db(0xAF, 0xD3, 0xF3)                             # back to 100 % for drawing
    def init(a):
        a.db(0x3E, 0xC0, 0xD3, 0xBF, 0x3E, 0x8F, 0xD3, 0xBF)   # R15 = $C0: turbo writes, I/O registers
        a.db(0x21); a.ref16('nops'); a.db(0x11); a.dw(0xC200); a.db(0x01); a.dw(ROMWAIT_NOPS + 1)
        a.db(0xED, 0xB0)                                   # LDIR: the block to work RAM
    def tail(a):
        a.label('nops'); a.db(*([0x00] * ROMWAIT_NOPS)); a.db(0xC9)
    labels = [(0x10 if w == 'ram' else 0x00) | s for s, w in ROMWAIT_CASES]
    return _ports_rom([], False, [], region=0x8C, custom=(init, run, tail, labels))


def _ports_rom(first, gate, every, rows=None, region=0x4C, custom=None):
    """The ports.sms layout: the ports in first read once at start, the gate
    opened (R15 = $80, then 200 x 100 in the math unit on a MasterDrive) if
    gate, then the ports in every read each frame; all drawn one row each from
    row 3. With rows, each frame runs those (writes, port) rows instead; a row
    that reads $0A puts bank 0 back before anything touches work RAM."""
    rows = rows or []
    allp = list(first) + list(every) + [r[1] for r in rows] + (list(custom[3]) if custom else [])
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
    if first:                                              # read once, before the gate opens
        a.db(0x21); a.ref16('ports'); a.db(0x11); a.dw(0xC100); a.db(0x06, len(first))
        a.label('rd1'); a.db(0x4E, 0xED, 0x78, 0x12, 0x23, 0x13, 0x10); a.rel('rd1')
    if gate:                                               # R15 = $80: Feature Enable A bit 7
        a.db(0x3E, 0x80, 0xD3, 0xBF, 0x3E, 0x8F, 0xD3, 0xBF)
        # detection (Technical Reference §14): only a MasterDrive answers $Ax at $17;
        # on the other machines $0C-$0E are the $3E/$3F mirrors and must not be written
        a.db(0xDB, 0x17, 0xE6, 0xF0, 0xFE, 0xA0, 0x20); a.rel('nomd')   # IN A,($17) ; AND $F0 ; CP $A0 ; JR NZ
        a.db(0x3E, 200, 0xD3, 0x0C, 0x3E, 100, 0xD3, 0x0D, 0xAF, 0xD3, 0x0E)   # 200 x 100 = $4E20
        a.label('nomd')
    if custom:
        custom[0](a)                                       # once, before the loop
    a.label('loop')
    if custom:
        custom[1](a)                                       # each pass: store the row values at $C100+i
    elif rows:                                               # each row: its writes, then IN A,(port) -> $C100+i
        for i, (outs, port) in enumerate(rows):
            for q, v in outs:
                a.db(0x3E, v, 0xD3, q)                     # LD A,v ; OUT (q),A
            a.db(0xDB, port)                               # IN A,(port)
            if any(q == 0x0A for q, _ in outs):
                a.db(0x47, 0xAF, 0xD3, 0x0A, 0x78)         # LD B,A ; XOR A ; OUT ($0A),A ; LD A,B
            a.db(0x32); a.dw(0xC100 + i)                   # LD ($C100+i),A
    else:
        # read every port into $C100...
        a.db(0x21); a.ref16('ports' if not first else 'every'); a.db(0x11); a.dw(0xC100 + len(first)); a.db(0x06, len(every))
        a.label('rd'); a.db(0x4E, 0xED, 0x78, 0x12, 0x23, 0x13, 0x10); a.rel('rd')   # LD C,(HL) ; IN A,(C) ; LD (DE),A ; INC HL ; INC DE ; DJNZ
    # ...then draw them, one row each from row 3
    a.db(0x21); a.dw(0x3800 + 3 * 64 + 6 * 2); a.db(0x22); a.dw(0xC200)   # row address
    a.db(0x21); a.ref16('ports'); a.db(0x22); a.dw(0xC204)
    a.db(0x21); a.dw(0xC100); a.db(0x22); a.dw(0xC206)
    a.db(0x3E, len(allp), 0x32); a.dw(0xC202)
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
    a.db(*first)
    if first:
        a.label('every')
    a.db(*every)
    a.db(*[r[1] for r in rows])
    if custom:
        a.db(*custom[3])
        custom[2](a)
    a.resolve()
    rom = a.b
    rom[0x7FF0:0x7FFA] = b'TMR SEGA' + b'\x00\x00'
    cs = sum(rom[0:0x7FF0]) & 0xFFFF
    rom[0x7FFA] = cs & 0xFF; rom[0x7FFB] = cs >> 8
    rom[0x7FFF] = region
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

def build_tms_tall(height, mode='g2'):
    """The TMS9918 modes at 224 or 240 lines (Q17), for MasterDrive software: a
    region-8 ROM, so it starts in MasterDrive mode, that sets Feature Enable B's
    height (R15 = $20, then bank 1 R2) before the stock registers. Graphics II
    ('g2'): patterns $0000-$1FFF and colours $2000-$3FFF in four full banks,
    names $1C00 with rows 24-29 drawn from the fourth bank (names 0-127), sprite
    attributes $3F80, sprite patterns from $3800 (numbers 128 and up). Sprites:
    one at Y = $D0 (a terminator only at 192 lines), two overlapping below line
    192 (collision), five on one line below it (overflow), one at Y = $E3
    (starts on line 228 by Mode 4's wrap rule) and one at Y = $FA (wraps to the
    top). Line interrupts on (R0 bit 4, R10 = 15): the handler ORs every status
    read into RAM and counts line interrupts; each frame it shows the saved
    status flags as the backdrop colour and writes the count into name cell 0.
    Text ('txt'): 40 x 30 cells, the name table running past R2's 1 KB. The
    same ROM in SG-1000 mode stays at 192 lines."""
    a = Asm()
    NT, SAT, SPG = 0x1C00, 0x3F80, 0x3800
    feb = {192: 0x00, 224: 0x40, 240: 0x80}[height]
    r1 = {'g2': 0x82, 'txt': 0x90}[mode]
    if mode == 'g2':
        regs = [0x12, r1, NT >> 10, 0xFF, 0x03, SAT >> 7, SPG >> 11, 0x01, 0, 0, 15]
    else:
        NT = 0x3800
        regs = [0x10, r1, NT >> 10, 0x80, 0x00, 0x76, 0x03, 0xF1, 0, 0, 15]
    rows = height // 8
    a.org(0); a.db(0xF3, 0xED, 0x56, 0x31); a.dw(0xC3F0); a.db(0xC3); a.ref16('main')
    a.org(0x38); a.db(0xC3); a.ref16('irq')
    a.org(0x66); a.db(0xED, 0x45)
    a.org(0x80); a.label('irq')
    a.db(0xF5, 0xC5, 0xE5)
    a.db(0xDB, 0xBF)                       # IN A,($BF)
    a.db(0x47, 0x21); a.dw(0xC002); a.db(0xB6, 0x77, 0x78)   # LD B,A ; LD HL,$C002 ; OR (HL) ; LD (HL),A ; LD A,B
    a.db(0x07); a.db(0x38); a.rel('frame') # RLCA ; JR C,frame (bit 7)
    a.db(0x21); a.dw(0xC001); a.db(0x34)   # line IRQ: INC ($C001)
    a.db(0x18); a.rel('out')
    a.label('frame')
    a.db(0x3A); a.dw(0xC002); a.db(0x07)    # LD A,($C002) (flags since the last frame) ; RLCA
    a.db(0x07, 0x07, 0xE6, 0x03, 0x87, 0x87, 0xC6, 0x01, 0xF6, 0xF0)
    a.db(0xD3, 0xBF, 0x3E, 0x87, 0xD3, 0xBF)
    # write the line-IRQ count into name cell 0 and clear it
    a.db(0x3E, NT & 0xFF, 0xD3, 0xBF, 0x3E, 0x40 | (NT >> 8), 0xD3, 0xBF)
    a.db(0x3A); a.dw(0xC001); a.db(0xD3, 0xBE)
    a.db(0xAF, 0x32); a.dw(0xC001); a.db(0x32); a.dw(0xC002)
    a.label('out')
    a.db(0xE1, 0xC1, 0xF1, 0xFB, 0xED, 0x4D)
    a.org(0x100); a.label('main')
    a.db(0xAF, 0x32); a.dw(0xC001)
    # R15 = $20 (XRB), bank 1 R2 = FEB height, before the stock registers
    a.db(0x3E, 0x20, 0xD3, 0xBF, 0x3E, 0x8F, 0xD3, 0xBF)
    a.db(0x3E, feb, 0xD3, 0xBF, 0x3E, 0x92, 0xD3, 0xBF)
    a.db(0x21); a.ref16('regs'); a.db(0x06, 2 * len(regs), 0x0E, 0xBF, 0xED, 0xB3)
    a.db(0xAF, 0xD3, 0xBF, 0x3E, 0x40, 0xD3, 0xBF)
    a.db(0x01); a.dw(0x4000)
    a.label('clr'); a.db(0xAF, 0xD3, 0xBE, 0x0B, 0x78, 0xB1, 0x20); a.rel('clr')
    blocks = []
    def block(name, addr, data):
        blocks.append((name, addr, bytes(data)))
        a.db(0x21); a.ref16(name); a.db(0x11); a.dw(addr); a.db(0x01); a.dw(len(data)); a.db(0xCD); a.ref16('copy')
    if mode == 'g2':
        block('pat', 0x0000, [_shape(n + t * 3, r) for t in range(3) for n in range(256) for r in range(8)]
              + [_shape(n * 5 + 1, r) ^ 0x0F for n in range(128) for r in range(8)])
        block('col', 0x2000, [((((n >> 2) + r + t) % 16) << 4) | ((n + t * 5 + r * 3) % 16)
                              for t in range(3) for n in range(256) for r in range(8)]
              + [((((n >> 1) + r) % 15 + 1) << 4) | ((n * 3 + r) % 16) for n in range(128) for r in range(8)])
        block('names', NT, [(row * 32 + col) & 0xFF if row < 24 else ((row - 24) * 32 + col) & 0x7F
                            for row in range(rows) for col in range(32)])
        block('spat', SPG + 128 * 8, [0xFF] * 32 + _ring16())
        sprites = [(0xD0, 30, 128, 0x0F),       # Y=$D0: line 209 (a terminator only at 192)
                   (199, 100, 132, 0x08), (203, 104, 128, 0x02),   # overlap below 192
                   (219, 20, 128, 0x04), (219, 60, 128, 0x06), (219, 100, 128, 0x0A), (219, 140, 128, 0x0C), (219, 180, 128, 0x0D),
                   (0xE3, 220, 128, 0x0B),      # start 228 (Mode 4 rule) or wraps (225 rule)
                   (0xFA, 240 - 16, 128, 0x09),
                   (99, 50, 132, 0x07)]
        block('sat', SAT, [v for s in sprites for v in s] + [0xE0] * (4 * (32 - len(sprites))))
    else:
        block('pat', 0x0000, [_shape(n, r) & 0xFC for n in range(256) for r in range(8)])
        block('names', NT, [(row * 3 + col) & 0xFF for row in range(rows) for col in range(40)])
    a.db(0xDB, 0xBF)
    a.db(0x3E, r1 | 0x60, 0xD3, 0xBF, 0x3E, 0x81, 0xD3, 0xBF)
    a.db(0xFB); a.label('loop'); a.db(0x18); a.rel('loop')
    a.label('copy')
    a.db(0x7B, 0xD3, 0xBF, 0x7A, 0xF6, 0x40, 0xD3, 0xBF)
    a.label('cl'); a.db(0x7E, 0xD3, 0xBE, 0x23, 0x0B, 0x78, 0xB1, 0x20); a.rel('cl'); a.db(0xC9)
    a.label('regs')
    for i, v in enumerate(regs): a.db(v, 0x80 | i)
    for name, addr, data in blocks:
        a.label(name); a.db(*data)
    a.resolve()
    rom = a.b
    assert a.pc <= 0x7FF0, hex(a.pc)
    rom[0x7FF0:0x7FFA] = b'TMR SEGA' + b'\x00\x00'
    cs = sum(rom[0:0x7FF0]) & 0xFFFF
    rom[0x7FFA] = cs & 0xFF; rom[0x7FFB] = cs >> 8
    rom[0x7FFF] = 0x8C
    return bytes(rom)



_F_GLYPH = [0xFE, 0xC0, 0xC0, 0xFC, 0xC0, 0xC0, 0xC1, 0x03]     # an F with a dot: shows both flips


def _spr_tile(t, r):
    """Sprite tile t, row r, as four bit planes: an F in colour (t % 15) + 1 and
    a diagonal in its complement, so flips and colours both show."""
    c1 = (t % 15) + 1
    c2 = 15 - (t % 15)
    f = _F_GLYPH[r]
    d = (0x80 >> r) & ~f & 0xFF
    return [(f if (c1 >> k) & 1 else 0) | (d if (c2 >> k) & 1 else 0) for k in range(4)]


def _bg_tile(t, r):
    """Background tile t, row r: one of the eight shapes in colour (t % 7) + 1;
    the rest, and always the left two columns, colour 0, so sprite priority can
    be seen against both."""
    c = (t % 7) + 1
    sh = _shape(t, r) & 0x3F
    return [sh if (c >> k) & 1 else 0 for k in range(4)]


def build_mdrgfx(variant):
    """MasterDrive picture extensions (Technical Reference sections 3 and 5),
    for comparing the core's renderer with the emulator's. Both variants start
    in MasterDrive mode (region 8), write everything with the display off, then
    turn it on and loop.

    'a' (mdrgfx.sms), 192 lines: the ESAT (both flips, 16x16, magnify, 16x16
    magnified, early clock, an ESAT palette with extended CRAM, an unwritten
    palette that shows as palette 1, priority behind the background), the line
    scroll and vertical-offset tables with R0's top-row and right-column locks,
    a tile window above row 5 from x = 176 with sprites over it, unique-cell
    tiles 512-519 from the upper 16 KB of VRAM, extended palettes and the
    priority bit in the name table, and a magnified sprite cut by the left edge.

    'b' (mdrtext.sms), 224 lines: the text window from row 20 down and from
    x = 16, every sprite 16x16 (Feature Enable B bit 2) and magnified by R1
    bit 0, one also by its ESAT (four times in all), sprites over the text
    window, one with ESAT priority (text pixels are never opaque), and the
    renderer's worst line: 16 sprites of 64 x 64 pixels side by side."""
    a = Asm()
    tall = variant == 'b'
    a.org(0x0000)
    a.db(0xF3, 0xED, 0x56, 0x31); a.dw(0xDFF0)
    a.db(0xC3); a.ref16('main')
    a.org(0x0038)
    a.db(0xF5, 0xDB, 0xBF, 0xF1, 0xFB, 0xED, 0x4D)
    a.org(0x0066)
    a.db(0xED, 0x45)
    a.org(0x0100)
    a.label('main')
    a.db(0x21); a.ref16('regs'); a.db(0x06, 0, 0x0E, 0xBF)      # B patched below
    regs_len_at = a.pc - 3
    a.db(0xED, 0xB3)
    blocks = []

    def block(name, addr, data, cram=False):
        blocks.append((name, bytes(data)))
        a.db(0x21); a.ref16(name); a.db(0x11); a.dw(addr | (0xC000 if cram else 0x4000))
        a.db(0x01); a.dw(len(data)); a.db(0xCD); a.ref16('copy')

    # CRAM, native (two bytes per entry): palettes 0-8; 9-15 stay unwritten
    pal = []
    for p in range(9):
        for c in range(16):
            r, g, b = (c + p * 5) & 15, (c * 3 + p * 7) & 15, (15 - c + p * 3) & 15
            pal += [(g << 4) | r, b]
    block('cram', 0x0000, pal, cram=True)
    # background tiles 0-127
    block('bgt', 0x0000, [v for t in range(128) for r in range(8) for v in _bg_tile(t, r)])
    # sprite tiles 0-63 at $2000
    block('spt', 0x2000, [v for t in range(64) for r in range(8) for v in _spr_tile(t, r)])
    if not tall:
        # line scroll table $1800, vertical-offset table $1900
        block('lineh', 0x1800, [(6 * (y % 24) // 12 if y % 24 < 12 else 6 * (24 - y % 24) // 12) & 0xFF
                                for y in range(256)])                 # a triangle wave of 6 pixels
        block('linev', 0x1900, [4 if 96 <= y < 128 else 0 for y in range(256)])
        # window tilemap $1000: 32 x 32
        block('wmap', 0x1000, [v for rr in range(32) for c in range(32)
                               for v in (((rr * 3 + c) % 128), 0x20 | (0x10 if c % 4 == 0 else 0))])
        # name table $3800: 32 x 28
        nt = []
        for rr in range(28):
            for c in range(32):
                lo = (rr * 5 + c) % 128
                hi = (0x02 if c % 5 == 1 else 0) | (0x04 if rr % 3 == 1 else 0)
                hi |= ((rr & 1) << 3) | (((c >> 2) & 3) << 5)
                if 9 <= rr <= 11 and c < 8:
                    hi |= 0x10                                   # priority over sprites
                if rr == 12 and c < 8:
                    lo, hi = c, 0x80 | (hi & 0x0E)               # unique-cell tiles 512-519
                nt += [lo, hi]
        block('nt', 0x3800, nt)
        # sprites: (Y, X, tile, ESAT byte 0, ESAT byte 1)
        spr = [(20, 16, 1, 0x00, 0), (20, 40, 2, 0x02, 0), (20, 64, 3, 0x01, 0), (20, 88, 4, 0x08, 0),
               (20, 120, 6, 0x10, 0), (20, 140, 8, 0x18, 0), (20, 20, 10, 0x20, 0), (20, 200, 11, 0x00, 5),
               (20, 224, 12, 0x00, 9), (72, 4, 13, 0x04, 0), (72, 30, 14, 0x00, 0), (120, 3, 15, 0x30, 0),
               (150, 100, 16, 0x08, 2), (154, 108, 18, 0x00, 3), (0xD0, 0, 0, 0, 0)]
    else:
        # text font $2800: 256 characters
        block('font', 0x2800, [_shape(ch, r) ^ ((ch << 2) & 0xFC) if r == 7 else _shape(ch, r)
                               for ch in range(256) for r in range(8)])
        # text window name table $1000: 40 bytes a row, from the window's top edge
        block('tmap', 0x1000, [(rr * 40 + c) & 0xFF for rr in range(8) for c in range(40)])
        # name table $3700: 32 x 32 (224 lines)
        block('nt', 0x3700, [v for rr in range(32) for c in range(32)
                             for v in (((rr * 7 + c) % 128), ((rr & 1) << 3) | (0x02 if c % 3 == 0 else 0))])
        spr = [(30, 20, 20, 0x00, 0), (40, 60, 24, 0x10, 0), (100, 10, 28, 0x20, 0),
               (150, 150, 32, 0x00, 0), (170, 200, 36, 0x04, 0), (0xF0, 120, 40, 0x00, 0)]
        # the renderer's worst line: 16 sprites of 64 x 64 pixels on lines 81-144
        spr += [(80, 8 + 15 * k, 4 * (k % 8), 0x10 | (0x02 if k & 1 else 0), 0) for k in range(16)]
    sat = [s[0] for s in spr] + [0xE0 if tall else 0xD0] * (64 - len(spr))
    block('saty', 0x3F00, sat)
    block('satxt', 0x3F80, [v for s in spr for v in (s[1], s[2])])
    block('esat', 0x1A00, [v for s in spr for v in (s[3], s[4])])
    if not tall:
        # unique-cell tiles 512-519 in the upper 16 KB: bank 1 R3 = 1 for the CPU, then 0
        a.db(0x3E, 0x01, 0xD3, 0xBF, 0x3E, 0x93, 0xD3, 0xBF)
        block('uct', 0x0000, [v for t in range(8) for r in range(8)
                              for v in [0xFF if (r + t) & 1 else 0x0F, 0xF0, 0x3C if t & 1 else 0xC3, 0xFF]])
        a.db(0x3E, 0x00, 0xD3, 0xBF, 0x3E, 0x93, 0xD3, 0xBF)
    # Feature Enable A last, then the display on
    a.db(0x3E, 0x3D if tall else 0x3F, 0xD3, 0xBF, 0x3E, 0x8F, 0xD3, 0xBF)
    a.db(0x3E, 0x41 if tall else 0x40, 0xD3, 0xBF, 0x3E, 0x81, 0xD3, 0xBF)
    a.label('loop'); a.db(0x18); a.rel('loop')
    a.label('copy')                                         # HL -> port $BE, DE = address, BC = count
    a.db(0x7B, 0xD3, 0xBF, 0x7A, 0xD3, 0xBF)
    a.label('cl'); a.db(0x7E, 0xD3, 0xBE, 0x23, 0x0B, 0x78, 0xB1, 0x20); a.rel('cl'); a.db(0xC9)
    a.label('regs')
    # R15 = $21 first (XRB, native CRAM) so bank 1 and the CRAM writes take effect
    stock = [0xC6, 0x00, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x03, 0x00, 0x10, 0xFF] if not tall else \
            [0x06, 0x00, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x03, 0x00, 0x00, 0xFF]
    regs = [(0x21, 0x8F)] + [(v, 0x80 | i) for i, v in enumerate(stock)]
    if not tall:
        regs += [(0x18, 0x8B), (0x1A, 0x8C), (22, 0x8D), (0x85, 0x8E),
                 (0x10, 0x90), (0x19, 0x91), (0x13, 0x92), (0x00, 0x93), (0x08, 0x97)]
    else:
        regs += [(0x00, 0x8B), (0x1A, 0x8C), (2, 0x8D), (20, 0x8E),
                 (0x10, 0x90), (0x44, 0x92), (0x04, 0x97), (0x28, 0x98), (0x5A, 0x99)]
    for v, r in regs:
        a.db(v, r)
    a.b[regs_len_at] = 2 * len(regs)
    for name, data in blocks:
        a.label(name); a.db(*data)
    a.resolve()
    rom = a.b
    assert a.pc <= 0x7FF0, hex(a.pc)
    rom[0x7FF0:0x7FFA] = b'TMR SEGA' + b'\x00\x00'
    cs = sum(rom[0:0x7FF0]) & 0xFFFF
    rom[0x7FFA] = cs & 0xFF; rom[0x7FFB] = cs >> 8
    rom[0x7FFF] = 0x8C
    return bytes(rom)


class _Rng:
    """xorshift32, so the fuzz ROMs do not depend on Python's random module."""
    def __init__(self, seed):
        self.s = (seed * 2654435761 + 1) & 0xFFFFFFFF or 1

    def bits(self, n):
        x = self.s
        x ^= (x << 13) & 0xFFFFFFFF; x ^= x >> 17; x ^= (x << 5) & 0xFFFFFFFF
        self.s = x
        return x >> (32 - n)

    def below(self, n):
        return self.bits(16) % n


GFXFUZZ_SEEDS = (1, 6, 25, 38)    # between them: both windows, the ESAT, unique-cell tiles, both line tables, 16x16 sprites, 192/224/240 lines


def build_gfxfuzz(seed):
    """A random MasterDrive picture for comparing the core's renderer with the
    emulator's: every Mode 4 and MasterDrive video register from a seeded
    generator (R0 bits 1 and 3-7, R1 bits 0-1 and 3-4, R2-R10, bank 0 R11-R14,
    bank 1 R0, R1, R4-R6, R8, R9, Feature Enable A bits 1-4, B and C), all
    32 KB of VRAM and part of CRAM from a xorshift generator running on the
    Z80, and 64 sprite Y values, a few of them $D0. It writes at 200 % turbo
    with the display off (about 35 frames), then turns the display on; compare
    frames 70 on."""
    r = _Rng(seed)
    a = Asm()
    a.org(0)
    a.db(0xF3, 0xED, 0x56, 0x31); a.dw(0xDFF0); a.db(0xC3); a.ref16('main')
    a.org(0x38); a.db(0xF5, 0xDB, 0xBF, 0xF1, 0xFB, 0xED, 0x4D)
    a.org(0x66); a.db(0xED, 0x45)
    a.org(0x100); a.label('main')
    r0 = 0x04 | (2 * r.bits(1)) | (r.bits(1) << 3) | (r.bits(1) << 5) | (r.bits(2) << 6)
    r1 = (r.bits(2) << 3) | r.bits(2)
    stock = [r0, r1] + [r.bits(8) for _ in range(9)]
    regs = [(0x61, 0x8F)] + [(v, 0x80 | i) for i, v in enumerate(stock)]
    regs += [(r.bits(8), 0x8B + k) for k in range(4)]
    regs += [(r.bits(8), 0x90 | n) for n in (0, 1, 4, 5, 6, 8, 9)]
    regs += [(r.bits(8) | 0x10, 0x92), (r.bits(5), 0x97)]   # VRAM expansion while filling; no keyboard bit
    a.db(0x21); a.ref16('regs'); a.db(0x06, 2 * len(regs), 0x0E, 0xBF, 0xED, 0xB3)
    a.db(0x3E, 0x04, 0xD3, 0xF3)                            # 200 %
    a.db(0x21); a.dw(r.bits(16) | 1)                        # the Z80 generator's state
    for bank in (0, 1):
        a.db(0x3E, bank, 0xD3, 0xBF, 0x3E, 0x93, 0xD3, 0xBF)  # bank 1 R3: the CPU's VRAM bank
        a.db(0xAF, 0xD3, 0xBF, 0x3E, 0x40, 0xD3, 0xBF)
        a.db(0x01); a.dw(0x4000)
        a.label(f'v{bank}'); a.db(0xCD); a.ref16('rnd'); a.db(0xD3, 0xBE, 0x0B, 0x78, 0xB1, 0x20); a.rel(f'v{bank}')
    a.db(0x3E, 0x00, 0xD3, 0xBF, 0x3E, 0x93, 0xD3, 0xBF)
    a.db(0x3E, 0x00, 0xD3, 0xBF, 0x3E, 0x40 | ((stock[5] >> 1) & 0x3F), 0xD3, 0xBF)   # sprite Y at R5's table
    a.db(0x21); a.ref16('saty'); a.db(0x06, 64, 0x0E, 0xBE, 0xED, 0xB3)
    a.db(0x3E, 0x00, 0xD3, 0xBF, 0x3E, 0xC0, 0xD3, 0xBF)
    a.db(0x01); a.dw(32 * (1 + r.below(16)))                # CRAM bytes written: some palettes stay unwritten
    a.label('cr'); a.db(0xCD); a.ref16('rnd'); a.db(0xD3, 0xBE, 0x0B, 0x78, 0xB1, 0x20); a.rel('cr')
    a.db(0x3E, r.bits(8), 0xD3, 0xBF, 0x3E, 0x92, 0xD3, 0xBF)               # Feature Enable B
    a.db(0x3E, (r.bits(5) & 0x1E) | 0x21, 0xD3, 0xBF, 0x3E, 0x8F, 0xD3, 0xBF)   # Feature Enable A
    a.db(0x3E, r1 | 0x40, 0xD3, 0xBF, 0x3E, 0x81, 0xD3, 0xBF)
    a.label('loop'); a.db(0x18); a.rel('loop')
    a.label('rnd')                                          # xorshift16 (7, 9, 8): HL, A = H
    a.db(0x7C, 0x1F, 0x7D, 0x1F, 0xAC, 0x67, 0x7D, 0x1F, 0x7C, 0x1F, 0xAD, 0x6F, 0xAC, 0x67, 0xC9)
    a.label('regs')
    for v, rr in regs:
        a.db(v, rr)
    a.label('saty')
    a.db(*[0xD0 if r.below(32) == 0 else r.bits(8) for _ in range(64)])
    a.resolve()
    rom = a.b
    rom[0x7FF0:0x7FFA] = b'TMR SEGA' + b'\x00\x00'
    cs = sum(rom[0:0x7FF0]) & 0xFFFF
    rom[0x7FFA] = cs & 0xFF; rom[0x7FFB] = cs >> 8
    rom[0x7FFF] = 0x8C
    return bytes(rom)

def build_dma():
    """The DMA engine (Technical Reference section 9), drawn so the core and the
    emulator can be compared. In MasterDrive mode, with the display off, the
    ROM fills the name table (mode 2), copies 64 tiles from ROM (mode 0, source
    0) and three palettes into CRAM (mode 0 to CRAM, extended CRAM), copies 256
    bytes from work RAM bank 3 (source 2), copies 16 tiles VRAM to VRAM (mode
    1), copies from the card slot with no card in it ($FF, source 1), and fills
    $3FE0-$401F, which runs on into the upper 16 KB, where unique-cell tile 512
    shows it. Then it writes rows of names that show each result and turns the
    display on: rows 0-7 the ROM tiles, row 9 the work RAM tiles, row 11 the
    copied tiles, row 13 the card's, row 15 tile 512, the rest the filled name
    (tile 2, flipped)."""
    a = Asm()
    a.org(0x0000)
    a.db(0xF3, 0xED, 0x56, 0x31); a.dw(0xDFF0); a.db(0xC3); a.ref16('main')
    a.org(0x0038); a.db(0xF5, 0xDB, 0xBF, 0xF1, 0xFB, 0xED, 0x4D)
    a.org(0x0066); a.db(0xED, 0x45)
    a.org(0x0100); a.label('main')
    regs = [(0xA1, 0x8F)]                                       # I/O gate, XRB, native CRAM
    regs += [(v, 0x80 | i) for i, v in enumerate([0x06, 0x00, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x00, 0x00, 0x00, 0xFF])]
    regs += [(0x12, 0x92), (0x00, 0x93), (0x08, 0x97)]          # extended CRAM, VRAM expansion; unique-cell
    a.db(0x21); a.ref16('regs'); a.db(0x06, 2 * len(regs), 0x0E, 0xBF, 0xED, 0xB3)
    # work RAM bank 3: 256 bytes, then back to bank 0
    a.db(0x3E, 0x03, 0xD3, 0x0A)
    a.db(0x21); a.dw(0xC000); a.db(0x06, 0x00)
    a.label('wr'); a.db(0x78, 0x2F, 0xE6, 0x7F, 0x77, 0x23, 0x10); a.rel('wr')   # (HL) = ~B & $7F
    jobs = []

    def dma(src, ctl, dst, length):
        lab = f'job{len(jobs)}'
        jobs.append((lab, [src & 0xFF, src >> 8, ctl, dst & 0xFF, dst >> 8, length & 0xFF, 0x80 | (length >> 8)]))
        a.db(0x21); a.ref16(lab); a.db(0xCD); a.ref16('dmago')

    dma(0x0202, 0x08, 0x3800, 32 * 28 * 2)        # fill the name table with name $0202
    dma(0, 0x00, 0x0000, 64 * 32); a.label('rom_src_fix')
    dma(0, 0x00, 0x4000 | 0x0000, 96)             # palettes 0-2 to CRAM (bit 6 of the high byte)
    dma(0, 0x00, 0x4000 | 0x00A0, 32)             # palette 5
    dma(0x0000, 0x02, 0x0800, 256)                # work RAM bank 3 -> tiles 64-71
    dma(0x0000, 0x04, 0x1000, 512)                # VRAM $0000 -> $1000: tiles 128-143
    dma(0x2000, 0x01, 0x0C00, 256)                # the card (none: $FF) -> tiles 96-103
    dma(0x005A, 0x08, 0x3FE0, 0x40)               # fill $3FE0-$401F with $5A: into the upper 16 KB
    a.db(0x3E, 0x00, 0xD3, 0x0A)
    # sprites off; names for the result rows
    a.db(0x3E, 0x00, 0xD3, 0xBF, 0x3E, 0x7F, 0xD3, 0xBF, 0x3E, 0xD0, 0xD3, 0xBE)
    rows = {}
    for r in range(8):
        rows[r] = [(r * 8 + c % 8, 0x08 * (c // 16) | (0x20 if c % 16 >= 8 else 0)) for c in range(32)]
    rows[9] = [(64 + c % 8, 0x48) for c in range(32)]          # palette 5
    rows[11] = [(128 + c % 16, 0x20) for c in range(32)]       # palette 2
    rows[13] = [(96 + c % 8, 0x08) for c in range(32)]
    rows[15] = [(0, 0x80) for c in range(32)]                  # tile 512
    for r, ents in rows.items():
        addr = 0x3800 + r * 64
        a.db(0x3E, addr & 0xFF, 0xD3, 0xBF, 0x3E, 0x40 | (addr >> 8), 0xD3, 0xBF)
        a.db(0x21); a.ref16(f'row{r}'); a.db(0x06, 64, 0x0E, 0xBE, 0xED, 0xB3)
    a.db(0x3E, 0x40, 0xD3, 0xBF, 0x3E, 0x81, 0xD3, 0xBF)        # display on
    a.label('loop'); a.db(0x18); a.rel('loop')
    a.label('dmago')                                           # HL -> $F4-$FA
    a.db(0x0E, 0xF4, 0x06, 0x07)
    a.label('dl'); a.db(0xED, 0xA3, 0x0C, 0x78, 0xB7, 0x20); a.rel('dl'); a.db(0xC9)   # OUTI ; INC C ; LD A,B ; OR A ; JR NZ
    a.label('regs')
    for v, r in regs:
        a.db(v, r)
    for r, ents in rows.items():
        a.label(f'row{r}'); a.db(*[v for e in ents for v in e])
    a.label('tiles')
    a.db(*[v for t in range(64) for r in range(8) for v in _bg_tile(t + 8, r)])
    a.label('pals')
    for p in range(3):
        for c in range(16):
            r_, g, b = (c + p * 5) & 15, (c * 3 + p * 7) & 15, (15 - c + p * 3) & 15
            a.db((g << 4) | r_, b)
    a.label('pal5')
    for c in range(16):
        a.db(((c * 2) & 15) << 4 | 15, c)
    for lab, data in jobs:
        a.label(lab); a.db(*data)
    a.resolve()
    rom = a.b
    # the ROM-source jobs point at the tile and palette data
    for i, lab in ((1, 'tiles'), (2, 'pals'), (3, 'pal5')):
        at = a.labels[f'job{i}']
        rom[at] = a.labels[lab] & 0xFF; rom[at + 1] = a.labels[lab] >> 8
    # the CRAM jobs: $F8 bit 6 (the destination high byte above carried $40)
    for i in (2, 3):
        at = a.labels[f'job{i}']
        rom[at + 4] = 0x40
    assert a.pc <= 0x7FF0, hex(a.pc)
    rom[0x7FF0:0x7FFA] = b'TMR SEGA' + b'\x00\x00'
    cs = sum(rom[0:0x7FF0]) & 0xFFFF
    rom[0x7FFA] = cs & 0xFF; rom[0x7FFB] = cs >> 8
    rom[0x7FFF] = 0x8C
    return bytes(rom)


PCM_PHASES = 30          # frames per phase: PCM alone, wavetable alone, both, silence


def _wave_sine():
    return [round(8 + 7 * math.sin(2 * math.pi * k / 32)) for k in range(32)]


def build_pcm():
    """PCM and wavetable sound (Technical Reference section 7), for
    tools/check_pcm_wav.py. MasterDrive mode, the I/O gate open. Frames 0-29:
    the PCM plays a square wave at 8,000 samples a second, 16 samples of 192
    and 16 of 64 (250 Hz), the ROM keeping its FIFO above 32 bytes by reading
    $08. Frames 30-59: the PCM stops (its output holds the last sample) and
    the wavetable plays: voice 0 a sine of 32 samples, frequency 125 (400 Hz),
    volume 15, both sides; voice 1 a square (15, then 0), frequency 250 (800
    Hz), volume 8, the left side only. Frames 60-89: both. Frames 90-119:
    silence. Then the cycle repeats."""
    a = Asm()
    a.org(0x0000)
    a.db(0xF3, 0xED, 0x56, 0x31); a.dw(0xDFF0); a.db(0xC3); a.ref16('main')
    a.org(0x0038)                                          # frame IRQ: count frames at $C000
    a.db(0xF5, 0xDB, 0xBF, 0x3A); a.dw(0xC000); a.db(0x3C, 0x32); a.dw(0xC000)
    a.db(0xF1, 0xFB, 0xED, 0x4D)
    a.org(0x0066); a.db(0xED, 0x45)
    a.org(0x0100); a.label('main')
    a.db(0xAF, 0x32); a.dw(0xC000)
    a.db(0x3E, 0x80, 0xD3, 0xBF, 0x3E, 0x8F, 0xD3, 0xBF)    # R15 = $80: the I/O gate
    a.db(0x3E, 0x00, 0xD3, 0x08)                           # PCM at 8,000 a second
    # wavetable voices: waveforms, then frequency, volume and sides (not yet keyed on)
    for v, wave, f, vol, sides in ((0, _wave_sine(), 125, 15, 3), (1, [15] * 16 + [0] * 16, 250, 8, 2)):
        for k, smp in enumerate(wave):
            a.db(0x3E, (v << 5) | k, 0xD3, 0x11, 0x3E, smp, 0xD3, 0x12)
        a.db(0x3E, v << 5, 0xD3, 0x11)
        a.db(0x3E, f & 0xFF, 0xD3, 0x13, 0x3E, f >> 8, 0xD3, 0x14)
        a.db(0x3E, (sides << 4) | vol, 0xD3, 0x15)
    a.db(0x3E, 0x20, 0xD3, 0xBF, 0x3E, 0x81, 0xD3, 0xBF)    # frame IRQ on, display off
    a.db(0xFB)
    a.db(0x21); a.ref16('square')                          # HL: the next PCM sample
    a.label('loop')
    a.db(0x3A); a.dw(0xC000)                               # A = frame
    a.db(0xFE, PCM_PHASES); a.db(0x38); a.rel('feed')      # < 30: PCM
    a.db(0xFE, 2 * PCM_PHASES); a.db(0x30); a.rel('p3')
    a.db(0xCD); a.ref16('keyon'); a.db(0x18); a.rel('loop')   # 30-59: wavetable only
    a.label('p3')
    a.db(0xFE, 3 * PCM_PHASES); a.db(0x30); a.rel('quiet')
    a.label('feed')
    a.db(0xDB, 0x08, 0xE6, 0x70, 0xFE, 0x40); a.db(0x30); a.rel('loop')   # FIFO at 32 bytes or more
    a.db(0x06, 0x08)
    a.label('put'); a.db(0x7E, 0xD3, 0x07, 0x23, 0x7D, 0xE6, 0x1F, 0x20); a.rel('next')
    a.db(0x21); a.ref16('square')                          # wrap at 32 samples (the table is aligned)
    a.label('next'); a.db(0x10); a.rel('put')
    a.db(0x3A); a.dw(0xC000); a.db(0xFE, 2 * PCM_PHASES); a.db(0x38); a.rel('loop')
    a.db(0xCD); a.ref16('keyon'); a.db(0x18); a.rel('loop')
    a.label('quiet')                                       # 90-119: keys off, the PCM stops
    a.db(0x3E, 0x00, 0xD3, 0x11, 0x3E, 0x00, 0xD3, 0x14, 0x3E, 0x20, 0xD3, 0x11, 0x3E, 0x00, 0xD3, 0x14)
    a.label('hush'); a.db(0x3A); a.dw(0xC000); a.db(0xFE, 4 * PCM_PHASES); a.db(0x38); a.rel('hush')
    a.db(0xAF, 0x32); a.dw(0xC000); a.db(0x18); a.rel('loop')   # then the cycle again from frame 0
    a.label('keyon')                                       # key on both voices (frequency high bits 0)
    a.db(0x3E, 0x00, 0xD3, 0x11, 0x3E, 0x80, 0xD3, 0x14, 0x3E, 0x20, 0xD3, 0x11, 0x3E, 0x80, 0xD3, 0x14, 0xC9)
    while a.pc & 0x1F:
        a.db(0x00)
    a.label('square'); a.db(*([192] * 16 + [64] * 16))
    a.resolve()
    rom = a.b
    rom[0x7FF0:0x7FFA] = b'TMR SEGA' + b'\x00\x00'
    cs = sum(rom[0:0x7FF0]) & 0xFFFF
    rom[0x7FFA] = cs & 0xFF; rom[0x7FFB] = cs >> 8
    rom[0x7FFF] = 0x8C
    return bytes(rom)


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
    open(os.path.join(out, 'mdrfeat.sms'), 'wb').write(build_ss())
    print('wrote mdrfeat.sms')
    open(os.path.join(out, 'ports.sms'), 'wb').write(build_ports())
    print('wrote ports.sms')
    open(os.path.join(out, 'mdports.sms'), 'wb').write(build_mdports())
    print('wrote mdports.sms')
    open(os.path.join(out, 'mdrregs.sms'), 'wb').write(build_mdrregs())
    print('wrote mdrregs.sms')
    open(os.path.join(out, 'romwait.sms'), 'wb').write(build_romwait())
    print('wrote romwait.sms')
    for m in ('g1', 'g2', 'mc', 'txt'):
        open(os.path.join(out, f'tms_{m}.sg'), 'wb').write(build_tms(m))
        print(f'wrote tms_{m}.sg')
    open(os.path.join(out, 'dma.sms'), 'wb').write(build_dma())
    print('wrote dma.sms')
    open(os.path.join(out, 'pcm.sms'), 'wb').write(build_pcm())
    print('wrote pcm.sms')
    for sd in GFXFUZZ_SEEDS:
        open(os.path.join(out, f'gfxfuzz{sd}.sms'), 'wb').write(build_gfxfuzz(sd))
        print(f'wrote gfxfuzz{sd}.sms')
    for v, n in (('a', 'mdrgfx'), ('b', 'mdrtext')):
        open(os.path.join(out, f'{n}.sms'), 'wb').write(build_mdrgfx(v))
        print(f'wrote {n}.sms')
    for h, m in ((224, 'g2'), (240, 'g2'), (240, 'txt')):
        open(os.path.join(out, f'tms_{m}_{h}.sms'), 'wb').write(build_tms_tall(h, m))
        print(f'wrote tms_{m}_{h}.sms')
