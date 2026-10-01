// 稿子的本机存储：IndexedDB「mediacraft」放稿子、图片与实况视频，localStorage 只放两个小偏好。
// 布局与迁移规则见 docs/storage.md。这里只管读写，不懂稿子的内容。
// 几个窗口共用这一份存储：每次写完经 BroadcastChannel 告诉别的窗口写了哪些稿子、删了哪些、改了哪些 meta（onExternalChange）。
(function (root) {
  "use strict";

  const DB_NAME = "mediacraft";
  const DB_VERSION = 1;
  const PREFS_KEY = "mediacraft.prefs.v1";
  const STORES = ["drafts", "media", "meta"];
  // 告诉别的窗口（同一 origin 的别的页面）存了什么；浏览器里别的标签页也收得到
  const CHANNEL = "mediacraft-store";

  // ===== IndexedDB 基础 =====

  function request(req) {
    return new Promise((resolve, reject) => {
      req.onsuccess = () => resolve(req.result);
      req.onerror = () => reject(req.error);
    });
  }

  function finished(tx) {
    return new Promise((resolve, reject) => {
      tx.oncomplete = () => resolve();
      tx.onabort = () => reject(tx.error || new Error("存储事务被中止"));
      tx.onerror = () => reject(tx.error);
    });
  }

  function openDatabase() {
    if (!root.indexedDB) return Promise.reject(new Error("这个环境不支持 IndexedDB，稿子无法保存"));
    const req = root.indexedDB.open(DB_NAME, DB_VERSION);
    req.onupgradeneeded = () => {
      const db = req.result;
      db.createObjectStore("drafts", { keyPath: "id" });
      db.createObjectStore("media", { keyPath: "key" }).createIndex("draftId", "draftId");
      db.createObjectStore("meta", { keyPath: "key" });
    };
    // 旧页面还开着同一个库时不会卡住：它收到 versionchange 就关掉。
    return request(req).then((db) => {
      db.onversionchange = () => db.close();
      return db;
    });
  }

  // ===== 媒体：图片存 Blob，实况视频存原文件 =====

  // 图片在内存里是 data URL。能原样还原的（小写 MIME + 规范 base64）存成 Blob 省三分之一空间，
  // 其余的（极少见，比如百分号编码的 SVG）原样存字符串，保证读回来一字不差。
  const CANONICAL_DATA_URL = /^data:([a-z0-9.+-]+\/[a-z0-9.+-]+);base64,([A-Za-z0-9+/]*={0,2})$/;

  function dataUrlToStored(url) {
    const match = CANONICAL_DATA_URL.exec(url);
    if (!match || match[2].length % 4 !== 0) return url;
    const binary = atob(match[2]);
    const bytes = new Uint8Array(binary.length);
    for (let index = 0; index < binary.length; index += 1) bytes[index] = binary.charCodeAt(index);
    return new Blob([bytes], { type: match[1] });
  }

  function storedToDataUrl(value) {
    if (typeof value === "string") return Promise.resolve(value);
    return new Promise((resolve, reject) => {
      const reader = new FileReader();
      reader.onload = () => resolve(reader.result);
      reader.onerror = () => reject(reader.error);
      reader.readAsDataURL(value);
    });
  }

  function mediaKey(draftId, kind, id) {
    return `${draftId}/${kind}/${id}`;
  }

  // ===== 对外 =====

  let db = null;

  async function open() {
    db = await openDatabase();
  }

  // 一次读写事务：changes 里的操作要么全部生效，要么都不生效。
  //   drafts: 要写入的稿子；deleteDrafts: 要删的稿子 id（连同它们的全部媒体）；
  //   media: 要写入的 { draftId, kind: "image" | "video", id, data }；deleteMedia: 要删的 [draftId, kind, id]；
  //   meta: 要写入的 { key, ... }。
  // 所有请求在开事务时一次发出（不在回调里再发：页面换走、被挂起时，等着回调的事务会一直占着库，下一个页面就打不开了）。
  // 写完告诉别的窗口（写不成时不说）。
  async function write(changes) {
    const tx = db.transaction(STORES, "readwrite");
    const done = finished(tx);
    const drafts = tx.objectStore("drafts");
    const media = tx.objectStore("media");
    for (const record of changes.drafts || []) drafts.put(record);
    for (const item of changes.media || []) {
      media.put({ key: mediaKey(item.draftId, item.kind, item.id), draftId: item.draftId, kind: item.kind, id: item.id, data: item.data });
    }
    for (const [draftId, kind, id] of changes.deleteMedia || []) media.delete(mediaKey(draftId, kind, id));
    for (const id of changes.deleteDrafts || []) {
      drafts.delete(id);
      media.index("draftId").openKeyCursor(IDBKeyRange.only(id)).onsuccess = (event) => {
        const cursor = event.target.result;
        if (!cursor) return;
        media.delete(cursor.primaryKey);
        cursor.continue();
      };
    }
    for (const record of changes.meta || []) tx.objectStore("meta").put(record);
    await done;
    announce({
      drafts: (changes.drafts || []).map((record) => record.id),
      deleted: [...(changes.deleteDrafts || [])],
      meta: (changes.meta || []).map((record) => record.key),
    });
  }

  // ===== 别的窗口 =====

  const channel = typeof root.BroadcastChannel === "function" ? new root.BroadcastChannel(CHANNEL) : null;

  function announce(change) {
    if (!channel || !(change.drafts.length || change.deleted.length || change.meta.length)) return;
    try {
      channel.postMessage(change);
    } catch {
      // 告诉不了别的窗口只是它们晚一点才看到（重新打开时读的是存储里的）
    }
  }

  // 别的窗口写完了：listener({ drafts: 写了的稿子 id, deleted: 删了的稿子 id, meta: 改了的 meta 键 })
  function onExternalChange(listener) {
    channel?.addEventListener("message", (event) => listener(event.data));
  }

  // 页面换走（重新载入、关窗口）时关掉广播与库：页面可能被放进往返缓存挂起，挂起的页面再收到广播、开读写，
  // 事务就一直占着库，下一个页面打不开。万一又回到这个页面（往返缓存里取出来），整页重新载入
  root.addEventListener("pagehide", () => {
    channel?.close();
    db?.close();
  });
  root.addEventListener("pageshow", (event) => {
    if (event.persisted) root.location.reload();
  });

  async function readAll(storeName) {
    return request(db.transaction(storeName).objectStore(storeName).getAll());
  }

  async function readDraft(id) {
    return (await request(db.transaction("drafts").objectStore("drafts").get(id))) ?? null;
  }

  // 一篇稿子的全部媒体：{ images: { 图片 id: data URL }, videos: { 视频 key: Blob } }
  async function readMedia(draftId) {
    const items = await request(db.transaction("media").objectStore("media").index("draftId").getAll(IDBKeyRange.only(draftId)));
    const images = {};
    const videos = {};
    for (const item of items) {
      if (item.kind === "video") videos[item.id] = item.data;
      else images[item.id] = await storedToDataUrl(item.data);
    }
    return { images, videos };
  }

  async function readVideo(draftId, key) {
    const item = await request(db.transaction("media").objectStore("media").get(mediaKey(draftId, "video", key)));
    return item?.data ?? null;
  }

  async function readMeta(key) {
    return (await request(db.transaction("meta").objectStore("meta").get(key))) ?? null;
  }

  // 小偏好（当前稿子、上次选的主题）：同步读写，写不进去时不影响稿子本身。
  function readPrefs() {
    try {
      const prefs = JSON.parse(root.localStorage.getItem(PREFS_KEY) || "{}");
      return prefs && typeof prefs === "object" ? prefs : {};
    } catch {
      return {};
    }
  }

  function writePrefs(patch) {
    const prefs = { ...readPrefs(), ...patch };
    try {
      root.localStorage.setItem(PREFS_KEY, JSON.stringify(prefs));
    } catch {
      // 写不进时这次会话照常用内存里的值，下次启动退回默认。
    }
    return prefs;
  }

  const drafts = (root.MediaCraftDrafts ||= {});
  drafts.store = {
    open,
    write,
    readAll,
    readDraft,
    readMedia,
    readVideo,
    readMeta,
    readPrefs,
    writePrefs,
    onExternalChange,
    dataUrlToStored,
    storedToDataUrl,
  };
})(window);
