"""LaTeX 主文件、大纲、诊断和补全。规则对齐 Mac 版 LaTeXModel。"""

from __future__ import annotations

import re
import gzip
from pathlib import Path

from gaowenjian.errors import AppError

_ROOT = re.compile(r"(?i)%\s*!TeX\s+root\s*=\s*([^\r\n]+)")
_SECTION = re.compile(r"\\(part|chapter|section|subsection|subsubsection)\*?(?:\[[^\]]*\])?\{([^}]+)\}")
_FLOAT = re.compile(r"\\begin\{(figure\*?|table\*?|equation\*?|align\*?)\}")
_CAPTION = re.compile(r"\\caption(?:\[[^\]]*\])?\{([^}]+)\}")
_LABEL = re.compile(r"\\label\{([^}]+)\}")
_BIB = re.compile(r"(?:\\(?:cite|citep|citet|parencite|autocite)\{([^}]+)\}|\\bibitem\{([^}]+)\}|@\w+\s*[\{\(]\s*([^,\s\}]+))")
_FILE_LINE = re.compile(r"^(.+?\.tex):(\d+):(?:\s*(\d+):)?\s*(.*)$")
_TECTONIC_LINE = re.compile(r"^(.+?):(\d+):\s*(.*)$")
_FONT_RESOURCE_NOTICE = re.compile(r"^warning: accessing absolute path `[^`]+\.(?:otf|ttf|ttc)`;", re.IGNORECASE)
_LINE_MARK = re.compile(r"^l\.(\d+)\s*(.*)$")
_INPUT_LINE = re.compile(r"on input line (\d+)")
_BOX_LINE = re.compile(r"(?:at lines|on input line)\s+(\d+)")

COMMANDS = [
    "section", "subsection", "subsubsection", "paragraph", "chapter", "part",
    "textbf", "textit", "texttt", "textsc", "textsf", "underline", "emph",
    "frac", "sqrt", "sum", "int", "prod", "lim", "infty",
    "alpha", "beta", "gamma", "delta", "epsilon", "zeta", "eta", "theta",
    "iota", "kappa", "lambda", "mu", "nu", "xi", "pi", "rho", "sigma", "tau",
    "upsilon", "phi", "chi", "psi", "omega",
    "Gamma", "Delta", "Theta", "Lambda", "Xi", "Pi", "Sigma", "Phi", "Psi", "Omega",
    "leq", "geq", "neq", "approx", "equiv", "times", "div", "pm", "cdot",
    "in", "notin", "subset", "subseteq", "cup", "cap", "forall", "exists",
    "label", "ref", "eqref", "pageref", "cite", "citep", "citet",
    "usepackage", "documentclass", "input", "include", "includegraphics",
    "newcommand", "renewcommand", "def", "vspace", "hspace", "centering",
    "tableofcontents", "maketitle", "newpage", "clearpage", "bibliography",
]
ENVIRONMENTS = [
    "document", "equation", "equation*", "align", "align*", "gather", "gather*",
    "multline", "multline*", "split", "cases",
    "itemize", "enumerate", "description",
    "figure", "table", "tabular",
    "matrix", "pmatrix", "bmatrix", "vmatrix", "Vmatrix",
    "proof", "theorem", "lemma", "corollary", "definition", "example", "remark",
    "verbatim", "lstlisting", "minted", "center", "flushleft", "flushright", "minipage",
]
PACKAGES = [
    "amsmath", "amssymb", "amsfonts", "graphicx", "hyperref", "xcolor",
    "geometry", "booktabs", "tikz", "float", "caption", "subcaption",
    "xeCJK", "ctex", "fontspec", "biblatex", "natbib", "listings", "microtype",
    "array", "siunitx", "algorithm2e", "fancyhdr", "multicol", "titlesec",
]


def root_directive(text: str, current: Path | None) -> Path | None:
    match = _ROOT.search(text[:2000])
    if not match:
        return None
    target = match.group(1).strip().strip('"').strip("'")
    if not target:
        return None
    path = Path(target)
    if path.is_absolute():
        return path
    if current is None:
        return None
    parent = current if current.is_dir() else current.parent
    return (parent / target)


def parse_index(text: str) -> dict:
    nodes = []
    labels: list[str] = []
    citations: list[str] = []
    for index, line in enumerate(text.splitlines(), start=1):
        stripped = line.strip()
        if stripped.startswith("%") and "!TeX" not in stripped:
            continue
        section = _SECTION.search(line)
        if section:
            command, title = section.group(1), section.group(2)
            nodes.append({"kind": command, "title": title, "line": index})
        float_match = _FLOAT.search(line)
        if float_match:
            env = float_match.group(1)
            if env.startswith("figure"):
                title, kind = "插图 (figure)", "figure"
            elif env.startswith("table"):
                title, kind = "表格 (table)", "table"
            else:
                title, kind = f"公式 ({env})", "equation"
            nodes.append({"kind": kind, "title": title, "line": index})
        elif (caption := _CAPTION.search(line)):
            nodes.append({"kind": "figure", "title": f"标题：{caption.group(1)}", "line": index, "detail": "caption"})
        for label in _LABEL.findall(line):
            if label not in labels:
                labels.append(label)
            nodes.append({"kind": "label", "title": label, "line": index, "detail": "label"})
        for match in _BIB.finditer(line):
            raw = next(group for group in match.groups() if group)
            for key in [part.strip() for part in raw.split(",") if part.strip()]:
                if key not in citations:
                    citations.append(key)
                nodes.append({"kind": "citation", "title": key, "line": index, "detail": "citation"})
    return {"nodes": nodes, "labels": labels, "citations": citations}


def parse_log(log: str) -> list[dict]:
    results = []
    lines = log.splitlines()
    index = 0
    while index < len(lines):
        line = lines[index].strip()
        if _FONT_RESOURCE_NOTICE.match(line):
            index += 1
            continue
        file_line = None if line.startswith(("error:", "warning:")) else _FILE_LINE.match(line)
        if file_line:
            message = file_line.group(4).strip() or "编译问题"
            lowered = message.lower()
            severity = "warning" if any(word in lowered for word in ("warning", "overfull", "underfull")) else "error"
            results.append({"severity": severity, "message": message, "file": file_line.group(1), "line": int(file_line.group(2)), "detail": line})
            index += 1
            continue
        if line.startswith(("error:", "warning:")):
            severity, _, rest = line.partition(":")
            rest = rest.strip()
            located = _TECTONIC_LINE.match(rest)
            message = located.group(3) if located else rest
            results.append({"severity": severity, "message": message, "file": located.group(1) if located else None,
                            "line": int(located.group(2)) if located else None, "detail": line})
            index += 1
            continue
        if line.startswith("!"):
            message = line[1:].strip()
            line_number = None
            context = [line]
            look = index + 1
            while look < min(len(lines), index + 8):
                context.append(lines[look])
                mark = _LINE_MARK.match(lines[look].strip())
                if mark:
                    line_number = int(mark.group(1))
                    break
                if lines[look].strip().startswith("!"):
                    break
                look += 1
            results.append({"severity": "error", "message": message, "file": None, "line": line_number, "detail": "\n".join(context)})
            index += 1
            continue
        if "Warning:" in line or line.startswith("Overfull") or line.startswith("Underfull"):
            line_number = None
            mark = _INPUT_LINE.search(line) or _BOX_LINE.search(line)
            if mark:
                line_number = int(mark.group(1))
            results.append({"severity": "warning", "message": line, "file": None, "line": line_number, "detail": line})
            index += 1
            continue
        index += 1
    return results


def _rank(prefix: str, items: list[str], limit: int) -> list[str]:
    needle = prefix.lower()

    def key(item: str) -> tuple:
        return (not item.lower().startswith(needle), item)

    matched = [item for item in items if not needle or needle in item.lower()]
    return sorted(matched, key=key)[:limit]


def complete(text: str, cursor: int, labels: list[str], citations: list[str]) -> dict | None:
    cursor = max(0, min(cursor, len(text)))
    line_start = max(text.rfind("\n", 0, cursor), text.rfind("\r", 0, cursor)) + 1
    prefix = text[line_start:cursor]
    patterns = [
        (r"\\(begin|end)\{([A-Za-z0-9_\*]*)$", "environment"),
        (r"\\(ref|eqref|pageref|autoref|cref|Cref)\{([A-Za-z0-9_\-:]*)$", "label"),
        (r"\\(cite|citep|citet|parencite|textcite)\{([A-Za-z0-9_\-:]*)$", "citation"),
        (r"\\usepackage(?:\[[^\]]*\])?\{([A-Za-z0-9_\-]*)$", "package"),
        (r"\\([A-Za-z@]*)$", "command"),
    ]
    for pattern, kind in patterns:
        match = re.search(pattern, prefix)
        if not match:
            continue
        token = match.group(match.lastindex)
        start = cursor - len(token)
        if kind == "command":
            items = [{"title": "\\" + item, "subtitle": "LaTeX 命令", "insert": item, "caretFromEnd": 0} for item in _rank(token, COMMANDS, 16)]
        elif kind == "environment":
            is_begin = match.group(1) == "begin"
            items = []
            for item in _rank(token, ENVIRONMENTS, 16):
                if is_begin:
                    insert = f"{item}}}\n    \n\\end{{{item}}}"
                    items.append({"title": item, "subtitle": "环境 · 自动配对", "insert": insert, "caretFromEnd": len(f"\n\\end{{{item}}}")})
                else:
                    items.append({"title": item, "subtitle": "结束环境", "insert": item + "}", "caretFromEnd": 0})
        elif kind == "label":
            items = [{"title": item, "subtitle": "标签 (Label)", "insert": item + "}", "caretFromEnd": 0} for item in _rank(token, labels, 20)]
        elif kind == "citation":
            items = [{"title": item, "subtitle": "文献引用 (Bib)", "insert": item + "}", "caretFromEnd": 0} for item in _rank(token, citations, 20)]
        else:
            items = [{"title": item, "subtitle": "常用宏包", "insert": item + "}", "caretFromEnd": 0} for item in _rank(token, PACKAGES, 16)]
        return {"kind": kind, "start": start, "length": len(token), "items": items}
    return None


_SYNC_NODE = re.compile(r"^([\[\(hvkxg$])(-?\d+),(\d+)(?:,\d+)?:(-?\d+),(-?\d+)(?::(-?\d+))?")


def synctex_location(pdf: Path, root: Path, direction: str, *, source: Path | None = None,
                     line: int = 1, page: int = 1, x: float = 0, y: float = 0) -> dict:
    """Use SyncTeX's page and horizontal box records when no native query tool is present."""
    compressed = pdf.with_suffix(".synctex.gz")
    plain = pdf.with_suffix(".synctex")
    try:
        if compressed.is_file():
            with gzip.open(compressed, "rb") as stream:
                data = stream.read(32 * 1024 * 1024 + 1)
        else:
            with plain.open("rb") as stream:
                data = stream.read(32 * 1024 * 1024 + 1)
    except (OSError, EOFError) as exc:
        raise AppError("当前编译结果没有可读取的 SyncTeX 数据。", "synctex") from exc
    if len(data) > 32 * 1024 * 1024:
        raise AppError("SyncTeX 数据超过读取上限。", "synctex")
    for encoding in ("utf-8", "mbcs", "gb18030", "latin-1"):
        try:
            content = data.decode(encoding)
            break
        except (UnicodeError, LookupError):
            continue
    inputs: dict[int, Path] = {}
    params = {"Magnification": 1000, "Unit": 1, "X Offset": 0, "Y Offset": 0}
    boxes = []
    current_page = 0
    for entry in content.splitlines():
        if entry.startswith("Input:"):
            _, tag, name = entry.split(":", 2)
            if tag.isdecimal() and name.strip():
                inputs[int(tag)] = (root.parent / name.strip().strip('"')).resolve()
            continue
        if entry.startswith("{") and entry[1:].isdecimal():
            current_page = int(entry[1:])
            continue
        if entry.startswith("}"):
            current_page = 0
        name, _, value = entry.partition(":")
        if name in params and value.strip().lstrip("-").isdecimal():
            params[name] = int(value.strip())
        match = _SYNC_NODE.match(entry) if current_page else None
        if match:
            kind, tag, row, left, top, width = match.groups()
            if int(row) > 0:
                boxes.append((current_page, kind, int(tag), int(row), int(left), int(top), int(width or 0)))
    factor = params["Unit"] * params["Magnification"] / 1000 * 72 / (65536 * 72.27)
    if not inputs or factor <= 0:
        raise AppError("SyncTeX 数据无法读取。", "synctex")

    def location(box):
        number, _, tag, row, left, top, _ = box
        return {"Page": number, "Input": str(inputs[tag]), "Line": row, "Column": 1,
                "x": (left + params["X Offset"]) * factor, "y": (top + params["Y Offset"]) * factor}

    if direction == "forward" and source:
        tags = {tag for tag, path in inputs.items() if path == source.resolve()}
        matches = [box for box in boxes if box[2] in tags]
        if matches:
            return location(min(matches, key=lambda box: (abs(box[3] - line), box[1] not in {"h", "x", "("}, box[5])))
    if direction == "inverse":
        allowed = [box for box in boxes if box[0] == page and box[2] in inputs and box[1] in {"(", "h", "x", "g", "k"}]

        def distance(box):
            left = (box[4] + params["X Offset"]) * factor
            top = (box[5] + params["Y Offset"]) * factor
            right = left + box[6] * factor
            return (abs(top - y), max(left - x, 0, x - right), box[1] not in {"h", "x"})

        if allowed:
            return location(min(allowed, key=distance))
    raise AppError("SyncTeX 没有返回对应位置。", "synctex")
