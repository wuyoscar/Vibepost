#!/bin/zsh
# 生成实况测试用的两段视频（需要 ffmpeg，带 libx264、libx265）。已生成的文件随仓库提交，平时不用跑。
#   live-h264.mp4  H.264 + AAC 的 MP4，横屏 640 × 360
#   live-hevc.mov  HEVC（hvc1）+ AAC 的 MOV，像 iPhone 拍的竖屏：编码成横的 1280 × 720，带「顺时针转 90° 显示」标记
# 都是 10 秒、每秒 30 帧、带一路正弦音。画面上半截每秒换一种颜色（红、绿、蓝、琥珀、紫，五秒一轮），
# 下半截白色：测试据此判断取的是哪一秒、方向对不对。
set -euo pipefail
cd "$(dirname "$0")"

COLORS=(0xE53935 0x43A047 0x1E88E5 0xFFB300 0x8E24AA)
BOXES=""
for index in {0..4}; do
  BOXES+="${BOXES:+,}drawbox=x=0:y=0:w=iw:h=ih/2:color=${COLORS[index + 1]}:t=fill:enable='eq(mod(floor(t),5),${index})'"
done

ffmpeg -hide_banner -loglevel error -y \
  -f lavfi -i "color=c=white:s=640x360:r=30:d=10" \
  -f lavfi -i "sine=frequency=440:sample_rate=44100:duration=10" \
  -vf "$BOXES" -c:v libx264 -profile:v high -pix_fmt yuv420p -crf 30 -g 30 \
  -c:a aac -b:a 64k -movflags +faststart -shortest live-h264.mp4

CODED="$(mktemp -d)/coded.mov"
# 和 iPhone 竖着拍的一样：画面逆时针转 90° 编码，显示标记让播放器顺时针转回来
ffmpeg -hide_banner -loglevel error -y \
  -f lavfi -i "color=c=white:s=720x1280:r=30:d=10" \
  -f lavfi -i "sine=frequency=660:sample_rate=48000:duration=10" \
  -vf "$BOXES,transpose=2" -c:v libx265 -tag:v hvc1 -pix_fmt yuv420p -crf 32 \
  -x265-params log-level=error:keyint=30:open-gop=0 -c:a aac -b:a 64k -shortest "$CODED"
ffmpeg -hide_banner -loglevel error -y -display_rotation -90 -i "$CODED" \
  -c copy -tag:v hvc1 -movflags +faststart live-hevc.mov
rm -rf "$(dirname "$CODED")"
