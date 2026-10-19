"use strict";
const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs/promises");
const path = require("node:path");
const os = require("node:os");
const { seedWritingManuals } = require("../lib/writing-manuals.cjs");
const { Library } = require("../lib/storage.cjs");
const webRoot = path.resolve(__dirname, "../..");
const source = path.join(webRoot, "src/writing-manuals");

test("upgrade adds skills once, preserving edits and deletions across Library and AI initialization", async () => {
  const root = await fs.mkdtemp(path.join(os.tmpdir(), "vibepost-skills-"));
  try {
    const folder = path.join(root, "写作手册");
    await fs.mkdir(folder);
    await fs.writeFile(path.join(folder, "标题打磨.md"), "我的标题方法");
    const library = new Library(root, webRoot);
    await Promise.all([library.seed(), seedWritingManuals(folder, source)]);
    assert.equal((await library.manuals("read", { name: "标题打磨" })).content, "我的标题方法");
    const names = (await library.manuals("list")).manuals.map(m => m.name);
    assert.ok(names.includes("保留原意去AI味"));
    assert.ok(!names.includes("国际新闻"));
    await fs.unlink(path.join(folder, "观点长文.md"));
    await Promise.all([library.seed(), seedWritingManuals(folder, source)]);
    await assert.rejects(fs.stat(path.join(folder, "观点长文.md")), { code: "ENOENT" });
  } finally { await fs.rm(root, { recursive: true, force: true }); }
});

test("new install exposes all seven complete manuals through the shared bridge library", async () => {
  const root = await fs.mkdtemp(path.join(os.tmpdir(), "vibepost-skills-"));
  try {
    const library = new Library(root, webRoot);
    await library.seed();
    const { manuals } = await library.manuals("list");
    assert.equal(manuals.length, 7);
    for (const { name, description } of manuals) {
      assert.ok(description);
      const { content } = await library.manuals("read", { name });
      assert.ok(content.length > 300);
      assert.ok(!content.includes("/Users/"));
      assert.ok(!/\]\(references\//.test(content));
    }
  } finally { await fs.rm(root, { recursive: true, force: true }); }
});
