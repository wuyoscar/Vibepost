"""主视频的合成工具。画面上每样东西（面板、面板里的镜头、光标、字、飞的图）在每一帧的位置都在这里算好，
页面（HyperFrames）里只有一条时钟补间，照着表把东西摆到位。这样任何一帧都能单独重出，改一个镜头不用碰页面脚本。

    film = Film(92)                           # 排的时候的秒数；放出来是 92 × FPS / PLAY 秒
    pane = film.pane("a")                     # 一块显示录屏的面板，有自己的镜头
    pane.place(0, (128, 28, 1664, 936))       # 面板在画面上的位置
    pane.look(4.0, region)                    # 从 4 秒起镜头对着哪块（页面坐标的矩形，或每帧给矩形的函数）
    film.cursor.go(5.0, pane, (640, 300))     # 光标 5 秒时到这个页面坐标
    film.cursor.click(5.0)
    text = film.text("写完了。", 110, 300, "h1")
    text.stamp(0)
    film.write(folder)                        # index.html + cues.json
"""
import json
import math
from pathlib import Path

FPS = 24   # 排的时候一秒算几帧
PLAY = 30  # 放的时候一秒几帧：每一帧都算、都放，所以整条片子（弹簧、光标、字的来去都在内）快 PLAY / FPS 倍
W, H = 1920, 1080
PAGE_W, PAGE_H = 1440, 810  # 录屏时页面的大小（CSS 像素）

EASES = {
    "linear": lambda u: u,
    "in": lambda u: u ** 3,
    "out": lambda u: 1 - (1 - u) ** 3,
    "inout": lambda u: 4 * u ** 3 if u < 0.5 else 1 - (-2 * u + 2) ** 3 / 2,
    "expo": lambda u: 1.0 if u >= 1 else 1 - 2 ** (-10 * u),
    "back": lambda u: 1 + 2.3 * (u - 1) ** 3 + 1.3 * (u - 1) ** 2,
}


def frame(t):
    return max(0, round(t * FPS))


class Chan:
    """一个随时间变的数。操作按时间先后调用：set / to 都把后面的值一并改掉。"""

    def __init__(self, count, value=0.0):
        self.v = [float(value)] * count

    def at(self, t):
        return self.v[min(len(self.v) - 1, frame(t))]

    def set(self, t, value):
        start = min(len(self.v), frame(t))
        self.v[start:] = [float(value)] * (len(self.v) - start)
        return self

    def to(self, t, duration, value, ease="inout"):
        first = min(len(self.v) - 1, frame(t))
        last = max(first + 1, frame(t + duration))
        origin, curve = self.v[first], EASES[ease]
        for index in range(first, len(self.v)):
            u = min(1.0, (index - first) / (last - first))
            self.v[index] = origin + (value - origin) * curve(u)
        return self

    def packed(self, digits=2):
        values = [round(value, digits) for value in self.v]
        while len(values) > 1 and values[-1] == values[-2]:
            values.pop()
        return values[0] if len(values) == 1 else values


class Node:
    """画面上的一样东西：一段 HTML，加上位置（锚点在 ax, ay）、缩放、旋转、透明度，还可以有自己的量（extra）。"""

    def __init__(self, film, ident, html, x=0, y=0, ax=0, ay=0, cls="", z=10, clip=False, extra=()):
        self.film, self.id, self.html, self.ax, self.ay, self.cls, self.z, self.clip = film, ident, html, ax, ay, cls, z, clip
        self.x, self.y = film.chan(x), film.chan(y)
        self.s, self.rot, self.o = film.chan(1), film.chan(0), film.chan(0)
        self.extra = {name: film.chan(value) for name, value in extra}

    def show(self, t, duration=0.0, ease="out"):
        self.o.to(t, duration, 1, ease) if duration else self.o.set(t, 1)
        return self

    def hide(self, t, duration=0.0, ease="in"):
        self.o.to(t, duration, 0, ease) if duration else self.o.set(t, 0)
        return self

    def move(self, t, duration, x=None, y=None, s=None, rot=None, ease="inout"):
        for chan, value in ((self.x, x), (self.y, y), (self.s, s), (self.rot, rot)):
            if value is not None:
                chan.to(t, duration, value, ease) if duration else chan.set(t, value)
        return self

    # 字的几种来法、去法
    def stamp(self, t):
        """压进来：两帧内出现，从 1.08 倍落到 1 倍。"""
        self.o.to(t, 0.07, 1, "linear")
        self.s.set(t, 1.08).to(t, 0.42, 1, "expo")
        return self

    def rise(self, t, distance=22):
        base = self.y.at(t)
        self.o.to(t, 0.18, 1, "linear")
        self.y.set(t, base + distance).to(t, 0.5, base, "expo")
        return self

    def out(self, t, dx=0, dy=-16, duration=0.28):
        self.o.to(t, duration, 0, "in")
        if dx:
            self.x.to(t, duration, self.x.at(t) + dx, "in")
        if dy:
            self.y.to(t, duration, self.y.at(t) + dy, "in")
        return self

    def fly(self, t, duration, start, end, ease="inout", lift=0.0):
        """从 start(帧) 飞到 end(帧)：两头都是每帧给 (x, y, w, h) 的函数；lift 是路上往上拱多少像素。要有 w、h 两个量。"""
        first, last = frame(t), frame(t + duration)
        for index in range(first, min(last, self.film.count - 1) + 1):
            u = EASES[ease]((index - first) / max(1, last - first))
            a, b = start(index), end(index)
            box = [a[k] + (b[k] - a[k]) * u for k in range(4)]
            self.x.v[index], self.y.v[index] = box[0], box[1] - lift * math.sin(math.pi * u)
            self.extra["w"].v[index], self.extra["h"].v[index] = box[2], box[3]
        for chan, value in ((self.x, self.x.v[min(last, self.film.count - 1)]), (self.y, self.y.v[min(last, self.film.count - 1)]),
                            (self.extra["w"], self.extra["w"].v[min(last, self.film.count - 1)]), (self.extra["h"], self.extra["h"].v[min(last, self.film.count - 1)])):
            chan.set((min(last, self.film.count - 1)) / FPS, value)
        return self

    def span(self):
        """看得见的那一段（秒）：给 HyperFrames 的 data-start / data-duration。"""
        visible = [index for index, value in enumerate(self.o.v) if value > 0.001]
        if not visible:
            return None
        return max(0, visible[0] - 1) / PLAY, (visible[-1] + 2 - max(0, visible[0] - 1)) / PLAY

    def data(self):
        out = {"id": self.id, "kind": "node", "ax": self.ax, "ay": self.ay, "x": self.x.packed(), "y": self.y.packed(),
               "s": self.s.packed(4), "rot": self.rot.packed(), "o": self.o.packed(3)}
        out.update({name: chan.packed(3) for name, chan in self.extra.items()})
        return out


class Pane:
    """一块显示录屏的面板：在画面上有位置和大小，里面的镜头对着页面上的一块，用弹簧追。"""

    def __init__(self, film, ident, z=5):
        self.film, self.id, self.z = film, ident, z
        self.x, self.y, self.w, self.h = film.chan(0), film.chan(0), film.chan(W), film.chan(H)
        self.r, self.ry, self.rx, self.o = film.chan(18), film.chan(0), film.chan(0), film.chan(0)
        self.looks = []  # (帧, 区域, 最大倍数, 是否直接跳过去)
        self.cx, self.cy, self.zoom = film.chan(), film.chan(), film.chan(1)

    def place(self, t, box=None, duration=0.0, ease="inout", **more):
        values = dict(zip("xywh", box)) if box else {}
        values.update(more)
        for name, value in values.items():
            chan = getattr(self, name)
            chan.to(t, duration, value, ease) if duration else chan.set(t, value)
        return self

    def look(self, t, region, zmax=2.4, snap=False):
        self.looks.append((frame(t), region, zmax, snap))
        return self

    def target(self, index):
        """这一帧镜头想去的地方：(中心 x, 中心 y, 倍数)。"""
        region, zmax = FULL, 9.0
        for start, candidate, limit, _ in self.looks:
            if start <= index:
                region, zmax = candidate, limit
        x, y, w, h = region(index) if callable(region) else region  # type: ignore[misc]
        pw, ph = self.w.v[index], self.h.v[index]
        zoom = min(pw / max(w, 1), ph / max(h, 1), zmax)
        return x + w / 2, y + h / 2, zoom

    def solve(self):
        count = self.film.count
        snaps = {start for start, _, _, snap in self.looks if snap}
        cx, cy, zoom = self.target(0)
        state, speed = [cx, cy, math.log(zoom)], [0.0, 0.0, 0.0]
        omega, sub = 9.0, 4
        step = 1 / (FPS * sub)
        for index in range(count):
            cx, cy, zoom = self.target(index)
            goal = [cx, cy, math.log(zoom)]
            if index in snaps or self.o.v[index] <= 0.001:
                state, speed = goal[:], [0.0, 0.0, 0.0]  # 看不见的时候不用追，下次出现时已经在位
            else:
                for _ in range(sub):
                    for axis in range(3):
                        speed[axis] += (omega * omega * (goal[axis] - state[axis]) - 2 * omega * speed[axis]) * step
                        state[axis] += speed[axis] * step
            pw, ph = self.w.v[index], self.h.v[index]
            z = max(math.exp(state[2]), pw / PAGE_W, ph / PAGE_H)  # 面板里永远铺满，不露底
            half_w, half_h = pw / (2 * z), ph / (2 * z)
            self.cx.v[index] = min(max(state[0], half_w), PAGE_W - half_w)
            self.cy.v[index] = min(max(state[1], half_h), PAGE_H - half_h)
            self.zoom.v[index] = z

    def to_film(self, index, point):
        """页面上的一点，这一帧在画面上的位置。"""
        z = self.zoom.v[index]
        return (self.x.v[index] + self.w.v[index] / 2 + (point[0] - self.cx.v[index]) * z,
                self.y.v[index] + self.h.v[index] / 2 + (point[1] - self.cy.v[index]) * z)

    def box_to_film(self, index, box):
        left, top = self.to_film(index, (box[0], box[1]))
        z = self.zoom.v[index]
        return left, top, box[2] * z, box[3] * z

    def data(self):
        return {"id": self.id, "kind": "pane", "x": self.x.packed(), "y": self.y.packed(), "w": self.w.packed(), "h": self.h.packed(),
                "r": self.r.packed(), "ry": self.ry.packed(), "rx": self.rx.packed(), "o": self.o.packed(3),
                "cx": self.cx.packed(), "cy": self.cy.packed(), "z": self.zoom.packed(4)}


FULL = (0, 0, PAGE_W, PAGE_H)


class Cursor:
    """画出来的大光标。路点是页面坐标（跟着哪块面板的镜头走），或画面坐标（pane 为 None）。"""

    SIZE = 68

    def __init__(self, film):
        self.film = film
        self.way = []     # (到达的时刻, 面板, 点, 路上花多久)
        self.clicks = []  # 时刻
        self.o = film.chan(0)

    def go(self, t, pane, point, travel=0.55):
        self.way.append((t, pane, point, travel))
        self.way.sort(key=lambda entry: entry[0])  # 路点可以不按先后加
        return self

    def click(self, t, sound=True):
        self.clicks.append(t)
        if sound:
            self.film.clicks.append(t)
        return self

    def show(self, t):
        self.o.to(t, 0.12, 1, "linear")
        return self

    def hide(self, t):
        self.o.to(t, 0.2, 0, "linear")
        return self

    @staticmethod
    def place(index, pane, point):
        return pane.to_film(index, point) if pane else point

    def position(self, index):
        t = index / FPS
        here = self.way[0]
        for arrive, pane, point, travel in self.way:
            if t < arrive - travel:
                break
            if t < arrive:
                start, end = self.place(index, here[1], here[2]), self.place(index, pane, point)
                u = EASES["out"]((t - (arrive - travel)) / travel)
                bend = 0.12
                mx = (start[0] + end[0]) / 2 - (end[1] - start[1]) * bend
                my = (start[1] + end[1]) / 2 + (end[0] - start[0]) * bend
                w = 1 - u
                return w * w * start[0] + 2 * w * u * mx + u * u * end[0], w * w * start[1] + 2 * w * u * my + u * u * end[1]
            here = (arrive, pane, point, travel)
        return self.place(index, here[1], here[2])

    def data(self):
        count = self.film.count
        x, y, s, ring, ring_o = (Chan(count) for _ in range(5))
        s.v = [1.0] * count
        for index in range(count):
            x.v[index], y.v[index] = self.position(index)
            t = index / FPS
            since = min((t - click for click in self.clicks if t >= click), default=9)
            if since < 0.08:
                s.v[index] = 1 - 0.18 * since / 0.08
            elif since < 0.3:
                s.v[index] = 1 - 0.18 * (1 - EASES["out"]((since - 0.08) / 0.22))
            if since < 0.42:
                u = since / 0.42
                ring.v[index] = 14 + 46 * EASES["out"](u)
                ring_o.v[index] = 1 - u
        return {"id": "cursor", "kind": "cursor", "x": x.packed(), "y": y.packed(), "s": s.packed(3), "o": self.o.packed(3),
                "ring": ring.packed(), "ringO": ring_o.packed(3)}


class Film:
    def __init__(self, duration):
        self.duration = round(duration * FPS) / FPS
        self.count = frame(self.duration) + 1
        self.length = (self.count - 1) / PLAY  # 放出来有多长（秒）
        self.panes, self.nodes, self.clicks = [], [], []
        self.cursor = Cursor(self)
        self.serial = 0

    def chan(self, value=0.0):
        return Chan(self.count, value)

    def pane(self, ident, z=5):
        pane = Pane(self, ident, z)
        self.panes.append(pane)
        return pane

    def node(self, html, x=0, y=0, ident=None, **more):
        self.serial += 1
        node = Node(self, ident or f"n{self.serial}", html, x, y, **more)
        self.nodes.append(node)
        return node

    def text(self, words, x, y, cls="cap", **more):
        """一行要读的字：只在看得见的那一段算进时间线。"""
        return self.node(words, x, y, cls=cls, clip=True, z=more.pop("z", 30), **more)

    def write(self, folder, style="", video="assets/screen.mp4", audio="assets/track.wav", extra_script=""):
        for pane in self.panes:
            pane.solve()
        items = [pane.data() for pane in self.panes] + [node.data() for node in self.nodes] + [self.cursor.data()]
        body = []
        for pane in self.panes:
            body.append(
                f'<div class="pane" id="{pane.id}" style="z-index:{pane.z}" data-layout-ignore><div class="clipper"><div class="cam">'
                f'<video id="{pane.id}-video" class="clip" data-start="0" data-duration="{self.length:.3f}" data-track-index="0" '
                f'src="{video}" muted playsinline></video></div></div></div>')
        track = 2
        for node in self.nodes:
            inner = f'<div class="node {node.cls}" id="{node.id}" style="z-index:{node.z}">{node.html}</div>'
            if node.clip:
                span = node.span()
                if not span:
                    continue
                track += 1
                body.append(f'<div class="clip holder" data-start="{span[0]:.3f}" data-duration="{min(span[1], self.length - span[0]):.3f}" '
                            f'data-track-index="{track}" style="z-index:{node.z}">{inner}</div>')
            else:
                body.append(inner.replace('class="node', 'data-layout-ignore class="node', 1))
        body.append('<div id="ring" data-layout-ignore></div>')
        body.append(f'<svg id="cursor" data-layout-ignore viewBox="0 0 24 24" width="{Cursor.SIZE}" height="{Cursor.SIZE}">'
                    '<path d="M5 3l14 8.2-6.3 1.5-3 6z"/></svg>')
        if audio:
            body.append(f'<audio id="bed" class="clip" data-start="0" data-duration="{self.length:.3f}" data-track-index="1" '
                        f'src="{audio}" data-volume="1"></audio>')
        data = {"fps": PLAY, "duration": self.length, "count": self.count, "items": items}
        html = TEMPLATE.replace("/*STYLE*/", style).replace("<!--BODY-->", "\n".join(body)) \
            .replace("/*DATA*/", json.dumps(data, ensure_ascii=False, separators=(",", ":"))) \
            .replace("/*EXTRA*/", extra_script).replace("{DURATION}", f"{self.length:.3f}")
        folder = Path(folder)
        (folder / "index.html").write_text(html)
        (folder / "cues.json").write_text(json.dumps({"total": self.length, "clicks": sorted(frame(moment) / PLAY for moment in self.clicks)}))
        return html


TEMPLATE = """<!doctype html>
<html lang="zh-CN">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=1920, height=1080">
<script src="https://cdn.jsdelivr.net/npm/gsap@3.15.0/dist/gsap.min.js"></script>
<style>
@font-face { font-family: "PF"; src: local("PingFangSC-Regular"), local("PingFang SC"); font-weight: 400; }
@font-face { font-family: "PF"; src: local("PingFangSC-Medium"); font-weight: 500; }
@font-face { font-family: "PF"; src: local("PingFangSC-Semibold"); font-weight: 700; }
@font-face { font-family: "Mono"; src: local("SFMono-Regular"), local("Menlo-Regular"), local("Menlo"); font-weight: 400; }
@font-face { font-family: "Mono"; src: local("SFMono-Semibold"), local("Menlo-Bold"); font-weight: 700; }
:root { --ground: #f2f2f4; --ink: #16171a; --muted: #5d6068; --accent: #ff4f1f; --sans: "PF", sans-serif; --mono: "Mono", "PF", monospace; }
* { margin: 0; padding: 0; box-sizing: border-box; }
html, body { width: 1920px; height: 1080px; overflow: hidden; background: var(--ground); }
#root { width: 1920px; height: 1080px; position: relative; overflow: hidden; background: var(--ground); font-family: var(--sans); color: var(--ink); perspective: 2600px; }
.pane { position: absolute; left: 0; top: 0; transform-origin: 50% 50%; border-radius: 18px; box-shadow: 0 24px 60px rgba(0, 0, 0, .22), 0 0 0 1px rgba(0, 0, 0, .08); opacity: 0; }
.clipper { position: absolute; inset: 0; overflow: hidden; border-radius: inherit; background: #fff; }
.cam { position: absolute; left: 0; top: 0; width: 1440px; height: 810px; transform-origin: 0 0; }
.cam video { position: absolute; left: 0; top: 0; width: 1440px; height: 810px; }
.holder { position: absolute; left: 0; top: 0; width: 1920px; height: 1080px; }
.node { position: absolute; left: 0; top: 0; opacity: 0; white-space: nowrap; }
#cursor { position: absolute; left: 0; top: 0; z-index: 60; opacity: 0; overflow: visible; filter: drop-shadow(0 4px 6px rgba(0, 0, 0, .32)); }
#cursor path { fill: #16171a; stroke: #fff; stroke-width: 1.5; stroke-linejoin: round; }
#ring { position: absolute; left: 0; top: 0; z-index: 59; border: 4px solid var(--accent); border-radius: 50%; opacity: 0; }
/*STYLE*/
</style>
</head>
<body>
<div id="root" data-composition-id="main" data-start="0" data-duration="{DURATION}" data-width="1920" data-height="1080">
<!--BODY-->
</div>
<script>
const FILM = /*DATA*/;
(function () {
  const value = (chan, index) => (typeof chan === "number" ? chan : chan[index < chan.length ? index : chan.length - 1]);
  const items = FILM.items.map((item) => {
    const element = document.getElementById(item.id);
    return Object.assign({}, item, { element, cam: element && element.querySelector(".cam"), clipper: element && element.querySelector(".clipper") });
  });
  const ring = document.getElementById("ring");
  const SIZE = /*CURSOR*/68;
  const hooks = [];
  /*EXTRA*/
  function render(t) {
    const index = Math.max(0, Math.min(FILM.count - 1, Math.round(t * FILM.fps)));
    for (const item of items) {
      const element = item.element;
      if (!element) continue;
      const opacity = value(item.o, index);
      element.style.opacity = opacity;
      if (item.kind === "pane") {
        const w = value(item.w, index), h = value(item.h, index), z = value(item.z, index);
        element.style.width = w + "px";
        element.style.height = h + "px";
        element.style.borderRadius = value(item.r, index) + "px";
        const ry = value(item.ry, index), rx = value(item.rx, index);
        element.style.transform = "translate(" + value(item.x, index) + "px," + value(item.y, index) + "px)" + (ry || rx ? " rotateY(" + ry + "deg) rotateX(" + rx + "deg)" : "");
        item.cam.style.transform = "translate(" + (w / 2 - value(item.cx, index) * z).toFixed(2) + "px," + (h / 2 - value(item.cy, index) * z).toFixed(2) + "px) scale(" + z + ")";
      } else if (item.kind === "cursor") {
        const x = value(item.x, index), y = value(item.y, index);
        element.style.transformOrigin = (5 / 24) * SIZE + "px " + (3 / 24) * SIZE + "px";
        element.style.transform = "translate(" + (x - (5 / 24) * SIZE).toFixed(2) + "px," + (y - (3 / 24) * SIZE).toFixed(2) + "px) scale(" + value(item.s, index) + ")";
        const radius = value(item.ring, index);
        ring.style.opacity = opacity ? value(item.ringO, index) : 0;
        ring.style.width = ring.style.height = 2 * radius + "px";
        ring.style.transform = "translate(" + (x - radius).toFixed(2) + "px," + (y - radius).toFixed(2) + "px)";
      } else {
        const s = value(item.s, index), rot = value(item.rot, index);
        element.style.transformOrigin = item.ax * 100 + "% " + item.ay * 100 + "%";
        element.style.transform = "translate(" + value(item.x, index) + "px," + value(item.y, index) + "px) translate(" + -item.ax * 100 + "%," + -item.ay * 100 + "%)"
          + (s !== 1 ? " scale(" + s + ")" : "") + (rot ? " rotate(" + rot + "deg)" : "");
        if (item.w !== undefined) {
          element.style.width = value(item.w, index) + "px";
          element.style.height = value(item.h, index) + "px";
        }
        if (item.clip !== undefined) element.style.clipPath = "inset(0 " + value(item.clip, index) + "% 0 0)";
      }
    }
    for (const hook of hooks) hook(index, value);
  }
  const clock = { t: 0 };
  const tl = gsap.timeline({ paused: true });
  tl.to(clock, { t: FILM.duration, duration: FILM.duration, ease: "none", onUpdate: () => render(clock.t) });
  tl.seek(0);
  render(0);
  window.__render = render;
  window.__timelines = window.__timelines || {};
  window.__timelines["main"] = tl;
})();
</script>
</body>
</html>
"""
