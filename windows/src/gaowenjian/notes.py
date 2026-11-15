"""便笺。Windows 自有记录可读写；macOS 的 Flat RTFD 只读，且绝不空白覆盖。"""

from __future__ import annotations

import json
import uuid
from datetime import datetime, timezone
from pathlib import Path

from gaowenjian.errors import AppError
from gaowenjian.rtf import from_html, parse as parse_rtf
from gaowenjian.safety import GuardedJSON, canonical_json, digest, reject_symlink

WRITER = "gaowenjian-windows-1"
COLORS = ["yellow", "blue", "green", "pink", "purple", "gray"]
SCHEMA = 2


def _now() -> str:
    return datetime.now(timezone.utc).isoformat()


def _default_style() -> dict:
    return {"color": "yellow", "fontName": "Segoe UI", "fontSize": 15, "width": 360, "height": 300}


class NotesStore:
    def __init__(self, root: Path):
        self.root = root
        self.contents = self.root / "Contents"
        self.archive_path = self.root / "notes.json"
        self.guard = GuardedJSON(self.archive_path)
        self.notes: list[dict] = []
        self.defaults = _default_style()
        self.read_only = False
        self.blocked = ""
        self.owned = False
        self._bodies: dict[str, dict] = {}
        self.load()

    def load(self) -> None:
        self.notes = []
        self._bodies = {}
        self.read_only = False
        self.blocked = ""
        self.owned = False
        self.defaults = _default_style()
        if self.root.exists():
            reject_symlink(self.root)
        if not self.archive_path.exists():
            if self.root.exists() and any(self.root.iterdir()):
                self.read_only = True
                self.blocked = "便笺目录已有资料，但主记录缺失。已停止保存，不能用空白资料覆盖。"
            return
        if not self.guard.readable or not isinstance(self.guard.data, dict):
            self.read_only = True
            self.blocked = self.guard.error or "便笺记录无法读取。原资料已保留，未进行覆盖。"
            return
        archive = self.guard.data
        version = archive.get("version")
        payload = archive.get("payload")
        if version not in (1, 2) or not isinstance(payload, dict):
            self.read_only = True
            self.blocked = "便笺记录的版本或结构无法读取。原资料已保留，未进行覆盖。"
            return
        expected = archive.get("payloadDigest")
        ours = archive.get("writer") == WRITER and expected == digest(canonical_json(payload))
        notes = payload.get("notes")
        defaults = payload.get("defaults") or _default_style()
        if not isinstance(notes, list):
            self.read_only = True
            self.blocked = "便笺记录无法读取。原资料已保留，未进行覆盖。"
            return
        try:
            self._validate_defaults(defaults)
            loaded = []
            seen = set()
            for note in notes:
                self._validate_note(note)
                if note["id"] in seen:
                    raise AppError("便笺记录包含重复编号。")
                seen.add(note["id"])
                body = self._load_body(note, version)
                loaded.append(note)
                self._bodies[note["id"]] = body
            self.notes = loaded
            self.defaults = defaults
            self.owned = bool(ours and version == 2)
            self.read_only = not self.owned
            if self.read_only:
                self.blocked = "这是 macOS 或其他写入器的便笺记录。Windows 版只读打开，不会覆盖 notes.json。可以导出副本。"
        except (AppError, OSError) as exc:
            self.notes = []
            self._bodies = {}
            self.read_only = True
            self.owned = False
            self.blocked = exc.message + " 原资料已保留，未进行覆盖。"

    def snapshot(self) -> dict:
        visible = []
        for note in self.notes:
            body = self._bodies.get(note["id"], {})
            visible.append({
                "id": note["id"],
                "title": note.get("title") or "",
                "group": note.get("group") or "",
                "color": note.get("color") or "yellow",
                "createdAt": note.get("createdAt"),
                "updatedAt": note.get("updatedAt"),
                "deletedAt": note.get("deletedAt"),
                "isPinned": bool(note.get("isPinned")),
                "isTranslucent": bool(note.get("isTranslucent")),
                "isCollapsed": bool(note.get("isCollapsed")),
                "isOnDesktop": bool(note.get("isOnDesktop")),
                "frame": note.get("frame") or {},
                "plainText": note.get("plainText") or "",
                "html": body.get("html") or "",
                "attachments": [item["name"] for item in body.get("attachments") or []],
                "editable": self.owned and not note.get("deletedAt"),
            })
        return {
            "readOnly": self.read_only,
            "blocked": self.blocked,
            "owned": self.owned,
            "defaults": self.defaults,
            "notes": visible,
        }

    def create(self, title: str = "", html: str = "", plain: str = "") -> str:
        self._require_writable(create=True)
        note_id = str(uuid.uuid4())
        now = _now()
        frame = {"x": 180, "y": 180, "width": self.defaults["width"], "height": self.defaults["height"]}
        body = {"format": "gaowenjian-html-1", "html": html, "attachments": []}
        note = {
            "id": note_id,
            "title": title,
            "group": "",
            "color": self.defaults["color"],
            "createdAt": now,
            "updatedAt": now,
            "deletedAt": None,
            "isPinned": False,
            "isTranslucent": False,
            "isCollapsed": False,
            "isOnDesktop": False,
            "frame": frame,
            "plainText": plain,
            "rtfd": "",
            "rtfdDigest": "",
        }
        self._validate_note(note)
        self.notes.insert(0, note)
        self._bodies[note_id] = body
        try:
            self._flush()
        except Exception:
            self.notes.pop(0)
            self._bodies.pop(note_id, None)
            raise
        return note_id

    def update(self, note_id: str, html: str, plain: str) -> None:
        self._require_writable()
        note = self._live(note_id)
        body = {"format": "gaowenjian-html-1", "html": html, "attachments": self._bodies.get(note_id, {}).get("attachments") or []}
        note["plainText"] = plain
        note["updatedAt"] = _now()
        self._bodies[note_id] = body
        self._flush()

    def attach(self, note_id: str, name: str, content: bytes) -> None:
        self._require_writable()
        if len(content) > 20 * 1024 * 1024:
            raise AppError("单个附件不能超过 20 MB。", "notes")
        note = self._live(note_id)
        body = dict(self._bodies[note_id])
        attachments = list(body.get("attachments") or [])
        if sum(len(item.get("content") or b"") for item in attachments) + len(content) > 64 * 1024 * 1024:
            raise AppError("一张便笺的附件合计不能超过 64 MB。", "notes")
        attachments.append({"name": Path(name).name or "附件", "sha256": digest(content), "content": content})
        body["attachments"] = attachments
        note["updatedAt"] = _now()
        self._bodies[note_id] = body
        self._flush()

    def metadata(self, note_id: str, changes: dict) -> None:
        self._require_writable()
        note = self._find(note_id)
        allowed = {"title", "group", "color", "isPinned", "isTranslucent", "isCollapsed", "isOnDesktop", "frame"}
        for key, value in changes.items():
            if key not in allowed:
                continue
            note[key] = value
        if note.get("color") not in COLORS:
            raise AppError("便笺颜色无效。", "notes")
        self._validate_note(note)
        note["updatedAt"] = _now()
        self._flush()

    def trash(self, note_id: str) -> None:
        self._require_writable()
        note = self._live(note_id)
        note["deletedAt"] = _now()
        note["updatedAt"] = note["deletedAt"]
        self._flush()

    def restore(self, note_id: str) -> None:
        self._require_writable()
        note = self._find(note_id)
        if not note.get("deletedAt"):
            return
        note["deletedAt"] = None
        note["updatedAt"] = _now()
        self._flush()

    def set_defaults(self, changes: dict) -> None:
        self._require_writable()
        candidate = dict(self.defaults)
        for key in ("color", "fontName", "fontSize", "width", "height"):
            if key in changes:
                candidate[key] = changes[key]
        self._validate_defaults(candidate)
        self.defaults = candidate
        self._flush()

    def export(self, note_id: str, fmt: str, destination: Path) -> None:
        note = self._find(note_id)
        body = self._bodies.get(note_id) or {}
        plain = note.get("plainText") or ""
        attachments = body.get("attachments") or []
        if destination.exists():
            raise AppError("导出目标已存在。请换一个新路径，不能覆盖已有文件。", "export")
        if fmt == "txt":
            destination.write_text(plain, encoding="utf-8")
            return
        if fmt == "rtf":
            if attachments:
                raise AppError("这张便笺包含附件。请导出为 RTFD，RTF 无法完整保留附件。", "export")
            destination.write_bytes(from_html(body.get("html") or _escape(plain)))
            return
        if fmt == "rtfd":
            destination.mkdir()
            (destination / "TXT.rtf").write_bytes(from_html(body.get("html") or _escape(plain)))
            for item in attachments:
                (destination / Path(item["name"]).name).write_bytes(item["content"])
            return
        raise AppError("便笺可导出 TXT、RTF 和 RTFD。", "export")

    def import_file(self, path: Path) -> str:
        self._require_writable(create=True)
        reject_symlink(path)
        if path.is_dir() or path.suffix.lower() == ".rtfd":
            rtf_path = path / "TXT.rtf"
            if not rtf_path.is_file():
                raise AppError("RTFD 的正文 TXT.rtf 缺失或无法读取，原件已保留。", "notes")
            parsed = parse_rtf(rtf_path.read_bytes())
            note_id = self.create(path.stem, parsed["html"], parsed["plain"])
            for child in path.iterdir():
                if child.name.lower() == "txt.rtf" or not child.is_file() or child.is_symlink():
                    continue
                self.attach(note_id, child.name, child.read_bytes())
            return note_id
        if path.suffix.lower() == ".txt":
            text = path.read_text(encoding="utf-8")
            return self.create(path.stem, _escape(text).replace("\n", "<br>"), text)
        if path.suffix.lower() == ".rtf":
            parsed = parse_rtf(path.read_bytes())
            return self.create(path.stem, parsed["html"], parsed["plain"])
        raise AppError("便笺可导入 TXT、RTF 和 RTFD 文件。", "notes")

    def _require_writable(self, create: bool = False) -> None:
        if self.blocked and not self.owned:
            raise AppError(self.blocked, "notes")
        if self.read_only or not self.owned and self.guard.exists:
            raise AppError(self.blocked or "便笺资料只读，不能覆盖原记录。", "notes")
        if create and not self.owned:
            self.owned = True

    def _find(self, note_id: str) -> dict:
        for note in self.notes:
            if note["id"] == note_id:
                return note
        raise AppError("便笺不存在。", "notes")

    def _live(self, note_id: str) -> dict:
        note = self._find(note_id)
        if note.get("deletedAt"):
            raise AppError("便笺已在回收站中。", "notes")
        return note

    def _load_body(self, note: dict, version: int) -> dict:
        if version == 1:
            return {"format": "mac-flat-rtfd", "html": "", "attachments": [], "opaque": True}
        digest_hex = note.get("rtfdDigest") or ""
        if note.get("rtfd"):
            raise AppError("便笺记录包含与存储版本不符的正文数据。")
        blob = self._blob_path(digest_hex)
        reject_symlink(blob)
        data = blob.read_bytes()
        if digest(data) != digest_hex:
            raise AppError(f"“{note.get('title') or '便笺'}”的富文本或附件摘要校验失败。")
        try:
            body = json.loads(data.decode("utf-8"))
        except (UnicodeError, json.JSONDecodeError):
            return {"format": "mac-flat-rtfd", "html": "", "attachments": [], "opaque": True}
        if body.get("format") != "gaowenjian-html-1":
            return {"format": "mac-flat-rtfd", "html": "", "attachments": [], "opaque": True}
        attachments = []
        for item in body.get("attachments") or []:
            content = bytes.fromhex(item.get("hex") or "")
            if digest(content) != item.get("sha256"):
                raise AppError("便笺附件摘要校验失败。")
            attachments.append({"name": item.get("name") or "附件", "sha256": item["sha256"], "content": content})
        plain = note.get("plainText") or ""
        if body.get("plain") != plain:
            raise AppError(f"“{note.get('title') or '便笺'}”的正文索引与富文本不一致。")
        return {"format": "gaowenjian-html-1", "html": body.get("html") or "", "attachments": attachments}

    def _store_body(self, note: dict, body: dict) -> str:
        payload = {
            "format": "gaowenjian-html-1",
            "html": body.get("html") or "",
            "plain": note.get("plainText") or "",
            "attachments": [
                {"name": item["name"], "sha256": item["sha256"], "hex": item["content"].hex()}
                for item in body.get("attachments") or []
            ],
        }
        raw = json.dumps(payload, ensure_ascii=False, sort_keys=True, separators=(",", ":")).encode("utf-8")
        digest_hex = digest(raw)
        self.contents.mkdir(parents=True, exist_ok=True)
        reject_symlink(self.contents)
        target = self._blob_path(digest_hex)
        if target.exists():
            reject_symlink(target)
            if target.read_bytes() != raw:
                raise AppError("同摘要正文包与当前缓存不一致，已中止保存。", "notes")
            return digest_hex
        temporary = self.contents / f".pending-{uuid.uuid4().hex}.rtfd"
        temporary.write_bytes(raw)
        if temporary.read_bytes() != raw:
            temporary.unlink(missing_ok=True)
            raise AppError("新正文包写入核验失败，记录未被更新。", "notes")
        temporary.replace(target)
        if digest(target.read_bytes()) != digest_hex:
            raise AppError("新正文包摘要核验失败，记录未被更新。", "notes")
        return digest_hex

    def _blob_path(self, digest_hex: str) -> Path:
        if len(digest_hex) != 64 or any(char not in "0123456789abcdef" for char in digest_hex):
            raise AppError("便笺正文摘要格式无效，原资料已保留。", "notes")
        return self.contents / f"{digest_hex}.rtfd"

    def _flush(self) -> None:
        for note in self.notes:
            body = self._bodies[note["id"]]
            if body.get("format") == "gaowenjian-html-1":
                note["rtfd"] = ""
                note["rtfdDigest"] = self._store_body(note, body)
        payload = {"defaults": self.defaults, "notes": self.notes}
        archive = {"payload": payload, "payloadDigest": digest(canonical_json(payload)), "version": SCHEMA, "writer": WRITER}
        self.guard.save(archive)
        self.owned = True
        self.read_only = False
        self.blocked = ""

    def _validate_defaults(self, style: dict) -> None:
        if style.get("color") not in COLORS or not style.get("fontName"):
            raise AppError("新便笺默认字体或颜色无效。")
        size = float(style.get("fontSize"))
        width = float(style.get("width"))
        height = float(style.get("height"))
        if not 6 <= size <= 200 or not 180 <= width <= 10000 or not 120 <= height <= 10000:
            raise AppError("新便笺默认字体或窗口尺寸无效。")

    def _validate_note(self, note: dict) -> None:
        frame = note.get("frame") or {}
        width = float(frame.get("width"))
        height = float(frame.get("height"))
        if not all(isinstance(frame.get(key), (int, float)) for key in ("x", "y", "width", "height")):
            raise AppError("便笺窗口尺寸、位置或日期无效。")
        if not 180 <= width <= 10000 or not 40 <= height <= 10000:
            raise AppError("便笺窗口尺寸、位置或日期无效。")
        if note.get("color") not in COLORS:
            raise AppError("便笺颜色无效。")
        uuid.UUID(str(note.get("id")))


def _escape(text: str) -> str:
    return text.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")
