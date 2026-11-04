// Organizer module port; source application is not a runtime dependency.
import Foundation

struct OFIndexRoot: Identifiable, Codable, Sendable, Hashable {
    var id: UUID
    var displayName: String
    var path: String
    var volumeIdentifier: String
    var device: UInt64
    var inode: UInt64
    var status: String
    var isPaused: Bool
    var lastScanAt: Date?
    var lastEventID: UInt64
    var diagnostic: String?
}

struct OFIndexedFile: Identifiable, Codable, Sendable, Hashable {
    var id: String
    var rootID: UUID
    var relativePath: String
    var name: String
    var fileExtension: String
    var typeIdentifier: String
    var size: Int64
    var modifiedAt: Date
    var createdAt: Date
    var isDirectory: Bool
    var isPackage: Bool
    var isSymbolicLink: Bool
    var isCloudPlaceholder: Bool
    var device: UInt64
    var inode: UInt64
    var volumeIdentifier: String
    var userTags: [String]
    var favorite: Bool
}

enum OFSearchKind: String, Codable, CaseIterable, Sendable { case all, files, folders }
enum OFSearchSort: String, Codable, CaseIterable, Sendable { case name, modified, size, path }
struct OFSearchFilter: Codable, Sendable, Hashable {
    var query: String = ""
    var rootID: UUID? = nil
    var extensionName: String = ""
    var typeIdentifier: String = ""
    var pathContains: String = ""
    var minSize: Int64? = nil
    var maxSize: Int64? = nil
    var modifiedAfter: Date? = nil
    var modifiedBefore: Date? = nil
    var kind: OFSearchKind = .all
    var sort: OFSearchSort = .name
    var ascending: Bool = true
    var favoritesOnly: Bool = false
    var tag: String = ""
    var folder: String = ""
}
struct OFSearchPage: Sendable {
    var files: [OFIndexedFile]
    var totalCount: Int
    var page: Int
    var pageSize: Int
}
struct OFScanProgress: Sendable {
    var rootID: UUID
    var indexedCount: Int
    var pendingDirectories: Int
    var currentPath: String
}
struct OFScanReport: Sendable {
    var rootID: UUID
    var indexedCount: Int
    var completed: Bool
    var resumed: Bool
    var elapsed: TimeInterval
    var diagnostic: String?
}

enum OFIndexError: LocalizedError {
    case database(String), recovery(String), permission(String), unavailable(String), unsafe(String), busy, cancelled
    var errorDescription: String? {
        switch self {
        case .database(let s): return "索引数据库：\(s)"
        case .recovery(let s): return "需要恢复资料：\(s)；已停止写入。请从备份恢复完整资料，勿删除初始化记录。"
        case .permission(let s): return "授权不可用：\(s)；请重新选择该目录授权。"
        case .unavailable(let s): return "文件不可用：\(s)"
        case .unsafe(let s): return "为保护原件已停止：\(s)"
        case .busy: return "另一项扫描正在进行，请稍后重试。"
        case .cancelled: return "已取消，保留上次完整索引和本次检查点。"
        }
    }
}

extension String {
    var ofIndexNormalized: String {
        precomposedStringWithCanonicalMapping.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    }
}

/// Retain this lease across asynchronous use; releasing it balances the root bookmark's scope.
final class OFIndexAccessLease: @unchecked Sendable {
    let url: URL
    private var scoped: Bool
    private let lock = NSLock()
    init(url:URL,scoped:Bool) {self.url = url; self.scoped = scoped}
    func release() {
        lock.lock(); defer {lock.unlock()}
        if scoped {url.stopAccessingSecurityScopedResource(); scoped = false}
    }
    deinit {release()}
}
