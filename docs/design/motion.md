# 动效规范

MediaCraft 的动效走原生 Mac 的路子：安静、准确、跟手（参照 Things 3、Linear、Raycast、备忘录）。每一下操作都有即时的反馈，东西从它来的地方出现、回到它去的地方；不弹跳、不卡通。

实现：令牌与样式在 `src/styles.css`（开头的 `:root` 与各控件旁边），CSS 做不到的几件事在 `src/motion.js`（`window.MediaCraftMotion`），触感走原生壳 `macos/Sources/MediaCraftShell/Haptics.swift`。测试：`macos/Tests/MediaCraftShellTests/MotionTests.swift`。

## 三条规矩

1. **状态从不等动画。** `hidden`、`aria-*`、`open`、焦点都同步改好，动画只是视觉：进场用 `@starting-style` 或在已经更新好的元素上补一段动画，退场用 `transition-behavior: allow-discrete` 把 `display` 多留一小段。退场中的东西不接鼠标（`pointer-events: none`），焦点当下移走（`MediaCraftMotion.returnFocus`）。测试与键盘用户看到的永远是最终状态。
2. **只动 transform、opacity、clip-path**（颜色与阴影可以过渡，filter 少用），不做布局动画：抽屉开合、换标签时布局立即到位，看起来的「滑」是 FLIP 或 clip-path。20 页的稿子也保持 60 fps。
3. **尊重「减少动态效果」**：位移、缩放全部取消，只留透明度的淡入淡出；转圈、闪烁这类循环动画停下。

## 令牌

| 令牌 | 值 | 用在 |
| --- | --- | --- |
| `--motion-fast` | 90 ms | 悬停变色、按下、退场 |
| `--motion-quick` | 160 ms | 透明度、遮罩、焦点环 |
| `--motion-moderate` | 240 ms | 滑块、松开回弹、进场位移、换皮肤 |
| `--motion-slow` | 360 ms | 对话框落定、手机预览、主题底色、AI 消息浮起 |
| `--ease-standard` | `cubic-bezier(0.2, 0, 0, 1)` | 状态变化 |
| `--ease-decelerate` | `cubic-bezier(0.05, 0.7, 0.1, 1)` | 进场（快进慢停） |
| `--ease-exit` | `cubic-bezier(0.3, 0, 1, 1)` | 退场（越走越快） |
| `--ease-spring` | `linear(…)`，过冲 2%（不认 `linear()` 的 WebKit 上换成拟合的 `cubic-bezier`） | 松开回弹、滑块、对话框、翻页轮播 |
| `--press-scale` | 0.97（宽的行与格子 0.985） | 按下时缩到多大 |

## `<html data-motion>`

`src/motion.js` 在页面最早的时候写上，之后跟着窗口与系统设置变：

| 值 | 什么时候 | 效果 |
| --- | --- | --- |
| `full` | 窗口看得见 | 正常播放 |
| `reduced` | 系统开了「减少动态效果」 | 所有过渡只剩 `opacity`，关键帧动画停下，脚本动画去掉位移 |
| `paused` | 窗口整个看不见（被挡住、最小化，测试的 harness 也是） | 什么都不播。WebKit 这时停住动画时间线，动画会停在第一帧；干脆不播，回来时已经是最终状态 |

## 每一处交互

| 交互 | 做法 | 退场 |
| --- | --- | --- |
| 按钮、分段控件、标签、小药丸、色块、主题格、配色库的格子、色轮把手、列表行、胶片缩略图 | 悬停立刻变色（有边框的边框也深一点）；按下 `scale(--press-scale)` 并加深，`--motion-fast`；松开沿 `--ease-spring` 回弹 | — |
| 胶片缩略图、主题格、模板格的悬停 | 胶片缩略图浮起 2 px（`translate`，`--motion-moderate` + `--ease-spring`）；主题格、模板格的缩略图 `scale(1.03)`，投影浮出来 | — |
| 焦点环 | 平时透明、外扩 5 px，键盘焦点落上来时收拢到 1 px 并显色；输入框的光环从 0 长到 3 px | — |
| 停用 | 透明度 0.42，箭头光标，变化时淡过去 | — |
| 切换按钮（手机预览、AI、源码、声音） | 颜色过渡，按下去时图标从 0.82 落定 | — |
| 分段控件的选中滑块（图文卡片 / 长文、样式 / AI 助手、稿件筛选、裁剪 / 拼图 / 实况的比例……） | `track()` 量出选中那一段，`::after` 用 clip-path 裁出滑块、`::before` 是下沿细边，一起滑过去 | — |
| 胶片当前页的框 | `track()`，`::after` 的框平移过去；胶片自己平滑滚动 | — |
| 主题格的选中底色 | `track()`，`::before` 的底色 clip-path 滑过去（4×2 格里斜着走也行） | — |
| 稿件抽屉 | 抽屉 clip-path 从左展开，里面各块左移淡入；编辑区、页码、卡片、胶片从原位置平移到新位置（`flip()`） | 列宽立即收回，编辑区平移回来 |
| 检查器换标签 | 新的一页淡入、上浮 6 px（旧的一页立即让位） | — |
| 正文栏（标题下面）展开 / 收起 | 箭头沿弹簧转 90°；输入框立即展开、收起（`details`，不做高度动画），跟着内容长高也是立即的 | — |
| 下拉菜单与浮层（段落样式、插入、Claude Code 设置、字体列表、「/」菜单、选中文字的浮动条、发布检查面板） | 从触发点那一侧 `scale(0.96)` + 淡入，弹簧落定（发布检查面板从页脚那一侧升起） | 收起立即（菜单）；列表、浮动条与发布检查面板 `--motion-fast` 淡出缩回 |
| 对话框（确认、发送前的检查、裁剪、拼图、实况） | 遮罩淡入，面板 `scale(0.96)`、下移 8 px 沿弹簧落定 | `--motion-fast` 淡出、缩到 0.98，当下不接鼠标、焦点移走 |
| 导出进度卡 | 从顶栏下面滑下；进度条按比例横向缩放 | 往上淡出 |
| 舞台翻页 | 跳到那一张后，它从翻页方向横着滑进来（往后翻从右边来） | — |
| 图文卡片 ↔ 长文 | 新的舞台内容淡入 | — |
| 手机预览 | 手机从顶栏按钮那一侧（右上）放大落下；轮播翻页沿弹簧；笔记 / 发现页 / 主页用 `.segmented`，视图立即换好 | 整层淡出，底下的大卡片已经回来 |
| 系统切换浅色 / 深色 | `src/motion.js` 跟着 `prefers-color-scheme` 换 `<html data-ui-theme>`：界面所有颜色 240 ms 一起淡过去（图标跟着 currentColor）；打开 App 时第一次上皮肤直接换。换卡片主题不动界面（ADR 0007）。不用 View Transitions：它要等下一帧截下旧画面才换状态，违反第一条 | — |
| AI 消息、工具行、动作行、候选、结尾、封面标题候选卡 | 新来的一条浮起 8 px 淡入（`is-new`，整段重画时旧的不再动） | — |
| AI 流式回复 | 末尾一根闪动的光标 | — |
| 确认修改 | 逐处接受 / 拒绝后，这一处从「待定」的样子淡到决定后的样子，按下的按钮落定；汇总条与标题那一行同样 | — |
| 权限确认卡 | 从输入框那边升上来 | — |
| 拖放 | 编辑区的落点线换位置时滑过去、出现时从左展开；舞台的落点线换落点时从中间展开；拖起的小图微微歪着、从大到小落到指针边；拼图目标高亮淡入 | — |
| 滑杆 | 拖动时圆钮放大到 1.12 | — |
| 色轮把手 | 位置用 `translate` 属性摆（不动 `left` / `top`），按下的 `scale` 叠在上面；拖动时整块光标是「抓着」；第一次打开时底图分块画（块与块之间让出主线程），画好留着 | — |
| 新手引导 | 压暗层淡入，卡片浮上来；换一步时卡片滑到下一处、压暗层的洞沿弹簧挪过去、高亮圈到位后淡入 | — |

## 触感（Force Touch 触控板）

页面调 `MediaCraftNative.haptic(pattern)`，壳里是 `NSHapticFeedbackManager`；浏览器里 `MediaCraftNative` 为 `null`，什么都不做。只在拖动中、吸到一个位置的那一下用：

| 时机 | pattern |
| --- | --- |
| 编辑区宽度拖到默认宽度附近吸住（±8 px） | `alignment` |
| 拼图拖下边吸到下一档比例 | `level-change` |
| 裁剪自由比例下拖角，吸到 3:4 / 1:1 / 4:3 / 16:9（对数差 < 0.015） | `alignment` |
| 把一张图拖到另一张图上（松手就拼成一组） | `alignment` |

走脚本消息 `mediacraftHaptic`（不等回复），不走 `/__native/` 请求：拖动中要马上震。

## 新控件、新浮层怎么接

- 能点的控件：把类名加进 `styles.css`「控件」开头那两组 `:where(…)`（过渡列表、按下列表）。
- 分段控件：用 `.segmented`，滑块自动接上（页面里现有的一打开就接，之后加进来的第一次碰到时接）。
- 别的「一组里选一个」：`MediaCraftMotion.track(容器, 选中项的选择器)`，再照 `.theme-grid::before` 写一个用 `--sel-*` 的伪元素。
- 浮层：用 `details.pop-menu > .pop-menu-panel`（下拉）或带 `hidden` 的 `.floating-bar` / `.font-picker-list`，进退场自动有；`transform-origin` 设在触发点那一侧。
- 对话框：`.modal > .dialog`，关上时 `MediaCraftMotion.returnFocus(modal, 打开前的焦点)`。
- 跟着拖动走的把手：位置用 `translate` 属性（不是 `transform`，免得和按下的 `scale` 抢；也不动 `left` / `top`）。
- 位置会跳的东西：`MediaCraftMotion.flip(元素们, () => { 同步改状态 })`；已经更新好的元素补一段：`MediaCraftMotion.play(元素, 关键帧, { duration, easing })`。
- 不要：动画结束才改状态、`transitionend` 里藏元素、动布局属性、在会被整段重画的节点上用无条件的进场动画（会一直重播）。
- 旧 WebKit（最低的 macOS 14.0 自带 Safari 17.0）：`allow-discrete` 写成单独的 `transition-behavior`，不写进 `transition` 简写；`linear()` 只通过 `--ease-spring` 用；`backdrop-filter` 同时写 `-webkit-` 版本。`CompatibilityTests` 会查这几条，清单见 [compatibility.md](../compatibility.md)。
