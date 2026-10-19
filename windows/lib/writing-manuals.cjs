"use strict";
const fs = require("node:fs/promises");
const path = require("node:path");
const { COPYFILE_EXCL } = require("node:fs").constants;
const pending = new Map();
const legacy = ["小红书图文.md", "国际新闻.md", "代码库解读.md"];

// Library 与 AI 服务可能同时初始化同一目录；两处共用升级规则，避免补回用户删除的手册。
function seedWritingManuals(folder, source) {
  const key = path.resolve(folder);
  const next = (pending.get(key) || Promise.resolve()).catch(() => {}).then(async () => {
    let existed = true;
    try { await fs.stat(folder); } catch (error) {
      if (error.code !== "ENOENT") throw error;
      existed = false;
    }
    await fs.mkdir(folder, { recursive: true });
    const record = path.join(folder, ".bundled-writing-manuals.json");
    let previous;
    try { previous = JSON.parse(await fs.readFile(record, "utf8")); } catch (error) {
      if (error.code !== "ENOENT") throw error;
      previous = existed ? legacy : [];
    }
    if (!Array.isArray(previous) || previous.some((name) => typeof name !== "string")) throw new Error("写作技能安装记录不合规");
    const installed = new Set(previous);
    for (const name of await fs.readdir(source)) {
      if (!name.endsWith(".md") || installed.has(name)) continue;
      try { await fs.copyFile(path.join(source, name), path.join(folder, name), COPYFILE_EXCL); } catch (error) {
        if (error.code !== "EEXIST") throw error;
      }
      installed.add(name);
    }
    const temp = record + "." + require("node:crypto").randomUUID() + ".tmp";
    try {
      await fs.writeFile(temp, JSON.stringify([...installed].sort()), { flag: "wx", mode: 0o600 });
      await fs.rename(temp, record);
    } finally { await fs.rm(temp, { force: true }); }
  });
  pending.set(key, next);
  next.finally(() => { if (pending.get(key) === next) pending.delete(key); }).catch(() => {});
  return next;
}

module.exports = { seedWritingManuals };
