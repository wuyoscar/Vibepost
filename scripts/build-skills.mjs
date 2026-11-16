// 由 src/skills/*.md（内置技能）与 src/skills/手册/*.md（内置写作手册）合成登记表 src/skills/index.js，格式见 src/skills/format.js。
// 改了、加了技能文件就重新运行：node scripts/build-skills.mjs
// 测试（SkillsTests）在页面里重新读这些文件、按同一个解析器比对，登记表过期就不过。
import { readdirSync, readFileSync, writeFileSync } from "node:fs";
import vm from "node:vm";

const root = new URL("../", import.meta.url);
const context = vm.createContext({});
vm.runInContext(readFileSync(new URL("src/skills/format.js", root), "utf8"), context);
const { entry } = context.MediaCraftSkillFormat;

// 按文件名排（固定的区域，不跟着这台机器的语言设置变）
const collator = new Intl.Collator("zh-Hans-CN", { numeric: true });
function read(folder) {
  const entries = readdirSync(new URL(folder, root))
    .filter((name) => name.endsWith(".md"))
    .sort(collator.compare)
    .map((name) => `${folder}${name}`)
    .map((file) => entry(file, readFileSync(new URL(file, root), "utf8")));
  const names = new Set();
  for (const item of entries) {
    if (names.has(item.name)) throw new Error(`两份都叫「${item.name}」：${item.file}`);
    names.add(item.name);
  }
  return entries;
}

// 内置技能（每轮都用）：要有短版
const skills = read("src/skills/");
for (const item of skills) {
  if (!item.brief) throw new Error(`${item.file}：没有「## 最要紧的几条」一节（AI 每轮的说明书带它）`);
}
// 内置写作手册（题材手册，AI 按题材挑、用户也能点名）：不用短版
const manuals = read("src/skills/手册/").map(({ file, name, description, markdown }) => ({ file, name, description, markdown }));

const literal = (value) => JSON.stringify(value, null, 2).replace(/\n/g, "\n  ");
const source = `// 内置技能与内置写作手册的登记表：由 scripts/build-skills.mjs 从 src/skills/*.md、src/skills/手册/*.md 生成，不要手改（改了文件后重新运行它）。
// 每一项是 src/skills/format.js 的 entry() 读出的样子；页面在 src/skills/skills.js 登记：技能和操作手册一起是内置技能，手册和用户自己的写作手册列在一起。
(function (root) {
  "use strict";

  root.MediaCraftSkillRegistry = Object.freeze(${literal(skills)});
  root.MediaCraftManualRegistry = Object.freeze(${literal(manuals)});
})(globalThis);
`;
const target = new URL("src/skills/index.js", root);
writeFileSync(target, source);
console.log(`wrote ${target.pathname}（${skills.length} 份技能，${manuals.length} 份手册）`);
