from __future__ import annotations

import uuid

import pytest

from gaowenjian.errors import AppError
from gaowenjian.handoff import _write_package, read_package
from gaowenjian.workspace import Workspace
from test_ocr_returns import isolated_local, request_fixture, result_fixture


def test_failed_receipt_preserves_only_existing_drafts(tmp_path, isolated_local, monkeypatch):
    profile = tmp_path / "profile"
    workspace = Workspace(profile)
    draft = workspace.new_text("markdown", "已有未保存稿")
    original_recovery = workspace.recovery_guard.path.read_bytes()
    book, _, paths, now = request_fixture(tmp_path, book=workspace.handoff, count=1)
    manifest, payloads = result_fixture(book, now)
    package = tmp_path / "result.gaoaction"
    _write_package(package, manifest, payloads)
    review = workspace.inspect_handoff(package)

    def fail(_):
        raise AppError("fixture journal write failure", "conflict")

    monkeypatch.setattr(book, "finish_import", fail)
    with pytest.raises(AppError, match="fixture journal write failure"):
        workspace.import_handoff(package, review["sha256"])
    assert workspace.tabs == [draft] and workspace.selection == draft.id
    assert workspace.recovery_guard.path.read_bytes() == original_recovery
    assert [tab.text for tab in Workspace(profile).tabs] == [draft.text]
    assert paths[0].read_bytes() == b"synthetic source 0"


def test_interrupted_receipt_reuses_recovered_text_on_repack(tmp_path, isolated_local, monkeypatch):
    class Interrupted(BaseException):
        pass

    profile = tmp_path / "profile"
    workspace = Workspace(profile)
    book, _, paths, now = request_fixture(tmp_path, book=workspace.handoff, count=1)
    manifest, payloads = result_fixture(book, now)
    package = tmp_path / "result.gaoaction"
    _write_package(package, manifest, payloads)

    def interrupt(_):
        raise Interrupted()

    monkeypatch.setattr(book, "finish_import", interrupt)
    with pytest.raises(Interrupted):
        workspace.import_handoff(package, workspace.inspect_handoff(package)["sha256"])

    reopened = Workspace(profile)
    [recovered] = reopened.tabs
    reopened.edit(recovered.id, "用户从恢复稿继续写作")
    manifest["requestID"] = str(uuid.uuid4())
    rewrapped = tmp_path / "rewrapped.gaoaction"
    _write_package(rewrapped, manifest, payloads)
    review = reopened.inspect_handoff(rewrapped)
    assert reopened.import_handoff(rewrapped, review["sha256"]) is recovered
    assert reopened.tabs == [recovered] and recovered.text == "用户从恢复稿继续写作"
    assert paths[0].read_bytes() == b"synthetic source 0"

    manifest["parameters"]["outputs"] = ["text", "markdown"]
    conflicting = tmp_path / "conflicting.gaoaction"
    _write_package(conflicting, manifest, payloads)

    with pytest.raises(AppError) as rejected:
        reopened.import_handoff(conflicting, read_package(conflicting)[-1])
    assert rejected.value.code == "handoffConflict"
    assert reopened.tabs == [recovered]


def test_receipt_readback_error_does_not_discard_a_committed_draft(tmp_path, isolated_local, monkeypatch):
    profile = tmp_path / "profile"
    workspace = Workspace(profile)
    book, _, paths, now = request_fixture(tmp_path, book=workspace.handoff, count=1)
    manifest, payloads = result_fixture(book, now)
    package = tmp_path / "result.gaoaction"
    _write_package(package, manifest, payloads)
    save = book.journal.save

    def report_failure_after_write(record):
        save(record)
        raise AppError("fixture read-back error after replacement", "verify")

    monkeypatch.setattr(book.journal, "save", report_failure_after_write)
    accepted = workspace.import_handoff(package, workspace.inspect_handoff(package)["sha256"])
    restarted = Workspace(profile)
    assert [tab.id for tab in restarted.tabs] == [accepted.id]
    with pytest.raises(AppError) as rejected:
        restarted.import_handoff(package, read_package(package)[-1])
    assert rejected.value.code == "duplicate"
    assert paths[0].read_bytes() == b"synthetic source 0"
