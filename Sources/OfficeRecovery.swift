import Foundation

struct OfficeRecoveryRecord: Codable {
    let originalPath: String
    let originalDigest: String
    let documentDigest: String
    let updatedAt: Date
}
struct OfficeRecoveryCandidate {
    let url: URL
    let record: OfficeRecoveryRecord
}
enum OfficeRecovery {
    static func documentURL(for original: URL, previous: Bool = false) -> URL {
        let key = OfficePackage.hash(Data(original.standardizedFileURL.path.utf8))
        return FileSafety.root.appendingPathComponent("Recovery/Office", isDirectory: true).appendingPathComponent(key + (previous ? "-previous" : "") + "." + original.pathExtension.lowercased())
    }
    static func metadataURL(_ document: URL) -> URL { document.appendingPathExtension("json") }
    static func read(for original: URL, previous: Bool = false) throws -> OfficeRecoveryCandidate? {
        let document = documentURL(for: original, previous: previous)
        let metadata = metadataURL(document)
        let fm = FileManager.default
        guard fm.fileExists(atPath: document.path) || fm.fileExists(atPath: metadata.path) else { return nil }
        let record = try JSONDecoder().decode(OfficeRecoveryRecord.self, from: Data(contentsOf: metadata))
        guard record.originalPath == original.standardizedFileURL.path, try OfficePackage.digest(document) == record.documentDigest else {
            throw OfficeFailure.message("Office 恢复草稿校验失败。已有草稿已保留，不会以空白内容覆盖。")
        }
        _ = try OfficePackage(url: document) // Verify ZIP/XML package validity before offering a recovery.
        return OfficeRecoveryCandidate(url: document, record: record)
    }
    static func persist(package: OfficePackage, original: URL, originalDigest: String) throws {
        let target = documentURL(for: original)
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let old = try read(for: original) {
            let previous = documentURL(for: original, previous: true)
            try Data(contentsOf: old.url).write(to: previous, options: .atomic)
            try JSONEncoder().encode(old.record).write(to: metadataURL(previous), options: .atomic)
        }
        try package.save(to: target, updateSource: false, createSnapshot: false)
        let record = OfficeRecoveryRecord(originalPath: original.standardizedFileURL.path, originalDigest: originalDigest, documentDigest: try OfficePackage.digest(target), updatedAt: Date())
        try JSONEncoder().encode(record).write(to: metadataURL(target), options: .atomic)
    }
    static func cleanValidDrafts(for original: URL) {
        for previous in [false, true] {
            // Corrupt/missing records are retained for manual recovery, never interpreted as an empty draft.
            if let result = try? read(for: original, previous: previous) {
                try? FileManager.default.removeItem(at: result.url)
                try? FileManager.default.removeItem(at: metadataURL(result.url))
            }
        }
    }
    static func archiveExisting(for original: URL) throws {
        let fm = FileManager.default
        let candidates = [false, true].flatMap { previous -> [URL] in let doc = documentURL(for: original, previous: previous); return [doc, metadataURL(doc)] }.filter { fm.fileExists(atPath: $0.path) }
        guard !candidates.isEmpty else { return }
        let archive = FileSafety.root.appendingPathComponent("Recovery/Office/Retained/\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: archive, withIntermediateDirectories: true)
        for source in candidates {
            let bytes = try Data(contentsOf: source)
            let destination = archive.appendingPathComponent(source.lastPathComponent)
            try bytes.write(to: destination, options: .atomic)
            guard try Data(contentsOf: destination) == bytes else { throw OfficeFailure.message("恢复草稿保留副本校验失败。") }
        }
        // Remove only after every existing byte has been copied and verified, including damaged records.
        for source in candidates { try fm.removeItem(at: source) }
    }
    static func discardIfSafe(for original: URL, expectedOriginalDigest: String) {
        guard (try? OfficePackage.digest(original)) == expectedOriginalDigest else { return }
        for previous in [false, true] {
            guard let record = try? read(for: original, previous: previous), record.record.originalDigest == expectedOriginalDigest else { continue }
            try? FileManager.default.removeItem(at: record.url)
            try? FileManager.default.removeItem(at: metadataURL(record.url))
        }
    }
}
