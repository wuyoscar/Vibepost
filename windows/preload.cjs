"use strict";
const { contextBridge, ipcRenderer } = require("electron");
const epoch = ipcRenderer.sendSync("native:epoch");
const invoke = (action, params = {}) =>
  ipcRenderer.invoke("native:call", {
    epoch,
    action,
    params,
  });
const call = async (action, params = {}) => {
  const result = await invoke(action, params);
  if (result?.__error) {
    const error = new Error(result.__error.message);
    Object.assign(error, result.__error);
    throw error;
  }
  return result;
};
const listeners = new Map();
const cancelledMotion = new Set();
ipcRenderer.on("native:event", (_event, { kind, event }) => {
  for (const callback of listeners.get(kind) || []) callback(event);
});
function listen(kind, callback) {
  if (typeof callback !== "function") throw new TypeError("需要事件回调");
  if (!listeners.has(kind)) listeners.set(kind, new Set());
  listeners.get(kind).add(callback);
  return () => listeners.get(kind).delete(callback);
}
async function bytes(value) {
  if (typeof value === "string") return value;
  throw new TypeError("文件必须先在页面内转换为 Base64");
}
const ai = {
  status: (refresh = false, backend = "claude") =>
    call("ai/status", { refresh, backend }),
  setPath: (path, backend = "claude") => call("ai/settings", { path, backend }),
  models: (backend) => call("ai/models", { backend }),
  providers: () => call("ai/providers", {}),
  saveProviders: (providers) => call("ai/providers-save", { providers }),
  send: (request) => call("ai/send", request),
  cancel: (draftId) => call("ai/cancel", { draftId }),
  respond: (draftId, turnId, message) =>
    call("ai/respond", { draftId, turnId, message }),
  workFile: (draftId, turnId, markdown) =>
    call("ai/work-file", { draftId, turnId, markdown }),
  candidate: (draftId, turnId, source, grant = {}) =>
    call("ai/candidate", { draftId, turnId, source, ...grant }),
  candidateFile: (draftId, id) => call("ai/candidate-file", { draftId, id }),
  generateImage: (draftId, turnId, job) =>
    call("ai/generate-image", { draftId, turnId, ...job }),
  generateCancel: (draftId) => call("ai/generate-cancel", { draftId }),
  remove: (draftId) => call("ai/remove", { draftId }),
  onEvent: (callback) => listen("ai", callback),
};
const bridge = {
  capabilities: {
    airDrop: false,
    livePhoto: false,
    phoneTransfer: true,
    motionExport: ["mp4", "gif"],
    saveDialog: true,
  },
  windowChrome: null,
  haptic: () => {},
  // contextBridge drops custom fields on rejected Errors. Return raster errors
  // as plain data; the main-world wrapper restores missing-media negotiation.
  rasterCards: (request) => invoke("cards/raster", request),
  livePhoto: null,
  saveFile: async (blob, name) =>
    call("save", { name, data: await bytes(blob) }),
  copyText: (text) => call("clipboard/text", { text: String(text || "") }),
  // 系统通知（AI 等你确认、回复说完时，src/ai/notify.js）：{ title, body }；点击通知回到这个窗口
  notify: (request) => call("notify/show", request),
  copyRichText: (html, text) => call("clipboard/rich", { html, text }),
  sendToPhone: (files, text, details = {}) =>
    call("phone/start", { files, text, ...details }),
  stopPhoneTransfer: (session) => call("phone/stop", { session }),
  // Binary conversion remains here; AbortSignal/progress callbacks stay in the
  // renderer wrapper because they cannot cross a contextBridge boundary.
  motionRender: async ({ card, video, ...settings }) => {
    try {
      const binary = { card: await bytes(card), video: await bytes(video) };
      if (cancelledMotion.has(settings.job))
        throw Object.assign(new Error("已取消导出"), { name: "AbortError" });
      return await call("motion/render", { ...settings, ...binary });
    } finally {
      cancelledMotion.delete(settings.job);
    }
  },
  motionCancel: (job) => {
    cancelledMotion.add(job);
    return call("motion/cancel", { job });
  },
  onMotion: (callback) => listen("motion", callback),
  ai,
  windows: {
    open: (r) => call("window/open", r),
    claim: (r) => call("window/claim", r),
    occupy: (r) => call("window/occupy", r),
    missing: () => call("window/missing"),
    edited: (edited) => call("window/edited", { edited }),
    appInfo: () => call("window/info"),
    checkForUpdates: () => call("window/updates"),
    bindAgent: (session, draftId) => call("window/bind", { session, draftId }),
  },
  manuals: {
    list: () => call("manuals/list"),
    read: (name) => call("manuals/read", { name }),
    save: (r) => call("manuals/save", r),
    reveal: (name) => call("manuals/reveal", { name }),
    open: (name) => call("manuals/open", { name }),
  },
  templates: {
    list: () => call("templates/list"),
    read: (name) => call("templates/read", { name }),
    save: (r) => call("templates/save", r),
    remove: (name) => call("templates/remove", { name }),
    reveal: (name) => call("templates/reveal", { name }),
  },
  mcp: {
    status: () => call("mcp/status"),
    setEnabled: (enabled) => call("mcp/enabled", { enabled }),
    write: async (request, name, blob) =>
      call("mcp/write", { request, name, data: await bytes(blob) }),
    onEvent: (callback) => listen("mcp", callback),
  },
};
contextBridge.exposeInMainWorld("__electronBridge", bridge);
// Fixed events required by the shared Mac/frontend contract. No arbitrary
// renderer IPC channels or executable code are exposed.
ipcRenderer.on("native:window", (_event, detail) =>
  window.dispatchEvent(new CustomEvent("mediacraft:native-window", { detail })),
);
