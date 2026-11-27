let settingsTab = "writing";
const settingsChannel = new BroadcastChannel("gaowenjian-settings");

function settingsPanel() {
  const tabs = {writing: "写作", tools: "工具", local: "本地资料", about: "关于"};
  let content;
  if (settingsTab === "tools") {
    const tools = Object.entries(state.engines).map(([name, found]) => `<div class="settings-line"><span>${h(name === "tectonic" ? "内置 Tectonic" : name)}</span><span class="muted">${found ? name === "tectonic" ? "可用 · 离线编译" : "可用" : "未找到"}</span></div>`).join("");
    content = `<fieldset><legend>LaTeX 编译</legend>${tools}<label class="settings-line">默认引擎 <select id="engine" data-setting="latexEngine">${noteOptions({auto: "自动", tectonic: "Tectonic", xelatex: "XeLaTeX", pdflatex: "pdfLaTeX", lualatex: "LuaLaTeX"}, state.settings.latexEngine)}</select></label><p>基础宏包随应用提供。缺少缓存时会提示，也可选择本机安装的 TeX Live。</p></fieldset>
      <fieldset><legend>Office 阅读</legend><div class="settings-line"><span>版式预览</span><span class="muted">本地简版</span></div><p>Word、Excel 和 PowerPoint 只读查看。可使用本机办公软件打开原文件。</p></fieldset>`;
  } else if (settingsTab === "local") {
    const count = state.notes.notes.filter((item) => !item.deletedAt).length;
    content = `<fieldset><legend>文档与草稿</legend><p>文档保存在你选择的位置。编辑时更新当前恢复稿，供意外退出后继续写作。</p><p>检测到其他程序修改原文件，或资料无法读取时，会停止覆盖。</p></fieldset>
      <fieldset><legend>便笺</legend><div class="settings-line"><span>现用便笺</span><span>${count} 条</span></div><p>正文、格式和附件保存在本机。关闭桌面便笺会隐藏窗口，删除的便笺可从回收站恢复。</p></fieldset>
      <fieldset><legend>资料位置</legend><p class="data-directory">${h(state.dataDir)}</p><button id="settings-open-dir">在资源管理器中打开</button><p>此目录包含工作区、恢复稿、便笺与整理索引。</p></fieldset>`;
  } else if (settingsTab === "about") {
    content = `<div class="settings-about"><img src="app-icon.png" width="88" height="88" alt=""><h1>搞文件</h1><code>V${h(state.version)}</code><h2>给想法，一张纸。</h2><p>LaTeX 与 Markdown 写作 · PDF 编辑<br>Office 阅读 · 文件整理 · 便笺</p><p>${icon("drive")} 无需账户，本机处理</p></div>`;
  } else {
    content = `<fieldset><legend>写作习惯</legend><label class="settings-line">源码字号 <input id="font-size" type="range" data-setting="editorFontSize" min="11" max="24" step="1" value="${Number(state.settings.editorFontSize) || 15}"><output id="font-size-value">${Number(state.settings.editorFontSize) || 15} pt</output></label><label class="settings-line">源码自动换行 <input type="checkbox" data-setting="wrapLines" ${state.settings.wrapLines === false ? "" : "checked"}></label></fieldset>
      <fieldset><legend>外观</legend><label class="settings-line">主题 <select id="appearance" data-setting="appearance">${noteOptions({system: "跟随系统", light: "浅色纸面", dark: "深色石墨"}, state.settings.appearance)}</select></label></fieldset>
      <fieldset><legend>常用快捷键</legend>${[["新建 Markdown", "Ctrl+N"], ["打开文件", "Ctrl+O"], ["保存文档", "Ctrl+S"], ["编译 LaTeX", "Ctrl+B"]].map(([label, key]) => `<div class="settings-line"><span>${label}</span><kbd>${key}</kbd></div>`).join("")}</fieldset>`;
  }
  return `<nav class="settings-tabs" aria-label="设置分类">${Object.entries(tabs).map(([id, title]) => `<button data-settings-tab="${id}" aria-pressed="${id === settingsTab}">${title}</button>`).join("")}</nav>${message ? `<div class="banner warn" role="alert">${h(message)}</div>` : ""}<div class="settings-content">${content}</div>`;
}

function bindSettings() {
  document.querySelectorAll("[data-settings-tab]").forEach((button) => button.onclick = () => { settingsTab = button.dataset.settingsTab; render(); });
  document.querySelectorAll("[data-setting]").forEach((control) => control.onchange = async () => {
    const key = control.dataset.setting;
    const value = control.type === "checkbox" ? control.checked : control.type === "range" ? Number(control.value) : control.value;
    try {
      await api("/api/settings", {[key]: value});
      applyTheme();
      settingsChannel.postMessage(state.settings);
    } catch (error) { fail(error); }
  });
  const font = document.getElementById("font-size");
  if (font) font.oninput = () => { document.getElementById("font-size-value").textContent = `${font.value} pt`; };
  const open = document.getElementById("settings-open-dir");
  if (open) open.onclick = () => api("/api/external", {path: state.dataDir}).catch(fail);
}

settingsChannel.onmessage = ({data}) => {
  if (!state) return;
  state.settings = data;
  applyTheme();
};
