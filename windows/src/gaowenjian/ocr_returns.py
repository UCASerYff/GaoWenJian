"""Fixed per-user mailbox for explicitly requested Windows OCR returns."""

from __future__ import annotations

import hashlib
import json
import os
import re
import time
import uuid
from collections import Counter
from contextlib import ExitStack, contextmanager
from datetime import datetime, timedelta, timezone
from pathlib import Path

from gaowenjian.errors import AppError
from gaowenjian.handoff import (
    BUNDLE_ID, MAX_MANIFEST, _components, _decode_manifest, _parse_time, _sha, _validate,
    read_package, read_regular, regular_path,
)
from gaowenjian.safety import _read_stable, digest

PROVIDER = "com.gaoseries.GaoCaoZuo"
ACTION = "ocr.files"
RETURN_PARTS = ("GaoSeries", "GaoAction", "OcrReturns-v1")
TICKET_FILE = "request.json"
RESULT_DIR = "result.gaoaction"
MAX_TICKET = 4096


def _base() -> Path | None:
    value = os.environ.get("LOCALAPPDATA")
    if not value:
        return None
    path = Path(value)
    if not path.is_absolute() or ".." in path.parts:
        return None
    if os.name == "nt" and re.fullmatch(r"[A-Za-z]:", path.drive) is None:
        return None
    return path


def _canonical_uuid(value) -> bool:
    try:
        return isinstance(value, str) and str(uuid.UUID(value)) == value
    except ValueError:
        return False


def _lexical(path: Path) -> Path:
    value = str(path)
    if os.name == "nt" and value.startswith(("\\\\?\\", "\\\\.\\")) and re.match(r"[A-Za-z]:\\", value[4:]):
        value = value[4:]
    value = os.path.abspath(value)
    if os.name == "nt":
        parent = Path(value)
        return Path(parent.anchor, *(part.rstrip(" .") for part in parent.parts[1:]))
    return Path(value)


def is_return_path(path: Path) -> bool:
    base = _base()
    return base is not None and _lexical(path).is_relative_to(base.joinpath(*RETURN_PARTS))


@contextmanager
def _pin_directory(path: Path):
    """On Windows, deny replacement of each checked directory while it is in use."""
    first = regular_path(path, directory=True)
    if os.name != "nt":
        yield
        return
    import ctypes as c
    from ctypes import wintypes as w

    kernel = c.WinDLL("kernel32", use_last_error=True)
    create, close = kernel.CreateFileW, kernel.CloseHandle
    create.argtypes = (w.LPCWSTR, w.DWORD, w.DWORD, w.LPVOID, w.DWORD, w.DWORD, w.HANDLE)
    create.restype = w.HANDLE
    close.argtypes, close.restype = (w.HANDLE,), w.BOOL
    # FILE_READ_ATTRIBUTES, share reads/writes, OPEN_EXISTING, BACKUP_SEMANTICS | OPEN_REPARSE_POINT.
    handle = create(str(path), 0x80, 3, None, 3, 0x02200000, None)
    if handle == c.c_void_p(-1).value:
        raise c.WinError(c.get_last_error())
    try:
        last = regular_path(path, directory=True)
        if (first.st_dev, first.st_ino) != (last.st_dev, last.st_ino):
            raise AppError("OCR 回传目录已变化。", "changed")
        yield
    finally:
        close(handle)


@contextmanager
def _mailbox(base: Path, identifier: str, *, create=False):
    if not _canonical_uuid(identifier):
        raise AppError("OCR 请求编号无效。", "invalidPath")
    with ExitStack() as pins:
        for ancestor in (*reversed(base.parents), base):
            pins.enter_context(_pin_directory(ancestor))
        path = base
        for name in (*RETURN_PARTS, identifier):
            path = path / name
            if create:
                try:
                    path.mkdir()
                except FileExistsError:
                    pass
            pins.enter_context(_pin_directory(path))
        yield path


def _ticket(session: dict, now: datetime) -> dict:
    identifier = session.get("requestID")
    sha, expires = session.get("manifestSHA256"), session.get("expiresAt")
    if (session.get("action") != ACTION or session.get("targetBundleID") != PROVIDER
            or not _canonical_uuid(identifier) or not _sha(sha) or now >= _parse_time(expires)):
        raise AppError("本机 OCR 请求已过期或无效。", "expired")
    return {"schemaVersion": 1, "requestID": identifier, "action": ACTION, "sourceBundleID": BUNDLE_ID,
            "targetBundleID": PROVIDER, "requestManifestSHA256": sha, "expiresAt": expires}


def _read_ticket(path: Path, wanted: dict) -> bytes:
    raw = read_regular(path, MAX_TICKET)

    def object_from_unique_keys(pairs):
        record = dict(pairs)
        if len(record) != len(pairs):
            raise ValueError("repeated ticket key")
        return record

    try:
        record = json.loads(raw.decode("utf-8"), object_pairs_hook=object_from_unique_keys)
    except (UnicodeError, ValueError) as exc:
        raise AppError("OCR 回传票据无法核对。", "ocrTicket") from exc
    if not isinstance(record, dict) or type(record.get("schemaVersion")) is not int or record != wanted:
        raise AppError("OCR 回传票据与本机发送记录不匹配。", "ocrTicket")
    return raw


def publish_ticket(session: dict, now: datetime) -> bool:
    """Ticket creation is best effort after the existing manual request is durably saved."""
    base = _base()
    if base is None:
        return False
    try:
        ticket = _ticket(session, now)
        with _mailbox(base, ticket["requestID"], create=True) as directory:
            path = directory / TICKET_FILE
            if os.path.lexists(path):
                _read_ticket(path, ticket)
                return True
            temporary = directory / f".request-{uuid.uuid4().hex}.tmp"
            staged = None
            try:
                with temporary.open("xb") as stream:
                    staged = os.fstat(stream.fileno())
                    raw = json.dumps(ticket, ensure_ascii=False, separators=(",", ":")).encode("utf-8") + b"\n"
                    stream.write(raw)
                    stream.flush()
                    os.fsync(stream.fileno())
                regular_path(directory, directory=True)
                try:
                    if os.name == "nt":
                        temporary.rename(path)  # Windows rename without replace fails if the destination exists.
                    else:
                        os.link(temporary, path)
                        temporary.unlink()
                except FileExistsError:
                    pass
                _read_ticket(path, ticket)
            finally:
                if staged is not None and os.path.lexists(temporary):
                    existing = regular_path(temporary)
                    if (existing.st_dev, existing.st_ino) == (staged.st_dev, staged.st_ino):
                        temporary.unlink()
        return True
    except (AppError, OSError):
        return False


def _stamp(path: Path) -> tuple:
    item = regular_path(path)
    return (item.st_dev, item.st_ino, item.st_size, item.st_mtime_ns, item.st_ctime_ns, item.st_nlink)


def _sessions(book) -> list[dict]:
    if not book or not book.outgoing.exists or not book.outgoing.readable or not book.journal.readable:
        return []
    try:
        path = book.outgoing.path
        stamp = _stamp(path)
        key = (stamp, book.outgoing.fingerprint)
        if book.ocr_outgoing_stamp != key:
            actual, _ = _read_stable(path, lambda stream: hashlib.file_digest(stream, "sha256").hexdigest())
            if actual != book.outgoing.fingerprint or stamp != _stamp(path):
                return []
            book.ocr_outgoing_stamp = key
        return (book.outgoing.data or {}).get("sessions", [])
    except (AppError, OSError):
        return []


def _read_result(book, directory: Path, ticket: dict, now: datetime) -> tuple[dict, list[bytes], str]:
    from gaowenjian.ocr_handoff import validate_result

    started = time.monotonic()
    ticket_path = directory / TICKET_FILE
    original_ticket = _read_ticket(ticket_path, ticket)
    result_path = directory / RESULT_DIR
    with _pin_directory(result_path):
        manifest, files, sha = read_package(result_path, now=now)
        if (manifest["kind"] != "result" or manifest["action"] != ACTION or manifest["inReplyTo"] != ticket["requestID"]
                or manifest["sourceBundleID"] != PROVIDER or manifest["targetBundleID"] != BUNDLE_ID
                or manifest["provenance"].get("requestManifestSHA256") != ticket["requestManifestSHA256"]):
            raise AppError("OCR 回传结果与本机请求不匹配。", "ocrProvenance")
        validate_result(manifest, files, book.outgoing.data, book.journal.data)
        if manifest["status"] == "failed":
            raise AppError("搞操作未能识别这些文件，可在搞操作手工处理。", "ocrFailed")
        if original_ticket != _read_ticket(ticket_path, ticket):
            raise AppError("OCR 回传票据已变化，请重新审核。", "changed")
        regular_path(result_path, directory=True)
        finished = now + timedelta(seconds=time.monotonic() - started)
        if finished >= min(_parse_time(ticket["expiresAt"]), _parse_time(manifest["expiresAt"])):
            raise AppError("OCR 请求或回传已过期，可通过搞操作手工导出。", "expired")
        return manifest, files, sha


def inspect_return(book, path: Path, now: datetime | None = None) -> tuple[dict, list[bytes], str]:
    base = _base()
    if base is None:
        raise AppError("没有可用的 OCR 回传目录。", "invalidPath")
    root = base.joinpath(*RETURN_PARTS)
    try:
        parts = path.relative_to(root).parts
    except ValueError as exc:
        raise AppError("请选择当前 OCR 请求的固定回传目录。", "invalidPath") from exc
    if len(parts) != 2 or parts[1] != RESULT_DIR or not _canonical_uuid(parts[0]):
        raise AppError("请选择当前 OCR 请求的固定回传目录。", "invalidPath")
    sessions = [item for item in _sessions(book) if item.get("requestID") == parts[0]]
    if len(sessions) != 1:
        raise AppError("找不到与 OCR 回传匹配的本机发送记录。", "ocrTicket")
    now = now or datetime.now(timezone.utc)
    try:
        with _mailbox(base, parts[0]) as directory:
            return _read_result(book, directory, _ticket(sessions[0], now), now)
    except OSError as exc:
        raise AppError("OCR 回传票据或结果暂时不可用。", "missing") from exc


def _result_paths(path: Path, manifest: dict) -> tuple[Path, ...]:
    return (path / "manifest.json", *(path.joinpath("payload", *_components(item["relativePath"]))
                                    for item in manifest["items"]))


def scan_returns(book, *, now: datetime | None = None) -> dict:
    from gaowenjian.ocr_handoff import result_sources

    base = _base()
    now = now or datetime.now(timezone.utc)
    response = {"pending": False, "results": [], "issues": []}
    if base is None or book is None:
        return response
    handled = {item["inReplyTo"] for item in (book.journal.data or {}).get("entries", [])
               if item.get("action") == ACTION and _canonical_uuid(item.get("inReplyTo"))}
    previous, current = book.ocr_returns_cache, {}
    sessions = _sessions(book)
    identifiers = Counter(item["requestID"] for item in sessions if _canonical_uuid(item.get("requestID")))
    for session in reversed(sessions):
        identifier = session.get("requestID")
        if not _canonical_uuid(identifier) or identifier in handled or identifiers[identifier] != 1:
            continue
        try:
            ticket = _ticket(session, now)
        except AppError:
            continue
        try:
            with _mailbox(base, identifier) as directory:
                _read_ticket(directory / TICKET_FILE, ticket)
                path = directory / RESULT_DIR
                if not os.path.lexists(path):
                    response["pending"] = True
                    continue
                cached = previous.get(identifier)
                with _pin_directory(path):
                    if (cached and cached[0] == ticket and now < cached[1]
                            and cached[3] == tuple(_stamp(member) for member in cached[2])):
                        current[identifier] = cached
                    else:
                        raw = read_regular(path / "manifest.json", MAX_MANIFEST)
                        metadata = _decode_manifest(raw)
                        _validate(metadata, BUNDLE_ID, now)
                        members = _result_paths(path, metadata)
                        stamps = tuple(_stamp(member) for member in members)
                        manifest, _, sha = _read_result(book, directory, ticket, now)
                        if sha != digest(raw) or stamps != tuple(_stamp(member) for member in members):
                            raise AppError("OCR 回传结果读取期间发生变化。", "changed")
                        summary = {"requestID": identifier, "resultID": manifest["requestID"], "path": str(path),
                                   "sha256": sha, "status": manifest["status"], "expiresAt": manifest["expiresAt"],
                                   "failureCount": len(manifest["provenance"]["exportFailures"]),
                                   "sources": result_sources(book, manifest)}
                        current[identifier] = ticket, _parse_time(manifest["expiresAt"]), members, stamps, summary
                response["results"].append(current[identifier][-1])
        except FileNotFoundError:
            continue  # Older sessions and missing tickets stay eligible for manual handoff.
        except (AppError, OSError) as exc:
            reason = exc.code if isinstance(exc, AppError) else "unavailable"
            response["issues"].append({"requestID": identifier, "reason": reason})
    book.ocr_returns_cache = current
    return response
