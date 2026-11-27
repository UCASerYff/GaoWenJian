"""Review Windows GaoAction requests and write verified Organizer receipts."""

from __future__ import annotations

import uuid
from datetime import datetime, timezone
from pathlib import Path

from gaowenjian.errors import AppError
from gaowenjian.handoff import _already, _file_url, _request, _stamp, _write_package, read_package, regular_path
from gaowenjian.ocr_handoff import INPUTS
from gaowenjian.organizer import _path, reveal

ACTIONS = {"files.search", "files.choose", "files.reveal", "associations.manage"}
TYPES = {**INPUTS, ".txt": "public.plain-text", ".md": "net.daringfireball.markdown",
         ".tex": "org.tug.tex", ".csv": "public.comma-separated-values-text", ".json": "public.json",
         ".rtf": "public.rtf", ".html": "public.html", ".xml": "public.xml"}
EXTENSIONS = {uti: ext for ext, uti in TYPES.items()}
EXTENSIONS["public.utf8-plain-text"] = ".txt"
EXTENSIONS["public.markdown"] = ".md"


def _scope(book, refs):
    if not refs:
        return None
    if len(refs) != 1 or refs[0]["kind"] != "directory":
        raise AppError("仅接受一个用来限制范围的目录引用。", "handoff")
    path = _file_url(refs[0]["fileURL"])
    if path is None:
        raise AppError("目录引用不是 Windows 本机路径。", "scope")
    book.resolve_reference(refs[0], path, directory=True)
    return path


def _selected_reference(path: Path) -> dict:
    info = regular_path(path)
    return {
        "id": str(uuid.uuid4()), "kind": "file", "fileURL": path.as_uri(), "displayName": path.name,
        "declaredIdentity": {"device": info.st_dev, "inode": info.st_ino, "byteCount": info.st_size, "volumeUUID": None,
                             "modifiedAt": datetime.fromtimestamp(info.st_mtime, timezone.utc).isoformat().replace("+00:00", "Z")},
    }


def _matches(path: Path, allowed: list) -> bool:
    if not allowed:
        return True
    value = TYPES.get(path.suffix.lower(), "public.data")
    return any(item in {"public.item", "public.data", value}
               or (item == "public.image" and path.suffix.lower() in INPUTS and path.suffix.lower() != ".pdf")
               or (item == "public.utf8-plain-text" and value == "public.plain-text")
               or (item == "public.markdown" and value == "net.daringfireball.markdown") for item in allowed)


def review(workspace, manifest, sha):
    action = manifest["action"]
    if not workspace.handoff or manifest["kind"] != "request" or manifest["items"]:
        raise AppError("整理交接必须为无附件请求。", "handoff")
    if _already(workspace.handoff.journal.data, manifest["requestID"], sha):
        raise AppError("这份整理请求已处理。", "duplicate")
    params, refs = manifest["parameters"], manifest["references"]
    if action == "files.search":
        if set(params) != {"query"} or not isinstance(params["query"], str) or not params["query"].strip():
            raise AppError("文件查找请求必须提供非空查询。", "handoff")
        scope = _scope(workspace.handoff, refs)
        result = workspace.organizer.search({"query": params["query"]})
        items = [item for item in result["items"] if scope is None or scope in Path(item["path"]).parents]
        return {"candidates": items, "query": params["query"]}
    if action == "files.choose":
        allowed = params.get("allowedUTIs", [])
        if (set(params) - {"allowedUTIs", "multiple"} or not isinstance(allowed, list) or len(allowed) > 100
                or not all(isinstance(value, str) for value in allowed) or type(params.get("multiple", False)) is not bool):
            raise AppError("文件选择请求含无效参数。", "handoff")
        _scope(workspace.handoff, refs)
        return {"multiple": params.get("multiple", False)}
    if action == "files.reveal":
        if params or len(refs) != 1 or refs[0]["kind"] not in {"file", "directory"}:
            raise AppError("定位请求必须指定一个普通文件或目录。", "handoff")
        return {"directory": refs[0]["kind"] == "directory"}
    if action == "associations.manage":
        uti = params.get("uti", "com.adobe.pdf")
        if refs or set(params) - {"uti"} or not isinstance(uti, str) or uti not in EXTENSIONS:
            raise AppError("无法把此交接的文件类型映射到 Windows 扩展名。", "handoff")
        return {"extension": EXTENSIONS[uti]}
    raise AppError("没有这个整理动作。", "handoff")


def complete(workspace, payload: dict) -> dict:
    book = workspace.handoff
    if not book or payload.get("confirm") is not True:
        raise AppError("请先审核交接请求。", "confirmation")
    manifest, _, sha = read_package(_path(payload.get("path")))
    if sha != payload.get("sha256") or manifest["action"] not in ACTIONS:
        raise AppError("整理交接自审核后发生变化，请重新审核。", "changed")
    options = review(workspace, manifest, sha)
    action, refs = manifest["action"], manifest["references"]
    cancelled = payload.get("cancel") is True
    phase = payload.get("phase")
    if action == "associations.manage" and phase == "open" and not cancelled:
        return workspace.organizer.associations("open", options["extension"])
    folder = _path(payload.get("destination"))
    try:
        regular_path(folder, directory=True)
    except OSError as exc:
        raise AppError("无法访问回执导出目录。", "missing") from exc

    selected = []
    provenance = {"workflowState": "cancelled"}
    if not cancelled:
        if action == "files.search":
            ids = payload.get("ids")
            available = {item["id"] for item in options["candidates"]}
            if not isinstance(ids, list) or not ids or not all(isinstance(value, str) and value in available for value in ids):
                raise AppError("请勾选当前查询返回的文件。", "handoff")
            selected = [_selected_reference(workspace.organizer.open_file(identifier)) for identifier in dict.fromkeys(ids)]
        elif action == "files.choose":
            paths = payload.get("paths")
            if not isinstance(paths, list) or not 1 <= len(paths) <= (100 if options["multiple"] else 1):
                raise AppError("所选文件数量与请求不符。", "handoff")
            scope = _scope(book, refs)
            candidates = list(dict.fromkeys(_path(value) for value in paths))
            if any((scope is not None and scope not in path.parents) or not _matches(path, manifest["parameters"].get("allowedUTIs", []))
                   for path in candidates):
                raise AppError("所选文件超出请求范围或类型限制。", "handoff")
            selected = [_selected_reference(path) for path in candidates]
        elif action == "files.reveal":
            local = _path(payload.get("revealPath"))
            book.resolve_reference(refs[0], local, directory=options["directory"])
            reveal(local)
            provenance = {"workflowState": "revealed", "identityVerified": True, "revealRequestIssued": True}
        else:
            value = workspace.organizer.associations("verify", options["extension"])
            if value["status"] != "changed":
                raise AppError("默认应用尚未改变，仍等待核验。", "pending")
            provenance = {"workflowState": "changed", "readBackVerified": True,
                          "uti": manifest["parameters"].get("uti", "com.adobe.pdf")}
        if selected:
            provenance = {"workflowState": "selected", "selectionCount": len(selected), "accessRequiresReceiverVerification": True}

    identifier = str(uuid.uuid4())
    result = _request(action, identifier, manifest["sourceBundleID"], {}, datetime.now(timezone.utc))
    result.update({"kind": "result", "inReplyTo": manifest["requestID"], "status": "cancelled" if cancelled else "completed",
                   "references": selected, "provenance": provenance})
    target = folder / f"Organizer-{identifier}.gaoaction"
    _write_package(target, result, {})
    book.finish_import({"requestID": manifest["requestID"], "manifestSHA256": sha, "action": action})
    return {"path": str(target), "status": result["status"]}
