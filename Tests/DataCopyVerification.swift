import AppKit
import Foundation

/// Install verification reads a backup and initializes production models only
/// after making a separate temporary copy. It never opens the real user store.
@MainActor enum DataCopyVerification {
    static func run(backup: URL) throws {
        let manager = FileManager.default
        let destination = FileSafety.root.standardizedFileURL
        guard NSApp == nil, destination.path.hasPrefix("/private/tmp/gaowenjian-headless."),
              !manager.fileExists(atPath: destination.path), backup.isFileURL,
              backup.standardizedFileURL != destination,
              try backup.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]).isDirectory == true else {
            throw FileIssue.message("Data-copy verification requires a readable backup and a new isolated destination")
        }
        let before = try inventory(backup)
        try manager.copyItem(at: backup, to: destination)
        guard try inventory(destination) == before else { throw FileIssue.message("Isolated backup copy does not match its source") }
        // The workspace's remembered browser folder can point outside the
        // backup. Do not let a decode check enumerate the real user's folders.
        // Quarantine this one optional field in the verified temporary copy.
        let workspaceJSON = destination.appendingPathComponent("workspace.json")
        var folderQuarantined = false
        if manager.fileExists(atPath: workspaceJSON.path) {
            guard var state = try JSONSerialization.jsonObject(with: Data(contentsOf: workspaceJSON)) as? [String: Any] else { throw FileIssue.message("Workspace backup JSON is invalid") }
            if let folder = state["folder"], !(folder is NSNull) {
                guard folder is String else { throw FileIssue.message("Workspace folder record is invalid") }
                state.removeValue(forKey: "folder")
                try JSONSerialization.data(withJSONObject: state).write(to: workspaceJSON, options: .atomic)
                folderQuarantined = true
            }
        }
        let workspace = WorkspaceStore()
        guard workspace.error == nil else { throw FileIssue.message("Workspace backup could not be decoded; original backup remains unchanged") }
        let notes = StickyNotesStore(rootURL: destination.appendingPathComponent("StickyNotes"))
        guard notes.error == nil else { throw FileIssue.message("Sticky backup could not be decoded completely; original backup remains unchanged") }
        var attachmentCount = 0
        for note in notes.notes {
            guard let content = notes.content(for: note.id) else { throw FileIssue.message("Backup note body is not readable") }
            var problem: Error?
            content.enumerateAttribute(.attachment, in: NSRange(location: 0, length: content.length)) { value, _, _ in
                guard let value else { return }
                do {
                    guard let attachment = value as? NSTextAttachment, let wrapper = attachment.fileWrapper else { throw FileIssue.message("Backup attachment is missing") }
                    try readable(wrapper); attachmentCount += 1
                } catch { problem = error }
            }
            if let problem { throw problem }
        }
        guard NSApp == nil, try inventory(backup) == before else { throw FileIssue.message("Backup verification changed its source or initialized an application") }
        print("PASS: isolated production decode of verified backup copy; stickyRecords=\(notes.notes.count), embeddedAttachments=\(attachmentCount), recoveredDrafts=\(workspace.restoredCount), sourceObjects=\(before.count), externalFolderReferenceQuarantined=\(folderQuarantined); source inventory unchanged; NSApp=nil; no smoke test")
    }

    private static func readable(_ wrapper: FileWrapper) throws {
        if wrapper.isRegularFile {
            guard wrapper.regularFileContents != nil else { throw FileIssue.message("Backup attachment bytes are unreadable") }
        } else if wrapper.isDirectory, let children = wrapper.fileWrappers {
            for child in children.values { try readable(child) }
        } else { throw FileIssue.message("Backup attachment has an unsupported or linked object") }
    }
    private static func inventory(_ root: URL) throws -> [String: String] {
        let properties: Set<URLResourceKey> = [.isRegularFileKey, .isSymbolicLinkKey, .isDirectoryKey]
        var enumerationFailed = false
        guard try root.resourceValues(forKeys: properties).isSymbolicLink != true,
              let contents = FileManager.default.enumerator(at: root, includingPropertiesForKeys: Array(properties), errorHandler: { _, _ in enumerationFailed = true; return false }) else {
            throw FileIssue.message("Backup root cannot be safely enumerated")
        }
        var result: [String: String] = [:]
        for case let url as URL in contents {
            let values = try url.resourceValues(forKeys: properties)
            guard values.isSymbolicLink != true else { throw FileIssue.message("Backup contains a link; verification stopped before loading any model") }
            let relative = String(url.path.dropFirst(root.path.count + 1))
            if values.isRegularFile == true { result[relative] = FileSafety.digest(try Data(contentsOf: url)) }
            else if values.isDirectory == true { result[relative + "/"] = "directory" }
            else { throw FileIssue.message("Backup contains an unsupported file object") }
        }
        guard !enumerationFailed else { throw FileIssue.message("Backup directory could not be read completely") }
        return result
    }
}
