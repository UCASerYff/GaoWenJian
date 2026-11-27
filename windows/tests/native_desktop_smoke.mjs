import assert from "node:assert/strict";
import {spawn} from "node:child_process";
import {mkdir, mkdtemp, readFile, rm, writeFile} from "node:fs/promises";
import {createServer} from "node:net";
import {tmpdir} from "node:os";
import {basename, join, resolve} from "node:path";
import {setTimeout as delay} from "node:timers/promises";

const executable = resolve(process.argv[2]);
const evidence = process.argv[3] ? resolve(process.argv[3]) : null;
const source = /python(?:w)?\.exe$/i.test(basename(executable));
const root = await mkdtemp(join(tmpdir(), "gao-wenjian-native-"));
const dataPath = join(root, "profile");

async function freePort() {
  const server = createServer();
  await new Promise((done, fail) => server.on("error", fail).listen(0, "127.0.0.1", done));
  const port = server.address().port;
  await new Promise((done) => server.close(done));
  return port;
}

const [appPort, debuggerPort] = await Promise.all([freePort(), freePort()]);
const appUrl = `http://127.0.0.1:${appPort}`;
const child = spawn(executable, [...(source ? [resolve("windows/launch.py")] : []), "--hidden", "--data-dir", dataPath, "--port", `${appPort}`], {
  windowsHide: true,
  stdio: ["ignore", "ignore", "pipe"],
  env: {...process.env, WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS: `--remote-debugging-port=${debuggerPort} --disable-background-networking`},
});
let logs = "";
child.stderr.setEncoding("utf8").on("data", (line) => { logs += line; });
const clients = [];

async function until(probe, name, timeout = 25000) {
  const end = Date.now() + timeout;
  while (Date.now() < end) {
    if (child.exitCode !== null) throw Error(`Native process exited with ${child.exitCode}\n${logs}`);
    try { const value = await probe(); if (value) return value; }
    catch { /* the target is still starting */ }
    await delay(125);
  }
  throw Error(`Timed out waiting for ${name}\n${logs}`);
}

async function connect(path, type = "page") {
  const endpoint = await until(async () => {
    const targets = await (await fetch(`http://127.0.0.1:${debuggerPort}/json/list`)).json();
    return targets.find((item) => item.url.startsWith(`${appUrl}${path}`) && item.type === type);
  }, `WebView2 ${path}`, 35000);
  const socket = new WebSocket(endpoint.webSocketDebuggerUrl);
  clients.push(socket);
  await new Promise((done, fail) => { socket.addEventListener("open", done, {once: true}); socket.addEventListener("error", fail, {once: true}); });
  let id = 0;
  async function request(method, params = {}) {
    const message = {id: ++id, method, params};
    return new Promise((done, fail) => {
      const timer = setTimeout(() => { socket.removeEventListener("message", got); fail(Error(`WebView2 request timed out: ${method}`)); }, 30000);
      function got(event) {
        const reply = JSON.parse(event.data);
        if (reply.id !== message.id) return;
        socket.removeEventListener("message", got);
        clearTimeout(timer);
        const error = reply.error?.message || reply.result?.exceptionDetails?.exception?.description;
        if (error) fail(Error(error));
        else done(reply.result);
      }
      socket.addEventListener("message", got);
      socket.send(JSON.stringify(message));
    });
  }
  const evaluate = async (expression) => (await request("Runtime.evaluate", {expression, returnByValue: true, awaitPromise: true})).result?.value;
  evaluate.request = request;
  return evaluate;
}

async function capture(target, name, width, height) {
  if (!evidence) return;
  await mkdir(evidence, {recursive: true});
  await target.request("Emulation.setDeviceMetricsOverride", {width, height, deviceScaleFactor: 1.5, mobile: false});
  assert.equal(await target("window.devicePixelRatio"), 1.5);
  const image = await target.request("Page.captureScreenshot", {format: "png"});
  await writeFile(join(evidence, `${name}.png`), Buffer.from(image.data, "base64"));
}

try {
  const main = await connect("/");
  await until(() => main('Boolean(document.querySelector(".welcome") && window.pywebview?.api?.show_settings)'), "workspace and native bridge");
  await main('showSettings()');
  const settings = await connect("/settings");
  await until(() => settings('Boolean(document.querySelector("#appearance"))'), "settings controls");
  await settings(`(() => { const select = document.querySelector("#appearance"); select.value="dark"; select.dispatchEvent(new Event("change")); })()`);
  await until(() => main('document.documentElement.dataset.theme === "dark"'), "theme propagated to main window");
  await capture(settings, "native-settings-dark-150dpi", 595, 545);

  await main('navigate("notes")');
  await main('document.querySelector("#note-new").click()');
  await until(() => main('Boolean(document.querySelector("#note-title"))'), "note editor");
  await main(`(() => { const field=document.querySelector("#note-title"); field.value="桌面便笺验证"; field.dispatchEvent(new Event("input")); document.querySelector("#note-desktop").click(); })()`);
  const note = await connect("/note?");
  await until(() => note('Boolean(document.querySelector(".desktop-note-title") && window.pywebview?.api?.close_note)'), "native note and bridge");
  assert.equal(await note('document.querySelector(".desktop-note-title b").textContent'), "桌面便笺验证");
  await note(`(() => { const body=document.querySelector("#note-body"); body.innerHTML="<b>正文与粗体</b>"; body.dispatchEvent(new Event("input")); document.querySelector('.note-options summary').click(); document.querySelector('[data-note-toggle="isPinned"]').click(); })()`);
  try {
    await until(() => note('document.querySelector(\'[data-note-toggle="isPinned"]\')?.getAttribute("aria-pressed") === "true"'), "note pinned");
  } catch (error) {
    console.error(await note('JSON.stringify({note:state.notes.notes[0], draft:noteDraft, message,status:document.querySelector("#note-status")?.textContent})'));
    const page = await (await fetch(appUrl, {signal: AbortSignal.timeout(2000)})).text();
    const currentToken = /name="gao-token" content="([^"]+)"/.exec(page)[1];
    const state = await (await fetch(`${appUrl}/api/state`, {headers: {"X-Gao-Token": currentToken}, signal: AbortSignal.timeout(2000)})).json();
    console.error("backend test note:", state.notes.notes[0]);
    console.error(await note('Promise.race([flushNoteEdit(),new Promise(resolve => setTimeout(() => resolve("not resolved"),2000))])'));
    throw error;
  }
  await capture(note, "native-note-dark-150dpi", 360, 300);
  await note('document.querySelector("#desktop-collapse").click()');
  await until(() => note('document.querySelector("#desktop-collapse")?.getAttribute("aria-label") === "展开"'), "note collapsed");
  await note('document.querySelector("#desktop-close").click()');
  await until(async () => {
    const archive = JSON.parse(await readFile(join(dataPath, "StickyNotes", "notes.json"), "utf8"));
    const [record] = archive.payload.notes;
    return record.isOnDesktop === false && record.isPinned && record.isCollapsed && record.plainText === "正文与粗体";
  }, "sticky note state on disk");

  await main(`(async () => { await api("/api/tabs/new", {kind:"markdown",text:${JSON.stringify("# 中文排版\n\n隔离打印验证")}}); view="editor"; render(); })()`);
  try {
    await until(() => main('document.querySelector("#markdown-frame")?.dataset.ready === "true"'), "Markdown editor ready");
  } catch (error) {
    console.error(await main('JSON.stringify({view, message, tab:selected()?.kind, frame:document.querySelector("#markdown-frame")?.dataset.ready, status:document.querySelector("#status")?.textContent})'));
    const markdown = await connect("/markdown-editor.html?", "iframe");
    console.error(await markdown('JSON.stringify({title:document.title, body:document.body?.innerText.slice(0,180), renderer:typeof window.gaoMarkdown, bridge:typeof sendMarkdownEvent})'));
    throw error;
  }
  await main(`(() => { writingSession(selected().id).export={format:"pdf", path:${JSON.stringify(join(root, "中文.pdf"))}};
    markdownCommand("requestExport", "pdf"); })()`);
  await until(async () => (await readFile(join(root, "中文.pdf"))).subarray(0, 4).toString() === "%PDF", "styled Markdown PDF", 45000);
  const latex = join(root, "离屏阅读.tex");
  await writeFile(latex, String.raw`\documentclass{article}
\begin{document}
\section{Reader smoke}
$x^2 + y^2 = r^2$
\newpage
Second page
\end{document}
`);
  const opened = await main(`(async () => {
    const tab = (await api('/api/tabs/open', {path:${JSON.stringify(latex)}})).result;
    return tab.id;
  })()`);
  const compiled = await main(`(async () => (await api('/api/tabs/compile', {id:${JSON.stringify(opened)}})).result.success)()`);
  assert.equal(compiled, true);
  await main(`window.pywebview.api.show_latex_pdf(${JSON.stringify(opened)})`);
  const reader = await connect("/latex-reader.html?");
  await until(() => reader("document.querySelector('#reader-canvas img')?.naturalWidth > 0"), "independent PDF reader");
  assert.equal(await reader("document.querySelector('#reader-total').textContent.trim()"), "/ 2");
  await capture(reader, "native-latex-reader-150dpi", 800, 650);
  if (await main("Boolean(window.pywebview.api.capture_project_readers)")) {
    await reader("document.querySelector('#reader-next').click()");
    await until(() => reader("document.querySelector('#reader-page-number').value === '2'"), "native LaTeX reader page two");
    assert.equal(await main(`(async () => (await window.pywebview.api.capture_project_readers())[${JSON.stringify(opened)}])()`), 1);
    await main("document.querySelector('#workspace-nav [data-go=projects]').click()");
    await until(() => main("Boolean(document.querySelector('[data-project-new]'))"), "native projects entry");
    await main("document.querySelector('[data-project-new]').click()");
    const fields = {name: "原生读窗项目", folder: root, main: latex};
    await main(`(() => {
      for (const [field,value] of Object.entries(${JSON.stringify(fields)})) document.querySelector('#project-' + field).value = value;
      document.querySelector('.project-dialog button[type=submit]').click();
    })()`);
    await until(() => main("activeProject()?.documents.some(item => item.reading?.readerPage === 1)"), "native reading position saved in project");
    await capture(main, "native-writing-project-dark-150dpi", 800, 650);
    console.log("native project OK: captured independent LaTeX reader page and saved through the project form");
  }
  await main('setTimeout(() => window.pywebview.api.close_workspace(true),100); true');
  const exit = await Promise.race([new Promise((done) => child.once("exit", done)), delay(15000, "timeout", {ref: false})]);
  assert.equal(exit, 0, logs);
  console.log("native desktop OK: settings, separate sticky note, Markdown PDF export, independent LaTeX reader, clean exit");
} finally {
  for (const socket of clients) socket.close();
  if (child.exitCode === null) {
    child.kill();
    await delay(400);
  }
  child.stderr.destroy();
  await rm(root, {recursive: true, force: true, maxRetries: 8, retryDelay: 250});
}
