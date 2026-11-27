let settingsTab = "writing";
const settingsChannel = new BroadcastChannel("gaowenjian-settings");

function settingsPanel() {
  const tabs = {writing: ["外观与写作", "markdown"], tools: ["文档工具", "doc"], local: ["本地资料", "drive"], about: ["关于", "gear"]};
  const section = (title, body) => `<section class="settings-section"><h3>${title}</h3><div>${body}</div></section>`;
  let content;
  if (settingsTab === "tools") {
    const tools = Object.entries(state.engines).map(([name, found]) => `<div class="settings-line engine-state"><span>${h(name === "tectonic" ? "内置 Tectonic" : name)}</span><span class="${found ? "available" : "muted"}">${found ? `${icon("check")} ${name === "tectonic" ? "可离线编译" : "可用"}` : "未找到"}</span></div>`).join("");
    content = section("LaTeX 编译", `<label class="settings-line"><span>默认引擎</span><select id="engine" data-setting="latexEngine">${noteOptions({auto: "自动", tectonic: "Tectonic", xelatex: "XeLaTeX", pdflatex: "pdfLaTeX", lualatex: "LuaLaTeX"}, state.settings.latexEngine)}</select></label>${tools}`)
      + section("Office 阅读", `<div class="settings-line"><span>版式预览</span><span class="muted">本地简版</span></div><p>Word、Excel 和 PowerPoint 只读查看。可用本机办公软件打开原文件。</p>`);
  } else if (settingsTab === "local") {
    const count = state.notes.notes.filter((item) => !item.deletedAt).length;
    content = section("资料位置", `<p class="data-directory">${h(state.dataDir)}</p><button id="settings-open-dir">${icon("open")} 在资源管理器中打开</button>`)
      + section("文档恢复", `<p>当前恢复稿会随编辑更新。原件发生外部变更时，工作台会提示先核对文件。</p>`)
      + section("便笺", `<div class="settings-line"><span>现用便笺</span><span>${count} 条</span></div><p>关闭桌面便笺会隐藏窗口。删除的便笺可从回收站找回。</p>`);
  } else if (settingsTab === "about") {
    content = `<div class="settings-about"><img src="/app-icon.png" width="55" height="55" alt=""><div><strong>搞文件</strong><code>Windows ${h(state.version)}</code></div></div>`
      + section("工作范围", "<p>LaTeX 与 Markdown 写作、PDF 编辑、Office 阅读、文件整理与桌面便笺。</p><p>工作区和文档处理保存在本机。</p>");
  } else {
    content = section("外观", `<label class="settings-line"><span>应用主题</span><select id="appearance" data-setting="appearance">${noteOptions({system: "跟随系统", light: "浅色", dark: "深色"}, state.settings.appearance)}</select></label>`)
      + section("编辑器", `<label class="settings-line settings-font"><span>源码字号</span><input id="font-size" type="range" data-setting="editorFontSize" min="11" max="24" step="1" value="${Number(state.settings.editorFontSize) || 15}"><output id="font-size-value">${Number(state.settings.editorFontSize) || 15} px</output></label>
        <label class="settings-line"><span>源码自动换行</span><input type="checkbox" data-setting="wrapLines" ${state.settings.wrapLines === false ? "" : "checked"}></label>`)
      + section("常用快捷键", `<dl class="settings-keys">${[["新建 Markdown", "Ctrl+N"], ["打开文件", "Ctrl+O"], ["保存文档", "Ctrl+S"], ["编译 LaTeX", "Ctrl+B"]].map(([label, key]) => `<div><dt>${label}</dt><dd><kbd>${key}</kbd></dd></div>`).join("")}</dl>`);
  }
  return `<div class="settings-view"><header class="settings-heading"><h1>设置</h1><span id="settings-feedback" role="status"></span></header>
    <div class="settings-layout"><nav class="settings-tabs" aria-label="设置分类">${Object.entries(tabs).map(([id, [title, symbol]]) => `<button data-settings-tab="${id}" ${id === settingsTab ? 'aria-current="true"' : ""}>${icon(symbol)}<span>${title}</span></button>`).join("")}</nav>
    <article class="settings-content"><h2>${tabs[settingsTab][0]}</h2>${message ? workspaceNotice(message, message === errorNotice) : ""}${content}</article></div></div>`;
}

function bindSettings() {
  document.querySelectorAll("[data-settings-tab]").forEach((button) => button.onclick = () => {
    settingsTab = button.dataset.settingsTab;
    message = errorNotice = "";
    render();
    document.querySelector('[data-settings-tab][aria-current="true"]')?.focus();
  });
  document.querySelectorAll("[data-setting]").forEach((control) => control.onchange = async () => {
    const key = control.dataset.setting;
    const value = control.type === "checkbox" ? control.checked : control.type === "range" ? Number(control.value) : control.value;
    const feedback = document.getElementById("settings-feedback");
    if (feedback) feedback.textContent = "正在保存…";
    try {
      await api("/api/settings", {[key]: value});
      applyTheme();
      settingsChannel.postMessage(state.settings);
      if (feedback) feedback.textContent = "已保存";
    } catch (error) { fail(error); }
  });
  const font = document.getElementById("font-size");
  if (font) font.oninput = () => { document.getElementById("font-size-value").textContent = `${font.value} px`; };
  const open = document.getElementById("settings-open-dir");
  if (open) open.onclick = () => api("/api/external", {path: state.dataDir}).catch(fail);
}

settingsChannel.onmessage = ({data}) => {
  if (!state) return;
  state.settings = data;
  applyTheme();
};
