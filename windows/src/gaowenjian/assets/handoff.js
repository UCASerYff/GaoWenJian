let handoffState = null;
let handoffRequest = null;
let handoffReview = null;
let ocrPaths = [];
let ocrCurrentTab = null;
let providerOverride = "";
let outputSelection = ["text", "markdown", "json", "searchablePDF"];
let ocrLanguages = "";

const handoffStatus = {pending: "待处理", completed: "已完成", partial: "部分完成", failed: "失败", cancelled: "已取消", unsupported: "不支持"};
const handoffApps = {"com.gaoseries.GaoCaoZuo": "搞操作", "com.gaoseries.GaoYanJiu": "搞研究",
  "com.gaoseries.GaoWenJian": "搞文件", "com.gaoseries.GaoJieTu": "搞截图"};

function handoffPanel() {
  const current = state.tabs.find((tab) => tab.id === ocrCurrentTab);
  const result = handoffReview;
  const provider = providerOverride || handoffState?.provider;
  const rows = [
    ["text", "纯文本"], ["markdown", "Markdown"], ["json", "JSON"], ["searchablePDF", "可搜索 PDF"],
  ];
  return '<h1>文档交接</h1>'
    + '<div class="card handoff-card"><h2>OCR · 搞操作</h2>'
    + '<p>选择图像或 PDF。请求在两分钟内交给搞操作审核，由搞操作在本机识别。</p>'
    + '<div class="row"><button id="ocr-choose">选择图像或 PDF…</button>'
    + (current ? '<button id="ocr-clear-current">移除当前文档</button>' : '')
    + '<span>' + h((current ? [current.title] : []).concat(ocrPaths.map((path) => path.split(/[\\/]/).at(-1))).join("、") || "未选择文件") + '</span></div>'
    + '<fieldset><legend>输出</legend><div class="row">' + rows.map(([kind, label]) =>
      '<label><input type="checkbox" data-ocr-format="' + kind + '"' + (outputSelection.includes(kind) ? ' checked' : '') + '> ' + label + '</label>').join("")
    + '</div></fieldset>'
    + '<label>语言 <input id="ocr-language" value="' + h(ocrLanguages) + '" placeholder="跟随 Windows，可输入 zh-CN, en-US"></label>'
    + '<div class="row"><button id="ocr-send">交给搞操作审核</button><button id="ocr-export">导出请求包…</button>'
    + '<button id="ocr-provider">选取搞操作程序…</button></div>'
    + (provider ? '<div class="muted">' + h(provider) + '</div>' : '')
    + (handoffRequest ? '<div class="banner"><strong>已生成请求</strong> ' + h(handoffRequest.path) + '</div>' : '')
    + '</div><div class="card handoff-card"><h2>接收文档或回包</h2>'
    + '<div class="row"><button id="handoff-choose-folder">选择交接包目录…</button><button id="handoff-choose-file">选择 ZIP…</button></div>'
    + (result ? '<div class="banner"><strong>' + h(handoffApps[result.source] || result.source) + '</strong> · ' + h(result.action)
      + (result.status ? ' · ' + h(handoffStatus[result.status] || result.status) : '')
      + '<ul>' + result.items.map((item) => '<li>' + h(item.name) + '</li>').join("")
      + result.references.map((name) => '<li>原件引用 · ' + h(name) + '</li>').join("") + '</ul>'
      + (result.organizer ? organizerReviewPanel(result) : '<button id="handoff-accept">接收</button> <button id="handoff-cancel">取消</button>')
      + '</div>' : '')
    + (handoffState?.references || []).map((item) => '<div class="row">' + h(item.name)
      + '<button data-handoff-reference="' + h(item.id) + '">选择并核验原件…</button></div>').join("")
    + '</div>'
    + (selected() && ["latex", "markdown", "text", "csv", "pdf"].includes(selected().kind)
      ? '<div class="card handoff-card"><h2>发给搞研究</h2><button id="handoff-research">导出当前文档交接包…</button></div>' : '');
}

async function pickHandoffPath(mode) {
  return (await api("/api/dialog", {mode})).result.path;
}

function listenHandoff(id, action) {
  const node = document.getElementById(id);
  if (node) node.onclick = () => Promise.resolve().then(action).catch(fail);
}

async function refreshHandoff() {
  handoffState = (await api("/api/handoff/state", {})).result;
}

async function reviewHandoff(path) {
  handoffReview = {...(await api("/api/handoff/inspect", {path})).result, path};
  view = "handoff";
  render();
}

function organizerReviewPanel(review) {
  const options = review.organizer;
  const cancel = '<button id="organizer-handoff-cancel">取消并导出回执…</button>';
  if (review.action === "files.search") {
    return '<p>查找 · ' + h(options.query) + '</p>' + (options.candidates.length ? options.candidates.map((item) =>
      '<label><input type="checkbox" data-handoff-candidate="' + h(item.id) + '"> ' + h(item.path) + '</label><br>').join("")
      + '<button id="organizer-handoff-accept">交接所选引用…</button>' : '<p>授权范围内没有匹配条目。</p>') + cancel;
  }
  if (review.action === "files.choose") return '<button id="organizer-handoff-accept">选择文件并交接引用…</button>' + cancel;
  if (review.action === "files.reveal") return '<button id="organizer-handoff-accept">核对原件并定位…</button>' + cancel;
  return '<p>Windows 文件类型 · ' + h(options.extension) + '</p>'
    + '<button id="organizer-handoff-open">打开 Windows 默认应用设置</button>'
    + '<button id="organizer-handoff-accept">核对设置并导出回执…</button>' + cancel;
}

async function finishOrganizerHandoff(cancel = false, phase = "") {
  const {path, sha256, action, organizer} = handoffReview;
  const data = {path, sha256, confirm: true, cancel, phase};
  if (!cancel && phase !== "open") {
    if (action === "files.choose") {
      const selected = await pickHandoffPath(organizer.multiple ? "multiple" : "open");
      data.paths = organizer.multiple ? selected : [selected];
    } else if (action === "files.reveal") {
      data.revealPath = await pickHandoffPath(organizer.directory ? "folder" : "open");
    } else if (action === "files.search") {
      data.ids = [...document.querySelectorAll("[data-handoff-candidate]:checked")].map((item) => item.dataset.handoffCandidate);
      if (!data.ids.length) throw new Error("请先勾选要发送的文件引用。");
    }
  }
  if (phase !== "open") {
    data.destination = await pickHandoffPath("folder");
    if (!confirm(cancel ? "导出取消回执？" : "确认此动作并导出回执？")) return;
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
  if (!ocrPaths.length && !ocrCurrentTab) throw new Error("请先选择 OCR 输入。");
  const directory = send ? null : await pickHandoffPath("folder");
  if (!confirm(send ? "发送所选内容的副本，交给搞操作审核？" : "把所选内容的副本写入交接包？")) return;
  const payload = {
    paths: ocrPaths, currentTab: ocrCurrentTab, outputs: outputSelection,
    languages: ocrLanguages.split(/[\s,，]+/).filter(Boolean), directory, confirm: true,
  };
  handoffRequest = (await api("/api/handoff/ocr", payload)).result;
  if (send) {
    const opened = (await api("/api/handoff/dispatch", {
      requestID: handoffRequest.requestID, provider: providerOverride, confirm: true,
    })).result;
    message = "已交给搞操作 V" + opened.providerVersion + "，请在搞操作审核并导出结果。";
  } else {
    message = "请求包已导出，请在搞操作选择该目录审核。";
  }
  render();
}

function bindHandoff() {
  document.querySelectorAll("[data-ocr-current]").forEach((node) => node.onclick = async () => {
    ocrCurrentTab = selected()?.id || null;
    try { await navigate("handoff"); } catch (error) { fail(error); }
  });
  if (view !== "handoff") return;
  if (!handoffState) refreshHandoff().then(() => { if (view === "handoff") render(); }).catch(fail);
  listenHandoff("ocr-choose", async () => {
    ocrPaths = (await api("/api/handoff/choose-inputs", {})).result.paths;
    render();
  });
  listenHandoff("ocr-clear-current", () => { ocrCurrentTab = null; render(); });
  listenHandoff("ocr-send", () => makeOcrRequest(true));
  listenHandoff("ocr-export", () => makeOcrRequest(false));
  listenHandoff("ocr-provider", async () => { providerOverride = await pickHandoffPath("open"); render(); });
  const languages = document.getElementById("ocr-language");
  if (languages) languages.oninput = () => { ocrLanguages = languages.value; };
  document.querySelectorAll("[data-ocr-format]").forEach((node) => node.onchange = () => {
    outputSelection = [...document.querySelectorAll("[data-ocr-format]:checked")].map((item) => item.dataset.ocrFormat);
  });
  listenHandoff("handoff-choose-folder", async () => reviewHandoff(await pickHandoffPath("folder")));
  listenHandoff("handoff-choose-file", async () => reviewHandoff(await pickHandoffPath("open")));
  listenHandoff("handoff-accept", async () => {
    const response = await api("/api/handoff/import", handoffReview);
    handoffReview = null;
    await refreshHandoff();
    if (response.result.id) view = "editor";
    message = state.status;
    render();
  });
  listenHandoff("handoff-cancel", () => { handoffReview = null; render(); });
  listenHandoff("organizer-handoff-cancel", () => finishOrganizerHandoff(true));
  listenHandoff("organizer-handoff-open", () => finishOrganizerHandoff(false, "open"));
  listenHandoff("organizer-handoff-accept", () => finishOrganizerHandoff());
  document.querySelectorAll("[data-handoff-reference]").forEach((node) => node.onclick = async () => {
    try {
      const path = await pickHandoffPath("open");
      await api("/api/handoff/reference", {id: node.dataset.handoffReference, path});
      await refreshHandoff();
      view = "editor";
      render();
    } catch (error) { fail(error); }
  });
  listenHandoff("handoff-research", async () => {
    const directory = await pickHandoffPath("folder");
    if (!confirm("将当前内容写成交接副本，交给搞研究导入？")) return;
    const result = (await api("/api/handoff/research", {id: selected().id, directory})).result;
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
  return '<div class="banner' + (failed || incoming.failureCount ? " warn" : "") + '">' + h(source) + ' · ' + action
    + (status ? ' · ' + h(status) : '') + (failed ? ' · ' + failed + ' 页失败' : '')
    + (incoming.failureCount ? ' · ' + incoming.failureCount + ' 份导出失败' : '') + '</div>';
}
