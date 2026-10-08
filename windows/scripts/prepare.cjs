"use strict";
const fs = require("node:fs/promises");
const path = require("node:path");
const crypto = require("node:crypto");
const { spawn } = require("node:child_process");
const { windows, root, cache, environment } = require("./paths.cjs");
const FFMPEG = {
  version: "9.0.2",
  url: "https://www.gyan.dev/ffmpeg/builds/packages/ffmpeg-9.0.2-essentials_build.zip",
  sha256: "60f467265b1e312373dbcd92200c2618a74850f98d3d078e94296bb3fa2047ba",
};
async function run(command, args, options = {}) {
  return new Promise((resolve, reject) => {
    const child = spawn(command, args, {
      env: environment(),
      stdio: "inherit",
      windowsHide: true,
      ...options,
    });
    child.once("error", reject);
    child.once("exit", (code) =>
      code === 0 ? resolve() : reject(new Error(`${command} exited ${code}`)),
    );
  });
}
async function exists(file) {
  return fs.access(file).then(
    () => true,
    () => false,
  );
}
async function main() {
  const resources = path.join(windows, "resources");
  await fs.mkdir(resources, { recursive: true });
  const archive = path.join(cache, "ffmpeg", `ffmpeg-${FFMPEG.version}.zip`);
  await fs.mkdir(path.dirname(archive), { recursive: true });
  if (!(await exists(archive))) {
    await require("./runtime.cjs").download(FFMPEG.url, archive);
  }
  const hash = crypto
    .createHash("sha256")
    .update(await fs.readFile(archive))
    .digest("hex");
  if (hash !== FFMPEG.sha256)
    throw new Error(
      "FFmpeg SHA-256 mismatch; remove the corrupt cache archive and retry",
    );
  const extracted = path.join(cache, "ffmpeg", "extracted");
  if (
    !(await exists(
      path.join(
        extracted,
        `ffmpeg-${FFMPEG.version}-essentials_build`,
        `bin`,
        `ffmpeg.exe`,
      ),
    ))
  ) {
    await fs.mkdir(extracted, { recursive: true });
    // Pass paths as arguments, not interpolated PowerShell code.
    await run("powershell.exe", [
      "-NoProfile",
      "-NonInteractive",
      "-File",
      path.join(__dirname, "extract.ps1"),
      "-Archive",
      archive,
      "-Destination",
      extracted,
    ]);
  }
  const source = path.join(
    extracted,
    `ffmpeg-${FFMPEG.version}-essentials_build`,
  );
  await fs.mkdir(path.join(resources, "ffmpeg"), { recursive: true });
  for (const name of ["ffmpeg.exe", "ffprobe.exe"])
    await fs.copyFile(
      path.join(source, "bin", name),
      path.join(resources, "ffmpeg", name),
    );
  await fs.rm(path.join(resources, "ffmpeg", "ffplay.exe"), { force: true });
  for (const name of ["LICENSE", "README.txt"])
    if (await exists(path.join(source, name)))
      await fs.copyFile(
        path.join(source, name),
        path.join(resources, "ffmpeg", name),
      );
  await fs.writeFile(
    path.join(resources, "ffmpeg", "source.json"),
    JSON.stringify(FFMPEG, null, 2),
  );
  const pdf = path.dirname(require.resolve("pdfjs-dist/package.json"));
  await fs.cp(path.join(pdf, "legacy", "build"), path.join(resources, "pdf"), {
    recursive: true,
  });
  for (const name of ["cmaps", "standard_fonts", "wasm"])
    await fs.cp(path.join(pdf, name), path.join(resources, "pdf", name), {
      recursive: true,
    });
  await fs.copyFile(
    path.join(pdf, "LICENSE"),
    path.join(resources, "pdf", "LICENSE"),
  );
  const { default: pngToIco } = await import("png-to-ico");
  await fs.writeFile(
    path.join(resources, "icon.ico"),
    await pngToIco(path.join(root, "brand", "app-icon-256.png")),
  );
  if (!(await exists(path.join(root, "fonts", "fonts.css"))))
    await run(process.env.PYTHON || "python", ["scripts/fetch-fonts.py"], {
      cwd: root,
    });
  if (!(await exists(path.join(root, "src", "vendor", "codemirror.js"))))
    throw new Error(
      "Run npm ci && npm run build:codemirror in the repository root first",
    );
  console.log(
    "Windows assets prepared; FFmpeg " + FFMPEG.version + " verified " + hash,
  );
}
if (require.main === module)
  main().catch((error) => {
    console.error(error);
    process.exitCode = 1;
  });
module.exports = { main, FFMPEG };
