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

function writingTitle(tab, label, actions) {
  return `<header class="writing-heading">
    <div class="writing-identity">
      <span class="writing-kind-icon" aria-hidden="true">${icon(tab.kind)}</span>
      <div class="writing-name">
        <h1 title="${h(tab.path || tab.title)}">${h(tab.title)}</h1>
        <div class="writing-file-meta">
          <span>${label}${tab.encoding ? " · " + h(tab.encoding.toUpperCase()) : ""}</span>
          <span class="writing-dirty" data-writing-dirty ${tab.dirty ? "" : "hidden"}>未保存</span>
        </div>
      </div>
    </div>
    <div class="writing-heading-actions">${actions}</div>
  </header>`;
}

function markdownPanel(tab) {
  const session = writingSession(tab.id);
  const url = new URLSearchParams({tab: tab.id, token, theme: document.documentElement.dataset.theme || "light",
    font: state.settings.editorFontSize || 15, wrap: state.settings.wrapLines === false ? "off" : "soft"});
  return `
    <div class="writing-panel" data-writing="markdown" data-tab-id="${h(tab.id)}">
      ${writingTitle(tab, "Markdown", `<button id="save-as">另存为…</button>
        <select id="md-export" aria-label="导出 Markdown" disabled><option value="">${session.export ? "导出中…" : "导出"}</option><option value="html">导出 HTML…</option><option value="pdf">导出 PDF…</option></select>`)}
      <div class="writing-toolbar" aria-label="Markdown 工具">
        <div class="writing-modes" role="group" aria-label="Markdown 编辑模式">
          ${Object.entries({live: "即时编辑", split: "分屏", source: "源码"}).map(([mode, title]) =>
            `<button type="button" data-md-mode="${mode}" aria-pressed="${session.mode === mode}">${title}</button>`).join("")}
        </div>
        <span class="writing-spacer"></span>
        <div class="writing-actions" role="group" aria-label="格式">
          <button class="writing-icon-button" data-md-format="bold" title="加粗（Ctrl+B）" aria-label="加粗"><b>B</b></button>
          <button class="writing-icon-button" data-md-format="italic" title="斜体（Ctrl+I）" aria-label="斜体"><i>I</i></button>
        </div>
        <div class="writing-actions" role="group" aria-label="插入与导航">
          <select id="md-insert" aria-label="插入"><option value="">插入</option>
            <optgroup label="段落">${optionList({h1: "一级标题", h2: "二级标题", list: "无序列表", task: "任务列表", quote: "引用"})}</optgroup>
            <optgroup label="内容">${optionList({table: "表格", code: "代码块", math: "行内公式", display: "公式块", mermaid: "Mermaid 图示", footnote: "脚注", link: "链接"})}</optgroup>
          </select>
          <button id="md-image">插入图片</button><input id="md-image-file" type="file" accept="image/png,image/jpeg,image/gif,image/webp,image/bmp,image/svg+xml" hidden multiple>
          <button id="md-outline" aria-pressed="${session.outline}">${icon("sidebar")} 大纲</button>
        </div>
      </div>
      <div class="markdown-frame-wrap" aria-busy="true">
        <div class="markdown-frame-loading" role="status">正在加载编辑器…</div>
        <iframe id="markdown-frame" title="Markdown 编辑器" sandbox="allow-scripts" data-tab="${h(tab.id)}" src="/markdown-editor.html?${h(url)}"></iframe>
      </div>
      <div id="md-export-status" class="writing-feedback" aria-live="polite" ${session.markdownStatus ? "" : "hidden"}>${h(session.markdownStatus || "")}</div>
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

function markWritingDirty(id) {
  const panel = document.querySelector(".writing-panel");
  if (panel?.dataset.tabId === id) panel.querySelector("[data-writing-dirty]").hidden = false;
}

function markdownExportState(session, frame, text = "") {
  session.markdownStatus = text;
  const mounted = document.getElementById("markdown-frame");
  if (mounted?.dataset.tab !== frame.dataset.tab) return;
  const panel = mounted.closest(".writing-panel");
  const status = panel.querySelector("#md-export-status");
  const picker = panel.querySelector("#md-export");
  status.textContent = text;
  status.hidden = !text;
  picker.disabled = Boolean(session.export) || mounted.dataset.ready !== "true";
  picker.options[0].textContent = session.export ? "导出中…" : "导出";
}

function bindMarkdown(tab) {
  const frame = document.getElementById("markdown-frame");
  if (!frame) return;
  const session = writingSession(tab.id);
  const modes = [...document.querySelectorAll("[data-md-mode]")];
  modes.forEach((button, index) => {
    button.onclick = () => {
      session.mode = button.dataset.mdMode;
      markdownCommand("setMode", session.mode);
      modes.forEach((item) => item.setAttribute("aria-pressed", item === button));
    };
    button.onkeydown = (event) => {
      const direction = event.key === "ArrowLeft" ? -1 : event.key === "ArrowRight" ? 1 : 0;
      if (!direction) return;
      event.preventDefault();
      const next = modes[(index + direction + modes.length) % modes.length];
      next.focus();
      next.click();
    };
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
      markdownExportState(session, frame, format === "pdf" ? "正在生成排版 PDF…" : "正在生成 HTML…");
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
  if (!tab) return;
  const session = writingSession(id);
  const data = event.data;
  try {
    if (data.kind === "ready") {
      frame.dataset.ready = "true";
      frame.closest(".markdown-frame-wrap").setAttribute("aria-busy", "false");
      markdownExportState(session, frame, session.markdownStatus);
      markdownCommand("load", tab.text, session.mode, session.outline, session.editor);
      if (session.export && !session.export.printing) markdownCommand("requestExport", session.export.format);
    }
    if (data.kind === "snapshot") session.editor = data.snapshot;
    if (data.kind === "change") {
      stageEdit({id, text: data.text});
      markWritingDirty(id);
    }
    if (data.kind === "save") await saveTab(false);
    if (data.kind === "pasteImage") await insertMarkdownImage(id, data.name, data.data, frame);
    if (data.kind === "link") {
      const status = document.getElementById("status");
      if (status) status.textContent = "当前工作台在本机运行。链接地址：" + data.href;
    }
    if (data.kind === "exportReady" && session.export?.format === data.format) {
      const requested = session.export;
      if (requested.printing) return;
      requested.printing = true;
      try {
        await flushEdits(id);
        if (requested.format === "pdf" && window.pywebview?.api) {
          await window.pywebview.api.print_markdown(id, requested.path, data.html);
        } else {
          await api("/api/export/" + requested.format, {id, path: requested.path, html: data.html});
        }
        session.export = null;
        markdownExportState(session, frame, "已导出 " + requested.path.replace(/^.*[\\/]/, ""));
      } catch (error) {
        session.export = null;
        markdownExportState(session, frame, "");
        throw error;
      }
    }
    if (data.kind === "error") {
      session.export = null;
      markdownExportState(session, frame, "");
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
  const compileState = session.busy ? ["busy", "编译中"] : result.success ? ["success", "编译成功"] :
    result.success === false ? ["error", "编译未完成"] : ["idle", "尚未编译"];
  return `
    <div class="writing-panel" data-writing="latex" data-tab-id="${h(tab.id)}">
      ${writingTitle(tab, "LaTeX", `<button id="save-as">另存为…</button>
        <button id="latex-external" ${pages.length ? "" : "disabled"}>独立阅读</button>
        <button id="latex-export" ${pages.length ? "" : "disabled"}>导出 PDF…</button>`)}
      <div class="writing-toolbar latex-toolbar" aria-label="LaTeX 工具">
        <div class="writing-actions" role="group" aria-label="源码工具">
          <button id="latex-sidebar" aria-pressed="${session.latexSidebar}" aria-controls="latex-index" title="显示结构与诊断">${icon("sidebar")} 结构</button>
          <select id="latex-insert" aria-label="插入 LaTeX"><option value="">插入</option>
          <optgroup label="数学公式">${optionList({fraction: "分式", sqrt: "根号", sum: "求和", integral: "积分", equation: "行间编号公式", align: "多行对齐公式"})}</optgroup>
          <optgroup label="常用环境">${optionList({itemize: "项目符号", enumerate: "编号列表", figure: "插图", table: "表格"})}</optgroup>
          <optgroup label="文本样式与引用">${optionList({bold: "加粗", italic: "斜体", emphasis: "强调", section: "一级节", subsection: "二级节", label: "标签", ref: "引用", cite: "文献引用"})}</optgroup>
          </select>
        </div>
        <span class="writing-spacer"></span>
        <div class="writing-actions latex-build-tools" role="group" aria-label="编译工具">
          <label class="latex-engine-field"><span>引擎</span><select id="latex-engine" aria-label="编译器">
            ${Object.entries({auto: "自动", tectonic: "Tectonic · 离线", xelatex: "xelatex", pdflatex: "pdflatex", lualatex: "lualatex"}).map(([id, label]) =>
              `<option value="${id}" ${engine === id ? "selected" : ""}>${label}</option>`).join("")}
          </select></label>
          <button id="latex-master" title="选择 LaTeX 主文件">${h(session.main?.split(/[\\/]/).pop() || session.autoMain || "当前文件")}</button>
          <button id="latex-clear-master" aria-label="恢复使用当前或自动识别的主文件" title="恢复使用当前或自动识别的主文件" ${session.main ? "" : "hidden"}>清除指定</button>
          <button id="latex-log" aria-pressed="${session.log}" aria-controls="latex-log-panel">日志</button>
          <button id="latex-compile" class="writing-primary" title="编译（Ctrl+B）" ${session.busy ? "disabled aria-busy='true'" : ""}><span aria-hidden="true">▶</span> <span data-compile-label>${session.busy ? "编译中…" : "编译"}</span></button>
        </div>
      </div>
      <div class="latex-layout ${session.latexSidebar ? "latex-show-sidebar" : ""}" data-build-state="${compileState[0]}">
        <aside id="latex-index" class="latex-index" aria-label="文档结构和编译诊断">
          <div class="writing-subheading latex-index-heading">
            <div class="writing-modes" role="group" aria-label="结构与诊断">
              <button data-latex-pane="index" aria-pressed="${session.latexPane === "index"}">结构</button>
              <button data-latex-pane="diagnostics" aria-pressed="${session.latexPane === "diagnostics"}">诊断${result.diagnostics?.length ? " · " + result.diagnostics.length : ""}</button>
            </div>
          </div>
          <div id="latex-index-items"></div>
        </aside>
        <div class="latex-source-panel">
          <div class="writing-subheading latex-source-title"><strong>源码</strong><span class="writing-spacer"></span>
            <button id="latex-complete" title="补全（Ctrl+空格）">补全</button></div>
          <div class="latex-source-area"><div class="latex-numbers" aria-hidden="true"></div><div class="latex-code-surface">
            <pre class="latex-highlight" aria-hidden="true"></pre><textarea id="latex-source" class="editor latex-source" data-tab="${h(tab.id)}" aria-label="LaTeX 源码" spellcheck="false" wrap="${wrap}">${h(tab.text)}</textarea></div></div>
          <div id="latex-completions" class="latex-completions" hidden></div>
        </div>
        <section class="latex-preview" aria-label="LaTeX PDF 预览">
          <div class="writing-subheading"><strong>PDF 预览</strong><span class="writing-spacer"></span>
            <span class="latex-build-state" data-build-label>${compileState[1]}</span>
            <button id="latex-forward" title="将当前源码行定位到 PDF" ${pages.length ? "" : "disabled"}>定位</button>
          </div>
          ${page ? `<div class="latex-preview-toolbar" aria-label="PDF 导航和缩放">
            <div class="writing-actions" role="group" aria-label="页码"><button id="latex-page-prev" title="上一页" aria-label="上一页" ${session.page ? "" : "disabled"}>‹</button><span id="latex-page-count">${page.number} / ${pages.length}</span><button id="latex-page-next" title="下一页" aria-label="下一页" ${session.page + 1 < pages.length ? "" : "disabled"}>›</button></div>
            <div class="writing-actions" role="group" aria-label="缩放"><button id="latex-zoom-out" title="缩小" aria-label="缩小">−</button><button id="latex-actual" title="实际大小">100%</button><button id="latex-zoom-in" title="放大" aria-label="放大">＋</button>
            <button id="latex-fit-width" title="适应宽度" aria-label="适应宽度">↔</button><button id="latex-fit-page" title="适应页面" aria-label="适应页面">↕</button></div>
          </div>` : ""}
          <div class="latex-preview-scroll">${page ? pages.map((pdfPage, index) => {
            const flags = new URLSearchParams({tab: tab.id, token, generation: result.generation || "", page: index, width});
            const paperWidth = session.zoomMode === "page" ?
              `min(100%,calc((100cqh - 20px) * ${pdfPage.width / pdfPage.height}))` :
              session.zoomMode === "actual" ? `${pdfPage.width * 4 / 3}px` : `${session.zoom * 100}%`;
            return `<div class="latex-paper" data-latex-page="${index}" style="width:${paperWidth};aspect-ratio:${pdfPage.width}/${pdfPage.height}">
              <img class="latex-page-image" ${session.page === index ? 'id="latex-paper"' : 'loading="lazy"'} src="/api/latex/page?${h(flags)}" alt="编译 PDF 第 ${pdfPage.number} 页" title="按住 Ctrl 点击以返回源码"><i class="latex-pin" hidden></i></div>`;
          }).join("") :
            `<div class="latex-empty"><span class="latex-empty-icon" aria-hidden="true">${icon("doc")}</span><strong>编译后在这里预览 PDF</strong></div>`}</div>
        </section>
      </div>
      <section id="latex-log-panel" class="latex-log-panel" ${session.log ? "" : "hidden"} aria-label="编译日志">
        <div class="writing-subheading"><strong>编译日志</strong><span class="writing-spacer"></span><button id="latex-close-log" aria-label="关闭编译日志">${icon("close")}</button></div>
        <pre class="latex-log" tabindex="0">${h(result.log || "尚未运行编译。")}</pre>
      </section>
      <div class="writing-status writing-feedback" aria-live="polite" ${session.status ? "" : "hidden"}>${h(session.status || "")}</div>
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
  const layout = panel.querySelector(".latex-layout");
  const newline = tab.text.includes("\r\n") ? "\r\n" : "\n";
  const nativeText = (value) => newline === "\r\n" ? value.replace(/\n/g, "\r\n") : value;
  const pane = byId("latex-index-items");
  const status = (text) => {
    session.status = text;
    const notice = panel.querySelector(".writing-status");
    notice.textContent = text;
    notice.hidden = !text;
  };
  const renderWithFocus = (control, focused = document.activeElement === control) => {
    render();
    if (focused && control.id) document.getElementById(control.id)?.focus({preventScroll: true});
  };
  const showIndex = () => {
    const data = session.latexPane === "diagnostics" ? tab.preview?.diagnostics : session.index?.nodes;
    pane.replaceChildren();
    for (const item of data || []) {
      const entry = document.createElement(item.line || item.file ? "button" : "div");
      entry.className = "latex-index-entry";
      if (item.severity) entry.dataset.severity = item.severity;
      entry.title = item.detail || item.title || "";
      const line = document.createElement("span");
      line.className = "latex-index-item-line";
      line.textContent = item.line || "–";
      const name = document.createElement("span");
      name.className = "latex-index-item-name";
      name.textContent = item.message || item.title;
      entry.append(line, name);
      if (entry.tagName === "BUTTON") entry.onclick = async () => {
        const filename = item.file;
        if (filename && tab.path && filename.split(/[\\/]/).pop() !== tab.title) {
          const root = tab.preview?.source || session.main || tab.path;
          const path = /^(?:[A-Za-z]:[\\/]|[\\/])/.test(filename) ? filename : root.replace(/[^\\/]+$/, "") + filename;
          await openPath(path);
        }
        if (item.line) jumpLatex(document.querySelector(".latex-source"), item.line);
      };
      pane.append(entry);
    }
    if (!pane.childNodes.length) {
      const empty = document.createElement("p");
      empty.className = "latex-index-empty";
      empty.textContent = session.latexPane === "diagnostics" ? "没有编译诊断" : "文档中没有章节、插图或引用";
      pane.append(empty);
    }
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
    const horizontalPadding = parseFloat(getComputedStyle(source).paddingInlineStart);
    probe.style.width = Math.max(1, source.clientWidth - 2 * horizontalPadding) + "px";
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
    paint.style.paddingRight = horizontalPadding + source.offsetWidth - source.clientWidth + "px";
    paint.innerHTML = colorLatex(source.value);
    mirrorScroll();
  };
  source.oninput = (event) => {
    stageEdit({id: tab.id, text: nativeText(source.value)});
    markWritingDirty(tab.id);
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
  byId("latex-sidebar").onclick = () => {
    session.latexSidebar = !session.latexSidebar;
    layout.classList.toggle("latex-show-sidebar", session.latexSidebar);
    byId("latex-sidebar").setAttribute("aria-pressed", session.latexSidebar);
  };
  const setLogVisible = (visible) => {
    session.log = visible;
    byId("latex-log-panel").hidden = !visible;
    byId("latex-log").setAttribute("aria-pressed", visible);
  };
  byId("latex-log").onclick = () => setLogVisible(!session.log);
  byId("latex-close-log").onclick = () => {
    setLogVisible(false);
    byId("latex-log").focus({preventScroll: true});
  };
  byId("latex-engine").onchange = ({target}) => { session.engine = target.value; };
  byId("latex-master").onclick = async () => {
    try { const path = await fileDialog("open"); if (path) { session.main = path; renderWithFocus(byId("latex-master")); } }
    catch (error) { if (!error.message.includes("没有选择")) fail(error); }
  };
  byId("latex-clear-master").onclick = () => {
    session.main = null;
    render();
    document.getElementById("latex-master")?.focus({preventScroll: true});
  };

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
    const previousStatus = session.status || "";
    const previousStage = layout.dataset.buildState;
    const buildLabel = panel.querySelector("[data-build-label]");
    const previousBuildLabel = buildLabel.textContent;
    const initialFocus = document.activeElement;
    let completed = false;
    session.busy = true;
    const button = byId("latex-compile");
    button.disabled = true;
    button.setAttribute("aria-busy", "true");
    button.querySelector("[data-compile-label]").textContent = "编译中…";
    layout.dataset.buildState = "busy";
    buildLabel.textContent = "编译中";
    status("正在本地编译…");
    try {
      await flushEdits(tab.id);
      const current = state.tabs.find((item) => item.id === tab.id);
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
      completed = true;
      session.status = "";
      if (result.success) {
        session.page = 0;
        session.pin = null;
      } else {
        session.latexSidebar = true;
        session.latexPane = "diagnostics";
        session.log = true;
      }
    } catch (error) {
      session.busy = false;
      session.status = previousStatus;
      fail(error);
    } finally {
      session.busy = false;
      if (panel.isConnected && completed) {
        if (initialFocus === button || initialFocus === source) renderWithFocus(initialFocus, true);
        else render();
      }
      else if (panel.isConnected) {
        button.disabled = false;
        button.removeAttribute("aria-busy");
        button.querySelector("[data-compile-label]").textContent = "编译";
        layout.dataset.buildState = previousStage;
        buildLabel.textContent = previousBuildLabel;
        status(previousStatus);
      }
    }
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
    window.open("/latex-reader.html?" + url, "_blank", "popup,width=1000,height=850");
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
  const setZoom = (control, mode, zoom = 1) => { session.zoom = zoom; session.zoomMode = mode; renderWithFocus(control); };
  if (papers.length) {
    byId("latex-page-prev").onclick = () => selectPage(session.page - 1, true);
    byId("latex-page-next").onclick = () => selectPage(session.page + 1, true);
    byId("latex-zoom-in").onclick = (event) => setZoom(event.currentTarget, "width", Math.min(3, session.zoom + 0.2));
    byId("latex-zoom-out").onclick = (event) => setZoom(event.currentTarget, "width", Math.max(0.45, session.zoom - 0.2));
    byId("latex-actual").onclick = (event) => setZoom(event.currentTarget, "actual");
    byId("latex-fit-width").onclick = (event) => setZoom(event.currentTarget, "width");
    byId("latex-fit-page").onclick = (event) => setZoom(event.currentTarget, "page");
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
  byId("latex-forward").onclick = async (event) => {
    const control = event.currentTarget;
    try {
      const line = source.value.slice(0, source.selectionStart).split("\n").length;
      const {result} = await api("/api/tabs/synctex", {id: tab.id, direction: "forward", line});
      session.pin = result;
      session.page = result.Page - 1;
      status("已定位到 PDF 第 " + result.Page + " 页");
      renderWithFocus(control);
    } catch (error) { status(error.message); }
  };
}

function bindWriting(tab) {
  if (tab?.kind === "markdown") bindMarkdown(tab);
  if (tab?.kind === "latex") bindLatex(tab);
}
