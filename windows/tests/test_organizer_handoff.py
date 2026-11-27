from __future__ import annotations

import json
import os
import zipfile

import pytest

from gaowenjian.errors import AppError
from gaowenjian.handoff import _request, read_package
from gaowenjian.organizer import Organizer, dispatch
from gaowenjian.organizer_actions import complete
from gaowenjian.safety import digest
from gaowenjian.workspace import Workspace


def sample(tmp_path):
    data = tmp_path / "isolated"
    root = tmp_path / "documents"
    root.mkdir()
    workspace = Workspace(data)
    organizer = workspace.organizer
    assert organizer.overview() == {"initialized": False}
    assert not (data / "WindowsOrganizer").exists()
    organizer.initialize()
    root_id = organizer.authorize(str(root))["id"]
    return workspace, organizer, root, root_id


def test_organizer_search_favorites_workspaces_and_revoke(tmp_path):
    workspace, organizer, root, root_id = sample(tmp_path)
    document = root / "ＡＢＣ中文.md"
    document.write_text("# test", encoding="utf-8")
    hidden = root / ".隐藏"
    hidden.mkdir()
    (hidden / "secret.txt").write_text("ignore", encoding="utf-8")
    (root / "papers.pdf").write_bytes(b"test")
    assert organizer.scan(root_id)["count"] == 2
    found = organizer.search({"query": "abc 中文", "extension": "md"})["items"]
    assert [item["name"] for item in found] == ["ＡＢＣ中文.md"]
    file_id = found[0]["id"]
    organizer.favorite(file_id, "科研")
    organizer.create_space("项目")
    organizer.save_query("查询", "中文", ".md")
    reloaded = Organizer(workspace.data_dir)
    space = reloaded.overview()["spaces"][0]["id"]
    reloaded.member(space, file_id)
    assert reloaded.search({"favorite": True, "space": space})["items"][0]["tags"] == "科研"
    assert reloaded.overview()["queries"][0]["query"] == "中文"
    assert reloaded.open_file(file_id) == document
    document.write_text("external modification", encoding="utf-8")
    with pytest.raises(AppError, match="已变化"):
        reloaded.open_file(file_id)
    reloaded.revoke(root_id)
    assert reloaded.search({})["items"] == []
    assert document.read_text(encoding="utf-8") == "external modification"


@pytest.mark.skipif(os.name != "nt", reason="MoveFile handle-based rename is Windows-only.")
def test_organizer_moves_by_handle_after_confirmation(tmp_path):
    workspace, organizer, root, root_id = sample(tmp_path)
    source, target = root / "源.txt", root / "目标.txt"
    source.write_text("original", encoding="utf-8")
    organizer.scan(root_id)
    identifier = organizer.search({})["items"][0]["id"]
    tab = workspace.open_path(source)
    with pytest.raises(AppError, match="关闭"):
        dispatch(workspace, "plan", {"id": identifier, "root": root_id, "path": str(target)})
    workspace.close(tab.id, False)
    organizer.favorite(identifier, "protected")
    plan = dispatch(workspace, "plan", {"id": identifier, "root": root_id, "path": str(target)})
    with pytest.raises(AppError, match="确认"):
        dispatch(workspace, "execute", {"id": plan["id"]})
    target.write_text("other owner", encoding="utf-8")
    with pytest.raises(AppError, match="已存在"):
        dispatch(workspace, "execute", {"id": plan["id"], "confirm": True})
    assert target.read_text() == "other owner"
    assert source.read_text() == "original"
    target.unlink()
    assert dispatch(workspace, "execute", {"id": plan["id"], "confirm": True})["status"] == "moved"
    assert not source.exists() and target.read_text() == "original"
    assert organizer.open_file(identifier) == target
    assert organizer.search({"favorite": True})["items"][0]["tags"] == "protected"
    assert Organizer(workspace.data_dir).overview()["moves"][0]["status"] == "moved"


def test_organizer_corrupt_index_is_retained(tmp_path):
    _, organizer, _, _ = sample(tmp_path)
    organizer.database.write_bytes(b"damaged")
    with pytest.raises(AppError, match="无法读取"):
        organizer.overview()
    with pytest.raises(AppError, match="无法读取"):
        organizer.initialize()
    assert organizer.database.read_bytes() == b"damaged"


def create_text_package(tmp_path, content=b"approved"):
    from datetime import datetime, timezone
    import uuid

    now = datetime.now(timezone.utc)
    manifest = _request("documents.newText", str(uuid.uuid4()), "com.gaoseries.GaoWenJian", {}, now)
    manifest["sourceBundleID"] = "com.gaoseries.GaoCiYuan"
    manifest["items"] = [{"id": "input", "relativePath": "note.txt", "uti": "public.utf8-plain-text",
                         "byteCount": len(content), "sha256": digest(content)}]
    path = tmp_path / "test.gaoaction"
    (path / "payload").mkdir(parents=True)
    (path / "manifest.json").write_text(json.dumps(manifest), encoding="utf-8")
    (path / "payload" / "note.txt").write_bytes(content)
    return path, manifest


def test_handoff_tampering_and_review_conflict_leave_drafts_intact(tmp_path):
    workspace = Workspace(tmp_path / "isolated")
    draft = workspace.new_text("markdown", "# saved draft")
    path, manifest = create_text_package(tmp_path)
    review = workspace.inspect_handoff(path)
    attachment = path / "payload" / "note.txt"
    attachment.write_bytes(b"tampered")
    with pytest.raises(AppError, match="SHA-256"):
        workspace.import_handoff(path, review["sha256"])
    assert [tab.id for tab in workspace.tabs] == [draft.id]
    attachment.write_bytes(b"approved")
    manifest["parameters"] = {"suggestedTitle": "replaced"}
    (path / "manifest.json").write_text(json.dumps(manifest), encoding="utf-8")
    with pytest.raises(AppError, match="审核后"):
        workspace.import_handoff(path, review["sha256"])
    assert workspace.import_handoff(path).text == "approved"
    manifest["parameters"] = {"suggestedTitle": "another"}
    (path / "manifest.json").write_text(json.dumps(manifest), encoding="utf-8")
    with pytest.raises(AppError, match="不同的清单"):
        workspace.import_handoff(path)
    assert len(workspace.tabs) == 2


def test_zip_read_does_not_extract_and_preserves_distinct_same_basenames(tmp_path):
    path, manifest = create_text_package(tmp_path)
    manifest["action"] = "documents.open"
    manifest["items"][0]["relativePath"] = "a/note.txt"
    manifest["items"].append({"id": "other", "relativePath": "b/note.txt", "uti": "text/plain",
                              "byteCount": 6, "sha256": digest(b"second")})
    zipped = tmp_path / "text.zip"
    with zipfile.ZipFile(zipped, "w") as archive:
        archive.writestr("container/manifest.json", json.dumps(manifest))
        archive.writestr("container/payload/a/note.txt", b"approved")
        archive.writestr("container/payload/b/note.txt", b"second")
    names = sorted(item.name for item in tmp_path.iterdir())
    assert read_package(zipped)[1] == [b"approved", b"second"]
    assert sorted(item.name for item in tmp_path.iterdir()) == names


def test_organizer_handoff_search_requires_real_index_matches_and_confirmation(tmp_path):
    from datetime import datetime, timezone
    import uuid

    workspace, organizer, root, root_id = sample(tmp_path)
    document = root / "合成资料.txt"
    document.write_text("fixture", encoding="utf-8")
    organizer.scan(root_id)
    manifest = _request("files.search", str(uuid.uuid4()), "com.gaoseries.GaoWenJian", {"query": "合成"},
                        datetime.now(timezone.utc))
    manifest["sourceBundleID"] = "com.gaoseries.GaoYanJiu"
    path = tmp_path / "external.gaoaction"
    path.mkdir()
    (path / "manifest.json").write_text(json.dumps(manifest), encoding="utf-8")
    reviewed = workspace.inspect_handoff(path)
    candidate = reviewed["organizer"]["candidates"][0]
    payload = {"path": str(path), "sha256": reviewed["sha256"], "destination": str(tmp_path), "ids": [candidate["id"]]}
    with pytest.raises(AppError, match="审核"):
        complete(workspace, payload)
    assert not list(tmp_path.glob("Organizer-*.gaoaction"))
    result = complete(workspace, {**payload, "confirm": True})
    manifest, files, _ = read_package(type(path)(result["path"]), target="com.gaoseries.GaoYanJiu")
    assert not files and manifest["status"] == "completed"
    assert manifest["references"][0]["fileURL"] == document.as_uri()
    assert manifest["provenance"]["accessRequiresReceiverVerification"] is True
    with pytest.raises(AppError, match="已处理"):
        complete(workspace, {**payload, "confirm": True})
