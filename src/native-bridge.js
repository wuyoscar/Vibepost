// 运行在 MediaCraft.app 壳里时，暴露原生能力（保存文件、发送到 iPhone、带格式复制、合成实况）。
// 浏览器里打开时 window.MediaCraftNative 为 null，页面走原来的浏览器路径。
(() => {
  // Electron supplies the contract through an isolated preload. The Swift
  // host continues to use the scheme bridge below.
  if (window.__electronBridge) {
    const base = window.__electronBridge;
    const bytes = async (blob) => {
      const data = new Uint8Array(await blob.arrayBuffer());
      const chunks = [];
      for (let offset = 0; offset < data.length; offset += 8192) chunks.push(String.fromCharCode(...data.subarray(offset, offset + 8192)));
      return btoa(chunks.join(""));
    };
    const progressListeners = new Map();
    base.onMotion((event) => progressListeners.get(event.job)?.(event.progress));
    const pngBlob = (data) => new Blob([Uint8Array.from(atob(data), (char) => char.charCodeAt(0))], { type: "image/png" });
    const captureCards = async (request) => {
      // The shared frontend batches up to 40 pages; Windows keeps each IPC
      // capture bounded to 16 without changing the Mac batching contract.
      if (Array.isArray(request.pages) && request.pages.length > 16) {
        const replies = [];
        for (let start = 0; start < request.pages.length; start += 16) {
          replies.push(await captureCards({ ...request, pages: request.pages.slice(start, start + 16) }));
        }
        return {
          ...replies.at(-1),
          pages: replies.flatMap((reply) => reply.pages),
          times: replies.flatMap((reply) => reply.times ?? []),
          totalMs: replies.reduce((sum, reply) => sum + (reply.totalMs ?? 0), 0),
        };
      }
      const result = await base.rasterCards(request);
      if (result?.__error) {
        throw Object.assign(new Error(result.__error.message), result.__error);
      }
      return {
        ...result,
        pages: result.pages.map((page) => ({
          ...page,
          ...(page.png ? { png: pngBlob(page.png) } : {}),
          strips: (page.strips ?? []).map((strip) => ({ ...strip, png: pngBlob(strip.png) })),
        })),
      };
    };
    // Theme choices, the filmstrip and phone views may request previews together.
    // Apply backpressure before IPC instead of filling the bounded native queue.
    let rasterQueue = Promise.resolve();
    const rasterCards = (request) => {
      const run = rasterQueue.then(() => captureCards(request));
      rasterQueue = run.catch(() => {});
      return run;
    };
    window.MediaCraftNative = {
      ...base,
      rasterCards: base.rasterCards ? rasterCards : null,
      pdfToImages: (blob) => window.MediaCraftWindowsPDF(blob),
      saveFile: async (blob, name) => base.saveFile(await bytes(blob), name),
      sendToPhone: async (files, text, details = {}) => base.sendToPhone(await Promise.all(files.map(async (file) => ({ name: file.name, type: file.blob.type, data: await bytes(file.blob) }))), text, details),
      mcp: { ...base.mcp, write: async (request, name, blob) => base.mcp.write(request, name, await bytes(blob)) },
      async motionVideo({ card, video, ...settings }, { signal, onProgress } = {}) {
        const job = crypto.randomUUID();
        const abort = () => void base.motionCancel(job);
        signal?.throwIfAborted();
        signal?.addEventListener("abort", abort, { once: true });
        progressListeners.set(job, onProgress);
        try {
          const result = await base.motionRender({ card: await bytes(card), video: await bytes(video), ...settings, job });
          signal?.throwIfAborted();
          // IPC progress and invoke replies use separate queues; completion is
          // authoritative even if the final progress event arrives afterward.
          onProgress?.(1);
          return new Blob([Uint8Array.from(atob(result.data), (char) => char.charCodeAt(0))], { type: result.type });
        } finally {
          signal?.removeEventListener("abort", abort);
          progressListeners.delete(job);
        }
      },
    };
    return;
  }
  if (window.location.protocol !== "mediacraft:") {
    window.MediaCraftNative = null;
    return;
  }

  // 壳只接带着这个请求头的 POST：图片、样式里的地址、表单都带不上它，碰不到原生能力（AppSchemeHandler）
  const BRIDGE_HEADERS = { "X-MediaCraft-Bridge": "1" };

  // 壳回的 JSON（{ ok, error?, … }）；回的不是 JSON 时按失败算，原因写上状态码
  async function replyOf(response) {
    try {
      return await response.json();
    } catch {
      return { ok: false, error: `原生层没有回 JSON（状态 ${response.status}）` };
    }
  }

  // 自定义 scheme 收不到 Blob 形式的请求体，统一转成 ArrayBuffer。
  // 参数用百分号编码（URLSearchParams 把空格写成「+」，壳那边解不回空格，文件名里的空格会变成「+」）
  async function call(action, params = {}, blob = null) {
    const query = Object.entries(params).map(([key, value]) => `${encodeURIComponent(key)}=${encodeURIComponent(value)}`).join("&");
    const body = blob ? await blob.arrayBuffer() : new ArrayBuffer(0);
    const response = await fetch(`/__native/${action}${query ? `?${query}` : ""}`, { method: "POST", headers: BRIDGE_HEADERS, body });
    const reply = await replyOf(response);
    if (response.ok && reply.ok) return reply;
    throw new Error(reply.error || `原生调用失败：${action}`);
  }

  const callJson = (action, body = {}) => call(action, {}, new Blob([JSON.stringify(body)]));

  // 带文件的 body：4 字节大端的头部长度 + JSON 头部 + 各段依次相接（各段长度写在头部里），请求与回复同一种格式。
  function framed(header, parts) {
    const json = new TextEncoder().encode(JSON.stringify(header));
    const length = new Uint8Array(4);
    new DataView(length.buffer).setUint32(0, json.length);
    return new Blob([length, json, ...parts]);
  }

  function unframed(buffer) {
    const length = new DataView(buffer).getUint32(0);
    const header = JSON.parse(new TextDecoder().decode(new Uint8Array(buffer, 4, length)));
    let offset = 4 + length;
    const parts = header.files.map(({ size }) => {
      const part = new Blob([new Uint8Array(buffer, offset, size)]);
      offset += size;
      return part;
    });
    return { header, parts };
  }

  // 实况合成（壳里用 AVFoundation 做，ADR 0004）。request：{ card（卡片 PNG）, video（原视频）, videoName,
  //   cardWidth, cardHeight, well: { x, y, width, height, radius }, crop, start, span, speed, cover, sound }。
  // signal 中止时壳停下合成（reject AbortError）；onProgress(0–1) 随合成推进。
  // 得到 { identifier, photo, movie, metadata }（Blob），就是 .pvt 里的 JPG、MOV 与 metadata.plist。
  async function livePhoto({ card, video, ...settings }, { signal, onProgress } = {}) {
    const job = crypto.randomUUID();
    const listener = (event) => {
      if (event.detail?.job === job) onProgress?.(event.detail.progress);
    };
    window.addEventListener("mediacraft:native-live-photo", listener);
    try {
      const body = framed({ ...settings, job, cardBytes: card.size, videoBytes: video.size }, [card, video]);
      // 中止时交出调用方给的原因（比如「已取消」），不是浏览器自己的那句
      const response = await fetch("/__native/live-photo", { method: "POST", headers: BRIDGE_HEADERS, body: await body.arrayBuffer(), signal })
        .catch((error) => {
          throw signal?.aborted ? signal.reason ?? error : error;
        });
      if (!response.ok || response.headers.get("Content-Type") !== "application/octet-stream") {
        throw new Error((await replyOf(response)).error || "实况没能生成");
      }
      const { header, parts } = unframed(await response.arrayBuffer());
      const [photo, movie, metadata] = parts;
      return { identifier: header.identifier, photo, movie, metadata };
    } finally {
      window.removeEventListener("mediacraft:native-live-photo", listener);
    }
  }

  // HTML 卡片出图（src/cards/，壳里的 CardRasterizer）。request：{ pages: [每页的 HTML], style, media: { 编号: data URL },
  //   width, height, scale }；得到 { pages: [PNG Blob], totalMs, times: [每页毫秒] }。
  // 出图：request = { pages: [{ html, chrome?: { head, foot }, full? }]（也认每页只是 HTML 的旧写法）, style, media, mediaIds, width, height, scale }。
  // 回 { pages: [{ png（full 时）, strips: [{ x, y, width, height, png }] }], generation, totalMs, times }；
  // 宿主页缺图时 reject 的错误带 missing（编号）与 generation，调用方补发一次
  async function rasterCards(request) {
    const response = await fetch("/__native/cards/raster", {
      method: "POST",
      headers: BRIDGE_HEADERS,
      body: await new Blob([JSON.stringify(request)]).arrayBuffer(),
    });
    if (!response.ok || response.headers.get("Content-Type") !== "application/octet-stream") {
      const reply = await replyOf(response);
      const error = new Error(reply.error || "卡片没能出图");
      if (Array.isArray(reply.missing)) error.missing = reply.missing;
      if (typeof reply.generation === "string") error.generation = reply.generation;
      throw error;
    }
    const { header, parts } = unframed(await response.arrayBuffer());
    const png = (part) => new Blob([part], { type: "image/png" });
    let at = 0;
    const pages = (header.pages ?? header.files.map(() => ({ full: true, strips: [] }))).map((page) => ({
      png: page.full === false ? null : png(parts[at++]),
      strips: (page.strips ?? []).map((rect) => ({ ...rect, png: png(parts[at++]) })),
      ms: page.ms,
    }));
    return { pages, generation: header.generation ?? null, totalMs: header.totalMs, times: pages.map((page) => page.ms) };
  }

  // 网页铺进透明标题栏时（壳开了毛玻璃）才有：告诉壳哪里可以拖动窗口、界面是深色还是浅色。
  const windowChrome = window.webkit?.messageHandlers?.mediacraftWindow;
  // 触控板的触感反馈（壳里是 NSHapticFeedbackManager），不等回复
  const haptics = window.webkit?.messageHandlers?.mediacraftHaptic;

  window.MediaCraftNative = {
    // message：{ appearance: "dark" | "light" } 或 { drag: [[x, y, 宽, 高]…], noDrag: [[…]…] }（页面坐标）
    windowChrome: windowChrome ? (message) => windowChrome.postMessage(message) : null,
    // 拖到吸附点时轻轻一震：pattern 为 "alignment"（对齐、吸住）或 "level-change"（跨过一档）。只在拖动中用，别的时候不震
    haptic: (pattern) => haptics?.postMessage(pattern),
    saveFile: (blob, filename) => call("save", { name: filename }, blob),
    // PDF 每页渲染成一张 PNG，按页序返回 Blob。
    async pdfToImages(blob) {
      const { pages } = await call("pdf-pages", {}, blob);
      return pages.map((base64) => new Blob([Uint8Array.from(atob(base64), (char) => char.charCodeAt(0))], { type: "image/png" }));
    },
    // files: [{ blob, name }]，name 为 NN.png 或 NN.pvt/<文件>，按 NN 排序即页序；text 写进剪贴板。
    async sendToIPhone(files, text) {
      const batch = crypto.randomUUID();
      for (const file of files) await call("stage", { batch, name: file.name }, file.blob);
      return call("send-to-iphone", { batch }, new Blob([text || ""]));
    },
    // 纯文本写进剪贴板（「复制卡片文字」、发完复制标题 / 正文 / 话题）。
    copyText: (text) => call("copy-text", {}, new Blob([text])),
    // 带格式复制：HTML 与纯文本一起写进剪贴板（粘进公众号编辑器时用 HTML）。
    copyRichText: (html, text) => call("copy-rich", {}, new Blob([JSON.stringify({ html, text })])),
    livePhoto,
    rasterCards,
    // 本机的 AI 后端（Claude Code、Codex；src/ai/session.js 用）：每轮起一个进程，输出由壳推成 mediacraft:native-ai 事件。
    ai: {
      status: (refresh = false, backend = "claude") => callJson("ai/status", { refresh, backend }),
      setPath: (path, backend = "claude") => callJson("ai/settings", { path, backend }),
      // 后端能用的模型：{ models: [{ id, name, isDefault }] }（现在只有 Codex 有列表）
      models: (backend) => callJson("ai/models", { backend }),
      send: (request) => callJson("ai/send", request),
      cancel: (draftId) => callJson("ai/cancel", { draftId }),
      // 往这一轮的 stdin 写一整行（后端认得的样子：回答它的请求，或主动发的请求）。
      // 返回 { delivered }：真写进去了为 true，这一轮已经结束为 false；写失败时 reject
      respond: (draftId, turnId, message) => callJson("ai/respond", { draftId, turnId, message }),
      // 这一轮进行中读（markdown 为 undefined）或改写工作副本的 draft.md，返回 { markdown }
      workFile: (draftId, turnId, markdown) => callJson("ai/work-file", { draftId, turnId, markdown }),
      // 配图候选（这一轮进行中）：本机路径或网址 → { id, name, width, height, thumb }。网上的、工作目录以外的要用户同意：
      // 壳先回 { needsApproval, approval（一次性凭据）, scope（「本次会话都允许」放行的范围）}，问过用户后带着
      // { approval, session } 再来。candidateFile 取原图 { type, data（base64）}
      candidate: (draftId, turnId, source, grant = {}) => callJson("ai/candidate", { draftId, turnId, source, ...grant }),
      candidateFile: (draftId, id) => callJson("ai/candidate-file", { draftId, id }),
      // 生图（App 的工具 generate_image，这一轮进行中）：job 是 { provider, model, prompt, count, size }，
      // 生成的图存成配图候选，返回 { images: [{ id, name, width, height, thumb }] }；generateCancel 停止这篇正在生成的
      generateImage: (draftId, turnId, job) => callJson("ai/generate-image", { draftId, turnId, ...job }),
      generateCancel: (draftId) => callJson("ai/generate-cancel", { draftId }),
      // 删稿子时删掉它的工作副本与配图候选（还在跑的一轮先停掉）
      remove: (draftId) => callJson("ai/remove", { draftId }),
      // event：{ type: "lines", turnId, draftId, lines: [后端的输出行，每行一个 JSON] } 或 { type: "exit", turnId, draftId, … }
      onEvent: (listener) => window.addEventListener("mediacraft:native-ai", (event) => listener(event.detail)),
    },
    // 窗口：一个窗口一篇稿子（src/drafts/windows.js）。open({ draftId }) 在新窗口打开那篇（它在别的窗口里开着时回
    // { elsewhere: true }，壳把那个窗口调到前面），open({ fresh: true }) 新窗口里新建一篇；claim({ draftId, focus }) 这个窗口
    // 能不能开这篇（{ elsewhere } 为真时不能）；occupy({ current, drafts, page, sequence }) 这个窗口占着的（page 是这个页面的 id，
    // sequence 是它第几次报）；missing() 要开的那篇不在了
    windows: {
      open: (request) => callJson("window/open", request),
      claim: (request) => callJson("window/claim", request),
      occupy: (request) => callJson("window/occupy", request),
      missing: () => callJson("window/missing"),
      // 这个窗口有没有还没存进本机的改动：壳在关闭按钮上显示小圆点（isDocumentEdited）
      edited: (edited) => callJson("window/edited", { edited }),
      // App 的版本号与能不能检查更新；检查更新（像点了菜单里的「检查更新…」）
      appInfo: () => callJson("window/app-info"),
      checkForUpdates: () => callJson("window/check-updates"),
      // 外部 Agent 的这次会话（session）认定了这篇：壳记着，之后它的请求交给开着这篇的窗口
      bindAgent: (session, draftId) => callJson("window/bind-agent", { session, draftId }),
    },
    // 写作手册（只管写什么、什么口味）：App 支持目录「写作手册」文件夹里的 .md，壳在第一次用时用自带的示例建好（WritingManuals.swift）。
    // list() → { manuals: [{ name, description }], folder }；read(name) → { name, description, content（正文）}；
    // save({ name, description, content }) 新建或整份换掉（先问过用户），名字、说明、正文不合规矩时 reject 带原因；
    // reveal(name) 在 Finder 中显示（不给 name 时打开文件夹）；open(name) 用默认的 App 打开
    manuals: {
      list: () => callJson("manuals/list"),
      read: (name) => callJson("manuals/read", { name }),
      save: ({ name, description, content }) => callJson("manuals/save", { name, description, content }),
      reveal: (name) => callJson("manuals/reveal", name ? { name } : {}),
      open: (name) => callJson("manuals/open", { name }),
    },
    // 用户自己存的模板：App 支持目录「模板」文件夹里每套一个文件夹「<名字>/模板.md」+ 同目录的图片（TemplateLibrary.swift；
    // 格式见 src/templates/format.js，页面读写，壳只管文件）。list() → { templates: [{ name, content }], folder }（content 是 模板.md 全文）；
    // read(name) → { name, content, images: { 文件名: data URL } }；save({ name, content, images: [{ name, data（base64）}] }) 新建或整套换掉；
    // remove(name) 删掉那一套；reveal(name) 在 Finder 中显示它的文件夹（不给 name 时打开模板文件夹）
    templates: {
      list: () => callJson("templates/list"),
      read: (name) => callJson("templates/read", { name }),
      save: ({ name, content, images }) => callJson("templates/save", { name, content, images }),
      remove: (name) => callJson("templates/remove", { name }),
      reveal: (name) => callJson("templates/reveal", name ? { name } : {}),
    },
    // 外部 Agent（MCP，src/mcp/server.js 用）：终端里的 Claude Code 等经 mediacraft-mcp 连进壳，请求由壳交给 window.MediaCraftMCP。
    mcp: {
      // { available, enabled, clients, command }：有没有在监听、「允许外部 Agent 连接」开没开、连着几个、接入命令
      status: () => callJson("mcp/status"),
      setEnabled: (enabled) => callJson("mcp/settings", { enabled }),
      // 外部 Agent 的导出：把做好的文件交给壳，写进这次调用（request）登记的目录，返回 { path, name }
      write: (request, name, blob) => call("mcp/write", { request, name }, blob),
      // event：{ type: "clients", count }
      onEvent: (listener) => window.addEventListener("mediacraft:native-mcp", (event) => listener(event.detail)),
    },
  };
})();
