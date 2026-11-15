"""与 Mac 版 DelimitedText 相同的引号、换行和前导零规则。"""

from __future__ import annotations


def parse(text: str, delimiter: str = ",") -> list[list[str]]:
    rows: list[list[str]] = []
    row: list[str] = []
    value: list[str] = []
    quoted = False
    chars = list(text)
    index = 0
    while index < len(chars):
        char = chars[index]
        if char == '"':
            if quoted and index + 1 < len(chars) and chars[index + 1] == '"':
                value.append('"')
                index += 1
            elif quoted or not value:
                quoted = not quoted
            else:
                value.append(char)
        elif char == delimiter and not quoted:
            row.append("".join(value))
            value = []
        elif char in "\n\r" and not quoted:
            if char == "\r" and index + 1 < len(chars) and chars[index + 1] == "\n":
                index += 1
            row.append("".join(value))
            rows.append(row)
            row = []
            value = []
        else:
            value.append(char)
        index += 1
    if value or row or not rows:
        row.append("".join(value))
        rows.append(row)
    width = max((len(item) for item in rows), default=1)
    return [item + [""] * (width - len(item)) for item in rows]


def encode(rows: list[list[str]], delimiter: str = ",") -> str:
    def cell(value: str) -> str:
        if delimiter in value or '"' in value or "\n" in value or "\r" in value:
            return '"' + value.replace('"', '""') + '"'
        return value

    lines = [delimiter.join(cell(value) for value in row) for row in rows]
    return "\n".join(lines) + "\n"


def markdown_table(rows: list[list[str]]) -> str:
    if not rows:
        return ""

    def line(cells: list[str]) -> str:
        escaped = [cell.replace("|", "\\|").replace("\n", "<br>") for cell in cells]
        return "| " + " | ".join(escaped) + " |"

    header = rows[0]
    body = [line(header), line(["---"] * len(header))]
    body.extend(line(row) for row in rows[1:])
    return "\n".join(body)
