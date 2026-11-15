"""只监听 127.0.0.1 的本地页面。文档和资料不离开这台电脑。"""

from __future__ import annotations

import json
import mimetypes
import secrets
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, urlparse

from gaowenjian.errors import AppError
from gaowenjian.resources import asset_dir
from gaowenjian.version import VERSION_LABEL
from gaowenjian.workspace import Workspace


class DocumentServer(ThreadingHTTPServer):
    allow_reuse_address = False
    daemon_threads = True

    def __init__(self, workspace: Workspace, host: str = "127.0.0.1", port: int = 0):
        self.workspace = workspace
        self.token = secrets.token_urlsafe(24)
        self.lock = threading.Lock()
        self.shutdown_requested = threading.Event()
        super().__init__((host, port), Handler)

    @property
    def url(self) -> str:
        host, port = self.server_address[:2]
        return f"http://{host}:{port}/"


class Handler(BaseHTTPRequestHandler):
    server: DocumentServer

    def do_GET(self) -> None:
        parsed = urlparse(self.path)
        if parsed.path == "/":
            self._page()
            return
        if parsed.path == "/api/state":
            if not self._authorized():
                return
            with self.server.lock:
                self._json(self.server.workspace.snapshot())
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
        root = asset_dir().resolve()
        asset = (root / parsed.path.lstrip("/")).resolve()
        if asset.is_file() and root in asset.parents:
            mime = mimetypes.guess_type(asset.name)[0] or "application/octet-stream"
            self._bytes(asset.read_bytes(), mime)
            return
        self._json({"error": "没有这个页面。"}, 404)

    def do_POST(self) -> None:
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
                result = dispatch(self.server.workspace, parsed.path, payload)
            self._json({"ok": True, "result": result, "state": self.server.workspace.snapshot()})
        except AppError as exc:
            status = 200 if exc.code == "folder" else 400
            body = {"ok": exc.code == "folder", "error": exc.message, "code": exc.code}
            if exc.code == "folder":
                body["state"] = self.server.workspace.snapshot()
            self._json(body, status)

    def _page(self) -> None:
        html = (asset_dir() / "index.html").read_text(encoding="utf-8")
        html = html.replace("{{TOKEN}}", self.server.token).replace("{{VERSION}}", VERSION_LABEL)
        self._bytes(html.encode("utf-8"), "text/html; charset=utf-8")

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
        return {"id": tab.id}
    if path == "/api/tabs/select":
        workspace.selection = workspace._tab(payload["id"]).id
        return {"id": workspace.selection}
    if path == "/api/tabs/edit":
        workspace.edit(payload["id"], payload.get("text") or "", payload.get("html"))
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
        return workspace.compile_latex(payload["id"])
    if path == "/api/tabs/synctex":
        return workspace.synctex(payload["id"], payload)
    if path == "/api/tabs/csv":
        workspace.apply_csv(payload["id"], payload.get("rows") or [])
        return {"ok": True}
    if path == "/api/tabs/pdf":
        return workspace.pdf_action(payload["id"], payload.get("op") or "", payload)
    if path == "/api/export/html":
        return {"path": str(workspace.export_html(payload["id"], Path(payload["path"])))}
    if path == "/api/export/pdf":
        return workspace.export_pdf(payload["id"], Path(payload["path"]))
    if path == "/api/folder":
        workspace.set_folder(Path(payload["path"]))
        return {"folder": str(workspace.folder)}
    if path == "/api/dialog":
        return {"path": choose_path(payload.get("mode") or "open")}
    if path == "/api/settings":
        return workspace.update_settings(payload)
    if path == "/api/external":
        workspace.external_open(Path(payload["path"]))
        return {"opened": True}
    if path == "/api/office/export-recovery":
        return {"path": str(workspace.export_office_recovery(payload["id"], Path(payload["path"])))}
    if path == "/api/handoff/import":
        tab = workspace.import_handoff(Path(payload["path"]))
        return {"id": None if tab is None else tab.id}
    if path == "/api/handoff/research":
        return workspace.export_research(payload["id"], Path(payload["directory"]), payload.get("targetRecordID"))
    if path == "/api/notes/create":
        return {"id": workspace.notes.create(payload.get("title") or "", payload.get("html") or "", payload.get("plain") or "")}
    if path == "/api/notes/update":
        workspace.notes.update(payload["id"], payload.get("html") or "", payload.get("plain") or "")
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
    raise AppError("没有这个操作。", "invalid")


def choose_path(mode: str) -> str:
    try:
        import tkinter as tk
        from tkinter import filedialog
    except Exception as exc:
        raise AppError("当前环境没有图形文件对话框，请输入路径。", "dialog") from exc
    root = tk.Tk()
    root.withdraw()
    try:
        if mode == "save":
            selected = filedialog.asksaveasfilename(title="保存文件")
        elif mode == "folder":
            selected = filedialog.askdirectory(title="打开文件夹")
        else:
            selected = filedialog.askopenfilename(title="打开文件")
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
