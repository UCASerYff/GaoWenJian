import Foundation

@MainActor enum WritingProjectsTests {
    static func run(in directory: URL) throws {
        let data = directory.appendingPathComponent("profile", isDirectory: true)
        let firstFolder = directory.appendingPathComponent("论文与校样", isDirectory: true)
        let secondFolder = directory.appendingPathComponent("下一课题", isDirectory: true)
        for folder in [data, firstFolder, secondFolder] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        let main = firstFolder.appendingPathComponent("主文.md")
        let missing = firstFolder.appendingPathComponent("计划.txt")
        let proof = firstFolder.appendingPathComponent("校样.pdf")
        let alternate = secondFolder.appendingPathComponent("研究.tex")
        let original = Data("# 磁盘原稿\n".utf8)
        try original.write(to: main)
        try Data("暂时离线".utf8).write(to: missing)
        try PDFModuleTests.makeFixture().write(to: proof)
        try Data("\\documentclass{article}\n".utf8).write(to: alternate)
        try require(WritingProjectPaths.key("/tmp//fixture/") == "/private/tmp/fixture" &&
                    WritingProjectPaths.key("/private/tmp/fixture") == "/private/tmp/fixture" &&
                    WritingProjectPaths.key("/var/fixture") == "/private/var/fixture" &&
                    WritingProjectPaths.key("/etc/fixture") == "/private/etc/fixture", "stable system path keys")
        if main.path.hasPrefix("/private/tmp/") {
            let systemPath = String(main.path.dropFirst("/private".count))
            let checked = try WritingProjectPaths.requireExisting(systemPath, directory: false, dataRoot: data)
            try require(checked.path == main.path, "ordinary document opens through the system temporary path")
        }
        let linkedFolder = directory.appendingPathComponent("项目目录链接")
        try FileManager.default.createSymbolicLink(at: linkedFolder, withDestinationURL: firstFolder)
        var rejected = false
        do {
            _ = try WritingProjectPaths.requireExisting(linkedFolder.path + "/" + main.lastPathComponent,
                                                        directory: false, dataRoot: data)
        } catch { rejected = true }
        try require(rejected, "an intermediate user symlink is rejected")
        let store = WorkspaceStore(dataRoot: data)
        let recovery = data.appendingPathComponent("recovery.json")
        store.checkpoint()
        try require(!FileManager.default.fileExists(atPath: recovery.path), "idle workspace does not create an empty recovery file")
        store.open(main)
        store.open(missing)
        store.open(proof)
        let anchor = ProjectPDFPosition(pageIndex: 1, offset: 0.28)
        store.active?.projectReading.restore(.init(document: anchor))
        try store.saveWritingProject(id: nil, name: "论文与校样", folder: firstFolder.path, main: main.path)
        guard let firstID = store.activeWritingProjectID else { throw FileIssue.message("Project creation did not take effect") }
        try require(store.currentWritingProject?.documents.first(where: { $0.path == proof.path })?.reading.document == anchor, "PDF position recorded")
        try require(store.currentWritingProject?.selectedPath == proof.path, "active document recorded")

        for tab in store.tabs { store.close(tab) }
        store.open(alternate)
        try store.saveWritingProject(id: nil, name: "下一个课题", folder: secondFolder.path, main: alternate.path)
        guard let secondID = store.activeWritingProjectID else { throw FileIssue.message("Second project creation failed") }
        try require(secondID != firstID && store.writingProjects.projects.count == 2, "two separate project records")
        try require(store.writingProjectMain(for: store.active!) == alternate, "active project resolves its bound TeX main file")
        let otherDraft = store.active!
        otherDraft.edited("尚未保存的合成课题")
        store.checkpoint()
        let checkpointDate = Date(timeIntervalSince1970: 1_700_000_000)
        try FileManager.default.setAttributes([.modificationDate: checkpointDate], ofItemAtPath: recovery.path)
        store.checkpoint()
        let unchanged = try recovery.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        try require(unchanged == checkpointDate, "unchanged draft does not rewrite its recovery file")
        try FileManager.default.removeItem(at: recovery)
        store.checkpoint()
        try require(FileManager.default.fileExists(atPath: recovery.path), "missing active draft recovery is recreated")
        rejected = false
        do { try store.restoreWritingProject(firstID, drafts: .requireSaved) } catch { rejected = true }
        try require(rejected && store.activeWritingProjectID == secondID && store.active === otherDraft, "restore requires explicit draft decision and leaves workspace untouched")

        try FileManager.default.removeItem(at: missing)
        try FileManager.default.createSymbolicLink(at: missing, withDestinationURL: alternate)
        try store.restoreWritingProject(firstID, drafts: .preserveDrafts)
        try require(store.active?.url == proof && store.active?.projectReading.capture().document == anchor, "selected PDF and normalized page offset restored")
        try require(store.tabs.contains { $0 === otherDraft && $0.dirty && $0.text == "尚未保存的合成课题" }, "old project draft remains live")
        try require(store.unavailableProjectFiles.contains { $0.path == missing.path } && !store.tabs.contains { $0.url == missing }, "replaced symlink is reported without opening it")
        try require(try Data(contentsOf: main) == original, "restore leaves original bytes in place")
        try store.checkpointWritingProject()
        try require(store.currentWritingProject?.documents.contains { $0.path == missing.path } == true, "unavailable entry still in the project record")
        try require(store.currentWritingProject?.documents.contains { $0.path == alternate.path } == false, "carried draft is kept outside the new project's document list")

        try FileManager.default.removeItem(at: missing)
        try Data("重新可用".utf8).write(to: missing)
        let cold = WorkspaceStore(dataRoot: data)
        try require(cold.writingProjects.lastOpened == firstID && cold.writingProjects.projects.count == 2, "cold catalog restore")
        try require(cold.tabs.contains { $0.id == otherDraft.id && $0.dirty && $0.text == otherDraft.text }, "previous draft survives restart")
        try cold.restoreWritingProject(firstID, drafts: .preserveDrafts)
        try require(cold.unavailableProjectFiles.isEmpty && cold.tabs.contains { $0.url == missing }, "retry picks up the missing file without recreating it")
        try require(cold.active?.projectReading.capture().document == anchor, "persisted PDF position survives cold restore")

        let unsafe = directory.appendingPathComponent("corrupt-profile", isDirectory: true)
        try FileManager.default.createDirectory(at: unsafe, withIntermediateDirectories: true)
        let record = unsafe.appendingPathComponent("writing-projects.json")
        let unsupported = Data("{\"schemaVersion\":99,\"projects\":[]}".utf8)
        try unsupported.write(to: record)
        let blocked = WorkspaceStore(dataRoot: unsafe)
        rejected = false
        do { try blocked.saveWritingProject(id: nil, name: "无权覆盖", folder: firstFolder.path, main: main.path) } catch { rejected = true }
        try require(try rejected && blocked.writingProjectError != nil && Data(contentsOf: record) == unsupported, "unsupported catalog stays on disk")

        // Half-open next-page geometry is intentionally different from the model's stale current page.
        let visible = ProjectPDFViewport.position(viewport: CGRect(x: 0, y: 720, width: 500, height: 460),
                                                 pages: [(0, CGRect(x: 0, y: 0, width: 400, height: 800)),
                                                         (1, CGRect(x: 0, y: 815, width: 400, height: 800))],
                                                 flipped: true, preferred: 0)
        try require(visible == ProjectPDFPosition(pageIndex: 1, offset: 0), "select actual dominant page rather than stale toolbar value")
        let page = CGRect(x: 0, y: 815, width: 400, height: 800)
        try require(abs(ProjectPDFViewport.scrollY(page: page, viewportHeight: 460, flipped: true, offset: 0.25) - 1015) < 0.001, "flipped viewport restores normalized scroll")
        try require(abs(ProjectPDFViewport.scrollY(page: page, viewportHeight: 460, flipped: false, offset: 0.25) - 955) < 0.001, "nonflipped viewport restores normalized scroll")
        print("写作项目 PASS · 会话切换、缺失与替身保护、冷恢复、PDF 可见页和页内位置")
    }

    private static func require(_ condition: @autoclosure () throws -> Bool, _ label: String) throws {
        guard try condition() else { throw FileIssue.message("Writing projects: " + label) }
    }
}
