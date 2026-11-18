// AI 设置 ›「接别家的模型」›「接口」：在 App 里填一家服务商的密钥，或任何 OpenAI 兼容的接口地址加模型名。
// 它们经 OpenCode 使用（一个带工具的 Agent 就够了：光有接口的模型不会读写文件）：壳把填好的几家存在本机，
// 起 opencode 时写成内联配置带给它（macOS AIProviders.swift，Windows windows/lib/ai-providers.cjs），
// 所以这几家的模型出现在 OpenCode 报的选单里。只经 App API（mc.ai.providers / saveProviders）。
// - 预设的服务商：只填密钥。provider 是 OpenCode 模型目录（models.dev）里的 id，接口地址和有哪些模型由它管，
//   2026-11-17 对着 opencode 1.18.34 核对过；目录里没有的 id 它会直接略过。
// - 自定义接口：名字、接口地址、模型名、密钥。provider 是这边起的 `my-…`。
// 密钥只进不出：存的时候给壳，之后这里只知道「填了没有」；换了接口地址要重新填密钥。
// 浏览器里没有壳：这一节不显示。
(function (root) {
  "use strict";

  const PRESETS = [
    {
      group: "按量付费",
      items: [
        { provider: "deepseek", name: "DeepSeek" },
        { provider: "moonshotai-cn", name: "Kimi（月之暗面开放平台）" },
        { provider: "zhipuai", name: "智谱 GLM" },
        { provider: "alibaba-cn", name: "通义千问（阿里云百炼）" },
        { provider: "minimax-cn", name: "MiniMax" },
        { provider: "volcengine", name: "豆包（火山方舟）" },
        { provider: "siliconflow-cn", name: "硅基流动" },
      ],
    },
    {
      group: "包月套餐",
      items: [
        { provider: "kimi-code-plan-cn", name: "Kimi 会员（Kimi For Coding）" },
        { provider: "zhipuai-coding-plan", name: "智谱 GLM Coding Plan" },
        { provider: "alibaba-coding-plan-cn", name: "阿里云百炼 Coding Plan" },
        { provider: "minimax-cn-coding-plan", name: "MiniMax Token Plan" },
        { provider: "volcengine-coding-plan", name: "火山方舟 Coding Plan" },
      ],
    },
    {
      group: "国际站",
      items: [
        { provider: "zai", name: "Z.AI（智谱国际站）" },
        { provider: "zai-coding-plan", name: "Z.AI Coding Plan" },
        { provider: "moonshotai", name: "Moonshot AI（Kimi 国际站）" },
        { provider: "kimi-code-plan-global", name: "Kimi For Coding（kimi.ai）" },
        { provider: "alibaba", name: "阿里云百炼（国际站）" },
        { provider: "minimax", name: "MiniMax（国际站）" },
        { provider: "openrouter", name: "OpenRouter" },
      ],
    },
  ];
  const CUSTOM = "custom";

  const ai = root.MediaCraftAI;
  const $ = (selector) => document.querySelector(selector);
  const section = $("#aiProviders");
  const list = $("#aiProviderList");
  const addButton = $("#aiProviderAddBtn");
  const form = $("#aiProviderForm");
  const presetSelect = $("#aiProviderPreset");
  const nameInput = $("#aiProviderName");
  const urlInput = $("#aiProviderURL");
  const modelsInput = $("#aiProviderModels");
  const keyInput = $("#aiProviderKey");
  const error = $("#aiProviderError");

  // 存着的几家（没有密钥，只有 hasKey）；正在改的那一家（新加的为 null）
  let entries = [];
  let editing = null;

  function showError(problem) {
    error.hidden = !problem;
    error.textContent = problem ? problem.message || String(problem) : "";
  }

  const splitModels = (text) => text.split(/[,，、\s]+/).map((model) => model.trim()).filter(Boolean);

  // 自定义接口在 OpenCode 里的服务商 id：my- 加名字里的英文数字（没有就是 my-api），和已有的不重
  function customId(name) {
    const slug = name.toLowerCase().replace(/[^a-z0-9]+/g, "-").replace(/^-+|-+$/g, "").slice(0, 40);
    const base = `my-${slug || "api"}`;
    let id = base;
    for (let n = 2; entries.some((entry) => entry.provider === id); n += 1) id = `${base}-${n}`;
    return id;
  }

  function describe(entry) {
    const key = entry.hasKey ? "已填密钥" : "还没填密钥";
    return entry.baseURL ? `${entry.baseURL} · ${entry.models.join("、")} · ${key}` : key;
  }

  function button(label, title, action) {
    const node = document.createElement("button");
    node.type = "button";
    node.className = "pill-button";
    node.textContent = label;
    node.title = title;
    node.addEventListener("click", action);
    return node;
  }

  function render() {
    list.replaceChildren(...entries.map((entry) => {
      const item = document.createElement("li");
      item.className = "ai-manual";
      item.setAttribute("role", "group");
      item.setAttribute("aria-label", entry.name);
      const name = document.createElement("span");
      name.className = "ai-manual-name";
      name.textContent = entry.name;
      const note = document.createElement("span");
      note.className = "ai-manual-description";
      note.textContent = describe(entry);
      const actions = document.createElement("span");
      actions.className = "ai-manual-actions";
      // 删除要点两下：第一下变成「确定删除」，移开就变回去（密钥只进不出，删掉了 App 里找不回来）
      const remove = button("删除", `删掉「${entry.name}」和它的密钥`, () => {
        if (remove.dataset.armed) return void run(() => save(entries.filter((other) => other !== entry).map(stored)));
        remove.dataset.armed = "true";
        remove.textContent = "确定删除";
      });
      const disarm = () => {
        delete remove.dataset.armed;
        remove.textContent = "删除";
      };
      remove.addEventListener("blur", disarm);
      remove.addEventListener("mouseleave", disarm);
      actions.append(button("修改", `改「${entry.name}」的密钥或设置`, () => open(entry)), remove);
      item.append(name, note, actions);
      return item;
    }));
  }

  // 存着的一家再交给壳时的样子：不带 key，壳沿用已存的
  const stored = ({ provider, name, baseURL, models }) => ({ provider, name, baseURL: baseURL ?? null, models: models ?? [] });

  async function save(next) {
    entries = await ai.api.saveProviders(next);
    render();
  }

  function run(task) {
    showError(null);
    return Promise.resolve().then(task).catch(showError);
  }

  // 服务商选单：还没填过的预设（正在改的那一家留着），最后是自定义接口
  function fillPresets() {
    const taken = new Set(entries.filter((entry) => entry !== editing).map((entry) => entry.provider));
    const groups = PRESETS.map(({ group, items }) => {
      const node = document.createElement("optgroup");
      node.label = group;
      node.append(...items.filter((item) => !taken.has(item.provider)).map((item) => new Option(item.name, item.provider)));
      return node;
    }).filter((node) => node.children.length);
    // 正在改的那一家不在预设里（别的版本存的）：照它自己的名字列出来
    const known = PRESETS.some(({ items }) => items.some((item) => item.provider === editing?.provider));
    const own = editing && !editing.baseURL && !known ? [new Option(editing.name, editing.provider)] : [];
    presetSelect.replaceChildren(...own, ...groups, new Option("自定义接口（OpenAI 兼容）", CUSTOM));
  }

  function syncForm() {
    const custom = presetSelect.value === CUSTOM;
    for (const field of form.querySelectorAll("[data-custom]")) field.hidden = !custom;
    keyInput.placeholder = editing?.hasKey ? "留空：沿用已填的密钥" : "";
  }

  // 打开表单：entry 是要改的那一家，没给是新加
  function open(entry = null) {
    editing = entry;
    showError(null);
    fillPresets();
    presetSelect.value = entry ? (entry.baseURL ? CUSTOM : entry.provider) : presetSelect.options[0].value;
    // 改的时候不换服务商：换一家就是另加一个
    presetSelect.disabled = !!entry;
    nameInput.value = entry?.baseURL ? entry.name : "";
    urlInput.value = entry?.baseURL ?? "";
    modelsInput.value = (entry?.models ?? []).join(", ");
    keyInput.value = "";
    syncForm();
    form.hidden = false;
    addButton.hidden = true;
    (entry ? keyInput : presetSelect).focus();
  }

  function close() {
    editing = null;
    keyInput.value = "";
    form.hidden = true;
    addButton.hidden = false;
  }

  async function submit() {
    const key = keyInput.value.trim();
    let entry;
    if (presetSelect.value === CUSTOM) {
      const name = nameInput.value.trim();
      const baseURL = urlInput.value.trim();
      const models = splitModels(modelsInput.value);
      if (!name) throw new Error("给这个接口起个名字");
      if (!/^https?:\/\/[^\s/]+/.test(baseURL)) throw new Error("接口地址要像 https://api.example.com/v1 这样");
      if (!models.length) throw new Error("写上至少一个模型名（服务商文档里的模型 ID）");
      if (editing && editing.baseURL !== baseURL && !key) throw new Error("换了接口地址，密钥要重新填");
      entry = { provider: editing?.provider ?? customId(name), name, baseURL, models };
    } else {
      const preset = PRESETS.flatMap((group) => group.items).find((item) => item.provider === presetSelect.value);
      entry = { provider: preset?.provider ?? editing.provider, name: preset?.name ?? editing.name, baseURL: null, models: [] };
    }
    if (!key && !editing?.hasKey) throw new Error("填上密钥");
    if (key) entry.key = key;
    const rest = entries.map((other) => (other === editing ? entry : stored(other)));
    await save(editing ? rest : [...rest, entry]);
    close();
  }

  addButton.addEventListener("click", () => open());
  presetSelect.addEventListener("change", syncForm);
  $("#aiProviderCancelBtn").addEventListener("click", close);
  $("#aiProviderSaveBtn").addEventListener("click", () => void run(submit));
  form.addEventListener("keydown", (event) => {
    if (event.key !== "Enter" || event.isComposing || event.target.tagName !== "INPUT") return;
    event.preventDefault();
    void run(submit);
  });

  // 每次打开 AI 设置时重新列一遍（另一个窗口可能刚改过）。列表晚一步回来时表单可能已经打开了：不动它，
  // 只把正在改的那一家换成新列表里的同一家（没了就收起）
  async function refresh() {
    const found = await ai.api.providers();
    section.hidden = found === null;
    if (found === null) return;
    entries = found;
    render();
    if (!editing) return;
    editing = entries.find((entry) => entry.provider === editing.provider) ?? null;
    if (!editing) close();
  }

  // 关上 AI 设置时收起表单：填了一半的密钥不留在框里
  $("#aiSettings").addEventListener("toggle", (event) => {
    if (event.target.open) void refresh().catch(showError);
    else close();
  });
  void refresh().catch(() => undefined);

  ai.providerPresets = PRESETS;
})(window);
