"""PDF 阅读与页面工具。重写前保留原字节；加密或无法解析时不改原件。"""

from __future__ import annotations

import io
import struct
import zlib
from pathlib import Path

from pypdf import PdfReader, PdfWriter
from pypdf.annotations import FreeText

from gaowenjian.errors import AppError

MAX_BYTES = 200 * 1024 * 1024
MAX_PIXELS = 80_000_000
MAX_IMAGE_BYTES = 64 * 1024 * 1024


def inspect(data: bytes) -> dict:
    reader = _reader(data)
    outline = _outline(reader.outline)
    pages = []
    for index, page in enumerate(reader.pages):
        text = page.extract_text() or ""
        pages.append({
            "number": index + 1,
            "rotation": int(page.rotation or 0),
            "width": float(page.mediabox.width),
            "height": float(page.mediabox.height),
            "text": text[:4000],
        })
    fields = []
    try:
        form = reader.get_fields() or {}
    except Exception:
        form = {}
    for name, field in form.items():
        value = field.get("/V")
        fields.append({"name": str(name), "value": "" if value is None else str(value)})
    return {
        "encrypted": False,
        "pages": pages,
        "outline": outline,
        "fields": fields,
        "message": "页面按文字查阅。Windows 版不栅格化原始页面，因此没有缩略图和双页图像；双页是相邻两页的文字对照。",
    }


def search(data: bytes, query: str) -> list[dict]:
    if not query:
        return []
    found = []
    for page in inspect(data)["pages"]:
        if query.casefold() in page["text"].casefold():
            found.append({"page": page["number"], "excerpt": _excerpt(page["text"], query)})
    return found


def transform(data: bytes, operation: str, payload: dict) -> bytes:
    reader = _reader(data)
    writer = PdfWriter()
    writer.append(reader)
    count = len(writer.pages)
    if operation == "rotate":
        degrees = int(payload.get("degrees") or 90)
        if degrees not in {90, 180, 270, -90}:
            raise AppError("旋转角度只能是 90、180 或 270。", "pdf")
        for number in _pages(payload, count):
            writer.pages[number].rotate(degrees)
    elif operation == "crop":
        box = payload.get("box") or []
        if len(box) != 4:
            raise AppError("裁剪需要 left、bottom、right、top 四个点。", "pdf")
        left, bottom, right, top = (float(item) for item in box)
        if right <= left or top <= bottom:
            raise AppError("裁剪区域无效。", "pdf")
        for number in _pages(payload, count):
            page = writer.pages[number]
            page.mediabox.lower_left = (left, bottom)
            page.mediabox.upper_right = (right, top)
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
        rebuilt = PdfWriter()
        for number in order:
            rebuilt.add_page(writer.pages[number])
        writer = rebuilt
    elif operation == "text":
        page_number = _one_page(payload, count)
        text = str(payload.get("text") or "")
        if not text or "\x00" in text:
            raise AppError("要插入的文字无效。", "pdf")
        if any(ord(char) > 255 for char in text):
            raise AppError("文字叠加使用 PDF 内置 Helvetica，不能嵌入中文。请改用批注无法覆盖的另存说明，或先在源文档中排版。", "pdf")
        x = float(payload.get("x") or 72)
        y = float(payload.get("y") or 72)
        size = int(payload.get("size") or 14)
        width = max(80.0, float(payload.get("width") or 240))
        height = max(24.0, float(payload.get("height") or 36))
        writer.add_annotation(page_number, FreeText(
            text=text,
            rect=(x, y, x + width, y + height),
            font_size=f"{size}pt",
        ))
    elif operation == "image":
        page_number = _one_page(payload, count)
        image = payload.get("image")
        if not isinstance(image, (bytes, bytearray)):
            raise AppError("缺少要插入的图片。", "image")
        image = bytes(image)
        if len(image) > MAX_IMAGE_BYTES:
            raise AppError("单张图片不能超过 64 MB。", "image")
        stamp = _image_overlay(image, writer.pages[page_number], payload)
        overlay = PdfReader(io.BytesIO(stamp))
        writer.pages[page_number].merge_page(overlay.pages[0])
    elif operation == "form":
        values = payload.get("values")
        if not isinstance(values, dict) or not values:
            raise AppError("没有要写入的表单字段。", "pdf")
        safe = {str(key): "" if value is None else str(value) for key, value in values.items()}
        writer.update_page_form_field_values(None, safe, auto_regenerate=False)
    else:
        raise AppError("不支持这个 PDF 操作。", "pdf")
    output = io.BytesIO()
    writer.write(output)
    result = output.getvalue()
    _reader(result)
    return result


def merge(documents: list[bytes]) -> bytes:
    if len(documents) < 2:
        raise AppError("合并至少需要两份 PDF。", "pdf")
    writer = PdfWriter()
    for data in documents:
        writer.append(_reader(data))
    output = io.BytesIO()
    writer.write(output)
    return output.getvalue()


def extract(data: bytes, pages: list[int]) -> bytes:
    reader = _reader(data)
    chosen = _pages({"pages": pages}, len(reader.pages))
    writer = PdfWriter()
    for number in chosen:
        writer.add_page(reader.pages[number])
    output = io.BytesIO()
    writer.write(output)
    return output.getvalue()


def split(data: bytes) -> list[bytes]:
    reader = _reader(data)
    parts = []
    for page in reader.pages:
        writer = PdfWriter()
        writer.add_page(page)
        output = io.BytesIO()
        writer.write(output)
        parts.append(output.getvalue())
    return parts


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


def _reader(data: bytes) -> PdfReader:
    if len(data) > MAX_BYTES:
        raise AppError("PDF 超过 200 MB，已停止读入内存。", "pdf")
    if not data.startswith(b"%PDF"):
        raise AppError("这不是 PDF 文件，原件未修改。", "pdf")
    try:
        reader = PdfReader(io.BytesIO(data), strict=False)
    except Exception as exc:
        raise AppError(f"PDF 无法读取，原件已保留：{exc}", "pdf") from exc
    if reader.is_encrypted:
        raise AppError("加密 PDF 不能在 Windows 版打开或改写。", "encrypted")
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


def _outline(nodes, depth: int = 0) -> list[dict]:
    result = []
    for node in nodes or []:
        if isinstance(node, list):
            result.extend(_outline(node, depth + 1))
            continue
        title = getattr(node, "title", None) or str(node)
        result.append({"title": str(title), "depth": depth})
    return result


def _excerpt(text: str, query: str) -> str:
    folded = text.casefold()
    at = folded.find(query.casefold())
    if at < 0:
        return text[:180]
    start = max(0, at - 40)
    return text[start:start + 180]


def _decode_image(data: bytes) -> tuple[int, int, bytes, int]:
    if data.startswith(b"\xff\xd8"):
        return _jpeg(data)
    if data.startswith(b"\x89PNG\r\n\x1a\n"):
        return _png(data)
    raise AppError("叠加图片目前接受 JPEG 和 PNG。", "image")


def _jpeg(data: bytes) -> tuple[int, int, bytes, int]:
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
            # 重新包进 Flate 需要像素。没有 JPEG 解码器时，改用 DCT 原样嵌入。
            return _jpeg_passthrough(data, width, height)
        index += length
    raise AppError("JPEG 缺少尺寸信息。", "image")


def _jpeg_passthrough(data: bytes, width: int, height: int) -> tuple[int, int, bytes, int]:
    # 用一个哨兵告诉 _image_overlay：samples 已是 JPEG，colors 为 0。
    return width, height, data, 0


def _image_overlay(image: bytes, page, payload: dict) -> bytes:
    width, height, samples, colors = _decode_image(image)
    if width * height > MAX_PIXELS:
        raise AppError("图片超过 8000 万像素。", "image")
    draw_w = float(payload.get("width") or min(240, float(page.mediabox.width) / 2))
    draw_h = float(payload.get("height") or draw_w * height / max(width, 1))
    x = float(payload.get("x") or 72)
    y = float(payload.get("y") or 72)
    page_w = float(page.mediabox.width)
    page_h = float(page.mediabox.height)
    if colors == 0:
        filter_name = "/DCTDecode"
        encoded = samples
        color = "/DeviceRGB"
    else:
        filter_name = "/FlateDecode"
        encoded = zlib.compress(samples)
        color = "/DeviceRGB" if colors == 3 else "/DeviceGray"
    stream = f"q {draw_w:.2f} 0 0 {draw_h:.2f} {x:.2f} {y:.2f} cm /Im0 Do Q".encode()
    objects = [
        b"<< /Type /Catalog /Pages 2 0 R >>",
        b"<< /Type /Pages /Count 1 /Kids [3 0 R] >>",
        (
            f"<< /Type /Page /Parent 2 0 R /MediaBox [0 0 {page_w:.2f} {page_h:.2f}] "
            f"/Resources << /XObject << /Im0 4 0 R >> >> /Contents 5 0 R >>"
        ).encode(),
        (
            f"<< /Type /XObject /Subtype /Image /Width {width} /Height {height} "
            f"/ColorSpace {color} /BitsPerComponent 8 /Filter {filter_name} /Length {len(encoded)} >>\nstream\n".encode()
            + encoded + b"\nendstream"
        ),
        b"<< /Length %d >>\nstream\n" % len(stream) + stream + b"\nendstream",
    ]
    return _assemble(objects)


def _png(data: bytes) -> tuple[int, int, bytes, int]:
    if data[12:16] != b"IHDR":
        raise AppError("PNG 缺少 IHDR。", "image")
    width, height, depth, color_type, comp, filt, interlace = struct.unpack(">IIBBBBB", data[16:29])
    if depth != 8 or comp != 0 or filt != 0 or interlace != 0 or color_type not in {0, 2, 6}:
        raise AppError("只接受 8 位、非隔行的灰阶或 RGB PNG。", "image")
    if width < 1 or height < 1 or width * height > MAX_PIXELS:
        raise AppError("PNG 尺寸无效或超过 8000 万像素。", "image")
    channels = {0: 1, 2: 3, 6: 4}[color_type]
    chunks = []
    index = 8
    while index + 8 <= len(data):
        length = int.from_bytes(data[index:index + 4], "big")
        kind = data[index + 4:index + 8]
        chunk = data[index + 8:index + 8 + length]
        if kind == b"IDAT":
            chunks.append(chunk)
        if kind == b"IEND":
            break
        index += 12 + length
    try:
        raw = zlib.decompress(b"".join(chunks))
    except zlib.error as exc:
        raise AppError("PNG 像素无法解压。", "image") from exc
    stride = width * channels
    rows = []
    position = 0
    previous = bytearray(stride)
    for _ in range(height):
        if position >= len(raw):
            raise AppError("PNG 像素不完整。", "image")
        filter_type = raw[position]
        position += 1
        row = bytearray(raw[position:position + stride])
        position += stride
        if len(row) != stride:
            raise AppError("PNG 行数据不完整。", "image")
        _unfilter(filter_type, row, previous, channels)
        previous = row
        if channels == 4:
            rgb = bytearray()
            for pixel in range(width):
                alpha = row[pixel * 4 + 3] / 255
                for channel in range(3):
                    rgb.append(int(row[pixel * 4 + channel] * alpha + 255 * (1 - alpha)))
            rows.append(bytes(rgb))
        else:
            rows.append(bytes(row))
    colors = 1 if channels == 1 else 3
    return width, height, b"".join(rows), colors


def _unfilter(filter_type: int, row: bytearray, previous: bytearray, channels: int) -> None:
    def left(pixel: int) -> int:
        return row[pixel - channels] if pixel >= channels else 0

    def up(pixel: int) -> int:
        return previous[pixel]

    def paeth(pixel: int) -> int:
        a = left(pixel)
        b = up(pixel)
        c = previous[pixel - channels] if pixel >= channels else 0
        estimate = a + b - c
        pa, pb, pc = abs(estimate - a), abs(estimate - b), abs(estimate - c)
        if pa <= pb and pa <= pc:
            return a
        if pb <= pc:
            return b
        return c

    for pixel in range(len(row)):
        predictor = 0
        if filter_type == 1:
            predictor = left(pixel)
        elif filter_type == 2:
            predictor = up(pixel)
        elif filter_type == 3:
            predictor = (left(pixel) + up(pixel)) // 2
        elif filter_type == 4:
            predictor = paeth(pixel)
        elif filter_type != 0:
            raise AppError("PNG 使用了无法还原的行过滤。", "image")
        row[pixel] = (row[pixel] + predictor) & 255


def image_info(data: bytes, extension: str) -> dict:
    if len(data) > MAX_IMAGE_BYTES:
        raise AppError("单张图片不能超过 64 MB。", "image")
    width = height = None
    preview = extension.lower() in {"png", "jpg", "jpeg", "gif", "webp", "bmp", "svg"}
    if data.startswith(b"\x89PNG\r\n\x1a\n") and len(data) >= 24:
        width, height = struct.unpack(">II", data[16:24])
    elif data.startswith(b"\xff\xd8"):
        try:
            width, height, _, _ = _jpeg(data)
        except AppError:
            width = height = None
    elif data.startswith(b"GIF") and len(data) >= 10:
        width, height = struct.unpack("<HH", data[6:10])
    if width and height and width * height > MAX_PIXELS:
        raise AppError("图片超过 8000 万像素。", "image")
    note = ""
    if extension.lower() in {"heic", "tif", "tiff"}:
        note = "浏览器通常不能直接显示 HEIC 或 TIFF。Windows 版不做格式转换，也不提供 OCR。"
        preview = False
    return {"width": width, "height": height, "preview": preview, "note": note, "bytes": len(data)}
