const officeViews = new Map();
let officeResize;

function officePanel(tab) {
  let local = officeViews.get(tab.id);
  if (!local) {
    local = {mode: "layout", part: 0, query: "", search: false, navigation: null, recovery: false, loading: false, error: ""};
    officeViews.set(tab.id, local);
  }
  const recovery = tab.preview?.recovery;
  const preview = local.recovery && recovery?.readable ? recovery.preview : tab.preview;
  const ext = tab.title.split(".").at(-1).toUpperCase();
  const parts = preview?.parts || [];
  if (local.part >= parts.length) local.part = 0;
  const partLabel = {sheet: "工作表", slides: "幻灯片"}[preview?.mode];
  const navigable = Boolean(partLabel && parts.length);
  const viewing = local.loading ? `<div class="office-empty" role="status">${icon("office")}<h3>正在读取原文件…</h3></div>`
    : local.mode === "layout" ? officeLayout(preview, local) : officeContents(preview, local);
  return `<div class="office-workspace" data-office-mode="${h(preview?.mode || 'other')}">
    <div class="office-document-head"><div class="office-title"><span class="office-title-icon">${icon(preview?.mode === "sheet" ? "home" : "office")}</span><div><h2 title="${h(tab.path)}">${h(tab.title)}</h2><span>${h(ext)} · ${local.recovery ? "旧版草稿 · " : ""}只读</span></div></div><div class="office-head-actions">
      <button data-external="${h(tab.path)}" aria-label="用外部应用打开原文件" title="用外部应用打开原文件">${icon("previewExternal")}<span>用外部应用打开</span></button>
      <details class="action-menu align-right office-overflow"><summary title="更多 Office 操作" aria-label="更多 Office 操作">${icon("more")}</summary><div><button id="office-reveal">在资源管理器中显示</button><button id="office-reload" ${local.loading ? "disabled" : ""}>重新读取原文件</button></div></details>
    </div></div>
    <div class="office-toolbar" aria-label="Office 查看工具">
      ${navigable ? `<button id="office-navigation" class="office-icon-button" aria-label="${partLabel}导航" title="${partLabel}导航" aria-pressed="${local.navigation !== false}">${icon("sidebar")}</button>` : ""}
      <div class="office-segments"><button id="office-layout" aria-pressed="${local.mode === 'layout'}">版式预览</button><button id="office-content" aria-pressed="${local.mode === 'content'}">内容查阅</button></div>
      ${navigable ? officePartPicker(parts, local, partLabel) : ""}<button id="office-search-toggle" title="搜索文档内容" aria-label="搜索文档内容" aria-pressed="${local.search && local.mode === 'content'}" ${!parts.length || local.loading ? "disabled" : ""}>${icon("search")}<span>搜索</span></button>
    </div>
    ${recovery?.present ? `<div class="office-notice office-caution"><span>${icon("restore")} <b>旧版未保存草稿</b> ${h(recovery.message)}</span>${recovery.readable ? `<button id="office-recovery-toggle">${local.recovery ? "查看原文件" : "查看草稿"}</button><button id="office-export-recovery">导出恢复副本…</button>` : ""}<button id="office-recovery-folder">查看恢复目录</button></div>` : ""}
    ${preview?.macros ? `<div class="office-notice office-caution">${icon("previewAlert")} 此文件包含 VBA 宏，预览只读取静态内容。</div>` : ""}
    ${local.error ? `<div class="office-notice office-caution" role="alert">${icon("previewAlert")}<span>${h(local.error)}</span><button id="office-retry">重新读取</button></div>` : ""}
    ${!local.loading && local.search && local.mode === "content" ? officeSearchBar(preview, local) : ""}
    <div class="office-layout">${navigable && local.navigation !== false ? officeNavigator(preview, local, partLabel) : ""}
      <div class="office-stage" aria-label="Office 预览区" tabindex="0">${viewing}</div>
    </div>
    ${preview?.message ? `<div class="office-status">${h(preview.message)}</div>` : ""}
  </div>`;
}

function officeLayout(preview, local) {
  const parts = preview?.parts || [];
  const item = parts[local.part];
  let body = "";
  if (preview?.mode === "word") {
    if (preview.layout?.length) body = `<article class="office-page">${preview.layout.map(wordParagraph).join("")}</article>`;
  } else if (preview?.mode === "sheet" && item) {
    if (item.cells?.length) body = `<div class="office-sheet">${officeGrid(item.cells)}</div>`;
  } else if (preview?.mode === "slides" && item) {
    body = `<article class="office-slide" style="--slide-ratio:${Number(preview.ratio) || 1.777}">${officeSlideShapes(item)}</article>`;
  }
  if (!body) return officeEmpty(preview?.mode === "sheet" && item ? "此工作表没有可显示的单元格" : "此文档没有可显示的版式", true);
  return `<div class="office-paper-scroll${preview.mode === "slides" ? " office-slide-viewport" : ""}">${body}</div>`;
}

function officeSlideShapes(item, thumbnail = false) {
  return (item.shapes || []).slice(0, thumbnail ? 5 : undefined).map((shape, index) => {
    const values = shape.position || [6, 7 + index * 22, 88, 21];
    const [left, top, width, height] = values.map((value) => `${Math.max(-200, Math.min(200, Number(value) || 0))}%`);
    return `<span style="left:${left};top:${top};width:${width};height:${height}">${h(thumbnail ? shape.text.slice(0, 64) : shape.text)}</span>`;
  }).join("");
}

function officeEmpty(title, layout) {
  return `<div class="office-empty"><div><span class="office-empty-icon">${icon("office")}</span><h3>${title}</h3>${layout ? '<button type="button" data-office-content>查看文档内容</button>' : ""}</div></div>`;
}

function wordParagraph(block) {
  if (block.type === "table") return `<table class="office-word-table">${block.rows.map((row) => `<tr>${row.map((value) => `<td>${h(value)}</td>`).join("")}</tr>`).join("")}</table>`;
  const heading = /^Heading[1-9]?$/i.test(block.style) || /^Title$/i.test(block.style);
  const align = {center: "center", right: "right", both: "justify"}[block.alignment] || "left";
  return `<p class="${heading ? "office-heading" : ""}${block.pageBreak ? " office-page-break" : ""}" style="text-align:${align}">${(block.runs || []).map((run) => {
    const color = /^[0-9a-f]{6}$/i.test(run.color) ? `color:#${run.color};` : "";
    const size = Number(run.size) > 0 ? `font-size:${Number(run.size)}pt;` : "";
    return `<span style="${color}${size}${run.bold ? "font-weight:700;" : ""}${run.italic ? "font-style:italic;" : ""}${run.underline ? "text-decoration:underline;" : ""}">${h(run.text)}</span>`;
  }).join("") || "&nbsp;"}</p>`;
}

function officeGrid(cells) {
  const rows = new Map();
  const columns = new Set();
  for (const cell of cells || []) {
    const address = /^([A-Z]+)([1-9][0-9]*)$/i.exec(cell.address);
    if (!address) continue;
    const [, column, row] = address;
    columns.add(column);
    if (!rows.has(Number(row))) rows.set(Number(row), new Map());
    rows.get(Number(row)).set(column, cell.value);
  }
  const sortColumns = [...columns].sort((a, b) => a.length - b.length || a.localeCompare(b)).slice(0, 72);
  const content = [...rows].sort(([a], [b]) => a - b).slice(0, 350);
  return `<table class="office-grid"><thead><tr><th></th>${sortColumns.map((column) => `<th>${h(column)}</th>`).join("")}</tr></thead><tbody>${content.map(([index, row]) => `<tr><th>${index}</th>${sortColumns.map((column) => `<td>${h(row.get(column) ?? "")}</td>`).join("")}</tr>`).join("")}</tbody></table>${rows.size > 350 || columns.size > 72 ? '<p>版式预览已达到显示上限，更多已提取单元格可在内容查阅中搜索。</p>' : ""}`;
}

function officePartPicker(parts, local, label) {
  return `<select id="office-pick-layout" class="office-part-select" aria-label="选择${label}">${parts.map((item, index) => `<option value="${index}" ${index === local.part ? "selected" : ""}>${h(item.title)}</option>`).join("")}</select>`;
}

function officeNavigator(preview, local, label) {
  const slides = preview.mode === "slides";
  return `<div class="office-parts" data-navigation="${local.navigation === null ? "auto" : "open"}"><div class="office-nav-title"><strong>${label}</strong><button id="office-navigation-close" class="office-icon-button" title="关闭${label}导航" aria-label="关闭${label}导航">${icon("close")}</button></div><div class="office-nav-list">${preview.parts.map((item, index) => `<button data-office-part="${index}" aria-current="${index === local.part ? 'page' : 'false'}" title="${h(item.title)}">${slides ? `<span class="office-slide-thumb" aria-hidden="true" style="--slide-ratio:${Number(preview.ratio) || 1.777}">${officeSlideShapes(item, true)}</span>` : icon("home")}<span>${h(item.title)}</span></button>`).join("")}</div></div>`;
}

function officeSearchBar(preview, local) {
  const placeholder = {sheet: "查找单元格、值或公式", slides: "查找当前幻灯片文字", word: "查找段落文字"}[preview?.mode] || "查找文档内容";
  return `<div class="office-search-bar" role="search"><label>${icon("search")}<input type="search" maxlength="256" id="office-search" aria-label="${placeholder}" placeholder="${placeholder}" value="${h(local.query)}"></label><output id="office-search-count" aria-live="polite">${officeMatches(preview, local).length} 项</output><button id="office-search-close" class="office-icon-button" title="关闭搜索" aria-label="关闭搜索">${icon("close")}</button></div>`;
}

function officeContents(preview, local) {
  if (!preview?.parts?.length) return officeEmpty("此文件没有可提取的查阅内容", false);
  return `<div class="office-reading"><div id="office-search-results">${officeContentResults(preview, local)}</div></div>`;
}

function officeMatches(preview, local) {
  const query = local.search ? local.query.trim().toLocaleLowerCase() : "";
  const matches = (...values) => values.some((text) => String(text || "").toLocaleLowerCase().includes(query));
  const item = preview?.parts?.[local.part];
  if (preview?.mode === "sheet") return (item?.cells || []).filter((cell) => matches(cell.address, cell.value, cell.formula));
  return (preview?.mode === "slides" ? [item] : (preview?.parts || [])).filter((row) => row && matches(row.title, row.text));
}

function officeContentResults(preview, local) {
  const rows = officeMatches(preview, local);
  const query = local.search ? local.query.trim() : "";
  const empty = `<p class="office-no-results">${query ? "没有匹配内容" : "没有可查阅内容"}</p>`;
  const pattern = query ? new RegExp(query.replace(/[.*+?^${}()|[\]\\]/g, "\\$&"), "giu") : null;
  const matched = (value) => {
    const text = String(value ?? "");
    if (!pattern) return h(text);
    let end = 0, result = "";
    for (const match of text.matchAll(pattern)) {
      result += h(text.slice(end, match.index)) + `<mark>${h(match[0])}</mark>`;
      end = match.index + match[0].length;
    }
    return result + h(text.slice(end));
  };
  if (preview.mode === "sheet") {
    const title = preview.parts[local.part]?.title;
    return `<h3>${h(title)}</h3>${rows.length ? `<div class="office-results-table"><table class="office-grid"><thead><tr><th scope="col">单元格</th><th scope="col">原始值／缓存结果</th><th scope="col">公式</th></tr></thead><tbody>${rows.map((cell) => `<tr><th scope="row">${matched(cell.address)}</th><td>${matched(cell.value)}</td><td><code>${matched(cell.formula)}</code></td></tr>`).join("")}</tbody></table></div>` : empty}`;
  }
  return rows.map((row) => `<article class="office-content-row"><small>${matched(row.title)}</small><div>${matched(row.text || "（空白）")}</div></article>`).join("") || empty;
}

function bindOffice() {
  officeResize?.disconnect();
  const workspace = document.querySelector(".office-workspace");
  const tab = selected();
  if (!workspace || !tab) return;
  const local = officeViews.get(tab.id);
  const recovery = tab.preview?.recovery;
  const preview = local.recovery && recovery?.readable ? recovery.preview : tab.preview;
  const assign = (id, fn) => { const element = document.getElementById(id); if (element) element.onclick = () => Promise.resolve().then(fn).catch(fail); };
  const showMode = (mode) => { local.mode = mode; render(); document.getElementById(`office-${mode}`)?.focus(); };
  assign("office-layout", () => showMode("layout"));
  assign("office-content", () => showMode("content"));
  workspace.querySelectorAll("[data-office-content]").forEach((node) => { node.onclick = () => showMode("content"); });
  assign("office-recovery-toggle", () => { local.recovery = !local.recovery; local.part = 0; local.query = ""; local.error = ""; render(); });
  assign("office-reveal", () => api("/api/reveal", {id: tab.id}));
  assign("office-recovery-folder", () => api("/api/office/recovery-folder", {id: tab.id}));
  const reload = async () => {
    if (local.loading) return;
    local.loading = true;
    local.error = "";
    render();
    try { await api("/api/office/reload", {id: tab.id}); }
    catch (error) { local.error = error.message; }
    finally { local.loading = false; if (selected()?.id === tab.id) render(); }
  };
  assign("office-reload", reload);
  assign("office-retry", reload);
  assign("office-export-recovery", async () => {
    const name = tab.title.replace(/(\.[^.]+)$/, " 恢复副本$1");
    const path = await fileDialog("save", name);
    if (path) { await api("/api/office/export-recovery", {id: tab.id, path}); message = "恢复副本已导出"; render(); }
  });
  const navigator = workspace.querySelector(".office-parts");
  const usingNavigator = () => Boolean(navigator && getComputedStyle(navigator).display !== "none");
  const navigationButton = document.getElementById("office-navigation");
  const syncNavigation = () => navigationButton?.setAttribute("aria-pressed", String(usingNavigator()));
  syncNavigation();
  if (navigationButton && window.ResizeObserver) {
    officeResize = new ResizeObserver(syncNavigation);
    officeResize.observe(workspace);
  }
  const toggleNavigation = () => {
    local.navigation = !usingNavigator();
    render();
    document.getElementById("office-navigation")?.focus({preventScroll: true});
  };
  assign("office-navigation", toggleNavigation);
  assign("office-navigation-close", toggleNavigation);
  const picker = document.getElementById("office-pick-layout");
  if (picker) picker.onchange = () => { local.part = Number(picker.value); render(); document.getElementById("office-pick-layout")?.focus({preventScroll: true}); };
  workspace.querySelectorAll("[data-office-part]").forEach((node) => node.onclick = () => {
    local.part = Number(node.dataset.officePart);
    if (workspace.clientWidth <= 670) local.navigation = false;
    render();
    document.querySelector(`[data-office-part="${local.part}"]`)?.focus({preventScroll: true});
  });
  const toggleSearch = (requested = null) => {
    local.search = requested ?? !(local.search && local.mode === "content");
    if (local.search) local.mode = "content";
    render();
    const next = document.getElementById(local.search ? "office-search" : "office-search-toggle");
    next?.focus({preventScroll: true});
    if (local.search) next?.select();
  };
  assign("office-search-toggle", () => toggleSearch());
  assign("office-search-close", () => toggleSearch(false));
  workspace.onkeydown = (event) => {
    if (event.ctrlKey && event.key.toLowerCase() === "f" && preview?.parts?.length && !local.loading) {
      event.preventDefault(); toggleSearch(true);
    } else if (event.key === "Escape" && event.target.closest(".office-search-bar")) {
      event.preventDefault(); toggleSearch(false);
    }
  };
  const search = document.getElementById("office-search");
  if (search) search.oninput = () => {
    local.query = search.value;
    document.getElementById("office-search-results").innerHTML = officeContentResults(preview, local);
    document.getElementById("office-search-count").textContent = `${officeMatches(preview, local).length} 项`;
  };
}
