"use strict";
const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs/promises");
const path = require("node:path");
const os = require("node:os");
const { seedWritingManuals } = require("../lib/writing-manuals.cjs");
const { Library } = require("../lib/storage.cjs");
const webRoot = path.resolve(__dirname, "../..");

test("new install creates an empty writing-manual folder: the app bundles no manuals (the built-in writing skill is src/skills/)", async () => {
  const root = await fs.mkdtemp(path.join(os.tmpdir(), "vibepost-skills-"));
  try {
    const library = new Library(root, webRoot);
    await Promise.all([library.seed(), seedWritingManuals(path.join(root, "写作手册"))]);
    assert.deepEqual(await fs.readdir(path.join(root, "写作手册")), []);
    assert.deepEqual((await library.manuals("list")).manuals, []);
  } finally { await fs.rm(root, { recursive: true, force: true }); }
});

test("existing manuals (including examples an older version installed) stay listed and untouched; nothing is added back or removed", async () => {
  const root = await fs.mkdtemp(path.join(os.tmpdir(), "vibepost-skills-"));
  try {
    const folder = path.join(root, "写作手册");
    await fs.mkdir(folder);
    await fs.writeFile(path.join(folder, "标题打磨.md"), "我的标题方法");
    await fs.writeFile(path.join(folder, "菜谱.md"), "---\nname: 菜谱\ndescription: 家常菜谱\n---\n\n先写用料。\n");
    await fs.writeFile(path.join(folder, ".bundled-writing-manuals.json"), JSON.stringify(["标题打磨.md"]));
    const library = new Library(root, webRoot);
    await Promise.all([library.seed(), seedWritingManuals(folder)]);
    assert.equal((await library.manuals("read", { name: "标题打磨" })).content, "我的标题方法");
    assert.deepEqual((await library.manuals("list")).manuals.map((m) => m.name).sort(), ["标题打磨", "菜谱"].sort());
    assert.deepEqual((await fs.readdir(folder)).sort(), [".bundled-writing-manuals.json", "标题打磨.md", "菜谱.md"].sort());
  } finally { await fs.rm(root, { recursive: true, force: true }); }
});
