#!/usr/bin/env python3
"""Check an audio capture of roms/pcm.sms (tools/mk_testrom.py, build_pcm).

usage: check_pcm_wav.py capture.wav

The ROM plays four phases of 30 frames each, then repeats them: (1) the PCM
alone, a square wave of 16 samples of 192 and 16 of 64 at 8,000 samples a
second (250 Hz); (2) the wavetable alone, voice 0 a 32-sample sine at
frequency 125 (400 Hz) on both sides at volume 15, voice 1 a square at
frequency 250 (800 Hz) on the left at volume 8; (3) both; (4) silence. For
each phase this measures the three tones over its frames 8-25, on both
sides, and checks that each is there, at the expected level and pitch, or
absent, as the phase and the voice's sides say. The levels are the
emulator's (open question Q27): in the units of a PSG channel at full volume
(8191), the PCM is (sample - 128) x 80 and a voice (sample - 8) x volume x 51,
before the mixer's 41/64.
"""
import math
import sys
import wave

import numpy as np

FRAME = 262 * 228 / 3579545          # NTSC frame, seconds
PHASE = 30                           # frames per phase
HEADROOM = 41 / 64
PCM_HZ = 8000 / 32
SINE_HZ = 125 * 3.2
SQ_HZ = 250 * 3.2


def fundamental(samples, scale):
    """Amplitude of the fundamental of one period of a waveform (list of values)."""
    n = len(samples)
    c = sum(v * np.exp(-2j * np.pi * k / n) for k, v in enumerate(samples))
    return 2 * abs(c) / n * scale


PCM_FULL = fundamental([64 * 80] * 16 + [-64 * 80] * 16, HEADROOM)
SINE_FULL = fundamental([(round(8 + 7 * math.sin(2 * math.pi * k / 32)) - 8) * 15 * 51 for k in range(32)], HEADROOM)
SQ_FULL = fundamental([7 * 8 * 51] * 16 + [-8 * 8 * 51] * 16, HEADROOM)


def tone(x, f, rate):
    t = np.arange(len(x)) / rate
    w = np.hanning(len(x))
    return 2 * abs(np.sum(x * w * np.exp(-2j * np.pi * f * t))) / w.sum()


def peak(x, rate, lo, hi):
    n = 1 << 18
    spec = np.abs(np.fft.rfft(x * np.hanning(len(x)), n))
    freqs = np.fft.rfftfreq(n, 1 / rate)
    band = (freqs >= lo) & (freqs <= hi)
    i = np.flatnonzero(band)[np.argmax(spec[band])]
    a, b, c = np.log(spec[i - 1:i + 2] + 1e-9)
    return freqs[i] + 0.5 * (a - c) / (a - 2 * b + c) * (freqs[1] - freqs[0])


def main():
    w = wave.open(sys.argv[1])
    rate = w.getframerate()
    d = np.frombuffer(w.readframes(w.getnframes()), dtype='<i2').reshape(-1, 2).astype(float)
    need = (4 * PHASE) * FRAME
    if len(d) < int(need * rate):
        sys.exit(f'capture too short: {len(d) / rate:.2f} s, need {need:.2f} s')
    bad = 0
    # (phase name, PCM on, wavetable on)
    for k, (name, pcm, wt) in enumerate((('PCM', True, False), ('wavetable', False, True), ('both', True, True),
                                         ('silence', False, False))):
        a = int((PHASE * k + 8) * FRAME * rate)
        b = int((PHASE * k + 25) * FRAME * rate)
        for ch, side in ((0, 'L'), (1, 'R')):
            x = d[a:b, ch] - d[a:b, ch].mean()
            p, s, q = tone(x, PCM_HZ, rate), tone(x, SINE_HZ, rate), tone(x, SQ_HZ, rate)
            want_q = wt and ch == 0
            ok = ((abs(p / PCM_FULL - 1) < 0.08) if pcm else (p < 40)) and \
                 ((abs(s / SINE_FULL - 1) < 0.08) if wt else (s < 40)) and \
                 ((abs(q / SQ_FULL - 1) < 0.10) if want_q else (q < 40))
            print(f'{name:9} {side}: PCM 250 Hz {p:6.0f} (want {PCM_FULL:.0f} if on), sine 400 Hz {s:6.0f} '
                  f'(want {SINE_FULL:.0f}), square 800 Hz {q:6.0f} (want {SQ_FULL:.0f} left) {"ok" if ok else "WRONG"}')
            bad += not ok
            if ch == 0:
                for on, hz0, label in ((pcm, PCM_HZ, 'PCM'), (wt, SINE_HZ, 'sine'), (want_q, SQ_HZ, 'square')):
                    if on:
                        hz = peak(x, rate, hz0 * 0.95, hz0 * 1.05)
                        good = abs(hz / hz0 - 1) < 0.003
                        print(f'          {label} pitch {hz:.2f} Hz, expected {hz0:.2f} {"ok" if good else "WRONG"}')
                        bad += not good
    if bad:
        sys.exit(f'{bad} check(s) failed')
    print('PASS')


if __name__ == '__main__':
    main()
