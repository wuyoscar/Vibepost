// 审阅 AI 的修改：一轮改了 draft.md / title.txt / caption.txt 时不直接套用，先逐处标出（卡片内容在编辑器里，src/editor/review.js；
// 标题与小红书正文各一处，在编辑器上方那一条里），
// 每处接受或拒绝；每处都决定了（或点「全部接受」「全部拒绝」）时，把接受的一次套用——撤销历史里的一步，⌘Z 整个撤回。
// 待确认的修改随稿子存（ai.review），换稿子、重新打开 App 都还在；这期间正文变了就挪到现在的正文上重算（src/ai/diff.js）。
// 审阅时编辑器只读，舞台按「没拒绝的都接受」出图，不能改图片、不能导出（应用那边，见 src/ai/host.js）。
// 对外是 mediacraft.ai.review 与 mediacraft.on("ai") 的 review 事件，见 docs/app-api.md。
(function (root) {
  "use strict";

  const ai = (root.MediaCraftAI ||= {});
  const drafts = root.MediaCraftDrafts;
  const mc = () => root.mediacraft;
  const { diff } = ai;
  const $ = (selector) => document.querySelector(selector);

  // 应用给的适配（src/ai/host.js）：review(view | null) 显示 / 收起标注与预览，edit(patch) 一步可撤销地改稿子
  let host = null;
  // 正在显示的审阅（当前稿子的）；没有为 null
  let shown = null;
  // 决定、结束、跟上当前稿子依次进行，免得连点时交错
  let queue = Promise.resolve();

  function serially(task) {
    const run = queue.then(task);
    queue = run.catch(() => undefined);
    return run;
  }

  function report(error) {
    $("#statusText").textContent = error.message || String(error);
  }

  const saved = (draftId) => drafts.aiSession(draftId)?.review ?? null;

  function store(draftId, patch) {
    return drafts.setAiSession(draftId, { ...drafts.aiSession(draftId), ...patch });
  }

  // 这篇待确认的修改挪到现在的正文上：标题、小红书正文（有的话）在前，卡片内容的按位置；每处带上决定（没决定为 "pending"）
  function hunksOf(record, current) {
    const { title, caption, hunks } = diff.review(record.base, record, current);
    return [
      ...(title ? [{ ...title, kind: "title" }] : []),
      ...(caption ? [{ ...caption, kind: "caption" }] : []),
      ...hunks.map((hunk) => ({ ...hunk, kind: "text" })),
    ].map((hunk, index) => ({ ...hunk, index, decision: record.decisions[hunk.key] ?? "pending" }));
  }

  const textHunks = (hunks) => hunks.filter((hunk) => hunk.kind === "text");

  // take(hunk) 为真的换成 AI 的，得到的卡片内容、标题与小红书正文
  function result(view, take) {
    const field = (kind) => {
      const hunk = view.hunks.find((item) => item.kind === kind);
      return hunk && take(hunk) ? hunk.after : view.current[kind];
    };
    return {
      markdown: diff.apply(view.current.markdown, textHunks(view.hunks), take),
      title: field("title"),
      caption: field("caption"),
    };
  }

  // 当前稿子待确认的修改（挪到现在的正文上）；没有为 null
  async function current() {
    const draft = await mc().drafts.current();
    const record = draft.readOnly ? null : saved(draft.id);
    if (!record) return null;
    const now = { markdown: draft.markdown, title: draft.title, caption: draft.caption };
    return { draftId: draft.id, turnId: record.turnId, record, current: now, hunks: hunksOf(record, now) };
  }

  async function required() {
    const view = await current();
    if (!view) throw new Error("现在没有待确认的 AI 修改");
    return view;
  }

  // 对外的一处修改：卡片内容的 before / after 是整行（不含最后一个换行），source 是 before 在现在的卡片内容里的范围；
  // 标题与小红书正文是整段，source 为 null
  function publicHunk(hunk, length) {
    const text = hunk.kind === "text";
    const lines = (value) => (text ? value.replace(/\n$/, "") : value);
    const before = lines(hunk.before);
    const from = Math.min(hunk.from, length);
    return {
      index: hunk.index,
      kind: hunk.kind,
      before,
      after: lines(hunk.after),
      source: text ? [from, from + before.length] : null,
      conflict: hunk.conflict,
      decision: hunk.decision,
    };
  }

  function status(view) {
    if (!view) return { open: false, turnId: null, hunks: [] };
    const length = view.current.markdown.length;
    return { open: true, turnId: view.turnId, hunks: view.hunks.map((hunk) => publicHunk(hunk, length)) };
  }

  function emit(view, open) {
    ai.emit({ type: "review", draftId: view.draftId, turnId: view.turnId, open, count: view.hunks.length });
  }

  // ===== 显示 =====

  const bar = $("#aiReview");
  const barCount = $("#aiReviewCount");
  const barNote = $("#aiReviewNote");
  const titleRow = $("#aiReviewTitle");
  const titleBefore = $("#aiReviewTitleBefore");
  const titleAfter = $("#aiReviewTitleAfter");
  const titleButtons = [...titleRow.querySelectorAll("[data-review-decision]")];
  const captionRow = $("#aiReviewCaption");
  const captionChange = $("#aiReviewCaptionChange");
  const captionButtons = [...captionRow.querySelectorAll("[data-review-decision]")];

  // 标题、正文那一行的状态：第几处、决定、是不是冲突（没有这处修改时藏起来）
  function renderRow(row, buttons, hunk) {
    row.hidden = !hunk;
    if (!hunk) return;
    row.setAttribute("aria-label", `第 ${hunk.index + 1} 处修改`);
    row.dataset.decision = hunk.decision;
    row.classList.toggle("is-conflict", hunk.conflict);
    for (const button of buttons) button.setAttribute("aria-pressed", String(button.dataset.reviewDecision === hunk.decision));
  }

  // 小红书正文整段比对：删掉的字删除线、加上的字绿底
  function renderCaption(hunk) {
    if (!hunk) return;
    const pieces = diff.parts(hunk.before, hunk.after).map(({ op, text }) => {
      if (op === "equal") return text;
      const node = document.createElement(op === "delete" ? "del" : "ins");
      node.textContent = text;
      return node;
    });
    captionChange.replaceChildren(...pieces);
  }

  // 编辑器上方的一条：几处修改、全部接受 / 全部拒绝，标题与小红书正文的修改也在这里（它们不在编辑器里）
  function renderBar(view) {
    bar.hidden = !view;
    if (!view) return;
    const decided = view.hunks.filter((hunk) => hunk.decision !== "pending").length;
    barCount.textContent = `AI 改了 ${view.hunks.length} 处`;
    barNote.textContent = decided
      ? `已决定 ${decided} 处 · 舞台上是没拒绝的都接受后的样子`
      : "逐处接受或拒绝 · 舞台上是全部接受后的样子";
    const title = view.hunks.find((hunk) => hunk.kind === "title");
    const caption = view.hunks.find((hunk) => hunk.kind === "caption");
    renderRow(titleRow, titleButtons, title);
    renderRow(captionRow, captionButtons, caption);
    renderCaption(caption);
    if (!title) return;
    titleBefore.textContent = title.before || "（没有标题）";
    titleAfter.textContent = title.after || "（不要标题）";
  }

  // 显示这一套审阅（null 收起）：编辑器里逐处标出、舞台出「没拒绝的都接受」的样子、编辑器上方一条汇总
  function show(view) {
    if (!view && !shown) return;
    shown = view;
    host.review(view && {
      hunks: textHunks(view.hunks).map(({ index, from, to, before, after, conflict, decision }) => ({
        index, from, to, conflict, decision, parts: diff.parts(before, after),
      })),
      preview: result(view, (hunk) => hunk.decision !== "rejected"),
      decide: (index, decision) => void decide(at(index), decision).catch(report),
    });
    renderBar(view);
  }

  // ===== 决定与结束 =====

  // 结束审阅：先收起标注（编辑器恢复可写、舞台回到正文），再把接受的一次套用；没决定的算拒绝。
  // 会话记录里这一轮的结尾记下几处、接受了几处。
  async function close(view) {
    const hunks = view.hunks.map((hunk) => (hunk.decision === "pending" ? { ...hunk, decision: "rejected" } : hunk));
    const accepted = hunks.filter((hunk) => hunk.decision === "accepted").length;
    const final = { ...view, hunks };
    show(null);
    if (accepted) await host.edit(result(final, (hunk) => hunk.decision === "accepted"));
    const session = { ...drafts.aiSession(view.draftId) };
    delete session.review;
    const end = `${view.turnId}:end`;
    session.messages = session.messages.map((message) => (message.id === end
      ? { ...message, review: { count: hunks.length, accepted }, ...(accepted ? { edited: true } : {}) }
      : message));
    await drafts.setAiSession(view.draftId, session);
    emit(final, false);
    return { ...status(final), open: false, applied: accepted };
  }

  // 记下决定；每处都决定了就结束
  async function settle(view, decisions) {
    const record = { ...view.record, decisions: { ...view.record.decisions, ...decisions } };
    const next = { ...view, record, hunks: hunksOf(record, view.current) };
    if (next.hunks.every((hunk) => hunk.decision !== "pending")) return close(next);
    await store(view.draftId, { review: record });
    show(next);
    emit(next, true);
    return status(next);
  }

  // pick(view) 挑出要决定的那一处
  function decide(pick, decision) {
    return serially(async () => {
      const view = await required();
      const hunk = pick(view);
      if (!hunk) throw new RangeError(`没有这一处修改（一共 ${view.hunks.length} 处）`);
      return settle(view, { [hunk.key]: decision });
    });
  }

  const at = (index) => (view) => (Number.isInteger(index) ? view.hunks[index] : undefined);
  const kindHunk = (kind) => (view) => view.hunks.find((hunk) => hunk.kind === kind);

  function decideAll(decision) {
    return serially(async () => {
      const view = await required();
      return close({ ...view, hunks: view.hunks.map((hunk) => ({ ...hunk, decision })) });
    });
  }

  // 跟上当前稿子：有待确认的修改就显示（正文变了会重新挪），没有就收起；挪过来已经没有修改了（比如你改成了一样的）就直接结束。
  // 出错只报在状态栏，不往外抛。
  function sync() {
    return serially(async () => {
      const view = await current();
      if (view && !view.hunks.length) await close(view);
      else show(view);
    }).catch(report);
  }

  // ===== 给 src/ai/session.js 与 src/ai/versions.js =====

  // 一轮结束时：这一轮的修改挪到那篇现在的正文上有几处。有修改时返回 { record, count }（record 存进 ai.review），没有为 null。
  async function prepare(draftId, turnId, proposal) {
    const draft = await mc().drafts.get(draftId);
    if (!draft) return null;
    const record = { turnId, base: proposal.base, markdown: proposal.markdown, title: proposal.title, caption: proposal.caption, decisions: {} };
    const count = hunksOf(record, { markdown: draft.markdown, title: draft.title, caption: draft.caption }).length;
    return count ? { record, count } : null;
  }

  // 撤回版本前：丢掉这篇还没确认的修改（都算拒绝）
  function dismiss(draftId) {
    return serially(async () => {
      const view = await current();
      if (view?.draftId === draftId) await close(view);
    });
  }

  function start() {
    mc().on("change", ({ draftId }) => {
      if (shown || saved(draftId)) void sync();
    });
    void sync();
  }

  const run = (task) => () => void task().catch(report);
  $("#aiReviewAcceptAll").addEventListener("click", run(() => decideAll("accepted")));
  $("#aiReviewRejectAll").addEventListener("click", run(() => decideAll("rejected")));
  for (const [kind, buttons] of [["title", titleButtons], ["caption", captionButtons]]) {
    for (const button of buttons) button.addEventListener("click", run(() => decide(kindHunk(kind), button.dataset.reviewDecision)));
  }

  ai.review = {
    connect(adapter) {
      host = adapter;
    },
    start,
    sync,
    prepare,
    dismiss,
    isOpen: (draftId) => Boolean(saved(draftId)),
    // mediacraft.ai.review（App API）
    api: {
      get: () => serially(async () => {
        const view = await current();
        return status(view?.hunks.length ? view : null);
      }),
      accept: (index) => decide(at(index), "accepted"),
      reject: (index) => decide(at(index), "rejected"),
      acceptAll: () => decideAll("accepted"),
      rejectAll: () => decideAll("rejected"),
      finish: () => serially(async () => close(await required())),
    },
  };
})(window);
