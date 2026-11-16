# /// script
# requires-python = ">=3.11"
# dependencies = []
# ///
"""照各段底片的时间表写出详细教程的合成（tutorial/index.html）和声音的时间点（tutorial/cues.json）。在 docs/demo 里运行：

    uv run tools/build.py /绝对路径/frames [只用这几段…]

<帧目录>/<段名>/ 里要有 scripts/make-demo.py 出的 screen.mp4 与 screen.json（段名见 DemoFramesTests；没录的段跳过）。
这里把各段底片、首帧、图标拷进 assets/，再写 index.html：一条暂停的 GSAP 时间线，各段底片首尾相接，
镜头照时间表里的 view 推近和平移，每一节一句字幕，等 AI 时快进的地方标出来，最后是片尾。分镜与数值见 SPEC.md。
"""
from __future__ import annotations

import html
import json
import shutil
import subprocess
import sys
from pathlib import Path

TOOLS = Path(__file__).resolve().parent
HERE = TOOLS.parent / "tutorial"  # 详细教程是 docs/demo/tutorial 这个 HyperFrames 项目
REPO = TOOLS.parent.parent.parent
W, H = 1920, 1080
ORDER = ["basics", "polish", "paste", "topic", "manuals", "agent"]  # 先讲基础功能，再讲使用场景
HOOK = 2.6  # 开场：首帧停这么久
TAIL = 1.6  # 每段底片最后多停的 3 秒（make-demo.py 的 END_HOLD）里砍掉这么多
END = 4.4  # 片尾
MOVE = 0.6  # 镜头推近 / 平移：18 帧
HOOK_LINE = "Vibepost：一篇小红书笔记，从写到发"
END_LINE = "用 Markdown 写小红书的桌面 App"
REPO_URL = "github.com/wuyoscar/Vibepost"

# 镜头对着哪几栏（横向从哪一栏到哪一栏）、竖向中心在页面高度的几分之几、最多放大多少；full 是全景
VIEWS = {
    "write": dict(span=("editor", "stage"), fy=0.46, most=1.34),
    "style": dict(span=("stage", "inspector"), fy=0.46, most=1.34),
}


def camera(view: str, page: list[float], regions: dict) -> list[float]:
    """一个机位：放大倍数和画面左上角的位移（transform-origin 在左上角）。"""
    shot = VIEWS.get(view)
    if not shot:
        return [1.0, 0.0, 0.0]
    unit = W / page[0]
    left, right = regions[shot["span"][0]], regions[shot["span"][1]]
    x0, x1 = left[0], right[0] + right[2]
    scale = min(shot["most"], page[0] / (x1 - x0))
    cx, cy = (x0 + x1) / 2 * unit, shot["fy"] * page[1] * unit
    x = min(0.0, max(W * (1 - scale), W / 2 - cx * scale))
    y = min(0.0, max(H * (1 - scale), H / 2 - cy * scale))
    return [round(scale, 4), round(x, 1), round(y, 1)]


def main() -> None:
    if len(sys.argv) < 2:
        raise SystemExit(__doc__)
    frames = Path(sys.argv[1])
    wanted = sys.argv[2:] or ORDER
    parts = [name for name in ORDER if name in wanted and (frames / name / "screen.json").exists()]
    if not parts:
        raise SystemExit(f"{frames} 里没有录好的段（要有 <段名>/screen.json）")
    assets = HERE / "assets"
    assets.mkdir(exist_ok=True)
    shutil.copyfile(REPO / "brand" / "icon.png", assets / "icon.png")

    e = html.escape
    clock = HOOK
    videos, captions, tags, shots, clicks = [], [], [], [(0.0, [1.0, 0.0, 0.0], False)], []
    for index, name in enumerate(parts):
        data = json.loads((frames / name / "screen.json").read_text())
        shutil.copyfile(frames / name / "screen.mp4", assets / f"{name}.mp4")
        length = round(data["duration"] - TAIL, 3)
        videos.append(dict(id=f"v-{name}", src=f"assets/{name}.mp4", start=round(clock, 3), duration=length))
        seen = None
        for number, mark in enumerate(data["marks"]):
            start = min(mark["start"], length)
            end = min(data["marks"][number + 1]["start"] if number + 1 < len(data["marks"]) else length, length)
            if end - start < 0.4:
                continue
            # 机位变了才动镜头；一段的开头直接切到它的第一个机位
            view = camera(mark["view"], data["page"], data["regions"])
            if view != seen:
                shots.append((round(clock + start, 3), view, seen is None and index > 0))
                seen = view
            if not captions or captions[-1]["text"] != mark["caption"] or captions[-1]["part"] != name:
                captions.append(dict(id=f"cap-{len(captions)}", part=name, text=mark["caption"], start=round(clock + start + 0.35, 3), end=round(clock + end, 3)))
            else:
                captions[-1]["end"] = round(clock + end, 3)
        for span in data.get("fast", []):
            start, end = min(span["start"], length), min(span["end"], length)
            if end - start >= 1.0:
                tags.append(dict(id=f"fast-{len(tags)}", text=f"快进 ×{span['speed']:g}", start=round(clock + start, 3), duration=round(end - start, 3)))
        clicks += [round(clock + click["t"], 3) for click in data["clicks"] if click["t"] < length]
        clock += length
    out = round(clock, 3)  # 底片放完、片尾开始
    total = round(out + END, 3)
    for caption in captions:
        caption["duration"] = round(caption["end"] - caption["start"], 3)
    # 第一个机位在开场结束时才推过去
    shots = [shot for index, shot in enumerate(shots) if index == 0 or shot[1] != shots[index - 1][1]]

    # 开场的静帧取自第一段底片的第一帧：和后面接上时一个像素都不差
    subprocess.run(["ffmpeg", "-y", "-loglevel", "error", "-i", str(assets / f"{parts[0]}.mp4"), "-frames:v", "1", "-q:v", "2", str(assets / "poster.jpg")], check=True)
    (HERE / "cues.json").write_text(json.dumps({"total": total, "clicks": clicks, "end": round(out + 0.55, 3)}, indent=1))

    video_html = "\n".join(
        f'<video id="{v["id"]}" class="clip shot" data-start="{v["start"]}" data-duration="{v["duration"]}" data-track-index="0" src="{v["src"]}" muted playsinline></video>'
        for v in videos
    )
    caption_html = "\n".join(
        f'<div class="cap clip" id="{c["id"]}" data-start="{c["start"]}" data-duration="{c["duration"]}" data-track-index="2"><span id="{c["id"]}-in">{e(c["text"])}</span></div>'
        for c in captions
    )
    tag_html = "\n".join(
        f'<div class="fast clip" id="{t["id"]}" data-start="{t["start"]}" data-duration="{t["duration"]}" data-track-index="3"><span>{e(t["text"])}</span></div>'
        for t in tags
    )
    brand = "".join(f'<span class="ec">{ch}</span>' for ch in "Vibepost")
    page_html = f'''<!doctype html>
<html lang="zh-CN">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width={W}, height={H}">
<script src="https://cdn.jsdelivr.net/npm/gsap@3.15.0/dist/gsap.min.js"></script>
<style>
@font-face {{ font-family: "PF"; src: local("PingFangSC-Regular"), local("PingFang SC"); font-weight: 400; }}
@font-face {{ font-family: "PF"; src: local("PingFangSC-Medium"); font-weight: 500; }}
@font-face {{ font-family: "PF"; src: local("PingFangSC-Semibold"); font-weight: 700; }}
:root {{ --ground: #f2f2f4; --ink: #16171a; --muted: #5d6068; --sans: "PF", sans-serif; --mono: "JetBrains Mono", monospace; }}
* {{ margin: 0; padding: 0; box-sizing: border-box; }}
html, body {{ width: {W}px; height: {H}px; overflow: hidden; background: var(--ground); }}
#root {{ width: {W}px; height: {H}px; position: relative; overflow: hidden; background: var(--ground); font-family: var(--sans); color: var(--ink); }}
#cam {{ position: absolute; left: 0; top: 0; width: {W}px; height: {H}px; }}
#poster, .shot {{ position: absolute; left: 0; top: 0; width: {W}px; height: {H}px; object-fit: contain; }}
.cap {{ position: absolute; left: 0; right: 0; bottom: 112px; height: 84px; text-align: center; }}
.cap span {{ display: inline-block; height: 84px; padding: 0 28px; border-radius: 12px; background: var(--ink); color: #fff; font: 700 44px/84px var(--sans); white-space: nowrap; box-shadow: 0 10px 30px rgba(0, 0, 0, .18); }}
#hook {{ height: 112px; bottom: 150px; }}
#hook span {{ height: 112px; padding: 0 38px; border-radius: 16px; font: 700 62px/112px var(--sans); }}
.fast {{ position: absolute; left: 0; right: 0; bottom: 208px; height: 52px; text-align: center; }}
.fast span {{ display: inline-block; height: 52px; padding: 0 18px; border-radius: 10px; background: var(--ink); color: #fff; font: 500 28px/52px var(--sans); white-space: nowrap; }}
#end {{ position: absolute; inset: 0; display: flex; flex-direction: column; align-items: center; justify-content: center; }}
#end-icon {{ width: 232px; height: 232px; border-radius: 52px; box-shadow: 0 24px 60px -18px rgba(0, 0, 0, .35); opacity: 0; }}
#end h1 {{ margin-top: 54px; font: 700 132px/1 var(--sans); letter-spacing: -.01em; }}
.ec {{ display: inline-block; opacity: 0; }}
#end-line {{ margin-top: 40px; font: 500 46px/1.3 var(--sans); color: var(--ink); opacity: 0; }}
#end-url {{ margin-top: 46px; font: 400 32px/1 var(--mono); color: var(--muted); opacity: 0; }}
</style>
</head>
<body>
<div id="root" data-composition-id="main" data-start="0" data-duration="{total}" data-width="{W}" data-height="{H}">
<div id="cam" data-layout-ignore>
<img id="poster" class="clip" data-start="0" data-duration="{HOOK}" data-track-index="0" src="assets/poster.jpg" alt="">
{video_html}
</div>
<div class="cap clip" id="hook" data-start="0" data-duration="{HOOK - 0.1}" data-track-index="2"><span id="hook-in">{e(HOOK_LINE)}</span></div>
{caption_html}
{tag_html}
<div id="end" class="clip" data-start="{out}" data-duration="{round(total - out, 3)}" data-track-index="4">
<img id="end-icon" src="assets/icon.png" alt="">
<h1>{brand}</h1>
<p id="end-line">{e(END_LINE)}</p>
<p id="end-url">{REPO_URL}</p>
</div>
<audio id="bed" class="clip" data-start="0" data-duration="{total}" data-track-index="5" src="assets/track.wav" data-volume="1"></audio>
</div>
<script>
const SHOTS = {json.dumps(shots)};
const CAPS = {json.dumps([c["id"] for c in captions])};
const OUT = {out}, TOTAL = {total};
const tl = gsap.timeline({{ paused: true }});
const ft = (sel, from, to, t) => tl.fromTo(sel, from, Object.assign({{ immediateRender: false }}, to), t);
const blurIn = (sel, t, d = 0.3) => ft(sel, {{ opacity: 0, filter: "blur(10px)" }}, {{ opacity: 1, filter: "blur(0px)", duration: d, ease: "power2.out" }}, t);

/* 镜头：机位变了才动，推近和平移是同一种走法；换段时直接切 */
gsap.set("#cam", {{ transformOrigin: "0 0", scale: 1, x: 0, y: 0, opacity: 1 }});
for (let i = 1; i < SHOTS.length; i++) {{
  const [, [s0, x0, y0]] = SHOTS[i - 1], [t, [s1, x1, y1], cut] = SHOTS[i];
  ft("#cam", {{ scale: s0, x: x0, y: y0 }}, {{ scale: s1, x: x1, y: y1, duration: cut ? 0.001 : {MOVE}, ease: cut ? "none" : "power3.inOut" }}, t);
}}

/* 字幕：墨色块从左到右擦出来，落定后不动；到点由下一句顶掉 */
for (const id of CAPS) {{
  const start = Number(document.getElementById(id).dataset.start);
  ft(`#${{id}}-in`, {{ clipPath: "inset(0 100% 0 0 round 12px)" }}, {{ clipPath: "inset(0 0% 0 0 round 12px)", duration: 0.27, ease: "power2.out" }}, start);
}}

/* 片尾：界面退后，图标落定，名字逐字出现 */
ft("#cam", {{ opacity: 1, filter: "blur(0px)" }}, {{ opacity: 0, filter: "blur(16px)", duration: 0.45, ease: "power2.in" }}, OUT - 0.45);
ft("#end-icon", {{ opacity: 0, scale: 0.84, filter: "blur(12px)" }}, {{ opacity: 1, scale: 1, filter: "blur(0px)", duration: 0.55, ease: "expo.out" }}, OUT + 0.1);
tl.fromTo(".ec", {{ opacity: 0, filter: "blur(10px)" }}, {{ opacity: 1, filter: "blur(0px)", duration: 0.22, ease: "power2.out", stagger: 0.05, immediateRender: false }}, OUT + 0.35);
blurIn("#end-line", OUT + 0.9);
blurIn("#end-url", OUT + 1.25);
tl.set({{}}, {{}}, TOTAL);
window.__timelines["main"] = tl;
tl.seek(0);
</script>
</body>
</html>
'''
    (HERE / "index.html").write_text(page_html)
    print(f"index.html  {total} 秒：{' + '.join(parts)}；{len(shots)} 个机位，{len(captions)} 句字幕，{len(tags)} 处快进，{len(clicks)} 次点击")


if __name__ == "__main__":
    main()
