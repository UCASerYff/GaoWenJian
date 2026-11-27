from __future__ import annotations

import io
import urllib.error
import urllib.request

import pytest
from PIL import Image
from pypdf import PdfReader, PdfWriter
from pypdf.generic import ArrayObject, DecodedStreamObject, DictionaryObject, NameObject, NumberObject, RectangleObject, TextStringObject

from gaowenjian.errors import AppError
from gaowenjian.pdfdoc import inspect, merge, plain_pdf, render_page, search, transform
from gaowenjian.web import serve
from gaowenjian.workspace import Workspace


def _dict(**entries):
    return DictionaryObject({NameObject(f"/{key}"): value for key, value in entries.items()})


def _form_pdf() -> bytes:
    source, _ = plain_pdf("Hello PDF workspace\nSelect this line")
    writer = PdfWriter(clone_from=PdfReader(io.BytesIO(source)))
    writer.add_blank_page(width=500, height=400)
    writer.add_outline_item("第一章", 0)
    writer.add_outline_item("第二章", 1)
    font = writer._add_object(_dict(Type=NameObject("/Font"), Subtype=NameObject("/Type1"), BaseFont=NameObject("/Helvetica")))
    form = _dict(Fields=ArrayObject(), DA=TextStringObject("/Helv 12 Tf 0 g"), DR=_dict(Font=_dict(Helv=font)))
    writer.root_object[NameObject("/AcroForm")] = writer._add_object(form)

    def appearance(mark):
        obj = DecodedStreamObject()
        obj.update(_dict(Type=NameObject("/XObject"), Subtype=NameObject("/Form"), BBox=RectangleObject((0, 0, 20, 20))))
        obj.set_data(b"0 G 0.8 w 0.4 0.4 19.2 19.2 re S" + (b" 2 2 16 16 re f" if mark else b""))
        return writer._add_object(obj)

    def widget(page_number, box, field_type=None, name=None, state=None, parent=None, flags=None, **extra):
        annotation = _dict(Type=NameObject("/Annot"), Subtype=NameObject("/Widget"), Rect=RectangleObject(box), F=NumberObject(4), **extra)
        if field_type:
            annotation[NameObject("/FT")] = NameObject(field_type)
        if name:
            annotation[NameObject("/T")] = TextStringObject(name)
        if state:
            annotation[NameObject("/AP")] = _dict(N=DictionaryObject({NameObject("/Off"): appearance(False), NameObject(state): appearance(True)}))
            annotation[NameObject("/AS")] = NameObject("/Off")
        if parent:
            annotation[NameObject("/Parent")] = parent
        if flags:
            annotation[NameObject("/Ff")] = NumberObject(flags)
        annotation = writer.add_annotation(page_number, annotation)
        if name and parent is None:
            form["/Fields"].append(annotation.indirect_reference)
        return annotation.indirect_reference

    widget(0, (50, 700, 250, 725), "/Tx", "name", V=TextStringObject("Before"))
    widget(0, (50, 650, 70, 670), "/Btn", "agree", state="/Yes", V=NameObject("/Off"))
    radio = _dict(FT=NameObject("/Btn"), T=TextStringObject("plan"), Ff=NumberObject(1 << 15), V=NameObject("/Off"), Kids=ArrayObject())
    parent = writer._add_object(radio)
    form["/Fields"].append(parent)
    radio["/Kids"].extend([widget(0, (50, 600, 70, 620), state="/A", parent=parent),
                           widget(1, (50, 300, 70, 320), state="/B", parent=parent)])
    values = ArrayObject([ArrayObject([TextStringObject("a"), TextStringObject("第一项")]),
                          ArrayObject([TextStringObject("b"), TextStringObject("第二项")])])
    widget(0, (50, 550, 230, 575), "/Ch", "choice", flags=1 << 17, Opt=values, V=TextStringObject("a"))
    widget(0, (50, 450, 230, 530), "/Ch", "multi", flags=1 << 21, Opt=values, V=ArrayObject([TextStringObject("a")]))
    widget(0, (50, 350, 230, 375), "/Tx", "readonly", flags=1, V=TextStringObject("keep"))
    output = io.BytesIO()
    writer.write(output)
    return output.getvalue()


def test_interactive_fields_persist_with_appearance_and_survive_recovery(tmp_path):
    original = _form_pdf()
    source = tmp_path / "表单.pdf"
    source.write_bytes(original)
    data_dir = tmp_path / "isolated"
    workspace = Workspace(data_dir)
    tab = workspace.open_path(source)
    assert [field["type"] for field in tab.preview["fields"]] == ["text", "checkbox", "radio", "choice", "choice", "text"]
    values = {"name": "搞文件 Windows", "agree": "/Yes", "plan": "/B", "choice": "b", "multi": ["b", "a"]}
    workspace.pdf_action(tab.id, "form", {"values": values})
    assert source.read_bytes() == original
    assert tab.preview["canUndo"] and tab.dirty
    workspace.pdf_action(tab.id, "undo", {})
    assert tab.binary == original and not tab.dirty
    workspace.pdf_action(tab.id, "redo", {})
    restarted = Workspace(data_dir)
    restored = restarted.open_path(source)
    assert restored.binary == tab.binary and restored.dirty
    new_path = tmp_path / "已填写.pdf"
    restarted.save(restored.id, new_path, as_copy=True)
    assert source.read_bytes() == original
    assert not Workspace(data_dir).open_path(source).dirty
    result = new_path.read_bytes()
    reopened = PdfReader(io.BytesIO(result))
    canonical = reopened.get_fields()
    assert {name: canonical[name]["/V"] for name in values} == {**values, "multi": ["a", "b"]}
    unchecked = reopened.pages[0]["/Annots"][2].get_object()
    checked = reopened.pages[1]["/Annots"][0].get_object()
    assert unchecked["/AS"] == "/Off" and checked["/AS"] == "/B"
    assert checked["/Parent"]["/V"] == "/B"
    assert checked["/AP"]["/N"]["/B"].get_data()
    assert reopened.pages[0]["/Annots"][0].get_object()["/AP"]["/N"].get_data()
    before = render_page(original, 0, 595)
    after = render_page(result, 0, 595)
    assert before != after
    with Image.open(io.BytesIO(after)) as preview:
        assert preview.size == (595, 842)
        assert sum(1 for pixel in preview.crop((50, 117, 250, 142)).convert("RGB").getdata() if max(pixel) < 160) > 100
    with pytest.raises(AppError, match="不可编辑"):
        transform(result, "form", {"values": {"readonly": "no"}})
    with pytest.raises(AppError, match="选项无效"):
        transform(result, "form", {"values": {"plan": "/Unknown"}})


def test_page_operations_keep_forms_outlines_and_visible_crop():
    original = _form_pdf()
    reordered = transform(original, "reorder", {"order": [1, 0]})
    info = inspect(reordered)
    assert [page["width"] for page in info["pages"]] == [500, 595]
    assert [item["page"] for item in info["outline"]] == [1, 0]
    assert next(field for field in info["fields"] if field["name"] == "agree")["widgets"][0]["page"] == 1
    cropped = transform(reordered, "crop", {"pages": [0], "margins": [10, 20, 30, 40]})
    before = PdfReader(io.BytesIO(reordered)).pages[0]
    after = PdfReader(io.BytesIO(cropped)).pages[0]
    assert list(before.mediabox) == list(after.mediabox)
    assert list(after.cropbox) == [20, 30, 460, 390]
    assert inspect(cropped)["pages"][0]["width"] == 440


def test_merge_retains_duplicate_named_forms_as_separate_fields():
    first = _form_pdf()
    combined = merge([first, first])
    details = inspect(combined)
    assert len(details["pages"]) == 4
    names = {item["name"]: item for item in details["fields"]}
    assert names["name"]["widgets"][0]["page"] == 0
    assert names["附加文档1.name"]["widgets"][0]["page"] == 2
    updated = transform(combined, "form", {"values": {"name": "First", "附加文档1.name": "Second"}})
    values = {item["name"]: item["value"] for item in inspect(updated)["fields"]}
    assert values["name"] == "First" and values["附加文档1.name"] == "Second"


def test_raster_service_protects_tabs_and_displays_unicode_and_markup(tmp_path):
    source = tmp_path / "批注.pdf"
    source.write_bytes(_form_pdf())
    workspace = Workspace(tmp_path / "profile")
    tab = workspace.open_path(source)
    before = render_page(tab.binary, 0, 595)
    hit = search(tab.binary, "Select this line")[0]
    assert hit["page"] == 1 and hit["rects"]
    x1, y1, x2, y2 = hit["rects"][0]
    workspace.pdf_action(tab.id, "markup", {"kind": "highlight", "page": 0, "selection": [x1 - 2, y1 - 3, x2 + 2, y2 + 3]})
    workspace.pdf_action(tab.id, "text", {"page": 0, "text": "搞文件 批注", "x": 110, "y": 500, "color": "#7b1129"})
    assert [item["title"] for item in tab.preview["annotations"]] == ["高亮", "文字"]
    assert tab.preview["annotations"][-1]["text"] == "搞文件 批注"
    server = serve(workspace, open_browser=False)
    try:
        page = f"{server.url}api/pdf/page?tab={tab.id}&page=0&width=595"
        with pytest.raises(urllib.error.HTTPError) as unauthorized:
            urllib.request.urlopen(page, timeout=5)
        assert unauthorized.value.code == 403
        request = urllib.request.Request(page, headers={"X-Gao-Token": server.token})
        with urllib.request.urlopen(request, timeout=5) as response:
            assert response.getheader("Content-Type") == "image/png"
            output = response.read()
        assert output != before
        with Image.open(io.BytesIO(output)).convert("RGB") as preview:
            assert sum(1 for red, green, blue in preview.crop((110, 317, 248, 341)).getdata() if red > green * 1.3 and red > blue * 1.3) > 40
    finally:
        server.shutdown()
        server.server_close()


def test_password_is_session_only_and_cannot_change_encrypted_pdf(tmp_path):
    writer = PdfWriter(clone_from=PdfReader(io.BytesIO(_form_pdf())))
    writer.encrypt("isolated-password", algorithm="RC4-128")
    source = tmp_path / "encrypted.pdf"
    writer.write(source)
    original = source.read_bytes()
    workspace = Workspace(tmp_path / "profile")
    tab = workspace.open_path(source)
    assert tab.preview["locked"]
    with pytest.raises(AppError, match="密码无效"):
        workspace.pdf_action(tab.id, "unlock", {"password": "invalid"})
    workspace.pdf_action(tab.id, "unlock", {"password": "isolated-password"})
    assert not tab.preview["locked"] and tab.preview["encrypted"]
    assert "isolated-password" not in str(workspace.snapshot())
    assert render_page(workspace.pdf_preview_bytes(tab.id)[0], 0, 250, workspace.pdf_preview_bytes(tab.id)[1]).startswith(b"\x89PNG")
    with pytest.raises(AppError, match="仅供阅读"):
        workspace.pdf_action(tab.id, "rotate", {"pages": [0]})
    with pytest.raises(AppError, match="仅供阅读"):
        workspace.save(tab.id)
    assert source.read_bytes() == original


def test_signature_and_conflicting_prior_recovery_keep_originals(tmp_path):
    writer = PdfWriter(clone_from=PdfReader(io.BytesIO(_form_pdf())))
    writer.root_object[NameObject("/Perms")] = _dict(DocMDP=_dict())
    source = tmp_path / "protected.pdf"
    writer.write(source)
    original = source.read_bytes()
    workspace = Workspace(tmp_path / "profile")
    tab = workspace.open_path(source)
    workspace.pdf_action(tab.id, "rotate", {"pages": [0], "degrees": 90})
    with pytest.raises(AppError, match="另存副本"):
        workspace.save(tab.id)
    assert source.read_bytes() == original
    draft_path = workspace._pdf_dir(source) / "draft.pdf"
    draft = draft_path.read_bytes()
    changed = _form_pdf()
    source.write_bytes(changed)
    new_workspace = Workspace(tmp_path / "profile")
    new_tab = new_workspace.open_path(source)
    assert new_tab.preview["canRecover"] and not new_tab.dirty
    new_workspace.pdf_action(new_tab.id, "rotate", {"pages": [1], "degrees": 90})
    assert draft_path.read_bytes() == draft
    destination = tmp_path / "conflicting-draft.pdf"
    new_workspace.pdf_action(new_tab.id, "recovery-copy", {"path": str(destination)})
    assert destination.read_bytes() == draft
    assert source.read_bytes() == changed
