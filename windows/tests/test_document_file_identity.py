import json
import os

import pytest

from gaowenjian.errors import AppError
from gaowenjian.pdfdoc import plain_pdf
from gaowenjian.safety import digest, read_file_snapshot, safe_replace
from gaowenjian.workspace import Workspace


def test_workspace_rejects_same_bytes_in_replaced_file_after_restart(tmp_path):
    original = tmp_path / "original.md"
    original.write_bytes(b"# original\n")
    workspace = Workspace(tmp_path / "profile")
    tab = workspace.open_path(original)
    original_identity = tab.file_identity
    if original_identity is None or original_identity.as_record() is None:
        pytest.skip("filesystem did not supply a recoverable file identifier")
    workspace.edit(tab.id, "# recovered edit\n")
    substitute = tmp_path / "substitute.md"
    substitute.write_bytes(original.read_bytes())
    os.replace(substitute, original)
    _, updated_identity = read_file_snapshot(original)
    if updated_identity == original_identity:
        pytest.skip("filesystem cannot distinguish the two file entries")

    for active in (workspace, Workspace(workspace.data_dir)):
        current = active.tabs[0]
        assert current.file_identity == original_identity
        with pytest.raises(AppError, match="其他程序修改") as refused:
            active.save(current.id)
        assert refused.value.code == "conflict"
        assert current.dirty and original.read_bytes() == b"# original\n"
    destination = tmp_path / "saved-copy.md"
    workspace.save(tab.id, destination, as_copy=True)
    assert destination.read_bytes() == b"# recovered edit\n"
    assert not list(tmp_path.glob(".pending-*"))


@pytest.mark.parametrize("mutation", ["modify", "remove"])
def test_rechecks_destination_after_fsync_of_staged_replacement(tmp_path, monkeypatch, mutation):
    target = tmp_path / "original.txt"
    target.write_bytes(b"original")
    initial, identity = read_file_snapshot(target)
    real_fsync = os.fsync

    def mutate_after_fsync(handle):
        real_fsync(handle)
        if mutation == "modify":
            target.write_bytes(b"changed by another editor")
        else:
            target.unlink()

    monkeypatch.setattr(os, "fsync", mutate_after_fsync)
    with pytest.raises(AppError) as error:
        safe_replace(target, b"replacement", digest(initial), expected_identity=identity)
    assert error.value.code == ("conflict" if mutation == "modify" else "missing")
    if mutation == "modify":
        assert target.read_bytes() == b"changed by another editor"
    else:
        assert not target.exists()
    assert not list(tmp_path.glob(".pending-*"))


def test_legacy_digest_only_recovery_can_save_and_refresh_file_identity(tmp_path):
    source = tmp_path / "legacy.md"
    source.write_bytes(b"# original\n")
    profile = tmp_path / "profile"
    profile.mkdir()
    (profile / "recovery.json").write_text(json.dumps([{
        "path": str(source), "kind": "markdown", "text": "# restored\n", "digest": digest(source.read_bytes()),
    }]), encoding="utf-8")
    workspace = Workspace(profile)
    tab = workspace.tabs[0]
    assert tab.file_identity is None
    workspace.save(tab.id)
    assert read_file_snapshot(source) == (b"# restored\n", tab.file_identity)
    workspace.edit(tab.id, "# edit number two\n")
    workspace.save(tab.id)
    assert read_file_snapshot(source) == (b"# edit number two\n", tab.file_identity)


def test_same_bytes_replaced_pdf_has_recovery_copy_instead_of_applied_draft(tmp_path):
    source = tmp_path / "original.pdf"
    content, _ = plain_pdf("Original")
    source.write_bytes(content)
    workspace = Workspace(tmp_path / "profile")
    tab = workspace.open_path(source)
    workspace.pdf_action(tab.id, "rotate", {"pages": [0], "degrees": 90})
    revised = tab.binary
    substitute = tmp_path / "substitute.pdf"
    substitute.write_bytes(content)
    os.replace(substitute, source)
    if tab.file_identity is None or tab.file_identity.as_record() is None:
        pytest.skip("filesystem did not supply a recoverable file identifier")

    restarted = Workspace(workspace.data_dir)
    current = restarted.open_path(source)
    assert current.preview["canRecover"] and current.binary == content and not current.dirty
    exported = tmp_path / "recovered-copy.pdf"
    restarted.pdf_action(current.id, "recovery-copy", {"path": str(exported)})
    assert exported.read_bytes() == revised
    assert source.read_bytes() == content
