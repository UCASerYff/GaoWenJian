"""RTF 子集读写。遇到无法无损保留的控制字时拒绝覆盖原件。"""

from __future__ import annotations

import re

from gaowenjian.errors import AppError

_SKIP_DESTINATIONS = {"fonttbl", "colortbl", "stylesheet", "info", "listtable", "listoverridetable", "rsidtbl", "generator", "xmlnstbl"}
_KNOWN = {
    "rtf", "ansi", "ansicpg", "mac", "pc", "pca", "uc", "u", "par", "line", "tab",
    "b", "i", "ul", "ulnone", "uldb", "strike", "fs", "f", "pard", "plain", "sl",
    "sa", "sb", "fi", "li", "ri", "qc", "ql", "qr", "qj", "lang", "langfe", "loch",
    "hich", "dbch", "super", "sub", "nosupersub", "cf", "cb", "highlight", "expnd",
    "expndtw", "kerning", "outl", "shad", "scaps", "caps", "v", "emdash", "endash",
    "lquote", "rquote", "ldblquote", "rdblquote", "bullet", "emspace", "enspace",
    "qmspace", "~", "_", "-", "ltrch", "rtlch", "noproof",
}


def parse(data: bytes) -> dict:
    if not data.startswith(b"{\\rtf"):
        raise AppError("这不是 RTF 文件。", "rtf")
    text = data.decode("latin1", errors="replace")
    lossy = False
    plain: list[str] = []
    html: list[str] = []
    bold = italic = underline = False
    skip_depth = None
    depth = 0
    index = 0
    uc = 1

    def set_style() -> None:
        tags = []
        if bold:
            tags.append("strong")
        if italic:
            tags.append("em")
        if underline:
            tags.append("u")
        return tags

    open_tags: list[str] = []

    def close_style() -> None:
        while open_tags:
            html.append(f"</{open_tags.pop()}>")

    def open_style() -> None:
        nonlocal open_tags
        wanted = set_style()
        if open_tags == wanted:
            return
        close_style()
        for tag in wanted:
            html.append(f"<{tag}>")
            open_tags.append(tag)

    while index < len(text):
        char = text[index]
        if char == "{":
            depth += 1
            index += 1
            if index < len(text) and text[index] == "\\":
                name, _arg, index = _read_control(text, index)
                if name in _SKIP_DESTINATIONS or name == "*" or name == "pict":
                    if name == "pict":
                        lossy = True
                    skip_depth = depth
            continue
        if char == "}":
            if skip_depth == depth:
                skip_depth = None
            depth -= 1
            index += 1
            continue
        if skip_depth is not None:
            index += 1
            continue
        if char == "\\":
            if index + 1 < len(text) and text[index + 1] in "\\{}":
                open_style()
                literal = text[index + 1]
                plain.append(literal)
                html.append(_escape(literal))
                index += 2
                continue
            if index + 1 < len(text) and text[index + 1] == "'":
                hex_code = text[index + 2:index + 4]
                try:
                    decoded = bytes([int(hex_code, 16)]).decode("latin1")
                except ValueError:
                    decoded = ""
                    lossy = True
                open_style()
                plain.append(decoded)
                html.append(_escape(decoded))
                index += 4
                continue
            name, arg, index = _read_control(text, index)
            if name == "u" and arg is not None:
                code = int(arg) % 65536
                open_style()
                character = chr(code)
                plain.append(character)
                html.append(_escape(character))
                index += uc
                continue
            if name == "par" or name == "line":
                close_style()
                plain.append("\n")
                html.append("<br>")
                continue
            if name == "tab":
                open_style()
                plain.append("\t")
                html.append(" ")
                continue
            if name == "b":
                bold = arg != "0"
            elif name == "i":
                italic = arg != "0"
            elif name in {"ul", "uldb"}:
                underline = True
            elif name == "ulnone":
                underline = False
            elif name == "plain" or name == "pard":
                bold = italic = underline = False
            elif name == "uc" and arg is not None:
                uc = int(arg)
            elif name == "pict":
                lossy = True
                skip_depth = depth
            elif name not in _KNOWN:
                lossy = True
            continue
        if char in "\r\n":
            index += 1
            continue
        open_style()
        plain.append(char)
        html.append(_escape(char))
        index += 1
    close_style()
    return {"plain": "".join(plain), "html": "".join(html), "lossy": lossy}


def _read_control(text: str, index: int) -> tuple[str, str | None, int]:
    index += 1
    if index >= len(text):
        return "", None, index
    if not text[index].isalpha() and text[index] not in "-":
        symbol = text[index]
        return symbol, None, index + 1
    start = index
    while index < len(text) and text[index].isalpha():
        index += 1
    name = text[start:index]
    arg = None
    if index < len(text) and (text[index].isdigit() or text[index] == "-"):
        arg_start = index
        index += 1
        while index < len(text) and text[index].isdigit():
            index += 1
        arg = text[arg_start:index]
    if index < len(text) and text[index] == " ":
        index += 1
    return name, arg, index


def from_html(fragment: str) -> bytes:
    plain_parts: list[str] = []
    tokens = re.split(r"(<[^>]+>)", fragment)
    bold = italic = underline = False
    body = ["{\\rtf1\\ansi\\deff0", "{\\fonttbl{\\f0 Segoe UI;}}", "\\f0\\fs30 "]

    def emit(text: str) -> None:
        prefix = ""
        if bold:
            prefix += "\\b "
        if italic:
            prefix += "\\i "
        if underline:
            prefix += "\\ul "
        encoded = []
        for char in text:
            if char == "\n":
                encoded.append("\\par ")
            elif ord(char) < 128 and char not in "\\{}":
                encoded.append(char)
            elif char in "\\{}":
                encoded.append("\\" + char)
            else:
                encoded.append(f"\\u{ord(char)}?")
        if prefix:
            body.append("{" + prefix + "".join(encoded) + "}")
        else:
            body.append("".join(encoded))
        plain_parts.append(text)

    for token in tokens:
        if not token:
            continue
        if token.startswith("<"):
            tag = token.strip("<>/ ").split()[0].lower()
            closing = token.startswith("</")
            if tag in {"strong", "b"}:
                bold = not closing
            elif tag in {"em", "i"}:
                italic = not closing
            elif tag == "u":
                underline = not closing
            elif tag == "br":
                body.append("\\par ")
                plain_parts.append("\n")
            continue
        emit(_unescape(token))
    body.append("}")
    return "".join(body).encode("ascii", errors="backslashreplace")


def _escape(text: str) -> str:
    return text.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")


def _unescape(text: str) -> str:
    return text.replace("&lt;", "<").replace("&gt;", ">").replace("&amp;", "&")
