"""只监听 127.0.0.1 的本地页面。文档和资料不离开这台电脑。"""

from __future__ import annotations

import json
import mimetypes
import re
import secrets
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, urlparse

from gaowenjian.errors import AppError
from gaowenjian.pdfdoc import render_page
from gaowenjian.resources import app_icon, asset_dir
from gaowenjian.safety import reject_symlink
from gaowenjian.version import VERSION_LABEL
from gaowenjian.workspace import Workspace
from gaowenjian.writing import cjk_font, markdown_assets

MARKDOWN_STATIC = {
    "/markdown-bridge.js", "/markdown-theme.css", "/md-assets/markdown.css",
    "/md-assets/markdown-core.js", "/md-assets/markdown-editor.js",
    "/md-assets/vendor/marked.js", "/md-assets/vendor/highlight.min.js",
    "/md-assets/vendor/mermaid.min.js", "/md-assets/vendor/purify.min.js",
    "/md-assets/vendor/katex.min.js", "/md-assets/vendor/katex.min.css",
}


class DocumentServer(ThreadingHTTPServer):
    allow_reuse_address = False
    daemon_threads = True

    def __init__(self, workspace: Workspace, host: str = "127.0.0.1", port: int = 0):
        self.workspace = workspace
        self.token = secrets.token_urlsafe(24)
        self.lock = threading.Lock()
        self.revision = 0
        self.shutdown_requested = threading.Event()
        self.desktop_closing = False
        self.ocr_window_visible = True
        super().__init__((host, port), Handler)

    @property
    def url(self) -> str:
        host, port = self.server_address[:2]
        return f"http://{host}:{port}/"

    def snapshot(self) -> dict:
        self.revision += 1
        return {**self.workspace.snapshot(), "revision": self.revision}


class Handler(BaseHTTPRequestHandler):
    server: DocumentServer

    def do_GET(self) -> None:
        parsed = urlparse(self.path)
        bundled_cjk = parsed.path == "/md-assets/NotoSansSC-Regular.otf"
        opaque_font = bundled_cjk or re.fullmatch(r"/md-assets/vendor/fonts/[\w.-]+\.woff2", parsed.path) is not None
        opaque_read = opaque_font or parsed.path in MARKDOWN_STATIC or parsed.path == "/api/media"
        if not self._local_request(opaque_read=opaque_read):
            return
        if parsed.path in {"/", "/settings", "/note"}:
            self._page()
            return
        if parsed.path == "/app-icon.png":
            self._bytes(app_icon().read_bytes(), "image/png")
            return
        if bundled_cjk and cjk_font().is_file():
            self._bytes(cjk_font().read_bytes(), "font/otf")
            return
        if parsed.path == "/markdown-editor.html":
            editor = (asset_dir() / "markdown-editor.html").read_text(encoding="utf-8")
            document = editor.replace("{{ORIGIN}}", self.server.url.removesuffix("/"))
            self._bytes(document.encode("utf-8"), "text/html; charset=utf-8")
            return
        if parsed.path == "/api/state":
            if not self._authorized():
                return
            with self.server.lock:
                state = self.server.snapshot()
            self._json(state)
            return
        if parsed.path == "/api/handoff/ocr-returns":
            if not self._authorized():
                return
            with self.server.lock:
                result = self.server.workspace.ocr_returns() if self.server.ocr_window_visible and not self.server.desktop_closing else {"paused": True}
            self._json(result)
            return
        if parsed.path == "/api/media":
            if not self._authorized(query=parse_qs(parsed.query)):
                return
            query = parse_qs(parsed.query)
            try:
                content, mime = self.server.workspace.media(query.get("tab", [""])[0], query.get("rel", [""])[0])
            except AppError as exc:
                self._json({"error": exc.message, "code": exc.code}, 400)
                return
            self._bytes(content, mime)
            return
        if parsed.path == "/api/binary":
            if not self._authorized(query=parse_qs(parsed.query)):
                return
            query = parse_qs(parsed.query)
            try:
                content, mime = self.server.workspace.file_bytes(query.get("tab", [""])[0])
            except AppError as exc:
                self._json({"error": exc.message, "code": exc.code}, 400)
                return
            self._bytes(content, mime)
            return
        if parsed.path == "/api/pdf/page":
            query = parse_qs(parsed.query)
            if not self._authorized(query=query):
                return
            try:
                page = int(query.get("page", ["0"])[0])
                width = int(query.get("width", ["1100"])[0])
                with self.server.lock:
                    source, password = self.server.workspace.pdf_preview_bytes(query.get("tab", [""])[0])
                content = render_page(source, page, width, password)
            except (AppError, ValueError) as exc:
                self._json({"error": str(exc), "code": "pdf"}, 400)
                return
            self._bytes(content, "image/png")
            return
        if parsed.path.startswith("/api/latex/"):
            query = parse_qs(parsed.query)
            if not self._authorized(query=query):
                return
            try:
                tab = query.get("tab", [""])[0]
                page = query.get("page", [""])[0]
                if parsed.path == "/api/latex/page" and page.isdecimal():
                    width = query.get("width", ["1200"])[0]
                    if not width.isdecimal():
                        raise AppError("无效的预览宽度。", "latex")
                    content = self.server.workspace.latex_page(tab, int(page), int(width))
                    self._bytes(content, "image/png")
                elif parsed.path == "/api/latex/document":
                    self._bytes(self.server.workspace.latex_pdf(tab), "application/pdf")
                else:
                    raise AppError("无效的 LaTeX 预览操作。", "latex")
            except AppError as exc:
                self._json({"error": exc.message, "code": exc.code}, 400)
            return
        relative = parsed.path.lstrip("/")
        root = asset_dir().resolve()
        if relative.startswith("md-assets/"):
            root = markdown_assets().resolve()
            relative = relative.removeprefix("md-assets/")
        asset = (root / relative).resolve()
        if asset.is_file() and root in asset.parents:
            mime = mimetypes.guess_type(asset.name)[0] or "application/octet-stream"
            content = asset.read_bytes()
            if relative == "markdown-editor.js":
                content = content.replace(
                    b"return 'gaomd://attachment/'+path.split('/').map(p=>encodeURIComponent(decodeURIComponentSafe(p))).join('/');",
                    b"return window.gaoMarkdownAttachmentURL(path.split('/').map(decodeURIComponentSafe).join('/'));",
                ).replace(
                    b"theme:matchMedia('(prefers-color-scheme: dark)').matches?",
                    b"theme:window.gaoMarkdownDark()?",
                ).replace(
                    b"    finishEdit,\n",
                    b"""    finishEdit,
    snapshotWindows() {
      commitInput();
      return {text:state.text,selection:currentSelection(),undo:state.undo,redo:state.redo,
              sourceScroll:source.scrollTop,previewScroll:previewPane.scrollTop};
    },
    restoreWindows(snapshot) {
      if(!snapshot || snapshot.text!==state.text) return;
      state.undo=snapshot.undo;state.redo=snapshot.redo;state.lastSelection=snapshot.selection;
      if(state.mode!=='live') source.setSelectionRange(editorOffset(state.text,snapshot.selection.start),
        editorOffset(state.text,snapshot.selection.end));
      source.scrollTop=snapshot.sourceScroll;previewPane.scrollTop=snapshot.previewScroll;
    },
""",
                )
            self._bytes(content, mime)
            return
        self._json({"error": "没有这个页面。"}, 404)

    def do_POST(self) -> None:
        if not self._local_request():
            return
        parsed = urlparse(self.path)
        if parsed.path == "/api/shutdown":
            if not self._authorized():
                return
            force = False
            try:
                force = bool(self._body().get("force"))
            except AppError:
                force = False
            with self.server.lock:
                if not force and self.server.workspace.dirty_count():
                    self._json({"ok": False, "error": "还有未保存的文件。", "code": "dirty"}, 400)
                    return
            self._json({"ok": True})
            self.server.shutdown_requested.set()
            threading.Thread(target=self.server.shutdown, daemon=True).start()
            return
        if not self._authorized():
            return
        try:
            payload = self._body()
            with self.server.lock:
                if self.server.desktop_closing:
                    raise AppError("搞文件正在退出。", "closing")
                result = dispatch(self.server.workspace, parsed.path, payload)
                state = self.server.snapshot()
            self._json({"ok": True, "result": result, "state": state})
        except AppError as exc:
            status = 200 if exc.code == "folder" else 400
            body = {"ok": exc.code == "folder", "error": exc.message, "code": exc.code}
            if exc.code == "folder":
                with self.server.lock:
                    body["state"] = self.server.snapshot()
            self._json(body, status)
        except OSError:
            self._json({"ok": False, "error": "无法读取或写入所选位置。请检查文件是否存在、是否被占用及当前访问权限。", "code": "filesystem"}, 400)
        except (KeyError, TypeError, ValueError):
            self._json({"ok": False, "error": "请求参数无效。", "code": "invalid"}, 400)

    def _page(self) -> None:
        html = (asset_dir() / "index.html").read_text(encoding="utf-8")
        html = html.replace("{{TOKEN}}", self.server.token).replace("{{VERSION}}", VERSION_LABEL)
        self._bytes(html.encode("utf-8"), "text/html; charset=utf-8")

    def _local_request(self, *, opaque_read: bool = False) -> bool:
        authority = self.server.url.removesuffix("/").removeprefix("http://")
        origin = self.headers.get("Origin")
        if self.headers.get("Host") == authority and (
            origin in {None, f"http://{authority}"} or (opaque_read and origin == "null")
        ):
            return True
        self._json({"error": "请求来源无效。"}, 403)
        return False

    def _authorized(self, query: dict | None = None) -> bool:
        token = self.headers.get("X-Gao-Token")
        if token is None and query:
            token = (query.get("token") or [""])[0]
        if token == self.server.token:
            return True
        self._json({"error": "缺少本机会话令牌。"}, 403)
        return False

    def _body(self) -> dict:
        length = int(self.headers.get("Content-Length") or 0)
        if length > 48 * 1024 * 1024:
            raise AppError("上传超过限制。", "invalid")
        raw = self.rfile.read(length) if length else b"{}"
        if not raw:
            return {}
        try:
            data = json.loads(raw.decode("utf-8"))
        except (UnicodeError, json.JSONDecodeError) as exc:
            raise AppError("请求体须为 JSON 对象。", "invalid") from exc
        if not isinstance(data, dict):
            raise AppError("请求体须为 JSON 对象。", "invalid")
        return data

    def _json(self, payload: dict, status: int = 200) -> None:
        body = json.dumps(payload, ensure_ascii=False).encode("utf-8")
        self._bytes(body, "application/json; charset=utf-8", status)

    def _bytes(self, body: bytes, content_type: str, status: int = 200) -> None:
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-Content-Type-Options", "nosniff")
        self.send_header("Referrer-Policy", "no-referrer")
        if content_type == "image/svg+xml":
            self.send_header("Content-Security-Policy", "sandbox; default-src 'none'; style-src 'unsafe-inline'")
        if self.headers.get("Origin") == "null" and (
            content_type in {"font/woff2", "font/otf"} or urlparse(self.path).path in MARKDOWN_STATIC
        ):
            self.send_header("Access-Control-Allow-Origin", "null")
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, fmt: str, *args) -> None:
        return


def dispatch(workspace: Workspace, path: str, payload: dict):
    if path == "/api/tabs/new":
        tab = workspace.new_text(payload.get("kind") or "markdown", payload.get("text"))
        return {"id": tab.id}
    if path == "/api/tabs/open":
        tab = workspace.open_path(Path(payload["path"]))
        return {"id": tab.id if tab else None}
    if path == "/api/tabs/select":
        workspace.selection = workspace._tab(payload["id"]).id
        return {"id": workspace.selection}
    if path == "/api/tabs/edit":
        workspace.edit(payload["id"], payload.get("text") or "", payload.get("html"), select=payload.get("select") is not False)
        return {"dirty": True}
    if path == "/api/tabs/save":
        destination = Path(payload["path"]) if payload.get("path") else None
        saved = workspace.save(payload["id"], destination, bool(payload.get("asCopy")))
        return {"path": str(saved)}
    if path == "/api/tabs/close":
        workspace.close(payload["id"], bool(payload.get("discard")))
        return {"closed": True}
    if path == "/api/tabs/preview":
        return workspace.preview(payload["id"])
    if path == "/api/tabs/complete":
        return workspace.complete(payload["id"], int(payload.get("cursor") or 0)) or {"items": []}
    if path == "/api/tabs/compile":
        return workspace.compile_latex(payload["id"], payload.get("main"), payload.get("engine"))
    if path == "/api/tabs/synctex":
        return workspace.synctex(payload["id"], payload)
    if path == "/api/latex/export":
        return workspace.export_latex(payload["id"], Path(payload["path"]))
    if path == "/api/markdown/attachment":
        return workspace.markdown_attachment(payload["id"], payload.get("name") or "", payload.get("data") or "")
    if path == "/api/tabs/csv":
        workspace.apply_csv(payload["id"], payload.get("rows") or [])
        return {"ok": True}
    if path == "/api/tabs/pdf":
        return workspace.pdf_action(payload["id"], payload.get("op") or "", payload)
    if path == "/api/export/html":
        return {"path": str(workspace.export_html(payload["id"], Path(payload["path"]), payload.get("html")))}
    if path == "/api/export/pdf":
        return workspace.export_pdf(payload["id"], Path(payload["path"]), payload.get("html"))
    if path == "/api/folder":
        if payload.get("path"):
            workspace.set_folder(Path(payload["path"]))
        else:
            workspace.folder = None
            workspace._persist_state()
        return {"folder": str(workspace.folder or "")}
    if path == "/api/dialog":
        return {"path": choose_path(payload.get("mode") or "open", payload.get("name") or "")}
    if path == "/api/settings":
        return workspace.update_settings(payload)
    if path == "/api/external":
        workspace.external_open(Path(payload["path"]))
        return {"opened": True}
    if path == "/api/reveal":
        workspace.reveal(payload["id"])
        return {"opened": True}
    if path == "/api/office/reload":
        workspace.reload_office(payload["id"])
        return {"ok": True}
    if path == "/api/office/recovery-folder":
        folder = workspace.data_dir / "Recovery" / "Office"
        if not folder.is_dir():
            raise AppError("Office 恢复目录不存在。", "missing")
        workspace.external_open(folder)
        return {"opened": True}
    if path == "/api/office/export-recovery":
        return {"path": str(workspace.export_office_recovery(payload["id"], Path(payload["path"])))}
    if path == "/api/handoff/import":
        tab = workspace.import_handoff(Path(payload["path"]), payload.get("sha256"))
        return {"id": None if tab is None else tab.id}
    if path == "/api/handoff/state":
        return workspace.handoff_state()
    if path == "/api/handoff/inspect":
        return workspace.inspect_handoff(Path(payload["path"]))
    if path == "/api/handoff/ocr":
        return workspace.export_ocr(payload)
    if path == "/api/handoff/dispatch":
        from gaowenjian.ocr_handoff import dispatch_request

        if not workspace.handoff or payload.get("confirm") is not True:
            raise AppError("请确认打开搞操作审核。", "handoff")
        return dispatch_request(workspace.handoff, payload["requestID"],
                                Path(payload["provider"]) if payload.get("provider") else None)
    if path == "/api/handoff/reference":
        tab = workspace.handoff_reference(payload["id"], Path(payload["path"]))
        return {"id": tab.id}
    if path == "/api/handoff/research":
        return workspace.export_research(payload["id"], Path(payload["directory"]), payload.get("targetRecordID"))
    if path == "/api/handoff/choose-inputs":
        return {"paths": choose_path("ocr-inputs")}
    if path == "/api/handoff/organizer":
        from gaowenjian.organizer_actions import complete

        return complete(workspace, payload)
    if path.startswith("/api/organizer/"):
        from gaowenjian.organizer import dispatch as dispatch_organizer

        return dispatch_organizer(workspace, path.removeprefix("/api/organizer/"), payload)
    if path == "/api/notes/create":
        return {"id": workspace.notes.create(payload.get("title") or "", payload.get("html") or "", payload.get("plain") or "")}
    if path == "/api/notes/update":
        workspace.notes.update(payload["id"], payload.get("html") or "", payload.get("plain") or "",
                               expected=payload.get("expected"), changes=payload.get("changes"))
        return {"ok": True}
    if path == "/api/notes/attach":
        source = Path(payload["path"])
        reject_symlink(source)
        if not source.is_file() or source.stat().st_size > 20 * 1024 * 1024:
            raise AppError("请选择不超过 20 MB 的附件文件。", "notes")
        workspace.notes.attach(payload["id"], source.name, source.read_bytes())
        return {"ok": True}
    if path == "/api/notes/export-attachment":
        workspace.notes.export_attachment(payload["id"], int(payload["index"]), Path(payload["path"]))
        return {"ok": True}
    if path == "/api/notes/metadata":
        workspace.notes.metadata(payload["id"], payload.get("changes") or {})
        return {"ok": True}
    if path == "/api/notes/trash":
        workspace.notes.trash(payload["id"])
        return {"ok": True}
    if path == "/api/notes/restore":
        workspace.notes.restore(payload["id"])
        return {"ok": True}
    if path == "/api/notes/defaults":
        workspace.notes.set_defaults(payload)
        return {"ok": True}
    if path == "/api/notes/import":
        return {"id": workspace.notes.import_file(Path(payload["path"]))}
    if path == "/api/notes/export":
        workspace.notes.export(payload["id"], payload.get("format") or "txt", Path(payload["path"]))
        return {"ok": True}
    if path == "/api/notes/to-markdown":
        note = workspace.notes._find(payload["id"])
        tab = workspace.new_text("markdown", note.get("plainText") or "")
        return {"id": tab.id}
    if path == "/api/projects/save":
        return workspace.projects.save(payload)
    if path == "/api/projects/restore":
        return workspace.projects.restore(payload)
    if path == "/api/projects/checkpoint":
        return workspace.projects.checkpoint(payload.get("reading", {}))
    if path == "/api/projects/reader":
        return workspace.projects.reader_page(payload["id"], payload.get("page"))
    raise AppError("没有这个操作。", "invalid")


def choose_path(mode: str, name: str = "") -> str | list[str]:
    try:
        import tkinter as tk
        from tkinter import filedialog
    except Exception as exc:
        raise AppError("当前环境没有图形文件对话框，请输入路径。", "dialog") from exc
    root = tk.Tk()
    root.withdraw()
    try:
        from gaowenjian.desktop import FILE_TYPES

        types = tuple((item.split(" (")[0], " ".join(item.split(" (")[1][:-1].split(";"))) for item in FILE_TYPES.get(mode, ()))
        if mode == "save":
            selected = filedialog.asksaveasfilename(title="保存文件", initialfile=Path(name).name)
        elif mode == "folder":
            selected = filedialog.askdirectory(title="打开文件夹")
        elif mode == "ocr-inputs":
            selected = list(filedialog.askopenfilenames(title="选择 OCR 文件", filetypes=[
                ("PDF 和图像", "*.pdf *.png *.jpg *.jpeg *.tif *.tiff *.gif *.webp *.heic *.heif"), ("所有文件", "*"),
            ]))
        elif mode == "multiple":
            selected = list(filedialog.askopenfilenames(title="选择要交接的文件"))
        else:
            selected = filedialog.askopenfilename(title="打开文件", filetypes=types + (("所有文件", "*"),))
    finally:
        root.destroy()
    if not selected:
        raise AppError("没有选择文件。", "cancelled")
    return selected


def serve(workspace: Workspace, port: int = 0, open_browser: bool = True) -> DocumentServer:
    server = DocumentServer(workspace, port=port)
    thread = threading.Thread(target=server.serve_forever, name="gaowenjian-http", daemon=True)
    thread.start()
    if open_browser:
        import webbrowser
        webbrowser.open(server.url)
    return server
