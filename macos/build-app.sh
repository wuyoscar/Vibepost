#!/bin/zsh
# 构建 Vibepost.app（bundle id 与存储目录沿用旧名 mediacraft，改了会丢稿子）。
#   ./macos/build-app.sh            Release：网页打包进 .app
#   ./macos/build-app.sh debug      Debug：直接读仓库网页，改完 ⌘R 生效
#   ./macos/build-app.sh --install  Release 并拷进 /Applications
#   ./macos/build-app.sh --universal  同时编 Apple 芯片与 Intel（通用二进制，打 DMG 分发时用）
# 版本号只写在仓库根目录的 VERSION 里（「关于 Vibepost」显示的就是它）。
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
MODE="release"
INSTALL=0
ARCHS=()
for arg in "$@"; do
  case "$arg" in
    debug) MODE="debug" ;;
    --install) INSTALL=1 ;;
    --universal) ARCHS=(--arch arm64 --arch x86_64) ;;
    *) echo "unknown argument: $arg" >&2; exit 2 ;;
  esac
done
VERSION="$(tr -d '[:space:]' < "$REPO/VERSION")"

# App 本体与外部 Agent 用的 MCP 服务（mediacraft-mcp，docs/mcp.md）放在同一个 Contents/MacOS/ 里
swift build --package-path "$REPO/macos" -c "$MODE" "${ARCHS[@]}" --product MediaCraft
swift build --package-path "$REPO/macos" -c "$MODE" "${ARCHS[@]}" --product mediacraft-mcp
BIN_DIR="$(swift build --package-path "$REPO/macos" -c "$MODE" "${ARCHS[@]}" --show-bin-path)"

# 放在 Spotlight 不收录的目录（名字以 .noindex 结尾）：本机只有 /Applications 里那一份出现在启动台与 Spotlight 里
APP="$REPO/build.noindex/Vibepost.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/MediaCraft" "$APP/Contents/MacOS/Vibepost"
cp "$BIN_DIR/mediacraft-mcp" "$APP/Contents/MacOS/mediacraft-mcp"

WEB_ROOT_KEY=""
if [[ "$MODE" == "debug" ]]; then
  WEB_ROOT_KEY="<key>MCWebRoot</key><string>$REPO</string>"
else
  WEB="$APP/Contents/Resources/web"
  mkdir -p "$WEB/docs"
  cp -R "$REPO/index.html" "$REPO/src" "$REPO/brand" "$WEB/"
  cp -R "$REPO/docs/guide-assets" "$WEB/docs/"
  # 打包字体由 scripts/fetch-fonts.py 下载生成，不在 git 里。
  if [[ -f "$REPO/fonts/manifest.json" ]]; then
    cp -R "$REPO/fonts" "$WEB/"
  else
    echo "warning: 没有 fonts/，这次打出的 App 不含内置字体（只能用系统字体）。先运行 python3 scripts/fetch-fonts.py" >&2
  fi
fi

# 图标：由品牌图 brand/icon.png 生成 macOS 风格的圆角方块（scripts/build_app_icon.swift）
ICONSET="$(mktemp -d)/Vibepost.iconset"
mkdir -p "$ICONSET"
if swift "$REPO/scripts/build_app_icon.swift" "$REPO/brand/icon.png" "$ICONSET/icon_512x512@2x.png"; then
  for size in 16 32 128 256 512; do
    sips -z $size $size "$ICONSET/icon_512x512@2x.png" --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
    sips -z $((size * 2)) $((size * 2)) "$ICONSET/icon_512x512@2x.png" --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
  done
  iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/Vibepost.icns"
fi

# 最低系统与 Package.swift 的 .macOS(.v14) 一致，依据见 docs/compatibility.md。
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>com.wuyoscar.mediacraft</string>
  <key>CFBundleName</key><string>Vibepost</string>
  <key>CFBundleDisplayName</key><string>Vibepost</string>
  <key>CFBundleExecutable</key><string>Vibepost</string>
  <key>CFBundleIconFile</key><string>Vibepost</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSHumanReadableCopyright</key><string>© 2026 wuyoscar · CC BY-NC-SA 4.0</string>
  $WEB_ROOT_KEY
</dict>
</plist>
PLIST

# 里面的 MCP 服务先签，再签整个 App
codesign --force --sign - "$APP/Contents/MacOS/mediacraft-mcp" >/dev/null
codesign --force --sign - "$APP" >/dev/null
echo "built $APP ($MODE)"

if [[ "$INSTALL" == 1 ]]; then
  rm -rf "/Applications/Vibepost.app"
  ditto "$APP" "/Applications/Vibepost.app"
  echo "installed /Applications/Vibepost.app"
fi
