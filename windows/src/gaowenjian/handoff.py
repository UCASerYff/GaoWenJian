"""GaoAction V1 目录包、请求与回执。"""

from __future__ import annotations

import base64
import json
import os
import re
import stat
import tempfile
import uuid
import zipfile
from datetime import datetime, timedelta, timezone
from pathlib import Path
from urllib.parse import unquote, urlsplit
from urllib.request import url2pathname

from gaowenjian.errors import AppError
from gaowenjian.safety import GuardedJSON, digest, reject_symlink, safe_replace

BUNDLE_ID = "com.gaoseries.GaoWenJian"
TTL = timedelta(seconds=120)
MAX_ITEMS = 256
MAX_MANIFEST = 1_048_576
MAX_TEXT = 8_388_608
MAX_ITEM_BYTES = 128 * 1024 * 1024
MAX_PACKAGE_BYTES = 512 * 1024 * 1024
TEXT_UTIS = {"public.utf8-plain-text", "public.plain-text", "text/plain", "net.daringfireball.markdown", "public.markdown", "text/markdown"}
PDF_UTIS = {"com.adobe.pdf", "application/pdf"}
KNOWN_ACTIONS = {
    "capture.region", "capture.window", "capture.display", "ocr.files", "images.annotate", "images.pin",
    "text.translate", "storage.inspect", "cleanup.review", "apps.uninstall.review", "files.search",
    "files.choose", "files.reveal", "associations.manage", "documents.open", "documents.newText",
    "research.importDocuments", "portal.openSite", "portal.openWorkspace", "portal.focusSearch",
    "portal.proposeSite", "portal.prepareDownload", "windows.overview", "desktop.openSettings", "downloads.prepare",
}
BASE_KEYS = {"schemaVersion", "kind", "requestID", "sourceBundleID", "targetBundleID", "action", "createdAt", "expiresAt", "nonce", "items", "references", "parameters"}
RESULT_KEYS = {"inReplyTo", "status", "errorCode", "provenance"}
ITEM_KEYS = {"id", "relativePath", "uti", "byteCount", "sha256"}
REFERENCE_KEYS = {"id", "kind", "fileURL", "displayName", "declaredIdentity", "bundleID", "sha256"}
IDENTITY_KEYS = {"volumeUUID", "device", "inode", "byteCount", "modifiedAt"}


class HandoffBook:
    def __init__(self, root: Path):
        self.root = root
        self.root.mkdir(parents=True, exist_ok=True)
        self.journal = GuardedJSON(root / "journal.json")
        self.outgoing = GuardedJSON(root / "outgoing.json")
        self.ocr_outgoing_stamp = None
        self.ocr_returns_cache = {}
        if self.journal.exists and not self.journal.readable:
            raise AppError(self.journal.error or "交接日志损坏，已停止处理。", "handoff")
        if self.outgoing.exists and not self.outgoing.readable:
            raise AppError(self.outgoing.error or "交接发送记录损坏，已停止处理。", "handoff")
        for guard, key in ((self.journal, "entries"), (self.outgoing, "sessions")):
            if guard.exists and (not isinstance(guard.data, dict) or guard.data.get("version") != 1
                                 or not isinstance(guard.data.get(key), list)
                                 or not all(isinstance(item, dict) for item in guard.data[key])):
                raise AppError("交接记录版本或格式无效，已保留原件。", "handoff")

    def import_package(self, path: Path, now: datetime | None = None, *, remember=True,
                       expected_digest: str | None = None) -> dict:
        if not self.journal.readable or not self.outgoing.readable:
            raise AppError("交接日志或发送记录无法读取，已停止处理。", "handoff")
        now = now or datetime.now(timezone.utc)
        from gaowenjian.ocr_returns import inspect_return, is_return_path

        from_mailbox = is_return_path(path)
        if from_mailbox and expected_digest is None:
            raise AppError("请先在交接页审核 OCR 结果，再确认接收。", "reviewRequired")
        manifest, files, digest_hex = inspect_return(self, path, now) if from_mailbox else read_package(path, now=now)
        bound_ocr = (manifest["kind"] == "result" and manifest["action"] == "ocr.files"
                     and "requestManifestSHA256" in manifest["provenance"])
        if from_mailbox or bound_ocr:
            if expected_digest is None:
                raise AppError("请先在交接页审核 OCR 结果，再确认接收。", "reviewRequired")
            if digest_hex != expected_digest:
                raise AppError("交接包自审核后发生变化，请重新审核。", "changed")
        if _already(self.journal.data, manifest.get("requestID"), digest_hex):
            return {"duplicate": True, "requestID": manifest.get("requestID"), "opened": []}
        action = manifest["action"]
        opened = []
        ocr_sources = []
        ocr_items = {}
        if action == "documents.open" and manifest.get("items") and manifest.get("references"):
            raise AppError("打开文档的交接不能同时携带附件和原件引用。", "invalidActionInput")
        if action == "documents.newText" and (len(files) != 1 or manifest["references"] or manifest["items"][0]["uti"] not in TEXT_UTIS):
            raise AppError("新建文字交接必须正好包含一个文本附件。", "invalidActionInput")
        if manifest["kind"] == "result" and action == "research.importDocuments":
            self._accept_research_result(manifest)
            opened.append({"kind": "receipt", "status": manifest.get("status")})
        elif action == "documents.newText":
            text = _read_text(files[0])
            opened.append({"kind": "newText", "text": text, "title": (manifest.get("parameters") or {}).get("suggestedTitle"), "manifest": _public_manifest(manifest)})
        elif action == "documents.open" or (manifest["kind"] == "result" and action == "ocr.files"):
            if action == "ocr.files":
                from gaowenjian.ocr_handoff import result_sources, validate_result

                if validate_result(manifest, files, self.outgoing.data, self.journal.data):
                    return {"duplicate": True, "requestID": manifest["requestID"], "opened": []}
                if not files:
                    opened.append({"kind": "receipt", "action": action, "status": manifest["status"]})
                else:
                    ocr_sources = result_sources(self, manifest)
                    sources = {item["sourceItemID"]: item for item in ocr_sources}
                    ocr_items = {output["resultItemID"]: (sources[output["sourceItemID"]], output)
                                 for output in manifest["provenance"]["outputs"]}
            for item, content in zip(manifest["items"], files, strict=True):
                uti = item["uti"]
                source, output = ocr_items.get(item["id"], (None, None))
                item_manifest = _public_manifest(manifest, source, output)
                if uti in TEXT_UTIS or uti in {"public.json", "application/json", "text/json"}:
                    opened.append({"kind": "newText", "text": _read_text(content), "title": Path(item["relativePath"]).name, "manifest": item_manifest})
                elif uti in PDF_UTIS:
                    opened.append({"kind": "pdf", "bytes": content, "title": Path(item["relativePath"]).name, "manifest": item_manifest})
                else:
                    raise AppError("交接文件类型目前不能在 Windows 版打开，原文档未修改。", "handoff")
            for reference in manifest.get("references") or []:
                opened.append({"kind": "reference", "reference": reference})
        elif action == "files.choose" and manifest["kind"] == "result":
            for reference in manifest.get("references") or []:
                opened.append({"kind": "reference", "reference": reference})
        else:
            raise AppError("这个交接动作在 Windows 版不能执行。可以保留交接包，但不会改动当前文档。", "unsupported")
        record = {"requestID": manifest["requestID"], "manifestSHA256": digest_hex, "action": action}
        if action == "ocr.files":
            record["inReplyTo"] = manifest["inReplyTo"]
            record["status"] = manifest["status"]
            record["failureCount"] = len(manifest["provenance"]["exportFailures"])
            record["ocrSources"] = ocr_sources
            record["ocrOutputs"] = [
                {**ocr_items[item["id"]][1], "sha256": item["sha256"], "uti": item["uti"],
                 "name": Path(item["relativePath"]).name} for item in manifest["items"]
            ]
        if remember:
            self.finish_import(record)
        return {"duplicate": False, "requestID": manifest["requestID"], "opened": opened, "record": record}

    def finish_import(self, record: dict) -> None:
        _remember(self.journal, record)

    def incoming_pdf(self, path: Path, sha: str) -> dict | None:
        """Recover source pages only for an explicitly accepted, unchanged app-owned copy."""
        if (not self.journal.readable or not _sha(sha)
                or path.absolute().parent != self.root.absolute() / "Incoming"):
            return None
        try:
            regular_path(path)
        except (AppError, OSError):
            return None
        for record in reversed((self.journal.data or {}).get("entries", [])):
            if record.get("action") != "ocr.files":
                continue
            outputs, sources = record.get("ocrOutputs"), record.get("ocrSources")
            if not isinstance(outputs, list) or not isinstance(sources, list):
                continue
            for output in outputs:
                if (not isinstance(output, dict) or output.get("sha256") != sha
                        or not isinstance(output.get("uti"), str) or output["uti"] not in PDF_UTIS):
                    continue
                name = output.get("name")
                if not isinstance(name, str) or path.name != f"{sha[:16]}-{name[:80]}":
                    continue
                source = next((item for item in sources if isinstance(item, dict)
                               and item.get("sourceItemID") == output.get("sourceItemID")
                               and item.get("sourceSHA256") == output.get("sourceSHA256")
                               and isinstance(item.get("pages"), list)
                               and {"sourceItemID", "sourceSHA256", "name", "path", "pages"}.issubset(item)), None)
                if source is None:
                    continue
                from gaowenjian.ocr_returns import PROVIDER

                details = {"action": "ocr.files", "requestID": record.get("requestID"), "inReplyTo": record.get("inReplyTo"),
                           "sourceBundleID": PROVIDER, "status": record.get("status"), "provenance": {}}
                output_link = {key: value for key, value in output.items() if key not in {"sha256", "uti", "name"}}
                result = _public_manifest(details, source, output_link)
                result["failureCount"] = record.get("failureCount", 0)
                return result
        return None

    def resolve_reference(self, reference: dict, selected: Path, *, directory=False) -> None:
        declared = _file_url(reference["fileURL"])
        if declared is not None and selected.resolve() != declared.resolve():
            raise AppError("所选对象与交接原件不匹配，请重新复核。", "referenceMismatch")
        try:
            info = regular_path(selected, directory=directory)
        except OSError as exc:
            raise AppError("交接原件不存在或不是普通文件。", "reference") from exc
        identity = reference.get("declaredIdentity") or {}
        if identity.get("byteCount") is not None and identity["byteCount"] != info.st_size:
            raise AppError("原件大小已变化，请重新发送。", "referenceChanged")
        if identity.get("device") is not None and identity["device"] != info.st_dev:
            raise AppError("原件身份已变化，请重新发送。", "referenceChanged")
        if identity.get("inode") is not None and identity["inode"] != info.st_ino:
            raise AppError("原件身份已变化，请重新发送。", "referenceChanged")
        if identity.get("modifiedAt"):
            expected = _parse_time(identity["modifiedAt"])
            actual = datetime.fromtimestamp(info.st_mtime, timezone.utc)
            if abs((actual - expected).total_seconds()) >= 0.001:
                raise AppError("原件修改时间已变化，请重新发送。", "referenceChanged")
        if identity.get("volumeUUID") and (directory or not reference.get("sha256")):
            raise AppError("Windows 版不能核对 macOS 卷标识。请让发送方带上 SHA-256，或在本机重新选择文件后只核对该摘要。", "volume")
        if reference.get("sha256") and not directory:
            if digest(read_regular(selected, MAX_ITEM_BYTES)) != reference["sha256"]:
                raise AppError("原件内容已变化，请重新发送。", "referenceChanged")

    def export_research(self, destination: Path, filename: str, content: bytes, uti: str, target_record: str | None, now: datetime | None = None) -> dict:
        if destination.exists():
            raise AppError("导出目标已存在，请换一个新目录。失败不会删除已有目标。", "export")
        now = now or datetime.now(timezone.utc)
        request_id = str(uuid.uuid4())
        item_id = str(uuid.uuid4())
        parameters = {}
        if target_record:
            parameters["targetRecordID"] = target_record
        manifest = _request("research.importDocuments", request_id, "com.gaoseries.GaoYanJiu", parameters, now)
        safe_name = _safe_filename(filename)
        relative = "payload/" + safe_name
        manifest["items"] = [{
            "id": item_id,
            "relativePath": relative,
            "uti": uti,
            "byteCount": len(content),
            "sha256": digest(content),
        }]
        _validate(manifest, manifest["targetBundleID"], now)
        _write_package(destination, manifest, {safe_name: content})
        record = {
            "requestID": request_id,
            "action": "research.importDocuments",
            "targetBundleID": "com.gaoseries.GaoYanJiu",
            "manifestSHA256": digest((destination / "manifest.json").read_bytes()),
            "sources": [{"id": item_id, "sha256": digest(content)}],
        }
        _remember(self.outgoing, record, key="sessions")
        return {"path": str(destination), "requestID": request_id}

    def export_copy(self, directory: Path, filename: str, content: bytes, expected_digest: str | None, confirm: bool) -> Path:
        directory.mkdir(parents=True, exist_ok=True)
        target = directory / _safe_filename(filename)
        if target.exists():
            if not confirm:
                raise AppError("目标已存在。请重新确认摘要后再导出。", "export")
            current = digest(target.read_bytes())
            if expected_digest and current != expected_digest:
                raise AppError("目标内容与确认时的摘要不一致，未覆盖。", "conflict")
        safe_replace(target, content, digest(target.read_bytes()) if target.exists() else None)
        return target

    def _accept_research_result(self, manifest: dict) -> None:
        sessions = (self.outgoing.data or {}).get("sessions") if isinstance(self.outgoing.data, dict) else None
        session = next((item for item in sessions or [] if item.get("requestID") == manifest.get("inReplyTo")), None)
        if not session:
            raise AppError("没有找到对应的研究导入请求，不能把回执当成已导入。", "research")
        if manifest["sourceBundleID"] != session.get("targetBundleID") or session.get("action") != manifest["action"]:
            raise AppError("研究导入回执来源与所选目标应用不一致。", "research")
        status = manifest.get("status")
        provenance = manifest.get("provenance") or {}
        if provenance.get("requestManifestSHA256") != session.get("manifestSHA256"):
            raise AppError("研究导入回执的原请求摘要不匹配。", "research")
        workflow = "imported" if status == "completed" else status
        if provenance.get("workflowState") != workflow:
            raise AppError("研究导入回执的流程状态不一致。", "research")
        sources = provenance.get("sources")
        expected = {item["id"]: item["sha256"] for item in session.get("sources") or []}
        if not isinstance(sources, list) or len(sources) != len(expected):
            raise AppError("研究导入回执未完整覆盖所发文档。", "research")
        seen = set()
        imported = 0
        for source in sources:
            if not isinstance(source, dict):
                raise AppError("研究导入回执的来源无效。", "research")
            source_id = source.get("sourceItemID")
            if source_id in seen or expected.get(source_id) != source.get("sourceSHA256"):
                raise AppError("研究导入回执含未知或摘要不匹配的来源。", "research")
            seen.add(source_id)
            if source.get("status") == "imported":
                imported += 1
            elif source.get("status") not in {"failed", "cancelled", "pending", "unsupported"}:
                raise AppError("研究导入回执的来源状态无效。", "research")
        if seen != set(expected):
            raise AppError("研究导入回执未完整覆盖所发文档。", "research")
        consistent = (
            (status == "completed" and imported == len(sources))
            or (status == "partial" and 0 < imported < len(sources))
            or (status not in {"completed", "partial"} and imported == 0)
        )
        if not consistent:
            raise AppError("研究导入回执的整体状态与各文档状态不一致。", "research")
        if manifest.get("items") or manifest.get("references") or manifest.get("parameters"):
            raise AppError("研究导入回执不能携带文档、原件引用或请求参数。", "research")


def read_package(path: Path, *, now=None, target=BUNDLE_ID) -> tuple[dict, list[bytes], str]:
    """Read exact attachment bytes once, without extracting a zip beside the user file."""
    now = now or datetime.now(timezone.utc)
    path = path.absolute()
    try:
        if path.is_file():
            regular_path(path)
            with zipfile.ZipFile(path) as archive:
                entries = archive.infolist()
                names = {}
                if len(entries) > 1024:
                    raise AppError("交接包成员过多。", "itemLimit")
                for entry in entries:
                    name = entry.filename.rstrip("/")
                    _path_parts(name)
                    if name.casefold() in names or stat.S_ISLNK(entry.external_attr >> 16):
                        raise AppError("交接包存在不安全或重复的路径。", "invalidPath")
                    names[name.casefold()] = entry
                manifests = [entry.filename for entry in entries if entry.filename.split("/")[-1] == "manifest.json"]
                if len(manifests) != 1 or manifests[0].count("/") > 1:
                    raise AppError("交接清单缺失或重复。", "invalidManifest")
                prefix = manifests[0][:-len("manifest.json")]

                def read_member(relative: str, maximum: int) -> bytes:
                    entry = names.get((prefix + relative).casefold())
                    if entry is None or entry.is_dir() or entry.file_size > maximum:
                        raise AppError("交接附件缺失或超过限制。", "invalidItem")
                    with archive.open(entry) as stream:
                        return stream.read(maximum + 1)

                return _read_contents(read_member, now, target)
        if not path.is_dir() or path.suffix.lower() not in {".gaoaction", ".gaoresult"}:
            raise AppError("请选择 .gaoaction 交接目录，或相同结构的 zip。", "invalidPackage")
        regular_path(path, directory=True)
        return _read_contents(lambda relative, limit: read_regular(path.joinpath(*relative.split("/")), limit), now, target)
    except (OSError, zipfile.BadZipFile, RuntimeError) as exc:
        raise AppError("交接包、清单或附件无法读取。", "invalidPackage") from exc


def _read_contents(read, now: datetime, target: str) -> tuple[dict, list[bytes], str]:
    raw = read("manifest.json", MAX_MANIFEST)
    manifest = _decode_manifest(raw)
    _validate(manifest, target, now)
    files = []
    for item in manifest["items"]:
        member = "payload/" + "/".join(_components(item["relativePath"]))
        data = read(member, item["byteCount"])
        if len(data) != item["byteCount"] or digest(data) != item["sha256"]:
            raise AppError("交接附件的大小或 SHA-256 与清单不匹配。", "changed")
        files.append(data)
    return manifest, files, digest(raw)


def regular_path(path: Path, *, directory=False) -> os.stat_result:
    """Reject Windows reparse points and POSIX symlinks at every selected component."""
    for parent in reversed(path.absolute().parents):
        record = parent.lstat()
        if not stat.S_ISDIR(record.st_mode) or getattr(record, "st_file_attributes", 0) & 0x400:
            raise AppError("路径包含重解析点或链接，已停止操作。", "invalidPath")
    record = path.lstat()
    mode_ok = stat.S_ISDIR(record.st_mode) if directory else stat.S_ISREG(record.st_mode) and record.st_nlink == 1
    if not mode_ok or getattr(record, "st_file_attributes", 0) & 0x400:
        raise AppError("路径包含重解析点、链接或不受支持的对象。", "invalidPath")
    return record


def read_regular(path: Path, maximum: int) -> bytes:
    before = regular_path(path)
    if before.st_size > maximum:
        raise AppError("附件超过本机交接大小限制。", "itemLimit")
    with path.open("rb") as stream:
        opened = os.fstat(stream.fileno())
        def stamp(item):
            # Windows lstat and fstat can report creation and metadata-change times differently.
            return (item.st_dev, item.st_ino, item.st_size, item.st_mtime_ns, item.st_nlink)
        if stamp(before) != stamp(opened):
            raise AppError("文件在校验时已变化，请重试。", "changed")
        data = stream.read(maximum + 1)
        if len(data) != before.st_size or stamp(before) != stamp(os.fstat(stream.fileno())) or stamp(before) != stamp(regular_path(path)):
            raise AppError("文件在读取时已变化，请重试。", "changed")
    return data


def _components(path: str) -> list[str]:
    parts = _path_parts(path)
    if parts[0] == "payload":
        parts = parts[1:]
    if not parts:
        raise AppError("交接附件不是普通文件。", "invalidPath")
    return parts


def _path_parts(path: str) -> list[str]:
    if not isinstance(path, str) or not path or len(path) > 4096:
        raise AppError("交接附件路径不安全。", "invalidPath")
    parts = path.split("/")
    for part in parts:
        stem = part.split(".")[0].upper()
        if (not part or part[-1] in " ." or any(ord(char) < 32 or char in '\\:<>\"|?*' for char in part)
                or stem in {"CON", "PRN", "AUX", "NUL", "CONIN$", "CONOUT$"}
                or re.fullmatch(r"(COM|LPT)[1-9¹²³]", stem)):
            raise AppError("交接附件路径不安全。", "invalidPath")
    return parts


def _decode_manifest(data: bytes) -> dict:
    if len(data) > MAX_MANIFEST:
        raise AppError("交接清单超过 1 MiB。", "manifestLimit")
    try:
        manifest = json.loads(data.decode("utf-8"))
    except (UnicodeError, json.JSONDecodeError) as exc:
        raise AppError("交接清单损坏或数据类型无效。", "invalidManifest") from exc
    if not isinstance(manifest, dict):
        raise AppError("交接清单不是有效对象。", "invalidManifest")
    keys = set(manifest)
    if not BASE_KEYS.issubset(keys) or not keys.issubset(BASE_KEYS | RESULT_KEYS):
        raise AppError("交接清单缺少必要字段或包含未知字段。", "invalidManifest")
    if manifest.get("kind") == "result" and not {"inReplyTo", "status", "provenance"}.issubset(keys):
        raise AppError("交接结果缺少状态字段。", "invalidResult")
    for key, required in (("items", ITEM_KEYS), ("references", {"id", "kind", "fileURL", "displayName", "declaredIdentity"})):
        entries = manifest.get(key)
        if not isinstance(entries, list):
            raise AppError("交接项目列表无效。", "invalidManifest")
        allowed = required if key == "items" else required | {"bundleID", "sha256"}
        for entry in entries:
            if not isinstance(entry, dict) or not required.issubset(entry) or not set(entry).issubset(allowed):
                raise AppError("交接项目包含未知字段。", "invalidManifest")
            if key == "references":
                identity = entry.get("declaredIdentity")
                if not isinstance(identity, dict) or set(identity) != IDENTITY_KEYS:
                    raise AppError("原件身份字段不完整。", "invalidReference")
    return manifest


def _validate(manifest: dict, expected_target: str, now: datetime) -> None:
    if type(manifest.get("schemaVersion")) is not int or manifest["schemaVersion"] != 1:
        raise AppError("交接包版本暂不支持，原文档未修改。", "unsupportedSchema")
    if manifest.get("kind") not in {"request", "result"} or not _uuid(manifest.get("requestID")):
        raise AppError("交接包类型或请求编号无效。", "invalidManifest")
    if not _bundle(manifest.get("sourceBundleID")) or manifest.get("targetBundleID") != expected_target:
        raise AppError("交接包的目标应用不匹配。", "wrongTarget")
    if not isinstance(manifest.get("action"), str) or manifest["action"] not in KNOWN_ACTIONS:
        raise AppError("交接动作暂不支持。", "unsupportedAction")
    try:
        nonce = base64.b64decode(manifest.get("nonce") or "", validate=True)
    except Exception as exc:
        raise AppError("交接包随机标记无效。", "invalidNonce") from exc
    if len(nonce) != 32:
        raise AppError("交接包随机标记无效。", "invalidNonce")
    created = _parse_time(manifest.get("createdAt"))
    expires = _parse_time(manifest.get("expiresAt"))
    if expires <= created or expires - created > TTL or created > now or now >= expires:
        raise AppError("交接包已过期或时间无效，请重新发送。", "expired")
    if not isinstance(manifest.get("parameters"), dict):
        raise AppError("交接参数无效。", "invalidManifest")
    items = manifest.get("items") or []
    references = manifest.get("references") or []
    if len(items) > MAX_ITEMS or len(references) > MAX_ITEMS or len(items) + len(references) > MAX_ITEMS:
        raise AppError("交接文件过多，请分批发送。", "itemLimit")
    seen = set()
    paths = set()
    total = 0
    for item in items:
        if (not isinstance(item["id"], str) or not 1 <= len(item["id"]) <= 256 or item["id"] in seen
                or not _sha(item.get("sha256")) or not isinstance(item["uti"], str) or not item["uti"]):
            raise AppError("交接文件信息无效。", "invalidItem")
        seen.add(item["id"])
        relative = "/".join(_components(item["relativePath"])).casefold()
        if relative in paths:
            raise AppError("交接包存在重复附件路径。", "duplicatePath")
        paths.add(relative)
        if type(item["byteCount"]) is not int or not 0 <= item["byteCount"] <= MAX_ITEM_BYTES:
            raise AppError("交接文件信息无效。", "invalidItem")
        total += item["byteCount"]
    if total > MAX_PACKAGE_BYTES:
        raise AppError("交接文件总大小超过限制，请分批发送。", "itemLimit")
    for reference in references:
        _file_url(reference["fileURL"])
        if reference["kind"] not in ("file", "directory", "application") or not isinstance(reference["displayName"], str):
            raise AppError("原件引用格式无效。", "invalidReference")
        identity = reference["declaredIdentity"]
        if any(identity.get(key) is not None and (type(identity[key]) is not int or identity[key] < 0)
               for key in ("device", "inode", "byteCount")):
            raise AppError("原件身份无效。", "invalidReference")
        if reference.get("sha256") is not None and not _sha(reference["sha256"]):
            raise AppError("原件摘要无效。", "invalidReference")
    if manifest["kind"] == "result":
        if not _uuid(manifest.get("inReplyTo")) or manifest.get("status") not in ("pending", "completed", "partial", "cancelled", "failed", "unsupported"):
            raise AppError("交接结果缺少关联编号或状态。", "invalidResult")
        if not isinstance(manifest.get("provenance"), dict):
            raise AppError("交接结果缺少关联编号或状态。", "invalidResult")
    else:
        if any(manifest.get(key) is not None for key in ("inReplyTo", "status", "errorCode", "provenance")):
            raise AppError("请求包不能混入结果字段。", "invalidManifest")


def _request(action: str, request_id: str, target: str, parameters: dict, now: datetime) -> dict:
    return {
        "schemaVersion": 1,
        "kind": "request",
        "requestID": request_id,
        "sourceBundleID": BUNDLE_ID,
        "targetBundleID": target,
        "action": action,
        "createdAt": _stamp(now),
        "expiresAt": _stamp(now + TTL),
        "nonce": base64.b64encode(os.urandom(32)).decode("ascii"),
        "items": [],
        "references": [],
        "parameters": parameters,
    }


def _write_package(directory: Path, manifest: dict, files: dict[str, bytes]) -> None:
    try:
        regular_path(directory.parent, directory=True)
        if os.path.lexists(directory):
            raise AppError("交接目标已存在。", "conflict")
        with tempfile.TemporaryDirectory(prefix=".gaoaction-", dir=directory.parent) as parent:
            staging = Path(parent) / "package"
            payload = staging / "payload"
            payload.mkdir(parents=True)
            for name, content in files.items():
                target = payload / name
                safe_replace(target, content, None)
                if digest(read_regular(target, len(content))) != digest(content):
                    raise AppError("交接附件写入后核验失败，未保留半份交接包。", "handoff")
            raw = json.dumps(manifest, ensure_ascii=False, indent=2, sort_keys=True).encode("utf-8") + b"\n"
            safe_replace(staging / "manifest.json", raw, None)
            staging.rename(directory)
    except OSError as exc:
        raise AppError("交接包无法写入所选目录。", "handoff") from exc


def _remember(guard: GuardedJSON, record: dict, key: str = "entries") -> None:
    data = dict(guard.data or {}) if isinstance(guard.data, dict) else {}
    data.setdefault("version", 1)
    items = list(data.get(key) or [])
    items.append(record)
    data[key] = items[-500:]
    guard.save(data)


def _already(data, request_id: str, manifest_sha: str) -> bool:
    if not isinstance(data, dict):
        return False
    for item in data.get("entries") or []:
        if item.get("requestID") == request_id:
            if item.get("manifestSHA256") != manifest_sha:
                raise AppError("同一交接编号已对应不同的清单。", "handoffConflict")
            return True
    return False


def _read_text(data: bytes) -> str:
    if len(data) > MAX_TEXT or b"\x00" in data:
        raise AppError("交接正文超过限制或含无效字符，未改变当前文档。", "handoff")
    try:
        return data.decode("utf-8")
    except UnicodeError as exc:
        raise AppError("文字交接必须是有效 UTF-8 文件。", "invalidUTF8") from exc


def _public_manifest(manifest: dict, source: dict | None = None, output: dict | None = None) -> dict:
    info = {key: manifest.get(key) for key in ("action", "requestID", "inReplyTo", "status", "sourceBundleID")}
    if manifest["action"] == "ocr.files":
        info["failureCount"] = len(manifest["provenance"].get("exportFailures", []))
        if source and output:
            info.update({"sourceItemID": source["sourceItemID"], "sourceSHA256": source["sourceSHA256"],
                         "sourceName": source["name"], "sourcePath": source["path"], "pages": source["pages"],
                         "output": output})
    return info


def _file_url(value: str) -> Path | None:
    if not isinstance(value, str) or len(value) > 16384 or not value.startswith("file://"):
        raise AppError("仅接受规范化的本机原件引用。", "invalidReference")
    parsed = urlsplit(value)
    decoded = unquote(parsed.path)
    if (parsed.netloc not in {"", "localhost"} or parsed.query or parsed.fragment or not decoded.startswith("/")
            or any(part in {".", ".."} for part in decoded.split("/")) or "\\" in decoded or "\x00" in decoded):
        raise AppError("仅接受规范化的本机原件引用。", "invalidReference")
    path = Path(url2pathname(parsed.path))
    if not path.is_absolute():
        return None
    return path


def _parse_time(value: str) -> datetime:
    if not isinstance(value, str) or not value.endswith("Z"):
        raise AppError("交接包已过期或时间无效，请重新发送。", "expired")
    text = value[:-1] + "+00:00"
    try:
        parsed = datetime.fromisoformat(text)
    except ValueError as exc:
        raise AppError("交接包已过期或时间无效，请重新发送。", "expired") from exc
    if parsed.tzinfo is None:
        parsed = parsed.replace(tzinfo=timezone.utc)
    return parsed.astimezone(timezone.utc)


def _stamp(value: datetime) -> str:
    return value.astimezone(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def _uuid(value) -> bool:
    try:
        uuid.UUID(str(value))
        return True
    except (ValueError, TypeError):
        return False


def _bundle(value) -> bool:
    if not isinstance(value, str) or len(value.encode()) > 255 or "." not in value:
        return False
    return all(char.isalnum() or char in ".-" for char in value)


def _sha(value) -> bool:
    return isinstance(value, str) and len(value) == 64 and all(char in "0123456789abcdef" for char in value)


def _safe_filename(name: str) -> str:
    cleaned = "".join(char for char in name if char not in "\\/\x00" and ord(char) >= 32)
    cleaned = cleaned[:80] or "交接文档"
    if cleaned in {".", ".."}:
        return "交接文档"
    return cleaned
