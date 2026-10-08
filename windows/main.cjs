"use strict";
const {
  app,
  BrowserWindow,
  ipcMain,
  protocol,
  net,
  clipboard,
  dialog,
  shell,
  Menu,
  nativeImage,
} = require("electron");
const fs = require("node:fs/promises");
const fsSync = require("node:fs");
const path = require("node:path");
const { pathToFileURL } = require("node:url");
const { Library, safeName, within, atomicJson } = require("./lib/storage.cjs");
const { WindowState } = require("./lib/window-state.cjs");
const { AiService } = require("./lib/ai.cjs");
const { McpService } = require("./lib/mcp.cjs");
const { PhoneService } = require("./lib/phone.cjs");
const { MotionService } = require("./lib/motion.cjs");
protocol.registerSchemesAsPrivileged([
  {
    scheme: "mediacraft",
    privileges: {
      standard: true,
      secure: true,
      supportFetchAPI: true,
      corsEnabled: true,
      stream: true,
    },
  },
]);
const arg = (name) => {
  const i = process.argv.indexOf(name);
  return i < 0 ? null : process.argv[i + 1];
};
const dataDir = path.resolve(
  arg("--data-dir") || path.join(app.getPath("appData"), "Vibepost"),
);
fsSync.mkdirSync(path.join(dataDir, "tmp"), { recursive: true });
app.setPath("userData", dataDir);
app.setPath("sessionData", path.join(dataDir, "Chromium"));
process.env.TEMP = process.env.TMP = path.join(dataDir, "tmp");
app.setName("Vibepost");
const webRoot = app.isPackaged
  ? path.join(process.resourcesPath, "web")
  : path.resolve(__dirname, "..");
const assets = app.isPackaged
  ? path.join(process.resourcesPath, "windows")
  : path.join(__dirname, "resources");
const version = fsSync
  .readFileSync(path.join(webRoot, "VERSION"), "utf8")
  .trim();
const states = new WindowState();
const views = new Map();
const activeDispatch = new Map();
const dispatchQueues = new Map();
const phoneOwners = new Map();
let ai,
  mcp,
  phone,
  motion,
  library,
  quitting = false,
  disposing = false;
const key = (owner) => `${owner.id}:${owner.epoch}`;
function emit(owner, kind, event) {
  const state = states.windows.get(Number(owner.id));
  const view = views.get(Number(owner.id));
  if (state?.epoch === owner.epoch && view && !view.isDestroyed())
    view.webContents.send("native:event", { kind, event });
}
function broadcast(kind, event) {
  for (const state of states.windows.values()) emit(state, kind, event);
}
function trusted(event) {
  const view = BrowserWindow.fromWebContents(event.sender);
  if (
    !view ||
    event.senderFrame !== event.sender.mainFrame ||
    !/^mediacraft:\/\/app\//.test(event.senderFrame.url)
  )
    throw new Error("无效的窗口来源");
  return states.owner(view.id);
}
function owned(owner, draftId) {
  const state = states.assert(owner);
  if (typeof draftId !== "string" || !state.held.has(draftId))
    throw new Error("这个窗口没有打开这篇稿子");
  return state;
}
function decode(data, max = 256 * 1024 * 1024) {
  if (
    typeof data !== "string" ||
    data.length > Math.ceil(max / 3) * 4 + 4 ||
    !/^[A-Za-z0-9+/]*={0,2}$/.test(data)
  )
    throw new Error("文件数据不合规");
  return Buffer.from(data, "base64");
}
async function saved(view) {
  try {
    return await view.webContents.executeJavaScript(
      "window.mediacraft?.drafts.saveNow().then(()=>true) ?? Promise.resolve(true)",
    );
  } catch (error) {
    const result = await dialog.showMessageBox(view, {
      type: "warning",
      buttons: ["返回编辑", "仍然关闭"],
      defaultId: 0,
      cancelId: 0,
      message: "稿件保存失败",
      detail: error.message,
    });
    return result.response === 1;
  }
}
async function persist() {
  await atomicJson(
    path.join(dataDir, "windows.json"),
    [...states.windows.values()].map((s) => s.current).filter(Boolean),
  );
}
async function releaseOwner(owner) {
  await ai?.closeOwner(owner);
  for (const [job, entry] of motion?.jobs || [])
    if (entry.owner === key(owner)) motion.cancel(job, key(owner));
  for (const [session, holder] of phoneOwners)
    if (holder === key(owner)) {
      phoneOwners.delete(session);
      await phone.stop(session);
    }
}
async function ready(view) {
  for (let attempt = 0; attempt < 300; attempt++) {
    if (view.isDestroyed()) throw new Error("窗口已关闭");
    if (
      await view.webContents
        .executeJavaScript(
          "Boolean(window.mediacraft && window.MediaCraftDrafts?.currentId())",
        )
        .catch(() => false)
    )
      return;
    await new Promise((resolve) => setTimeout(resolve, 100));
  }
  throw new Error("编辑器启动超时");
}
function show(view, draftId) {
  view.webContents.send("native:window", { type: "show", draftId });
  if (view.isMinimized()) view.restore();
  view.show();
  view.focus();
}
async function createWindow({
  draftId,
  fresh = false,
  panel,
  background = false,
} = {}) {
  const view = new BrowserWindow({
    width: 1360,
    height: 940,
    minWidth: 900,
    minHeight: 650,
    show: false,
    title: "Vibepost",
    icon: path.join(assets, "icon.ico"),
    backgroundColor: "#f6f5f1",
    webPreferences: {
      preload: path.join(__dirname, "preload.cjs"),
      contextIsolation: true,
      nodeIntegration: false,
      sandbox: false,
      webviewTag: false,
    },
  });
  states.add(view.id);
  views.set(view.id, view);
  if (draftId) {
    const state = states.windows.get(view.id);
    state.current = draftId;
    state.held.add(draftId);
  }
  let first = true,
    closing = false;
  view.webContents.on("did-start-navigation", (_e, url, inPlace, isMain) => {
    if (!isMain || inPlace) return;
    if (first) {
      first = false;
      return;
    }
    const previous = states.reload(view.id);
    void releaseOwner(previous);
  });
  view.webContents.on("will-navigate", (event, url) => {
    if (!url.startsWith("mediacraft://app/")) event.preventDefault();
  });
  view.webContents.setWindowOpenHandler(() => ({ action: "deny" }));
  view.webContents.on(
    "render-process-gone",
    () => void releaseOwner(states.owner(view.id)),
  );
  view.on("close", (event) => {
    if (closing || quitting) return;
    event.preventDefault();
    void (async () => {
      if (await saved(view)) {
        closing = true;
        await persist().catch(console.error);
        view.close();
      }
    })();
  });
  view.on("closed", () => {
    const owner = states.owner(view.id);
    void releaseOwner(owner);
    states.remove(view.id);
    views.delete(view.id);
  });
  const query = new URLSearchParams();
  if (draftId) query.set("draft", draftId);
  if (fresh) query.set("new", "1");
  if (panel) query.set("panel", panel);
  await view.loadURL("mediacraft://app/index.html?" + query.toString());
  await ready(view);
  if (background) view.showInactive();
  else view.show();
  if (process.argv.includes("--dev"))
    view.webContents.openDevTools({ mode: "detach" });
  return view;
}
async function dispatchMcp(request) {
  const name = request.method === "tools/call" ? request.params?.name : null;
  const bound = states.bindings.get(request.session);
  let state = bound
    ? [...states.windows.values()].find((s) => s.current === bound)
    : null;
  let view;
  if (name === "create_draft") {
    view = await createWindow({ fresh: true, background: true });
    request = { ...request, reuseBlank: true };
  } else if (
    name === "open_draft" &&
    typeof request.params?.arguments?.id === "string" &&
    request.params.arguments.id.length > 0 &&
    request.params.arguments.id.length <= 200
  ) {
    const id = request.params.arguments.id;
    state =
      [...states.windows.values()].find((s) => s.current === id) ||
      states.holder(id);
    if (state && state.current !== id)
      return JSON.stringify({
        result: {
          content: [
            {
              type: "text",
              text: "这篇稿子的 AI 正在其他窗口运行，请等待完成",
            },
          ],
          isError: true,
        },
      });
    view = state
      ? views.get(state.id)
      : await createWindow({ draftId: id, background: true });
  } else
    view =
      (state && views.get(state.id)) ||
      BrowserWindow.getFocusedWindow() ||
      [...views.values()][0] ||
      (await createWindow());
  await ready(view);
  const run = (dispatchQueues.get(view.id) || Promise.resolve())
    .catch(() => {})
    .then(async () => {
      const context = {
        ...request,
        bound: states.bindings.get(request.session) || null,
      };
      activeDispatch.set(view.id, {
        session: request.session,
        epoch: states.owner(view.id).epoch,
        exportRequest: request.exportRequest,
      });
      try {
        return await view.webContents.executeJavaScript(
          `window.MediaCraftMCP.handle(${JSON.stringify(JSON.stringify(context))})`,
        );
      } finally {
        activeDispatch.delete(view.id);
      }
    });
  dispatchQueues.set(view.id, run);
  run
    .finally(() => {
      if (dispatchQueues.get(view.id) === run) dispatchQueues.delete(view.id);
    })
    .catch(() => {});
  return run;
}
ipcMain.on("native:epoch", (event) => {
  try {
    event.returnValue = trusted(event).epoch;
  } catch {
    event.returnValue = -1;
  }
});
ipcMain.handle(
  "native:call",
  async (event, { epoch, action, params = {} } = {}) => {
    try {
      const owner = trusted(event);
      if (owner.epoch !== epoch) throw new Error("页面已失效");
      const view = views.get(owner.id);
      const state = states.assert(owner);
      if (
        typeof action !== "string" ||
        !params ||
        typeof params !== "object" ||
        Array.isArray(params)
      )
        throw new Error("请求不合规");
      if (
        action.startsWith("ai/") &&
        !["ai/status", "ai/settings", "ai/models", "ai/remove"].includes(action)
      )
        owned(owner, params.draftId);
      switch (action) {
        case "ai/status":
          return await ai.status(params.refresh, params.backend);
        case "ai/settings":
          return await ai.setPath(params.path, params.backend);
        case "ai/models":
          return await ai.models(params.backend);
        case "ai/send":
          return await ai.send(owner, params);
        case "ai/respond":
          return await ai.respond(owner, params);
        case "ai/work-file":
          return await ai.workFile(owner, params);
        case "ai/candidate":
          return await ai.candidate(owner, params);
        case "ai/candidate-file":
          return await ai.candidateFile(owner, params);
        case "ai/generate-image":
          return await ai.generateImage(owner, params);
        case "ai/cancel":
          return await ai.cancel(owner, params);
        case "ai/generate-cancel":
          return await ai.generateCancel(owner, params);
        case "ai/remove":
          if (states.holder(params.draftId, owner.id))
            throw new Error("这个窗口没有打开这篇稿子");
          return await ai.remove(owner, params);
        case "window/claim": {
          if (typeof params.draftId !== "string")
            throw new Error("稿件编号不合规");
          const holder = states.holder(params.draftId, owner.id);
          if (holder && params.focus !== false)
            show(views.get(holder.id), params.draftId);
          if (!holder) state.held.add(params.draftId);
          return { elsewhere: Boolean(holder) };
        }
        case "window/occupy": {
          const result = states.occupy(owner, params);
          void persist().catch(console.error);
          return result;
        }
        case "window/open": {
          const holder = states.holder(params.draftId);
          if (holder) {
            show(views.get(holder.id), params.draftId);
            return {};
          }
          await createWindow({
            draftId: params.draftId,
            fresh: !params.draftId,
            panel: params.panel,
          });
          return {};
        }
        case "window/missing":
          if (views.size > 1) setImmediate(() => view.close());
          return {};
        case "window/edited":
          view.setDocumentEdited(Boolean(params.edited));
          return {};
        case "window/info":
          return { version, updates: true, platform: "windows" };
        case "window/updates":
          await shell.openExternal(
            "https://github.com/wuyoscar/Vibepost/releases",
          );
          return {};
        case "window/bind": {
          const dispatch = activeDispatch.get(owner.id);
          if (
            !dispatch ||
            dispatch.epoch !== epoch ||
            dispatch.session !== params.session ||
            state.current !== params.draftId
          )
            throw new Error("无效的 MCP 会话");
          states.bind(params.session, params.draftId);
          return {};
        }
        case "clipboard/text":
          clipboard.writeText(String(params.text || ""));
          return {};
        case "clipboard/rich":
          clipboard.write({
            html: String(params.html || ""),
            text: String(params.text || ""),
          });
          return {};
        case "save": {
          const name = safeName(params.name, 240);
          const bytes = decode(params.data);
          const result = await dialog.showSaveDialog(view, {
            defaultPath: path.join(dataDir, "导出", name),
            createDirectory: true,
          });
          if (result.canceled || !result.filePath)
            throw Object.assign(new Error("已取消保存"), {
              name: "AbortError",
            });
          await fs.mkdir(path.dirname(result.filePath), { recursive: true });
          await fs.writeFile(result.filePath, bytes);
          return {
            name: path.basename(result.filePath),
            path: result.filePath,
          };
        }
        case "motion/render":
          return await motion.render(key(owner), params);
        case "motion/cancel":
          return motion.cancel(params.job, key(owner));
        case "phone/start": {
          const result = await phone.start(params);
          try {
            states.assert(owner);
          } catch (error) {
            await phone.stop(result.session);
            throw error;
          }
          phoneOwners.set(result.session, key(owner));
          return result;
        }
        case "phone/stop":
          if (phoneOwners.get(params.session) !== key(owner))
            throw new Error("传输属于其他窗口");
          phoneOwners.delete(params.session);
          return await phone.stop(params.session);
        case "mcp/status":
          return mcp.status();
        case "mcp/enabled":
          return await mcp.setEnabled(params.enabled);
        case "mcp/write": {
          const dispatch = activeDispatch.get(owner.id);
          if (
            !dispatch ||
            dispatch.epoch !== epoch ||
            !dispatch.exportRequest ||
            dispatch.exportRequest !== params.request
          )
            throw new Error("没有正在执行的 MCP 导出");
          return await mcp.write({ ...params, data: decode(params.data) });
        }
        default: {
          const match =
            /^(manuals|templates)\/(list|read|save|remove|reveal|open)$/.exec(
              action,
            );
          if (!match) throw new Error("未知的原生调用");
          const [, kind, operation] = match;
          if (operation === "reveal" || operation === "open") {
            const folder = library.folder(kind);
            const target = params.name
              ? path.join(
                  folder,
                  safeName(params.name) + (kind === "manuals" ? ".md" : ""),
                )
              : folder;
            if (operation === "reveal") shell.showItemInFolder(target);
            else {
              const error = await shell.openPath(target);
              if (error) throw new Error(error);
            }
            return {};
          }
          return await library[kind](operation, params);
        }
      }
    } catch (error) {
      return {
        __error: {
          name: error.name,
          message: error.message,
          status: error.status,
        },
      };
    }
  },
);
async function staticResponse(request) {
  const url = new URL(request.url);
  if (url.hostname !== "app") return new Response("Not found", { status: 404 });
  let name;
  try {
    name = decodeURIComponent(url.pathname);
  } catch {
    return new Response("Bad request", { status: 400 });
  }
  let target;
  const routes = [
    ["/__windows/browser/", path.join(__dirname, "browser")],
    ["/__windows/renderer/", path.join(__dirname, "renderer")],
    ["/__windows/vendor/pdf/", path.join(assets, "pdf")],
    ["/src/", path.join(webRoot, "src")],
    ["/fonts/", path.join(webRoot, "fonts")],
    ["/brand/", path.join(webRoot, "brand")],
    ["/docs/guide-assets/", path.join(webRoot, "docs", "guide-assets")],
    ["/docs/template-assets/", path.join(webRoot, "docs", "template-assets")],
  ];
  const route = routes.find(([prefix]) => name.startsWith(prefix));
  if (route) {
    const [prefix, directory] = route;
    target = path.resolve(directory, name.slice(prefix.length));
    if (!within(directory, target))
      return new Response("Forbidden", { status: 403 });
  } else if (name === "/index.html" || name === "/VERSION") {
    target = path.join(webRoot, name.slice(1));
  } else return new Response("Not found", { status: 404 });
  try {
    if (name === "/index.html") {
      let html = await fs.readFile(target, "utf8");
      html = html.replace(
        "</head>",
        '<script src="/__windows/browser/pdf.js"></script><script src="/__windows/browser/host.js"></script><link rel="stylesheet" href="/__windows/renderer/phone-transfer.css"></head>',
      );
      html = html.replace(
        "</body>",
        '<script src="/__windows/renderer/phone-transfer.js"></script><script src="/__windows/renderer/media-ui.js"></script></body>',
      );
      return new Response(html, {
        headers: { "content-type": "text/html; charset=utf-8" },
      });
    }
    return await net.fetch(pathToFileURL(target).href);
  } catch {
    return new Response("Not found", { status: 404 });
  }
}
async function shutdown() {
  if (disposing) return;
  disposing = true;
  await persist().catch(console.error);
  await Promise.allSettled([
    ai?.dispose(),
    mcp?.dispose(),
    phone?.dispose(),
    motion?.dispose(),
  ]);
  quitting = true;
  app.quit();
}
if (!app.requestSingleInstanceLock({ dataDir })) app.quit();
else {
  app.on("second-instance", () => {
    const view = [...views.values()][0];
    if (view) show(view);
  });
  app.on("window-all-closed", () => void shutdown());
  app.on("before-quit", (event) => {
    if (!quitting) {
      event.preventDefault();
      void (async () => {
        for (const view of views.values()) if (!(await saved(view))) return;
        await shutdown();
      })();
    }
  });
  app
    .whenReady()
    .then(async () => {
      protocol.handle("mediacraft", staticResponse);
      library = new Library(dataDir, webRoot);
      await library.seed();
      ai = new AiService({
        dataDir,
        nativeImage,
        emit: (owner, event) => emit(owner, "ai", event),
      });
      phone = new PhoneService({ dataDir });
      motion = new MotionService({
        dataDir,
        ffmpegPath: path.join(assets, "ffmpeg", "ffmpeg.exe"),
        ffprobePath: path.join(assets, "ffmpeg", "ffprobe.exe"),
        emit: (owner, event) => {
          const [id, epoch] = owner.split(":").map(Number);
          emit({ id, epoch }, "motion", event);
        },
      });
      mcp = new McpService({
        dataDir,
        executable: process.execPath,
        helperPath: app.isPackaged
          ? path.join(process.resourcesPath, "mcp", "stdio.cjs")
          : path.join(__dirname, "mcp", "stdio.cjs"),
        appArgs: app.isPackaged ? [] : [__dirname],
        dispatch: dispatchMcp,
        emit: (event) => broadcast("mcp", event),
        prepareImage: (bytes) => {
          const image = nativeImage.createFromBuffer(bytes);
          if (image.isEmpty()) throw new Error("图片解码失败");
          return image;
        },
      });
      await mcp
        .start()
        .catch((error) => console.error("MCP unavailable:", error.message));
      Menu.setApplicationMenu(
        Menu.buildFromTemplate([
          {
            label: "文件",
            submenu: [
              {
                label: "新建窗口",
                accelerator: "CmdOrCtrl+N",
                click: () => void createWindow({ fresh: true }),
              },
              { role: "close" },
              { role: "quit" },
            ],
          },
          {
            label: "编辑",
            submenu: [
              { role: "undo" },
              { role: "redo" },
              { type: "separator" },
              { role: "cut" },
              { role: "copy" },
              { role: "paste" },
              { role: "selectAll" },
            ],
          },
          {
            label: "查看",
            submenu: [
              {
                label: "重新载入",
                accelerator: "CmdOrCtrl+R",
                click: async (_item, view) => {
                  if (view && (await saved(view))) view.webContents.reload();
                },
              },
              { role: "toggleDevTools" },
              { role: "resetZoom" },
              { role: "zoomIn" },
              { role: "zoomOut" },
              { role: "togglefullscreen" },
            ],
          },
        ]),
      );
      let restore = [];
      try {
        restore = JSON.parse(
          await fs.readFile(path.join(dataDir, "windows.json"), "utf8"),
        );
      } catch {}
      const ids = Array.isArray(restore)
        ? [...new Set(restore.filter((id) => typeof id === "string"))].slice(
            0,
            12,
          )
        : [];
      if (ids.length)
        for (const draftId of ids) await createWindow({ draftId });
      else await createWindow();
    })
    .catch((error) => {
      dialog.showErrorBox("Vibepost 启动失败", error.stack || error.message);
      quitting = true;
      app.quit();
    });
}
