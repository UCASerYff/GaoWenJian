// Normal native GUI launch on an inactive desktop. Only the test shell, not Explorer, receives icon calls.
import assert from "node:assert/strict";
import {spawn} from "node:child_process";
import {once} from "node:events";
import {mkdir, mkdtemp, readFile, rm, writeFile} from "node:fs/promises";
import {createServer} from "node:net";
import {tmpdir} from "node:os";
import {basename, join, resolve} from "node:path";
import {createInterface} from "node:readline";
import {setTimeout as delay} from "node:timers/promises";
import {fileURLToPath} from "node:url";

assert.ok(process.argv[2], "Pass the normal GUI executable or x64 Python, followed by an optional driver Python and evidence directory.");
const executable = resolve(process.argv[2]);
const python = process.argv[3] || "python";
const evidence = process.argv[4] ? resolve(process.argv[4]) : null;
const source = /python(?:w)?\.exe$/i.test(basename(executable));
const launcher = source ? [fileURLToPath(new URL("../launch.py", import.meta.url))] : [];
const trayClass = "GaoWenJian.TrayWindow";
const sockets = [];

async function freePort() {
  const listener = createServer().listen(0, "127.0.0.1");
  await once(listener, "listening");
  const {port} = listener.address();
  await new Promise((done) => listener.close(done));
  return port;
}

const [appPort, debuggerPort] = await Promise.all([freePort(), freePort()]);
const appUrl = `http://127.0.0.1:${appPort}`;
const root = await mkdtemp(join(tmpdir(), "gao-wenjian-tray-"));
const profile = join(root, "profile");
const driver = spawn(python, [fileURLToPath(new URL("tray_win32_driver.py", import.meta.url)), executable], {
  stdio: ["pipe", "pipe", "inherit"], windowsHide: true,
  env: {...process.env, PYTHONUTF8: "1", WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS: `--remote-debugging-port=${debuggerPort} --disable-background-networking`},
});
const driverExit = once(driver, "exit");
const pending = new Map();
let driverReady = false;
let driverError;
let serial = 0;
const lines = createInterface({input: driver.stdout});
lines.on("line", (line) => {
  const reply = JSON.parse(line);
  if (reply.ready) driverReady = true;
  if (pending.has(reply.id)) pending.get(reply.id)(reply);
});
driver.on("error", (error) => { driverError = error; });
driver.stdin.on("error", (error) => { driverError ||= error; });

function operation(op, fields = {}) {
  return new Promise((done, fail) => {
    if (driverError || driver.exitCode !== null) return fail(driverError || Error(`Driver exited with ${driver.exitCode}`));
    const id = ++serial;
    const timeout = setTimeout(() => {
      pending.delete(id);
      fail(Error(`Win32 test driver timed out: ${op}`));
    }, 5000);
    pending.set(id, (reply) => {
      pending.delete(id);
      clearTimeout(timeout);
      if (reply.error) fail(Error(reply.error));
      else done(reply.result);
    });
    driver.stdin.write(JSON.stringify({id, op, ...fields}) + "\n");
  });
}

async function until(probe, label, timeout = 30000) {
  const end = Date.now() + timeout;
  let recent;
  do {
    try {
      const value = await probe();
      if (value) return value;
    } catch (error) {
      recent = error;
    }
    await delay(125);
  } while (Date.now() < end);
  throw Error(`Timed out: ${label}`, {cause: recent});
}

async function target(path) {
  const endpoint = await until(async () => {
    const response = await fetch(`http://127.0.0.1:${debuggerPort}/json/list`, {signal: AbortSignal.timeout(1000)});
    return (await response.json()).find((page) => page.type === "page" && page.url.startsWith(`${appUrl}${path}`));
  }, `WebView2 ${path}`);
  const socket = new WebSocket(endpoint.webSocketDebuggerUrl);
  sockets.push(socket);
  await Promise.race([once(socket, "open"), once(socket, "error").then(() => { throw Error("WebView2 CDP socket failed"); })]);
  let count = 0;
  function request(method, params = {}) {
    return new Promise((done, fail) => {
      const id = ++count;
      const timeout = setTimeout(() => {
        socket.removeEventListener("message", receive);
        fail(Error(`CDP timeout: ${method}`));
      }, 30000);
      function receive(event) {
        const reply = JSON.parse(event.data);
        if (reply.id !== id) return;
        clearTimeout(timeout);
        socket.removeEventListener("message", receive);
        const error = reply.error?.message || reply.result?.exceptionDetails?.exception?.description;
        if (error) fail(Error(error));
        else done(reply.result);
      }
      socket.addEventListener("message", receive);
      socket.send(JSON.stringify({id, method, params}));
    });
  }
  return {
    async evaluate(expression) {
      return (await request("Runtime.evaluate", {expression, returnByValue: true, awaitPromise: true})).result?.value;
    },
    async capture(name) {
      if (!evidence) return;
      const image = await request("Page.captureScreenshot", {format: "png"});
      await writeFile(join(evidence, `${name}.png`), Buffer.from(image.data, "base64"));
    },
  };
}

const workspace = (windows) => windows.find((window) => window.title.startsWith("搞文件 V"));
const trays = (windows) => windows.filter((window) => window.class === trayClass);
const start = (...args) => operation("start", {args: [...launcher, ...args]});
const status = (pid) => operation("status", {pid});
const post = (pid, hwnd, message, wparam = 0, lparam = 0) => operation("post", {pid, hwnd, message, wparam, lparam});
const shell = () => operation("shell");

async function api(path, sessionToken, data) {
  const response = await fetch(`${appUrl}/api/${path}`, {
    method: data === undefined ? "GET" : "POST",
    headers: {"X-Gao-Token": sessionToken, "Content-Type": "application/json"},
    body: data === undefined ? undefined : JSON.stringify(data),
    signal: AbortSignal.timeout(3000),
  });
  assert.equal(response.ok, true, `Local API ${path} returned ${response.status}`);
  return response.json();
}

try {
  await until(() => {
    if (driverError || driver.exitCode !== null) throw driverError || Error(`Driver exited with ${driver.exitCode}`);
    return driverReady;
  }, "isolated inactive desktop and test notification area", 7000);
  if (evidence) await mkdir(evidence, {recursive: true});
  const draft = join(root, "保存确认.txt");
  const forwardedPath = join(root, "转发打开.txt");
  await writeFile(draft, "磁盘原文", "utf8");
  await writeFile(forwardedPath, "第二次启动打开的文件", "utf8");

  const pid = await start("--data-dir", profile, "--port", String(appPort));
  const initial = await until(async () => {
    const observed = await status(pid);
    return workspace(observed.windows)?.visible && trays(observed.windows).length === 1 && observed.windows;
  }, "normal launch has a visible main window and one tray callback window");
  const mainWindow = workspace(initial);
  const [tray] = trays(initial);
  assert.equal(tray.visible, false);
  const registered = await until(async () => {
    const observed = await shell();
    return observed.icons === 1 && observed.events.some(({event, icon}) => event === 0 && icon === 1) && observed;
  }, "Shell_NotifyIcon NIM_ADD for one logical icon");
  const main = await target("/");
  await until(() => main.evaluate('Boolean(document.querySelector(".welcome") && window.pywebview?.api?.show_settings)'), "workspace ready");
  const token = await main.evaluate('document.querySelector("meta[name=gao-token]").content');

  await main.evaluate('showSettings()');
  const settings = await target("/settings");
  await until(() => settings.evaluate('Boolean(document.querySelector("#appearance"))'), "settings window ready");
  await settings.evaluate('(() => { const select=document.querySelector("#appearance"); select.value="dark"; select.dispatchEvent(new Event("change")); })()');
  await until(() => main.evaluate('document.documentElement.dataset.theme === "dark"'), "settings update reached workspace");
  const noteId = await main.evaluate('(async () => (await api("/api/notes/create", {title:"托盘隔离便笺"})).result.id)()');
  await main.evaluate(`(async () => { await api('/api/notes/metadata', {id:${JSON.stringify(noteId)}, changes:{isOnDesktop:true}}); await window.pywebview.api.show_note(${JSON.stringify(noteId)}); })()`);
  const note = await target("/note?");
  await until(() => note.evaluate('Boolean(document.querySelector("#note-body"))'), "desktop note ready");
  await note.evaluate('(() => {const body=document.querySelector("#note-body"); body.textContent="后台保存便笺"; body.dispatchEvent(new Event("input")); })()');
  const hasTex = Boolean((await api("state", token)).engines.tectonic);
  const hasReader = !source || hasTex;
  let readerWindow;
  if (hasReader) {
    const tex = join(root, "后台读窗.tex");
    await writeFile(tex, String.raw`\documentclass{article}
\begin{document}
Tray reader smoke test.
\end{document}
`, "utf8");
    const id = (await api("tabs/open", token, {path: tex})).result.id;
    assert.equal((await main.evaluate(`(async () => (await api('/api/tabs/compile', {id:${JSON.stringify(id)}})).result.success)()`)), true);
    await main.evaluate(`window.pywebview.api.show_latex_pdf(${JSON.stringify(id)})`);
    const reader = await target("/latex-reader.html?");
    await until(() => reader.evaluate("document.querySelector('#reader-canvas img')?.naturalWidth > 0"), "native PDF reader ready");
    readerWindow = (await status(pid)).windows.find((window) => window.title === "后台读窗.pdf");
    assert.ok(readerWindow?.visible);
  }

  await main.evaluate(`openPath(${JSON.stringify(draft)})`);
  await until(() => main.evaluate('document.querySelector("textarea.editor")?.value === "磁盘原文"'), "fixture opened in editor");
  await main.evaluate('(() => {const editor=document.querySelector("textarea.editor"); editor.value="通过托盘确认保存"; editor.dispatchEvent(new Event("input")); })()');
  await post(pid, mainWindow.hwnd, 0x10);
  await until(async () => (await status(pid)).windows.some((window) => window.hwnd === mainWindow.hwnd && !window.visible), "native X hid the main window");
  assert.equal(await main.evaluate('Boolean(document.querySelector("dialog[open]"))'), false);
  assert.equal((await shell()).icons, 1);
  await until(async () => (await api("state", token)).tabs.some((tab) => tab.dirty && tab.text === "通过托盘确认保存"), "editing flushed while backgrounded");
  await until(async () => (await api("state", token)).notes.notes.some((item) => item.id === noteId && item.plainText === "后台保存便笺"), "desktop note continued saving in background");

  await post(pid, tray.hwnd, 0x8001, 0, (1 << 16) | 0x400);
  await until(async () => workspace((await status(pid)).windows)?.visible, "notification-area selection restored the same window");
  assert.equal(await main.evaluate('document.querySelector("textarea.editor").value'), "通过托盘确认保存");
  if (hasReader) assert.equal((await status(pid)).windows.some((window) => window.hwnd === readerWindow.hwnd), true);
  await post(pid, mainWindow.hwnd, 0x10);
  await until(async () => !workspace((await status(pid)).windows)?.visible, "main window hidden for duplicate launch");
  const forwarded = await start("--data-dir", profile, "--open", forwardedPath);
  await until(async () => (await status(forwarded)).exit === 0, "short-lived launch forwarded to the existing process");
  await until(async () => workspace((await status(pid)).windows)?.visible, "forwarded launch restored the existing process");
  await until(async () => (await api("state", token)).tabs.some((tab) => tab.path === forwardedPath), "forwarded launch opened the requested document");
  assert.equal(trays((await status(pid)).windows).length, 1);
  assert.deepEqual((await shell()).events, registered.events, "duplicate startup must not send another icon registration");

  await operation("restart-shell", {pid, hwnd: tray.hwnd});
  await until(async () => {
    const observed = await shell();
    return observed.icons === 1 && observed.events.filter(({event}) => event === 0).length === 2;
  }, "TaskbarCreated registered the icon with the replacement notification area");
  await post(pid, mainWindow.hwnd, 0x10);
  await until(async () => !workspace((await status(pid)).windows)?.visible, "main window returned to tray before quit");
  await post(pid, tray.hwnd, 0x111, 1);
  await until(async () => workspace((await status(pid)).windows)?.visible, "tray Open menu restored the workspace");
  await post(pid, mainWindow.hwnd, 0x10);
  await until(async () => !workspace((await status(pid)).windows)?.visible, "main window hidden before Exit menu");
  await post(pid, tray.hwnd, 0x111, 2);
  await until(() => main.evaluate('Boolean(document.querySelector("dialog[open] button[value=cancel]"))'), "tray Exit opened the existing save confirmation");
  await main.capture("tray-exit-save-confirmation");
  await main.evaluate('document.querySelector("dialog[open] button[value=cancel]").click()');
  await until(() => main.evaluate('!document.querySelector("dialog[open]")'), "cancel left the app running");
  await until(async () => !workspace((await status(pid)).windows)?.visible, "canceled background quit returned the workspace to the tray");
  assert.equal((await status(pid)).exit, null);
  assert.equal((await shell()).icons, 1);
  assert.equal(await readFile(draft, "utf8"), "磁盘原文");
  assert.ok((await api("state", token)).tabs.some((tab) => tab.dirty && tab.text === "通过托盘确认保存"));

  await post(pid, tray.hwnd, 0x111, 2);
  await until(() => main.evaluate('Boolean(document.querySelector("dialog[open] button[value=save]"))'), "second tray Exit still prompted to save");
  await main.evaluate('document.querySelector("dialog[open] button[value=save]").click()');
  await until(async () => (await status(pid)).exit === 0, "tray Exit closed all windows and the application process");
  const removed = await until(async () => {
    const observed = await shell();
    return observed.icons === 0 && observed.events.some(({event, icon}) => event === 2 && icon === 1) && observed;
  }, "Shell_NotifyIcon NIM_DELETE removed the logical icon");
  await assert.rejects(fetch(appUrl, {signal: AbortSignal.timeout(2500)}), "workspace port closed after process exit");
  assert.equal(await readFile(draft, "utf8"), "通过托盘确认保存");
  const archived = JSON.parse(await readFile(join(profile, "StickyNotes", "notes.json"), "utf8"));
  assert.ok(archived.payload.notes.some((item) => item.id === noteId && item.isOnDesktop && item.plainText === "后台保存便笺"));
  assert.equal(JSON.parse(await readFile(join(profile, "settings.json"), "utf8")).appearance, "dark");

  const versionPid = await start("--version");
  await until(async () => (await status(versionPid)).exit === 0, "version command returned without a desktop process");
  assert.deepEqual(await shell(), removed, "short-lived version command did not touch the notification area");

  const reopened = await start("--data-dir", profile, "--port", String(appPort));
  await until(async () => workspace((await status(reopened)).windows)?.visible && (await shell()).icons === 1, "normal launch worked again after full exit");
  const reopenedMain = await target("/");
  await until(() => reopenedMain.evaluate('Boolean(document.querySelector("#exit-app") && window.pywebview?.api?.close_workspace)'), "workspace after full relaunch");
  const reopenedNote = await target("/note?");
  await until(() => reopenedNote.evaluate('document.querySelector("#note-body")?.textContent === "后台保存便笺"'), "desktop note restored on relaunch");
  assert.equal(await reopenedMain.evaluate('document.documentElement.dataset.theme'), "dark");
  await reopenedMain.evaluate('(() => {const exit=document.querySelector("#exit-app"); exit.closest("details").open=true; exit.click(); })()');
  await until(async () => (await status(reopened)).exit === 0 && (await shell()).icons === 0, "workspace Exit menu shared full shutdown");
  const finished = await shell();

  const service = await start("--no-browser", "--data-dir", join(root, "api-only"), "--port", String(appPort));
  const serviceToken = await until(async () => {
    const page = await fetch(appUrl, {signal: AbortSignal.timeout(1000)});
    return /name="gao-token" content="([^"]+)"/.exec(await page.text())?.[1];
  }, "CLI service started without a native workspace");
  assert.equal(trays((await status(service)).windows).length, 0);
  await api("shutdown", serviceToken, {});
  await until(async () => (await status(service)).exit === 0, "CLI service returned after shutdown");

  const hidden = await start("--hidden", "--data-dir", join(root, "hidden-only"), "--port", String(appPort));
  const hiddenMain = await target("/");
  await until(() => hiddenMain.evaluate('Boolean(document.querySelector(".welcome") && window.pywebview?.api?.close_workspace)'), "hidden native test created a workspace");
  const hiddenWindows = (await status(hidden)).windows;
  assert.equal(workspace(hiddenWindows)?.visible, false);
  assert.equal(trays(hiddenWindows).length, 0);
  await hiddenMain.evaluate('setTimeout(() => workspaceExit().catch(fail),100); true');
  await until(async () => (await status(hidden)).exit === 0, "hidden native test shut down completely");
  assert.deepEqual(await shell(), finished, "CLI and hidden test startup did not touch the notification area");
  if (evidence) await writeFile(join(evidence, "tray-shell-events.json"), `${JSON.stringify(finished, null, 2)}\n`);
  console.log("tray smoke OK: actual Shell_NotifyIcon ADD/re-add/DELETE received by the isolated test notification area, same-window restoration, single instance, cancel, save and complete exit; Explorer rendering was outside this desktop");
} finally {
  for (const socket of sockets) socket.close();
  lines.close();
  if (driver.exitCode === null && !driverError) driver.stdin.end('{"op":"stop"}\n');
  await Promise.race([driverExit.catch(() => {}), delay(10000, null, {ref: false}).then(() => driver.kill())]);
  await rm(root, {recursive: true, force: true, maxRetries: 10, retryDelay: 250});
}
