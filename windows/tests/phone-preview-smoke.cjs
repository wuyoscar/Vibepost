"use strict";
// Real Electron regression: inspect rendered pixels as well as the carousel DOM.
// Each run owns its data directory and closes only the Electron process it starts.
const { _electron: electron } = require("playwright");
const fs = require("node:fs/promises");
const path = require("node:path");
const assert = require("node:assert/strict");
const { environment, windows, root } = require("../scripts/paths.cjs");

async function main() {
  const data = path.resolve(process.env.VIBEPOST_TEST_DATA || path.join(root, ".scratch", "phone-preview-smoke"));
  const report = { ok: false, label: process.env.VIBEPOST_TEST_LABEL || "phone-preview", checks: [], errors: [], scenarios: [], startup: { events: [] } };
  let application, page, diagnosticTimer, child;
  let stage = "launch", recordingWindows = false, finishing = false;
  const windowStates = [];
  await fs.mkdir(data, { recursive: true });
  async function check(name, task) {
    stage = name;
    try { await task(); report.checks.push(name); console.log("PASS", name); }
    catch (error) {
      report.errors.push({ name, message: error.message, stack: error.stack });
      console.error("FAIL", name, error.message);
    }
  }
  try {
    const env = environment();
    delete env.ELECTRON_RUN_AS_NODE;
    const dpr = Number(process.env.VIBEPOST_TEST_DPR || 1);
    const executablePath = process.env.VIBEPOST_TEST_EXE || await require("../scripts/runtime.cjs").main();
    report.startup.launchAt = new Date().toISOString();
    application = await electron.launch({ executablePath, args: [...(process.env.VIBEPOST_TEST_EXE ? [] : [windows]), "--data-dir", data, `--force-device-scale-factor=${dpr}`], env, timeout: 60000 });
    const startupLog = (source, message) => {
      if (report.startup.events.length < 400) report.startup.events.push({ at: new Date().toISOString(), source, message: String(message).slice(0, 4000) });
    };
    application.on("console", message => startupLog(`main:${message.type()}`, message.text()));
    child = application.process();
    child.stdout?.on("data", chunk => startupLog("stdout", chunk));
    child.stderr?.on("data", chunk => startupLog("stderr", chunk));
    child.once("exit", (code, signal) => startupLog("process-exit", JSON.stringify({ code, signal })));
    application.on("window", window => startupLog("window", window.url()));
    // Read-only telemetry helps locate a stalled screenshot host without waiting
    // for another executeJavaScript call in that host's renderer.
    async function recordWindows() {
      if (recordingWindows) return;
      recordingWindows = true;
      try {
        const state = await withDeadline(application.evaluate(({ BrowserWindow }) => BrowserWindow.getAllWindows().map(window => ({
          id: window.id, url: window.webContents.getURL(), loading: window.webContents.isLoading(),
          debuggerAttached: window.webContents.debugger.isAttached(), destroyed: window.isDestroyed(), visible: window.isVisible(), clientSize: window.getContentSize(),
        }))), 5000, "Window telemetry");
        windowStates.push({ at: new Date().toISOString(), stage, windows: state });
        await fs.writeFile(path.join(data, "raster-window-states.json"), JSON.stringify(windowStates, null, 2));
        return true;
      } catch (error) {
        if (!finishing) {
          clearInterval(diagnosticTimer);
          report.errors.push({ name: "window telemetry", stage, message: error.message });
        }
        return false;
      }
      finally { recordingWindows = false; }
    }
    // Do not evaluate the main process during initial navigation: the preload
    // needs synchronous IPC before Playwright announces the first page. A CI
    // failure showed an existing, blank/loading BrowserWindow until cleanup
    // while this observer was polling the main inspector every two seconds.
    stage = "waiting for editor window";
    const editorDeadline = Date.now() + 60000;
    await application.firstWindow({ timeout: 60000 });
    page = await waitForEditorWindow(application, Math.max(1, editorDeadline - Date.now()));
    report.startup.editorAt = new Date().toISOString();
    report.startup.editorUrl = page.url();
    page.setDefaultTimeout(60000);
    page.on("pageerror", error => report.errors.push({ name: "renderer error", stage, at: new Date().toISOString(), message: error.message, stack: error.stack }));
    page.on("console", message => { if (message.type() === "error") console.error("renderer:", message.text().slice(0, 1000)); });
    await page.waitForFunction(() => window.mediacraft && window.MediaCraftDrafts.currentId(), null, { timeout: 60000 });
    report.startup.readyAt = new Date().toISOString();
    diagnosticTimer = setInterval(() => void recordWindows(), 2000);
    diagnosticTimer.unref();
    if (!await recordWindows()) throw new Error("Initial window telemetry failed");
    const skipTour = page.locator('[data-onboarding="skip"]');
    if (await skipTour.isVisible()) await skipTour.click();
    await application.evaluate(({ BrowserWindow }) => BrowserWindow.getAllWindows().find(window => /\/index\.html(?:\?|$)/.test(window.webContents.getURL())).setContentSize(1360, 920));
    const fixture = await page.evaluate(async () => {
      const mc = window.mediacraft;
      await mc.drafts.create({ title: "手机预览比例回归", caption: "这段是独立正文，卡片翻页不应改变它。 #比例检查 #Windows", markdown: "" });
      const canvas = document.createElement("canvas");
      canvas.width = 600; canvas.height = 300;
      const context = canvas.getContext("2d");
      context.fillStyle = "#00ff00"; context.fillRect(0, 0, 600, 300);
      // A known square inside a landscape image detects stretched pixels even
      // when the outer canvas's CSS and backing-store dimensions are correct.
      context.fillStyle = "#ff0000"; context.fillRect(200, 50, 200, 200);
      const blob = await new Promise(resolve => canvas.toBlob(resolve, "image/png"));
      const [imageId] = await mc.media.import([new File([blob], "landscape-square-marker.png", { type: "image/png" })]);
      await mc.media.update(imageId, { layout: { widthPercent: 100, align: "center" } });
      const markdown = `# 第一页：图片比例\n\n[[image:${imageId}]]\n\n红色必须是正方形，绿色图片必须是横向 2:1。\n\n[[分页]]\n\n# 第二页：文字与列表\n\n- 完整卡片宽度\n- 相同的字号和行距\n\n这是跨行的中文段落，用于检查每页在轮播中占据完整的一屏宽度。\n\n[[分页]]\n\n# 第三页：再检查图片\n\n[[image:${imageId}]]\n\n最后一页的边界与右侧翻页按钮。`;
      const themes = await mc.themes.list();
      const theme = themes.find(item => item.name.includes("备忘")) || themes[0];
      await mc.drafts.update({ markdown, theme: theme.id, imageMaxHeight: 1048, fontSize: 32, lineHeight: 1.5 });
      const avatar = document.createElement("canvas");
      avatar.width = 400; avatar.height = 200;
      const avatarContext = avatar.getContext("2d");
      avatarContext.fillStyle = "#0000ff"; avatarContext.fillRect(0, 0, 400, 200);
      avatarContext.fillStyle = "#00ffff"; avatarContext.beginPath(); avatarContext.arc(200, 100, 70, 0, Math.PI * 2); avatarContext.fill();
      await mc.profile.update({ name: "中文署名回归", handle: "preview_test", avatar: avatar.toDataURL(), avatarCrop: { x: 100, y: 0, width: 200, height: 200 } });
      const bounds = node => {
        const rect = node.getBoundingClientRect();
        return { width: rect.width, height: rect.height, x: rect.x, y: rect.y };
      };
      const dom = [...document.querySelectorAll("*")].filter(node => node.shadowRoot?.querySelector(".mc-page")).map(host => ({
        page: bounds(host.shadowRoot.querySelector(".mc-page")),
        images: [...host.shadowRoot.querySelectorAll("img")].map(image => ({ ...bounds(image), intrinsicWidth: image.naturalWidth, intrinsicHeight: image.naturalHeight })),
      }));
      return { id: (await mc.drafts.current()).id, imageId, pages: await mc.render.pages(), themeId: theme.id, themes, dpr: devicePixelRatio, dom };
    });
    report.fixture = fixture;
    stage = "fixture ready";
    console.log("Fixture ready:", fixture.pages.length, "pages, DPR", fixture.dpr);
    await settleAnimations(page);
    await page.screenshot({ path: path.join(data, "source-dom-cards.png") });
    await page.locator("#phoneButton").click();
    stage = "waiting for phone pixels";
    console.log("Phone preview opened; waiting for real raster pixels");
    await waitNote(page, fixture.pages.length);
    await check("fixture contains at least three pages", () => assert(fixture.pages.length >= 3));
    await capture(page, data, report, "note-initial");
    await check("avatar crop and Chinese byline are square and synchronized", async () => {
      await page.waitForFunction(() => document.querySelector(".phone-name").textContent === "中文署名回归");
      const avatar = await page.evaluate(() => {
        const canvas = document.querySelector(".phone-avatar");
        const rect = canvas.getBoundingClientRect();
        return { width: rect.width, height: rect.height, borderRadius: getComputedStyle(canvas).borderRadius, pixels: window.__phonePixelMetrics(canvas) };
      });
      report.avatar = avatar;
      assert(Math.abs(avatar.width - avatar.height) < 0.01);
      assert.equal(avatar.borderRadius, "50%");
      assert(avatar.pixels.cyan.count > 100);
      assert(Math.abs(avatar.pixels.cyan.width / avatar.pixels.cyan.height - 1) < 0.06, "cropped circle must remain round");
    });
    await check("note carousel geometry", async () => assertGeometry(report.scenarios.at(-1).geometry));
    await check("note rendered image keeps square and landscape proportions", async () => assertPixels(report.scenarios.at(-1).pixels));
    const full = await page.evaluate(async () => {
      const [canvas] = await window.mediacraft.render.canvases();
      return { png: canvas.toDataURL("image/png"), metrics: window.__phonePixelMetrics(canvas) };
    });
    report.fullPng = full.metrics;
    await writeDataUrl(path.join(data, "card-full.png"), full.png);
    await check("full PNG rendered image proportions", () => assertPixels(full.metrics));
    await check("phone next/previous and keyboard page boundaries", async () => {
      const total = fixture.pages.length;
      assert(await page.locator(".phone-flip-prev").isDisabled());
      for (let index = 1; index < total; index++) {
        await page.locator(".phone-flip-next").click();
        await waitSlide(page, index, total);
        assertGeometry(await geometry(page));
      }
      assert(await page.locator(".phone-flip-next").isDisabled());
      await page.locator(".phone-carousel").press("ArrowRight");
      await waitSlide(page, total - 1, total);
      await page.locator(".phone-carousel").press("ArrowLeft");
      await waitSlide(page, total - 2, total);
      for (let index = total - 3; index >= 0; index--) {
        await page.locator(".phone-carousel").press("ArrowLeft");
        await waitSlide(page, index, total);
      }
      assert(await page.locator(".phone-flip-prev").isDisabled());
    });
    await capture(page, data, report, "note-after-navigation");
    await check("horizontal wheel and pointer drag flip complete screen slots", async () => {
      const total = fixture.pages.length;
      await page.locator(".phone-carousel").hover();
      await page.mouse.wheel(120, 0);
      await waitSlide(page, 1, total);
      const box = await page.locator(".phone-carousel").boundingBox();
      const x = box.x + box.width / 2, y = box.y + box.height / 2;
      await page.mouse.move(x, y);
      await page.mouse.down();
      await page.mouse.move(x - Math.min(130, box.width * 0.4), y, { steps: 8 });
      await page.mouse.up();
      await waitSlide(page, 2, total);
      assertGeometry(await geometry(page));
      await page.mouse.move(x, y);
      await page.mouse.down();
      await page.mouse.move(x + Math.min(130, box.width * 0.4), y, { steps: 8 });
      await page.mouse.up();
      await waitSlide(page, 1, total);
      await page.locator(".phone-carousel").press("ArrowLeft");
      await waitSlide(page, 0, total);
      await capture(page, data, report, "note-after-wheel-drag");
      assertGeometry(report.scenarios.at(-1).geometry);
      assertPixels(report.scenarios.at(-1).pixels);
    });
    for (const view of ["feed", "profile"]) {
      await check(`${view} current cover geometry and image pixels`, async () => {
        await page.locator(`[data-phone-view="${view}"]`).click();
        await page.waitForFunction(view => {
          const screen = document.querySelector(`[data-phone-screen="${view}"]`);
          return !screen.hidden && screen.querySelector('[aria-current="true"] .phone-cover');
        }, view);
        await settleAnimations(page);
        await capture(page, data, report, view);
        const sample = report.scenarios.at(-1);
        assertPixels(sample.pixels);
        assert(Math.abs(sample.geometry.current.width / sample.geometry.current.height - 3 / 4) < 0.005, `${view} cover CSS ratio`);
      });
    }
    await page.locator('[data-phone-view="note"]').click();
    await waitNote(page, fixture.pages.length);
    await check("Ctrl+1/2/3 switch note, feed and profile inside phone preview", async () => {
      for (const [key, view] of [["2", "feed"], ["3", "profile"], ["1", "note"]]) {
        await page.locator("#phonePreview").focus();
        await page.locator("#phonePreview").press(`Control+${key}`);
        await page.waitForFunction(view => document.querySelector(`[data-phone-view="${view}"]`).getAttribute("aria-pressed") === "true", view);
      }
      await waitCurrentPixels(page);
    });
    await check("preview off and on retains synchronized note", async () => {
      await page.locator("#phoneButton").click();
      await page.waitForFunction(() => document.querySelector("#phonePreview").hidden && document.querySelector("#previewPanel").dataset.view === "cards");
      await page.locator("#phoneButton").click();
      await waitNote(page, fixture.pages.length);
      assert(await page.locator(".phone-title").textContent() === "手机预览比例回归");
      assert((await page.locator(".phone-body").textContent()).includes("独立正文"));
      assert((await page.locator(".phone-tags").textContent()).includes("#Windows"));
    });
    await check("real screenshot host rebuild resends cached media across contextBridge", async () => {
      await page.evaluate(() => {
        const original = window.MediaCraftNative.rasterCards;
        window.__phoneOriginalRaster = original;
        window.__phoneRasterTrace = [];
        window.__phoneRasterDiagnostics = [];
        window.MediaCraftNative.rasterCards = async request => {
          const entry = {
            at: new Date().toISOString(), mediaIds: request.mediaIds, sent: Object.keys(request.media || {}),
            request: { pages: request.pages, style: request.style, width: request.width, height: request.height, scale: request.scale },
          };
          window.__phoneRasterTrace.push(entry);
          try {
            const result = await original(request);
            Object.assign(entry, { ok: true, generation: result.generation });
            // Inspect bytes returned by the genuine bridge, before the shared
            // compositor or phone can cache/draw them. This distinguishes an
            // old native surface from an old phone thumbnail callback.
            // Only diagnose the target new-layout call. Decoding every theme
            // thumbnail here would add unrelated CPU work to the real UI.
            if (request.pages.some(page => typeof page.html === "string" && page.html.includes("--mc-img-max:220px"))) {
            const diagnosis = Promise.all(result.pages.map(async (page, index) => {
              const image = async blob => {
                const bitmap = await createImageBitmap(blob);
                const canvas = document.createElement("canvas");
                canvas.width = bitmap.width; canvas.height = bitmap.height;
                canvas.getContext("2d").drawImage(bitmap, 0, 0); bitmap.close();
                return { metrics: window.__phonePixelMetrics(canvas), png: canvas.toDataURL() };
              };
              return { index, ...(page.png ? { full: await image(page.png) } : {}), strips: await Promise.all((page.strips || []).map(async strip => ({ x: strip.x, y: strip.y, width: strip.width, height: strip.height, ...await image(strip.png) }))) };
            })).then(pages => { entry.nativePages = pages; });
            window.__phoneRasterDiagnostics.push(diagnosis);
            }
            return result;
          } catch (error) {
            Object.assign(entry, { ok: false, status: error.status, missing: error.missing, generation: error.generation, message: error.message });
            throw error;
          }
        };
      });
      try {
      const oldHost = await application.evaluate(({ BrowserWindow }) => {
        const host = BrowserWindow.getAllWindows().find(window => window.webContents.getURL().endsWith("/raster-host.html"));
        if (!host) throw new Error("real screenshot host was not created");
        const id = host.id;
        host.destroy();
        return id;
      });
      // Changing actual image layout forces new page HTML/PNG keys; the renderer
      // still remembers sending this image to the old host. A new host must
      // request it again through the real main/preload/contextBridge boundary.
      await page.locator("#imageHeightInput").evaluate(input => {
        input.value = "220";
        input.dispatchEvent(new Event("input", { bubbles: true }));
        input.dispatchEvent(new Event("change", { bubbles: true }));
      });
      await page.waitForFunction(async () => (await window.mediacraft.drafts.current()).imageMaxHeight === 220);
      const recoveryPages = await page.evaluate(() => window.mediacraft.render.refresh());
      await waitCurrentPixels(page);
      let readyError;
      try { await waitImageLayout(page, recoveryPages[0]); }
      catch (error) { readyError = error; }
      await capture(page, data, report, "host-rebuilt-media-restored");
      const newHost = await application.evaluate(({ BrowserWindow }) => BrowserWindow.getAllWindows().find(window => window.webContents.getURL().endsWith("/raster-host.html"))?.id);
      assert(newHost && newHost !== oldHost, "a fresh screenshot host must replace the destroyed one");
      await page.evaluate(() => Promise.all(window.__phoneRasterDiagnostics));
      const trace = await page.evaluate(() => window.__phoneRasterTrace);
      for (const [call, entry] of trace.entries()) for (const result of entry.nativePages || []) {
        if (result.full) {
          await writeDataUrl(path.join(data, `host-recovery-native-${call}-${result.index}-full.png`), result.full.png);
          delete result.full.png;
        }
        for (const [index, strip] of result.strips.entries()) {
          await writeDataUrl(path.join(data, `host-recovery-native-${call}-${result.index}-strip-${index}.png`), strip.png);
          delete strip.png;
        }
      }
      report.hostRecovery = { oldHost, newHost, pages: recoveryPages, requests: trace };
      await fs.writeFile(path.join(data, "host-recovery-native-trace.json"), JSON.stringify(report.hostRecovery, null, 2));
      if (readyError) throw readyError;
      const missingIndex = trace.findIndex(entry => entry.status === 409 && entry.missing?.includes(fixture.imageId) && !entry.sent.includes(fixture.imageId));
      assert(missingIndex >= 0, "new host must request previously cached image through the real error envelope");
      const missing = trace[missingIndex];
      assert(typeof missing.generation === "string" && missing.generation, "new host generation must survive contextBridge");
      assert(trace.slice(missingIndex + 1).some(entry => entry.ok && entry.sent.includes(fixture.imageId) && entry.generation === missing.generation), "renderer must resend missing image and receive successful PNGs from the new generation");
      assertGeometry(report.scenarios.at(-1).geometry);
      assertPixels(report.scenarios.at(-1).pixels);
      assertImageLayout(report.scenarios.at(-1).pixels, recoveryPages[0]);
      assert(report.scenarios.at(-1).pixels.green.height < report.scenarios[0].pixels.green.height * 0.8, "updated image layout must render new pixels instead of reusing the old PNG cache");
      await page.locator("#imageHeightInput").evaluate(input => {
        input.value = "1048";
        input.dispatchEvent(new Event("input", { bubbles: true }));
        input.dispatchEvent(new Event("change", { bubbles: true }));
      });
      await page.evaluate(() => window.mediacraft.render.pages());
      await waitCurrentPixels(page);
      } finally {
        await page.evaluate(() => { window.MediaCraftNative.rasterCards = window.__phoneOriginalRaster; }).catch(() => {});
      }
    });
    if (process.env.VIBEPOST_TEST_FOCUS === "recovery") return;
    await check("17-page native screenshot request is batched without truncation", async () => {
      const batch = await page.evaluate(async () => {
        const result = await window.MediaCraftNative.rasterCards({
          pages: Array.from({ length: 17 }, (_, index) => ({ html: `<div class="mc-page"><span>${index + 1}</span><div class="marker"></div></div>`, full: true })),
          style: ".mc-page{position:relative;width:864px;height:1152px;background:#ffffff;color:#111111;font:64px Arial}.marker{position:absolute;left:200px;top:200px;width:200px;height:200px;background:#ff0000}",
          media: {}, mediaIds: [], width: 864, height: 1152, scale: 2,
        });
        const pages = await Promise.all(result.pages.map(async (page, index) => {
          const buffer = await page.png.arrayBuffer();
          const header = new DataView(buffer);
          const bitmap = await createImageBitmap(page.png);
          const canvas = document.createElement("canvas");
          canvas.width = bitmap.width; canvas.height = bitmap.height;
          canvas.getContext("2d").drawImage(bitmap, 0, 0);
          bitmap.close();
          const center = [...canvas.getContext("2d").getImageData(600, 600, 1, 1).data];
          return { index, width: header.getUint32(16), height: header.getUint32(20), center, png: index === 0 || index === 16 ? canvas.toDataURL() : null };
        }));
        return { generation: result.generation, pages };
      });
      report.nativeBatch = { ...batch, pages: batch.pages.map(({ png, ...info }) => info) };
      assert.equal(batch.pages.length, 17);
      for (const item of batch.pages) {
        assert.deepEqual([item.width, item.height], [1728, 2304]);
        assert.deepEqual(item.center, [255, 0, 0, 255], `page ${item.index + 1} must contain rendered pixels`);
        if (item.png) await writeDataUrl(path.join(data, `native-17-page-${item.index + 1}.png`), item.png);
      }
    });
    for (const theme of fixture.themes) {
      await check(`theme ${theme.id}: real UI change and all three phone views`, async () => {
        await page.locator("#themeButton").click();
        await page.locator(`.theme-option[data-theme="${theme.id}"]`).click();
        await page.waitForFunction(id => document.documentElement.dataset.cardTheme === id, theme.id);
        const pages = await page.evaluate(() => window.mediacraft.render.pages());
        await waitNote(page, pages.length);
        await waitCurrentPixels(page);
        await capture(page, data, report, `theme-${theme.id}-note`);
        assertGeometry(report.scenarios.at(-1).geometry);
        assertPixels(report.scenarios.at(-1).pixels);
        for (const view of ["feed", "profile"]) {
          await page.locator(`[data-phone-view="${view}"]`).click();
          await waitCurrentPixels(page);
          await capture(page, data, report, `theme-${theme.id}-${view}`);
          assertPixels(report.scenarios.at(-1).pixels);
        }
      });
      await page.locator('[data-phone-view="note"]').click();
    }
    await page.evaluate(id => window.mediacraft.themes.apply(id), fixture.themeId);
    await waitCurrentPixels(page);
    for (const height of [220, 580, 1048]) {
      await check(`image height ${height}: phone rendering stays in proportion`, async () => {
        await page.locator("#imageHeightInput").evaluate((input, value) => {
          input.value = String(value);
          input.dispatchEvent(new Event("input", { bubbles: true }));
          input.dispatchEvent(new Event("change", { bubbles: true }));
        }, height);
        await page.waitForFunction(async height => (await window.mediacraft.drafts.current()).imageMaxHeight === height, height);
        const pages = await page.evaluate(() => window.mediacraft.render.refresh());
        await waitCurrentPixels(page);
        let readyError;
        try { await waitImageLayout(page, pages[0]); }
        catch (error) { readyError = error; }
        await capture(page, data, report, `height-${height}`);
        report.scenarios.at(-1).logicalPage = pages[0];
        if (readyError) throw readyError;
        assertGeometry(report.scenarios.at(-1).geometry);
        assertPixels(report.scenarios.at(-1).pixels);
        assertImageLayout(report.scenarios.at(-1).pixels, pages[0]);
      });
    }
    for (const size of [{ width: 1100, height: 740 }, { width: 1560, height: 1000 }, { width: 1360, height: 920 }]) {
      await check(`window ${size.width}x${size.height}: phone fits without stretching`, async () => {
        const client = await application.evaluate(({ BrowserWindow }, size) => {
          const editor = BrowserWindow.getAllWindows().find(window => /\/index\.html(?:\?|$)/.test(window.webContents.getURL()));
          editor.setContentSize(size.width, size.height);
          const [width, height] = editor.getContentSize();
          return { width, height };
        }, size);
        (report.resizes ||= []).push({ requested: size, actualClient: client });
        // Frame/menu rounding at fractional Windows DPI can differ by two CSS
        // pixels; assert the actual carousel/pixel geometry independently below.
        await page.waitForFunction(client => Math.abs(innerWidth - client.width) <= 2 && Math.abs(innerHeight - client.height) <= 2, client);
        await settleAnimations(page);
        await capture(page, data, report, `resize-${size.width}x${size.height}`);
        const sample = report.scenarios.at(-1);
        assertGeometry(sample.geometry);
        assert(sample.geometry.scale > 0 && sample.geometry.scale <= 1);
        assert(sample.geometry.carousel.width <= sample.geometry.viewport.width);
        assertPixels(sample.pixels);
      });
    }
    await check("caption/title UI edits synchronize without changing cards", async () => {
      await page.locator("#titleInput").fill("同步后的手机标题");
      if (!await page.locator("#captionField").evaluate(field => field.open)) await page.locator("#captionField > summary").click();
      await page.locator("#captionInput").fill("更新后的独立正文。 #新话题");
      await page.evaluate(() => window.mediacraft.drafts.saveNow());
      await page.waitForFunction(() => document.querySelector(".phone-title").textContent === "同步后的手机标题" && document.querySelector(".phone-body").textContent.includes("更新后的独立正文"));
      assert.equal(await page.locator(".phone-tags").textContent(), "#新话题");
      await capture(page, data, report, "caption-updated");
      assertPixels(report.scenarios.at(-1).pixels);
    });
    await check("empty caption placeholder opens real caption editor", async () => {
      await page.locator("#captionInput").fill("");
      await page.evaluate(() => window.mediacraft.drafts.saveNow());
      await page.waitForFunction(() => document.querySelector(".phone-body").classList.contains("is-placeholder") && document.querySelector(".phone-tags").hidden);
      await page.locator(".phone-body").click();
      await page.waitForFunction(() => document.activeElement === document.querySelector("#captionInput") && document.querySelector("#captionField").open);
      await page.locator("#captionInput").fill("更新后的独立正文。 #新话题");
      await page.evaluate(() => window.mediacraft.drafts.saveNow());
      await page.waitForFunction(() => document.querySelector(".phone-tags").textContent === "#新话题");
    });
    await check("long article disables phone preview and cards can reopen it", async () => {
      await page.locator('[data-layout-mode="article"]').click();
      await page.waitForFunction(() => document.querySelector("#phonePreview").hidden && document.querySelector("#phoneButton").disabled);
      await page.locator('[data-layout-mode="cards"]').click();
      await page.waitForFunction(() => !document.querySelector("#phoneButton").disabled);
      await page.locator("#phoneButton").click();
      await waitCurrentPixels(page);
      await capture(page, data, report, "article-back-to-cards");
      assertGeometry(report.scenarios.at(-1).geometry);
      assertPixels(report.scenarios.at(-1).pixels);
    });
    await check("actual DPR matches requested launch scale", () => assert.equal(fixture.dpr, dpr));
  } catch (error) {
    report.errors.push({ name: "fatal", message: error.message, stack: error.stack });
    if (page && !page.isClosed()) {
      await page.screenshot({ path: path.join(data, "fatal.png"), timeout: 10000 }).catch(() => {});
      report.fatalState = await withDeadline(page.evaluate(() => ({ url: location.href, counter: document.querySelector(".phone-counter")?.textContent, slides: document.querySelector(".phone-track")?.children.length, status: document.querySelector("#statusText")?.textContent, stats: window.MediaCraftCards?.stats })), 5000, "Failure renderer snapshot").catch(error => ({ error: error.message }));
    }
    if (application) {
      report.windows = application.windows().map(window => window.url());
      // One snapshot after failure supplies evidence without introducing a
      // periodic inspector observer into the startup being tested.
      report.mainWindowSnapshot = await withDeadline(application.evaluate(({ app, BrowserWindow }) => ({
        ready: app.isReady(), windows: app.isReady() ? BrowserWindow.getAllWindows().map(window => ({ id: window.id, url: window.webContents.getURL(), loading: window.webContents.isLoading(), visible: window.isVisible(), destroyed: window.isDestroyed() })) : [],
      })), 5000, "Failure window snapshot").catch(error => ({ error: error.message }));
    }
  } finally {
    finishing = true;
    clearInterval(diagnosticTimer);
    const forcedCleanup = application && await closeOwnedApplication(application, child, report);
    report.ok = report.errors.length === 0;
    await fs.writeFile(path.join(data, "report.json"), JSON.stringify(report, null, 2));
    console.log(JSON.stringify({ ok: report.ok, report: path.join(data, "report.json"), checks: report.checks, errors: report.errors.map(({ name, message }) => ({ name, message })) }, null, 2));
    if (!report.ok) process.exitCode = 1;
    // A hung inspector connection can otherwise keep this test runner alive
    // even after its owned Electron process has been killed. Evidence is saved.
    if (forcedCleanup) process.exit(1);
  }
}

async function withDeadline(promise, timeout, label) {
  let timer;
  try {
    return await Promise.race([promise, new Promise((_, reject) => {
      timer = setTimeout(() => reject(new Error(`${label} timed out after ${timeout}ms`)), timeout);
    })]);
  } finally { clearTimeout(timer); }
}

async function closeOwnedApplication(application, child, report, timeout = 15000, killTimeout = 5000) {
  try {
    await withDeadline(application.close(), timeout, "Electron close");
    return false;
  } catch (error) {
    report.errors.push({ name: "close", message: error.message });
    report.cleanup = { pid: child?.pid, forcedKill: false };
    if (child && child.exitCode === null && child.signalCode === null) {
      let onExit;
      const exited = new Promise(resolve => { onExit = resolve; child.once("exit", onExit); });
      try {
        // This handle belongs only to electron.launch above. Never kill by
        // application name or enumerate unrelated processes.
        report.cleanup.forcedKill = child.kill("SIGKILL");
        await withDeadline(exited, killTimeout, "Owned Electron process exit");
      } catch (killError) {
        report.errors.push({ name: "owned process cleanup", message: killError.message });
      } finally { child.off("exit", onExit); }
    }
    return true;
  }
}

async function waitForEditorWindow(application, timeout) {
  return new Promise((resolve, reject) => {
    const pages = new Set();
    let timer, done = false;
    const cleanup = () => {
      done = true;
      clearTimeout(timer);
      application.off("window", watch);
      application.off("close", closed);
      for (const page of pages) page.off("framenavigated", select);
    };
    const select = () => {
      if (done) return;
      const editor = application.windows().find(page => !page.isClosed() && /\/index\.html(?:\?|$)/.test(page.url()));
      if (editor) { cleanup(); resolve(editor); }
    };
    const watch = page => {
      if (done) return;
      pages.add(page);
      page.on("framenavigated", select);
      select();
    };
    const closed = () => { cleanup(); reject(new Error("Electron exited before an editor window became ready")); };
    application.on("window", watch);
    application.on("close", closed);
    timer = setTimeout(() => { cleanup(); reject(new Error(`Editor index.html window did not navigate within ${timeout}ms; observed: ${application.windows().map(page => page.url()).join(", ") || "none"}`)); }, timeout);
    for (const page of application.windows()) watch(page);
  });
}

async function settleAnimations(page) {
  await page.evaluate(async () => {
    await Promise.all(document.getAnimations().map(animation => animation.finished.catch(() => {})));
    await new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(resolve)));
  });
}
async function waitNote(page, count) {
  await page.waitForFunction(count => {
    const preview = document.querySelector("#phonePreview");
    return !preview.hidden && document.querySelector(".phone-track").children.length === count && document.querySelector(".phone-counter").textContent.endsWith(`/${count}`);
  }, count);
  await settleAnimations(page);
}
async function waitSlide(page, index, total) {
  await page.waitForFunction(({ index, total }) => document.querySelector(".phone-counter").textContent === `${index + 1}/${total}`, { index, total });
  await settleAnimations(page);
}
async function geometry(page) {
  return page.evaluate(() => {
    const rect = node => { const r = node.getBoundingClientRect(); return { x: r.x, y: r.y, width: r.width, height: r.height }; };
    const view = document.querySelector('[data-phone-view][aria-pressed="true"]').dataset.phoneView;
    const carousel = document.querySelector(".phone-carousel");
    const track = document.querySelector(".phone-track");
    const slides = [...track.children].map(node => ({ ...rect(node), backingWidth: node.width, backingHeight: node.height, hidden: node.getAttribute("aria-hidden") }));
    const current = document.querySelector(`[data-phone-screen="${view}"] [aria-current="true"] .phone-cover`) || slides.length && [...track.children].find(node => node.getAttribute("aria-hidden") === "false");
    return { view, dpr: devicePixelRatio, viewport: { width: innerWidth, height: innerHeight }, scale: Number(document.querySelector(".phone").style.getPropertyValue("--phone-scale")), carousel: rect(carousel), track: rect(track), slides, current: current ? rect(current) : null, counter: document.querySelector(".phone-counter").textContent };
  });
}
function assertGeometry(g) {
  const current = g.slides.find(slide => slide.hidden === "false");
  assert(current, "active carousel slide");
  for (const slide of g.slides) {
    assert(Math.abs(slide.width - g.carousel.width) < 0.8, "each carousel slot must occupy one screen");
    assert(Math.abs(slide.width / slide.height - slide.backingWidth / slide.backingHeight) < 0.002, "canvas CSS/backing proportions");
  }
  assert(Math.abs(current.x - g.carousel.x) < 0.8, "active page left edge");
  assert(Math.abs(current.x + current.width - g.carousel.x - g.carousel.width) < 0.8, "active page right edge");
}
function assertPixels(p) {
  assert(p.red.count > 100, "red square marker must be visible");
  assert(p.green.count > 100, "landscape green boundary marker must be visible");
  const redRatio = p.red.width / p.red.height;
  const greenRatio = p.green.width / p.green.height;
  assert(Math.abs(redRatio - 1) < 0.06, `rendered red square is stretched: ratio ${redRatio.toFixed(3)}, bounds ${JSON.stringify(p.red)}`);
  assert(Math.abs(greenRatio - 2) < 0.08, `landscape image is stretched: ratio ${greenRatio.toFixed(3)}`);
}
function assertImageLayout(pixels, page) {
  const image = page.imageHits[0];
  assert(image, "logical page must contain the fixture image");
  const expected = { x: image.x * pixels.width / page.width, y: image.y * pixels.height / page.height, width: image.width * pixels.width / page.width, height: image.height * pixels.height / page.height };
  for (const key of ["x", "y", "width", "height"]) {
    assert(Math.abs(pixels.green[key] - expected[key]) <= 2, `image ${key} must match the current logical layout: expected ${expected[key].toFixed(2)}, rendered ${pixels.green[key]}`);
  }
}
// Wait for the genuine thumbnail renderer to reach the same frame as the UI.
// This does not repair or mock rendering, and it accepts defective baseline
// pixels so the independent square and landscape checks can report the bug.
async function waitCurrentPixels(page) {
  await page.waitForFunction(async () => {
    const view = document.querySelector('[data-phone-view][aria-pressed="true"]').dataset.phoneView;
    const isNote = view === "note";
    const canvas = isNote ? [...document.querySelector(".phone-track").children].find(node => node.getAttribute("aria-hidden") === "false") : document.querySelector(`[data-phone-screen="${view}"] [aria-current="true"] .phone-cover`);
    if (!canvas) return false;
    const index = isNote ? [...document.querySelector(".phone-track").children].indexOf(canvas) : 0;
    const [source] = await window.mediacraft.render.thumbnails({ width: canvas.width, height: canvas.height, indexes: [index] });
    return source && canvas.toDataURL() === source.toDataURL();
  }, null, { timeout: 60000 });
  await settleAnimations(page);
}
// The phone's asynchronous thumbnail callback can still display the preceding
// layout after the pipeline is current. Wait for the natural UI update using
// independent logical image bounds; a stale PNG cache will time out here.
async function waitImageLayout(page, logicalPage) {
  await page.waitForFunction(logicalPage => {
    const canvas = [...document.querySelector(".phone-track").children].find(node => node.getAttribute("aria-hidden") === "false");
    const image = logicalPage.imageHits[0];
    if (!canvas || !image) return false;
    const pixels = window.__phonePixelMetrics(canvas);
    const expected = { x: image.x * pixels.width / logicalPage.width, y: image.y * pixels.height / logicalPage.height, width: image.width * pixels.width / logicalPage.width, height: image.height * pixels.height / logicalPage.height };
    return pixels.green.count > 100 && Object.keys(expected).every(key => Math.abs(pixels.green[key] - expected[key]) <= 2);
  }, logicalPage, { timeout: 60000 });
  await settleAnimations(page);
}
async function capture(page, data, report, name) {
  await page.evaluate(() => {
    window.__phonePixelMetrics = canvas => {
      const { width, height } = canvas;
      const pixels = canvas.getContext("2d").getImageData(0, 0, width, height).data;
      const ranges = Object.fromEntries(["red", "green", "cyan"].map(color => [color, { x: width, y: height, right: -1, bottom: -1, count: 0 }]));
      for (let y = 0; y < height; y++) for (let x = 0; x < width; x++) {
        const i = (y * width + x) * 4, r = pixels[i], g = pixels[i + 1], b = pixels[i + 2];
        const key = r > 230 && g < 20 && b < 20 ? "red" : g > 230 && r < 20 && b < 20 ? "green" : r < 20 && g > 230 && b > 230 ? "cyan" : null;
        if (!key || pixels[i + 3] < 240) continue;
        const range = ranges[key]; range.x = Math.min(range.x, x); range.y = Math.min(range.y, y); range.right = Math.max(range.right, x); range.bottom = Math.max(range.bottom, y); range.count++;
      }
      for (const range of Object.values(ranges)) { range.width = range.right - range.x + 1; range.height = range.bottom - range.y + 1; }
      return { width, height, ...ranges };
    };
  });
  const g = await geometry(page);
  const raw = await page.evaluate(() => {
    const view = document.querySelector('[data-phone-view][aria-pressed="true"]').dataset.phoneView;
    const canvas = document.querySelector(`[data-phone-screen="${view}"] [aria-current="true"] .phone-cover`) || [...document.querySelector(".phone-track").children].find(node => node.getAttribute("aria-hidden") === "false");
    return { pixels: window.__phonePixelMetrics(canvas), png: canvas.toDataURL("image/png") };
  });
  await page.screenshot({ path: path.join(data, `${name}.png`) });
  await writeDataUrl(path.join(data, `${name}-card.png`), raw.png);
  const item = { name, geometry: g, pixels: raw.pixels };
  report.scenarios.push(item);
  await fs.writeFile(path.join(data, `${name}-geometry.json`), JSON.stringify(item, null, 2));
}
async function writeDataUrl(file, url) { await fs.writeFile(file, Buffer.from(url.slice(url.indexOf(",") + 1), "base64")); }
main().catch(error => { console.error(error); process.exitCode = 1; });
