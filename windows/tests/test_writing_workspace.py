import base64
import gzip
import os
from io import BytesIO
from pathlib import Path

import pytest
from PIL import Image
from pypdf import PdfReader

from gaowenjian.errors import AppError
from gaowenjian.latex import parse_log, synctex_location
from gaowenjian.workspace import LATEX_TEMPLATE, Workspace
from gaowenjian.writing import markdown_assets


def test_markdown_attachment_collision_and_offline_export(tmp_path):
    source = tmp_path / "稿件.md"
    source.write_text("# 中文", encoding="utf-8")
    workspace = Workspace(tmp_path / "data")
    tab = workspace.open_path(source)
    pixels = BytesIO()
    Image.new("RGB", (4, 4), "green").save(pixels, "PNG")
    data = "data:image/png;base64," + base64.b64encode(pixels.getvalue()).decode("ascii")

    first = workspace.markdown_attachment(tab.id, "说明图.png", data)
    second = workspace.markdown_attachment(tab.id, "说明图.png", data)
    assert first["snippet"] == "![说明图](.assets/说明图.png)\n"
    assert second["snippet"] == "![说明图](.assets/说明图-1.png)\n"
    assert workspace.media(tab.id, ".assets/说明图.png") == (pixels.getvalue(), "image/png")
    with pytest.raises(AppError):
        workspace.media(tab.id, "../说明图.png")
    with pytest.raises(AppError):
        workspace.markdown_attachment(tab.id, "说明图.jpg", data)

    output = tmp_path / "导出.html"
    rendered = ('<article class="markdown-body"><h1>中文</h1><img src="/api/media?tab=editor'
                '&amp;token=local&amp;rel=.assets%2F%E8%AF%B4%E6%98%8E%E5%9B%BE.png"></article>')
    workspace.export_html(tab.id, output, rendered)
    html = output.read_text(encoding="utf-8")
    assert "<h1>中文</h1>" in html
    assert "data:font/woff2;base64," in html
    assert data in html
    assert "/api/media" not in html
    assert "script-src 'none'" in html
    with pytest.raises(AppError):
        workspace.export_html(tab.id, output, rendered)
    assert source.read_text(encoding="utf-8") == "# 中文"


def test_windows_synctex_roundtrip_and_drive_letter_diagnostics(tmp_path):
    root = tmp_path / "正文.tex"
    child = tmp_path / "section.tex"
    pdf = tmp_path / "正文.pdf"
    report = "\n".join([
        "SyncTeX Version:1", "Input:1:./正文.tex", "Input:2:section.tex",
        "Magnification:1000", "Unit:1", "X Offset:0", "Y Offset:0",
        "Content:", "{1", "(1,8:4736287,6571295:26000000,786432,0",
        "h1,8:4736287,6571295:26000000,786432,0",
        "h2,16:4736287,8865055:26000000,786432,0", ")", "}1",
    ])
    with gzip.open(pdf.with_suffix(".synctex.gz"), "wb") as target:
        target.write(report.encode("utf-8"))
    position = synctex_location(pdf, root, "forward", source=child, line=16)
    assert position["Page"] == 1
    assert position["Line"] == 16
    assert position["Input"] == str(child)
    inverse = synctex_location(pdf, root, "inverse", page=1, x=position["x"] + 10, y=position["y"])
    assert inverse["Input"] == str(child)
    assert inverse["Line"] == 16
    diagnostics = parse_log(r"error: C:\test\正文.tex:20: Undefined control sequence")
    assert diagnostics[0]["file"] == r"C:\test\正文.tex"
    assert diagnostics[0]["line"] == 20


def test_windows_writing_uses_pinned_local_markdown_assets():
    web = markdown_assets()
    for name in ("katex.min.js", "katex.min.css", "mermaid.min.js", "highlight.min.js", "marked.js", "purify.min.js"):
        assert (web / "vendor" / name).is_file()
    assert len(list((web / "vendor" / "fonts").glob("*.woff2"))) >= 15


@pytest.mark.skipif(not os.environ.get("GAOWENJIAN_TEST_TECTONIC"), reason="requires pinned Windows Tectonic")
def test_chinese_latex_template_compiles_without_system_cjk_fonts(tmp_path, monkeypatch):
    engine = Path(os.environ["GAOWENJIAN_TEST_TECTONIC"])
    monkeypatch.setattr("gaowenjian.workspace.tex_executable", lambda: engine)
    workspace = Workspace(tmp_path / "data")
    source = tmp_path / "模板.tex"
    source.write_text(LATEX_TEMPLATE.replace("Microsoft YaHei", "GaoMissingSansForTest")
                      .replace("SimSun", "GaoMissingSerifForTest"), encoding="utf-8")
    tab = workspace.open_path(source)
    result = workspace.compile_latex(tab.id)
    assert result["success"], result["diagnostics"]
    text = PdfReader(BytesIO(workspace.latex_pdf(tab.id))).pages[0].extract_text()
    assert "我的文档" in text
    assert "欢迎使用搞文件。" in text
    assert workspace.synctex(tab.id, {"direction": "forward", "line": 13})["Page"] == 1
