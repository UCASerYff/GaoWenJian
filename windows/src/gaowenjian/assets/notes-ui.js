const noteColors = {yellow: "黄色", blue: "蓝色", green: "绿色", pink: "粉色", purple: "紫色", gray: "灰色"};
const noteFilter = {query: "", group: "", color: "", sort: "updated", trash: false};
const noteEvents = new BroadcastChannel("gaowenjian-notes");
let noteDraft = null;
let noteTimeout = 0;
let noteWrite = Promise.resolve(true);
const desktopNoteId = new URLSearchParams(location.search).get("id");

function filteredNotes() {
  const query = noteFilter.query.toLocaleLowerCase();
  return state.notes.notes.filter((item) => Boolean(item.deletedAt) === noteFilter.trash
    && (!noteFilter.group || item.group === noteFilter.group)
    && (!noteFilter.color || item.color === noteFilter.color)
    && [item.title, item.group, item.plainText].some((text) => text.toLocaleLowerCase().includes(query)))
    .sort((a, b) => noteFilter.sort === "title" ? a.title.localeCompare(b.title, "zh-CN")
      : String(b[noteFilter.sort + "At"]).localeCompare(String(a[noteFilter.sort + "At"])));
}

function noteOptions(options, selected) {
  return Object.entries(options).map(([value, label]) => `<option value="${h(value)}" ${value === selected ? "selected" : ""}>${h(label)}</option>`).join("");
}

function notesPanel() {
  const {notes, readOnly, blocked} = state.notes;
  const matches = filteredNotes();
  const active = matches.find((item) => item.id === noteId) || matches[0];
  noteId = active?.id || null;
  const groups = [...new Set(notes.filter((item) => !item.deletedAt && item.group).map((item) => item.group))].sort();
  const hasDesktop = notes.some((item) => item.isOnDesktop && !item.deletedAt);
  return `<div class="notes-workspace">
    <header class="notes-header"><h1>便笺</h1><div class="row">
      <details class="action-menu align-right"><summary>${icon("more")}<span class="visually-hidden">便笺管理</span></summary><div><button id="notes-arrange" ${hasDesktop ? "" : "disabled"}>排列桌面便笺</button><button id="notes-import" ${readOnly ? "disabled" : ""}>导入便笺…</button></div></details>
      <button id="note-new" class="primary" ${readOnly ? "disabled" : ""}>${icon("add")} 新建便笺</button></div></header>
    ${blocked ? workspaceNotice(blocked, true) : ""}
    <div class="notes-grid"><aside class="notes-browser" aria-label="便笺列表">
      <div class="notes-browser-head"><strong>${noteFilter.trash ? "回收站" : "全部便笺"}</strong><small id="notes-count" aria-live="polite">${matches.length} 条</small></div>
      <label class="notes-search">${icon("search")}<input id="note-search" type="search" aria-label="搜索便笺" placeholder="搜索便笺" value="${h(noteFilter.query)}"></label>
      <details class="notes-filter" ${noteFilter.group || noteFilter.color || noteFilter.sort !== "updated" ? "open" : ""}><summary>筛选与排序 ${icon("chevron")}</summary>
        <div class="notes-filters"><select id="notes-group" aria-label="分组">${noteOptions({"": "全部分组", ...Object.fromEntries(groups.map((group) => [group, group]))}, noteFilter.group)}</select><select id="notes-color" aria-label="颜色">${noteOptions({"": "全部颜色", ...noteColors}, noteFilter.color)}</select><select id="notes-sort" aria-label="排序">${noteOptions({updated: "最近编辑", created: "新建时间", title: "标题"}, noteFilter.sort)}</select></div></details>
      <div id="note-list">${noteCards(matches)}</div>
      <button id="notes-trash-view" class="plain">${noteFilter.trash ? `${icon("notes")} 返回全部便笺` : `${icon("restore")} 回收站 (${notes.filter((item) => item.deletedAt).length})`}</button>
    </aside><div id="note-detail" class="note-detail">${active ? noteEditor(active) : noteEmpty(readOnly)}</div></div></div>`;
}

function noteCards(matches) {
  return matches.map((note) => `<button class="note-card note-${h(note.color)} ${note.id === noteId ? "selected" : ""}" data-note="${h(note.id)}" ${note.id === noteId ? 'aria-current="true"' : ""}><span class="note-card-title"><b>${h(note.title || "未命名便笺")}</b>${note.isPinned || note.isOnDesktop ? `<span title="${note.isPinned ? "置顶" : "桌面便笺"}">${icon(note.isPinned ? "pin" : "notes")}</span>` : ""}</span><span class="note-excerpt">${h(note.plainText.trim().slice(0, 115) || "空白便笺")}</span><small><span>${h(note.group || "未分组")}</span><time>${h(shortDate(note.updatedAt))}</time></small></button>`).join("") || `<p class="muted note-no-results">${noteFilter.trash ? "回收站为空" : "没有找到便笺"}</p>`;
}

function shortDate(value) {
  const date = new Date(value);
  return Number.isNaN(date.valueOf()) ? "" : date.toLocaleDateString("zh-CN");
}

function noteEmpty(readOnly) {
  return `<div class="note-empty">${icon("notes")}<h2>${noteFilter.trash ? "回收站为空" : "未选择便笺"}</h2>${readOnly || noteFilter.trash ? "" : '<button id="note-empty-new">新建便笺</button>'}</div>`;
}

function noteEditor(note, desktop = false) {
  const draft = noteDraft?.id === note.id ? noteDraft : null;
  const editable = note.editable;
  const title = `<input type="text" id="note-title" maxlength="512" aria-label="便笺标题" placeholder="未命名便笺" value="${h(draft?.changes.title ?? note.title)}" ${editable ? "" : "readonly"}>`;
  const fields = `<label>分组<input type="text" id="note-group" maxlength="512" value="${h(draft?.changes.group ?? note.group)}" placeholder="无分组" ${editable ? "" : "readonly"}></label>
         <label>颜色<select id="note-color" ${editable ? "" : "disabled"}>${noteOptions(noteColors, draft?.changes.color ?? note.color)}</select></label>`;
  const toggles = editable ? `<div class="row note-toggles"><button data-note-toggle="isPinned" aria-pressed="${note.isPinned}">${icon("pin")} 置顶</button><button data-note-toggle="isTranslucent" aria-pressed="${note.isTranslucent}">半透明</button><button data-note-toggle="isCollapsed" aria-pressed="${note.isCollapsed}">折叠</button></div>` : "";
  const formats = editable ? `<div class="note-format-buttons" aria-label="格式"><button class="symbol-button" data-note-command="bold" aria-label="粗体" title="粗体"><b>B</b></button><button class="symbol-button" data-note-command="italic" aria-label="斜体" title="斜体"><i>I</i></button><button class="symbol-button" data-note-command="underline" aria-label="下划线" title="下划线"><u>U</u></button><button id="note-attach" class="plain">${icon("add")} 附件</button></div>` : "";
  const options = `<details class="action-menu align-right note-options"><summary title="便笺选项" aria-label="便笺选项">${icon("more")}</summary><div>
    <div class="note-properties">${desktop ? `<label>标题${title}</label>` : ""}${fields}${toggles}</div><button id="note-md">在 Markdown 打开</button>
    ${["txt", "rtf", "rtfd"].map((format) => `<button data-note-export="${format}">导出 ${format.toUpperCase()}…</button>`).join("")}
    ${editable ? '<button class="note-delete" id="note-trash">移到回收站</button>' : ""}</div></details>`;
  const top = desktop ? "" : `<div class="note-title-row">${title}
     ${note.deletedAt && !state.notes.readOnly ? '<button id="note-restore">恢复便笺</button>' : ""}
     ${editable ? `<button id="note-desktop" class="plain">${icon("notes")} ${note.isOnDesktop ? "显示桌面便笺" : "放到桌面"}</button>` : ""}</div>`;
  return `<article class="note-paper note-${h(note.color)}" data-note-editor="${h(note.id)}">${top}
    <div class="note-format">${formats}<span class="row-spacer"></span>${options}</div>
    <div id="note-body" class="note-body" role="textbox" aria-label="便笺正文" aria-multiline="true" contenteditable="${editable}" style="--note-size:${Number(state.notes.defaults.fontSize) || 15}px"></div>
    ${note.attachments.length ? `<div class="row note-attachments">${note.attachments.map((name, index) => `<button data-note-attachment="${index}">${h(name)}</button>`).join("")}</div>` : ""}
    <footer class="note-status"><span id="note-status" role="status">${editable ? "已保存到本机" : "只读"}</span></footer>
  </article>`;
}

function sanitizedNoteHTML(fragment) {
  const source = new DOMParser().parseFromString(fragment, "text/html");
  const target = document.createElement("div");
  function append(node, destination) {
    if (node.nodeType === Node.TEXT_NODE) { destination.append(document.createTextNode(node.textContent)); return; }
    const tag = node.tagName;
    if (!tag || ["SCRIPT", "STYLE", "IFRAME", "OBJECT", "SVG", "MATH", "TEMPLATE", "IMG"].includes(tag)) return;
    const element = ["P", "DIV", "BR", "B", "I", "U", "STRONG", "EM"].includes(tag) ? document.createElement(tag) : destination;
    for (const child of node.childNodes) append(child, element);
    if (element !== destination) destination.append(element);
  }
  for (const child of source.body.childNodes) append(child, target);
  return target.innerHTML;
}

function updateNoteDraft(note) {
  const body = document.getElementById("note-body");
  const latest = state.notes.notes.find((item) => item.id === note.id);
  noteDraft = {id: note.id, expected: noteDraft?.expected ?? latest?.bodyDigest ?? note.bodyDigest, html: sanitizedNoteHTML(body.innerHTML),
    plain: body.innerText, changes: {title: document.getElementById("note-title").value,
      group: document.getElementById("note-group").value, color: document.getElementById("note-color").value}};
  const status = document.getElementById("note-status");
  if (status) status.textContent = "正在保存…";
  clearTimeout(noteTimeout);
  noteTimeout = setTimeout(flushNoteEdit, 450);
}

async function flushNoteEdit() {
  clearTimeout(noteTimeout);
  await noteWrite;
  const draft = noteDraft;
  if (!draft) return true;
  noteWrite = (async () => {
    try {
      await api("/api/notes/update", draft);
      if (noteDraft === draft) noteDraft = null;
      else if (noteDraft?.id === draft.id) noteDraft.expected = state.notes.notes.find((item) => item.id === draft.id)?.bodyDigest;
      if (surface === "workspace" && view === "notes") updateNoteList(false);
      noteEvents.postMessage({id: draft.id});
      const status = document.getElementById("note-status");
      if (status) status.textContent = noteDraft ? "正在保存…" : "已保存到本机";
      return true;
    } catch (error) {
      const status = document.getElementById("note-status");
      if (status) status.textContent = error.message;
      return false;
    }
  })();
  return noteWrite;
}

async function saveNote() {
  return flushNoteEdit();
}

function updateNoteList(updateDetail) {
  const matches = filteredNotes();
  const active = matches.find((item) => item.id === noteId) || matches[0];
  const changed = (active?.id || null) !== noteId;
  if (updateDetail) noteId = active?.id || null;
  const list = document.getElementById("note-list");
  if (!list) return;
  document.getElementById("notes-count").textContent = `${matches.length} 条`;
  list.innerHTML = noteCards(matches);
  list.querySelectorAll("[data-note]").forEach((button) => button.onclick = async () => {
    if (!(await flushNoteEdit())) return;
    noteId = button.dataset.note;
    render();
  });
  if (updateDetail && changed) {
    document.getElementById("note-detail").innerHTML = active ? noteEditor(active) : noteEmpty(state.notes.readOnly);
    bindNoteDetail(active);
  }
}

async function openNoteFile(mode, isDirectory = false) {
  if (!(await flushNoteEdit())) return;
  const path = await fileDialog(isDirectory ? "folder" : mode);
  if (!path) return;
  const response = await api("/api/notes/import", {path});
  noteFilter.trash = false;
  noteFilter.query = noteFilter.group = noteFilter.color = "";
  noteId = response.result.id;
  render();
}

function bindNotesWorkspace() {
  const create = async () => {
    if (!(await flushNoteEdit())) return;
    const response = await api("/api/notes/create", {});
    noteFilter.trash = false;
    noteFilter.query = noteFilter.group = noteFilter.color = "";
    noteId = response.result.id;
    render();
    document.getElementById("note-title")?.focus();
  };
  document.getElementById("note-new").onclick = () => create().catch(fail);
  document.getElementById("notes-trash-view").onclick = async () => {
    if (!(await flushNoteEdit())) return;
    noteFilter.trash = !noteFilter.trash;
    noteFilter.query = noteFilter.group = noteFilter.color = "";
    render();
  };
  document.getElementById("notes-import").onclick = async () => {
    const format = await chooseNoteImportMode();
    if (format) await openNoteFile("note-import", format === "rtfd");
  };
  document.getElementById("notes-arrange").onclick = () => window.pywebview?.api.arrange_notes();
  document.getElementById("notes-arrange").disabled ||= !window.pywebview?.api;
  document.getElementById("note-search").oninput = async (event) => {
    noteFilter.query = event.target.value;
    if (await flushNoteEdit()) updateNoteList(true);
  };
  for (const key of ["group", "color", "sort"]) {
    document.getElementById(`notes-${key}`).onchange = async (event) => {
      noteFilter[key] = event.target.value;
      if (await flushNoteEdit()) updateNoteList(true);
    };
  }
  updateNoteList(false);
  bindNoteDetail(state.notes.notes.find((item) => item.id === noteId));
}

function chooseNoteImportMode() {
  return new Promise((resolve) => {
    const dialog = document.createElement("dialog");
    dialog.className = "document-dialog";
    dialog.innerHTML = '<form method="dialog"><h2>导入便笺</h2><div class="row"><button value="text">TXT 或 RTF 文件</button><button value="rtfd">RTFD 文件夹</button><button value="">取消</button></div></form>';
    dialog.addEventListener("close", () => { resolve(dialog.returnValue); dialog.remove(); }, {once: true});
    document.body.append(dialog);
    dialog.showModal();
  });
}

function bindNoteDetail(note) {
  const on = (id, handler) => {
    const node = document.getElementById(id);
    if (node) node.onclick = () => Promise.resolve().then(handler).catch(fail);
  };
  on("note-empty-new", () => document.getElementById("note-new").click());
  if (!note) return;
  const body = document.getElementById("note-body");
  if (!body) return;
  const draft = noteDraft?.id === note.id ? noteDraft : null;
  body.innerHTML = sanitizedNoteHTML(draft?.html ?? (note.html || h(note.plainText).replaceAll("\n", "<br>")));
  if (note.editable) {
    for (const id of ["note-body", "note-title", "note-group", "note-color"]) {
      document.getElementById(id).oninput = () => updateNoteDraft(note);
    }
    body.onpaste = (event) => {
      event.preventDefault();
      document.execCommand("insertText", false, event.clipboardData.getData("text/plain"));
      updateNoteDraft(note);
    };
  }
  document.querySelectorAll("[data-note-command]").forEach((button) => {
    button.onmousedown = (event) => event.preventDefault();
    button.onclick = () => { body.focus(); document.execCommand(button.dataset.noteCommand); updateNoteDraft(note); };
  });
  document.querySelectorAll("[data-note-toggle]").forEach((button) => button.onclick = () => setNoteMetadata(note, {[button.dataset.noteToggle]: !note[button.dataset.noteToggle]}).catch(fail));
  on("note-desktop", async () => {
    if (!window.pywebview?.api) throw new Error("请从开始菜单启动搞文件以打开桌面便笺。");
    if (!(await setNoteMetadata(note, {isOnDesktop: true}))) return;
    await window.pywebview.api.show_note(note.id);
  });
  on("note-trash", async () => {
    if (!(await flushNoteEdit())) return;
    await api("/api/notes/trash", {id: note.id});
    noteEvents.postMessage({id: note.id});
    if (surface === "note") await window.pywebview?.api.close_note();
    else render();
  });
  on("note-restore", async () => {
    await api("/api/notes/restore", {id: note.id});
    noteEvents.postMessage({id: note.id});
    noteFilter.trash = false;
    render();
  });
  on("note-md", async () => {
    if (!(await flushNoteEdit())) return;
    await api("/api/notes/to-markdown", {id: note.id});
    noteEvents.postMessage({id: note.id, markdown: true});
    if (surface === "workspace") { view = "editor"; render(); }
    else await window.pywebview?.api.focus_workspace();
  });
  on("note-attach", async () => {
    if (!(await flushNoteEdit())) return;
    const path = await fileDialog("open");
    if (!path) return;
    await api("/api/notes/attach", {id: note.id, path});
    noteEvents.postMessage({id: note.id});
    render();
  });
  document.querySelectorAll("[data-note-attachment]").forEach((button) => button.onclick = async () => {
    const index = Number(button.dataset.noteAttachment);
    const path = await fileDialog("save", note.attachments[index]);
    if (path) await api("/api/notes/export-attachment", {id: note.id, index, path}).catch(fail);
  });
  document.querySelectorAll("[data-note-export]").forEach((button) => button.onclick = async () => {
    if (!(await flushNoteEdit())) return;
    const format = button.dataset.noteExport;
    const path = await fileDialog("save", `${(note.title || "便笺").replace(/[\\/:*?"<>|]/g, "_")}.${format}`);
    if (path) await api("/api/notes/export", {id: note.id, format, path}).catch(fail);
  });
}

async function setNoteMetadata(note, changes) {
  if (!(await flushNoteEdit())) return false;
  await api("/api/notes/metadata", {id: note.id, changes});
  noteEvents.postMessage({id: note.id});
  render();
  return true;
}

function renderDesktopNote() {
  const note = state.notes.notes.find((item) => item.id === desktopNoteId && !item.deletedAt);
  if (!note?.isOnDesktop) { window.pywebview?.api.close_note(); return; }
  app.innerHTML = `<div class="desktop-note note-${h(note.color)}" ${note.isCollapsed ? "data-collapsed" : ""}><header class="desktop-note-title pywebview-drag-region">${icon(note.isPinned ? "pin" : "notes")}<b>${h(note.title || "未命名便笺")}</b><button id="desktop-collapse" class="symbol-button" aria-label="${note.isCollapsed ? "展开" : "收起"}">${icon("chevron")}</button><button id="desktop-close" class="symbol-button" aria-label="关闭便笺">${icon("close")}</button></header>
    ${message ? `<p class="banner warn" role="alert">${h(message)}</p>` : ""}${note.isCollapsed ? "" : noteEditor(note, true)}</div>`;
  document.getElementById("desktop-close").onclick = () => hideDesktopNote().catch(fail);
  const collapse = () => setNoteMetadata(note, {isCollapsed: !note.isCollapsed}).catch(fail);
  document.getElementById("desktop-collapse").onclick = collapse;
  document.querySelector(".desktop-note-title").ondblclick = (event) => { if (!event.target.closest("button")) collapse(); };
  bindNoteDetail(note);
  window.pywebview?.api.apply_note_style();
}

async function hideDesktopNote() {
  if (!(await flushNoteEdit())) return;
  await api("/api/notes/metadata", {id: desktopNoteId, changes: {isOnDesktop: false}});
  noteEvents.postMessage({id: desktopNoteId});
  await window.pywebview?.api.close_note();
}

noteEvents.onmessage = async ({data}) => {
  if (!state || noteDraft) return;
  if (surface === "note" && data.id === desktopNoteId) await refresh();
  if (surface === "workspace" && (view === "notes" || data.markdown)) {
    if (data.markdown) view = "editor";
    await refresh();
  }
};
