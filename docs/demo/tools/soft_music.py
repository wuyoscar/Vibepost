"""A calm, light background track for a demo video, synthesised here (no samples, nothing downloaded, so no licence to clear).

    python soft_music.py OUT.wav SECONDS [BPM]

Warm pad chords (Cmaj7 - Am7 - Fmaj7 - G6, two bars each), an electric-piano-like arpeggio in eighth notes, a soft bass on
beats 1 and 3, a quiet shaker; the arpeggio comes in after two bars, the shaker after four; the last four seconds fade out on
a C chord. Stereo, 44.1 kHz, 16-bit, peak at -3 dBFS.
"""
import sys
import wave

import numpy as np

out, total = sys.argv[1], float(sys.argv[2])
bpm = float(sys.argv[3]) if len(sys.argv) > 3 else 88.0
SR = 44100
beat = 60.0 / bpm
N = int(total * SR)
rng = np.random.default_rng(7)


def hz(midi):
    return 440.0 * 2 ** ((midi - 69) / 12)


def tone(freq, dur, harmonics):
    t = np.arange(int(dur * SR)) / SR
    return sum(a * np.sin(2 * np.pi * freq * k * t + p) for k, a, p in harmonics)


def put(buf, start, sig, gain=1.0, pan=0.0):
    i = int(start * SR)
    if i >= N:
        return
    sig = sig[:N - i]
    buf[0, i:i + len(sig)] += sig * gain * (1 - max(0.0, pan))
    buf[1, i:i + len(sig)] += sig * gain * (1 + min(0.0, pan))


# chord tones (MIDI): root for the bass, a mid voicing for the pad, an upper set for the arpeggio
CHORDS = [
    (36, [60, 64, 67, 71], [72, 76, 79, 83, 79, 76, 72, 76]),      # Cmaj7
    (33, [57, 60, 64, 67], [69, 72, 76, 79, 76, 72, 69, 72]),      # Am7
    (29, [57, 60, 65, 69], [72, 77, 81, 84, 81, 77, 72, 77]),      # Fmaj7
    (31, [59, 62, 67, 69], [74, 79, 83, 86, 83, 79, 74, 79]),      # G6
]
bars = int(np.ceil(total / (4 * beat))) + 1
dry = np.zeros((2, N))
wet = np.zeros((2, N))                                              # what goes through the reverb

for bar in range(bars):
    t0 = bar * 4 * beat
    last = t0 + 4 * beat >= total - 4.5                             # the ending rests on C
    root, pad, arp = CHORDS[0] if last else CHORDS[(bar // 2) % 4]
    # pad: one swell per bar, slow attack and release, two slightly detuned layers
    dur = 4 * beat + 0.6
    n = int(dur * SR)
    env = np.minimum(1, np.arange(n) / (0.9 * SR)) * np.minimum(1, (n - np.arange(n)) / (1.1 * SR))
    for j, m in enumerate(pad):
        for det, pan in ((0.997, -0.35), (1.003, 0.35)):
            sig = tone(hz(m) * det, dur, [(1, 1.0, 0.0), (2, 0.22, 0.5), (3, 0.07, 1.1)]) * env
            put(dry, t0, sig, 0.050, pan)
            put(wet, t0, sig, 0.035, pan)
    # bass: beats 1 and 3
    for b in (0, 2):
        d = 1.7 * beat
        k = np.arange(int(d * SR))
        e = np.minimum(1, k / (0.02 * SR)) * np.exp(-k / (0.55 * SR))
        put(dry, t0 + b * beat, tone(hz(root + 12), d, [(1, 1.0, 0.0), (2, 0.25, 0.0)]) * e, 0.13)
    # arpeggio: eighth notes, from the third bar
    if bar >= 2:
        for i, m in enumerate(arp):
            d = 1.6
            k = np.arange(int(d * SR))
            e = np.minimum(1, k / (0.004 * SR)) * np.exp(-k / (0.36 * SR))
            sig = tone(hz(m), d, [(1, 1.0, 0.0), (2, 0.30, 0.0), (4, 0.10, 0.0), (7, 0.02, 0.0)]) * e
            vel = (0.105 if i % 2 == 0 else 0.080) * (0.92 + 0.16 * rng.random())
            pan = 0.45 * np.sin(i * 1.3 + bar)
            ts = t0 + i * beat / 2 + (0.006 * rng.random())
            put(dry, ts, sig, vel, pan)
            put(wet, ts, sig, vel * 0.9, -pan)
            put(dry, ts + 1.5 * beat, sig, vel * 0.22, -pan)        # one soft echo, dotted quarter later
    # shaker: off-beat eighths, from the fifth bar
    if bar >= 4 and not last:
        for i in range(8):
            d = 0.09
            k = np.arange(int(d * SR))
            noise = rng.standard_normal(len(k))
            noise = np.diff(noise, prepend=0.0)                     # tilt it bright
            e = np.exp(-k / (0.018 * SR))
            put(dry, t0 + i * beat / 2, noise * e, 0.016 if i % 2 else 0.007, 0.25 if i % 2 else -0.25)

# reverb: the wet bus convolved with 1.6 s of decaying noise, a different one per ear
L = int(1.6 * SR)
k = np.arange(L)
rev = np.zeros((2, N))
for ch in range(2):
    ir = rng.standard_normal(L) * np.exp(-k / (0.42 * SR))
    ir[:int(0.012 * SR)] = 0
    ir = np.convolve(ir, np.ones(24) / 24, mode='same')             # darker tail
    size = 1 << int(np.ceil(np.log2(N + L)))
    rev[ch] = np.fft.irfft(np.fft.rfft(wet[ch], size) * np.fft.rfft(ir, size), size)[:N]
rev *= 0.6 * np.abs(dry).max() / (np.abs(rev).max() + 1e-9)
mix = dry + rev

fade_in, fade_out = int(1.2 * SR), int(4.0 * SR)
g = np.ones(N)
g[:fade_in] = np.linspace(0, 1, fade_in) ** 2
g[-fade_out:] = np.linspace(1, 0, fade_out) ** 1.5
mix *= g
mix = np.tanh(mix / (np.abs(mix).max() + 1e-9) * 1.15) / np.tanh(1.15)   # a little soft saturation
mix *= 10 ** (-3 / 20) / np.abs(mix).max()
pcm = (mix.T * 32767).astype('<i2')
with wave.open(out, 'wb') as w:
    w.setnchannels(2); w.setsampwidth(2); w.setframerate(SR)
    w.writeframes(pcm.tobytes())
print(out, f'{total:.1f} s, {bpm:.0f} bpm, peak {20 * np.log10(np.abs(mix).max()):.1f} dBFS')
