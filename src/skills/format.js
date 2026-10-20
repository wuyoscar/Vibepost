// 内置技能文件（src/skills/*.md）的格式：开头两行 `---` 之间是 name 与 description（一行一个，值可以加引号），后面是正文 Markdown；
// 正文里「## 最要紧的几条」那一节是短版（App 里 AI 每轮的说明书带它，全文在工作副本的 AGENTS.md）。
// Node（scripts/build-skills.mjs 合成登记表）与页面（SkillsTests 比对登记表）共用这一份。
(function (root) {
  "use strict";

  const BRIEF_HEADING = "## 最要紧的几条";

  function unquote(value) {
    const text = value.trim();
    if (text.length >= 2 && (text[0] === '"' || text[0] === "'") && text.at(-1) === text[0]) return text.slice(1, -1);
    return text;
  }

  // 一份技能：{ file, name, description, markdown（正文）, brief（短版那一节的内容，没有时空着） }
  function entry(file, source) {
    const text = String(source).replace(/\r\n/g, "\n").replace(/^﻿/, "");
    const match = /^---\n([\s\S]*?)\n---\n/.exec(text);
    if (!match) throw new Error(`${file}：开头要有 --- 之间的 name 与 description`);
    const fields = {};
    for (const line of match[1].split("\n")) {
      const colon = line.indexOf(":");
      if (colon > 0) fields[line.slice(0, colon).trim()] = unquote(line.slice(colon + 1));
    }
    if (!fields.name) throw new Error(`${file}：没有 name`);
    if (!fields.description) throw new Error(`${file}：没有 description`);
    const markdown = text.slice(match[0].length).replace(/^\n+/, "");
    return { file, name: fields.name, description: fields.description, markdown, brief: brief(markdown) };
  }

  // 「## 最要紧的几条」下面到下一个 ## 之前的内容（去掉首尾空行）
  function brief(markdown) {
    const lines = markdown.split("\n");
    const start = lines.indexOf(BRIEF_HEADING);
    if (start === -1) return "";
    const rest = lines.slice(start + 1);
    const end = rest.findIndex((line) => line.startsWith("## "));
    return (end === -1 ? rest : rest.slice(0, end)).join("\n").trim();
  }

  root.MediaCraftSkillFormat = Object.freeze({ entry, BRIEF_HEADING });
})(globalThis);
