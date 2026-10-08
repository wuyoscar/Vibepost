"use strict";
const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs/promises");
const path = require("node:path");
const os = require("node:os");
const { WindowState } = require("../lib/window-state.cjs");
const { Library, safeName, within, atomicJson } = require("../lib/storage.cjs");
test("library serializes concurrent template replacements and caps image counts", async () => {
  const dir = await fs.mkdtemp(path.join(os.tmpdir(), "vibepost-library-"));
  try {
    const library = new Library(dir, path.resolve(__dirname, "../.."));
    await Promise.all(
      Array.from({ length: 8 }, (_, i) =>
        library.templates("save", {
          name: "并发模板",
          content: String(i),
          images: [],
        }),
      ),
    );
    assert.equal(
      (await library.templates("read", { name: "并发模板" })).content,
      "7",
    );
    assert.deepEqual(await fs.readdir(library.folder("templates")), [
      "并发模板",
    ]);
    await assert.rejects(
      library.templates("save", {
        name: "太多",
        content: "x",
        images: Array.from({ length: 41 }, (_, i) => ({
          name: i + ".png",
          data: "eA==",
        })),
      }),
      /40/,
    );
    await Promise.all(
      Array.from({ length: 8 }, (_, i) =>
        library.manuals("save", { name: "并发手册", content: String(i) }),
      ),
    );
    assert.equal((await library.manuals("list")).manuals.length, 1);
    assert.equal(
      (await library.manuals("read", { name: "并发手册" })).content,
      "7",
    );
  } finally {
    await fs.rm(dir, { recursive: true, force: true });
  }
});
test("window ownership rejects collisions, out-of-order reports and stale epochs", () => {
  const s = new WindowState();
  s.add(1);
  s.add(2);
  const a = s.owner(1),
    b = s.owner(2);
  s.occupy(a, { page: "p", sequence: 2, current: "a", drafts: ["a"] });
  assert.deepEqual(
    s.occupy(a, { page: "p", sequence: 1, current: "b", drafts: ["b"] }),
    { ignored: true },
  );
  assert.throws(() =>
    s.occupy(b, { page: "q", sequence: 1, current: "a", drafts: ["a"] }),
  );
  s.reload(1);
  assert.throws(() => s.assert(a));
  assert.equal(s.holder("a"), undefined);
});
test("Windows names and directory boundaries reject traversal and device names", () => {
  for (const name of ["..", "CON", "NUL.png", "a/b", "a\\b", "a.", " a", ""])
    assert.throws(() => safeName(name));
  assert.equal(safeName("中文模板"), "中文模板");
  assert.equal(within("/app/web", "/app/web-evil/file"), false);
});
test("concurrent state persistence serializes atomic replacements on Windows", async () => {
  const dir = await fs.mkdtemp(path.join(os.tmpdir(), "vibepost-state-"));
  try {
    const file = path.join(dir, "windows.json");
    await Promise.all(
      Array.from({ length: 12 }, (_, i) => atomicJson(file, [i])),
    );
    assert.deepEqual(JSON.parse(await fs.readFile(file, "utf8")), [11]);
    assert.deepEqual(await fs.readdir(dir), ["windows.json"]);
  } finally {
    await fs.rm(dir, { recursive: true, force: true });
  }
});
test("template round trip retains raw base64 images and manual metadata", async () => {
  const dir = await fs.mkdtemp(path.join(os.tmpdir(), "vibepost-host-"));
  try {
    const lib = new Library(dir, dir);
    await lib.templates("save", {
      name: "测试",
      content: "# card",
      images: [{ name: "a.png", data: "aGVsbG8=" }],
    });
    const result = await lib.templates("read", { name: "测试" });
    assert.equal(result.images["a.png"], "data:image/png;base64,aGVsbG8=");
    await lib.manuals("save", {
      name: "手册",
      description: "写作方式",
      content: "正文",
    });
    assert.equal((await lib.manuals("read", { name: "手册" })).content, "正文");
    await assert.rejects(lib.templates("save", { name: "..", content: "bad" }));
    await lib.templates("remove", { name: "测试" });
  } finally {
    await fs.rm(dir, { recursive: true, force: true });
  }
});
