// AI 改稿的修改对比：纯函数，不碰界面与存储（审阅见 src/ai/review.js）。
// 以「行」为单位比对：自定义标记（[[image:…]]、[[分页]]、{{…}}）都在一行之内，整行比对不会把它们拆开；
// 同一段（中间没有空行）里的几处改动合成一处修改，每处可以单独接受或拒绝。
// 发出后你也改了正文时，把 AI 的修改挪到现在的正文上：和你的改动不重叠的照样挪过去，
// 重叠的成为「冲突」——这一簇按 AI 的整段接受，或拒绝（留你的）。
// 位置都按「正文末尾补一个换行」算（每行都以 \n 结尾，最后一行也能整行替换），套用后再去掉。
(function (root) {
  "use strict";

  // 两边长度之积超过这个就不再细比，中间整段当作一处改动（两万字的稿子逐行比远到不了）
  const MAX_CELLS = 4_000_000;
  // 按字词比对时，夹在两处改动之间这么短的相同部分并进改动，免得一句话被切得太碎
  const TINY_EQUAL = 1;
  // 字词：整个自定义标记、{{…| 开头连同参数、}}、一串字母数字，其余每个字（码点）
  const TOKEN = /\[\[[^\]\n]*\]\]|\{\{[^|}\n]*\||\}\}|[A-Za-z0-9_]+|[\s\S]/gu;

  // 两个序列的差异：[{ aFrom, aTo, bFrom, bTo }]，按位置排好；a[aFrom, aTo) 换成 b[bFrom, bTo)。
  function changes(a, b) {
    let start = 0;
    while (start < a.length && start < b.length && a[start] === b[start]) start += 1;
    let aEnd = a.length;
    let bEnd = b.length;
    while (aEnd > start && bEnd > start && a[aEnd - 1] === b[bEnd - 1]) {
      aEnd -= 1;
      bEnd -= 1;
    }
    const n = aEnd - start;
    const m = bEnd - start;
    if (n === 0 && m === 0) return [];
    if (n === 0 || m === 0 || n * m > MAX_CELLS) return [{ aFrom: start, aTo: aEnd, bFrom: start, bTo: bEnd }];
    // common[i * width + j]：a[start + i …] 与 b[start + j …] 的最长公共子序列长度（不超过 min(n, m) ≤ 2000）
    const width = m + 1;
    const common = new Uint16Array((n + 1) * width);
    for (let i = n - 1; i >= 0; i -= 1) {
      for (let j = m - 1; j >= 0; j -= 1) {
        common[i * width + j] = a[start + i] === b[start + j]
          ? common[(i + 1) * width + j + 1] + 1
          : Math.max(common[(i + 1) * width + j], common[i * width + j + 1]);
      }
    }
    const result = [];
    let open = null;
    let i = 0;
    let j = 0;
    while (i < n || j < m) {
      if (i < n && j < m && a[start + i] === b[start + j]) {
        if (open) result.push(open);
        open = null;
        i += 1;
        j += 1;
        continue;
      }
      open ??= { aFrom: start + i, aTo: start + i, bFrom: start + j, bTo: start + j };
      // 先删后加：同一处的删除排在新增前面
      if (j >= m || (i < n && common[(i + 1) * width + j] >= common[i * width + j + 1])) {
        i += 1;
        open.aTo = start + i;
      } else {
        j += 1;
        open.bTo = start + j;
      }
    }
    if (open) result.push(open);
    return result;
  }

  function linesOf(text) {
    return text.split("\n").map((line) => `${line}\n`);
  }

  const isBlank = (line) => !line.trim();

  // AI 的改动按段合成一处处修改：两处改动之间的相同行里没有空行（同一段），就合成一处。
  function aiHunks(baseLines, proposalLines) {
    const hunks = [];
    for (const change of changes(baseLines, proposalLines)) {
      const last = hunks.at(-1);
      if (last && !baseLines.slice(last.aTo, change.aFrom).some(isBlank)) {
        last.aTo = change.aTo;
        last.bTo = change.bTo;
      } else {
        hunks.push({ ...change });
      }
    }
    return hunks;
  }

  // 两段（发出时正文里的行范围）算不算碰在一起：有重叠，或都是在同一处插入
  function overlaps(a, b) {
    return (a.aFrom < b.aTo && b.aFrom < a.aTo) || (a.aFrom === a.aTo && b.aFrom === b.aTo && a.aFrom === b.aFrom);
  }

  // AI 的修改与你的改动按位置聚成一簇簇（有重叠的连在一起）
  function clustersOf(ai, mine) {
    const items = [
      ...ai.map((change, index) => ({ ...change, index })),
      ...mine.map((change) => ({ ...change, index: null })),
    ].sort((x, y) => x.aFrom - y.aFrom || x.aTo - y.aTo);
    const clusters = [];
    for (const item of items) {
      const last = clusters.at(-1);
      if (last && overlaps(last, item)) {
        last.aTo = Math.max(last.aTo, item.aTo);
        last.members.push(item);
      } else {
        clusters.push({ aFrom: item.aFrom, aTo: item.aTo, members: [item] });
      }
    }
    return clusters;
  }

  const delta = (change) => change.bTo - change.bFrom - (change.aTo - change.aFrom);

  function offsets(lines) {
    const starts = [0];
    for (const line of lines) starts.push(starts.at(-1) + line.length);
    return starts;
  }

  // 这一轮的修改挪到现在的正文上。base：发出时 { markdown, title, caption }；proposal：AI 改成的 { markdown, title, caption }；
  // current：现在的 { markdown, title, caption }。返回 { title, caption, hunks }：
  //   title  标题的修改 { key: "title", conflict, before, after }，没有为 null
  //   caption 小红书正文（正文栏）的修改，整段一处 { key: "caption", conflict, before, after }，没有为 null
  //          （这版之前存的待确认修改没有 caption：两边都是 undefined，算没改）
  //   hunks  正文的一处处修改 [{ key, conflict, from, to, before, after }]，按位置排好：
  //          现在的正文（末尾补一个换行）里 [from, to) 是 before（整行），接受就换成 after（整行）。
  //          key 是 AI 那边第几处修改（冲突时几处连在一起，如 "2+3"），发出时与 AI 的稿子不变它就不变。
  function review(base, proposal, current) {
    const baseLines = linesOf(base.markdown);
    const proposalLines = linesOf(proposal.markdown);
    const currentLines = linesOf(current.markdown);
    const currentStarts = offsets(currentLines);
    const hunks = [];
    let aiShift = 0;
    let myShift = 0;
    for (const cluster of clustersOf(aiHunks(baseLines, proposalLines), changes(baseLines, currentLines))) {
      const ai = cluster.members.filter((member) => member.index !== null);
      const mine = cluster.members.filter((member) => member.index === null);
      const aiDelta = ai.reduce((sum, change) => sum + delta(change), 0);
      const myDelta = mine.reduce((sum, change) => sum + delta(change), 0);
      const cFrom = cluster.aFrom + myShift;
      const cTo = cluster.aTo + myShift + myDelta;
      const pFrom = cluster.aFrom + aiShift;
      const pTo = cluster.aTo + aiShift + aiDelta;
      aiShift += aiDelta;
      myShift += myDelta;
      if (!ai.length) continue;
      const before = currentLines.slice(cFrom, cTo).join("");
      const after = proposalLines.slice(pFrom, pTo).join("");
      if (before === after) continue;
      hunks.push({
        key: ai.map((change) => change.index).join("+"),
        conflict: mine.length > 0,
        from: currentStarts[cFrom],
        to: currentStarts[cTo],
        before,
        after,
      });
    }
    return { title: fieldChange("title", base, proposal, current), caption: fieldChange("caption", base, proposal, current), hunks };
  }

  // 标题、正文栏这种整段一处的字段：AI 没改、或现在已经是 AI 改成的样子时没有修改；发出后你也改过时算冲突
  function fieldChange(key, base, proposal, current) {
    if (proposal[key] === base[key] || proposal[key] === current[key]) return null;
    return { key, conflict: current[key] !== base[key], before: current[key], after: proposal[key] };
  }

  // 按 take(hunk) 的结果套用 review() 给的正文修改：接受的换成 after，其余留 before。
  function apply(markdown, hunks, take) {
    const text = `${markdown}\n`;
    let result = "";
    let pos = 0;
    for (const hunk of hunks) {
      result += text.slice(pos, hunk.from) + (take(hunk) ? hunk.after : hunk.before);
      pos = hunk.to;
    }
    return (result + text.slice(pos)).slice(0, -1);
  }

  // 一处修改前后逐字词比对，给编辑器标出删掉与加上的字：[{ op: "equal" | "delete" | "insert", text }]。
  // 自定义标记整个算一个字词，不会只标出半个标记。
  function parts(before, after) {
    const a = before.match(TOKEN) ?? [];
    const b = after.match(TOKEN) ?? [];
    // 先分成「相同」与「改动」两种段，再把夹在改动之间的零碎相同部分并进改动
    const runs = [];
    let at = 0;
    for (const change of changes(a, b)) {
      if (change.aFrom > at) runs.push({ equal: a.slice(at, change.aFrom).join("") });
      runs.push({ remove: a.slice(change.aFrom, change.aTo).join(""), add: b.slice(change.bFrom, change.bTo).join("") });
      at = change.aTo;
    }
    if (at < a.length) runs.push({ equal: a.slice(at).join("") });
    const tidy = [];
    for (let index = 0; index < runs.length; index += 1) {
      const run = runs[index];
      const previous = tidy.at(-1);
      const next = runs[index + 1];
      if (run.equal !== undefined && previous?.remove !== undefined && next?.remove !== undefined
        && Array.from(run.equal).length <= TINY_EQUAL && !run.equal.includes("\n")) {
        tidy[tidy.length - 1] = { remove: previous.remove + run.equal + next.remove, add: previous.add + run.equal + next.add };
        index += 1;
      } else {
        tidy.push(run);
      }
    }
    return tidy.flatMap((run) => (run.equal !== undefined
      ? [{ op: "equal", text: run.equal }]
      : [
        ...(run.remove ? [{ op: "delete", text: run.remove }] : []),
        ...(run.add ? [{ op: "insert", text: run.add }] : []),
      ]));
  }

  // AI 写回来的稿子：只把它改了的那几行换成 localize 之后的样子（英文记号换成中文写法），没动的行照旧——
  // 用户自己写的英文记号不会因为这一轮 AI 而变成一处「修改」。整篇先一起 localize（代码块里的照样不动），再按行取
  function localizeChanged(base, proposal, localize) {
    const before = linesOf(base);
    const after = linesOf(proposal);
    const localized = linesOf(localize(proposal));
    if (localized.length !== after.length) return proposal;
    const changed = new Set();
    for (const change of changes(before, after)) for (let line = change.bFrom; line < change.bTo; line += 1) changed.add(line);
    return after.map((line, index) => (changed.has(index) ? localized[index] : line)).join("").slice(0, -1);
  }

  (root.MediaCraftAI ||= {}).diff = { review, apply, parts, localizeChanged };
})(window);
