import io
import zipfile

import pytest

from gaowenjian.errors import AppError
from gaowenjian.notes import NotesStore
from gaowenjian.workspace import Workspace


def test_note_store_detects_stale_edit_and_preserves_verified_attachment(tmp_path):
    notes = NotesStore(tmp_path / "StickyNotes")
    note_id = notes.create("初始", "<b>初始内容</b>", "初始内容")
    notes.attach(note_id, "附件.txt", b"isolated attachment")
    first = notes.snapshot()["notes"][0]["bodyDigest"]
    notes.update(note_id, "<b>当前内容</b>", "当前内容", expected=first, changes={"title": "更新"})
    with pytest.raises(AppError, match="其他窗口"):
        notes.update(note_id, "old", "old", expected=first, changes={"title": "过时标题"})
    assert not (notes.contents / f"{first}.rtfd").exists()
    loaded = NotesStore(tmp_path / "StickyNotes")
    snapshot = loaded.snapshot()["notes"][0]
    assert snapshot["title"] == "更新" and snapshot["html"] == "<b>当前内容</b>"
    path = tmp_path / "附件副本.txt"
    loaded.export_attachment(note_id, 0, path)
    assert path.read_bytes() == b"isolated attachment"
    with pytest.raises(AppError, match="已存在"):
        loaded.export_attachment(note_id, 0, path)


def _word_fixture(label):
    content = io.BytesIO()
    with zipfile.ZipFile(content, "w") as package:
        package.writestr("[Content_Types].xml", "<Types/>")
        package.writestr("word/document.xml", f"""<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
            <w:body><w:p><w:pPr><w:pStyle w:val="Heading1"/></w:pPr><w:r>
            <w:rPr><w:b/><w:color w:val="346B58"/></w:rPr><w:t>{label}</w:t></w:r></w:p>
            <w:tbl><w:tr><w:tc><w:p><w:r><w:t>表格内容</w:t></w:r></w:p></w:tc></w:tr></w:tbl></w:body></w:document>""")
    return content.getvalue()


def test_word_layout_and_reload_keep_original_read_only(tmp_path):
    profile = Workspace(tmp_path / "profile")
    source = tmp_path / "文档.docx"
    source.write_bytes(_word_fixture("隔离测试"))
    tab = profile.open_path(source)
    body, grid = tab.preview["layout"]
    assert body["style"] == "Heading1" and body["runs"][0]["bold"]
    assert grid["rows"] == [["表格内容"]]
    revised = _word_fixture("外部改动")
    source.write_bytes(revised)
    profile.reload_office(tab.id)
    assert tab.preview["layout"][0]["runs"][0]["text"] == "外部改动"
    with pytest.raises(AppError):
        profile.save(tab.id)
    assert source.read_bytes() == revised
