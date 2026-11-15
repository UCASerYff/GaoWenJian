"""原子写入、摘要和损坏资料保护。不制作历史快照或备份副本。"""

from __future__ import annotations

import hashlib
import json
import os
import uuid
from pathlib import Path

from gaowenjian.errors import AppError


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


def atomic_write(path: Path, data: bytes) -> None:
    """同目录临时文件写入后替换。失败时不先删除目标。"""
    path.parent.mkdir(parents=True, exist_ok=True)
    reject_symlink(path.parent)
    if path.exists():
        reject_symlink(path)
    temporary = path.with_name(f".pending-{uuid.uuid4().hex}-{path.name}")
    try:
        with temporary.open("wb") as handle:
            handle.write(data)
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary, path)
    finally:
        if temporary.exists():
            temporary.unlink()


def safe_replace(path: Path, data: bytes, expected_digest: str | None) -> None:
    """覆盖前核对原件摘要。原件消失时不在旧位置重建。"""
    if expected_digest is not None:
        if not path.is_file():
            raise AppError("原文件已被移动或删除，请另存为，避免在旧位置静默重建文件。", "missing")
        reject_symlink(path)
        current = path.read_bytes()
        if digest(current) != expected_digest:
            raise AppError("文件已被其他程序修改。请重新打开或另存为，避免覆盖外部修改。", "conflict")
    elif path.exists():
        reject_symlink(path)
    atomic_write(path, data)


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
