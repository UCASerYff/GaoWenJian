import AppKit
import Foundation

@MainActor enum BackupRemovalTests {
    static func run(in root: URL) throws {
        guard root.path.hasPrefix("/private/tmp/gaowenjian-"), NSApp == nil else {
            throw FileIssue.message("Backup removal tests require isolated temporary data and no application")
        }
        let manager = FileManager.default
        try manager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: root) }
        var assertions = 0
        func require(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
            guard try condition() else { throw FileIssue.message("Backup removal: " + message) }
            assertions += 1
        }
        let store = StickyNotesStore(rootURL: root)
        let body = NSAttributedString(string: "Current note")
        let recycledBody = NSMutableAttributedString(string: "Recycled body with attachment: ")
        let attachmentBytes = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAusB9Wl2xL8AAAAASUVORK5CYII=")!
        let wrapper = FileWrapper(regularFileWithContents: attachmentBytes)
        wrapper.preferredFilename = "retained.png"
        recycledBody.append(NSAttributedString(attachment: NSTextAttachment(fileWrapper: wrapper)))
        guard let note = store.create(title: "Live", content: body),
              let recycled = store.create(title: "Recycled", content: recycledBody) else {
            throw FileIssue.message(store.error ?? "Unable to create synthetic notes")
        }
        let contents = root.appendingPathComponent("Contents", isDirectory: true)
        let oldDigest = store.notes.first { $0.id == note }!.rtfdDigest
        let recycledDigest = store.notes.first { $0.id == recycled }!.rtfdDigest
        try require(store.trash(id: recycled) && store.flush(), "recycle-bin state persisted")
        // Unknown content is not assumed to be an obsolete backup.
        let unknown = contents.appendingPathComponent("unknown-user-file.rtfd")
        let unknownBytes = Data("do not delete an unrecognized file".utf8)
        try unknownBytes.write(to: unknown)
        try require(store.updateContent(id: note, content: NSAttributedString(string: "Updated live body")) && store.flush(), "body update committed")
        let currentDigest = store.notes.first { $0.id == note }!.rtfdDigest
        try require(currentDigest != oldDigest, "updated body has a new digest")
        try require(!manager.fileExists(atPath: contents.appendingPathComponent(oldDigest + ".rtfd").path), "verified obsolete body is removed after commit")
        try require(manager.fileExists(atPath: contents.appendingPathComponent(currentDigest + ".rtfd").path), "current body remains")
        try require(manager.fileExists(atPath: contents.appendingPathComponent(recycledDigest + ".rtfd").path), "recycled note body remains")
        try require(try Data(contentsOf: unknown) == unknownBytes, "unknown file remains untouched")
        try require(!manager.fileExists(atPath: root.appendingPathComponent("History").path), "no automatic note history exists")
        let reopened = StickyNotesStore(rootURL: root)
        try require(reopened.error == nil && reopened.content(for: note)?.string == "Updated live body", "current note reloads")
        try require(reopened.notes.contains { $0.id == recycled && $0.deletedAt != nil }, "recycled note metadata reloads")
        var reloadedAttachment: Data?
        if let content = reopened.content(for: recycled) {
            content.enumerateAttribute(.attachment, in: NSRange(location: 0, length: content.length)) { value, _, _ in
                if let attachment = value as? NSTextAttachment { reloadedAttachment = attachment.fileWrapper?.regularFileContents }
            }
        }
        try require(reloadedAttachment == attachmentBytes, "recycled attachment reloads byte for byte")

        // A rejected external conflict must not trigger any body cleanup.
        let archive = root.appendingPathComponent("notes.json")
        let externalBytes = Data("unreadable external change".utf8)
        try externalBytes.write(to: archive)
        try require(reopened.updateContent(id: note, content: NSAttributedString(string: "Uncommitted edit")), "edit remains in memory")
        try require(!reopened.flush() && reopened.isDirty, "external conflict refuses commit")
        try require(try Data(contentsOf: archive) == externalBytes, "external bytes are never replaced")
        try require(manager.fileExists(atPath: contents.appendingPathComponent(currentDigest + ".rtfd").path), "failed commit does not remove current body")
        try require(manager.fileExists(atPath: contents.appendingPathComponent(recycledDigest + ".rtfd").path), "failed commit preserves recycled body")
        try require(NSApp == nil, "no application or windows were created")
        print("PASS: \(assertions) backup-removal checks; current/recycled/unknown data retained, obsolete known body removed, conflicts preserved")
    }
}
