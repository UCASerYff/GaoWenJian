const officeViews = new Map();

function officePanel(tab) {
  let local = officeViews.get(tab.id);
  if (!local) { local = {mode: "layout", part: 0, query: "", recovery: false}; officeViews.set(tab.id, local); }
  const recovery = tab.preview?.recovery;
  const preview = local.recovery && recovery?.readable ? recovery.preview : tab.preview;
  const ext = tab.title.split(".").at(-1).toUpperCase();
  const parts = preview?.parts || [];
  if (local.part >= parts.length) local.part = 0;
  return `<div class="office-workspace">
    <div class="row office-toolbar"><b>${icon("office")} ${h(ext)}</b><div class="office-segments"><button id="office-layout" aria-pressed="${local.mode === 'layout'}">版式预览</button><button id="office-content" aria-pressed="${local.mode === 'content'}">内容查阅</button></div><span class="row-spacer"></span>
      <button data-external="${h(tab.path)}">用外部应用打开…</button><details class="action-menu align-right"><summary title="更多操作" aria-label="更多 Office 操作">${icon("more")}</summary><div><button id="office-reveal">在资源管理器中显示</button><button id="office-reload">重新读取原文件</button></div></details></div>
    ${recovery?.present ? `<div class="row banner warn office-recovery"><b>${icon("restore")} 旧版未保存草稿已保留</b><span class="row-spacer"></span>${recovery.readable ? `<button id="office-recovery-toggle">${local.recovery ? "查看原文件" : "查看草稿"}</button><button id="office-export-recovery">导出恢复副本…</button>` : ""}<button id="office-recovery-folder">查看恢复目录</button><div>${h(recovery.message)}</div></div>` : ""}
    ${preview?.macros ? '<div class="banner warn">检测到 VBA 宏。查看器只读取静态内容。</div>' : ""}
    ${local.mode === "layout" ? officeLayout(preview, local) : officeContents(preview, local)}
    <div class="office-status">${icon("office")} ${local.recovery ? "旧版恢复草稿 · 只读" : "Office 查看器 · 只读"}<span>本地查看 · 原文件不变</span></div>
  </div>`;
}

function officeLayout(preview, local) {
  const parts = preview?.parts || [];
  const item = parts[local.part];
  let body = "";
  if (preview?.mode === "word") {
    body = `<article class="office-page">${(preview.layout || []).map(wordParagraph).join("")}</article>`;
  } else if (preview?.mode === "sheet" && item) {
    body = officeGrid(item.cells);
  } else if (preview?.mode === "slides" && item) {
    body = `<article class="office-slide" style="--slide-ratio:${Number(preview.ratio) || 1.777}">${(item.shapes || []).map((shape, index) => {
      const values = shape.position || [6, 7 + index * 22, 88, 21];
      const layout = values.map((value) => `${Math.max(-200, Math.min(200, Number(value) || 0))}%`);
      return `<div style="left:${layout[0]};top:${layout[1]};width:${layout[2]};height:${layout[3]}">${h(shape.text)}</div>`;
    }).join("")}</article>`;
  }
  if (!body) return `<div class="office-empty"><div>${icon("office")}<h2>此文档没有可显示的版式</h2><p>${h(preview?.message || "请选择内容查阅，或用外部应用打开。")}</p></div></div>`;
  return `<div class="office-layout">${preview.mode === "word" ? "" : officePartPicker(parts, local, "office-pick-layout")}<div class="office-paper-scroll">${body}</div><p class="muted office-notice">${h(preview.message)}</p></div>`;
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

function officePartPicker(parts, local, id) {
  return `<select id="${id}" class="office-part-select" aria-label="选择页或工作表">${parts.map((item, index) => `<option value="${index}" ${index === local.part ? "selected" : ""}>${h(item.title)}</option>`).join("")}</select>`;
}

function officeContents(preview, local) {
  const parts = preview?.parts || [];
  if (!parts.length) return `<div class="office-empty"><div>${icon("doc")}<h2>此文件没有可提取的查阅内容</h2><p>${h(preview?.message || "请用外部办公软件打开。")}</p></div></div>`;
  const separate = preview.mode === "sheet" || preview.mode === "slides";
  return `<div class="office-contents">${separate ? `<div class="office-parts">${parts.map((item, index) => `<button data-office-part="${index}" aria-pressed="${index === local.part}" title="${h(item.title)}">${icon(preview.mode === "sheet" ? "home" : "doc")}${h(item.title)}</button>`).join("")}</div>` : ""}<div class="office-reading"><input type="search" id="office-search" placeholder="搜索内容、单元格或公式" value="${h(local.query)}"><div id="office-search-results">${officeContentResults(preview, local)}</div><p class="muted office-notice">${h(preview.message)}</p></div></div>`;
}

function officeContentResults(preview, local) {
  const query = local.query.toLocaleLowerCase();
  const matches = (...values) => values.some((text) => String(text || "").toLocaleLowerCase().includes(query));
  const item = preview.parts[local.part];
  if (preview.mode === "sheet") {
    const cells = (item?.cells || []).filter((cell) => matches(cell.address, cell.value, cell.formula));
    return `<h3>${h(item?.title)}</h3><table class="office-grid"><thead><tr><th>单元格</th><th>原始值／缓存结果</th><th>公式</th></tr></thead><tbody>${cells.map((cell) => `<tr><th>${h(cell.address)}</th><td>${h(cell.value)}</td><td><code>${h(cell.formula)}</code></td></tr>`).join("")}</tbody></table>${cells.length ? "" : '<p class="muted">没有匹配内容</p>'}`;
  }
  const rows = (preview.mode === "slides" ? [item] : preview.parts).filter((row) => row && matches(row.title, row.text));
  return rows.map((row) => `<article class="office-content-row"><small>${h(row.title)}</small><div>${h(row.text || "（空白）")}</div></article>`).join("") || '<p class="muted">没有匹配内容</p>';
}

function bindOffice() {
  const toolbar = document.querySelector(".office-toolbar");
  const tab = selected();
  if (!toolbar || !tab) return;
  const local = officeViews.get(tab.id);
  const recovery = tab.preview?.recovery;
  const assign = (id, fn) => { const element = document.getElementById(id); if (element) element.onclick = () => Promise.resolve().then(fn).catch(fail); };
  assign("office-layout", () => { local.mode = "layout"; render(); });
  assign("office-content", () => { local.mode = "content"; render(); });
  assign("office-recovery-toggle", () => { local.recovery = !local.recovery; local.part = 0; local.query = ""; render(); });
  assign("office-reveal", () => api("/api/reveal", {id: tab.id}));
  assign("office-recovery-folder", () => api("/api/office/recovery-folder", {id: tab.id}));
  assign("office-reload", async () => { await api("/api/office/reload", {id: tab.id}); render(); });
  assign("office-export-recovery", async () => {
    const name = tab.title.replace(/(\.[^.]+)$/, " 恢复副本$1");
    const path = await fileDialog("save", name);
    if (path) { await api("/api/office/export-recovery", {id: tab.id, path}); message = "恢复副本已导出"; render(); }
  });
  const layoutPicker = document.getElementById("office-pick-layout");
  if (layoutPicker) layoutPicker.onchange = () => { local.part = Number(layoutPicker.value); render(); };
  document.querySelectorAll("[data-office-part]").forEach((node) => node.onclick = () => { local.part = Number(node.dataset.officePart); render(); });
  const search = document.getElementById("office-search");
  if (search) search.oninput = () => {
    local.query = search.value;
    document.getElementById("office-search-results").innerHTML = officeContentResults(local.recovery ? recovery.preview : tab.preview, local);
  };
}
