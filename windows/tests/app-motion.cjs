"use strict";
const fs = require("node:fs/promises");
const path = require("node:path");
const assert = require("node:assert/strict");
const { execFile } = require("node:child_process");
const { promisify } = require("node:util");
const run = promisify(execFile);
async function motion({ page, data }) {
  const resources = process.env.VIBEPOST_TEST_EXE
    ? path.join(
        path.dirname(process.env.VIBEPOST_TEST_EXE),
        "resources",
        "windows",
      )
    : path.resolve(__dirname, "../resources");
  const ffmpeg = path.join(resources, "ffmpeg", "ffmpeg.exe"),
    ffprobe = path.join(resources, "ffmpeg", "ffprobe.exe");
  const video = path.join(data, "source.mp4");
  await run(
    ffmpeg,
    [
      "-v",
      "error",
      "-y",
      "-f",
      "lavfi",
      "-i",
      "testsrc2=s=160x120:r=30",
      "-f",
      "lavfi",
      "-i",
      "sine=frequency=440",
      "-t",
      "1",
      "-c:v",
      "libx264",
      "-pix_fmt",
      "yuv420p",
      "-c:a",
      "aac",
      video,
    ],
    { windowsHide: true },
  );
  const bytes = (await fs.readFile(video)).toString("base64");
  for (const format of ["mp4", "gif"]) {
    const result = await page.evaluate(
      async ({ bytes, format }) => {
        const canvas = document.createElement("canvas");
        canvas.width = 864;
        canvas.height = 1152;
        const context = canvas.getContext("2d");
        context.fillStyle = "#fff";
        context.fillRect(0, 0, 864, 1152);
        context.fillStyle = "#123";
        context.font = "48px sans-serif";
        context.fillText("Windows motion", 60, 140);
        const card = await new Promise((resolve) =>
          canvas.toBlob(resolve, "image/png"),
        );
        const video = new Blob(
          [Uint8Array.from(atob(bytes), (char) => char.charCodeAt(0))],
          { type: "video/mp4" },
        );
        const progress = [];
        const blob = await window.MediaCraftNative.motionVideo(
          {
            card,
            video,
            videoName: "source.mp4",
            format,
            cardWidth: 864,
            cardHeight: 1152,
            well: { x: 120, y: 300, width: 600, height: 500, radius: 20 },
            crop: { x: 0, y: 0, width: 1, height: 1 },
            start: 0,
            span: 0.4,
            speed: 1,
            sound: true,
          },
          { onProgress: (value) => progress.push(value) },
        );
        const output = new Uint8Array(await blob.arrayBuffer());
        let binary = "";
        for (let i = 0; i < output.length; i += 8192)
          binary += String.fromCharCode(...output.subarray(i, i + 8192));
        return { type: blob.type, data: btoa(binary), progress };
      },
      { bytes, format },
    );
    assert(result.progress.includes(1));
    const output = path.join(data, "bridge-motion." + format);
    await fs.writeFile(output, Buffer.from(result.data, "base64"));
    const probe = JSON.parse(
      (
        await run(
          ffprobe,
          ["-v", "error", "-show_streams", "-of", "json", output],
          { windowsHide: true },
        )
      ).stdout,
    );
    const track = probe.streams.find((s) => s.codec_type === "video");
    assert.equal(track.width, format === "mp4" ? 1440 : 864);
    assert.equal(track.height, format === "mp4" ? 1920 : 1152);
  }
  return "real renderer/preload MP4/GIF encoding and progress";
}
module.exports = { motion };
