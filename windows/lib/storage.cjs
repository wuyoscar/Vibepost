"use strict";
const fs = require("node:fs/promises");
const path = require("node:path");

function safeName(value, maxLength = 80) {
  if (
    typeof value !== "string" ||
    !value.trim() ||
    [...value].length > maxLength ||
    /[\\/:*?"<>|\x00-\x1f\x7f]/.test(value) ||
    /^[. ]|[. ]$/.test(value) ||
    /^(con|prn|aux|nul|com[1-9]|lpt[1-9])(?:\.|$)/i.test(value)
  )
    throw new Error("文件名不合规");
  return value;
}
function within(root, target) {
  const relative = path.relative(path.resolve(root), path.resolve(target));
  return (
    relative === "" ||
    (!relative.startsWith(".." + path.sep) &&
      relative !== ".." &&
      !path.isAbsolute(relative))
  );
}
const writes = new Map();
function atomicJson(file, value) {
  const name = path.resolve(file);
  const next = (writes.get(name) || Promise.resolve())
    .catch(() => {})
    .then(() => writeJson(name, value));
  writes.set(name, next);
  next
    .finally(() => {
      if (writes.get(name) === next) writes.delete(name);
    })
    .catch(() => {});
  return next;
}
async function writeJson(file, value) {
  await fs.mkdir(path.dirname(file), { recursive: true });
  const temp = file + "." + require("node:crypto").randomUUID() + ".tmp";
  try {
    await fs.writeFile(temp, JSON.stringify(value, null, 2), { mode: 0o600 });
    await fs.rename(temp, file);
  } finally {
    await fs.rm(temp, { force: true });
  }
}
class Library {
  constructor(dataDir, webRoot) {
    this.dataDir = dataDir;
    this.webRoot = webRoot;
    this.queues = { manuals: Promise.resolve(), templates: Promise.resolve() };
  }
  serial(kind, task) {
    const next = this.queues[kind].catch(() => {}).then(task);
    this.queues[kind] = next;
    return next;
  }
  folder(kind) {
    return path.join(this.dataDir, kind === "manuals" ? "写作手册" : "模板");
  }
  async seed() {
    const dir = this.folder("manuals");
    await fs.mkdir(dir, { recursive: true });
    if (!(await fs.readdir(dir)).some((name) => name.endsWith(".md"))) {
      const source = path.join(this.webRoot, "src", "writing-manuals");
      for (const name of await fs.readdir(source))
        if (name.endsWith(".md"))
          await fs
            .copyFile(
              path.join(source, name),
              path.join(dir, name),
              require("node:fs").constants.COPYFILE_EXCL,
            )
            .catch((e) => {
              if (e.code !== "EEXIST") throw e;
            });
    }
    await fs.mkdir(this.folder("templates"), { recursive: true });
  }
  async manuals(action, input = {}) {
    return this.serial("manuals", () => this._manuals(action, input));
  }
  async _manuals(action, input = {}) {
    const folder = this.folder("manuals");
    await fs.mkdir(folder, { recursive: true });
    if (action === "list") {
      const manuals = [];
      for (const name of await fs.readdir(folder))
        if (name.endsWith(".md")) {
          const item = await this._manuals("read", { name: name.slice(0, -3) });
          manuals.push({ name: item.name, description: item.description });
        }
      return { manuals, folder };
    }
    const name = safeName(input.name);
    const file = path.join(folder, name + ".md");
    if (action === "read") {
      const text = await fs.readFile(file, "utf8");
      const front = /^---\r?\n([\s\S]*?)\r?\n---\r?\n*/.exec(text);
      const description =
        front?.[1]
          .match(/^description:\s*(.*)$/m)?.[1]
          ?.replace(/^['"]|['"]$/g, "") || "";
      return {
        name,
        description,
        content: front ? text.slice(front[0].length) : text,
      };
    }
    if (action === "save") {
      if (typeof input.content !== "string" || input.content.length > 500000)
        throw new Error("手册正文不合规");
      const description = String(input.description || "")
        .replace(/[\r\n]/g, " ")
        .slice(0, 500);
      const temporary =
        file + "." + require("node:crypto").randomUUID() + ".tmp";
      try {
        await fs.writeFile(
          temporary,
          `---\nname: ${name}\ndescription: ${description}\n---\n\n${input.content}`,
          "utf8",
        );
        await fs.rename(temporary, file);
      } finally {
        await fs.rm(temporary, { force: true });
      }
      return { name };
    }
    throw new Error("未知手册操作");
  }
  async templates(action, input = {}) {
    return this.serial("templates", () => this._templates(action, input));
  }
  async _templates(action, input = {}) {
    const root = this.folder("templates");
    await fs.mkdir(root, { recursive: true });
    if (action === "list") {
      const templates = [];
      for (const entry of await fs.readdir(root, { withFileTypes: true }))
        if (entry.isDirectory() && !entry.name.startsWith(".")) {
          try {
            templates.push({
              name: entry.name,
              content: await fs.readFile(
                path.join(root, entry.name, "模板.md"),
                "utf8",
              ),
            });
          } catch (e) {
            if (e.code !== "ENOENT") throw e;
          }
        }
      return { templates, folder: root };
    }
    const name = safeName(input.name);
    const folder = path.join(root, name);
    if (action === "read") {
      const content = await fs.readFile(path.join(folder, "模板.md"), "utf8");
      const images = {};
      for (const file of await fs.readdir(folder))
        if (/\.(png|jpe?g|webp|gif)$/i.test(file)) {
          const target = path.join(folder, file);
          const stat = await fs.lstat(target);
          if (!stat.isFile() || stat.isSymbolicLink()) continue;
          if (stat.size > 20 * 1024 * 1024 || Object.keys(images).length >= 40)
            throw new Error("模板最多 40 张图片，每张不超过 20 MB");
          images[file] =
            `data:image/${path.extname(file).slice(1).replace("jpg", "jpeg")};base64,${(await fs.readFile(target)).toString("base64")}`;
        }
      return { name, content, images };
    }
    if (action === "remove") {
      await fs.rm(folder, { recursive: true, force: true });
      return { name };
    }
    if (action === "save") {
      if (typeof input.content !== "string" || input.content.length > 1000000)
        throw new Error("模板正文不合规");
      if (
        !Array.isArray(input.images || []) ||
        (input.images || []).length > 40
      )
        throw new Error("模板最多 40 张图片");
      if (
        (input.images || []).some(
          (image) =>
            typeof image.data !== "string" ||
            image.data.length > 28 * 1024 * 1024,
        )
      )
        throw new Error("模板图片超过 20 MB");
      const images = (input.images || []).map((image) => ({
        name: safeName(image.name),
        buffer: Buffer.from(
          String(image.data).replace(/^data:[^,]*,/, ""),
          "base64",
        ),
      }));
      if (
        images.some(
          (image) =>
            !/^.*\.(png|jpe?g|gif|webp)$/i.test(image.name) ||
            image.buffer.length > 20 * 1024 * 1024,
        )
      )
        throw new Error("模板图片不合规");
      const temp = path.join(
        root,
        ".tmp-" + require("node:crypto").randomUUID(),
      );
      const backup = path.join(
        root,
        ".old-" + require("node:crypto").randomUUID(),
      );
      await fs.mkdir(temp);
      try {
        await fs.writeFile(path.join(temp, "模板.md"), input.content, "utf8");
        for (const image of images)
          await fs.writeFile(path.join(temp, image.name), image.buffer);
        let previous = false;
        try {
          await fs.rename(folder, backup);
          previous = true;
        } catch (e) {
          if (e.code !== "ENOENT") throw e;
        }
        try {
          await fs.rename(temp, folder);
        } catch (e) {
          if (previous) await fs.rename(backup, folder);
          throw e;
        }
        if (previous) await fs.rm(backup, { recursive: true });
      } finally {
        await fs.rm(temp, { recursive: true, force: true });
      }
      return { name };
    }
    throw new Error("未知模板操作");
  }
}
module.exports = { Library, safeName, within, atomicJson };
