"""Windows file organizer. Access is scoped to directories explicitly selected here."""

from __future__ import annotations

import hashlib
import os
import sqlite3
import stat
import subprocess
import unicodedata
import uuid
from contextlib import closing, contextmanager
from pathlib import Path

from gaowenjian.errors import AppError
from gaowenjian.handoff import _path_parts, regular_path
from gaowenjian.safety import safe_replace

MARKER = b"GaoWenJian Windows Organizer 1\n"
SCHEMA = """
PRAGMA user_version=1;
CREATE TABLE roots (id TEXT PRIMARY KEY, path TEXT UNIQUE, device TEXT, inode TEXT);
CREATE TABLE files (id TEXT PRIMARY KEY, root TEXT REFERENCES roots(id) ON DELETE CASCADE,
    relative TEXT, name TEXT, extension TEXT, folded TEXT, size INTEGER, modified INTEGER, device TEXT, inode TEXT,
    UNIQUE(root, relative));
CREATE TABLE favorites (file TEXT REFERENCES files(id) ON DELETE CASCADE, tag TEXT, PRIMARY KEY(file, tag));
CREATE TABLE queries (id TEXT PRIMARY KEY, name TEXT UNIQUE, query TEXT, extension TEXT);
CREATE TABLE spaces (id TEXT PRIMARY KEY, name TEXT UNIQUE);
CREATE TABLE members (space TEXT REFERENCES spaces(id) ON DELETE CASCADE,
    file TEXT REFERENCES files(id) ON DELETE CASCADE, PRIMARY KEY(space, file));
CREATE TABLE moves (id TEXT PRIMARY KEY, file TEXT, source TEXT, destination TEXT, destRoot TEXT,
    device TEXT, inode TEXT, size INTEGER, modified INTEGER, sha TEXT, parentDevice TEXT, parentInode TEXT, status TEXT);
CREATE TABLE associations (extension TEXT, before TEXT, after TEXT, changed TEXT DEFAULT CURRENT_TIMESTAMP);
"""
SKIP_DIRS = {".git", ".svn", "node_modules", "$recycle.bin", "system volume information"}


def fold(value: str) -> str:
    return unicodedata.normalize("NFKC", value).casefold()


def _name(value) -> str:
    if not isinstance(value, str) or not value.strip() or len(value.strip()) > 120:
        raise AppError("请输入 1 至 120 个字符的名称。", "organizer")
    return value.strip()


def _path(value) -> Path:
    if not isinstance(value, str) or not value:
        raise AppError("请选择本机路径。", "invalidPath")
    path = Path(value)
    if not path.is_absolute() or path.drive.startswith("\\\\") or ".." in path.parts:
        raise AppError("只接受本机磁盘上的规范路径。", "invalidPath")
    return path


def _within(path: Path, parent: Path) -> bool:
    return path == parent or parent in path.parents


def _identity(info: os.stat_result) -> tuple[str, str]:
    return str(info.st_dev), str(info.st_ino)


def _stamp(info: os.stat_result) -> tuple[str, str, int, int]:
    return (*_identity(info), info.st_size, info.st_mtime_ns)


def _file_sha(path: Path, stamp: tuple) -> str:
    with path.open("rb") as stream:
        if _stamp(os.fstat(stream.fileno())) != stamp:
            raise AppError("文件在核对时发生变化，请重新扫描。", "changed")
        sha = hashlib.file_digest(stream, "sha256").hexdigest()
        if _stamp(os.fstat(stream.fileno())) != stamp or _stamp(regular_path(path)) != stamp:
            raise AppError("文件在核对时发生变化，请重新扫描。", "changed")
    return sha


def _find(db, table: str, identifier: str):
    row = db.execute(f"SELECT * FROM {table} WHERE id = ?", (identifier,)).fetchone()
    if not row:
        raise AppError("记录已不存在，请刷新文件整理。", "missing")
    return row


class Organizer:
    def __init__(self, data: Path):
        self.data = data.absolute()
        self.folder = self.data / "WindowsOrganizer"
        self.marker = self.folder / "initialized"
        self.database = self.folder / "index.sqlite3"
        self.association_pending: dict[str, str] = {}

    def initialize(self) -> None:
        if self.folder.exists():
            if self.marker.is_file() and self.database.is_file():
                with self.connect():
                    return
            if any(self.folder.iterdir()):
                raise AppError("整理资料不完整，已保留原目录。", "organizerData")
        else:
            self.folder.mkdir()
        regular_path(self.folder, directory=True)
        with closing(sqlite3.connect(self.database)) as db, db:
            db.executescript(SCHEMA)
        safe_replace(self.marker, MARKER, None)

    @contextmanager
    def connect(self):
        try:
            if not self.marker.is_file() or not self.database.is_file():
                raise AppError("请先在文件整理中初始化本机索引。", "organizerData")
            regular_path(self.marker)
            regular_path(self.database)
            if self.marker.read_bytes() != MARKER:
                raise AppError("整理资料版本无效，已保留原文件。", "organizerData")
            db = sqlite3.connect(self.database.as_uri() + "?mode=rw", uri=True)
            try:
                db.row_factory = sqlite3.Row
                version = db.execute("PRAGMA user_version").fetchone()[0]
                if version != 1:
                    raise AppError("整理资料版本不受支持，已保留原文件。", "organizerData")
                db.execute("PRAGMA foreign_keys=ON")
                with db:
                    yield db
            finally:
                db.close()
        except sqlite3.Error as exc:
            raise AppError("整理资料无法读取或写入，已保留原文件。", "organizerData") from exc
        except OSError as exc:
            raise AppError("Windows 无法读取或执行此项整理操作。", "organizerIO") from exc

    def overview(self) -> dict:
        if not self.folder.exists():
            return {"initialized": False}
        with self.connect() as db:
            return {"initialized": True,
                    "roots": [dict(item) for item in db.execute("SELECT id, path FROM roots ORDER BY path")],
                    "queries": [dict(item) for item in db.execute("SELECT * FROM queries ORDER BY name")],
                    "spaces": [dict(item) for item in db.execute("SELECT * FROM spaces ORDER BY name")],
                    "moves": [dict(item) for item in db.execute("SELECT id, source, destination, status FROM moves ORDER BY rowid DESC LIMIT 100")],
                    "associations": [dict(item) for item in db.execute("SELECT * FROM associations ORDER BY rowid DESC LIMIT 30")]}

    def authorize(self, value: str) -> dict:
        path = _path(value)
        try:
            info = regular_path(path, directory=True)
        except OSError as exc:
            raise AppError("无法读取要授权的目录。", "scope") from exc
        if _within(path, self.data):
            raise AppError("应用内部资料不能成为整理授权目录。", "scope")
        with self.connect() as db:
            for item in db.execute("SELECT id, path, device, inode FROM roots"):
                other = Path(item["path"])
                if path == other:
                    if _identity(info) != (item["device"], item["inode"]):
                        raise AppError("授权目录的身份已变化，请撤销再重新授权。", "scopeChanged")
                    return {"id": item["id"], "path": str(path)}
                if _within(other, path) or _within(path, other):
                    raise AppError("此目录与现有授权范围重叠，请保留一项授权。", "scope")
            identifier = str(uuid.uuid4())
            db.execute("INSERT INTO roots VALUES (?,?,?,?)", (identifier, str(path), *_identity(info)))
        return {"id": identifier, "path": str(path)}

    def revoke(self, identifier: str) -> None:
        with self.connect() as db:
            _find(db, "roots", identifier)
            if db.execute("""SELECT 1 FROM moves m LEFT JOIN files f ON f.id=m.file
                WHERE m.status='moving' AND (f.root=? OR m.destRoot=?)""", (identifier, identifier)).fetchone():
                raise AppError("先核对该目录尚未结束的移动计划，再撤销授权。", "busy")
            db.execute("DELETE FROM roots WHERE id = ?", (identifier,))

    @staticmethod
    def _root(db, identifier: str) -> Path:
        item = _find(db, "roots", identifier)
        path = Path(item["path"])
        if _identity(regular_path(path, directory=True)) != (item["device"], item["inode"]):
            raise AppError("授权目录的身份已变化，请撤销再重新授权。", "scopeChanged")
        return path

    def scan(self, identifier: str) -> dict:
        with self.connect() as db:
            root = self._root(db, identifier)
            records, skipped, visited, truncated = [], 0, 0, False
            stack = [root]
            while stack:
                folder = stack.pop()
                try:
                    regular_path(folder, directory=True)
                    with os.scandir(folder) as directory:
                        for entry in directory:
                            visited += 1
                            if visited > 50_000:
                                stack.clear()
                                truncated = True
                                break
                            entry_path = Path(entry.path)
                            if entry.name.startswith(".") or entry.name.casefold() in SKIP_DIRS or _within(entry_path, self.data):
                                continue
                            try:
                                # DirEntry stat omits file IDs/link count on Windows.
                                info = entry_path.lstat()
                            except OSError:
                                skipped += 1
                                continue
                            if getattr(info, "st_file_attributes", 0) & 0x406:
                                continue
                            if stat.S_ISDIR(info.st_mode):
                                stack.append(entry_path)
                            elif stat.S_ISREG(info.st_mode) and info.st_nlink == 1:
                                relative = str(entry_path.relative_to(root))
                                records.append((str(uuid.uuid4()), identifier, relative, entry.name, entry_path.suffix.lower(),
                                                fold(relative), info.st_size, info.st_mtime_ns, *_identity(info)))
                except (OSError, AppError):
                    skipped += 1
            if self._root(db, identifier) != root:
                raise AppError("扫描期间授权目录已变化，原索引已保留。", "scopeChanged")
            if not skipped and not truncated:
                db.execute("CREATE TEMP TABLE seen (path TEXT PRIMARY KEY)")
                db.executemany("INSERT INTO seen VALUES (?)", ((item[2],) for item in records))
                db.execute("""DELETE FROM files WHERE root=? AND relative NOT IN (SELECT path FROM seen)
                    AND id NOT IN (SELECT file FROM moves WHERE status='moving')""", (identifier,))
            db.executemany("""INSERT INTO files VALUES (?,?,?,?,?,?,?,?,?,?)
                ON CONFLICT(root,relative) DO UPDATE SET name=excluded.name, extension=excluded.extension, folded=excluded.folded,
                size=excluded.size, modified=excluded.modified, device=excluded.device, inode=excluded.inode""", records)
        return {"count": len(records), "skipped": skipped, "truncated": truncated}

    def search(self, payload: dict) -> dict:
        query = payload.get("query") or ""
        extension = payload.get("extension") or ""
        if not isinstance(query, str) or len(query) > 1000 or not isinstance(extension, str) or len(extension) > 30:
            raise AppError("搜索词或扩展名无效。", "organizer")
        offset = max(0, int(payload.get("offset") or 0))
        sort = {"name": "f.folded", "date": "f.modified DESC", "size": "f.size DESC"}.get(payload.get("sort"), "f.folded")
        clauses, arguments = [], []
        for token in fold(query).split():
            clauses.append("instr(f.folded, ?) > 0")
            arguments.append(token)
        if extension:
            clauses.append("f.extension = ?")
            arguments.append("." + extension.lower().lstrip("."))
        if payload.get("root"):
            clauses.append("r.id = ?")
            arguments.append(payload["root"])
        if payload.get("favorite"):
            clauses.append("EXISTS (SELECT 1 FROM favorites WHERE file=f.id)")
        if payload.get("space"):
            clauses.append("EXISTS (SELECT 1 FROM members WHERE file=f.id AND space=?)")
            arguments.append(payload["space"])
        where = " AND ".join(clauses) if clauses else "1"
        with self.connect() as db:
            records = db.execute(f"""SELECT f.*, r.path AS rootPath,
                (SELECT group_concat(tag, '、') FROM favorites WHERE file=f.id) AS tags
                FROM files f JOIN roots r ON r.id=f.root WHERE {where}
                ORDER BY {sort}, f.id LIMIT 101 OFFSET ?""", (*arguments, offset))
            values = []
            for item in records:
                row = dict(item)
                row["path"] = str(Path(row.pop("rootPath")) / row["relative"])
                values.append({key: row[key] for key in ("id", "name", "path", "size", "modified", "extension", "tags")})
        return {"items": values[:100], "offset": offset, "more": len(values) > 100}

    def _from_index(self, db, identifier: str) -> tuple[sqlite3.Row, Path, os.stat_result]:
        row = _find(db, "files", identifier)
        root = self._root(db, row["root"])
        path = root / row["relative"]
        if not _within(path, root) or ".." in path.parts or _within(path, self.data):
            raise AppError("索引条目超出授权范围。", "scope")
        info = regular_path(path)
        if _stamp(info) != (row["device"], row["inode"], row["size"], row["modified"]):
            raise AppError("索引中的文件身份或修改时间已变化，请重新扫描。", "changed")
        return row, path, info

    def open_file(self, identifier: str) -> Path:
        with self.connect() as db:
            return self._from_index(db, identifier)[1]

    def favorite(self, identifier: str, tag: str, remove=False) -> None:
        tag = _name(tag)
        with self.connect() as db:
            _find(db, "files", identifier)
            db.execute("DELETE FROM favorites WHERE file=? AND tag=?" if remove else
                       "INSERT OR IGNORE INTO favorites VALUES (?,?)", (identifier, tag))

    def save_query(self, name, query, extension) -> None:
        if not isinstance(query, str) or not isinstance(extension, str):
            raise AppError("搜索词或扩展名无效。", "organizer")
        with self.connect() as db:
            db.execute("INSERT INTO queries VALUES (?,?,?,?) ON CONFLICT(name) DO UPDATE SET query=excluded.query, extension=excluded.extension",
                       (str(uuid.uuid4()), _name(name), query, extension))

    def create_space(self, name) -> None:
        with self.connect() as db:
            db.execute("INSERT OR IGNORE INTO spaces VALUES (?,?)", (str(uuid.uuid4()), _name(name)))

    def member(self, space, file, remove=False) -> None:
        with self.connect() as db:
            _find(db, "spaces", space)
            _find(db, "files", file)
            db.execute("DELETE FROM members WHERE space=? AND file=?" if remove else
                       "INSERT OR IGNORE INTO members VALUES (?,?)", (space, file))

    def remove(self, table: str, identifier: str) -> None:
        if table not in {"queries", "spaces"}:
            raise AppError("无法移除该类型的记录。", "organizer")
        with self.connect() as db:
            db.execute(f"DELETE FROM {table} WHERE id=?", (identifier,))

    def _destination(self, db, root_id: str, value: str) -> tuple[Path, os.stat_result]:
        root = self._root(db, root_id)
        destination = _path(value)
        if not _within(destination, root) or destination == root or _within(destination, self.data):
            raise AppError("目标必须在所选授权目录内。", "scope")
        if any(len(_path_parts(part)) != 1 for part in destination.relative_to(root).parts):
            raise AppError("目标路径无效。", "invalidPath")
        return destination, regular_path(destination.parent, directory=True)

    def plan(self, identifier, root_id, value, opened) -> dict:
        if os.name != "nt":
            raise AppError("移动计划只在 Windows 执行。", "platform")
        with self.connect() as db:
            _, source, info = self._from_index(db, identifier)
            target, parent = self._destination(db, root_id, value)
            self._check_move(source, target, info.st_dev, parent.st_dev, opened)
            sha = _file_sha(source, _stamp(info))
            plan_id = str(uuid.uuid4())
            db.execute("INSERT INTO moves VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?)",
                       (plan_id, identifier, str(source), str(target), root_id, *_stamp(info), sha, *_identity(parent), "preview"))
        return {"id": plan_id, "source": str(source), "destination": str(target), "status": "preview"}

    @staticmethod
    def _check_move(source: Path, target: Path, source_device, target_device, opened) -> None:
        if source == target or os.path.lexists(target):
            raise AppError("目标已存在，整理不会覆盖文件。", "conflict")
        if source_device != target_device:
            raise AppError("只支持同一卷上的普通文件移动。", "scope")
        if source in opened or target in opened:
            raise AppError("请先关闭工作台中对应的标签。", "busy")

    def execute(self, identifier, opened) -> dict:
        with self.connect() as db:
            item = _find(db, "moves", identifier)
            if item["status"] != "preview":
                raise AppError("该计划已执行、取消或需要核对，不能重复执行。", "organizer")
            row, source, info = self._from_index(db, item["file"])
            target, parent = self._destination(db, item["destRoot"], item["destination"])
            expected = (item["device"], item["inode"], item["size"], item["modified"])
            if (str(source) != item["source"] or _stamp(info) != expected
                    or _identity(parent) != (item["parentDevice"], item["parentInode"])):
                raise AppError("预览之后文件或目标目录已变化。", "changed")
            self._check_move(source, target, info.st_dev, parent.st_dev, opened)
            if _file_sha(source, expected) != item["sha"]:
                raise AppError("预览之后文件内容已变化。", "changed")
            db.execute("UPDATE moves SET status='moving' WHERE id=?", (identifier,))
            db.commit()  # Write intent before touching the original.
            move_windows(source, target, expected, item["sha"], _identity(parent))
            self._finish_move(db, item, row, target)
        return {"id": identifier, "status": "moved"}

    def _finish_move(self, db, item, row, target: Path) -> None:
        root = self._root(db, item["destRoot"])
        relative = str(target.relative_to(root))
        db.execute("DELETE FROM files WHERE root=? AND relative=? AND id<>?", (item["destRoot"], relative, item["file"]))
        if row:
            db.execute("UPDATE files SET root=?, relative=?, name=?, extension=?, folded=? WHERE id=?",
                       (item["destRoot"], relative, target.name, target.suffix.lower(), fold(relative), item["file"]))
        db.execute("UPDATE moves SET status='moved' WHERE id=?", (item["id"],))

    def recover_move(self, identifier) -> dict:
        with self.connect() as db:
            item = _find(db, "moves", identifier)
            if item["status"] != "moving":
                raise AppError("只有尚未确认结果的计划需要核对。", "organizer")
            source, destination = Path(item["source"]), Path(item["destination"])
            row = _find(db, "files", item["file"])
            root = self._root(db, row["root"])
            if source != root / row["relative"]:
                raise AppError("原件路径已变化，请在资源管理器人工核对。", "changed")
            self._destination(db, item["destRoot"], item["destination"])
            expected = (item["device"], item["inode"], item["size"], item["modified"])
            if not os.path.lexists(source) and _file_sha(destination, expected) == item["sha"]:
                self._finish_move(db, item, row, destination)
                return {"id": identifier, "status": "moved"}
            if not os.path.lexists(destination) and _file_sha(source, expected) == item["sha"]:
                db.execute("UPDATE moves SET status='cancelled' WHERE id=?", (identifier,))
                return {"id": identifier, "status": "cancelled"}
            raise AppError("原件与目标状态无法确认，已保留两处，请在资源管理器人工核对。", "changed")

    def cancel_move(self, identifier) -> None:
        with self.connect() as db:
            db.execute("UPDATE moves SET status='cancelled' WHERE id=? AND status='preview'", (identifier,))

    def associations(self, action, extension) -> dict:
        if not isinstance(extension, str) or not 2 <= len(extension) <= 20 or not extension.startswith(".") or not extension[1:].isalnum():
            raise AppError("请输入扩展名，例如 .pdf。", "organizer")
        if os.name != "nt":
            raise AppError("文件关联需要 Windows 系统设置。", "platform")
        extension = extension.lower()
        program = read_association(extension)
        if action == "open":
            self.association_pending[extension] = program
            os.startfile("ms-settings:defaultapps")
        if action == "verify":
            before = self.association_pending.get(extension)
            if before is None:
                raise AppError("请先通过本页打开 Windows 默认应用设置。", "organizer")
            if before == program:
                return {"extension": extension, "program": program, "status": "unchanged"}
            with self.connect() as db:
                db.execute("INSERT INTO associations(extension,before,after) VALUES (?,?,?)", (extension, before, program))
            del self.association_pending[extension]
            return {"extension": extension, "program": program, "status": "changed"}
        return {"extension": extension, "program": program, "status": "pending" if action == "open" else "read"}


def reveal(path: Path) -> None:
    if os.name != "nt":
        raise AppError("资源管理器定位需要 Windows。", "platform")
    try:
        subprocess.Popen([str(Path(os.environ["WINDIR"]) / "explorer.exe"), "/select,", str(path)],
                         stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    except (KeyError, OSError) as exc:
        raise AppError("Windows 无法打开资源管理器。", "organizerIO") from exc


def read_association(extension: str) -> str:
    import ctypes as c
    from ctypes import wintypes as w

    query = c.WinDLL("Shlwapi").AssocQueryStringW
    query.argtypes = (w.DWORD, w.DWORD, w.LPCWSTR, w.LPCWSTR, w.LPWSTR, c.POINTER(w.DWORD))
    query.restype = c.c_long
    size = w.DWORD(0)
    query(0, 20, extension, None, None, c.byref(size))  # ASSOCSTR_PROGID
    if size.value == 0 or size.value > 8192:
        return ""
    result = c.create_unicode_buffer(size.value)
    return result.value if query(0, 20, extension, None, result, c.byref(size)) == 0 else ""


def move_windows(source: Path, target: Path, expected: tuple, sha: str, parent_identity: tuple[str, str]) -> None:
    """Open the verified object with write/delete sharing disabled and rename by handle."""
    import ctypes as c
    import msvcrt
    from ctypes import wintypes as w

    kernel = c.WinDLL("kernel32", use_last_error=True)
    create, close = kernel.CreateFileW, kernel.CloseHandle
    create.argtypes = (w.LPCWSTR, w.DWORD, w.DWORD, w.LPVOID, w.DWORD, w.DWORD, w.HANDLE)
    create.restype = w.HANDLE
    close.argtypes = (w.HANDLE,)
    closer = kernel.SetFileInformationByHandle
    closer.argtypes = (w.HANDLE, c.c_int, w.LPVOID, w.DWORD)
    closer.restype = w.BOOL

    class Rename(c.Structure):
        _fields_ = (("replace", w.BOOL), ("root", w.HANDLE), ("length", w.DWORD), ("name", w.WCHAR * 1))

    invalid = c.c_void_p(-1).value
    destination = create(str(target.parent), 0x80, 3, None, 3, 0x02200000, None)
    if destination == invalid:
        raise c.WinError(c.get_last_error())
    try:
        if _identity(regular_path(target.parent, directory=True)) != parent_identity:
            raise AppError("目标目录在执行前已变化。", "changed")
        handle = create(str(source), 0x80010000, 1, None, 3, 0x00200000, None)
        if handle == invalid:
            raise c.WinError(c.get_last_error())
        try:
            descriptor = msvcrt.open_osfhandle(handle, os.O_RDONLY | os.O_BINARY)
        except OSError:
            close(handle)
            raise
        with os.fdopen(descriptor, "rb") as stream:
            current = os.fstat(descriptor)
            if (getattr(current, "st_file_attributes", 0) & 0x400 or current.st_nlink != 1 or _stamp(current) != expected
                    or hashlib.file_digest(stream, "sha256").hexdigest() != sha
                    or _stamp(os.fstat(descriptor)) != expected):
                raise AppError("在执行时原件身份或内容已变化。", "changed")
            path = str(target).encode("utf-16-le")
            memory = c.create_string_buffer(max(c.sizeof(Rename), Rename.name.offset + len(path) + 2))
            info = Rename.from_buffer(memory)
            info.length = len(path)
            c.memmove(c.addressof(memory) + Rename.name.offset, path, len(path))
            if not closer(handle, 3, memory, len(memory)):  # FileRenameInfo, ReplaceIfExists=FALSE
                raise c.WinError(c.get_last_error())
    finally:
        close(destination)


def dispatch(workspace, operation: str, payload: dict) -> dict:
    organizer = workspace.organizer
    value = payload.get
    identifier = value("id")
    if operation == "state":
        return organizer.overview()
    if operation == "search":
        return organizer.search(payload)
    if operation == "initialize":
        organizer.initialize()
    elif operation == "authorize":
        if value("confirm") is not True:
            raise AppError("请确认将所选目录加入索引范围。", "scope")
        return organizer.authorize(value("path"))
    elif operation == "revoke":
        organizer.revoke(identifier)
    elif operation == "scan":
        return organizer.scan(identifier)
    elif operation in {"open", "reveal"}:
        path = organizer.open_file(identifier)
        if operation == "reveal":
            reveal(path)
            return {"requested": True}
        return {"id": workspace.open_path(path).id}
    elif operation == "favorite":
        organizer.favorite(identifier, value("tag"), bool(value("remove")))
    elif operation == "save-query":
        organizer.save_query(value("name"), value("query", ""), value("extension", ""))
    elif operation == "create-space":
        organizer.create_space(value("name"))
    elif operation == "member":
        organizer.member(value("space"), identifier, bool(value("remove")))
    elif operation == "remove":
        organizer.remove(value("table"), identifier)
    elif operation in {"plan", "execute"}:
        opened = {tab.path.absolute() for tab in workspace.tabs if tab.path is not None}
        if operation == "plan":
            return organizer.plan(identifier, value("root"), value("path"), opened)
        if value("confirm") is not True:
            raise AppError("请先核对原件与目标，再明确确认移动。", "confirmation")
        return organizer.execute(identifier, opened)
    elif operation == "recover":
        return organizer.recover_move(identifier)
    elif operation == "cancel":
        organizer.cancel_move(identifier)
    elif operation == "association":
        action = value("action")
        if action not in ("read", "open", "verify"):
            raise AppError("文件关联操作无效。", "organizer")
        return organizer.associations(action, value("extension"))
    else:
        raise AppError("没有这个文件整理操作。", "organizer")
    return organizer.overview()
