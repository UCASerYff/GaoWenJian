let sidebarVisible = true;
let sidebarSearch = "";
const surface = ({"/settings": "settings", "/note": "note"})[location.pathname] || "workspace";
const pendingEdits = new Map();
const localEdits = new Map();
let editQueue = Promise.resolve();

function mergePendingEdits() {
  for (const [id, body] of localEdits) {
    const tab = state.tabs.find((item) => item.id === id);
    if (tab) { tab.text = body.text; tab.dirty = true; }
  }
}

function stageEdit(body) {
  clearTimeout(pendingEdits.get(body.id)?.timer);
  localEdits.set(body.id, body);
  mergePendingEdits();
  const timer = setTimeout(() => flushEdits(body.id).catch(fail), 350);
  pendingEdits.set(body.id, {body, timer});
  const status = document.querySelector(".status-document");
  if (status && selected()?.id === body.id) status.textContent = "有未保存修改";
}

async function flushEdits(tabId) {
  const edits = [...pendingEdits].filter(([id]) => !tabId || id === tabId);
  for (const [id, entry] of edits) {
    clearTimeout(entry.timer);
    pendingEdits.delete(id);
    editQueue = editQueue.catch(() => {}).then(async () => {
      try {
        if (localEdits.get(id) === entry.body) localEdits.delete(id);
        await api("/api/tabs/edit", {...entry.body, select: false});
        const dirty = state.tabs.find((item) => item.id === id)?.dirty;
        const marker = [...document.querySelectorAll(".tab-chip [data-tab]")].find((item) => item.dataset.tab === id);
        if (marker && !marker.querySelector(".status-dot") && dirty) {
          const dot = document.createElement("i");
          dot.className = "status-dot";
          dot.title = "未保存";
          marker.append(dot);
        } else if (!dirty) marker?.querySelector(".status-dot")?.remove();
      } catch (error) {
        if (!pendingEdits.has(id)) {
          pendingEdits.set(id, entry);
          localEdits.set(id, entry.body);
        }
        throw error;
      }
    });
  }
  await editQueue;
}

async function fileDialog(mode, name = "") {
  if (window.pywebview?.api) return window.pywebview.api.file_dialog(mode, name);
  try { return (await api("/api/dialog", {mode, name})).result.path; }
  catch (error) { if (error.code !== "cancelled") throw error; return ""; }
}

function closeDocumentChoice(title, quitting = false) {
  return new Promise((resolve) => {
    const dialog = document.createElement("dialog");
    dialog.className = "document-dialog";
    dialog.innerHTML = `<form method="dialog"><h2>${quitting ? title : `保存对 ${h(title)} 的修改？`}</h2><p>${quitting ? "可以保存后退出，或返回继续编辑。文本草稿已写入本地恢复记录。" : "关闭前可以保存当前修改，或放弃这次修改。"}</p><div class="row">${quitting ? "" : '<button value="discard">不保存</button>'}<span></span><button value="cancel" autofocus>${quitting ? "返回编辑" : "取消"}</button><button class="primary" value="save">${quitting ? "全部保存并退出" : "保存"}</button></div></form>`;
    dialog.addEventListener("close", () => { resolve(dialog.returnValue); dialog.remove(); }, {once: true});
    document.body.append(dialog);
    dialog.showModal();
  });
}

const symbols = {
  sidebar: '<rect x="2.5" y="3.5" width="19" height="17" rx="3"/><path d="M9 4v16M5 7h1M5 10h1"/>',
  home: '<rect x="3" y="3" width="7" height="7" rx="1"/><rect x="14" y="3" width="7" height="7" rx="1"/><rect x="3" y="14" width="7" height="7" rx="1"/><rect x="14" y="14" width="7" height="7" rx="1"/>',
  folder: '<path d="M3 7a2 2 0 0 1 2-2h5l2 2h7a2 2 0 0 1 2 2v9a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2Z"/>',
  folderPlus: '<path d="M3 7a2 2 0 0 1 2-2h5l2 2h7a2 2 0 0 1 2 2v9a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2Z M12 10v7m-3.5-3.5h7"/>',
  organize: '<path d="M21 9a2 2 0 0 0-2-2h-7l-2-2H5a2 2 0 0 0-2 2v11a2 2 0 0 0 2 2h6"/><circle cx="16.5" cy="15.5" r="3.2"/><path d="M16.5 10v2m0 7v2m-5.5-5.5h2m7 0h2"/>',
  latex: '<path d="M16.8 4.7c-2-2-5.6-.6-6.1 2.3L8.6 17c-.6 2.7-2.8 4-4.4 1.7M6.5 10h10M17 14l4 5m0-5-4 5"/>',
  markdown: '<path d="M3 5h18M3 10h13M3 15h18M3 20h10"/>',
  doc: '<path d="M13 3H6a2 2 0 0 0-2 2v14a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2V10zm0 0v7h7M8 14h8M8 17h8"/>',
  office: '<path d="M8 3H4a1 1 0 0 0-1 1v4m13-5h4a1 1 0 0 1 1 1v4m0 8v4a1 1 0 0 1-1 1h-4m-8 0H4a1 1 0 0 1-1-1v-4M7 9h10m-10 3h10m-10 3h7"/>',
  notes: '<rect x="4" y="3" width="16" height="18" rx="2"/><path d="M8 8h8m-8 4h8m-8 4h5"/>',
  gear: '<path d="M10 3h4l.6 2.3 2 .9 2.1-1.2 2.2 2.2-1.2 2.1.9 2L23 12l-.8 2.9-2.4.3-.9 2 1.2 2.1-2.2 2.2-2.1-1.2-2 .9L13 23h-3l-.6-2.3-2-.9-2.1 1.2L3.1 19l1.2-2.1-.9-2L1 14v-3l2.4-.6.9-2-1.2-2.1 2.2-2.2 2.1 1.2 2-.9Z"/><circle cx="12" cy="12" r="3"/>',
  drive: '<path d="M3 15l3-8a2 2 0 0 1 2-1h8a2 2 0 0 1 2 1l3 8v3a1 1 0 0 1-1 1H4a1 1 0 0 1-1-1zm0 0h18m-4 2h1"/>',
  search: '<circle cx="10" cy="10" r="6"/><path d="m15 15 5 5"/>',
  add: '<path d="M12 4v16M4 12h16"/>',
  save: '<path d="M4 10v9a1 1 0 0 0 1 1h14a1 1 0 0 0 1-1v-9m-8-7v12m-4-4 4 4 4-4"/>',
  close: '<path d="m6 6 12 12M6 18 18 6"/>',
  chevron: '<path d="m7 9 5 5 5-5"/>',
  more: '<circle cx="5" cy="12" r="1"/><circle cx="12" cy="12" r="1"/><circle cx="19" cy="12" r="1"/>',
  restore: '<path d="M3 12a9 9 0 1 1 2.5 6.2M3 5v7h7m2-5v5l3 2"/>',
};

function icon(name) {
  return `<svg class="ui-icon" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.65" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">${symbols[name] || symbols.doc}</svg>`;
}

function fileIcon(kind) {
  return {latex: "latex", markdown: "markdown", word: "office", spreadsheet: "office", presentation: "office", folder: "folder"}[kind] || "doc";
}

function renderWorkspace() {
  const tab = selected();
  const active = view === "editor" ? tab : null;
  app.innerHTML = `<header class="title-tools">
      <button class="symbol-button" id="toggle-sidebar" title="显示 / 隐藏侧边栏" aria-label="显示 / 隐藏侧边栏">${icon("sidebar")}</button>
      <div class="title-actions">
        <details class="action-menu"><summary>${icon("add")} 新建 ${icon("chevron")}</summary><div>
          <button data-card="latex">LaTeX 文档</button><button data-card="markdown">Markdown 文档</button>
          <button data-card="text">纯文本</button><button data-card="csv">CSV 表格</button></div></details>
        <button id="dialog">${icon("folder")} 打开</button><span class="tool-divider"></span>
        <button id="main-save" ${(active?.canSave || view === "notes") ? "" : "disabled"}>${icon("save")} 保存</button>
        <details class="action-menu align-right"><summary title="更多操作" aria-label="更多操作">${icon("more")}</summary><div>
          <button data-go="handoff">交接</button><button id="manual-open">输入文件路径…</button><button data-settings>设置</button><button id="exit-app">退出搞文件</button>
        </div></details>
      </div></header>
    <main class="main-shell" ${sidebarVisible ? "" : "data-sidebar-hidden"}>
      ${sidebarVisible ? workspaceSidebar(active) : ""}
      <div class="work-area">
        ${state.tabs.length ? `<nav class="tabs" aria-label="已打开文档">${state.tabs.map((item) => `<div class="tab-chip${item.id === active?.id ? " active" : ""}"><button data-tab="${h(item.id)}" title="${h(item.path || item.title)}">${icon(fileIcon(item.kind))}<span>${h(item.title)}</span>${item.dirty ? '<i class="status-dot" title="未保存"></i>' : ""}</button><button data-close="${h(item.id)}" class="tab-close" aria-label="关闭 ${h(item.title)}">${icon("close")}</button></div>`).join("")}</nav>` : ""}
        <section class="main-panel ${view === "home" ? "home-panel" : ""}">
          ${message ? `<div class="banner warn workspace-banner" role="status">${h(message)}<button id="dismiss-message" aria-label="关闭提示">${icon("close")}</button></div>` : ""}
          ${state.error ? `<div class="banner warn workspace-banner" role="alert">${h(state.error)}</div>` : ""}
          ${panel(tab)}
        </section>
        <footer class="work-status"><i class="status-dot"></i><span id="status">${h(view === "files" ? "整理与查找 · 写作标签已保留" : view === "notes" ? (state.notes?.blocked || "便笺自动保存在本机") : state.status)}</span>${active ? `<span class="status-document">${h(documentStatus(active))}</span>` : ""}</footer>
      </div></main>`;
  bind();
  bindWorkspace();
}

function documentStatus(tab) {
  if (!tab.canSave) return "只读查看";
  const text = ["markdown", "latex", "text", "csv", "richText"].includes(tab.kind);
  const summary = text ? `${tab.text.length} 字符 · ${tab.text.split("\n").length} 行 · ` : "";
  return summary + (tab.dirty ? "有未保存修改" : "已保存");
}

function workspaceSidebar(active) {
  const shortcut = (label, symbol, action, selected = false, color = "") => `<button class="side-shortcut ${color}${selected ? " selected" : ""}" ${action} ${selected ? 'aria-current="page"' : ""}>${icon(symbol)}<span>${label}</span>${selected ? '<i class="status-dot"></i>' : ""}</button>`;
  const folder = state.folder?.split(/[\\/]/).filter(Boolean).at(-1);
  return `<aside class="workspace-sidebar">
    <div class="app-brand"><img src="app-icon.png" alt="" width="38" height="38"><div><strong>搞文件</strong><small>你的本地写作台</small></div></div>
    <div class="shortcuts">
      ${shortcut("工作台", "home", 'data-go="home"', view === "home")}
      <h2>写作</h2>${shortcut("LaTeX", "latex", 'data-pick="latex"', false, "tone-latex")}${shortcut("Markdown", "markdown", 'data-pick="markdown"', false, "tone-md")}
      <h2>文档工具</h2>${shortcut("PDF 编辑", "doc", 'data-pick="pdf"', false, "tone-pdf")}${shortcut("Office 查看", "office", 'data-pick="office"')}${shortcut("整理与查找", "organize", 'data-go="files"', view === "files")}
    </div><div class="side-rule"></div>
    <div class="side-files-heading"><strong>${h(folder || "最近文件")}</strong><button id="folder-dialog" class="symbol-button" title="打开文件夹" aria-label="打开文件夹">${icon("folderPlus")}</button></div>
    <label class="side-search">${icon("search")}<input id="side-filter" type="search" placeholder="筛选文件名" value="${h(sidebarSearch)}"></label>
    <div class="side-files" id="side-files">${sidebarFileRows(active)}</div>
    ${state.folder ? '<button id="clear-folder" class="side-return">返回最近文件</button>' : ""}
    <div class="side-bottom">${shortcut("便笺", "notes", 'data-go="notes"', view === "notes")}
      <div><small>${icon("drive")}本机处理</small><button data-settings class="symbol-button" title="设置 Ctrl+," aria-label="设置">${icon("gear")}</button></div></div>
  </aside>`;
}

function sidebarFileRows(active) {
  const files = state.folder ? state.entries : state.recent;
  const matching = files.filter((item) => item.name.toLowerCase().includes(sidebarSearch.toLowerCase()));
  return matching.map((item) => `<button class="side-file ${active?.path === item.path ? "selected" : ""}" ${item.directory ? "disabled" : `data-open="${h(item.path)}"`} title="${h(item.path)}" style="--depth:${Number(item.depth) || 0}">${icon(fileIcon(item.directory ? "folder" : item.kind))}<span>${h(item.name)}</span></button>`).join("") || `<p class="muted">${sidebarSearch ? "没有匹配的文件" : "打开文件后，会显示在这里。"}</p>`;
}

function homePanel() {
  const heading = (label, detail) => `<div class="home-heading"><h2>${label}</h2><span>${detail}</span></div>`;
  const writingCard = (kind, title, description, detail, color) => `<article class="writing-card ${color}"><div class="writing-mark"><div class="writing-icon">${icon(kind)}</div><code>${kind === "latex" ? ".tex" : ".md"}</code></div><div><h3>${title}</h3><p>${description}</p></div><small>${detail}</small><div class="writing-actions"><button class="tinted" data-card="${kind}">新建文档</button><button class="plain" data-pick="${kind}">打开…</button></div></article>`;
  const tool = (title, detail, symbol, color, actions) => `<div class="home-tool"><div class="${color}">${icon(symbol)}</div><div><b>${title}</b><small>${detail}</small></div><div class="home-tool-actions">${actions}</div></div>`;
  const restored = state.tabs.filter((item) => item.restored).length;
  return `<div class="welcome">
    <div class="welcome-header"><div><small class="welcome-kicker">WORKSPACE</small><h1>给想法，一张纸。</h1><p>从写作到成稿，让文件各就其位。</p></div><button data-pick="open">${icon("folder")} 打开文件</button></div>
    ${restored ? `<div class="banner warn welcome-restore">${icon("restore")} 已恢复 ${restored} 个未保存草稿，请检查后保存。</div>` : ""}
    <div class="welcome-columns"><div class="launch-area">
      <div>${heading("开始写作", "从空白到成稿")}<div class="writing-cards">${writingCard("latex", "LaTeX", "让论文与公式井然有序", "离线编译 · 大纲导航 · PDF 联动", "tone-latex")}${writingCard("markdown", "Markdown", "让文字跟上你的想法", "即时预览 · 公式图示 · 多格式导出", "tone-md")}</div></div>
      <div>${heading("文档工具", "阅读、编辑与整理")}<div class="home-surface tools-list">
        ${tool("PDF 编辑", "文字与图片批注，表单与页面整理", "doc", "tone-pdf", '<button class="plain" data-card="ocr">识别文字…</button><button data-pick="pdf">打开 PDF</button>')}
        ${tool("Office 查看", "Word · Excel · PowerPoint", "office", "tone-md", '<details class="action-menu align-right"><summary>打开文档</summary><div><button data-pick="word">Word</button><button data-pick="spreadsheet">Excel</button><button data-pick="presentation">PowerPoint</button></div></details>')}
        ${tool("整理与查找", "授权目录索引，收藏与虚拟工作区", "organize", "tone-latex", '<button data-go="files">开始整理</button>')}
      </div></div>
      <div class="home-notes">${icon("notes")}<div>零散的灵感，也有去处。<small>便笺与桌面便条，随手记下来。</small></div><button class="plain" data-go="notes">打开便笺</button></div>
    </div><div>${heading("接着上次", "最近打开")}<div class="home-surface recent-surface">
      ${state.recent.length ? state.recent.slice(0, 7).map((item) => `<button class="recent-row" data-open="${h(item.path)}" title="${h(item.path)}">${icon(fileIcon(item.kind))}<span><b>${h(item.name)}</b><small>${h(item.path.split(/[\\/]/).slice(0, -1).join("\\"))}</small></span></button>`).join("") : `<div class="recent-empty">${icon("doc")}<div>这里等着你的第一份文档。</div><small>打开的文件会在此显示，文档始终留在原来的位置。</small></div>`}
      <button class="recent-folder" data-pick="folder">${icon("folderPlus")} 打开项目文件夹</button>
    </div></div></div>
    <div class="welcome-footer">${icon("save")} 将文件拖到窗口中，直接开始。 <kbd>Ctrl+N 新建 · Ctrl+O 打开</kbd></div>
  </div>`;
}

async function showSettings() {
  if (window.pywebview?.api) await window.pywebview.api.show_settings();
  else { view = "settings"; render(); }
}

async function workspaceSave() {
  if (view === "notes" || surface === "note") return saveNote();
  if (view === "editor" && selected()?.canSave) return saveTab(false);
}

async function leaveCurrent() {
  if (view === "notes" && !(await flushNoteEdit())) return false;
  const tab = selected();
  if (view === "editor" && tab?.kind === "pdf" && !(await flushPdfFields(tab))) return false;
  await flushEdits();
  return true;
}

async function navigate(target) {
  if (!(await leaveCurrent())) return;
  view = target;
  message = "";
  render();
}

async function workspaceExit() {
  if (!(await leaveCurrent())) return;
  if (window.pywebview?.api) {
    if (await window.pywebview.api.close_workspace()) return;
    const dirty = state.tabs.filter((item) => item.dirty);
    if (!dirty.length) throw new Error("仍有窗口的修改待保存。请检查桌面便笺后重试。");
    const choice = await closeDocumentChoice(`还有 ${dirty.length} 个文件未保存`, true);
    if (choice === "save") {
      for (const tab of dirty) if (!(await saveDocument(tab))) return;
      if (!(await window.pywebview.api.close_workspace())) throw new Error("还有修改待保存，请检查文档或桌面便笺。");
    }
  } else await api("/api/shutdown", {}).then(() => window.close());
}

function bindWorkspace() {
  document.querySelectorAll("[data-pick]").forEach((node) => node.onclick = () => pick(node.dataset.pick));
  document.querySelectorAll("[data-settings]").forEach((node) => node.onclick = () => showSettings().catch(fail));
  document.querySelector("#toggle-sidebar").onclick = () => { sidebarVisible = !sidebarVisible; render(); };
  document.querySelector("#main-save").onclick = () => workspaceSave().catch(fail);
  document.querySelector("#manual-open").onclick = () => openPath(prompt("输入文件路径") || "");
  document.querySelector("#exit-app").onclick = () => workspaceExit().catch(fail);
  const dismiss = document.querySelector("#dismiss-message");
  if (dismiss) dismiss.onclick = () => { message = ""; render(); };
  const filter = document.querySelector("#side-filter");
  if (filter) filter.oninput = () => {
    sidebarSearch = filter.value;
    const list = document.querySelector("#side-files");
    list.innerHTML = sidebarFileRows(view === "editor" ? selected() : null);
    list.querySelectorAll("[data-open]").forEach((row) => row.onclick = () => openPath(row.dataset.open));
  };
  const clear = document.querySelector("#clear-folder");
  if (clear) clear.onclick = () => api("/api/folder", {}).then(() => { sidebarSearch = ""; render(); }).catch(fail);
}

document.addEventListener("dragover", (event) => {
  if (surface === "workspace" && event.dataTransfer?.types.includes("Files")) event.preventDefault();
});
document.addEventListener("drop", (event) => {
  if (surface !== "workspace" || !event.dataTransfer?.types.includes("Files")) return;
  event.preventDefault();
  if (!window.pywebview?.api) pick("open");
});

async function openDroppedFiles(paths) {
  for (const path of paths) await openPath(path);
}
