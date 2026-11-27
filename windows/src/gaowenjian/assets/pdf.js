const pdfViews = new Map();
let pdfResize;

Object.assign(symbols, {
  previewPrevious: '<path d="m15 6-6 6 6 6"/>', previewNext: '<path d="m9 6 6 6-6 6"/>',
  previewPlus: '<path d="M12 5v14M5 12h14"/>', previewMinus: '<path d="M5 12h14"/>',
  previewFit: '<path d="M9 4H4v5m11-5h5v5M4 15v5h5m11-5v5h-5"/><rect x="8" y="7" width="8" height="10" rx="1"/>',
  previewBook: '<rect x="3" y="5" width="18" height="14" rx="2"/><path d="M12 5v14M6.5 9H9m6 0h2.5"/>',
  previewPen: '<path d="m4 16-.7 4.7L8 20l12-12-4-4L4 16Zm9.5-9.5 4 4"/>',
  previewText: '<path d="M5 6V4h14v2M12 4v16m-3 0h6"/>',
  previewImage: '<rect x="3" y="4" width="18" height="16" rx="2"/><circle cx="8" cy="9" r="1.5"/><path d="m3.5 17 5-4.5 3 2.5 3.5-4 5.5 6"/>',
  previewScan: '<path d="M9 4H4v5m11-5h5v5M4 15v5h5m11-5v5h-5M8 9h8m-8 3h8m-8 3h5"/>',
  previewExternal: '<path d="M14 4h6v6m0-6-8 8m7 2v5H5V5h5"/>',
  previewForm: '<rect x="4" y="3" width="16" height="18" rx="2"/><path d="m7 8 1 1 2-2m3 1h4M7 13h3m3 0h4m-10 4h3m3 0h4"/>',
  previewLock: '<rect x="5" y="10" width="14" height="11" rx="2"/><path d="M8 10V7a4 4 0 1 1 8 0v3m-4 4v3"/>',
  previewAlert: '<circle cx="12" cy="12" r="9"/><path d="M12 7v6m0 4h.01"/>',
  previewUndo: '<path d="m8 6-4 4 4 4m-4-4h10a5 5 0 1 1 0 10h-2"/>',
  previewRedo: '<path d="m16 6 4 4-4 4m4-4H10a5 5 0 1 0 0 10h2"/>',
});

function pdfView(tab) {
  if (!pdfViews.has(tab.id)) {
    pdfViews.set(tab.id, {page: 0, navigation: null, navigationPane: "pages", spread: false, zoom: 0,
      inspector: "", editing: false, searchOpen: false, query: "", hits: [], hit: 0, pending: new Map(),
      placement: null, jump: true, scroll: 0, notice: ""});
  }
  return pdfViews.get(tab.id);
}

function pdfPanel(tab) {
  const info = tab.preview || {};
  const ui = pdfView(tab);
  const identification = `<div class="pdf-title"><span class="pdf-title-icon">${icon("doc")}</span><div><h2 title="${h(tab.path)}">${h(tab.title)}</h2><span class="pdf-title-meta">${info.encrypted ? "PDF · 只读" : `${info.pages?.length || 0} 页${tab.dirty ? " · 有未保存修改" : ""}`}</span></div></div>`;
  if (info.locked) {
    return `<div class="pdf-workspace pdf-locked"><div class="pdf-document-head">${identification}</div><div class="pdf-empty"><form id="pdf-unlock">
      <span class="pdf-empty-icon">${icon("previewLock")}</span><h3>此 PDF 需要密码</h3><p>解锁后可阅读，原文件的加密设置会保留。</p>
      <div class="pdf-unlock-actions"><input aria-label="PDF 密码" placeholder="PDF 密码" type="password" autocomplete="off" autofocus><button class="primary">解锁阅读</button></div><p id="pdf-unlock-status" role="status"></p></form></div></div>`;
  }
  const pages = info.pages || [];
  ui.page = Math.max(0, Math.min(ui.page, pages.length - 1));
  if (!pages.length) {
    return `<div class="pdf-workspace"><div class="pdf-document-head">${identification}</div><div class="pdf-empty"><div><span class="pdf-empty-icon">${icon(info.pages ? "doc" : "previewAlert")}</span><h3>${info.pages ? "此 PDF 没有可阅读的页面" : "无法获取 PDF 预览"}</h3>${tab.message ? `<p>${h(tab.message)}</p>` : ""}<button data-external="${h(tab.path)}">${icon("previewExternal")} 用外部应用打开</button></div></div></div>`;
  }
  const editable = !info.encrypted;
  const attr = (disabled) => disabled ? "disabled" : "";
  const btn = (id, label, glyph, {disabled = false, pressed, iconOnly = false} = {}) => `<button type="button" data-pdf-command="${id}" class="${iconOnly ? "pdf-icon-button" : ""}" ${attr(disabled)} ${pressed == null ? "" : `aria-pressed="${pressed}"`} title="${label}" aria-label="${label}">${glyph ? icon(glyph) : ""}${iconOnly ? "" : `<span>${label}</span>`}</button>`;
  const menu = (label, name, items, className = "") => `<details class="action-menu pdf-menu ${className}"><summary title="${label}" aria-label="${label}">${icon(name)}${className ? "" : `<span>${label}</span>${icon("chevron")}`}</summary><div>${items}</div></details>`;
  const pageTools = menu("页面操作", "previewBook", [
    btn("rotate", "顺时针旋转当前页"), btn("crop", "裁剪当前页可见区域…"),
    btn("up", "当前页前移", "", {disabled: ui.page === 0}), btn("down", "当前页后移", "", {disabled: ui.page === pages.length - 1}),
    btn("merge", "追加 PDF 合并…"), btn("extract", "提取指定页面…"), btn("split", "每页拆分为独立 PDF…"),
    btn("delete", "删除当前页…", "", {disabled: pages.length < 2}),
  ].join(""));
  const annotations = menu("批注", "previewPen", [btn("highlight", "高亮文字"), btn("underline", "下划线"), btn("strike", "删除线"), btn("note", "添加便签…"), btn("objects", "对象与批注")].join(""));
  const more = menu("更多 PDF 操作", "more", `<button data-ocr-current>${icon("previewScan")} 交给搞操作 OCR</button>${btn("objects", "对象与批注", "previewPen")}
      ${editable ? `<button id="save-as">${icon("save")} 另存为…</button>${!tab.dirty && !ui.editing ? '<button id="save">保存 PDF</button>' : ""}` : ""}
      ${info.canRecover ? btn("recover", "另存恢复副本…", "restore") : ""}`, "align-right pdf-more");
  const sheets = pages.map((page, index) => pdfSheet(tab, page, index)).join("");
  return `<div class="pdf-workspace" data-pdf-id="${h(tab.id)}">
    <div class="pdf-document-head">${identification}<div class="pdf-head-actions">
      ${editable ? btn("edit", ui.editing ? "完成编辑" : "编辑 PDF", "previewPen", {pressed: ui.editing}) : ""}
      ${editable && (tab.dirty || ui.editing) ? `<button id="save" aria-label="保存 PDF" title="保存 PDF" ${tab.dirty ? 'class="primary"' : ""}>${icon("save")}<span>保存 PDF</span></button>` : ""}${more}
    </div></div>
    <div class="pdf-reading" aria-label="PDF 阅读工具">
      <div class="pdf-tool-cluster">${btn("thumbs", "页面导航", "sidebar", {pressed: ui.navigation !== false, iconOnly: true})}
      ${btn("prev", "上一页", "previewPrevious", {disabled: ui.page === 0, iconOnly: true})}<label class="pdf-page-number"><input id="pdf-page-number" aria-label="页码" type="number" min="1" max="${pages.length}" value="${ui.page + 1}"><span>/ ${pages.length}</span></label>
      ${btn("next", "下一页", "previewNext", {disabled: ui.page === pages.length - 1, iconOnly: true})}</div>
      <div class="pdf-tool-cluster">${btn("zoom-out", "缩小", "previewMinus", {iconOnly: true})}<output id="pdf-zoom-value" class="pdf-count">—</output>${btn("zoom-in", "放大", "previewPlus", {iconOnly: true})}
      ${btn("fit", "适合窗口", "previewFit", {iconOnly: true})}${btn("spread", "双页阅读", "previewBook", {pressed: ui.spread, iconOnly: true})}</div>
      <div class="pdf-tool-cluster pdf-reading-end">${btn("search", "搜索", "search", {pressed: ui.searchOpen})}${btn("forms", "表单", "previewForm", {pressed: ui.inspector === "forms"})}</div>
    </div>
    ${ui.editing ? `<div class="pdf-edit-tools" aria-label="PDF 编辑工具">
      <div class="pdf-tool-cluster">${btn("text", "插入文字", "previewText")}${btn("image", "插入图片", "previewImage")}${annotations}</div>
      <div class="pdf-tool-cluster">${pageTools}${btn("undo", "撤销 PDF 修改", "previewUndo", {disabled: !info.canUndo, iconOnly: true})}${btn("redo", "重做 PDF 修改", "previewRedo", {disabled: !info.canRedo, iconOnly: true})}</div>
    </div>` : ""}
    ${ui.searchOpen ? `<form id="pdf-find" class="pdf-find" role="search"><label>${icon("search")}<input type="search" maxlength="256" aria-label="搜索 PDF 文字" placeholder="搜索 PDF 文字" value="${h(ui.query)}"></label><button class="pdf-find-submit" type="submit">查找</button><output class="pdf-find-count" aria-live="polite">${ui.hits.length ? `${ui.hit + 1} / ${ui.hits.length}` : ui.query ? "没有匹配" : ""}</output>${btn("find-prev", "上一个结果", "chevron", {disabled: !ui.hits.length, iconOnly: true})}${btn("find-next", "下一个结果", "chevron", {disabled: !ui.hits.length, iconOnly: true})}${btn("search", "关闭搜索", "close", {iconOnly: true})}</form>` : ""}
    ${ui.placement ? `<div class="pdf-inline-notice pdf-placement" role="status">${icon("previewPen")} ${h(ui.placement.label)}${btn("cancel", "取消放置")}</div>` : ""}
    ${info.signed || tab.message ? `<div class="pdf-inline-notice pdf-caution" role="status">${icon("previewAlert")}<span>${h(tab.message || "此文件含数字签名字段，修改后请另存副本。")}</span>${info.canRecover ? btn("recover", "另存恢复副本…") : ""}</div>` : ""}
    <div class="pdf-layout">
      ${ui.navigation === false ? "" : pdfNavigation(tab, ui)}
      <div class="pdf-canvas ${ui.spread ? "pdf-spread" : ""} ${ui.placement ? "pdf-placing" : ""}" aria-label="PDF 阅读区" tabindex="0">${sheets}</div>
      ${ui.inspector ? pdfInspector(tab) : ""}
    </div>
    ${ui.notice || info.xfa ? `<div class="pdf-footer" role="status">${h(ui.notice || "XFA 动态表单仅供查看")}</div>` : ""}
    <dialog class="pdf-dialog" aria-labelledby="pdf-dialog-title"></dialog></div>`;
}

function pdfNavigation(tab, ui) {
  const pages = tab.preview.pages;
  const content = ui.navigationPane === "pages" ? `<div class="pdf-thumbnails" aria-label="缩略图">${pages.map((page, index) => `<button data-pdf-page="${index}" aria-current="${index === ui.page ? "page" : "false"}" aria-label="第 ${index + 1} 页"><span class="pdf-thumbnail"><img src="${pdfImageURL(tab, index, 180)}" loading="lazy" alt="" style="aspect-ratio:${pdfRatio(page)}"></span><span>${index + 1}</span></button>`).join("")}</div>`
    : `<div class="pdf-outline">${tab.preview.outline.map((item) => `<button class="pdf-outline-row" ${item.page == null ? "disabled" : `data-pdf-page="${item.page}"`} style="--outline-indent:${Math.min(5, item.depth) * 12}px" title="${h(item.title)}">${h(item.title)}</button>`).join("") || '<p>此 PDF 没有目录书签。</p>'}</div>`;
  return `<div class="pdf-navigation" data-navigation="${ui.navigation === null ? "auto" : "open"}" aria-label="页面导航"><div class="pdf-side-head"><strong>页面导航</strong><button type="button" data-pdf-command="thumbs" class="pdf-icon-button" aria-label="关闭页面导航" title="关闭页面导航">${icon("close")}</button></div><div class="pdf-side-tabs"><button data-pdf-nav="pages" aria-pressed="${ui.navigationPane === "pages"}">缩略图</button><button data-pdf-nav="outline" aria-pressed="${ui.navigationPane === "outline"}">目录</button></div>${content}</div>`;
}

function pdfRatio(page) {
  return Math.max(1, page.width || 1) / Math.max(1, page.height || 1);
}

function pdfImageURL(tab, page, width) {
  return `/api/pdf/page?tab=${encodeURIComponent(tab.id)}&page=${page}&width=${width}&revision=${encodeURIComponent(tab.preview?.revision || "")}&token=${encodeURIComponent(token)}`;
}

function pdfSheet(tab, page, index) {
  const ui = pdfView(tab);
  const info = tab.preview;
  const match = ui.searchOpen ? ui.hits[ui.hit] : null;
  const highlights = match?.page === index + 1 ? (match.rects || []).map((rect) => `<i class="pdf-search-mark" style="${pdfRectStyle(page, rect)}"></i>`).join("") : "";
  const widgets = (info.fields || []).flatMap((field, fieldIndex) => field.widgets.filter((widget) => widget.page === index).map((widget) => {
    const readonly = field.readonly || info.encrypted;
    const control = field.multi || readonly
      ? `<button aria-label="${h(field.label)}" data-pdf-field-focus="${fieldIndex}"></button>`
      : pdfControl(field, fieldIndex, ui.pending.get(field.name), false, widget);
    return `<div class="pdf-widget-inline" style="${pdfRectStyle(page, widget.rect)}">${control}</div>`;
  })).join("");
  const annotations = (info.annotations || []).filter((item) => item.page === index).map((item) =>
    `<button class="pdf-annotation-target" type="button" aria-label="${h(item.title + (item.text ? ' · ' + item.text : ''))}" title="${h(item.text || item.title)}" data-pdf-annotation="${index}:${item.index}" style="${pdfRectStyle(page, item.rect)}"></button>`).join("");
  return `<article class="pdf-sheet" data-pdf-sheet="${index}" data-pdf-width="${page.width}" style="aspect-ratio:${pdfRatio(page)}">
    <img data-pdf-raster="${index}" loading="lazy" alt="第 ${index + 1} 页"><div class="pdf-raster-state"><span class="pdf-raster-loading">正在载入第 ${index + 1} 页…</span><div class="pdf-raster-error"><p>${icon("previewAlert")} 第 ${index + 1} 页无法预览</p><button type="button" data-pdf-retry>重试</button></div></div>${highlights}${annotations}${widgets}</article>`;
}

function pdfPoint(page, x, y, toPaper = false) {
  const [left, bottom, right, top] = page.box;
  const width = right - left, height = top - bottom;
  if (toPaper) {
    if (page.rotation === 90) return [left + y * width, bottom + x * height];
    if (page.rotation === 180) return [right - x * width, bottom + y * height];
    if (page.rotation === 270) return [right - y * width, top - x * height];
    return [left + x * width, top - y * height];
  }
  const px = (x - left) / width, py = (y - bottom) / height;
  if (page.rotation === 90) return [py, px];
  if (page.rotation === 180) return [1 - px, py];
  if (page.rotation === 270) return [1 - py, 1 - px];
  return [px, 1 - py];
}

function pdfRectStyle(page, rect) {
  const a = pdfPoint(page, rect[0], rect[1]);
  const b = pdfPoint(page, rect[2], rect[3]);
  const units = [Math.min(a[0], b[0]), Math.min(a[1], b[1]), Math.abs(a[0] - b[0]), Math.abs(a[1] - b[1])];
  return ["left", "top", "width", "height"].map((key, i) => `${key}:${units[i] * 100}%`).join(";");
}

function pdfControl(field, index, pending, readonly, widget = null) {
  const value = pending ?? field.value;
  const control = `data-pdf-field="${index}" aria-label="${h(field.label)}" ${readonly ? "disabled" : ""}`;
  if (field.type === "checkbox") {
    const checked = widget?.states[0] || field.options[0]?.value;
    return `<input type="checkbox" ${control} value="${h(checked)}" ${value === checked ? "checked" : ""}>`;
  }
  if (field.type === "radio" && widget) {
    const option = widget.states[0];
    return `<input type="radio" name="pdf-radio-${index}" ${control} value="${h(option)}" ${value === option ? "checked" : ""}>`;
  }
  if (field.type === "radio" || field.type === "choice" && !field.editable) {
    const invalid = field.multi || field.options.some((item) => item.value === value);
    return `<select ${control} ${field.multi ? "multiple" : ""}>${field.multi ? "" : `<option value="${field.type === 'radio' ? '/Off' : ''}" ${invalid ? "" : "selected"}>未选择</option>`}${field.options.map((item) =>
      `<option value="${h(item.value)}" ${(field.multi ? value.includes(item.value) : value === item.value) ? "selected" : ""}>${h(item.label)}</option>`).join("")}</select>`;
  }
  const limit = field.maxLength ? `maxlength="${field.maxLength}"` : 'maxlength="20000"';
  if (field.multiline) return `<textarea ${control} ${limit}>${h(value)}</textarea>`;
  const list = field.editable && !widget ? `list="pdf-options-${index}"` : "";
  return `<input type="${field.password ? "password" : "text"}" ${control} ${limit} ${list} autocomplete="off" value="${h(value)}">
    ${list ? `<datalist id="pdf-options-${index}">${field.options.map((item) => `<option value="${h(item.value)}">${h(item.label)}</option>`).join("")}</datalist>` : ""}`;
}

function pdfInspector(tab) {
  const ui = pdfView(tab), info = tab.preview;
  const tabs = [["forms", "表单"], ["objects", "对象与批注"]];
  let content;
  if (ui.inspector === "forms") {
    content = info.fields.map((field, i) => {
      const readonly = field.readonly || info.encrypted;
      return `<div class="pdf-inspector-item"><div><b>${h(field.label)}</b>${field.widgets[0] ? `<button data-pdf-page="${field.widgets[0].page}">定位</button>` : ""}</div>
        ${field.type === "signature" ? '<span class="muted">数字签名字段 · 只读</span>' : field.type === "button" ? '<span class="muted">PDF 操作按钮 · 只读</span>' : readonly ? `<span class="muted">${field.password ? "密码字段" : h(field.value)} · 只读</span>` : pdfControl(field, i, ui.pending.get(field.name), false)}
      </div>`;
    }).join("") || `<div class="pdf-inspector-empty">${icon("previewForm")}<p>此 PDF 没有可填写的表单字段。</p>${info.encrypted ? "" : '<button data-pdf-command="text">插入文字…</button>'}</div>`;
  } else {
    content = info.annotations.map((item) => {
      const id = `${item.page}:${item.index}`;
      const edit = !info.encrypted && !item.readonly;
      return `<div class="pdf-inspector-item" data-pdf-object="${id}"><div><b>${h(item.title)}</b><span class="muted">第 ${item.page + 1} 页</span></div>
        ${item.text ? `<p>${h(item.text)}</p>` : ""}<div class="pdf-object-actions"><button data-pdf-page="${item.page}">定位</button>
        ${edit && item.canEdit ? `<button data-pdf-object-action="edit" data-object="${id}">编辑</button>` : ""}
        ${edit && item.canMove ? `<button data-pdf-object-action="move" data-object="${id}">移动</button><button data-pdf-object-action="size" data-object="${id}">尺寸</button>` : ""}
        ${edit ? `<button data-pdf-object-action="remove" data-object="${id}">删除</button>` : ""}</div></div>`;
    }).join("") || `<div class="pdf-inspector-empty">${icon("previewPen")}<p>此 PDF 暂无批注。</p></div>`;
  }
  return `<div class="pdf-inspector" aria-label="PDF 检查器"><div class="pdf-side-head"><strong>检查器</strong><button type="button" data-pdf-command="close-inspector" class="pdf-icon-button" title="关闭检查器" aria-label="关闭检查器">${icon("close")}</button></div><div class="pdf-side-tabs">${tabs.map(([id, name]) => `<button data-pdf-pane="${id}" aria-pressed="${ui.inspector === id}">${name}</button>`).join("")}</div><div class="pdf-inspector-body">${content}</div></div>`;
}

function bindPdf() {
  pdfResize?.disconnect();
  const tab = selected();
  if (tab?.kind !== "pdf") return;
  const unlock = document.getElementById("pdf-unlock");
  if (unlock) {
    unlock.onsubmit = async (event) => {
      event.preventDefault();
      const input = unlock.querySelector("input");
      const submit = unlock.querySelector("button");
      const password = input.value;
      input.value = "";
      submit.disabled = true;
      document.querySelector("#pdf-unlock-status").textContent = "正在解锁…";
      await pdfAction(tab, "unlock", {password});
    };
    return;
  }
  const workspace = document.querySelector(".pdf-workspace");
  const canvas = workspace?.querySelector(".pdf-canvas");
  if (!canvas) return;
  const ui = pdfView(tab), info = tab.preview;
  const sheets = Array.from(canvas.querySelectorAll(".pdf-sheet"));
  const number = workspace.querySelector("#pdf-page-number");
  const thumbs = workspace.querySelector(".pdf-thumbnails");
  const navigation = workspace.querySelector(".pdf-navigation");
  const hasNavigation = () => Boolean(navigation && getComputedStyle(navigation).display !== "none");
  const syncControls = () => {
    number.value = ui.page + 1;
    for (const [id, disabled] of [["prev", ui.page === 0], ["next", ui.page === sheets.length - 1], ["up", info.encrypted || ui.page === 0], ["down", info.encrypted || ui.page === sheets.length - 1]]) {
      const control = workspace.querySelector(`[data-pdf-command="${id}"]`);
      if (control) control.disabled = disabled;
    }
    thumbs?.querySelectorAll("[data-pdf-page]").forEach((button) => { button.setAttribute("aria-current", Number(button.dataset.pdfPage) === ui.page ? "page" : "false"); });
    const factor = ui.zoom || (sheets[ui.page]?.offsetWidth || 1) / (info.pages[ui.page]?.width || 1);
    workspace.querySelector("#pdf-zoom-value").textContent = Math.round(factor * 100) + "%";
    workspace.querySelector(".pdf-reading [data-pdf-command='thumbs']").setAttribute("aria-pressed", String(hasNavigation()));
  };
  const jump = (page) => {
    ui.page = Math.max(0, Math.min(page, info.pages.length - 1));
    if (sheets[ui.page]) canvas.scrollTop = sheets[ui.page].offsetTop - 20;
    ui.scroll = canvas.scrollTop;
    syncControls();
    const inView = thumbs?.querySelector(`[data-pdf-page="${ui.page}"]`);
    if (inView && (inView.offsetTop < thumbs.scrollTop || inView.offsetTop + inView.offsetHeight > thumbs.scrollTop + thumbs.clientHeight)) {
      inView.scrollIntoView({block: "nearest"});
    }
  };
  const resize = () => {
    const columns = ui.spread ? 2 : 1;
    const fit = Math.min(920, Math.max(85, (canvas.clientWidth - (columns === 2 ? 56 : 36)) / columns));
    const visible = info.pages[ui.page];
    const scale = ui.zoom || Math.min(1.7, fit / (visible?.width || 595), (canvas.clientHeight - 37) / (visible?.height || 842));
    for (const sheet of sheets) {
      const width = ui.zoom ? Number(sheet.dataset.pdfWidth) * ui.zoom : Math.min(fit, Number(sheet.dataset.pdfWidth) * scale);
      sheet.style.width = `${width}px`;
      const resolution = Math.max(200, Math.min(2400, Math.ceil(width * Math.min(devicePixelRatio || 1, 2) / 100) * 100));
      const image = sheet.querySelector("[data-pdf-raster]");
      const url = pdfImageURL(tab, Number(image.dataset.pdfRaster), resolution);
      if (image.dataset.source !== url) {
        image.dataset.source = url;
        sheet.classList.remove("pdf-image-error", "pdf-image-ready");
        image.onerror = () => { sheet.classList.remove("pdf-image-ready"); sheet.classList.add("pdf-image-error"); };
        image.onload = () => { sheet.classList.remove("pdf-image-error"); sheet.classList.add("pdf-image-ready"); };
        image.src = url;
      }
    }
    if (ui.jump) { ui.jump = false; jump(ui.page); }
    else syncControls();
  };
  workspace.querySelectorAll("[data-pdf-retry]").forEach((button) => { button.onclick = (event) => {
    event.stopPropagation();
    const sheet = button.closest(".pdf-sheet"), image = sheet.querySelector("img");
    sheet.classList.remove("pdf-image-error");
    image.src = `${image.dataset.source}&retry=${Date.now()}`;
  }; });
  resize();
  if (ui.scroll && !ui.jump) canvas.scrollTop = ui.scroll;
  if (window.ResizeObserver) {
    pdfResize = new ResizeObserver(resize);
    pdfResize.observe(canvas);
  }
  canvas.onscroll = () => {
    ui.scroll = canvas.scrollTop;
    const at = canvas.scrollTop + 34;
    let closest = ui.page;
    if (!sheets[closest] || Math.abs(sheets[closest].offsetTop - at) > 35) {
      for (let index = 0; index < sheets.length; index++) {
        const sheet = sheets[index];
        if (sheet.offsetTop <= at && at < sheet.offsetTop + sheet.offsetHeight) { closest = index; break; }
      }
    }
    if (closest !== ui.page) {
      ui.page = closest;
      syncControls();
    }
  };
  workspace.querySelectorAll("[data-pdf-page]").forEach((node) => { node.onclick = () => jump(Number(node.dataset.pdfPage)); });
  workspace.querySelectorAll("[data-pdf-nav]").forEach((node) => { node.onclick = () => {
    ui.navigationPane = node.dataset.pdfNav;
    render();
    document.querySelector(`[data-pdf-nav="${ui.navigationPane}"]`)?.focus();
  }; });
  workspace.querySelectorAll("[data-pdf-pane]").forEach((node) => { node.onclick = () => { ui.inspector = node.dataset.pdfPane; render(); }; });
  number.onchange = () => jump(Number(number.value || 1) - 1);
  workspace.querySelectorAll("[data-pdf-command]").forEach((node) => { node.onclick = () => {
    const menu = node.closest("details");
    if (menu) menu.open = false;
    pdfCommand(tab, node.dataset.pdfCommand, jump, canvas).catch(fail);
  }; });
  const finder = workspace.querySelector("#pdf-find");
  if (finder) finder.onsubmit = async (event) => {
    event.preventDefault();
    const submit = finder.querySelector('[type="submit"]');
    submit.disabled = true;
    finder.querySelector("output").textContent = "正在搜索…";
    await pdfFind(tab, event.target.querySelector("input").value);
  };
  workspace.onkeydown = (event) => {
    if (event.ctrlKey && event.key.toLowerCase() === "f") {
      event.preventDefault();
      if (!ui.searchOpen) { ui.searchOpen = true; render(); }
      const search = document.querySelector("#pdf-find input");
      search?.focus();
      search?.select();
    } else if (ui.searchOpen && event.key === "Escape" && finder?.contains(event.target)) {
      event.preventDefault();
      pdfCommand(tab, "search", jump, canvas).catch(fail);
    }
  };
  workspace.querySelectorAll("[data-pdf-field]").forEach((input) => {
    const field = info.fields[Number(input.dataset.pdfField)];
    const remember = () => {
      const value = input.type === "checkbox" ? (input.checked ? input.value : "/Off")
        : input.multiple ? Array.from(input.selectedOptions, (option) => option.value) : input.value;
      ui.pending.set(field.name, value);
    };
    input.oninput = remember;
    input.onchange = () => { remember(); flushPdfFields(tab, true); };
    if (input.tagName === "INPUT" && ["text", "password"].includes(input.type)) {
      input.onkeydown = (event) => { if (event.key === "Enter") { event.preventDefault(); input.blur(); } };
    }
  });
  workspace.querySelectorAll("[data-pdf-field-focus]").forEach((node) => { node.onclick = () => {
    ui.inspector = "forms";
    render();
    document.querySelector(`.pdf-inspector [data-pdf-field="${node.dataset.pdfFieldFocus}"]`)?.focus();
  }; });
  const findObject = (id) => info.annotations.find((item) => `${item.page}:${item.index}` === id);
  workspace.querySelectorAll("[data-pdf-object-action]").forEach((node) => {
    node.onclick = () => pdfObjectAction(tab, findObject(node.dataset.object), node.dataset.pdfObjectAction).catch(fail);
  });
  workspace.querySelectorAll("[data-pdf-annotation]").forEach((node) => {
    node.ondblclick = () => {
      const item = findObject(node.dataset.pdfAnnotation);
      if (item?.canEdit && !info.encrypted && !item.readonly) pdfObjectAction(tab, item, "edit").catch(fail);
      else { ui.inspector = "objects"; render(); }
    };
  });
  if (ui.placement) bindPdfPlacement(tab, canvas);
}

async function flushPdfFields(tab, refreshView = false) {
  const ui = pdfView(tab);
  if (ui.formWork && !(await ui.formWork)) return false;
  if (!ui.pending.size) return true;
  const values = Object.fromEntries(ui.pending);
  ui.formWork = (async () => {
    try {
      await api("/api/tabs/pdf", {id: tab.id, op: "form", values});
      for (const [key, value] of Object.entries(values)) if (ui.pending.get(key) === value) ui.pending.delete(key);
      if (refreshView && selected()?.id === tab.id && !ui.pending.size) {
        const active = document.activeElement;
        const restore = active?.matches("[data-pdf-field]") ? {id: active.dataset.pdfField, side: active.closest(".pdf-inspector") ? ".pdf-inspector" : ".pdf-canvas"} : null;
        render();
        if (restore) document.querySelector(`${restore.side} [data-pdf-field="${restore.id}"]`)?.focus({preventScroll: true});
      }
      return true;
    } catch (error) {
      fail(error);
      return false;
    } finally {
      ui.formWork = null;
    }
  })();
  return ui.formWork;
}

async function pdfAction(tab, operation, args = {}, success = "") {
  if (operation !== "unlock" && !(await flushPdfFields(tab))) return false;
  const ui = pdfView(tab);
  try {
    const response = await api("/api/tabs/pdf", {id: tab.id, op: operation, ...args});
    if (["delete", "reorder", "undo", "redo"].includes(operation)) ui.hits = [];
    ui.notice = success || (response.result?.paths?.length ? `已拆分为 ${response.result.paths.length} 个 PDF` : "");
    if (selected()?.id === tab.id) render();
    return true;
  } catch (error) { fail(error); return false; }
}

async function pdfSave(tab, asCopy) {
  if (!(await flushPdfFields(tab))) return false;
  tab = state.tabs.find((item) => item.id === tab.id) || tab;
  if (tab.preview?.encrypted) return false;
  if (tab.preview?.signed && tab.dirty && !asCopy) {
    if (!confirm("修改将影响已有数字签名。另存副本并保留原件？")) return false;
    asCopy = true;
  }
  try {
    let path = tab.path;
    if (asCopy || !path) path = await fileDialog("save", tab.title.replace(/\.pdf$/i, "") + "-副本.pdf");
    if (!path) return false;
    if (asCopy && !/\.pdf$/i.test(path)) path += ".pdf";
    await api("/api/tabs/save", {id: tab.id, path, asCopy});
    pdfView(tab).notice = state.status;
    if (selected()?.id === tab.id) render();
    return true;
  } catch (error) { fail(error); return false; }
}

async function pdfFind(tab, query) {
  const ui = pdfView(tab);
  try {
    ui.query = query.trim();
    const amount = ui.query ? await api("/api/tabs/pdf", {id: tab.id, op: "search", query: ui.query}) : null;
    ui.hits = amount?.result?.matches || [];
    ui.hit = 0;
    if (ui.hits.length) { ui.page = ui.hits[0].page - 1; ui.jump = true; }
    if (selected()?.id === tab.id) {
      render();
      document.querySelector("#pdf-find input")?.focus({preventScroll: true});
    }
  } catch (error) { fail(error); }
}

async function pdfCommand(tab, command, jump, canvas) {
  const ui = pdfView(tab);
  const page = ui.page, count = tab.preview.pages.length;
  if (command === "prev" || command === "next") return jump(page + (command === "prev" ? -1 : 1));
  if (command === "search") {
    ui.searchOpen = !ui.searchOpen;
    render();
    document.querySelector(ui.searchOpen ? "#pdf-find input" : '.pdf-reading [data-pdf-command="search"]')?.focus();
    return;
  }
  if (["thumbs", "spread", "forms", "objects", "close-inspector", "edit", "fit", "zoom-out", "zoom-in", "cancel"].includes(command)) {
    const area = canvas.closest(".pdf-workspace"), compact = area.clientWidth <= 760;
    if (command === "thumbs") {
      const visible = area.querySelector(".pdf-navigation");
      ui.navigation = !visible || getComputedStyle(visible).display === "none";
      if (compact && ui.navigation) ui.inspector = "";
    }
    if (command === "spread") ui.spread = !ui.spread;
    if (["forms", "objects"].includes(command)) {
      ui.inspector = command === "forms" && ui.inspector === "forms" ? "" : command;
      if (compact && ui.inspector) ui.navigation = false;
    }
    if (command === "close-inspector") ui.inspector = "";
    if (command === "edit") { ui.editing = !ui.editing; if (!ui.editing) ui.placement = null; }
    if (command === "fit") ui.zoom = 0;
    if (command.startsWith("zoom-")) {
      const rendered = canvas.querySelector(`[data-pdf-sheet="${page}"]`)?.offsetWidth || 595;
      const scale = ui.zoom || rendered / (tab.preview.pages[page]?.width || 595);
      ui.zoom = Math.max(0.25, Math.min(5, scale * (command === "zoom-out" ? 1 / 1.2 : 1.2)));
    }
    if (command === "cancel") ui.placement = null;
    ui.jump = true;
    render();
    document.querySelector(`[data-pdf-command="${command === "close-inspector" ? "forms" : command}"]`)?.focus({preventScroll: true});
    return;
  }
  if (command.startsWith("find-")) {
    if (!ui.hits.length) return;
    ui.hit = (ui.hit + ui.hits.length + (command === "find-prev" ? -1 : 1)) % ui.hits.length;
    ui.page = ui.hits[ui.hit].page - 1;
    ui.jump = true;
    render();
    document.querySelector(`[data-pdf-command="${command}"]`)?.focus({preventScroll: true});
    return;
  }
  if (command === "rotate") return pdfAction(tab, "rotate", {pages: [page], degrees: 90});
  if (command === "delete") {
    if (!confirm(`删除第 ${page + 1} 页？可在保存前撤销。`)) return;
    ui.jump = true;
    return pdfAction(tab, "delete", {pages: [page]});
  }
  if (command === "up" || command === "down") {
    const next = page + (command === "up" ? -1 : 1);
    const order = Array.from({length: count}, (_, index) => index);
    [order[page], order[next]] = [order[next], order[page]];
    ui.page = next;
    ui.jump = true;
    return pdfAction(tab, "reorder", {order});
  }
  if (command === "undo" || command === "redo") return pdfAction(tab, command);
  if (command === "crop") {
    const result = await pdfDialog("裁剪可见区域", ["上", "左", "下", "右"].map((name, index) =>
      ({name: `margin${index}`, label: name + "（点）", type: "number", value: 0, min: 0, step: "any"})), "应用");
    if (result) return pdfAction(tab, "crop", {pages: [page], margins: [0, 1, 2, 3].map((index) => Number(result[`margin${index}`]))});
    return;
  }
  if (command === "merge") {
    const path = await fileDialog("open");
    if (path) return pdfAction(tab, "merge", {path});
    return;
  }
  if (command === "extract") {
    const output = await pdfDialog("提取页面", [{name: "range", label: `页码或范围（1–${count}）`, value: page + 1}], "选择保存位置…");
    if (!output) return;
    const pages = pdfPageRange(output.range, count);
    const path = await fileDialog("save", tab.title.replace(/\.pdf$/i, "") + "-提取.pdf");
    if (path) return pdfAction(tab, "extract", {pages, path: /\.pdf$/i.test(path) ? path : path + ".pdf"}, `已提取 ${pages.length} 页`);
    return;
  }
  if (command === "split") {
    const directory = await fileDialog("folder");
    if (directory) return pdfAction(tab, "split", {directory});
    return;
  }
  if (command === "recover") {
    const path = await fileDialog("save", tab.title.replace(/\.pdf$/i, "") + "-恢复.pdf");
    if (path) return pdfAction(tab, "recovery-copy", {path: /\.pdf$/i.test(path) ? path : path + ".pdf"}, "已导出恢复副本");
    return;
  }
  if (["text", "note", "image"].includes(command)) {
    let args;
    if (command === "image") {
      const path = await fileDialog("open");
      if (!path) return;
      const width = await pdfDialog("插入图片", [{name: "width", label: "图片宽度（点，等比缩放）", type: "number", min: 1, value: 180}], "放置到页面");
      if (width) args = {path, width: Number(width.width)};
    } else {
      args = await pdfTextDialog(command === "note");
    }
    if (!args) return;
    ui.editing = true;
    ui.placement = {operation: command === "image" ? "image-file" : command, args, label: `点击页面放置${{image:"图片", text:"文字", note:"便签"}[command]}`};
    return render();
  }
  if (["highlight", "underline", "strike"].includes(command)) {
    const match = ui.searchOpen ? ui.hits[ui.hit] : null;
    if (match?.page === page + 1 && match.rects.length) return pdfAction(tab, "markup", {page, kind: command, rects: match.rects});
    ui.placement = {operation: "markup", args: {kind: command}, label: "在页面上拖动框选文字"};
    return render();
  }
}

function pdfPageRange(source, count) {
  const pages = new Set();
  for (const piece of source.replaceAll("，", ",").replace(/[–—]/g, "-").split(",")) {
    const range = /^\s*(\d+)\s*(?:-\s*(\d+)\s*)?$/.exec(piece);
    if (!range || Number(range[1]) < 1 || Number(range[2] || range[1]) > count || Number(range[2] || range[1]) < Number(range[1])) {
      throw new Error(`页码范围无效。请输入 1,3-5 这种格式且页码不超过 ${count}。`);
    }
    for (let page = Number(range[1]); page <= Number(range[2] || range[1]); page++) pages.add(page - 1);
  }
  return [...pages];
}

async function pdfTextDialog(note, item = null) {
  const fields = [{name: "text", label: note ? "便签内容" : "文字", type: "textarea", value: item?.text || ""}];
  if (!note) fields.push({name: "size", label: "字号（点）", type: "number", min: 6, max: 96, value: item?.size || 14},
    {name: "color", label: "颜色", type: "color", value: item?.color || "#202020"});
  const result = await pdfDialog(item ? "编辑批注" : (note ? "添加便签" : "插入文字"), fields, item ? "应用" : "放置到页面");
  return result ? {...result, ...(note ? {} : {size: Number(result.size)})} : null;
}

async function pdfObjectAction(tab, item, action) {
  if (!item) return;
  const ui = pdfView(tab);
  const props = {page: item.page, index: item.index};
  if (action === "remove") {
    if (confirm(`删除第 ${item.page + 1} 页的${item.title}？`)) return pdfAction(tab, "annotation-delete", props);
    return;
  }
  if (action === "edit") {
    const result = await pdfTextDialog(item.type === "/Text", item);
    if (result) return pdfAction(tab, "annotation-edit", {...props, ...result});
    return;
  }
  if (action === "move") {
    ui.page = item.page;
    ui.jump = true;
    ui.placement = {operation: "annotation-edit", args: props, label: "点击本页新位置"};
    return render();
  }
  if (action === "size") {
    const fields = [{name: "width", label: "宽度（点）", type: "number", min: 1, step: "any", value: Number((item.rect[2] - item.rect[0]).toFixed(1))}];
    if (!item.image) fields.push({name: "height", label: "高度（点）", type: "number", min: 1, step: "any", value: Number((item.rect[3] - item.rect[1]).toFixed(1))});
    const result = await pdfDialog("调整对象尺寸", fields, "应用");
    if (result) return pdfAction(tab, "annotation-edit", {...props, ...Object.fromEntries(Object.entries(result).map(([name, value]) => [name, Number(value)]))});
  }
}

function pdfDialog(title, fields, submitLabel) {
  const dialog = document.querySelector(".pdf-dialog");
  dialog.innerHTML = `<form method="dialog"><h2 id="pdf-dialog-title">${h(title)}</h2>${fields.map((field) => {
    const attrs = `name="${field.name}" ${field.min != null ? `min="${field.min}"` : ""} ${field.max != null ? `max="${field.max}"` : ""} ${field.step != null ? `step="${field.step}"` : ""}`;
    return `<label>${h(field.label)}${field.type === "textarea" ? `<textarea ${attrs} rows="4" maxlength="4000" required>${h(field.value)}</textarea>` : `<input type="${field.type || "text"}" ${attrs} value="${h(field.value)}" required>`}</label>`;
  }).join("")}<div class="pdf-dialog-actions"><button type="submit" formnovalidate value="cancel">取消</button><button class="primary" type="submit" value="apply">${h(submitLabel)}</button></div></form>`;
  dialog.returnValue = "";
  dialog.showModal();
  return new Promise((resolve) => { dialog.addEventListener("close", () => resolve(dialog.returnValue === "apply" ? Object.fromEntries(new FormData(dialog.querySelector("form"))) : null), {once: true}); });
}

function bindPdfPlacement(tab, canvas) {
  const ui = pdfView(tab);
  const placement = ui.placement;
  const point = (sheet, event) => {
    const area = sheet.getBoundingClientRect();
    return [Math.max(0, Math.min(1, (event.clientX - area.left) / area.width)), Math.max(0, Math.min(1, (event.clientY - area.top) / area.height))];
  };
  canvas.onkeydown = (event) => { if (event.key === "Escape") { ui.placement = null; render(); } };
  if (placement.operation !== "markup") {
    canvas.onclick = (event) => {
      const sheet = event.target.closest("[data-pdf-sheet]");
      if (!sheet) return;
      const page = Number(sheet.dataset.pdfSheet);
      if (placement.operation === "annotation-edit" && page !== placement.args.page) { ui.notice = "请在原页面内选择位置"; return; }
      const [x, y] = pdfPoint(tab.preview.pages[page], ...point(sheet, event), true);
      const args = {...placement.args, page, x, y};
      ui.page = page;
      ui.placement = null;
      ui.inspector ||= "objects";
      pdfAction(tab, placement.operation, args);
    };
    return;
  }
  let drag;
  canvas.onpointerdown = (event) => {
    const sheet = event.target.closest("[data-pdf-sheet]");
    if (!sheet || event.button !== 0) return;
    event.preventDefault();
    const marker = document.createElement("i");
    marker.className = "pdf-drag-mark";
    sheet.append(marker);
    drag = {sheet, marker, start: point(sheet, event)};
    canvas.setPointerCapture(event.pointerId);
  };
  canvas.onpointermove = (event) => {
    if (!drag) return;
    const end = point(drag.sheet, event), a = drag.start;
    Object.assign(drag.marker.style, {left: `${Math.min(a[0], end[0]) * 100}%`, top: `${Math.min(a[1], end[1]) * 100}%`,
      width: `${Math.abs(a[0] - end[0]) * 100}%`, height: `${Math.abs(a[1] - end[1]) * 100}%`});
  };
  canvas.onpointerup = (event) => {
    if (!drag) return;
    const page = Number(drag.sheet.dataset.pdfSheet);
    const a = pdfPoint(tab.preview.pages[page], ...drag.start, true);
    const b = pdfPoint(tab.preview.pages[page], ...point(drag.sheet, event), true);
    drag.marker.remove();
    drag = null;
    if (Math.abs(a[0] - b[0]) < 2 || Math.abs(a[1] - b[1]) < 2) return;
    ui.placement = null;
    ui.inspector ||= "objects";
    pdfAction(tab, "markup", {...placement.args, page, selection: [Math.min(a[0], b[0]), Math.min(a[1], b[1]), Math.max(a[0], b[0]), Math.max(a[1], b[1])]});
  };
  canvas.onpointercancel = () => { drag?.marker.remove(); drag = null; };
}
