const token = document.querySelector('meta[name="gao-token"]').content;
const app = document.querySelector("#app");
let state = null;
let view = new URLSearchParams(location.search).get("view") === "editor" ? "editor" : "home";
let noteId = null;
let message = "";

async function api(path, body) {
  const response = await fetch(path, {
    method: "POST",
    headers: {"Content-Type": "application/json", "X-Gao-Token": token},
    body: JSON.stringify(body || {}),
  });
  const payload = await response.json();
  if (payload.state) acceptState(payload.state);
  if (!response.ok || payload.ok === false) {
    const error = new Error(payload.error || "操作没有完成");
    error.code = payload.code;
    throw error;
  }
  return payload;
}

async function refresh() {
  const response = await fetch("/api/state", {headers: {"X-Gao-Token": token}});
  if (!response.ok) throw new Error("无法读取本机工作台状态。");
  if (!acceptState(await response.json())) return;
  applyTheme();
  render();
}

function acceptState(snapshot) {
  if (state && (snapshot.revision || 0) < (state.revision || 0)) return false;
  state = snapshot;
  mergePendingEdits();
  return true;
}

function applyTheme() {
  const appearance = state?.settings?.appearance || "system";
  const dark = appearance === "dark" || (appearance === "system" && matchMedia("(prefers-color-scheme: dark)").matches);
  document.documentElement.dataset.theme = dark ? "dark" : "light";
  document.documentElement.dataset.editorWrap = state?.settings?.wrapLines === false ? "off" : "on";
  document.documentElement.style.setProperty("--editor-size", `${Number(state?.settings?.editorFontSize) || 15}px`);
}

function selected() {
  return (state?.tabs || []).find((tab) => tab.id === state.selection) || null;
}

function h(value) {
  return String(value ?? "").replace(/[&<>"]/g, (char) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" }[char]));
}

function render() {
  if (!state) return;
  captureWritingSession();
  if (surface === "note") return renderDesktopNote();
  if (surface === "settings") {
    app.innerHTML = `<div class="settings-window">${settingsPanel()}</div>`;
    bindSettings();
    return;
  }
  renderWorkspace();
}

function panel(tab) {
  if (view === "handoff") return handoffPanel();
  if (view === "notes") return notesPanel();
  if (view === "settings") return settingsPanel();
  if (view === "files") return organizerPanel();
  if (!tab || view === "home") return homePanel();
  if (tab.kind === "markdown" || tab.kind === "latex" || tab.kind === "text") return incomingHandoff(tab) + textPanel(tab);
  if (tab.kind === "csv") return csvPanel(tab);
  if (tab.kind === "pdf") return incomingHandoff(tab) + pdfPanel(tab);
  if (tab.kind === "richText") return rtfPanel(tab);
  if (tab.kind === "image") return imagePanel(tab);
  if (["word", "spreadsheet", "presentation"].includes(tab.kind)) return officePanel(tab);
  return `<div class="banner warn">${h(tab.preview?.message || "这个格式只读。")}</div><button data-external="${h(tab.path)}">用系统程序打开</button>`;
}

function textPanel(tab) {
  if (tab.kind === "markdown") return markdownPanel(tab);
  if (tab.kind === "latex") return latexPanel(tab);
  return `<div class="row"><b>${h(tab.title)}</b><button id="find">查找</button><button id="save">保存</button><button id="save-as">另存为</button><button data-close="${h(tab.id)}">关闭</button></div>
    <textarea class="editor" data-tab="${h(tab.id)}">${h(tab.text)}</textarea>`;
}

function csvPanel(tab) {
  return `<div class="row"><b>${h(tab.title)}</b><button id="csv-grid">表格</button><button id="csv-md">复制为 Markdown</button><button id="save">保存</button><button data-close="${h(tab.id)}">关闭</button></div>
    <textarea class="editor" data-keep="1" data-tab="${h(tab.id)}">${h(tab.text)}</textarea><div id="grid"></div>`;
}

function imagePanel(tab) {
  const preview = tab.preview || {};
  const src = `/api/binary?tab=${encodeURIComponent(tab.id)}&token=${encodeURIComponent(token)}`;
  const zoom = imageZoom.get(tab.id) || 100;
  return `<div class="image-workspace"><div class="row image-toolbar"><b>${h(tab.title)}</b><span class="row-spacer"></span>
    ${preview.preview ? `<input type="range" min="10" max="300" value="${zoom}" id="image-zoom" aria-label="图片缩放"><span id="image-scale">${zoom}%</span>` : ""}
    <button data-ocr-current>识别图片文字 (OCR)</button><button data-reveal>在资源管理器中显示</button></div>
    ${preview.preview ? `<div class="image-scroll"><img alt="${h(tab.title)}" src="${src}" style="--image-base:${Math.min(preview.width || 1000, 1200) * zoom / 100}px"></div>` : `<p class="banner warn">${h(preview.note || "无法解码这张图片。")}</p>`}</div>`;
}

const imageZoom = new Map();

function rtfPanel(tab) {
  return `<div class="row"><b>富文本</b><button id="save">保存</button><button id="save-as">另存为</button><button data-close="${h(tab.id)}">关闭</button></div>
    ${tab.lossy ? `<div class="banner warn">原 RTF 含有未能无损保留的对象。可以编辑可见文字，但覆盖保存会被拒绝，请另存为。</div>` : ""}
    ${tab.message ? `<div class="banner">${h(tab.message)}</div>` : ""}
    <textarea class="editor" data-keep="1" data-tab="${h(tab.id)}">${h(tab.text)}</textarea>`;
}

function bind() {
  bindHandoff();
  bindOrganizer();
  document.querySelectorAll("[data-go]").forEach((node) => node.onclick = () => navigate(node.dataset.go).catch(fail));
  document.querySelectorAll("button[data-tab]").forEach((node) => node.onclick = async () => {
    if (!(await leaveCurrent())) return;
    await api("/api/tabs/select", {id: node.dataset.tab});
    view = "editor";
    render();
  });
  document.querySelectorAll("[data-open]").forEach((node) => node.onclick = () => openPath(node.dataset.open));
  document.querySelectorAll("[data-card]").forEach((node) => node.onclick = () => card(node.dataset.card));
  document.querySelectorAll("[data-close]").forEach((node) => node.onclick = () => closeTab(node.dataset.close));
  document.querySelectorAll("[data-external]").forEach((node) => node.onclick = () => api("/api/external", {path: node.dataset.external}).catch(fail));
  const open = document.getElementById("open");
  if (open) open.onclick = () => openPath(document.getElementById("path").value);
  const dialog = document.getElementById("dialog");
  if (dialog) dialog.onclick = () => pick("open");
  const folder = document.getElementById("folder-dialog");
  if (folder) folder.onclick = () => pick("folder");
  const editor = document.querySelector("textarea.editor");
  if (editor) editor.oninput = () => edit(editor);
  const save = document.getElementById("save");
  if (save) save.onclick = () => saveTab(false);
  const saveAs = document.getElementById("save-as");
  if (saveAs) saveAs.onclick = () => saveTab(true);
  bindWriting(selected());
  const grid = document.getElementById("csv-grid");
  if (grid) grid.onclick = () => showGrid();
  const csvMd = document.getElementById("csv-md");
  if (csvMd) csvMd.onclick = () => copyMarkdown();
  bindPdf();
  bindOffice();
  const imageSlider = document.getElementById("image-zoom");
  if (imageSlider) imageSlider.oninput = () => {
    const tab = selected();
    const zoom = Number(imageSlider.value);
    imageZoom.set(tab.id, zoom);
    document.getElementById("image-scale").textContent = `${zoom}%`;
    document.querySelector(".image-scroll img").style.setProperty("--image-base", `${Math.min(tab.preview?.width || 1000, 1200) * zoom / 100}px`);
  };
  document.querySelectorAll("[data-reveal]").forEach((node) => node.onclick = () => api("/api/reveal", {id: selected()?.id}).catch(fail));
  if (view === "notes" && document.getElementById("note-new")) bindNotesWorkspace();
  if (view === "settings") bindSettings();
  const find = document.getElementById("find");
  if (find) find.onclick = () => {
    const query = prompt("查找");
    const editorNode = document.querySelector("textarea.editor");
    const at = editorNode.value.indexOf(query || "");
    if (at >= 0) { editorNode.focus(); editorNode.selectionStart = at; editorNode.selectionEnd = at + (query || "").length; }
  };
}

async function card(id) {
  if (!(await leaveCurrent())) return;
  if (id === "ocr") { view = "handoff"; render(); return; }
  if (id === "notes") { view = "notes"; render(); return; }
  if (id === "office") { message = "从左侧输入或选择 Word、Excel、PPT 文件。查看器不会改写原件。"; view = "home"; render(); return; }
  if (id === "pdf") return pick("open");
  view = "editor";
  await api("/api/tabs/new", {kind: id, ...(id === "markdown" ? {text: ""} : {})});
  render();
}

async function openPath(path) {
  if (!path) return;
  try {
    if (!(await leaveCurrent())) return;
    if (/\.(gaoaction|gaoresult)$/i.test(path)) { await reviewHandoff(path); return; }
    const payload = await api("/api/tabs/open", {path});
    if (payload.result?.id) view = "editor";
    message = "";
    render();
  } catch (error) {
    if (String(error.message).includes("已打开文件夹")) { view = "files"; message = ""; render(); return; }
    fail(error);
  }
}

async function pick(mode) {
  try {
    const path = await fileDialog(mode);
    if (!path) return;
    if (mode === "folder") {
      await api("/api/folder", {path});
      sidebarSearch = "";
      render();
    } else await openPath(path);
  } catch (error) { fail(error); }
}

function edit(node) {
  const tab = state.tabs.find((item) => item.id === node.dataset.tab) || selected();
  if (!tab) return;
  const body = {id: tab.id, text: node.value};
  if (tab.kind === "richText") body.html = h(node.value).replaceAll("\n", "<br>");
  stageEdit(body);
}

async function saveTab(asCopy) {
  const tab = selected();
  if (!tab?.canSave) return false;
  try { return await saveDocument(tab, asCopy); }
  catch (error) { fail(error); return false; }
}

async function saveDocument(tab, asCopy = false) {
  if (tab.kind === "pdf") return pdfSave(tab, asCopy);
  await flushEdits(tab.id);
  const path = asCopy || !tab.path ? await fileDialog("save", tab.title) : tab.path;
  if (!path) return false;
  await api("/api/tabs/save", {id: tab.id, path, asCopy});
  message = state.status;
  render();
  return true;
}

async function closeTab(id) {
  const tab = state.tabs.find((item) => item.id === id);
  if (tab?.kind === "pdf" && !(await flushPdfFields(tab))) return;
  try {
    await flushEdits(id);
    await api("/api/tabs/close", {id, discard: false});
  } catch (error) {
    if (!String(error.message).includes("未保存")) return fail(error);
    const choice = await closeDocumentChoice(tab.title);
    if (choice === "save") {
      if (!(await saveDocument(tab))) return;
      await api("/api/tabs/close", {id, discard: false});
    } else if (choice === "discard") await api("/api/tabs/close", {id, discard: true});
    else return;
  }
  view = state.selection ? "editor" : "home";
  render();
}

async function showGrid() {
  const id = selected().id;
  await flushEdits(id);
  const payload = await api("/api/tabs/preview", {id});
  const rows = payload.result.rows || [];
  document.getElementById("grid").innerHTML = `<table class="grid">${rows.map((row, r) => `<tr>${row.map((cell, c) => `<td><input data-r="${r}" data-c="${c}" value="${h(cell)}"></td>`).join("")}</tr>`).join("")}</table><div class="row"><button id="grid-save">写回源码</button><button id="grid-sort">按列排序</button><button id="grid-filter">筛选</button></div>`;
  const readGrid = () => {
    const next = rows.map((row) => row.slice());
    document.querySelectorAll("#grid input").forEach((input) => { next[input.dataset.r][input.dataset.c] = input.value; });
    return next;
  };
  document.getElementById("grid-save").onclick = async () => {
    await api("/api/tabs/csv", {id, rows: readGrid()});
    render();
  };
  document.getElementById("grid-sort").onclick = async () => {
    const column = Number(prompt("按哪一列排序（从 0 开始）", "0") || 0);
    const next = readGrid();
    const header = next[0];
    const body = next.slice(1).sort((a, b) => String(a[column] ?? "").localeCompare(String(b[column] ?? ""), "zh"));
    await api("/api/tabs/csv", {id, rows: [header, ...body]});
    render();
  };
  document.getElementById("grid-filter").onclick = () => {
    const query = (prompt("只显示包含这些文字的行", "") || "").toLocaleLowerCase();
    document.querySelectorAll("#grid tr").forEach((row, index) => {
      if (index === 0) return;
      row.hidden = Boolean(query) && ![...row.querySelectorAll("input")].some((cell) => cell.value.toLocaleLowerCase().includes(query));
    });
  };
}

async function copyMarkdown() {
  const id = selected().id;
  await flushEdits(id);
  const payload = await api("/api/tabs/preview", {id});
  await navigator.clipboard?.writeText(payload.result.markdown);
  message = "已复制 Markdown 表格";
  render();
}

function fail(error) {
  message = error.message || String(error);
  render();
}

document.addEventListener("keydown", (event) => {
  if (!(event.ctrlKey || event.metaKey) || event.altKey || event.defaultPrevented) return;
  const actions = {s: workspaceSave, n: () => card("markdown"), o: () => pick("open"),
    "1": () => navigate("home"), "2": () => navigate("notes"), "3": () => navigate("files"), ",": showSettings};
  const action = actions[event.key.toLowerCase()];
  if (!action || (surface !== "workspace" && event.key.toLowerCase() !== "s")) return;
  event.preventDefault();
  Promise.resolve().then(action).catch(fail);
});

window.addEventListener("pywebviewready", () => {
  if (surface === "workspace") window.pywebview.api.restore_notes();
});
matchMedia("(prefers-color-scheme: dark)").addEventListener("change", applyTheme);
refresh().catch(fail);
