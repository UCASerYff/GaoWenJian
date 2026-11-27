"use strict";

const options = new URLSearchParams(location.search);
const tabId = options.get("tab") || "";
const sessionToken = options.get("token") || "";
const byId = (id) => document.getElementById(id);
const canvas = byId("reader-canvas");
const workspace = document.querySelector(".reader-workspace");
const thumbs = byId("reader-pages");
const original = byId("reader-original-view");
const status = byId("reader-status");
const pageNumber = byId("reader-page-number");
const systemDark = matchMedia("(prefers-color-scheme: dark)");
let appearance = options.get("appearance") || "system";
let pages = [];
let compiled = {};
let fileName = "LaTeX.pdf";
let current = 0;
let zoom = 1;
let actualSize = false;
let pdfUrl = "";
let useOriginal = false;
let showThumbs = true;
let available = false;
let scrollAnimation;

function requestOptions(extra = {}) {
  return new URLSearchParams({tab: tabId, token: sessionToken, ...extra});
}

function report(text) {
  status.textContent = text;
}

function applyReaderTheme() {
  document.documentElement.dataset.theme = appearance === "dark" || (appearance === "system" && systemDark.matches) ? "dark" : "light";
}

function thumbnailSrc(index, width) {
  const query = requestOptions({page: index, width, generation: compiled.generation || ""});
  return "/api/latex/page?" + query;
}

function updateControls() {
  document.querySelectorAll(".reader-toolbar button, .reader-toolbar input").forEach((control) => {
    control.disabled = !available || useOriginal;
  });
  byId("reader-prev").disabled ||= current === 0;
  byId("reader-next").disabled ||= current === pages.length - 1;
  byId("reader-original").disabled = !pdfUrl;
  byId("reader-export").disabled = !available;
}

function selectPage(index, reveal = false) {
  if (!pages.length || !Number.isFinite(index)) return;
  current = Math.max(0, Math.min(pages.length - 1, Math.trunc(index)));
  pageNumber.value = current + 1;
  thumbs.querySelector("[aria-current]")?.removeAttribute("aria-current");
  thumbs.children[current]?.setAttribute("aria-current", "page");
  report("第 " + (current + 1) + " 页，共 " + pages.length + " 页");
  if (reveal) {
    const sheet = canvas.children[current];
    canvas.scrollTop += sheet.getBoundingClientRect().top - canvas.getBoundingClientRect().top - 12;
    thumbs.children[current]?.scrollIntoView({block: "nearest", inline: "nearest"});
  }
  updateControls();
}

function showOriginal(value) {
  if (!pdfUrl) return;
  useOriginal = value;
  if (value && !original.getAttribute("src")) original.src = pdfUrl;
  original.hidden = !value;
  canvas.hidden = value;
  thumbs.hidden = value || !showThumbs;
  workspace.classList.toggle("show-original", value);
  byId("reader-original").setAttribute("aria-pressed", value);
  updateControls();
  if (value) report("PDF 原件");
  else selectPage(current, true);
}

function rasterError() {
  if (!useOriginal && pdfUrl) {
    showOriginal(true);
    report("页面图像不可用，已显示 PDF 原件。");
  }
}

function renderPages() {
  const preview = document.createDocumentFragment();
  const navigation = document.createDocumentFragment();
  const width = Math.min(2500, Math.max(900, Math.round(1050 * devicePixelRatio * zoom)));
  for (const [index, page] of pages.entries()) {
    const thumbnail = document.createElement("button");
    const label = document.createElement("span");
    label.textContent = index + 1;
    thumbnail.type = "button";
    thumbnail.title = "前往第 " + (index + 1) + " 页";
    thumbnail.setAttribute("aria-label", thumbnail.title);
    thumbnail.onclick = () => selectPage(index, true);

    const miniature = new Image();
    miniature.alt = "";
    miniature.loading = "lazy";
    miniature.style.aspectRatio = page.width + " / " + page.height;
    miniature.src = thumbnailSrc(index, 180);
    thumbnail.append(miniature, label);
    navigation.append(thumbnail);

    const sheet = document.createElement("article");
    sheet.className = "reader-page";
    sheet.style.aspectRatio = page.width + " / " + page.height;
    const scan = new Image();
    scan.alt = "第 " + (index + 1) + " 页";
    scan.loading = index === current ? "eager" : "lazy";
    scan.src = thumbnailSrc(index, width);
    scan.addEventListener("error", rasterError, {once: true});
    sheet.append(scan);
    preview.append(sheet);
  }
  thumbs.replaceChildren(navigation);
  canvas.replaceChildren(preview);
  sizePages();
  selectPage(current, true);
}

function sizePages() {
  canvas.style.setProperty("--reader-zoom", zoom);
  for (const [index, sheet] of [...canvas.children].entries()) {
    sheet.style.setProperty("--reader-page-cap", Math.round(880 * zoom) + "px");
    sheet.style.width = actualSize ? Math.round(pages[index].width * 4 / 3) + "px" : "";
    sheet.style.maxWidth = actualSize ? "none" : "";
  }
}

function resizePages(value, actual = false) {
  zoom = Math.max(.5, Math.min(3, value));
  actualSize = actual;
  renderPages();
}

async function loadDocument() {
  if (!tabId || !sessionToken) throw new Error("无法读取这个编译结果。");
  const stateRequest = await fetch("/api/state", {headers: {"X-Gao-Token": sessionToken}});
  if (!stateRequest.ok) throw new Error("无法读取 PDF 阅读会话。");
  const state = await stateRequest.json();
  const tab = state.tabs.find((item) => item.id === tabId && item.kind === "latex");
  compiled = tab?.preview || {};
  pages = compiled.pages || [];
  if (!pages.length) throw new Error("这个文档没有可读取的编译结果。");
  appearance = state.settings.appearance;
  applyReaderTheme();
  fileName = tab.title.replace(/\.[^.]+$/, "") + ".pdf";
  document.title = fileName + " · 搞文件";
  byId("reader-title").textContent = fileName;
  byId("reader-title").title = fileName;
  byId("reader-meta").textContent = pages.length + " 页 · LaTeX 编译结果";
  byId("reader-total").textContent = "/ " + pages.length;
  pageNumber.max = pages.length;
  const pdf = await fetch("/api/latex/document?" + requestOptions());
  if (!pdf.ok) throw new Error("编译 PDF 无法读取。");
  pdfUrl = URL.createObjectURL(await pdf.blob());
  available = true;
  renderPages();
  workspace.setAttribute("aria-busy", "false");
}

canvas.addEventListener("scroll", () => {
  if (scrollAnimation) return;
  scrollAnimation = requestAnimationFrame(() => {
    scrollAnimation = 0;
    const top = canvas.getBoundingClientRect().top + 18;
    const index = [...canvas.children].findIndex((page) => page.getBoundingClientRect().bottom > top);
    if (index >= 0 && index !== current) selectPage(index);
  });
});
byId("reader-toggle-pages").onclick = (event) => {
  showThumbs = !showThumbs;
  thumbs.hidden = !showThumbs;
  workspace.classList.toggle("no-thumbnails", !showThumbs);
  event.currentTarget.setAttribute("aria-pressed", showThumbs);
};
byId("reader-prev").onclick = () => selectPage(current - 1, true);
byId("reader-next").onclick = () => selectPage(current + 1, true);
pageNumber.onchange = () => selectPage(Number(pageNumber.value) - 1, true);
pageNumber.onkeydown = (event) => { if (event.key === "Enter") selectPage(Number(pageNumber.value) - 1, true); };
byId("reader-zoom-out").onclick = () => resizePages(zoom - .2);
byId("reader-zoom-in").onclick = () => resizePages(zoom + .2);
byId("reader-actual").onclick = () => resizePages(1, true);
byId("reader-fit").onclick = () => resizePages(1);
byId("reader-original").onclick = () => showOriginal(!useOriginal);
byId("reader-export").onclick = async () => {
  try {
    if (window.pywebview?.api) {
      const path = await window.pywebview.api.file_dialog("save", fileName);
      if (!path) return;
      const response = await fetch("/api/latex/export", {
        method: "POST",
        headers: {"X-Gao-Token": sessionToken, "Content-Type": "application/json"},
        body: JSON.stringify({id: tabId, path}),
      });
      const outcome = await response.json();
      if (!response.ok || !outcome.ok) throw Error(outcome.error || "导出没有完成。");
      report("已导出 " + path.replace(/^.*[\\/]/, ""));
    } else {
      const link = document.createElement("a");
      link.href = pdfUrl;
      link.download = fileName;
      link.click();
    }
  } catch (error) { report(error.message); }
};
document.addEventListener("keydown", (event) => {
  if (!available || useOriginal || event.target.closest("input, button, iframe") || event.altKey || event.ctrlKey || event.metaKey) return;
  if (event.key === "PageUp" || event.key === "PageDown") {
    event.preventDefault();
    selectPage(current + (event.key === "PageDown" ? 1 : -1), true);
  }
});
window.addEventListener("pagehide", () => { if (pdfUrl) URL.revokeObjectURL(pdfUrl); });
systemDark.addEventListener("change", applyReaderTheme);
applyReaderTheme();
updateControls();
loadDocument().catch((error) => {
  workspace.setAttribute("aria-busy", "false");
  byId("reader-meta").textContent = "无法载入";
  report(error.message);
});
