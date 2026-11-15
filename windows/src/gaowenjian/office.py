"""Office 只读内容查阅。不新建、不修改、不覆盖 Office 原件，不执行宏。"""

from __future__ import annotations

import zipfile
from xml.etree import ElementTree as ET

from gaowenjian.errors import AppError
from gaowenjian.safety import digest

_OLE = b"\xd0\xcf\x11\xe0"
_TEXT_LIMIT = 2_000_000


def read_document(path_bytes: bytes, extension: str) -> dict:
    extension = extension.lower().lstrip(".")
    if path_bytes.startswith(_OLE) or extension in {"doc", "xls", "ppt", "pps"}:
        return {
            "mode": "legacy",
            "editable": False,
            "message": "旧版二进制 Office 文档在 Windows 版只标记为只读，没有版式预览。请用本机 Word、Excel、PowerPoint 或 LibreOffice 打开，原件不会被改写。",
            "parts": [],
        }
    if not zipfile.is_zipfile(__import__("io").BytesIO(path_bytes)):
        raise AppError("无法识别这个 Office 文档，原件未修改。", "office")
    try:
        archive = zipfile.ZipFile(__import__("io").BytesIO(path_bytes))
    except zipfile.BadZipFile as exc:
        raise AppError("Office 压缩包无法读取，原件未修改。", "office") from exc
    names = archive.namelist()
    _reject_paths(names)
    if any(name.endswith("EncryptionInfo") or name == "EncryptedPackage" for name in names):
        raise AppError("文档已加密或受保护，Windows 版不能打开。请用原办公软件查看。", "encrypted")
    macros = any(name.endswith("vbaProject.bin") for name in names)
    if "[Content_Types].xml" not in names and "mimetype" not in names:
        raise AppError("这不是有效的 Office 或 OpenDocument 压缩包。", "office")
    if "mimetype" in names and b"opendocument" in archive.read("mimetype"):
        return _odf(archive, macros)
    if extension in {"docx", "docm", "dotx", "dotm"} or "word/document.xml" in names:
        return _word(archive, macros)
    if extension in {"xlsx", "xlsm", "xltx", "xltm"} or "xl/workbook.xml" in names:
        return _excel(archive, macros)
    if extension in {"pptx", "pptm", "potx", "potm", "ppsx"} or "ppt/presentation.xml" in names:
        return _powerpoint(archive, macros)
    if extension in {"odt", "ods", "odp"}:
        return _odf(archive, macros)
    raise AppError("这个压缩包没有可查阅的 Office 正文，原件未修改。", "office")


def _reject_paths(names: list[str]) -> None:
    if len(names) > 50000:
        raise AppError("文档包含过多文件，已停止读取。", "office")
    for name in names:
        parts = name.replace("\\", "/").split("/")
        if name.startswith("/") or ".." in parts or any(part == "" for part in parts[:-1] if False):
            raise AppError("文档压缩包包含不安全的路径，无法打开。", "office")
        if ".." in parts or name.startswith("\\"):
            raise AppError("文档压缩包包含不安全的路径，无法打开。", "office")


def _local(tag: str) -> str:
    return tag.rsplit("}", 1)[-1]


def _text_of(element: ET.Element, names: set[str]) -> str:
    chunks = []
    for node in element.iter():
        if _local(node.tag) in names and node.text:
            chunks.append(node.text)
    return "".join(chunks)


def _banner(macros: bool, layout: str) -> str:
    text = layout
    if macros:
        text += " 检测到宏，只作静态查阅，不执行 VBA。"
    return text


def _word(archive: zipfile.ZipFile, macros: bool) -> dict:
    root = ET.fromstring(archive.read("word/document.xml"))
    paragraphs = []
    for paragraph in root.iter():
        if _local(paragraph.tag) != "p":
            continue
        text = _text_of(paragraph, {"t"})
        if text:
            paragraphs.append(text)
        if sum(len(item) for item in paragraphs) > _TEXT_LIMIT:
            break
    return {
        "mode": "word",
        "editable": False,
        "macros": macros,
        "message": _banner(macros, "Word 内容查阅只列出正文段落。图片、页眉页脚、修订和完整排版请用原办公软件查看。"),
        "parts": [{"title": f"段落 {index + 1}", "text": text} for index, text in enumerate(paragraphs)],
    }


def _excel(archive: zipfile.ZipFile, macros: bool) -> dict:
    shared: list[str] = []
    if "xl/sharedStrings.xml" in archive.namelist():
        root = ET.fromstring(archive.read("xl/sharedStrings.xml"))
        for item in root:
            if _local(item.tag) == "si":
                shared.append(_text_of(item, {"t"}))
    workbook = ET.fromstring(archive.read("xl/workbook.xml"))
    rels = ET.fromstring(archive.read("xl/_rels/workbook.xml.rels"))
    targets = {}
    for rel in rels:
        if _local(rel.tag) != "Relationship":
            continue
        targets[rel.attrib.get("Id")] = rel.attrib.get("Target", "")
    sheets = []
    for sheet in workbook.iter():
        if _local(sheet.tag) != "sheet":
            continue
        relation = sheet.attrib.get("{http://schemas.openxmlformats.org/officeDocument/2006/relationships}id") or sheet.attrib.get("id")
        # Attribute names keep the namespace in ElementTree as {uri}name when Clark notation is used.
        relation = next((value for key, value in sheet.attrib.items() if key.endswith("}id") or key == "r:id"), relation)
        target = targets.get(relation, "")
        path = target if target.startswith("xl/") else "xl/" + target.lstrip("/")
        hidden = sheet.attrib.get("state", "visible") != "visible"
        cells = []
        if path in archive.namelist():
            worksheet = ET.fromstring(archive.read(path))
            for cell in worksheet.iter():
                if _local(cell.tag) != "c":
                    continue
                address = cell.attrib.get("r", "")
                kind = cell.attrib.get("t", "n")
                raw = ""
                formula = None
                for child in cell:
                    if _local(child.tag) == "v" and child.text:
                        raw = child.text
                    elif _local(child.tag) == "f" and child.text:
                        formula = child.text
                    elif _local(child.tag) == "is":
                        raw = _text_of(child, {"t"})
                        kind = "inlineStr"
                if kind == "s" and raw.isdigit() and int(raw) < len(shared):
                    display = shared[int(raw)]
                else:
                    display = raw
                if formula and not display:
                    display = "文件未保存公式结果"
                cells.append({"address": address, "value": display, "formula": formula or ""})
                if len(cells) > 5000:
                    break
        sheets.append({
            "title": ("隐藏 · " if hidden else "") + sheet.attrib.get("name", "工作表"),
            "hidden": hidden,
            "cells": cells,
        })
    return {
        "mode": "sheet",
        "editable": False,
        "macros": macros,
        "message": _banner(macros, "Excel 内容查阅显示单元格原值、公式和文件里已保存的计算结果，不重算、不刷新外部数据。"),
        "parts": sheets,
    }


def _powerpoint(archive: zipfile.ZipFile, macros: bool) -> dict:
    presentation = ET.fromstring(archive.read("ppt/presentation.xml"))
    rels = ET.fromstring(archive.read("ppt/_rels/presentation.xml.rels"))
    targets = {}
    for rel in rels:
        if _local(rel.tag) != "Relationship":
            continue
        targets[rel.attrib.get("Id")] = rel.attrib.get("Target", "")
    slides = []
    for node in presentation.iter():
        if _local(node.tag) != "sldId":
            continue
        relation = next((value for key, value in node.attrib.items() if key.endswith("}id")), "")
        target = targets.get(relation, "")
        path = "ppt/" + target.lstrip("/") if not target.startswith("ppt/") else target
        texts = []
        if path in archive.namelist():
            slide = ET.fromstring(archive.read(path))
            for shape in slide.iter():
                if _local(shape.tag) != "sp":
                    continue
                body = next((child for child in shape.iter() if _local(child.tag) == "txBody"), None)
                if body is None:
                    continue
                paragraphs = []
                for paragraph in body:
                    if _local(paragraph.tag) == "p":
                        paragraphs.append(_text_of(paragraph, {"t"}))
                joined = "\n".join(part for part in paragraphs if part)
                if joined:
                    texts.append(joined)
        slides.append({"title": texts[0].splitlines()[0] if texts else "空白幻灯片", "text": "\n\n".join(texts)})
    return {
        "mode": "slides",
        "editable": False,
        "macros": macros,
        "message": _banner(macros, "PowerPoint 内容查阅只列出文字框。图片、母版、动画和视频请用原办公软件查看。"),
        "parts": [{"title": f"第 {index + 1} 张 · {slide['title']}", "text": slide["text"]} for index, slide in enumerate(slides)],
    }


def _odf(archive: zipfile.ZipFile, macros: bool) -> dict:
    if "content.xml" not in archive.namelist():
        raise AppError("OpenDocument 缺少 content.xml，原件未修改。", "office")
    root = ET.fromstring(archive.read("content.xml"))
    paragraphs = []
    for node in root.iter():
        if _local(node.tag) in {"p", "h"}:
            text = "".join(node.itertext()).strip()
            if text:
                paragraphs.append(text)
            if sum(len(item) for item in paragraphs) > _TEXT_LIMIT:
                break
    return {
        "mode": "odf",
        "editable": False,
        "macros": macros,
        "message": _banner(macros, "OpenDocument 只提取文字，没有版式预览。"),
        "parts": [{"title": f"段落 {index + 1}", "text": text} for index, text in enumerate(paragraphs)],
    }


def package_digest(data: bytes) -> str:
    return digest(data)
