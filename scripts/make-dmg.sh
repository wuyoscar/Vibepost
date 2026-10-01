#!/bin/zsh
# 打安装用的 DMG：Release 构建（Apple 芯片 + Intel 通用二进制）→ Vibepost.app、「Applications」快捷方式、背景图
# → dist/Vibepost-<VERSION>.dmg（压缩、只读）。
#   scripts/make-dmg.sh
#       ad-hoc 签名，没有公证：别人下载后第一次打开要手动放行（README「安装」）。
#   scripts/make-dmg.sh --sign "Developer ID Application: 名字 (TEAMID)"
#       用 Developer ID 证书签名：开强化运行时（hardened runtime）、带安全时间戳，DMG 本身也签。
#   scripts/make-dmg.sh --sign "Developer ID Application: 名字 (TEAMID)" --notarize 钥匙串配置名
#       再交给 Apple 公证、等结果，把公证票据钉进 DMG。配置名先存一次：
#       xcrun notarytool store-credentials 配置名 --apple-id 邮箱 --team-id TEAMID --password App 专用密码
# 不需要 entitlements：没开 App 沙盒；WKWebView 的 JIT 在 WebKit 自己的进程里；不加载第三方动态库；
# 启动的 claude / node 是各自签名的程序，强化运行时不管子进程；不发 Apple Events、不用摄像头与麦克风。见 docs/compatibility.md。
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
IDENTITY=""
PROFILE=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --sign) IDENTITY="${2:?--sign 后面要跟证书名}"; shift 2 ;;
    --notarize) PROFILE="${2:?--notarize 后面要跟钥匙串配置名}"; shift 2 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done
if [[ -n "$PROFILE" && -z "$IDENTITY" ]]; then
  echo "公证前要先用 Developer ID 签名：再加上 --sign \"Developer ID Application: …\"" >&2
  exit 2
fi

VERSION="$(tr -d '[:space:]' < "$REPO/VERSION")"
VOLUME="Vibepost"
DMG="$REPO/dist/Vibepost-$VERSION.dmg"
# Finder 按卷名找磁盘，同名的挂着就会排错窗口
if [[ -e "/Volumes/$VOLUME" ]]; then
  echo "已经挂着一个「$VOLUME」磁盘，先推出它再打包" >&2
  exit 1
fi

"$REPO/macos/build-app.sh" --universal
APP="$REPO/build/Vibepost.app"
if [[ -n "$IDENTITY" ]]; then
  codesign --force --options runtime --timestamp --sign "$IDENTITY" "$APP"
fi
codesign --verify --strict "$APP"

WORK="$(mktemp -d)"
MOUNT=""
cleanup() {
  if [[ -n "$MOUNT" ]]; then hdiutil detach "$MOUNT" -quiet -force 2>/dev/null || true; fi
  rm -rf "$WORK"
}
trap cleanup EXIT

STAGE="$WORK/stage"
mkdir -p "$STAGE/.background"
ditto "$APP" "$STAGE/Vibepost.app"
ln -s /Applications "$STAGE/Applications"
swift "$REPO/scripts/make_dmg_background.swift" "$STAGE/.background/background.tiff" "$REPO/brand/app-icon-256.png"

# 先做可写的镜像，挂上去让 Finder 排好窗口（背景、图标位置记在卷上的 .DS_Store），再压缩成只读的。留 20 MB 给 Finder 写东西。
SIZE_MB=$(( $(du -sm "$STAGE" | cut -f1) + 20 ))
hdiutil create -quiet -volname "$VOLUME" -srcfolder "$STAGE" -fs HFS+ -format UDRW -size "${SIZE_MB}m" "$WORK/rw.dmg"
MOUNT="$(hdiutil attach "$WORK/rw.dmg" -readwrite -noverify -noautoopen | awk -F '\t' '/\/Volumes\// { print $NF }')"
if [[ ! -d "$MOUNT/Vibepost.app" ]]; then
  echo "镜像没挂上：$MOUNT" >&2
  exit 1
fi

# 图标中心与背景图（scripts/make_dmg_background.swift）上的箭头对齐；窗口内容区 640×400。
layout_window() {
  osascript <<APPLESCRIPT >/dev/null
with timeout of 60 seconds
  tell application "Finder"
    tell disk "$VOLUME"
      open
      set current view of container window to icon view
      set toolbar visible of container window to false
      set statusbar visible of container window to false
      set bounds of container window to {200, 120, 840, 548}
      set viewOptions to icon view options of container window
      set arrangement of viewOptions to not arranged
      set icon size of viewOptions to 112
      set text size of viewOptions to 13
      set background picture of viewOptions to file ".background:background.tiff"
      set position of item "Vibepost.app" of container window to {170, 205}
      set position of item "Applications" of container window to {470, 205}
      close
      open
      delay 1
      close
    end tell
  end tell
end timeout
APPLESCRIPT
}

# Finder 排版要「自动化」权限（第一次会弹框问终端能否控制 Finder）；不给或卡住就跳过，DMG 照样能用，只是没有背景与图标位置。
LAYOUT_OK=0
layout_window &
LAYOUT_PID=$!
for _ in {1..90}; do
  kill -0 "$LAYOUT_PID" 2>/dev/null || break
  sleep 1
done
if kill -0 "$LAYOUT_PID" 2>/dev/null; then
  kill "$LAYOUT_PID" 2>/dev/null || true
fi
if wait "$LAYOUT_PID"; then LAYOUT_OK=1; fi
if [[ "$LAYOUT_OK" != 1 ]]; then
  echo "warning: Finder 没能排好 DMG 窗口（没有自动化权限？），这次的 DMG 没有背景与图标位置" >&2
fi

rm -rf "$MOUNT/.fseventsd"
sync
for attempt in 1 2 3 4 5; do
  hdiutil detach "$MOUNT" -quiet && break
  [[ "$attempt" == 5 ]] && hdiutil detach "$MOUNT" -quiet -force
  sleep 2
done
MOUNT=""

mkdir -p "$REPO/dist"
rm -f "$DMG"
hdiutil convert "$WORK/rw.dmg" -quiet -format UDZO -imagekey zlib-level=9 -o "$DMG"

if [[ -n "$IDENTITY" ]]; then
  codesign --force --timestamp --sign "$IDENTITY" "$DMG"
else
  codesign --force --sign - "$DMG"
fi

if [[ -n "$PROFILE" ]]; then
  RESULT="$WORK/notary.json"
  xcrun notarytool submit "$DMG" --keychain-profile "$PROFILE" --wait --output-format json > "$RESULT"
  STATUS="$(plutil -extract status raw -o - "$RESULT")"
  if [[ "$STATUS" != "Accepted" ]]; then
    echo "公证没通过（$STATUS），看原因：xcrun notarytool log $(plutil -extract id raw -o - "$RESULT") --keychain-profile $PROFILE" >&2
    exit 1
  fi
  xcrun stapler staple "$DMG"
  spctl --assess --type open --context context:primary-signature --verbose "$DMG"
fi

echo "built $DMG"
if [[ -z "$IDENTITY" ]]; then
  cat <<NOTE
注意：这是 ad-hoc 签名、没有公证的 DMG。别人下载后第一次打开 Vibepost 会被 Gatekeeper 拦下：
  macOS 14：在「应用程序」里按住 Control 点 Vibepost →「打开」→ 再点「打开」；
  macOS 15 及以上：先双击一次，再到「系统设置 → 隐私与安全性」最下面点「仍要打开」。
要让别人双击就能打开：scripts/make-dmg.sh --sign "Developer ID Application: …" --notarize 钥匙串配置名
NOTE
elif [[ -z "$PROFILE" ]]; then
  echo "注意：已签名但没有公证，别人第一次打开仍会被 Gatekeeper 拦下；加上 --notarize 钥匙串配置名 完成公证。"
fi
