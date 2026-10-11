import Foundation

func runOfficeViewerTests() throws {
    guard CommandLine.arguments.contains("--data-dir"), FileSafety.root.path.hasPrefix("/private/tmp/") else {
        throw OfficeFailure.message("Office 查看器测试必须使用隔离临时资料路径。")
    }
    let fm = FileManager.default
    let root = FileSafety.root.appendingPathComponent("OfficeViewerTests-\(UUID().uuidString)", isDirectory: true)
    try fm.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: root) }
    func expect(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        guard try condition() else { throw OfficeFailure.message("Office 查看器测试失败：" + message) }
    }
    // All native Office readers open read-only previews, retain real bytes, and remove owned preview copies on close.
    for ext in ["docx", "xlsx", "pptx"] {
        let original = root.appendingPathComponent("文档.\(ext)")
        try OfficeFactory.create(kind: ext, to: original)
        let before = try Data(contentsOf: original)
        let modified = try original.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        let snapshotURL: URL
        do {
            let snapshot = try OfficeReadOnlySnapshot(url: original)
            snapshotURL = snapshot.previewURL
            try expect(snapshotURL != original, "\(ext) 预览没有使用原件路径")
            try expect(try Data(contentsOf: snapshotURL) == before, "\(ext) 预览副本保持完整字节")
            try expect(!snapshot.sections.isEmpty, "\(ext) 可以读取查阅内容")
            let permissions = try fm.attributesOfItem(atPath: snapshotURL.path)[.posixPermissions] as? NSNumber
            try expect(permissions?.intValue == 0o400, "\(ext) 预览副本是只读权限")
            let refresh = try OfficeReadOnlySnapshot(url: original)
            try expect(refresh.previewURL != snapshotURL, "刷新使用独立副本")
        }
        try expect(!fm.fileExists(atPath: snapshotURL.path), "\(ext) 关闭时清理临时副本")
        try expect(try Data(contentsOf: original) == before, "\(ext) 查看和刷新后原件字节不变")
        try expect(try original.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate == modified, "\(ext) 不修改原件时间戳")
    }
    // A stale but valid cached formula must be displayed exactly as saved, not silently recalculated by the old editor model.
    var files = OfficeFactory.excelFiles
    files["xl/worksheets/sheet1.xml"] = files["xl/worksheets/sheet1.xml"]!.replacingOccurrences(of: "<f>SUM(B2:B2)</f><v>10</v>", with: "<f>SUM(B2:B2)</f><v>4321</v>")
    let excel = root.appendingPathComponent("缓存.xlsx")
    try OfficePackage(files: files).save(to: excel)
    let excelBytes = try Data(contentsOf: excel)
    let sheet = try OfficeReadOnlySnapshot(url: excel)
    try expect(sheet.sections[0].rows.first(where: { $0.label == "B3" })?.text == "4321", "查看器使用文件缓存而不是重算")
    try expect(sheet.sections[0].rows.first(where: { $0.label == "B3" })?.formula == "=SUM(B2:B2)", "公式只读可查阅")
    try expect(try Data(contentsOf: excel) == excelBytes, "缓存查阅不回写工作簿")

    // Old binary formats pass through unchanged to native preview; they never enter an editing/conversion path.
    for ext in ["doc", "xls", "ppt", "odt", "ods", "odp"] {
        let original = root.appendingPathComponent("旧格式.\(ext)")
        let bytes = Data([0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1, 42])
        try bytes.write(to: original)
        let snapshot = try OfficeReadOnlySnapshot(url: original)
        try expect(snapshot.sections.isEmpty, "旧格式使用系统预览而不是OOXML编辑模型")
        try expect(try Data(contentsOf: snapshot.previewURL) == bytes && Data(contentsOf: original) == bytes, "旧格式预览原件和副本字节一致")
    }

    // Recovery can be exported independently even when the original changed since the draft, retaining both generations.
    let original = root.appendingPathComponent("旧版草稿.docx")
    try OfficeFactory.create(kind: "docx", to: original)
    let originalBytes = try Data(contentsOf: original)
    let package = try OfficePackage(url: original)
    let document = try OfficeWordDocument(package: package)
    document.setText(id: document.paragraphs[0].id, text: "恢复旧版未保存的文字")
    try document.apply()
    try OfficeRecovery.persist(package: package, original: original, originalDigest: OfficePackage.hash(originalBytes))
    let candidate = try OfficeRecovery.read(for: original)!
    let draftBytes = try Data(contentsOf: candidate.url)
    let metadataBytes = try Data(contentsOf: OfficeRecovery.metadataURL(candidate.url))
    let changedOriginal = Data("文件已被外部程序更新".utf8)
    try changedOriginal.write(to: original)
    let destination = root.appendingPathComponent("恢复副本.docx")
    try OfficeViewerRecovery.export(candidate, to: destination)
    let recoveryView = try OfficeReadOnlySnapshot(url: candidate.url)
    try expect(recoveryView.sections[0].rows.contains(where: { $0.text == "恢复旧版未保存的文字" }), "旧版草稿可只读查看")
    try expect(try Data(contentsOf: destination) == draftBytes, "恢复副本逐字节导出")
    try expect(try Data(contentsOf: original) == changedOriginal, "原件已经外部修改时也不会被恢复覆盖")
    try expect(try Data(contentsOf: candidate.url) == draftBytes && Data(contentsOf: OfficeRecovery.metadataURL(candidate.url)) == metadataBytes, "恢复资料和元数据继续保留")
    var overwriteRefused = false
    do { try OfficeViewerRecovery.export(candidate, to: original) } catch { overwriteRefused = true }
    try expect(overwriteRefused, "恢复副本拒绝覆盖原件")
    try fm.removeItem(at: original)
    var recreateRefused = false
    let nested = root.appendingPathComponent("现有目录", isDirectory: true)
    try fm.createDirectory(at: nested, withIntermediateDirectories: false)
    let equivalentOriginal = nested.appendingPathComponent("../" + original.lastPathComponent)
    do { try OfficeViewerRecovery.export(candidate, to: equivalentOriginal) } catch { recreateRefused = true }
    try expect(recreateRefused && !fm.fileExists(atPath: original.path), "原件删除后仍拒绝在其标准化路径重建")
    let separateRecovery = root.appendingPathComponent("原件删除后的恢复副本.docx")
    try OfficeViewerRecovery.export(candidate, to: separateRecovery)
    try expect(try Data(contentsOf: separateRecovery) == draftBytes, "原件删除后仍可导出到新的副本路径")
    let corruptBytes = Data("损坏的草稿".utf8)
    try corruptBytes.write(to: candidate.url)
    var corruptRefused = false
    do { try OfficeViewerRecovery.export(candidate, to: root.appendingPathComponent("损坏恢复.docx")) } catch { corruptRefused = true }
    try expect(corruptRefused, "导出前复核草稿摘要")
    try expect(try Data(contentsOf: candidate.url) == corruptBytes && Data(contentsOf: OfficeRecovery.metadataURL(candidate.url)) == metadataBytes, "损坏资料也不会被空白覆盖或删除")
    print("PASS: Office read-only snapshots, cached values, legacy passthrough, retained draft export")
}
