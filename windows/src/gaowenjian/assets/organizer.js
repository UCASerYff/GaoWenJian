let organizerData = null;
let organizerSection = "search";
let organizerResults = {items: [], offset: 0, more: false};
let organizerFilter = {query: "", extension: "", sort: "name", root: "", favorite: false, space: ""};
let associationExtension = ".pdf";
let associationResult = null;
let organizerLoaded = false;
let organizerBusy = false;

function organizerPanel() {
  const menu = [["search", "查找"], ["favorite", "收藏"], ["roots", "授权目录"], ["spaces", "工作区"], ["moves", "整理计划"], ["associations", "文件关联"]];
  return '<h1>文件整理</h1><div class="row organizer-nav" aria-label="文件整理">' + menu.map(([id, title]) =>
    '<button data-organizer-section="' + id + '"' + (organizerSection === id ? ' class="active" aria-current="page"' : '') + '>' + title + '</button>').join("")
    + '</div>' + (organizerData?.initialized ? organizerContent() : organizerIntro());
}

function organizerIntro() {
  if (!organizerLoaded) return '<p class="muted">正在读取整理资料…</p>';
  if (!organizerData) return '<button id="organizer-reload">重新读取整理资料</button>';
  return '<div class="card handoff-card"><h2>创建本机索引</h2>'
    + '<p>之后可以选择授权目录。查找、收藏和工作区使用索引里的文件信息。</p>'
    + '<button id="organizer-init">创建索引</button></div>';
}

function organizerContent() {
  if (organizerSection === "roots") {
    return '<div class="row"><h2>授权目录</h2><button id="organizer-authorize">添加目录…</button></div>'
      + (organizerData.roots.length ? organizerData.roots.map((root) => '<div class="organizer-record"><span>' + h(root.path)
        + '</span><button data-organizer-scan="' + h(root.id) + '">扫描</button>'
        + '<button data-organizer-revoke="' + h(root.id) + '">撤销授权</button></div>').join("") : '<p class="muted">暂无授权目录。</p>');
  }
  if (organizerSection === "moves") {
    const labels = {preview: "等待确认", moving: "等待核对", moved: "已完成", cancelled: "已取消"};
    return '<h2>整理计划</h2>' + (organizerData.moves.length ? organizerData.moves.map((item) =>
      '<article class="organizer-record"><div><strong>' + (labels[item.status] || h(item.status)) + '</strong>'
      + '<div>原路径 · ' + h(item.source) + '</div><div>目标 · ' + h(item.destination) + '</div></div>'
      + (item.status === "preview" ? '<button data-organizer-execute="' + h(item.id) + '">确认执行…</button> <button data-organizer-cancel="' + h(item.id) + '">取消计划</button>' : '')
      + (item.status === "moving" ? '<button data-organizer-recover="' + h(item.id) + '">核对实际位置</button>' : '')
      + '</article>').join("") : '<p class="muted">在查找结果上创建移动或重命名计划。</p>');
  }
  if (organizerSection === "associations") {
    return '<h2>文件关联</h2><form id="organizer-association" class="row"><label>扩展名 <input id="organizer-ext-choice" value="' + h(associationExtension) + '"></label>'
      + '<button type="submit">读取当前设置</button><button type="button" id="organizer-default-apps">打开 Windows 设置</button>'
      + '<button type="button" id="organizer-confirm-association">核对设置结果</button></form>'
      + (associationResult ? '<div class="banner">' + h(associationResult.extension) + ' · '
        + h(associationResult.program || "没有注册默认处理程序") + ' · '
        + ({changed: "已核实改变", unchanged: "读回值相同", pending: "等待用户在系统设置完成", read: "试读成功"}[associationResult.status] || "") + '</div>' : '')
      + organizerData.associations.map((item) => '<p>' + h(item.changed + ' · ' + item.extension + ' · ' + item.before + ' → ' + item.after) + '</p>').join("");
  }
  if (organizerSection === "spaces") {
    return '<div class="row"><h2>工作区</h2><button id="organizer-space-new">新建工作区…</button></div>'
      + organizerData.spaces.map((item) => '<div class="organizer-record"><button data-organizer-space="' + h(item.id) + '">'
        + h(item.name) + '</button><button data-organizer-space-remove="' + h(item.id) + '">移除工作区</button></div>').join("")
      + (organizerFilter.space ? '<h3>' + h(organizerData.spaces.find((item) => item.id === organizerFilter.space)?.name) + '</h3>' + organizerItems() : '<p class="muted">在查找结果上添加文件。工作区只保存引用。</p>');
  }
  return '<form id="organizer-search" class="row"><label>查找 <input id="organizer-query" value="' + h(organizerFilter.query) + '" placeholder="文件名或相对路径"></label>'
    + '<label>类型 <input id="organizer-extension" value="' + h(organizerFilter.extension) + '" placeholder=".md"></label>'
    + '<label>目录 <select id="organizer-root"><option value="">全部授权目录</option>' + organizerData.roots.map((item) =>
      '<option value="' + h(item.id) + '"' + (item.id === organizerFilter.root ? " selected" : "") + '>' + h(item.path) + '</option>').join("")
    + '</select></label><label>排序 <select id="organizer-sort">' + [["name", "名称"], ["date", "修改时间"], ["size", "大小"]].map(([value, label]) =>
      '<option value="' + value + '"' + (organizerFilter.sort === value ? " selected" : "") + '>' + label + '</option>').join("")
    + '</select></label><button type="submit">查找</button><button type="button" id="organizer-save-query">保存查询…</button></form>'
    + '<div class="row">' + organizerData.queries.map((item) =>
      '<button data-organizer-query="' + h(item.id) + '">' + h(item.name) + '</button>'
      + '<button data-organizer-query-remove="' + h(item.id) + '" aria-label="移除查询 ' + h(item.name) + '">移除</button>').join("") + '</div>'
    + organizerItems()
    + (state.entries?.length && !organizerData.roots.length ? '<details><summary>最近浏览的文件夹</summary><ul class="list">'
      + state.entries.map((item) => '<li><button data-open="' + h(item.path) + '">' + h(item.name) + '</button></li>').join("") + '</ul></details>' : '');
}

function organizerItems() {
  const rows = organizerResults.items.map((item) => '<article class="organizer-record"><div><button data-organizer-open="' + h(item.id) + '">'
    + h(item.name) + '</button><p class="muted">' + h(item.path) + '</p><p>' + h(new Intl.NumberFormat("zh-CN").format(item.size)) + ' B'
    + (item.tags ? ' · ' + h(item.tags) : '') + '</p></div><div class="row">'
    + '<button data-organizer-reveal="' + h(item.id) + '">定位</button>'
    + '<button data-organizer-favorite="' + h(item.id) + '">加标签…</button>'
    + (item.tags ? '<button data-organizer-unfavorite="' + h(item.id) + '">移除标签…</button>' : '')
    + (organizerData.spaces.length ? '<button data-organizer-member="' + h(item.id) + '">加入工作区…</button>' : '')
    + (organizerSection === "spaces" ? '<button data-organizer-unmember="' + h(item.id) + '">移出工作区</button>' : '')
    + '<button data-organizer-plan="' + h(item.id) + '">移动或重命名…</button></div></article>').join("");
  return (rows || '<p class="muted">没有匹配文件。</p>') + '<div class="row">'
    + (organizerResults.offset ? '<button id="organizer-previous">上一页</button>' : '')
    + (organizerResults.more ? '<button id="organizer-next">下一页</button>' : '') + '</div>';
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
  render();
}

function bindOrganizer() {
  if (view !== "files") return;
  if (!organizerLoaded && !organizerBusy) {
    organizerBusy = true;
    organizerRefresh().catch(fail).finally(() => { organizerLoaded = true; organizerBusy = false; if (view === "files") render(); });
  }
  function on(attribute, fn) {
    document.querySelectorAll("[data-organizer-" + attribute + "]").forEach((node) =>
      node.onclick = () => Promise.resolve().then(() => fn(node.getAttribute("data-organizer-" + attribute))).catch(fail));
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
  });
  const form = document.getElementById("organizer-search");
  function readForm() {
    for (const key of ["query", "extension", "root", "sort"]) organizerFilter[key] = document.getElementById("organizer-" + key).value;
  }
  if (form) form.onsubmit = (event) => { event.preventDefault(); readForm(); organizerSearch().catch(fail); };
  listen("organizer-init", async () => {
    await organizerApi("initialize");
    organizerSection = "roots";
    await organizerRefresh();
  });
  listen("organizer-reload", () => organizerRefresh());
  listen("organizer-authorize", async () => {
    const path = await pickHandoffPath("folder");
    if (!confirm("允许搞文件扫描所选目录？\n" + path)) return;
    await organizerApi("authorize", {path, confirm: true});
    await organizerRefresh();
  });
  on("scan", async (id) => {
    message = "正在扫描所选授权目录…";
    render();
    const result = await organizerApi("scan", {id});
    message = '已索引 ' + result.count + ' 个文件' + (result.skipped ? ' · 无法读取 ' + result.skipped + ' 项' : '')
      + (result.truncated ? ' · 达到扫描上限，请缩小范围' : '');
    await organizerRefresh();
  });
  on("revoke", async (id) => {
    if (confirm("撤销目录权限并移除它的索引条目？原始文件仍保留。")) {
      await organizerApi("revoke", {id});
      if (organizerFilter.root === id) organizerFilter.root = "";
      await organizerRefresh();
    }
  });
  listen("organizer-previous", () => organizerSearch(organizerResults.offset - 100));
  listen("organizer-next", () => organizerSearch(organizerResults.offset + 100));
  listen("organizer-save-query", async () => {
    readForm();
    const name = prompt("查询名称", organizerFilter.query);
    if (name) { await organizerApi("save-query", {...organizerFilter, name}); await organizerRefresh(); }
  });
  on("query", async (id) => {
    const query = organizerData.queries.find((item) => item.id === id);
    organizerFilter = {...organizerFilter, query: query.query, extension: query.extension};
    await organizerSearch();
  });
  on("query-remove", async (id) => {
    if (confirm("移除这条查询？")) { await organizerApi("remove", {id, table: "queries"}); await organizerRefresh(); }
  });
  on("open", async (id) => { await organizerApi("open", {id}); view = "editor"; render(); });
  on("reveal", async (id) => {
    await organizerApi("reveal", {id});
    message = "已向资源管理器请求定位文件。";
    render();
  });
  async function tag(id, remove) {
    const item = organizerResults.items.find((row) => row.id === id);
    const value = prompt(remove ? "要移除的标签" : "标签名称", remove ? item.tags.split("、")[0] : "收藏");
    if (value) { await organizerApi("favorite", {id, tag: value, remove}); await organizerSearch(); }
  }
  on("favorite", (id) => tag(id, false));
  on("unfavorite", (id) => tag(id, true));
  listen("organizer-space-new", async () => {
    const name = prompt("工作区名称");
    if (name) { await organizerApi("create-space", {name}); await organizerRefresh(); }
  });
  on("space", async (id) => { organizerFilter.space = id; await organizerSearch(); });
  on("space-remove", async (id) => {
    if (confirm("移除此工作区及其中的引用？")) {
      await organizerApi("remove", {table: "spaces", id});
      if (organizerFilter.space === id) organizerFilter.space = "";
      await organizerRefresh();
    }
  });
  on("member", async (id) => {
    const choices = organizerData.spaces.map((item, index) => String(index + 1) + " " + item.name);
    const choice = prompt("选择工作区编号\n" + choices.join("\n"), "1");
    if (choice) {
      const space = organizerData.spaces[Number(choice) - 1];
      if (!space) throw new Error("找不到指定的工作区。");
      await organizerApi("member", {id, space: space.id});
      await organizerSearch();
    }
  });
  on("unmember", async (id) => { await organizerApi("member", {id, space: organizerFilter.space, remove: true}); await organizerSearch(); });
  on("plan", async (id) => {
    const item = organizerResults.items.find((row) => row.id === id);
    const path = prompt("输入授权目录下的完整目标路径", item.path);
    if (!path || path === item.path) return;
    const windowsPath = (value) => value.toLowerCase().replaceAll("/", "\\");
    const root = organizerData.roots.find((item) => windowsPath(path).startsWith(windowsPath(item.path).replace(/\\+$/, "") + "\\"));
    if (!root) throw new Error("目标必须在授权目录下。");
    await organizerApi("plan", {id, root: root.id, path});
    organizerSection = "moves";
    await organizerRefresh();
  });
  on("execute", async (id) => {
    const item = organizerData.moves.find((entry) => entry.id === id);
    if (confirm("执行此移动？\n" + item.source + "\n→ " + item.destination)) {
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
