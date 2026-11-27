let organizerData = null;
let organizerSection = "search";
let organizerResults = {items: [], offset: 0, more: false};
let organizerFilter = {query: "", extension: "", sort: "name", root: "", favorite: false, space: ""};
let associationExtension = ".pdf";
let associationResult = null;
let organizerLoaded = false;
let organizerBusy = false;
let organizerScanning = "";
const organizerDate = new Intl.DateTimeFormat("zh-CN", {dateStyle: "medium", timeStyle: "short"});

function organizerPanel() {
  const menu = [["search", "查找"], ["favorite", "收藏"], ["roots", "授权目录"], ["spaces", "工作区"], ["moves", "整理计划"], ["associations", "文件关联"]];
  return `<div class="doc-tools-page organizer-page">
    <div class="doc-tools-heading"><h1>文件整理与查找</h1>
      <p>在授权目录中查找文件，管理收藏、工作区与移动计划。</p></div>
    ${organizerData?.initialized ? `<nav class="organizer-nav" aria-label="文件整理">
      ${menu.map(([id, title]) => `<button data-organizer-section="${id}"${organizerSection === id ? ' aria-current="page"' : ""}>${title}</button>`).join("")}
    </nav>${organizerContent()}` : organizerIntro()}
  </div>`;
}

function organizerIntro() {
  if (!organizerLoaded) return '<div class="doc-tools-card"><p role="status">正在读取整理资料…</p></div>';
  if (!organizerData) return '<div class="doc-tools-card"><button id="organizer-reload">重新读取整理资料</button></div>';
  return `<div class="doc-tools-card organizer-intro">
    <span class="doc-file-icon" aria-hidden="true">${icon("organize")}</span>
    <h2>创建本机索引</h2>
    <p>创建后选择允许扫描的目录。扫描会记录文件名与修改时间等信息。</p>
    <div class="doc-tools-actions"><button class="doc-tools-primary" id="organizer-init">创建索引</button></div>
  </div>`;
}

function organizerContent() {
  if (organizerSection === "roots") {
    return `<div class="doc-tools-card organizer-list-card">
      <div class="doc-tools-card-bar"><h2>已授权目录</h2><button class="doc-tools-primary" id="organizer-authorize">${icon("add")} 添加目录…</button></div>
      <p class="doc-tools-hint">添加后手动扫描。撤销授权会移除该目录的索引条目。</p>
      ${organizerData.roots.length ? `<ul class="organizer-list">${organizerData.roots.map((root) => `<li class="organizer-entry">
        <span class="doc-file-icon" aria-hidden="true">${icon("folder")}</span>
        <div class="organizer-file"><strong>${h(organizerBaseName(root.path))}</strong>
          <span class="doc-truncate" title="${h(root.path)}">${h(root.path)}</span></div>
        <div class="doc-tools-actions">
          <button data-organizer-scan="${h(root.id)}"${organizerScanning ? " disabled" : ""}>${organizerScanning === root.id ? "扫描中…" : "扫描"}</button>
          <button class="doc-tools-quiet" data-organizer-revoke="${h(root.id)}"${organizerScanning ? " disabled" : ""}>撤销授权…</button>
        </div></li>`).join("")}</ul>` : '<div class="doc-tools-empty">尚未授权目录。</div>'}
    </div>`;
  }
  if (organizerSection === "moves") {
    const labels = {preview: "等待确认", moving: "等待核对", moved: "已完成", cancelled: "已取消"};
    return `<div class="doc-tools-card organizer-list-card">
      <div class="doc-tools-card-bar"><h2>移动与重命名</h2></div>
      ${organizerData.moves.length ? `<ul class="organizer-list">${organizerData.moves.map((item) => `<li class="organizer-move">
        <div class="doc-tools-card-bar"><strong class="doc-truncate" title="${h(item.destination)}">${h(organizerBaseName(item.destination))}</strong>
          <span class="doc-tools-state" data-state="${h(item.status)}">${h(labels[item.status] || item.status)}</span></div>
        <dl><dt>原位置</dt><dd>${h(item.source)}</dd><dt>目标位置</dt><dd>${h(item.destination)}</dd></dl>
        ${item.status === "preview" ? `<div class="doc-tools-actions">
          <button class="doc-tools-primary" data-organizer-execute="${h(item.id)}">确认执行…</button>
          <button data-organizer-cancel="${h(item.id)}">取消计划</button></div>` : ""}
        ${item.status === "moving" ? `<div class="doc-tools-actions">
          <button class="doc-tools-primary" data-organizer-recover="${h(item.id)}">核对实际位置</button></div>` : ""}
      </li>`).join("")}</ul>` : `<div class="doc-tools-empty">在查找结果的更多操作中，可为文件创建移动或重命名计划。
        <button data-organizer-section="search">前往查找</button></div>`}
    </div>`;
  }
  if (organizerSection === "associations") {
    const labels = {changed: "已核实更改", unchanged: "默认应用未改变", pending: "等待在 Windows 设置中完成", read: "已读取"};
    return `<div class="doc-tools-card organizer-list-card">
      <h2>Windows 默认应用</h2>
      <p class="doc-tools-hint">在 Windows 设置中更改默认应用，再返回核对结果。</p>
      <form id="organizer-association" class="organizer-association-form">
        <label class="doc-tools-field"><span>扩展名</span><input id="organizer-ext-choice" type="text" value="${h(associationExtension)}" required></label>
        <div class="doc-tools-actions">
          <button type="submit">读取当前设置</button><button type="button" class="doc-tools-primary" id="organizer-default-apps">打开 Windows 设置</button>
          <button type="button" id="organizer-confirm-association">核对设置结果</button></div>
      </form>
      ${associationResult ? `<div class="doc-tools-status" role="status">
        <strong>${h(associationResult.extension)} · ${h(labels[associationResult.status] || "")}</strong>
        <span>${h(associationResult.program || "没有注册默认处理程序")}</span></div>` : ""}
      ${organizerData.associations.length ? `<h3>更改记录</h3><ul class="organizer-list">${organizerData.associations.map((item) =>
        `<li class="organizer-history"><strong>${h(item.extension)}</strong> <span>${h(item.before + " → " + item.after)}</span><time>${h(item.changed)}</time></li>`).join("")}</ul>` : ""}
    </div>`;
  }
  if (organizerSection === "spaces") {
    const active = organizerData.spaces.find((item) => item.id === organizerFilter.space);
    return `<div class="organizer-workspace-grid">
      <div class="doc-tools-card organizer-list-card">
        <div class="doc-tools-card-bar"><h2>我的工作区</h2><button class="doc-tools-primary" id="organizer-space-new">${icon("add")} 新建…</button></div>
        ${organizerData.spaces.length ? `<ul class="organizer-list">${organizerData.spaces.map((item) => `<li class="organizer-workspace-item">
          <button class="doc-tools-quiet" data-organizer-space="${h(item.id)}"${active?.id === item.id ? ' aria-current="true"' : ""}>
            <span class="doc-truncate">${h(item.name)}</span></button>
          <button class="doc-tools-quiet doc-tools-icon" data-organizer-space-remove="${h(item.id)}" title="移除工作区" aria-label="移除工作区 ${h(item.name)}">${icon("close")}</button>
        </li>`).join("")}</ul>` : '<div class="doc-tools-empty">尚无工作区。</div>'}
      </div>
      ${active ? organizerItems(active.name) : `<div class="doc-tools-card">
        <h2>工作区文件</h2><div class="doc-tools-empty">在查找结果的更多操作中，可将文件的引用加入工作区。</div></div>`}
    </div>`;
  }
  return `<div class="doc-tools-card organizer-search-card">
    <form id="organizer-search">
      <div class="organizer-search-main">
        <label class="doc-tools-field"><span>文件名或相对路径</span>
          <input type="search" id="organizer-query" value="${h(organizerFilter.query)}" placeholder="输入关键词"></label>
        <button type="submit" class="doc-tools-primary">${icon("search")} 查找</button>
      </div>
      <div class="organizer-search-options">
        <label class="doc-tools-field"><span>授权目录</span><select id="organizer-root"><option value="">全部授权目录</option>
          ${organizerData.roots.map((item) => `<option value="${h(item.id)}" title="${h(item.path)}"${item.id === organizerFilter.root ? " selected" : ""}>${h(organizerRootLabel(item))}</option>`).join("")}</select></label>
        <label class="doc-tools-field"><span>扩展名</span><input type="text" id="organizer-extension" value="${h(organizerFilter.extension)}" placeholder="全部类型"></label>
        <label class="doc-tools-field"><span>排序</span><select id="organizer-sort">
          ${[["name", "名称"], ["date", "修改时间"], ["size", "大小"]].map(([value, label]) =>
            `<option value="${value}"${organizerFilter.sort === value ? " selected" : ""}>${label}</option>`).join("")}</select></label>
        <button type="button" id="organizer-save-query">保存查询…</button>
      </div>
    </form>
    ${organizerData.queries.length ? `<div class="organizer-queries">
      <strong>已保存查询</strong><div class="doc-tools-actions">${organizerData.queries.map((item) => `<span class="organizer-query">
        <button class="doc-tools-quiet doc-truncate" data-organizer-query="${h(item.id)}" title="${h(item.name)}">${h(item.name)}</button>
        <button class="doc-tools-quiet doc-tools-icon" data-organizer-query-remove="${h(item.id)}" title="移除查询" aria-label="移除查询 ${h(item.name)}">${icon("close")}</button>
      </span>`).join("")}</div></div>` : ""}
  </div>
  ${organizerItems(organizerSection === "favorite" ? "收藏文件" : "查找结果")}
  ${state.entries?.length && !organizerData.roots.length ? `<details class="doc-tools-card doc-tools-detail"><summary>最近浏览的文件夹 ${icon("chevron")}</summary>
    <ul class="organizer-list">${state.entries.map((item) => `<li><button data-open="${h(item.path)}">${h(item.name)}</button></li>`).join("")}</ul></details>` : ""}`;
}

function organizerBaseName(path) {
  return path.split(/[\\/]/).filter(Boolean).at(-1) || path;
}

function organizerRootLabel(root) {
  const name = organizerBaseName(root.path);
  return organizerData.roots.some((item) => item.id !== root.id && organizerBaseName(item.path) === name) ? root.path : name;
}

function organizerRelativePath(path) {
  const root = organizerData.roots.find((item) => path.toLowerCase().startsWith(item.path.toLowerCase().replace(/[\\/]+$/, "") + "\\"));
  return root ? organizerBaseName(root.path) + path.slice(root.path.replace(/[\\/]+$/, "").length) : path;
}

function organizerItems(title) {
  const {items, offset, more} = organizerResults;
  const rows = items.map((item) => {
    const date = Number.isFinite(item.modified) ? organizerDate.format(item.modified / 1e6) : "";
    const openActions = [["favorite", "添加标签…"], ...(item.tags ? [["unfavorite", "移除标签…"]] : []),
      ...(organizerData.spaces.length ? [["member", "加入工作区…"]] : []),
      ...(organizerSection === "spaces" ? [["unmember", "移出工作区"]] : []), ["plan", "移动或重命名…"]];
    return `<li class="organizer-entry">
      <span class="doc-file-icon" aria-hidden="true">${icon("doc")}</span>
      <div class="organizer-file">
        <button class="doc-tools-quiet doc-truncate" data-organizer-open="${h(item.id)}" title="${h(item.name)}">${h(item.name)}</button>
        <span class="doc-truncate" title="${h(item.path)}">${h(organizerRelativePath(item.path))}</span>
        ${item.tags ? `<span class="organizer-tags doc-truncate" title="${h(item.tags)}">${h(item.tags)}</span>` : ""}
      </div>
      <div class="organizer-size"><time>${h(date)}</time><span>${h(toolFileSize(item.size))}</span></div>
      <div class="doc-tools-actions">
        <button class="doc-tools-quiet" data-organizer-reveal="${h(item.id)}">定位</button>
        <details class="organizer-more"><summary title="更多操作" aria-label="${h(item.name)} 的更多操作">${icon("more")}</summary>
          <div class="organizer-menu">${openActions.map(([key, label]) =>
            `<button data-organizer-${key}="${h(item.id)}">${label}</button>`).join("")}</div></details>
      </div>
    </li>`;
  }).join("");
  let empty = "没有匹配的文件。";
  if (organizerSection === "spaces") empty = "此工作区还没有文件。";
  else if (organizerSection === "favorite") empty = "未找到收藏文件。可在查找结果中添加标签。";
  else if (!organizerData.roots.length) empty = '先添加授权目录并扫描。 <button data-organizer-section="roots">前往授权目录</button>';
  return `<div class="doc-tools-card organizer-list-card organizer-results">
    <div class="doc-tools-card-bar"><h2>${h(title)}</h2>${items.length ? `<span class="doc-tools-hint">${more ? "本页 " : ""}${items.length} 项</span>` : ""}</div>
    ${rows ? `<ul class="organizer-list">${rows}</ul>` : `<div class="doc-tools-empty">${empty}</div>`}
    ${offset || more ? `<div class="doc-tools-actions organizer-pagination">
      <button id="organizer-previous"${offset ? "" : " disabled"}>上一页</button>
      <span>第 ${Math.floor(offset / 100) + 1} 页</span>
      <button id="organizer-next"${more ? "" : " disabled"}>下一页</button>
    </div>` : ""}
  </div>`;
}

async function organizerApi(action, data = {}) {
  return (await api("/api/organizer/" + action, data)).result;
}

async function organizerRefresh(search = true) {
  organizerData = await organizerApi("state");
  if (search && organizerData.initialized && ["search", "favorite", "spaces"].includes(organizerSection)) {
    organizerResults = await organizerApi("search", {...organizerFilter, offset: organizerResults.offset});
  }
  if (view === "files") render();
}

async function organizerSearch(offset = 0) {
  organizerResults = await organizerApi("search", {...organizerFilter, offset});
  if (view === "files") render();
}

function bindOrganizer() {
  if (view !== "files") return;
  if (!organizerLoaded && !organizerBusy) {
    organizerBusy = true;
    organizerRefresh().catch(fail).finally(() => { organizerLoaded = true; organizerBusy = false; if (view === "files") render(); });
  }
  function on(attribute, fn) {
    document.querySelectorAll("[data-organizer-" + attribute + "]").forEach((node) => {
      node.onclick = () => {
        const menu = node.closest(".organizer-more");
        if (menu) {
          menu.open = false;
          menu.querySelector("summary").focus();
        }
        return Promise.resolve().then(() => fn(node.getAttribute("data-organizer-" + attribute))).catch(fail);
      };
    });
  }
  function listen(id, action) {
    listenHandoff(id, action);
  }
  on("section", async (name) => {
    organizerSection = name;
    organizerFilter.favorite = name === "favorite";
    organizerFilter.space = "";
    organizerResults = {items: [], offset: 0, more: false};
    await organizerRefresh();
    if (view === "files") document.querySelector(".organizer-nav [aria-current=page]")?.focus();
  });
  document.querySelectorAll(".organizer-more").forEach((menu) => {
    menu.ontoggle = () => {
      if (menu.open) {
        document.querySelectorAll(".organizer-more[open]").forEach((other) => {
          if (other !== menu) other.open = false;
        });
      }
    };
    menu.onfocusout = (event) => {
      if (!menu.contains(event.relatedTarget)) menu.open = false;
    };
    menu.onkeydown = (event) => {
      if (event.key === "Escape" && menu.open) {
        event.stopPropagation();
        menu.open = false;
        menu.querySelector("summary").focus();
      }
    };
  });
  const form = document.getElementById("organizer-search");
  function readForm() {
    for (const key of ["query", "extension", "root", "sort"]) organizerFilter[key] = document.getElementById("organizer-" + key).value;
  }
  if (form) {
    form.oninput = readForm;
    form.onsubmit = (event) => { event.preventDefault(); readForm(); organizerSearch().catch(fail); };
  }
  listen("organizer-init", async () => {
    await organizerApi("initialize");
    organizerSection = "roots";
    await organizerRefresh();
  });
  listen("organizer-reload", () => organizerRefresh());
  listen("organizer-authorize", async () => {
    const path = await pickHandoffPath("folder");
    if (!path || !await toolDialog({title: "授权目录", text: path, action: "授权扫描"})) return;
    await organizerApi("authorize", {path, confirm: true});
    await organizerRefresh();
  });
  on("scan", async (id) => {
    if (organizerScanning) return;
    organizerScanning = id;
    render();
    try {
      const result = await organizerApi("scan", {id});
      message = '已索引 ' + result.count + ' 个文件' + (result.skipped ? ' · 无法读取 ' + result.skipped + ' 项' : '')
        + (result.truncated ? ' · 达到扫描上限，请缩小范围' : '');
    } finally {
      organizerScanning = "";
    }
    await organizerRefresh();
  });
  on("revoke", async (id) => {
    const root = organizerData.roots.find((item) => item.id === id);
    if (await toolDialog({title: "撤销授权", text: "移除该目录的索引条目。\n" + root.path, action: "撤销授权", danger: true})) {
      await organizerApi("revoke", {id});
      if (organizerFilter.root === id) organizerFilter.root = "";
      await organizerRefresh();
    }
  });
  listen("organizer-previous", () => organizerSearch(organizerResults.offset - 100));
  listen("organizer-next", () => organizerSearch(organizerResults.offset + 100));
  listen("organizer-save-query", async () => {
    readForm();
    const input = await toolDialog({title: "保存查询", fields: [{name: "name", label: "查询名称", value: organizerFilter.query}], action: "保存"});
    if (input) { await organizerApi("save-query", {...organizerFilter, name: input.name}); await organizerRefresh(); }
  });
  on("query", async (id) => {
    const query = organizerData.queries.find((item) => item.id === id);
    organizerFilter = {...organizerFilter, query: query.query, extension: query.extension};
    await organizerSearch();
  });
  on("query-remove", async (id) => {
    const query = organizerData.queries.find((item) => item.id === id);
    if (await toolDialog({title: "移除已保存查询", text: query.name, action: "移除", danger: true})) {
      await organizerApi("remove", {id, table: "queries"});
      await organizerRefresh();
    }
  });
  on("open", async (id) => { await organizerApi("open", {id}); view = "editor"; render(); });
  on("reveal", async (id) => {
    await organizerApi("reveal", {id});
    message = "已向资源管理器请求定位文件。";
    render();
  });
  async function tag(id, remove) {
    const item = organizerResults.items.find((row) => row.id === id);
    const label = remove ? "移除标签" : "添加标签";
    const options = remove ? item.tags.split("、").map((value) => ({value, label: value})) : undefined;
    const input = await toolDialog({title: label, text: item.name, action: remove ? "移除" : "添加",
      fields: [{name: "tag", label: "标签", value: remove ? options[0].value : "收藏", options}]});
    if (input) { await organizerApi("favorite", {id, tag: input.tag, remove}); await organizerSearch(organizerResults.offset); }
  }
  on("favorite", (id) => tag(id, false));
  on("unfavorite", (id) => tag(id, true));
  listen("organizer-space-new", async () => {
    const input = await toolDialog({title: "新建工作区", fields: [{name: "name", label: "工作区名称"}], action: "新建"});
    if (input) {
      await organizerApi("create-space", {name: input.name});
      await organizerRefresh();
    }
  });
  on("space", async (id) => { organizerFilter.space = id; await organizerSearch(); });
  on("space-remove", async (id) => {
    const space = organizerData.spaces.find((item) => item.id === id);
    if (await toolDialog({title: "移除工作区", text: "移除「" + space.name + "」及其中的文件引用。", action: "移除", danger: true})) {
      await organizerApi("remove", {table: "spaces", id});
      if (organizerFilter.space === id) organizerFilter.space = "";
      await organizerRefresh();
    }
  });
  on("member", async (id) => {
    const item = organizerResults.items.find((row) => row.id === id);
    const options = organizerData.spaces.map((space) => ({value: space.id, label: space.name}));
    const input = await toolDialog({title: "加入工作区", text: item.name, action: "加入",
      fields: [{name: "space", label: "工作区", options}]});
    if (input) {
      await organizerApi("member", {id, space: input.space});
      await organizerSearch(organizerResults.offset);
    }
  });
  on("unmember", async (id) => { await organizerApi("member", {id, space: organizerFilter.space, remove: true}); await organizerSearch(); });
  on("plan", async (id) => {
    const item = organizerResults.items.find((row) => row.id === id);
    const windowsPath = (value) => value.toLowerCase().replaceAll("/", "\\");
    const prefix = (root) => root.path.replace(/[\\/]+$/, "") + "\\";
    const root = organizerData.roots.find((root) => windowsPath(item.path).startsWith(windowsPath(prefix(root))));
    const options = organizerData.roots.map((item) => ({label: item.path, value: item.id}));
    const input = await toolDialog({title: "创建整理计划", text: "原位置\n" + item.path, action: "预览计划", fields: [
      {name: "root", label: "目标授权目录", value: root?.id, options},
      {name: "relative", label: "相对路径与文件名", value: root ? item.path.slice(prefix(root).length) : item.name},
    ]});
    if (!input) return;
    const destination = organizerData.roots.find((item) => item.id === input.root);
    if (!destination) throw new Error("目标授权目录已变化，请重新选择。");
    const path = /^[a-z]:[\\/]/i.test(input.relative) ? input.relative : prefix(destination) + input.relative.replace(/^[\\/]+/, "");
    if (windowsPath(path) === windowsPath(item.path)) throw new Error("请输入不同的目标路径或文件名。");
    await organizerApi("plan", {id, root: destination.id, path});
    organizerSection = "moves";
    await organizerRefresh();
  });
  on("execute", async (id) => {
    const item = organizerData.moves.find((entry) => entry.id === id);
    if (await toolDialog({title: "确认执行整理计划", text: "原位置\n" + item.source + "\n\n目标位置\n" + item.destination, action: "执行移动"})) {
      await organizerApi("execute", {id, confirm: true});
      message = "整理已完成。";
      await organizerRefresh();
    }
  });
  on("recover", async (id) => { const result = await organizerApi("recover", {id}); message = result.status === "moved" ? "已核实目标文件。" : "原件仍在原位置。"; await organizerRefresh(); });
  on("cancel", async (id) => { await organizerApi("cancel", {id}); await organizerRefresh(); });
  async function association(action) {
    associationExtension = document.getElementById("organizer-ext-choice").value.trim();
    associationResult = await organizerApi("association", {action, extension: associationExtension});
    await organizerRefresh();
  }
  const associationForm = document.getElementById("organizer-association");
  if (associationForm) associationForm.onsubmit = (event) => { event.preventDefault(); association("read").catch(fail); };
  listen("organizer-default-apps", () => association("open"));
  listen("organizer-confirm-association", () => association("verify"));
}
