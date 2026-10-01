// 卡片内容（长文是全文）的纯文本：「复制卡片文字」与长文的「复制全文」、长文发送到 iPhone 时放进剪贴板的都是它（App API render.plainText）；
// 图文卡片的小红书正文另在正文栏里单独写（稿子的 caption）。
// 从 parseMarkdown 的语法树推出，规则：
// - 标题、段落、引用只留文字；列表留原来的缩进与编号 / 圆点；代码块留代码本身；分割线照原文；
// - 表格留成「| 格 | 格 |」几行（含对齐行），小红书里也看得出是一张表；
// - 链接写成 [文字](网址)：发出去点不了，网址留给读的人；
// - 行内格式的标记（**、~~、`、{{…|}}）都去掉；图片、拼图、分页符与结尾页标记不进纯文本；
// - 块与块之间：原文里隔着空行的空一行（多空几行也只空一行），紧挨着的换一行，被行内图片拆开的同一行直接接上。
(function (root) {
  "use strict";

  const engine = root.MediaCraftEngine || (root.MediaCraftEngine = {});
  const WITHOUT_TEXT = new Set(["image", "imagePair", "pageBreak", "endPage"]);
  const ALIGN_MARKS = { left: ":---", center: ":---:", right: "---:" };

  // 一串行内片段的文字。同一个链接里的几段（中间只隔着格式标记）合起来写一次 [文字](网址)；
  // 两个挨着的链接网址相同时，中间隔着的原文里有「](」，照样是两个。
  function runsText(runs, markdown) {
    const pieces = [];
    for (let index = 0; index < runs.length; index += 1) {
      const run = runs[index];
      if (!run.link) {
        pieces.push(run.text);
        continue;
      }
      let text = run.text;
      while (index + 1 < runs.length) {
        const next = runs[index + 1];
        const between = markdown.slice(runs[index].source[1], next.source[0]);
        if (next.link !== run.link || between.includes("](")) break;
        text += next.text;
        index += 1;
      }
      pieces.push(`[${text}](${run.link})`);
    }
    return pieces.join("");
  }

  const cellsLine = (cells) => `| ${cells.join(" | ")} |`;

  function tableText(block, markdown) {
    const row = (cells) => cellsLine(cells.map((cell) => runsText(cell.runs, markdown)));
    return [
      row(block.header.cells),
      cellsLine(block.align.map((align) => ALIGN_MARKS[align] ?? "---")),
      ...block.rows.map((item) => row(item.cells)),
    ].join("\n");
  }

  function blockText(block, markdown) {
    switch (block.type) {
      case "heading":
        return runsText(block.runs, markdown);
      case "paragraph":
      case "quote":
        return block.lines.map((line) => runsText(line.runs, markdown)).join("\n");
      case "list":
        return block.items.map((item) => {
          const indent = markdown.slice(item.source[0], item.markerSource[0]);
          return `${indent}${item.marker} ${runsText(item.runs, markdown)}`;
        }).join("\n");
      case "code":
        return block.text;
      case "table":
        return tableText(block, markdown);
      case "rule":
        return markdown.slice(block.source[0], block.source[1]).trim();
      default:
        return "";
    }
  }

  function plainText(markdown) {
    const { blocks } = engine.parseMarkdown(markdown);
    const parts = [];
    let previous = null;
    let blankBetween = false;
    for (const block of blocks) {
      if (previous && block.blankLinesBefore > 0) blankBetween = true;
      if (WITHOUT_TEXT.has(block.type)) continue;
      if (previous) {
        const sameLine = !markdown.slice(previous.source[1], block.source[0]).includes("\n");
        parts.push(blankBetween ? "\n\n" : sameLine ? "" : "\n");
      }
      parts.push(blockText(block, markdown));
      previous = block;
      blankBetween = false;
    }
    return parts.join("");
  }

  engine.plainText = plainText;
})(globalThis);
