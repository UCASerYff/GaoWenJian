let sidebarVisible = true;
let browserVisible = false;
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
    dialog.setAttribute("aria-labelledby", "close-document-heading");
    dialog.innerHTML = `<form method="dialog"><h2 id="close-document-heading">${quitting ? title : `保存对 ${h(title)} 的修改？`}</h2><p>${quitting ? "可以保存后退出，或返回继续编辑。文本草稿已写入本地恢复记录。" : "关闭前可以保存当前修改，或放弃这次修改。"}</p><div class="row">${quitting ? "" : '<button value="discard">不保存</button>'}<span></span><button value="cancel" autofocus>${quitting ? "返回编辑" : "取消"}</button><button class="primary" value="save">${quitting ? "全部保存并退出" : "保存"}</button></div></form>`;
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
  arrow: '<path d="M5 12h14m-6-6 6 6-6 6"/>',
  clock: '<circle cx="12" cy="12" r="9"/><path d="M12 7v5l3 2"/>',
  scan: '<path d="M8 4H4v4m12-4h4v4m0 8v4h-4M4 16v4h4m-6-8h20M8 8h8m-8 8h8"/>',
  open: '<path d="M3.5 7V5a1 1 0 0 1 1-1h5l2 2h7a1 1 0 0 1 1 1v2M3.5 7v12h15l3-9h-15l-3 9"/>',
  check: '<path d="m5 12 4 4 10-10"/>',
  alert: '<path d="M12 3 2.5 20h19L12 3Zm0 7v4m0 3h.01"/>',
  pin: '<path d="m15 4 5 5-3 1-2 2v4l-3 1-5-5 1-3h4l2-2 1-3ZM8 16l-4 4"/>',
  keyboard: '<rect x="2.5" y="5" width="19" height="14" rx="2"/><path d="M6 9h1m3 0h1m3 0h1m3 0h1M6 12h1m3 0h1m3 0h1m3 0h1M8 15h8"/>',
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
  app.innerHTML = `<div class="main-shell" ${sidebarVisible ? "" : "data-sidebar-hidden"}>
      ${workspaceSidebar()}
      <div class="work-area">
        ${workspaceCommands(active)}
        ${state.tabs.length ? documentTabs(active) : ""}
        <div class="work-stage">
          ${fileBrowser(active)}
          <main class="main-panel ${view === "home" ? "home-panel" : ""}" data-view="${h(view)}" ${active ? `data-kind="${h(active.kind)}"` : ""}>
            ${message ? workspaceNotice(message, message === errorNotice, true) : ""}
            ${state.error ? workspaceNotice(state.error, true) : ""}
            ${panel(tab)}
          </main>
        </div>
        <footer class="work-status"><i class="status-dot"></i><span id="status" role="status">${h(view === "notes" ? (state.notes?.blocked || "便笺已保存在本机") : state.status)}</span>${active ? `<span class="status-document">${h(documentStatus(active))}</span>` : ""}</footer>
      </div></div>`;
  bind();
  bindWorkspace();
}

function workspaceCommands(active) {
  return `<header class="title-tools" aria-label="文件命令">
    <div class="title-start">
      <button class="symbol-button" id="toggle-sidebar" title="显示或隐藏导航" aria-label="显示或隐藏导航" aria-expanded="${sidebarVisible}" aria-controls="workspace-nav">${icon("sidebar")}</button>
      <button class="plain" id="toggle-browser" data-browse title="文件浏览" aria-label="文件浏览" aria-expanded="${browserVisible}" aria-controls="workspace-browser">${icon("folder")}<span>文件浏览</span></button>
    </div>
    <div class="title-actions">
      <button id="dialog" class="plain" title="打开文件 Ctrl+O">${icon("open")}<span>打开文件</span></button>
      ${active?.canSave ? `<button id="main-save" class="plain" title="保存 Ctrl+S">${icon("save")}<span>保存</span></button>` : ""}
      <details class="action-menu align-right"><summary class="command-primary">${icon("add")} 新建 ${icon("chevron")}</summary><div>
        <button data-card="markdown">Markdown 文档</button><button data-card="latex">LaTeX 文档</button>
        <button data-card="text">纯文本</button><button data-card="csv">CSV 表格</button></div></details>
      <details class="action-menu align-right"><summary title="更多命令" aria-label="更多命令">${icon("more")}</summary><div>
        <button data-go="handoff">交接</button><button id="manual-open">输入文件路径…</button><button data-settings>设置</button><button id="exit-app">退出搞文件</button>
      </div></details>
    </div></header>`;
}

function documentTabs(active) {
  return `<nav class="tabs" aria-label="打开的文档">${state.tabs.map((item) => {
    const current = item.id === active?.id;
    const tone = item.kind === "markdown" ? "tone-md" : item.kind === "latex" ? "tone-latex" : item.kind === "pdf" ? "tone-pdf" : "";
    return `<div class="tab-chip ${tone}${current ? " active" : ""}"><button data-tab="${h(item.id)}" ${current ? 'aria-current="true"' : ""} title="${h(item.path || item.title)}">${icon(fileIcon(item.kind))}<span>${h(item.title)}</span>${item.dirty ? '<i class="status-dot" title="未保存" aria-label="未保存"></i>' : ""}</button><button data-close="${h(item.id)}" class="tab-close" title="关闭" aria-label="关闭 ${h(item.title)}">${icon("close")}</button></div>`;
  }).join("")}</nav>`;
}

function workspaceNotice(text, warning, dismiss = false) {
  return `<div class="banner workspace-banner ${warning ? "warn" : ""}" role="${warning ? "alert" : "status"}">${icon(warning ? "alert" : "check")}<span>${h(text)}</span>${dismiss ? `<button id="dismiss-message" class="symbol-button" aria-label="关闭提示">${icon("close")}</button>` : ""}</div>`;
}

function documentStatus(tab) {
  if (!tab.canSave) return "只读查看";
  const text = ["markdown", "latex", "text", "csv", "richText"].includes(tab.kind);
  const summary = text ? `${tab.text.length} 字符 · ${tab.text.split("\n").length} 行 · ` : "";
  return summary + (tab.dirty ? "有未保存修改" : "已保存");
}

function workspaceSidebar() {
  const shortcut = (label, symbol, action, selected = false) => `<button class="side-shortcut${selected ? " selected" : ""}" title="${label}" aria-label="${label}" ${action} ${selected ? 'aria-current="page"' : ""}>${icon(symbol)}<span>${label}</span></button>`;
  return `<aside class="workspace-sidebar" id="workspace-nav" ${sidebarVisible ? "" : "hidden"}>
    <div class="app-brand"><img src="/app-icon.png" alt="" width="32" height="32"><strong>搞文件</strong></div>
    <nav class="shortcuts" aria-label="工作台导航">
      ${shortcut("工作台", "home", 'data-go="home"', view === "home")}
      ${shortcut("整理与查找", "organize", 'data-go="files"', view === "files")}
      ${shortcut("便笺", "notes", 'data-go="notes"', view === "notes")}
      ${shortcut("OCR 与交接", "scan", 'data-go="handoff"', view === "handoff")}
    </nav>
    <div class="side-bottom">${shortcut("设置", "gear", "data-settings", view === "settings")}</div>
  </aside>`;
}

function fileBrowser(active) {
  const folder = state.folder?.split(/[\\/]/).filter(Boolean).at(-1);
  return `<aside class="workspace-browser" id="workspace-browser" aria-label="文件浏览" ${browserVisible ? "" : "hidden"}>
    <div class="side-files-heading"><strong title="${h(state.folder || "最近文件")}">${h(folder || "最近文件")}</strong><button id="folder-dialog" class="symbol-button" title="打开文件夹" aria-label="打开文件夹">${icon("folderPlus")}</button><button id="close-browser" class="symbol-button" title="关闭浏览" aria-label="关闭浏览">${icon("close")}</button></div>
    <label class="side-search">${icon("search")}<input id="side-filter" type="search" placeholder="筛选文件名" value="${h(sidebarSearch)}"></label>
    <div class="side-files" id="side-files">${sidebarFileRows(active)}</div>
    ${state.folder ? '<button id="clear-folder" class="side-return">返回最近文件</button>' : ""}
  </aside>`;
}

function sidebarFileRows(active) {
  const files = state.folder ? state.entries : state.recent;
  const matching = files.filter((item) => item.name.toLowerCase().includes(sidebarSearch.toLowerCase()));
  return matching.map((item) => `<button class="side-file ${active?.path === item.path ? "selected" : ""}" ${item.directory ? "disabled" : `data-open="${h(item.path)}"`} title="${h(item.path)}" style="--depth:${Number(item.depth) || 0}">${icon(fileIcon(item.directory ? "folder" : item.kind))}<span>${h(item.name)}</span></button>`).join("") || `<p class="muted">${sidebarSearch ? "没有匹配的文件" : "打开文件后，会显示在这里。"}</p>`;
}

function homePanel() {
  const writingRow = (kind, title, detail, color) => `<div class="writing-launch ${color}">
    <button class="launch-main" data-card="${kind}" title="新建 ${title}"><span class="launch-icon">${icon(kind)}</span><span><strong>${title}</strong><small>${detail}</small></span>${icon("add")}</button>
    <button class="symbol-button" data-pick="${kind}" title="打开 ${title}" aria-label="打开 ${title}">${icon("open")}</button></div>`;
  const tool = (title, detail, symbol, color, attributes) => `<button class="home-tool ${color}" ${attributes}><span class="launch-icon">${icon(symbol)}</span><span><strong>${title}</strong><small>${detail}</small></span>${icon("arrow")}</button>`;
  const restored = state.tabs.filter((item) => item.restored);
  return `<div class="welcome">
    <div class="welcome-header"><h1>工作台</h1><button class="plain home-folder" data-pick="folder">${icon("folderPlus")} 打开文件夹</button></div>
    ${restored.length ? `<div class="home-recovery" role="status">${icon("restore")}<span>已恢复 ${restored.length} 个未保存草稿</span><button data-tab="${h(restored[0].id)}">查看草稿</button></div>` : ""}
    <div class="welcome-columns">
      <section class="home-card recent-surface" aria-labelledby="recent-heading"><div class="home-card-heading"><h2 id="recent-heading">最近打开</h2>${state.recent.length ? '<button class="plain" data-browse aria-controls="workspace-browser">查看文件</button>' : ""}</div>
        ${state.recent.length ? `<div class="recents">${state.recent.slice(0, 6).map(recentFileRow).join("")}</div>` : `<div class="workspace-empty">${icon("clock")}<div><strong>暂无最近文件</strong><p>打开或拖入一个文件即可开始。</p></div><button data-pick="open">打开文件</button></div>`}
      </section>
      <section class="home-card writing-surface" aria-labelledby="writing-heading"><div class="home-card-heading"><h2 id="writing-heading">新建文档</h2></div>
        ${writingRow("markdown", "Markdown", "笔记与文档", "tone-md")}
        ${writingRow("latex", "LaTeX", "公式与排版", "tone-latex")}
        <div class="file-formats"><button data-card="text">${icon("doc")} 纯文本</button><button data-card="csv">${icon("home")} CSV 表格</button></div>
      </section>
    </div>
    <section class="quick-tools" aria-labelledby="tools-heading"><h2 id="tools-heading">文档工具</h2><div class="quick-tools-grid">
      ${tool("PDF 编辑", "表单、批注与页面整理", "doc", "tone-pdf", 'data-pick="pdf"')}
      ${tool("Office 查看", "Word、Excel 与 PowerPoint", "office", "tone-office", 'data-pick="office"')}
      ${tool("识别文字", "交给搞操作处理", "scan", "tone-latex", 'data-card="ocr"')}
    </div></section>
  </div>`;
}

function recentFileRow(item) {
  const folder = item.path.replace(/[/\\][^/\\]+$/, "");
  const display = folder.split(/[/\\]/).filter(Boolean).slice(-2).join("\\");
  return `<button class="recent-row" data-open="${h(item.path)}" title="${h(item.path)}"><span class="recent-icon">${icon(fileIcon(item.kind))}</span><span><strong>${h(item.name)}</strong><small>${h(display)}</small></span>${icon("arrow")}</button>`;
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
  const nav = document.getElementById("toggle-sidebar");
  nav.onclick = () => {
    sidebarVisible = !sidebarVisible;
    document.querySelector(".main-shell").toggleAttribute("data-sidebar-hidden", !sidebarVisible);
    document.getElementById("workspace-nav").hidden = !sidebarVisible;
    nav.setAttribute("aria-expanded", String(sidebarVisible));
  };
  document.querySelectorAll("[data-browse]").forEach((node) => node.onclick = () => showBrowser(!browserVisible));
  document.getElementById("close-browser").onclick = () => showBrowser(false);
  const save = document.getElementById("main-save");
  if (save) save.onclick = () => workspaceSave().catch(fail);
  document.getElementById("manual-open").onclick = chooseOpenPath;
  document.querySelector("#exit-app").onclick = () => workspaceExit().catch(fail);
  const dismiss = document.querySelector("#dismiss-message");
  if (dismiss) dismiss.onclick = () => { message = errorNotice = ""; dismiss.closest(".workspace-banner").remove(); };
  const filter = document.querySelector("#side-filter");
  if (filter) filter.oninput = () => {
    sidebarSearch = filter.value;
    const list = document.querySelector("#side-files");
    list.innerHTML = sidebarFileRows(view === "editor" ? selected() : null);
    list.querySelectorAll("[data-open]").forEach((row) => row.onclick = () => openPath(row.dataset.open));
  };
  const clear = document.querySelector("#clear-folder");
  if (clear) clear.onclick = () => api("/api/folder", {}).then(() => { sidebarSearch = ""; render(); }).catch(fail);
  document.querySelector(".tab-chip.active")?.scrollIntoView({block: "nearest", inline: "nearest"});
}

function showBrowser(show) {
  browserVisible = show;
  const drawer = document.getElementById("workspace-browser");
  if (!drawer) return;
  drawer.hidden = !show;
  document.querySelectorAll("[data-browse]").forEach((node) => node.setAttribute("aria-expanded", String(show)));
  document.getElementById(show ? "side-filter" : "toggle-browser")?.focus();
}

function chooseOpenPath() {
  const dialog = document.createElement("dialog");
  dialog.className = "document-dialog path-dialog";
  dialog.setAttribute("aria-labelledby", "path-dialog-title");
  dialog.innerHTML = `<form method="dialog"><h2 id="path-dialog-title">打开指定文件</h2><label for="open-path">文件路径</label><input type="text" id="open-path" autocomplete="off" autofocus required><div class="row"><span></span><button value="cancel" formnovalidate>取消</button><button value="open" class="primary">打开</button></div></form>`;
  dialog.addEventListener("close", () => {
    const path = dialog.querySelector("input").value.trim();
    const shouldOpen = dialog.returnValue === "open";
    dialog.remove();
    if (shouldOpen && path) openPath(path);
  }, {once: true});
  document.body.append(dialog);
  dialog.showModal();
}

document.addEventListener("pointerdown", (event) => {
  document.querySelectorAll("details.action-menu[open]").forEach((menu) => {
    if (!menu.contains(event.target)) menu.open = false;
  });
});

document.addEventListener("keydown", (event) => {
  if (event.key !== "Escape" || document.querySelector("dialog[open]")) return;
  const openedMenu = event.target.closest?.("details.action-menu[open]");
  if (openedMenu) {
    openedMenu.open = false;
    openedMenu.querySelector("summary").focus();
  } else if (browserVisible && document.getElementById("workspace-browser")?.contains(event.target)) {
    showBrowser(false);
  }
});

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
