import AppKit
import Combine
import Foundation

enum StickyNoteColor: String, Codable, CaseIterable, Identifiable {
    case yellow, blue, green, pink, purple, gray
    var id: String { rawValue }
}

struct StickyNoteFrame: Codable, Equatable {
    var x: Double = 180
    var y: Double = 180
    var width: Double = 360
    var height: Double = 300
}

struct StickyNoteDefaults: Codable, Equatable {
    var color: StickyNoteColor = .yellow
    var fontName: String = NSFont.systemFont(ofSize: 15).fontName
    var fontSize: Double = 15
    var width: Double = 360
    var height: Double = 300
}

struct StickyNote: Codable, Identifiable, Equatable {
    var id: UUID
    var title: String
    var group: String
    var color: StickyNoteColor
    var createdAt: Date
    var updatedAt: Date
    var deletedAt: Date?
    var isPinned: Bool
    var isTranslucent: Bool
    var isCollapsed: Bool
    var isOnDesktop: Bool
    var frame: StickyNoteFrame
    var plainText: String
    // Flat RTFD includes the rich text and every embedded attachment in one checked payload.
    var rtfd: Data
    var rtfdDigest: String
}

enum StickyNoteExportFormat: String, CaseIterable { case txt, rtf, rtfd }

@MainActor final class StickyNotesStore: ObservableObject {
    @Published private(set) var notes: [StickyNote] = []
    @Published private(set) var defaults = StickyNoteDefaults()
    @Published private(set) var isDirty = false
    @Published private(set) var saveStatus = "尚未读取"
    @Published var error: String?
    let rootURL: URL

    private struct Payload: Codable { var notes: [StickyNote]; var defaults: StickyNoteDefaults }
    private struct Archive: Codable { var version: Int; var payload: Payload; var payloadDigest: String }
    private var contents: [UUID: NSAttributedString] = [:]
    private var dirtyContents: Set<UUID> = []
    private var expectedDigest: String?
    private var baselineBlobDigests: Set<String> = []
    private var loaded = false
    private var saveTask: Task<Void, Never>?
    private var archiveURL: URL { rootURL.appendingPathComponent("notes.json") }
    private var historyURL: URL { rootURL.appendingPathComponent("History", isDirectory: true) }
    private var contentsURL: URL { rootURL.appendingPathComponent("Contents", isDirectory: true) }
    private let manager = FileManager.default

    init(rootURL: URL = FileSafety.root.appendingPathComponent("StickyNotes", isDirectory: true)) {
        self.rootURL = rootURL.standardizedFileURL
        _ = load()
    }

    /// Reloading never discards an unsaved edit. A failed initial read leaves the original bytes untouched.
    @discardableResult func load() -> Bool {
        guard !isDirty else { return fail("还有未保存的便笺修改。请先保存或保留当前窗口，不能用磁盘资料替换编辑内容。") }
        do {
            try rejectSymbolicLink(rootURL)
            try rejectSymbolicLink(archiveURL)
            if !manager.fileExists(atPath: archiveURL.path) {
                if expectedDigest != nil { throw FileIssue.message("便笺资料文件已被移动或删除。已保留当前便笺，不能按空白资料重新创建。") }
                if manager.fileExists(atPath: rootURL.path), !((try manager.contentsOfDirectory(at: rootURL, includingPropertiesForKeys: nil)).isEmpty) {
                    throw FileIssue.message("便笺目录已有资料，但主记录缺失。请从安全备份恢复，不能用空白资料覆盖。")
                }
                notes = []; contents = [:]; defaults = StickyNoteDefaults(); loaded = true
                saveStatus = "已保存"; error = nil
                return true
            }
            let data = try Data(contentsOf: archiveURL)
            let archive = try JSONDecoder().decode(Archive.self, from: data)
            guard (1...2).contains(archive.version), FileSafety.digest(try encode(archive.payload)) == archive.payloadDigest else {
                throw FileIssue.message("便笺记录的版本或摘要校验失败。原资料已保留，未进行覆盖。")
            }
            try validate(defaults: archive.payload.defaults)
            var decoded: [UUID: NSAttributedString] = [:]
            var restored: [StickyNote] = []
            for var note in archive.payload.notes {
                guard decoded[note.id] == nil else { throw FileIssue.message("便笺记录包含重复编号，已停止读取并保留原资料。") }
                try validateMetadata(note)
                if archive.version == 2 {
                    guard note.rtfd.isEmpty else { throw FileIssue.message("便笺记录包含与存储版本不符的正文数据，原资料已保留。") }
                    note.rtfd = try readBlob(digest: note.rtfdDigest)
                }
                guard FileSafety.digest(note.rtfd) == note.rtfdDigest else { throw FileIssue.message("“\(note.title)”的富文本或附件摘要校验失败。") }
                let content = try decodeRichText(note.rtfd)
                guard content.string == note.plainText else { throw FileIssue.message("“\(note.title)”的正文索引与富文本不一致，原资料已保留。") }
                decoded[note.id] = content
                restored.append(note)
            }
            // Publish only after every record, rich text and attachment has passed verification.
            notes = restored; defaults = archive.payload.defaults; contents = decoded
            expectedDigest = FileSafety.digest(data); loaded = true; error = nil; saveStatus = "已保存"
            baselineBlobDigests = archive.version == 2 ? Set(restored.map(\.rtfdDigest)) : []
            if archive.version == 1 {
                // Every legacy record was verified above before any migration write begins.
                markDirty(schedule: false)
                return flush()
            }
            return true
        } catch { return fail("读取便笺失败：\(error.localizedDescription)") }
    }

    func content(for id: UUID) -> NSAttributedString? { contents[id]?.copy() as? NSAttributedString }

    @discardableResult func create(title: String = "", content: NSAttributedString = NSAttributedString(string: "")) -> UUID? {
        guard loaded else { _ = fail("便笺资料尚未成功读取，不能创建便笺覆盖原资料。"); return nil }
        do {
            let rich = try encodeRichText(content), now = Date(), id = UUID()
            let frame = StickyNoteFrame(x: 180, y: 180, width: defaults.width, height: defaults.height)
            let note = StickyNote(id: id, title: title, group: "", color: defaults.color, createdAt: now, updatedAt: now,
                                  deletedAt: nil, isPinned: false, isTranslucent: false, isCollapsed: false,
                                  isOnDesktop: false, frame: frame, plainText: content.string, rtfd: rich, rtfdDigest: FileSafety.digest(rich))
            notes.insert(note, at: 0); contents[id] = content.copy() as? NSAttributedString
            markDirty(schedule: false); _ = flush(); return id
        } catch { _ = fail(error.localizedDescription); return nil }
    }

    @discardableResult func updateContent(id: UUID, content: NSAttributedString) -> Bool {
        guard loaded, let index = notes.firstIndex(where: { $0.id == id && $0.deletedAt == nil }) else { return fail("便笺不存在、已在回收站中或资料尚未核验。") }
        do {
            try validateAttachments(content)
            if contents[id]?.isEqual(to: content) == true { return true }
            contents[id] = content.copy() as? NSAttributedString
            notes[index].plainText = content.string; notes[index].updatedAt = Date(); dirtyContents.insert(id)
            markDirty(); return true
        } catch { return fail(error.localizedDescription) }
    }

    /// Only presentation metadata can be changed through this closure; identity and document bytes stay protected.
    @discardableResult func updateMetadata(id: UUID, _ mutate: (inout StickyNote) -> Void) -> Bool {
        guard loaded, let index = notes.firstIndex(where: { $0.id == id }) else { return fail("便笺不存在或资料尚未核验。") }
        let original = notes[index]
        var candidate = original; mutate(&candidate)
        candidate.id = original.id; candidate.createdAt = original.createdAt; candidate.deletedAt = original.deletedAt
        candidate.plainText = original.plainText; candidate.rtfd = original.rtfd; candidate.rtfdDigest = original.rtfdDigest
        candidate.updatedAt = original.updatedAt
        guard candidate != original else { return true }
        candidate.updatedAt = Date()
        do { try validateMetadata(candidate); notes[index] = candidate; markDirty(); return true }
        catch { return fail(error.localizedDescription) }
    }

    @discardableResult func trash(id: UUID) -> Bool {
        guard loaded, let index = notes.firstIndex(where: { $0.id == id }) else { return fail("便笺不存在或资料尚未核验。") }
        notes[index].deletedAt = Date(); notes[index].updatedAt = Date(); notes[index].isOnDesktop = false
        markDirty(schedule: false); return flush()
    }

    @discardableResult func restore(id: UUID) -> Bool {
        guard loaded, let index = notes.firstIndex(where: { $0.id == id }) else { return fail("便笺不存在或资料尚未核验。") }
        notes[index].deletedAt = nil; notes[index].updatedAt = Date()
        markDirty(schedule: false); return flush()
    }

    @discardableResult func setDefaults(from id: UUID) -> Bool {
        guard loaded, let note = notes.first(where: { $0.id == id }) else { return fail("便笺不存在或资料尚未核验。") }
        var style = defaults
        style.color = note.color; style.width = note.frame.width; style.height = max(120, note.frame.height)
        if let content = contents[id], content.length > 0, let font = content.attribute(.font, at: 0, effectiveRange: nil) as? NSFont {
            style.fontName = font.fontName; style.fontSize = Double(font.pointSize)
        }
        do { try validate(defaults: style); defaults = style; markDirty(schedule: false); return flush() }
        catch { return fail(error.localizedDescription) }
    }

    /// Flush is the close/quit boundary. Failure keeps the edited content and isDirty set for a visible retry.
    @discardableResult func flush() -> Bool {
        saveTask?.cancel(); saveTask = nil
        guard loaded else { return fail("原便笺资料未能读取或校验，保存已中止。") }
        guard isDirty else { return true }
        saveStatus = "正在保存…"
        do {
            try rejectSymbolicLink(rootURL); try rejectSymbolicLink(archiveURL)
            let original = try checkedOriginal()
            try verifyBaselineBlobs()
            var persisted = notes
            for index in persisted.indices where dirtyContents.contains(persisted[index].id) {
                guard let content = contents[persisted[index].id] else { throw FileIssue.message("便笺正文缓存缺失，已中止保存。") }
                let rich = try encodeRichText(content)
                persisted[index].rtfd = rich; persisted[index].rtfdDigest = FileSafety.digest(rich)
                persisted[index].plainText = content.string
            }
            try manager.createDirectory(at: rootURL, withIntermediateDirectories: true)
            // Body packages are immutable and shared by current records and historical metadata.
            // Moving/colouring a note therefore never duplicates its attachments in History.
            var prepared: Set<String> = []
            for note in persisted where prepared.insert(note.rtfdDigest).inserted { try ensureBlob(note.rtfd, digest: note.rtfdDigest) }
            let lightweight = persisted.map { note -> StickyNote in var record = note; record.rtfd = Data(); return record }
            let payload = Payload(notes: lightweight, defaults: defaults)
            let archive = Archive(version: 2, payload: payload, payloadDigest: FileSafety.digest(try encode(payload)))
            let data = try encode(archive)
            if let original { try snapshot(original, named: "notes.json") }
            // Recheck after the snapshot so an external update during backup is never knowingly overwritten.
            _ = try checkedOriginal()
            try verifyBaselineBlobs()
            try data.write(to: archiveURL, options: .atomic)
            guard try Data(contentsOf: archiveURL) == data else { throw FileIssue.message("便笺写入后校验失败，请保留当前窗口并从安全备份检查资料。") }
            expectedDigest = FileSafety.digest(data); notes = persisted; dirtyContents.removeAll()
            baselineBlobDigests = Set(persisted.map(\.rtfdDigest))
            isDirty = false; error = nil; saveStatus = "已保存"; return true
        } catch { return fail("便笺尚未保存：\(error.localizedDescription)") }
    }

    func importNote(from url: URL) throws -> UUID {
        guard loaded else { throw FileIssue.message("便笺资料尚未核验，无法导入。") }
        try rejectSymbolicLink(url)
        let ext = url.pathExtension.lowercased(), content: NSAttributedString
        switch ext {
        case "txt":
            var detected: String.Encoding = .utf8
            let text = try String(contentsOf: url, usedEncoding: &detected)
            let font = NSFont(name: defaults.fontName, size: defaults.fontSize) ?? .systemFont(ofSize: defaults.fontSize)
            content = NSAttributedString(string: text, attributes: [.font: font])
        case "rtf":
            let data = try Data(contentsOf: url)
            content = try NSAttributedString(data: data, options: [.documentType: NSAttributedString.DocumentType.rtf], documentAttributes: nil)
        case "rtfd":
            _ = try Self.destinationDigest(at: url) // Walk every member, refusing unreadable files and symbolic links.
            content = try decodeRichPackage(at: url)
        default: throw FileIssue.message("便笺可导入 TXT、RTF 和 RTFD 文件。")
        }
        try validateAttachments(content)
        guard let id = create(title: url.deletingPathExtension().lastPathComponent, content: content) else {
            throw FileIssue.message(error ?? "导入便笺失败。")
        }
        // A write failure still leaves the imported note visible and dirty rather than losing its content.
        return id
    }

    /// An existing target requires a digest captured after the user's explicit replacement choice.
    func exportNote(id: UUID, to url: URL, format: StickyNoteExportFormat, expectedDigest: String? = nil) throws {
        guard loaded, let content = contents[id] else { throw FileIssue.message("便笺正文尚未核验，无法导出。") }
        let destination = url.standardizedFileURL
        guard !destination.path.hasPrefix(rootURL.path + "/"), destination != rootURL else { throw FileIssue.message("请导出到便笺资料目录之外，避免修改内部记录与历史。") }
        try rejectSymbolicLink(destination)
        let initial = try Self.destinationDigest(at: destination)
        if let expectedDigest {
            guard initial == expectedDigest else { throw FileIssue.message("导出目标已被其他程序修改、移动或删除，请重新选择保存位置。") }
        } else if initial != nil { throw FileIssue.message("导出目标已存在，请确认替换后重新选择，或换一个文件名。") }
        if format == .rtf, containsAttachments(content) { throw FileIssue.message("这张便笺包含附件。请导出为 RTFD，RTF 无法完整保留附件。") }
        try manager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        let staging = destination.deletingLastPathComponent().appendingPathComponent(".gaosticky-export-" + UUID().uuidString + "." + format.rawValue)
        defer { try? manager.removeItem(at: staging) }
        switch format {
        case .txt: try Data(content.string.utf8).write(to: staging, options: .atomic)
        case .rtf:
            let data = try content.data(from: NSRange(location: 0, length: content.length), documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
            try data.write(to: staging, options: .atomic)
        case .rtfd:
            let wrapper = try content.fileWrapper(from: NSRange(location: 0, length: content.length), documentAttributes: [.documentType: NSAttributedString.DocumentType.rtfd])
            try validateWrapper(wrapper)
            try wrapper.write(to: staging, options: .atomic, originalContentsURL: nil)
        }
        let stagedDigest = try Self.destinationDigest(at: staging)
        if format != .txt {
            let reloaded: NSAttributedString
            if format == .rtfd { reloaded = try decodeRichPackage(at: staging) }
            else { reloaded = try NSAttributedString(data: Data(contentsOf: staging), options: [.documentType: NSAttributedString.DocumentType.rtf], documentAttributes: nil) }
            guard reloaded.string == content.string, try attachmentDigests(reloaded) == attachmentDigests(content) else {
                throw FileIssue.message("导出文件的正文或附件核验失败，原目标未被覆盖。")
            }
        }
        guard try Self.destinationDigest(at: destination) == initial else { throw FileIssue.message("导出目标在准备期间发生变化，已取消覆盖。") }
        if initial != nil { try snapshotExport(destination) }
        guard try Self.destinationDigest(at: destination) == initial else { throw FileIssue.message("导出目标在备份期间发生变化，已取消覆盖。") }
        if initial != nil { _ = try manager.replaceItemAt(destination, withItemAt: staging) }
        else { try manager.moveItem(at: staging, to: destination) }
        guard try Self.destinationDigest(at: destination) == stagedDigest else { throw FileIssue.message("导出后的文件校验失败，原件快照已保留，请检查保存位置。") }
    }

    static func destinationDigest(at url: URL) throws -> String? {
        let manager = FileManager.default
        // resourceValues catches a dangling symlink that fileExists would treat as absent.
        if let values = try? url.resourceValues(forKeys: [.isSymbolicLinkKey]), values.isSymbolicLink == true {
            throw FileIssue.message("不能读取或覆盖符号链接，避免影响其他位置的文件。")
        }
        guard manager.fileExists(atPath: url.path) else { return nil }
        let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isSymbolicLink != true else { throw FileIssue.message("RTFD 目录包含符号链接，附件不能完整核验。") }
        if values.isDirectory == true {
            var manifest = Data("directory\n".utf8)
            for child in try manager.contentsOfDirectory(at: url, includingPropertiesForKeys: nil).sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                let name = Data(child.lastPathComponent.utf8)
                guard let digest = try destinationDigest(at: child) else { throw FileIssue.message("附件在核验时被移动或删除。") }
                manifest.append(Data("\(name.count):".utf8)); manifest.append(name); manifest.append(Data(":\(digest)\n".utf8))
            }
            return FileSafety.digest(manifest)
        }
        return FileSafety.digest(try Data(contentsOf: url))
    }

    private func markDirty(schedule: Bool = true) {
        isDirty = true; saveStatus = "有未保存修改"
        saveTask?.cancel(); saveTask = nil
        if schedule {
            saveTask = Task { @MainActor [weak self] in
                do { try await Task.sleep(nanoseconds: 450_000_000) } catch { return }
                _ = self?.flush()
            }
        }
    }

    private func fail(_ message: String) -> Bool { error = message; saveStatus = isDirty ? "保存失败 · 可重试" : "资料未能核验"; return false }
    private func encode<T: Encodable>(_ value: T) throws -> Data { let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]; return try encoder.encode(value) }
    private func checkedOriginal() throws -> Data? {
        if let expectedDigest {
            guard manager.fileExists(atPath: archiveURL.path) else { throw FileIssue.message("原便笺记录已被移动或删除，不能在旧位置重新创建。") }
            let data = try Data(contentsOf: archiveURL)
            guard FileSafety.digest(data) == expectedDigest else { throw FileIssue.message("便笺资料已被其他程序修改，当前编辑已保留，请先检查外部资料或导出当前便笺。") }
            return data
        }
        guard !manager.fileExists(atPath: archiveURL.path) else { throw FileIssue.message("便笺记录在读取后新出现，不能覆盖尚未核验的资料。") }
        return nil
    }
    private func blobURL(digest: String) throws -> URL {
        guard digest.count == 64, digest.allSatisfy({ "0123456789abcdef".contains($0) }) else {
            throw FileIssue.message("便笺正文摘要格式无效，原资料已保留。")
        }
        return contentsURL.appendingPathComponent(digest + ".rtfd")
    }
    private func readBlob(digest: String) throws -> Data {
        try rejectSymbolicLink(contentsURL)
        let url = try blobURL(digest: digest); try rejectSymbolicLink(url)
        guard manager.fileExists(atPath: url.path) else { throw FileIssue.message("便笺正文或附件包缺失，请从安全备份恢复；不能按空白内容保存。") }
        let data = try Data(contentsOf: url)
        guard FileSafety.digest(data) == digest else { throw FileIssue.message("便笺正文或附件包摘要校验失败，原资料已保留且不会被覆盖。") }
        return data
    }
    private func verifyBaselineBlobs() throws {
        for digest in baselineBlobDigests { _ = try readBlob(digest: digest) }
    }
    private func ensureBlob(_ data: Data, digest: String) throws {
        guard FileSafety.digest(data) == digest else { throw FileIssue.message("便笺正文缓存摘要不一致，已中止保存。") }
        try rejectSymbolicLink(contentsURL)
        let url = try blobURL(digest: digest); try rejectSymbolicLink(url)
        if manager.fileExists(atPath: url.path) {
            guard try readBlob(digest: digest) == data else { throw FileIssue.message("同摘要正文包与当前缓存不一致，已中止保存。") }
            return
        }
        guard !baselineBlobDigests.contains(digest) else { throw FileIssue.message("原正文包已被删除，不能用缓存重新创建尚未恢复的资料。") }
        try manager.createDirectory(at: contentsURL, withIntermediateDirectories: true)
        let staging = contentsURL.appendingPathComponent(".pending-" + UUID().uuidString)
        defer { try? manager.removeItem(at: staging) }
        try data.write(to: staging, options: .atomic)
        guard try Data(contentsOf: staging) == data else { throw FileIssue.message("新正文包写入核验失败，记录未被更新。") }
        // moveItem refuses an existing path, unlike an atomic write that could replace a racing external file.
        try manager.moveItem(at: staging, to: url)
        guard try readBlob(digest: digest) == data else { throw FileIssue.message("新正文包摘要核验失败，记录未被更新。") }
    }
    private func rejectSymbolicLink(_ url: URL) throws {
        if let values = try? url.resourceValues(forKeys: [.isSymbolicLinkKey]), values.isSymbolicLink == true {
            throw FileIssue.message("便笺资料或附件指向符号链接，已停止操作以保护原文件。")
        }
    }
    private func snapshot(_ data: Data, named name: String) throws {
        try rejectSymbolicLink(historyURL)
        try manager.createDirectory(at: historyURL, withIntermediateDirectories: true)
        let target = historyURL.appendingPathComponent(Date().ISO8601Format().replacingOccurrences(of: ":", with: "-") + "-" + UUID().uuidString + "-" + name)
        try data.write(to: target, options: .atomic)
        guard try Data(contentsOf: target) == data else { throw FileIssue.message("便笺原件快照核验失败，已中止保存。") }
    }
    private func snapshotExport(_ source: URL) throws {
        try rejectSymbolicLink(historyURL)
        let folder = historyURL.appendingPathComponent("Exports", isDirectory: true)
        try rejectSymbolicLink(folder); try manager.createDirectory(at: folder, withIntermediateDirectories: true)
        let digest = try Self.destinationDigest(at: source)
        let target = folder.appendingPathComponent(UUID().uuidString + "-" + source.lastPathComponent)
        try manager.copyItem(at: source, to: target)
        guard try Self.destinationDigest(at: target) == digest else { throw FileIssue.message("导出原目标快照核验失败，已中止覆盖。") }
    }
    private func validateMetadata(_ note: StickyNote) throws {
        let frame = note.frame
        guard frame.x.isFinite, frame.y.isFinite, frame.width.isFinite, frame.height.isFinite,
              frame.width >= 180, frame.height >= 40, frame.width <= 10_000, frame.height <= 10_000,
              note.createdAt.timeIntervalSince1970.isFinite, note.updatedAt.timeIntervalSince1970.isFinite,
              note.deletedAt?.timeIntervalSince1970.isFinite != false else { throw FileIssue.message("便笺窗口尺寸、位置或日期无效。") }
    }
    private func validate(defaults style: StickyNoteDefaults) throws {
        guard style.fontSize.isFinite, (6...200).contains(style.fontSize), !style.fontName.isEmpty,
              style.width.isFinite, style.height.isFinite, (180...10_000).contains(style.width), (120...10_000).contains(style.height) else {
            throw FileIssue.message("新便笺默认字体或窗口尺寸无效。")
        }
    }
    private func encodeRichText(_ content: NSAttributedString) throws -> Data {
        try validateAttachments(content)
        let data = try content.data(from: NSRange(location: 0, length: content.length), documentAttributes: [.documentType: NSAttributedString.DocumentType.rtfd])
        let reloaded = try decodeRichText(data)
        guard reloaded.string == content.string, try attachmentDigests(reloaded) == attachmentDigests(content) else {
            throw FileIssue.message("富文本或附件在序列化时未能完整保留，已中止保存。")
        }
        return data
    }
    private func decodeRichText(_ data: Data) throws -> NSAttributedString {
        guard let wrapper = FileWrapper(serializedRepresentation: data), wrapper.isDirectory else {
            throw FileIssue.message("便笺富文本包无法读取，原件已保留。")
        }
        return try decodeCheckedWrapper(wrapper)
    }
    private func decodeRichPackage(at url: URL) throws -> NSAttributedString {
        // Read each file ourselves: FileWrapper(url:) asks LaunchServices to classify RTFD,
        // which can fail in a restricted local process even when the files are readable.
        let wrapper = try readWrapper(at: url)
        if wrapper.isRegularFile, let data = wrapper.regularFileContents { return try decodeRichText(data) }
        return try decodeCheckedWrapper(wrapper)
    }
    private func decodeCheckedWrapper(_ wrapper: FileWrapper) throws -> NSAttributedString {
        try validateWrapper(wrapper)
        guard let rtf = wrapper.fileWrappers?.first(where: { $0.key.lowercased() == "txt.rtf" })?.value.regularFileContents else {
            throw FileIssue.message("RTFD 的正文 TXT.rtf 缺失或无法读取，原件已保留。")
        }
        guard let content = NSAttributedString(rtfdFileWrapper: wrapper, documentAttributes: nil) else {
            throw FileIssue.message("RTFD 便笺无法读取，原件已保留。")
        }
        let attachments = try attachmentDigests(content)
        // AppKit can silently remove a referenced file that is missing from an RTFD package.
        // Count actual RTF control words, excluding escaped literal text, before accepting it.
        guard attachments.count >= graphicReferenceCount(in: rtf) else {
            throw FileIssue.message("RTFD 引用的附件缺失或无法读取，已停止导入并保留原件。")
        }
        return content
    }
    private func graphicReferenceCount(in data: Data) -> Int {
        let bytes = [UInt8](data); var index = 0, count = 0
        while index < bytes.count {
            guard bytes[index] == 92 else { index += 1; continue }
            index += 1
            guard index < bytes.count else { break }
            if bytes[index] == 92 || bytes[index] == 123 || bytes[index] == 125 { index += 1; continue }
            if bytes[index] == 39 { index = min(bytes.count, index + 3); continue }
            let start = index
            while index < bytes.count, (65...90).contains(bytes[index]) || (97...122).contains(bytes[index]) { index += 1 }
            if index > start {
                if String(bytes: bytes[start..<index], encoding: .ascii) == "NeXTGraphic" { count += 1 }
            } else { index += 1 }
        }
        return count
    }
    private func readWrapper(at url: URL) throws -> FileWrapper {
        try rejectSymbolicLink(url)
        let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey])
        let wrapper: FileWrapper
        if values.isDirectory == true {
            var children: [String: FileWrapper] = [:]
            for child in try manager.contentsOfDirectory(at: url, includingPropertiesForKeys: nil) {
                children[child.lastPathComponent] = try readWrapper(at: child)
            }
            wrapper = FileWrapper(directoryWithFileWrappers: children)
        } else if values.isRegularFile == true { wrapper = FileWrapper(regularFileWithContents: try Data(contentsOf: url)) }
        else { throw FileIssue.message("RTFD 中包含无法读取的文件类型，附件不能完整核验。") }
        wrapper.preferredFilename = url.lastPathComponent; return wrapper
    }
    private func containsAttachments(_ content: NSAttributedString) -> Bool {
        var found = false
        content.enumerateAttribute(.attachment, in: NSRange(location: 0, length: content.length)) { value, _, stop in
            if value != nil { found = true; stop.pointee = true }
        }
        return found
    }
    private func validateAttachments(_ content: NSAttributedString) throws { _ = try attachmentDigests(content) }
    private func attachmentDigests(_ content: NSAttributedString) throws -> [String] {
        var digests: [String] = [], issue: Error?
        content.enumerateAttribute(.attachment, in: NSRange(location: 0, length: content.length)) { value, range, _ in
            guard let value else { return }
            do {
                guard let attachment = value as? NSTextAttachment, let wrapper = attachment.fileWrapper else {
                    throw FileIssue.message("有附件尚未加载到便笺中，请重新加入附件后保存。")
                }
                try validateWrapper(wrapper)
                digests.append(contentsOf: Array(repeating: try wrapperDigest(wrapper), count: range.length))
            } catch { issue = error }
        }
        if let issue { throw issue }; return digests
    }
    private func validateWrapper(_ wrapper: FileWrapper) throws {
        guard !wrapper.isSymbolicLink else { throw FileIssue.message("附件是符号链接，不能保证资料独立完整，请加入实际文件。") }
        if wrapper.isRegularFile {
            guard wrapper.regularFileContents != nil else { throw FileIssue.message("附件无法读取，不能按空附件保存。") }
        } else if wrapper.isDirectory {
            guard let children = wrapper.fileWrappers else { throw FileIssue.message("附件目录无法读取。") }
            for child in children.values { try validateWrapper(child) }
        } else { throw FileIssue.message("附件类型不受支持，原便笺未被覆盖。") }
    }
    private func wrapperDigest(_ wrapper: FileWrapper) throws -> String {
        if wrapper.isRegularFile, let data = wrapper.regularFileContents { return FileSafety.digest(data) }
        guard wrapper.isDirectory, let children = wrapper.fileWrappers else { throw FileIssue.message("附件无法读取。") }
        var manifest = Data("directory\n".utf8)
        for key in children.keys.sorted() {
            let name = Data(key.utf8), digest = try wrapperDigest(children[key]!)
            manifest.append(Data("\(name.count):".utf8)); manifest.append(name); manifest.append(Data(":\(digest)\n".utf8))
        }
        return FileSafety.digest(manifest)
    }
}
