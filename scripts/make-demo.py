# /// script
# requires-python = ">=3.11"
# dependencies = ["pillow>=10"]
# ///
"""把 DemoFramesTests 存下的逐帧截图合成 README 的动图和教程视频的底片。

    DEMO_FRAMES_DIR=/绝对路径/frames DEMO_PART=basics macos/run-tests.sh --filter DemoFrames 600    # 一段一段录，段名见 DemoFramesTests
    uv run scripts/make-demo.py /绝对路径/frames docs/screenshots [只做这几段…] [--no-pointer]

每一段（<帧目录>/<段名>/）出（都带指针：走到要点的控件上，点的时候有一圈涟漪）：
  <段>/screen.mp4               这一段的底片（截图的原始像素，最多 2880 宽）、30 帧；等 AI 的部分照时间线快进
  <段>/screen.json              每条字幕在底片里的起止时间（秒）、镜头对着哪几栏、点击的时刻、快进的几段，
                                以及 samples：每个时刻光标在哪、关键元素在哪（--no-pointer 时底片不画指针，由合成自己画）
basics 一段另出 README 的两张动图：
  <输出目录>/demo-write.webp    写：左边打字，中间的卡片跟着排（README 开头）
  <输出目录>/demo-themes.webp   排：换主题

画面是时间的函数：每一帧由时间线算出来，同样的输入出同样的结果。动图用动态 WebP（全彩、有帧间压缩），宽 1600。
"""
from __future__ import annotations

import json
import subprocess
import sys
from pathlib import Path

from PIL import Image, ImageDraw

WEBP_WIDTH = 1600
VIDEO_WIDTH = 2880  # 底片最多这么宽：教程视频里镜头推近 1.5 倍还是清楚的
FPS = 30
MOVE = 0.55  # 指针走到下一个控件最多用这么久
RIPPLE = 0.24  # 点一下的涟漪
END_HOLD = 3.0  # 一段放完以后多停这么久
STILL = 0.5  # 快进时一个不动的画面最多停这么久

# macOS 的箭头指针（尖在 0,0），单位是页面像素
ARROW = [(0, 0), (0, 17), (4, 13.2), (6.8, 19.6), (9.4, 18.5), (6.7, 12.2), (12, 12.2)]


def ease(t: float) -> float:
    return 1 - (1 - t) ** 3


def draw_pointer(image: Image.Image, at: tuple[float, float], scale: float, ripple: float | None) -> Image.Image:
    """在一帧上画指针；ripple 是 0–1 的涟漪进度（None 不画）。4 倍超采样，边缘不毛。"""
    x, y = at[0] * scale, at[1] * scale
    size = int(64 * scale)
    over = 4
    layer = Image.new("RGBA", (size * over, size * over), (0, 0, 0, 0))
    draw = ImageDraw.Draw(layer)
    origin = size * over / 2
    unit = scale * over * 1.25
    if ripple is not None:
        radius = (6 + 16 * ease(ripple)) * scale * over
        alpha = int(150 * (1 - ripple))
        draw.ellipse([origin - radius, origin - radius, origin + radius, origin + radius], fill=(20, 110, 255, alpha // 3), outline=(20, 110, 255, alpha), width=int(2 * scale * over))
    points = [(origin + px * unit, origin + py * unit) for px, py in ARROW]
    shadow = [(px + 1.2 * unit, py + 1.6 * unit) for px, py in points]
    draw.polygon(shadow, fill=(0, 0, 0, 60))
    draw.polygon(points, fill=(20, 20, 22, 255))
    draw.line(points + [points[0]], fill=(255, 255, 255, 255), width=max(2, int(1.5 * unit)), joint="curve")
    layer = layer.resize((size, size), Image.Resampling.LANCZOS)
    out = image.convert("RGBA")
    out.alpha_composite(layer, (int(x - size / 2), int(y - size / 2)))
    return out.convert("RGB")


class Timeline:
    def __init__(self, directory: Path):
        data = json.loads((directory / "timeline.json").read_text())
        self.directory = directory
        self.page = (data["width"], data["height"])
        self.frames = data["frames"]
        self.regions = data.get("regions", {})
        # 等 AI 的那些帧快进：停留的时间除以倍数
        for frame in self.frames:
            frame["fast"] = frame.get("speed", 1) > 1
            frame["hold"] = frame["hold"] / frame.get("speed", 1)
            # 快进的时候画面一直没变（Agent 在想）：这一帧最多停 STILL 秒
            if frame["fast"]:
                frame["hold"] = min(frame["hold"], STILL)
        self._cache: dict[str, Image.Image] = {}
        # 每一帧开始时指针在哪（上一帧走到的地方）；一直没有指针的段落不画
        position = None
        for frame in self.frames:
            frame["from"] = position
            if frame.get("cursor"):
                position = tuple(frame["cursor"])
            frame["to"] = position

    def image(self, name: str) -> Image.Image:
        if name not in self._cache:
            if len(self._cache) > 8:
                self._cache.pop(next(iter(self._cache)))
            self._cache[name] = Image.open(self.directory / name).convert("RGB")
        return self._cache[name]

    def chapter(self, name: str) -> list[dict]:
        return [frame for frame in self.frames if frame["chapter"] == name]

    def states(self, frames: list[dict], step: float, tail: float = 0.0, jump: bool = True):
        """把几帧展开成一串（图片名, 指针位置或 None, 涟漪进度或 None, 停多久）。step 是指针在动时的帧间隔；
        jump 为真时这是一段的开头，指针直接出现在要去的地方附近。"""
        for index, frame in enumerate(frames):
            hold = frame["hold"] + (tail if index == len(frames) - 1 else 0)
            start, end = frame["from"], frame["to"]
            moving = start is not None and end is not None and start != end
            # 一段的第一帧：指针直接出现在要去的地方附近，不从上一段的位置飞过来
            if jump and index == 0 and end is not None and start is not None and start != end:
                start = (end[0] - 60, end[1] + 46)
            move = min(MOVE, hold * 0.6) if moving else 0.0
            ripple = RIPPLE if frame.get("click") and end is not None else 0.0
            ripple = min(ripple, max(0.0, hold - move))
            elapsed = 0.0
            while elapsed < move - 1e-6:
                progress = ease(min(1.0, (elapsed + step) / move))
                at = (start[0] + (end[0] - start[0]) * progress, start[1] + (end[1] - start[1]) * progress)
                yield frame["file"], at, None, min(step, move - elapsed)
                elapsed += step
            rest = hold - move - ripple
            if rest > 1e-6:
                yield frame["file"], end, None, rest
            elapsed = 0.0
            while elapsed < ripple - 1e-6:
                yield frame["file"], end, min(1.0, (elapsed + step) / ripple), min(step, ripple - elapsed)
                elapsed += step

    def render(self, state, size: tuple[int, int], pointer: bool = True) -> Image.Image:
        name, at, ripple, _ = state
        image = self.image(name)
        scale = image.width / self.page[0]
        if pointer and at is not None:
            image = draw_pointer(image, at, scale, ripple)
        return image.resize(size, Image.Resampling.LANCZOS) if image.size != size else image


def make_webp(timeline: Timeline, chapter: str, target: Path, quality: int = 72) -> None:
    frames = timeline.chapter(chapter)
    if not frames:
        raise SystemExit(f"时间线里没有「{chapter}」这一段")
    first = timeline.image(frames[0]["file"])
    size = (WEBP_WIDTH, round(WEBP_WIDTH * first.height / first.width))
    images, durations = [], []
    for state in timeline.states(frames, step=0.05, tail=END_HOLD):
        image = timeline.render(state, size)
        duration = round(state[3] * 1000)
        # 和上一帧一模一样的画面并成一帧，停得久一点
        if images and image.tobytes() == images[-1].tobytes():
            durations[-1] += duration
        else:
            images.append(image)
            durations.append(duration)
    target.parent.mkdir(parents=True, exist_ok=True)
    images[0].save(target, "WEBP", save_all=True, append_images=images[1:], duration=durations, loop=0, quality=quality, method=6, minimize_size=True)
    print(f"{target}  {len(images)} 帧  {sum(durations) / 1000:.1f} 秒  {target.stat().st_size / 1e6:.2f} MB")


def make_video(timeline: Timeline, target: Path, pointer: bool = True) -> None:
    """整段底片：每 1/30 秒一帧，经管道交给 ffmpeg。顺便记下每一段、每条字幕的起止时间。"""
    first = timeline.image(timeline.frames[0]["file"])
    width = min(VIDEO_WIDTH, first.width) // 2 * 2
    size = (width, round(width * first.height / first.width) // 2 * 2)
    command = [
        "ffmpeg", "-y", "-loglevel", "error", "-f", "rawvideo", "-pix_fmt", "rgb24", "-s", f"{size[0]}x{size[1]}", "-r", str(FPS), "-i", "-",
        "-c:v", "libx264", "-crf", "16", "-preset", "slow", "-pix_fmt", "yuv420p", "-movflags", "+faststart", str(target),
    ]
    encoder = subprocess.Popen(command, stdin=subprocess.PIPE)
    marks: list[dict] = []
    clicks: list[dict] = []
    fast: list[dict] = []  # 快进的几段
    samples: list[dict] = []  # 画面里光标和关键元素在什么时候到哪（页面坐标）；合成时自己画光标、拎面板用
    clock = 0.0  # 时间线上的时间
    written = 0  # 已经写出的帧数
    for index, frame in enumerate(timeline.frames):
        key = (frame["chapter"], frame["caption"], frame.get("view", "full"))
        if not marks or (marks[-1]["chapter"], marks[-1]["caption"], marks[-1]["view"]) != key:
            marks.append({"chapter": key[0], "caption": key[1], "view": key[2], "start": round(written / FPS, 3)})
        before = written
        # 一帧一帧展开：中间的帧接着上一帧的指针位置走，不跳
        for state in timeline.states([frame], step=1 / FPS, tail=END_HOLD if index == len(timeline.frames) - 1 else 0, jump=index == 0):
            clock += state[3]
            count = round(clock * FPS) - written
            if count <= 0:
                continue
            data = timeline.render(state, size, pointer).tobytes()
            sample = {"t": round(written / FPS, 3), "file": state[0], "cursor": list(state[1]) if state[1] else None, "rects": frame.get("rects"), "press": state[2] is not None}
            if not samples or {k: v for k, v in samples[-1].items() if k != "t"} != {k: v for k, v in sample.items() if k != "t"}:
                samples.append(sample)
            for _ in range(count):
                encoder.stdin.write(data)
            written += count
        marks[-1]["end"] = round(written / FPS, 3)
        if frame["fast"] and written > before:
            if fast and abs(fast[-1]["end"] - before / FPS) < 0.002 and fast[-1]["speed"] == frame["speed"]:
                fast[-1]["end"] = round(written / FPS, 3)
            else:
                fast.append({"start": round(before / FPS, 3), "end": round(written / FPS, 3), "speed": frame["speed"]})
        if frame.get("click") and frame["to"] is not None:
            clicks.append({"t": round(written / FPS - RIPPLE, 3), "chapter": frame["chapter"], "at": list(frame["to"])})
    encoder.stdin.close()
    if encoder.wait() != 0:
        raise SystemExit("ffmpeg 没能合成底片")
    target.with_suffix(".json").write_text(json.dumps({"fps": FPS, "duration": round(written / FPS, 3), "page": list(timeline.page), "regions": timeline.regions, "marks": marks, "clicks": clicks, "fast": fast, "samples": samples, "pointer": pointer}, ensure_ascii=False, indent=2))
    print(f"{target}  {size[0]}x{size[1]}  {written} 帧  {written / FPS:.1f} 秒  {target.stat().st_size / 1e6:.2f} MB")


def main() -> None:
    if len(sys.argv) < 3:
        raise SystemExit(__doc__)
    root, output = Path(sys.argv[1]), Path(sys.argv[2])
    only = [name for name in sys.argv[3:] if not name.startswith("--")]
    pointer = "--no-pointer" not in sys.argv
    for part in sorted(path.parent for path in root.glob("*/timeline.json")):
        if only and part.name not in only:
            continue
        timeline = Timeline(part)
        if part.name == "basics":
            make_webp(timeline, "write", output / "demo-write.webp")
            make_webp(timeline, "themes", output / "demo-themes.webp")
        make_video(timeline, part / "screen.mp4", pointer)


if __name__ == "__main__":
    main()
