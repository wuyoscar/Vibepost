// 稿子管理：全部稿子常驻内存（不含图片、视频本体），改动后自动存进本机（停手约 0.4 秒，一直在改时至少每 2 秒一次，
// 不等出图），也能马上存（saveNow：保存按钮、⌘S、壳在退出 / 关窗 / 重新载入前）；新建、打开、删除、署名、上次的主题。
// 界面（编辑器、表单）由宿主适配：start(host) 时传进来，这里不碰 src/app.js 的内部名字。
//   host.builtIns        内置说明书：[{ id, title, record }]，只读，不存盘
//   host.defaultProfile  默认署名 { name, handle, avatar, avatarCrop }（还没存过署名时用）
//   host.guideProfile    内置说明书的署名（没给时用默认署名）
//   host.blank()         新稿子的字段（沿用上次选的主题）
//   host.capture()       当前界面上的这篇：{ fields（记录里除 id、时间戳外的字段，图片只有信息）, sources（图片 id → data URL）, profile（署名）}
//   host.apply(record, media, profile)  把一篇稿子放到界面上（同步）
//   host.opened(record)  放上去之后：出图、刷新只读状态等（异步）
//   host.claim(id, { focus })  这个窗口能不能打开这篇（同一篇只在一个窗口里开，src/drafts/windows.js）；focus 时那篇在别的窗口里
//                        就把那个窗口调到前面、换到那篇。没有时都能开
//   host.showProfile(profile)  别的窗口改了署名：换到界面上（异步）
// 几个窗口共用一份存储：别的窗口存下的稿子、删掉的稿子、改的署名经 store.onExternalChange 跟过来。
(function (root) {
  "use strict";

  const drafts = (root.MediaCraftDrafts ||= {});
  const { store } = drafts;
  // AI 的工作副本与配图候选在壳管的目录里（docs/storage.md），删稿子时一起删；浏览器里没有
  const nativeAI = root.MediaCraftNative?.ai ?? null;

  // 不再受 localStorage 5 MB 的限制（稿子与媒体都在 IndexedDB），这个上限只防脚本失控连续建稿；到了会明说，不删旧稿。
  const LIMIT = 1000;
  const TITLE_LENGTH = 24;
  const UNTITLED = "未命名稿件";
  // 每篇最多留这么多个版本（每轮 AI 之前存一个），多了删最旧的
  const VERSION_LIMIT = 50;
  const VERSION_FIELDS = ["title", "caption", "markdown", "mode", "theme", "colors", "tunedColors", "fonts", "fontSize", "lineHeight", "imageMaxHeight", "cover", "cardCss", "images"];

  let host = null;
  let builtIns = [];
  const records = new Map();
  let currentId = null;
  let profile = null;
  // 上一次存下的署名（JSON）；存盘失败时清空，下次重写
  let savedProfile = "";
  let prefs = {};
  // 当前稿子上一次存下（或打开时）的样子，用来判断有没有改动；存盘失败时置空，下次整篇重写。
  let baseline = null;
  // 当前稿子已经存进本机的图片：图片 id → data URL
  let persistedImages = new Map();
  let lastChangeSignature = "";
  let writes = Promise.resolve();
  let writeError = null;
  // 新建、打开、删除依次进行，免得连点时交错
  let switching = Promise.resolve();
  // change：当前稿子改了；list：稿子列表变了；removed-elsewhere：正开着的这篇在别的窗口里删了，已经换到另一篇；
  // save-state：存盘状态变了（见下面「存盘状态」）
  const listeners = { change: new Set(), list: new Set(), "removed-elsewhere": new Set(), "save-state": new Set() };
  // 别的窗口删掉的稿子：排着的写入里它的那部分到写的时候丢掉；这个窗口写过的稿子（只有开着它的窗口会写）
  const forgotten = new Set();
  const written = new Set();
  // 「新建窗口」（?new=1）启动时新建的那篇空稿子：外部 Agent 的 create_draft 只能用它，不会改到别的稿子
  let freshId = null;

  const summaries = new WeakMap();

  function emit(type, detail) {
    for (const listener of listeners[type]) listener(detail);
  }

  // ===== 标题与搜索 =====

  function textOfRuns(runs) {
    return (runs || []).map((run) => run.text).join("");
  }

  function blockText(block) {
    if (block.type === "heading") return textOfRuns(block.runs);
    if (block.type === "paragraph" || block.type === "quote") return textOfRuns(block.lines?.find((line) => textOfRuns(line.runs).trim())?.runs);
    if (block.type === "list") return textOfRuns(block.items?.[0]?.runs);
    if (block.type === "code") return String(block.text || "").split("\n")[0];
    if (block.type === "table") return block.header.cells.map((cell) => textOfRuns(cell.runs)).join(" ");
    return "";
  }

  // 列表里显示的名字：自己填的标题；没填时取正文第一行文字（去掉 Markdown 标记），只看开头一段。
  function firstLine(markdown) {
    const head = String(markdown || "").slice(0, 2000);
    const { blocks } = root.MediaCraftEngine.parseMarkdown(head);
    for (const block of blocks) {
      const text = blockText(block).trim();
      if (text) return text;
    }
    return "";
  }

  // 存储里读出来的记录：用的是定稿之前的旧主题时换成接替它的新主题，没调过的配色换成新主题的
  // （src/themes/themes.js 的 migrate；每轮 AI 之前存的版本一样换）。启动时换过的一次写回去。
  function upgrade(record) {
    const themes = root.MediaCraftThemes;
    if (!record || !themes) return record;
    let versionsChanged = false;
    const versions = Array.isArray(record.versions)
      ? record.versions.map((version) => {
        const changes = version?.draft && themes.migrate(version.draft);
        if (!changes) return version;
        versionsChanged = true;
        return { ...version, draft: { ...version.draft, ...changes } };
      })
      : null;
    const changes = themes.migrate(record);
    if (!changes && !versionsChanged) return record;
    return { ...record, ...changes, ...(versionsChanged ? { versions } : {}) };
  }

  function summaryOf(record) {
    let summary = summaries.get(record);
    if (!summary) {
      const name = Array.from(String(record.title || "").trim() || firstLine(record.markdown)).slice(0, TITLE_LENGTH).join("");
      summary = { title: name || UNTITLED, haystack: `${record.title || ""}\n${record.caption || ""}\n${record.markdown || ""}`.toLowerCase() };
      summaries.set(record, summary);
    }
    return summary;
  }

  // ===== 查询 =====

  function isBuiltIn(id) {
    return builtIns.some((item) => item.id === id);
  }

  function get(id) {
    return records.get(id) ?? builtIns.find((item) => item.id === id)?.record ?? null;
  }

  function own() {
    return [...records.values()].sort((a, b) => b.updatedAt - a.updatedAt || String(a.id).localeCompare(String(b.id)));
  }

  function summarize(record, builtInTitle) {
    const builtIn = builtInTitle !== undefined;
    return {
      id: record.id,
      title: builtIn ? builtInTitle : summaryOf(record).title,
      mode: record.mode === "article" ? "article" : "cards",
      updatedAt: builtIn ? 0 : record.updatedAt,
      builtIn,
      current: record.id === currentId,
    };
  }

  // 全部稿子：内置说明书在前，自己的按最近修改在前。
  function list() {
    return [...builtIns.map((item) => summarize(item.record, item.title)), ...own().map((record) => summarize(record))];
  }

  // 按名字、小红书正文与卡片内容搜（不分大小写），mode 为 "cards" / "article" 时只要这一种。
  function search(query = "", mode = "all") {
    const needle = String(query).trim().toLowerCase();
    return list().filter((item) => (mode === "all" || item.mode === mode) && (!needle || summaryOf(get(item.id)).haystack.includes(needle)));
  }

  // ===== 存盘状态（顶栏的保存按钮 src/drafts/save-button.js、窗口的「有改动」标记）=====
  // status：saved 都存好了（savedAt 是最近一次写好的时间，刚打开时是这篇的修改时间）；pending 有改动、过一会儿就存；
  // saving 正在写；error 没存上（error 是原因；过一会儿自动再试，也可以 saveNow）；none 没有要存的（内置说明书、正在换稿子）。

  const SAVE_DELAY = 400; // 停手这么久就存
  const SAVE_MAX_WAIT = 2000; // 一直在改时至少隔这么久存一次
  const RETRY_DELAY = 5000; // 没存上时隔这么久再试
  let saveTimer = 0;
  let retryTimer = 0;
  let pendingSince = 0;
  let savesInFlight = 0;
  let saveFailure = null;
  let savedAt = null;
  let saveState = { status: "none", savedAt: null, error: null };

  // 按现在的情况算出状态，变了才发 save-state；explicit（马上存之后）总是发，保存按钮借它告诉用户「存好了」
  function settle({ explicit = false } = {}) {
    let status = "saved";
    if (!currentId || isBuiltIn(currentId)) status = "none";
    else if (saveFailure) status = "error";
    else if (saveTimer) status = "pending";
    else if (savesInFlight) status = "saving";
    const next = { status, savedAt: status === "none" ? null : savedAt, error: status === "error" ? saveFailure : null };
    const same = next.status === saveState.status && next.savedAt === saveState.savedAt && next.error === saveState.error;
    saveState = next;
    if (!same || explicit) emit("save-state", { ...next, draftId: currentId, explicit });
  }

  // 界面上改了点什么：过一会儿存（连续改动顺延，但最多等 SAVE_MAX_WAIT）
  function saveSoon() {
    if (!currentId || isBuiltIn(currentId)) return;
    const now = Date.now();
    if (!saveTimer) pendingSince = now;
    clearTimeout(saveTimer);
    saveTimer = setTimeout(save, Math.max(0, Math.min(SAVE_DELAY, pendingSince + SAVE_MAX_WAIT - now)));
    settle();
  }

  // 马上存（保存按钮、⌘S、壳在退出 / 关窗 / 重新载入前）：不再等、存、等写完；没存上时 reject 原因。之前没存上过就整篇重写
  async function saveNow() {
    if (currentId && !isBuiltIn(currentId)) {
      if (saveFailure || writeError) baseline = null;
      save();
    }
    try {
      await flush();
    } finally {
      settle({ explicit: true });
    }
    return { ...saveState, draftId: currentId };
  }

  function retryLater() {
    clearTimeout(retryTimer);
    retryTimer = setTimeout(() => {
      if (saveFailure) save();
    }, RETRY_DELAY);
  }

  // ===== 存盘 =====

  // 排队写：写的时候丢掉别的窗口已经删了的稿子（连同它的媒体），不把它写回去
  function enqueue(changes, onError) {
    for (const record of changes.drafts || []) written.add(record.id);
    const run = writes.then(() => store.write(withoutForgotten(changes)));
    writes = run.then(
      () => {
        writeError = null;
      },
      (error) => {
        writeError = error;
        onError?.();
        emit("list");
      },
    );
    return run;
  }

  function withoutForgotten(changes) {
    if (!forgotten.size) return changes;
    return {
      ...changes,
      drafts: (changes.drafts || []).filter((record) => !forgotten.has(record.id)),
      media: (changes.media || []).filter((item) => !forgotten.has(item.draftId)),
      deleteMedia: (changes.deleteMedia || []).filter(([draftId]) => !forgotten.has(draftId)),
    };
  }

  // 等所有排队的写入完成；有写入失败时报错（改动还在内存里，下次存盘会重试）。
  async function flush() {
    await writes;
    if (writeError) throw new Error(`没能存进本机：${writeError.message || writeError}`);
  }

  // 存当前稿子：界面上的内容与上次存下的不同才写。内置说明书不存。改动（含切换到另一篇）会发 change。
  function save() {
    clearTimeout(saveTimer);
    saveTimer = 0;
    if (!currentId || isBuiltIn(currentId)) return settle();
    const { fields, sources, profile: nextProfile } = host.capture();
    const changes = { drafts: [], media: [], deleteMedia: [], meta: [] };
    profile = nextProfile;
    if (JSON.stringify(profile) !== savedProfile) {
      savedProfile = JSON.stringify(profile);
      changes.meta.push({ key: "profile", ...profile });
    }
    const puts = Object.entries(sources).filter(([id, src]) => persistedImages.get(id) !== src);
    // 版本里还用着的图片先留在本机（撤回时要用），版本删掉后下次存盘再清
    const kept = versionMedia(versions(currentId)).images;
    const removed = [...persistedImages.keys()].filter((id) => !Object.hasOwn(sources, id) && !kept.has(id));
    for (const [id, src] of puts) changes.media.push({ draftId: currentId, kind: "image", id, data: store.dataUrlToStored(src) });
    for (const id of removed) changes.deleteMedia.push([currentId, "image", id]);
    const signature = JSON.stringify(fields);
    const changed = signature !== baseline || puts.length > 0 || removed.length > 0;
    const draftId = currentId;
    if (changed) {
      const previous = records.get(draftId);
      const record = { ...fields, id: draftId, createdAt: previous?.createdAt ?? Date.now(), updatedAt: Date.now() };
      // 界面不认识的旧字段、AI 会话记录、版本原样带着走
      if (previous?.legacy) record.legacy = previous.legacy;
      if (previous?.ai) record.ai = previous.ai;
      if (previous?.versions) record.versions = previous.versions;
      records.set(draftId, record);
      changes.drafts.push(record);
      baseline = signature;
      for (const [id, src] of puts) persistedImages.set(id, src);
      for (const id of removed) persistedImages.delete(id);
    }
    const changeSignature = `${draftId}\n${signature}`;
    if (changed || changeSignature !== lastChangeSignature) {
      lastChangeSignature = changeSignature;
      emit("change", { draftId });
    }
    if (!changes.drafts.length && !changes.meta.length) return settle();
    savesInFlight += 1;
    settle();
    enqueue(changes, () => {
      savedProfile = "";
      if (currentId !== draftId) return;
      baseline = null;
      for (const [id] of puts) persistedImages.delete(id);
    })
      .then(
        () => {
          savedAt = Date.now();
          saveFailure = null;
        },
        (error) => {
          if (currentId !== draftId) return;
          saveFailure = error?.message || String(error);
          retryLater();
        },
      )
      .finally(() => {
        savesInFlight -= 1;
        settle();
      });
    if (changed) emit("list");
  }

  // ===== 切换 =====

  function serially(task) {
    const run = switching.then(task);
    switching = run.catch(() => undefined);
    return run;
  }

  // 打开一篇：自己的稿子以存储里的为准（别的窗口可能刚存过，广播也可能错过），存储里没有了就是在别处删了
  async function show(id) {
    await writes; // 这个窗口排着的写入先落盘（它们不会失败出去：失败记在 writeError）
    const [stored, media] = isBuiltIn(id)
      ? [get(id), { images: {}, videos: {} }]
      : await Promise.all([store.readDraft(id).then(upgrade), store.readMedia(id)]);
    if (!stored) {
      records.delete(id);
      forgotten.add(id);
      emit("list");
      throw new Error("这篇稿子已经在另一个窗口里删掉了");
    }
    if (!isBuiltIn(id)) records.set(id, stored);
    const record = get(id);
    currentId = id;
    prefs = store.writePrefs({ currentDraftId: id });
    // 内置说明书用它自己的署名，不显示也不改你的署名
    host.apply(record, media, isBuiltIn(id) ? host.guideProfile ?? host.defaultProfile : profile);
    // 打开时界面会把旧值规范化（比如字体、行距的写法），这不算改动，不改修改时间。
    baseline = isBuiltIn(id) ? null : JSON.stringify(host.capture().fields);
    persistedImages = new Map(Object.entries(media.images));
    // 刚打开：都存好了，「已保存」的时间是这篇的修改时间（离开上一篇前已经存完）
    saveFailure = null;
    savedAt = isBuiltIn(id) ? null : record.updatedAt ?? null;
    settle();
    emit("list");
    await host.opened(record);
  }

  // 离开当前稿子前先把它存好；存不进去就不走，免得丢改动。之前有写入失败时整篇重写一遍再走。
  async function leaveCurrent() {
    if (writeError) baseline = null;
    save();
    await flush();
  }

  function assertExists(id) {
    if (!get(id)) throw new Error(`没有这篇稿子：${id}`);
  }

  // 这个窗口能不能打开这篇：同一篇只在一个窗口里开（正在看的，和 AI 还在跑的）；内置说明书只读，哪个窗口都能开
  async function claim(id, { focus = true } = {}) {
    return isBuiltIn(id) || !host.claim || (await host.claim(id, { focus }));
  }

  // 这个窗口能开的一篇：先 wanted 里的（按顺序），再最近改过的自己的稿子；都在别的窗口里开着时打开第一本说明书
  async function firstClaimable(wanted) {
    const seen = new Set();
    for (const id of [...wanted, ...own().map((record) => record.id)]) {
      if (!id || seen.has(id) || !get(id)) continue;
      seen.add(id);
      if (await claim(id, { focus: false })) return id;
    }
    return builtIns[0].id;
  }

  // 要打开的这篇在别的窗口里开着（或那里的 AI 还在跑）：壳已经把那个窗口调到前面、换到了这篇
  function elsewhere(id) {
    const error = new Error(`「${summaryOf(get(id)).title}」在另一个窗口里开着，已经切到那个窗口`);
    error.elsewhere = true;
    return error;
  }

  // focus：那篇在别的窗口里时把那个窗口调到前面（用户自己开的）；外部 Agent 开的不抢焦点
  function open(id, { focus = true } = {}) {
    return serially(async () => {
      assertExists(id);
      if (id !== currentId && !(await claim(id, { focus }))) throw elsewhere(id);
      try {
        await leaveCurrent();
        await show(id);
      } catch (error) {
        host.resync?.(); // 没开成：把这个窗口真正占着的告诉壳，替它占着的那篇放回去
        throw error;
      }
      return get(id);
    });
  }

  function newId() {
    const random = Array.from(crypto.getRandomValues(new Uint8Array(4)), (byte) => byte.toString(36).padStart(2, "0")).join("");
    return `draft_${Date.now().toString(36)}_${random}`;
  }

  // 新的一篇空稿子（沿用上次选的主题），存进本机，返回它的 id
  async function addBlank() {
    const now = Date.now();
    const record = { ...host.blank(), id: newId(), createdAt: now, updatedAt: now };
    records.set(record.id, record);
    try {
      await enqueue({ drafts: [record] });
    } catch (error) {
      records.delete(record.id);
      emit("list");
      throw new Error(`新稿子没能存进本机：${error.message || error}`);
    }
    return record.id;
  }

  // 新建一篇并打开它；到上限时报错，不删旧稿。
  function create() {
    return serially(async () => {
      if (records.size >= LIMIT) throw new RangeError(`稿子已经存满 ${LIMIT} 篇，请先删掉不需要的稿子`);
      await leaveCurrent();
      const id = await addBlank();
      await show(id);
      return get(id);
    });
  }

  // 删除一篇（连同它的图片、实况视频与 AI 的工作副本、配图候选）。删的是正在编辑的这篇时，打开最近改过的另一篇，没有就打开说明书。
  // 后端自己的会话记录（~/.claude/projects/、~/.codex/sessions/）不归 App 管，不删。工作副本没删掉时稿子照样删了，reject 说明原因。
  function remove(id) {
    return serially(async () => {
      if (isBuiltIn(id)) throw new Error("内置说明书不可删除");
      const record = records.get(id);
      if (!record) throw new Error(`没有这篇稿子：${id}`);
      const wasCurrent = id === currentId;
      records.delete(id);
      // 先停止存这篇，免得删除途中出图又把它写回去
      if (wasCurrent) currentId = null;
      try {
        await enqueue({ deleteDrafts: [id] });
      } catch (error) {
        records.set(id, record);
        if (wasCurrent) currentId = id;
        emit("list");
        throw new Error(`没能删除：${error.message || error}`);
      }
      const aiError = await nativeAI?.remove(id).then(() => null, (error) => error);
      if (wasCurrent) await show(await firstClaimable([]));
      else emit("list");
      if (aiError) throw new Error(`稿子已删除，但 AI 的工作副本没能删掉：${aiError.message || aiError}`);
    });
  }

  // ===== AI 会话记录（src/ai/）：随稿子一起存，不算内容改动（不改修改时间），内置说明书没有 =====

  function aiSession(id) {
    return records.get(id)?.ai ?? null;
  }

  function setAiSession(id, ai) {
    const record = records.get(id);
    if (!record) return Promise.reject(new Error(`没有这篇稿子：${id}`));
    const next = { ...record, ai };
    records.set(id, next);
    return enqueue({ drafts: [next] });
  }

  // ===== 版本（src/ai/versions.js）：当前稿子某一刻的样子，每轮 AI 之前存一个，可以撤回；随稿子存，不算内容改动 =====

  function versions(id) {
    return records.get(id)?.versions ?? [];
  }

  // 这些版本还用着的图片 id 与实况视频 key
  function versionMedia(list) {
    const images = new Set();
    const videos = new Set();
    for (const version of list) {
      for (const [id, image] of Object.entries(version.draft.images || {})) {
        images.add(id);
        if (image.kind === "live") videos.add(String(image.videoKey || id));
      }
    }
    return { images, videos };
  }

  // 给正在编辑的这篇存一个版本 { id, label }：先把界面上的样子存进本机（新图片的画面也进了媒体库），再记下各字段
  // （图片只记信息与 id，画面留在媒体库里，版本还用着就不删）。超过上限删最旧的，只有它们用着的实况视频跟着删。
  async function addVersion(id, { id: versionId, label }) {
    if (id !== currentId || isBuiltIn(id)) throw new Error("只能给正在编辑的稿子存版本");
    save();
    await flush();
    const { fields } = host.capture();
    const draft = Object.fromEntries(VERSION_FIELDS.map((field) => [field, structuredClone(fields[field])]));
    const list = [...versions(id), { id: versionId, at: Date.now(), label, draft }];
    const kept = list.slice(-VERSION_LIMIT);
    const inUse = versionMedia([...kept, { draft: { images: fields.images } }]).videos;
    const dropped = [...versionMedia(list.slice(0, -VERSION_LIMIT)).videos].filter((key) => !inUse.has(key));
    const record = { ...records.get(id), versions: kept };
    records.set(id, record);
    await enqueue({ drafts: [record], deleteMedia: dropped.map((key) => [id, "video", key]) });
  }

  // ===== 当前稿子的实况视频 =====

  function putVideo(key, blob) {
    return enqueue({ media: [{ draftId: currentId, kind: "video", id: String(key), data: blob }] });
  }

  // 版本里还用着的视频先留着（撤回时要用），等那些版本删掉时再删
  function deleteVideo(key) {
    if (versionMedia(versions(currentId)).videos.has(String(key))) return Promise.resolve();
    return enqueue({ deleteMedia: [[currentId, "video", String(key)]] });
  }

  async function readVideo(key) {
    await writes;
    return store.readVideo(currentId, String(key));
  }

  // ===== 启动 =====

  // ===== 别的窗口存下的（store.onExternalChange）=====
  // 这个窗口正开着的这篇不会被别的窗口改（同一篇只在一个窗口里），只可能被删：那时不再存它，换到另一篇。
  // 删掉的稿子这个窗口写过（它开着过）：排着的写入里它的那部分丢掉，再删一次，免得删之前已经在写的又把它写回来。

  async function external({ drafts: changed = [], deleted = [], meta = [] }) {
    const gone = new Set(deleted);
    // 正开着的这篇在别处删了：马上不再存它（界面上的改动都不再写），等排着的事做完再换到另一篇
    const removed = currentId && gone.has(currentId) && records.has(currentId) ? summaryOf(records.get(currentId)).title : null;
    if (removed !== null) {
      currentId = null;
      clearTimeout(saveTimer);
      saveTimer = 0;
      settle();
    }
    for (const id of changed) {
      if (id === currentId || gone.has(id)) continue;
      const record = await store.readDraft(id).then(upgrade, () => undefined);
      if (record === undefined) continue; // 读不出来：留着这边的，下次再说
      if (record) records.set(id, record);
      else gone.add(id);
    }
    const rewrite = [...gone].filter((id) => records.has(id) && written.has(id));
    for (const id of gone) {
      records.delete(id);
      forgotten.add(id);
    }
    if (rewrite.length) void enqueue({ deleteDrafts: rewrite }).catch(() => undefined);
    if (meta.includes("profile")) await reloadProfile();
    if (removed !== null) {
      await serially(async () => {
        if (currentId) return; // 这期间已经打开了别的
        await show(await firstClaimable([]));
      });
      emit("removed-elsewhere", { title: removed });
    } else emit("list");
  }

  async function reloadProfile() {
    const stored = await store.readMeta("profile").catch(() => null);
    if (!stored) return;
    profile = { name: stored.name, handle: stored.handle, avatar: stored.avatar, avatarCrop: stored.avatarCrop ?? null };
    savedProfile = JSON.stringify(profile);
    if (currentId && !isBuiltIn(currentId)) await host.showProfile?.(profile);
  }

  // 打开存储、载入全部稿子并打开上次那篇（新环境打开第一篇说明书）。initialId 那篇已经不在了时返回 { draftMissing: true }。
  // initialId：先打开这篇（新窗口里「在新窗口打开」的那篇、恢复的窗口开着的那篇）；fresh：新建一篇打开（「新建窗口」）。
  // 要开的那篇在别的窗口里开着时，开上次那篇或最近改过的另一篇。
  async function start(hostAdapter, { initialId, fresh = false } = {}) {
    host = hostAdapter;
    builtIns = host.builtIns;
    await store.open();
    store.onExternalChange((change) => void external(change));
    const upgraded = [];
    for (const stored of await store.readAll("drafts")) {
      const record = upgrade(stored);
      records.set(record.id, record);
      if (record !== stored) upgraded.push(record);
    }
    // 定稿之前的主题一次写回成新主题（不改修改时间）；写不进也不要紧，读的时候照样换
    if (upgraded.length) void enqueue({ drafts: upgraded }).catch(() => undefined);
    const stored = await store.readMeta("profile");
    profile = stored
      ? { name: stored.name, handle: stored.handle, avatar: stored.avatar, avatarCrop: stored.avatarCrop ?? null }
      : { ...host.defaultProfile };
    savedProfile = stored ? JSON.stringify(profile) : "";
    prefs = store.readPrefs();
    if (fresh && records.size < LIMIT) {
      freshId = await addBlank();
      await show(freshId);
      return {};
    }
    await show(await firstClaimable([initialId, prefs.currentDraftId]));
    return initialId && !get(initialId) ? { draftMissing: true } : {};
  }

  function on(type, listener) {
    listeners[type].add(listener);
    return () => listeners[type].delete(listener);
  }

  Object.assign(drafts, {
    limit: LIMIT,
    start,
    on,
    list,
    search,
    get,
    count: () => records.size,
    // 这个窗口正开着的这篇（新建、打开途中为 null）
    currentId: () => currentId,
    // 这个窗口是「新建窗口」开的、还开着启动时新建的那篇空稿子时是它的 id，否则为 null
    freshId: () => (freshId && freshId === currentId ? freshId : null),
    isBuiltIn,
    create,
    open,
    remove,
    save,
    saveSoon,
    saveNow,
    // { status: "saved" | "pending" | "saving" | "error" | "none", savedAt, error, draftId }
    saveState: () => ({ ...saveState, draftId: currentId }),
    flush,
    aiSession,
    setAiSession,
    versions,
    addVersion,
    putVideo,
    deleteVideo,
    readVideo,
    // 别的窗口可能刚改过：每次从本机读
    lastTheme: () => {
      const id = store.readPrefs().lastTheme;
      return id ? root.MediaCraftThemes?.normalize(id) ?? id : null;
    },
    setLastTheme: (id) => {
      prefs = store.writePrefs({ lastTheme: id });
    },
  });
})(window);
