const pdfViews = new Map();
let pdfResize;

function pdfView(tab) {
  if (!pdfViews.has(tab.id)) {
    pdfViews.set(tab.id, {page: 0, thumbnails: true, spread: false, zoom: 0, inspector: "", query: "",
      hits: [], hit: 0, pending: new Map(), placement: null, jump: true, scroll: 0, notice: ""});
  }
  return pdfViews.get(tab.id);
}

function pdfPanel(tab) {
  const info = tab.preview || {};
  if (info.locked) {
    return `<div class="pdf-locked"><form id="pdf-unlock">${icon("doc")}<h2>输入 PDF 密码</h2>
      <input aria-label="PDF 密码" type="password" autocomplete="off" autofocus><button class="primary">解锁阅读</button>
      <p class="muted">加密文件仅供阅读，保留原有加密设置。</p></form></div>`;
  }
  const ui = pdfView(tab);
  const pages = info.pages || [];
  ui.page = Math.max(0, Math.min(ui.page, pages.length - 1));
  const editable = !info.encrypted;
  const attr = (disabled) => disabled ? "disabled" : "";
  const menu = (label, items) => `<details class="action-menu pdf-menu"><summary>${label} ${icon("chevron")}</summary><div>${items}</div></details>`;
  const cmd = (id, label, disabled) => `<button type="button" data-pdf-command="${id}" ${attr(disabled)}>${label}</button>`;
  const pageTools = menu("页面", [
    cmd("rotate", "顺时针旋转当前页", !editable), cmd("crop", "裁剪当前页可见区域…", !editable),
    cmd("up", "当前页前移", !editable || ui.page === 0), cmd("down", "当前页后移", !editable || ui.page === pages.length - 1),
    cmd("delete", "删除当前页…", !editable || pages.length < 2), cmd("merge", "追加 PDF 合并…", !editable),
    cmd("extract", "提取指定页面…", !editable), cmd("split", "每页拆分为独立 PDF…", !editable),
  ].join(""));
  const findings = ui.hits.length ? `<span class="pdf-find-count">${ui.hit + 1} / ${ui.hits.length}</span>${cmd("find-prev", "↑")}${cmd("find-next", "↓")}` : "";
  const sheets = pages.map((page, index) => pdfSheet(tab, page, index)).join("");
  return `<div class="pdf-workspace" data-pdf-id="${h(tab.id)}">
    <div class="pdf-bar pdf-reading">
      <button data-pdf-command="thumbs" aria-label="显示或隐藏缩略图" title="显示或隐藏缩略图" aria-pressed="${ui.thumbnails}">${icon("sidebar")}</button>
      <button data-pdf-command="prev" aria-label="上一页" ${attr(ui.page === 0)}>‹</button>
      <input id="pdf-page-number" aria-label="页码" type="number" min="1" max="${pages.length}" value="${ui.page + 1}"><span class="muted pdf-count">/ ${pages.length}</span>
      <button data-pdf-command="next" aria-label="下一页" ${attr(ui.page >= pages.length - 1)}>›</button>
      <span class="pdf-divider"></span>
      <button data-pdf-command="zoom-out" aria-label="缩小" title="缩小">−</button><span id="pdf-zoom-value" class="pdf-count"></span>
      <button data-pdf-command="zoom-in" aria-label="放大" title="放大">+</button>${cmd("fit", "适合")}
      <button data-pdf-command="spread" title="双页阅读" aria-pressed="${ui.spread}">双页</button>
      <form id="pdf-find" class="pdf-find">${icon("search")}<input type="search" aria-label="搜索 PDF 文字" placeholder="搜索 PDF 文字" value="${h(ui.query)}">${findings}</form>
      <button class="pdf-inspector-toggle" data-pdf-command="inspector" aria-label="批注、表单与目录" aria-pressed="${Boolean(ui.inspector)}">${icon("sidebar")}</button>
      <button data-ocr-current>交给搞操作 OCR</button>
    </div><div class="pdf-bar">
      ${cmd("text", "插入文字", !editable)}${cmd("image", "插入图片", !editable)}
      ${menu("批注", [cmd("highlight", "高亮文字", !editable), cmd("underline", "下划线", !editable),
          cmd("strike", "删除线", !editable), cmd("note", "添加便签…", !editable), cmd("objects", "对象与批注")].join(""))}
      ${pageTools}<button data-pdf-command="undo" title="撤销 PDF 修改" aria-label="撤销 PDF 修改" ${attr(!info.canUndo)}>↶</button>
      <button data-pdf-command="redo" title="重做 PDF 修改" aria-label="重做 PDF 修改" ${attr(!info.canRedo)}>↷</button>
      ${ui.placement ? `<span class="pdf-placement">${h(ui.placement.label)}</span>${cmd("cancel", "取消")}` : ""}
      ${info.canRecover ? cmd("recover", "另存恢复副本…") : ""}<span class="pdf-flex"></span>
      <button id="save-as" ${attr(!editable)}>另存为…</button><button id="save" ${attr(!editable)}>${icon("save")} ${tab.dirty ? "保存 PDF •" : "保存 PDF"}</button>
    </div>
    <div class="pdf-layout ${ui.thumbnails ? "" : "without-thumbnails"} ${ui.inspector ? "" : "without-inspector"}">
      ${ui.thumbnails ? `<div class="pdf-thumbnails" aria-label="页面缩略图"><b>页面</b>${pages.map((page, index) => `<button data-pdf-page="${index}" aria-current="${index === ui.page ? "page" : "false"}" aria-label="第 ${index + 1} 页">
        <img src="${pdfImageURL(tab, index, 180)}" loading="lazy" alt="" style="aspect-ratio:${pdfRatio(page)}"><span>${index + 1}</span></button>`).join("")}</div>` : ""}
      <div class="pdf-canvas ${ui.spread ? "pdf-spread" : ""} ${ui.placement ? "pdf-placing" : ""}" aria-label="PDF 阅读区" tabindex="0">${sheets}</div>
      ${ui.inspector ? pdfInspector(tab) : ""}
    </div>
    <div class="pdf-footer" role="status"><span class="${tab.dirty ? "pdf-dirty" : ""}">${h(ui.notice || tab.message || (info.encrypted ? "加密 PDF · 只读" : tab.dirty ? "PDF 已修改 · 待保存" : info.xfa ? "XFA 动态表单无法在此工作台填写" : "已打开 PDF"))}</span>
      ${info.signed ? '<span class="pdf-placement">含数字签名字段 · 修改后请另存副本</span>' : ""}</div>
    <dialog class="pdf-dialog" aria-labelledby="pdf-dialog-title"></dialog></div>`;
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
  const match = ui.hits[ui.hit];
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
    <img data-pdf-raster="${index}" loading="lazy" alt="第 ${index + 1} 页">${highlights}${annotations}${widgets}</article>`;
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
  const tabs = [["objects", "对象"], ["forms", "表单"], ["outline", "目录"]];
  let content;
  if (ui.inspector === "forms") {
    content = info.fields.map((field, i) => {
      const readonly = field.readonly || info.encrypted;
      return `<div class="pdf-inspector-item"><div><b>${h(field.label)}</b>${field.widgets[0] ? `<button data-pdf-page="${field.widgets[0].page}">定位</button>` : ""}</div>
        ${field.type === "signature" ? '<span class="muted">数字签名字段 · 只读</span>' : field.type === "button" ? '<span class="muted">PDF 操作按钮 · 只读</span>' : readonly ? `<span class="muted">${field.password ? "密码字段" : h(field.value)} · 只读</span>` : pdfControl(field, i, ui.pending.get(field.name), false)}
      </div>`;
    }).join("") || '<p class="muted">无交互表单。扫描表格可使用“插入文字”填写。</p>';
  } else if (ui.inspector === "outline") {
    content = info.outline.map((item) => `<button class="pdf-outline-row" style="padding-inline-start:${8 + item.depth * 12}px" ${item.page == null ? "disabled" : `data-pdf-page="${item.page}"`}>${h(item.title)}</button>`).join("") || '<p class="muted">此 PDF 未包含目录书签。</p>';
  } else {
    content = info.annotations.map((item) => {
      const id = `${item.page}:${item.index}`;
      const edit = !info.encrypted && !item.readonly;
      return `<div class="pdf-inspector-item" data-pdf-object="${id}"><div><b>${h(item.title)}</b><span class="muted">第 ${item.page + 1} 页</span></div>
        ${item.text ? `<p>${h(item.text)}</p>` : ""}<div class="pdf-object-actions"><button data-pdf-page="${item.page}">定位</button>
        ${edit && item.canEdit ? `<button data-pdf-object-action="edit" data-object="${id}">编辑</button>` : ""}
        ${edit && item.canMove ? `<button data-pdf-object-action="move" data-object="${id}">移动</button><button data-pdf-object-action="size" data-object="${id}">尺寸</button>` : ""}
        ${edit ? `<button data-pdf-object-action="remove" data-object="${id}">删除</button>` : ""}</div></div>`;
    }).join("") || '<p class="muted">暂无对象与批注。</p>';
  }
  return `<div class="pdf-inspector" aria-label="PDF 检查器"><div class="pdf-inspector-tabs">${tabs.map(([id, name]) => `<button data-pdf-pane="${id}" aria-pressed="${ui.inspector === id}">${name}</button>`).join("")}</div><div class="pdf-inspector-body">${content}</div></div>`;
}

function bindPdf() {
  pdfResize?.disconnect();
  const tab = selected();
  if (tab?.kind !== "pdf") return;
  const unlock = document.getElementById("pdf-unlock");
  if (unlock) {
    unlock.onsubmit = (event) => {
      event.preventDefault();
      const input = unlock.querySelector("input");
      const password = input.value;
      input.value = "";
      pdfAction(tab, "unlock", {password});
    };
    return;
  }
  const workspace = document.querySelector(".pdf-workspace");
  if (!workspace) return;
  const ui = pdfView(tab), info = tab.preview;
  const canvas = workspace.querySelector(".pdf-canvas");
  const sheets = Array.from(canvas.querySelectorAll(".pdf-sheet"));
  const number = workspace.querySelector("#pdf-page-number");
  const thumbs = workspace.querySelector(".pdf-thumbnails");
  const syncControls = () => {
    number.value = ui.page + 1;
    for (const [id, disabled] of [["prev", ui.page === 0], ["next", ui.page === sheets.length - 1], ["up", info.encrypted || ui.page === 0], ["down", info.encrypted || ui.page === sheets.length - 1]]) {
      workspace.querySelector(`[data-pdf-command="${id}"]`).disabled = disabled;
    }
    thumbs?.querySelectorAll("[data-pdf-page]").forEach((button) => { button.setAttribute("aria-current", Number(button.dataset.pdfPage) === ui.page ? "page" : "false"); });
    const factor = ui.zoom || (sheets[ui.page]?.offsetWidth || 1) / (info.pages[ui.page]?.width || 1);
    workspace.querySelector("#pdf-zoom-value").textContent = Math.round(factor * 100) + "%";
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
    const fit = Math.min(900, Math.max(100, (canvas.clientWidth - (columns === 2 ? 58 : 36)) / columns));
    const visible = info.pages[ui.page];
    const scale = ui.zoom || Math.min(1.7, fit / (visible?.width || 595), (canvas.clientHeight - 37) / (visible?.height || 842));
    for (const sheet of sheets) {
      const width = ui.zoom ? Number(sheet.dataset.pdfWidth) * ui.zoom : Math.min(fit, Number(sheet.dataset.pdfWidth) * scale);
      sheet.style.width = `${width}px`;
      const resolution = Math.max(200, Math.min(2400, Math.ceil(width * Math.min(devicePixelRatio || 1, 2) / 100) * 100));
      const image = sheet.querySelector("[data-pdf-raster]");
      const url = pdfImageURL(tab, Number(image.dataset.pdfRaster), resolution);
      if (image.getAttribute("src") !== url) {
        image.onerror = () => { sheet.classList.add("pdf-image-error"); };
        image.onload = () => { sheet.classList.remove("pdf-image-error"); };
        image.src = url;
      }
    }
    if (ui.jump) { ui.jump = false; jump(ui.page); }
    else syncControls();
  };
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
  workspace.querySelectorAll("[data-pdf-pane]").forEach((node) => { node.onclick = () => { ui.inspector = node.dataset.pdfPane; render(); }; });
  number.onchange = () => jump(Number(number.value || 1) - 1);
  workspace.querySelectorAll("[data-pdf-command]").forEach((node) => { node.onclick = () => {
    const menu = node.closest("details");
    if (menu) menu.open = false;
    pdfCommand(tab, node.dataset.pdfCommand, jump, canvas).catch(fail);
  }; });
  workspace.querySelector("#pdf-find").onsubmit = async (event) => {
    event.preventDefault();
    await pdfFind(tab, event.target.querySelector("input").value);
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
    ui.notice = ui.query && !ui.hits.length ? "没有匹配的文字" : "";
    render();
  } catch (error) { fail(error); }
}

async function pdfCommand(tab, command, jump, canvas) {
  const ui = pdfView(tab);
  const page = ui.page, count = tab.preview.pages.length;
  if (command === "prev" || command === "next") return jump(page + (command === "prev" ? -1 : 1));
  if (["thumbs", "spread", "inspector", "objects", "fit", "zoom-out", "zoom-in", "cancel"].includes(command)) {
    if (command === "thumbs") ui.thumbnails = !ui.thumbnails;
    if (command === "spread") ui.spread = !ui.spread;
    if (command === "inspector") ui.inspector = ui.inspector ? "" : tab.preview.fields.length ? "forms" : "objects";
    if (command === "objects") ui.inspector = "objects";
    if (command === "fit") ui.zoom = 0;
    if (command.startsWith("zoom-")) {
      const rendered = canvas.querySelector(`[data-pdf-sheet="${page}"]`)?.offsetWidth || 595;
      const scale = ui.zoom || rendered / (tab.preview.pages[page]?.width || 595);
      ui.zoom = Math.max(0.25, Math.min(5, scale * (command === "zoom-out" ? 1 / 1.2 : 1.2)));
    }
    if (command === "cancel") ui.placement = null;
    ui.jump = true;
    return render();
  }
  if (command.startsWith("find-")) {
    ui.hit = (ui.hit + ui.hits.length + (command === "find-prev" ? -1 : 1)) % ui.hits.length;
    ui.page = ui.hits[ui.hit].page - 1;
    ui.jump = true;
    return render();
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
    ui.placement = {operation: command === "image" ? "image-file" : command, args, label: `点击页面放置${{image:"图片", text:"文字", note:"便签"}[command]}`};
    return render();
  }
  if (["highlight", "underline", "strike"].includes(command)) {
    const match = ui.hits[ui.hit];
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
