:::kicker
核心动作：拆
:::

# 一段 prompt，
# 拆成这样

:::mono
Classify the support ticket into {{mark:choice|billing, shipping, or account}}. Set {{mark:noul|urgent=true if the customer cannot use the product or has a deadline today}}. If they {{mark:noul|ask for a refund}}, add refund=true. {{mark:drop|~~Output JSON only.~~}}
:::

:::rows
- [choice] `team` billing / shipping / account，再加一个 other 兜底，模型不会被逼着选错。
- [noul] `urgent` "用不了产品"和"今天截止"这两条定义，原样搬进 criteria。
- [noul] `refund_requested` 一个命题一个问题，高值就是"是"。
- [drop] `Output JSON only` 答案本来就是类型化的，格式指令没用了。
- [code] **算术 日期 计数 精确匹配** 永远留在代码里，Jev 不是计算器。
:::

:::footnote
所有问题放在同一个请求里并行发出。阈值集中在一个常量块里，按错误的代价来调。
:::
