// MediaCraft 页面的启动：把各模块接起来（编辑器、图片与实况、稿子、出图与舞台、AI、导出），管着正在编辑的这一篇，
// 并挂上页面对外唯一的接口 window.mediacraft（实现在 src/api/，文档 docs/app-api.md）。
// 界面上的零件各在自己的文件里：查找栏 src/editor/find.js、面板宽度与菜单 src/workspace/、主题与字体 src/themes/、
// 出图流水线与舞台 src/stage/、图片记录与可撤销的删图 src/media/image-store.js、审阅 AI 修改时的预览 src/ai/host.js；
// 它们只经这里给的小接口互相调用。
"use strict";

const $ = (selector) => document.querySelector(selector);

// 默认署名：名字空着（第一次发之前在「样式 › 署名」里填，发布检查会提醒），头像先用 App 图标
// （256 像素的一份，随网页一起打包；卡片上的头像最大约 100 逻辑像素，原图 1024 像素每次出图都要解码，白费工夫）。
const DEFAULT_PROFILE = Object.freeze({ name: "", handle: "", avatar: "brand/icon-256.png", avatarCrop: null });
// 内置说明书的署名
const GUIDE_PROFILE = Object.freeze({ name: "Vibepost", handle: "", avatar: "brand/icon-256.png", avatarCrop: null });

const statusBar = $("#statusText");
const titleField = $("#titleInput");
// 小红书正文（图片下面的那段）；这里只读写它的值，展开收起、字数、自动保存在 src/drafts/caption.js
const captionField = $("#captionInput");
const modeButtons = [...document.querySelectorAll("#layoutModeSwitch [data-layout-mode]")];

function notify(message) {
  statusBar.textContent = message;
}

// ===== 正在编辑的这篇 =====
// 卡片内容在编辑器里（唯一的底层格式），标题在标题框，小红书正文在正文栏，样式在检查器的表单里；其余字段在这里。形状同稿件记录（docs/storage.md）。
// images 只整个换成新的对象、不在原来的上面改（copy-on-write）：出图、存盘拿到的就是那一刻的快照。
const draft = {
  id: null,
  mode: "cards",
  theme: MediaCraftThemes.DEFAULT,
  cover: MediaCraftCoverForm.normalize(null), // 首页做封面：{ enabled, subtitle, image }
  cardCss: "", // 这一篇自己的卡片样式（HTML 卡片，检查器「高级 › 卡片样式」）
  article: {}, // 旧版的长文样式，只为原样保留
  images: Object.freeze({}), // 图片 id → 图片记录（含画面 src）
};

// 图片有进有出时，检查器「封面」的底图选项跟着换
function setImages(next) {
  draft.images = Object.freeze(next);
  coverForm.showImages(draft.images);
}

// 色轮拖动时舞台先换成这组颜色看看（palettes.preview）：{ colors（五个角色）, tunedColors }，不改稿子、不存盘；没在预览时为 null。
let colorPreview = null;

// 新稿子的字段：空白正文，主题配色，字体跟随主题，版式默认值
function defaultDraftFields(themeId) {
  const theme = MediaCraftThemes.get(themeId);
  const follow = MediaCraftFonts.FOLLOW_THEME;
  return {
    title: "",
    caption: "",
    markdown: "",
    mode: "cards",
    theme: theme.id,
    colors: { ...theme.colors },
    tunedColors: [],
    fonts: { zh: follow, en: follow, code: follow },
    ...MediaCraftStyleForm.DEFAULTS,
    cover: MediaCraftCoverForm.normalize(null),
    cardCss: "",
    article: {},
    images: {},
  };
}

function assertEditable() {
  if (MediaCraftGuides.isGuide(draft.id)) throw new Error("内置说明书不可修改，请先新建稿子");
}

// 界面上的改动：交给稿件模块过一会儿存（不等出图：出图失败或很慢时也存得进去），停一下再出图
function edited() {
  MediaCraftDrafts.saveSoon();
  requestRender();
}

// ===== 检查器：样式与署名 =====
const styleForm = MediaCraftStyleForm.create(() => edited());
const byline = MediaCraftByline.create(DEFAULT_PROFILE, () => edited());

// ===== 检查器：封面（src/workspace/cover-form.js）。封面的标题取标题框，所以开着封面时改标题也要重新出图 =====
const coverForm = MediaCraftCoverForm.create({
  onChange(cover) {
    draft.cover = cover;
    edited();
  },
  importImage: (file) => media.importDetached(file),
});
titleField.addEventListener("input", () => {
  if (draft.cover.enabled) requestRender();
});

function setCover(value) {
  draft.cover = MediaCraftCoverForm.normalize(value);
  coverForm.write(draft.cover);
}

// ===== 检查器：卡片样式（src/workspace/card-css.js）=====
const cardCssForm = MediaCraftCardCss.create({
  onChange(value) {
    draft.cardCss = value;
    edited();
  },
});

function setCardCss(value) {
  draft.cardCss = String(value ?? "");
  cardCssForm.write(draft.cardCss);
}

// ===== 正文编辑器（src/editor/）：应用只经这个接口读写正文、选区与焦点 =====
const editor = window.MediaCraftEditor.create({
  parent: $("#markdownEditor"),
  media: (ref) => imageStore.editorInfo(ref),
  onEditImage: ({ imageIds, source }) => media.edit({ ids: imageIds, source }),
  onChange: handleEditorChange,
  onMediaEdit: (edits) => media.applyEdits(edits),
  onFieldEdit: applyFieldEdits,
  onPasteFiles: (files, at) => void media.importDropped(files, at),
  onDropFiles: (transfer, at) => void media.importDropped(Array.from(transfer.files), at),
  pickImages: () => $("#imageFileInput").click(),
  pickLivePhoto: () => $("#videoFileInput").click(),
  notify,
});
// 浮动条的字色、高亮色块跟着这篇的配色（不是色轮正在预览的）；稿子有改动（换主题、套配色、调色块、换稿子）时重画
const toolbars = MediaCraftEditor.bindToolbars(editor, {
  formatBar: $(".format-bar"),
  selectionTools: $("#selectionTools"),
  swatches: () => MediaCraftPalettes.inlineSwatches(styleForm.read().colors),
});
MediaCraftEditor.bindFind(editor, { bar: $("#findBar"), toggle: $("#findToggleBtn") }, notify);
// 发布检查在正文里的标注（由下面的发布助手更新）
const checkHints = MediaCraftEditor.bindHints(editor);
MediaCraftEditor.bindUndoKeys(editor);

// ===== 图片与 PDF（src/media/）：导入、裁剪、拼图、舞台上的图片、检查器「图片」、头像裁剪 =====
// 图片记录怎么存盘归稿子存储；图片与实况模块只经 imageStore 读写当前稿子的 draft.images（src/media/image-store.js）。
const imageStore = window.MediaCraftMedia.createImageStore({
  images: () => draft.images,
  setImages,
  livePhotos: () => livePhotos,
  refresh: () => media.refresh(),
});

const media = window.MediaCraftMedia.create({
  editor,
  store: imageStore,
  readOnly: () => MediaCraftGuides.isGuide(draft.id) || ai.preview() !== null,
  render: () => edited(),
  notify,
  editLivePhoto: (id) => void livePhotos.edit(id),
  isVideo: (file) => livePhotos.isVideo(file),
  importVideos: (files, at) => livePhotos.importVideos(files, at),
  avatar: byline.avatar,
  elements: {
    viewport: $("#stageScroller"),
    pages: $("#stageCards"),
    panel: $("#imagePanel"),
    fileInput: $("#imageFileInput"),
    avatarInput: $("#avatarInput"),
    avatarCrop: $("#cropAvatarBtn"),
  },
});

// ===== 实况（src/media/live*.js）：视频做成实况、实况编辑器、舞台上的预览播放；成片由原生壳合成（ADR 0004）=====
// 实况视频存进本机归稿件模块（src/drafts/），这里只把它的几个方法接过去。
const livePhotos = window.MediaCraftMedia.createLivePhotos({
  editor,
  store: imageStore,
  insert: (tag, at) => media.insertTags([tag], at),
  newImageId: () => media.newImageId(),
  defaultLayout: () => media.defaultLayout(),
  storage: {
    put: (key, blob) => MediaCraftDrafts.putVideo(key, blob),
    remove: (key) => MediaCraftDrafts.deleteVideo(key),
    read: (key) => MediaCraftDrafts.readVideo(key),
  },
  readOnly: () => MediaCraftGuides.isGuide(draft.id),
  notify,
  elements: { videoInput: $("#videoFileInput"), pages: $("#stageCards") },
});

// 用户在编辑器里改了正文。撤销 / 重做时，预览里删过的图片跟着这一步的正文回来或消失。
function handleEditorChange({ history }) {
  if (history) imageStore.syncDeletions(editor.getText());
  edited();
}

// ===== 稿子的字段：界面 ↔ 稿件记录 =====

// 这篇现在的样子（图片带着画面），形状同稿件记录里除 id、时间戳以外的字段
function draftFields() {
  return {
    title: titleField.value,
    caption: captionField.value,
    markdown: editor.getText(),
    mode: draft.mode,
    theme: draft.theme,
    ...styleForm.read(),
    cover: draft.cover,
    cardCss: draft.cardCss,
    article: draft.article,
    images: draft.images,
  };
}

// 出图用的设置：稿子的字段加上署名；preview 为 true 时正文换成审阅 AI 修改中的样子、配色换成色轮正在预览的
function renderSettings({ preview = true } = {}) {
  const fields = draftFields();
  const reviewing = preview ? ai.preview() : null;
  return {
    ...fields,
    title: reviewing?.title ?? fields.title,
    markdown: reviewing ? reviewing.content : fields.markdown,
    ...(preview && colorPreview ? colorPreview : {}),
    profile: byline.read(),
  };
}

// 交给稿件模块存盘：图片的 data URL 另放（sources），记录里只留图片信息；随网页打包的图片留着相对路径
function captureDraft() {
  const { images, ...fields } = draftFields();
  const stored = {};
  const sources = {};
  Object.keys(images).forEach((id) => {
    const { src, ...info } = images[id];
    if (typeof src === "string" && src.startsWith("data:")) sources[id] = src;
    else if (src) info.src = src;
    stored[id] = structuredClone(info);
  });
  return { fields: { ...fields, images: stored }, sources, profile: byline.read() };
}

// 主题只管卡片（ADR 0007）：<html data-card-theme> 立即写上，主题面板（src/theme-panel.js）跟着它标出当前主题；
// 卡片结构与「跟随主题」的字体在出图时按这篇的主题取。
function setTheme(id) {
  draft.theme = MediaCraftThemes.normalize(id);
  document.documentElement.dataset.cardTheme = draft.theme;
}

// 在主题面板里换主题：卡片结构、配色与字体一起换，这篇调过的配色重置为主题配色；
// 这个主题记为上一次选的，之后新建的稿子沿用它。点当前主题不动，免得冲掉调过的颜色。
async function chooseTheme(id) {
  if (MediaCraftThemes.normalize(id) === draft.theme) return;
  setTheme(id);
  const theme = MediaCraftThemes.get(draft.theme);
  colorPreview = null;
  styleForm.write({ colors: theme.colors, tunedColors: [] });
  MediaCraftDrafts.setLastTheme(draft.theme);
  MediaCraftDrafts.saveSoon();
  await pipeline.render();
  notify(`已切换为「${theme.name}」主题`);
}

// 排版模式：顶栏的两个按钮、舞台上显示什么、顶栏右边是哪几个导出按钮（发送到 iPhone 只在 App 里有）
function setMode(mode) {
  draft.mode = mode === "article" ? "article" : "cards";
  const article = draft.mode === "article";
  document.body.dataset.layoutMode = draft.mode;
  for (const button of modeButtons) button.setAttribute("aria-pressed", String(button.dataset.layoutMode === draft.mode));
  $("#outputZipBtn").hidden = article;
  $("#outputWechatBtn").hidden = !article;
  $("#outputLongImageBtn").hidden = !article;
  $("#sendToIPhoneBtn").hidden = !window.MediaCraftNative;
  // 页脚的复制：图文卡片复制的是卡片上的文字（小红书正文另在正文栏里），长文复制全文
  $("#copyCardTextBtn span").textContent = article ? "复制全文" : "复制卡片文字";
  $("#copyCardTextBtn").title = article ? "复制长文的全文（去掉图片与格式）" : "复制卡片上的文字（去掉图片与格式）";
}

async function switchMode(mode) {
  setMode(mode);
  MediaCraftDrafts.saveSoon();
  await renderNow();
}

// 把一篇稿子放到界面上（稿件模块打开、新建、切换时）
function showDraft(record, stored, profile) {
  draft.id = record.id;
  // 上一篇的 AI 审阅预览作废；这一篇有待确认的修改时，AI 模块在切换后重新显示
  ai.reset();
  stageNotes.reset();
  colorPreview = null;
  livePhotos.load(stored.videos);
  titleField.value = record.title || "";
  captionField.value = record.caption || "";
  editor.load(String(record.markdown ?? ""));
  setMode(record.mode);
  setTheme(record.theme);
  setCover(record.cover);
  setCardCss(record.cardCss);
  const theme = MediaCraftThemes.get(draft.theme);
  const fonts = record.fonts || {};
  // 这版之前存的稿子没有 tunedColors：打开时按值推断一次（MediaCraftPalettes.inferTuned）
  styleForm.write({
    ...MediaCraftPalettes.complete(record.colors, { colors: theme.colors }, record.tunedColors ?? MediaCraftPalettes.inferTuned(record.colors)),
    fonts: { zh: fonts.zh, en: fonts.en, code: fonts.code },
    cardHeight: record.cardHeight,
    fontSize: record.fontSize,
    lineHeight: record.lineHeight,
    imageMaxHeight: record.imageMaxHeight,
  });
  draft.article = record.article ?? {};
  setImages(Object.fromEntries(Object.entries(record.images || {}).map(([id, info]) => [
    id,
    { ...info, src: stored.images[id] ?? info.src ?? "" },
  ])));
  void byline.write(profile);
  media.refresh();
}

// 编辑器记下的字段改动（第一次套用，或撤销 / 重做到的）落到界面上
function applyFieldEdits(edits) {
  for (const { field, after } of edits) {
    if (field === "title") titleField.value = after;
    else if (field === "caption") captionField.value = after;
    else if (field === "mode") setMode(after);
    else if (field === "theme") setTheme(after);
    else if (field === "cover") setCover(after);
    else if (field === "cardCss") setCardCss(after);
    else if (field === "images") setImages({ ...after });
    else if (field !== "colors" && field !== "tunedColors") styleForm.write({ [field]: after });
  }
  applyColorEdits(edits);
  media.refresh();
  edited();
}

// 颜色与「单独调过」的标记一起落（同一步里两个字段的先后不影响结果；这一步没改标记时照旧）
function applyColorEdits(edits) {
  const colors = edits.find((edit) => edit.field === "colors")?.after;
  const tuned = edits.find((edit) => edit.field === "tunedColors")?.after;
  if (colors === undefined && tuned === undefined) return;
  const current = styleForm.read();
  styleForm.write(MediaCraftPalettes.complete(colors ?? current.colors, current, tuned ?? current.tunedColors));
}

// ===== 卡片上的批注（src/stage/annotations.js）：批注几处，一次交给 AI =====
const stageNotes = MediaCraftStageNotes.create({
  viewport: $("#stageScroller").parentElement,
  pagesRoot: $("#stageCards"),
  text: () => editor.getText(),
  readOnly: () => MediaCraftGuides.isGuide(draft.id) || ai.preview() !== null,
  openAI() {
    const tab = $("#aiTab");
    if (tab.getAttribute("aria-selected") !== "true") tab.click();
  },
  send: (prompt, label) => window.mediacraft.ai.send(prompt, { kind: "command", label }).catch((error) => notify(error.message || String(error))),
});

// ===== 舞台上 HTML 卡片的块（src/stage/blocks.js）：点选、挪动、换样式都改成原文的一步编辑 =====
const stageBlocks = MediaCraftStageBlocks.create({
  viewport: $("#stageScroller"),
  pagesRoot: $("#stageCards"),
  actions: {
    readOnly: () => MediaCraftGuides.isGuide(draft.id) || ai.preview() !== null,
    text: () => editor.getText(),
    apply(next) {
      editor.edit({ text: next });
      edited();
    },
    reveal: ([start, end]) => editor.select(start, end),
    annotate: (block) => stageNotes.add(block),
    ask([start, end]) {
      const text = editor.getText();
      document.dispatchEvent(new CustomEvent("mediacraft:rewrite", { detail: { start, end, text: text.slice(start, end) } }));
    },
  },
});

// ===== 出图：流水线（src/stage/pipeline.js）→ 舞台（src/stage/preview.js）=====
const preview = MediaCraftPreview.create({
  pages: $("#stageCards"),
  pageCount: $("#pageCount"),
  attach(frame, page, index) {
    livePhotos.attachPage(frame, page);
    media.attachPage(frame, page, index);
    stageBlocks.attach(frame, page, index);
    stageNotes.attach(frame, page, index);
  },
  exportPage: (index) => exporter.exportPage(index),
});

const pipeline = MediaCraftPipeline.create({
  settings: () => renderSettings(),
  preview,
  drawn({ mode, pageCount }) {
    MediaCraftDrafts.save();
    appApi.emit("rendered", { draftId: draft.id, mode, pageCount });
  },
  failed: (error) => notify(`没能出图：${error.message || error}`),
});
// 界面上的改动：停一下再出图；API 与切换模式马上出图
const requestRender = pipeline.request;
const renderNow = pipeline.now;

// ===== 顶栏的模式按钮（导出与页脚的「复制卡片文字」在 src/output/output.js）=====
for (const button of modeButtons) button.addEventListener("click", () => void switchMode(button.dataset.layoutMode));


// ===== 稿子：稿件模块（src/drafts/）的宿主 =====
// 稿子的存取、切换与稿件抽屉都在稿件模块里；这里告诉它怎样读写界面上的这一篇。
const draftHost = {
  builtIns: MediaCraftGuides.builtIns(),
  // 模板库里的一份（src/templates/templates.js）：get 与 firstPage 认得，createFrom 复制成稿子
  template: (id) => MediaCraftTemplates.record(id),
  defaultProfile: DEFAULT_PROFILE,
  guideProfile: GUIDE_PROFILE,
  // 新稿子：空白正文，沿用上一次选的主题与它的配色，其余是默认值
  blank: () => defaultDraftFields(MediaCraftDrafts.lastTheme()),
  capture: captureDraft,
  apply: showDraft,
  // 同一篇只在一个窗口里开（src/drafts/windows.js）
  claim: (id, options) => MediaCraftWindows.claim(id, options),
  resync: () => MediaCraftWindows.resync(),
  // 别的窗口改了署名：换到表单上，卡片重画
  async showProfile(profile) {
    await byline.write(profile);
    requestRender();
  },
  async opened() {
    // 这个窗口的地址记着它开着的这篇：重新载入（⌘R）还是这篇，不跟着别的窗口换
    history.replaceState(null, "", `?draft=${encodeURIComponent(draft.id)}`);
    const readOnly = MediaCraftGuides.isGuide(draft.id);
    editor.setReadOnly(readOnly);
    MediaCraftGuides.lockControls(readOnly);
    // 换了一篇：撤销历史从头开始，上一篇里删掉的图片再也找不回来了
    editor.clearHistory();
    imageStore.forgetDeletions(editor.getText());
    await renderNow();
  },
};

// ===== AI 的修改与版本（src/ai/host.js）：审阅时的标注与预览，一步可撤销地改稿子 =====
const ai = MediaCraftAI.createHost({
  editor,
  draftId: () => draft.id,
  images: () => draft.images,
  // 正文以外随正文一起撤销的字段（版本里存的也是这些）
  fieldValues() {
    const { markdown, article, ...fields } = draftFields();
    return { ...fields, images: { ...draft.images } };
  },
  assertEditable,
  render: pipeline,
  livePhotos,
});

// ===== 导出与发送（src/output/）：卡片画布、实况视频、长图与公众号富文本从这里取 =====

// 审阅 AI 的修改时舞台是预览，不是稿子本身：不导出，免得导出的和稿子对不上。
function unlessReviewing(task) {
  return (...args) => {
    if (ai.preview()) throw new Error("先处理完 AI 的修改（接受或拒绝），再导出");
    return task(...args);
  };
}

const exporter = window.MediaCraftOutput.create({
  cards: unlessReviewing(async () => {
    // 色轮还在预览时，导出的是稿子自己的配色
    if (colorPreview) {
      colorPreview = null;
      await renderNow();
    }
    await pipeline.settle();
    if (draft.mode === "article") throw new Error("长文模式没有卡片，请先切到图文卡片");
    return pipeline.pixels();
  }),
  liveSource: (imageId) => livePhotos.exportSource(imageId),
  setMode: unlessReviewing(switchMode),
  articleImage: unlessReviewing(() => MediaCraftRender.articleImage(renderSettings({ preview: false }))),
  articleRichText: unlessReviewing(() => MediaCraftRender.articleRichText(renderSettings({ preview: false }))),
  plainText: () => MediaCraftEngine.plainText(editor.getText()),
  notify,
  // 发布助手在 App API 挂好之后才建（见下面），这几个到点按钮时才用到它
  beforeSend: () => publishAssistant.beforeSend(),
  topics: () => publishAssistant.topics(),
  fontNotice: () => publishAssistant.fontNotice(),
});

// ===== 启动：打开稿件存储，再打开上次那篇；新环境打开说明书并弹新手引导 =====

// 稿件存储是否已经就绪（打开了第一篇）
let draftsStarted = false;

async function startDrafts() {
  MediaCraftDrafts.on("change", (detail) => {
    toolbars.refreshSwatches();
    appApi.emit("change", detail);
  });
  MediaCraftDrafts.on("save-state", (detail) => appApi.emit("save-state", detail));
  // 这个窗口打开哪篇：地址上的 ?draft=<id>（「在新窗口打开」）、?new（「新建窗口」），都没有时打开上次那篇
  const params = new URLSearchParams(location.search);
  const opened = await MediaCraftDrafts.start(draftHost, { initialId: params.get("draft"), fresh: params.has("new") });
  draftsStarted = true;
  // 这个窗口要开的那篇已经不在了（恢复的窗口）：壳在还有别的窗口时关掉它
  if (opened.draftMissing) MediaCraftWindows.missing();
  MediaCraftWindows.start({ ai: MediaCraftAI });
  MediaCraftDrafts.on("removed-elsewhere", ({ title }) => notify(`「${title}」在另一个窗口里删掉了，已换到另一篇`));
  MediaCraftOnboarding.start({ firstRun: MediaCraftDrafts.count() === 0 });
}

// ===== App API：window.mediacraft（src/api/）=====
const appApi = MediaCraftApi.create({
  draft,
  editor,
  styleForm,
  byline,
  media,
  livePhotos,
  pipeline,
  exporter,
  fields: draftFields,
  renderSettings,
  statusText: () => statusBar.textContent,
  setTitle: (title) => {
    titleField.value = title;
  },
  setCaption: (caption) => {
    captionField.value = caption;
  },
  chooseTheme,
  setMode,
  setCover,
  setCardCss,
  setColorPreview: (next) => {
    colorPreview = next;
  },
  assertEditable,
  isReady: () => draftsStarted,
  ready: () => draftsReady,
});
window.mediacraft = appApi.api;

// ===== 发布助手（src/publish/）：页脚的「检查」、发送前的检查、发完复制话题、系统字体的提醒；只经 App API 读写稿子 =====
const publishAssistant = MediaCraftPublish.createAssistant({ hints: checkHints, notify });

const draftsReady = startDrafts();
draftsReady.catch((error) => notify(`稿件没能打开：${error.message || error}`));
