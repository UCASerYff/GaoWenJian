"""写作、文件和便笺工作区。用户文档留在原路径，内部资料损坏时不覆盖。"""

from __future__ import annotations

import os
import shutil
import subprocess
import sys
import uuid
from pathlib import Path

from gaowenjian.csvtext import encode as encode_csv
from gaowenjian.csvtext import markdown_table, parse as parse_csv
from gaowenjian.errors import AppError
from gaowenjian.handoff import HandoffBook
from gaowenjian.latex import complete as latex_complete
from gaowenjian.latex import parse_index, parse_log, root_directive
from gaowenjian.markdown import export_document, outline, render
from gaowenjian.notes import NotesStore
from gaowenjian.office import read_document
from gaowenjian.pdfdoc import extract, image_info, inspect, merge, plain_pdf, search, split, transform
from gaowenjian.rtf import from_html, parse as parse_rtf
from gaowenjian.safety import GuardedJSON, digest, inside, reject_symlink, safe_replace, same_file
from gaowenjian.version import VERSION_LABEL

TEXT_KINDS = {"markdown", "latex", "csv", "text"}
WRITER = "gaowenjian-windows-1"
MARKDOWN_TEMPLATE = """# 新的开始

在这里记录想法、整理材料和撰写文档。

## 待办

- [ ] 整理资料
- [ ] 完成初稿

## 数据

| 项目 | 数值 |
| --- | --- |
| 示例 | 1 |

## 公式

$$E = mc^2$$
"""
LATEX_TEMPLATE = r"""\documentclass[12pt]{article}
\usepackage{fontspec}
\usepackage{xeCJK}
\usepackage{amsmath,amssymb,graphicx}
\title{我的文档}
\author{}
\date{\today}
\begin{document}
\maketitle
\section{开始写作}
欢迎使用搞文件。本地编辑与离线编译。
\begin{equation}
E = mc^2
\end{equation}
\end{document}
"""
CSV_TEMPLATE = "名称,数值,备注\n项目,0,\n"


def kind_for(path: Path) -> str:
    extension = path.suffix.lower().lstrip(".")
    if extension in {"md", "markdown"}:
        return "markdown"
    if extension in {"tex", "bib", "sty", "cls"}:
        return "latex"
    if extension == "pdf":
        return "pdf"
    if extension in {"doc", "docx", "docm", "dotx", "dotm", "odt"}:
        return "word"
    if extension in {"xls", "xlsx", "xlsm", "xltx", "xltm", "ods"}:
        return "spreadsheet"
    if extension in {"ppt", "pptx", "pptm", "potx", "potm", "pps", "ppsx", "odp"}:
        return "presentation"
    if extension in {"csv", "tsv"}:
        return "csv"
    if extension == "rtf":
        return "richText"
    if extension in {"txt", "json", "xml", "yaml", "yml", "html", "css", "js", "swift", "py", "r", "log", "sh"}:
        return "text"
    if extension in {"png", "jpg", "jpeg", "gif", "webp", "heic", "tiff", "tif", "bmp", "svg"}:
        return "image"
    return "other"


class Tab:
    def __init__(self, kind: str, text: str = "", path: Path | None = None):
        self.id = str(uuid.uuid4())
        self.kind = kind
        self.path = path
        self.text = text
        self.saved_text = text
        self.dirty = bool(text)
        self.digest: str | None = None
        self.encoding = "utf-8"
        self.encoding_code = 4
        self.restored = False
        self.suggested_title: str | None = None
        self.extra: dict = {}
        self.binary: bytes | None = None
        self.lossy = False
        self.html = ""
        self.preview: dict | None = None
        self.undo: list[bytes] = []
        self.redo: list[bytes] = []
        self.message = ""

    @property
    def title(self) -> str:
        if self.path:
            return self.path.name
        if self.suggested_title:
            return self.suggested_title
        extension = {"markdown": "md", "latex": "tex", "csv": "csv"}.get(self.kind, "txt")
        return f"未命名.{extension}"


class Workspace:
    def __init__(self, data_dir: Path):
        self.data_dir = data_dir
        self.data_dir.mkdir(parents=True, exist_ok=True)
        self.tabs: list[Tab] = []
        self.selection: str | None = None
        self.folder: Path | None = None
        self.recent: list[str] = []
        self.status = "文件仅保存在本机"
        self.error = ""
        self.state_guard = GuardedJSON(self.data_dir / "workspace.json")
        self.recovery_guard = GuardedJSON(self.data_dir / "recovery.json")
        self.settings_guard = GuardedJSON(self.data_dir / "settings.json")
        self.settings = {"appearance": "system", "latexEngine": "auto"}
        self.notes = NotesStore(self.data_dir / "StickyNotes")
        try:
            self.handoff = HandoffBook(self.data_dir / "Handoff")
        except AppError as exc:
            self.handoff = None
            self.error = exc.message
        self._load_settings()
        self._load_state()
        self._load_recovery()

    def snapshot(self) -> dict:
        return {
            "version": VERSION_LABEL,
            "status": self.status,
            "error": self.error,
            "dataDir": str(self.data_dir),
            "folder": str(self.folder) if self.folder else "",
            "entries": self.entries(),
            "recent": [{"path": path, "name": Path(path).name, "kind": kind_for(Path(path))} for path in self.recent],
            "tabs": [self._tab_summary(tab) for tab in self.tabs],
            "selection": self.selection,
            "settings": self.settings,
            "notes": self.notes.snapshot(),
            "engines": self.engine_status(),
            "recoveryBlocked": not self.recovery_guard.readable,
            "stateBlocked": not self.state_guard.readable,
        }

    def new_text(self, kind: str, text: str | None = None) -> Tab:
        if kind not in TEXT_KINDS:
            raise AppError("只能新建 Markdown、LaTeX、CSV 或纯文本。", "kind")
        if text is None:
            text = {"markdown": MARKDOWN_TEMPLATE, "latex": LATEX_TEMPLATE, "csv": CSV_TEMPLATE}.get(kind, "")
        if "\x00" in text:
            raise AppError("文本含无效字符。", "text")
        tab = Tab(kind, text)
        tab.saved_text = ""
        tab.dirty = text != ""
        self.tabs.append(tab)
        self.selection = tab.id
        self._checkpoint()
        self.status = f"已新建{tab.title}"
        return tab

    def open_path(self, path: Path) -> Tab:
        path = path.expanduser()
        if path.suffix.lower() == ".gaoaction" or (path.is_dir() and path.name.endswith(".gaoaction")):
            return self.import_handoff(path)
        if path.is_dir():
            self.set_folder(path)
            raise AppError("已打开文件夹。", "folder")
        if not path.is_file():
            raise AppError(f"文件不存在：{path.name}", "missing")
        reject_symlink(path)
        for tab in self.tabs:
            if tab.path and same_file(tab.path, path):
                self.selection = tab.id
                return tab
        kind = kind_for(path)
        data = path.read_bytes()
        tab = Tab(kind, path=path)
        tab.digest = digest(data)
        if kind in TEXT_KINDS:
            if len(data) > 20_000_000:
                raise AppError("文本超过 20 MB，请使用专用大文件工具打开。", "limit")
            text, encoding, code = _decode_text(data)
            tab.text = text
            tab.saved_text = text
            tab.encoding = encoding
            tab.encoding_code = code
            tab.dirty = False
        elif kind == "richText":
            parsed = parse_rtf(data)
            tab.text = parsed["plain"]
            tab.html = parsed["html"]
            tab.saved_text = parsed["plain"]
            tab.binary = data
            tab.lossy = parsed["lossy"]
            tab.dirty = False
            self._restore_rtf(tab)
        elif kind == "pdf":
            tab.binary = data
            tab.preview = inspect(data)
            tab.dirty = False
            self._restore_pdf(tab)
        elif kind == "image":
            tab.binary = data
            tab.preview = image_info(data, path.suffix.lstrip("."))
        elif kind in {"word", "spreadsheet", "presentation"}:
            tab.binary = data
            tab.preview = read_document(data, path.suffix.lstrip("."))
            tab.preview["recovery"] = self._office_recovery(path, data)
        else:
            tab.preview = {"message": "Windows 版不能编辑这个格式。可以在资源管理器中打开，原件不会被改写。", "bytes": len(data)}
        self.tabs.append(tab)
        self.selection = tab.id
        self._remember(path)
        self.status = f"已打开 {path.name}"
        return tab

    def edit(self, tab_id: str, text: str, html: str | None = None) -> None:
        tab = self._tab(tab_id)
        if tab.kind not in TEXT_KINDS | {"richText"}:
            raise AppError("这个文件不能按文本编辑。", "readonly")
        if "\x00" in text or len(text.encode("utf-8")) > 20_000_000:
            raise AppError("文本超过限制或含无效字符。", "text")
        tab.text = text
        if html is not None:
            tab.html = html
        tab.dirty = tab.restored or text != tab.saved_text or (tab.kind == "richText" and html is not None)
        self.selection = tab.id
        if tab.kind == "richText" and tab.path:
            self._persist_rtf(tab)
        self._checkpoint()
        self.status = "已记录未保存的修改" if tab.dirty else "已与磁盘一致"

    def save(self, tab_id: str, path: Path | None = None, as_copy: bool = False) -> Path:
        tab = self._tab(tab_id)
        if tab.kind in {"word", "spreadsheet", "presentation", "image", "other"}:
            raise AppError("这个格式在 Windows 版只读，不能覆盖保存。需要编辑时请用本机对应软件打开。", "readonly")
        destination = path or tab.path
        if destination is None or as_copy and path is None:
            raise AppError("请指定保存路径。", "path")
        destination = Path(destination)
        if inside(destination, self.data_dir):
            raise AppError("不能把用户文档保存进应用资料目录。", "protected")
        if tab.path and same_file(destination, tab.path) and as_copy:
            raise AppError("另存目标不能是当前原件。", "path")
        replacing = tab.path is not None and same_file(destination, tab.path) and not as_copy
        if tab.kind in TEXT_KINDS:
            encoding = "utf-8" if as_copy or not replacing else tab.encoding
            try:
                data = _encode_text(tab.text, encoding)
            except UnicodeEncodeError as exc:
                raise AppError("当前编码无法保存这些字符，请使用“另存为”生成 UTF-8 文件。", "encoding") from exc
        elif tab.kind == "richText":
            if replacing and tab.lossy:
                raise AppError("这份 RTF 含有 Windows 版无法无损保留的对象。请另存为新文件，原件未被覆盖。", "lossy")
            data = from_html(tab.html or _html_escape(tab.text))
        elif tab.kind == "pdf":
            if tab.binary is None:
                raise AppError("没有可保存的 PDF。", "pdf")
            data = tab.binary
        else:
            raise AppError("这个文件不能保存。", "readonly")
        safe_replace(destination, data, tab.digest if replacing else None)
        written = destination.read_bytes()
        if written != data:
            raise AppError("保存后读回核验失败，请检查磁盘。", "verify")
        if replacing or tab.path is None or as_copy:
            tab.path = destination
            tab.digest = digest(written)
            tab.saved_text = tab.text
            tab.binary = written if tab.kind in {"pdf", "richText"} else tab.binary
            tab.dirty = False
            tab.restored = False
            tab.lossy = False if tab.kind == "richText" else tab.lossy
            if as_copy:
                tab.encoding = "utf-8"
                tab.encoding_code = 4
        self._remember(destination)
        self._checkpoint()
        if tab.kind == "pdf":
            self._clear_pdf_recovery(tab)
        if tab.kind == "richText":
            self._clear_rtf_recovery(tab)
        self.status = f"已保存 {destination.name}"
        return destination

    def close(self, tab_id: str, discard: bool = False) -> None:
        tab = self._tab(tab_id)
        if tab.dirty and not discard:
            raise AppError(f"“{tab.title}”还有未保存的修改。", "dirty")
        if discard and tab.kind == "pdf":
            self._clear_pdf_recovery(tab)
        if discard and tab.kind == "richText":
            self._clear_rtf_recovery(tab)
        index = self.tabs.index(tab)
        self.tabs.remove(tab)
        if self.selection == tab_id:
            self.selection = self.tabs[min(index, len(self.tabs) - 1)].id if self.tabs else None
        self._checkpoint()

    def set_folder(self, path: Path) -> None:
        path = path.expanduser()
        if not path.is_dir():
            raise AppError("文件夹不存在。", "missing")
        self.folder = path
        self._persist_state()
        self.status = f"当前文件夹 {path.name}"

    def entries(self) -> list[dict]:
        if not self.folder or not self.folder.is_dir():
            return []
        result = []

        def scan(directory: Path, depth: int) -> None:
            if depth >= 4 or len(result) >= 1500:
                return
            try:
                children = sorted(directory.iterdir(), key=lambda item: (not item.is_dir(), item.name.lower()))
            except OSError:
                return
            for child in children:
                if child.name.startswith(".") or child.is_symlink():
                    continue
                if child.name in {"node_modules", "build", ".git"}:
                    continue
                result.append({"path": str(child), "name": child.name, "directory": child.is_dir(), "depth": depth, "kind": "folder" if child.is_dir() else kind_for(child)})
                if child.is_dir():
                    scan(child, depth + 1)

        scan(self.folder, 0)
        return result

    def preview(self, tab_id: str) -> dict:
        tab = self._tab(tab_id)
        if tab.kind == "markdown":
            return {"html": render(tab.text), "outline": outline(tab.text)}
        if tab.kind == "latex":
            root = root_directive(tab.text, tab.path)
            return {"index": parse_index(tab.text), "root": str(root) if root else "", "log": tab.preview or {}}
        if tab.kind == "csv":
            delimiter = "\t" if tab.path and tab.path.suffix.lower() == ".tsv" else ","
            rows = parse_csv(tab.text, delimiter)
            return {"rows": rows, "delimiter": delimiter, "markdown": markdown_table(rows)}
        if tab.kind == "pdf" and tab.binary is not None:
            tab.preview = inspect(tab.binary)
            return tab.preview
        return tab.preview or {}

    def apply_csv(self, tab_id: str, rows: list[list[str]]) -> None:
        tab = self._tab(tab_id)
        if tab.kind != "csv":
            raise AppError("当前文件不是 CSV。", "kind")
        delimiter = "\t" if tab.path and tab.path.suffix.lower() == ".tsv" else ","
        self.edit(tab_id, encode_csv([[str(cell) for cell in row] for row in rows], delimiter))

    def complete(self, tab_id: str, cursor: int) -> dict | None:
        tab = self._tab(tab_id)
        if tab.kind != "latex":
            return None
        indexed = parse_index(tab.text)
        return latex_complete(tab.text, cursor, indexed["labels"], indexed["citations"])

    def compile_latex(self, tab_id: str) -> dict:
        tab = self._tab(tab_id)
        if tab.kind != "latex":
            raise AppError("请先打开 LaTeX 文件。", "kind")
        if tab.dirty or tab.path is None:
            raise AppError("请先保存 LaTeX 文件，再编译磁盘上的主文件。", "dirty")
        root = root_directive(tab.text, tab.path) or tab.path
        if not root.is_file() or root.suffix.lower() != ".tex":
            raise AppError("请选择有效的 .tex 主文件。", "latex")
        before = digest(root.read_bytes())
        engine_name, executable = self._engine()
        build = self.data_dir / "Builds" / digest(str(root).encode())[:24] / uuid.uuid4().hex
        build.mkdir(parents=True)
        if engine_name == "tectonic":
            command = [str(executable), "--only-cached", "--untrusted", "--keep-logs", "--synctex", "--outdir", str(build), str(root)]
            env = os.environ.copy()
            cache = self.data_dir / "TeXCache"
            cache.mkdir(parents=True, exist_ok=True)
            env["TECTONIC_CACHE_DIR"] = str(cache)
        else:
            command = [str(executable), "-file-line-error", "-synctex=1", "-no-shell-escape", "-interaction=nonstopmode", "-halt-on-error", "-output-directory=" + str(build), str(root)]
            env = None
        try:
            result = subprocess.run(command, cwd=root.parent, env=env, text=True, capture_output=True, timeout=120, check=False)
        except subprocess.TimeoutExpired as exc:
            raise AppError("编译超过 120 秒，已停止。原 tex 文件未修改。", "latex") from exc
        if digest(root.read_bytes()) != before:
            raise AppError("编译期间主文件发生变化，请重新编译。", "conflict")
        log = (result.stdout or "") + ("\n" + result.stderr if result.stderr else "")
        diagnostics = parse_log(log)
        produced = build / f"{root.stem}.pdf"
        tab.preview = {"log": log[-20000:], "diagnostics": diagnostics, "engine": engine_name}
        parent = build.parent
        for old in parent.iterdir():
            if old != build:
                shutil.rmtree(old, ignore_errors=True)
        if result.returncode != 0 or not produced.is_file():
            errors = [item for item in diagnostics if item["severity"] == "error"]
            raise AppError(f"编译未完成。{'发现 ' + str(len(errors)) + ' 处错误。' if errors else ''}离线缺失的宏包需要本机 TeX 环境提供。\n{log[-4000:]}", "latex")
        opened = self.open_path(produced)
        self.status = f"编译成功 · {root.name}"
        return {"pdf": str(produced), "tab": opened.id, "diagnostics": diagnostics, "engine": engine_name}

    def synctex(self, tab_id: str, payload: dict) -> dict:
        tool = shutil.which("synctex")
        if not tool:
            raise AppError("没有找到 synctex。Windows 版不附带 TeX 工具，双向定位需要本机安装。", "synctex")
        tab = self._tab(tab_id)
        pdf = payload.get("pdf") or (str(tab.path) if tab.kind == "pdf" and tab.path else "")
        if not pdf:
            raise AppError("没有可定位的 PDF。", "synctex")
        if payload.get("direction") == "forward":
            source = payload.get("source")
            command = [tool, "view", "-i", f"{int(payload.get('line') or 1)}:1:{source}", "-o", pdf]
        else:
            command = [tool, "edit", "-o", f"{int(payload.get('page') or 1)}:{int(payload.get('x') or 0)}:{int(payload.get('y') or 0)}:{pdf}"]
        result = subprocess.run(command, text=True, capture_output=True, timeout=20, check=False)
        if result.returncode != 0 or "SyncTeX result begin" not in result.stdout:
            raise AppError("SyncTeX 没有返回位置。", "synctex")
        parsed = {}
        for line in result.stdout.splitlines():
            if ":" not in line:
                continue
            key, value = line.split(":", 1)
            parsed[key.strip()] = value.strip()
        return parsed

    def pdf_action(self, tab_id: str, operation: str, payload: dict) -> dict:
        tab = self._tab(tab_id)
        if tab.kind != "pdf" or tab.binary is None:
            raise AppError("当前文件不是 PDF。", "pdf")
        if operation == "search":
            return {"matches": search(tab.binary, str(payload.get("query") or ""))}
        if operation == "undo":
            if not tab.undo:
                raise AppError("没有可撤销的 PDF 操作。", "pdf")
            tab.redo.append(tab.binary)
            tab.binary = tab.undo.pop()
            tab.dirty = True
            tab.preview = inspect(tab.binary)
            self._persist_pdf(tab)
            return tab.preview
        if operation == "redo":
            if not tab.redo:
                raise AppError("没有可重做的 PDF 操作。", "pdf")
            tab.undo.append(tab.binary)
            tab.binary = tab.redo.pop()
            tab.dirty = True
            tab.preview = inspect(tab.binary)
            self._persist_pdf(tab)
            return tab.preview
        if operation == "merge":
            extra = Path(payload["path"]).read_bytes()
            updated = merge([tab.binary, extra])
        elif operation == "extract":
            updated = extract(tab.binary, [int(item) for item in payload.get("pages") or []])
            target = Path(payload["path"])
            if target.exists():
                raise AppError("提取目标已存在，请换新路径。", "export")
            safe_replace(target, updated, None)
            return {"path": str(target)}
        elif operation == "split":
            directory = Path(payload["directory"])
            if directory.exists() and any(directory.iterdir()):
                raise AppError("拆分目录必须是空目录或不存在的新目录。", "export")
            directory.mkdir(parents=True, exist_ok=True)
            paths = []
            for index, part in enumerate(split(tab.binary), start=1):
                target = directory / f"{(tab.path.stem if tab.path else '页面')}-{index}.pdf"
                safe_replace(target, part, None)
                paths.append(str(target))
            return {"paths": paths}
        elif operation in {"image", "image-file"}:
            import base64
            if operation == "image-file":
                raw = Path(payload["path"]).read_bytes()
            else:
                raw = base64.b64decode(payload.get("contentBase64") or "", validate=True)
            stamped = dict(payload)
            stamped["image"] = raw
            updated = transform(tab.binary, "image", stamped)
        else:
            updated = transform(tab.binary, operation, payload)
        tab.undo.append(tab.binary)
        tab.undo = tab.undo[-20:]
        tab.redo.clear()
        tab.binary = updated
        tab.dirty = True
        tab.preview = inspect(updated)
        self._persist_pdf(tab)
        return tab.preview

    def export_html(self, tab_id: str, path: Path) -> Path:
        tab = self._tab(tab_id)
        if tab.kind != "markdown":
            raise AppError("HTML 导出只用于 Markdown。", "export")
        if path.exists():
            raise AppError("导出目标已存在。请换一个新路径。", "export")
        safe_replace(path, export_document(tab.title, render(tab.text)).encode("utf-8"), None)
        return path

    def export_pdf(self, tab_id: str, path: Path) -> dict:
        tab = self._tab(tab_id)
        if tab.kind not in TEXT_KINDS:
            raise AppError("文本 PDF 导出只用于文本类文件。", "export")
        if path.exists():
            raise AppError("导出目标已存在。请换一个新路径。", "export")
        data, degraded = plain_pdf(tab.text)
        safe_replace(path, data, None)
        return {"path": str(path), "degraded": degraded}

    def import_handoff(self, path: Path) -> Tab:
        if self.handoff is None:
            raise AppError(self.error or "交接日志无法读取，已停止处理。", "handoff")
        if not self.recovery_guard.readable:
            raise AppError("草稿恢复记录无法读取，交接文字尚未导入，请先处理现有恢复记录。", "recovery")
        result = self.handoff.import_package(path)
        if result["duplicate"]:
            raise AppError("这份交接结果已经处理过，没有重复打开。", "duplicate")
        last = None
        for item in result["opened"]:
            if item["kind"] == "newText":
                kind = "markdown" if (item.get("title") or "").lower().endswith((".md", ".markdown")) or item.get("manifest", {}).get("action") == "documents.newText" and "markdown" in str(item.get("title") or "") else "text"
                if item.get("manifest", {}).get("action") == "documents.newText":
                    kind = "markdown" if str(item.get("title") or "").lower().endswith((".md", ".markdown")) else "text"
                tab = Tab(kind, item["text"])
                tab.saved_text = ""
                tab.dirty = True
                tab.suggested_title = item.get("title") or "交接文档.txt"
                tab.extra = {"incoming": item.get("manifest")}
                self.tabs.append(tab)
                self.selection = tab.id
                last = tab
            elif item["kind"] == "pdf":
                inbox = self.data_dir / "Handoff" / "Incoming"
                inbox.mkdir(parents=True, exist_ok=True)
                target = inbox / f"{digest(item['bytes'])[:16]}-{_safe(item.get('title') or '交接.pdf')}"
                if not target.exists():
                    safe_replace(target, item["bytes"], None)
                last = self.open_path(target)
                last.extra = {"incoming": item.get("manifest")}
            elif item["kind"] == "receipt":
                self.status = f"研究导入回执：{item.get('status')}"
            elif item["kind"] == "reference":
                self.status = "交接包含原件引用。请在本机重新选择同一文件，Windows 版不会沿用对方的访问授权。"
                self.error = self.status
        self._checkpoint()
        if last is None:
            raise AppError(self.error or "交接包没有可打开的文档。", "handoff")
        return last

    def export_research(self, tab_id: str, directory: Path, target_record: str | None = None) -> dict:
        if self.handoff is None:
            raise AppError("交接发送记录无法读取，已停止导出。", "handoff")
        tab = self._tab(tab_id)
        if tab.kind in TEXT_KINDS:
            content = tab.text.encode("utf-8")
            filename = (tab.path.stem if tab.path else "文档") + (".md" if tab.kind == "markdown" else ".txt")
            uti = "text/markdown" if tab.kind == "markdown" else "text/plain"
            if tab.kind == "latex":
                filename += ".tex.txt" if not filename.endswith(".txt") else ""
                if not filename.endswith(".txt"):
                    filename = filename + ".txt"
                filename = (tab.path.stem if tab.path else "文档") + ".tex.txt"
                uti = "text/plain"
        elif tab.kind == "pdf" and tab.binary is not None:
            content = tab.binary
            filename = tab.title if tab.title.endswith(".pdf") else tab.title + ".pdf"
            uti = "application/pdf"
        else:
            raise AppError("当前格式不能作为研究导入副本。请改用文本或 PDF。", "handoff")
        package = directory / f"{uuid.uuid4().hex}.gaoaction"
        return self.handoff.export_research(package, filename, content, uti, target_record)

    def update_settings(self, payload: dict) -> dict:
        if not self.settings_guard.readable:
            raise AppError(self.settings_guard.error or "设置无法读取，已保留原文件。", "settings")
        appearance = payload.get("appearance", self.settings.get("appearance"))
        engine = payload.get("latexEngine", self.settings.get("latexEngine"))
        if appearance not in {"system", "light", "dark"} or engine not in {"auto", "tectonic", "xelatex", "pdflatex", "lualatex"}:
            raise AppError("设置值无效。", "settings")
        self.settings = {"appearance": appearance, "latexEngine": engine}
        stored = dict(self.settings_guard.data or {}) if isinstance(self.settings_guard.data, dict) else {}
        stored.update(self.settings)
        self.settings_guard.save(stored)
        return self.settings

    def external_open(self, path: Path) -> None:
        if os.name == "nt":
            os.startfile(path)  # type: ignore[attr-defined]
            return
        command = ["open", str(path)] if sys.platform == "darwin" else ["xdg-open", str(path)]
        subprocess.Popen(command, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

    def media(self, tab_id: str, relative: str) -> tuple[bytes, str]:
        tab = self._tab(tab_id)
        if tab.path is None:
            raise AppError("未保存的文档没有可引用的本地图片。", "media")
        root = tab.path.parent.resolve()
        target = (root / relative).resolve()
        if not inside(target, root) or not target.is_file() or target.is_symlink():
            raise AppError("图片路径超出文档目录。", "media")
        mime = "image/svg+xml" if target.suffix.lower() == ".svg" else "application/octet-stream"
        if target.suffix.lower() in {".png"}:
            mime = "image/png"
        elif target.suffix.lower() in {".jpg", ".jpeg"}:
            mime = "image/jpeg"
        elif target.suffix.lower() == ".gif":
            mime = "image/gif"
        elif target.suffix.lower() == ".webp":
            mime = "image/webp"
        return target.read_bytes(), mime

    def file_bytes(self, tab_id: str) -> tuple[bytes, str]:
        tab = self._tab(tab_id)
        if tab.kind == "pdf" and tab.binary is not None:
            return tab.binary, "application/pdf"
        if tab.kind == "image" and tab.binary is not None:
            return tab.binary, "application/octet-stream"
        raise AppError("没有可预览的二进制内容。", "media")

    def export_office_recovery(self, tab_id: str, path: Path) -> Path:
        tab = self._tab(tab_id)
        recovery = (tab.preview or {}).get("recovery") or {}
        source = recovery.get("path")
        if not source:
            raise AppError("没有可导出的 Office 恢复副本。", "recovery")
        if path.exists():
            raise AppError("导出目标已存在，且不能覆盖原件。", "export")
        if tab.path and same_file(path, tab.path):
            raise AppError("不能把恢复副本覆盖到原件。", "export")
        data = Path(source).read_bytes()
        if recovery.get("documentDigest") and digest(data) != recovery["documentDigest"]:
            raise AppError("Office 恢复草稿校验失败。已有草稿已保留，不会导出损坏内容。", "recovery")
        safe_replace(path, data, None)
        return path

    def engine_status(self) -> dict:
        return {name: shutil.which(name) is not None for name in ("tectonic", "xelatex", "pdflatex", "lualatex", "synctex")}

    def dirty_count(self) -> int:
        return sum(1 for tab in self.tabs if tab.dirty)

    def _engine(self) -> tuple[str, Path]:
        choice = self.settings.get("latexEngine") or "auto"
        order = ["tectonic", "xelatex", "pdflatex", "lualatex"] if choice == "auto" else [choice]
        for name in order:
            found = shutil.which(name)
            if found:
                return name, Path(found)
        raise AppError("本机没有找到 Tectonic、XeLaTeX、pdfLaTeX 或 LuaLaTeX。Windows 版不附带编译器和宏包缓存，也不会联网下载。", "latex")

    def _tab(self, tab_id: str) -> Tab:
        for tab in self.tabs:
            if tab.id == tab_id:
                return tab
        raise AppError("标签不存在。", "missing")

    def _tab_summary(self, tab: Tab) -> dict:
        return {
            "id": tab.id,
            "kind": tab.kind,
            "title": tab.title,
            "path": str(tab.path) if tab.path else "",
            "dirty": tab.dirty,
            "restored": tab.restored,
            "lossy": tab.lossy,
            "encoding": tab.encoding,
            "text": tab.text if tab.kind in TEXT_KINDS or tab.kind == "richText" else "",
            "html": tab.html if tab.kind == "richText" else "",
            "message": tab.message,
            "preview": tab.preview if tab.kind not in TEXT_KINDS else tab.preview,
            "canSave": tab.kind in TEXT_KINDS | {"pdf", "richText"},
        }

    def _remember(self, path: Path) -> None:
        text = str(path)
        self.recent = [item for item in self.recent if item != text]
        self.recent.insert(0, text)
        self.recent = self.recent[:40]
        self._persist_state()

    def _load_settings(self) -> None:
        if not self.settings_guard.readable:
            self.error = self.settings_guard.error or "设置无法读取，已保留原文件。"
            return
        if isinstance(self.settings_guard.data, dict):
            for key in ("appearance", "latexEngine"):
                if key in self.settings_guard.data:
                    self.settings[key] = self.settings_guard.data[key]

    def _load_state(self) -> None:
        if not self.state_guard.readable:
            self.error = self.state_guard.error or "工作区记录无法读取，已保留原文件。"
            return
        data = self.state_guard.data
        if not isinstance(data, dict):
            return
        recent = data.get("recent")
        if isinstance(recent, list):
            self.recent = [item for item in recent if isinstance(item, str)][:40]
        folder = data.get("folder")
        if isinstance(folder, str) and folder and Path(folder).is_dir():
            self.folder = Path(folder)

    def _persist_state(self) -> None:
        if not self.state_guard.readable:
            self.error = self.state_guard.error or "工作区记录无法读取，已保留原文件。"
            return
        data = dict(self.state_guard.data or {}) if isinstance(self.state_guard.data, dict) else {}
        data["recent"] = self.recent
        data["folder"] = str(self.folder) if self.folder else None
        try:
            self.state_guard.save(data)
        except AppError as exc:
            self.error = exc.message

    def _load_recovery(self) -> None:
        if not self.recovery_guard.exists:
            return
        if not self.recovery_guard.readable or not isinstance(self.recovery_guard.data, list):
            self.error = self.recovery_guard.error or "恢复草稿无法读取，已保留原文件。"
            self.recovery_guard.readable = False
            return
        for item in self.recovery_guard.data:
            if not isinstance(item, dict):
                self.recovery_guard.readable = False
                self.error = "恢复草稿无法读取，已保留原文件。"
                self.tabs.clear()
                return
            kind = item.get("kind") if item.get("kind") in TEXT_KINDS else "text"
            tab = Tab(kind, str(item.get("text") or ""))
            if item.get("id"):
                tab.id = str(item["id"])
            raw_path = item.get("path")
            tab.path = Path(raw_path) if isinstance(raw_path, str) and raw_path else None
            tab.digest = item.get("digest")
            tab.saved_text = ""
            tab.dirty = True
            tab.restored = True
            tab.suggested_title = item.get("suggestedTitle")
            code = item.get("encoding")
            tab.encoding_code = code if isinstance(code, int) else 4
            tab.encoding = item.get("encodingName") or {4: "utf-8", 10: "utf-16"}.get(tab.encoding_code, "utf-8")
            tab.extra = {key: value for key, value in item.items() if key not in {"id", "path", "kind", "text", "digest", "encoding", "encodingName", "suggestedTitle"}}
            self.tabs.append(tab)
        if self.tabs:
            self.selection = self.tabs[0].id
            self.status = f"已恢复 {len(self.tabs)} 个未保存文本"

    def _checkpoint(self) -> None:
        if not self.recovery_guard.readable:
            self.error = self.recovery_guard.error or "恢复草稿不可读取，已保留原记录。"
            return
        items = []
        for tab in self.tabs:
            if tab.kind not in TEXT_KINDS or not tab.dirty:
                continue
            item = dict(tab.extra)
            item.update({
                "id": tab.id,
                "path": str(tab.path) if tab.path else None,
                "kind": tab.kind,
                "text": tab.text,
                "digest": tab.digest,
                "encoding": tab.encoding_code,
                "encodingName": tab.encoding,
                "suggestedTitle": tab.suggested_title,
            })
            items.append(item)
        try:
            self.recovery_guard.save(items)
        except AppError as exc:
            self.error = f"草稿恢复文件保存失败：{exc.message}"

    def _restore_pdf(self, tab: Tab) -> None:
        directory = self._pdf_dir(tab.path)
        mac = self.data_dir / "Recovery" / "PDF" / digest(str(tab.path).encode())
        for candidate, owned in ((directory, True), (mac, False)):
            draft = candidate / "draft.pdf"
            meta = candidate / "origin.json"
            if not draft.exists() and not meta.exists():
                continue
            try:
                payload = GuardedJSON(meta)
                if not payload.readable or not isinstance(payload.data, dict):
                    raise AppError("恢复草稿无法读取")
                if payload.data.get("digest") != tab.digest or payload.data.get("path") not in {str(tab.path), None}:
                    tab.message = "原文件已变化；旧 PDF 恢复草稿已保留，可另存恢复副本。"
                    continue
                data = draft.read_bytes()
                inspect(data)
            except (AppError, OSError):
                tab.message = "PDF 恢复草稿无法读取，原件及恢复资料已保留。"
                if owned:
                    tab.extra["pdfRecoveryBlocked"] = True
                continue
            if owned or not tab.dirty:
                tab.binary = data
                tab.preview = inspect(data)
                tab.dirty = True
                tab.message = "已恢复上次未保存的 PDF 修改 · 请检查后保存" if owned else "已读入 macOS 留下的 PDF 恢复稿，未删除原恢复目录。"
            return

    def _persist_pdf(self, tab: Tab) -> None:
        if tab.path is None or tab.binary is None or tab.extra.get("pdfRecoveryBlocked"):
            return
        directory = self._pdf_dir(tab.path)
        meta_guard = GuardedJSON(directory / "origin.json")
        if not meta_guard.readable:
            tab.message = "PDF 恢复草稿无法读取，未覆盖原恢复资料。"
            tab.extra["pdfRecoveryBlocked"] = True
            return
        try:
            safe_replace(directory / "draft.pdf", tab.binary, None)
            meta = dict(meta_guard.data or {}) if isinstance(meta_guard.data, dict) else {}
            meta.update({"path": str(tab.path), "digest": tab.digest, "writer": WRITER})
            meta_guard.save(meta)
        except AppError as exc:
            tab.message = f"恢复草稿未能写入，请及时保存：{exc.message}"

    def _clear_pdf_recovery(self, tab: Tab) -> None:
        if tab.extra.get("pdfRecoveryBlocked"):
            return
        directory = self._pdf_dir(tab.path) if tab.path else None
        if directory and directory.exists():
            shutil.rmtree(directory, ignore_errors=True)

    def _pdf_dir(self, path: Path | None) -> Path:
        key = digest(str(path or "").encode())
        return self.data_dir / "Recovery" / "WindowsPDF" / key

    def _restore_rtf(self, tab: Tab) -> None:
        path = self._rtf_path(tab.path)
        mac = self.data_dir / "Recovery" / "RTF" / (digest(str(tab.path).encode())[:24] + ".json")
        if mac.exists():
            tab.message = "检测到 macOS 的 RTF 恢复稿，Windows 版不会覆盖它。"
        guard = GuardedJSON(path)
        if not guard.exists:
            return
        if not guard.readable or not isinstance(guard.data, dict) or guard.data.get("writer") != WRITER:
            tab.message = "RTF 恢复草稿无法读取或不是 Windows 版写入的，已保留并禁止覆盖。"
            tab.extra["rtfRecoveryBlocked"] = True
            return
        record = guard.data
        if record.get("sourcePath") != str(tab.path) or record.get("baseDigest") != tab.digest:
            tab.message = "原件在草稿生成后已变化，已打开当前原件并保留旧恢复草稿。"
            return
        tab.html = record.get("html") or ""
        tab.text = record.get("plain") or ""
        tab.dirty = True
        tab.restored = True
        tab.message = "已恢复上次未保存的 RTF 修改。"

    def _persist_rtf(self, tab: Tab) -> None:
        if tab.path is None or tab.extra.get("rtfRecoveryBlocked"):
            return
        guard = GuardedJSON(self._rtf_path(tab.path))
        if not guard.readable:
            tab.extra["rtfRecoveryBlocked"] = True
            tab.message = "RTF 恢复草稿无法读取，已有草稿保持原样。"
            return
        record = {
            "version": 1,
            "writer": WRITER,
            "sourcePath": str(tab.path),
            "baseDigest": tab.digest,
            "html": tab.html,
            "plain": tab.text,
        }
        try:
            guard.save(record)
        except AppError as exc:
            tab.message = f"恢复草稿写入失败，已有草稿保持原样。{exc.message}"

    def _clear_rtf_recovery(self, tab: Tab) -> None:
        if tab.extra.get("rtfRecoveryBlocked") or tab.path is None:
            return
        path = self._rtf_path(tab.path)
        if path.exists():
            path.unlink()

    def _rtf_path(self, path: Path | None) -> Path:
        key = digest(str(path or "").encode())[:24]
        return self.data_dir / "Recovery" / "WindowsRTF" / f"{key}.json"

    def _office_recovery(self, path: Path, current: bytes) -> dict:
        key = digest(str(path).encode())
        draft = self.data_dir / "Recovery" / "Office" / f"{key}{path.suffix.lower()}"
        meta = Path(str(draft) + ".json")
        if not draft.exists() and not meta.exists():
            return {"present": False}
        guard = GuardedJSON(meta)
        if not guard.readable or not isinstance(guard.data, dict):
            return {"present": True, "readable": False, "message": "Office 恢复草稿校验失败。已有草稿已保留，不会以空白内容覆盖。"}
        record = guard.data
        try:
            data = draft.read_bytes()
            if record.get("documentDigest") and digest(data) != record.get("documentDigest"):
                raise AppError("摘要不一致")
            if record.get("originalPath") and record.get("originalPath") != str(path):
                raise AppError("路径不一致")
        except (AppError, OSError):
            return {"present": True, "readable": False, "message": "Office 恢复草稿校验失败。已有草稿已保留，不会以空白内容覆盖。"}
        preview = None
        try:
            preview = read_document(data, path.suffix.lstrip("."))
        except AppError as exc:
            preview = {"message": exc.message}
        return {
            "present": True,
            "readable": True,
            "path": str(draft),
            "documentDigest": digest(data),
            "originalChanged": digest(current) != record.get("originalDigest"),
            "preview": preview,
            "message": "旧版未保存草稿已保留。可以只读查看并导出为新文件，不会覆盖原件，也不会删除草稿。",
        }


def _decode_text(data: bytes) -> tuple[str, str, int]:
    if data.startswith(b"\xef\xbb\xbf"):
        return data.decode("utf-8-sig"), "utf-8-sig", 4
    try:
        return data.decode("utf-8"), "utf-8", 4
    except UnicodeDecodeError:
        pass
    if data.startswith((b"\xff\xfe", b"\xfe\xff")):
        return data.decode("utf-16"), "utf-16", 10
    try:
        return data.decode("gb18030"), "gb18030", 2147483649
    except UnicodeDecodeError as exc:
        raise AppError("无法按 UTF-8、UTF-16 或 GB18030 读取这个文本。", "encoding") from exc


def _encode_text(text: str, encoding: str) -> bytes:
    if encoding == "utf-8-sig":
        return text.encode("utf-8-sig")
    return text.encode(encoding)


def _html_escape(text: str) -> str:
    return text.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;").replace("\n", "<br>")


def _safe(name: str) -> str:
    cleaned = "".join(char for char in name if char not in "\\/\x00" and ord(char) >= 32)
    return cleaned[:80] or "交接文档.pdf"
