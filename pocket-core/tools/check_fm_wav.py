#!/usr/bin/env python3
"""Check an audio capture of roms/fm.sms or roms/fm_tight.sms (tools/mk_testrom.py, build_fm).

usage: check_fm_wav.py capture.wav [--no-fm] [--pal]

The ROM plays a PSG square wave (tone period $0FE: 440.4 Hz on the NTSC
machine) and an FM sine (F-number 330, block 5: 1001.4 Hz on NTSC) and steps
the FM control port $F2 through 0, 1, 3, 2, 0 every 10 frames. For each step
this measures both tones over frames 3-7 of the step, on both channels, and
checks that each is present or absent as that $F2 state says (0 PSG only,
1 FM only, 2 neither, 3 both). It also checks the PSG and FM pitches and the
FM level against the PSG level (provisional balance, open question Q20).
fm_tight.sms plays the same, with its FM writes spaced the way a sound
driver spaces them: enough for the YM2413 at 100 %, too close at 200 % turbo
unless the bus synchroniser holds the CPU.

--no-fm: a mode without the FM unit (Game Gear, SG-1000, SC-3000). $F2 writes
do nothing there, so the PSG plays through every step and FM never does.
--pal: the capture is from the PAL machine (313-line frames, 3.546893 MHz), so
the frames are longer and both tones are about 0.9 % lower.
"""
import sys
import wave

import numpy as np

PAL = '--pal' in sys.argv              # PAL machine: 313 lines at 3.546893 MHz
BASE = 3546893 if PAL else 3579545
FRAME = (313 if PAL else 262) * 228 / BASE   # frame, seconds
PSG_HZ = BASE / (32 * 254)             # tone period $0FE
FM_HZ = 330 * 2 ** 5 * (BASE / 72) / 2 ** 19   # F-number 330, block 5
STEPS = [0, 1, 3, 2, 0]                # $F2 for frames 0-9, 10-19, ...
HEADROOM = 41 / 64                    # the mixer's scale before the 16-bit output
# fundamental of a full-volume PSG square (+-8191): 4/pi x 8191
PSG_FULL = 4 / np.pi * 8191 * HEADROOM
# one FM channel at full volume: +-510 from the chip, x8 in the mixer
FM_FULL = 510 * 8 * HEADROOM


def tone(x, f, rate):
    """Amplitude of the component at f (Hann-windowed single-bin DFT)."""
    t = np.arange(len(x)) / rate
    w = np.hanning(len(x))
    return 2 * abs(np.sum(x * w * np.exp(-2j * np.pi * f * t))) / w.sum()


def peak(x, rate, lo, hi):
    """Frequency of the strongest component between lo and hi Hz."""
    n = 1 << 18
    spec = np.abs(np.fft.rfft(x * np.hanning(len(x)), n))
    freqs = np.fft.rfftfreq(n, 1 / rate)
    band = (freqs >= lo) & (freqs <= hi)
    i = np.flatnonzero(band)[np.argmax(spec[band])]
    a, b, c = np.log(spec[i - 1:i + 2] + 1e-9)       # parabolic interpolation
    return freqs[i] + 0.5 * (a - c) / (a - 2 * b + c) * (freqs[1] - freqs[0])


def main():
    args = [a for a in sys.argv[1:] if not a.startswith('--')]
    no_fm = '--no-fm' in sys.argv
    w = wave.open(args[0])
    rate = w.getframerate()
    d = np.frombuffer(w.readframes(w.getnframes()), dtype='<i2').reshape(-1, 2).astype(float)
    need = (10 * (len(STEPS) - 1) + 8) * FRAME
    if len(d) < int(need * rate):
        sys.exit(f'capture too short: {len(d) / rate:.2f} s, need {need:.2f} s')
    bad = 0
    for k, f2 in enumerate(STEPS):
        a = int((10 * k + 3) * FRAME * rate)
        b = int((10 * k + 8) * FRAME * rate)
        want_psg = no_fm or f2 in (0, 3)
        want_fm = not no_fm and f2 in (1, 3)
        for ch, name in ((0, 'L'), (1, 'R')):
            x = d[a:b, ch]
            p, f = tone(x, PSG_HZ, rate), tone(x, FM_HZ, rate)
            ok = ((p > 0.9 * PSG_FULL) if want_psg else (p < 20)) and \
                 ((f > 0.8 * FM_FULL) if want_fm else (f < 20))
            print(f'step {k} $F2={f2} {name}: PSG {p:7.0f} ({"on" if want_psg else "off"}), '
                  f'FM {f:6.0f} ({"on" if want_fm else "off"}) {"ok" if ok else "WRONG"}')
            bad += not ok
            if want_psg and ch == 0:
                hz = peak(x, rate, PSG_HZ * 0.9, PSG_HZ * 1.1)
                good = abs(hz / PSG_HZ - 1) < 0.002
                print(f'        PSG pitch {hz:.2f} Hz, expected {PSG_HZ:.2f} {"ok" if good else "WRONG"}')
                bad += not good
            if want_fm and ch == 0:
                hz = peak(x, rate, FM_HZ * 0.9, FM_HZ * 1.1)
                good = abs(hz / FM_HZ - 1) < 0.002
                print(f'        FM pitch {hz:.1f} Hz, expected {FM_HZ:.1f} {"ok" if good else "WRONG"}')
                bad += not good
                if want_psg:
                    r = f / p
                    good = 0.3 < r < 0.5
                    print(f'        FM / PSG fundamental {r:.3f}, expected about {FM_FULL / PSG_FULL:.3f} '
                          f'{"ok" if good else "WRONG"}')
                    bad += not good
    if bad:
        sys.exit(f'{bad} check(s) failed')
    print('PASS')


if __name__ == '__main__':
    main()
