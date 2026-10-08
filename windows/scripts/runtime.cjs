"use strict";
const fs = require("node:fs/promises");
const path = require("node:path");
const crypto = require("node:crypto");
const { spawn } = require("node:child_process");
const { windows, cache, environment } = require("./paths.cjs");
async function run(command, args) {
  return new Promise((resolve, reject) => {
    const child = spawn(command, args, {
      env: environment(),
      stdio: "inherit",
      windowsHide: true,
    });
    child.on("error", reject);
    child.on("exit", (code) =>
      code === 0 ? resolve() : reject(new Error(`${command} exited ${code}`)),
    );
  });
}
async function download(url, file) {
  await fs.mkdir(path.dirname(file), { recursive: true });
  const temp = file + ".partial";
  try {
    if (process.platform === "win32")
      await run("powershell.exe", [
        "-NoProfile",
        "-NonInteractive",
        "-File",
        path.join(__dirname, "download.ps1"),
        "-Url",
        url,
        "-Destination",
        temp,
      ]);
    else {
      const response = await fetch(url);
      if (!response.ok) throw new Error(`Download ${response.status}`);
      await fs.writeFile(temp, Buffer.from(await response.arrayBuffer()));
    }
    await fs.rename(temp, file);
  } finally {
    await fs.rm(temp, { force: true });
  }
}
async function main() {
  const version = require("electron/package.json").version;
  const name = `electron-v${version}-win32-x64.zip`;
  const archive = path.join(cache, "runtime", name);
  const dist = path.join(cache, "runtime", version);
  const expected = require("electron/checksums.json")[name];
  if (!expected) throw new Error("Electron checksum missing");
  if (
    !(await fs.access(archive).then(
      () => true,
      () => false,
    ))
  ) {
    console.log("Downloading pinned Electron " + version);
    const base =
      process.env.ELECTRON_MIRROR ||
      "https://github.com/electron/electron/releases/download/";
    await download(`${base.replace(/\/?$/, "/")}v${version}/${name}`, archive);
  }
  const hash = crypto
    .createHash("sha256")
    .update(await fs.readFile(archive))
    .digest("hex");
  if (hash !== expected) throw new Error("Electron SHA-256 mismatch");
  if (
    !(await fs.access(path.join(dist, "electron.exe")).then(
      () => true,
      () => false,
    ))
  ) {
    await fs.mkdir(dist, { recursive: true });
    await run("powershell.exe", [
      "-NoProfile",
      "-NonInteractive",
      "-File",
      path.join(__dirname, "extract.ps1"),
      "-Archive",
      archive,
      "-Destination",
      dist,
    ]);
  }
  return path.join(dist, "electron.exe");
}
if (require.main === module)
  main()
    .then(console.log)
    .catch((error) => {
      console.error(error);
      process.exitCode = 1;
    });
module.exports = { main, download, run };
