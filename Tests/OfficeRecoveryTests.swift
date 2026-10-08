import Foundation

func runOfficeRecoveryTests() throws {
    guard CommandLine.arguments.contains("--data-dir") else { throw OfficeFailure.message("恢复测试必须指定隔离资料目录。") }
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("GaoOfficeRecoveryTest-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    func expect(_ okay: @autoclosure () -> Bool, _ message: String) throws { if !okay() { throw OfficeFailure.message("Office 恢复测试失败：" + message) } }
    let original = root.appendingPathComponent("draft.docx")
    try OfficeFactory.create(kind: "docx", to: original)
    let digest = try OfficePackage.digest(original)
    let package = try OfficePackage(url: original)
    let word = try OfficeWordDocument(package: package)
    word.setText(id: word.paragraphs[0].id, text: "未保存草稿一")
    try word.apply(); try OfficeRecovery.persist(package: package, original: original, originalDigest: digest)
    let first = try OfficeRecovery.read(for: original)!
    let loadedFirst = try OfficeWordDocument(package: OfficePackage(url: first.url))
    try expect(loadedFirst.paragraphs[0].text == "未保存草稿一", "自动草稿可重新读取")
    let originalAfterDraft = try OfficePackage.digest(original)
    try expect(originalAfterDraft == digest, "草稿不会修改原件")
    word.setText(id: word.paragraphs[0].id, text: "未保存草稿二")
    try word.apply(); try OfficeRecovery.persist(package: package, original: original, originalDigest: digest)
    let previous = try OfficeRecovery.read(for: original, previous: true)!
    try expect(previous.record.documentDigest == first.record.documentDigest, "保留上一个完整恢复副本")
    let currentURL = OfficeRecovery.documentURL(for: original)
    let damaged = Data("损坏但必须保留的草稿".utf8); try damaged.write(to: currentURL)
    var refused = false
    do { try OfficeRecovery.persist(package: package, original: original, originalDigest: digest) } catch { refused = true }
    let afterRefusal = try Data(contentsOf: currentURL)
    try expect(refused && afterRefusal == damaged, "损坏草稿不会被当作空内容覆盖")
    let restored = try OfficePackage(url: previous.url)
    OfficeRecovery.discardIfSafe(for: original, expectedOriginalDigest: digest)
    try expect(FileManager.default.fileExists(atPath: currentURL.path), "放弃修改时保留损坏草稿")
    // A fully loaded candidate can be bound to the actual original and must respect external conflicts.
    try restored.bindOriginal(original, expectedDigest: digest)
    try Data("原件外部修改".utf8).write(to: original)
    var conflict = false
    do { try restored.save(to: original) } catch { conflict = true }
    try expect(conflict, "恢复后的保存仍检查原件外部修改")
    try OfficeRecovery.archiveExisting(for: original)
    try expect(!FileManager.default.fileExists(atPath: currentURL.path), "用户选择保留后为新草稿腾出活动位置")
    let retained = FileSafety.root.appendingPathComponent("Recovery/Office/Retained")
    let archived = FileManager.default.enumerator(at: retained, includingPropertiesForKeys: nil)!
    var retainedDamagedBytes = false
    for case let file as URL in archived { if let data = try? Data(contentsOf: file), data == damaged { retainedDamagedBytes = true } }
    try expect(retainedDamagedBytes, "已归档的损坏草稿逐字节保留")
    print("Office recovery tests: PASS (atomic drafts / previous copy / conflict / corruption retention)")
}
