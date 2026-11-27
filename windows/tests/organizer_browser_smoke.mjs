// Node 22+ built-in fetch/WebSocket, local Edge launched with isolated profile and no visible window.
import { spawn } from "node:child_process";
import {createHash, randomBytes, randomUUID} from "node:crypto";
import { once } from "node:events";
import { mkdtemp, mkdir, readFile, rename, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import assert from "node:assert/strict";

const client = process.argv[2];
if (!client) throw Error("Pass the absolute path to the client CLI executable or test Python.");
const screenshotDir = process.argv[3];
const root = await mkdtemp(join(tmpdir(), "GaoWenJian-browser-"));
const appData = join(root, "data");
const edgeProfile = join(root, "edge");
const fixtures = join(root, "fixtures");
const localAppData = join(root, "LocalAppData");
const sourceLauncher = join(dirname(fileURLToPath(import.meta.url)), "..", "launch.py");
const command = /python(?:w)?\.exe$/i.test(client) ? [resolve(sourceLauncher)] : [];
let server, browser, socket, url, token;

async function wait(predicate, timeout = 12_000, stage = "workbench") {
  const deadline = Date.now() + timeout;
  while (Date.now() < deadline) {
    const result = await predicate();
    if (result) return result;
    await new Promise((resolve) => setTimeout(resolve, 120));
  }
  throw Error("Timed out waiting for " + stage + ".");
}

function openChild(binary, args, stdio = ["ignore", "pipe", "pipe"], env = process.env) {
  return spawn(binary, args, {windowsHide: true, stdio, env});
}

const pending = new Map();
let serial = 0;
function cdp(method, params = {}) {
  return new Promise((resolve, reject) => {
    const id = ++serial;
    const timeout = setTimeout(() => { pending.delete(id); reject(Error("Timed out: " + method)); }, 10_000);
    pending.set(id, {resolve, reject, timeout});
    socket.send(JSON.stringify({id, method, params}));
  });
}

async function evalPage(expression) {
  const result = await cdp("Runtime.evaluate", {expression, returnByValue: true, awaitPromise: true});
  if (result.exceptionDetails) throw Error(result.exceptionDetails.exception?.description || result.exceptionDetails.text);
  return result.result.value;
}

async function api(path, payload) {
  const response = await fetch(url + "api/" + path, {
    method: "POST", headers: {"Content-Type": "application/json", "X-Gao-Token": token}, body: JSON.stringify(payload),
  });
  const received = await response.json();
  if (!response.ok) throw Error(received.error || path);
  return received.result;
}

async function screenshot(name) {
  if (!screenshotDir) return;
  const image = await cdp("Page.captureScreenshot", {format: "png"});
  await writeFile(join(screenshotDir, name + ".png"), Buffer.from(image.data, "base64"));
}

async function publishFixture(request) {
  const slot = join(localAppData, "GaoSeries", "GaoAction", "OcrReturns-v1", request.requestID);
  const ticket = JSON.parse(await readFile(join(slot, "request.json"), "utf8"));
  const original = JSON.parse(await readFile(join(request.path, "manifest.json"), "utf8"));
  const [input] = original.items;
  const source = {sourceItemID: input.id, sourceSHA256: input.sha256, sourceID: randomUUID()};
  const resultItemID = randomUUID();
  const text = Buffer.from("隔离 OCR 识别结果\n");
  const date = (offset) => new Date(Date.now() + offset).toISOString().replace(/\.\d+Z$/, "Z");
  const staging = join(slot, ".smoke-result-staging");
  await mkdir(join(staging, "payload"), {recursive: true});
  await writeFile(join(staging, "payload", "识别结果.txt"), text);
  await writeFile(join(staging, "manifest.json"), JSON.stringify({
    schemaVersion: 1, kind: "result", requestID: randomUUID(), sourceBundleID: "com.gaoseries.GaoCaoZuo",
    targetBundleID: "com.gaoseries.GaoWenJian", action: "ocr.files", createdAt: date(0), expiresAt: date(90_000),
    nonce: randomBytes(32).toString("base64"), inReplyTo: original.requestID, status: "completed",
    parameters: original.parameters, references: [], items: [{id: resultItemID, relativePath: "识别结果.txt",
      uti: "public.utf8-plain-text", byteCount: text.length, sha256: createHash("sha256").update(text).digest("hex")}],
    provenance: {engine: "Windows.Media.Ocr", networkUsed: false, requestManifestSHA256: ticket.requestManifestSHA256,
      sources: [{...source, outputItemIDs: [resultItemID], pages: [{pageNumber: 1, status: "completed", lineCount: 1, elapsedSeconds: 0.1}]}],
      outputs: [{...source, resultItemID, format: "text"}], exportFailures: []},
  }));
  await rename(staging, join(slot, "result.gaoaction"));
}

try {
  await mkdir(fixtures);
  await mkdir(localAppData);
  await writeFile(join(fixtures, "复核-中文.md"), "# isolated document\n");
  if (screenshotDir) await mkdir(screenshotDir, {recursive: true});
  server = openChild(client, [...command, "--no-browser", "--data-dir", appData], undefined,
    {...process.env, LOCALAPPDATA: localAppData});
  let output = "";
  server.stdout.on("data", (chunk) => output += chunk);
  server.stderr.on("data", (chunk) => process.stderr.write(chunk));
  url = await wait(() => output.match(/http:\/\/127\.0\.0\.1:\d+\//)?.[0], 25_000);
  const response = await fetch(url);
  token = (await response.text()).match(/name="gao-token" content="([^"]+)"/)[1];
  const draft = await api("tabs/new", {kind: "text", text: "隔离草稿"});
  await api("organizer/initialize", {});
  const auth = await api("organizer/authorize", {confirm: true, path: fixtures});
  await api("organizer/scan", {id: auth.id});

  const edge = join(process.env["ProgramFiles(x86)"], "Microsoft", "Edge", "Application", "msedge.exe");
  browser = openChild(edge, ["--headless=new", "--disable-gpu", "--no-first-run", "--no-default-browser-check",
                             "--remote-debugging-port=0", "--user-data-dir=" + edgeProfile, "about:blank"], "ignore");
  const devtoolsPort = await wait(async () => {
    try { return (await readFile(join(edgeProfile, "DevToolsActivePort"), "utf8")).split("\n")[0]; }
    catch { return null; }
  }, 30_000);
  const pages = await (await fetch("http://127.0.0.1:" + devtoolsPort + "/json/list")).json();
  socket = new WebSocket(pages.find((page) => page.type === "page").webSocketDebuggerUrl);
  await new Promise((resolve, reject) => {
    const timeout = setTimeout(() => reject(Error("Timed out connecting to headless Edge.")), 10_000);
    socket.addEventListener("open", () => { clearTimeout(timeout); resolve(); }, {once: true});
    socket.addEventListener("error", (event) => { clearTimeout(timeout); reject(event.error || Error("Edge connection error.")); }, {once: true});
  });
  socket.addEventListener("message", (event) => {
    const reply = JSON.parse(event.data);
    if (!pending.has(reply.id)) return;
    const callbacks = pending.get(reply.id);
    pending.delete(reply.id);
    clearTimeout(callbacks.timeout);
    if (reply.error) callbacks.reject(Error(reply.error.message));
    else callbacks.resolve(reply.result);
  });
  await cdp("Page.enable");

  for (const [theme, width, height, scale] of [["light", 1180, 760, 1], ["dark", 900, 680, 1.5]]) {
    await api("settings", {appearance: theme});
    await cdp("Emulation.setDeviceMetricsOverride", {width, height, deviceScaleFactor: scale, mobile: false});
    await cdp("Page.navigate", {url});
    await wait(() => evalPage("document.documentElement.dataset.theme === " + JSON.stringify(theme)
      + " && !!document.querySelector('[data-card=ocr]')"), 12_000, theme + " home");
    assert.equal(await evalPage("window.devicePixelRatio"), scale);
    await evalPage("document.querySelector('[data-go=files]').click()");
    await wait(() => evalPage("!!document.querySelector('[data-organizer-open]')"), 12_000, theme + " Organizer result");
    assert.ok(await evalPage("document.querySelector('.main-panel').innerText.includes('复核-中文.md')"));
    await screenshot("organizer-" + theme);
    await evalPage("document.querySelector('[data-go=handoff]').click()");
    await wait(() => evalPage("!!document.querySelector('#ocr-send')"), 12_000, theme + " OCR page");
    assert.ok(await evalPage("document.querySelector('.main-panel').innerText.includes('搞操作')"));
    assert.equal(await evalPage("document.querySelectorAll('[data-ocr-format]:checked').length"), 4);
    await screenshot("handoff-" + theme);
    assert.ok(await evalPage("document.documentElement.scrollWidth <= innerWidth"));
    await evalPage("document.querySelector('button[data-tab=" + JSON.stringify(draft.id) + "]').click()");
    await wait(() => evalPage("!!document.querySelector('textarea')"), 12_000, theme + " retained draft");
    assert.ok(await evalPage("document.querySelector('textarea').value.includes('隔离草稿')"));
  }
  const original = join(fixtures, "原件-扫描.png");
  const pngData = await evalPage(`(() => {
    const canvas = document.createElement('canvas');
    canvas.width = 540; canvas.height = 281;
    const draw = canvas.getContext('2d');
    draw.fillStyle = '#fff'; draw.fillRect(0, 0, 540, 281);
    draw.fillStyle = '#176755'; draw.fillRect(34, 32, 472, 6);
    draw.fillStyle = '#202925'; draw.font = '600 26px Microsoft YaHei UI'; draw.fillText('隔离扫描样本', 34, 86);
    draw.font = '18px Microsoft YaHei UI'; draw.fillText('编号 12345 · 校验页 1', 34, 137);
    draw.fillText('此文档用于核对 OCR 来源与页码。', 34, 175);
    return canvas.toDataURL().split(',')[1];
  })()`);
  const png = Buffer.from(pngData, "base64");
  await writeFile(original, png);
  await evalPage(`openPath(${JSON.stringify(original)})`);
  assert.equal(await evalPage("selected().kind"), "image");
  const request = await api("handoff/ocr", {confirm: true, paths: [original], outputs: ["text"]});
  assert.equal(request.returnEnabled, true);
  await evalPage("checkOcrReturns()");
  await wait(() => evalPage("ocrReturns.pending === true"), 10_000, "pending OCR return");
  await evalPage("setOcrReturnWindowVisible(false, 1)");
  await publishFixture(request);
  await new Promise((resolve) => setTimeout(resolve, 4300));
  assert.equal(await evalPage("ocrReturns.results.length"), 0, "hidden workspace stops OCR polling");
  await evalPage("setOcrReturnWindowVisible(true, 2)");
  await wait(() => evalPage("Boolean(document.querySelector('#ocr-document-return [data-ocr-review]'))"), 10_000, "source document return notice");
  assert.equal(await evalPage("state.tabs.length"), 2, "no tabs opened before acknowledgement");
  await screenshot("ocr-return-source-dark");
  await evalPage(`(async () => { await api('/api/settings', {appearance:'light'}); applyTheme(); })()`);
  await screenshot("ocr-return-source-light");
  await evalPage(`(async () => { await api('/api/settings', {appearance:'dark'}); applyTheme(); })()`);
  await evalPage("document.querySelector('#ocr-document-return [data-ocr-review]').click()");
  await wait(() => evalPage("Boolean(document.querySelector('#handoff-accept'))"), 10_000, "received OCR review");
  assert.ok(await evalPage("document.querySelector('.ocr-review-sources').textContent.includes('原件-扫描.png')"));
  assert.ok(await evalPage("document.querySelector('.ocr-review-sources').textContent.includes('第 1 页')"));
  await evalPage("document.querySelector('.ocr-review-sources details').open = true");
  await cdp("Emulation.setDeviceMetricsOverride", {width: 738, height: 650, deviceScaleFactor: 1.5, mobile: false});
  assert.ok(await evalPage("document.documentElement.scrollWidth <= innerWidth"));
  await screenshot("ocr-return-review-dark-narrow");
  await evalPage("document.querySelector('#handoff-cancel').click()");
  assert.equal(await evalPage("state.tabs.length"), 2);
  await evalPage("document.querySelector('#ocr-return-inbox [data-ocr-review]').click()");
  await wait(() => evalPage("Boolean(document.querySelector('#handoff-accept'))"), 10_000, "reopen review by ID");
  await evalPage("document.querySelector('#handoff-accept').click()");
  await wait(() => evalPage("selected()?.incoming?.inReplyTo === " + JSON.stringify(request.requestID)), 10_000, "explicit OCR approval");
  assert.equal(await evalPage("state.tabs.length"), 3);
  assert.equal(await evalPage("selected().incoming.sourceName"), "原件-扫描.png");
  assert.deepEqual(await readFile(original), png);
  await wait(() => evalPage("ocrReturns.results.length === 0"), 10_000, "accepted result removed from queue");
  console.log("OK · Organizer and OCR handoff in isolated Edge, light/dark, 1180/900px, 100%/150% DPI, draft preserved.");
  console.log("OK · OCR stops while hidden, rechecks on show, shows source and page mapping, opens a copy only on explicit approval.");
} finally {
  if (socket?.readyState === WebSocket.OPEN) {
    socket.send(JSON.stringify({id: ++serial, method: "Browser.close"}));
  }
  socket?.close();
  if (server && server.exitCode === null && token) {
    try { await api("shutdown", {force: true}); } catch {}
  }
  await Promise.all([browser, server].filter(Boolean).map(async (process) => {
    if (process.exitCode !== null || process.signalCode !== null) return;
    const exited = once(process, "exit");
    process.kill();
    await Promise.race([exited, new Promise((resolve) => setTimeout(resolve, 5000).unref())]);
    process.stdout?.destroy();
    process.stderr?.destroy();
  }));
  await rm(root, {recursive: true, force: true, maxRetries: 8, retryDelay: 200});
}
