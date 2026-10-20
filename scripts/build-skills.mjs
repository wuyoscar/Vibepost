// 由 src/skills/*.md（内置技能，格式见 src/skills/format.js）合成登记表 src/skills/index.js。
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
const files = readdirSync(new URL("src/skills/", root))
  .filter((name) => name.endsWith(".md"))
  .sort(collator.compare)
  .map((name) => `src/skills/${name}`);
const entries = files.map((file) => entry(file, readFileSync(new URL(file, root), "utf8")));

const names = new Set();
for (const item of entries) {
  if (names.has(item.name)) throw new Error(`两份技能都叫「${item.name}」：${item.file}`);
  names.add(item.name);
  if (!item.brief) throw new Error(`${item.file}：没有「## 最要紧的几条」一节（AI 每轮的说明书带它）`);
}

const source = `// 内置技能的登记表：由 scripts/build-skills.mjs 从 src/skills/*.md 生成，不要手改（改技能文件后重新运行它）。
// 每一项是 src/skills/format.js 的 entry() 读出的样子；页面在 src/skills/skills.js 和操作手册一起登记成内置技能。
(function (root) {
  "use strict";

  root.MediaCraftSkillRegistry = Object.freeze(${JSON.stringify(entries, null, 2).replace(/\n/g, "\n  ")});
})(globalThis);
`;
const target = new URL("src/skills/index.js", root);
writeFileSync(target, source);
console.log(`wrote ${target.pathname}（${entries.length} 份）`);
