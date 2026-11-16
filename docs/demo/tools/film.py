# /// script
# requires-python = ">=3.11"
# dependencies = ["pillow"]
# ///
"""主视频「你写，Agent 排」：把录到的帧合成一条 HyperFrames 片子。在 docs/demo 里运行：

    uv run tools/film.py <帧目录> [--partial]     # 读 <帧目录>/collab 与 <帧目录>/agent，写 index.html、cues.json、assets/
    uv run tools/sound.py . 96                    # 配乐与点击声（assets/track.wav）
    npx hyperframes@0.9.55 check --json && npx hyperframes@0.9.55 render

帧是 `DemoFramesTests` 的 collab（App 里的 Agent）和 agent（终端里的 Agent 经 MCP）两段录的：每一帧带着「段 + 步」、
指针位置和几样东西在页面上的位置。分镜见 SPEC.md；每个镜头的长度按 96 BPM 的拍子算，点击落在拍子上。
--partial：素材只录到一半时，录到哪合成到哪（看前面的镜头用）。
"""
import json
import re
import shutil
import subprocess
import sys
from pathlib import Path

from PIL import Image

from filmkit import FPS, FULL, PAGE_W, Film, frame

TOOLS = Path(__file__).resolve().parent
HERE = TOOLS.parent
REPO = HERE.parent.parent
ASSETS = HERE / "assets"
SOURCE = Path(sys.argv[1]).resolve()
PARTIAL = "--partial" in sys.argv
BEAT = 60 / 96


def at(beats):
    """第几拍 → 秒（取到整帧）。分镜里的拍号是初稿的；后来给开头两句说明各多留了两拍（来得及读），从第 12、16 拍起顺延。"""
    beats += 0 if beats < 12 else 2 if beats < 16 else 4
    return round(beats * BEAT * FPS) / FPS


class Take:
    """录到的一段：帧、每帧的步骤名、指针和被跟踪的元素。"""

    def __init__(self, name):
        self.name, self.dir = name, SOURCE / name
        data = json.loads((self.dir / "timeline.json").read_text())
        self.frames, self.draft = data["frames"], data.get("draft") or {}

    def find(self, chapter, step=None):
        return [index for index, entry in enumerate(self.frames) if entry["chapter"] == chapter and (step is None or entry.get("step") == step)]

    def one(self, chapter, step, which=0):
        return self.find(chapter, step)[which]

    def rect(self, index, name):
        return self.frames[index].get("rects", {}).get(name)

    def near(self, index, name):
        """这一帧没有就找前面最近的，再不行找后面的。"""
        for other in list(range(index, -1, -1)) + list(range(index + 1, len(self.frames))):
            if self.rect(other, name):
                return self.rect(other, name)
        return None

    def cursor(self, index):
        return tuple(self.frames[index]["cursor"])

    def crop(self, index, box, name, width=None):
        image = Image.open(self.dir / self.frames[index]["file"]).convert("RGB")
        scale = image.width / PAGE_W
        piece = image.crop((round(box[0] * scale), round(box[1] * scale), round((box[0] + box[2]) * scale), round((box[1] + box[3]) * scale)))
        if width:
            piece = piece.resize((width, round(piece.height * width / piece.width)), Image.Resampling.LANCZOS)
        piece.save(ASSETS / name, quality=92)
        return f"assets/{name}"


ASSETS.mkdir(exist_ok=True)
collab = Take("collab")
agent = Take("agent") if (SOURCE / "agent" / "timeline.json").exists() else None

TOTAL = 130  # 拍
film = Film(at(TOTAL))
screen = [(collab, 0)] * film.count  # 每一帧画面上放的是哪一段的第几帧


def show(t, take, index):
    for position in range(min(frame(t), film.count), film.count):
        screen[position] = (take, index)


def run(t0, t1, take, indices):
    """把一串帧铺进 t0–t1：每帧占的长度照录制时的比例。返回这一串真实花了几秒。"""
    first, count = frame(t0), max(1, frame(t1) - frame(t0))
    weights = [max(0.02, take.frames[index]["hold"] / take.frames[index].get("speed", 1)) for index in indices]
    total, edges, running = sum(weights), [], 0.0
    for weight in weights:
        running += weight
        edges.append(running)
    cursor = 0
    for offset in range(count):
        position = (offset + 0.5) / count * total
        while cursor < len(indices) - 1 and edges[cursor] < position:
            cursor += 1
        screen[first + offset] = (take, indices[cursor])
    show(t1, take, indices[-1])
    stamps = [take.frames[index].get("at") for index in indices]
    return stamps[-1] - stamps[0] if None not in stamps else sum(take.frames[index]["hold"] for index in indices)


def region(name, pad=0, grow=(0, 0, 0, 0)):
    """镜头对着被跟踪的那样东西（每帧现查）；grow：左、上、右、下各多带多少。"""
    def box(index):
        take, source = screen[index]
        found = take.near(source, name) or FULL
        return (found[0] - pad - grow[0], found[1] - pad - grow[1], found[2] + 2 * pad + grow[0] + grow[2], found[3] + 2 * pad + grow[1] + grow[3])
    return box


def around(name, width, height, shift=(0, 0)):
    """以那样东西为中心、固定大小的一块。"""
    def box(index):
        take, source = screen[index]
        found = take.near(source, name) or FULL
        return (found[0] + found[2] / 2 - width / 2 + shift[0], found[1] + found[3] / 2 - height / 2 + shift[1], width, height)
    return box


WORK = (128, 28, 1664, 936)    # 一块面板时的位置：下面留一条给说明
LEFT = (128, 28, 880, 936)     # 两块面板：左边看卡片
RIGHT = (1032, 28, 760, 936)   # 右边看会话
A = film.pane("a", z=5)
B = film.pane("b", z=6)
cursor = film.cursor


def column(index, name, tall_for=None):
    """右边面板看的一竖条：和面板一样的比例，宽度取会话那一栏。返回 (x, 宽, 高)。"""
    take, source = screen[index]
    x, _, w, _ = take.near(source, "thread") or (1112, 250, 316, 400)
    return x - 8, w + 16, (w + 16) * RIGHT[3] / RIGHT[2]


def thread_view(index):
    """会话：刚发出去时从用户那句看起；内容多了、那句滚上去以后，看最新的那一段。"""
    take, source = screen[index]
    x, w, tall = column(index, "thread")
    _, top, _, height = take.near(source, "thread") or (1112, 250, 316, 400)
    bubble = take.rect(source, "bubble")
    if bubble and bubble[1] >= top and bubble[1] - 40 + tall <= top + height + 60:
        return (x, bubble[1] - 40, w, tall)
    return (x, top + height - tall + 10, w, tall)


def composer_view(index):
    """对话框：底边对着输入框的底边。"""
    take, source = screen[index]
    x, w, tall = column(index, "thread")
    box = take.near(source, "composer") or (1112, 690, 316, 100)
    return (x, box[1] + box[3] - tall + 14, w, tall)


def beside(name, lift=0.5):
    """右边面板里以某样东西为中心的一竖条。"""
    def box(index):
        take, source = screen[index]
        x, w, tall = column(index, "thread")
        found = take.near(source, name) or (1112, 400, 316, 60)
        return (x, found[1] + found[3] / 2 - tall * lift, w, tall)
    return box


def candidate_view(index):
    """配图候选：下一张能点的那张在会话里看得见时对着它，滚出去了就看会话最新的那一段。"""
    take, source = screen[index]
    found, thread = take.rect(source, "candidate"), take.near(source, "thread") or (1112, 250, 316, 400)
    if found and thread[1] - 20 <= found[1] and found[1] + found[3] <= thread[1] + thread[3] + 20:
        return beside("candidate")(index)
    return thread_view(index)


EDITOR = (0, 100, 500, 532)  # 左边面板看编辑器时的那一块


def split(beat, now, zmax_now, look_a, look_b, zoom_a=1.7, zoom_b=2.7):
    """一块面板分成两块：右边那块先和整块叠在一起，再各走各的。"""
    t = at(beat)
    B.place(t, WORK, o=1).look(t, now, zmax=zmax_now, snap=True)
    B.place(t, RIGHT, 0.7).look(t + 0.04, look_b, zmax=zoom_b)
    A.place(t, LEFT, 0.7).look(t, look_a, zmax=zoom_a)


def merge(beat, look, zmax):
    """两块并回一块：都去同一个位置、看同一块，叠上以后收掉右边那块。"""
    t = at(beat)
    A.place(t, WORK, 0.7).look(t, look, zmax=zmax)
    B.place(t, WORK, 0.7).look(t, look, zmax=zmax)
    B.place(t + 1.0, o=0)


def caption(beat, words, until):
    node = film.text(words, 128, 1022, "cap", ay=0.5)
    node.rise(at(beat))
    node.out(at(until) - 0.3)
    return node


def fast(beat, until, real):
    """快进的角标：倍数是真实的（录制时每帧记了时刻）。"""
    times = max(2, round(real / (at(until) - at(beat))))
    node = film.text(f"快进 ×{times}", 1792, 1022, "fast", ax=1, ay=0.5)
    node.o.to(at(beat), 0.15, 1, "linear")
    node.o.to(at(until), 0.2, 0, "linear")


def press(t, pane, point, travel=0.55):
    """光标走过去，在 t 这一刻点下。"""
    cursor.go(t - 0.12, pane, point, travel)
    cursor.click(t)


def click_frames(t, pane, take, chapter, step, travel=0.55):
    """录的时候点一下是两帧：点之前（带指针）、点之后。光标在 t 点下，下一帧出结果。"""
    before, after = take.find(chapter, step)[:2]
    if pane == "auto":  # 两块面板时：点在检查器那一栏就是右边那块，否则是左边
        pane = B if take.cursor(before)[0] >= (take.near(before, "inspector") or (1100,))[0] else A
    press(t, pane, take.cursor(before), travel)
    show(t + 1 / FPS, take, after)
    return before, after


sections = []


def section(build):
    sections.append(build)
    return build


# ===== 0–8 拍：写完了，还要排版、配图、分页 =====
@section
def hook():
    raw = collab.one("hook", "raw")
    show(0, collab, raw)
    A.place(0, (300, 372, 1720, 968), r=16, ry=-9, rx=5, o=1).look(0, (0, 30, 1150, 647), snap=True)
    film.text("写完了。", 110, 84, "h1").show(0).out(at(8) - 0.12, dx=-90, dy=0)
    x = 110
    for index, words in enumerate(["还要排版、", "配图、", "分页。"]):
        film.text(words, x, 236, "h2").stamp(at(2 + index)).out(at(8) - 0.12 + 0.03 * (index + 1), dx=-90, dy=0)
        x += 96 * len(words)
    collab.crop(raw, collab.near(raw, "page"), "before.jpg")


# ===== 8–12 拍：没排过的样子 =====
@section
def tension():
    A.place(at(8), WORK, 0.75, r=18, ry=0, rx=0)
    A.look(at(8), FULL)
    A.look(at(8.8), region("page", pad=36), zmax=1.55)
    caption(8.8, "没排过版的样子：一整页的字。", 12)
    cursor.go(at(9.6), None, (2040, 1180), 0.01)
    cursor.show(at(9.7))
    click_frames(at(11), A, collab, "hook", "next", travel=0.8)


# ===== 12–16 拍：Vibepost，你写字，Agent 排版 =====
@section
def reveal():
    A.look(at(12), FULL)
    caption(12.2, 'Vibepost：你写字，<span class="ul">Agent</span> 排版。', 16).cls += " brand"
    click_frames(at(14), A, collab, "ask", "open", travel=0.7)
    # 从这里起分成两块：左边是你的卡片，右边是和 Agent 的对话
    split(14.6, FULL, 9.0, region("page", pad=30), composer_view)


# ===== 16–26 拍：说一句 =====
@section
def ask():
    caption(16.2, "说一句你要什么。", 26)
    run(at(16), at(21), collab, collab.find("ask", "type"))
    show(at(21), collab, collab.one("ask", "typed"))
    click_frames(at(23), B, collab, "ask", "send")
    B.look(at(23.2), thread_view, zmax=2.7)


# ===== 26–40 拍：Agent 动手 =====
@section
def work():
    real = run(at(26.4), at(37), collab, collab.find("work", "wait"))
    show(at(37), collab, collab.one("work", "done"))
    caption(26.3, "Agent 换主题、分页、套组件，还生成了配图。", 40)
    fast(26.4, 37, real)


# ===== 40–48 拍：你点头 =====
@section
def review():
    show(at(40), collab, collab.one("review", "marks"))
    A.look(at(40), EDITOR, zmax=2.0)  # 修改对比的那一条在编辑器顶上，逐处的标注在正文里
    caption(40.1, "改了哪里，逐处标给你看。", 44.5)
    caption(44.6, "你点头，才算数。", 48)
    click_frames(at(45.5), "auto", collab, "review", "accept", travel=0.7)


# ===== 48–60 拍：配图，点一张就放进那一页 =====
@section
def photos():
    A.look(at(48), region("page", pad=30), zmax=1.7)
    B.look(at(48), candidate_view, zmax=2.7)
    caption(48.3, "它生成的配图，点一张就放进那一页。", 60)
    picks = [number for number in (1, 2, 3) if collab.find("photos", f"pick-{number}")]
    flights = []
    for order, number in enumerate(picks):
        base = 48.6 + order * 3.6
        show(at(base), collab, collab.find("photos", f"caret-{number}")[-1])
        lead, result = collab.find("photos", f"pick-{number}")[:2]
        show(at(base + 0.8), collab, lead)
        moment = at(base + 2.2)
        press(moment, B, collab.cursor(lead), travel=0.6)
        landing = moment + 0.5
        show(landing, collab, result)
        photo = collab.near(result, "photo")
        source = collab.crop(result, photo, f"photo-{number}.jpg")
        flights.append((moment, landing, collab.near(lead, "candidate"), photo, source))
    show(at(59), collab, collab.one("photos", "placed"))
    return flights


# ===== 60–66 拍：同一篇，之前和现在 =====
@section
def wipe():
    caption(60.3, "同一篇稿子：左边是之前，右边是现在。", 66)
    return at(60.6), at(62.2), at(64.4), at(65.2)


# ===== 66–80 拍：让它写一套卡片样式 =====
@section
def style():
    show(at(66), collab, collab.one("style", "ask"))
    B.look(at(66), composer_view, zmax=2.7)
    caption(66.3, "还不够？让它给这篇写一套卡片样式。", 76)
    click_frames(at(68.5), B, collab, "style", "send")
    B.look(at(68.8), thread_view, zmax=2.7)
    real = run(at(69), at(73.6), collab, collab.find("style", "wait"))
    fast(69, 73.6, real)
    if collab.find("style", "accept"):
        show(at(73.6), collab, collab.one("style", "marks"))
        A.look(at(73.6), EDITOR, zmax=2.0)
        click_frames(at(75), "auto", collab, "style", "accept", travel=0.6)
    A.look(at(75.4), region("stage", pad=-6), zmax=1.6)
    B.look(at(75.6), thread_view, zmax=2.7)
    show(at(76), collab, collab.one("style", "first"))
    caption(76.2, "新样式下的每一页。", 80)
    flips = sorted({entry["step"] for entry in collab.frames if entry["chapter"] == "style" and entry.get("step", "").startswith("flip-")})
    for order, step in enumerate(flips[:3]):
        click_frames(at(77 + order), A, collab, "style", step, travel=0.5 if order == 0 else 0.2)


# ===== 80–88 拍：存成写作手册 =====
@section
def manual():
    menu, pick = collab.one("manual", "menu"), collab.find("manual", "pick")
    spot = collab.cursor(pick[0])
    view = (spot[0] - 400, spot[1] - 300, 760, 427.5)
    merge(80, view, 2.3)
    show(at(80), collab, menu)
    caption(80.3, "把这篇的写法存成写作手册，下次照着写。", 88)
    click_frames(at(82), A, collab, "manual", "pick", travel=0.7)
    waits = collab.find("manual", "wait")
    asked = [index for index in waits if collab.rect(index, "confirm")]
    clicks = [index for index in waits if collab.frames[index].get("click")]
    if asked and clicks:
        run(at(82.2), at(84), collab, [index for index in waits if index < asked[0]])
        show(at(84), collab, asked[0])
        A.look(at(84), (340, 191, 760, 427.5), zmax=2.2)  # 确认框在窗口正中
        press(at(86), A, collab.cursor(clicks[0]), travel=0.7)
        after = [index for index in waits if index > clicks[0]]
        show(at(86) + 1 / FPS, collab, after[0] if after else collab.one("manual", "done"))
        A.look(at(86.4), view, zmax=2.3)
    else:
        run(at(82.2), at(86.5), collab, waits)
    show(at(87), collab, collab.one("manual", "done"))


# ===== 88–102 拍：终端里的 Agent 也能连进来 =====
@section
def terminal():
    if not agent:
        raise IndexError("没有 agent 这一段")
    frames = agent.find("agent", "before") + agent.find("agent", "window")
    leave, enter = at(88), at(88.9)
    cursor.hide(leave - 0.1)
    cursor.go(leave + 0.3, None, (2040, 1180), 0.01)
    if B.o.at(leave) > 0:  # 前一段没并回一块时（素材不全）：右边那块直接收掉
        B.place(leave, o=0)
    A.place(leave, x=2000, duration=0.4, ease="in")
    show(leave + 0.45, agent, frames[0])
    side = (948, 28, 908, 936)
    A.place(leave + 0.45, (2000, 28, 908, 936)).look(leave + 0.45, region("stage", pad=-6), zmax=1.6, snap=True)
    A.place(enter, x=side[0], duration=0.6, ease="expo")
    caption(89.2, "终端里的 Agent 也能连进来（MCP）：建稿子、排版都行。", 102)
    real = run(at(90), at(98), agent, frames)
    show(at(98), agent, agent.one("agent", "done"))
    fast(90, 98, real)
    flips = sorted({entry["step"] for entry in agent.frames if entry.get("step", "").startswith("flip-")})
    if flips:
        cursor.go(at(98.2), None, (1500, 1180), 0.01)
        cursor.show(at(98.3))
    for order, step in enumerate(flips[:3]):
        click_frames(at(99 + order * 0.75), A, agent, "agent", step, travel=0.6 if order == 0 else 0.2)
    cursor.hide(at(101.5))
    # 终端里的每一行按真实的先后出现：录的时候每帧、每段输出都记了时刻
    marks = sorted({(agent.frames[source].get("at", 0.0), position / FPS) for position in range(frame(at(90)), frame(at(98))) for take, source in [screen[position]] if take is agent})
    return enter, marks


# ===== 102–116 拍：发到 iPhone =====
@section
def payoff():
    leave = at(101.6)
    A.place(leave, x=2000, duration=0.38, ease="in")
    show(leave + 0.42, collab, collab.one("send", "first"))
    stage = (-250, 130, 1480, 832.5)  # 窗口左边出画：卡片和「发送到 iPhone」都在画面里
    A.place(leave + 0.42, (-1800, stage[1], stage[2], stage[3])).look(leave + 0.42, FULL, snap=True)
    A.place(at(102.4), x=stage[0], duration=0.6, ease="expo")
    caption(102.6, "发送到 iPhone：卡片按页序隔空投送过去。", 116)
    cursor.go(at(103), None, (700, 1160), 0.01)
    cursor.show(at(103.1))
    click_frames(at(104.5), A, collab, "send", "send", travel=0.8)
    cursor.hide(at(105.6))
    return at(102.4), at(105)


# ===== 116–130 拍：你写字。Agent 排版。你点头。 =====
@section
def claim():
    A.place(at(116), x=-1800, duration=0.45, ease="in")
    A.place(at(117), o=0)
    for index, words in enumerate(["你写字。", 'Agent 排版。', "你点头。"]):
        film.text(words, 150, 236 + index * 168, "h1").stamp(at(116.6 + index)).out(at(122) - 0.1 + 0.03 * index, dx=-90, dy=0)


built = {}
for build in sections:
    try:
        built[build.__name__] = build()
    except IndexError as error:
        if not PARTIAL:
            raise
        print("这一段的素材还没有：", build.__name__, error)

# 镜头先算出来：下面飞的东西要知道面板里的东西此刻在画面上的位置
A.solve()
B.solve()


def on(pane, box):
    """页面上的一块，在某一帧落在画面上的位置（给飞的东西当起点、终点）。"""
    return lambda index: pane.box_to_film(index, box)


style_css = """
.h1 { font: 700 120px/1.1 var(--sans); letter-spacing: -.01em; }
.h2 { font: 700 96px/1.1 var(--sans); letter-spacing: -.01em; }
.cap { font: 500 44px/1.2 var(--sans); }
.cap.brand { font-weight: 700; font-size: 50px; }
.ul { box-shadow: inset 0 -.13em 0 var(--accent); }
.fast { font: 500 30px/1.2 var(--sans); color: var(--muted); }
.shot { border-radius: 12px; overflow: hidden; box-shadow: 0 18px 44px rgba(0, 0, 0, .28); }
.shot img { display: block; width: 100%; height: 100%; object-fit: cover; }
.flat { overflow: hidden; }
.flat img { display: block; width: 100%; height: 100%; object-fit: cover; }
.handle { width: 6px; background: #16171a; border-radius: 3px; box-shadow: 0 0 0 2px rgba(255, 255, 255, .9); }
.handle::after { content: ""; position: absolute; left: -21px; top: 50%; width: 48px; height: 48px; margin-top: -24px; border-radius: 50%; background: #16171a; box-shadow: 0 0 0 3px #fff, 0 6px 16px rgba(0, 0, 0, .3); }
.term { width: 860px; height: 936px; border-radius: 18px; background: #16171a; box-shadow: 0 24px 60px rgba(0, 0, 0, .22); overflow: hidden; white-space: normal; }
.term .bar { height: 56px; display: flex; align-items: center; gap: 10px; padding: 0 22px; background: #24262b; }
.term .bar i { width: 15px; height: 15px; border-radius: 50%; background: #5d6068; }
.term .bar span { margin-left: 14px; font: 500 28px/1 var(--sans); color: #b9bbc2; }
.term .view { position: absolute; left: 0; right: 0; top: 56px; bottom: 0; overflow: hidden; }
.term .scroll { padding: 22px 30px; }
.ln { font: 400 28px/44px var(--mono); color: #e9e9ec; white-space: pre; height: 44px; opacity: 0; }
.ln.dim { color: #9a9ca5; }
.ln.tool { color: #fff; font-weight: 700; }
.ln.gap { height: 18px; }
.phone { width: 440px; height: 900px; border-radius: 66px; background: #0d0d0f; box-shadow: 0 30px 70px rgba(0, 0, 0, .3), inset 0 0 0 3px #3a3b40; white-space: normal; }
.phone .glass { position: absolute; inset: 13px; border-radius: 54px; background: #fff; overflow: hidden; }
.phone .island { position: absolute; left: 50%; top: 16px; width: 118px; height: 34px; margin-left: -59px; border-radius: 17px; background: #0d0d0f; z-index: 3; }
.phone .strip { position: absolute; left: 19px; top: 84px; display: flex; gap: 19px; }
.phone .strip img { width: 376px; height: 501px; border-radius: 14px; object-fit: cover; opacity: 0; box-shadow: 0 0 0 1px rgba(0, 0, 0, .08); }
.phone .dots { position: absolute; left: 0; right: 0; top: 604px; display: flex; justify-content: center; gap: 9px; }
.phone .dots i { width: 9px; height: 9px; border-radius: 50%; background: #d3d4d9; }
.phone .dots i.on { background: #16171a; }
.phone .title { position: absolute; left: 24px; right: 24px; top: 634px; font: 700 30px/1.3 var(--sans); }
.phone .body { position: absolute; left: 24px; right: 24px; top: 722px; font: 400 28px/1.4 var(--sans); color: var(--muted); height: 118px; overflow: hidden; }
.card { border-radius: 14px; overflow: hidden; box-shadow: 0 18px 44px rgba(0, 0, 0, .28); }
.card img { display: block; width: 100%; height: 100%; object-fit: cover; }
.icon img { display: block; width: 232px; height: 232px; border-radius: 52px; box-shadow: 0 24px 60px -18px rgba(0, 0, 0, .35); }
.brandname { font: 700 132px/1 var(--sans); letter-spacing: -.01em; }
.sub { font: 500 44px/1.3 var(--sans); }
.url { font: 400 32px/1 var(--mono); color: var(--muted); }
"""
extra = []

# 配图：点下去那一刻，图从会话里飞进卡片
for moment, landing, start, end, source in built.get("photos") or []:
    node = film.node(f'<img src="{source}" alt="">', cls="shot", z=20, extra=(("w", 10), ("h", 10)))
    node.o.set(moment + 1 / FPS, 1)
    node.fly(moment + 1 / FPS, landing - moment - 1 / FPS, on(B, start), on(A, end), lift=60)
    node.o.set(landing, 0)

# 之前 / 现在：光标拖着一条线，线左边是没排过的那一页
if "wipe" in built:
    grab, opened, back, closed = built["wipe"]
    index = frame(opened)
    left, top, width, height = A.box_to_film(index, collab.near(screen[index][1], "page"))
    middle = top + height / 2
    cursor.go(grab, None, (left + 4, middle), 0.6)
    cursor.click(grab)
    cursor.go(opened, None, (left + width * 0.6, middle), opened - grab - 0.1)
    cursor.go(closed, None, (left + 4, middle), closed - back)
    before = film.node('<img src="assets/before.jpg" alt="">', left, top, cls="flat", z=18, extra=(("w", width), ("h", height), ("clip", 100)))
    handle = film.node("", left, top, cls="handle", z=19, extra=(("w", 6), ("h", height)))
    before.o.set(grab, 1).set(closed + 0.05, 0)
    handle.o.to(grab - 0.15, 0.15, 1, "linear").to(closed, 0.15, 0, "linear")
    for position in range(frame(grab), frame(closed) + 1):
        reach = min(max(cursor.position(position)[0], left + 4), left + width)
        handle.x.v[position] = reach - 3
        before.extra["clip"].v[position] = 100 * (1 - (reach - left) / width)

# 终端：Codex 的真实输出里，它说的话和它经 MCP 调的工具（它自己跑的本机命令不放）
if "terminal" in built:
    enter, marks = built["terminal"]

    def film_time(stamp):
        earlier = [(real, moment) for real, moment in marks if real <= stamp]
        later = [(real, moment) for real, moment in marks if real > stamp]
        if not earlier:
            return marks[0][1]
        if not later:
            return marks[-1][1]
        (r0, m0), (r1, m1) = earlier[-1], later[0]
        return m0 + (m1 - m0) * (stamp - r0) / max(1e-6, r1 - r0)

    def wrap(text, limit=46.0):
        """按显示宽度折行（中文一个字算 1.7 个英文字符宽），英文单词不从中间断开。"""
        rows, row, used = [], "", 0.0
        for token in re.findall(r"[A-Za-z0-9_./-]+|.", text):
            wide = sum(1.7 if ord(char) > 0x2E7F else 1.0 for char in token)
            if used + wide > limit and row:
                rows.append(row)
                row, used = "", 0.0
            row += token
            used += wide
        return rows + [row] if row else rows

    rows = [("dim", "$ codex exec \"用 mediacraft 这个 MCP 服务，", enter), ("dim", "    在 Vibepost 里新建一篇小红书图文……\"", enter), ("gap", "", enter)]
    speaking, pending = False, []
    for line in (SOURCE / "agent" / "agent-output.jsonl").read_text().splitlines():
        chunk = json.loads(line)
        for text in chunk["text"].splitlines():
            text = re.sub(r"\x1b\[[0-9;]*m", "", text).rstrip()
            tool = re.match(r"mcp: mediacraft/(\w+) started", text)
            if tool:
                rows.append(("tool", f"▸ mediacraft · {tool.group(1)}", film_time(chunk["t"])))
                speaking = False
            elif text == "codex":
                speaking = True
                rows.append(("gap", "", film_time(chunk["t"])))
            elif text in ("exec", "user", "tokens used") or text.startswith(("mcp:", "--------")):
                speaking = False
            elif speaking and text and not text.startswith(("```", ":::", "#", "[[", "- ", "|")) and len(rows) < 400:
                for piece in wrap(text.replace("**", "")):
                    rows.append(("", piece, film_time(chunk["t"])))
    # 说的话太长时只留开头两行
    shown, streak = [], 0
    for kind, text, moment in rows:
        streak = streak + 1 if kind == "" else 0
        if streak <= 2:
            shown.append((kind, text, moment))
        elif streak == 3:  # 后面还有：在留下的最后一行末尾标出来
            kept = shown[-1]
            shown[-1] = (kept[0], kept[1].rstrip("，。、；： ")[:-1] + "…", kept[2])
    rows = [row for row in shown if row[2] <= at(100.5)]
    escape = lambda text: text.replace("&", "&amp;").replace("<", "&lt;")
    html = '<div class="bar"><i></i><i></i><i></i><span>终端</span></div><div class="view"><div class="scroll">' \
        + "".join(f'<div class="ln {kind}">{escape(text)}</div>' for kind, text, _ in rows) + "</div></div>"
    term = film.node(html, -920, 28, ident="term", cls="term", z=7, extra=(("lines", 0), ("scroll", 0)))
    term.o.set(enter - 0.05, 1)
    term.move(enter, 0.6, x=64, ease="expo")
    heights = [18 if kind == "gap" else 44 for kind, _, _ in rows]
    for position in range(frame(enter), film.count):
        visible = sum(1 for _, _, moment in rows if moment <= position / FPS)
        term.extra["lines"].v[position] = visible
        term.extra["scroll"].v[position] = max(0, sum(heights[:visible]) + 44 - (936 - 56))
    smooth = term.extra["scroll"].v
    for position in range(1, film.count):  # 滚动跟得柔一点
        smooth[position] = smooth[position - 1] + (smooth[position] - smooth[position - 1]) * 0.35
    term.move(at(101.6), 0.38, x=-920, ease="in")
    term.o.set(at(101.6) + 0.4, 0)
    extra.append("""
  const term = items.find((item) => item.id === "term");
  if (term) {
    const lines = [...term.element.querySelectorAll(".ln")], scroll = term.element.querySelector(".scroll");
    hooks.push((index, value) => {
      const count = value(term.lines, index);
      lines.forEach((line, order) => { line.style.opacity = order < count ? 1 : 0; });
      scroll.style.transform = "translateY(" + -value(term.scroll, index) + "px)";
    });
  }""")

# 手机：卡片从舞台上一张张飞进去
if "payoff" in built:
    rise, sent = built["payoff"]
    cards = sorted((SOURCE / "collab" / "cards").glob("*.png"))[:5]
    names = []
    for order, file in enumerate(cards):
        image = Image.open(file).convert("RGB")
        image.resize((752, round(image.height * 752 / image.width)), Image.Resampling.LANCZOS).save(ASSETS / f"card-{order + 1}.jpg", quality=90)
        names.append(f"assets/card-{order + 1}.jpg")
    # 手机上卡片下面的字：稿子的标题（没填时用第一个标题行）和小红书正文（没写就空着）
    heading = next((line.lstrip("# ").strip() for line in (collab.draft.get("markdown") or "").splitlines() if line.startswith("#")), "")
    title = collab.draft.get("title") or heading
    body = (collab.draft.get("caption") or "").strip().replace("\n", " ")
    html = '<div class="glass"><div class="island"></div><div class="strip">' + "".join(f'<img src="{name}" alt="">' for name in names) + "</div>" \
        + '<div class="dots">' + "".join("<i></i>" for _ in names) + "</div>" \
        + f'<div class="title">{title}</div><div class="body">{body}</div></div>'
    phone = film.node(html, 1550, 1700, ident="phone", cls="phone", ax=0.5, ay=0.5, z=12, extra=(("landed", 0), ("strip", 0)))
    phone.o.set(rise - 0.05, 1)
    phone.move(rise, 0.7, y=512, ease="expo")
    slot = lambda index: (phone.x.v[index] - 220 + 13 + 19, phone.y.v[index] - 450 + 13 + 84, 376, 501)
    page = collab.near(collab.one("send", "send"), "page")
    step = 395  # 一张卡片加间距
    for order, name in enumerate(names):
        leave = sent + at(1.5) * order
        landing = leave + 0.6
        card = film.node(f'<img src="{name}" alt="">', cls="card", z=21, extra=(("w", 10), ("h", 10)))
        card.o.set(leave, 1)
        card.rot.set(leave, -5).to(leave, 0.6, 0, "out")
        card.fly(leave, 0.6, on(A, page), slot, lift=70)
        card.o.set(landing, 0)
        phone.extra["landed"].set(landing, order + 1)
        if order:
            phone.extra["strip"].to(landing - 0.4, 0.4, order * step, "inout")
        film.clicks.append(landing)
    last = sent + at(1.5) * (len(names) - 1) + 0.6
    if len(names) > 2:  # 回到带图的那一页停住
        phone.extra["strip"].to(last + at(1.5), 0.6, step, "inout")
    extra.append("""
  const phone = items.find((item) => item.id === "phone");
  if (phone) {
    const strip = phone.element.querySelector(".strip"), shots = [...strip.children], dots = [...phone.element.querySelectorAll(".dots i")];
    hooks.push((index, value) => {
      const landed = value(phone.landed, index), offset = value(phone.strip, index);
      shots.forEach((shot, order) => { shot.style.opacity = order < landed ? 1 : 0; });
      strip.style.transform = "translateX(" + -offset + "px)";
      dots.forEach((dot, order) => dot.classList.toggle("on", order === Math.round(offset / STEP)));
    });
  }""".replace("STEP", str(step)))

    # 片尾：手机收成图标
    if "claim" in built:
        phone.move(at(116), 0.6, x=1600)
        phone.move(at(122), 0.45, s=0.3, ease="in")
        phone.o.to(at(122) + 0.25, 0.2, 0, "linear")

if "claim" in built:
    shutil.copy(REPO / "brand" / "icon.png", ASSETS / "icon.png")
    icon = film.node('<img src="assets/icon.png" alt="">', 1600, 512, cls="icon", ax=0.5, ay=0.5, z=40)
    # 手机先在原地收成图标，图标再走到中间
    icon.s.set(0, 0.3)
    icon.o.to(at(122) + 0.2, 0.15, 1, "linear")
    icon.move(at(122) + 0.2, 0.45, s=1, ease="back")
    icon.move(at(122) + 0.6, 0.7, x=960, y=330)
    film.text("Vibepost", 960, 560, "brandname", ax=0.5, ay=0.5).stamp(at(123.4))
    film.text("用 Markdown 写小红书的桌面 App · macOS 与 Windows", 960, 690, "sub", ax=0.5, ay=0.5).rise(at(124.2))
    film.text("github.com/wuyoscar/Vibepost", 960, 790, "url", ax=0.5, ay=0.5).rise(at(124.8))

# ===== 录屏：按上面排好的每一帧合成一条视频 =====
listing, previous, length = [], None, 0
for position in range(film.count):
    take, index = screen[position]
    file = take.dir / take.frames[index]["file"]
    if file != previous and previous is not None:
        listing.append((previous, length))
        length = 0
    previous, length = file, length + 1
listing.append((previous, length))
concat = ASSETS / "screen.txt"
concat.write_text("".join(f"file '{file}'\nduration {length / FPS:.6f}\n" for file, length in listing) + f"file '{listing[-1][0]}'\n")
signature = concat.read_text()
stamp = ASSETS / "screen.signature"
if not (ASSETS / "screen.mp4").exists() or not stamp.exists() or stamp.read_text() != signature:
    subprocess.run(["ffmpeg", "-y", "-loglevel", "error", "-f", "concat", "-safe", "0", "-i", str(concat),
                    "-vf", f"fps={FPS},scale=2880:1620:flags=lanczos,format=yuv420p", "-c:v", "libx264", "-crf", "15", "-preset", "medium",
                    "-g", str(FPS), "-movflags", "+faststart", "-t", f"{film.duration:.3f}", str(ASSETS / "screen.mp4")], check=True)
    stamp.write_text(signature)

film.write(HERE, style=style_css, extra_script="\n".join(extra))
print(f"{film.duration:.2f} 秒，{len(listing)} 段画面，{len(film.clicks)} 次点击；镜头：", ", ".join(built))
