import base64
import json
import shutil
import struct
import threading
import urllib.request
import uuid
import zlib
from datetime import datetime, timedelta, timezone
from pathlib import Path

import pytest
from pypdf import PdfReader, PdfWriter

from gaowenjian.csvtext import encode, markdown_table, parse
from gaowenjian.errors import AppError
from gaowenjian.handoff import HandoffBook
from gaowenjian.latex import complete, parse_index, parse_log, root_directive
from gaowenjian.markdown import outline, render
from gaowenjian.notes import NotesStore
from gaowenjian.office import read_document
from gaowenjian.pdfdoc import inspect, plain_pdf, search, transform
from gaowenjian.rtf import from_html, parse as parse_rtf
from gaowenjian.safety import digest
from gaowenjian.web import serve
from gaowenjian.workspace import Workspace


def test_csv_keeps_quotes_newlines_and_leading_zeros():
    rows = parse('名称,"他说""好""",00\n"第一行\n第二行",1\n')
    assert rows[0] == ["名称", '他说"好"', "00"]
    assert rows[1][0] == "第一行\n第二行"
    assert encode([["00", "a,b"]]) == '00,"a,b"\n'
    assert "00" in markdown_table([["值"], ["00"]])


def test_markdown_outline_tasks_and_table():
    text = "# 标题\n\n- [x] 完成\n\n| 值 | 数 |\n| --- | --- |\n| 00 | 1 |\n\n```mermaid\ngraph TD\n```\n"
    assert outline(text)[0]["title"] == "标题"
    html = render(text)
    assert "<h1>" in html and "checked" in html and "<td>00</td>" in html and "mermaid" in html


def test_latex_index_diagnostics_and_completion():
    text = "% !TeX root = main.tex\n\\section{开始}\n\\begin{figure}\n\\label{fig:one}\n\\cite{Knuth}\n"
    assert root_directive(text, Path("/work/chapter.tex")) == Path("/work/main.tex")
    indexed = parse_index(text)
    assert any(node["title"] == "开始" for node in indexed["nodes"])
    assert indexed["labels"] == ["fig:one"]
    assert indexed["citations"] == ["Knuth"]
    log = "chapter.tex:3: Undefined control sequence\n! Missing $ inserted.\nl.9 E = mc\nLaTeX Warning: Citation on input line 4\n"
    diagnostics = parse_log(log)
    assert diagnostics[0]["line"] == 3
    assert any(item["severity"] == "error" and item["line"] == 9 for item in diagnostics)
    assert any(item["severity"] == "warning" and item["line"] == 4 for item in diagnostics)
    completion = complete("\\sec", 4, [], [])
    assert completion["items"][0]["title"] == "\\section"
    paired = complete("\\begin{eq", 9, [], [])
    assert "\\end{equation}" in paired["items"][0]["insert"]


def test_conflict_and_unreadable_recovery(tmp_path: Path):
    original = tmp_path / "note.md"
    original.write_text("原稿\n", encoding="utf-8")
    workspace = Workspace(tmp_path / "data")
    tab = workspace.open_path(original)
    original.write_text("外部修改\n", encoding="utf-8")
    with pytest.raises(AppError, match="其他程序修改"):
        workspace.save(tab.id)
    assert original.read_text(encoding="utf-8") == "外部修改\n"
    original.unlink()
    with pytest.raises(AppError, match="另存为"):
        workspace.save(tab.id)

    blocked = tmp_path / "blocked"
    blocked.mkdir()
    (blocked / "recovery.json").write_text("{", encoding="utf-8")
    restored = Workspace(blocked)
    restored.new_text("markdown", "不能覆盖")
    assert (blocked / "recovery.json").read_text(encoding="utf-8") == "{"
    assert "无法读取" in restored.error or "保留" in restored.error


def test_notes_roundtrip_and_refusal(tmp_path: Path):
    store = NotesStore(tmp_path / "StickyNotes")
    note_id = store.create("例", "<b>你好</b>", "你好")
    store.metadata(note_id, {"color": "green", "group": "写作", "isPinned": True})
    store.trash(note_id)
    store.restore(note_id)
    reloaded = NotesStore(tmp_path / "StickyNotes")
    assert reloaded.notes[0]["plainText"] == "你好"
    assert reloaded.notes[0]["color"] == "green"
    assert reloaded.owned

    occupied = tmp_path / "occupied"
    occupied.mkdir()
    (occupied / "orphan.bin").write_bytes(b"keep")
    blocked = NotesStore(occupied)
    with pytest.raises(AppError, match="主记录缺失"):
        blocked.create("不会写", "", "")
    assert not (occupied / "notes.json").exists()
    assert (occupied / "orphan.bin").read_bytes() == b"keep"

    corrupt = tmp_path / "corrupt"
    corrupt.mkdir()
    (corrupt / "notes.json").write_text("{", encoding="utf-8")
    refused = NotesStore(corrupt)
    with pytest.raises(AppError, match="保留"):
        refused.create("x", "", "")
    assert (corrupt / "notes.json").read_text(encoding="utf-8") == "{"


def test_rtf_lossy_save_refuses_overwrite(tmp_path: Path):
    simple = parse_rtf(br"{\rtf1\ansi {\fonttbl{\f0 Arial;}} Hello \b bold}")
    assert "Hello" in simple["plain"] and "bold" in simple["plain"]
    assert not simple["lossy"]
    lossy = parse_rtf(br"{\rtf1\ansi Keep {\pict \bin6 binary} tail}")
    assert lossy["lossy"]
    path = tmp_path / "note.rtf"
    path.write_bytes(br"{\rtf1\ansi Keep {\pict \bin6 binary} tail}")
    workspace = Workspace(tmp_path / "data")
    tab = workspace.open_path(path)
    workspace.edit(tab.id, tab.text + " more", html="<b>more</b>")
    with pytest.raises(AppError, match="另存为"):
        workspace.save(tab.id)
    assert b"\\pict" in path.read_bytes()
    copy = tmp_path / "copy.rtf"
    workspace.save(tab.id, copy, as_copy=True)
    assert copy.read_bytes().startswith(b"{\\rtf1")
    assert from_html("<strong>加粗</strong>").startswith(b"{\\rtf1")


def test_office_content_and_legacy(tmp_path: Path):
    docx = _office_zip(tmp_path / "a.docx", {"[Content_Types].xml": "<Types/>", "word/document.xml": "<w:document xmlns:w='urn'><w:p><w:r><w:t>正文</w:t></w:r></w:p></w:document>"})
    word = read_document(docx.read_bytes(), "docx")
    assert word["parts"][0]["text"] == "正文"
    sheet = tmp_path / "a.xlsx"
    _office_zip(sheet, {
        "[Content_Types].xml": "<Types/>",
        "xl/workbook.xml": "<workbook><sheets><sheet name='一' sheetId='1' r:id='rId1' xmlns:r='urn'/></sheets></workbook>",
        "xl/_rels/workbook.xml.rels": "<Relationships><Relationship Id='rId1' Target='worksheets/sheet1.xml'/></Relationships>",
        "xl/worksheets/sheet1.xml": "<worksheet><sheetData><c r='A1' t='inlineStr'><is><t>00</t></is></c><c r='B1'><f>A1</f></c></sheetData></worksheet>",
    })
    excel = read_document(sheet.read_bytes(), "xlsx")
    assert excel["parts"][0]["cells"][0]["value"] == "00"
    assert "未保存公式结果" in excel["parts"][0]["cells"][1]["value"]
    legacy = read_document(b"\xd0\xcf\x11\xe0legacy", "doc")
    assert legacy["mode"] == "legacy"
    data = tmp_path / "data"
    record_dir = data / "Recovery" / "Office"
    record_dir.mkdir(parents=True)
    key = digest(str(tmp_path / "a.docx").encode())
    draft = record_dir / f"{key}.docx"
    draft.write_bytes(docx.read_bytes())
    (record_dir / f"{key}.docx.json").write_text("{", encoding="utf-8")
    workspace = Workspace(data)
    opened = workspace.open_path(docx)
    assert opened.preview["recovery"]["readable"] is False
    assert (record_dir / f"{key}.docx.json").read_text(encoding="utf-8") == "{"


def test_pdf_tools_keep_original_on_failure(tmp_path: Path):
    source = tmp_path / "a.pdf"
    _pdf(source, ["Hello PDF", "Second"])
    original = source.read_bytes()
    workspace = Workspace(tmp_path / "data")
    tab = workspace.open_path(source)
    assert search(tab.binary, "Hello")[0]["page"] == 1
    workspace.pdf_action(tab.id, "rotate", {"pages": [0], "degrees": 90})
    assert inspect(tab.binary)["pages"][0]["rotation"] % 360 == 90
    other = tmp_path / "b.pdf"
    _pdf(other, ["Merged"])
    workspace.pdf_action(tab.id, "merge", {"path": str(other)})
    assert len(inspect(tab.binary)["pages"]) >= 2
    png = _png(1, 1, [(255, 0, 0)])
    import base64
    workspace.pdf_action(tab.id, "image", {"page": 0, "contentBase64": base64.b64encode(png).decode(), "x": 40, "y": 40, "width": 20, "height": 20})
    workspace.pdf_action(tab.id, "text", {"page": 0, "text": "Note", "x": 72, "y": 72})
    assert source.read_bytes() == original
    workspace.save(tab.id)
    assert source.read_bytes() != original
    source.write_bytes(original)
    with pytest.raises(AppError, match="其他程序修改"):
        workspace.save(tab.id)
    exported, degraded = plain_pdf("OK 中文")
    assert degraded and PdfReader(__import__("io").BytesIO(exported)).pages


def test_handoff_validation_and_duplicate(tmp_path: Path):
    book = HandoffBook(tmp_path / "Handoff")
    package = _package(tmp_path / "one.gaoaction", "documents.newText", b"hello\n", "text/plain", expired=False)
    imported = book.import_package(package)
    assert imported["opened"][0]["text"] == "hello\n"
    again = book.import_package(package)
    assert again["duplicate"] is True
    expired = _package(tmp_path / "old.gaoaction", "documents.newText", b"no\n", "text/plain", expired=True)
    with pytest.raises(AppError, match="过期"):
        book.import_package(expired)
    bad = tmp_path / "bad.gaoaction"
    bad.mkdir()
    (bad / "manifest.json").write_text("{}", encoding="utf-8")
    (bad / "payload").mkdir()
    with pytest.raises(AppError):
        book.import_package(bad)
    traversal = tmp_path / "escape.zip"
    _zip_with(traversal, {"manifest.json": b"{}", "payload/../../x": b"no"})
    with pytest.raises(AppError, match="不安全"):
        book.import_package(traversal)


def test_http_session_writes_document(tmp_path: Path):
    workspace = Workspace(tmp_path / "data")
    server = serve(workspace, port=0, open_browser=False)
    try:
        page = _request(server, "/")
        assert page.status == 200
        token = page.headers.get("X-Test") or _token(page.body)
        assert "搞文件" in page.body.decode()
        created = _request(server, "/api/tabs/new", {"kind": "markdown", "text": "CI smoke document"}, token)
        assert created.status == 200
        target = tmp_path / "smoke.md"
        saved = _request(server, "/api/tabs/save", {"id": created.payload["result"]["id"], "path": str(target)}, token)
        assert saved.status == 200
        assert "CI smoke document" in target.read_text(encoding="utf-8")
        state = _request(server, "/api/state", token=token)
        assert any("CI smoke document" in tab["text"] for tab in state.payload["tabs"])
        denied = _request(server, "/api/state")
        assert denied.status == 403
        shutdown = _request(server, "/api/shutdown", {}, token)
        assert shutdown.status == 200
    finally:
        server.shutdown_requested.set()
        server.shutdown()
        server.server_close()


def test_compile_reports_missing_engine(tmp_path: Path, monkeypatch):
    monkeypatch.setattr(shutil, "which", lambda name: None)
    tex = tmp_path / "main.tex"
    tex.write_text("\\section{A}\n", encoding="utf-8")
    workspace = Workspace(tmp_path / "data")
    tab = workspace.open_path(tex)
    with pytest.raises(AppError, match="不会联网"):
        workspace.compile_latex(tab.id)


def _pdf(path: Path, lines: list[str]) -> None:
    writer = PdfWriter()
    for line in lines:
        writer.add_blank_page(width=300, height=300)
    path.write_bytes(_writer_bytes(writer))
    # 再写一层可检索文字，避免空白页没有文本层。
    from gaowenjian.pdfdoc import plain_pdf
    data, _ = plain_pdf("\n".join(lines))
    path.write_bytes(data)


def _writer_bytes(writer: PdfWriter) -> bytes:
    import io
    output = io.BytesIO()
    writer.write(output)
    return output.getvalue()


def _png(width: int, height: int, pixels: list[tuple[int, int, int]]) -> bytes:
    raw = b""
    for y in range(height):
        raw += b"\x00" + b"".join(bytes(pixels[y * width + x]) for x in range(width))
    def chunk(kind: bytes, data: bytes) -> bytes:
        return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data) & 0xFFFFFFFF)
    ihdr = struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0)
    return b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", ihdr) + chunk(b"IDAT", zlib.compress(raw)) + chunk(b"IEND", b"")


def _office_zip(path: Path, files: dict[str, str]) -> Path:
    import io
    import zipfile
    buffer = io.BytesIO()
    with zipfile.ZipFile(buffer, "w") as archive:
        for name, text in files.items():
            archive.writestr(name, text)
    path.write_bytes(buffer.getvalue())
    return path


def _package(path: Path, action: str, content: bytes, uti: str, expired: bool) -> Path:
    now = datetime.now(timezone.utc)
    created = now - timedelta(hours=2) if expired else now
    expires = created + timedelta(seconds=120)
    path.mkdir()
    payload = path / "payload"
    payload.mkdir()
    (payload / "input.txt").write_bytes(content)
    manifest = {
        "action": action,
        "createdAt": created.strftime("%Y-%m-%dT%H:%M:%SZ"),
        "expiresAt": expires.strftime("%Y-%m-%dT%H:%M:%SZ"),
        "items": [{"byteCount": len(content), "id": "input-1", "relativePath": "payload/input.txt", "sha256": digest(content), "uti": uti}],
        "kind": "request",
        "nonce": base64.b64encode(b"\x00" * 32).decode(),
        "parameters": {"suggestedTitle": "交接测试"},
        "references": [],
        "requestID": str(uuid.uuid4()),
        "schemaVersion": 1,
        "sourceBundleID": "com.gaoseries.FixtureSender",
        "targetBundleID": "com.gaoseries.GaoWenJian",
    }
    (path / "manifest.json").write_text(json.dumps(manifest), encoding="utf-8")
    return path


def _zip_with(path: Path, files: dict[str, bytes]) -> None:
    import zipfile
    with zipfile.ZipFile(path, "w") as archive:
        for name, content in files.items():
            archive.writestr(name, content)


class Response:
    def __init__(self, status: int, body: bytes, headers):
        self.status = status
        self.body = body
        self.headers = headers
        try:
            self.payload = json.loads(body.decode())
        except Exception:
            self.payload = None


def _request(server, path: str, body: dict | None = None, token: str | None = None) -> Response:
    data = None if body is None else json.dumps(body).encode()
    headers = {}
    if token:
        headers["X-Gao-Token"] = token
    if data is not None:
        headers["Content-Type"] = "application/json"
    request = urllib.request.Request(server.url.rstrip("/") + path, data=data, headers=headers, method="GET" if data is None else "POST")
    try:
        with urllib.request.urlopen(request, timeout=5) as response:
            return Response(response.status, response.read(), response.headers)
    except urllib.error.HTTPError as exc:
        return Response(exc.code, exc.read(), exc.headers)


def _token(body: bytes) -> str:
    text = body.decode()
    start = text.index('name="gao-token" content="') + len('name="gao-token" content="')
    return text[start:text.index('"', start)]
