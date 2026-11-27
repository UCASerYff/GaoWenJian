"""写作、文件和便笺工作区。用户文档留在原路径，内部资料损坏时不覆盖。"""

from __future__ import annotations

import base64
import binascii
import os
import re
import shutil
import subprocess
import sys
import uuid
from pathlib import Path

from gaowenjian.csvtext import encode as encode_csv
from gaowenjian.csvtext import markdown_table, parse as parse_csv
from gaowenjian.errors import AppError
from gaowenjian.handoff import HandoffBook, regular_path
from gaowenjian.latex import complete as latex_complete
from gaowenjian.latex import parse_index, parse_log, root_directive, synctex_location
from gaowenjian.markdown import export_document, outline, render
from gaowenjian.notes import NotesStore
from gaowenjian.office import read_document
from gaowenjian.organizer import Organizer
from gaowenjian.pdfdoc import MAX_BYTES as MAX_PDF_BYTES
from gaowenjian.pdfdoc import extract, image_info, inspect, merge, plain_pdf, render_page, search, split, transform
from gaowenjian.rtf import from_html, parse as parse_rtf
from gaowenjian.safety import FileIdentity, GuardedJSON, digest, inside, read_file_snapshot, reject_symlink, safe_replace, same_file, write_document
from gaowenjian.version import VERSION_LABEL
from gaowenjian.writing import image_mime, markdown_document, print_markdown, tex_bundle_options, tex_environment, tex_executable

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
\IfFontExistsTF{Microsoft YaHei}
  {\setCJKmainfont{Microsoft YaHei}}
  {\IfFontExistsTF{SimSun}{\setCJKmainfont{SimSun}}{\setCJKmainfont{NotoSansSC-Regular.otf}}}
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
    if extension in {"md", "markdown", "mdown", "mkd"}:
        return "markdown"
    if extension in {"tex", "ltx", "bib", "sty", "cls"}:
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
    if extension in {"png", "jpg", "jpeg", "gif", "webp", "heic", "heif", "tiff", "tif", "bmp", "svg"}:
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
        self.file_identity: FileIdentity | None = None
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
        self.settings = {"appearance": "system", "latexEngine": "auto", "editorFontSize": 15, "wrapLines": True}
        self.handoff_references: dict[str, dict] = {}
        self.organizer = Organizer(self.data_dir)
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

    def open_path(self, path: Path) -> Tab | None:
        path = path.expanduser()
        if path.suffix.lower() in {".gaoaction", ".gaoresult"}:
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
        data, identity = read_file_snapshot(path, MAX_PDF_BYTES if kind == "pdf" else None)
        tab = Tab(kind, path=path)
        tab.digest = digest(data)
        tab.file_identity = identity
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
            tab.extra["pdfRequiresCopy"] = tab.preview.get("signed", False)
            if not tab.preview["encrypted"]:
                self._restore_pdf(tab)
            tab.preview = self._pdf_metadata(tab)
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

    def edit(self, tab_id: str, text: str, html: str | None = None, *, select: bool = True) -> None:
        tab = self._tab(tab_id)
        if tab.kind not in TEXT_KINDS | {"richText"}:
            raise AppError("这个文件不能按文本编辑。", "readonly")
        if "\x00" in text or len(text.encode("utf-8")) > 20_000_000:
            raise AppError("文本超过限制或含无效字符。", "text")
        tab.text = text
        if html is not None:
            tab.html = html
        tab.dirty = tab.restored or text != tab.saved_text or (tab.kind == "richText" and html is not None)
        if select:
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
        if not replacing and destination.exists():
            raise AppError("保存目标已存在。请选择新文件名，避免覆盖其他文件。", "conflict")
        if replacing and not tab.digest:
            raise AppError("恢复稿缺少原文件摘要，请另存为以保留原件。", "path")
        original_pdf_path = tab.path if tab.kind == "pdf" else None
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
            if (tab.preview or {}).get("encrypted"):
                raise AppError("加密 PDF 仅供阅读。", "encrypted")
            if replacing and tab.dirty and tab.extra.get("pdfRequiresCopy"):
                raise AppError("此 PDF 含数字签名字段。请另存副本保留已签名的原件。", "signed")
            data = tab.binary
        else:
            raise AppError("这个文件不能保存。", "readonly")
        identity = write_document(destination, data, tab.digest if replacing else None, tab.file_identity if replacing else None)
        if replacing or tab.path is None or as_copy:
            tab.path = destination
            tab.file_identity = identity
            tab.digest = digest(data)
            tab.saved_text = tab.text
            tab.binary = data if tab.kind in {"pdf", "richText"} else tab.binary
            tab.dirty = False
            tab.restored = False
            tab.lossy = False if tab.kind == "richText" else tab.lossy
            if as_copy:
                tab.encoding = "utf-8"
                tab.encoding_code = 4
        self._remember(destination)
        self._checkpoint()
        if tab.kind == "pdf":
            self._clear_pdf_recovery(tab, original_pdf_path)
            if original_pdf_path and not same_file(destination, original_pdf_path):
                tab.extra.pop("pdfRecoveryBlocked", None)
                tab.extra.pop("pdfRecoveryPath", None)
                tab.message = ""
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
            tab.preview = self._pdf_metadata(tab)
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

    def compile_latex(self, tab_id: str, main: str | None = None, engine: str | None = None) -> dict:
        tab = self._tab(tab_id)
        if tab.kind != "latex":
            raise AppError("请先打开 LaTeX 文件。", "kind")
        if tab.dirty or tab.path is None:
            raise AppError("请先保存 LaTeX 文件，再编译磁盘上的主文件。", "dirty")
        root = (Path(main) if main else root_directive(tab.text, tab.path) or tab.path).resolve()
        if not root.is_file() or root.suffix.lower() != ".tex":
            raise AppError("请选择有效的 .tex 主文件。", "latex")
        before = digest(root.read_bytes())
        engine_name, executable = self._engine(engine)
        build = self.data_dir / "Builds" / digest(str(root).encode())[:24] / uuid.uuid4().hex
        build.mkdir(parents=True)
        try:
            if engine_name == "tectonic":
                env = tex_environment(self.data_dir)
                command = [str(executable), "--only-cached", "--untrusted", "--keep-logs",
                           "--synctex", "--outdir", str(build), *tex_bundle_options(env), "./" + root.name]
            else:
                command = [str(executable), "-file-line-error", "-synctex=1", "-no-shell-escape",
                           "-interaction=nonstopmode", "-halt-on-error", "-output-directory=" + str(build),
                           "./" + root.name]
                env = None
            result = subprocess.run(command, cwd=root.parent, env=env, encoding="utf-8", errors="replace",
                                    capture_output=True, timeout=120, check=False,
                                    creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0))
            if not root.is_file() or digest(root.read_bytes()) != before:
                raise AppError("编译期间主文件发生变化，请重新编译。", "conflict")
        except subprocess.TimeoutExpired as exc:
            shutil.rmtree(build, ignore_errors=True)
            raise AppError("编译超过 120 秒，已停止。原 tex 文件未修改。", "latex") from exc
        except OSError as exc:
            shutil.rmtree(build, ignore_errors=True)
            raise AppError(f"无法启动 LaTeX 编译器：{exc}", "latex") from exc
        except AppError:
            shutil.rmtree(build, ignore_errors=True)
            raise
        log = (result.stdout or "") + ("\n" + result.stderr if result.stderr else "")
        diagnostics = parse_log(log)
        produced = build / f"{root.stem}.pdf"
        previous = tab.extra.get("compiledPdf")
        preview = dict(tab.preview or {})
        preview.update(log=log[-20000:], diagnostics=diagnostics, engine=engine_name, success=False)
        tab.preview = preview
        if result.returncode != 0 or not produced.is_file():
            if not diagnostics:
                diagnostics.append({"severity": "error", "message": "未生成 PDF，请查看编译日志。"})
            shutil.rmtree(build, ignore_errors=True)
            self.status = f"编译未完成 · {root.name}"
            return preview
        try:
            contents = produced.read_bytes()
            pages = inspect(contents)["pages"]
        except (AppError, OSError) as exc:
            shutil.rmtree(build, ignore_errors=True)
            raise AppError("编译生成的 PDF 无法读取。", "latex") from exc
        preview.update(success=True, pages=pages, source=str(root), generation=build.name)
        tab.extra.update(compiledPdf=produced, compiledRoot=root, compiledDigest=digest(contents))
        if previous and previous.parent != build and inside(previous, self.data_dir / "Builds"):
            shutil.rmtree(previous.parent, ignore_errors=True)
        self.status = f"编译成功 · {root.name}"
        return preview

    def synctex(self, tab_id: str, payload: dict) -> dict:
        tab = self._tab(tab_id)
        pdf = tab.extra.get("compiledPdf")
        root = tab.extra.get("compiledRoot")
        if not pdf or not root:
            raise AppError("请先在工作台编译 LaTeX 主文件。", "synctex")
        try:
            return synctex_location(pdf, root, payload.get("direction"), source=tab.path,
                                    line=int(payload.get("line") or 1), page=int(payload.get("page") or 1),
                                    x=float(payload.get("x") or 0), y=float(payload.get("y") or 0))
        except (TypeError, ValueError) as exc:
            raise AppError("SyncTeX 定位参数无效。", "synctex") from exc

    def latex_pdf(self, tab_id: str) -> bytes:
        tab = self._tab(tab_id)
        path = tab.extra.get("compiledPdf")
        if not path or not inside(path, self.data_dir / "Builds"):
            raise AppError("没有可读取的 LaTeX 编译结果。", "latex")
        try:
            contents = path.read_bytes()
        except OSError as exc:
            raise AppError("编译结果已不可用，请重新编译。", "latex") from exc
        if digest(contents) != tab.extra.get("compiledDigest"):
            raise AppError("编译结果已发生外部修改，请重新编译。", "conflict")
        return contents

    def latex_page(self, tab_id: str, page: int, width: int) -> bytes:
        return render_page(self.latex_pdf(tab_id), page, width)

    def export_latex(self, tab_id: str, path: Path) -> dict:
        if path.exists():
            raise AppError("导出目标已存在，请换一个新路径。", "export")
        safe_replace(path, self.latex_pdf(tab_id), None)
        return {"path": str(path)}

    def pdf_action(self, tab_id: str, operation: str, payload: dict) -> dict:
        tab = self._tab(tab_id)
        if tab.kind != "pdf" or tab.binary is None:
            raise AppError("当前文件不是 PDF。", "pdf")
        if operation == "unlock":
            if not (tab.preview or {}).get("encrypted"):
                raise AppError("当前 PDF 不需要解锁。", "pdf")
            password = payload.get("password")
            if not isinstance(password, str):
                raise AppError("请输入 PDF 密码。", "pdf")
            inspect(tab.binary, password)
            tab.extra["pdfPassword"] = password
            tab.preview = self._pdf_metadata(tab)
            return tab.preview
        if (tab.preview or {}).get("locked"):
            raise AppError("请先解锁 PDF。", "encrypted")
        if operation == "search":
            return {"matches": search(tab.binary, str(payload.get("query") or "")[:256], tab.extra.get("pdfPassword"))}
        if (tab.preview or {}).get("encrypted"):
            raise AppError("加密 PDF 仅供阅读。", "encrypted")
        if operation == "recovery-copy":
            draft = tab.extra.get("pdfRecoveryPath")
            target = Path(payload["path"])
            if draft is None:
                raise AppError("没有经核验的 PDF 恢复稿。", "recovery")
            if target.exists() or inside(target, self.data_dir):
                raise AppError("请把恢复副本另存为资料目录之外的新文件。", "export")
            restored = self._pdf_read(draft)
            inspect(restored)
            safe_replace(target, restored, None)
            return {"path": str(target)}
        if operation == "undo":
            if not tab.undo:
                raise AppError("没有可撤销的 PDF 操作。", "pdf")
            tab.redo.append(tab.binary)
            tab.binary = tab.undo.pop()
            return self._pdf_changed(tab)
        if operation == "redo":
            if not tab.redo:
                raise AppError("没有可重做的 PDF 操作。", "pdf")
            tab.undo.append(tab.binary)
            tab.binary = tab.redo.pop()
            return self._pdf_changed(tab)
        if operation == "merge":
            extra = self._pdf_read(Path(payload["path"]))
            updated = merge([tab.binary, extra])
        elif operation == "extract":
            updated = extract(tab.binary, [int(item) for item in payload.get("pages") or []])
            target = Path(payload["path"])
            if target.exists() or inside(target, self.data_dir):
                raise AppError("提取目标已存在，请换新路径。", "export")
            safe_replace(target, updated, None)
            return {"path": str(target)}
        elif operation == "split":
            directory = Path(payload["directory"])
            if inside(directory, self.data_dir) or directory.exists() and (not directory.is_dir() or any(directory.iterdir())):
                raise AppError("拆分目录必须是空目录或不存在的新目录。", "export")
            parts = split(tab.binary)
            directory.mkdir(parents=True, exist_ok=True)
            paths = []
            for index, part in enumerate(parts, start=1):
                target = directory / f"第{index:03}页.pdf"
                safe_replace(target, part, None)
                paths.append(str(target))
            return {"paths": paths}
        elif operation in {"image", "image-file"}:
            import base64
            if operation == "image-file":
                raw = self._pdf_read(Path(payload["path"]), limit=64 * 1024 * 1024)
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
        return self._pdf_changed(tab)

    def _pdf_metadata(self, tab: Tab) -> dict:
        preview = inspect(tab.binary, tab.extra.get("pdfPassword"))
        preview.update({"canUndo": bool(tab.undo), "canRedo": bool(tab.redo),
                        "canRecover": bool(tab.extra.get("pdfRecoveryPath")), "revision": digest(tab.binary)[:16]})
        return preview

    def _pdf_changed(self, tab: Tab) -> dict:
        tab.dirty = digest(tab.binary) != tab.digest
        tab.preview = self._pdf_metadata(tab)
        if tab.dirty:
            self._persist_pdf(tab)
        else:
            self._clear_pdf_recovery(tab)
        self.status = "PDF 已修改 · 待保存" if tab.dirty else "PDF 已与磁盘一致"
        return tab.preview

    def _pdf_read(self, path: Path, limit: int = MAX_PDF_BYTES) -> bytes:
        try:
            reject_symlink(path)
            if path.stat().st_size > limit:
                raise AppError("文件超过可处理大小。", "limit")
            return path.read_bytes()
        except OSError as exc:
            raise AppError(f"文件无法读取：{path.name}", "missing") from exc

    def pdf_preview_bytes(self, tab_id: str) -> tuple[bytes, str | None]:
        tab = self._tab(tab_id)
        if tab.kind != "pdf" or tab.binary is None or (tab.preview or {}).get("locked"):
            raise AppError("当前 PDF 无法预览，请先打开或解锁。", "pdf")
        return tab.binary, tab.extra.get("pdfPassword")

    def export_html(self, tab_id: str, path: Path, rendered: str | None = None) -> Path:
        tab = self._tab(tab_id)
        if tab.kind != "markdown":
            raise AppError("HTML 导出只用于 Markdown。", "export")
        if path.exists():
            raise AppError("导出目标已存在。请换一个新路径。", "export")
        document = self._markdown_document(tab, rendered)
        safe_replace(path, document.encode("utf-8"), None)
        return path

    def export_pdf(self, tab_id: str, path: Path, rendered: str | None = None) -> dict:
        tab = self._tab(tab_id)
        if tab.kind not in TEXT_KINDS:
            raise AppError("文本 PDF 导出只用于文本类文件。", "export")
        if path.exists():
            raise AppError("导出目标已存在。请换一个新路径。", "export")
        if tab.kind == "markdown":
            data, degraded = print_markdown(self._markdown_document(tab, rendered)), False
        else:
            data, degraded = plain_pdf(tab.text)
        safe_replace(path, data, None)
        return {"path": str(path), "degraded": degraded}

    def _markdown_document(self, tab: Tab, rendered: str | None) -> str:
        if rendered is None:
            return export_document(tab.title, render(tab.text))
        if not isinstance(rendered, str) or not rendered.startswith('<article class="markdown-body"'):
            raise AppError("Markdown 排版内容无效。", "export")
        return markdown_document(Path(tab.title).stem, rendered, lambda relative: self.media(tab.id, relative))

    def markdown_attachment(self, tab_id: str, name: str, url: str) -> dict:
        tab = self._tab(tab_id)
        if tab.kind != "markdown" or tab.path is None:
            raise AppError("请先保存 Markdown 文档，再插入图片。", "media")
        prefix, delimiter, encoded = url.partition(",")
        if not delimiter or not prefix.startswith("data:image/") or not prefix.endswith(";base64"):
            raise AppError("图片数据无效。", "media")
        try:
            contents = base64.b64decode(encoded, validate=True)
        except (ValueError, binascii.Error) as exc:
            raise AppError("无法读取图片数据。", "media") from exc
        if not 0 < len(contents) <= 25 * 1024 * 1024:
            raise AppError("图片数据必须小于 25 MB。", "media")
        source = Path(name)
        mime = image_mime(contents, source.name)
        if prefix[5:-7] != mime:
            raise AppError("图片扩展名与内容格式不匹配。", "media")
        stem = re.sub(r"[^\w-]", "-", source.stem)[:60] or "图片"
        assets = tab.path.parent / ".assets"
        if not inside(assets, tab.path.parent):
            raise AppError("附件目录指向文档目录外。", "media")
        assets.mkdir(exist_ok=True)
        reject_symlink(assets)
        for number in range(1000):
            suffix = f"-{number}" if number else ""
            target = assets / (stem + suffix + source.suffix.lower())
            try:
                with target.open("xb") as handle:
                    handle.write(contents)
                return {"snippet": f"![{stem}](.assets/{target.name})\n"}
            except FileExistsError:
                continue
        raise AppError("同名附件过多，请更改文件名。", "media")

    def inspect_handoff(self, path: Path) -> dict:
        from gaowenjian.handoff import read_package
        from gaowenjian.organizer_actions import ACTIONS, review

        manifest, _, sha = read_package(path)
        result = {"sha256": sha, "action": manifest["action"], "source": manifest["sourceBundleID"],
                  "status": manifest.get("status"), "kind": manifest["kind"],
                  "items": [{"name": Path(item["relativePath"]).name, "byteCount": item["byteCount"]} for item in manifest["items"]],
                  "references": [item["displayName"] for item in manifest["references"]]}
        if manifest["kind"] == "request" and manifest["action"] in ACTIONS:
            result["organizer"] = review(self, manifest, sha)
        return result

    def import_handoff(self, path: Path, expected_digest: str | None = None) -> Tab | None:
        if self.handoff is None:
            raise AppError(self.error or "交接日志无法读取，已停止处理。", "handoff")
        if not self.recovery_guard.readable:
            raise AppError("草稿恢复记录无法读取，交接文字尚未导入，请先处理现有恢复记录。", "recovery")
        result = self.handoff.import_package(path, remember=False)
        if result["duplicate"]:
            raise AppError("这份交接结果已经处理过，没有重复打开。", "duplicate")
        record = result["record"]
        if expected_digest is not None and record["manifestSHA256"] != expected_digest:
            raise AppError("交接包自审核后发生变化，请重新审核。", "changed")
        last = None
        additions = []
        references = {}
        receipt = None
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
                additions.append(tab)
                last = tab
            elif item["kind"] == "pdf":
                inbox = self.data_dir / "Handoff" / "Incoming"
                inbox.mkdir(parents=True, exist_ok=True)
                regular_path(inbox, directory=True)
                sha = digest(item["bytes"])
                target = inbox / f"{sha[:16]}-{_safe(item.get('title') or '交接.pdf')}"
                existing = next((tab for tab in self.tabs if tab.path and same_file(tab.path, target)), None)
                if existing is not None:
                    last = existing
                    continue
                tab = Tab("pdf", path=target)
                tab.preview = inspect(item["bytes"])
                tab.binary = item["bytes"]
                tab.digest = sha
                tab.extra = {"incoming": item.get("manifest")}
                if target.exists():
                    regular_path(target)
                    if digest(target.read_bytes()) != sha:
                        raise AppError("已接收的 PDF 副本发生变化，无法导入到同一位置。", "changed")
                else:
                    safe_replace(target, item["bytes"], None)
                additions.append(tab)
                last = tab
            elif item["kind"] == "receipt":
                receipt = item
            elif item["kind"] == "reference":
                references[str(uuid.uuid4())] = item["reference"]
        self.tabs.extend(additions)
        if any(tab.kind in TEXT_KINDS for tab in additions):
            try:
                self._checkpoint(strict=True)
            except AppError:
                self.tabs = [tab for tab in self.tabs if tab not in additions]
                raise
        self.handoff.finish_import(record)
        self.handoff_references.update(references)
        if last is not None:
            self.selection = last.id
        if receipt:
            label = "搞操作 OCR" if receipt.get("action") == "ocr.files" else "研究导入"
            self.status = f"{label}回执 · {receipt['status']}"
        elif references:
            self.status = "收到原件引用。请选择同一文件以核验身份。"
        elif additions:
            self.status = f"已接收 {len(additions)} 个文件"
        return last

    def handoff_state(self) -> dict:
        from gaowenjian.ocr_handoff import default_provider

        sessions = (self.handoff.outgoing.data or {}).get("sessions", []) if self.handoff else []
        provider = default_provider()
        return {"references": [{"id": key, "name": item["displayName"]} for key, item in self.handoff_references.items()],
                "provider": str(provider) if provider else "",
                "sessions": [{key: item.get(key) for key in ("requestID", "action", "expiresAt", "path")}
                             for item in reversed(sessions[-20:]) if item.get("action") == "ocr.files"]}

    def handoff_reference(self, identifier: str, path: Path) -> Tab:
        reference = self.handoff_references.get(identifier)
        if self.handoff is None or reference is None:
            raise AppError("这份原件引用已不在当前交接会话。", "missing")
        self.handoff.resolve_reference(reference, path)
        tab = self.open_path(path)
        del self.handoff_references[identifier]
        return tab

    def export_ocr(self, payload: dict) -> dict:
        from gaowenjian.ocr_handoff import export_request

        if self.handoff is None or payload.get("confirm") is not True:
            raise AppError("请确认创建用于搞操作审核的 OCR 请求。", "handoff")
        current = None
        if payload.get("currentTab"):
            tab = self._tab(payload["currentTab"])
            if tab.kind not in {"pdf", "image"} or tab.binary is None:
                raise AppError("当前标签没有可用于 OCR 的 PDF 或图像数据。", "handoff")
            current = (Path(tab.title), tab.binary)
        directory = Path(payload["directory"]) if payload.get("directory") else None
        return export_request(self.handoff, payload.get("paths") or [], payload.get("outputs") or [],
                              payload.get("languages") or [], directory, current=current)

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
        font_size = payload.get("editorFontSize", self.settings["editorFontSize"])
        wrap_lines = payload.get("wrapLines", self.settings["wrapLines"])
        if appearance not in {"system", "light", "dark"} or engine not in {"auto", "tectonic", "xelatex", "pdflatex", "lualatex"}:
            raise AppError("设置值无效。", "settings")
        if type(font_size) is not int or not 11 <= font_size <= 24 or not isinstance(wrap_lines, bool):
            raise AppError("源码字号或自动换行设置无效。", "settings")
        candidate = {"appearance": appearance, "latexEngine": engine, "editorFontSize": font_size, "wrapLines": wrap_lines}
        stored = dict(self.settings_guard.data or {}) if isinstance(self.settings_guard.data, dict) else {}
        stored.update(candidate)
        self.settings_guard.save(stored)
        self.settings = candidate
        return self.settings

    def reload_office(self, tab_id: str) -> None:
        tab = self._tab(tab_id)
        if tab.kind not in {"word", "spreadsheet", "presentation"} or not tab.path or not tab.path.is_file():
            raise AppError("找不到可重新读取的 Office 原件。", "office")
        reject_symlink(tab.path)
        data = tab.path.read_bytes()
        preview = read_document(data, tab.path.suffix)
        preview["recovery"] = self._office_recovery(tab.path, data)
        tab.binary, tab.preview, tab.digest = data, preview, digest(data)
        self.status = f"已重新读取 {tab.title}"

    def reveal(self, tab_id: str) -> None:
        tab = self._tab(tab_id)
        if not tab.path or not tab.path.is_file():
            raise AppError("当前文档还没有可显示的本机文件。", "missing")
        if os.name == "nt":
            subprocess.Popen(["explorer.exe", "/select,", str(tab.path)])
        else:
            self.external_open(tab.path.parent)

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
        reference = Path(relative)
        target = root / reference
        if reference.anchor or ":" in relative or not inside(target, root) or not target.is_file() or target.is_symlink():
            raise AppError("图片路径超出文档目录。", "media")
        if target.stat().st_size > 25 * 1024 * 1024:
            raise AppError("本地图片超过 25 MB。", "media")
        contents = target.read_bytes()
        return contents, image_mime(contents, target.name)

    def file_bytes(self, tab_id: str) -> tuple[bytes, str]:
        tab = self._tab(tab_id)
        if tab.kind == "pdf" and tab.binary is not None:
            return tab.binary, "application/pdf"
        if tab.kind == "image" and tab.binary is not None:
            ext = tab.path.suffix.lower() if tab.path else ""
            if ext in {".tif", ".tiff"}:
                import io
                from PIL import Image

                try:
                    with Image.open(io.BytesIO(tab.binary)) as image:
                        if image.width * image.height > 80_000_000:
                            raise AppError("图片超过 8000 万像素。", "image")
                        output = io.BytesIO()
                        image.thumbnail((4096, 4096))
                        image.convert("RGBA").save(output, format="PNG")
                        return output.getvalue(), "image/png"
                except (OSError, Image.DecompressionBombError) as exc:
                    raise AppError("无法解码这张 TIFF 图片。", "image") from exc
            import mimetypes

            return tab.binary, mimetypes.guess_type(tab.path.name if tab.path else "")[0] or "application/octet-stream"
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
        return {
            "tectonic": tex_executable() is not None,
            "synctex": True,
            **{name: shutil.which(name) is not None for name in ("xelatex", "pdflatex", "lualatex")},
        }

    def dirty_count(self) -> int:
        return sum(1 for tab in self.tabs if tab.dirty)

    def _engine(self, choice: str | None = None) -> tuple[str, Path]:
        choice = choice or self.settings.get("latexEngine") or "auto"
        if choice not in {"auto", "tectonic", "xelatex", "pdflatex", "lualatex"}:
            raise AppError("LaTeX 编译器选项无效。", "latex")
        order = ["tectonic", "xelatex", "pdflatex", "lualatex"] if choice == "auto" else [choice]
        for name in order:
            found = tex_executable() if name == "tectonic" else shutil.which(name)
            if found:
                return name, Path(found)
        raise AppError("本机没有找到所选的 LaTeX 编译器，工作台不会联网下载。", "latex")

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
            "canSave": tab.kind in TEXT_KINDS | {"richText"} or tab.kind == "pdf" and not (tab.preview or {}).get("encrypted"),
            "incoming": tab.extra.get("incoming"),
        }

    def _remember(self, path: Path) -> None:
        text = str(path)
        self.recent = [item for item in self.recent if item != text]
        self.recent.insert(0, text)
        self.recent = self.recent[:40]
        self._persist_state()

    def _load_settings(self) -> None:
        if not self.settings_guard.readable or (self.settings_guard.exists and not isinstance(self.settings_guard.data, dict)):
            self.settings_guard.readable = False
            self.error = self.settings_guard.error or "设置无法读取，已保留原文件。"
            return
        if isinstance(self.settings_guard.data, dict):
            for key in self.settings:
                if key in self.settings_guard.data:
                    self.settings[key] = self.settings_guard.data[key]

    def _load_state(self) -> None:
        if not self.state_guard.readable or (self.state_guard.exists and not isinstance(self.state_guard.data, dict)):
            self.state_guard.readable = False
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
            tab.file_identity = FileIdentity.from_record(item.get("windowsFileIdentity"))
            tab.saved_text = ""
            tab.dirty = True
            tab.restored = True
            tab.suggested_title = item.get("suggestedTitle")
            code = item.get("encoding")
            tab.encoding_code = code if isinstance(code, int) else 4
            tab.encoding = item.get("encodingName") or {4: "utf-8", 10: "utf-16"}.get(tab.encoding_code, "utf-8")
            tab.extra = {key: value for key, value in item.items() if key not in {"id", "path", "kind", "text", "digest", "encoding", "encodingName", "suggestedTitle", "windowsFileIdentity"}}
            self.tabs.append(tab)
        if self.tabs:
            self.selection = self.tabs[0].id
            self.status = f"已恢复 {len(self.tabs)} 个未保存文本"

    def _checkpoint(self, *, strict=False) -> None:
        if not self.recovery_guard.readable:
            self.error = self.recovery_guard.error or "恢复草稿不可读取，已保留原记录。"
            if strict:
                raise AppError(self.error, "recovery")
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
            if tab.file_identity and (identity := tab.file_identity.as_record()):
                item["windowsFileIdentity"] = identity
            items.append(item)
        try:
            self.recovery_guard.save(items)
        except AppError as exc:
            self.error = f"草稿恢复文件保存失败：{exc.message}"
            if strict:
                raise

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
                data = self._pdf_read(draft)
                if inspect(data)["encrypted"]:
                    raise AppError("恢复稿已加密。", "recovery")
                baseline = FileIdentity.from_record(payload.data.get("windowsFileIdentity")) if owned else None
                if (payload.data.get("digest") != tab.digest or payload.data.get("path") not in {str(tab.path), None}
                        or baseline is not None and baseline != tab.file_identity):
                    tab.message = "原文件已变化；旧 PDF 恢复草稿已保留，可另存恢复副本。"
                    tab.extra.setdefault("pdfRecoveryPath", draft)
                    if owned:
                        tab.extra["pdfRecoveryBlocked"] = True
                    continue
            except (AppError, OSError):
                tab.message = "PDF 恢复草稿无法读取，原件及恢复资料已保留。"
                if owned:
                    tab.extra["pdfRecoveryBlocked"] = True
                continue
            if owned or not tab.dirty:
                tab.binary = data
                tab.preview = self._pdf_metadata(tab)
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
        current_meta = meta_guard.data if isinstance(meta_guard.data, dict) else {}
        baseline = FileIdentity.from_record(current_meta.get("windowsFileIdentity"))
        if meta_guard.exists and (current_meta.get("digest") != tab.digest or current_meta.get("path") not in {str(tab.path), None}
                                  or baseline is not None and baseline != tab.file_identity):
            tab.message = "现有 PDF 恢复草稿属于不同版本，已保留。"
            tab.extra["pdfRecoveryBlocked"] = True
            return
        try:
            safe_replace(directory / "draft.pdf", tab.binary, None)
            meta = dict(current_meta)
            meta.update({"path": str(tab.path), "digest": tab.digest, "writer": WRITER})
            if tab.file_identity and (identity := tab.file_identity.as_record()):
                meta["windowsFileIdentity"] = identity
            meta_guard.save(meta)
        except AppError as exc:
            tab.message = f"恢复草稿未能写入，请及时保存：{exc.message}"

    def _clear_pdf_recovery(self, tab: Tab, path: Path | None = None) -> None:
        if tab.extra.get("pdfRecoveryBlocked"):
            return
        original = path or tab.path
        directory = self._pdf_dir(original) if original else None
        if directory and directory.is_dir() and not directory.is_symlink() and inside(directory, self.data_dir):
            try:
                for name in ("draft.pdf", "origin.json"):
                    artifact = directory / name
                    if artifact.is_file() and not artifact.is_symlink():
                        artifact.unlink()
                directory.rmdir()
            except OSError:
                pass

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
