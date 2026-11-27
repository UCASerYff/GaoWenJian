import json

import pytest
from pypdf import PdfWriter

from gaowenjian.errors import AppError
from gaowenjian.web import dispatch
from gaowenjian.workspace import Workspace


def manuscript(root, name, content="# 合成文稿"):
    root.mkdir(exist_ok=True)
    path = root / name
    path.write_text(content, encoding="utf-8")
    return path


def save_project(workspace, name, main, positions=None):
    return dispatch(workspace, "/api/projects/save", {
        "name": name, "folder": str(main.parent), "main": str(main), "reading": positions or {},
    })["id"]


def test_project_refs_and_cold_pdf_reading_position(tmp_path):
    data = tmp_path / "data"
    main = manuscript(tmp_path / "项目", "正文.md", "# 仅在原件中的合成正文")
    reference = manuscript(tmp_path / "外部参考", "资料.txt")
    pdf = main.parent / "校样.pdf"
    writer = PdfWriter()
    for _ in range(3):
        writer.add_blank_page(width=420, height=720)
    writer.write(pdf)
    workspace = Workspace(data)
    workspace.open_path(main)
    workspace.open_path(reference)
    preview = workspace.open_path(pdf)
    project_id = save_project(workspace, "论文", main, {preview.id: {"page": 2, "offset": .4}})

    stored = (data / "writing-projects.json").read_text(encoding="utf-8")
    assert "仅在原件中的合成正文" not in stored
    assert json.loads(stored)["schemaVersion"] == 1
    reopened = Workspace(data)
    assert reopened.projects.snapshot()["lastOpened"] == project_id
    assert reopened.tabs == []
    restored = dispatch(reopened, "/api/projects/restore", {"id": project_id})
    assert restored["issues"] == []
    assert reopened.folder == main.parent
    assert [tab.path for tab in reopened.tabs] == [main, reference, pdf]
    assert reopened._tab(reopened.selection).path == pdf
    assert reopened._tab(reopened.selection).project_reading == {"page": 2, "offset": .4}


def test_switch_protects_unsaved_and_restores_missing_original_without_recreation(tmp_path):
    data = tmp_path / "data"
    alpha = manuscript(tmp_path / "甲项目", "甲正文.md")
    beta = manuscript(tmp_path / "乙项目", "乙正文.md")
    workspace = Workspace(data)
    alpha_tab = workspace.open_path(alpha)
    alpha_id = save_project(workspace, "项目甲", alpha)
    workspace.close(alpha_tab.id)
    beta_tab = workspace.open_path(beta)
    beta_id = save_project(workspace, "项目乙", beta)
    workspace.edit(beta_tab.id, "# 项目乙草稿")
    before = (data / "writing-projects.json").read_bytes()
    with pytest.raises(AppError) as rejected:
        workspace.projects.restore({"id": alpha_id})
    assert rejected.value.code == "dirty"
    assert workspace.projects.active == beta_id
    assert (data / "writing-projects.json").read_bytes() == before

    unnamed = workspace.new_text("text", "独立未命名草稿")
    beta.unlink()
    restore = workspace.projects.restore({"id": alpha_id, "drafts": "keep"})
    assert restore["keptDrafts"] == 2
    assert beta_tab in workspace.tabs and unnamed in workspace.tabs
    workspace.projects.checkpoint({})
    a_session = next(item for item in workspace.projects.snapshot()["items"] if item["id"] == alpha_id)
    assert a_session["documents"] == [{"path": str(alpha)}]

    restarted = Workspace(data)
    outcome = restarted.projects.restore({"id": beta_id, "drafts": "keep"})
    assert any(item["path"] == str(beta) for item in outcome["issues"])
    assert restarted._tab(unnamed.id).text == "独立未命名草稿"
    kept = restarted._tab(beta_tab.id)
    assert kept.dirty and kept.text == "# 项目乙草稿"
    assert not beta.exists()


def test_missing_reference_stays_in_checkpoint_and_can_be_reopened(tmp_path):
    data = tmp_path / "data"
    main = manuscript(tmp_path / "项目", "正文.md")
    appendix = manuscript(main.parent, "附录.txt")
    workspace = Workspace(data)
    workspace.open_path(main)
    workspace.open_path(appendix)
    project_id = save_project(workspace, "书稿", main)
    appendix.unlink()
    second = Workspace(data)
    assert second.projects.restore({"id": project_id})["issues"][0]["path"] == str(appendix)
    second.projects.checkpoint({})
    appendix.write_text("重新可用的合成附录", encoding="utf-8")
    assert second.projects.restore({"id": project_id})["issues"] == []
    assert [tab.path for tab in second.tabs] == [main, appendix]


def test_project_latex_reader_and_main_location_guard(tmp_path):
    data = tmp_path / "data"
    main = manuscript(tmp_path / "写作", "主文件.tex")
    section = manuscript(main.parent, "章节.tex")
    outside = manuscript(tmp_path / "其他", "外部正文.md")
    workspace = Workspace(data)
    chapter = workspace.open_path(section)
    with pytest.raises(AppError, match="项目目录内"):
        workspace.projects.save({"name": "错误目录", "folder": str(main.parent), "main": str(outside)})
    workspace.projects.reader_page(chapter.id, 4)
    project_id = save_project(workspace, "LaTeX 专著", main, {chapter.id: {"previewPage": 3}})
    resumed = Workspace(data)
    resumed.projects.restore({"id": project_id})
    assert resumed._tab(resumed.selection).project_reading == {"previewPage": 3, "readerPage": 4}
    assert any(tab.path == main for tab in resumed.tabs)


def test_compiled_latex_draft_checkpoint_does_not_copy_runtime_paths(tmp_path):
    data = tmp_path / "data"
    main = manuscript(tmp_path / "写作", "主文件.tex")
    workspace = Workspace(data)
    editor = workspace.open_path(main)
    editor.extra.update(compiledPdf=data / "Builds" / "temporary.pdf", compiledRoot=main, compiledDigest="test")
    workspace.edit(editor.id, "编译后继续写作")
    save_project(workspace, "LaTeX 续写", main)
    resumed = Workspace(data)
    assert resumed._tab(editor.id).text == "编译后继续写作"
    assert "compiledPdf" not in resumed._tab(editor.id).extra


@pytest.mark.parametrize("protected", [b"{broken json", b'{"schemaVersion": 2, "projects": []}'])
def test_future_or_corrupt_project_metadata_remains_protected(tmp_path, protected):
    data = tmp_path / "data"
    data.mkdir()
    record = data / "writing-projects.json"
    record.write_bytes(protected)
    workspace = Workspace(data)
    main = manuscript(tmp_path / "项目", "正文.md")
    assert workspace.projects.snapshot()["blocked"]
    with pytest.raises(AppError):
        save_project(workspace, "受护项目", main)
    assert record.read_bytes() == protected
