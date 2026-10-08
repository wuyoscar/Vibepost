"use strict";

const test = require("node:test");
const assert = require("node:assert/strict");
const { EventEmitter } = require("node:events");
const { CardRasterService, validateRequest, LIMITS } = require("../lib/card-raster.cjs");

const image = "data:image/png;base64,eA==";
const request = (patch = {}) => ({ pages: [{ html: "<article>正文</article>" }], style: ".mc-page{width:864px;height:1152px}", width: 864, height: 1152, scale: 2, ...patch });
const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));
function png(width, height) {
  const bytes = Buffer.alloc(24);
  Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]).copy(bytes);
  bytes.write("IHDR", 12);
  bytes.writeUInt32BE(width, 16);
  bytes.writeUInt32BE(height, 20);
  return bytes.toString("base64");
}

function browserFixture(settings = {}) {
  const windows = [];
  class BrowserWindow {
    constructor(options) {
      this.options = options;
      this.dead = false;
      this.failNext = false;
      this.stall = settings.stall === true;
      this.media = new Set();
      this.operations = [];
      this.webContents = new EventEmitter();
      Object.assign(this.webContents, {
        setWindowOpenHandler: (handler) => { this.open = handler; },
        setAudioMuted: () => {}, setZoomMode: () => {}, setZoomFactor: () => {},
        debugger: {
          attach: () => {},
          sendCommand: async (name, params) => {
            this.operations.push({ name, params });
            if (name === "Emulation.setDeviceMetricsOverride") this.scale = params.deviceScaleFactor;
            if (name === "Page.captureScreenshot") {
              if (this.failNext) { this.failNext = false; throw new Error("GPU capture failed"); }
              if (this.stall) return await new Promise(() => {});
              return { data: png(params.clip.width * this.scale, params.clip.height * this.scale) };
            }
          },
        },
        executeJavaScript: async (source) => {
          if (source.startsWith("Boolean(")) return true;
          const parsed = /^window\.mcRaster\.(\w+)\(\.\.\.([\s\S]*)\)$/.exec(source);
          const args = JSON.parse(parsed[2]);
          this.operations.push({ name: parsed[1], args });
          if (parsed[1] === "setup") {
            Object.keys(args[1]).forEach((id) => this.media.add(id));
            return { generation: `generation-${windows.indexOf(this)}`, missing: args[2].filter((id) => !this.media.has(id)) };
          }
          if (parsed[1] === "show") {
            await sleep(5);
            return { width: 864, height: 1152 };
          }
          if (parsed[1] === "chrome") return [{ x: 8, y: 1110, width: 830, height: 42 }];
        },
      });
      windows.push(this);
    }
    async loadURL(url) { this.url = url; }
    isDestroyed() { return this.dead; }
    destroy() { this.dead = true; }
  }
  return { BrowserWindow, windows };
}

test("raster input rejects invalid media, sizes and unbounded batches before creating a window", async () => {
  const fixture = browserFixture();
  const service = new CardRasterService(fixture);
  for (const patch of [
    { width: "864" }, { height: 5000 }, { scale: 4 }, { scale: 0 }, { pages: [] },
    { pages: Array(LIMITS.pages + 1).fill("<p>x</p>") },
    { pages: [{ html: "x", full: "false" }] },
    { pages: [{ html: "x", chrome: { head: 10 } }] },
    { pages: [{ html: "x", arbitrary: true }] },
    { style: 1 }, { method: "pdf" },
    { media: { x: "file:///C:/secret.png" } },
    { media: { x: "https://example.com/image.png" } },
    { media: { x: "mediacraft://app/index.html" } },
    { media: { x: "data:text/html;base64,eA==" } },
    { media: { x: "data:image/png;base64,invalid!" } },
    { mediaIds: [3] }, { unknown: "field" },
  ]) await assert.rejects(service.render("1:0", request(patch)), { code: "RASTER_BAD_REQUEST" });
  assert.equal(fixture.windows.length, 0);
  assert.deepEqual(validateRequest(request({ pages: ["<p>旧版页面</p>"] })).pages[0], { html: "<p>旧版页面</p>", chrome: undefined, full: true });
  await assert.rejects(service.render("1:0", request({ style: "x".repeat(LIMITS.styleBytes + 1) })), { code: "RASTER_BAD_REQUEST" });
  await assert.rejects(service.render("1:0", request({ media: { x: `data:image/png;base64,${"x".repeat(LIMITS.imageBytes)}` } })), { code: "RASTER_BAD_REQUEST" });
  service.dispose();
});

test("raster host uses actual device pixels and returns chrome strips at the same scale", async () => {
  const fixture = browserFixture();
  const service = new CardRasterService(fixture);
  const rendered = await service.render("1:0", request({ pages: [{ html: "x", chrome: { foot: "第2页" } }] }));
  const view = fixture.windows[0];
  const pngBytes = Buffer.from(rendered.pages[0].png, "base64");
  assert.equal(pngBytes.readUInt32BE(16), 1728);
  assert.equal(pngBytes.readUInt32BE(20), 2304);
  const strip = rendered.pages[0].strips[0];
  const stripBytes = Buffer.from(strip.png, "base64");
  assert.equal(stripBytes.readUInt32BE(16), strip.width * 2);
  assert.equal(stripBytes.readUInt32BE(20), strip.height * 2);
  assert.equal(rendered.times.length, 1);
  assert.ok(rendered.totalMs >= rendered.times[0]);
  assert.equal(view.options.show, false);
  assert.equal(view.options.webPreferences.preload, undefined);
  assert.equal(view.options.webPreferences.nodeIntegration, false);
  assert.equal(view.options.webPreferences.sandbox, true);
  assert.equal(view.options.webPreferences.backgroundThrottling, false);
  assert.equal(view.options.webPreferences.offscreen, true);
  assert.deepEqual(view.open(), { action: "deny" });
  let prevented = false;
  view.webContents.emit("will-navigate", { preventDefault() { prevented = true; } }, "https://example.com");
  assert.equal(prevented, true);
  const partial = await service.render("1:0", request({ pages: [{ html: "x", full: false, chrome: { foot: "第3页" } }] }));
  assert.equal(partial.pages[0].png, undefined);
  assert.equal(partial.pages[0].strips.length, 1);
  service.dispose();
});

test("missing-media negotiation keeps its generation and owner caches remain separate", async () => {
  const fixture = browserFixture();
  const service = new CardRasterService(fixture);
  let missing;
  try { await service.render("1:0", request({ mediaIds: ["photo"] })); }
  catch (error) { missing = error; }
  assert.equal(missing.status, 409);
  assert.deepEqual(missing.missing, ["photo"]);
  assert.ok(missing.generation);
  const one = await service.render("1:0", request({ media: { photo: image }, mediaIds: ["photo"] }));
  assert.equal(one.generation, missing.generation);
  assert.equal(fixture.windows.length, 1);
  await service.render("1:0", request({ mediaIds: ["photo"] }));
  await assert.rejects(service.render("2:0", request({ mediaIds: ["photo"] })), { code: "RASTER_MISSING_MEDIA" });
  const two = await service.render("2:0", request({ media: { photo: image }, mediaIds: ["photo"] }));
  assert.notEqual(two.generation, one.generation);
  service.release("1:0");
  assert.equal(fixture.windows[0].dead, true);
  assert.equal(fixture.windows[1].dead, false);
  service.dispose();
  assert.equal(fixture.windows[1].dead, true);
});

test("concurrent pages cannot interleave setup/show/chrome and a failure does not poison the queue", async () => {
  const fixture = browserFixture();
  const service = new CardRasterService(fixture);
  const a = service.render("1:0", request({ pages: [{ html: "A", chrome: { head: "A header" } }] }));
  const b = service.render("1:0", request({ pages: [{ html: "B", chrome: { head: "B header" } }] }));
  await Promise.all([a, b]);
  const view = fixture.windows[0];
  assert.deepEqual(view.operations.filter((item) => ["setup", "show", "chrome"].includes(item.name)).map((item) => item.name), ["setup", "show", "chrome", "setup", "show", "chrome"]);
  view.failNext = true;
  const failed = service.render("1:0", request());
  const recovered = service.render("1:0", request());
  await assert.rejects(failed, /GPU capture failed/);
  const next = await recovered;
  assert.equal(view.dead, true);
  assert.equal(fixture.windows.length, 2);
  assert.equal(next.generation, "generation-1");
  service.dispose();
});

test("timed-out captures rebuild the host and releasing an owner cancels running and queued work", async () => {
  const fixture = browserFixture();
  const service = new CardRasterService({ ...fixture, pageTimeout: 30 });
  await service.render("1:0", request());
  fixture.windows[0].stall = true;
  await assert.rejects(service.render("1:0", request()), (error) => {
    assert.equal(error.code, "RASTER_TIMEOUT");
    assert.deepEqual(error.missing, []);
    assert.equal(error.generation, undefined);
    return true;
  });
  assert.equal(fixture.windows[0].dead, true);
  await service.render("1:0", request());
  fixture.windows[1].stall = true;
  const running = service.render("1:0", request());
  const queued = service.render("1:0", request());
  await sleep(10);
  service.release("1:0");
  await assert.rejects(running, { code: "RASTER_CLOSED" });
  await assert.rejects(queued, { code: "RASTER_CLOSED" });
  assert.equal(fixture.windows[1].dead, true);
  service.dispose();
  await assert.rejects(service.render("2:0", request()), { code: "RASTER_CLOSED" });
});

test("the host limit evicts least-recently-used idle editors and their media can be resent", async () => {
  const fixture = browserFixture();
  const service = new CardRasterService(fixture);
  let originalGeneration;
  for (let owner = 0; owner < LIMITS.owners + 2; owner++) {
    const result = await service.render(`${owner}:0`, request(owner === 0 ? { media: { photo: image }, mediaIds: ["photo"] } : {}));
    if (owner === 0) originalGeneration = result.generation;
  }
  assert.equal(service.contexts.size, LIMITS.owners);
  assert.equal(fixture.windows.length, LIMITS.owners + 2);
  assert.equal(fixture.windows[0].dead, true);
  assert.equal(fixture.windows[1].dead, true);
  assert.equal(service.contexts.has("0:0"), false);
  let missing;
  try { await service.render("0:0", request({ mediaIds: ["photo"] })); }
  catch (error) { missing = error; }
  assert.equal(missing.code, "RASTER_MISSING_MEDIA");
  assert.notEqual(missing.generation, originalGeneration);
  assert.deepEqual(missing.missing, ["photo"]);
  const resent = await service.render("0:0", request({ media: { photo: image }, mediaIds: ["photo"] }));
  assert.equal(resent.generation, missing.generation);
  service.dispose();
});

test("only idle hosts can be evicted and an all-active host pool reports busy", async () => {
  const settings = { stall: true };
  const fixture = browserFixture(settings);
  const service = new CardRasterService({ ...fixture, pageTimeout: 1000 });
  const running = Array.from({ length: LIMITS.owners }, (_, id) => service.render(`${id}:0`, request()));
  const settled = Promise.allSettled(running);
  await sleep(15);
  assert.equal(fixture.windows.length, LIMITS.owners);
  await assert.rejects(service.render("8:0", request()), { code: "RASTER_BUSY" });
  assert.equal(fixture.windows.filter((view) => view.dead).length, 0);
  service.release("7:0");
  settings.stall = false;
  await service.render("8:0", request());
  await service.render("9:0", request());
  assert.equal(service.contexts.has("8:0"), false);
  assert.equal(service.contexts.has("9:0"), true);
  assert.ok(fixture.windows.slice(0, 7).every((view) => !view.dead));
  service.dispose();
  assert.ok((await settled).every((result) => result.status === "rejected" && result.reason.code === "RASTER_CLOSED"));
});

test("late crash events from a replaced host cannot destroy the new host", async () => {
  const fixture = browserFixture();
  const service = new CardRasterService(fixture);
  await service.render("1:0", request());
  const old = fixture.windows[0];
  old.failNext = true;
  await assert.rejects(service.render("1:0", request()), /GPU capture failed/);
  const rebuilt = await service.render("1:0", request());
  const replacement = fixture.windows[1];
  old.webContents.emit("render-process-gone", {}, { reason: "crashed" });
  assert.equal(replacement.dead, false);
  assert.equal(service.contexts.get("1:0").window, replacement);
  assert.equal((await service.render("1:0", request())).generation, rebuilt.generation);
  replacement.webContents.emit("render-process-gone", {}, { reason: "crashed" });
  assert.equal(replacement.dead, true);
  assert.equal(service.contexts.get("1:0").window, null);
  service.dispose();
});

test("only host timeouts request a bounded media resend and a rebuilt host returns full pixels", async () => {
  const fixture = browserFixture();
  const service = new CardRasterService({ ...fixture, pageTimeout: 30 });
  const original = await service.render("1:0", request({ media: { photo: image }, mediaIds: ["photo"] }));
  fixture.windows[0].stall = true;
  let failure;
  try { await service.render("1:0", request({ mediaIds: ["photo"] })); }
  catch (error) { failure = error; }
  assert.equal(failure.name, "CardRasterError");
  assert.equal(failure.code, "RASTER_TIMEOUT");
  assert.match(failure.message, /超时/);
  assert.deepEqual(failure.missing, ["photo"]);
  assert.equal(failure.generation, undefined);
  const recovered = await service.render("1:0", request({ media: { photo: image }, mediaIds: failure.missing }));
  assert.notEqual(recovered.generation, original.generation);
  const bytes = Buffer.from(recovered.pages[0].png, "base64");
  assert.equal(bytes.readUInt32BE(16), 1728);
  assert.equal(bytes.readUInt32BE(20), 2304);
  fixture.windows[1].failNext = true;
  await assert.rejects(service.render("1:0", request()), (error) => {
    assert.match(error.message, /GPU capture failed/);
    assert.equal(error.missing, undefined);
    return true;
  });
  service.dispose();
});
