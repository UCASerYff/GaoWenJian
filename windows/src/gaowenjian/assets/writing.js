const writingSessions = new Map();
const markdownSnippets = {
  h1: "# 标题\n\n", h2: "## 标题\n\n", list: "- 列表项目\n", task: "- [ ] 待办事项\n",
  quote: "> 引用内容\n\n", table: "\n\n| 列一 | 列二 |\n| --- | --- |\n| 内容 | 内容 |\n\n",
  code: "\n\n```text\n代码内容\n```\n\n", display: "\n\n$$\nE = mc^2\n$$\n\n",
  mermaid: "\n\n```mermaid\nflowchart LR\n    A[开始] --> B[完成]\n```\n\n", footnote: "[^1]\n\n[^1]: 脚注内容\n",
};
const latexSnippets = {
  fraction: ["\\frac{}{}", 3], sqrt: ["\\sqrt{}", 1], sum: ["\\sum_{i=1}^{n} ", 0],
  integral: ["\\int_{a}^{b} ", 0], equation: ["\\begin{equation}\n  \n\\end{equation}\n", 16],
  align: ["\\begin{align}\n  \n\\end{align}\n", 13], itemize: ["\\begin{itemize}\n  \\item \n\\end{itemize}\n", 15],
  enumerate: ["\\begin{enumerate}\n  \\item \n\\end{enumerate}\n", 17],
  figure: ["\\begin{figure}[htbp]\n  \\centering\n  \\includegraphics[width=0.8\\linewidth]{image.png}\n  \\caption{插图描述}\n  \\label{fig:fig1}\n\\end{figure}\n", 0],
  table: ["\\begin{table}[htbp]\n  \\centering\n  \\begin{tabular}{cc}\n    列1 & 列2 \\\\\n    数据1 & 数据2 \\\\\n  \\end{tabular}\n  \\caption{表格标题}\n  \\label{tab:table1}\n\\end{table}\n", 0],
  bold: ["\\textbf{}", 1], italic: ["\\textit{}", 1], emphasis: ["\\emph{}", 1],
  section: ["\n\\section{}\n", 2], subsection: ["\n\\subsection{}\n", 2],
  label: ["\\label{}", 1], ref: ["\\ref{}", 1], cite: ["\\cite{}", 1],
};

function writingSession(id) {
  if (!writingSessions.has(id)) writingSessions.set(id, {mode: "live", outline: false, latexSidebar: true, latexPane: "index", page: 0, zoom: 1, log: false});
  return writingSessions.get(id);
}

function optionList(items) {
  return Object.entries(items).map(([key, label]) => `<option value="${key}">${h(label)}</option>`).join("");
}

function markdownPanel(tab) {
  const session = writingSession(tab.id);
  const url = new URLSearchParams({tab: tab.id, token, theme: document.documentElement.dataset.theme || "light",
    font: state.settings.editorFontSize || 15, wrap: state.settings.wrapLines === false ? "off" : "soft"});
  return `
    <div class="writing-panel" data-writing="markdown">
      <div class="row writing-toolbar">
        <div class="writing-modes" aria-label="Markdown 编辑模式">
          ${Object.entries({live: "即时编辑", split: "分屏", source: "源码"}).map(([mode, title]) =>
            `<button type="button" data-md-mode="${mode}" aria-pressed="${session.mode === mode}">${title}</button>`).join("")}
        </div>
        <button id="md-outline" aria-pressed="${session.outline}">☷ 大纲</button>
        <button data-md-format="bold" title="加粗（Ctrl+B）"><b>B</b></button>
        <button data-md-format="italic" title="斜体（Ctrl+I）"><i>I</i></button>
        <select id="md-insert" aria-label="插入"><option value="">＋ 插入</option>${optionList({
          h1: "一级标题", h2: "二级标题", list: "无序列表", task: "任务列表", quote: "引用", table: "表格", code: "代码块",
          math: "行内公式", display: "公式块", mermaid: "Mermaid 图示", footnote: "脚注", link: "链接",
        })}</select>
        <button id="md-image">插入图片</button><input id="md-image-file" type="file" accept="image/png,image/jpeg,image/gif,image/webp,image/bmp,image/svg+xml" hidden multiple>
        <span class="writing-spacer"></span>
        <select id="md-export" aria-label="导出"><option value="">导出</option><option value="html">导出 HTML…</option><option value="pdf">导出 PDF…</option></select>
        <button id="save-as">另存为…</button>
      </div>
      <iframe id="markdown-frame" title="Markdown 编辑器" sandbox="allow-scripts" data-tab="${h(tab.id)}" src="/markdown-editor.html?${h(url)}"></iframe>
    </div>`;
}

async function saveWritingOutput(extension, tab) {
  const suggested = tab.title.replace(/\.[^.]+$/, "") + "." + extension;
  try {
    return await fileDialog("save", suggested);
  } catch (error) {
    if (error.message.includes("没有选择")) return "";
    return prompt("导出到新文件", suggested) || "";
  }
}

function markdownCommand(command, ...args) {
  document.getElementById("markdown-frame")?.contentWindow?.postMessage({gaoMarkdown: true, command, args}, "*");
}

function captureWritingSession() {
  const source = document.querySelector(".latex-source");
  if (source) {
    writingSession(source.dataset.tab).source = {top: source.scrollTop, left: source.scrollLeft,
      start: source.selectionStart, end: source.selectionEnd};
  }
}

function bindMarkdown(tab) {
  const frame = document.getElementById("markdown-frame");
  if (!frame) return;
  const session = writingSession(tab.id);
  document.querySelectorAll("[data-md-mode]").forEach((button) => button.onclick = () => {
    session.mode = button.dataset.mdMode;
    markdownCommand("setMode", session.mode);
    document.querySelectorAll("[data-md-mode]").forEach((item) => item.setAttribute("aria-pressed", item === button));
  });
  const outline = document.getElementById("md-outline");
  outline.onclick = () => {
    session.outline = !session.outline;
    outline.setAttribute("aria-pressed", session.outline);
    markdownCommand("setOutline", session.outline);
  };
  document.querySelectorAll("[data-md-format]").forEach((button) => button.onclick = () => markdownCommand("format", button.dataset.mdFormat));
  document.getElementById("md-insert").onchange = ({target}) => {
    const command = target.value;
    target.value = "";
    if (["math", "link"].includes(command)) markdownCommand("format", command);
    if (markdownSnippets[command]) markdownCommand("insertSnippet", markdownSnippets[command]);
  };
  const file = document.getElementById("md-image-file");
  document.getElementById("md-image").onclick = () => file.click();
  file.onchange = async () => {
    try {
      for (const image of file.files) {
        if (image.size > 25 * 1024 * 1024) throw new Error("图片超过 25 MB。");
        const data = await new Promise((resolve, reject) => {
          const reader = new FileReader();
          reader.onload = () => resolve(reader.result);
          reader.onerror = () => reject(new Error("无法读取图片。"));
          reader.readAsDataURL(image);
        });
        await insertMarkdownImage(tab.id, image.name, data, frame);
      }
    } catch (error) { fail(error); }
    file.value = "";
  };
  document.getElementById("md-export").onchange = async ({target}) => {
    const format = target.value;
    target.value = "";
    if (!format || session.export || frame.dataset.ready !== "true") return;
    const path = await saveWritingOutput(format, tab);
    if (path && frame.isConnected) {
      session.export = {format, path};
      markdownCommand("requestExport", format);
    }
  };
}

async function insertMarkdownImage(id, name, data, frame) {
  const payload = await api("/api/markdown/attachment", {id, name, data});
  if (frame.isConnected) markdownCommand("insertSnippet", payload.result.snippet);
}

window.addEventListener("message", async (event) => {
  const frame = document.getElementById("markdown-frame");
  if (event.origin !== "null" || !frame || event.source !== frame.contentWindow || !event.data?.gaoMarkdown) return;
  const id = frame.dataset.tab;
  const tab = state.tabs.find((item) => item.id === id);
  const session = writingSession(id);
  const data = event.data;
  try {
    if (data.kind === "ready") {
      frame.dataset.ready = "true";
      markdownCommand("load", tab.text, session.mode, session.outline, session.editor);
    }
    if (data.kind === "snapshot") session.editor = data.snapshot;
    if (data.kind === "change") stageEdit({id, text: data.text});
    if (data.kind === "save") await saveTab(false);
    if (data.kind === "pasteImage") await insertMarkdownImage(id, data.name, data.data, frame);
    if (data.kind === "link") {
      const status = document.getElementById("status");
      if (status) status.textContent = "当前工作台在本机运行。链接地址：" + data.href;
    }
    if (data.kind === "exportReady" && session.export?.format === data.format) {
      const requested = session.export;
      session.export = null;
      await flushEdits(id);
      if (requested.format === "pdf" && window.pywebview?.api) {
        await window.pywebview.api.print_markdown(id, requested.path, data.html);
      } else {
        await api("/api/export/" + requested.format, {id, path: requested.path, html: data.html});
      }
      const status = document.getElementById("status");
      if (status) status.textContent = "已导出 " + requested.path;
    }
    if (data.kind === "error") {
      session.export = null;
      throw new Error(data.message);
    }
  } catch (error) { fail(error); }
});

function latexPanel(tab) {
  const session = writingSession(tab.id);
  const result = tab.preview || {};
  const pages = result.pages || [];
  const page = pages[Math.min(session.page, pages.length - 1)];
  const width = Math.max(800, Math.min(2500, Math.ceil(1100 * devicePixelRatio * session.zoom)));
  const engine = session.engine || state.settings.latexEngine;
  const wrap = state.settings.wrapLines === false ? "off" : "soft";
  return `
    <div class="writing-panel" data-writing="latex">
      <div class="row writing-toolbar">
        <button id="latex-sidebar" aria-pressed="${session.latexSidebar}" title="显示结构与诊断">☷ 结构</button>
        <select id="latex-insert" aria-label="插入 LaTeX"><option value="">＋ 插入</option>
          <optgroup label="数学公式">${optionList({fraction: "分式", sqrt: "根号", sum: "求和", integral: "积分", equation: "行间编号公式", align: "多行对齐公式"})}</optgroup>
          <optgroup label="常用环境">${optionList({itemize: "项目符号", enumerate: "编号列表", figure: "插图", table: "表格"})}</optgroup>
          <optgroup label="文本样式与引用">${optionList({bold: "加粗", italic: "斜体", emphasis: "强调", section: "一级节", subsection: "二级节", label: "标签", ref: "引用", cite: "文献引用"})}</optgroup>
        </select>
        <select id="latex-engine" aria-label="编译器">
          ${Object.entries({auto: "自动", tectonic: "Tectonic · 离线", xelatex: "xelatex", pdflatex: "pdflatex", lualatex: "lualatex"}).map(([id, label]) =>
            `<option value="${id}" ${engine === id ? "selected" : ""}>${label}</option>`).join("")}
        </select>
        <button id="latex-master" title="选择 LaTeX 主文件">${h(session.main?.split(/[\\/]/).pop() || session.autoMain || "当前文件")}</button>
        <button id="latex-clear-master" title="恢复使用当前或自动识别的主文件" ${session.main ? "" : "hidden"}>清除指定</button>
        <span class="writing-spacer"></span>
        <button id="latex-compile" title="编译（Ctrl+B）">▶ 编译</button>
        <button id="latex-forward" ${pages.length ? "" : "disabled"}>定位 PDF</button>
        <button id="latex-export" ${pages.length ? "" : "disabled"}>导出 PDF…</button>
        <button id="latex-external" ${pages.length ? "" : "disabled"}>独立阅读</button>
        <button id="latex-log" aria-pressed="${session.log}">日志</button>
        <button id="save-as">另存为…</button>
      </div>
      <div class="latex-layout ${session.latexSidebar ? "latex-show-sidebar" : ""}">
        <aside class="latex-index">
          <div class="row"><button data-latex-pane="index" aria-pressed="${session.latexPane === "index"}">结构</button>
          <button data-latex-pane="diagnostics" aria-pressed="${session.latexPane === "diagnostics"}">诊断 ${result.diagnostics?.length || ""}</button></div>
          <div id="latex-index-items"></div>
        </aside>
        <div class="latex-source-panel">
          <div class="row latex-source-title"><b>LaTeX 源码</b><span class="writing-spacer"></span><button id="latex-complete" title="补全（Ctrl+空格）">补全</button></div>
          <div class="latex-source-area"><div class="latex-numbers" aria-hidden="true"></div><div class="latex-code-surface">
            <pre class="latex-highlight" aria-hidden="true"></pre><textarea class="editor latex-source" data-tab="${h(tab.id)}" aria-label="LaTeX 源码" spellcheck="false" wrap="${wrap}">${h(tab.text)}</textarea></div></div>
          <div id="latex-completions" class="latex-completions" hidden></div>
        </div>
        <section class="latex-preview">
          <div class="row latex-preview-toolbar"><b>PDF 预览</b><span class="writing-spacer"></span>
          ${page ? `<button id="latex-page-prev" title="上一页" aria-label="上一页" ${session.page ? "" : "disabled"}>‹</button><span id="latex-page-count">${page.number} / ${pages.length}</span><button id="latex-page-next" title="下一页" aria-label="下一页" ${session.page + 1 < pages.length ? "" : "disabled"}>›</button>
          <button id="latex-zoom-out" title="缩小" aria-label="缩小">−</button><button id="latex-actual" title="实际大小">100%</button><button id="latex-zoom-in" title="放大" aria-label="放大">＋</button>
          <button id="latex-fit-width" title="适应宽度" aria-label="适应宽度">↔</button><button id="latex-fit-page" title="适应页面" aria-label="适应页面">↕</button>` : ""}
          </div>
          <div class="latex-preview-scroll">${page ? pages.map((pdfPage, index) => {
            const flags = new URLSearchParams({tab: tab.id, token, generation: result.generation || "", page: index, width});
            const paperWidth = session.zoomMode === "page" ?
              `min(100%,calc((100cqh - 20px) * ${pdfPage.width / pdfPage.height}))` :
              session.zoomMode === "actual" ? `${pdfPage.width * 4 / 3}px` : `${session.zoom * 100}%`;
            return `<div class="latex-paper" data-latex-page="${index}" style="width:${paperWidth};aspect-ratio:${pdfPage.width}/${pdfPage.height}">
              <img class="latex-page-image" ${session.page === index ? 'id="latex-paper"' : 'loading="lazy"'} src="/api/latex/page?${h(flags)}" alt="编译 PDF 第 ${pdfPage.number} 页" title="按住 Ctrl 点击以返回源码"><i class="latex-pin" hidden></i></div>`;
          }).join("") :
            '<div class="latex-empty muted">编译后在这里预览 PDF</div>'}</div>
        </section>
      </div>
      ${session.log ? `<pre class="latex-log" aria-label="编译日志">${h(result.log || "尚未运行编译。")}</pre>` : ""}
      <div class="writing-status" aria-live="polite">${h(session.status || "")}</div>
    </div>`;
}

function jumpLatex(node, line, column = 1) {
  if (!node) return;
  const lines = node.value.split("\n");
  const index = Math.min(lines.length - 1, Math.max(0, line - 1));
  const offset = lines.slice(0, index).reduce((total, value) => total + value.length + 1, 0);
  const point = offset + Math.min(lines[index].length, Math.max(0, column - 1));
  node.focus();
  node.setSelectionRange(point, point);
  const numbers = node.closest(".latex-source-area")?.querySelector(".latex-numbers");
  const visible = numbers?.children[Math.max(0, index - 3)];
  if (visible) node.scrollTop = visible.getBoundingClientRect().top - numbers.getBoundingClientRect().top + numbers.scrollTop - 12;
}

function colorLatex(text) {
  const tokens = /\\[A-Za-z@]+|\\.|%[^\n]*|\$\$?|[{}[\]&]/g;
  let last = 0;
  let formatted = "";
  for (const match of text.matchAll(tokens)) {
    const part = match[0];
    const tone = part[0] === "%" ? "comment" : part[0] === "\\" ? "command" : part[0] === "$" ? "math" : "group";
    formatted += h(text.slice(last, match.index)) + `<span class="latex-tone-${tone}">${h(part)}</span>`;
    last = match.index + part.length;
  }
  return formatted + h(text.slice(last)) + "\n";
}

function bindLatex(tab) {
  const panel = document.querySelector('[data-writing="latex"]');
  if (!panel) return;
  const session = writingSession(tab.id);
  const byId = (id) => panel.querySelector("#" + id);
  const source = panel.querySelector(".latex-source");
  const paint = panel.querySelector(".latex-highlight");
  const numbers = panel.querySelector(".latex-numbers");
  const newline = tab.text.includes("\r\n") ? "\r\n" : "\n";
  const nativeText = (value) => newline === "\r\n" ? value.replace(/\n/g, "\r\n") : value;
  const pane = byId("latex-index-items");
  const status = (text) => { session.status = text; panel.querySelector(".writing-status").textContent = text; };
  const showIndex = () => {
    const data = session.latexPane === "diagnostics" ? tab.preview?.diagnostics : session.index?.nodes;
    pane.replaceChildren();
    for (const item of data || []) {
      const button = document.createElement("button");
      button.textContent = [item.line, item.message || item.title].filter(Boolean).join("  ");
      button.title = item.detail || item.title || "";
      button.onclick = async () => {
        const filename = item.file;
        if (filename && tab.path && filename.split(/[\\/]/).pop() !== tab.title) {
          const root = tab.preview?.source || session.main || tab.path;
          const path = /^(?:[A-Za-z]:[\\/]|[\\/])/.test(filename) ? filename : root.replace(/[^\\/]+$/, "") + filename;
          await openPath(path);
        }
        if (item.line) jumpLatex(document.querySelector(".latex-source"), item.line);
      };
      pane.append(button);
    }
    if (!pane.childNodes.length) pane.textContent = session.latexPane === "diagnostics" ? "没有编译诊断" : "文档中没有章节、插图或引用";
  };
  const refreshIndex = async () => {
    await flushEdits(tab.id);
    const {result} = await api("/api/tabs/preview", {id: tab.id});
    session.index = result.index;
    session.autoMain = result.root ? result.root.split(/[\\/]/).pop() + "（自动识别）" : "";
    if (panel.isConnected) {
      if (!session.main) byId("latex-master").textContent = session.autoMain || "当前文件";
      showIndex();
    }
  };
  let indexTimer, suggestionTimer;
  const mirrorScroll = () => {
    paint.scrollTop = numbers.scrollTop = source.scrollTop;
    paint.scrollLeft = source.scrollLeft;
  };
  const updateNumbers = () => {
    const probe = document.createElement("div");
    probe.className = "latex-line-measure";
    probe.style.width = Math.max(1, source.clientWidth - 16) + "px";
    const lines = source.value.split("\n");
    const counts = document.createDocumentFragment();
    if (source.wrap === "soft") {
      for (const line of lines) {
        probe.append(Object.assign(document.createElement("div"), {textContent: line || " "}));
      }
      panel.append(probe);
    }
    lines.forEach((_, index) => {
      const count = document.createElement("div");
      count.textContent = index + 1;
      if (source.wrap === "soft") count.style.height = probe.children[index].offsetHeight + "px";
      counts.append(count);
    });
    numbers.replaceChildren(counts);
    probe.remove();
    paint.style.whiteSpace = source.wrap === "soft" ? "pre-wrap" : "pre";
    paint.style.paddingRight = 8 + source.offsetWidth - source.clientWidth + "px";
    paint.innerHTML = colorLatex(source.value);
    mirrorScroll();
  };
  source.oninput = (event) => {
    stageEdit({id: tab.id, text: nativeText(source.value)});
    updateNumbers();
    clearTimeout(indexTimer);
    indexTimer = setTimeout(() => refreshIndex().catch(fail), 450);
    clearTimeout(suggestionTimer);
    byId("latex-completions").hidden = true;
    if (!event?.isComposing && /\\[A-Za-z@]+$|\\[A-Za-z@]+\{[A-Za-z0-9_:\-]*$/.test(source.value.slice(0, source.selectionStart))) {
      suggestionTimer = setTimeout(() => complete(false).catch(fail), 210);
    }
  };
  source.addEventListener("scroll", mirrorScroll);
  source.addEventListener("compositionstart", () => source.parentElement.classList.add("is-composing"));
  source.addEventListener("compositionend", () => { source.parentElement.classList.remove("is-composing"); updateNumbers(); });
  if (session.source) {
    source.setSelectionRange(session.source.start, session.source.end);
    source.scrollTop = session.source.top;
    source.scrollLeft = session.source.left;
  }
  updateNumbers();
  const resize = new ResizeObserver(() => {
    if (!source.isConnected) resize.disconnect();
    else updateNumbers();
  });
  resize.observe(source);
  showIndex();
  if (!session.index) refreshIndex().catch(fail);
  panel.querySelectorAll("[data-latex-pane]").forEach((button) => button.onclick = () => {
    session.latexPane = button.dataset.latexPane;
    panel.querySelectorAll("[data-latex-pane]").forEach((item) => item.setAttribute("aria-pressed", item === button));
    showIndex();
  });
  byId("latex-sidebar").onclick = () => { session.latexSidebar = !session.latexSidebar; render(); };
  byId("latex-log").onclick = () => { session.log = !session.log; render(); };
  byId("latex-engine").onchange = ({target}) => { session.engine = target.value; };
  byId("latex-master").onclick = async () => {
    try { const path = await fileDialog("open"); if (path) { session.main = path; render(); } }
    catch (error) { if (!error.message.includes("没有选择")) fail(error); }
  };
  byId("latex-clear-master").onclick = () => { session.main = null; render(); };

  const insert = (value, back = 0, start = source.selectionStart) => {
    source.setRangeText(value, start, source.selectionEnd, "end");
    source.setSelectionRange(source.selectionStart - back, source.selectionStart - back);
    source.focus();
    source.oninput();
  };
  byId("latex-insert").onchange = ({target}) => {
    if (latexSnippets[target.value]) insert(...latexSnippets[target.value]);
    target.value = "";
  };
  const complete = async (focus = true) => {
    const selectionStart = source.selectionStart;
    const value = source.value;
    await flushEdits(tab.id);
    const cursor = Array.from(nativeText(value.slice(0, selectionStart))).length;
    const {result} = await api("/api/tabs/complete", {id: tab.id, cursor});
    if (!source.isConnected || source.value !== value || source.selectionStart !== selectionStart) return;
    const items = byId("latex-completions");
    const start = Array.from(nativeText(source.value)).slice(0, result.start).join("").replace(/\r\n/g, "\n").length;
    items.replaceChildren();
    items.hidden = !result.items.length;
    for (const entry of result.items) {
      const button = document.createElement("button");
      button.textContent = entry.title + " · " + entry.subtitle;
      button.onclick = () => { insert(entry.insert, entry.caretFromEnd, start); items.hidden = true; };
      items.append(button);
    }
    if (focus) items.firstElementChild?.focus();
  };
  byId("latex-complete").onclick = () => complete().catch(fail);

  const compile = async () => {
    if (session.busy) return;
    session.busy = true;
    session.status = "正在本地编译…";
    const button = byId("latex-compile");
    button.disabled = true;
    status(session.status);
    try {
      await flushEdits(tab.id);
      let current = state.tabs.find((item) => item.id === tab.id);
      if (current.dirty || !current.path) {
        if (!current.path) {
          const path = await saveWritingOutput("tex", current);
          if (!path) return;
          await api("/api/tabs/save", {id: tab.id, path});
        } else {
          await api("/api/tabs/save", {id: tab.id});
        }
      }
      const {result} = await api("/api/tabs/compile", {id: tab.id, main: session.main, engine: session.engine});
      session.status = state.status;
      if (result.success) {
        session.page = 0;
        session.pin = null;
      } else {
        session.latexSidebar = true;
        session.latexPane = "diagnostics";
        session.log = true;
      }
      if (panel.isConnected) render();
    } catch (error) { fail(error); }
    finally { session.busy = false; button.disabled = false; }
  };
  byId("latex-compile").onclick = compile;
  panel.addEventListener("keydown", (event) => {
    const completions = byId("latex-completions");
    if (event.key === "Escape" && !completions.hidden) {
      completions.hidden = true;
      source.focus();
    }
    if (!completions.hidden && ["ArrowDown", "ArrowUp"].includes(event.key)) {
      const focused = completions.contains(document.activeElement) ? document.activeElement : null;
      const item = event.key === "ArrowDown" ? focused?.nextElementSibling || completions.firstElementChild :
        focused?.previousElementSibling || completions.lastElementChild;
      item?.focus();
      event.preventDefault();
    }
    if (!event.ctrlKey && !event.metaKey) return;
    if (event.key.toLowerCase() === "b") { event.preventDefault(); compile(); }
    if (event.code === "Space") { event.preventDefault(); complete().catch(fail); }
  });
  byId("latex-export").onclick = async () => {
    const path = await saveWritingOutput("pdf", tab);
    if (path) api("/api/latex/export", {id: tab.id, path}).then(() => status("已导出 " + path)).catch(fail);
  };
  byId("latex-external").onclick = () => {
    if (window.pywebview?.api) {
      window.pywebview.api.show_latex_pdf(tab.id).catch(fail);
      return;
    }
    const url = new URLSearchParams({tab: tab.id, token});
    window.open("/api/latex/document?" + url, "_blank", "popup,width=900,height=850");
  };
  const pages = tab.preview?.pages || [];
  const scroll = panel.querySelector(".latex-preview-scroll");
  const papers = [...scroll.querySelectorAll(".latex-paper")];
  const selectPage = (index, reveal = false) => {
    session.page = Math.max(0, Math.min(papers.length - 1, index));
    const active = papers[session.page];
    byId("latex-paper")?.removeAttribute("id");
    active.querySelector("img").id = "latex-paper";
    byId("latex-page-count").textContent = (session.page + 1) + " / " + papers.length;
    byId("latex-page-prev").disabled = session.page === 0;
    byId("latex-page-next").disabled = session.page === papers.length - 1;
    if (reveal) {
      scroll.scrollTop += active.getBoundingClientRect().top - scroll.getBoundingClientRect().top - 10;
    }
  };
  const setZoom = (mode, zoom = 1) => { session.zoom = zoom; session.zoomMode = mode; render(); };
  if (papers.length) {
    byId("latex-page-prev").onclick = () => selectPage(session.page - 1, true);
    byId("latex-page-next").onclick = () => selectPage(session.page + 1, true);
    byId("latex-zoom-in").onclick = () => setZoom("width", Math.min(3, session.zoom + 0.2));
    byId("latex-zoom-out").onclick = () => setZoom("width", Math.max(0.45, session.zoom - 0.2));
    byId("latex-actual").onclick = () => setZoom("actual");
    byId("latex-fit-width").onclick = () => setZoom("width");
    byId("latex-fit-page").onclick = () => setZoom("page");
    selectPage(session.page, true);
    scroll.addEventListener("scroll", () => {
      const top = scroll.getBoundingClientRect().top;
      const active = papers.findIndex((paper) => paper.getBoundingClientRect().bottom > top + 20);
      if (active >= 0 && active !== session.page) selectPage(active);
    });
  }
  papers.forEach((sheet, index) => {
    const page = pages[index];
    const paper = sheet.querySelector("img");
    const pin = sheet.querySelector(".latex-pin");
    if (session.pin?.Page === page.number) {
      pin.hidden = false;
      pin.style.left = Math.max(0, Math.min(99, 100 * session.pin.x / page.width)) + "%";
      pin.style.top = Math.max(0, Math.min(99, 100 * session.pin.y / page.height)) + "%";
      const reveal = () => pin.scrollIntoView({block: "center", inline: "nearest"});
      if (paper.complete) reveal();
      else paper.addEventListener("load", reveal, {once: true});
    }
    paper.onclick = async (event) => {
      if (!event.ctrlKey && !event.metaKey) return;
      const rect = paper.getBoundingClientRect();
      try {
        const {result} = await api("/api/tabs/synctex", {id: tab.id, direction: "inverse", page: page.number,
          x: (event.clientX - rect.left) / rect.width * page.width, y: (event.clientY - rect.top) / rect.height * page.height});
        if (result.Input.toLowerCase() !== tab.path.toLowerCase()) await openPath(result.Input);
        jumpLatex(document.querySelector(".latex-source"), result.Line, result.Column);
      } catch (error) { status(error.message); }
    };
  });
  byId("latex-forward").onclick = async () => {
    try {
      const line = source.value.slice(0, source.selectionStart).split("\n").length;
      const {result} = await api("/api/tabs/synctex", {id: tab.id, direction: "forward", line});
      session.pin = result;
      session.page = result.Page - 1;
      status("已定位到 PDF 第 " + result.Page + " 页");
      render();
    } catch (error) { status(error.message); }
  };
}

function bindWriting(tab) {
  if (tab?.kind === "markdown") bindMarkdown(tab);
  if (tab?.kind === "latex") bindLatex(tab);
}
