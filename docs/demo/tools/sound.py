# /// script
# requires-python = ">=3.11"
# dependencies = ["numpy"]
# ///
"""片子的声音：一段合成的轻音乐（tools/soft_music.py），每次点击上一声很轻的「嗒」。在 docs/demo 里运行：

    uv run tools/sound.py              # 详细教程：读 tutorial/cues.json，写 tutorial/assets/track.wav
    uv run tools/sound.py . 96         # 主视频：读 ./cues.json，写 ./assets/track.wav，96 BPM

声音都是现场合成的，没有下载的素材。
"""
import json
import subprocess
import sys
import wave
from pathlib import Path

import numpy as np

TOOLS = Path(__file__).resolve().parent
HERE = Path(sys.argv[1]).resolve() if len(sys.argv) > 1 else TOOLS.parent / "tutorial"  # 哪个 HyperFrames 项目（默认是详细教程）
BPM = sys.argv[2] if len(sys.argv) > 2 else "88"
cues = json.loads((HERE / "cues.json").read_text())
bed = HERE / "assets" / "bed.wav"
subprocess.run([sys.executable, str(TOOLS / "soft_music.py"), str(bed), str(cues["total"]), BPM], check=True)

source = wave.open(str(bed))
rate, count = source.getframerate(), source.getnframes()
mix = np.frombuffer(source.readframes(count), "<i2").reshape(-1, 2).T.astype(float) / 32768
source.close()


def put(at, signal, gain, pan=0.0):
    start = int(at * rate)
    if start >= mix.shape[1]:
        return
    signal = signal[: mix.shape[1] - start]
    mix[0, start : start + len(signal)] += signal * gain * (1 - max(0, pan))
    mix[1, start : start + len(signal)] += signal * gain * (1 + min(0, pan))


k = np.arange(int(0.09 * rate))
noise = np.random.default_rng(3)
tick = np.sin(2 * np.pi * 1500 * k / rate) * np.exp(-k / (0.012 * rate)) + 0.5 * np.sin(2 * np.pi * 760 * k / rate) * np.exp(-k / (0.03 * rate))
tick[: int(0.003 * rate)] += 0.5 * noise.standard_normal(int(0.003 * rate))
for index, at in enumerate(cues["clicks"]):
    put(at + 1 / 30, tick, 0.10, 0.25 if index % 2 else -0.25)  # 声音比画面晚一帧

mix = np.clip(mix, -0.98, 0.98)
target = HERE / "assets" / "track.wav"
out = wave.open(str(target), "wb")
out.setnchannels(2)
out.setsampwidth(2)
out.setframerate(rate)
out.writeframes((mix.T * 32767).astype("<i2").tobytes())
out.close()
bed.unlink()
print(target, round(mix.shape[1] / rate, 2), "秒", len(cues["clicks"]), "次点击")
