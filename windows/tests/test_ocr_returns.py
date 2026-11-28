from __future__ import annotations

import json
import os
import subprocess
import uuid
from datetime import datetime, timedelta, timezone
from pathlib import Path
from types import SimpleNamespace

import pytest

from gaowenjian.errors import AppError
from gaowenjian.handoff import BUNDLE_ID, TTL, HandoffBook, _request, _write_package
from gaowenjian.ocr_handoff import ENGINE, PROVIDER, export_request, inspect_return, is_return_path, scan_returns
from gaowenjian.ocr_returns import publish_ticket
from gaowenjian.pdfdoc import plain_pdf
from gaowenjian.safety import digest
from gaowenjian.workspace import Workspace


@pytest.fixture
def isolated_local(tmp_path, monkeypatch):
    local = tmp_path / "local"
    local.mkdir()
    monkeypatch.setenv("LOCALAPPDATA", str(local))
    return local / "GaoSeries" / "GaoAction" / "OcrReturns-v1"


def request_fixture(tmp_path, *, book=None, count=2):
    book = book or HandoffBook(tmp_path / "profile" / "Handoff")
    now = datetime.now(timezone.utc).replace(microsecond=0)
    paths = [tmp_path / f"来源 {index}.png" for index in range(count)]
    for index, path in enumerate(paths):
        path.write_bytes(f"synthetic source {index}".encode())
    request = export_request(book, [str(path) for path in paths], ["text"], [], now=now)
    return book, request, paths, now


def result_fixture(book, now, *, modern=True, status="completed"):
    request = book.outgoing.data["sessions"][-1]
    manifest = _request("ocr.files", str(uuid.uuid4()), BUNDLE_ID, request["parameters"], now)
    manifest.update({"kind": "result", "status": status, "sourceBundleID": PROVIDER, "inReplyTo": request["requestID"]})
    pages, outputs, payloads = [], [], {}
    for index, item in enumerate(request["sources"], 1):
        output_id = str(uuid.uuid4())
        mapping = {"sourceID": str(uuid.uuid4()), "sourceItemID": item["id"], "sourceSHA256": item["sha256"]}
        name = f"OCR-{index}.txt"
        content = f"经过审核的文字 {index}".encode()
        manifest["items"].append({"id": output_id, "relativePath": name, "uti": "public.utf8-plain-text",
                                  "byteCount": len(content), "sha256": digest(content)})
        payloads[name] = content
        pages.append({**mapping, "pages": [{"pageNumber": page, "status": "completed", "lineCount": page,
                                            "elapsedSeconds": 0.1} for page in range(1, index + 1)],
                      "outputItemIDs": [output_id]})
        outputs.append({**mapping, "resultItemID": output_id, "format": "text"})
    manifest["provenance"] = {"engine": ENGINE, "networkUsed": False, "sources": pages,
                              "outputs": outputs, "exportFailures": []}
    if modern:
        manifest["provenance"]["requestManifestSHA256"] = request["manifestSHA256"]
    if status == "failed":
        manifest["items"] = []
        payloads.clear()
        manifest["provenance"].update({"sources": [], "outputs": [], "exportFailures": ["failed fixture"]})
        manifest["errorCode"] = "failed fixture"
    return manifest, payloads


def test_ticket_binds_a_persisted_request_without_paths(tmp_path, isolated_local):
    book, request, paths, now = request_fixture(tmp_path)
    assert request["returnEnabled"] is True
    request_manifest = (Path(request["path"]) / "manifest.json").read_bytes()
    ticket_path = isolated_local / request["requestID"] / "request.json"
    raw = ticket_path.read_bytes()
    assert not raw.startswith(b"\xef\xbb\xbf") and str(paths[0]).encode() not in raw
    assert json.loads(raw) == {
        "schemaVersion": 1, "requestID": request["requestID"], "action": "ocr.files", "sourceBundleID": BUNDLE_ID,
        "targetBundleID": PROVIDER, "requestManifestSHA256": digest(request_manifest), "expiresAt": request["expiresAt"],
    }
    durable = json.loads(book.outgoing.path.read_bytes())["sessions"][0]
    assert durable["manifestSHA256"] == digest(request_manifest)
    assert [source["path"] for source in durable["sources"]] == list(map(str, paths))
    assert scan_returns(book, now=now) == {"pending": True, "results": [], "issues": []}
    assert not scan_returns(book, now=now + TTL)["pending"]
    assert publish_ticket(durable, now)
    ticket_path.write_text("{}", encoding="utf-8")
    assert not publish_ticket(durable, now) and ticket_path.read_text(encoding="utf-8") == "{}"
    assert scan_returns(book, now=now)["issues"][0]["reason"] == "ocrTicket"


def test_ticket_is_written_only_after_outgoing_persistence(tmp_path, isolated_local, monkeypatch):
    from gaowenjian import ocr_handoff

    original = ocr_handoff.publish_ticket
    book = HandoffBook(tmp_path / "profile" / "Handoff")

    def verify_order(session, now):
        assert json.loads(book.outgoing.path.read_bytes())["sessions"][-1] == session
        return original(session, now)

    monkeypatch.setattr(ocr_handoff, "publish_ticket", verify_order)
    _, request, _, _ = request_fixture(tmp_path, book=book)
    assert request["returnEnabled"]


@pytest.mark.parametrize("selection", [None, "", "C:\\合成资料\\一 张.png",
                                       ("C:\\合成资料\\一 张.png", "C:\\合成资料\\二 份.pdf")])
def test_native_ocr_picker_uses_multiple_and_preserves_complete_paths(selection):
    from gaowenjian.desktop import FILE_TYPES, WindowActions
    from webview.util import parse_file_type

    formats = SimpleNamespace(OPEN=1, FOLDER=2, SAVE=3)
    actions = WindowActions(SimpleNamespace(webview=SimpleNamespace(FileDialog=formats)))

    def choose(dialog_type, **options):
        assert dialog_type == formats.OPEN
        assert options["allow_multiple"] is True and options["file_types"][:-1] == FILE_TYPES["ocr-inputs"]
        for filter_type in options["file_types"]:
            parse_file_type(filter_type)
        return selection

    actions._window = SimpleNamespace(create_file_dialog=choose)
    expected = [selection] if isinstance(selection, str) and selection else list(selection or ())
    assert actions.file_dialog("ocr-inputs") == expected


def test_native_note_import_filter_is_accepted():
    from gaowenjian.desktop import FILE_TYPES
    from webview.util import parse_file_type

    _, patterns = parse_file_type(FILE_TYPES["note-import"][0])
    assert patterns == "*.txt;*.rtf"


def test_verified_return_is_review_only_until_explicit_digest_and_preserves_each_source(tmp_path, isolated_local):
    workspace = Workspace(tmp_path / "profile")
    draft = workspace.new_text("markdown", "未保存的原草稿")
    book, request, paths, now = request_fixture(tmp_path, book=workspace.handoff)
    manifest, payloads = result_fixture(book, now)
    returned = isolated_local / request["requestID"] / "result.gaoaction"
    _write_package(returned, manifest, payloads)
    assert is_return_path(returned / "manifest.json")
    assert not is_return_path(tmp_path / "result.gaoaction")
    result = scan_returns(book, now=now)
    assert not result["pending"] and len(result["results"]) == 1
    summary = result["results"][0]
    assert summary["resultID"] == manifest["requestID"]
    assert [item["path"] for item in summary["sources"]] == list(map(str, paths))
    assert [[p["pageNumber"] for p in item["pages"]] for item in summary["sources"]] == [[1], [1, 2]]
    assert scan_returns(book, now=now) == result and not book.journal.exists
    assert workspace.tabs == [draft]
    with pytest.raises(AppError) as blocked:
        workspace.open_path(returned)
    assert blocked.value.code == "handoffReview"
    with pytest.raises(AppError) as blocked:
        workspace.import_handoff(returned)
    assert blocked.value.code == "reviewRequired"
    with pytest.raises(AppError) as blocked:
        workspace.import_handoff(returned, "0" * 64)
    assert blocked.value.code == "changed"
    assert workspace.tabs == [draft] and draft.dirty
    inspected = workspace.inspect_handoff(returned)
    assert inspected["sha256"] == summary["sha256"] and inspected["ocrSources"] == summary["sources"]
    workspace.import_handoff(returned, inspected["sha256"])
    assert workspace.tabs[0] is draft and draft.text == "未保存的原草稿"
    imported = [tab.extra["incoming"] for tab in workspace.tabs[1:]]
    assert [item["sourcePath"] for item in imported] == list(map(str, paths))
    assert [[p["pageNumber"] for p in item["pages"]] for item in imported] == [[1], [1, 2]]
    assert not scan_returns(book, now=now)["results"] and returned.is_dir()
    journal = json.loads(book.journal.path.read_bytes())["entries"][0]
    assert journal["ocrSources"] == summary["sources"] and len(journal["ocrOutputs"]) == len(paths)
    assert [path.read_bytes() for path in paths] == [b"synthetic source 0", b"synthetic source 1"]
    # Transport expiry does not affect either the accepted text drafts or their provenance.
    reopened = Workspace(workspace.data_dir)
    assert not scan_returns(reopened.handoff, now=now + TTL)["results"]
    assert [tab.text for tab in reopened.tabs] == [draft.text, "经过审核的文字 1", "经过审核的文字 2"]
    assert [tab.extra["incoming"]["sourcePath"] for tab in reopened.tabs[1:]] == list(map(str, paths))
    assert returned.is_dir()


@pytest.mark.parametrize("earlier", ["request", "result"])
def test_ready_deadline_and_expired_review_do_not_modify_artifacts(tmp_path, isolated_local, monkeypatch, earlier):
    from gaowenjian import handoff, ocr_returns

    workspace = Workspace(tmp_path / "profile")
    draft = workspace.new_text("markdown", "未保存的原草稿")
    book, request, _, now = request_fixture(tmp_path, book=workspace.handoff, count=1)
    if earlier == "request":
        manifest, payloads = result_fixture(book, now + timedelta(seconds=30))
        deadline = now + TTL
    else:
        manifest, payloads = result_fixture(book, now)
        deadline = now + timedelta(seconds=45)
        manifest["expiresAt"] = handoff._stamp(deadline)
    returned = isolated_local / request["requestID"] / "result.gaoaction"
    _write_package(returned, manifest, payloads)
    tracked = [book.outgoing.path, workspace.recovery_guard.path, returned.parent / "request.json",
               returned / "manifest.json", returned / "payload" / "OCR-1.txt"]
    previous = [path.read_bytes() for path in tracked]

    current = deadline - timedelta(seconds=2)
    summary = scan_returns(book, now=current)["results"][0]
    assert summary["expiresAt"] == handoff._stamp(deadline)
    assert scan_returns(book, now=current)["results"] == [summary]
    assert not scan_returns(book, now=deadline)["results"]

    class ExpiredClock(datetime):
        @classmethod
        def now(cls, tz=None):
            return deadline

    monkeypatch.setattr(handoff, "datetime", ExpiredClock)
    monkeypatch.setattr(ocr_returns, "datetime", ExpiredClock)
    with pytest.raises(AppError) as inspect_error:
        workspace.inspect_handoff(returned)
    assert inspect_error.value.code == "expired"
    with pytest.raises(AppError) as import_error:
        workspace.import_handoff(returned, summary["sha256"])
    assert import_error.value.code == "expired"
    assert workspace.tabs == [draft] and workspace.selection == draft.id and draft.dirty
    assert not book.journal.exists
    assert [path.read_bytes() for path in tracked] == previous


@pytest.mark.parametrize("mismatch", ["old", "digest", "reverse-bundle", "source", "page", "failed"])
def test_invalid_old_and_failed_returns_stay_out_of_review(tmp_path, isolated_local, mismatch):
    book, request, _, now = request_fixture(tmp_path, count=1)
    result, payloads = result_fixture(book, now, modern=mismatch != "old", status="failed" if mismatch == "failed" else "completed")
    if mismatch == "digest":
        result["provenance"]["requestManifestSHA256"] = "1" * 64
    if mismatch == "reverse-bundle":
        result["sourceBundleID"] = BUNDLE_ID
    if mismatch == "source":
        result["provenance"]["sources"][0]["sourceSHA256"] = "1" * 64
    if mismatch == "page":
        result["provenance"]["sources"][0]["pages"][0]["pageNumber"] = 2
    returned = isolated_local / request["requestID"] / "result.gaoaction"
    _write_package(returned, result, payloads)
    scan = scan_returns(book, now=now)
    assert not scan["pending"] and not scan["results"] and scan["issues"]
    with pytest.raises(AppError):
        inspect_return(book, returned, now)
    assert not book.journal.exists and returned.is_dir()


def test_manual_legacy_result_and_unreviewed_modern_copy(tmp_path, isolated_local):
    book, _, _, now = request_fixture(tmp_path, count=1)
    path = tmp_path / "manual-modern.gaoaction"
    manifest, payloads = result_fixture(book, now)
    _write_package(path, manifest, payloads)
    with pytest.raises(AppError) as blocked:
        book.import_package(path, now, remember=False)
    assert blocked.value.code == "reviewRequired"
    path = tmp_path / "manual-legacy.gaoaction"
    manifest, payloads = result_fixture(book, now, modern=False)
    _write_package(path, manifest, payloads)
    manual = book.import_package(path, now)
    assert manual["opened"][0]["text"] == "经过审核的文字 1"
    assert book.import_package(path, now)["duplicate"]


def test_explicit_pdf_receipt_can_recover_link_only_for_its_owned_copy(tmp_path, isolated_local):
    workspace = Workspace(tmp_path / "profile")
    book = workspace.handoff
    now = datetime.now(timezone.utc).replace(microsecond=0)
    source = tmp_path / "原 PDF.pdf"
    source.write_bytes(plain_pdf("Original document")[0])
    request = export_request(book, [str(source)], ["searchablePDF"], [], now=now)
    result, _ = result_fixture(book, now)
    recognizable = plain_pdf("Recognized copy")[0]
    result["items"][0].update({"relativePath": "OCR-1.pdf", "uti": "com.adobe.pdf", "byteCount": len(recognizable),
                                "sha256": digest(recognizable)})
    result["provenance"]["outputs"][0]["format"] = "searchablePDF"
    returned = isolated_local / request["requestID"] / "result.gaoaction"
    _write_package(returned, result, {"OCR-1.pdf": recognizable})
    tab = workspace.import_handoff(returned, inspect_return(book, returned, now)[-1])
    assert tab.path != source and source.read_bytes() != recognizable
    reopened = HandoffBook(book.root)
    associated = reopened.incoming_pdf(tab.path, digest(recognizable))
    assert associated == tab.extra["incoming"]
    assert associated["sourcePath"] == str(source) and associated["pages"][0]["pageNumber"] == 1
    decoy = tmp_path / tab.path.name
    decoy.write_bytes(recognizable)
    assert reopened.incoming_pdf(decoy, digest(recognizable)) is None
    assert reopened.incoming_pdf(tab.path, digest(b"changed")) is None
    journal = book.journal.path.read_bytes()
    payload = returned / "payload" / "OCR-1.pdf"
    assert scan_returns(reopened, now=now + TTL) == {"pending": False, "results": [], "issues": []}
    restarted = Workspace(workspace.data_dir)
    assert restarted.open_path(tab.path).extra["incoming"] == associated
    assert tab.path.read_bytes() == payload.read_bytes() == recognizable
    assert restarted.handoff.journal.path.read_bytes() == journal


def test_auto_does_not_follow_reparse_mailbox(tmp_path, isolated_local):
    isolated_local.parent.mkdir(parents=True)
    other = tmp_path / "outside"
    other.mkdir()
    if os.name == "nt":
        junction = subprocess.run(["cmd.exe", "/d", "/c", "mklink", "/J", str(isolated_local), str(other)],
                                  capture_output=True, creationflags=subprocess.CREATE_NO_WINDOW, check=False)
        if junction.returncode:
            pytest.skip("Windows junction creation unavailable in this environment")
    else:
        isolated_local.symlink_to(other, target_is_directory=True)
    try:
        book, request, _, now = request_fixture(tmp_path)
        assert not request["returnEnabled"] and not list(other.iterdir())
        assert not scan_returns(book, now=now)["results"]
        assert (Path(request["path"]) / "manifest.json").is_file()
    finally:
        if os.name == "nt":
            isolated_local.rmdir()
        else:
            isolated_local.unlink()


def test_return_cache_rechecks_payload_changes_and_rejects_missing_own_record(tmp_path, isolated_local):
    book, request, _, now = request_fixture(tmp_path, count=1)
    manifest, payloads = result_fixture(book, now)
    returned = isolated_local / request["requestID"] / "result.gaoaction"
    _write_package(returned, manifest, payloads)
    assert scan_returns(book, now=now)["results"]
    (returned / "payload" / "OCR-1.txt").write_bytes(b"replaced")
    scan = scan_returns(book, now=now)
    assert not scan["results"] and scan["issues"]
    book.outgoing.path.unlink()
    assert scan_returns(book, now=now) == {"pending": False, "results": [], "issues": []}
