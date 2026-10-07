// 自带模板的自检：按 src/templates/README.md 的格式解析每套 src/templates/*.md，查 front matter 齐不齐、主题认不认得、
// 图片找不找得到、话题几个，再按 [[分页]] 分成卡片，查每张的字数（120–320）、记号是不是中文写法、组件有没有收尾、
// 页尾是不是在最后、有没有只剩标题的卡片。改了模板就跑一遍：node scripts/check-templates.mjs（有问题退出码 1）。
// 字数按显示宽度算（中文 1、英文数字半个，同小红书标题的算法），不算记号与组件的开头收尾；图片按占的版面折算
// （整幅图约占大半页，记 100；拼图矮一些，记 70），所以带图的卡片字少也算填满。
import { existsSync, readdirSync, readFileSync } from "node:fs";
import vm from "node:vm";

const root = new URL("../", import.meta.url);
const templatesDir = new URL("src/templates/", root);

// ===== 主题 id：从主题注册表里取（它只要 deepFreeze） =====
const themeContext = vm.createContext({ MediaCraftEngine: { deepFreeze: (value) => value } });
vm.runInContext(readFileSync(new URL("src/themes/themes.js", root), "utf8"), themeContext);
const THEME_IDS = new Set(themeContext.MediaCraftThemes.list().map((theme) => theme.id));

const STYLE_TAGS = new Set(["简洁", "柔和", "有态度"]);
const CHARS = { min: 120, max: 320, end: 10 };
const IMAGE_WEIGHT = { single: 100, pair: 70 };
const CARDS = { min: 6, max: 9 };

// 英文写法的记号（App 认，但模板只能写中文）
const ENGLISH_MARKERS = /\[\[image:|\{\{(color|bg|underline|mark):|:::(kicker|note|footnote|mono|rows|steps)\b|align=/;

// ===== front matter：与写作手册同一套规则 =====
// 一行一个「键: 值」；值是 | 或 > 时，后面缩进的几行是它的值（| 保留换行，> 并成一行）；别的键后面缩进的行接在值后面
function parseFrontMatter(raw) {
  const lines = raw.replace(/\r\n/g, "\n").replace(/^﻿/, "").split("\n");
  if (lines[0]?.trim() !== "---") return { fields: {}, body: raw };
  const end = lines.findIndex((line, index) => index > 0 && ["---", "..."].includes(line.trim()));
  if (end < 0) return { fields: {}, body: raw };
  const fields = {};
  let key = null;
  let block = null;
  for (const line of lines.slice(1, end)) {
    if (key && /^\s/.test(line)) {
      const text = line.trim();
      if (block === "|") fields[key] = fields[key] ? `${fields[key]}\n${text}` : text;
      else fields[key] = [fields[key], text].filter(Boolean).join(" ");
      continue;
    }
    const colon = line.indexOf(":");
    if (colon < 0) {
      key = null;
      continue;
    }
    key = line.slice(0, colon).trim();
    let value = line.slice(colon + 1).trim();
    block = ["|", ">", "|-", ">-", "|+", ">+"].includes(value) ? value[0] : null;
    if (block) value = "";
    fields[key] = value;
  }
  let body = lines.slice(end + 1).join("\n");
  body = body.replace(/^\n+/, "");
  return { fields, body };
}

// 「a b, c d」→ [["a", "b"], ["c", "d"]]：逗号分开各项，每项第一个空格前是名字
const pairs = (value) => String(value ?? "").split(",").map((item) => item.trim()).filter(Boolean).map((item) => {
  const space = item.search(/\s/);
  return space < 0 ? [item, ""] : [item.slice(0, space), item.slice(space + 1).trim()];
});

// ===== 字数 =====
const width = (text) => [...text.replace(/\s/g, "")].reduce((sum, char) => sum + (/[\x21-\x7e]/.test(char) ? 0.5 : 1), 0);

// 一张卡片的文字（去掉记号与组件的开头收尾、Markdown 前缀、行内格式）
function cardText(lines) {
  return lines
    .filter((line) => !/^\s*\[\[(图片|分页|结尾)[^\]]*\]\]\s*$/.test(line) && !/^\s*:::/.test(line) && !/^\s*\|\s*-{3,}/.test(line))
    .map((line) => line
      .replace(/^\s*(#{1,6}\s+|>\s*|[-*]\s+|\d+\.\s+)/, "")
      .replace(/\{\{[^:|}]+:[^|}]*\|([^}]*)\}\}/g, "$1")
      .replace(/\*\*|~~|`|\*/g, "")
      .replace(/\[([^\]]*)\]\([^)]*\)/g, "$1")
      .replace(/^\s*\[[^\]]+\]\s*/, "")
      .replace(/\|/g, ""))
    .join("");
}

const imageWeight = (lines) => lines.reduce((sum, line) => {
  const match = /^\s*\[\[图片:([^\]]+)\]\]\s*$/.exec(line);
  if (!match) return sum;
  return sum + (match[1].split("|").filter((part) => !/^\d+x\d+$/.test(part)).length > 1 ? IMAGE_WEIGHT.pair : IMAGE_WEIGHT.single);
}, 0);

const imageIds = (lines) => lines.flatMap((line) => {
  const match = /^\s*\[\[图片:([^\]]+)\]\]\s*$/.exec(line);
  return match ? match[1].split("|").filter((part) => !/^\d+x\d+$/.test(part)) : [];
});

// 卡片里的块：空行隔开，组件整块算一块
function blocks(lines) {
  const result = [];
  let current = null;
  let inComponent = false;
  for (const line of lines) {
    if (!line.trim() && !inComponent) {
      current = null;
      continue;
    }
    if (!current) result.push(current = []);
    current.push(line);
    if (/^\s*:::\S/.test(line)) inComponent = true;
    else if (/^\s*:::\s*$/.test(line)) inComponent = false;
  }
  return result;
}
const isHeading = (block) => block.length === 1 && /^#{1,6}\s/.test(block[0]);
const isKicker = (block) => /^\s*:::小标签/.test(block[0]);
const isFootnote = (block) => /^\s*:::页尾/.test(block[0]);

// ===== 一套模板 =====
function check(file) {
  const problems = [];
  const raw = readFileSync(new URL(file, templatesDir), "utf8");
  const { fields, body } = parseFrontMatter(raw);
  const name = file.replace(/\.md$/, "");

  if (fields.name !== name) problems.push(`name 应为文件名「${name}」，现在是「${fields.name ?? ""}」`);
  if (!fields.description) problems.push("缺 description");
  else if ([...fields.description].length > 80) problems.push("description 超过 80 字");
  const tags = String(fields.tags ?? "").split(",").map((tag) => tag.trim()).filter(Boolean);
  if (tags.length !== 2) problems.push(`tags 要两个（题材、风格），现在 ${tags.length} 个`);
  else if (!STYLE_TAGS.has(tags[1])) problems.push(`风格标签要是 ${[...STYLE_TAGS].join(" / ")} 之一，现在是「${tags[1]}」`);
  if (!THEME_IDS.has(fields.theme)) problems.push(`theme「${fields.theme}」不在主题注册表里`);
  if (fields.colors !== undefined) {
    for (const [role, value] of pairs(fields.colors)) {
      if (!["bg", "text", "accent", "secondary", "surface"].includes(role)) problems.push(`colors 里认不出的角色「${role}」`);
      if (!/^#[0-9a-fA-F]{6}$/.test(value)) problems.push(`colors 的 ${role} 要是 #rrggbb，现在是「${value}」`);
    }
  }

  const images = new Map();
  for (const [id, path] of pairs(fields.images)) {
    if (!/^[\w-]+$/.test(id)) problems.push(`图片编号「${id}」只能用字母、数字、下划线、连字符`);
    if (!existsSync(new URL(path, root))) problems.push(`图片 ${id} 的文件不存在：${path}`);
    images.set(id, path);
  }
  if (images.size < 2 || images.size > 3) problems.push(`示例图要 2–3 张，现在 ${images.size} 张`);

  const cover = Object.fromEntries(pairs(fields.cover));
  if (fields.cover !== undefined) {
    if (!["true", "false"].includes(cover.enabled)) problems.push("cover 的 enabled 要是 true / false");
    if (cover.subtitle && [...cover.subtitle].length > 60) problems.push("cover 的 subtitle 超过 60 字");
    if (cover.image && !images.has(cover.image)) problems.push(`cover 的图片「${cover.image}」没在 images 里`);
  }

  const caption = String(fields.caption ?? "");
  if (!caption.trim()) problems.push("缺 caption");
  else {
    const topics = caption.trim().split("\n").at(-1).match(/#[^\s#]+/g) ?? [];
    if (topics.length < 3 || topics.length > 5) problems.push(`caption 最后一行要 3–5 个 #话题，现在 ${topics.length} 个`);
    if ([...caption.replace(/\s/g, "")].length > 1000) problems.push("caption 超过 1000 字");
  }

  if (ENGLISH_MARKERS.test(raw)) problems.push(`用了英文写法的记号：${ENGLISH_MARKERS.exec(raw)[0]}`);
  if (/[:：]\s|\s\|\s*[^\s|]/.test(raw.match(/\{\{[^}]*\}\}/g)?.join("\n") ?? "")) problems.push("行内记号的冒号、竖线两侧不能有空格");

  // ===== 卡片 =====
  const lines = body.split("\n");
  if (!/^#\s+\S/.test(lines[0] ?? "")) problems.push("正文第一行要是「# 标题」（封面与稿件标题从它取）");
  else if (width(lines[0].replace(/^#\s+/, "")) > 20) problems.push("标题超过 20 字（小红书的限制）");
  const endAt = lines.findIndex((line) => line.trim() === "[[结尾]]");
  const bodyLines = endAt < 0 ? lines : lines.slice(0, endAt);
  const endLines = endAt < 0 ? null : lines.slice(endAt + 1);
  const cards = [];
  let current = [];
  for (const line of bodyLines) {
    if (line.trim() === "[[分页]]") {
      cards.push(current);
      current = [];
    } else current.push(line);
  }
  cards.push(current);
  if (cards.length < CARDS.min || cards.length > CARDS.max) problems.push(`卡片要 ${CARDS.min}–${CARDS.max} 张，现在 ${cards.length} 张`);

  const used = new Set();
  const counts = [];
  const inspect = (cardLines, label, min) => {
    const chars = width(cardText(cardLines));
    const total = chars + imageWeight(cardLines);
    counts.push(`${label} ${chars}${imageWeight(cardLines) ? `+图${imageWeight(cardLines)}` : ""}`);
    if (total < min || total > CHARS.max) problems.push(`${label}字数 ${total}，要在 ${min}–${CHARS.max}`);
    const openers = cardLines.filter((line) => /^\s*:::\S/.test(line)).length;
    const closers = cardLines.filter((line) => /^\s*:::\s*$/.test(line)).length;
    if (openers !== closers) problems.push(`${label}的组件开头 ${openers} 个、收尾 ${closers} 个，不配对`);
    const open = (cardLines.join("\n").match(/\{\{/g) ?? []).length;
    const close = (cardLines.join("\n").match(/\}\}/g) ?? []).length;
    if (open !== close) problems.push(`${label}的 {{ 与 }} 不配对`);
    for (const id of imageIds(cardLines)) {
      used.add(id);
      if (!images.has(id)) problems.push(`${label}用了没登记的图片「${id}」`);
    }
    const parts = blocks(cardLines);
    if (!parts.length) problems.push(`${label}是空的`);
    else {
      if (isHeading(parts.at(-1)) || isKicker(parts.at(-1))) problems.push(`${label}以标题或小标签结尾，会只剩标题`);
      if (parts.every((block) => isHeading(block) || isKicker(block))) problems.push(`${label}只有标题`);
      const footnote = parts.findIndex(isFootnote);
      if (footnote >= 0 && footnote !== parts.length - 1) problems.push(`${label}的页尾不在最后一块`);
    }
  };
  cards.forEach((cardLines, index) => inspect(cardLines, `第 ${index + 1} 张`, CHARS.min));
  if (endLines) inspect(endLines, "结尾页", CHARS.end);
  if (cover.image) used.add(cover.image);
  for (const id of images.keys()) if (!used.has(id)) problems.push(`图片「${id}」登记了但没用到`);
  if (!bodyLines.some((line) => /^\s*\[\[图片:/.test(line))) problems.push("正文里至少要有一处 [[图片:编号]]");

  return { name, theme: fields.theme, tags, cards: cards.length + (endLines ? 1 : 0), counts, problems };
}

// ===== 跑 =====
const files = readdirSync(templatesDir).filter((file) => file.endsWith(".md") && file !== "README.md").sort((a, b) => a.localeCompare(b, "zh"));
let failed = false;
for (const file of files) {
  const result = check(file);
  const status = result.problems.length ? "✗" : "✓";
  console.log(`${status} ${result.name}（${result.theme}；${result.tags.join("、")}）${result.cards} 页：${result.counts.join("，")}`);
  for (const problem of result.problems) console.log(`    - ${problem}`);
  if (result.problems.length) failed = true;
}
if (!files.length) {
  console.log("src/templates/ 里没有模板");
  failed = true;
}
console.log(failed ? "有问题，见上面" : `${files.length} 套模板都通过`);
process.exit(failed ? 1 : 0);
