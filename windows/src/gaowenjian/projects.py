"""Local writing sessions store document references, leaving source files and recovery data in place."""

from __future__ import annotations

import math
import os
import uuid
from pathlib import Path

from gaowenjian.errors import AppError
from gaowenjian.safety import GuardedJSON, inside, reject_symlink

MAIN_EXTENSIONS = {".md", ".markdown", ".mdown", ".mkd", ".tex", ".ltx"}
PACKAGE_EXTENSIONS = {".gaoaction", ".gaoresult"}
SCHEMA = 1


def _absolute(value):
    return isinstance(value, str) and bool(value) and "\x00" not in value and Path(value).is_absolute()


def _key(path):
    return os.path.normcase(os.path.abspath(path))


def _under_folder(path, folder):
    try:
        return os.path.commonpath((_key(path), _key(folder))) == _key(folder)
    except ValueError:
        return False


def _reading(value):
    if not isinstance(value, dict):
        raise AppError("PDF 阅读位置无效。", "project")
    result = {}
    for key in ("page", "previewPage", "readerPage"):
        if key in value:
            page = value[key]
            if type(page) is not int or not 0 <= page <= 1_000_000:
                raise AppError("PDF 页码无效。", "project")
            result[key] = page
    if "offset" in value:
        offset = value["offset"]
        if type(offset) not in (int, float) or not 0 <= offset <= 1 or not math.isfinite(offset):
            raise AppError("PDF 页内位置无效。", "project")
        result["offset"] = offset
    return result


def _valid_record(item):
    if not (isinstance(item, dict) and isinstance(item.get("id"), str) and item["id"]
            and isinstance(item.get("name"), str) and item["name"]
            and _absolute(item.get("folder")) and _absolute(item.get("main")) and isinstance(item.get("documents"), list)
            and Path(item["main"]).suffix.lower() in MAIN_EXTENSIONS and _under_folder(item["main"], item["folder"])
            and (item.get("selection") is None or _absolute(item["selection"]))
            and (item.get("selectionDraftId") is None or isinstance(item["selectionDraftId"], str))):
        return False
    for document in item["documents"]:
        if not isinstance(document, dict):
            return False
        path, draft = document.get("path"), document.get("draftId")
        if not ((_absolute(path) and draft is None) or (path is None and isinstance(draft, str) and draft)):
            return False
        try:
            _reading(document.get("reading", {}))
        except AppError:
            return False
    return True


class WritingProjects:
    def __init__(self, workspace):
        self.workspace = workspace
        self.guard = GuardedJSON(workspace.data_dir / "writing-projects.json")
        self.active = None
        self.issues = []
        self._unavailable = []
        self._carried_drafts = set()
        if self.guard.readable and self.guard.exists:
            data = self.guard.data
            if not (isinstance(data, dict) and type(data.get("schemaVersion")) is int and data["schemaVersion"] == SCHEMA
                    and isinstance(data.get("projects"), list) and all(_valid_record(item) for item in data["projects"])
                    and len({item["id"] for item in data["projects"]}) == len(data["projects"])):
                self.guard.readable = False
                self.guard.error = "项目记录不可识别，已保留原文件。"

    def snapshot(self):
        data = self.guard.data if self.guard.readable and self.guard.exists else {}
        return {"items": data.get("projects", []), "active": self.active, "lastOpened": data.get("lastOpened"),
                "blocked": self.guard.error if not self.guard.readable else "", "issues": self.issues}

    def _records(self):
        if not self.guard.readable:
            raise AppError(self.guard.error or "项目记录无法读取，已保留原文件。", "project")
        return list((self.guard.data or {}).get("projects", []))

    def _save(self, records, active):
        self.guard.save({**(self.guard.data or {}), "schemaVersion": SCHEMA, "projects": records, "lastOpened": active})

    @staticmethod
    def _find(records, project_id):
        record = next((item for item in records if item["id"] == project_id), None)
        if record is None:
            raise AppError("没有找到要打开的写作项目。", "project")
        return record

    def _safe_path(self, value):
        if not _absolute(value):
            raise AppError("请选择有效的本机文件或文件夹路径。", "project")
        path = Path(os.path.abspath(value))
        reject_symlink(path)
        if inside(path, self.workspace.data_dir):
            raise AppError("项目文件不能位于应用资料目录中。", "project")
        return path

    def _configuration(self, payload, previous):
        name = payload.get("name")
        if not isinstance(name, str) or not name.strip() or "\x00" in name or len(name.strip()) > 120:
            raise AppError("请输入不超过 120 个字符的项目名称。", "project")
        folder = self._safe_path(payload.get("folder"))
        main = self._safe_path(payload.get("main"))
        if not folder.is_dir():
            raise AppError("项目目录不存在或无法读取。", "project")
        if not _under_folder(main, folder) or not inside(main, folder) or main.suffix.lower() not in MAIN_EXTENSIONS:
            raise AppError("请选择项目目录内的 Markdown 或 LaTeX 主文件。", "project")
        if not main.is_file() and (not previous or _key(previous["main"]) != _key(main)):
            raise AppError("主文件不存在。", "project")
        return {"name": name.strip(), "folder": str(folder), "main": str(main)}

    def _capture(self, record, state):
        if not isinstance(state, dict):
            raise AppError("项目阅读位置无效。", "project")
        previous = {_key(item["path"]): item for item in record.get("documents", []) if item.get("path")}
        documents = []
        seen = set()
        active_path = None
        active_draft = None
        for tab in self.workspace.tabs:
            if tab.id in self._carried_drafts and (not tab.path or _key(tab.path) not in previous):
                continue
            if tab.path and tab.path.suffix.lower() not in PACKAGE_EXTENSIONS:
                key = _key(tab.path)
                if key in seen:
                    continue
                seen.add(key)
                position = {**previous.get(key, {}).get("reading", {}), **tab.project_reading, **_reading(state.get(tab.id, {}))}
                documents.append({"path": str(Path(os.path.abspath(tab.path))), **({"reading": position} if position else {})})
                if tab.id == self.workspace.selection:
                    active_path = documents[-1]["path"]
            elif not tab.path and tab.dirty:
                documents.append({"draftId": tab.id})
                if tab.id == self.workspace.selection:
                    active_draft = tab.id
        for document in self._unavailable:
            if document.get("path") and _key(document["path"]) not in seen:
                seen.add(_key(document["path"]))
                documents.append(document)
        if _key(record["main"]) not in seen:
            documents.insert(0, {"path": record["main"]})
        return {**record, "documents": documents, "selection": active_path, "selectionDraftId": active_draft}

    def save(self, payload):
        records = self._records()
        project_id = payload.get("id")
        record = self._find(records, project_id) if project_id else {"id": str(uuid.uuid4())}
        config = self._configuration(payload, record if project_id else None)
        current_reading = payload.get("reading", {})
        # An unavailable file belongs only to the session that tried to reopen it.
        unavailable = self._unavailable
        if self.active != record["id"]:
            self._unavailable = []
        try:
            updated = self._capture({**record, **config}, current_reading)
            self._save([updated, *(item for item in records if item["id"] != record["id"])], updated["id"])
        except (AppError, OSError, ValueError):
            self._unavailable = unavailable
            raise
        self.active = updated["id"]
        if not self._unavailable:
            self.issues = []
        self.workspace.folder = Path(updated["folder"])
        self.workspace._persist_state()
        self.workspace.status = f"已保存项目会话 · {updated['name']}"
        return {"id": self.active}

    def checkpoint(self, reading):
        if self.active is not None:
            records = self._records()
            current = self._find(records, self.active)
            updated = self._capture(current, reading)
            if updated != current:
                records[records.index(current)] = updated
                self._save(records, self.active)
        return {"id": self.active}

    def reader_page(self, tab_id, page):
        tab = self.workspace._tab(tab_id)
        if tab.kind != "latex":
            raise AppError("当前文档没有 LaTeX 阅读窗口。", "project")
        tab.project_reading.update(_reading({"readerPage": page}))
        return {"saved": True}

    def restore(self, payload):
        mode = payload.get("drafts", "require-saved")
        if mode not in {"require-saved", "keep"}:
            raise AppError("未保存草稿的处理方式无效。", "project")
        workspace = self.workspace
        dirty = [tab for tab in workspace.tabs if tab.dirty]
        if dirty and mode != "keep":
            raise AppError("有未保存的文档。请先保存，或保留草稿后重试。", "dirty")
        records = self._records()
        record = self._find(records, payload.get("id"))
        if self.active:
            current = self._find(records, self.active)
            updated = self._capture(current, payload.get("reading", {}))
            records[records.index(current)] = updated
            if current is record:
                record = updated
        self._save(records, record["id"])

        issues, reopened, unavailable = [], [], []
        folder = None
        try:
            folder = self._safe_path(record["folder"])
            if not folder.is_dir():
                raise AppError("项目目录不存在或无法读取。", "project")
        except (AppError, OSError) as exc:
            folder = None
            issues.append({"path": record["folder"], "message": str(exc)})
        open_by_path = {_key(tab.path): tab for tab in workspace.tabs if tab.path}
        open_drafts = {tab.id: tab for tab in dirty}
        documents = record["documents"]
        for document in documents:
            if draft_id := document.get("draftId"):
                if draft_id in open_drafts:
                    reopened.append(open_drafts[draft_id])
                elif not workspace.recovery_guard.readable:
                    issues.append({"path": "未命名草稿", "message": "恢复记录暂时无法读取。"})
                continue
            path_text = document["path"]
            key = _key(path_text)
            tab = open_by_path.get(key)
            try:
                path = self._safe_path(path_text)
                if not path.is_file() or path.suffix.lower() in PACKAGE_EXTENSIONS:
                    raise AppError("文件不存在或不可作为项目文档打开。", "project")
                if tab is None:
                    tab = workspace.open_path(path)
            except (AppError, OSError) as exc:
                issues.append({"path": path_text, "message": str(exc)})
                unavailable.append(document)
                if not tab or not tab.dirty:
                    continue
            if tab and tab not in reopened:
                tab.project_reading = _reading(document.get("reading", {}))
                reopened.append(tab)
        carried = [tab for tab in dirty if tab not in reopened]
        self._carried_drafts = {tab.id for tab in carried}
        workspace.tabs[:] = reopened + carried
        selected = next((tab for tab in reopened if tab.id == record.get("selectionDraftId")), None)
        if selected is None:
            selected = next((tab for wanted in [record.get("selection"), record["main"]] if wanted
                             for tab in reopened if tab.path and _key(tab.path) == _key(wanted)), None)
        workspace.selection = selected.id if selected else workspace.tabs[0].id if workspace.tabs else None
        workspace.folder = folder
        workspace._persist_state()
        self.active, self.issues, self._unavailable = record["id"], issues, unavailable
        workspace.status = f"已打开项目 · {record['name']}"
        return {"id": self.active, "issues": issues, "keptDrafts": len(dirty)}
