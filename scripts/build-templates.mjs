// 由 src/templates/*.md（自带模板，格式见 src/templates/format.js）合成登记表 src/templates/index.js。
// 改了、加了模板文件就重新运行：node scripts/build-templates.mjs
// 测试（TemplatesTests）在页面里重新读这些文件、按同一个解析器比对，登记表过期就不过。
import { readdirSync, readFileSync, writeFileSync } from "node:fs";
import vm from "node:vm";

const root = new URL("../", import.meta.url);
const context = vm.createContext({});
vm.runInContext(readFileSync(new URL("src/templates/format.js", root), "utf8"), context);
const { entry } = context.MediaCraftTemplateFormat;

// 按文件名排（固定的区域，不跟着这台机器的语言设置变）
const collator = new Intl.Collator("zh-Hans-CN", { numeric: true });
const files = readdirSync(new URL("src/templates/", root))
  .filter((name) => name.endsWith(".md"))
  .sort(collator.compare)
  .map((name) => `src/templates/${name}`);
const entries = files.map((file) => entry(file, readFileSync(new URL(file, root), "utf8")));

const ids = new Set();
for (const item of entries) {
  if (ids.has(item.id)) throw new Error(`两份模板的 id 都是「${item.id}」：${item.file}`);
  ids.add(item.id);
}

const source = `// 自带模板的登记表：由 scripts/build-templates.mjs 从 src/templates/*.md 生成，不要手改（改模板文件后重新运行它）。
// 每一项是 src/templates/format.js 的 entry() 读出的样子；页面在 src/templates/templates.js 登记成稿子记录。
(function (root) {
  "use strict";

  root.MediaCraftTemplateRegistry = Object.freeze(${JSON.stringify(entries, null, 2).replace(/\n/g, "\n  ")});
})(globalThis);
`;
const target = new URL("src/templates/index.js", root);
writeFileSync(target, source);
console.log(`wrote ${target.pathname}（${entries.length} 套）`);
