"use strict";
const { _electron: electron } = require("playwright");
const fs = require("node:fs/promises");
const path = require("node:path");
const assert = require("node:assert/strict");
const { environment, windows, root } = require("../scripts/paths.cjs");
async function main() {
  const data =
    process.env.VIBEPOST_TEST_DATA || path.join(root, ".scratch", "app-smoke");
  await fs.mkdir(data, { recursive: true });
  const env = environment();
  delete env.ELECTRON_RUN_AS_NODE;
  Object.assign(process.env, env);
  const application = await electron.launch({
    executablePath:
      process.env.VIBEPOST_TEST_EXE ||
      (await require("../scripts/runtime.cjs").main()),
    args: [
      ...(process.env.VIBEPOST_TEST_EXE ? [] : [windows]),
      "--data-dir",
      data,
    ],
    env,
    timeout: 60000,
  });
  const errors = [];
  const checks = [];
  try {
    const page = await application.firstWindow();
    page.on("pageerror", (error) => errors.push(error.message));
    page.on("console", (msg) => {
      if (msg.type() === "error")
        console.error("renderer:", msg.text().slice(0, 500));
    });
    await page.waitForFunction(
      () => window.mediacraft && window.MediaCraftDrafts.currentId(),
      { timeout: 60000 },
    );
    const info = await page.evaluate(async () => ({
      native: !!window.MediaCraftNative.ai,
      origin: location.origin,
      version: (await window.MediaCraftNative.windows.appInfo()).version,
      tools: await window.MediaCraftMCP.handle(
        JSON.stringify({ session: "test", method: "tools/list" }),
      ),
    }));
    assert.equal(info.origin, "mediacraft://app");
    assert.equal(
      info.version,
      (await fs.readFile(path.join(root, "VERSION"), "utf8")).trim(),
    );
    assert(info.native);
    assert(
      JSON.parse(info.tools).result.tools.some(
        (t) => t.name === "send_to_phone",
      ),
    );
    checks.push("shared frontend, stable origin, version and capabilities");
    const assetPaths = [
      "/index.html",
      "/VERSION",
      "/__windows/browser/host.js",
      "/__windows/renderer/phone-transfer.css",
      "/__windows/vendor/pdf/pdf.mjs",
      "/src/native-bridge.js",
      "/fonts/fonts.css",
      "/brand/app-icon-256.png",
      "/docs/guide-assets/valley-morning.jpg",
    ];
    const traversalPaths = [
      "/__windows/browser/%2f../main.cjs",
      "/__windows/browser/..%2fmain.cjs",
      "/__windows/browser/%5c..%5cmain.cjs",
      "/__windows/renderer/%5c..%5cpreload.cjs",
      "/__windows/vendor/pdf/%2f..%2ficon.ico",
      "/src/%2f..%2fVERSION",
      "/fonts/%5c..%5cVERSION",
      "/brand/%2f..%2fVERSION",
      "/docs/guide-assets/%5c..%5c..%5cVERSION",
      "/docs/template-assets/%2f..%2f..%2fVERSION",
    ];
    const assets = await page.evaluate(async (paths) => {
      return Promise.all(paths.map(async (asset) => {
        const response = await fetch(asset);
        return { asset, status: response.status, bytes: (await response.arrayBuffer()).byteLength };
      }));
    }, [...assetPaths, ...traversalPaths]);
    for (const result of assets.slice(0, assetPaths.length)) {
      assert.equal(result.status, 200, `normal asset: ${result.asset}`);
      assert(result.bytes > 0, `empty asset: ${result.asset}`);
    }
    for (const result of assets.slice(assetPaths.length)) {
      assert.equal(result.status, 403, `directory traversal: ${result.asset}`);
    }
    checks.push("static asset directory boundaries and encoded traversal rejection");
    const draft = await page.evaluate(async () => {
      await window.mediacraft.drafts.create({
        title: "Windows smoke",
        markdown: "# 测试标题\n\n共享前端与 Windows 保存。",
        caption: "测试文案",
      });
      await window.mediacraft.drafts.saveNow();
      return await window.mediacraft.drafts.current();
    });
    assert.match(draft.markdown, /Windows|Windows 保存/);
    checks.push("draft create/edit/save");
    const png = await page.evaluate(async () => {
      let saved;
      await window.mediacraft.output.exportPng(0, {
        save: async (blob, name) => {
          saved = { type: blob.type, size: blob.size };
          return name;
        },
      });
      return saved;
    });
    assert.equal(png.type, "image/png");
    assert(png.size > 1000);
    checks.push("real PNG raster/export");
    const zip = await page.evaluate(async () => {
      let saved;
      await window.mediacraft.output.exportZip({
        save: async (blob, name) => {
          saved = { type: blob.type, size: blob.size };
          return name;
        },
      });
      return saved;
    });
    assert(zip.size > 1000);
    checks.push("real ZIP export");
    const savePath = path.join(data, "dialog-save.png");
    await application.evaluate(({ dialog }, file) => {
      dialog.showSaveDialog = async () => ({ canceled: false, filePath: file });
    }, savePath);
    await page.evaluate(() => window.mediacraft.output.exportPng(0));
    assert.deepEqual(
      (await fs.readFile(savePath)).subarray(0, 8),
      Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]),
    );
    await application.evaluate(({ dialog }) => {
      dialog.showSaveDialog = async () => ({ canceled: true });
    });
    await assert.rejects(
      page.evaluate(() => window.mediacraft.output.exportPng(0)),
      /已取消保存/,
    );
    checks.push("native file save and canceled dialog propagation");
    checks.push(await require("./app-motion.cjs").motion({ page, data }));
    const phone = await page.evaluate(async () => {
      const result = await window.MediaCraftNative.sendToPhone(
        [
          {
            name: "test.png",
            blob: new Blob([new Uint8Array([1, 2, 3])], { type: "image/png" }),
          },
        ],
        "测试文案",
        { title: "Smoke" },
      );
      return result;
    });
    assert((await fetch(phone.url)).ok);
    await page.evaluate(
      (session) => window.MediaCraftNative.stopPhoneTransfer(session),
      phone.session,
    );
    await assert.rejects(fetch(phone.url));
    checks.push("LAN token transfer and stop");
    // Minimal one-page PDF uses a text stream and exercises the shipped PDF.js worker.
    const pdf =
      "%PDF-1.4\n1 0 obj<</Type/Catalog/Pages 2 0 R>>endobj\n2 0 obj<</Type/Pages/Kids[3 0 R]/Count 1>>endobj\n3 0 obj<</Type/Page/Parent 2 0 R/MediaBox[0 0 200 200]/Resources<</Font<</F1 4 0 R>>>>/Contents 5 0 R>>endobj\n4 0 obj<</Type/Font/Subtype/Type1/BaseFont/Helvetica>>endobj\n5 0 obj<</Length 36>>stream\nBT /F1 18 Tf 20 100 Td (PDF) Tj ET\nendstream\nendobj\ntrailer<</Root 1 0 R>>\n%%EOF";
    const pages = await page.evaluate(async (raw) => {
      const items = await window.MediaCraftNative.pdfToImages(
        new Blob([raw], { type: "application/pdf" }),
      );
      return items.map((b) => ({ size: b.size, type: b.type }));
    }, pdf);
    assert.equal(pages.length, 1);
    assert(pages[0].size > 100);
    checks.push("real PDF import");
    const opened = application.waitForEvent("window");
    await page.evaluate(() => window.MediaCraftNative.windows.open({}));
    await opened;
    const second = application.windows().find((p) => p !== page && p.url().startsWith("mediacraft://app/index.html"));
    await second.waitForFunction(
      () => window.mediacraft && window.MediaCraftDrafts.currentId(),
    );
    const claim = await second.evaluate(
      (id) =>
        window.MediaCraftNative.windows.claim({ draftId: id, focus: false }),
      draft.id,
    );
    assert.equal(claim.elsewhere, true);
    await assert.rejects(
      second.evaluate((id) => window.MediaCraftNative.ai.remove(id), draft.id),
      /没有打开/,
    );
    checks.push("multiwindow draft ownership and IPC rejection");
    await page.reload();
    await page.waitForFunction(
      () => window.mediacraft && window.MediaCraftDrafts.currentId(),
    );
    const restored = await page.evaluate(() =>
      window.mediacraft.drafts.current(),
    );
    assert.equal(restored.id, draft.id);
    assert.equal(restored.markdown, draft.markdown);
    checks.push("draft persistence after reload");
    await page.evaluate(() => window.MediaCraftNative.mcp.setEnabled(true));
    // Use the keyboard path so small hosted desktops do not overlap the toolbar.
    await page.locator("#aiButton").press("Enter");
    await page.locator("#aiSettings > summary").press("Enter");
    const registration = await page.evaluate(() => window.MediaCraftNative.mcp.status());
    await page.locator("#mcpCopyBtn").press("Enter");
    await page.waitForFunction(() => document.querySelector("#statusText").textContent.includes("已复制接入命令"));
    assert.equal(await application.evaluate(({ clipboard }) => clipboard.readText()), registration.command);
    await page.locator("#mcpCopyCodexBtn").press("Enter");
    await page.waitForFunction(() => document.querySelector("#statusText").textContent.includes("已复制 Codex 配置"));
    assert.equal(await application.evaluate(({ clipboard }) => clipboard.readText()), registration.codexConfig);
    assert.match(registration.codexConfig, /\[mcp_servers\.mediacraft\]/);
    assert.match(registration.codexConfig, /--data-dir/);
    await page.locator("#aiSettings > summary").press("Enter");
    const mcpChecks = await require("./mcp-app.cjs").run({
      application,
      page,
      data,
    });
    assert.equal(mcpChecks.ok, true);
    checks.push(
      "MCP Claude/Codex clipboard registration and real stdio create/update/bound-window/PNG/ZIP/overwrite/disable",
    );
    await fs.writeFile(
      path.join(data, "mcp-report.json"),
      JSON.stringify(mcpChecks, null, 2),
    );
    await page.screenshot({ path: path.join(data, "windows-smoke.png") });
    assert.deepEqual(errors, []);
    await fs.writeFile(
      path.join(data, "report.json"),
      JSON.stringify(
        { ok: true, checks, errors, version: info.version },
        null,
        2,
      ),
    );
    console.log(JSON.stringify({ ok: true, checks }, null, 2));
  } finally {
    await application.close();
  }
}
main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
