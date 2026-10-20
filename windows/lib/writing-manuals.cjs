"use strict";
const fs = require("node:fs/promises");

// 写作手册是用户自己的（补充题材的口味）：第一次用时只建一个空文件夹，App 不往里放东西，也从不删里面的文件
// （老版本放进去的示例照样是用户的手册）。怎么写的底线是内置的写作技能 src/skills/写作.md，随网页打包、每轮都用。
// Library 与 AI 服务可能同时初始化同一目录：mkdir recursive 本身就不怕重复。
async function seedWritingManuals(folder) {
  await fs.mkdir(folder, { recursive: true });
}

module.exports = { seedWritingManuals };
