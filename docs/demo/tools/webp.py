# /// script
# requires-python = ">=3.11"
# dependencies = ["pillow"]
# ///
"""把一条视频做成会自动播放的动图（WebP，无声）：GitHub 的 README 里放不了仓库里的 mp4，动图可以。

    uv run tools/webp.py renders/film.mp4 ../screenshots/vibepost.webp            # 整条，宽 960、一秒 12 帧
    uv run tools/webp.py renders/film.mp4 out.webp --from 18 --to 27 --width 960  # 只要一段

这里的 ffmpeg 没带 libwebp，所以先用它抽帧，再用 Pillow 合成。
"""
import argparse
import subprocess
import tempfile
from pathlib import Path

from PIL import Image

parser = argparse.ArgumentParser()
parser.add_argument("video")
parser.add_argument("out")
parser.add_argument("--width", type=int, default=960)
parser.add_argument("--fps", type=int, default=12)
parser.add_argument("--quality", type=int, default=70)
parser.add_argument("--from", dest="start", type=float, default=0.0)
parser.add_argument("--to", dest="end", type=float)
args = parser.parse_args()

with tempfile.TemporaryDirectory() as folder:
    span = ["-ss", str(args.start)] + (["-to", str(args.end)] if args.end else [])
    subprocess.run(["ffmpeg", "-y", "-loglevel", "error", *span, "-i", args.video,
                    "-vf", f"fps={args.fps},scale={args.width}:-2:flags=lanczos", str(Path(folder) / "%05d.png")], check=True)
    files = sorted(Path(folder).glob("*.png"))
    frames = (Image.open(file).convert("RGB") for file in files)
    first = next(frames)
    # 每帧的时长取整到毫秒，逐帧补上取整丢掉的那一点，放完正好是原来的长度
    durations, owed = [], 0.0
    for _ in files:
        owed += 1000 / args.fps
        durations.append(round(owed))
        owed -= durations[-1]
    first.save(args.out, save_all=True, append_images=frames, duration=durations, loop=0, quality=args.quality, method=4)
print(args.out, f"{len(files)} 帧，{Path(args.out).stat().st_size / 1e6:.2f} MB")
