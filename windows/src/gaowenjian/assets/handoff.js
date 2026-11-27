let handoffState = null;
let handoffRequest = null;
let handoffReview = null;
let ocrPaths = [];
let ocrCurrentTab = null;
let providerOverride = "";
let outputSelection = ["text", "markdown", "json", "searchablePDF"];
let ocrLanguages = "";
let ocrOptionsOpen = false;
let ocrBusy = false;
let handoffLoading = false;
let ocrReturns = {results: [], issues: [], pending: false};
let ocrReturnNativeVisible = true;
let ocrReturnTimer = 0;
let ocrReturnRequest = null;
let ocrReturnRefreshQueued = false;
let ocrVisibilityGeneration = 0;
let ocrNativeRevision = 0;

const handoffStatus = {pending: "待处理", completed: "已完成", partial: "部分完成", failed: "失败", cancelled: "已取消", unsupported: "不支持"};
const handoffApps = {"com.gaoseries.GaoCaoZuo": "搞操作", "com.gaoseries.GaoYanJiu": "搞研究",
  "com.gaoseries.GaoWenJian": "搞文件", "com.gaoseries.GaoJieTu": "搞截图"};
const handoffActions = {
  "ocr.files": "文字识别", "documents.open": "打开文档", "documents.newText": "新建文档",
  "research.importDocuments": "导入研究资料", "files.search": "查找文件", "files.choose": "选择文件",
  "files.reveal": "定位原件", "associations.manage": "管理文件关联",
};

function handoffPanel() {
  const current = state.tabs.find((tab) => tab.id === ocrCurrentTab);
  const provider = providerOverride || handoffState?.provider;
  const formats = [["text", "纯文本"], ["markdown", "Markdown"], ["json", "JSON"], ["searchablePDF", "可搜索 PDF"]];
  const files = (current ? [{name: current.title, path: current.path || current.title, current: true}] : [])
    .concat(ocrPaths.map((path, index) => ({name: path.split(/[\\/]/).at(-1), path, index})));
  const currentResearch = selected();
  const canResearch = currentResearch && ["latex", "markdown", "text", "csv", "pdf"].includes(currentResearch.kind);
  const blocked = ocrBusy || !files.length || !outputSelection.length;
  return `<div class="doc-tools-page">
    <div class="doc-tools-heading"><h1>文档交接</h1><p>接收其他应用的文档，或发送当前内容的副本。</p></div>
    ${handoffReview ? handoffReviewCard(handoffReview) : ""}
    <div id="ocr-return-inbox" hidden></div>
    <div class="handoff-grid">
      <div class="doc-tools-card handoff-ocr-card"${ocrBusy ? ' aria-busy="true"' : ""}>
        <div class="handoff-card-heading">
          <div><h2>文字识别</h2><p>由搞操作审核并在本机识别。</p></div>
          <span class="doc-tools-state"${provider ? ` title="${h(provider)}"` : ""}>${providerOverride ? "已选程序" : provider ? "已找到搞操作" : "搞操作 OCR"}</span>
        </div>
        <div class="handoff-inputs">
          <div class="doc-tools-card-bar">
            <strong>识别文件${files.length ? " · " + files.length : ""}</strong>
            <button id="ocr-choose">${icon("folder")} ${ocrPaths.length ? "重选图像或 PDF" : "选择图像或 PDF"}</button>
          </div>
          ${files.length ? `<ul class="handoff-files">${files.map((file) => `<li>
            <span class="doc-file-icon" aria-hidden="true">${icon("doc")}</span>
            <span class="doc-truncate" title="${h(file.path)}">${h(file.name)}</span>
            <button class="doc-tools-quiet doc-tools-icon" ${file.current ? 'id="ocr-clear-current"' : `data-ocr-remove="${file.index}"`}
              aria-label="移除 ${h(file.name)}" title="移除">${icon("close")}</button>
          </li>`).join("")}</ul>` : '<div class="doc-tools-empty handoff-input-empty">添加图像或 PDF 后即可发起识别。</div>'}
        </div>
        <fieldset class="handoff-formats"><legend>输出格式</legend>
          <div class="doc-tools-actions">${formats.map(([kind, label]) => `<label class="doc-tools-choice">
            <input type="checkbox" data-ocr-format="${kind}"${outputSelection.includes(kind) ? " checked" : ""}>${label}</label>`).join("")}</div>
        </fieldset>
        <details id="ocr-options" class="doc-tools-detail"${ocrOptionsOpen ? " open" : ""}>
          <summary>识别语言与程序 ${icon("chevron")}</summary>
          <div class="handoff-options">
            <label class="doc-tools-field"><span>语言</span><input type="text" id="ocr-language" value="${h(ocrLanguages)}"
              placeholder="跟随 Windows，如 zh-CN、en-US"></label>
            <div class="doc-tools-field"><span>搞操作程序</span><div class="doc-tools-actions">
              <span class="doc-truncate" title="${h(provider || "")}">${provider ? h(provider.split(/[\\/]/).at(-1)) : "自动查找"}</span>
              <button id="ocr-provider">选择程序…</button></div></div>
          </div>
        </details>
        <div class="doc-tools-actions">
          <button id="ocr-send" class="doc-tools-primary"${blocked ? " disabled" : ""}>${ocrBusy ? "正在准备…" : "交给搞操作审核"}</button>
          <button id="ocr-export"${blocked ? " disabled" : ""}>导出请求包…</button>
        </div>
        <p class="doc-tools-hint">请求生成后须在 2 分钟内交给搞操作。</p>
        ${handoffRequest ? `<div class="doc-tools-status" role="status"><strong>${h(handoffRequest.label)}</strong>
          <span class="doc-truncate" title="${h(handoffRequest.path)}">${h(handoffRequest.path)}</span>
          ${handoffRequest.returnEnabled === false ? "<span>自动回传不可用，可手工接收结果包。</span>" : ""}</div>` : ""}
      </div>
      <div class="handoff-secondary">
        <div class="doc-tools-card">
          <div class="handoff-card-heading"><div><h2>接收交接包</h2><p>查看来源和项目，审核后打开文档。</p></div></div>
          <div class="doc-tools-actions">
            <button id="handoff-choose-folder">${icon("folder")} 选择包目录…</button>
            <button id="handoff-choose-file">选择 ZIP…</button>
          </div>
          ${handoffState?.references?.length ? `<ul class="handoff-files">${handoffState.references.map((item) =>
            `<li><span class="doc-truncate" title="${h(item.name)}">${h(item.name)}</span>
              <button data-handoff-reference="${h(item.id)}">核验原件…</button></li>`).join("")}</ul>` : ""}
        </div>
        ${canResearch ? `<div class="doc-tools-card">
          <div class="handoff-card-heading"><div><h2>发给搞研究</h2>
            <p class="doc-truncate" title="${h(currentResearch.title)}">${h(currentResearch.title)}</p></div></div>
          <div class="doc-tools-actions"><button id="handoff-research">导出文档交接包…</button></div>
        </div>` : ""}
      </div>
    </div>
  </div>`;
}

function handoffReviewCard(result) {
  const entries = result.items.map((item) => ({name: item.name, detail: toolFileSize(item.byteCount)}))
    .concat(result.references.map((name) => ({name, detail: "原件引用"})));
  return `<div class="doc-tools-card handoff-review" aria-labelledby="handoff-review-title">
    <div class="handoff-card-heading">
      <div><h2 id="handoff-review-title" tabindex="-1">审核交接包</h2>
        <p>${h(handoffApps[result.source] || result.source)} · <span title="${h(result.action)}">${h(handoffActions[result.action] || result.action)}</span></p></div>
      ${result.status ? `<span class="doc-tools-state">${h(handoffStatus[result.status] || result.status)}</span>` : ""}
    </div>
    ${entries.length ? `<ul class="handoff-files">${entries.map(({name, detail}) =>
      `<li><span class="doc-file-icon" aria-hidden="true">${icon("doc")}</span><span class="doc-truncate" title="${h(name)}">${h(name)}</span>
        <span class="doc-tools-hint">${h(detail)}</span></li>`).join("")}</ul>` : ""}
    ${result.ocrSources?.length ? `<div class="ocr-review-sources"><h3>原件与页码</h3>${result.ocrSources.map((source) => {
      const pages = source.pages || [];
      const failed = pages.filter((page) => page.status === "failed").length;
      return `<details class="doc-tools-detail"><summary><span class="doc-truncate" title="${h(source.path || source.name)}">${h(source.name)} · ${pages.length} 页${failed ? ` · ${failed} 页失败` : ""}</span>${icon("chevron")}</summary>
        <p>原件 SHA-256 <code>${h(source.sourceSHA256)}</code></p>
        ${pages.length ? `<p>${h(pages.map((page) => `第 ${page.pageNumber} 页 · ${page.status === "failed" ? "识别失败" : `${page.lineCount} 行`}`).join("；"))}</p>` : ""}</details>`;
    }).join("")}</div>` : ""}
    ${result.organizer ? organizerReviewPanel(result) :
      `<div class="doc-tools-actions"><button id="handoff-accept" class="doc-tools-primary">${result.ocrSources ? "接收结果副本" : "接收交接包"}</button><button id="handoff-cancel">取消</button></div>`}
  </div>`;
}

async function pickHandoffPath(mode) {
  if (mode === "multiple") {
    try { return (await api("/api/dialog", {mode})).result.path; }
    catch (error) { if (error.code !== "cancelled") throw error; return []; }
  }
  return fileDialog(mode);
}

function toolFileSize(bytes) {
  if (!Number.isFinite(bytes)) return "";
  if (bytes < 1024) return bytes + " B";
  const units = ["B", "KB", "MB", "GB", "TB"];
  const exponent = Math.min(units.length - 1, Math.floor(Math.log(bytes) / Math.log(1024)));
  return new Intl.NumberFormat("zh-CN", {maximumFractionDigits: 1}).format(bytes / 1024 ** exponent) + " " + units[exponent];
}

function toolDialog({title, text = "", fields = [], action, danger = false}) {
  const opener = document.activeElement;
  const dialog = document.createElement("dialog");
  dialog.className = "doc-tools-dialog";
  dialog.setAttribute("aria-labelledby", "doc-tools-dialog-title");
  dialog.innerHTML = `<form method="dialog">
    <h2 id="doc-tools-dialog-title">${h(title)}</h2>
    ${text ? `<p>${h(text)}</p>` : ""}
    ${fields.map((field, index) => `<label class="doc-tools-field"><span>${h(field.label)}</span>
      ${field.options ? `<select name="${h(field.name)}" required${index === 0 ? " autofocus" : ""}>
        ${field.options.map(({value, label}) => `<option value="${h(value)}"${value === field.value ? " selected" : ""}>${h(label)}</option>`).join("")}</select>`
      : `<input name="${h(field.name)}" type="text" value="${h(field.value || "")}" required${index === 0 ? " autofocus" : ""}>`}
    </label>`).join("")}
    <div class="doc-tools-actions">
      <button type="button" data-tool-cancel${!fields.length ? " autofocus" : ""}>取消</button>
      <button class="${danger ? "doc-tools-danger" : "doc-tools-primary"}" value="commit">${h(action)}</button>
    </div>
  </form>`;
  document.body.append(dialog);
  dialog.querySelector("[data-tool-cancel]").onclick = () => dialog.close();
  return new Promise((resolve) => {
    dialog.addEventListener("close", () => {
      const values = dialog.returnValue === "commit" ? Object.fromEntries(new FormData(dialog.querySelector("form"))) : null;
      dialog.remove();
      if (opener?.isConnected) opener.focus();
      resolve(values);
    }, {once: true});
    dialog.showModal();
    if (fields.length) dialog.querySelector("input")?.select();
  });
}

function listenHandoff(id, action) {
  const node = document.getElementById(id);
  if (node) node.onclick = () => Promise.resolve().then(action).catch(fail);
}

async function refreshHandoff() {
  handoffState = (await api("/api/handoff/state", {})).result;
}

async function reviewHandoff(path, expectedDigest = null) {
  if (!path) return;
  const review = (await api("/api/handoff/inspect", {path})).result;
  if (expectedDigest && review.sha256 !== expectedDigest) {
    checkOcrReturns();
    throw new Error("回传结果已变化，请重新查看待审核列表。");
  }
  handoffReview = {...review, path};
  message = "";
  view = "handoff";
  render();
  document.getElementById("handoff-review-title")?.focus();
}

function ocrReturnWindowActive() {
  return surface === "workspace" && ocrReturnNativeVisible && !document.hidden;
}

function setOcrReturnWindowVisible(visible, revision) {
  if (revision <= ocrNativeRevision) return;
  ocrNativeRevision = revision;
  if (visible !== ocrReturnNativeVisible) {
    ocrReturnNativeVisible = visible;
    updateOcrReturnVisibility();
  }
}

function updateOcrReturnVisibility() {
  ocrVisibilityGeneration++;
  clearTimeout(ocrReturnTimer);
  if (ocrReturnWindowActive()) checkOcrReturns();
}

function checkOcrReturns() {
  if (!ocrReturnWindowActive()) return;
  if (ocrReturnRequest) {
    ocrReturnRefreshQueued = true;
    return;
  }
  const generation = ocrVisibilityGeneration;
  clearTimeout(ocrReturnTimer);
  ocrReturnRequest = fetch("/api/handoff/ocr-returns", {headers: {"X-Gao-Token": token}})
    .then((response) => response.ok ? response.json() : null)
    .then((result) => {
      if (result && !result.paused && ocrReturnWindowActive() && generation === ocrVisibilityGeneration) {
        ocrReturns = result;
        paintOcrReturns();
      }
    }).catch(() => {}).finally(() => {
      ocrReturnRequest = null;
      const refresh = ocrReturnRefreshQueued || generation !== ocrVisibilityGeneration;
      ocrReturnRefreshQueued = false;
      if (!ocrReturnWindowActive()) return;
      if (refresh) checkOcrReturns();
      else if (ocrReturns.pending) ocrReturnTimer = setTimeout(checkOcrReturns, 4000);
    });
}

function replaceOcrReturnContent(node, html) {
  if (!node) return;
  if (node.ocrContent !== html) {
    node.ocrContent = html;
    node.innerHTML = html;
    node.hidden = !html;
  }
}

function paintOcrReturns() {
  const {results, issues, pending} = ocrReturns;
  const nav = document.querySelector('#workspace-nav [data-go="handoff"]');
  if (nav) {
    nav.toggleAttribute("data-ocr-waiting-review", results.length > 0);
    const label = "OCR 与交接" + (results.length ? `，${results.length} 项待审核` : "");
    nav.setAttribute("aria-label", label);
    nav.title = label;
  }
  const documentSlot = document.getElementById("ocr-document-return");
  const active = view === "editor" ? selected() : null;
  const normalize = (path) => path?.replaceAll("/", "\\").toLowerCase();
  const sameOriginal = (source) => source.path && normalize(source.path) === normalize(active.ocrSourcePath);
  const matching = active?.ocrSourceSHA256 && active.ocrSourcePath ? results.filter((item) =>
    item.sources.some(sameOriginal)) : [];
  const priorVersion = matching.length && !matching.some((item) =>
    item.sources.some((source) => sameOriginal(source) && source.sourceSHA256 === active.ocrSourceSHA256));
  replaceOcrReturnContent(documentSlot, matching.length ? `<div class="ocr-document-notice">
    ${icon("scan")}<span>此文件有 ${matching.length} 项 OCR 结果待审核。${priorVersion ? "识别基于提交时的文件副本。" : ""}</span>
    ${matching.length === 1 ? `<button data-ocr-review="${h(matching[0].resultID)}">审核结果</button>` : '<button data-ocr-inbox>查看待审核</button>'}</div>` : "");
  const queued = results.filter((item) => item.sha256 !== handoffReview?.sha256);
  replaceOcrReturnContent(document.getElementById("ocr-return-inbox"), queued.length || pending || issues.length ?
    `<section class="doc-tools-card ocr-inbox" aria-labelledby="ocr-inbox-title">
      <div class="handoff-card-heading"><div><h2 id="ocr-inbox-title">OCR 待审核</h2><p>${queued.length ? "核对来源和页码后，再接收结果副本。" : "如未收到回传，可手工接收结果包。"}</p></div>
      ${pending ? '<span class="doc-tools-state" role="status">等待搞操作回传</span>' : ""}</div>
      ${queued.length ? `<ul class="handoff-files">${queued.map((item) => {
        const names = item.sources.map((source) => source.name).join("、");
        const pages = item.sources.reduce((sum, source) => sum + (source.pages?.length || 0), 0);
        return `<li><span class="doc-file-icon" aria-hidden="true">${icon("scan")}</span><span class="doc-truncate" title="${h(names)}">${h(names || "OCR 结果")}</span>
          <span class="doc-tools-hint">${pages} 页 · ${h(handoffStatus[item.status] || item.status)}</span>
          <button data-ocr-review="${h(item.resultID)}">审核</button></li>`;
      }).join("")}</ul>` : ""}
      ${issues.length ? '<p class="ocr-inbox-warning" role="status">部分回传未通过核验。可从搞操作手工导出结果包后再审核。</p>' : ""}
    </section>` : "");
}

document.addEventListener("visibilitychange", updateOcrReturnVisibility);
document.addEventListener("click", (event) => {
  const button = event.target.closest?.("[data-ocr-review], [data-ocr-inbox]");
  if (!button) return;
  if (button.hasAttribute("data-ocr-inbox")) navigate("handoff").catch(fail);
  else {
    const item = ocrReturns.results.find((result) => result.resultID === button.dataset.ocrReview);
    if (item) leaveCurrent().then((ready) => ready && reviewHandoff(item.path, item.sha256)).catch(fail);
  }
});

function organizerReviewPanel(review) {
  const options = review.organizer;
  const actions = (buttons) => '<div class="doc-tools-actions">' + buttons
    + '<button id="organizer-handoff-cancel">取消并导出回执…</button></div>';
  const accept = (label) => '<button class="doc-tools-primary" id="organizer-handoff-accept">' + label + '</button>';
  if (review.action === "files.search") {
    return '<h3>查找 “' + h(options.query) + '”</h3>' + (options.candidates.length
      ? '<div class="handoff-candidates">' + options.candidates.map((item) =>
        `<label class="doc-tools-choice"><input type="checkbox" data-handoff-candidate="${h(item.id)}">
          <span class="doc-truncate" title="${h(item.path)}">${h(item.name)}</span></label>`).join("") + '</div>'
      : '<p class="doc-tools-empty">授权范围内没有匹配条目。</p>')
      + actions(options.candidates.length ? accept("交接所选引用…") : "");
  }
  if (review.action === "files.choose") return actions(accept("选择文件并交接引用…"));
  if (review.action === "files.reveal") return actions(accept("核对原件并定位…"));
  return '<p>Windows 文件类型 · ' + h(options.extension) + '</p>'
    + actions('<button id="organizer-handoff-open">打开 Windows 默认应用设置</button>'
      + accept("核对设置并导出回执…"));
}

async function finishOrganizerHandoff(cancel = false, phase = "") {
  const {path, sha256, action, organizer} = handoffReview;
  const data = {path, sha256, confirm: true, cancel, phase};
  if (!cancel && phase !== "open") {
    if (action === "files.choose") {
      const selected = await pickHandoffPath(organizer.multiple ? "multiple" : "open");
      if (!selected?.length) return;
      data.paths = organizer.multiple ? selected : [selected];
    } else if (action === "files.reveal") {
      data.revealPath = await pickHandoffPath(organizer.directory ? "folder" : "open");
      if (!data.revealPath) return;
    } else if (action === "files.search") {
      data.ids = [...document.querySelectorAll("[data-handoff-candidate]:checked")].map((item) => item.dataset.handoffCandidate);
      if (!data.ids.length) throw new Error("请先勾选要发送的文件引用。");
    }
  }
  if (phase !== "open") {
    data.destination = await pickHandoffPath("folder");
    if (!data.destination || !await toolDialog({title: cancel ? "导出取消回执" : "确认交接动作",
      text: data.destination, action: "导出回执"})) return;
  }
  const result = (await api("/api/handoff/organizer", data)).result;
  if (result.path) {
    handoffReview = null;
    message = "交接回执已导出 · " + result.path;
  } else {
    message = "已打开 Windows 设置。改变所选类型的默认应用后返回核对。";
  }
  render();
}

async function makeOcrRequest(send) {
  const currentTab = state.tabs.some((tab) => tab.id === ocrCurrentTab) ? ocrCurrentTab : null;
  if (ocrBusy || (!ocrPaths.length && !currentTab) || !outputSelection.length) return;
  const directory = send ? null : await pickHandoffPath("folder");
  if (!send && !directory) return;
  if (!await toolDialog({title: send ? "交给搞操作审核" : "导出 OCR 请求包",
    text: send ? "搞操作将收到所选内容的副本，需要在搞操作确认后才会识别。" : "请求包包含所选内容的副本，请在 2 分钟内交给搞操作审核。",
    action: send ? "交给搞操作" : "导出请求包"})) return;
  const payload = {
    paths: ocrPaths, currentTab, outputs: outputSelection,
    languages: ocrLanguages.split(/[\s,，]+/).filter(Boolean), directory, confirm: true,
  };
  ocrBusy = true;
  message = "";
  render();
  try {
    handoffRequest = {...(await api("/api/handoff/ocr", payload)).result, label: "已导出 OCR 请求包"};
    checkOcrReturns();
    if (send) {
      const opened = (await api("/api/handoff/dispatch", {
        requestID: handoffRequest.requestID, provider: providerOverride, confirm: true,
      })).result;
      handoffRequest.label = "已交给搞操作 V" + opened.providerVersion + " 审核";
    }
  } finally {
    ocrBusy = false;
    if (view === "handoff") render();
  }
}

function bindHandoff() {
  document.querySelectorAll("[data-ocr-current]").forEach((node) => node.onclick = async () => {
    ocrCurrentTab = selected()?.id || null;
    try { await navigate("handoff"); } catch (error) { fail(error); }
  });
  if (view !== "handoff") return;
  if (!handoffState && !handoffLoading) {
    handoffLoading = true;
    refreshHandoff().then(() => { if (view === "handoff") render(); })
      .catch((error) => { handoffState = {}; fail(error); }).finally(() => { handoffLoading = false; });
  }
  listenHandoff("ocr-choose", async () => {
    try { ocrPaths = (await api("/api/handoff/choose-inputs", {})).result.paths; }
    catch (error) { if (error.code !== "cancelled") throw error; return; }
    render();
  });
  listenHandoff("ocr-clear-current", () => { ocrCurrentTab = null; render(); });
  document.querySelectorAll("[data-ocr-remove]").forEach((button) => button.onclick = () => {
    ocrPaths.splice(Number(button.dataset.ocrRemove), 1);
    render();
  });
  listenHandoff("ocr-send", () => makeOcrRequest(true));
  listenHandoff("ocr-export", () => makeOcrRequest(false));
  listenHandoff("ocr-provider", async () => {
    const provider = await pickHandoffPath("open");
    if (provider) { providerOverride = provider; render(); }
  });
  const options = document.getElementById("ocr-options");
  if (options) options.ontoggle = () => { ocrOptionsOpen = options.open; };
  const languages = document.getElementById("ocr-language");
  if (languages) languages.oninput = () => { ocrLanguages = languages.value; };
  document.querySelectorAll("[data-ocr-format]").forEach((node) => node.onchange = () => {
    outputSelection = [...document.querySelectorAll("[data-ocr-format]:checked")].map((item) => item.dataset.ocrFormat);
    for (const id of ["ocr-send", "ocr-export"]) {
      document.getElementById(id).disabled = ocrBusy || !outputSelection.length
        || (!ocrPaths.length && !state.tabs.some((tab) => tab.id === ocrCurrentTab));
    }
  });
  listenHandoff("handoff-choose-folder", async () => reviewHandoff(await pickHandoffPath("folder")));
  listenHandoff("handoff-choose-file", async () => reviewHandoff(await pickHandoffPath("open")));
  listenHandoff("handoff-accept", async () => {
    const response = await api("/api/handoff/import", handoffReview);
    handoffReview = null;
    await refreshHandoff();
    if (response.result.id) view = "editor";
    message = state.status;
    checkOcrReturns();
    render();
  });
  listenHandoff("handoff-cancel", () => { handoffReview = null; render(); });
  listenHandoff("organizer-handoff-cancel", () => finishOrganizerHandoff(true));
  listenHandoff("organizer-handoff-open", () => finishOrganizerHandoff(false, "open"));
  listenHandoff("organizer-handoff-accept", () => finishOrganizerHandoff());
  document.querySelectorAll("[data-handoff-reference]").forEach((node) => node.onclick = async () => {
    try {
      const path = await pickHandoffPath("open");
      if (!path) return;
      await api("/api/handoff/reference", {id: node.dataset.handoffReference, path});
      await refreshHandoff();
      view = "editor";
      render();
    } catch (error) { fail(error); }
  });
  listenHandoff("handoff-research", async () => {
    const current = selected();
    const directory = await pickHandoffPath("folder");
    if (!directory || !await toolDialog({title: "发给搞研究", text: "将《" + current.title + "》的副本写入交接包，供搞研究导入。",
      action: "导出交接包"})) return;
    const result = (await api("/api/handoff/research", {id: current.id, directory})).result;
    message = "已导出搞研究交接包 · " + result.path;
    render();
  });
}

function incomingHandoff(tab) {
  const incoming = tab?.incoming;
  if (!incoming) return "";
  const status = incoming.status && handoffStatus[incoming.status];
  const source = handoffApps[incoming.sourceBundleID] || incoming.sourceBundleID;
  const action = incoming.action === "ocr.files" ? "OCR" : "文档交接";
  const failed = (incoming.pages || []).filter((page) => page.status === "failed").length;
  const pages = action === "OCR" ? (incoming.pages || []).map((page) => `第 ${page.pageNumber} 页`) : [];
  return '<div class="banner' + (failed || incoming.failureCount ? " warn" : "") + '">' + h(source) + ' · ' + action
    + (status ? ' · ' + h(status) : '') + (failed ? ' · ' + failed + ' 页失败' : '')
    + (incoming.failureCount ? ' · ' + incoming.failureCount + ' 份导出失败' : '')
    + (incoming.sourceName ? ` · 原件 <span title="${h(incoming.sourcePath || incoming.sourceName)}">${h(incoming.sourceName)}</span>` : "")
    + (pages.length ? ` · <span title="${h(pages.join("、"))}">${h(pages.slice(0, 3).join("、"))}${pages.length > 3 ? ` 等 ${pages.length} 页` : ""}</span>` : "") + '</div>';
}
