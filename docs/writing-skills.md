# 写作技能

输入框的「写作技能」或 `/` 打开可搜索的手册列表。可多选，选择本身不发送；写下要求后一起发送，只明确应用于该条消息。消息历史记录所选名称。技能仍可能留在后端会话历史中，后续轮次会明确说明本轮选择，不把之前的选择当作常驻指令。

每份是 `src/writing-manuals/` 中自足的 Markdown 手册，无脚本、额外 API 或绝对路径依赖。原有的小红书图文、国际新闻、代码库解读继续保留。用户的手册也出现在同一列表。

## 本次移植

| 手册 | 参考的本机技能 | 适配范围 |
| --- | --- | --- |
| 标题打磨 | title-matrix：SKILL.md、references/platforms.md、evidence.md、review-and-library.md | 保留看点、力度、兑现原则；去掉本地案例库操作、平台算法断言和未经验证的表现统计 |
| 保留原意去AI味 | de-AI-writing：SKILL.md、references/ai-trace-index.md、discourse-pass.md、syntax-pass.md、vocab-pass.md、translation-guardrails.md、narrative-pass.md | 将一般修订原则重新编写为卡片适用的手册；不复制检测效果承诺或机械删格式规则 |
| 观点长文 | good-writing：SKILL.md、references/style-summary.md、style-dna.md | 提炼一般论证与节奏原则；不复制范文、不署名具体作者、不强制厚段或作者模仿 |
| 英文简明表达 | simple-english：SKILL.md、references/checklist.md、use-cases.md | 只取一般清晰表达原则；保留不确定性，不宣称 STE 合规，不带词典依赖 |

核对日期：2026-10-12。上述源文件没有能确认“卡兹克标题／写作”的署名，产品中不作该归因。`humanizer-zh` 与去 AI 味重复，未另行移植。本文列的是改编来源，不要求最终用户安装原技能；运行所需内容均已写进各手册正文，没有遗漏的 references 链接。

标题手册改编自 title-matrix，原 MIT 许可与署名保留在 `src/writing-manuals/licenses/title-matrix.txt`，随网页资源打包；该第三方部分保留 MIT 许可。其他手册采用重新表述的通用原则，不随包附带外部作者的文章样本。

## 安装与更新

首次使用创建本机「写作手册」目录。更新时只补入从未安装过的新增手册，不覆盖同名文件，不补回用户主动删除的手册。隐藏的 `.bundled-writing-manuals.json` 记录已经处理过的自带文件名；不会被当作写作手册或拷入 agent 工作副本。已有目录没有记录时，将旧版三份示例视为已经处理，保留用户的删改。
