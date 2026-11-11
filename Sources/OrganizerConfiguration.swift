// Organizer module port; source application is not a runtime dependency.
import Foundation
import CryptoKit
import Darwin

struct OFAppFailure: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

/// A missing business document is never interpreted as an empty initialized document.
final class OFProtectedDocument<Value: Codable> {
    struct OFEnvelope: Codable { let schemaVersion: Int; let sha256: String; let payload: Data }
    let url: URL
    private let marker: URL
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private var lastDiskDigest: String?
    private var creating = false
    init(directory: URL, name: String) {
        url = directory.appendingPathComponent(name + ".json")
        marker = directory.appendingPathComponent(name + ".initialized")
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    }
    func load(initial: @autoclosure () -> Value) throws -> Value {
        let fm = FileManager.default
        if !fm.fileExists(atPath: url.path) {
            guard !fm.fileExists(atPath: marker.path) else { throw OFAppFailure("资料文件缺失：\(url.lastPathComponent)。已停止写入，未建立空白资料。") }
            let value = initial(); creating = true; defer { creating = false }; try save(value); try Data("schema=1\n".utf8).write(to: marker, options: .atomic)
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: marker.path)
            return value
        }
        guard fm.fileExists(atPath: marker.path) else { throw OFAppFailure("资料初始化依据缺失：\(url.lastPathComponent)。停止写入，需恢复核验。") }
        try Self.validateFile(marker)
        guard try Data(contentsOf: marker) == Data("schema=1\n".utf8) else { throw OFAppFailure("资料初始化依据损坏，停止写入。") }
        try Self.validateFile(url)
        let data = try Data(contentsOf: url)
        guard data.count <= 32 * 1024 * 1024 else { throw OFAppFailure("资料过大，停止读取。") }
        let envelope = try decoder.decode(OFEnvelope.self, from: data)
        guard envelope.schemaVersion == 1 else { throw OFAppFailure("资料格式过新或不支持，停止写入。") }
        guard Self.digest(envelope.payload) == envelope.sha256 else { throw OFAppFailure("资料摘要不符，停止写入。") }
        let value = try decoder.decode(Value.self, from: envelope.payload)
        lastDiskDigest = Self.digest(data)
        return value
    }
    func save(_ value: Value) throws {
        if !creating {
            try Self.validateFile(marker)
            guard try Data(contentsOf: marker) == Data("schema=1\n".utf8) else { throw OFAppFailure("资料初始化依据损坏，停止写入。") }
        }
        let exists = FileManager.default.fileExists(atPath: url.path)
        if exists {
            try Self.validateFile(url)
            guard let lastDiskDigest, Self.digest(try Data(contentsOf: url)) == lastDiskDigest else { throw OFAppFailure("资料在读取后被替换或修改，停止写入。") }
        } else {
            guard creating, lastDiskDigest == nil, !FileManager.default.fileExists(atPath: marker.path) else { throw OFAppFailure("已初始化资料在运行期间缺失，停止写入。") }
        }
        let data = try encoder.encode(value)
        let encoded = try encoder.encode(OFEnvelope(schemaVersion: 1, sha256: Self.digest(data), payload: data))
        try encoded.write(to: url, options: .atomic)
        lastDiskDigest = Self.digest(encoded)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
    private static func validateFile(_ url: URL) throws {
        var st = stat()
        guard lstat(url.path, &st) == 0, st.st_uid == getuid(), (st.st_mode & S_IFMT) == S_IFREG, st.st_nlink == 1, st.st_size <= 32 * 1024 * 1024 else { throw OFAppFailure("资料对象类型、身份或大小异常，停止读取与写入。") }
    }
    static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
}

struct OFLibraryConfiguration: Codable {
    var schemaVersion = 1
    var workspaces: [OFVirtualWorkspace] = []
    var savedQueries: [OFSavedQuery] = []
    var appearance = "system"
    var automaticMonitoring = true
}
struct OFVirtualWorkspace: Codable, Identifiable {
    var id = UUID()
    var name: String
    var panels: [OFVirtualPanel] = []
}
struct OFVirtualPanel: Codable, Identifiable {
    var id = UUID()
    var name: String
    var kind: String // directory, query, favorites
    var rootID: UUID?
    var query = ""
    var extensionName = ""
    var sort = "name"
    var ascending = true
    var collapsed = false
    var paused = false
    var filter: OFSearchFilter? = nil
}
struct OFSavedQuery: Codable, Identifiable {
    var id = UUID()
    var name: String
    var query: String
    var rootID: UUID?
    var extensionName: String
    var pathContains: String
    var typeIdentifier: String
    var kind: String
    var minSize: Int64?
    var maxSize: Int64?
    var modifiedAfter: Date?
    var modifiedBefore: Date?
    var sort: String
    var ascending: Bool
    var filter: OFSearchFilter? = nil
}

enum OFAppLocations {
    private static var lockFD: Int32 = -1
    static let bundleID = "com.gaoseries.GaoWenJian"
    static var directory: URL { FileSafety.root.appendingPathComponent("Organizer", isDirectory: true) }
    static var initializationMarker: URL { FileSafety.root.appendingPathComponent("Organizer.initialized") }
    static let markerBytes = Data("schema=1\n".utf8)
    static let expectedDocuments = ["configuration.json", "configuration.initialized", "metadata.sqlite", "index-initialized.json", "associations_history.json", "associations_history.initialized", "MovePlans/initialized.json", "MovePlans/ledger.json", "MovePlans.initialized"]
    static func prepare() throws -> URL {
        guard lockFD < 0 else { throw OFAppFailure("整理模块资料已由一个模型持有，请复用现有模块。") }
        let fm = FileManager.default, dir = directory, marker = initializationMarker
        var parent = dir
        while parent.path != "/" {
            var info = stat()
            if lstat(parent.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFLNK { throw OFAppFailure("整理资料路径包含符号链接，停止读取与写入。") }
            parent.deleteLastPathComponent()
        }
        if fm.fileExists(atPath:dir.path) {
            try OrganizerMigration.requireActiveAuthority(directory:dir)
        }
        let initialized = fm.fileExists(atPath: marker.path)
        if initialized {
            try validateMarker()
            guard fm.fileExists(atPath: dir.path) else { throw OFAppFailure("已初始化整理目录缺失，已停止写入以保护现有资料。") }
            for name in expectedDocuments where !fm.fileExists(atPath: dir.appendingPathComponent(name).path) {
                throw OFAppFailure("已初始化整理资料缺失：\(name)。停止写入，请恢复。")
            }
        } else if fm.fileExists(atPath: dir.path) {
            let children = try fm.contentsOfDirectory(atPath: dir.path)
            guard children.allSatisfy({ $0 == ".app.lock" }) else {
                throw OFAppFailure("整理目录已有资料但缺少初始化依据；须完成迁移收据核验并检查资料完整性，不会建立空白资料。")
            }
        }
        try fm.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var ds = stat()
        guard lstat(dir.path, &ds) == 0, ds.st_uid == getuid(), (ds.st_mode & S_IFMT) == S_IFDIR,
              ds.st_mode & 0o077 == 0 else { throw OFAppFailure("整理资料目录身份、类型或权限异常。") }
        let fd = open(dir.appendingPathComponent(".app.lock").path, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw OFAppFailure("无法建立整理资料独占锁。") }
        var ls = stat()
        guard fstat(fd, &ls) == 0, ls.st_uid == getuid(), ls.st_nlink == 1, ls.st_mode & S_IFMT == S_IFREG,
              ls.st_mode & 0o077 == 0, flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            close(fd); throw OFAppFailure("整理资料已由其他进程使用，或锁身份不安全。")
        }
        lockFD = fd
        return dir
    }
    static func markInitialized() throws {
        if FileManager.default.fileExists(atPath: initializationMarker.path) { try validateMarker(); return }
        for name in expectedDocuments where !FileManager.default.fileExists(atPath: directory.appendingPathComponent(name).path) {
            throw OFAppFailure("整理初始化尚不完整：\(name)，不会写完成标记。")
        }
        try markerBytes.write(to: initializationMarker, options: .withoutOverwriting)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: initializationMarker.path)
    }
    static func release() { if lockFD >= 0 { flock(lockFD, LOCK_UN); close(lockFD); lockFD = -1 } }
    private static func validateMarker() throws {
        var info = stat()
        guard lstat(initializationMarker.path, &info) == 0, info.st_uid == getuid(), info.st_mode & S_IFMT == S_IFREG,
              info.st_nlink == 1, info.st_size == markerBytes.count,
              try Data(contentsOf: initializationMarker) == markerBytes else { throw OFAppFailure("整理初始化标记身份或内容异常，请恢复核验。") }
    }
}
