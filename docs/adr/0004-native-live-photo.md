# 0004：实况在原生壳里合成

- 状态：已采纳（2026-09-29）

## 背景
实况（Live Photo）要把卡片画面和一段视频合成一对 JPG + MOV，两边用同一个配对 ID。原来在网页里用 WebCodecs 解码编码、自己拼 MP4、再往 JPEG 里手写 EXIF / MakerNote。MediaCraft 只做 Mac App，壳里本来就有 AVFoundation。

## 决定
- 合成挪到原生壳（Swift：AVFoundation + Core Image + ImageIO），网页上的 WebCodecs 路径与 mp4box、mp4-muxer 一起删掉。
- 页面经原生桥 `POST /__native/live-photo` 交出卡片 PNG、原视频与设置（时长、倍速、起点、裁剪、声音、封面帧），壳在后台线程合成，拿回 `.pvt` 里的 JPG、MOV、metadata.plist；进度由壳推给页面，取消就是中止这次请求。
- MOV 用硬件 HEVC 编码（编不了时退回 H.264），带 `com.apple.quicktime.content.identifier` 与 still-image-time 定时元数据；JPG 的 Apple MakerNote 第 17 项写同一个 ID。
- 实况编辑器与卡片上的预览播放仍在网页里（`<video>`），只有成片交给壳。

## 后果
- 导出、发送实况只在 App 里可用（和发送到 iPhone 一样）；浏览器里打开时明确提示，普通卡片照常导出。
- 不再依赖 WebKit 的 WebCodecs 与 JPEG 元数据的写法；配对元数据由系统框架写出，iOS 认得。
- 合成的正确性由 WKWebView harness 端到端验证（H.264 MP4 与 iPhone 式 HEVC MOV 两种素材）。
