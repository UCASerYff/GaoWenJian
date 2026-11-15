"""Markdown 大纲与本地预览。公式和 Mermaid 保留源码，不拉取在线脚本。"""

from __future__ import annotations

import html
import re

_HEADING = re.compile(r"^(#{1,6})\s+(.*)$")
_FENCE = re.compile(r"^```([\w-]*)\s*$")
_UL = re.compile(r"^(\s*)[-*+]\s+\[([ xX])\]\s+(.*)$")
_LI = re.compile(r"^(\s*)([-*+]|\d+\.)\s+(.*)$")
_QUOTE = re.compile(r"^>\s?(.*)$")
_HR = re.compile(r"^(\*\s*){3,}$|^(\-\s*){3,}$|^(_\s*){3,}$")


def outline(text: str) -> list[dict]:
    nodes = []
    for index, line in enumerate(text.splitlines(), start=1):
        match = _HEADING.match(line.strip())
        if match:
            nodes.append({"level": len(match.group(1)), "title": match.group(2).strip(), "line": index})
    return nodes


def render(text: str) -> str:
    lines = text.splitlines()
    blocks: list[str] = []
    footnotes: list[tuple[str, str]] = []
    index = 0
    while index < len(lines):
        line = lines[index]
        fence = _FENCE.match(line.strip())
        if fence:
            language = fence.group(1)
            body: list[str] = []
            index += 1
            while index < len(lines) and not _FENCE.match(lines[index].strip()):
                body.append(lines[index])
                index += 1
            index += 1
            code = html.escape("\n".join(body))
            kind = "mermaid" if language == "mermaid" else "code"
            label = html.escape(language or "code")
            blocks.append(f'<pre class="{kind}" data-language="{label}"><code>{code}</code></pre>')
            continue
        if line.strip().startswith("[^") and "]:" in line:
            key, _, rest = line.strip()[2:].partition("]:")
            footnotes.append((key.strip(), rest.strip()))
            index += 1
            continue
        if _HEADING.match(line.strip()):
            match = _HEADING.match(line.strip())
            assert match
            level = len(match.group(1))
            blocks.append(f"<h{level}>{_inline(match.group(2).strip())}</h{level}>")
            index += 1
            continue
        if _HR.match(line.strip()):
            blocks.append("<hr>")
            index += 1
            continue
        if "|" in line and index + 1 < len(lines) and re.match(r"^\s*\|?\s*:?-{3,}", lines[index + 1]):
            rows = []
            while index < len(lines) and "|" in lines[index]:
                cells = [cell.strip() for cell in lines[index].strip().strip("|").split("|")]
                rows.append(cells)
                index += 1
            if len(rows) >= 2:
                header = "".join(f"<th>{_inline(cell)}</th>" for cell in rows[0])
                body_rows = []
                for row in rows[2:]:
                    body_rows.append("<tr>" + "".join(f"<td>{_inline(cell)}</td>" for cell in row) + "</tr>")
                blocks.append(f"<table><thead><tr>{header}</tr></thead><tbody>{''.join(body_rows)}</tbody></table>")
            continue
        task = _UL.match(line)
        bullet = _LI.match(line)
        if task or bullet:
            items = []
            ordered = bool(bullet and not task and bullet.group(2)[:1].isdigit())
            while index < len(lines):
                current_task = _UL.match(lines[index])
                current = _LI.match(lines[index])
                if not current_task and not current:
                    break
                if current_task:
                    checked = " checked" if current_task.group(2).lower() == "x" else ""
                    items.append(f'<li><input type="checkbox" disabled{checked}> {_inline(current_task.group(3))}</li>')
                else:
                    items.append(f"<li>{_inline(current.group(3))}</li>")
                index += 1
            tag = "ol" if ordered else "ul"
            blocks.append(f"<{tag}>{''.join(items)}</{tag}>")
            continue
        quote = _QUOTE.match(line)
        if quote:
            quoted = []
            while index < len(lines) and _QUOTE.match(lines[index]):
                quoted.append(_QUOTE.match(lines[index]).group(1))
                index += 1
            blocks.append(f"<blockquote><p>{_inline(' '.join(quoted))}</p></blockquote>")
            continue
        if not line.strip():
            index += 1
            continue
        paragraph = [line.strip()]
        index += 1
        while index < len(lines) and lines[index].strip() and not _structural(lines[index]):
            paragraph.append(lines[index].strip())
            index += 1
        blocks.append(f"<p>{_inline(' '.join(paragraph))}</p>")
    if footnotes:
        items = "".join(f"<li id=\"fn-{html.escape(key)}\"><sup>{html.escape(key)}</sup> {_inline(value)}</li>" for key, value in footnotes)
        blocks.append(f"<section class=\"footnotes\"><ol>{items}</ol></section>")
    return "\n".join(blocks)


def _structural(line: str) -> bool:
    stripped = line.strip()
    return bool(
        _HEADING.match(stripped)
        or _FENCE.match(stripped)
        or _HR.match(stripped)
        or _UL.match(line)
        or _LI.match(line)
        or _QUOTE.match(line)
        or stripped.startswith("[^")
    )


def _inline(text: str) -> str:
    placeholders: list[str] = []

    def hold(fragment: str) -> str:
        placeholders.append(fragment)
        return f"\x00{len(placeholders) - 1}\x00"

    def math(match: re.Match) -> str:
        return hold(f'<span class="math">{html.escape(match.group(0))}</span>')

    text = re.sub(r"\$\$.+?\$\$|\\\(.+?\\\)|\\\[.+?\\\]", math, text)
    text = re.sub(r"`([^`]+)`", lambda match: hold(f"<code>{html.escape(match.group(1))}</code>"), text)
    escaped = html.escape(text)

    def image(match: re.Match) -> str:
        alt = html.escape(match.group(1))
        src = match.group(2).strip()
        if src.startswith(("http://", "https://", "data:")):
            return f'<span class="remote-image">未加载远程图片：{alt}</span>'
        return f'<img alt="{alt}" data-rel="{html.escape(src)}">'

    escaped = re.sub(r"!\[([^\]]*)\]\(([^)]+)\)", image, escaped)
    escaped = re.sub(r"\[([^\]]+)\]\(([^)]+)\)", lambda match: f'<a href="{html.escape(match.group(2), quote=True)}">{match.group(1)}</a>', escaped)
    escaped = re.sub(r"\[\^([^\]]+)\]", lambda match: f'<sup class="footnote-ref">{html.escape(match.group(1))}</sup>', escaped)
    escaped = re.sub(r"\*\*([^*]+)\*\*", r"<strong>\1</strong>", escaped)
    escaped = re.sub(r"(?<!\*)\*([^*]+)\*(?!\*)", r"<em>\1</em>", escaped)
    for index, fragment in enumerate(placeholders):
        escaped = escaped.replace(f"\x00{index}\x00", fragment)
        escaped = escaped.replace(html.escape(f"\x00{index}\x00"), fragment)
    return escaped


def export_document(title: str, body_html: str) -> str:
    return f"""<!DOCTYPE html>
<html lang="zh-CN">
<head>
<meta charset="utf-8">
<title>{html.escape(title)}</title>
<style>
body {{ font: 16px/1.6 "Segoe UI", "PingFang SC", sans-serif; margin: 48px auto; max-width: 760px; color: #1c1b19; }}
pre {{ background: #f4f1ea; padding: 12px 16px; overflow: auto; }}
table {{ border-collapse: collapse; }}
td, th {{ border: 1px solid #ccc; padding: 4px 8px; }}
.math, .mermaid {{ font-family: ui-monospace, Consolas, monospace; }}
</style>
</head>
<body>
{body_html}
</body>
</html>
"""
