"""An upbeat, light track for a product film, synthesised here (no samples, nothing downloaded, so no licence to clear).

    python groove_music.py OUT.wav SECONDS BPM ['{"reveal": 14, "wipe": 67, ...}']

D major, one chord a bar (D - A/C# - Bm7 - G, later G - D/F# - Em7 - A). A marimba-like pluck plays eighth notes, a round bass
plays a syncopated line, a pad sits behind and ducks on every kick; kick on every beat, a soft clap on 2 and 4, hats off the beat.
The arrangement follows the film (beats given in the last argument): a sparse opening with single notes on beats 2, 3, 4, the
groove from "reveal", no drums during "wipe", a lighter groove under "terminal", everything from "payoff", three chord stabs at
"claim", one held chord at "end". Bars are counted so that "reveal" falls on a downbeat. Stereo, 44.1 kHz, 16-bit, peak -3 dBFS.
"""
import json
import sys
import wave

import numpy as np
from scipy.signal import butter, sosfilt

out, total, bpm = sys.argv[1], float(sys.argv[2]), float(sys.argv[3])
marks = json.loads(sys.argv[4]) if len(sys.argv) > 4 else {}
SR = 44100
beat = 60.0 / bpm
N = int(total * SR)
beats_total = total / beat
rng = np.random.default_rng(11)

reveal = marks.get("reveal", 16.0)
wipe = marks.get("wipe", beats_total * 0.45)
hands = marks.get("hands", wipe + 6)
style = marks.get("style", hands + 10)
terminal = marks.get("terminal", beats_total * 0.72)
payoff = marks.get("payoff", beats_total * 0.81)
claim = marks.get("claim", beats_total * 0.9)
end = marks.get("end", beats_total * 0.95)


def hz(midi):
    return 440.0 * 2 ** ((midi - 69) / 12)


def bus():
    return np.zeros((2, N))


def put(buf, at_beat, sig, gain=1.0, pan=0.0):
    i = int(at_beat * beat * SR)
    if i >= N or i < 0:
        return
    sig = sig[:N - i]
    buf[0, i:i + len(sig)] += sig * gain * (1 - max(0.0, pan))
    buf[1, i:i + len(sig)] += sig * gain * (1 + min(0.0, pan))


def filt(sig, kind, cutoff, order=2):
    return sosfilt(butter(order, cutoff, kind, fs=SR, output="sos"), sig)


def pluck(midi, length=0.9):
    t = np.arange(int(length * SR)) / SR
    f = hz(midi)
    sig = np.sin(2 * np.pi * f * t) * np.exp(-t / 0.24) + 0.32 * np.sin(2 * np.pi * 3 * f * t) * np.exp(-t / 0.07) \
        + 0.14 * np.sin(2 * np.pi * 4 * f * t) * np.exp(-t / 0.035)
    return sig * np.minimum(1, t / 0.003)


def saw(freq, length, harmonics=8):
    t = np.arange(int(length * SR)) / SR
    return sum(np.sin(2 * np.pi * freq * k * t) / k for k in range(1, harmonics + 1))


def pad_note(midi, length):
    n = int(length * SR)
    env = np.minimum(1, np.arange(n) / (0.28 * SR)) * np.minimum(1, (n - np.arange(n)) / (0.45 * SR))
    return (saw(hz(midi) * 0.996, length) + saw(hz(midi) * 1.004, length)) * env


def bass_note(midi, length):
    t = np.arange(int(length * SR)) / SR
    f = hz(midi)
    sig = np.sin(2 * np.pi * f * t) + 0.45 * np.sin(2 * np.pi * 2 * f * t) + 0.18 * np.sin(2 * np.pi * 3 * f * t)
    return sig * np.minimum(1, t / 0.006) * np.minimum(1, (length - t) / 0.03) * np.exp(-t / 0.9)


def kick():
    t = np.arange(int(0.32 * SR)) / SR
    phase = 2 * np.pi * (48 * t + 70 * 0.035 * (1 - np.exp(-t / 0.035)))
    sig = np.sin(phase) * np.exp(-t / 0.15)
    sig[:int(0.002 * SR)] += 0.25 * rng.standard_normal(int(0.002 * SR))
    return sig


def clap():
    n = int(0.22 * SR)
    t = np.arange(n) / SR
    env = sum(np.where(t >= d, np.exp(-(t - d) / 0.007), 0) for d in (0, 0.011, 0.022)) * 0.5 + np.where(t >= 0.03, np.exp(-(t - 0.03) / 0.06), 0)
    return filt(filt(rng.standard_normal(n), "highpass", 900), "lowpass", 3800) * env


def hat(decay=0.022):
    n = int(decay * 6 * SR)
    t = np.arange(n) / SR
    return filt(rng.standard_normal(n), "highpass", 7500) * np.exp(-t / decay)


def riser(length_beats):
    n = int(length_beats * beat * SR)
    u = np.arange(n) / n
    return filt(rng.standard_normal(n), "highpass", 2500) * u ** 2.2


def impact():
    t = np.arange(int(1.6 * SR)) / SR
    return np.sin(2 * np.pi * 52 * t) * np.exp(-t / 0.3) + 0.5 * filt(rng.standard_normal(len(t)), "lowpass", 2600) * np.exp(-t / 0.42)


# 和弦：低音、垫底的四个音、上面给拨弦用的四个音
A = [(38, [57, 62, 66, 69], [74, 78, 81, 86]), (37, [57, 61, 64, 69], [73, 76, 81, 85]),
     (35, [57, 59, 62, 66], [71, 74, 78, 81]), (43, [55, 59, 62, 67], [71, 74, 79, 83])]
B = [(43, [55, 59, 62, 67], [71, 74, 79, 83]), (42, [57, 62, 66, 69], [74, 78, 81, 86]),
     (40, [55, 59, 62, 64], [71, 74, 76, 79]), (45, [57, 61, 64, 69], [73, 76, 81, 85])]

drums, low, pads, plucks, wet = bus(), bus(), bus(), bus(), bus()
kicks = []
KICK, CLAP, HAT, OPEN = kick(), clap(), hat(), hat(0.06)


def state(position):
    if position < reveal:
        return "intro"
    if position >= claim:
        return "out"
    if wipe <= position < hands:
        return "break"
    if terminal <= position < payoff:
        return "light"
    if position >= payoff:
        return "full"
    return "groove"


offset = reveal % 4
bar = -1
while offset + bar * 4 < beats_total:
    start = offset + bar * 4
    chords = B if style <= start < terminal else A
    root, pad, arp = chords[bar % 4] if start >= reveal else A[(0, 0, 2, 2)[bar % 4]]
    mood = state(max(0.0, start))
    if mood != "out" and start + 4 > 0:
        # 垫底：一小节一个和弦，开头轻一些
        for note in pad:
            sig = pad_note(note, 4 * beat + 0.5)
            put(pads, max(0, start), sig, 0.034 if mood == "intro" else 0.030, 0.0)
        for step in range(8):  # 八个八分音符
            position = start + step / 2
            if position < 0 or position >= beats_total:
                continue
            mood = state(position)
            if mood in ("intro", "out"):
                continue
            # 拨弦
            sparse = mood in ("break", "light")
            if not sparse or step % 2 == 0:
                note = arp[(0, 1, 2, 3, 2, 1, 2, 3)[step]]
                velocity = (1.0, 0.6, 0.8, 0.6, 0.9, 0.6, 0.8, 0.7)[step] * (0.9 + 0.2 * rng.random())
                pan = 0.4 if step % 2 else -0.4
                put(plucks, position, pluck(note), 0.19 * velocity, pan)
                put(plucks, position + 0.75, pluck(note), 0.055 * velocity, -pan)  # 附点八分之后一声回声
                put(wet, position, pluck(note), 0.10 * velocity, -pan)
                if mood == "full" and step % 2 == 0:
                    put(plucks, position, pluck(note + 12, 0.6), 0.06 * velocity, -pan)
            if mood == "break":
                continue
            # 鼓：每拍一脚，二四拍一声拍手，反拍一声镲
            if step % 2 == 0:
                put(drums, position, KICK, 0.62)
                kicks.append(position)
                if step in (2, 6) and mood != "light":
                    put(drums, position, CLAP, 0.20, 0.1)
                    put(wet, position, CLAP, 0.08)
            else:
                put(drums, position, OPEN if step == 7 else HAT, 0.075 if step == 7 else 0.090, -0.2)
            if mood == "full" or hands <= position < style:
                put(drums, position + 0.25, HAT, 0.042, 0.25)  # 十六分的小镲
            # 低音：一拍、二拍半、三拍半、四拍
            pattern = {0: 1.3, 3: 0.9, 5: 0.45, 6: 0.9} if mood != "light" else {0: 1.8, 4: 1.8}
            if step in pattern:
                put(low, position, bass_note(root + (12 if step == 5 else 0), pattern[step] * beat), 0.25)
    bar += 1

# 开头：一个和弦，第 2、3、4 拍各一个音（片头那三句压进来的地方），第 8 拍换一个和弦
for note in (62, 66, 69, 74):
    put(plucks, 0, pluck(note, 1.4), 0.20)
    put(wet, 0, pluck(note, 1.4), 0.16)
for position, note in ((2, 78), (3, 81), (4, 86), (8, 71), (8, 78), (10, 74), (11, 76)):
    if position < reveal:
        put(plucks, position, pluck(note, 1.2), 0.36, 0.2 if note % 2 else -0.2)
        put(wet, position, pluck(note, 1.2), 0.24)

# 每个大的转折前一段上扬的沙声，转折那一下一声闷响
for mark in (reveal, hands, payoff):
    put(wet, mark - 2, riser(2), 0.05)
    put(drums, mark - 2, riser(2), 0.035)
for mark in (reveal, hands, payoff, end):
    put(drums, mark, impact(), 0.30)
    put(wet, mark, impact(), 0.20)

# 结尾：三句各一个和弦，最后一个长和弦
for index, (root, _, arp) in enumerate((A[0], A[3], B[3])):
    position = claim + 0.6 + index
    for note in arp:
        put(plucks, position, pluck(note, 1.0), 0.11)
        put(wet, position, pluck(note, 1.0), 0.08)
    put(low, position, bass_note(root, 0.8 * beat), 0.30)
    put(drums, position, KICK, 0.55)
for index, note in enumerate((62, 69, 74, 76, 78, 81, 86)):
    put(plucks, end + index * 0.125, pluck(note, 2.6), 0.11, 0.3 if index % 2 else -0.3)
    put(wet, end + index * 0.125, pluck(note, 2.6), 0.10)
for note in (50, 57, 62, 66, 69, 76):
    put(pads, end, pad_note(note, max(1.0, total - end * beat)), 0.030)
put(low, end, bass_note(38, 3.0), 0.32)

# 垫底和低音在每一脚上让一下
duck = np.ones(N)
for position in kicks:
    i = int(position * beat * SR)
    n = min(N - i, int(0.5 * SR))
    if n > 0:
        duck[i:i + n] = np.minimum(duck[i:i + n], 1 - 0.5 * np.exp(-np.arange(n) / (0.14 * SR)))
pads = np.stack([filt(channel, "lowpass", 1500) for channel in pads]) * duck
low = np.stack([filt(channel, "lowpass", 520) for channel in low]) * (0.6 + 0.4 * duck)
wet += pads * 0.5

# 混响：湿的那一路卷一段衰减的噪声，左右各一段
L = int(1.5 * SR)
k = np.arange(L)
rev = np.zeros((2, N))
for channel in range(2):
    ir = rng.standard_normal(L) * np.exp(-k / (0.38 * SR))
    ir[:int(0.012 * SR)] = 0
    ir = np.convolve(ir, np.ones(20) / 20, mode="same")
    size = 1 << int(np.ceil(np.log2(N + L)))
    rev[channel] = np.fft.irfft(np.fft.rfft(wet[channel], size) * np.fft.rfft(ir, size), size)[:N]
dry = drums + low + pads + plucks
rev *= 0.45 * np.abs(dry).max() / (np.abs(rev).max() + 1e-9)
mix = dry + rev

fade_in, fade_out = int(0.05 * SR), int(2.6 * SR)
gain = np.ones(N)
gain[:fade_in] = np.linspace(0, 1, fade_in)
gain[-fade_out:] = np.linspace(1, 0, fade_out) ** 1.5
mix *= gain
mix = np.tanh(mix / (np.abs(mix).max() + 1e-9) * 1.3) / np.tanh(1.3)  # 一点软饱和
mix *= 10 ** (-3 / 20) / np.abs(mix).max()
with wave.open(out, "wb") as file:
    file.setnchannels(2)
    file.setsampwidth(2)
    file.setframerate(SR)
    file.writeframes((mix.T * 32767).astype("<i2").tobytes())
print(out, f"{total:.1f} s, {bpm:.0f} bpm, peak {20 * np.log10(np.abs(mix).max()):.1f} dBFS, {len(kicks)} kicks")
