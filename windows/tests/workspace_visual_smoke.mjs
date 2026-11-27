// Run against a frozen CLI or a Python.exe using a private profile and headless Edge.
import assert from "node:assert/strict";
import {spawn} from "node:child_process";
import {once} from "node:events";
import {mkdir, mkdtemp, readFile, rm, unlink, writeFile} from "node:fs/promises";
import {tmpdir} from "node:os";
import {basename, dirname, join, resolve} from "node:path";
import {setTimeout as delay} from "node:timers/promises";
import {fileURLToPath} from "node:url";

assert.ok(process.argv[2] && process.argv[3], "Pass the CLI or Python executable and an evidence directory.");
const cli = resolve(process.argv[2]);
const evidenceDir = resolve(process.argv[3]);
const baseline = process.argv.includes("--baseline");
const projects = process.argv.includes("--projects");
const project = dirname(dirname(fileURLToPath(import.meta.url)));
const command = /python(?:w)?\.exe$/i.test(basename(cli)) ? [join(project, "launch.py")] : [];
const root = await mkdtemp(join(tmpdir(), "gao-workspace-visual-"));
const fixtures = join(root, "写作样本");
const edgeProfile = join(root, "edge-profile");
let app, edge, socket, url, token;
let serial = 0;
const requests = new Map();

async function until(predicate, label) {
  const deadline = Date.now() + 30000;
  do {
    const value = await predicate();
    if (value) return value;
    await delay(100);
  } while (Date.now() < deadline);
  throw Error(`Timed out waiting for ${label}`);
}

function devtools(method, params = {}) {
  return new Promise((resolve, reject) => {
    const id = ++serial;
    const timer = setTimeout(() => { requests.delete(id); reject(Error(`Timed out: ${method}`)); }, 10000);
    requests.set(id, (reply) => {
      clearTimeout(timer);
      if (reply.error) reject(Error(reply.error.message));
      else resolve(reply.result);
    });
    socket.send(JSON.stringify({id, method, params}));
  });
}

async function page(expression) {
  const reply = await devtools("Runtime.evaluate", {expression, returnByValue: true, awaitPromise: true});
  if (reply.exceptionDetails) throw Error(reply.exceptionDetails.exception?.description || reply.exceptionDetails.text);
  return reply.result.value;
}

async function api(path, data) {
  const response = await fetch(url + "api/" + path, {
    method: "POST", headers: {"Content-Type": "application/json", "X-Gao-Token": token}, body: JSON.stringify(data),
  });
  const result = await response.json();
  assert.ok(response.ok && result.ok !== false, result.error || path);
  return result.result;
}

async function navigate(endpoint = "") {
  await devtools("Page.navigate", {url: url + endpoint});
  await until(() => page("Boolean(window.document.querySelector('.main-panel, .desktop-note, .settings-window'))"), endpoint || "workbench");
}

async function screenshot(name) {
  await page("document.fonts.ready.then(() => true)");
  assert.equal(await page("document.documentElement.scrollWidth <= innerWidth"), true, `${name} overflows the viewport`);
  const image = await devtools("Page.captureScreenshot", {format: "png"});
  await writeFile(join(evidenceDir, `${name}.png`), Buffer.from(image.data, "base64"));
}

function child(binary, args, stdio = ["ignore", "pipe", "pipe"]) {
  return spawn(binary, args, {windowsHide: true, stdio});
}

function samplePdf() {
  const objects = ["<</Type /Catalog /Pages 2 0 R>>", "<</Type /Pages /Count 3 /Kids [3 0 R 4 0 R 5 0 R]>>",
    ...[6, 7, 8].map((n) => `<</Type /Page /Parent 2 0 R /MediaBox [0 0 400 960] /Resources <</Font <</F1 9 0 R>>>> /Contents ${n} 0 R>>`),
    ...[1, 2, 3].map((page) => {
      const drawing = `0.12 0.36 0.28 rg 28 902 344 5 re f BT /F1 21 Tf 28 860 Td (Proof page ${page}) Tj ET\n`;
      return `<</Length ${drawing.length}>>\nstream\n${drawing}endstream`;
    }), "<</Type /Font /Subtype /Type1 /BaseFont /Helvetica>>"];
  let pdf = "%PDF-1.4\n";
  const offsets = objects.map((object, index) => {
    const offset = pdf.length;
    pdf += `${index + 1} 0 obj\n${object}\nendobj\n`;
    return offset;
  });
  const count = objects.length + 1;
  return pdf + `xref\n0 ${count}\n0000000000 65535 f \n${offsets.map((offset) => String(offset).padStart(10, "0") + " 00000 n \n").join("")}`
    + `trailer\n<</Root 1 0 R /Size ${count}>>\nstartxref\n${pdf.length}\n%%EOF\n`;
}

async function projectControls(mdPath, textPath) {
  const secondDirectory = join(root, "第二写作项目");
  const secondMain = join(secondDirectory, "课题草案.md");
  const proof = join(fixtures, "排版校样.pdf");
  const enterProjects = async () => {
    await page(`document.querySelector('#workspace-nav [data-go="projects"]').click()`);
    await until(() => page("!!document.querySelector('#projects-heading')"), "writing projects");
  };
  const create = async (name, folder, main) => {
    await page("document.querySelector('[data-project-new]').click()");
    await page(`(() => {
      const dialog = document.querySelector('.project-dialog[open]');
      for (const [field, value] of Object.entries(${JSON.stringify({name, folder, main})})) dialog.querySelector('#project-' + field).value = value;
      if (!dialog.querySelector('form').checkValidity()) throw new Error('Project configuration form is invalid');
      dialog.querySelector('button[type=submit]').click();
    })()`);
    return until(() => page(`(() => {
      const error = document.querySelector('.project-dialog[open] .project-form-error:not([hidden])');
      if (error) throw new Error(error.textContent);
      return activeProject()?.name === ${JSON.stringify(name)} && activeProject().id;
    })()`), `saved ${name}`);
  };
  const open = (id) => page(`document.querySelector('[data-project-open="${id}"]').click()`);
  const proofPageInView = (index) => page(`(() => {
    const canvas = document.querySelector('.pdf-canvas');
    if (!canvas) return false;
    const top = canvas.getBoundingClientRect().top + canvas.clientTop;
    const bottom = top + canvas.clientHeight;
    const pages = [...canvas.querySelectorAll('[data-pdf-sheet]')].map((sheet) => {
      const bounds = sheet.getBoundingClientRect();
      return {top: bounds.top, visible: Math.max(0, Math.min(bottom, bounds.bottom) - Math.max(top, bounds.top))};
    });
    const active = pages[${index}];
    return active && Math.abs(active.top - top) < 38 && active.visible >= canvas.clientHeight * .55 &&
      pages.every((candidate) => candidate === active || active.visible > candidate.visible);
  })()`);

  await mkdir(secondDirectory);
  await writeFile(secondMain, "# 另一个写作项目\n");
  await writeFile(proof, samplePdf());
  await api("settings", {appearance: "light"});
  await devtools("Emulation.setDeviceMetricsOverride", {width: 1250, height: 820, deviceScaleFactor: 1, mobile: false});
  await navigate();
  await page(`openPath(${JSON.stringify(proof)})`);
  await until(() => page(`(() => {
    if (errorNotice) throw new Error(errorNotice);
    const rasterError = document.querySelector('.pdf-image-error[data-pdf-sheet="0"] [data-pdf-retry]');
    if (rasterError) throw new Error(rasterError.closest('.pdf-sheet').innerText);
    return Boolean(document.querySelector('.pdf-image-ready'));
  })()`), "PDF project proof");
  await page(`document.querySelector('[data-pdf-command="next"]').click()`);
  await until(() => page(`document.querySelector('#pdf-page-number').value === '2'`), "PDF page two");
  await until(() => proofPageInView(1), "PDF page two occupies the reading viewport after Next");
  await enterProjects();
  const first = await create("稿件与校样", fixtures, mdPath);
  await screenshot("projects-light");

  await page(`(async () => {
    for (const tab of [...state.tabs]) await api('/api/tabs/close', {id: tab.id});
    await openPath(${JSON.stringify(secondMain)});
  })()`);
  await until(() => page(`view === 'editor' && selected()?.path === ${JSON.stringify(secondMain)}`), "second project's main document");
  await enterProjects();
  const second = await create("课题草案", secondDirectory, secondMain);
  const draft = await page(`(async () => {
    const result = (await api('/api/tabs/new', {kind:'text', text:'草稿须在项目切换后继续保留'})).result;
    return result.id;
  })()`);
  await unlink(textPath);
  await api("settings", {appearance: "dark"});
  await devtools("Emulation.setDeviceMetricsOverride", {width: 620, height: 620, deviceScaleFactor: 1.5, mobile: false});
  await navigate();
  await enterProjects();
  await open(first);
  await until(() => page("!!document.querySelector('#switch-project-heading')"), "project unsaved confirmation");
  await screenshot("projects-switch-dark-narrow");
  await page(`document.querySelector('.project-dialog button[value="cancel"]').click()`);
  await until(() => page(`!document.querySelector('#switch-project-heading') && activeProject()?.id === ${JSON.stringify(second)}`), "cancelled project switch");
  await open(first);
  await until(() => page("!!document.querySelector('#switch-project-heading')"), "project unsaved confirmation retry");
  await page(`document.querySelector('.project-dialog button[value="keep"]').click()`);
  await until(() => page(`document.querySelector('#pdf-page-number')?.value === '2' && activeProject().id === ${JSON.stringify(first)}`), "restored project PDF at page two");
  await until(() => page("Boolean(document.querySelector('.pdf-sheet.pdf-image-ready [data-pdf-raster=\"1\"]'))"), "restored PDF proof rendering");
  await until(() => proofPageInView(1), "restored PDF page two occupies the reading viewport");
  assert.equal(await page(`Boolean(state.tabs.find((tab) => tab.id === ${JSON.stringify(draft)} && tab.dirty))`), true);
  assert.equal(await page(`document.querySelector('.workspace-banner')?.textContent.includes('样本说明.txt')`), true);
  await screenshot("projects-restored-pdf-dark-narrow");
  await enterProjects();
  await screenshot("projects-missing-dark-narrow");

  const revision = join(fixtures, "待保存的修改.txt");
  await writeFile(revision, "未修改的合成样本");
  await page(`(async () => {
    await api('/api/tabs/close', {id:${JSON.stringify(draft)}, discard:true});
    await openPath(${JSON.stringify(revision)});
    const editor = document.querySelector('textarea.editor');
    editor.value = '切换前已明确保存';
    editor.dispatchEvent(new Event('input'));
  })()`);
  await enterProjects();
  await open(second);
  await until(() => page("!!document.querySelector('#switch-project-heading')"), "save documents before changing project");
  await page(`document.querySelector('.project-dialog button[value="save"]').click()`);
  await until(() => page(`activeProject()?.id === ${JSON.stringify(second)}`), "saved changes and opened second project");
  assert.equal(await readFile(revision, "utf8"), "切换前已明确保存");
}

try {
  await mkdir(fixtures);
  await mkdir(evidenceDir, {recursive: true});
  const mdPath = join(fixtures, "调研记录.md");
  const textPath = join(fixtures, "样本说明.txt");
  const csvPath = join(fixtures, "样本清单.csv");
  await writeFile(mdPath, "# 调研记录\n\n为下次讨论汇总证据。行内公式 $E=mc^2$。\n\n## 本周计划\n\n- [x] 核对笔记\n- [ ] 整理结果\n\n| 日期 | 状态 |\n| --- | --- |\n| 周一 | 已完成 |\n");
  await writeFile(textPath, "隔离样本\n备注：文件仅用于界面复核。\n");
  await writeFile(csvPath, "编号,状态\n001,已完成\n002,待复核\n");
  app = child(cli, [...command, "--no-browser", "--data-dir", join(root, "data")]);
  let logs = "";
  app.stdout.on("data", (chunk) => { logs += chunk; });
  app.stderr.on("data", (chunk) => process.stderr.write(chunk));
  url = await until(() => logs.match(/http:\/\/127\.0\.0\.1:\d+\//)?.[0], "local API");
  token = (await (await fetch(url)).text()).match(/name="gao-token" content="([^"]+)"/)[1];
  await api("tabs/open", {path: csvPath});
  await api("tabs/open", {path: textPath});
  const markdown = await api("tabs/open", {path: mdPath});
  const note = await api("notes/create", {title: "组会摘录"});
  await api("notes/update", {id: note.id, html: "整理两份样本的结果。<br><br><b>下次组会</b>前补齐图表。", plain: "整理两份样本的结果。\n\n下次组会前补齐图表。"});
  await api("notes/metadata", {id: note.id, changes: {group: "写作", isOnDesktop: true}});
  await api("notes/create", {title: "文献补读"});

  const path = join(process.env["ProgramFiles(x86)"], "Microsoft", "Edge", "Application", "msedge.exe");
  edge = child(path, ["--headless=new", "--disable-background-networking", "--no-first-run",
    "--no-default-browser-check", "--remote-debugging-port=0", `--user-data-dir=${edgeProfile}`, "about:blank"], "ignore");
  const port = await until(async () => {
    try { return (await readFile(join(edgeProfile, "DevToolsActivePort"), "utf8")).split("\n")[0]; }
    catch { return null; }
  }, "headless Edge");
  const targets = await (await fetch(`http://127.0.0.1:${port}/json/list`)).json();
  socket = new WebSocket(targets.find((target) => target.type === "page").webSocketDebuggerUrl);
  await Promise.race([once(socket, "open"), delay(10000).then(() => { throw Error("Edge CDP connection timed out"); })]);
  socket.addEventListener("message", ({data}) => {
    const reply = JSON.parse(data);
    const settle = requests.get(reply.id);
    requests.delete(reply.id);
    settle?.(reply);
  });
  await devtools("Page.enable");

  if (projects) {
    await projectControls(mdPath, textPath);
    console.log("project visuals OK: creation, dark narrow cancel/keep/save, restored PDF page, missing file and retained draft");
  } else {
  for (const [theme, width, height, scale] of [["light", 1250, 820, 1], ["dark", 790, 650, 1.5]]) {
    await api("settings", {appearance: theme});
    await devtools("Emulation.setDeviceMetricsOverride", {width, height, deviceScaleFactor: scale, mobile: false});
    await navigate();
    await until(() => page(`document.documentElement.dataset.theme === '${theme}' && !!document.querySelector('[data-card=markdown]')`), "home");
    assert.equal(await page("window.devicePixelRatio"), scale);
    await screenshot(`workbench-${theme}`);
    await page(`document.querySelector('button[data-tab=${JSON.stringify(markdown.id)}]').click()`);
    await until(() => page("document.querySelector('#markdown-frame')?.dataset.ready === 'true'"), "Markdown editor");
    if (!baseline) {
      assert.equal(await page(`(async () => { const editor = document.querySelector('#markdown-frame'); const draft = (await api('/api/tabs/new',{kind:'text',text:'隔离草稿'})).result; view = 'editor'; render(); const body = document.querySelector('textarea.editor'); body.value += '\\n续写'; body.dispatchEvent(new Event('input')); const toggle = document.getElementById('toggle-sidebar'); toggle.click(); toggle.click(); return body.isConnected && body.value.includes('续写') && Boolean(draft.id) && !editor.isConnected; })()`), true);
      await page(`document.querySelector('button[data-tab=${JSON.stringify(markdown.id)}]').click()`);
      await until(() => page("document.querySelector('#markdown-frame')?.dataset.ready === 'true'"), "Markdown editor after restoring draft tab");
    }
    await screenshot(`markdown-${theme}`);
    await page("navigate('notes')");
    await until(() => page("!!document.querySelector('[data-note]')"), "notes list");
    await page(`document.querySelector('[data-note=${JSON.stringify(note.id)}]').click()`);
    await until(() => page("document.querySelector('#note-title')?.value === '组会摘录'"), "selected note");
    await screenshot(`notes-${theme}`);
    await navigate("settings");
    await until(() => page("!!document.getElementById('appearance')"), "settings");
    await screenshot(`settings-${theme}`);
  }
  await devtools("Emulation.setDeviceMetricsOverride", {width: 360, height: 320, deviceScaleFactor: 1.5, mobile: false});
  await navigate(`note?id=${encodeURIComponent(note.id)}`);
  await screenshot("desktop-note-150dpi");
  console.log("workspace visuals OK: home, Markdown, notes, settings, desktop note at 100% and 150%");
  }
} finally {
  if (socket?.readyState === WebSocket.OPEN) {
    socket.send(JSON.stringify({id: ++serial, method: "Browser.close"}));
  }
  socket?.close();
  if (app && app.exitCode === null && token) {
    try { await api("shutdown", {force: true}); } catch {}
  }
  await Promise.all([edge, app].filter(Boolean).map(async (process) => {
    if (process.exitCode === null && process.signalCode === null) {
      const exited = once(process, "exit");
      process.kill();
      await Promise.race([exited, delay(4000)]);
    }
    process.stdout?.destroy();
    process.stderr?.destroy();
  }));
  await rm(root, {recursive: true, force: true, maxRetries: 8, retryDelay: 200});
}
