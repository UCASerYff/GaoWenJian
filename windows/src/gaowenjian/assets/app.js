const token = document.querySelector('meta[name="gao-token"]').content;
const app = document.querySelector("#app");
let state = null;
let view = "home";
let noteId = null;
let pdfPage = 0;
let spread = false;
let markdownSplit = true;
let message = "";

async function api(path, body) {
  const response = await fetch(path, {
    method: "POST",
    headers: {"Content-Type": "application/json", "X-Gao-Token": token},
    body: JSON.stringify(body || {}),
  });
  const payload = await response.json();
  if (payload.state) state = payload.state;
  if (!response.ok || payload.ok === false) throw new Error(payload.error || "操作没有完成");
  return payload;
}

async function refresh() {
  const response = await fetch("/api/state", {headers: {"X-Gao-Token": token}});
  state = await response.json();
  applyTheme();
  render();
}

function applyTheme() {
  const appearance = state?.settings?.appearance || "system";
  const dark = appearance === "dark" || (appearance === "system" && matchMedia("(prefers-color-scheme: dark)").matches);
  document.documentElement.dataset.theme = dark ? "dark" : "light";
}

function selected() {
  return (state.tabs || []).find((tab) => tab.id === state.selection) || null;
}

function h(value) {
  return String(value ?? "").replace(/[&<>"]/g, (char) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" }[char]));
}

function render() {
  const tab = selected();
  app.innerHTML = `
    <header>
      <strong>搞文件</strong><span>V${h(state.version)} · Windows</span>
      <span class="muted">${h(state.dataDir)}</span>
      <span style="flex:1"></span>
      <button data-go="home">首页</button>
      <button data-go="files">文件夹</button>
      <button data-go="notes">便笺</button>
      <button data-go="settings">设置</button>
    </header>
    <nav class="tabs">
      ${(state.tabs || []).map((item) => `<button data-tab="${h(item.id)}" class="${item.id === state.selection ? "active" : ""}">${h(item.title)}${item.dirty ? " ·" : ""}</button>`).join("")}
    </nav>
    <main>
      <aside>
        ${message ? `<div class="banner warn">${h(message)}</div>` : ""}
        ${state.error ? `<div class="banner warn">${h(state.error)}</div>` : ""}
        <div class="row"><input id="path" type="text" placeholder="输入本机路径"><button id="open">打开</button></div>
        <div class="row" style="margin-top:8px"><button id="dialog">选择文件…</button><button id="folder-dialog">文件夹…</button></div>
        <h3>最近</h3>
        <ul class="list">${(state.recent || []).map((item) => `<li><button data-open="${h(item.path)}">${h(item.name)}</button></li>`).join("") || "<li class='muted'>还没有最近文件</li>"}</ul>
      </aside>
      <section>${panel(tab)}</section>
    </main>
    <footer id="status">${h(state.status || "")}</footer>`;
  bind();
}

function panel(tab) {
  if (view === "notes") return notesPanel();
  if (view === "settings") return settingsPanel();
  if (view === "files") return filesPanel();
  if (!tab || view === "home") return homePanel();
  if (tab.kind === "markdown" || tab.kind === "latex" || tab.kind === "text") return textPanel(tab);
  if (tab.kind === "csv") return csvPanel(tab);
  if (tab.kind === "pdf") return pdfPanel(tab);
  if (tab.kind === "richText") return rtfPanel(tab);
  if (tab.kind === "image") return imagePanel(tab);
  if (["word", "spreadsheet", "presentation"].includes(tab.kind)) return officePanel(tab);
  return `<div class="banner warn">${h(tab.preview?.message || "这个格式只读。")}</div><button data-external="${h(tab.path)}">用系统程序打开</button>`;
}

function homePanel() {
  const cards = [
    ["latex", "LaTeX", "写作与本地编译"],
    ["markdown", "Markdown", "源码、预览与导出"],
    ["pdf", "PDF", "阅读、页面和叠加"],
    ["office", "Office 查看", "Word / Excel / PPT 只读"],
    ["csv", "CSV / TSV", "表格、筛选前的源码"],
    ["text", "纯文本", "查找与保存"],
    ["notes", "便笺", "六色、分组、回收站"],
  ];
  return `<h1>写作优先</h1><p class="muted">LaTeX 与 Markdown 是主要入口。PDF 和 OCR 放在一起，Office 只读。切换入口会保留已打开的标签。</p>
    <div class="cards">${cards.map(([id, title, copy]) => `<button class="card" data-card="${id}"><b>${title}</b><span>${copy}</span></button>`).join("")}</div>
    <p class="muted">OCR 由 macOS 上的搞截图执行。Windows 版可以导入已经生成的交接结果，但不能发起识别。</p>`;
}

function textPanel(tab) {
  const extra = tab.kind === "markdown"
    ? `<button id="toggle-split">${markdownSplit ? "隐藏预览" : "分屏预览"}</button><button id="export-html">导出 HTML</button><button id="export-pdf">导出纯文本 PDF</button>`
    : tab.kind === "latex"
      ? `<button id="compile">编译</button><button id="outline">刷新大纲</button><button id="complete">补全</button>`
      : `<button id="find">查找</button>`;
  return `<div class="row"><b>${h(tab.title)}</b>${extra}<button id="save">保存</button><button id="save-as">另存为</button><button data-close="${h(tab.id)}">关闭</button></div>
    <div id="side"></div>
    <div class="${tab.kind === "markdown" && markdownSplit ? "split" : ""}">
      <textarea class="editor" data-keep="1" data-tab="${h(tab.id)}">${h(tab.text)}</textarea>
      ${tab.kind === "markdown" && markdownSplit ? `<div class="preview" id="preview"></div>` : ""}
    </div>`;
}

function csvPanel(tab) {
  return `<div class="row"><b>${h(tab.title)}</b><button id="csv-grid">表格</button><button id="csv-md">复制为 Markdown</button><button id="save">保存</button><button data-close="${h(tab.id)}">关闭</button></div>
    <textarea class="editor" data-keep="1" data-tab="${h(tab.id)}">${h(tab.text)}</textarea><div id="grid"></div>`;
}

function pdfPanel(tab) {
  const pages = tab.preview?.pages || [];
  const page = pages[pdfPage] || pages[0];
  const next = pages[pdfPage + 1];
  return `    <div class="row"><b>${h(tab.title)}</b><button id="pdf-prev">上一页</button><button id="pdf-next">下一页</button>
    <button id="spread">${spread ? "单页文字" : "双页文字"}</button><button id="rotate">旋转</button>
    <button id="crop">裁剪</button><button id="pdf-delete">删除本页</button><button id="reorder">排序</button>
    <button id="merge">合并</button><button id="extract">提取</button><button id="split">拆分</button>
    <button id="stamp">叠加英文</button><button id="image-stamp">叠加图片</button><button id="pdf-search">搜索</button>
    <button id="undo">撤销</button><button id="redo">重做</button><button id="save">保存</button><button data-close="${h(tab.id)}">关闭</button></div>
    <p class="muted">${h(tab.preview?.message || tab.message || "")}</p>
    <div class="pages"><div>${pages.map((item, index) => `<button data-page="${index}">${item.number}${index === pdfPage ? " ·" : ""}</button>`).join("")}</div>
      <div class="${spread ? "two" : ""}"><article class="page-text">${h(page?.text || "这一页没有抽出文字。")}</article>${spread && next ? `<article class="page-text">${h(next.text)}</article>` : ""}</div></div>
    <h3>目录</h3><ul class="list">${(tab.preview?.outline || []).map((item) => `<li style="padding-left:${item.depth * 12}px">${h(item.title)}</li>`).join("") || "<li class='muted'>没有书签，或重写后未能保留。</li>"}</ul>
    <h3>表单</h3><ul class="list">${(tab.preview?.fields || []).map((field) => `<li>${h(field.name)}：${h(field.value)}</li>`).join("") || "<li class='muted'>没有读到表单字段。</li>"}</ul>`;
}

function officePanel(tab) {
  const recovery = tab.preview?.recovery;
  const parts = tab.preview?.parts || [];
  return `<div class="banner">${h(tab.preview?.message || "")}</div>
    <div class="row"><button data-external="${h(tab.path)}">用外部应用打开</button><button id="reload">重新读取</button>
      ${recovery?.readable ? `<button id="export-recovery">导出恢复副本…</button>` : ""}</div>
    ${recovery?.message ? `<p class="banner warn">${h(recovery.message)}</p>` : ""}
    ${parts.map((part) => `<article><h3>${h(part.title || "")}</h3><pre class="page-text">${h(part.text || JSON.stringify(part.cells || [], null, 2))}</pre></article>`).join("")}`;
}

function imagePanel(tab) {
  const preview = tab.preview || {};
  const src = `/api/binary?tab=${encodeURIComponent(tab.id)}&token=${encodeURIComponent(token)}`;
  return `<div class="row"><b>${h(tab.title)}</b><button data-close="${h(tab.id)}">关闭</button></div>
    <p class="muted">${h(preview.note || "")} ${preview.width ? `${preview.width}×${preview.height}` : ""}</p>
    ${preview.preview ? `<img alt="" src="${src}" style="max-width:100%">` : `<div class="banner warn">当前浏览器不能直接显示这个图片格式。</div>`}
    <p class="muted">图片文字识别入口在 macOS 上交给搞截图。Windows 版不内置 OCR。</p>`;
}

function rtfPanel(tab) {
  return `<div class="row"><b>富文本</b><button id="save">保存</button><button id="save-as">另存为</button><button data-close="${h(tab.id)}">关闭</button></div>
    ${tab.lossy ? `<div class="banner warn">原 RTF 含有未能无损保留的对象。可以编辑可见文字，但覆盖保存会被拒绝，请另存为。</div>` : ""}
    ${tab.message ? `<div class="banner">${h(tab.message)}</div>` : ""}
    <textarea class="editor" data-keep="1" data-tab="${h(tab.id)}">${h(tab.text)}</textarea>`;
}

function notesPanel() {
  const notes = state.notes || {notes: []};
  const active = (notes.notes || []).find((note) => note.id === noteId);
  return `<div class="row"><h2>便笺</h2><button id="note-new">新建便笺</button><button data-go="home">返回首页</button></div>
    ${notes.blocked ? `<div class="banner warn">${h(notes.blocked)}</div>` : ""}
    <div class="row"><input id="note-search" type="search" placeholder="搜索标题、分组或正文"></div>
    <div id="note-list">${(notes.notes || []).filter((note) => !note.deletedAt).map((note) => `<button class="note ${h(note.color)} ${note.isTranslucent ? "translucent" : ""}" data-note="${h(note.id)}"><b>${h(note.title || "便笺")}</b><div>${h((note.plainText || "").slice(0, 80))}</div></button>`).join("")}</div>
    <h3>回收站</h3>
    ${(notes.notes || []).filter((note) => note.deletedAt).map((note) => `<div class="row"><span>${h(note.title || "便笺")}</span><button data-restore="${h(note.id)}">恢复</button></div>`).join("") || "<p class='muted'>回收站是空的。删除只是移入这里。</p>"}
    ${active && !active.deletedAt ? `<div class="note ${h(active.color)}"><input id="note-title" type="text" value="${h(active.title)}"><textarea id="note-body">${h(active.plainText)}</textarea>
      <div class="row"><select id="note-color">${["yellow","blue","green","pink","purple","gray"].map((color) => `<option ${color === active.color ? "selected" : ""}>${color}</option>`).join("")}</select>
      <input id="note-group" type="text" value="${h(active.group)}" placeholder="分组"><button id="note-save">保存便笺</button><button id="note-trash">删除</button><button id="note-md">送入 Markdown</button></div></div>` : ""}`;
}

function settingsPanel() {
  const engines = state.engines || {};
  return `<h2>设置</h2><p class="muted">设置保存在本机资料目录，不上传。</p>
    <label>外观<select id="appearance"><option>system</option><option>light</option><option>dark</option></select></label>
    <label>LaTeX 引擎<select id="engine"><option>auto</option><option>tectonic</option><option>xelatex</option><option>pdflatex</option><option>lualatex</option></select></label>
    <button id="save-settings">保存设置</button>
    <ul>${Object.entries(engines).map(([name, found]) => `<li>${h(name)}：${found ? "已在 PATH 中" : "未找到"}</li>`).join("")}</ul>
    <p class="muted">Windows 版不附带 Tectonic 和宏包，也不会联网下载。tectonic 会以 --only-cached 调用。</p>`;
}

function filesPanel() {
  return `<h2>文件夹</h2><p class="muted">这是本机目录浏览，不是 macOS 文件整理索引，也不会移动或关联文件。</p>
    <ul class="list">${(state.entries || []).map((item) => `<li><button data-open="${h(item.path)}" style="padding-left:${8 + item.depth * 14}px">${item.directory ? "📁 " : ""}${h(item.name)}</button></li>`).join("") || "<li class='muted'>先在左侧打开一个文件夹。</li>"}</ul>`;
}

function bind() {
  document.querySelectorAll("[data-go]").forEach((node) => node.onclick = () => { view = node.dataset.go; render(); });
  document.querySelectorAll("[data-tab]").forEach((node) => node.onclick = async () => {
    view = "editor";
    await api("/api/tabs/select", {id: node.dataset.tab});
    render();
  });
  document.querySelectorAll("[data-open]").forEach((node) => node.onclick = () => openPath(node.dataset.open));
  document.querySelectorAll("[data-card]").forEach((node) => node.onclick = () => card(node.dataset.card));
  document.querySelectorAll("[data-close]").forEach((node) => node.onclick = () => closeTab(node.dataset.close));
  document.querySelectorAll("[data-external]").forEach((node) => node.onclick = () => api("/api/external", {path: node.dataset.external}).catch(fail));
  document.querySelectorAll("[data-page]").forEach((node) => node.onclick = () => { pdfPage = Number(node.dataset.page); render(); });
  document.querySelectorAll("[data-note]").forEach((node) => node.onclick = () => { noteId = node.dataset.note; render(); });
  document.querySelectorAll("[data-restore]").forEach((node) => node.onclick = async () => { await api("/api/notes/restore", {id: node.dataset.restore}); render(); });
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
  const preview = document.getElementById("preview");
  if (preview && selected()) api("/api/tabs/preview", {id: selected().id}).then((payload) => {
    preview.innerHTML = payload.result.html;
    const tabId = selected().id;
    preview.querySelectorAll("img[data-rel]").forEach((img) => {
      img.src = `/api/media?tab=${encodeURIComponent(tabId)}&token=${encodeURIComponent(token)}&rel=${encodeURIComponent(img.dataset.rel)}`;
    });
  }).catch(fail);
  const toggle = document.getElementById("toggle-split");
  if (toggle) toggle.onclick = () => { markdownSplit = !markdownSplit; render(); };
  const compile = document.getElementById("compile");
  if (compile) compile.onclick = () => api("/api/tabs/compile", {id: selected().id}).then(() => { view = "editor"; render(); }).catch(fail);
  const outline = document.getElementById("outline");
  if (outline) outline.onclick = () => showLatex();
  const complete = document.getElementById("complete");
  if (complete) complete.onclick = () => completeLatex();
  const grid = document.getElementById("csv-grid");
  if (grid) grid.onclick = () => showGrid();
  const csvMd = document.getElementById("csv-md");
  if (csvMd) csvMd.onclick = () => copyMarkdown();
  const rotate = document.getElementById("rotate");
  if (rotate) rotate.onclick = () => pdf("rotate", {pages: [pdfPage], degrees: Number(prompt("旋转角度", "90") || 90)});
  const crop = document.getElementById("crop");
  if (crop) crop.onclick = () => {
    const box = (prompt("裁剪 left,bottom,right,top", "0,0,400,400") || "").split(",").map(Number);
    pdf("crop", {pages: [pdfPage], box});
  };
  const remove = document.getElementById("pdf-delete");
  if (remove) remove.onclick = () => pdf("delete", {pages: [pdfPage]});
  const reorder = document.getElementById("reorder");
  if (reorder) reorder.onclick = () => pdf("reorder", {order: (prompt("页序，从 0 开始，例如 1,0", "0") || "").split(",").map(Number)});
  const merge = document.getElementById("merge");
  if (merge) merge.onclick = () => { const path = prompt("要合并进来的 PDF 路径"); if (path) pdf("merge", {path}); };
  const extract = document.getElementById("extract");
  if (extract) extract.onclick = () => { const path = prompt("提取到新 PDF 的路径"); if (path) pdf("extract", {pages: [pdfPage], path}); };
  const split = document.getElementById("split");
  if (split) split.onclick = () => { const directory = prompt("拆分到空目录"); if (directory) pdf("split", {directory}); };
  const imageStamp = document.getElementById("image-stamp");
  if (imageStamp) imageStamp.onclick = () => {
    const path = prompt("PNG 或 JPEG 的路径");
    if (path) pdf("image-file", {page: pdfPage, path, x: 72, y: 72, width: 160, height: 120});
  };
  const undo = document.getElementById("undo");
  if (undo) undo.onclick = () => pdf("undo", {});
  const redo = document.getElementById("redo");
  if (redo) redo.onclick = () => pdf("redo", {});
  const stamp = document.getElementById("stamp");
  if (stamp) stamp.onclick = () => {
    const text = prompt("只用英文、数字和标点。中文不能嵌入 Helvetica。", "Note");
    if (text) pdf("text", {page: pdfPage, text, x: 72, y: 700});
  };
  const search = document.getElementById("pdf-search");
  if (search) search.onclick = async () => {
    const query = prompt("搜索 PDF 文字");
    if (!query) return;
    const payload = await api("/api/tabs/pdf", {id: selected().id, op: "search", query});
    message = (payload.result.matches || []).map((item) => `第 ${item.page} 页 ${item.excerpt}`).join("\n") || "没有匹配。";
    render();
  };
  const prev = document.getElementById("pdf-prev");
  if (prev) prev.onclick = () => { pdfPage = Math.max(0, pdfPage - 1); render(); };
  const next = document.getElementById("pdf-next");
  if (next) next.onclick = () => { pdfPage += 1; render(); };
  const spreadButton = document.getElementById("spread");
  if (spreadButton) spreadButton.onclick = () => { spread = !spread; render(); };
  const noteNew = document.getElementById("note-new");
  if (noteNew) noteNew.onclick = async () => { const payload = await api("/api/notes/create", {title: "便笺", plain: "", html: ""}); noteId = payload.result.id; render(); };
  const noteSave = document.getElementById("note-save");
  if (noteSave) noteSave.onclick = saveNote;
  const noteTrash = document.getElementById("note-trash");
  if (noteTrash) noteTrash.onclick = async () => { await api("/api/notes/trash", {id: noteId}); render(); };
  const noteMd = document.getElementById("note-md");
  if (noteMd) noteMd.onclick = async () => { await api("/api/notes/to-markdown", {id: noteId}); view = "editor"; render(); };
  const settings = document.getElementById("save-settings");
  if (settings) settings.onclick = async () => {
    await api("/api/settings", {appearance: document.getElementById("appearance").value, latexEngine: document.getElementById("engine").value});
    applyTheme();
    message = "设置已保存";
    render();
  };
  const appearance = document.getElementById("appearance");
  if (appearance) appearance.value = state.settings.appearance;
  const engine = document.getElementById("engine");
  if (engine) engine.value = state.settings.latexEngine;
  const exportHtml = document.getElementById("export-html");
  if (exportHtml) exportHtml.onclick = () => exportAs("/api/export/html", ".html");
  const exportPdf = document.getElementById("export-pdf");
  if (exportPdf) exportPdf.onclick = () => exportAs("/api/export/pdf", ".pdf");
  const recovery = document.getElementById("export-recovery");
  if (recovery) recovery.onclick = async () => {
    const path = prompt("导出为新文件的完整路径");
    if (!path) return;
    await api("/api/office/export-recovery", {id: selected().id, path}).catch(fail);
  };
  const reload = document.getElementById("reload");
  if (reload) reload.onclick = () => openPath(selected().path);
  const find = document.getElementById("find");
  if (find) find.onclick = () => {
    const query = prompt("查找");
    const editorNode = document.querySelector("textarea.editor");
    const at = editorNode.value.indexOf(query || "");
    if (at >= 0) { editorNode.focus(); editorNode.selectionStart = at; editorNode.selectionEnd = at + (query || "").length; }
  };
}

async function card(id) {
  if (id === "notes") { view = "notes"; render(); return; }
  if (id === "office") { message = "从左侧输入或选择 Word、Excel、PPT 文件。查看器不会改写原件。"; view = "home"; render(); return; }
  if (id === "pdf") { message = "打开 PDF 后可以搜索文字、旋转、裁剪、排序、合并和叠加。没有页面缩略图。"; view = "home"; render(); return; }
  view = "editor";
  await api("/api/tabs/new", {kind: id});
  render();
}

async function openPath(path) {
  if (!path) return;
  try {
    const payload = await api("/api/tabs/open", {path});
    if (payload.code === "folder" || payload.state?.folder && path.endsWith && false) view = "files";
    if (!payload.result?.id) view = "files";
    else view = "editor";
    message = "";
    render();
  } catch (error) {
    if (String(error.message).includes("已打开文件夹")) { view = "files"; message = ""; render(); return; }
    fail(error);
  }
}

async function pick(mode) {
  try {
    const payload = await api("/api/dialog", {mode});
    if (mode === "folder") await api("/api/folder", {path: payload.result.path});
    else await openPath(payload.result.path);
    view = mode === "folder" ? "files" : "editor";
    render();
  } catch (error) { fail(error); }
}

let editTimer = 0;
function edit(node) {
  clearTimeout(editTimer);
  editTimer = setTimeout(async () => {
    const tab = selected();
    if (!tab) return;
    const body = {id: tab.id, text: node.value};
    if (tab.kind === "richText") body.html = node.value.replace(/[&<>]/g, (char) => ({"&":"&amp;","<":"&lt;",">":"&gt;"}[char])).replaceAll("\n", "<br>");
    try { await api("/api/tabs/edit", body); document.getElementById("status").textContent = state.status; }
    catch (error) { fail(error); }
  }, 350);
}

async function saveTab(asCopy) {
  const tab = selected();
  let path = tab.path;
  if (asCopy || !path) path = prompt("保存路径", path || tab.title);
  if (!path) return;
  try { await api("/api/tabs/save", {id: tab.id, path, asCopy}); message = state.status; render(); }
  catch (error) { fail(error); }
}

async function closeTab(id) {
  const tab = state.tabs.find((item) => item.id === id);
  try {
    await api("/api/tabs/close", {id, discard: false});
  } catch (error) {
    if (!String(error.message).includes("未保存")) return fail(error);
    const choice = prompt("输入 save、discard 或 cancel", "save");
    if (choice === "save") { await saveTab(false); await api("/api/tabs/close", {id, discard: false}); }
    else if (choice === "discard") await api("/api/tabs/close", {id, discard: true});
    else return;
  }
  view = state.selection ? "editor" : "home";
  render();
}

async function showLatex() {
  const payload = await api("/api/tabs/preview", {id: selected().id});
  const nodes = payload.result.index.nodes.map((node) => `${node.line}  ${node.kind}  ${node.title}`).join("\n");
  document.getElementById("side").innerHTML = `<pre class="page-text">${h(nodes)}</pre>`;
}

async function completeLatex() {
  const node = document.querySelector("textarea.editor");
  const payload = await api("/api/tabs/complete", {id: selected().id, cursor: node.selectionStart});
  const items = payload.result.items || [];
  if (!items.length) return;
  const insert = items[0].insert;
  const start = payload.result.start;
  node.value = node.value.slice(0, start) + insert + node.value.slice(node.selectionStart);
  await api("/api/tabs/edit", {id: selected().id, text: node.value});
}

async function showGrid() {
  const payload = await api("/api/tabs/preview", {id: selected().id});
  const rows = payload.result.rows || [];
  document.getElementById("grid").innerHTML = `<table class="grid">${rows.map((row, r) => `<tr>${row.map((cell, c) => `<td><input data-r="${r}" data-c="${c}" value="${h(cell)}"></td>`).join("")}</tr>`).join("")}</table><div class="row"><button id="grid-save">写回源码</button><button id="grid-sort">按列排序</button><button id="grid-filter">筛选</button></div>`;
  const readGrid = () => {
    const next = rows.map((row) => row.slice());
    document.querySelectorAll("#grid input").forEach((input) => { next[input.dataset.r][input.dataset.c] = input.value; });
    return next;
  };
  document.getElementById("grid-save").onclick = async () => {
    await api("/api/tabs/csv", {id: selected().id, rows: readGrid()});
    render();
  };
  document.getElementById("grid-sort").onclick = async () => {
    const column = Number(prompt("按哪一列排序（从 0 开始）", "0") || 0);
    const next = readGrid();
    const header = next[0];
    const body = next.slice(1).sort((a, b) => String(a[column] ?? "").localeCompare(String(b[column] ?? ""), "zh"));
    await api("/api/tabs/csv", {id: selected().id, rows: [header, ...body]});
    render();
  };
  document.getElementById("grid-filter").onclick = () => {
    const query = prompt("只显示包含这些文字的行", "") || "";
    document.querySelectorAll("#grid tr").forEach((row, index) => {
      if (index === 0) return;
      row.hidden = query && !row.textContent.includes(query);
    });
  };
}

async function copyMarkdown() {
  const payload = await api("/api/tabs/preview", {id: selected().id});
  await navigator.clipboard?.writeText(payload.result.markdown);
  message = "已复制 Markdown 表格";
  render();
}

async function pdf(op, extra) {
  try { await api("/api/tabs/pdf", {id: selected().id, op, ...extra}); render(); }
  catch (error) { fail(error); }
}

async function exportAs(endpoint, extension) {
  const path = prompt("导出到新文件", (selected().path || "导出") + extension);
  if (!path) return;
  const payload = await api(endpoint, {id: selected().id, path}).catch(fail);
  if (payload?.result?.degraded) message = "PDF 使用内置英文字体，非 ASCII 字符已替换为问号。排版导出请用 HTML。";
  render();
}

async function saveNote() {
  const plain = document.getElementById("note-body").value;
  const html = plain.replace(/[&<>]/g, (char) => ({"&":"&amp;","<":"&lt;",">":"&gt;"}[char])).replaceAll("\n", "<br>");
  await api("/api/notes/update", {id: noteId, plain, html});
  await api("/api/notes/metadata", {id: noteId, changes: {title: document.getElementById("note-title").value, group: document.getElementById("note-group").value, color: document.getElementById("note-color").value}});
  render();
}

function fail(error) {
  message = error.message || String(error);
  render();
}

document.addEventListener("keydown", (event) => {
  if ((event.ctrlKey || event.metaKey) && event.key.toLowerCase() === "s") { event.preventDefault(); saveTab(false); }
  if ((event.ctrlKey || event.metaKey) && event.key === "1") { view = "home"; render(); }
  if ((event.ctrlKey || event.metaKey) && event.key === "2") { view = "notes"; render(); }
});

refresh().catch(fail);
