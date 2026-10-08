"use strict";
const fs = require("node:fs/promises");
const path = require("node:path");
const { build, Platform, Arch } = require("electron-builder");
const { windows, root, environment } = require("./paths.cjs");
async function main() {
  Object.assign(process.env, environment());
  await require("./prepare.cjs").main();
  const electronDist = path.dirname(await require("./runtime.cjs").main());
  const version = (
    await fs.readFile(path.join(root, "VERSION"), "utf8")
  ).trim();
  const out = path.resolve(
    process.env.VIBEPOST_OUTPUT_DIR || path.join(root, "dist", "windows"),
  );
  await build({
    targets: Platform.WINDOWS.createTarget(["nsis", "dir"], Arch.x64),
    projectDir: windows,
    config: {
      electronDist,
      appId: "com.wuyoscar.mediacraft",
      productName: "Vibepost",
      asar: true,
      extraMetadata: { version },
      directories: { output: out },
      files: [
        "main.cjs",
        "preload.cjs",
        "lib/**",
        "browser/**",
        "renderer/**",
        "package.json",
      ],
      extraResources: [
        {
          from: root,
          to: "web",
          filter: [
            "index.html",
            "VERSION",
            "src/**",
            "fonts/**",
            "brand/**",
            "docs/guide-assets/**",
            "docs/template-assets/**",
          ],
        },
        { from: path.join(windows, "resources"), to: "windows" },
        { from: path.join(windows, "mcp"), to: "mcp" },
      ],
      win: {
        icon: path.join(windows, "resources", "icon.ico"),
        artifactName: "Vibepost-${version}-Windows-Setup.${ext}",
        signAndEditExecutable: true,
      },
      nsis: {
        oneClick: false,
        allowToChangeInstallationDirectory: true,
        createDesktopShortcut: true,
        createStartMenuShortcut: true,
        shortcutName: "Vibepost",
      },
      publish: null,
    },
  });
  console.log("Windows build " + version + " at " + out);
}
main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
