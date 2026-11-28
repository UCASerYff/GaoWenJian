"""Offline writing resources, export, and TeX process configuration."""

from __future__ import annotations

import base64
import functools
import hashlib
import html
import mimetypes
import os
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path
from urllib.parse import parse_qs, urlsplit
from xml.sax.saxutils import escape

from gaowenjian.errors import AppError
from gaowenjian.safety import atomic_write, reject_symlink

TEX_BUNDLE_HASH = "6ffe055852f8faf66c0acbe1a7fb27f87b869a90bad1204f3bf4d9683f597c7c"


def writing_resource(packed: str, relative: str) -> Path:
    frozen = getattr(sys, "_MEIPASS", None)
    if frozen:
        return Path(frozen) / packed
    return Path(__file__).resolve().parents[3] / relative


def markdown_assets() -> Path:
    return writing_resource("gaowenjian_markdown", "Resources/Web")


def cjk_font() -> Path:
    supplement = writing_resource("gaowenjian_tex_extra", "windows/tex-extra")
    return supplement / "bundles" / "data" / TEX_BUNDLE_HASH / "NotoSansSC-Regular.otf"


def tex_executable() -> Path | None:
    shipped = writing_resource("gaowenjian_tex", "windows/tools") / "tectonic.exe"
    if shipped.is_file():
        return shipped
    external = shutil.which("tectonic")
    return Path(external) if external else None


def tex_environment(data_dir: Path) -> dict[str, str]:
    cache = data_dir / "TeXCache"
    cache.mkdir(parents=True, exist_ok=True)
    reject_symlink(cache)
    for source_dir in (
        writing_resource("gaowenjian_tex_seed", "Resources/TeXCache"),
        writing_resource("gaowenjian_tex_extra", "windows/tex-extra"),
    ):
        if not source_dir.is_dir():
            continue
        for source in source_dir.rglob("*"):
            if not source.is_file() or source.is_symlink():
                continue
            # Generate the format locally. A previous Windows format stays in use.
            relative = source.relative_to(source_dir)
            if relative.parts[0] in {"formats", "LICENSES"}:
                continue
            target = cache / relative
            if not target.resolve().is_relative_to(cache.resolve()):
                raise AppError("TeX 缓存目录指向了资料目录之外。", "latex")
            target.parent.mkdir(parents=True, exist_ok=True)
            reject_symlink(target)
            if not target.exists():
                try:
                    with target.open("xb") as out:
                        out.write(source.read_bytes())
                except FileExistsError:
                    pass

    bundle = cache / "bundles" / "data" / TEX_BUNDLE_HASH
    if (bundle / "tectonic-format-latex.tex").is_file() and (bundle / "NotoSansSC-Regular.otf").is_file():
        identity = bundle / "SHA256SUM"
        reject_symlink(identity)
        # Keep this seed identity stable across app releases when the TeX resources are unchanged.
        windows_bundle_id = hashlib.sha256(
            (TEX_BUNDLE_HASH + " / Windows 1.11 / AMSFonts 3.04 / Noto Sans SC 2.004").encode("ascii")
        ).hexdigest()
        try:
            with identity.open("x", encoding="ascii") as handle:
                handle.write(windows_bundle_id + "\n")
        except FileExistsError:
            pass

    env = os.environ.copy()
    env["TECTONIC_CACHE_DIR"] = str(cache)
    if os.name == "nt":
        font_cache = cache / "WindowsFonts"
        font_cache.mkdir(exist_ok=True)
        reject_symlink(font_cache)
        font_dirs = [Path(env["WINDIR"]) / "Fonts"]
        if env.get("LOCALAPPDATA"):
            user_fonts = Path(env["LOCALAPPDATA"]) / "Microsoft" / "Windows" / "Fonts"
            if user_fonts.is_dir():
                font_dirs.append(user_fonts)
        entries = "".join(f"<dir>{escape(path.as_posix())}</dir>" for path in font_dirs)
        config = font_cache / "fonts.conf"
        content = ('<?xml version="1.0"?><!DOCTYPE fontconfig SYSTEM "urn:fontconfig:fonts.dtd">'
                   f"<fontconfig>{entries}<cachedir>{escape(font_cache.as_posix())}</cachedir></fontconfig>")
        if not config.is_file() or config.read_text(encoding="utf-8") != content:
            atomic_write(config, content.encode("utf-8"))
        env["FONTCONFIG_FILE"] = str(config)
    return env


def tex_bundle_options(env: dict[str, str]) -> list[str]:
    bundle = Path(env["TECTONIC_CACHE_DIR"]) / "bundles" / "data" / TEX_BUNDLE_HASH
    # A Windows drive-letter path would be interpreted as an unknown URL scheme.
    if (bundle / "SHA256SUM").is_file():
        return ["--bundle", bundle.resolve().as_uri()]
    return []


@functools.lru_cache(maxsize=1)
def markdown_css() -> str:
    resources = markdown_assets()
    katex = (resources / "vendor" / "katex.min.css").read_text(encoding="utf-8")

    def inline_font(match: re.Match) -> str:
        binary = (resources / "vendor" / "fonts" / match.group(1)).read_bytes()
        return "url(data:font/woff2;base64," + base64.b64encode(binary).decode() + ")"

    katex = re.sub(r"url\(fonts/([\w.-]+\.woff2)\)", inline_font, katex)
    katex = re.sub(r",url\(fonts/[^)]*\)[^,;}]*", "", katex)
    return katex + "\n" + (resources / "markdown.css").read_text(encoding="utf-8")


def markdown_document(title: str, body: str, media) -> str:
    def inline_media(match: re.Match) -> str:
        src = html.unescape(match.group(1))
        url = urlsplit(src)
        if url.path != "/api/media" or url.scheme or url.netloc:
            return match.group(0)
        relative = parse_qs(url.query).get("rel", [""])[0]
        binary, mime = media(relative)
        content = base64.b64encode(binary).decode("ascii")
        return f'src="data:{mime};base64,{content}"'

    body = re.sub(r'(?<!\S)src="(/api/media\?[^"]*)"', inline_media, body)
    css = markdown_css() + """
html,body{height:auto;overflow:visible;display:block;padding:0}
body{background:var(--paper);font-family:"Segoe UI","Microsoft YaHei UI","Microsoft YaHei",SimSun,"Gao CJK",sans-serif}
.markdown-body{padding:32px 42px}
@page{size:A4;margin:15mm 14mm}
@media print{.markdown-body{padding:0}}
"""
    windows_fonts = Path(os.environ.get("WINDIR") or "C:/Windows") / "Fonts"
    if (re.search(r"[\u3400-\u9fff]", body) and cjk_font().is_file()
            and not any((windows_fonts / name).is_file() for name in ("msyh.ttc", "simsun.ttc"))):
        encoded = base64.b64encode(cjk_font().read_bytes()).decode("ascii")
        css += '@font-face{font-family:"Gao CJK";src:url(data:font/otf;base64,' + encoded + ') format("opentype")}'
    return (f'<!doctype html><html lang="zh-CN"><head><meta charset="utf-8">'
            '<meta name="viewport" content="width=device-width,initial-scale=1">'
            '<meta http-equiv="Content-Security-Policy" content="default-src \'none\'; '
            'style-src \'unsafe-inline\'; img-src data:; font-src data:; script-src \'none\'; '
            'base-uri \'none\'; form-action \'none\'">'
            f"<title>{html.escape(title)}</title><style>{css}</style></head><body>{body}</body></html>")


def print_markdown(document: str) -> bytes:
    candidates = [
        Path(root) / browser / executable
        for browser, executable in (
            ("Google/Chrome/Application", "chrome.exe"),
            ("Microsoft/Edge/Application", "msedge.exe"),
        )
        for variable in ("ProgramFiles", "ProgramFiles(x86)", "LOCALAPPDATA")
        if (root := os.environ.get(variable))
    ]
    candidates.extend(Path(found) for name in ("msedge", "chrome", "chromium") if (found := shutil.which(name)))
    browsers = list(dict.fromkeys(path for path in candidates if path.is_file()))
    if not browsers:
        raise AppError("PDF 排版导出需要本机的 Microsoft Edge 或 Chrome。", "export")
    with tempfile.TemporaryDirectory(prefix="gao-markdown-", ignore_cleanup_errors=True) as temporary:
        root = Path(temporary)
        source = root / "document.html"
        output = root / "document.pdf"
        source.write_text(document, encoding="utf-8")
        for serial, browser in enumerate(browsers):
            command = [
                str(browser), "--headless=new", "--disable-gpu", "--no-first-run",
                "--no-default-browser-check", "--disable-extensions",
                "--disable-background-networking", "--disable-component-update", "--disable-sync",
                "--no-proxy-server", "--host-resolver-rules=MAP * ~NOTFOUND",
                "--no-pdf-header-footer", f"--print-to-pdf={output}",
                f"--user-data-dir={root / ('profile-' + str(serial))}", source.as_uri(),
            ]
            try:
                process = subprocess.run(command, capture_output=True, timeout=30, check=False,
                                         creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0))
            except (OSError, subprocess.TimeoutExpired):
                continue
            if process.returncode == 0 and output.is_file():
                data = output.read_bytes()
                if data.startswith(b"%PDF-"):
                    return data
            output.unlink(missing_ok=True)
        raise AppError("排版引擎未能生成 PDF。", "export")


def image_mime(data: bytes, name: str) -> str:
    mime = mimetypes.guess_type(name)[0]
    signatures = {
        "image/png": data.startswith(b"\x89PNG\r\n\x1a\n"),
        "image/jpeg": data.startswith(b"\xff\xd8\xff"),
        "image/gif": data[:6] in {b"GIF87a", b"GIF89a"},
        "image/webp": data.startswith(b"RIFF") and data[8:12] == b"WEBP",
        "image/bmp": data.startswith(b"BM"),
        "image/svg+xml": re.search(br"<svg[\s>]", data[:4096], re.IGNORECASE) is not None,
    }
    if not signatures.get(mime or ""):
        raise AppError("图片格式无法识别。支持 PNG、JPEG、GIF、WebP、BMP 和 SVG。", "media")
    return mime
