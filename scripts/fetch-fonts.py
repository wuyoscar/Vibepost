#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.10"
# dependencies = []
# ///
"""下载并校验打包字体，生成仓库根目录的 fonts/（不进 git）。

    uv run scripts/fetch-fonts.py

用 uv 跑（https://docs.astral.sh/uv/）：它自己备好合适的 Python，不往系统的 Python 里装东西。只用标准库，没有依赖。

- 版本全部固定：npm 包按 registry 的 dist.integrity（sha512）校验，GitHub 发布包按 sha256 校验。
- 下载缓存在 ~/Library/Caches/MediaCraft/fonts/，重复执行、在别的 worktree 里执行都直接复用。
- 只取所需字重的 woff2，保留 unicode-range 分片；生成 fonts/fonts.css、fonts/manifest.json 与 fonts/licenses/。
- 族名统一加「MC 」前缀，不与本机装的同名字体、界面 CSS 里的 Inter 冲突。
"""
from __future__ import annotations

import base64
import hashlib
import json
import logging
import os
import posixpath
import re
import shutil
import tarfile
import tempfile
import urllib.request
import zipfile
from dataclasses import dataclass
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
OUTPUT = REPO / "fonts"
CACHE = Path(os.environ.get("MEDIACRAFT_FONT_CACHE_DIR", str(Path.home() / "Library/Caches/MediaCraft/fonts")))
FAMILY_PREFIX = "MC "
FONTSOURCE_VERSION = "5.3.0"


@dataclass(frozen=True)
class Download:
    url: str
    checksum: str  # "sha512-<base64>"（npm 的 dist.integrity）或 "sha256:<hex>"


@dataclass(frozen=True)
class NpmFont:
    id: str
    family: str
    package: Download
    css: dict[int, str]  # 字重 → 包里声明这一字重 @font-face 的 CSS
    licenses: tuple[str, ...]


@dataclass(frozen=True)
class ZipFont:
    id: str
    family: str
    archive: Download
    woff2: str
    weight: int
    license: Download


def fontsource(font_id: str, family: str, integrity: str, weights: tuple[int, ...]) -> NpmFont:
    url = f"https://registry.npmjs.org/@fontsource/{font_id}/-/{font_id}-{FONTSOURCE_VERSION}.tgz"
    css = {weight: f"{weight}.css" for weight in weights}
    return NpmFont(font_id, family, Download(url, integrity), css, ("LICENSE",))


NPM_FONTS = (
    fontsource(
        "noto-sans-sc", "Noto Sans SC",
        "sha512-HeqIlGm0+ohOKxZLuHj1qW6r6avHH0OWdKERAcSDI0RQ+MXrteuLKA+M+5eOA8rYy0MFvOR5AT0fQo2rUkye0Q==",
        (400, 500, 700, 900),
    ),
    fontsource(
        "noto-serif-sc", "Noto Serif SC",
        "sha512-0/zaEFkidiWldE62rTeD74x8ygUsQvejiSNtO0LQxQk3qpaHnlMZ3w4C7yH80B4KTIg8VKeFP4oSgwWMchY9+g==",
        (400, 600, 900),
    ),
    NpmFont(
        "lxgw-wenkai", "LXGW WenKai",
        Download(
            "https://registry.npmjs.org/lxgw-wenkai-webfont/-/lxgw-wenkai-webfont-1.7.0.tgz",
            "sha512-kVJmT4xMAyOLhG6q0w63wJkVU7RP8UMQRGoAWj9tnpzL7sWFFYiEHBdUQyW9myqBQFa5SQfWfa2VLYF4IJBL5g==",
        ),
        {400: "lxgwwenkai-regular.css", 700: "lxgwwenkai-bold.css"},
        ("OFL.txt", "LICENSE"),  # 字体本身 OFL，webfont 打包 MIT
    ),
    fontsource(
        "inter", "Inter",
        "sha512-RofMylZmjlJEfELXeNHFWBRcSs75rGU/6bV2S2jfnvv/3rPXPGe0LgUJTklcHZ9lM4OZmAVFhcJPnACfb91A3g==",
        (400, 500, 600, 700),
    ),
    fontsource(
        "ibm-plex-sans", "IBM Plex Sans",
        "sha512-CbE4CbbEEZJX860XyUiRpsksXIQR8Rp2XDva2VO53NJox9tVNtusrysd2x5YkUEY3ErQ66W1IiiQL8/wihhw5w==",
        (400, 500, 600, 700),
    ),
    fontsource(
        "ibm-plex-serif", "IBM Plex Serif",
        "sha512-zwPfHB7EJbS5B8qnitPigJYzNdnt6PUeaoOA1gAAt//1pjpTVZN5sOU14NIAZ+C1xypL6GWsUG2VMYJW9bhJqQ==",
        (400, 600),
    ),
    fontsource(
        "source-serif-4", "Source Serif 4",
        "sha512-yQz8xmIgMzks8zQbpuca3UYtjxK798XCyQAGdDXmzBgvV7sdoK6d0YvE9F9kiYxORCEMRBgGZDZsSYcXj5KvwA==",
        (400, 600, 700),
    ),
    fontsource(
        "ibm-plex-mono", "IBM Plex Mono",
        "sha512-eTgnZjZEGk1QtD3ZstF+Vclo2HLAni8YMy34/DxllwZvyz1lR/1RF/xTiAquOBO7MvqBx8D2Ig2WCPMVfdZu7Q==",
        (400, 500, 600),
    ),
    fontsource(
        "jetbrains-mono", "JetBrains Mono",
        "sha512-fqDfB5I9f1p1TV486aUgB9t8zP84P0O1FtQR5Ol9vjwPy+S+EIGlVYm1cvj2W5shcZMTg2nZFdVMoH5wFu8a1A==",
        (400, 700),
    ),
    fontsource(
        "fira-code", "Fira Code",
        "sha512-EJL968RJRkakubAj/coU8pSUaeTE5UNoRjtzAr6kGiSZ3jWuN8/AKWHwym/PFUaQL1q7IL/H+EXs4358YhrTBQ==",
        (400, 500),
    ),
)

# 得意黑只有一个字重，发布包里没有许可证文件，许可证从同一标签的仓库里取。
SMILEY_SANS = ZipFont(
    "smiley-sans", "Smiley Sans",
    Download(
        "https://github.com/atelier-anchor/smiley-sans/releases/download/v2.0.1/smiley-sans-v2.0.1.zip",
        "sha256:299c0be6c960ae37361762eca76f7d0cd516615435bb96c0d4b98a1e70178a07",
    ),
    "SmileySans-Oblique.ttf.woff2",
    400,
    Download(
        "https://raw.githubusercontent.com/atelier-anchor/smiley-sans/v2.0.1/LICENSE",
        "sha256:9401f4050f1b66c26b6ccdc8b0e14a3c1cc37aac122eda84386f25854a9bec72",
    ),
)

FONT_FACE = re.compile(r"@font-face\s*{([^}]*)}")
WOFF2_URL = re.compile(r"""url\(['"]?([^'")]+\.woff2)['"]?\)""")


def verified(data: bytes, checksum: str) -> bool:
    if checksum.startswith("sha256:"):
        return hashlib.sha256(data).hexdigest() == checksum[len("sha256:"):]
    algorithm, _, digest = checksum.partition("-")
    return base64.b64encode(hashlib.new(algorithm, data).digest()).decode() == digest


def fetch(download: Download) -> Path:
    """返回缓存里校验通过的文件；缓存没有或对不上时重新下载。"""
    path = CACHE / re.sub(r"[^A-Za-z0-9._-]+", "_", download.url.split("://", 1)[1])
    if path.exists() and verified(path.read_bytes(), download.checksum):
        return path
    logging.info("下载 %s", download.url)
    request = urllib.request.Request(download.url, headers={"User-Agent": "MediaCraft fetch-fonts"})
    with urllib.request.urlopen(request, timeout=300) as response:
        data = response.read()
    if not verified(data, download.checksum):
        raise SystemExit(f"校验失败，已停止：{download.url}\n期望 {download.checksum}")
    CACHE.mkdir(parents=True, exist_ok=True)
    partial = path.with_name(path.name + ".partial")
    partial.write_bytes(data)
    partial.replace(path)
    return path


def read_members(archive: Path, names: set[str]) -> dict[str, bytes]:
    """顺序读一遍 .tgz 取出指定文件（gzip 流来回 seek 会反复解压）。"""
    found: dict[str, bytes] = {}
    with tarfile.open(archive, "r:gz") as tar:
        for member in tar:
            if member.isfile() and member.name in names:
                found[member.name] = tar.extractfile(member).read()
    missing = names - found.keys()
    if missing:
        raise SystemExit(f"{archive.name} 里缺少：{', '.join(sorted(missing))}")
    return found


def declared_faces(css: str, weight: int) -> list[tuple[str, str | None]]:
    """CSS 里这一字重正体的 (woff2 相对路径, unicode-range)。"""
    faces = []
    for body in FONT_FACE.findall(css):
        declarations = {}
        for declaration in body.split(";"):
            name, separator, value = declaration.partition(":")
            if separator:
                declarations[name.strip()] = value.strip()
        if declarations.get("font-style") != "normal":
            continue
        if int(declarations["font-weight"]) != weight:
            raise SystemExit(f"字重不符：期望 {weight}，CSS 里是 {declarations['font-weight']}")
        url = WOFF2_URL.search(declarations["src"])
        if not url:
            raise SystemExit(f"没有 woff2：{declarations['src']}")
        faces.append((url.group(1), declarations.get("unicode-range")))
    if not faces:
        raise SystemExit(f"CSS 里没有 {weight} 字重的正体")
    return faces


def face_rule(family: str, weight: int, url: str, unicode_range: str | None) -> str:
    lines = [
        "@font-face {",
        f'  font-family: "{family}";',
        "  font-style: normal;",
        f"  font-weight: {weight};",
        "  font-display: swap;",
        f'  src: url("{url}") format("woff2");',
    ]
    if unicode_range:
        lines.append(f"  unicode-range: {unicode_range};")
    lines.append("}")
    return "\n".join(lines)


def add_npm_font(font: NpmFont, out: Path, rules: list[str]) -> dict:
    archive = fetch(font.package)
    css = read_members(archive, {f"package/{name}" for name in font.css.values()})
    family = FAMILY_PREFIX + font.family
    woff2_members: set[str] = set()
    for weight, name in sorted(font.css.items()):
        for url, unicode_range in declared_faces(css[f"package/{name}"].decode(), weight):
            member = posixpath.normpath(f"package/{url}")
            woff2_members.add(member)
            rules.append(face_rule(family, weight, f"{font.id}/{posixpath.basename(member)}", unicode_range))
    license_members = {f"package/{name}" for name in font.licenses}
    files = read_members(archive, woff2_members | license_members)
    (out / font.id).mkdir()
    for member in woff2_members:
        (out / font.id / posixpath.basename(member)).write_bytes(files[member])
    for member in license_members:
        (out / "licenses" / f"{font.id}-{Path(member).stem}.txt").write_bytes(files[member])
    return {"id": font.id, "family": family, "weights": sorted(font.css)}


def add_zip_font(font: ZipFont, out: Path, rules: list[str]) -> dict:
    with zipfile.ZipFile(fetch(font.archive)) as archive:
        data = archive.read(font.woff2)
    family = FAMILY_PREFIX + font.family
    (out / font.id).mkdir()
    (out / font.id / font.woff2).write_bytes(data)
    shutil.copyfile(fetch(font.license), out / "licenses" / f"{font.id}-LICENSE.txt")
    rules.append(face_rule(family, font.weight, f"{font.id}/{font.woff2}", None))
    return {"id": font.id, "family": family, "weights": [font.weight]}


def main() -> None:
    logging.basicConfig(level=logging.INFO, format="%(message)s")
    with tempfile.TemporaryDirectory() as temp:
        out = Path(temp) / "fonts"
        (out / "licenses").mkdir(parents=True)
        rules: list[str] = ["/* 由 scripts/fetch-fonts.py 生成，勿手改。 */"]
        manifest = [add_npm_font(font, out, rules) for font in NPM_FONTS]
        manifest.append(add_zip_font(SMILEY_SANS, out, rules))
        (out / "fonts.css").write_text("\n\n".join(rules) + "\n", encoding="utf-8")
        (out / "manifest.json").write_text(
            json.dumps({"fonts": manifest}, ensure_ascii=False, indent=2) + "\n", encoding="utf-8"
        )
        shutil.rmtree(OUTPUT, ignore_errors=True)
        shutil.move(str(out), str(OUTPUT))
    woff2 = list(OUTPUT.rglob("*.woff2"))
    megabytes = sum(path.stat().st_size for path in woff2) / 1_000_000
    logging.info("已生成 %s：%d 个字体、%d 个 woff2，共 %.1f MB", OUTPUT, len(manifest), len(woff2), megabytes)


if __name__ == "__main__":
    main()
