#!/usr/bin/env python3
"""Check an audio capture of roms/pcm.sms (tools/mk_testrom.py, build_pcm).

usage: check_pcm_wav.py capture.wav

The ROM plays seven phases of 20 frames each (mk_testrom.PCM_PHASES), then
repeats them: the PCM alone at each of its four rates, a square wave of 16
samples of 192 and 16 of 64, so a tone at the rate / 32 (250, 344.5, 500 and
689 Hz); the wavetable alone, voice 0 a 32-sample sine at frequency 125
(400 Hz) on both sides at volume 15, voice 1 a square at frequency 250
(800 Hz) on the left at volume 8; the PCM at 8,000 samples a second with the
wavetable; and silence. For each phase this measures every one of those tones
over the phase's frames 5-17, on both sides, and checks that each is there,
within 2 % of the expected level and 0.05 % of its pitch, or absent, as the
phase and the voice's sides say. The levels are the emulator's (open question
Q27): in the units of a PSG channel at full volume (8191), the PCM is
(sample - 128) x 80 and a voice (sample - 8) x volume x 51, before the
mixer's 41/64.
"""
import math
import os
import sys
import wave

import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from mk_testrom import PCM_PHASES, PCM_PHASE_FRAMES  # noqa: E402

FRAME = 262 * 228 / 3579545          # NTSC frame, seconds
HEADROOM = 41 / 64
RATES = (8000, 11025, 16000, 22050)
PCM_HZ = [r / 32 for r in RATES]
SINE_HZ = 125 * 3.2
SQ_HZ = 250 * 3.2
LEVEL_TOL = 0.02
PITCH_TOL = 0.0005
ABSENT = 40


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
    need = len(PCM_PHASES) * PCM_PHASE_FRAMES * FRAME
    if len(d) < int(need * rate):
        sys.exit(f'capture too short: {len(d) / rate:.2f} s, need {need:.2f} s')
    bad = 0
    for k, (pcm, wt) in enumerate(PCM_PHASES):
        name = (f'PCM {RATES[pcm]}' if pcm is not None else '') + (' + ' if pcm is not None and wt else '') + \
            ('wavetable' if wt else '') or 'silence'
        a = int((PCM_PHASE_FRAMES * k + 5) * FRAME * rate)
        b = int((PCM_PHASE_FRAMES * k + 17) * FRAME * rate)
        for ch, side in ((0, 'L'), (1, 'R')):
            x = d[a:b, ch] - d[a:b, ch].mean()
            # (label, frequency, expected level or None for absent)
            tones = [(f'PCM {hz:.1f} Hz', hz, PCM_FULL if pcm == i else None) for i, hz in enumerate(PCM_HZ)]
            tones += [('sine 400 Hz', SINE_HZ, SINE_FULL if wt else None),
                      ('square 800 Hz', SQ_HZ, SQ_FULL if wt and ch == 0 else None)]
            words = []
            for label, hz, want in tones:
                got = tone(x, hz, rate)
                ok = abs(got / want - 1) < LEVEL_TOL if want else got < ABSENT
                if want or not ok:
                    words.append(f'{label} {got:.0f} (want {want:.0f})' if want else f'{label} {got:.0f} (want none)')
                if want and ch == 0:
                    f = peak(x, rate, hz * 0.95, hz * 1.05)
                    good = abs(f / hz - 1) < PITCH_TOL
                    words.append(f'at {f:.2f} Hz' + ('' if good else ' WRONG PITCH'))
                    bad += not good
                bad += not ok
                if not ok:
                    words.append('WRONG')
            print(f'{name:21} {side}: ' + ('; '.join(words) if words else 'nothing heard, as wanted'))
    if bad:
        sys.exit(f'{bad} check(s) failed')
    print('PASS')


if __name__ == '__main__':
    main()
