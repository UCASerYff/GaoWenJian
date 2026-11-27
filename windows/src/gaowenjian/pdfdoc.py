"""PDF 阅读与页面工具。重写前保留原字节；加密或无法解析时不改原件。"""

from __future__ import annotations

import io
import math
import os
import re
import threading
import struct
from contextlib import closing
from pathlib import Path

from pypdf import PdfReader, PdfWriter
from pypdf.generic import (
    ArrayObject, DecodedStreamObject, DictionaryObject, FloatObject,
    NameObject, NumberObject, RectangleObject, TextStringObject,
)

from gaowenjian.errors import AppError

MAX_BYTES = 200 * 1024 * 1024
MAX_PIXELS = 80_000_000
MAX_IMAGE_BYTES = 64 * 1024 * 1024
_PDFIUM = threading.Lock()


def inspect(data: bytes, password: str | None = None) -> dict:
    reader = _reader(data, password, allow_locked=True)
    locked = reader.is_encrypted and password is None
    if locked:
        return {"locked": True, "encrypted": True, "pages": [], "fields": [], "outline": []}
    try:
        outline = _outline(reader, reader.outline)
    except Exception:
        outline = []
    pages = []
    annotations = []
    for index, page in enumerate(reader.pages):
        box = list(map(float, page.cropbox))
        width, height = box[2] - box[0], box[3] - box[1]
        rotation = int(page.rotation or 0) % 360
        if rotation in {90, 270}:
            width, height = height, width
        pages.append({
            "number": index + 1,
            "rotation": rotation,
            "width": width,
            "height": height,
            "box": box,
        })
        annotations.extend(_annotation_details(page, index))
    fields, _ = _form_details(reader)
    acroform = reader.root_object.get("/AcroForm")
    return {
        "encrypted": reader.is_encrypted,
        "locked": False,
        "pages": pages,
        "outline": outline,
        "fields": fields,
        "annotations": annotations,
        "signed": any(field["type"] == "signature" for field in fields) or "/Perms" in reader.root_object,
        "xfa": acroform is not None and "/XFA" in acroform.get_object(),
    }


def search(data: bytes, query: str, password: str | None = None) -> list[dict]:
    if not query:
        return []
    import pypdfium2 as pdfium

    found: list[dict] = []
    with _PDFIUM, closing(pdfium.PdfDocument(data, password=password)) as document:
        for page_index in range(len(document)):
            with closing(document[page_index]) as page, closing(page.get_textpage()) as text:
                with closing(text.search(query, match_case=False)) as matches:
                    while hit := matches.get_next():
                        start, count = hit
                        rects = [list(text.get_rect(i)) for i in range(text.count_rects(start, count))]
                        context_start = max(0, start - 36)
                        context_count = min(text.count_chars() - context_start, count + 85)
                        found.append({"page": page_index + 1, "excerpt": text.get_text_range(context_start, context_count), "rects": rects})
                        if len(found) == 500:
                            return found
    return found


def render_page(data: bytes, page: int, width: int, password: str | None = None) -> bytes:
    """Rasterize one visible page without rewriting the editable document."""
    import pypdfium2 as pdfium

    if len(data) > MAX_BYTES or not 96 <= width <= 3000 or page < 0:
        raise AppError("PDF 预览参数超出支持范围。", "pdf")
    try:
        with _PDFIUM, closing(pdfium.PdfDocument(data, password=password)) as document:
            document.init_forms()
            if page >= len(document):
                raise AppError("PDF 预览页码超出范围。", "pdf")
            with closing(document[page]) as opened:
                page_width, page_height = opened.get_size()
                if page_width <= 0 or page_height <= 0:
                    raise AppError("PDF 页面尺寸无效。", "pdf")
                scale = min(width / page_width, 4200 / page_height)
                with closing(opened.render(scale=scale, draw_annots=True, may_draw_forms=True)) as bitmap:
                    output = io.BytesIO()
                    bitmap.to_pil().save(output, format="PNG")
                    return output.getvalue()
    except (pdfium.PdfiumError, ValueError, OSError) as exc:
        raise AppError(f"PDF 页面无法渲染：{exc}", "pdf") from exc


def _text_selection(data: bytes, page_index: int, selection) -> list[list[float]]:
    import pypdfium2 as pdfium

    if not isinstance(selection, list) or len(selection) != 4:
        raise AppError("请选择有效的文字区域。", "pdf")
    left, bottom, right, top = map(float, selection)
    if not all(map(math.isfinite, (left, bottom, right, top))) or right <= left or top <= bottom:
        raise AppError("请选择有效的文字区域。", "pdf")
    result: list[list[float]] = []
    try:
        with _PDFIUM, closing(pdfium.PdfDocument(data)) as document, closing(document[page_index]) as page, closing(page.get_textpage()) as text:
            if not text.get_text_bounded(left, bottom, right, top).strip():
                return []
            runs = []
            start = None
            count = min(text.count_chars(), 150_000)
            for index in range(count):
                x1, y1, x2, y2 = text.get_charbox(index)
                hit = (left <= (x1 + x2) / 2 <= right and bottom <= (y1 + y2) / 2 <= top) and x1 != x2 and y1 != y2
                if hit and start is None:
                    start = index
                elif not hit and start is not None:
                    runs.append((start, index - start))
                    start = None
            if start is not None:
                runs.append((start, count - start))
            for index, length in runs:
                result.extend(list(text.get_rect(j)) for j in range(text.count_rects(index, length)))
                if len(result) >= 500:
                    return result[:500]
    except (pdfium.PdfiumError, ValueError) as exc:
        raise AppError("PDF 选区无法读取。", "pdf") from exc
    return result


def transform(data: bytes, operation: str, payload: dict) -> bytes:
    reader = _reader(data)
    writer = PdfWriter(clone_from=reader)
    count = len(writer.pages)
    values = None
    if operation == "rotate":
        degrees = int(payload.get("degrees") or 90)
        if degrees not in {90, 180, 270, -90}:
            raise AppError("旋转角度只能是 90、180 或 270。", "pdf")
        for number in _pages(payload, count):
            writer.pages[number].rotate(degrees)
    elif operation == "crop":
        for number in _pages(payload, count):
            page = writer.pages[number]
            _crop(page, payload)
    elif operation == "delete":
        removing = sorted(_pages(payload, count), reverse=True)
        if len(removing) >= count:
            raise AppError("至少保留一页。", "pdf")
        for number in removing:
            writer.remove_page(number)
    elif operation == "reorder":
        order = [int(item) for item in payload.get("order") or []]
        if sorted(order) != list(range(count)):
            raise AppError("排序必须包含每一页且不能重复。", "pdf")
        root_pages = writer.root_object["/Pages"]
        reordered = ArrayObject([writer.pages[number].indirect_reference for number in order])
        root_pages[NameObject("/Kids")] = reordered
        for reference in reordered:
            reference.get_object()[NameObject("/Parent")] = root_pages.indirect_reference
    elif operation in {"text", "note", "image", "markup", "annotation-delete", "annotation-edit"}:
        page_number = _one_page(payload, count)
        if operation == "markup" and payload.get("selection") is not None:
            payload = {**payload, "rects": _text_selection(data, page_number, payload["selection"])}
        _edit_annotation(writer, page_number, operation, payload)
    elif operation == "form":
        values = _fill_form(writer, payload.get("values"))
    else:
        raise AppError("不支持这个 PDF 操作。", "pdf")
    output = io.BytesIO()
    writer.write(output)
    result = output.getvalue()
    reopened = _reader(result)
    if values is not None:
        _verify_form(reopened, values)
    return result


def merge(documents: list[bytes]) -> bytes:
    if len(documents) < 2:
        raise AppError("合并至少需要两份 PDF。", "pdf")
    original, *remaining = [_reader(data) for data in documents]
    writer = PdfWriter(clone_from=original)
    names = {item["name"] for item in _form_details(original)[0]}
    for index, reader in enumerate(remaining, start=1):
        fields, _ = _form_details(reader)
        if any(item["name"] in names for item in fields):
            suffix = f"附加文档{index}"
            while any(name == suffix or name.startswith(suffix + ".") for name in names):
                suffix += "_"
            reader.add_form_topname(suffix)
            fields, _ = _form_details(reader)
        names.update(item["name"] for item in fields)
        writer.append(reader)
    output = io.BytesIO()
    writer.write(output)
    return output.getvalue()


def extract(data: bytes, pages: list[int]) -> bytes:
    reader = _reader(data)
    chosen = _pages({"pages": pages}, len(reader.pages))
    writer = PdfWriter()
    writer.append(reader, pages=chosen)
    output = io.BytesIO()
    writer.write(output)
    return output.getvalue()


def split(data: bytes) -> list[bytes]:
    reader = _reader(data)
    parts = []
    for page_index in range(len(reader.pages)):
        writer = PdfWriter()
        writer.append(reader, pages=[page_index])
        output = io.BytesIO()
        writer.write(output)
        parts.append(output.getvalue())
    return parts


def _object_key(obj):
    reference = getattr(obj, "indirect_reference", None)
    return (reference.idnum, reference.generation) if reference is not None else id(obj)


def _pdf_value(value):
    if isinstance(value, ArrayObject):
        return [str(item) for item in value]
    return "" if value is None else str(value)


def _button_appearances(widget) -> dict:
    appearance = widget.get("/AP")
    if appearance is None:
        return {}
    normal = appearance.get_object().get("/N")
    normal = normal.get_object() if normal is not None else None
    return normal if isinstance(normal, DictionaryObject) and not hasattr(normal, "get_data") else {}


def _form_details(source) -> tuple[list[dict], dict]:
    form = source.root_object.get("/AcroForm")
    if form is None:
        return [], {}
    form = form.get_object()
    canonical = {}
    seen = set()

    def visit(reference, prefix="", inherited_type=None, inherited_flags=0):
        field = reference.get_object()
        key = _object_key(field)
        if key in seen:
            return
        seen.add(key)
        part = str(field.get("/T") or "")
        name = ".".join(piece for piece in (prefix, part) if piece)
        field_type = field.get("/FT", inherited_type)
        flags = int(field.get("/Ff", inherited_flags))
        children = [item for item in field.get("/Kids", []) if item.get_object().get("/T") is not None]
        if children:
            for child in children:
                visit(child, name, field_type, flags)
        elif name and field_type:
            canonical[key] = (name, field, field_type, flags, [])

    for reference in form.get("/Fields", []):
        visit(reference)
    for page_index, page in enumerate(source.pages):
        for reference in page.get("/Annots", []):
            widget = reference.get_object()
            if widget.get("/Subtype") != "/Widget":
                continue
            current = widget
            ancestors = set()
            while _object_key(current) not in ancestors:
                key = _object_key(current)
                ancestors.add(key)
                if key in canonical:
                    canonical[key][4].append((page_index, widget))
                    break
                parent = current.get("/Parent")
                if parent is None:
                    break
                current = parent.get_object()

    fields = []
    by_name = {}
    duplicate_names = set()
    for name, field, field_type, flags, widgets in canonical.values():
        kind = {"/Tx": "text", "/Ch": "choice", "/Sig": "signature"}.get(str(field_type), "unknown")
        if field_type == "/Btn":
            kind = "button" if flags & (1 << 16) else "radio" if flags & (1 << 15) else "checkbox"
        options = []
        if kind == "choice":
            for option in field.get("/Opt", []):
                value, label = option if isinstance(option, ArrayObject) and len(option) == 2 else (option, option)
                options.append({"value": str(value), "label": str(label)})
        widget_details = []
        for page_index, widget in widgets:
            states = [str(value) for value in _button_appearances(widget) if value != "/Off"]
            rect = widget.get("/Rect", [])
            if len(rect) == 4:
                widget_details.append({"page": page_index, "rect": list(map(float, rect)), "states": states})
            if kind in {"radio", "checkbox"}:
                for value in states:
                    if not any(item["value"] == value for item in options):
                        options.append({"value": value, "label": value.removeprefix("/")})
        value = _pdf_value(field.get("/V"))
        if kind in {"radio", "checkbox"} and not value:
            value = "/Off"
        multi = kind == "choice" and bool(flags & (1 << 21))
        if multi and isinstance(value, str):
            value = [value] if value else []
        info = {"name": name, "label": str(field.get("/TU") or name), "type": kind,
                "value": value, "widgets": widget_details, "options": options, "multi": multi,
                "editable": kind == "choice" and bool(flags & (1 << 18)),
                "multiline": kind == "text" and bool(flags & (1 << 12)),
                "password": kind == "text" and bool(flags & (1 << 13)),
                "maxLength": int(field.get("/MaxLen", 0) or 0),
                "readonly": bool(flags & 1) or kind in {"button", "signature", "unknown"}
                or not widgets or (kind in {"radio", "checkbox"} and not options) or "/XFA" in form}
        fields.append(info)
        if name in by_name:
            duplicate_names.add(name)
        by_name[name] = (field, widgets, info)
    for info in fields:
        if info["name"] in duplicate_names:
            info["readonly"] = True
    return fields, by_name


def _fill_form(writer: PdfWriter, values) -> dict:
    if not isinstance(values, dict) or not values:
        raise AppError("没有要写入的表单字段。", "pdf")
    _, fields = _form_details(writer)
    checked = {}
    for name, value in values.items():
        if name not in fields or fields[name][2]["readonly"]:
            raise AppError(f"字段不可编辑：{name}", "pdf")
        field, widgets, info = fields[name]
        options = [option["value"] for option in info["options"]]
        kind = info["type"]
        if kind in {"checkbox", "radio"}:
            if value not in ["/Off", *options]:
                raise AppError(f"字段选项无效：{name}", "pdf")
            field[NameObject("/V")] = NameObject(value)
            applied = False
            same_value_radio = int(field.get("/Ff", 0)) & (1 << 25)
            for _, widget in widgets:
                available = _button_appearances(widget)
                selected = value != "/Off" and value in available
                if kind == "radio" and applied and not same_value_radio:
                    selected = False
                widget[NameObject("/AS")] = NameObject(value if selected else "/Off")
                if widget is not field:
                    widget.pop(NameObject("/V"), None)
                applied |= selected
        else:
            items = value if info["multi"] and isinstance(value, list) else [value]
            if any(not isinstance(item, str) or "\x00" in item or len(item) > (info["maxLength"] or 20_000) for item in items):
                raise AppError(f"字段内容超长或无效：{name}", "pdf")
            if kind == "choice" and not info["editable"] and any(item != "" and item not in options for item in items):
                raise AppError(f"字段选项无效：{name}", "pdf")
            if info["multi"]:
                if not isinstance(value, list):
                    raise AppError(f"多选字段需要一组选项：{name}", "pdf")
                indices = sorted({options.index(item) for item in items if item in options})
                value = [options[index] for index in indices]
                field[NameObject("/I")] = ArrayObject([NumberObject(index) for index in indices])
                field[NameObject("/V")] = ArrayObject([TextStringObject(item) for item in value])
            else:
                field[NameObject("/V")] = TextStringObject(value)
                field.pop(NameObject("/I"), None)
            for page_index, widget in widgets:
                if widget is not field:
                    widget.pop(NameObject("/V"), None)
                _paint_form_text(writer, writer.pages[page_index], field, widget, info, value)
        checked[name] = value
    writer.set_need_appearances_writer(False)
    return checked


def _paint_form_text(writer, page, field, widget, info, value) -> None:
    labels = {option["value"]: option["label"] for option in info["options"]}
    lines = [labels.get(item, item) for item in value] if isinstance(value, list) else [labels.get(value, value)]
    standard = not info["password"] and all(line.isascii() for line in lines) and all(key == label for key, label in labels.items())
    if standard:
        try:
            writer._update_field_annotation(page, field, widget)
            return
        except (TypeError, ValueError, KeyError, AttributeError):
            pass
    from PIL import Image, ImageDraw

    left, bottom, right, top = map(float, widget["/Rect"])
    scale = 3
    width, height = min(4000, round(abs(right - left) * scale)), min(4000, round(abs(top - bottom) * scale))
    if min(width, height) < 2 or width * height > 8_000_000:
        raise AppError("表单控件尺寸无效，无法绘制输入内容。", "pdf")
    da = str(widget.get_inherited("/DA", writer.root_object["/AcroForm"].get("/DA", "")))
    match = re.search(r"(?:^|\s)(\d+(?:\.\d+)?)\s+Tf\b", da)
    size = float(match.group(1)) * scale if match else 0
    text = "\n".join(lines)
    if info["password"]:
        text = "•" * len(text)
    size = max(6, min(144, round(size or (min(height * 0.74, 36) if "\n" in text else height * 0.74))))
    font = _text_font(text, size)
    image = Image.new("RGBA", (width, height))
    draw = ImageDraw.Draw(image)
    appearance = widget.get("/MK", DictionaryObject()).get_object()

    def color(name):
        values = [max(0, min(255, round(float(item) * 255))) for item in appearance.get(name, [])]
        return tuple(values * 3 + [255]) if len(values) == 1 else tuple(values + [255]) if len(values) == 3 else None

    bg, border = color("/BG"), color("/BC")
    if bg or border:
        draw.rectangle((0, 0, width - 1, height - 1), fill=bg, outline=border, width=scale)
    if text:
        region = draw.multiline_textbbox((0, 0), text, font=font, spacing=1)
        alignment = int(widget.get_inherited("/Q", 0))
        text_width = region[2] - region[0]
        x = max(scale, (width - text_width) / 2 if alignment == 1 else width - text_width - scale if alignment == 2 else scale)
        y = max(scale, (height - (region[3] - region[1])) / 2) if "\n" not in text else scale
        draw.multiline_text((x - region[0], y - region[1]), text, font=font, fill="#202020", spacing=1)
    widget[NameObject("/AP")] = DictionaryObject({NameObject("/N"): _image_appearance(writer, image)})


def _verify_form(reader, expected: dict) -> None:
    _, fields = _form_details(reader)
    for name, value in expected.items():
        if name not in fields or fields[name][2]["value"] != value:
            raise AppError(f"保存后的表单字段核验失败：{name}", "pdf")
        field, widgets, info = fields[name]
        selected = []
        for _, widget in widgets:
            if widget is not field and "/V" in widget:
                raise AppError(f"表单控件与记录不一致：{name}", "pdf")
            appearance = widget.get("/AP")
            if appearance is None or "/N" not in appearance.get_object():
                raise AppError(f"表单字段缺少可显示外观：{name}", "pdf")
            if info["type"] in {"checkbox", "radio"}:
                state = widget.get("/AS")
                if state not in _button_appearances(widget):
                    raise AppError(f"表单控件缺少选中状态外观：{name}", "pdf")
                if state != "/Off":
                    selected.append(str(state))
        if info["type"] in {"checkbox", "radio"} and set(selected) != ({value} if value != "/Off" else set()):
            raise AppError(f"表单控件的显示与保存值不一致：{name}", "pdf")


def _crop(page, payload: dict) -> None:
    visible = list(map(float, page.cropbox))
    margins = payload.get("margins")
    if margins is not None:
        if not isinstance(margins, list) or len(margins) != 4:
            raise AppError("请输入上、左、下、右四个裁剪边距。", "pdf")
        top, left, bottom, right = (float(value) for value in margins)
        if min(top, left, bottom, right) < 0:
            raise AppError("裁剪边距不能小于零。", "pdf")
        # View-relative margins follow the rotated page as displayed.
        sides = [top, right, bottom, left]
        turn = (int(page.rotation or 0) // 90) % 4
        top, right, bottom, left = sides[turn:] + sides[:turn]
        box = [visible[0] + left, visible[1] + bottom, visible[2] - right, visible[3] - top]
    else:
        box = payload.get("box") or []
        if not isinstance(box, list) or len(box) != 4:
            raise AppError("请输入四个裁剪边界。", "pdf")
        box = [float(value) for value in box]
    left, bottom, right, top = box
    if not all(math.isfinite(value) for value in box) or right - left < 20 or top - bottom < 20:
        raise AppError("裁剪后至少保留 20 × 20 点的可见区域。", "pdf")
    if left < visible[0] or bottom < visible[1] or right > visible[2] or top > visible[3]:
        raise AppError("裁剪区域超出当前可见页。", "pdf")
    page.cropbox = RectangleObject(box)


_ANNOTATION_NAMES = {
    "/FreeText": "文字", "/Text": "便签", "/Stamp": "图章", "/Highlight": "高亮",
    "/Underline": "下划线", "/StrikeOut": "删除线", "/Ink": "手写批注", "/Square": "矩形批注",
    "/Circle": "椭圆批注", "/Line": "线段批注", "/Polygon": "多边形批注",
}


def _annotation_details(page, page_index: int) -> list[dict]:
    result = []
    for index, reference in enumerate(page.get("/Annots", [])):
        annotation = reference.get_object()
        subtype = str(annotation.get("/Subtype") or "")
        if subtype not in _ANNOTATION_NAMES:
            continue
        rect = annotation.get("/Rect", [])
        if len(rect) != 4:
            continue
        image = subtype == "/Stamp" and str(annotation.get("/GaoWenJianImage") or "") == "1"
        readonly = bool(int(annotation.get("/F") or 0) & (64 | 128 | 512))
        result.append({"page": page_index, "index": index, "type": subtype, "text": str(annotation.get("/Contents") or ""),
                       "title": "图片" if image else _ANNOTATION_NAMES[subtype], "rect": list(map(float, rect)),
                       "readonly": readonly, "canMove": subtype in {"/FreeText", "/Text"} or image,
                       "canEdit": subtype in {"/FreeText", "/Text"}, "size": int(annotation.get("/GaoSize", 14)),
                       "color": str(annotation.get("/GaoColor") or "#202020"), "image": image})
    return result


def _edit_annotation(writer: PdfWriter, page_number: int, operation: str, payload: dict) -> None:
    from PIL import Image, ImageDraw, ImageOps

    page = writer.pages[page_number]
    annotation = None
    existing = None
    original_rect = None
    if operation in {"annotation-delete", "annotation-edit"}:
        index = int(payload.get("index", -1))
        existing = next((item for item in _annotation_details(page, page_number) if item["index"] == index), None)
        if existing is None or existing["readonly"]:
            raise AppError("当前批注不可修改，请重新定位。", "pdf")
        if operation == "annotation-delete":
            del page["/Annots"][index]
            return
        annotation = page["/Annots"][index].get_object()
        original_rect = existing["rect"]
        if "text" in payload:
            if not existing["canEdit"]:
                raise AppError("当前批注不支持编辑文字。", "pdf")
            operation = "note" if existing["type"] == "/Text" else "text"
        elif not existing["canMove"]:
            raise AppError("当前批注不支持移动或调整尺寸。", "pdf")

    box = list(map(float, page.cropbox))
    x = float(payload.get("x", original_rect[0] if original_rect else 72))
    y = float(payload.get("y", original_rect[1] if original_rect else 72))
    width = float(payload.get("width", original_rect[2] - original_rect[0] if original_rect else 0))
    height = float(payload.get("height", original_rect[3] - original_rect[1] if original_rect else 0))
    rotation = int(page.rotation or 0) % 360
    appearance = None
    text = ""
    if operation in {"text", "note"}:
        text = payload.get("text", "")
        if not isinstance(text, str) or not text.strip() or "\x00" in text or len(text) > 4_000:
            raise AppError("请输入 1 到 4000 个有效文字字符。", "pdf")
        if operation == "note":
            subtype = "/Text"
            width = height = 22
            appearance = _note_appearance(writer)
        else:
            subtype = "/FreeText"
            size = int(payload.get("size", 14))
            color = str(payload.get("color", "#202020"))
            if not 6 <= size <= 96 or not re.fullmatch(r"#[0-9a-fA-F]{6}", color):
                raise AppError("请输入 6 到 96 点字号及有效颜色。", "pdf")
            scale = 3
            font = _text_font(text, size * scale)
            draft = ImageDraw.Draw(Image.new("RGBA", (1, 1)))
            text_rect = draft.multiline_textbbox((0, 0), text, font=font, spacing=size)
            pixels = (max(1, text_rect[2] - text_rect[0] + 12), max(1, text_rect[3] - text_rect[1] + 12))
            if max(pixels) > 10000 or pixels[0] * pixels[1] > 24_000_000:
                raise AppError("文字对象过大，请换行、缩小字号或拆成多段。", "pdf")
            image = Image.new("RGBA", pixels)
            ImageDraw.Draw(image).multiline_text((6 - text_rect[0], 6 - text_rect[1]), text, font=font, fill=color, spacing=size)
            width, height = width if "width" in payload else pixels[0] / scale, height if "height" in payload else pixels[1] / scale
            appearance = _image_appearance(writer, image, rotation)
            if rotation in {90, 270}:
                width, height = height, width
    elif operation == "image":
        subtype = "/Stamp"
        raw = payload.get("image")
        if not isinstance(raw, (bytes, bytearray)) or not raw or len(raw) > MAX_IMAGE_BYTES:
            raise AppError("请选择不超过 64 MB 的图片。", "image")
        try:
            with Image.open(io.BytesIO(raw)) as source:
                if source.width * source.height > MAX_PIXELS:
                    raise AppError("叠加图片超过 8000 万像素。", "image")
                image = ImageOps.exif_transpose(source).convert("RGBA")
                image.thumbnail((4096, 4096), Image.Resampling.LANCZOS)
                width = width or min(180, (box[2] - box[0]) / 2)
                height = height or width * image.height / image.width
                appearance = _image_appearance(writer, image, rotation)
                if rotation in {90, 270}:
                    width, height = height, width
        except (OSError, ValueError, Image.DecompressionBombError) as exc:
            raise AppError("图片无法读取。", "image") from exc
    elif operation == "markup":
        subtype = {"highlight": "/Highlight", "underline": "/Underline", "strike": "/StrikeOut"}.get(payload.get("kind"))
        rects = payload.get("rects")
        if subtype is None or not isinstance(rects, list) or not 1 <= len(rects) <= 500:
            raise AppError("请先选定要标记的文字。", "pdf")
        quads = []
        for rect in rects:
            if len(rect) != 4 or not all(math.isfinite(float(item)) for item in rect):
                raise AppError("所选区域坐标无效。", "pdf")
            left, bottom, right, top = list(map(float, rect))
            if left >= right or bottom >= top:
                raise AppError("所选区域坐标无效。", "pdf")
            quads.append((left, bottom, right, top))
        x, y = min(rect[0] for rect in quads), min(rect[1] for rect in quads)
        width, height = max(rect[2] for rect in quads) - x, max(rect[3] for rect in quads) - y
    else:
        subtype = existing["type"]
        if existing["image"] and "width" in payload:
            height = width * (original_rect[3] - original_rect[1]) / max(1, original_rect[2] - original_rect[0])

    if any(not math.isfinite(value) for value in [x, y, width, height]) or width <= 0 or height <= 0:
        raise AppError("对象的位置或尺寸无效。", "pdf")
    if operation != "markup":
        factor = min(1, (box[2] - box[0]) / width, (box[3] - box[1]) / height)
        width, height = width * factor, height * factor
        x, y = max(box[0], min(x, box[2] - width)), max(box[1], min(y, box[3] - height))
    if annotation is None:
        annotation = DictionaryObject({NameObject("/Type"): NameObject("/Annot"),
                                       NameObject("/Subtype"): NameObject(subtype), NameObject("/F"): NumberObject(4)})
        writer.add_annotation(page_number, annotation)
        annotation = page["/Annots"][-1].get_object()
    annotation[NameObject("/Rect")] = RectangleObject([x, y, x + width, y + height])
    if appearance is not None:
        annotation[NameObject("/AP")] = DictionaryObject({NameObject("/N"): appearance})
    if operation in {"text", "note"}:
        annotation[NameObject("/Contents")] = TextStringObject(text)
        if operation == "text":
            annotation[NameObject("/GaoSize")] = NumberObject(size)
            annotation[NameObject("/GaoColor")] = TextStringObject(color)
            annotation[NameObject("/DA")] = TextStringObject(f"/Helvetica {size} Tf 0 g")
        else:
            annotation[NameObject("/Name")] = NameObject("/Comment")
    elif operation == "image":
        annotation[NameObject("/GaoWenJianImage")] = TextStringObject("1")
        annotation[NameObject("/Contents")] = TextStringObject("插入图片")
    elif operation == "markup":
        points = [value for left, bottom, right, top in quads for value in (left, top, right, top, left, bottom, right, bottom)]
        annotation[NameObject("/QuadPoints")] = ArrayObject([FloatObject(value) for value in points])
        color = (1, 0.82, 0.15) if subtype == "/Highlight" else (0.8, 0.18, 0.14)
        annotation[NameObject("/C")] = ArrayObject([FloatObject(value) for value in color])


def _image_appearance(writer: PdfWriter, image, rotation: int = 0):
    def image_stream(pixels, color_space):
        stream = DecodedStreamObject()
        stream.set_data(pixels.tobytes())
        stream.update({NameObject("/Type"): NameObject("/XObject"), NameObject("/Subtype"): NameObject("/Image"),
                       NameObject("/Width"): NumberObject(pixels.width), NameObject("/Height"): NumberObject(pixels.height),
                       NameObject("/ColorSpace"): NameObject(color_space), NameObject("/BitsPerComponent"): NumberObject(8)})
        return stream.flate_encode()

    rgb = image_stream(image.convert("RGB"), "/DeviceRGB")
    if image.getchannel("A").getextrema() != (255, 255):
        rgb[NameObject("/SMask")] = writer._add_object(image_stream(image.getchannel("A"), "/DeviceGray"))
    appearance = DecodedStreamObject()
    matrix = {90: b"0 1 -1 0 1 0 cm ", 180: b"-1 0 0 -1 1 1 cm ", 270: b"0 -1 1 0 0 1 cm "}.get(rotation, b"")
    appearance.set_data(b"q " + matrix + b"/Appearance Do Q")
    appearance.update({NameObject("/Type"): NameObject("/XObject"), NameObject("/Subtype"): NameObject("/Form"),
                       NameObject("/BBox"): RectangleObject([0, 0, 1, 1]),
                       NameObject("/Resources"): DictionaryObject({NameObject("/XObject"): DictionaryObject({
                           NameObject("/Appearance"): writer._add_object(rgb)})})})
    return writer._add_object(appearance)


def _note_appearance(writer: PdfWriter):
    appearance = DecodedStreamObject()
    appearance.set_data(b"q 1 0.84 0.33 rg 0.53 0.35 0.08 RG 1 w 1 1 20 20 re B 5 15 m 17 15 l 5 11 m 17 11 l 5 7 m 13 7 l S Q")
    appearance.update({NameObject("/Type"): NameObject("/XObject"), NameObject("/Subtype"): NameObject("/Form"),
                       NameObject("/BBox"): RectangleObject([0, 0, 22, 22])})
    return writer._add_object(appearance)


def _text_font(text: str, size: int):
    from PIL import ImageFont

    fonts = Path(os.environ.get("WINDIR", r"C:\Windows")) / "Fonts"
    font_files = [fonts / "msyh.ttc", fonts / "simsun.ttc", fonts / "simhei.ttf", Path("/usr/share/fonts/opentype/noto/NotoSansCJK-Regular.ttc")]
    path = next((location for location in font_files if location.is_file()), None)
    if path is not None:
        return ImageFont.truetype(path, size)
    if not text.isascii():
        raise AppError("系统缺少可用于 PDF 叠加的中文字体。请安装微软雅黑后重试。", "pdf")
    return ImageFont.load_default(size)


def plain_pdf(text: str) -> tuple[bytes, bool]:
    """用内置字体写纯文本 PDF。不能编码的字符会被替换，并返回降级标记。"""
    degraded = False
    encoded_lines = []
    for raw_line in text.replace("\r\n", "\n").replace("\r", "\n").split("\n"):
        line = []
        for char in raw_line:
            if 32 <= ord(char) <= 126 and char not in "\\()":
                line.append(char)
            elif char in "\\()":
                line.append("\\" + char)
            else:
                line.append("?")
                degraded = True
        encoded_lines.append("".join(line))
    wrapped: list[str] = []
    for line in encoded_lines:
        while len(line) > 90:
            wrapped.append(line[:90])
            line = line[90:]
        wrapped.append(line)
    pages: list[list[str]] = []
    current: list[str] = []
    for line in wrapped:
        current.append(line)
        if len(current) == 46:
            pages.append(current)
            current = []
    if current or not pages:
        pages.append(current)
    objects: list[bytes] = []

    def add(body: bytes) -> int:
        objects.append(body)
        return len(objects)

    catalog = add(b"")
    pages_id = add(b"")
    font_id = add(b"<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>")
    page_ids = []
    content_ids = []
    for lines in pages:
        commands = ["BT", "/F1 11 Tf", "50 780 Td", "14 TL"]
        for line in lines:
            commands.append(f"({line}) Tj")
            commands.append("T*")
        commands.append("ET")
        stream = "\n".join(commands).encode("ascii")
        content_ids.append(add(b"<< /Length %d >>\nstream\n" % len(stream) + stream + b"\nendstream"))
        page_ids.append(add(b""))
    kids = " ".join(f"{number} 0 R" for number in page_ids)
    objects[pages_id - 1] = f"<< /Type /Pages /Count {len(page_ids)} /Kids [{kids}] >>".encode()
    objects[catalog - 1] = f"<< /Type /Catalog /Pages {pages_id} 0 R >>".encode()
    for page_id, content_id in zip(page_ids, content_ids):
        objects[page_id - 1] = (
            f"<< /Type /Page /Parent {pages_id} 0 R /MediaBox [0 0 595 842] "
            f"/Resources << /Font << /F1 {font_id} 0 R >> >> /Contents {content_id} 0 R >>"
        ).encode()
    return _assemble(objects), degraded


def _assemble(objects: list[bytes]) -> bytes:
    output = bytearray(b"%PDF-1.4\n")
    offsets = [0]
    for number, body in enumerate(objects, start=1):
        offsets.append(len(output))
        output.extend(f"{number} 0 obj\n".encode())
        output.extend(body)
        output.extend(b"\nendobj\n")
    xref = len(output)
    output.extend(f"xref\n0 {len(objects) + 1}\n".encode())
    output.extend(b"0000000000 65535 f \n")
    for offset in offsets[1:]:
        output.extend(f"{offset:010d} 00000 n \n".encode())
    output.extend(f"trailer << /Size {len(objects) + 1} /Root 1 0 R >>\nstartxref\n{xref}\n%%EOF".encode())
    return bytes(output)


def _reader(data: bytes, password: str | None = None, *, allow_locked: bool = False) -> PdfReader:
    if len(data) > MAX_BYTES:
        raise AppError("PDF 超过 200 MB，已停止读入内存。", "pdf")
    if not data.startswith(b"%PDF"):
        raise AppError("这不是 PDF 文件，原件未修改。", "pdf")
    try:
        reader = PdfReader(io.BytesIO(data), strict=False)
    except Exception as exc:
        raise AppError(f"PDF 无法读取，原件已保留：{exc}", "pdf") from exc
    if reader.is_encrypted:
        if password is not None:
            try:
                valid = reader.decrypt(password)
            except Exception as exc:
                raise AppError("此 PDF 的加密方式当前无法读取。", "encrypted") from exc
            if not valid:
                raise AppError("PDF 密码无效。", "encrypted")
        elif not allow_locked:
            raise AppError("加密 PDF 只允许解锁后阅读。", "encrypted")
    return reader


def _pages(payload: dict, count: int) -> list[int]:
    raw = payload.get("pages")
    if raw is None:
        raw = list(range(count))
    numbers = []
    for item in raw:
        number = int(item)
        if number < 0 or number >= count:
            raise AppError("页码超出范围。", "pdf")
        if number not in numbers:
            numbers.append(number)
    if not numbers:
        raise AppError("没有选中的页面。", "pdf")
    return numbers


def _one_page(payload: dict, count: int) -> int:
    pages = _pages({"pages": [payload.get("page", 0)]}, count)
    return pages[0]


def _outline(reader: PdfReader, nodes, depth: int = 0) -> list[dict]:
    result = []
    for node in nodes or []:
        if isinstance(node, list):
            result.extend(_outline(reader, node, depth + 1))
            continue
        title = getattr(node, "title", None) or str(node)
        try:
            page = reader.get_destination_page_number(node)
        except (AttributeError, TypeError, ValueError):
            page = None
        result.append({"title": str(title), "depth": depth, "page": page})
    return result


def _jpeg_size(data: bytes) -> tuple[int, int]:
    index = 2
    while index + 4 < len(data):
        if data[index] != 0xFF:
            break
        while index < len(data) and data[index] == 0xFF:
            index += 1
        if index >= len(data):
            break
        marker = data[index]
        index += 1
        if marker in {0xD8, 0xD9}:
            continue
        if index + 2 > len(data):
            break
        length = int.from_bytes(data[index:index + 2], "big")
        if marker in {0xC0, 0xC1, 0xC2} and index + 7 < len(data):
            components = data[index + 7]
            height = int.from_bytes(data[index + 3:index + 5], "big")
            width = int.from_bytes(data[index + 5:index + 7], "big")
            if components != 3 or width < 1 or height < 1:
                raise AppError("只接受 8 位 RGB JPEG。", "image")
            return width, height
        index += length
    raise AppError("JPEG 缺少尺寸信息。", "image")


def image_info(data: bytes, extension: str) -> dict:
    if len(data) > MAX_IMAGE_BYTES:
        raise AppError("单张图片不能超过 64 MB。", "image")
    width = height = None
    preview = extension.lower() in {"png", "jpg", "jpeg", "gif", "webp", "bmp", "svg"}
    if data.startswith(b"\x89PNG\r\n\x1a\n") and len(data) >= 24:
        width, height = struct.unpack(">II", data[16:24])
    elif data.startswith(b"\xff\xd8"):
        try:
            width, height = _jpeg_size(data)
        except AppError:
            width = height = None
    elif data.startswith(b"GIF") and len(data) >= 10:
        width, height = struct.unpack("<HH", data[6:10])
    if width and height and width * height > MAX_PIXELS:
        raise AppError("图片超过 8000 万像素。", "image")
    note = ""
    if extension.lower() in {"tif", "tiff"}:
        from PIL import Image

        try:
            with Image.open(io.BytesIO(data)) as image:
                width, height = image.size
            if width * height > MAX_PIXELS:
                raise AppError("图片超过 8000 万像素。", "image")
            preview = True
        except (OSError, Image.DecompressionBombError):
            note = "无法解码这张 TIFF 图片。"
    if extension.lower() in {"heic", "heif"}:
        note = "内置查看器无法解码 HEIC。可在资源管理器中打开，或交给搞操作识别文字。"
    return {"width": width, "height": height, "preview": preview, "note": note, "bytes": len(data)}
