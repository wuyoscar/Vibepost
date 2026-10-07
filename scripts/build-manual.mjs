// 由操作手册登记表（src/engine/manual.js）与片段登记表（src/engine/snippets.js）生成 docs/manual.md。
// 改了登记表就重新运行：node scripts/build-manual.mjs
// 测试（ManualTests）在页面里写出手册，和仓库里的这份逐字比对。
import { readFileSync, writeFileSync } from "node:fs";
import vm from "node:vm";

const context = vm.createContext({});
for (const file of ["manual.js", "snippets.js"]) {
  vm.runInContext(readFileSync(new URL(`../src/engine/${file}`, import.meta.url), "utf8"), context);
}
const target = new URL("../docs/manual.md", import.meta.url);
writeFileSync(target, context.MediaCraftManual.document());
console.log(`wrote ${target.pathname}`);
