// 把编辑器用到的 CodeMirror 6 模块打成一个离线文件 src/vendor/codemirror.js（IIFE，全局变量 CodeMirror）。
// 版本钉死在 package.json / package-lock.json，同样的依赖打出同样的文件：
//   npm ci && node scripts/build-codemirror.mjs
// 编辑器要用新的导出时，加到下面的 EXPORTS 里再重新打包，打出的文件与许可证说明一起提交。
import { readFileSync, writeFileSync } from "node:fs";
import { dirname, join, relative } from "node:path";
import { fileURLToPath } from "node:url";
import { build } from "esbuild";

const root = join(dirname(fileURLToPath(import.meta.url)), "..");
const output = join(root, "src/vendor/codemirror.js");

const EXPORTS = {
  "@codemirror/state": [
    "Annotation", "Compartment", "EditorSelection", "EditorState", "Prec", "StateEffect", "StateField", "Transaction",
  ],
  "@codemirror/view": [
    "Decoration", "EditorView", "ViewPlugin", "WidgetType", "dropCursor", "keymap", "placeholder",
  ],
  "@codemirror/commands": [
    "history", "historyKeymap", "insertNewline", "invertedEffects", "isolateHistory", "redo", "standardKeymap", "undo",
  ],
};

const entry = Object.entries(EXPORTS)
  .map(([name, symbols]) => `export { ${symbols.join(", ")} } from "${name}";`)
  .join("\n");

const result = await build({
  stdin: { contents: entry, resolveDir: root, sourcefile: "codemirror-entry.js" },
  bundle: true,
  format: "iife",
  globalName: "CodeMirror",
  target: "safari16",
  minify: true,
  legalComments: "none",
  metafile: true,
  write: false,
});

// 打进去的每个 npm 包：名字、版本与它自己的许可证全文。
const packages = new Map();
for (const input of Object.keys(result.metafile.inputs)) {
  const match = /node_modules\/((?:@[^/]+\/)?[^/]+)\//.exec(input);
  if (!match || packages.has(match[1])) continue;
  const dir = join(root, "node_modules", match[1]);
  const { version, license } = JSON.parse(readFileSync(join(dir, "package.json"), "utf8"));
  if (license !== "MIT") throw new Error(`${match[1]} 的许可证是 ${license}，不是 MIT，先确认能否打包`);
  packages.set(match[1], { version, text: readFileSync(join(dir, "LICENSE"), "utf8").trim() });
}

const names = [...packages.keys()].sort();
const banner = [
  "/*!",
  " * CodeMirror 6 离线打包（MIT），由 scripts/build-codemirror.mjs 生成，不要手改。",
  ` * 包含：${names.map((name) => `${name}@${packages.get(name).version}`).join(", ")}`,
  " *",
  ...names.flatMap((name) => [
    ` * ---- ${name} ----`,
    ...packages.get(name).text.split("\n").map((line) => ` * ${line}`.trimEnd()),
    " *",
  ]),
  " */",
].join("\n");

writeFileSync(output, `${banner}\n${result.outputFiles[0].text}`);
const size = Buffer.byteLength(readFileSync(output));
process.stdout.write(`已生成 ${relative(root, output)}：${names.length} 个包，${(size / 1024).toFixed(1)} KB\n`);
