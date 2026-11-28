// Run with Node. These tests use the actual frontend and a deterministic clock, without a visible window.
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { createContext, runInContext } from "node:vm";

const source = (name) => readFileSync(new URL("../src/gaowenjian/assets/" + name, import.meta.url), "utf8");

function setup() {
  let now = Date.parse("2026-11-29T01:00:00Z");
  let timerID = 0;
  const timers = new Map();
  const nav = {
    ready: false,
    toggleAttribute(_, enabled) { this.ready = enabled; },
    setAttribute() {},
  };
  const inbox = {hidden: true};
  const documentReturn = {hidden: true};
  const choose = {};
  const reviewCard = {
    replacement: null,
    replaceWith(node) { this.replacement = node; },
  };
  const document = {
    hidden: false,
    querySelector: (selector) => selector === ".handoff-review" ? reviewCard : nav,
    createElement: () => ({setAttribute() {}}),
    querySelectorAll: () => [],
    addEventListener() {},
    getElementById: (id) => ({
      "ocr-return-inbox": inbox, "ocr-document-return": documentReturn, "ocr-choose": choose,
    })[id],
  };
  const active = {ocrSourcePath: "C:\\合成资料\\扫描文件.pdf", ocrSourceSHA256: "b".repeat(64)};
  const calls = [];
  const context = createContext({
    location: {pathname: "/"}, document, window: {}, token: "synthetic-token",
    state: {tabs: [], fixtures: ["unchanged"]}, view: "editor", message: "unchanged", selected: () => active,
    h: (value) => String(value ?? ""), render() {}, fail: (error) => { throw error; },
    api: async (path) => { throw new Error("Unexpected API " + path); },
    fetch: async (path) => {
      calls.push(path);
      return {ok: true, json: async () => context.response};
    },
    Date: class extends Date { static now() { return now; } },
    setTimeout: (callback, delay) => { timers.set(++timerID, {callback, at: now + delay}); return timerID; },
    clearTimeout: (id) => timers.delete(id),
  });
  const run = (script) => runInContext(script, context);
  run(source("shell.js"));
  run(source("handoff.js"));
  const step = (milliseconds) => {
    const end = now + milliseconds;
    for (let ticks = 0; ; ticks++) {
      assert.ok(ticks < 20, "OCR timers did not settle");
      const [id, next] = [...timers.entries()].sort((left, right) => left[1].at - right[1].at)[0] || [];
      if (!next || next.at > end) break;
      timers.delete(id);
      now = next.at;
      next.callback();
    }
    now = end;
  };
  const request = async () => {
    run("checkOcrReturns()");
    await run("ocrReturnRequest");
  };
  return {context, run, request, step, timers, calls, nav, inbox, documentReturn, choose, reviewCard, active};
}

{
  const {context, run, choose} = setup();
  const paths = ["C:\\合成资料\\一 张.png", "C:\\合成资料\\第二份.pdf"];
  let selected = paths;
  const nativeCalls = [];
  context.window.pywebview = {api: {file_dialog: async (mode, name) => {
    nativeCalls.push([mode, name]);
    return selected;
  }}};
  run('view = "handoff"; handoffState = {}; bindHandoff()');
  await choose.onclick();
  assert.deepEqual(nativeCalls, [["ocr-inputs", ""]]);
  assert.deepEqual(run("ocrPaths"), paths);
  selected = [];
  await choose.onclick();
  assert.deepEqual(run("ocrPaths"), paths, "native cancellation preserves the previous selection");

  context.window.pywebview = {api: {}};
  const fallbackPaths = ["C:\\合成资料\\回退图片.png", "C:\\合成资料\\回退 PDF.pdf"];
  let cancelled = false;
  let fallbackCalls = 0;
  context.api = async (path, payload) => {
    assert.equal(path, "/api/dialog");
    assert.equal(payload.mode, "ocr-inputs");
    fallbackCalls++;
    if (cancelled) throw Object.assign(new Error("cancelled"), {code: "cancelled"});
    return {result: {path: fallbackPaths}};
  };
  await choose.onclick();
  assert.deepEqual(run("ocrPaths"), fallbackPaths);
  cancelled = true;
  await choose.onclick();
  assert.deepEqual(run("ocrPaths"), fallbackPaths, "fallback cancellation preserves the whole selection");

  cancelled = false;
  context.window.pywebview.api.file_dialog = async () => { throw new Error("native picker unavailable"); };
  await choose.onclick();
  assert.equal(fallbackCalls, 3, "a rejected native OCR invocation opens the fallback once");
  assert.deepEqual(run("ocrPaths"), fallbackPaths);
  await assert.rejects(run('fileDialog("open")'), /native picker unavailable/);
  assert.equal(fallbackCalls, 3, "other picker modes retain their original native error");
  context.window.pywebview.api.file_dialog = async () => {
    throw Object.assign(new Error("cancelled"), {code: "cancelled"});
  };
  await choose.onclick();
  assert.equal(fallbackCalls, 3, "explicit native cancellation does not open the fallback");
  assert.deepEqual(run("ocrPaths"), fallbackPaths);
  context.window.pywebview = {api: {}};

  run('toolDialog = async () => ({})');
  const submitted = [];
  context.api = async (path, payload) => {
    if (path === "/api/dialog") return {result: {path: "C:\\合成资料\\发件"}};
    assert.equal(path, "/api/handoff/ocr");
    submitted.push(payload);
    return {result: {requestID: "new-request"}};
  };
  context.response = {results: [], pending: false, issues: []};
  await run("makeOcrRequest(false)");
  await run("ocrReturnRequest");
  assert.deepEqual(submitted[0].paths, fallbackPaths);
  assert.equal(submitted[0].directory, "C:\\合成资料\\发件");
  assert.equal(run('supportsOcrImage("C:/合成资料/example.TIFF")'), true);
  assert.equal(run('supportsOcrImage("C:/合成资料/example.BMP")'), false);
  assert.equal(run('supportsOcrImage("C:/合成资料/example.SVG")'), false);
}

const ready = (now, active, delay = 2000) => ({
  resultID: "result-1", path: "C:\\isolated\\result.gaoaction", sha256: "a".repeat(64), status: "completed",
  expiresAt: new Date(now + delay).toISOString(),
  sources: [{name: "扫描文件.pdf", path: active.ocrSourcePath, sourceSHA256: active.ocrSourceSHA256, pages: []}],
});

{
  const {context, run, request, step, timers, calls, nav, documentReturn, active} = setup();
  const result = ready(run("Date.now()"), active);
  context.response = {results: [result], pending: false, issues: []};
  await request();
  assert.ok(nav.ready && !documentReturn.hidden);
  assert.equal(timers.size, 1, "ready-only state schedules one local expiration");
  step(1999);
  assert.ok(nav.ready);
  step(1);
  assert.ok(!nav.ready && documentReturn.hidden);
  assert.equal(run("ocrReturns.results.length"), 0);
  assert.equal(timers.size, 0);
  assert.equal(calls.length, 1, "expiration does not poll the inbox");
}

{
  const {context, run, request, step, timers, calls, reviewCard, active} = setup();
  const result = ready(run("Date.now()"), active);
  context.expectedResult = result;
  context.response = {results: [result], pending: false, issues: []};
  await request();
  context.api = async (path) => {
    assert.equal(path, "/api/handoff/inspect", "review does not import");
    return {result: {sha256: result.sha256}};
  };
  await run("reviewHandoff(expectedResult.path, expectedResult)");
  assert.equal(run("handoffReview.path"), result.path);
  step(2000);
  assert.equal(run("handoffReview"), null);
  assert.match(reviewCard.replacement.textContent, /已过期/);
  assert.deepEqual(context.state.fixtures, ["unchanged"]);
  assert.equal(calls.length, 1);
  assert.equal(timers.size, 0);
}

{
  const {context, run, request, step, timers, calls, nav, active} = setup();
  context.response = {results: [ready(run("Date.now()"), active)], pending: true, issues: []};
  await request();
  assert.equal(timers.size, 2, "pending polling and ready expiration are independent");
  context.document.hidden = true;
  run("updateOcrReturnVisibility()");
  assert.equal(timers.size, 0);
  step(6000);
  assert.equal(calls.length, 1);
  context.response = {results: [], pending: false, issues: []};
  context.document.hidden = false;
  run("updateOcrReturnVisibility()");
  await run("ocrReturnRequest");
  assert.equal(calls.length, 2);
  assert.ok(!nav.ready);
  assert.equal(timers.size, 0);
}

{
  const {context, run, request, active} = setup();
  const result = ready(run("Date.now()"), active);
  context.expectedResult = result;
  context.response = {results: [result], pending: false, issues: []};
  await request();
  run('handoffReview = {path: "previous manual review"}');
  context.api = async (path) => {
    assert.equal(path, "/api/handoff/inspect");
    throw Object.assign(new Error("OCR 结果已变化"), {code: "changed"});
  };
  context.response = {results: [], pending: false, issues: []};
  await assert.rejects(run("reviewHandoff(expectedResult.path, expectedResult)"), /OCR 结果已变化/);
  await run("ocrReturnRequest");
  assert.equal(context.view, "editor");
  assert.equal(context.message, "unchanged");
  assert.deepEqual(context.state.fixtures, ["unchanged"]);
  assert.equal(run("handoffReview.path"), "previous manual review");
  assert.equal(run("ocrReturns.results.length"), 0, "an invalid review refreshes the ready list");
}

console.log("OCR frontend OK: native/fallback multi-select and cancellation, ready expiry, hidden suspend, rejected review.");
