import AppKit
import Foundation

@MainActor func runStickyNotesTests() throws {
    guard FileSafety.root.path.hasPrefix("/private/tmp/"), CommandLine.arguments.contains("--data-dir") else {
        throw FileIssue.message("便笺测试只能使用隔离 /private/tmp 资料目录。")
    }
    let manager = FileManager.default
    let folder = FileSafety.root.appendingPathComponent("StickyTests-" + UUID().uuidString, isDirectory: true)
    try manager.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? manager.removeItem(at: folder) }
    var count = 0
    func expect(_ condition: Bool, _ message: String) { precondition(condition, message); count += 1 }
    func refuse(_ action: () throws -> Void, _ message: String) {
        do { try action(); preconditionFailure(message) } catch { count += 1 }
    }
    func attachment(_ data: Data, name: String) -> NSAttributedString {
        let wrapper = FileWrapper(regularFileWithContents: data); wrapper.preferredFilename = name
        return NSAttributedString(attachment: NSTextAttachment(fileWrapper: wrapper))
    }
    func dataForAttachments(_ content: NSAttributedString) -> [Data] {
        var values: [Data] = []
        content.enumerateAttribute(.attachment, in: NSRange(location: 0, length: content.length)) { value, _, _ in
            if let attachment = value as? NSTextAttachment, let data = attachment.fileWrapper?.regularFileContents { values.append(data) }
        }
        return values
    }
    let rich = NSMutableAttributedString(string: "真实便笺\n第二行\n", attributes: [.font: NSFont.boldSystemFont(ofSize: 19), .foregroundColor: NSColor.systemPurple])
    // A real PNG and PDF are embedded as attachments rather than merely linked to fixture files.
    let image = NSImage(size: NSSize(width: 12, height: 12))
    image.lockFocus(); NSColor.systemBlue.setFill(); NSBezierPath(rect: NSRect(x: 0, y: 0, width: 12, height: 12)).fill(); image.unlockFocus()
    let png = NSBitmapImageRep(data: image.tiffRepresentation!)!.representation(using: .png, properties: [:])!
    let pdfBuffer = NSMutableData()
    var mediaBox = CGRect(x: 0, y: 0, width: 100, height: 120)
    let consumer = CGDataConsumer(data: pdfBuffer)!
    let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil)!
    context.beginPDFPage(nil); context.setFillColor(NSColor.systemRed.cgColor); context.fill(CGRect(x: 10, y: 10, width: 30, height: 30)); context.endPDFPage(); context.closePDF()
    let pdf = pdfBuffer as Data
    rich.append(attachment(png, name: "图片.png")); rich.append(NSAttributedString(string: "\n")); rich.append(attachment(pdf, name: "材料.pdf"))

    let root = folder.appendingPathComponent("Notes", isDirectory: true), store = StickyNotesStore(rootURL: root)
    expect(store.error == nil && store.notes.isEmpty && !store.isDirty, "initial empty database did not load")
    guard let id = store.create(title: "附件便笺", content: rich) else { throw FileIssue.message(store.error ?? "create failed") }
    expect(!store.isDirty && store.notes.count == 1, "new note was not persisted")
    let archive = root.appendingPathComponent("notes.json"), firstArchive = try Data(contentsOf: archive)
    let initialBlobs = try manager.contentsOfDirectory(at: root.appendingPathComponent("Contents"), includingPropertiesForKeys: nil)
    expect(initialBlobs.count == 1, "body blob was not stored once")
    let firstJSON = try JSONSerialization.jsonObject(with: firstArchive) as! [String: Any]
    let firstPayload = firstJSON["payload"] as! [String: Any]
    expect((firstJSON["version"] as? Int) == 2 && (firstPayload["notes"] as! [[String: Any]])[0]["rtfd"] as? String == "", "metadata still contains base64 attachment data")
    let reopened = StickyNotesStore(rootURL: root)
    expect(reopened.error == nil && reopened.content(for: id)?.string == rich.string, "rich text did not round trip")
    expect(dataForAttachments(reopened.content(for: id)!) == [png, pdf], "PNG/PDF attachment bytes changed")
    let restoredFont = reopened.content(for: id)!.attribute(.font, at: 0, effectiveRange: nil) as! NSFont
    expect(restoredFont.pointSize == 19 && NSFontManager.shared.traits(of: restoredFont).contains(.boldFontMask), "font formatting changed")
    expect(reopened.updateMetadata(id: id) { $0.title = "已整理"; $0.group = "研究"; $0.color = .purple; $0.isPinned = true; $0.isTranslucent = true; $0.isCollapsed = true; $0.isOnDesktop = true; $0.frame = StickyNoteFrame(x: -120, y: 20, width: 420, height: 330) }, "metadata edit failed")
    expect(reopened.isDirty && reopened.flush(), "metadata flush failed")
    let metadata = StickyNotesStore(rootURL: root).notes[0]
    expect(metadata.title == "已整理" && metadata.group == "研究" && metadata.color == .purple && metadata.isPinned && metadata.isTranslucent && metadata.isCollapsed && metadata.isOnDesktop && metadata.frame.x == -120, "metadata was lost")
    let snapshots = try manager.contentsOfDirectory(at: root.appendingPathComponent("History"), includingPropertiesForKeys: nil)
    expect(try snapshots.contains { try Data(contentsOf: $0) == firstArchive }, "verified original snapshot missing")
    expect(reopened.setDefaults(from: id), "default style save failed")
    expect(try manager.contentsOfDirectory(at: root.appendingPathComponent("Contents"), includingPropertiesForKeys: nil).count == initialBlobs.count, "metadata changes duplicated attachment blobs")
    let metadataHistory = try manager.contentsOfDirectory(at: root.appendingPathComponent("History"), includingPropertiesForKeys: nil)
    expect(try metadataHistory.allSatisfy { try Data(contentsOf: $0).count < 16_384 }, "metadata history copied full attachment packages")
    guard let blank = reopened.create() else { throw FileIssue.message("empty note creation failed") }
    expect(reopened.content(for: blank)?.string == "" && reopened.notes.first(where: { $0.id == blank })?.color == .purple && reopened.defaults.fontSize == 19, "default style copied content or lost style")
    expect(reopened.updateContent(id: id, content: NSAttributedString(string: "")) && reopened.flush(), "empty replacement failed")
    expect(StickyNotesStore(rootURL: root).content(for: id)?.string == "", "empty edited text was lost")
    expect(reopened.trash(id: id) && reopened.notes.first(where: { $0.id == id })?.deletedAt != nil, "soft deletion failed")
    expect(StickyNotesStore(rootURL: root).notes.contains(where: { $0.id == id && $0.deletedAt != nil }), "trash did not persist")
    expect(reopened.restore(id: id) && reopened.notes.first(where: { $0.id == id })?.deletedAt == nil, "trash restore failed")
    expect(reopened.updateContent(id: id, content: rich) && reopened.flush(), "attachment content restore failed")

    let rtfdURL = folder.appendingPathComponent("导出.rtfd"), txtURL = folder.appendingPathComponent("导出.txt"), rtfURL = folder.appendingPathComponent("导出.rtf")
    try reopened.exportNote(id: id, to: rtfdURL, format: .rtfd)
    let importedID = try reopened.importNote(from: rtfdURL)
    expect(dataForAttachments(reopened.content(for: importedID)!) == [png, pdf], "RTFD import/export changed attachments")
    let incompleteRTFD = folder.appendingPathComponent("附件缺失.rtfd")
    try manager.copyItem(at: rtfdURL, to: incompleteRTFD)
    let pngMember = try manager.contentsOfDirectory(at: incompleteRTFD, includingPropertiesForKeys: nil).first(where: { $0.pathExtension.lowercased() == "png" })!
    try manager.removeItem(at: pngMember)
    let beforeIncompleteImport = reopened.notes.count
    refuse({ _ = try reopened.importNote(from: incompleteRTFD) }, "RTFD with a missing attachment was imported as complete")
    expect(reopened.notes.count == beforeIncompleteImport, "failed import created a partial note")
    refuse({ try reopened.exportNote(id: id, to: rtfURL, format: .rtf) }, "RTF export silently dropped attachments")
    expect(!manager.fileExists(atPath: rtfURL.path), "refused RTF export created target")
    try reopened.exportNote(id: id, to: txtURL, format: .txt)
    expect(try String(contentsOf: txtURL, encoding: .utf8) == rich.string, "plain text export changed text")
    let txtOriginal = try Data(contentsOf: txtURL)
    refuse({ try reopened.exportNote(id: id, to: txtURL, format: .txt) }, "existing target overwritten without digest")
    expect(try Data(contentsOf: txtURL) == txtOriginal, "refused overwrite modified target")
    let txtDigest = try StickyNotesStore.destinationDigest(at: txtURL)
    try Data("外部更改".utf8).write(to: txtURL)
    refuse({ try reopened.exportNote(id: id, to: txtURL, format: .txt, expectedDigest: txtDigest) }, "external export change overwritten")
    let changedDigest = try StickyNotesStore.destinationDigest(at: txtURL)
    try reopened.exportNote(id: id, to: txtURL, format: .txt, expectedDigest: changedDigest)
    expect(try Data(contentsOf: txtURL) == txtOriginal, "approved replacement failed")
    let rtfdDigest = try StickyNotesStore.destinationDigest(at: rtfdURL)
    try reopened.exportNote(id: id, to: rtfdURL, format: .rtfd, expectedDigest: rtfdDigest)
    expect(try StickyNotesStore.destinationDigest(at: rtfdURL) == rtfdDigest, "approved directory replacement changed attachment bytes")
    let exports = try manager.contentsOfDirectory(at: root.appendingPathComponent("History/Exports"), includingPropertiesForKeys: nil)
    expect(try exports.contains { try StickyNotesStore.destinationDigest(at: $0) == changedDigest }, "original export target snapshot missing")

    let simple = NSAttributedString(string: "中文样式", attributes: [.font: NSFont.systemFont(ofSize: 17), .underlineStyle: NSUnderlineStyle.single.rawValue])
    guard let simpleID = reopened.create(title: "简单文本", content: simple) else { throw FileIssue.message("simple note failed") }
    try reopened.exportNote(id: simpleID, to: rtfURL, format: .rtf)
    let rtfID = try reopened.importNote(from: rtfURL)
    expect(reopened.content(for: rtfID)?.string == simple.string && reopened.content(for: rtfID)?.attribute(.underlineStyle, at: 0, effectiveRange: nil) != nil, "RTF style import lost formatting")
    let utf16URL = folder.appendingPathComponent("UTF16.txt")
    try "中文 Unicode\n".data(using: .utf16)!.write(to: utf16URL)
    let textID = try reopened.importNote(from: utf16URL)
    expect(reopened.content(for: textID)?.string == "中文 Unicode\n", "UTF16 import failed")
    expect(reopened.flush(), "final edits did not flush")

    let beforeExternal = try Data(contentsOf: archive)
    let concurrent = StickyNotesStore(rootURL: root)
    expect(concurrent.updateContent(id: simpleID, content: NSAttributedString(string: "当前未保存编辑")), "pending edit failed")
    let external = Data("外部资料，禁止覆盖".utf8); try external.write(to: archive, options: .atomic)
    expect(!concurrent.flush() && concurrent.isDirty && concurrent.content(for: simpleID)?.string == "当前未保存编辑", "external change did not preserve dirty memory")
    expect(try Data(contentsOf: archive) == external, "external bytes were overwritten")
    expect(!concurrent.load() && concurrent.content(for: simpleID)?.string == "当前未保存编辑", "reload discarded dirty content")
    try beforeExternal.write(to: archive, options: .atomic)
    expect(concurrent.flush() && !concurrent.isDirty, "retry after restoring expected original failed")
    expect(concurrent.updateContent(id: simpleID, content: NSAttributedString(string: "删除冲突")), "delete-conflict edit failed")
    let beforeDelete = try Data(contentsOf: archive); try manager.removeItem(at: archive)
    expect(!concurrent.flush() && !manager.fileExists(atPath: archive.path) && concurrent.isDirty, "missing database was silently recreated")
    try beforeDelete.write(to: archive, options: .atomic); expect(concurrent.flush(), "retry after database restoration failed")

    let brokenRoot = folder.appendingPathComponent("Corrupt", isDirectory: true)
    try manager.createDirectory(at: brokenRoot, withIntermediateDirectories: true)
    let brokenURL = brokenRoot.appendingPathComponent("notes.json"), broken = Data("{malformed-json".utf8)
    try broken.write(to: brokenURL)
    let corrupted = StickyNotesStore(rootURL: brokenRoot)
    expect(corrupted.error != nil && corrupted.create() == nil && !corrupted.flush(), "corrupt data accepted empty overwrite")
    expect(try Data(contentsOf: brokenURL) == broken, "corrupt data changed")
    let checksumRoot = folder.appendingPathComponent("Checksum", isDirectory: true)
    try manager.createDirectory(at: checksumRoot, withIntermediateDirectories: true)
    let checksumURL = checksumRoot.appendingPathComponent("notes.json")
    var json = try JSONSerialization.jsonObject(with: Data(contentsOf: archive)) as! [String: Any]
    json["payloadDigest"] = String(repeating: "0", count: 64)
    let invalidChecksum = try JSONSerialization.data(withJSONObject: json, options: [.sortedKeys]); try invalidChecksum.write(to: checksumURL)
    let invalidStore = StickyNotesStore(rootURL: checksumRoot)
    expect(invalidStore.error != nil && invalidStore.create() == nil, "bad archive checksum accepted")
    expect(try Data(contentsOf: checksumURL) == invalidChecksum, "bad checksum was overwritten")
    struct CheckedPayload: Codable { var notes: [StickyNote]; var defaults: StickyNoteDefaults }
    struct CheckedArchive: Codable { var version: Int; var payload: CheckedPayload; var payloadDigest: String }
    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
    try manager.copyItem(at: root.appendingPathComponent("Contents"), to: checksumRoot.appendingPathComponent("Contents"))
    var tampered = try JSONDecoder().decode(CheckedArchive.self, from: Data(contentsOf: archive))
    tampered.payload.notes[0].rtfdDigest = String(repeating: "0", count: 64)
    tampered.payloadDigest = FileSafety.digest(try encoder.encode(tampered.payload))
    let badRichChecksum = try encoder.encode(tampered); try badRichChecksum.write(to: checksumURL, options: .atomic)
    let invalidRichChecksum = StickyNotesStore(rootURL: checksumRoot)
    expect(invalidRichChecksum.error != nil && invalidRichChecksum.notes.isEmpty && invalidRichChecksum.create() == nil, "per-note rich-text checksum failed to block partial publication")
    expect(try Data(contentsOf: checksumURL) == badRichChecksum, "per-note checksum corruption overwritten")
    let unreadableRich = Data("invalid-flat-rtfd".utf8)
    tampered.payload.notes[0].rtfd = Data()
    tampered.payload.notes[0].rtfdDigest = FileSafety.digest(unreadableRich)
    try unreadableRich.write(to: checksumRoot.appendingPathComponent("Contents/" + tampered.payload.notes[0].rtfdDigest + ".rtfd"))
    tampered.payloadDigest = FileSafety.digest(try encoder.encode(tampered.payload))
    let badRichText = try encoder.encode(tampered); try badRichText.write(to: checksumURL, options: .atomic)
    let invalidRichText = StickyNotesStore(rootURL: checksumRoot)
    expect(invalidRichText.error != nil && invalidRichText.notes.isEmpty && invalidRichText.create() == nil, "invalid RTFD bytes accepted despite valid digests")
    expect(try Data(contentsOf: checksumURL) == badRichText, "unreadable rich-text bytes overwritten")
    let legacyRoot = folder.appendingPathComponent("Legacy", isDirectory: true)
    try manager.createDirectory(at: legacyRoot, withIntermediateDirectories: true)
    var legacy = CheckedArchive(version: 1, payload: CheckedPayload(notes: concurrent.notes, defaults: concurrent.defaults), payloadDigest: "")
    legacy.payloadDigest = FileSafety.digest(try encoder.encode(legacy.payload))
    let legacyData = try encoder.encode(legacy), legacyURL = legacyRoot.appendingPathComponent("notes.json")
    try legacyData.write(to: legacyURL)
    let migrated = StickyNotesStore(rootURL: legacyRoot)
    expect(migrated.error == nil && !migrated.isDirty && migrated.notes.count == concurrent.notes.count, "valid embedded schema migration failed")
    expect(dataForAttachments(migrated.content(for: id)!) == [png, pdf], "migration changed real attachment bytes")
    let migratedArchive = try JSONDecoder().decode(CheckedArchive.self, from: Data(contentsOf: legacyURL))
    expect(migratedArchive.version == 2 && migratedArchive.payload.notes.allSatisfy({ $0.rtfd.isEmpty }), "migration did not create lightweight metadata")
    let migrationHistory = try manager.contentsOfDirectory(at: legacyRoot.appendingPathComponent("History"), includingPropertiesForKeys: nil)
    expect(try migrationHistory.contains { try Data(contentsOf: $0) == legacyData }, "migration did not preserve the verified original archive")
    let failedMigrationRoot = folder.appendingPathComponent("FailedMigration", isDirectory: true)
    try manager.createDirectory(at: failedMigrationRoot, withIntermediateDirectories: true)
    let failedMigrationURL = failedMigrationRoot.appendingPathComponent("notes.json")
    try legacyData.write(to: failedMigrationURL)
    try manager.createSymbolicLink(at: failedMigrationRoot.appendingPathComponent("Contents"), withDestinationURL: root.appendingPathComponent("Contents"))
    let migrationFailure = StickyNotesStore(rootURL: failedMigrationRoot)
    expect(migrationFailure.error != nil && migrationFailure.isDirty && !migrationFailure.flush(), "unsafe migration target was followed")
    expect(try Data(contentsOf: failedMigrationURL) == legacyData, "failed migration overwrote original archive")

    let liveBlobDigest = concurrent.notes.first(where: { $0.id == id })!.rtfdDigest
    let liveBlobURL = root.appendingPathComponent("Contents/" + liveBlobDigest + ".rtfd")
    let originalBlob = try Data(contentsOf: liveBlobURL), beforeBlobDamage = try Data(contentsOf: archive)
    expect(concurrent.updateMetadata(id: id) { $0.color = .blue }, "blob damage test edit failed")
    let damagedBlob = Data("损坏的附件包".utf8); try damagedBlob.write(to: liveBlobURL, options: .atomic)
    expect(!concurrent.flush() && concurrent.isDirty, "live save ignored externally corrupted body blob")
    expect(try Data(contentsOf: liveBlobURL) == damagedBlob && Data(contentsOf: archive) == beforeBlobDamage, "corrupt blob or metadata were overwritten")
    let corruptBlobLoad = StickyNotesStore(rootURL: root)
    expect(corruptBlobLoad.error != nil && corruptBlobLoad.notes.isEmpty && corruptBlobLoad.create() == nil, "corrupt body blob published partial records")
    try originalBlob.write(to: liveBlobURL, options: .atomic); expect(concurrent.flush(), "restored body blob did not permit retry")
    let beforeBlobDelete = try Data(contentsOf: archive)
    expect(concurrent.updateMetadata(id: id) { $0.color = .green }, "blob deletion test edit failed")
    try manager.removeItem(at: liveBlobURL)
    expect(!concurrent.flush() && !manager.fileExists(atPath: liveBlobURL.path), "missing body blob was silently recreated from cache")
    let missingBlobLoad = StickyNotesStore(rootURL: root)
    expect(missingBlobLoad.error != nil && missingBlobLoad.notes.isEmpty && missingBlobLoad.create() == nil, "missing blob treated as empty note")
    expect(try Data(contentsOf: archive) == beforeBlobDelete, "missing blob save changed metadata")
    try originalBlob.write(to: liveBlobURL, options: .atomic); expect(concurrent.flush(), "restored missing blob did not permit retry")
    let missingRoot = folder.appendingPathComponent("MissingRecord", isDirectory: true)
    try manager.createDirectory(at: missingRoot.appendingPathComponent("History"), withIntermediateDirectories: true)
    let missingStore = StickyNotesStore(rootURL: missingRoot)
    expect(missingStore.error != nil && missingStore.create() == nil, "missing record with existing history treated as empty")

    let symlink = folder.appendingPathComponent("linked.txt")
    try manager.createSymbolicLink(at: symlink, withDestinationURL: txtURL)
    refuse({ try reopened.exportNote(id: id, to: symlink, format: .txt) }, "export followed symbolic link")
    let orphan = folder.appendingPathComponent("dangling.txt")
    try manager.createSymbolicLink(at: orphan, withDestinationURL: folder.appendingPathComponent("absent.txt"))
    refuse({ _ = try reopened.importNote(from: orphan) }, "import accepted dangling symlink")
    let invalidAttachment = NSMutableAttributedString(string: "附件未加载")
    invalidAttachment.append(NSAttributedString(attachment: NSTextAttachment()))
    expect(!concurrent.updateContent(id: simpleID, content: invalidAttachment), "unreadable attachment accepted")
    print("PASS: sticky notes rich text, PNG/PDF attachments, lightweight metadata history, immutable blobs, checked schema migration, defaults, empty text, recycle bin, TXT/RTF/RTFD import/export, snapshots, conflicts, corruption and symlink protection (\(count) assertions).")
}
