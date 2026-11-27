"""原子写入、摘要和损坏资料保护。不制作历史快照或备份副本。"""

from __future__ import annotations

import hashlib
import json
import os
import stat
import uuid
from dataclasses import dataclass
from pathlib import Path
from typing import BinaryIO, Callable, TypeVar

from gaowenjian.errors import AppError

_MISSING = "原文件已被移动或删除，请另存为，避免在旧位置静默重建文件。"
_CONFLICT = "文件已被其他程序修改。请重新打开或另存为，避免覆盖外部修改。"
_ReadResult = TypeVar("_ReadResult")


@dataclass(frozen=True)
class FileIdentity:
    device: int
    index: int
    fallback_path: str = ""
    creation: int | None = None

    @classmethod
    def from_record(cls, record) -> FileIdentity | None:
        if not isinstance(record, list) or len(record) != 2:
            return None
        device, index = record
        if type(device) is not int or type(index) is not int or device < 0 or index <= 0:
            return None
        return cls(device, index)

    def as_record(self) -> list[int] | None:
        return [self.device, self.index] if self.index else None


def digest(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def default_data_dir() -> Path:
    if os.name == "nt":
        base = os.environ.get("APPDATA") or str(Path.home() / "AppData" / "Roaming")
        return Path(base) / "GaoSeries" / "GaoWenJian"
    xdg = os.environ.get("XDG_DATA_HOME") or str(Path.home() / ".local" / "share")
    return Path(xdg) / "GaoSeries" / "GaoWenJian"


def reject_symlink(path: Path) -> None:
    if path.is_symlink():
        raise AppError("路径指向符号链接，已停止操作以保护原文件。", "symlink")


def _identity(info: os.stat_result, path: Path) -> FileIdentity:
    if info.st_ino:
        return FileIdentity(info.st_dev, info.st_ino)
    normalized_path = os.path.normcase(os.path.abspath(path))
    return FileIdentity(info.st_dev, 0, normalized_path, getattr(info, "st_birthtime_ns", None))


def _read_stamp(info: os.stat_result, path: Path) -> tuple:
    # Win32 path and handle queries expose different st_ctime semantics.
    change = getattr(info, "st_birthtime_ns", None) if os.name == "nt" else info.st_ctime_ns
    return _identity(info, path), info.st_size, info.st_mtime_ns, change


def _read_stable(path: Path, consume: Callable[[BinaryIO], _ReadResult], limit: int | None = None) -> tuple[_ReadResult, FileIdentity]:
    reject_symlink(path)
    with path.open("rb") as handle:
        initial = os.fstat(handle.fileno())
        if not stat.S_ISREG(initial.st_mode):
            raise AppError("请选择普通文件。", "path")
        if limit is not None and initial.st_size > limit:
            raise AppError("文件超过可处理大小。", "limit")
        stamp = _read_stamp(initial, path)
        result = consume(handle)
        if stamp != _read_stamp(os.fstat(handle.fileno()), path):
            raise AppError(_CONFLICT, "conflict")
        if stamp != _read_stamp(path.stat(follow_symlinks=False), path):
            raise AppError(_CONFLICT, "conflict")
    return result, stamp[0]


def read_file_snapshot(path: Path, limit: int | None = None) -> tuple[bytes, FileIdentity]:
    """绑定来自同一实际文件的内容与身份。"""
    try:
        data, identity = _read_stable(path, lambda handle: handle.read() if limit is None else handle.read(limit + 1), limit)
    except FileNotFoundError as exc:
        raise AppError(_MISSING, "missing") from exc
    except OSError as exc:
        raise AppError(f"无法读取文件：{path.name}", "file") from exc
    if limit is not None and len(data) > limit:
        raise AppError("文件超过可处理大小。", "limit")
    return data, identity


def _atomic_write(path: Path, data: bytes, before_replace: Callable[[], None] | None = None) -> FileIdentity:
    path.parent.mkdir(parents=True, exist_ok=True)
    reject_symlink(path.parent)
    reject_symlink(path)
    temporary = path.with_name(f".pending-{uuid.uuid4().hex}-{path.name}")
    created = False
    try:
        with temporary.open("xb") as handle:
            created = True
            handle.write(data)
            handle.flush()
            os.fsync(handle.fileno())
            staged = _identity(os.fstat(handle.fileno()), path)
        if before_replace is not None:
            before_replace()
        else:
            reject_symlink(path)
        os.replace(temporary, path)
        return staged
    finally:
        if created and temporary.exists():
            temporary.unlink()


def atomic_write(path: Path, data: bytes) -> None:
    """同目录临时文件写入后替换。失败时不先删除目标。"""
    _atomic_write(path, data)


def _checked_replace(path: Path, data: bytes, expected_digest: str | None, expected_identity: FileIdentity | None) -> FileIdentity:
    if expected_digest is None and expected_identity is None:
        return _atomic_write(path, data)
    if not path.is_file():
        raise AppError(_MISSING, "missing")

    def verify_current() -> None:
        try:
            current, identity = _read_stable(path, lambda handle: hashlib.file_digest(handle, "sha256").hexdigest())
        except FileNotFoundError as exc:
            raise AppError(_MISSING, "missing") from exc
        except OSError as exc:
            raise AppError(f"无法核对原文件：{path.name}", "file") from exc
        if (expected_identity is not None and identity != expected_identity) or (expected_digest is not None and current != expected_digest):
            raise AppError(_CONFLICT, "conflict")

    return _atomic_write(path, data, before_replace=verify_current)


def safe_replace(path: Path, data: bytes, expected_digest: str | None, *, expected_identity: FileIdentity | None = None) -> None:
    """在同目录暂存完成后核对原件，再原子替换。"""
    _checked_replace(path, data, expected_digest, expected_identity)


def write_document(path: Path, data: bytes, expected_digest: str | None, expected_identity: FileIdentity | None) -> FileIdentity:
    staged = _checked_replace(path, data, expected_digest, expected_identity)
    written, current = read_file_snapshot(path)
    if written != data or (staged.index and current != staged):
        raise AppError("保存后读回核验失败，请检查磁盘。", "verify")
    return current


def canonical_json(value) -> bytes:
    return json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":")).encode("utf-8")


class GuardedJSON:
    """损坏或外部改动的 JSON 只保留，不用空内容覆盖。"""

    def __init__(self, path: Path):
        self.path = path
        self.readable = True
        self.exists = False
        self.data = None
        self.fingerprint: str | None = None
        self.error: str | None = None
        self.load()

    def load(self) -> None:
        self.error = None
        if not self.path.exists():
            self.exists = False
            self.readable = True
            self.data = None
            self.fingerprint = None
            return
        self.exists = True
        try:
            reject_symlink(self.path)
            raw = self.path.read_bytes()
        except AppError as exc:
            self.readable = False
            self.data = None
            self.error = exc.message
            return
        except OSError as exc:
            self.readable = False
            self.data = None
            self.error = f"记录无法读取，已保留原文件：{exc}"
            return
        self.fingerprint = digest(raw)
        try:
            self.data = json.loads(raw.decode("utf-8"))
            self.readable = True
        except (UnicodeError, json.JSONDecodeError) as exc:
            self.readable = False
            self.data = None
            self.error = f"记录无法读取，已保留原文件：{exc}"

    def save(self, value, *, allow_create: bool = True) -> None:
        if not self.readable:
            raise AppError(self.error or "记录无法读取，已保留原文件。", "unreadable")
        if self.exists:
            if not self.path.is_file():
                raise AppError("原记录已被移动或删除，不能在旧位置重新创建。", "missing")
            reject_symlink(self.path)
            current = self.path.read_bytes()
            if digest(current) != self.fingerprint:
                raise AppError("记录已被其他程序修改，当前编辑已保留，未覆盖原文件。", "conflict")
        elif not allow_create:
            raise AppError("记录缺失，不能用新内容补造尚未核验的资料。", "missing")
        raw = json.dumps(value, ensure_ascii=False, indent=2).encode("utf-8") + b"\n"
        atomic_write(self.path, raw)
        written = self.path.read_bytes()
        if written != raw:
            raise AppError("写入后读回核验失败，请检查磁盘。", "verify")
        self.data = value
        self.fingerprint = digest(written)
        self.exists = True
        self.readable = True
        self.error = None


def inside(path: Path, root: Path) -> bool:
    try:
        path.resolve().relative_to(root.resolve())
        return True
    except ValueError:
        return False


def same_file(left: Path, right: Path) -> bool:
    try:
        return left.resolve() == right.resolve()
    except OSError:
        return str(left) == str(right)
