"use strict";
const path = require("node:path");
const fs = require("node:fs");
const windows = path.resolve(__dirname, "..");
const root = path.dirname(windows);
const cache = path.resolve(
  process.env.VIBEPOST_CACHE_DIR ||
    path.join(root, ".scratch", "windows-cache"),
);
function environment() {
  const temp = path.join(cache, "tmp");
  fs.mkdirSync(temp, { recursive: true });
  return {
    ...process.env,
    TEMP: temp,
    TMP: temp,
    npm_config_cache: path.join(cache, "npm"),
    ELECTRON_CACHE: path.join(cache, "electron"),
    electron_config_cache: path.join(cache, "electron"),
    ELECTRON_BUILDER_CACHE: path.join(cache, "builder"),
    MEDIACRAFT_FONT_CACHE_DIR: path.join(cache, "fonts"),
  };
}
module.exports = { windows, root, cache, environment };
