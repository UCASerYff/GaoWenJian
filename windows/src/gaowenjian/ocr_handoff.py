"""Offline OCR request and result validation for the Windows GaoCaoZuo provider."""

from __future__ import annotations

import json
import math
import os
import re
import subprocess
import uuid
from datetime import datetime, timezone
from pathlib import Path

from gaowenjian.errors import AppError
from gaowenjian.handoff import (
    MAX_ITEM_BYTES, _remember, _request, _validate, _write_package, read_package, read_regular, regular_path,
)
from gaowenjian.safety import digest

PROVIDER = "com.gaoseries.GaoCaoZuo"
ENGINE = "Windows.Media.Ocr"
FORMATS = {"text": "public.utf8-plain-text", "markdown": "net.daringfireball.markdown",
           "json": "public.json", "searchablePDF": "com.adobe.pdf"}
INPUTS = {".pdf": "com.adobe.pdf", ".png": "public.png", ".jpg": "public.jpeg", ".jpeg": "public.jpeg",
          ".tif": "public.tiff", ".tiff": "public.tiff", ".gif": "com.compuserve.gif", ".webp": "public.webp",
          ".heic": "public.heic", ".heif": "public.heif"}
LANGUAGE = re.compile(r"[A-Za-z]{2,8}(?:-[A-Za-z0-9]{1,8})*\Z", re.ASCII)


def export_request(book, paths: list, outputs: list, languages: list, destination: Path | None = None,
                   *, current: tuple[Path, bytes] | None = None, now=None) -> dict:
    if not isinstance(paths, list) or not all(isinstance(path, str) and path for path in paths):
        raise AppError("请选择本机图像或 PDF 文件。", "invalid")
    if (not isinstance(outputs, list) or not outputs or not all(isinstance(value, str) and value in FORMATS for value in outputs)
            or len(set(outputs)) != len(outputs)):
        raise AppError("请选择至少一种 OCR 输出格式。", "invalid")
    if (not isinstance(languages, list) or len(languages) > 12
            or not all(isinstance(value, str) and len(value) <= 63 and LANGUAGE.fullmatch(value) for value in languages)):
        raise AppError("OCR 语言最多 12 种，使用 zh-CN、en-US 等 Windows 语言标记。", "invalid")
    count = len(paths) + bool(current)
    if not 1 <= count <= 200 or count * len(outputs) > 256:
        raise AppError("请选择 1 至 200 个输入，且每批最多生成 256 份输出。", "itemLimit")
    now = now or datetime.now(timezone.utc)
    identifier = str(uuid.uuid4())
    parameters = {"outputs": outputs}
    if languages:
        parameters["languages"] = list(dict.fromkeys(languages))
    manifest = _request("ocr.files", identifier, PROVIDER, parameters, now)
    inputs = [(Path(value), None) for value in paths]
    if current:
        inputs.insert(0, current)
    files = {}
    try:
        total = 0
        for index, (path, content) in enumerate(inputs, start=1):
            extension = path.suffix.lower()
            if extension not in INPUTS:
                raise AppError("搞操作只接受受支持的图像与 PDF 附件。", "unsupported")
            if content is None:
                if not path.is_absolute():
                    raise AppError("请选择绝对文件路径。", "invalidPath")
                content = read_regular(path, MAX_ITEM_BYTES)
            total += len(content)
            if not content or len(content) > MAX_ITEM_BYTES or total > 512 * 1024 * 1024:
                raise AppError("OCR 输入文件为空或超过本机交接大小限制，请分批。", "itemLimit")
            name = f"Input-{index}{extension}"
            files[name] = content
            manifest["items"].append({"id": str(uuid.uuid4()), "relativePath": name, "uti": INPUTS[extension],
                                      "byteCount": len(content), "sha256": digest(content)})
    except OSError as exc:
        raise AppError("无法读取所选 OCR 输入。", "missing") from exc
    _validate(manifest, PROVIDER, now)
    if destination is None:
        destination = book.root / "Outgoing"
        destination.mkdir(exist_ok=True)
    path = destination / f"OCR-{identifier}.gaoaction"
    _write_package(path, manifest, files)
    raw = read_regular(path / "manifest.json", 1_048_576)
    session = {"requestID": identifier, "action": "ocr.files", "targetBundleID": PROVIDER,
               "manifestSHA256": digest(raw), "parameters": parameters, "expiresAt": manifest["expiresAt"],
               "path": str(path), "sources": [{"id": item["id"], "sha256": item["sha256"]} for item in manifest["items"]]}
    _remember(book.outgoing, session, key="sessions")
    return {"path": str(path), "requestID": identifier, "expiresAt": manifest["expiresAt"], "itemCount": count}


def default_provider() -> Path | None:
    if os.name != "nt":
        return None
    import winreg

    try:
        with winreg.OpenKey(winreg.HKEY_CURRENT_USER,
                            r"Software\Microsoft\Windows\CurrentVersion\Uninstall\GaoSeries.GaoCaoZuo.Windows_is1") as key:
            location, _ = winreg.QueryValueEx(key, "InstallLocation")
        path = Path(location) / "GaoCaoZuo.exe"
        if path.is_absolute() and path.is_file():
            return path
    except OSError:
        pass
    local = os.environ.get("LOCALAPPDATA")
    path = Path(local) / "Programs" / "GaoSeries" / "GaoCaoZuo" / "GaoCaoZuo.exe" if local else None
    return path if path and path.is_file() else None


def check_provider(gui: Path) -> dict:
    gui = gui.absolute()
    cli = gui.with_name("GaoCaoZuo-cli.exe")
    if os.name != "nt" or gui.name.casefold() != "gaocaozuo.exe":
        raise AppError("请选择搞操作的 Windows 安装程序目录内的 GaoCaoZuo.exe。", "provider")
    try:
        regular_path(gui)
        regular_path(cli)
        run = subprocess.run([str(cli), "--capabilities"], check=True, capture_output=True, timeout=20,
                             creationflags=subprocess.CREATE_NO_WINDOW)
        capabilities = json.loads(run.stdout)
        actions = capabilities.get("actions", [])
        valid = (capabilities.get("schemaVersion") == 1 and capabilities.get("bundleID") == PROVIDER
                 and any(isinstance(item, dict) and item.get("action") == "ocr.files"
                         and item.get("supportsItems") is True and item.get("requiresUserConfirmation") is True
                         for item in actions))
        if not valid:
            raise ValueError("incompatible provider")
    except (OSError, ValueError, AttributeError, subprocess.SubprocessError) as exc:
        raise AppError("未能核对搞操作的 OCR 能力。请安装支持 GaoAction 文件 OCR 的版本。", "provider") from exc
    return capabilities


def dispatch_request(book, identifier: str, provider: Path | None = None) -> dict:
    entries = (book.outgoing.data or {}).get("sessions", [])
    session = next((item for item in entries if item.get("requestID") == identifier and item.get("action") == "ocr.files"), None)
    if session is None:
        raise AppError("找不到这份 OCR 请求。", "missing")
    gui = provider or default_provider()
    if gui is None:
        raise AppError("没有找到搞操作。可安装搞操作 V1.16 或在交接页选择其程序。", "provider")
    capabilities = check_provider(gui)
    path = Path(session["path"])
    _, _, actual = read_package(path, target=PROVIDER)
    if actual != session["manifestSHA256"]:
        raise AppError("OCR 请求清单已变化，请重新准备请求。", "changed")
    try:
        subprocess.Popen([str(gui.absolute()), "--gaoaction", str(path.absolute())],
                         stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    except OSError as exc:
        raise AppError("无法打开搞操作。该请求仍可手动交给搞操作审核。", "provider") from exc
    return {"path": str(path), "requestID": identifier, "providerVersion": capabilities.get("appVersion")}


def validate_result(manifest: dict, files: list[bytes], outgoing, journal) -> bool:
    """Check the exact completed/partial/failed result format from the Windows provider."""
    def require(value) -> None:
        if not value:
            raise AppError("搞操作 OCR 回包与本机请求、源文件或逐页结果不匹配。", "ocrProvenance")

    in_reply_to = manifest["inReplyTo"]
    sessions = (outgoing or {}).get("sessions", [])
    session = next((item for item in sessions if item.get("requestID") == in_reply_to), None)
    require(session and session.get("action") == "ocr.files" and session.get("targetBundleID") == PROVIDER)
    require(manifest["sourceBundleID"] == PROVIDER and not manifest["references"]
            and manifest["parameters"] == session["parameters"])
    provenance = manifest["provenance"]
    require(provenance.get("engine") == ENGINE and provenance.get("networkUsed") is False)
    if "requestManifestSHA256" in provenance:
        require(provenance["requestManifestSHA256"] == session["manifestSHA256"])
    sources, outputs, failures = (provenance.get(key) for key in ("sources", "outputs", "exportFailures"))
    require(isinstance(sources, list) and isinstance(outputs, list) and isinstance(failures, list)
            and all(isinstance(value, str) for value in failures))
    status = manifest["status"]
    require(status in {"completed", "partial", "failed"})
    require(bool(manifest.get("errorCode")) == (status != "completed"))
    expected = {item["id"]: item["sha256"] for item in session["sources"]}
    requested = set(session["parameters"]["outputs"])
    payloads = {item["id"]: (item, content) for item, content in zip(manifest["items"], files, strict=True)}
    mapped_sources = {}
    source_uuids = set()
    pages_total = pages_completed = 0
    if not sources:
        require(status == "failed" and not outputs and not payloads and failures)
    for source in sources:
        require(isinstance(source, dict))
        item_id, sha, sid = (source.get(key) for key in ("sourceItemID", "sourceSHA256", "sourceID"))
        require(isinstance(item_id, str) and isinstance(sid, str) and sid and sid not in source_uuids
                and item_id in expected and expected[item_id] == sha and item_id not in mapped_sources)
        source_uuids.add(sid)
        pages, ids = source.get("pages"), source.get("outputItemIDs")
        require(isinstance(pages, list) and 1 <= len(pages) <= 200 and isinstance(ids, list)
                and all(isinstance(value, str) for value in ids) and len(set(ids)) == len(ids))
        for page_number, page in enumerate(pages, start=1):
            require(isinstance(page, dict) and type(page.get("pageNumber")) is int and page["pageNumber"] == page_number
                    and page.get("status") in ("completed", "failed")
                    and type(page.get("lineCount")) is int and page["lineCount"] >= 0)
            elapsed = page.get("elapsedSeconds")
            require(type(elapsed) in (int, float) and 0 <= elapsed < math.inf)
            pages_completed += page["status"] == "completed"
        pages_total += len(pages)
        mapped_sources[item_id] = (sid, set(ids), set(), pages)
    if sources:
        require(set(mapped_sources) == set(expected))
    seen_outputs = set()
    for output in outputs:
        require(isinstance(output, dict))
        item_id, output_id, format_name = (output.get(key) for key in ("sourceItemID", "resultItemID", "format"))
        require(all(isinstance(value, str) for value in (item_id, output_id, format_name))
                and item_id in mapped_sources and format_name in requested and output_id in payloads
                and output_id not in seen_outputs)
        sid, ids, formats, pages = mapped_sources[item_id]
        attachment, content = payloads[output_id]
        require(sid == output.get("sourceID") and expected[item_id] == output.get("sourceSHA256")
                and output_id in ids and format_name not in formats and attachment["uti"] == FORMATS[format_name])
        if format_name == "json":
            _validate_json(content, expected[item_id], pages, require)
        elif format_name == "searchablePDF":
            require(content.startswith(b"%PDF-"))
        seen_outputs.add(output_id)
        formats.add(format_name)
    require(set(payloads) == seen_outputs == set().union(*(item[1] for item in mapped_sources.values())))
    require(status != "completed" or (pages_total == pages_completed and not failures
                                       and all(item[2] == requested for item in mapped_sources.values())))
    require(status != "partial" or (pages_completed and (pages_completed < pages_total or failures)))
    require(status != "failed" or (not pages_completed or (failures and not payloads)))
    return any(entry.get("action") == "ocr.files" and entry.get("inReplyTo") == in_reply_to
               for entry in (journal or {}).get("entries", []))


def _validate_json(content: bytes, source_sha: str, pages: list, require) -> None:
    try:
        result = json.loads(content.decode("utf-8"))
        sources = result["sources"]
        require(result["engine"] == ENGINE and result["networkUsed"] is False
                and isinstance(sources, list) and len(sources) == 1)
        source = sources[0]
        # A source that could not be opened has no computed SHA in the provider's JSON.
        require(source.get("sha256") == source_sha or (source.get("sha256") is None
                                                        and all(page["status"] == "failed" for page in pages)))
        require(len(source["pages"]) == len(pages))
        for item, expected in zip(source["pages"], pages, strict=True):
            require(item["page"] == expected["pageNumber"] and item["status"] == expected["status"]
                    and isinstance(item["lines"], list) and len(item["lines"]) == expected["lineCount"])
    except (ValueError, KeyError, AttributeError, TypeError):
        require(False)
