"use strict";

const { performance } = require("node:perf_hooks");

const HOST_URL = "mediacraft://app/src/cards/raster-host.html";
const WIDTH = 864;
const HEIGHT = 1152;
const LIMITS = Object.freeze({
  pages: 16,
  htmlBytes: 4 * 1024 * 1024,
  styleBytes: 2 * 1024 * 1024,
  mediaBytes: 128 * 1024 * 1024,
  imageBytes: 64 * 1024 * 1024,
  mediaCount: 512,
  queued: 8,
  owners: 8,
});

class CardRasterError extends Error {
  constructor(message, code = "RASTER_BAD_REQUEST", fields = {}) {
    super(message);
    this.name = "CardRasterError";
    this.code = code;
    Object.assign(this, fields);
  }
}

function fail(what) {
  throw new CardRasterError(`卡片出图请求无效：${what}`);
}

function object(value, what, keys) {
  if (!value || typeof value !== "object" || Array.isArray(value)) fail(what);
  if (Object.keys(value).some((key) => !keys.includes(key))) fail(`${what}字段`);
  return value;
}

function text(value, what, max) {
  if (typeof value !== "string" || Buffer.byteLength(value, "utf8") > max) fail(what);
  return value;
}

function mediaId(value) {
  if (typeof value !== "string" || !value || value.length > 512) fail("图片编号");
  return value;
}

// Imported images cross the bridge as data URLs, including local template assets.
// Never allow file:, http:, blob: or another app URL to become a screenshot fetch.
function imageUrl(value) {
  text(value, "图片大小", LIMITS.imageBytes);
  const match = /^data:image\/[a-z0-9.+-]+((?:;[a-z0-9=.+-]+)*),([\s\S]*)$/i.exec(value);
  if (!match || !match[2]) fail("图片地址");
  if (/;base64(?:;|$)/i.test(match[1]) && !/^[A-Za-z0-9+/]*={0,2}$/.test(match[2])) fail("图片编码");
  return value;
}

function validateRequest(input) {
  object(input, "请求", ["pages", "style", "media", "mediaIds", "width", "height", "scale", "method"]);
  if (input.width !== WIDTH || ![1152, 1222, 1536, 1728].includes(input.height) || ![1, 2].includes(input.scale)) fail("尺寸（宽 864，高 1152 / 1222 / 1536 / 1728，1 或 2 倍图）");
  if (input.method !== undefined && input.method !== "snapshot") fail("出图方式");
  if (!Array.isArray(input.pages) || !input.pages.length || input.pages.length > LIMITS.pages) fail("页数（每批最多 16 页）");
  const style = text(input.style, "样式", LIMITS.styleBytes);
  let htmlBytes = 0;
  const pages = input.pages.map((value) => {
    const page = typeof value === "string" ? { html: value } : object(value, "页面", ["html", "chrome", "full"]);
    const html = text(page.html, "页面内容", LIMITS.htmlBytes);
    htmlBytes += Buffer.byteLength(html, "utf8");
    if (page.full !== undefined && typeof page.full !== "boolean") fail("整页标记");
    let chrome;
    if (page.chrome !== undefined && page.chrome !== null) {
      object(page.chrome, "页眉页脚", ["head", "foot"]);
      chrome = {};
      for (const part of ["head", "foot"]) {
        const value = page.chrome[part];
        if (value !== undefined && value !== null) {
          chrome[part] = text(value, "页眉页脚内容", LIMITS.htmlBytes);
          htmlBytes += Buffer.byteLength(value, "utf8");
        }
      }
    }
    return { html, chrome, full: page.full !== false };
  });
  if (htmlBytes > LIMITS.htmlBytes) fail("页面内容总量");
  const media = {};
  let mediaBytes = 0;
  if (input.media !== undefined && input.media !== null) {
    if (typeof input.media !== "object" || Array.isArray(input.media)) fail("图片集合");
    const entries = Object.entries(input.media);
    if (entries.length > LIMITS.mediaCount) fail("图片数量");
    for (const [id, src] of entries) {
      mediaId(id);
      imageUrl(src);
      mediaBytes += Buffer.byteLength(src, "utf8");
      if (mediaBytes > LIMITS.mediaBytes) fail("图片总量");
      Object.defineProperty(media, id, { value: src, enumerable: true });
    }
  }
  const mediaIds = input.mediaIds ?? [];
  if (!Array.isArray(mediaIds) || mediaIds.length > LIMITS.mediaCount) fail("图片编号数量");
  return { pages, style, media, mediaIds: [...new Set(mediaIds.map(mediaId))], width: WIDTH, height: input.height, scale: input.scale };
}

function pngDimensions(data) {
  if (typeof data !== "string" || data.length > 64 * 1024 * 1024 || !/^[A-Za-z0-9+/]*={0,2}$/.test(data)) throw new CardRasterError("截图没有返回有效 PNG", "RASTER_CAPTURE");
  const bytes = Buffer.from(data, "base64");
  if (bytes.length < 24 || !bytes.subarray(0, 8).equals(Buffer.from([137, 80, 78, 71, 13, 10, 26, 10])) || bytes.toString("ascii", 12, 16) !== "IHDR") throw new CardRasterError("截图没有返回有效 PNG", "RASTER_CAPTURE");
  return { width: bytes.readUInt32BE(16), height: bytes.readUInt32BE(20) };
}

/** Chromium screenshot hosts are isolated by editing-window epoch. The main
 * process validates the calling editor before it supplies this owner key. */
class CardRasterService {
  constructor({ BrowserWindow, loadTimeout = 20000, pageTimeout = 60000 } = {}) {
    if (typeof BrowserWindow !== "function") throw new TypeError("BrowserWindow is required");
    this.BrowserWindow = BrowserWindow;
    this.loadTimeout = loadTimeout;
    this.pageTimeout = pageTimeout;
    this.contexts = new Map();
    this.disposed = false;
  }

  async render(owner, input) {
    if (this.disposed) throw new CardRasterError("卡片出图服务已关闭", "RASTER_CLOSED");
    if (typeof owner !== "string" || !owner || owner.length > 200) fail("窗口归属");
    const request = validateRequest(input);
    let context = this.contexts.get(owner);
    if (!context) {
      if (this.contexts.size >= LIMITS.owners) {
        // Hosts are a bounded cache, not a limit on how many editors may ever
        // render. Rebuilding an idle owner's host is handled by generation and
        // missing-media negotiation when that editor next requests a capture.
        const idle = [...this.contexts.entries()]
          .filter(([, entry]) => entry.queued === 0)
          .sort((a, b) => a[1].lastUsed - b[1].lastUsed)[0];
        if (!idle) throw new CardRasterError("同时出图的窗口太多，请稍后重试", "RASTER_BUSY");
        this.release(idle[0]);
      }
      context = { window: null, ready: null, tail: Promise.resolve(), queued: 0, released: false, lastUsed: performance.now() };
      context.cancel = new Promise((_, reject) => { context.reject = reject; });
      context.cancel.catch(() => {});
      this.contexts.set(owner, context);
    }
    if (context.queued >= LIMITS.queued) throw new CardRasterError("卡片出图请求太多，请稍后重试", "RASTER_BUSY");
    context.lastUsed = performance.now();
    context.queued++;
    const work = context.tail.then(() => this._render(context, request));
    // A failed capture must not poison subsequent requests or interleave show/chrome.
    context.tail = work.catch(() => {});
    try { return await work; }
    finally { context.queued--; context.lastUsed = performance.now(); }
  }

  _assert(context) {
    if (context.released || this.disposed) throw new CardRasterError("编辑窗口已关闭或重新载入", "RASTER_CLOSED");
  }

  async _bounded(context, operation, timeout, what) {
    this._assert(context);
    let timer;
    const deadline = new Promise((_, reject) => {
      timer = setTimeout(() => reject(new CardRasterError(`${what}超时，请重新尝试`, "RASTER_TIMEOUT")), timeout);
    });
    try {
      return await Promise.race([Promise.resolve().then(operation), deadline, context.cancel]);
    } catch (error) {
      this._reset(context);
      throw error;
    } finally { clearTimeout(timer); }
  }

  _reset(context) {
    const view = context.window;
    context.window = null;
    context.ready = null;
    if (view && !view.isDestroyed()) view.destroy();
  }

  async _host(context) {
    this._assert(context);
    if (context.window && !context.window.isDestroyed()) return await context.ready;
    const view = new this.BrowserWindow({
      width: WIDTH, height: HEIGHT, useContentSize: true, show: false,
      frame: false, focusable: false, skipTaskbar: true,
      backgroundColor: "#00000000",
      webPreferences: {
        nodeIntegration: false, contextIsolation: true, sandbox: true,
        webviewTag: false, backgroundThrottling: false,
        offscreen: true,
        paintWhenInitiallyHidden: true, spellcheck: false,
      },
    });
    context.window = view;
    const contents = view.webContents;
    contents.setWindowOpenHandler(() => ({ action: "deny" }));
    for (const event of ["will-navigate", "will-frame-navigate", "will-redirect", "before-input-event", "before-mouse-event", "context-menu"])
      contents.on(event, (event) => event.preventDefault());
    // A destroyed host may report its crash after a replacement was created.
    // Such a late event must not tear down the replacement's window/cache.
    contents.on("render-process-gone", () => {
      if (context.window === view) this._reset(context);
    });
    contents.setAudioMuted(true);
    contents.setZoomMode("isolated");
    contents.setZoomFactor(1);
    context.ready = this._bounded(context, async () => {
      await view.loadURL(HOST_URL);
      contents.debugger.attach("1.3");
      await contents.debugger.sendCommand("Emulation.setDefaultBackgroundColorOverride", { color: { r: 0, g: 0, b: 0, a: 0 } });
      const available = await contents.executeJavaScript("Boolean(window.mcRaster?.setup && window.mcRaster?.show && window.mcRaster?.chrome)");
      if (!available) throw new CardRasterError("卡片出图页面没有载入", "RASTER_HOST");
      return view;
    }, this.loadTimeout, "载入卡片出图页面");
    return await context.ready;
  }

  async _call(context, contents, name, args) {
    return await this._bounded(context, () => contents.executeJavaScript(`window.mcRaster.${name}(...${JSON.stringify(args)})`), this.pageTimeout, "排版卡片");
  }

  async _capture(context, contents, rect, scale) {
    // CDP uses CSS clip coordinates and the explicit device scale for actual
    // Chromium rasterization. capturePage's NativeImage backing scale depends on
    // the monitor; do not resize/up-sample a 1x capture to fake a 2x result.
    const result = await this._bounded(context, () => contents.debugger.sendCommand("Page.captureScreenshot", {
      format: "png", fromSurface: true, captureBeyondViewport: true,
      clip: { ...rect, scale: 1 },
    }), this.pageTimeout, "截取卡片");
    const expected = { width: Math.round(rect.width * scale), height: Math.round(rect.height * scale) };
    const actual = pngDimensions(result.data);
    if (actual.width !== expected.width || actual.height !== expected.height) throw new CardRasterError("截图像素尺寸与卡片比例不一致", "RASTER_CAPTURE");
    return result.data;
  }

  async _render(context, request) {
    this._assert(context);
    const started = performance.now();
    try {
      const view = await this._host(context);
      const contents = view.webContents;
      await this._bounded(context, () => contents.debugger.sendCommand("Emulation.setDeviceMetricsOverride", {
        width: WIDTH, height: request.height, deviceScaleFactor: request.scale, mobile: false,
        screenWidth: WIDTH, screenHeight: request.height,
      }), this.pageTimeout, "设置卡片像素比例");
      const setup = await this._call(context, contents, "setup", [request.style, request.media, request.mediaIds, WIDTH, request.height]);
      if (!setup || typeof setup.generation !== "string" || !Array.isArray(setup.missing)) throw new CardRasterError("卡片出图页面返回了无效状态", "RASTER_HOST");
      if (setup.missing.length) throw new CardRasterError("卡片出图页面需要补发图片", "RASTER_MISSING_MEDIA", { status: 409, missing: setup.missing, generation: setup.generation });
      const pages = [], times = [];
      for (const page of request.pages) {
        const pageStarted = performance.now();
        const shown = await this._call(context, contents, "show", [page.html]);
        if (shown?.width !== WIDTH || shown?.height !== request.height) throw new CardRasterError("卡片排版尺寸不正确", "RASTER_HOST");
        const rendered = { strips: [] };
        if (page.full) rendered.png = await this._capture(context, contents, { x: 0, y: 0, width: WIDTH, height: request.height }, request.scale);
        if (page.chrome) {
          const rects = await this._call(context, contents, "chrome", [page.chrome.head ?? "", page.chrome.foot ?? ""]);
          if (!Array.isArray(rects) || rects.length > 2) throw new CardRasterError("页眉页脚截图区域不正确", "RASTER_HOST");
          for (const rect of rects) {
            if (!rect || !["x", "y", "width", "height"].every((key) => Number.isInteger(rect[key])) || rect.x < 0 || rect.y < 0 || rect.width <= 0 || rect.height <= 0 || rect.x + rect.width > WIDTH || rect.y + rect.height > request.height) throw new CardRasterError("页眉页脚截图区域不正确", "RASTER_HOST");
            const { x, y, width, height } = rect;
            rendered.strips.push({ x, y, width, height, png: await this._capture(context, contents, { x, y, width, height }, request.scale) });
          }
        }
        times.push(performance.now() - pageStarted);
        pages.push(rendered);
      }
      return { pages, generation: setup.generation, times, totalMs: performance.now() - started };
    } catch (error) {
      // Missing-media is an expected negotiation and keeps the host's cache.
      if (error.code !== "RASTER_MISSING_MEDIA") this._reset(context);
      // The frontend already allows one missing-media retry. A stalled host is
      // now gone, so resend this batch's media to its replacement on that retry.
      // Keep the original timeout error and do not invent a host generation.
      // A second timeout remains a failure; callers impose the one-retry limit.
      if (error.code === "RASTER_TIMEOUT") error.missing = [...request.mediaIds];
      throw error;
    }
  }

  release(owner) {
    const context = this.contexts.get(owner);
    if (!context) return;
    this.contexts.delete(owner);
    context.released = true;
    context.reject(new CardRasterError("编辑窗口已关闭或重新载入", "RASTER_CLOSED"));
    this._reset(context);
  }

  dispose() {
    this.disposed = true;
    for (const owner of [...this.contexts.keys()]) this.release(owner);
  }
}

module.exports = { CardRasterService, CardRasterError, validateRequest, LIMITS };
