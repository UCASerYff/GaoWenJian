// Normal native GUI launch on an inactive desktop. Only the test shell, not Explorer, receives icon calls.
import assert from "node:assert/strict";
import {spawn} from "node:child_process";
import {createHash, randomBytes, randomUUID} from "node:crypto";
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
  env: {...process.env, HOMEPATH: root, PYTHONUTF8: "1", WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS: `--remote-debugging-port=${debuggerPort} --disable-background-networking`},
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
const iconSamples = {};

async function checkWindowIcons(pid, window, name, dpis = []) {
  const observed = await until(async () => {
    const icons = await operation("window-icons", {pid, hwnd: window.hwnd, dpis});
    return icons.native.icons.small && icons.native.icons.large && icons;
  }, `WM_GETICON returned native small and large handles for ${name}`);
  assert.deepEqual(observed.native.icons, observed.native.expected, `${name} default icons at native ${observed.native.dpi} DPI`);
  for (const sample of observed.samples) {
    assert.deepEqual(sample.icons, sample.expected, `${name} requested icons at ${sample.dpi} DPI`);
  }
  iconSamples[name] = observed;
}

function shellIcon(observation, event) {
  return observation.events.findLast((entry) => entry.event === event && entry.icon === 1);
}

async function manualReviewFixture() {
  const folder = join(root, "启动待审核.gaoaction");
  const blob = Buffer.from("待用户确认的启动交接\n");
  const timestamp = (offset) => new Date(Date.now() + offset).toISOString().replace(/\.\d+Z$/, "Z");
  await mkdir(join(folder, "payload"), {recursive: true});
  await writeFile(join(folder, "payload", "启动待审核.txt"), blob);
  await writeFile(join(folder, "manifest.json"), JSON.stringify({schemaVersion: 1, kind: "request", requestID: randomUUID(),
    sourceBundleID: "com.gaoseries.GaoYanJiu", targetBundleID: "com.gaoseries.GaoWenJian", action: "documents.newText",
    createdAt: timestamp(0), expiresAt: timestamp(90_000), nonce: randomBytes(32).toString("base64"), references: [],
    parameters: {suggestedTitle: "启动待审核.txt"}, items: [{id: randomUUID(), relativePath: "启动待审核.txt",
      uti: "public.utf8-plain-text", byteCount: blob.length, sha256: createHash("sha256").update(blob).digest("hex")}] }));
  return folder;
}

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
  const marketingVersion = process.env.GAOWENJIAN_EXPECT_MARKETING_VERSION;
  if (marketingVersion) {
    assert.equal(mainWindow.title, `搞文件 V${marketingVersion}`);
    console.log(`native window title OK: ${mainWindow.title}`);
  }
  const [tray] = trays(initial);
  assert.equal(tray.visible, false);
  const registered = await until(async () => {
    const observed = await shell();
    return observed.icons === 1 && shellIcon(observed, 0) && shellIcon(observed, 4) && observed;
  }, "Shell_NotifyIcon NIM_ADD for one logical icon");
  const main = await target("/");
  await until(() => main.evaluate('Boolean(document.querySelector(".welcome") && window.pywebview?.api?.show_settings)'), "workspace ready");
  if (!source) {
    assert.deepEqual(shellIcon(registered, 0).pixels, registered.expected, `initial notification icon at ${registered.dpi} DPI`);
    await checkWindowIcons(pid, mainWindow, "workspace", [96, 120, 144, 168, 192]);
    assert.deepEqual(iconSamples.workspace.samples.find(({dpi}) => dpi === 96).icons, {small: [16, 16], large: [32, 32]});
  }
  const token = await main.evaluate('document.querySelector("meta[name=gao-token]").content');
  assert.deepEqual(await api("handoff/ocr-returns", token), {pending: false, results: [], issues: []});
  await main.evaluate('navigate("handoff")');
  await until(() => main.evaluate('Boolean(document.querySelector("#ocr-choose") && window.pywebview?.api?.file_dialog)'),
    "OCR page and native file picker bridge");
  const priorSelection = [join(root, "保留的第一项.png"), join(root, "保留的第二项.pdf")];
  await main.evaluate("ocrPaths = " + JSON.stringify(priorSelection) + "; render(); true");
  const beforePicker = new Set((await status(pid)).windows.map(({hwnd}) => hwnd));
  await main.evaluate(`(() => {
    window.testOcrPickerSettled = false;
    document.querySelector("#ocr-choose").onclick().finally(() => { window.testOcrPickerSettled = true; });
    return true;
  })()`);
  const picker = await until(async () => (await status(pid)).windows.find((window) =>
    window.visible && window.class === "#32770" && !beforePicker.has(window.hwnd)), "owned native OCR file dialog", 10000);
  await post(pid, picker.hwnd, 0x0010);  // WM_CLOSE, on the disposable private desktop only.
  await until(async () => !(await status(pid)).windows.some(({hwnd}) => hwnd === picker.hwnd)
    && await main.evaluate("window.testOcrPickerSettled === true"), "native OCR picker returned after cancel", 10000);
  assert.deepEqual(await main.evaluate("ocrPaths"), priorSelection, "native cancel kept the existing multi-file selection");
  assert.equal(await main.evaluate('message'), "", "native cancel did not show an error");
  assert.equal(await main.evaluate(`performance.getEntriesByType("resource").some(({name}) =>
    ["/api/dialog", "/api/handoff/choose-inputs"].includes(new URL(name).pathname))`),
  false, "normal OCR picker did not use an HTTP dialog");
  console.log("native OCR picker OK: opened and canceled its owned dialog on the inactive desktop");
  await main.evaluate('document.querySelector("#workspace-nav [data-go=projects]").click()');
  await until(() => main.evaluate('Boolean(document.querySelector("#projects-heading"))'), "writing projects in the normal native launcher");
  await main.evaluate('navigate("home")');

  await main.evaluate('showSettings()');
  const settings = await target("/settings");
  await until(() => settings.evaluate('Boolean(document.querySelector("#appearance"))'), "settings window ready");
  if (!source) {
    const settingsWindow = await until(async () => (await status(pid)).windows.find(({title, visible}) => visible && title === "搞文件设置"), "native settings window");
    await checkWindowIcons(pid, settingsWindow, "settings");
  }
  await settings.evaluate('(() => { const select=document.querySelector("#appearance"); select.value="dark"; select.dispatchEvent(new Event("change")); })()');
  await until(() => main.evaluate('document.documentElement.dataset.theme === "dark"'), "settings update reached workspace");
  const noteId = await main.evaluate('(async () => (await api("/api/notes/create", {title:"托盘隔离便笺"})).result.id)()');
  await main.evaluate(`(async () => { await api('/api/notes/metadata', {id:${JSON.stringify(noteId)}, changes:{isOnDesktop:true}}); await window.pywebview.api.show_note(${JSON.stringify(noteId)}); })()`);
  const note = await target("/note?");
  await until(() => note.evaluate('Boolean(document.querySelector("#note-body"))'), "desktop note ready");
  if (!source) {
    const noteWindow = await until(async () => (await status(pid)).windows.find(({title, visible}) => visible && title === "托盘隔离便笺"), "native note window");
    await checkWindowIcons(pid, noteWindow, "note");
  }
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
    if (!source) await checkWindowIcons(pid, readerWindow, "reader");
  }

  await main.evaluate(`openPath(${JSON.stringify(draft)})`);
  await until(() => main.evaluate('document.querySelector("textarea.editor")?.value === "磁盘原文"'), "fixture opened in editor");
  await main.evaluate('(() => {const editor=document.querySelector("textarea.editor"); editor.value="通过托盘确认保存"; editor.dispatchEvent(new Event("input")); })()');
  await post(pid, mainWindow.hwnd, 0x10);
  await until(async () => (await status(pid)).windows.some((window) => window.hwnd === mainWindow.hwnd && !window.visible), "native X hid the main window");
  assert.deepEqual(await api("handoff/ocr-returns", token), {paused: true});
  assert.equal(await main.evaluate('Boolean(document.querySelector("dialog[open]"))'), false);
  assert.equal((await shell()).icons, 1);
  await until(async () => (await api("state", token)).tabs.some((tab) => tab.dirty && tab.text === "通过托盘确认保存"), "editing flushed while backgrounded");
  await until(async () => (await api("state", token)).notes.notes.some((item) => item.id === noteId && item.plainText === "后台保存便笺"), "desktop note continued saving in background");

  await post(pid, tray.hwnd, 0x8001, 0, (1 << 16) | 0x400);
  await until(async () => workspace((await status(pid)).windows)?.visible, "notification-area selection restored the same window");
  await until(async () => !(await api("handoff/ocr-returns", token)).paused, "OCR checks resumed on tray reopening");
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

  let dpiEvidence;
  if (!source) {
    const unchanged = await operation("tray-dpi-notification", {pid, hwnd: tray.hwnd});
    assert.equal(unchanged.beforeDpi, unchanged.afterDpi);
    assert.deepEqual((await shell()).events, registered.events, "unchanged shell DPI leaves the registered icon in place even if the message suggests a different DPI");
    const change = await operation("tray-dpi-notification", {pid, hwnd: tray.hwnd, change_shell: true});
    let modified = null;
    if (change.beforeDpi !== change.afterDpi) {
      modified = await until(async () => {
        const observed = await shell();
        return observed.icons === 1 && observed.events.slice(registered.events.length).find(({event}) => event === 1);
      }, "changed test shell DPI led to Shell_NotifyIcon NIM_MODIFY");
      assert.deepEqual(modified.pixels, change.expected, `modified notification icon at ${change.afterDpi} DPI`);
      assert.equal((await shell()).events.filter(({event}) => event === 0).length, 1, "DPI update kept the same logical notification icon");
    } else {
      assert.deepEqual((await shell()).events, registered.events, "the two test shell windows report the same DPI on this monitor");
    }
    dpiEvidence = {unchanged, changedFixture: change, modified};
  }

  await operation("restart-shell", {pid, hwnd: tray.hwnd});
  const replacement = await until(async () => {
    const observed = await shell();
    return observed.icons === 1 && observed.events.filter(({event}) => event === 0).length === 2
      && observed.events.filter(({event}) => event === 4).length === 2 && observed;
  }, "TaskbarCreated registered the icon with the replacement notification area");
  if (!source) assert.deepEqual(shellIcon(replacement, 0).pixels, replacement.expected, `re-registered notification icon at ${replacement.dpi} DPI`);
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

  const handoff = await manualReviewFixture();
  const reopened = await start("--data-dir", profile, "--port", String(appPort), "--open", handoff);
  await until(async () => workspace((await status(reopened)).windows)?.visible && (await shell()).icons === 1, "normal launch worked again after full exit");
  const reopenedMain = await target("/");
  await until(() => reopenedMain.evaluate('Boolean(document.querySelector("#exit-app") && window.pywebview?.api?.close_workspace)'), "workspace after full relaunch");
  await until(() => reopenedMain.evaluate('Boolean(document.querySelector("#handoff-accept"))'), "cold --open showed package review");
  assert.equal(await reopenedMain.evaluate("state.tabs.length"), 0, "cold --open never accepted a handoff before user action");
  await reopenedMain.evaluate('document.querySelector("#handoff-cancel").click()');
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
  if (evidence) {
    await writeFile(join(evidence, "tray-shell-events.json"), `${JSON.stringify(finished, null, 2)}\n`);
    if (dpiEvidence) await writeFile(join(evidence, "window-icon-samples.json"), `${JSON.stringify({windows: iconSamples,
      notificationArea: {initial: shellIcon(registered, 0), ...dpiEvidence, readded: shellIcon(replacement, 0)}}, null, 2)}\n`);
  }
  if (dpiEvidence) {
    const {modified, changedFixture} = dpiEvidence;
    const dpiChange = modified ? `MODIFY ${modified.pixels.join("×")} at ${changedFixture.afterDpi} DPI, ` : "same fixture DPI, ";
    console.log(`native icon sizes OK: window handles, Shell_NotifyIcon ADD ${shellIcon(registered, 0).pixels.join("×")}, ${dpiChange}TaskbarCreated re-ADD ${shellIcon(replacement, 0).pixels.join("×")}`);
  }
  console.log("tray smoke OK: Shell_NotifyIcon ADD/re-add/DELETE, workspace restoration, save, cancel and full exit in the private desktop");
} finally {
  for (const socket of sockets) socket.close();
  lines.close();
  if (driver.exitCode === null && !driverError) driver.stdin.end('{"op":"stop"}\n');
  await Promise.race([driverExit.catch(() => {}), delay(10000, null, {ref: false}).then(() => driver.kill())]);
  await rm(root, {recursive: true, force: true, maxRetries: 10, retryDelay: 250});
}
