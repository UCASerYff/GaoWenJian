import Darwin
import Foundation

struct ProjectPDFPosition: Codable, Equatable {
    let pageIndex: Int
    let offset: Double

    var isValid: Bool { (0...1_000_000).contains(pageIndex) && offset.isFinite && (0...1).contains(offset) }
}

struct ProjectReadingPositions: Codable, Equatable {
    var document: ProjectPDFPosition?
    var latexPreview: ProjectPDFPosition?
    var latexReader: ProjectPDFPosition?

    var isValid: Bool { [document, latexPreview, latexReader].compactMap { $0 }.allSatisfy(\.isValid) }
}

struct WritingProjectDocument: Codable, Equatable {
    var path: String?
    var draftID: UUID?
    var reading: ProjectReadingPositions = .init()

    var isValid: Bool {
        if let path { return draftID == nil && WritingProjectPaths.isAbsolute(path) && reading.isValid }
        return draftID != nil && reading.isValid
    }
}

struct WritingProject: Codable, Equatable, Identifiable {
    let id: UUID
    var name: String
    var folder: String
    var main: String
    var documents: [WritingProjectDocument]
    var selectedPath: String?
    var selectedDraftID: UUID?

    var isValid: Bool {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, name.count <= 120,
              !name.contains("\0"), WritingProjectPaths.isAbsolute(folder), WritingProjectPaths.isAbsolute(main),
              WritingProjectPaths.contains(main, in: folder), WritingProjectPaths.isMain(main), documents.count <= 1024,
              documents.allSatisfy(\.isValid), selectedPath == nil || selectedDraftID == nil else { return false }
        let paths = documents.compactMap(\.path)
        let drafts = documents.compactMap(\.draftID)
        return paths.contains(main) && Set(paths).count == paths.count && Set(drafts).count == drafts.count &&
            (selectedPath.map { paths.contains($0) } ?? true) && (selectedDraftID.map { drafts.contains($0) } ?? true)
    }
}

struct WritingProjectCatalog: Codable, Equatable {
    var schemaVersion = 1
    var projects: [WritingProject] = []
    var lastOpened: UUID?

    var isValid: Bool {
        schemaVersion == 1 && projects.count <= 512 && projects.allSatisfy(\.isValid) &&
            Set(projects.map(\.id)).count == projects.count && (lastOpened.map { id in projects.contains { $0.id == id } } ?? true)
    }
}

struct WritingProjectUnavailable: Identifiable, Equatable {
    let path: String
    let reason: String
    var id: String { path }
}

enum WritingProjectSwitch: Equatable {
    case requireSaved, preserveDrafts
}

enum WritingProjectPaths {
    static func isAbsolute(_ path: String) -> Bool {
        path.hasPrefix("/") && path.utf8.count <= 16_384 && !path.contains("\0") &&
            !path.split(separator: "/").contains { $0 == "." || $0 == ".." }
    }

    static func key(_ path: String) -> String {
        guard path.hasPrefix("/") else { return path }
        let components = path.split(separator: "/")
        let local = "/" + components.joined(separator: "/")
        // Foundation's file-path standardization can strip /private and restore a system symlink.
        switch components.first {
        case "tmp", "var", "etc": return "/private" + local
        default: return local
        }
    }

    static func contains(_ path: String, in folder: String) -> Bool {
        let prefix = key(folder)
        return key(path) != prefix && key(path).hasPrefix(prefix == "/" ? prefix : prefix + "/")
    }

    static func isMain(_ path: String) -> Bool {
        ["md", "markdown", "tex"].contains(URL(fileURLWithPath: path).pathExtension.lowercased())
    }

    static func isHandoff(_ path: String) -> Bool {
        ["gaoaction", "gaoresult"].contains(URL(fileURLWithPath: path).pathExtension.lowercased())
    }

    /// Session records are paths the user previously chose. Do not resolve a new symlink at a recorded location.
    static func requireExisting(_ path: String, directory: Bool, dataRoot: URL) throws -> URL {
        guard isAbsolute(path) else { throw FileIssue.message("项目位置不是有效的本机绝对路径。") }
        let normalized = key(path)
        let root = key(dataRoot.resolvingSymlinksInPath().path)
        guard normalized != root, !contains(normalized, in: root), !isHandoff(normalized) else {
            throw FileIssue.message("应用资料和交接包应通过原功能打开，不能由项目恢复。")
        }
        let components = normalized.split(separator: "/")
        var currentPath = ""
        for (index, component) in components.enumerated() {
            let requiresDirectory = directory || index < components.count - 1
            currentPath += "/\(component)"
            var value = stat()
            guard lstat(currentPath, &value) == 0 else { throw FileIssue.message("文件或目录不存在，或暂时无法读取。") }
            let current = URL(fileURLWithPath: currentPath, isDirectory: requiresDirectory)
            guard value.st_mode & S_IFMT == (requiresDirectory ? S_IFDIR : S_IFREG),
                  (try? current.resourceValues(forKeys: [.isAliasFileKey]).isAliasFile) != true else {
                throw FileIssue.message("项目仅恢复普通文件和目录，不跟随符号链接或 Finder 替身。")
            }
        }
        guard directory || !components.isEmpty else { throw FileIssue.message("项目引用不是普通文件。") }
        return URL(fileURLWithPath: normalized, isDirectory: directory)
    }
}

/// An independent catalog protects existing workspace and recovery files and follows the same atomic ledger pattern.
final class WritingProjectRepository {
    private static let name = "writing-projects.json"
    private static let limit: Int64 = 8 * 1024 * 1024
    private let root: URL
    private var digest: String?
    private(set) var catalog = WritingProjectCatalog()

    init(root: URL) throws {
        self.root = root
        let directory = try GaoPrivateIO.directory(root)
        if let data = try Self.read(from: directory) {
            let decoded = try JSONDecoder().decode(WritingProjectCatalog.self, from: data)
            guard decoded.isValid else { throw FileIssue.message("项目记录损坏或版本无法识别，已保留原记录。") }
            catalog = decoded
            digest = FileSafety.digest(data)
        }
    }

    func save(_ updated: WritingProjectCatalog) throws {
        guard updated.isValid else { throw FileIssue.message("项目记录无效或超过上限，原记录已保留。") }
        let directory = try GaoPrivateIO.directory(root)
        guard flock(directory.value, LOCK_EX | LOCK_NB) == 0 else { throw FileIssue.message("项目记录正在使用，请稍后重试。") }
        defer { _ = flock(directory.value, LOCK_UN) }
        let onDisk = try Self.read(from: directory)
        guard onDisk.map(FileSafety.digest) == digest else { throw FileIssue.message("项目记录已在磁盘变更，请重新打开应用，原记录已保留。") }
        if catalog == updated { return }
        let encoded = try JSONEncoder().encode(updated)
        guard Int64(encoded.count) <= Self.limit else { throw FileIssue.message("项目记录超过安全大小，未覆盖旧记录。") }
        try GaoPrivateIO.atomicJSON(encoded, directory: directory, name: Self.name)
        digest = FileSafety.digest(encoded)
        catalog = updated
    }

    private static func read(from directory: GaoFixedFD) throws -> Data? {
        let handle = openat(directory.value, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        if handle < 0 && errno == ENOENT { return nil }
        return try GaoPrivateIO.read(GaoFixedFD(handle), maximum: limit)
    }
}
