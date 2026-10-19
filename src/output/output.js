// MediaCraft 导出与发送：单张 PNG、整组 ZIP、长文长图存进「下载」（文件名以标题开头；给了 save 时交给它，外部 Agent 用它写进指定的目录），
// 整组按页序隔空投送到 iPhone（小红书正文进剪贴板，发完的提示卡上可以再分别复制标题、正文、话题），长文带格式复制进公众号编辑器。
// 图文卡片的正文是正文栏里单独写的那段（稿子的 caption），不是卡片上的字；长文没有正文栏，正文就是全文的纯文本。
// 稿子本身（标题、正文、模式、纯文本）经 App API 读；页面内部的东西由 create(host) 的 host 给：
//   host.cards()             → 预览里画到最新的卡片画布（这一页的排版结果用 MediaCraftRender.pageOf(canvas) 取，见 src/stage/render.js）
//   host.liveSource(imageId) → { video: Blob, videoName, start, span, speed, cover, sound, crop } | null（见 src/media/live-photos.js）
//   host.setMode(mode)       切换排版模式
//   host.articleImage()      → 长文长图的画布
//   host.articleRichText()   → { html, text }：公众号格式的 HTML 与纯文本
//   host.plainText()         → 卡片内容去掉图片与格式后的纯文本（页脚「复制卡片文字」，长文里是「复制全文」）
//   host.notify(message)     状态栏提示
//   host.beforeSend()        → 点「发送到 iPhone」后要不要发（发布检查，src/publish/assistant.js；只管界面上的按钮，App API 直接发）
//   host.topics()            → 发完可以复制的话题名（不带 #）
//   host.fontNotice()        → 用到只限个人使用的字体时，进度卡片上的提醒 { text, action }；不用提醒时为 null
(function (root) {
  "use strict";

  const CARD_WIDTH = 864;

  const pad = (number) => String(number).padStart(2, "0");

  // 标题做文件名：/ \ : * ? " < > | 与控制字符换成「-」，首尾的「-」「.」与空白去掉。
  function fileStem(title) {
    const stem = String(title || "")
      .replace(/[\\/:*?"<>|\u0000-\u001f]+/g, "-")
      .replace(/-{2,}/g, "-")
      .slice(0, 80)
      .replace(/^[\s.-]+|[\s.-]+$/g, "");
    return stem || "Vibepost";
  }

  function encodePng(picture) {
    return new Promise((resolve, reject) => {
      picture.toBlob((blob) => (blob ? resolve(blob) : reject(new Error("图片编码失败"))), "image/png");
    });
  }

  // PNG 与实况本来就压缩过，打包时不再压缩。
  function zipBlob(files) {
    const zip = new root.JSZip();
    for (const file of files) zip.file(file.name, file.blob);
    return zip.generateAsync({ type: "blob", compression: "STORE" });
  }

  // App 里存进「下载」（同名自动加序号），返回实际存下的文件名；浏览器里走普通下载。
  async function save(blob, filename) {
    if (root.MediaCraftNative) return (await root.MediaCraftNative.saveFile(blob, filename)).name;
    const link = document.createElement("a");
    link.href = URL.createObjectURL(blob);
    link.download = filename;
    link.click();
    setTimeout(() => URL.revokeObjectURL(link.href), 10_000);
    return filename;
  }

  async function copyHtml(html, text) {
    if (root.MediaCraftNative) {
      await root.MediaCraftNative.copyRichText(html, text);
      return;
    }
    await navigator.clipboard.write([new ClipboardItem({
      "text/html": new Blob([html], { type: "text/html" }),
      "text/plain": new Blob([text], { type: "text/plain" }),
    })]);
  }

  const saved = ({ filename }) => ({ title: root.MediaCraftNative?.capabilities?.saveDialog ? "已保存" : "已存进「下载」", detail: filename });
  const exported = ({ filename }) => ({ title: "已导出", detail: filename });
  // 导出的选项 { save }：save(blob, filename) → 实际存下的文件名，代替存进「下载」
  const saverOf = (options = {}) => (options.save ? { store: options.save, done: exported } : { store: save, done: saved });

  // 一页卡片 → { canvas, live }：live 是这页上那段实况在卡片上的框（逻辑坐标 864 × 1152；一页最多一段），没有为 null
  function cardOf(canvas) {
    const hit = root.MediaCraftRender.pageOf(canvas).imageHits.find((item) => item.live);
    const { imageId, x, y, width, height, radius } = hit ?? {};
    return { canvas, live: hit ? { imageId, x, y, width, height, radius } : null };
  }

  function create(host) {
    const api = () => root.mediacraft;
    let running = null;

    // 一次只做一件：做的时候所有导出按钮都停用。
    function setRunning(task) {
      running = task;
      for (const button of document.querySelectorAll("[data-output], [data-page-export], [data-motion-export]")) button.disabled = Boolean(task);
    }

    // 出图的导出与发送（fonts 为 true）顺带看看用没用到只限个人使用的字体，有就在进度卡片上提醒；不耽误导出本身
    function noticeFonts(task) {
      host.fontNotice()
        .then((notice) => notice && task.note(notice))
        .catch((error) => host.notify(`没能检查字体许可：${error.message || error}`));
    }

    async function job(heading, work, { cancellable = false, fonts = false, done }) {
      if (running) throw new Error("上一个导出还没完成，请稍候");
      const task = root.MediaCraftProgress.begin(heading, { cancellable });
      setRunning(task);
      if (fonts) noticeFonts(task);
      try {
        const result = await work(task);
        task.signal.throwIfAborted();
        task.succeed(done(result));
        return result;
      } catch (error) {
        task.fail(error);
        throw error;
      } finally {
        setRunning(null);
      }
    }

    // 文件名以标题开头；没填标题时用稿件列表里的名字（正文第一行）。
    async function stem() {
      const draft = await api().drafts.current();
      const listed = draft.title ? "" : (await api().drafts.list()).find((item) => item.current)?.title;
      return fileStem(draft.title || listed);
    }

    // 实况页：卡片画面与视频交给原生壳合成（ADR 0004），得到 .pvt 目录包里的三个文件：
    // <name>.pvt/<name>.MOV、<name>.JPG、metadata.plist。浏览器里没有壳，明说要到 App 里做。
    async function livePackage(card, name, task, onProgress) {
      const native = root.MediaCraftNative;
      if (native?.capabilities?.motionExport?.includes("mp4")) {
        return [
          await motionFile(card, name, "mp4", task, onProgress),
          { name: `${name}.png`, blob: await encodePng(card.canvas) },
        ];
      }
      if (!native?.livePhoto) throw new Error("实况要在 Vibepost App 里导出：浏览器里合成不了实况，普通卡片可以照常导出");
      const { video, ...clip } = await host.liveSource(card.live.imageId) ?? {};
      if (!video) throw new Error("实况视频找不到了，请重新插入这段视频");
      const { x, y, width, height, radius } = card.live;
      const { photo, movie, metadata } = await native.livePhoto({
        card: await encodePng(card.canvas),
        video,
        ...clip,
        cardWidth: CARD_WIDTH,
        cardHeight: card.canvas.height / 2,
        well: { x, y, width, height, radius },
      }, { signal: task.signal, onProgress });
      return [
        { name: `${name}.pvt/${name}.MOV`, blob: movie },
        { name: `${name}.pvt/${name}.JPG`, blob: photo },
        { name: `${name}.pvt/metadata.plist`, blob: metadata },
      ];
    }

    async function motionFile(card, name, format, task, onProgress) {
      const native = root.MediaCraftNative;
      if (!native?.motionVideo || !native.capabilities?.motionExport?.includes(format)) throw new Error(`当前平台不支持 ${format.toUpperCase()} 动态导出`);
      if (!card.live) throw new Error("这张卡片没有动态视频，请选择含视频的卡片");
      const { video, ...clip } = await host.liveSource(card.live.imageId) ?? {};
      if (!video) throw new Error("动态视频找不到了，请重新插入这段视频");
      const blob = await native.motionVideo({
        card: await encodePng(card.canvas), video, ...clip, format,
        cardWidth: CARD_WIDTH, cardHeight: card.canvas.height / 2, well: card.live,
      }, { signal: task.signal, onProgress });
      return { name: `${name}.${format}`, blob: blob?.blob ?? blob };
    }

    // 一页的文件：普通页一张 PNG，实况页一个 .pvt 目录包。
    async function pageFiles(card, name, task, onProgress) {
      if (card.live) return livePackage(card, name, task, onProgress);
      return [{ name: `${name}.png`, blob: await encodePng(card.canvas) }];
    }

    // 整组逐页准备，进度按页推进（实况页合成时页内也有进度）。name(index) 给出每页的文件名。
    async function allPageFiles(task, name) {
      const cards = (await host.cards()).map(cardOf);
      const files = [];
      for (const [index, card] of cards.entries()) {
        task.signal.throwIfAborted();
        const dynamic = root.MediaCraftNative?.capabilities?.motionExport?.includes("mp4");
        const step = (done = 0) => task.step(`第 ${index + 1} 张 / 共 ${cards.length} 张${card.live ? dynamic ? " · 合成动态卡片" : " · 合成实况" : ""}`, (index + done) / cards.length);
        step();
        files.push(...await pageFiles(card, name(index), task, step));
      }
      return { cards, files };
    }

    function exportPng(index, options) {
      const { store, done } = saverOf(options);
      return job("导出单张", async (task) => {
        const canvas = (await host.cards())[index];
        if (!canvas) throw new RangeError(`没有第 ${Number(index) + 1} 张`);
        const card = cardOf(canvas);
        const name = `${await stem()}-${pad(index + 1)}`;
        if (!card.live) return { filename: await store(await encodePng(card.canvas), `${name}.png`) };
        const label = root.MediaCraftNative?.capabilities?.motionExport?.includes("mp4") ? "正在合成动态卡片…" : "正在合成实况…";
        const files = await pageFiles(card, name, task, (progress) => task.step(label, progress));
        task.signal.throwIfAborted();
        return { filename: await store(await zipBlob(files), `${name}.zip`) };
      }, { cancellable: true, fonts: true, done });
    }

    function exportZip(options) {
      const { store, done } = saverOf(options);
      return job("导出全部卡片", async (task) => {
        const base = await stem();
        const { files } = await allPageFiles(task, (index) => `${base}-${pad(index + 1)}`);
        task.step("正在打包…", 1);
        const blob = await zipBlob(files);
        task.signal.throwIfAborted();
        return { filename: await store(blob, `${base}.zip`) };
      }, { cancellable: true, fonts: true, done });
    }

    function exportMotion(format, index, options) {
      if (!["mp4", "gif"].includes(format)) return Promise.reject(new Error("动态导出格式必须为 mp4 或 gif"));
      const { store, done } = saverOf(options);
      return job(`导出 ${format.toUpperCase()}`, async (task) => {
        const cards = (await host.cards()).map(cardOf);
        const base = await stem();
        if (index !== undefined && index !== null) {
          if (!Number.isInteger(index) || !cards[index]) throw new RangeError(`没有第 ${Number(index) + 1} 张`);
          const file = await motionFile(cards[index], `${base}-${pad(index + 1)}`, format, task, (progress) => task.step("正在合成动态卡片…", progress));
          task.signal.throwIfAborted();
          return { filename: await store(file.blob, file.name), format, pageCount: 1 };
        }
        const selected = cards.map((card, at) => ({ card, at })).filter(({ card }) => card.live);
        if (!selected.length) throw new Error("这篇稿子没有动态视频，请先插入一段视频");
        const files = [];
        for (const [at, entry] of selected.entries()) {
          task.signal.throwIfAborted();
          files.push(await motionFile(entry.card, `${base}-${pad(entry.at + 1)}`, format, task, (progress) => task.step(`第 ${entry.at + 1} 张 · 合成 ${format.toUpperCase()}`, (at + progress) / selected.length)));
        }
        task.signal.throwIfAborted();
        if (files.length === 1) return { filename: await store(files[0].blob, files[0].name), format, pageCount: 1 };
        return { filename: await store(await zipBlob(files), `${base}-${format}.zip`), format, pageCount: files.length };
      }, { cancellable: true, fonts: true, done });
    }

    function exportLongImage(options) {
      const { store, done } = saverOf(options);
      return job("导出长图", async (task) => {
        if ((await api().drafts.current()).mode !== "article") await host.setMode("article");
        task.step("正在生成长图…");
        const canvas = await host.articleImage();
        task.signal.throwIfAborted();
        return { filename: await store(await encodePng(canvas), `${await stem()}.png`) };
      }, { cancellable: true, fonts: true, done });
    }

    // 普通页 NN.png、实况页 NN.pvt，按文件名排序就是页序；拍摄时间由壳按页序写入。
    // 剪贴板放小红书正文（图文卡片是正文栏，长文是全文的纯文本）；正文为空时不动剪贴板。
    async function sendToIPhone() {
      if (root.MediaCraftNative?.capabilities?.phoneTransfer) return sendToPhone();
      if (!root.MediaCraftNative) throw new Error("只有在 Vibepost App 里才能发送到 iPhone");
      const { pageCount, copied } = await job("发送到 iPhone", async (task) => {
        const { mode } = await api().drafts.current();
        let files;
        let pages;
        if (mode === "article") {
          task.step("正在生成长图…");
          files = [{ name: "01.png", blob: await encodePng(await host.articleImage()) }];
          pages = 1;
        } else {
          const prepared = await allPageFiles(task, (index) => pad(index + 1));
          files = prepared.files;
          pages = prepared.cards.length;
        }
        task.signal.throwIfAborted();
        task.step("正在交给隔空投送…", 1);
        const { title, caption } = await api().drafts.current();
        const text = mode === "article" ? await api().render.plainText() : caption;
        const copied = Boolean(text.trim());
        await root.MediaCraftNative.sendToIPhone(files, copied ? text : "");
        // 话题取不出来不耽误发送：只是「复制话题」用不了
        const topics = await host.topics().catch((error) => {
          host.notify(`没能取出话题：${error.message || error}`);
          return [];
        });
        return { pageCount: pages, copied, text, title, topics, mode };
      }, {
        cancellable: true,
        fonts: true,
        done: (sent) => ({
          title: "已交给隔空投送",
          detail: sentDetail(sent),
          actions: copyActions(sent),
        }),
      });
      return { pageCount, copied };
    }

    async function sendToPhone() {
      const native = root.MediaCraftNative;
      if (!native?.capabilities?.phoneTransfer || !native.sendToPhone) throw new Error("当前平台不支持局域网手机传输");
      const result = await job("发送到手机", async (task) => {
        const { mode, title, caption } = await api().drafts.current();
        let files;
        let pageCount;
        if (mode === "article") {
          task.step("正在生成长图…");
          files = [{ name: "01.png", blob: await encodePng(await host.articleImage()) }];
          pageCount = 1;
        } else {
          const prepared = await allPageFiles(task, (index) => pad(index + 1));
          files = prepared.files;
          pageCount = prepared.cards.length;
        }
        const text = mode === "article" ? await api().render.plainText() : caption;
        const topics = await host.topics().catch(() => []);
        task.signal.throwIfAborted();
        task.step("正在生成手机下载链接…", 1);
        const session = await native.sendToPhone(files, text || "", { title, topics });
        if (task.signal.aborted) {
          await native.stopPhoneTransfer?.(session.session);
          task.signal.throwIfAborted();
        }
        return { ...session, pageCount, copied: false };
      }, {
        cancellable: true, fonts: true,
        done: () => ({ title: "手机传输链接已就绪", detail: "手机扫码下载并复制文字，关闭传输窗口后链接失效" }),
      });
      root.MediaCraftPhoneTransfer?.open(result, { stop: () => native.stopPhoneTransfer?.(result.session) });
      return result;
    }

    function sentDetail({ copied, mode }) {
      if (copied) return "正文已复制，在 iPhone 上直接粘贴";
      return mode === "article" ? "" : "正文栏还空着，剪贴板没动";
    }

    // 发完以后分别复制：经 Mac 与 iPhone 的通用剪贴板，在小红书里依次粘进标题栏、正文、话题
    function copyActions({ title, text, topics }) {
      const copy = (value, done) => async () => {
        await root.MediaCraftNative.copyText(value);
        return done;
      };
      const tags = topics.map((name) => `#${name}`).join(" ");
      return [
        { label: "复制标题", disabled: !title, title: title ? "" : "这篇没填标题", run: copy(title, "已复制标题，粘贴到小红书的标题栏") },
        { label: "复制正文", disabled: !text.trim(), title: text.trim() ? "" : "正文还没写", run: copy(text, "已复制正文") },
        {
          label: "复制话题",
          disabled: !topics.length,
          title: topics.length ? tags : "正文里没有 #话题，AI 助手也还没建议",
          run: copy(tags, `已复制 ${topics.length} 个话题：${tags}`),
        },
      ];
    }

    async function copyArticle() {
      const { html } = await job("复制公众号格式", async () => {
        const payload = await host.articleRichText();
        await copyHtml(payload.html, payload.text);
        return payload;
      }, { done: () => ({ title: "已复制公众号格式", detail: "到公众号编辑器里直接粘贴" }) });
      return { html };
    }

    // 页脚「复制卡片文字」（长文里是「复制全文」）：卡片内容去掉图片与格式后的纯文本（src/engine/plain-text.js），结果写在状态栏
    async function copyPlainText() {
      const text = host.plainText();
      const what = (await api().drafts.current()).mode === "article" ? "全文" : "卡片上的文字";
      if (!text.trim()) {
        host.notify(`没有可复制的文字：${what}是空的`);
        return;
      }
      try {
        if (root.MediaCraftNative) await root.MediaCraftNative.copyText(text);
        else await navigator.clipboard.writeText(text);
        host.notify(`已复制${what}（去掉了图片与格式）`);
      } catch (error) {
        host.notify(`没能复制：${error.message || error}`);
      }
    }
    document.querySelector("#copyCardTextBtn")?.addEventListener("click", () => void copyPlainText());

    const actions = { zip: exportZip, "long-image": exportLongImage, wechat: copyArticle, send: sendToIPhone };
    // 发送前先过一遍发布检查；检查本身出错时照常发，原因写在状态栏
    const gates = {
      send: () => host.beforeSend().catch((error) => {
        host.notify(`发布检查没能完成：${error.message || error}`);
        return true;
      }),
    };
    for (const button of document.querySelectorAll("[data-output]")) {
      const kind = button.dataset.output;
      button.addEventListener("click", async () => {
        if (gates[kind] && !(await gates[kind]())) return;
        // 出错、取消都已显示在进度卡片上
        actions[kind]().catch(() => undefined);
      });
    }

    return {
      exportPng,
      exportZip,
      exportMotion,
      exportLongImage,
      sendToIPhone,
      sendToPhone,
      copyArticle,
      // 预览里每页的下载按钮
      exportPage: (index) => exportPng(index).catch(() => undefined),
      busy: () => Boolean(running),
    };
  }

  root.MediaCraftOutput = { create };
})(globalThis);
