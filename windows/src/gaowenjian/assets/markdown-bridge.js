const editorConfig = new URLSearchParams(location.search);
const sendMarkdownEvent = (payload) => parent.postMessage({gaoMarkdown: true, ...payload}, location.origin);

window.webkit = {messageHandlers: {gaoMD: {postMessage: sendMarkdownEvent}}};
window.gaoMarkdownAttachmentURL = (relative) => {
  const media = new URLSearchParams({tab: editorConfig.get("tab"), token: editorConfig.get("token"), rel: relative});
  return `/api/media?${media}`;
};

document.documentElement.dataset.theme = editorConfig.get("theme") === "dark" ? "dark" : "light";
const font = Math.max(11, Math.min(24, Number(editorConfig.get("font")) || 15));
document.documentElement.style.setProperty("--md-editor-size", font + "px");
document.getElementById("source").wrap = editorConfig.get("wrap") === "off" ? "off" : "soft";
window.gaoMarkdownDark = () => document.documentElement.dataset.theme === "dark";
document.addEventListener("keydown", (event) => {
  if ((event.ctrlKey || event.metaKey) && event.key.toLowerCase() === "s") {
    event.preventDefault();
    sendMarkdownEvent({kind: "save"});
  }
});

window.addEventListener("message", (event) => {
  if (event.source !== parent || event.origin !== location.origin || !event.data?.gaoMarkdown) return;
  const editor = window.gaoMarkdown;
  if (!editor) return;
  const {command, args} = event.data;
  if (command === "load") {
    const [text, mode, outline, snapshot] = args;
    editor.setDocument(text, mode, outline);
    editor.restoreWindows?.(snapshot);
  } else if (["setMode", "setOutline", "format", "insertSnippet", "requestExport"].includes(command)) {
    editor[command](...args);
  }
});

let snapshotTimer;
function scheduleMarkdownSnapshot() {
  clearTimeout(snapshotTimer);
  snapshotTimer = setTimeout(() => {
    if (window.gaoMarkdown?.snapshotWindows) {
      sendMarkdownEvent({kind: "snapshot", snapshot: window.gaoMarkdown.snapshotWindows()});
    }
  }, 180);
}
for (const event of ["input", "keyup", "mouseup", "scroll"]) {
  document.addEventListener(event, scheduleMarkdownSnapshot, {capture: true, passive: true});
}
