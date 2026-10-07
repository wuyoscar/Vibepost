// 模板文件的格式：仓库自带的 src/templates/<名字>.md 与用户存的「模板/<名字>/模板.md」都是它——开头两行 --- 之间是
// front matter（和写作手册同一套写法：一行一个 `键: 值`，值可以加引号，`|` / `>` 后面缩进的几行是一段），后面是卡片内容
// （只用中文记号，src/engine/manual.js）。这里只管文字 ↔ 字段，不碰 DOM、不认主题：Node 里也能载入
// （scripts/build-templates.mjs 用它合成登记表 src/templates/index.js），页面里登记成稿子记录在 src/templates/templates.js。
//
// front matter 的键（都可省，写回时按这个顺序）：
//   name          模板名（列表里显示；用户模板就是文件夹名）
//   description   一句话说明
//   tags          逗号分隔：题材一个、风格一个（「清单, 简洁」）
//   id            登记表里的 id（ASCII，不写时用文件名）；用户模板不用
//   title         新稿子的标题（封面用它）
//   theme         主题 id（src/themes/themes.js；认不出按默认主题）
//   colors        缩进的 `bg: #rrggbb` 几行：只给三色时辅助、衬底按三色规则推，给了的辅助、衬底算单独调过；没给按主题
//   fonts         缩进的 `zh / en / code: 字体 id` 几行（src/themes/fonts.js）；没给跟随主题
//   cover         缩进的 `enabled: true`、`subtitle: …`、`image: 图片编号`
//   caption       小红书正文：`caption: |` 后面缩进的几行，换行照原样
//   images        缩进的 `编号: 路径` 几行：自带模板相对网页根（docs/guide-assets/…、docs/template-assets/…），
//                 用户模板相对它自己的文件夹；正文里写 [[图片:编号]]
// 色值直接写 #rrggbb（不是 YAML 的注释）；值里有「: 」、以 # 以外的特殊符号开头时加双引号。
(function (root) {
  "use strict";

  const COLOR_ROLES = ["bg", "text", "accent", "secondary", "surface"];
  const FONT_SCRIPTS = ["zh", "en", "code"];
  const HEX = /^#[0-9a-f]{6}$/i;
  const FENCE = /^(---|\.\.\.)\s*$/;
  // 键名（ASCII）、冒号（半角或全角）、值
  const ENTRY = /^([A-Za-z_][\w-]*)\s*[:：]\s*(.*)$/;
  const SUB_ENTRY = /^\s+([^\s:：]+)\s*[:：]\s*(.*)$/;

  const oneLine = (text) => String(text ?? "").split(/\s+/).filter(Boolean).join(" ");

  function unquote(value) {
    const text = String(value ?? "").trim();
    if (text.length < 2) return text;
    const quote = text[0];
    if ((quote !== "\"" && quote !== "'") || text[text.length - 1] !== quote) return text;
    const inner = text.slice(1, -1);
    if (quote === "'") return inner.replace(/''/g, "'");
    return inner.replace(/\\(.)/g, (_, char) => (char === "n" ? "\n" : char));
  }

  // 写回时要加引号的值：以 YAML 会另作解释的符号开头（# 后面是色值的除外）、里面有「: 」「 #」、以冒号结尾、空着
  function quoted(value) {
    const text = String(value ?? "");
    const special = /^["'[\]{}>|*&!%@`,?-]/.test(text) || (text.startsWith("#") && !/^#[0-9a-fA-F]{3,8}$/.test(text));
    if (!text || special || text.includes(": ") || text.includes(" #") || text.endsWith(":")) {
      return `"${text.replace(/\\/g, "\\\\").replace(/"/g, "\\\"").replace(/\n/g, "\\n")}"`;
    }
    return text;
  }

  // 缩进的几行去掉共同的缩进（`|` 块：换行照原样）
  function dedent(lines) {
    const indents = lines.filter((line) => line.trim()).map((line) => /^\s*/.exec(line)[0].length);
    const indent = indents.length ? Math.min(...indents) : 0;
    return lines.map((line) => line.slice(Math.min(indent, /^\s*/.exec(line)[0].length)));
  }

  // 开头 --- 之间的键值与正文：{ fields: { 键: 字符串 | { 子键: 字符串 } }, body }。
  // 没有这一段（或没收尾）时 fields 为空、全文都是正文；正文去掉开头的空行。认不出的行跳过。
  function split(raw) {
    let text = String(raw ?? "").replace(/\r\n/g, "\n");
    if (text.startsWith("﻿")) text = text.slice(1);
    const lines = text.split("\n");
    if (lines[0]?.trim() !== "---") return { fields: {}, body: text };
    const end = lines.findIndex((line, index) => index > 0 && FENCE.test(line));
    if (end < 0) return { fields: {}, body: text };
    const fields = {};
    let index = 1;
    while (index < end) {
      const line = lines[index];
      const match = /^\s/.test(line) ? null : ENTRY.exec(line);
      if (!match) {
        index += 1;
        continue;
      }
      const [, key, rawValue] = match;
      const value = rawValue.trim();
      // 后面缩进的几行（中间可以有空行）归这个键
      const block = [];
      let next = index + 1;
      while (next < end && (/^\s+\S/.test(lines[next]) || !lines[next].trim())) {
        block.push(lines[next]);
        next += 1;
      }
      while (block.length && !block[block.length - 1].trim()) block.pop();
      const continued = block.map((item) => item.trim()).filter(Boolean);
      if (/^\|[+-]?$/.test(value)) {
        fields[key] = dedent(block).join("\n");
      } else if (/^>[+-]?$/.test(value)) {
        fields[key] = continued.join(" ");
      } else if (!value && block.length && block.every((item) => !item.trim() || SUB_ENTRY.test(item))) {
        const map = {};
        for (const item of block) {
          const sub = SUB_ENTRY.exec(item);
          if (sub) map[sub[1]] = unquote(sub[2]);
        }
        fields[key] = map;
      } else {
        fields[key] = [value ? unquote(value) : "", ...continued].filter(Boolean).join(" ");
      }
      index = next;
    }
    return { fields, body: lines.slice(end + 1).join("\n").replace(/^\n+/, "") };
  }

  const text = (value) => (typeof value === "string" ? value : "");
  const map = (value) => (value && typeof value === "object" ? value : {});
  const truthy = (value) => ["true", "yes", "on", "1", "是", "开"].includes(String(value ?? "").trim().toLowerCase());

  // 标签：逗号（半角、全角、顿号）分开，去重
  function tags(value) {
    return [...new Set(text(value).split(/[,，、]/).map((tag) => tag.trim()).filter(Boolean))];
  }

  // 一份模板文件 → 登记表里的一项 { file, id, name, description, tags, title, theme, colors, fonts, cover, caption, images, markdown }：
  // 字段都规范过（色值小写、只留认得的键），markdown 是正文的行；file 是文件的相对路径（自带模板相对网页根），
  // 名字、id 没写时用文件名。页面与构建脚本都用它，所以登记表能和文件逐字比对（TemplatesTests）。
  function entry(file, raw) {
    const { fields, body } = split(raw);
    const stem = String(file).split("/").pop().replace(/\.md$/i, "");
    const colors = Object.fromEntries(COLOR_ROLES
      .filter((role) => HEX.test(text(map(fields.colors)[role]).trim()))
      .map((role) => [role, map(fields.colors)[role].trim().toLowerCase()]));
    const fonts = Object.fromEntries(FONT_SCRIPTS
      .filter((script) => text(map(fields.fonts)[script]).trim())
      .map((script) => [script, map(fields.fonts)[script].trim()]));
    const cover = map(fields.cover);
    const images = Object.fromEntries(Object.entries(map(fields.images))
      .filter(([id, path]) => /^[\w-]+$/.test(id) && text(path).trim())
      .map(([id, path]) => [id, text(path).trim()]));
    return {
      file: String(file),
      id: /^[A-Za-z0-9][\w-]*$/.test(text(fields.id).trim()) ? text(fields.id).trim() : stem,
      name: oneLine(fields.name) || stem,
      description: oneLine(fields.description),
      tags: tags(fields.tags),
      title: oneLine(fields.title),
      theme: text(fields.theme).trim(),
      colors,
      fonts,
      cover: {
        enabled: truthy(cover.enabled),
        subtitle: oneLine(cover.subtitle),
        image: /^[\w-]+$/.test(text(cover.image).trim()) ? text(cover.image).trim() : null,
      },
      caption: text(fields.caption).replace(/\s+$/, ""),
      images,
      markdown: body.replace(/\s+$/, "").split("\n"),
    };
  }

  // 登记表的一项（或同样形状的字段）→ 模板文件的全文：开头 front matter（没有的键不写），空一行，正文（末尾留一个换行）
  function compose(item) {
    const lines = ["---", `name: ${quoted(oneLine(item.name))}`];
    if (item.description) lines.push(`description: ${quoted(oneLine(item.description))}`);
    if (item.tags?.length) lines.push(`tags: ${tags(item.tags.join(", ")).join(", ")}`);
    if (item.id && /^[A-Za-z0-9][\w-]*$/.test(item.id)) lines.push(`id: ${item.id}`);
    if (item.title) lines.push(`title: ${quoted(oneLine(item.title))}`);
    if (item.theme) lines.push(`theme: ${item.theme}`);
    const block = (key, pairs) => {
      const rows = pairs.filter(([, value]) => value !== undefined && value !== null && value !== "");
      if (!rows.length) return;
      lines.push(`${key}:`, ...rows.map(([subKey, value]) => `  ${subKey}: ${quoted(String(value))}`));
    };
    block("colors", COLOR_ROLES.map((role) => [role, item.colors?.[role]]));
    block("fonts", FONT_SCRIPTS.map((script) => [script, item.fonts?.[script]]));
    const cover = item.cover ?? {};
    if (cover.enabled || cover.subtitle || cover.image) {
      block("cover", [["enabled", cover.enabled ? "true" : "false"], ["subtitle", cover.subtitle], ["image", cover.image]]);
    }
    if (item.caption) lines.push("caption: |", ...String(item.caption).replace(/\r\n/g, "\n").split("\n").map((row) => (row ? `  ${row}` : "")));
    block("images", Object.entries(item.images ?? {}));
    lines.push("---", "");
    const markdown = (Array.isArray(item.markdown) ? item.markdown.join("\n") : String(item.markdown ?? "")).replace(/\r\n/g, "\n").replace(/^\n+/, "").replace(/\s+$/, "");
    return `${lines.join("\n")}\n${markdown}\n`;
  }

  root.MediaCraftTemplateFormat = Object.freeze({ COLOR_ROLES, FONT_SCRIPTS, split, entry, compose, tags });
})(globalThis);
