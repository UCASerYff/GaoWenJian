"""GaoAction V1 目录包。不注册 URL 协议，也不代替其他搞系列应用执行动作。"""

from __future__ import annotations

import base64
import json
import os
import shutil
import uuid
import zipfile
from datetime import datetime, timedelta, timezone
from pathlib import Path

from gaowenjian.errors import AppError
from gaowenjian.safety import GuardedJSON, digest, reject_symlink, safe_replace

BUNDLE_ID = "com.gaoseries.GaoWenJian"
TTL = timedelta(seconds=120)
MAX_ITEMS = 256
MAX_MANIFEST = 1_048_576
MAX_TEXT = 8_388_608
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
        if self.journal.exists and not self.journal.readable:
            raise AppError(self.journal.error or "交接日志损坏，已停止处理。", "handoff")
        if self.outgoing.exists and not self.outgoing.readable:
            raise AppError(self.outgoing.error or "交接发送记录损坏，已停止处理。", "handoff")

    def import_package(self, path: Path, now: datetime | None = None) -> dict:
        if not self.journal.readable or not self.outgoing.readable:
            raise AppError("交接日志或发送记录无法读取，已停止处理。", "handoff")
        now = now or datetime.now(timezone.utc)
        manifest, files = _read_package(path)
        _validate(manifest, BUNDLE_ID, now)
        digest_hex = digest(_manifest_bytes(path))
        if _already(self.journal.data, manifest.get("requestID"), digest_hex):
            return {"duplicate": True, "requestID": manifest.get("requestID"), "opened": []}
        action = manifest["action"]
        opened = []
        if action == "documents.open" and manifest.get("items") and manifest.get("references"):
            raise AppError("打开文档的交接不能同时携带附件和原件引用。", "invalidActionInput")
        if action == "documents.newText" and len(files) != 1:
            raise AppError("新建文字交接必须正好包含一个文本附件。", "invalidActionInput")
        if manifest["kind"] == "result" and action == "research.importDocuments":
            self._accept_research_result(manifest)
            opened.append({"kind": "receipt", "status": manifest.get("status")})
        elif action == "documents.newText":
            text = _read_text(files[0])
            opened.append({"kind": "newText", "text": text, "title": (manifest.get("parameters") or {}).get("suggestedTitle"), "manifest": _public_manifest(manifest)})
        elif action == "documents.open" or (manifest["kind"] == "result" and action == "ocr.files"):
            for item, file_path in zip(manifest.get("items") or [], files):
                uti = item["uti"]
                if uti in TEXT_UTIS or uti in {"application/json", "text/json"}:
                    opened.append({"kind": "newText", "text": _read_text(file_path), "title": Path(item["relativePath"]).name, "manifest": _public_manifest(manifest)})
                elif uti in PDF_UTIS:
                    opened.append({"kind": "pdf", "bytes": file_path.read_bytes(), "title": Path(item["relativePath"]).name, "manifest": _public_manifest(manifest)})
                else:
                    raise AppError("交接文件类型目前不能在 Windows 版打开，原文档未修改。", "handoff")
            for reference in manifest.get("references") or []:
                opened.append({"kind": "reference", "reference": reference})
        elif action == "files.choose" and manifest["kind"] == "result":
            for reference in manifest.get("references") or []:
                opened.append({"kind": "reference", "reference": reference})
        else:
            raise AppError("这个交接动作在 Windows 版不能执行。可以保留交接包，但不会改动当前文档。", "unsupported")
        _remember(self.journal, {"requestID": manifest["requestID"], "manifestSHA256": digest_hex, "action": action})
        if files:
            hold = files[0].parent
            if hold.name.startswith(".handoff-files-"):
                shutil.rmtree(hold, ignore_errors=True)
        return {"duplicate": False, "requestID": manifest["requestID"], "opened": opened}

    def resolve_reference(self, reference: dict, selected: Path) -> None:
        declared = _file_url(reference["fileURL"])
        if declared is not None and selected.resolve() != declared.resolve() and os.name != "nt":
            raise AppError("所选对象与交接原件不匹配，请重新复核。", "referenceMismatch")
        reject_symlink(selected)
        if not selected.is_file():
            raise AppError("交接原件不存在或不是普通文件。", "reference")
        stat = selected.stat()
        identity = reference.get("declaredIdentity") or {}
        if identity.get("byteCount") is not None and int(identity["byteCount"]) != stat.st_size:
            raise AppError("原件大小已变化，请重新发送。", "referenceChanged")
        if identity.get("device") is not None and int(identity["device"]) != int(stat.st_dev):
            raise AppError("原件身份已变化，请重新发送。", "referenceChanged")
        if identity.get("inode") is not None and int(identity["inode"]) != int(stat.st_ino):
            raise AppError("原件身份已变化，请重新发送。", "referenceChanged")
        if identity.get("modifiedAt"):
            expected = _parse_time(identity["modifiedAt"])
            actual = datetime.fromtimestamp(stat.st_mtime, timezone.utc)
            if abs((actual - expected).total_seconds()) >= 0.001:
                raise AppError("原件修改时间已变化，请重新发送。", "referenceChanged")
        if identity.get("volumeUUID"):
            raise AppError("Windows 版不能核对 macOS 卷标识。请让发送方带上 SHA-256，或在本机重新选择文件后只核对该摘要。", "volume")
        if reference.get("sha256"):
            if digest(selected.read_bytes()) != reference["sha256"]:
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


def _read_package(path: Path) -> tuple[dict, list[Path]]:
    if path.is_file() and zipfile.is_zipfile(path):
        return _read_zip(path)
    if not path.is_dir() or path.suffix.lower() != ".gaoaction":
        raise AppError("请选择 .gaoaction 交接目录，或相同结构的 zip。", "invalidPackage")
    manifest_path = path / "manifest.json"
    reject_symlink(manifest_path)
    manifest = _decode_manifest(manifest_path.read_bytes())
    files = []
    for item in manifest.get("items") or []:
        files.append(_payload_file(path, item["relativePath"]))
    return manifest, files


def _read_zip(path: Path) -> tuple[dict, list[Path]]:
    staging = path.parent / f".handoff-{uuid.uuid4().hex}"
    try:
        with zipfile.ZipFile(path) as archive:
            for info in archive.infolist():
                name = info.filename.replace("\\", "/")
                if name.startswith("/") or ".." in name.split("/"):
                    raise AppError("交接包路径不安全。", "invalidPath")
            archive.extractall(staging)
        root = staging
        if not (root / "manifest.json").exists():
            children = [item for item in root.iterdir()]
            if len(children) == 1 and (children[0] / "manifest.json").exists():
                root = children[0]
        manifest, files = _read_package_dir(root)
        copied = []
        hold = path.parent / f".handoff-files-{uuid.uuid4().hex}"
        hold.mkdir()
        for file_path in files:
            target = hold / file_path.name
            shutil.copyfile(file_path, target)
            copied.append(target)
        return manifest, copied
    finally:
        shutil.rmtree(staging, ignore_errors=True)


def _read_package_dir(path: Path) -> tuple[dict, list[Path]]:
    manifest = _decode_manifest((path / "manifest.json").read_bytes())
    files = [_payload_file(path, item["relativePath"]) for item in manifest.get("items") or []]
    return manifest, files


def _payload_file(root: Path, relative: str) -> Path:
    parts = _components(relative)
    file_path = root / "payload"
    for part in parts:
        file_path = file_path / part
    reject_symlink(file_path)
    resolved = file_path.resolve()
    if not str(resolved).startswith(str((root / "payload").resolve())):
        raise AppError("交接附件路径不安全。", "invalidPath")
    if not file_path.is_file():
        raise AppError("交接附件缺失。", "invalidPath")
    return file_path


def _components(path: str) -> list[str]:
    if not path or len(path.encode()) > 4096 or path.startswith("/") or "\\" in path or "\x00" in path:
        raise AppError("交接附件路径不安全。", "invalidPath")
    parts = path.split("/")
    if any(part in {"", ".", ".."} for part in parts):
        raise AppError("交接附件路径不安全。", "invalidPath")
    if parts[0] == "payload":
        parts = parts[1:]
    if not parts:
        raise AppError("交接附件不是普通文件。", "invalidPath")
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
    if manifest.get("schemaVersion") != 1:
        raise AppError("交接包版本暂不支持，原文档未修改。", "unsupportedSchema")
    if manifest.get("kind") not in {"request", "result"} or not _uuid(manifest.get("requestID")):
        raise AppError("交接包类型或请求编号无效。", "invalidManifest")
    if not _bundle(manifest.get("sourceBundleID")) or manifest.get("targetBundleID") != expected_target:
        raise AppError("交接包的目标应用不匹配。", "wrongTarget")
    if manifest.get("action") not in KNOWN_ACTIONS:
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
    items = manifest.get("items") or []
    references = manifest.get("references") or []
    if len(items) > MAX_ITEMS or len(references) > MAX_ITEMS or len(items) + len(references) > MAX_ITEMS:
        raise AppError("交接文件过多，请分批发送。", "itemLimit")
    seen = set()
    paths = set()
    for item in items:
        if not item["id"] or len(item["id"].encode()) > 256 or item["id"] in seen or not _sha(item.get("sha256")):
            raise AppError("交接文件信息无效。", "invalidItem")
        seen.add(item["id"])
        relative = "/".join(_components(item["relativePath"]))
        if relative in paths:
            raise AppError("交接包存在重复附件路径。", "duplicatePath")
        paths.add(relative)
        if not isinstance(item["byteCount"], int) or item["byteCount"] < 0:
            raise AppError("交接文件信息无效。", "invalidItem")
    if manifest["kind"] == "result":
        if not _uuid(manifest.get("inReplyTo")) or manifest.get("status") not in {"pending", "completed", "partial", "cancelled", "failed", "unsupported"}:
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
    payload = directory / "payload"
    payload.mkdir(parents=True)
    for name, content in files.items():
        target = payload / name
        safe_replace(target, content, None)
        if digest(target.read_bytes()) != digest(content):
            raise AppError("交接附件写入后核验失败，未保留半份交接包。", "handoff")
    raw = json.dumps(manifest, ensure_ascii=False, indent=2, sort_keys=True).encode("utf-8") + b"\n"
    safe_replace(directory / "manifest.json", raw, None)


def _canonical_manifest(manifest: dict) -> bytes:
    return json.dumps(manifest, ensure_ascii=False, sort_keys=True, separators=(",", ":")).encode("utf-8")


def _manifest_bytes(path: Path) -> bytes:
    return _manifest_from(path)


def _manifest_from(path: Path) -> bytes:
    if path.is_dir():
        return (path / "manifest.json").read_bytes()
    with zipfile.ZipFile(path) as archive:
        names = [name for name in archive.namelist() if name.endswith("manifest.json")]
        if not names:
            raise AppError("交接清单缺失。", "invalidManifest")
        return archive.read(names[0])


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
    return any(item.get("requestID") == request_id or item.get("manifestSHA256") == manifest_sha for item in data.get("entries") or [])


def _read_text(path: Path) -> str:
    data = path.read_bytes()
    if len(data) > MAX_TEXT or b"\x00" in data:
        raise AppError("交接正文超过限制或含无效字符，未改变当前文档。", "handoff")
    try:
        return data.decode("utf-8")
    except UnicodeError as exc:
        raise AppError("文字交接必须是有效 UTF-8 文件。", "invalidUTF8") from exc


def _public_manifest(manifest: dict) -> dict:
    return {"action": manifest.get("action"), "requestID": manifest.get("requestID"), "status": manifest.get("status"), "sourceBundleID": manifest.get("sourceBundleID")}


def _file_url(value: str) -> Path | None:
    if not isinstance(value, str) or len(value.encode()) > 16384 or not value.startswith("file://"):
        raise AppError("仅接受规范化的本机原件引用。", "invalidReference")
    if "?" in value or "#" in value or ".." in value:
        raise AppError("仅接受规范化的本机原件引用。", "invalidReference")
    raw = value[7:]
    if raw.startswith("localhost"):
        raw = raw[len("localhost"):]
    path = Path(raw)
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
