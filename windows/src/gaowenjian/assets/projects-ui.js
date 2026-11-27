const projectMainPattern = /\.(md|markdown|mdown|mkd|tex|ltx)$/i;

function activeProject() {
  return state?.projects?.items.find((item) => item.id === state.projects.active);
}

function projectFileName(path) {
  return path.split(/[\\/]/).filter(Boolean).at(-1) || path;
}

function projectFolderLabel(path) {
  const parts = path.split(/[\\/]/).filter(Boolean);
  return (parts.length > 2 ? "…\\" : "") + parts.slice(-2).join("\\");
}

function projectContains(folder, path) {
  const normalize = (value) => value.replaceAll("\\", "/").replace(/\/+$/, "").toLowerCase();
  return Boolean(folder && path && normalize(path).startsWith(normalize(folder) + "/"));
}

function projectMainForTab(tab) {
  const project = activeProject();
  return project && /\.tex$/i.test(project.main) && projectContains(project.folder, tab.path) ? project.main : "";
}

function projectHomeShortcut() {
  const projects = state.projects;
  const last = projects?.items.find((item) => item.id === projects.lastOpened);
  const current = activeProject();
  return `<div class="project-home-shortcut">
    <button type="button" data-go="projects">${icon("project")} 写作项目</button>
    ${current ? `<span title="${h(current.folder)}">${h(current.name)}</span><button type="button" data-project-checkpoint>保存项目会话</button>` :
      last ? `<button type="button" class="plain project-resume" data-project-open="${h(last.id)}" title="继续 ${h(last.name)}">继续 ${h(last.name)}</button>` : ""}
  </div>`;
}

function projectsPanel() {
  const projects = state.projects;
  if (!projects) return "";
  const current = activeProject();
  const unavailable = projects.issues || [];
  return `<section class="projects-panel" aria-labelledby="projects-heading">
    <header class="projects-heading">
      <div><h1 id="projects-heading">写作项目</h1><p>保存项目目录、主文件、打开的文档和 PDF 阅读位置。</p></div>
      <div class="projects-actions">${current ? '<button type="button" data-project-checkpoint>保存项目会话</button>' : ""}<button type="button" class="primary" data-project-new ${projects.blocked ? "disabled" : ""}>${icon("add")} 新建项目</button></div>
    </header>
    ${projects.blocked ? `<div class="banner warn" role="alert">${h(projects.blocked)}</div>` : ""}
    ${unavailable.length ? `<details class="project-issues" open><summary>有 ${unavailable.length} 项无法打开，已有草稿已保留</summary><ul>
      ${unavailable.map((item) => `<li><strong title="${h(item.path)}">${h(projectFileName(item.path))}</strong> <span>${h(item.message)}</span></li>`).join("")}
    </ul>${current ? `<button type="button" data-project-open="${h(current.id)}">重新检查文件</button>` : ""}</details>` : ""}
    ${projects.items.length ? `<ul class="project-list">${projects.items.map((item) => `<li class="project-card" ${item.id === projects.active ? 'data-active="true"' : ""}>
      <div class="project-card-icon">${icon("project")}</div>
      <div class="project-card-content"><h2>${h(item.name)}</h2><span class="project-disk-path" title="${h(item.folder)}">${h(projectFolderLabel(item.folder))}</span>
        <span class="project-card-info" title="${h(item.main)}">${h(projectFileName(item.main))} · ${item.documents.length} 项会话记录</span></div>
      <div class="project-card-actions">${item.id === current?.id ? '<button type="button" data-project-edit>项目设置</button><button type="button" data-project-return>返回文档</button>' :
        `<button type="button" data-project-open="${h(item.id)}">打开项目 ${icon("arrow")}</button>`}</div>
    </li>`).join("")}</ul>` : `<div class="project-empty">${icon("project")}<div><h2>暂无项目</h2><p>打开项目文稿和资料，然后新建项目保存当前会话。</p></div></div>`}
  </section>`;
}

async function projectReadingPositions() {
  const independent = await window.pywebview?.api?.capture_project_readers?.() || {};
  const result = {};
  for (const tab of state.tabs) {
    if (tab.kind === "pdf" && pdfViews.has(tab.id)) {
      const pdf = pdfView(tab);
      result[tab.id] = {page: pdf.page, offset: pdf.offset || 0};
    } else if (tab.kind === "latex") {
      result[tab.id] = {};
      if (writingSessions.has(tab.id)) result[tab.id].previewPage = writingSession(tab.id).page;
      if (Number.isInteger(independent[tab.id])) result[tab.id].readerPage = independent[tab.id];
    }
  }
  return result;
}

async function checkpointProject() {
  if (activeProject()) await api("/api/projects/checkpoint", {reading: await projectReadingPositions()});
}

function projectSwitchChoice(dirty) {
  const dialog = document.createElement("dialog");
  dialog.className = "document-dialog project-dialog";
  dialog.setAttribute("aria-labelledby", "switch-project-heading");
  dialog.innerHTML = `<form method="dialog">
    <h2 id="switch-project-heading">有 ${dirty.length} 个文档未保存</h2>
    <p>可以先保存文件，也可以切换项目并让草稿继续留在标签栏。</p>
    <div class="project-dialog-actions"><button value="cancel" autofocus>取消</button><button value="keep">保留草稿并切换</button><button class="primary" value="save">全部保存并切换</button></div>
  </form>`;
  return new Promise((resolve) => {
    dialog.addEventListener("close", () => { resolve(dialog.returnValue); dialog.remove(); }, {once: true});
    document.body.append(dialog);
    dialog.showModal();
  });
}

async function openProject(id) {
  if (!(await leaveCurrent())) return;
  const dirty = state.tabs.filter((tab) => tab.dirty);
  let drafts = "require-saved";
  if (dirty.length) {
    const choice = await projectSwitchChoice(dirty);
    if (choice === "save") {
      for (const tab of dirty) if (!(await saveDocument(tab))) return;
    } else if (choice === "keep") drafts = "keep";
    else return;
  }
  const {result} = await api("/api/projects/restore", {id, drafts, reading: await projectReadingPositions()});
  browserVisible = false;
  for (const tab of state.tabs) {
    const saved = tab.projectReading || {};
    if (tab.kind === "pdf" && Number.isInteger(saved.page)) {
      Object.assign(pdfView(tab), {page: saved.page, offset: saved.offset || 0, scroll: 0, jump: true, restoreOffset: saved.offset || 0});
    } else if (tab.kind === "latex") {
      const session = writingSession(tab.id);
      if (projectMainForTab(tab)) delete session.main;
      if (Number.isInteger(saved.previewPage)) {
        session.page = saved.previewPage;
        session.restoreProjectPage = !tab.preview?.pages?.length;
      }
    }
  }
  await window.pywebview?.api?.sync_project_readers?.();
  view = state.selection ? "editor" : "projects";
  errorNotice = "";
  if (result.issues.length) {
    const names = result.issues.slice(0, 3).map((item) => projectFileName(item.path)).join("、");
    message = `${result.issues.length} 项无法打开（${names}${result.issues.length > 3 ? "等" : ""}）。已有草稿已保留，可在写作项目查看详情。`;
    errorNotice = message;
  } else message = result.keptDrafts ? `已保留 ${result.keptDrafts} 个未保存草稿。` : "";
  render();
}

function configureProject(item = null) {
  const folder = item?.folder || state.folder || "";
  const active = selected();
  const main = item?.main || (projectContains(folder, active?.path) && projectMainPattern.test(active.path) ? active.path : "");
  const choices = state.tabs.filter((tab) => tab.path && projectMainPattern.test(tab.path));
  const dialog = document.createElement("dialog");
  dialog.className = "document-dialog project-dialog";
  dialog.setAttribute("aria-labelledby", "project-configuration-heading");
  dialog.innerHTML = `<form>
    <h2 id="project-configuration-heading">${item ? "项目设置" : "新建写作项目"}</h2>
    <label class="project-field" for="project-name">项目名称</label><input id="project-name" type="text" value="${h(item?.name || projectFileName(folder))}" required maxlength="120" autofocus>
    <label class="project-field" for="project-folder">项目目录</label><div class="project-path-field"><input id="project-folder" type="text" value="${h(folder)}" required><button type="button" data-project-pick="folder">选择目录…</button></div>
    <label class="project-field" for="project-main">Markdown 或 LaTeX 主文件</label><div class="project-path-field"><input id="project-main" type="text" list="project-open-documents" value="${h(main)}" required><button type="button" data-project-pick="main">选择文件…</button></div>
    <datalist id="project-open-documents">${choices.map((tab) => `<option value="${h(tab.path)}"></option>`).join("")}</datalist>
    <p class="project-form-error" role="alert" hidden></p>
    <div class="project-dialog-actions"><button type="button" data-project-cancel>取消</button><button type="submit" class="primary">保存项目会话</button></div>
  </form>`;
  dialog.addEventListener("close", () => dialog.remove(), {once: true});
  const field = (name) => dialog.querySelector("#project-" + name);
  const problem = dialog.querySelector(".project-form-error");
  const explain = (error) => { problem.textContent = error.message; problem.hidden = false; };
  dialog.querySelectorAll("[data-project-pick]").forEach((button) => { button.onclick = async () => {
    const type = button.dataset.projectPick;
    try {
      const path = await fileDialog(type === "folder" ? "folder" : "open");
      if (!path) return;
      field(type).value = path;
      if (type === "folder" && !field("name").value.trim()) field("name").value = projectFileName(path);
    } catch (error) { explain(error); }
  }; });
  dialog.querySelector("[data-project-cancel]").onclick = () => dialog.close();
  dialog.querySelector("form").onsubmit = async (event) => {
    event.preventDefault();
    const submit = dialog.querySelector("button[type=submit]");
    submit.disabled = true;
    problem.hidden = true;
    try {
      if (!(await leaveCurrent())) return;
      await api("/api/projects/save", {id: item?.id, name: field("name").value, folder: field("folder").value,
        main: field("main").value, reading: await projectReadingPositions()});
      dialog.close();
      message = "项目会话已保存。";
      errorNotice = "";
      render();
    } catch (error) { explain(error); }
    finally { submit.disabled = false; }
  };
  document.body.append(dialog);
  dialog.showModal();
}

function bindProjects() {
  document.querySelectorAll("[data-project-open]").forEach((button) => { button.onclick = () => openProject(button.dataset.projectOpen).catch(fail); });
  document.querySelector("[data-project-new]")?.addEventListener("click", () => configureProject());
  document.querySelector("[data-project-edit]")?.addEventListener("click", () => configureProject(activeProject()));
  document.querySelector("[data-project-return]")?.addEventListener("click", () => navigate(state.selection ? "editor" : "home").catch(fail));
  document.querySelectorAll("[data-project-checkpoint]").forEach((button) => { button.onclick = async () => {
    try {
      if (!(await leaveCurrent())) return;
      await checkpointProject();
      message = "项目会话已保存。";
      errorNotice = "";
      render();
    } catch (error) { fail(error); }
  }; });
}
