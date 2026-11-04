// Organizer module port; source application is not a runtime dependency.
import Foundation
import SQLite3
import Darwin
import UniformTypeIdentifiers

private let ofSQLiteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
private enum OFSQLValue {
    case text(String), integer(Int64), real(Double), blob(Data), null
}
private struct OFIndexMarker: Codable { var schemaVersion: Int; var databaseID: String }
private struct OFScanCheckpoint: Codable { var generation: String; var pending: [String]; var count: Int; var eventAtStart: UInt64? = nil }

/// Call blocking methods from a detached task. One bounded scanner; short SQLite transactions use a recursive lock.
final class OFIndexStore: @unchecked Sendable {
    static let schemaVersion = 2
    let directory: URL
    let databaseURL: URL
    let supportsFTS5: Bool
    let testing: Bool
    private var db: OpaquePointer?
    private let lock = NSRecursiveLock()
    private let scanLock = NSLock()
    private var markers: URL { directory.appendingPathComponent("index-initialized.json") }
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(directory: URL, testing: Bool = false) throws {
        self.directory = directory
        self.databaseURL = directory.appendingPathComponent("metadata.sqlite")
        self.testing = testing
        let fm = FileManager.default
        let hasDirectory = fm.fileExists(atPath: directory.path)
        let markerURL = directory.appendingPathComponent("index-initialized.json")
        let hasMarker = fm.fileExists(atPath: markerURL.path)
        let hasDB = fm.fileExists(atPath: databaseURL.path)
        // Any state without its pair is evidence of an interrupted or damaged store, never a new library.
        if hasDB != hasMarker { throw OFIndexError.recovery("初始化记录与 metadata.sqlite 不完整") }
        if hasDirectory {
            var info = stat()
            guard lstat(directory.path,&info) == 0,(info.st_mode & S_IFMT) == S_IFDIR,info.st_uid == geteuid() else {throw OFIndexError.recovery("资料目录身份或类型不正确")}
        }
        for url in [databaseURL,markerURL] where fm.fileExists(atPath:url.path) {
            var info = stat()
            guard lstat(url.path,&info) == 0,(info.st_mode & S_IFMT) == S_IFREG,info.st_uid == geteuid(),info.st_nlink == 1,(url != markerURL || info.st_size <= 1024 * 1024) else {throw OFIndexError.recovery("索引或初始化文件是链接、类型异常或所有者不匹配")}
        }
        if hasDirectory && !hasDB {
            let suspicious = try fm.contentsOfDirectory(atPath: directory.path).filter { $0.hasPrefix("metadata.sqlite") || $0.hasPrefix("index-initialized") }
            if !suspicious.isEmpty { throw OFIndexError.recovery("存在不完整的索引初始化或旁文件") }
        }
        if !hasDirectory { try fm.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]) }
        var handle: OpaquePointer?
        let flags = hasDB ? SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX | SQLITE_OPEN_NOFOLLOW : SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX | SQLITE_OPEN_NOFOLLOW
        guard sqlite3_open_v2(databaseURL.path, &handle, flags, nil) == SQLITE_OK else {
            let diagnostic = handle.map {String(cString:sqlite3_errmsg($0))} ?? "未知错误"
            if handle != nil { sqlite3_close(handle) }; throw OFIndexError.recovery("无法打开索引（\(diagnostic)），未替换原文件")
        }
        self.db = handle
        sqlite3_busy_timeout(handle, 5000)
        sqlite3_create_function_v2(handle, "gao_normalize", 1, SQLITE_UTF8 | SQLITE_DETERMINISTIC, nil, { context, _, arguments in
            guard let context, let argument = arguments?[0], let bytes = sqlite3_value_text(argument) else { sqlite3_result_null(context); return }
            let normalized = String(cString: bytes).ofIndexNormalized
            sqlite3_result_text(context, normalized, -1, ofSQLiteTransient)
        }, nil, nil, nil)
        sqlite3_create_function_v2(handle, "gao_conforms", 2, SQLITE_UTF8 | SQLITE_DETERMINISTIC, nil, { context, _, arguments in
            guard let context, let value = arguments?[0], let filter = arguments?[1], let valueBytes = sqlite3_value_text(value), let filterBytes = sqlite3_value_text(filter) else {sqlite3_result_int(context,0); return}
            let identifier = String(cString:valueBytes), requested = String(cString:filterBytes)
            let matches = OFIndexStore.typeMatches(identifier,requested)
            sqlite3_result_int(context,matches ? 1:0)
        }, nil, nil, nil)
        var fts = false
        if sqlite3_exec(handle, "CREATE VIRTUAL TABLE temp.fts_runtime_probe USING fts5(value)", nil, nil, nil) == SQLITE_OK {
            fts = true; sqlite3_exec(handle, "DROP TABLE temp.fts_runtime_probe", nil, nil, nil)
        }
        self.supportsFTS5 = fts
        do {
            try execute("PRAGMA foreign_keys=ON")
            if hasDB {
                guard try scalarText("PRAGMA quick_check") == "ok" else { throw OFIndexError.recovery("数据库完整性检查失败") }
                let version = Int(try scalarInt("PRAGMA user_version"))
                guard version > 0 && version <= Self.schemaVersion else { throw OFIndexError.recovery("数据库格式不支持（\(version)）") }
                let marker = try decoder.decode(OFIndexMarker.self, from: Data(contentsOf: markerURL))
                guard marker.schemaVersion <= Self.schemaVersion,
                      try scalarText("SELECT value FROM index_meta WHERE key='databaseID'") == marker.databaseID else {
                    throw OFIndexError.recovery("初始化记录与数据库身份不匹配")
                }
                try execute("PRAGMA journal_mode=WAL")
                try execute("PRAGMA synchronous=FULL")
                try migrate(from: version)
            } else {
                try execute("PRAGMA journal_mode=WAL")
                try execute("PRAGMA synchronous=FULL")
                let identifier = UUID().uuidString
                try transaction {
                    try createSchema()
                    try execute("INSERT INTO index_meta(key,value) VALUES('databaseID',?)", [.text(identifier)])
                    try execute("INSERT INTO schema_history(version,applied_at) VALUES(?,?)", [.integer(Int64(Self.schemaVersion)), .real(Date().timeIntervalSince1970)])
                    try execute("PRAGMA user_version=\(Self.schemaVersion)")
                }
                let data = try encoder.encode(OFIndexMarker(schemaVersion: Self.schemaVersion, databaseID: identifier))
                try data.write(to: markerURL, options: .atomic)
                try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: markerURL.path)
            }
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: databaseURL.path)
            if supportsFTS5 { try createFTS() }
            // An unfinished scan is explicit, never automatically replayed on launch.
            try execute("UPDATE authorized_roots SET status='interrupted',diagnostic='上次扫描中断，可继续扫描；保留上次完整索引' WHERE status='scanning'")
        } catch {
            sqlite3_close(db); db = nil
            throw error
        }
    }
    deinit { if let db { sqlite3_close(db) } }

    private func createSchema() throws {
        try execute("""
        CREATE TABLE index_meta(key TEXT PRIMARY KEY,value TEXT NOT NULL);
        CREATE TABLE schema_history(version INTEGER NOT NULL,applied_at REAL NOT NULL);
        CREATE TABLE authorized_roots(id TEXT PRIMARY KEY,display_name TEXT NOT NULL,path TEXT NOT NULL,bookmark BLOB NOT NULL,volume TEXT NOT NULL,device INTEGER NOT NULL,inode INTEGER NOT NULL,root_created REAL NOT NULL,status TEXT NOT NULL DEFAULT 'ready',paused INTEGER NOT NULL DEFAULT 0,last_scan REAL,last_event INTEGER NOT NULL DEFAULT 0,diagnostic TEXT);
        CREATE TABLE files(id TEXT PRIMARY KEY,root_id TEXT NOT NULL REFERENCES authorized_roots(id) ON DELETE CASCADE,relative_path TEXT NOT NULL,name TEXT NOT NULL,extension TEXT NOT NULL,uti TEXT NOT NULL,size INTEGER NOT NULL,modified REAL NOT NULL,created REAL NOT NULL,is_directory INTEGER NOT NULL,is_package INTEGER NOT NULL,is_symlink INTEGER NOT NULL,is_placeholder INTEGER NOT NULL,device INTEGER NOT NULL,inode INTEGER NOT NULL,volume TEXT NOT NULL,name_norm TEXT NOT NULL,path_norm TEXT NOT NULL,generation TEXT NOT NULL,tags TEXT NOT NULL DEFAULT '[]',favorite INTEGER NOT NULL DEFAULT 0,UNIQUE(root_id,relative_path));
        CREATE INDEX files_identity ON files(root_id,volume,device,inode);
        CREATE INDEX files_sort ON files(name_norm,id);
        CREATE INDEX files_filter ON files(root_id,extension,modified,size);
        CREATE TABLE scan_checkpoints(root_id TEXT PRIMARY KEY REFERENCES authorized_roots(id) ON DELETE CASCADE,payload BLOB NOT NULL,updated_at REAL NOT NULL);
        CREATE TABLE staged_files(root_id TEXT NOT NULL REFERENCES authorized_roots(id) ON DELETE CASCADE,generation TEXT NOT NULL,payload BLOB NOT NULL,file_id TEXT NOT NULL,relative_path TEXT NOT NULL,PRIMARY KEY(root_id,generation,relative_path));
        CREATE INDEX staged_identity ON staged_files(file_id);
        """)
    }
    private func migrate(from version: Int) throws {
        if version == 1 {
            // v1 used the same inode-based metadata; v2 adds app-only tags/favourites.
            try transaction {
                let columns = try rows("PRAGMA table_info(files)").compactMap { $0["name"] as? String }
                if !columns.contains("tags") { try execute("ALTER TABLE files ADD COLUMN tags TEXT NOT NULL DEFAULT '[]'") }
                if !columns.contains("favorite") { try execute("ALTER TABLE files ADD COLUMN favorite INTEGER NOT NULL DEFAULT 0") }
                let rootColumns = try rows("PRAGMA table_info(authorized_roots)").compactMap { $0["name"] as? String }
                if !rootColumns.contains("root_created") { try execute("ALTER TABLE authorized_roots ADD COLUMN root_created REAL NOT NULL DEFAULT 0"); try execute("UPDATE authorized_roots SET status='needsAuthorization',diagnostic='旧格式需重新选择同一目录以补充根创建身份'") }
                try execute("INSERT INTO schema_history(version,applied_at) VALUES(2,?)", [.real(Date().timeIntervalSince1970)])
                try execute("PRAGMA user_version=2")
            }
        }
    }
    private func createFTS() throws {
        try execute("""
        CREATE VIRTUAL TABLE IF NOT EXISTS metadata_fts USING fts5(file_id UNINDEXED,metadata,tokenize='unicode61 remove_diacritics 2');
        CREATE TRIGGER IF NOT EXISTS files_fts_insert AFTER INSERT ON files BEGIN INSERT INTO metadata_fts(file_id,metadata) VALUES(new.id,new.name_norm||' '||new.path_norm||' '||new.uti||' '||new.tags); END;
        CREATE TRIGGER IF NOT EXISTS files_fts_delete AFTER DELETE ON files BEGIN DELETE FROM metadata_fts WHERE file_id=old.id; END;
        CREATE TRIGGER IF NOT EXISTS files_fts_update AFTER UPDATE ON files BEGIN DELETE FROM metadata_fts WHERE file_id=old.id; INSERT INTO metadata_fts(file_id,metadata) VALUES(new.id,new.name_norm||' '||new.path_norm||' '||new.uti||' '||new.tags); END;
        """)
        if try scalarInt("SELECT count(*) FROM metadata_fts") != scalarInt("SELECT count(*) FROM files") {
            try transaction { try execute("DELETE FROM metadata_fts"); try execute("INSERT INTO metadata_fts(file_id,metadata) SELECT id,name_norm||' '||path_norm||' '||uti||' '||tags FROM files") }
        }
    }

    func roots() throws -> [OFIndexRoot] {
        try rows("SELECT * FROM authorized_roots ORDER BY display_name,id").map { r in
            guard let id = UUID(uuidString: r.string("id")) else { throw OFIndexError.recovery("授权根 ID 损坏") }
            return OFIndexRoot(id: id, displayName: r.string("display_name"), path: r.string("path"), volumeIdentifier: r.string("volume"), device: UInt64(bitPattern:r.int("device")), inode: UInt64(bitPattern:r.int("inode")), status: r.string("status"), isPaused: r.int("paused") != 0, lastScanAt: r["last_scan"].map { _ in Date(timeIntervalSince1970:r.double("last_scan")) }, lastEventID:UInt64(bitPattern:r.int("last_event")), diagnostic:r["diagnostic"] as? String)
        }
    }
    @discardableResult func addRoot(url: URL) throws -> OFIndexRoot {
        let selected = url.standardizedFileURL.resolvingSymlinksInPath()
        if !testing { try Self.checkRootPolicy(selected) }
        let access = testing ? false:selected.startAccessingSecurityScopedResource()
        defer { if access { selected.stopAccessingSecurityScopedResource() } }
        // NSOpenPanel-selected URLs in this unsandboxed local build may not need a new scope.
        let fd = open(selected.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw OFIndexError.permission("无法读取所选目录") }
        defer { close(fd) }
        var info = stat(); guard fstat(fd, &info) == 0 else { throw OFIndexError.permission("无法核对根目录身份") }
        let volume = try Self.volumeID(selected)
        let knownRoots = try roots()
        var matchingRoot:OFIndexRoot?
        for candidate in knownRoots where candidate.volumeIdentifier == volume && candidate.inode == UInt64(info.st_ino) && (candidate.device == UInt64(info.st_dev) || volume != "device-only") {
            let oldBirth = try rootRecord(candidate.id).double("root_created")
            if oldBirth == 0 || abs(oldBirth-Self.birthTime(info)) < 0.000001 {matchingRoot = candidate; break}
        }
        if let prior = matchingRoot {
            let bookmark = try makeBookmark(selected)
            try execute("UPDATE authorized_roots SET bookmark=?,path=?,device=?,root_created=?,paused=0,status='changed',diagnostic='已重新授权，请补扫核对文件身份' WHERE id=?", [.blob(bookmark),.text(selected.path),.integer(Int64(info.st_dev)),.real(Self.birthTime(info)),.text(prior.id.uuidString)])
            return try roots().first(where: {$0.id == prior.id})!
        }
        let id = UUID()
        try execute("INSERT INTO authorized_roots(id,display_name,path,bookmark,volume,device,inode,root_created) VALUES(?,?,?,?,?,?,?,?)", [.text(id.uuidString),.text(selected.lastPathComponent),.text(selected.path),.blob(try makeBookmark(selected)),.text(volume),.integer(Int64(info.st_dev)),.integer(Int64(bitPattern:UInt64(info.st_ino))),.real(Self.birthTime(info))])
        return try roots().first(where: {$0.id == id})!
    }
    func removeRoot(id: UUID) throws { try execute("DELETE FROM authorized_roots WHERE id=?", [.text(id.uuidString)]) }
    func setPaused(rootID: UUID, paused: Bool) throws {
        let record = try rootRecord(rootID)
        let needsAuthorization = record.string("status") == "needsAuthorization" || record.blob("bookmark").isEmpty
        try execute("UPDATE authorized_roots SET paused=?,status=? WHERE id=?", [.integer(paused ? 1:0),.text(needsAuthorization ? "needsAuthorization" : paused ? "paused":"ready"),.text(rootID.uuidString)])
    }
    func updateEvent(rootID: UUID, eventID: UInt64, requiresFullScan: Bool, diagnostic: String? = nil) throws {
        try execute("UPDATE authorized_roots SET last_event=?,status=CASE WHEN paused=1 THEN 'paused' WHEN status='scanning' THEN 'scanning' ELSE 'changed' END,diagnostic=? WHERE id=?", [.integer(Int64(bitPattern:eventID)),.text(diagnostic ?? (requiresFullScan ? "事件提示可能丢失或根发生变化，需要完整补扫":"检测到变更，等待补扫")),.text(rootID.uuidString)])
    }
    func withRootAccess<T>(id: UUID, body: (URL) throws -> T) throws -> T {
        let lease = try accessLease(rootID:id)
        defer { lease.release() }
        return try body(lease.url)
    }
    func accessLease(rootID id: UUID) throws -> OFIndexAccessLease {
        let record = try rootRecord(id)
        guard record.string("status") != "needsAuthorization", !record.blob("bookmark").isEmpty else {
            throw OFIndexError.permission("迁移目录尚未在搞文件重新授权；请使用系统面板选择同一目录。")
        }
        var stale = false
        let root: URL
        do { root = try URL(resolvingBookmarkData:record.blob("bookmark"), options:testing ? [.withoutUI,.withoutMounting]:[.withSecurityScope,.withoutUI,.withoutMounting], relativeTo:nil, bookmarkDataIsStale:&stale) }
        catch { throw OFIndexError.permission("根书签失效或卷离线") }
        let access = testing ? false:root.startAccessingSecurityScopedResource()
        let lease = OFIndexAccessLease(url:root, scoped:access)
        var accepted = false
        defer { if !accepted { lease.release() } }
        let fd = open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw OFIndexError.permission("目录不可读或授权已撤销") }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd,&info) == 0, UInt64(info.st_ino) == UInt64(bitPattern:record.int("inode")),
              UInt64(info.st_dev) == UInt64(bitPattern:record.int("device")), abs(Self.birthTime(info)-record.double("root_created")) < 0.000001, try Self.volumeID(root) == record.string("volume") else {
            throw OFIndexError.unsafe("原根目录或卷已被其他对象替换；请重新授权")
        }
        if !testing { try Self.checkRootPolicy(root) }
        if stale {
            let renewed = try makeBookmark(root)
            try execute("UPDATE authorized_roots SET bookmark=?,path=?,diagnostic='书签已按相同根身份刷新' WHERE id=?", [.blob(renewed),.text(root.path),.text(id.uuidString)])
        } else if root.path != record.string("path") {
            try execute("UPDATE authorized_roots SET path=? WHERE id=?", [.text(root.path),.text(id.uuidString)])
        }
        accepted = true
        return lease
    }
    private func makeBookmark(_ url:URL) throws -> Data {
        try url.bookmarkData(options:testing ? []:[.withSecurityScope], includingResourceValuesForKeys:[.volumeUUIDStringKey,.fileResourceIdentifierKey], relativeTo:nil)
    }
    private func rootRecord(_ id:UUID) throws -> [String:Any] {
        guard let r = try rows("SELECT * FROM authorized_roots WHERE id=?", [.text(id.uuidString)]).first else { throw OFIndexError.unavailable("授权根已删除") }; return r
    }
    private static func volumeID(_ url:URL) throws -> String {
        // Metadata only, no reads of file contents or iCloud download requests.
        let values = try url.resourceValues(forKeys:[.volumeUUIDStringKey])
        return values.volumeUUIDString ?? "device-only"
    }
    private static func checkRootPolicy(_ url:URL) throws {
        let path = url.standardizedFileURL.path
        let blocked = ["/", "/System", "/Library", "/private", "/dev", "/bin", "/sbin", "/usr", "/Applications"]
        if blocked.contains(path) || ["/System/","/Library/","/private/","/dev/","/usr/"].contains(where:path.hasPrefix) { throw OFIndexError.unsafe("系统或应用目录不能作为索引根") }
        let parts = path.split(separator:"/").map(String.init)
        if parts.contains(where: { $0.hasPrefix(".") || ["Library","GaoSeries","Containers","Group Containers"].contains($0) }) { throw OFIndexError.unsafe("隐藏、系统容器或搞系列私有资料目录已排除") }
    }

    func scan(rootID:UUID, cancel:@Sendable () -> Bool = {false}, progress:@Sendable (OFScanProgress) -> Void = {_ in}) throws -> OFScanReport {
        guard scanLock.try() else { throw OFIndexError.busy }; defer { scanLock.unlock() }
        let started = Date()
        var checkpoint: OFScanCheckpoint
        let prior = try rows("SELECT payload FROM scan_checkpoints WHERE root_id=?", [.text(rootID.uuidString)]).first
        let resumed = prior != nil
        if let prior { checkpoint = try decoder.decode(OFScanCheckpoint.self, from:prior.blob("payload")) }
        else { checkpoint = OFScanCheckpoint(generation:UUID().uuidString,pending:[""],count:0) }
        let generation = checkpoint.generation
        let rootRecord = try rootRecord(rootID)
        guard rootRecord.string("status") != "needsAuthorization", !rootRecord.blob("bookmark").isEmpty else {
            throw OFIndexError.permission("迁移目录需要在搞文件重新授权，未开始扫描或改写检查点。")
        }
        if checkpoint.eventAtStart == nil { checkpoint.eventAtStart = UInt64(bitPattern:rootRecord.int("last_event")) }
        if rootRecord.int("paused") == 1 { throw OFIndexError.unavailable("该目录已暂停") }
        try saveCheckpoint(rootID,checkpoint)
        try execute("UPDATE authorized_roots SET status='scanning',diagnostic=NULL WHERE id=?", [.text(rootID.uuidString)])
        do {
            return try withRootAccess(id:rootID) { root in
                let rootFD = open(root.path,O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                guard rootFD >= 0 else { throw OFIndexError.permission("扫描根不可读") }; defer { close(rootFD) }
                var rootInfo = stat()
                guard fstat(rootFD,&rootInfo) == 0, UInt64(rootInfo.st_ino) == UInt64(bitPattern:rootRecord.int("inode")), UInt64(rootInfo.st_dev) == UInt64(bitPattern:rootRecord.int("device")) else { throw OFIndexError.unsafe("扫描开始时根路径已被替换") }
                while let relative = checkpoint.pending.last {
                    let paused = try self.rootRecord(rootID).int("paused") == 1
                    if cancel() || paused {
                        try saveCheckpoint(rootID,checkpoint)
                        try execute("UPDATE authorized_roots SET status='interrupted',diagnostic='扫描已取消；下次可从目录检查点继续' WHERE id=?", [.text(rootID.uuidString)])
                        return OFScanReport(rootID:rootID,indexedCount:checkpoint.count,completed:false,resumed:resumed,elapsed:Date().timeIntervalSince(started),diagnostic:"已保留检查点；上次完整索引仍可搜索")
                    }
                    let dirFD = try Self.openRelativeDirectory(rootFD:rootFD,relativePath:relative)
                    defer { close(dirFD) }
                    guard let stream = fdopendir(dup(dirFD)) else { throw OFIndexError.permission("无法枚举目录") }
                    var entries = [OFIndexedFile](); var childDirs = [String](); var allocatedIDs = Set<String>()
                    var directoryError: Error?
                    errno = 0
                    while let entry = readdir(stream) {
                        if cancel() { directoryError = OFIndexError.cancelled; break }
                        let name = withUnsafePointer(to:&entry.pointee.d_name) { ptr in ptr.withMemoryRebound(to:CChar.self,capacity:Int(MAXNAMLEN)+1) { String(cString:$0) } }
                        if name == "." || name == ".." || Self.excludedName(name) { continue }
                        var st = stat()
                        guard fstatat(dirFD,name,&st,AT_SYMLINK_NOFOLLOW) == 0 else { directoryError = OFIndexError.unavailable("扫描中有条目变化或不可读，已保留旧索引"); break }
                        let kind = st.st_mode & S_IFMT
                        guard kind == S_IFREG || kind == S_IFDIR || kind == S_IFLNK else { continue }
                        let rel = relative.isEmpty ? name:relative + "/" + name
                        let directory = kind == S_IFDIR
                        let symlink = kind == S_IFLNK
                        let ext = URL(fileURLWithPath:name).pathExtension.ofIndexNormalized
                        let package = directory && (Self.packageExtensions.contains(ext) || UTType(filenameExtension:ext)?.conforms(to:.package) == true)
                        let type = symlink ? "public.symlink" : directory ? (package ? "com.apple.package":"public.folder") : Self.fileType(ext)
                        var id = try stableID(rootID:rootID,relative:rel,device:UInt64(st.st_dev),inode:UInt64(st.st_ino),volume:rootRecord.string("volume"),created:Self.birthTime(st),generation:generation)
                        if allocatedIDs.contains(id) { id = UUID().uuidString }
                        allocatedIDs.insert(id)
                        let old = try rows("SELECT tags,favorite FROM files WHERE id=?", [.text(id)]).first
                        let tags = old.flatMap { try? decoder.decode([String].self,from:Data($0.string("tags").utf8)) } ?? []
                        entries.append(OFIndexedFile(id:id,rootID:rootID,relativePath:rel,name:name,fileExtension:ext,typeIdentifier:type,size:Int64(st.st_size),modifiedAt:Date(timeIntervalSince1970:Double(st.st_mtimespec.tv_sec)+Double(st.st_mtimespec.tv_nsec)/1e9),createdAt:Date(timeIntervalSince1970:Double(st.st_birthtimespec.tv_sec)+Double(st.st_birthtimespec.tv_nsec)/1e9),isDirectory:directory,isPackage:package,isSymbolicLink:symlink,isCloudPlaceholder:(st.st_flags & UInt32(SF_DATALESS)) != 0,device:UInt64(st.st_dev),inode:UInt64(st.st_ino),volumeIdentifier:rootRecord.string("volume"),userTags:tags,favorite:old?.int("favorite") == 1))
                        // A mount boundary is another authorization scope. Never enter it implicitly.
                        if directory && !package && (st.st_flags & UInt32(SF_DATALESS)) == 0 && UInt64(st.st_dev) == UInt64(rootRecord.int("device")) { childDirs.append(rel) }
                        errno = 0
                    }
                    let readError = errno
                    closedir(stream)
                    if let directoryError {
                        if case OFIndexError.cancelled = directoryError { continue }
                        throw directoryError
                    }
                    if readError != 0 { throw OFIndexError.permission("目录枚举中断（\(readError)）") }
                    // Revalidate the path still names the same directory before accepting a completed unit.
                    var before = stat(); guard fstat(dirFD,&before) == 0 else { throw OFIndexError.unsafe("扫描目录身份失效") }
                    let checkFD = try Self.openRelativeDirectory(rootFD:rootFD,relativePath:relative)
                    var after = stat(); let checkOK = fstat(checkFD,&after) == 0 && before.st_dev == after.st_dev && before.st_ino == after.st_ino
                    close(checkFD)
                    guard checkOK else { throw OFIndexError.unsafe("扫描期间目录被替换") }
                    var next = checkpoint
                    next.pending.removeLast(); next.pending.append(contentsOf:childDirs.sorted().reversed()); next.count += entries.count
                    try transaction {
                        for file in entries {
                            try execute("INSERT OR REPLACE INTO staged_files(root_id,generation,payload,file_id,relative_path) VALUES(?,?,?,?,?)", [.text(rootID.uuidString),.text(generation),.blob(try encoder.encode(file)),.text(file.id),.text(file.relativePath)])
                        }
                        try saveCheckpoint(rootID,next)
                    }
                    checkpoint = next
                    progress(OFScanProgress(rootID:rootID,indexedCount:checkpoint.count,pendingDirectories:checkpoint.pending.count,currentPath:relative))
                }
                if cancel() { throw OFIndexError.cancelled }
                // Recheck root identity immediately before atomic snapshot publication.
                try withRootAccess(id:rootID) { _ in
                    try transaction {
                        let staged = try rows("SELECT payload FROM staged_files WHERE root_id=? AND generation=?", [.text(rootID.uuidString),.text(generation)])
                        // Tags may have changed while the scan was running; preserve the live app annotations.
                        var live: [String:([String],Bool)] = [:]
                        for row in try rows("SELECT id,tags,favorite FROM files WHERE root_id=?", [.text(rootID.uuidString)]) { live[row.string("id")] = ((try? decoder.decode([String].self,from:Data(row.string("tags").utf8))) ?? [],row.int("favorite") == 1) }
                        try execute("DELETE FROM files WHERE root_id=?", [.text(rootID.uuidString)])
                        for item in staged {
                            var file = try decoder.decode(OFIndexedFile.self,from:item.blob("payload"))
                            if let annotation = live[file.id] { file.userTags = annotation.0; file.favorite = annotation.1 }
                            try insert(file,generation:generation)
                        }
                        try execute("DELETE FROM staged_files WHERE root_id=?", [.text(rootID.uuidString)])
                        try execute("DELETE FROM scan_checkpoints WHERE root_id=?", [.text(rootID.uuidString)])
                        let eventChanged = UInt64(bitPattern:try self.rootRecord(rootID).int("last_event")) != checkpoint.eventAtStart
                        try execute("UPDATE authorized_roots SET status=?,last_scan=?,diagnostic=? WHERE id=?", [.text(eventChanged ? "changed":"ready"),.real(Date().timeIntervalSince1970),eventChanged ? .text("扫描期间另有事件提示，建议再次补扫"):.null,.text(rootID.uuidString)])
                    }
                }
                return OFScanReport(rootID:rootID,indexedCount:checkpoint.count,completed:true,resumed:resumed,elapsed:Date().timeIntervalSince(started),diagnostic:nil)
            }
        } catch {
            try? execute("UPDATE authorized_roots SET status='interrupted',diagnostic=? WHERE id=?", [.text(error.localizedDescription),.text(rootID.uuidString)])
            throw error
        }
    }
    private func stableID(rootID:UUID,relative:String,device:UInt64,inode:UInt64,volume:String,created:Double,generation:String) throws -> String {
        let matches = try rows("SELECT id,relative_path FROM files WHERE root_id=? AND volume=? AND (device=? OR ?<>'device-only') AND inode=? AND abs(created-?)<0.000001", [.text(rootID.uuidString),.text(volume),.integer(Int64(bitPattern:device)),.text(volume),.integer(Int64(bitPattern:inode)),.real(created)])
        if let exact = matches.first(where: {$0.string("relative_path") == relative}) { return exact.string("id") }
        if matches.count == 1, let first = matches.first,
           try scalarInt("SELECT count(*) FROM staged_files WHERE generation=? AND file_id=?", [.text(generation),.text(first.string("id"))]) == 0 { return first.string("id") }
        return UUID().uuidString
    }
    private func saveCheckpoint(_ root:UUID,_ checkpoint:OFScanCheckpoint) throws {
        try execute("INSERT OR REPLACE INTO scan_checkpoints(root_id,payload,updated_at) VALUES(?,?,?)", [.text(root.uuidString),.blob(try encoder.encode(checkpoint)),.real(Date().timeIntervalSince1970)])
    }
    private static let knownExtensionTypes:[String:String] = [
        "txt":"public.plain-text","text":"public.plain-text","md":"net.daringfireball.markdown","markdown":"net.daringfireball.markdown",
        "csv":"public.comma-separated-values-text","tsv":"public.tab-separated-values-text","json":"public.json","xml":"public.xml","html":"public.html","htm":"public.html","rtf":"public.rtf",
        "swift":"public.swift-source","c":"public.c-source","h":"public.c-header","cpp":"public.c-plus-plus-source","py":"public.python-script","sh":"public.shell-script",
        "pdf":"com.adobe.pdf","png":"public.png","jpg":"public.jpeg","jpeg":"public.jpeg","heic":"public.heic","heif":"public.heif","gif":"com.compuserve.gif","tif":"public.tiff","tiff":"public.tiff","bmp":"com.microsoft.bmp","webp":"org.webmproject.webp","svg":"public.svg-image",
        "mp3":"public.mp3","wav":"com.microsoft.waveform-audio","m4a":"com.apple.m4a-audio","aif":"public.aiff-audio","aiff":"public.aiff-audio","mp4":"public.mpeg-4","mov":"com.apple.quicktime-movie","m4v":"com.apple.m4v-video",
        "zip":"public.zip-archive","gz":"org.gnu.gnu-zip-archive","tar":"public.tar-archive","docx":"org.openxmlformats.wordprocessingml.document","xlsx":"org.openxmlformats.spreadsheetml.sheet","pptx":"org.openxmlformats.presentationml.presentation"
    ]
    private static func fileType(_ ext:String) -> String {
        if let declared = UTType(filenameExtension:ext), !declared.isDynamic {return declared.identifier}
        return knownExtensionTypes[ext] ?? "public.data"
    }
    private static func typeMatches(_ identifier:String,_ requested:String) -> Bool {
        if identifier == requested {return true}
        if let type = UTType(identifier),let base = UTType(requested),type.conforms(to:base) {return true}
        // Public built-in fallback for environments where the LaunchServices type registry is unavailable.
        let image:Set<String> = ["public.png","public.jpeg","public.heic","public.heif","com.compuserve.gif","public.tiff","com.microsoft.bmp","org.webmproject.webp","public.svg-image"]
        let text:Set<String> = ["public.plain-text","net.daringfireball.markdown","public.comma-separated-values-text","public.tab-separated-values-text","public.json","public.xml","public.html","public.rtf","public.swift-source","public.c-source","public.c-header","public.c-plus-plus-source","public.python-script","public.shell-script"]
        let audio:Set<String> = ["public.mp3","com.microsoft.waveform-audio","com.apple.m4a-audio","public.aiff-audio"]
        let movie:Set<String> = ["public.mpeg-4","com.apple.quicktime-movie","com.apple.m4v-video"]
        if requested == "public.image" && image.contains(identifier) {return true}
        if requested == "public.text" && text.contains(identifier) {return true}
        if requested == "public.audio" && audio.contains(identifier) {return true}
        if ["public.movie","public.audiovisual-content"].contains(requested) && movie.contains(identifier) {return true}
        if requested == "public.audiovisual-content" && audio.contains(identifier) {return true}
        if requested == "public.directory" && ["public.folder","com.apple.package"].contains(identifier) {return true}
        if requested == "public.item" {return true}
        if requested == "public.data" {return !["public.folder","com.apple.package","public.symlink"].contains(identifier)}
        if requested == "public.content" {return image.contains(identifier) || text.contains(identifier) || audio.contains(identifier) || movie.contains(identifier) || identifier == "com.adobe.pdf"}
        return false
    }
    private static func birthTime(_ info:stat) -> Double { Double(info.st_birthtimespec.tv_sec)+Double(info.st_birthtimespec.tv_nsec)/1e9 }
    private static let packageExtensions: Set<String> = ["app","bundle","framework","plugin","kext","appex","xpc","photoslibrary","musiclibrary","playground","rtfd","pages","numbers","key","gaoaction","package","xcassets"]
    private static func excludedName(_ name:String) -> Bool {
        name.hasPrefix(".") || ["Library","GaoSeries","Containers","Group Containers","System Volume Information","$RECYCLE.BIN"].contains(name)
    }
    private static func openRelativeDirectory(rootFD:Int32,relativePath:String) throws -> Int32 {
        var fd = dup(rootFD); guard fd >= 0 else { throw OFIndexError.permission("无法固定授权根") }
        do {
            for component in relativePath.split(separator:"/") {
                guard component != "." && component != ".." else { throw OFIndexError.unsafe("相对路径越界") }
                let next = openat(fd,String(component),O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                guard next >= 0 else { throw OFIndexError.unavailable("目录已移动、链接替换或不可读") }
                close(fd); fd = next
            }
            return fd
        } catch { close(fd); throw error }
    }
    private func insert(_ f:OFIndexedFile,generation:String) throws {
        let tags = String(data:try encoder.encode(f.userTags),encoding:.utf8) ?? "[]"
        try execute("INSERT INTO files(id,root_id,relative_path,name,extension,uti,size,modified,created,is_directory,is_package,is_symlink,is_placeholder,device,inode,volume,name_norm,path_norm,generation,tags,favorite) VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)", [.text(f.id),.text(f.rootID.uuidString),.text(f.relativePath),.text(f.name),.text(f.fileExtension),.text(f.typeIdentifier),.integer(f.size),.real(f.modifiedAt.timeIntervalSince1970),.real(f.createdAt.timeIntervalSince1970),.integer(f.isDirectory ? 1:0),.integer(f.isPackage ? 1:0),.integer(f.isSymbolicLink ? 1:0),.integer(f.isCloudPlaceholder ? 1:0),.integer(Int64(bitPattern:f.device)),.integer(Int64(bitPattern:f.inode)),.text(f.volumeIdentifier),.text(f.name.ofIndexNormalized),.text(f.relativePath.ofIndexNormalized),.text(generation),.text(tags),.integer(f.favorite ? 1:0)])
    }

    func search(_ filter:OFSearchFilter,page:Int = 0,pageSize:Int = 100) throws -> OFSearchPage {
        var predicates = ["1=1"]; var parameters = [OFSQLValue]()
        let query = String(filter.query.prefix(4096)).ofIndexNormalized
        if !query.isEmpty {
            // Literal substring semantics: quotes, wildcard characters and Chinese never become query syntax.
            // FTS5 augments token matching; parameterized instr retains partial Chinese and composed Unicode matches.
            if supportsFTS5 {
                let ftsQuery = "\"" + query.replacingOccurrences(of:"\"",with:"\"\"") + "\""
                predicates.append("(instr(name_norm,?)>0 OR instr(path_norm,?)>0 OR instr(gao_normalize(tags),?)>0 OR id IN (SELECT file_id FROM metadata_fts WHERE metadata_fts MATCH ?))")
                parameters += [.text(query),.text(query),.text(query),.text(ftsQuery)]
            } else {
                predicates.append("(instr(name_norm,?)>0 OR instr(path_norm,?)>0 OR instr(gao_normalize(tags),?)>0)")
                parameters += [.text(query),.text(query),.text(query)]
            }
        }
        if let root = filter.rootID { predicates.append("root_id=?"); parameters.append(.text(root.uuidString)) }
        if !filter.extensionName.isEmpty { predicates.append("extension=?"); parameters.append(.text(filter.extensionName.trimmingCharacters(in:CharacterSet(charactersIn:".")).ofIndexNormalized)) }
        if !filter.typeIdentifier.isEmpty { predicates.append("gao_conforms(uti,?)=1"); parameters.append(.text(filter.typeIdentifier)) }
        if !filter.pathContains.isEmpty { predicates.append("instr(path_norm,?)>0"); parameters.append(.text(filter.pathContains.ofIndexNormalized)) }
        if !filter.folder.isEmpty { let prefix = filter.folder.trimmingCharacters(in:CharacterSet(charactersIn:"/")).ofIndexNormalized + "/"; predicates.append("substr(path_norm,1,?)=?"); parameters += [.integer(Int64(prefix.unicodeScalars.count)),.text(prefix)] }
        if let value = filter.minSize { predicates.append("size>=?"); parameters.append(.integer(value)) }
        if let value = filter.maxSize { predicates.append("size<=?"); parameters.append(.integer(value)) }
        if let value = filter.modifiedAfter { predicates.append("modified>=?"); parameters.append(.real(value.timeIntervalSince1970)) }
        if let value = filter.modifiedBefore { predicates.append("modified<=?"); parameters.append(.real(value.timeIntervalSince1970)) }
        if filter.kind != .all { predicates.append(filter.kind == .folders ? "is_directory=1":"is_directory=0") }
        if filter.favoritesOnly { predicates.append("favorite=1") }
        if !filter.tag.isEmpty { predicates.append("EXISTS (SELECT 1 FROM json_each(files.tags) WHERE value=?)"); parameters.append(.text(filter.tag)) }
        let sort: String
        switch filter.sort { case .name:sort="name_norm"; case .modified:sort="modified"; case .size:sort="size"; case .path:sort="path_norm" }
        let predicate = predicates.joined(separator:" AND ")
        let current = min(1_000_000,max(0,page)), limit = min(500,max(1,pageSize))
        let total = try scalarInt("SELECT count(*) FROM files WHERE \(predicate)",parameters)
        let found = try rows("SELECT * FROM files WHERE \(predicate) ORDER BY \(sort) \(filter.ascending ? "ASC":"DESC"),id ASC LIMIT ? OFFSET ?",parameters + [.integer(Int64(limit)),.integer(Int64(current*limit))]).map(decodeFile)
        return OFSearchPage(files:found,totalCount:Int(total),page:current,pageSize:limit)
    }
    private func decodeFile(_ r:[String:Any]) throws -> OFIndexedFile {
        guard let root = UUID(uuidString:r.string("root_id")) else { throw OFIndexError.recovery("文件根 ID 损坏") }
        return OFIndexedFile(id:r.string("id"),rootID:root,relativePath:r.string("relative_path"),name:r.string("name"),fileExtension:r.string("extension"),typeIdentifier:r.string("uti"),size:r.int("size"),modifiedAt:Date(timeIntervalSince1970:r.double("modified")),createdAt:Date(timeIntervalSince1970:r.double("created")),isDirectory:r.int("is_directory") != 0,isPackage:r.int("is_package") != 0,isSymbolicLink:r.int("is_symlink") != 0,isCloudPlaceholder:r.int("is_placeholder") != 0,device:UInt64(bitPattern:r.int("device")),inode:UInt64(bitPattern:r.int("inode")),volumeIdentifier:r.string("volume"),userTags:try decoder.decode([String].self,from:Data(r.string("tags").utf8)),favorite:r.int("favorite") != 0)
    }
    func updateAnnotations(fileID:String,tags:[String],favorite:Bool) throws {
        let clean = Array(Set(tags.map {String($0.trimmingCharacters(in:.whitespacesAndNewlines).prefix(128))}.filter {!$0.isEmpty})).sorted()
        try execute("UPDATE files SET tags=?,favorite=? WHERE id=?", [.text(String(data:try encoder.encode(clean),encoding:.utf8)!),.integer(favorite ? 1:0),.text(fileID)])
    }
    func withVerifiedURL<T>(for file:OFIndexedFile, allowSymbolicLink:Bool = false, body:(URL)throws -> T) throws -> T {
        try withRootAccess(id:file.rootID) { root in
            let fd = open(root.path,O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard fd >= 0 else { throw OFIndexError.permission("根目录不可用") }; defer { close(fd) }
            let components = file.relativePath.split(separator:"/").map(String.init)
            guard !components.isEmpty,components.allSatisfy({$0 != "." && $0 != ".." && !$0.isEmpty}) else { throw OFIndexError.unsafe("缓存路径无效") }
            let parentFD = try Self.openRelativeDirectory(rootFD:fd,relativePath:components.dropLast().joined(separator:"/")); defer {close(parentFD)}
            var st = stat()
            guard fstatat(parentFD,components.last!,&st,AT_SYMLINK_NOFOLLOW) == 0 else {throw OFIndexError.unavailable("原件已消失或无读取权限")}
            guard UInt64(st.st_dev) == file.device,UInt64(st.st_ino) == file.inode,abs(Self.birthTime(st)-file.createdAt.timeIntervalSince1970) < 0.000001 else {throw OFIndexError.unsafe("原路径已变成另一个文件，请重新扫描")}
            if (st.st_mode & S_IFMT) == S_IFLNK && !allowSymbolicLink {throw OFIndexError.unsafe("符号链接仅可显示在 Finder，不能隐式打开目标")}
            return try body(root.appendingPathComponent(file.relativePath))
        }
    }
    func verifiedURL(for file:OFIndexedFile,allowSymbolicLink:Bool = false) throws -> URL { try withVerifiedURL(for:file,allowSymbolicLink:allowSymbolicLink) {$0} }

    func setTags(fileID:String,tags:[String]) throws {
        lock.lock(); defer {lock.unlock()}
        guard let file = try rows("SELECT favorite FROM files WHERE id=?", [.text(fileID)]).first else {throw OFIndexError.unavailable("索引条目已失效")}
        try updateAnnotations(fileID:fileID,tags:tags,favorite:file.int("favorite") == 1)
    }
    func setFavorite(fileID:String,value:Bool) throws {
        try execute("UPDATE files SET favorite=? WHERE id=?", [.integer(value ? 1:0),.text(fileID)])
    }
    /// Discards only an incomplete staged snapshot; the prior complete index and annotations remain.
    func discardScanCheckpoint(rootID:UUID) throws {
        guard scanLock.try() else {throw OFIndexError.busy}; defer {scanLock.unlock()}
        try transaction {
            try execute("DELETE FROM scan_checkpoints WHERE root_id=?", [.text(rootID.uuidString)])
            try execute("DELETE FROM staged_files WHERE root_id=?", [.text(rootID.uuidString)])
            try execute("UPDATE authorized_roots SET status='changed',diagnostic='已放弃未完成快照，可重新完整扫描' WHERE id=?", [.text(rootID.uuidString)])
        }
    }
    /// SQLite online backup creates a consistent database including WAL changes; never overwrites a prior backup.
    func backupDatabase(to url:URL) throws {
        lock.lock(); defer {lock.unlock()}
        let fd = open(url.path,O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW | O_CLOEXEC,0o600)
        guard fd >= 0 else {throw OFIndexError.unsafe("备份目标已存在或不可写，不覆盖")}; close(fd)
        var target:OpaquePointer?
        var success = false
        defer {if let target {sqlite3_close(target)}; if !success {try? FileManager.default.removeItem(at:url)}}
        guard sqlite3_open_v2(url.path,&target,SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX,nil) == SQLITE_OK,
              let backup = sqlite3_backup_init(target,"main",db,"main") else {throw OFIndexError.database("无法开始一致性备份")}
        let result = sqlite3_backup_step(backup,-1)
        let finish = sqlite3_backup_finish(backup)
        guard result == SQLITE_DONE,finish == SQLITE_OK else {throw OFIndexError.database("备份未完成（\(result)）")}
        var check:OpaquePointer?
        guard sqlite3_prepare_v2(target,"PRAGMA quick_check",-1,&check,nil) == SQLITE_OK,sqlite3_step(check) == SQLITE_ROW,
              let bytes = sqlite3_column_text(check,0),String(cString:bytes) == "ok" else {
            sqlite3_finalize(check); throw OFIndexError.recovery("新备份完整性检查失败")
        }
        sqlite3_finalize(check)
        success = true
    }

    // Synthetic migration tests and diagnostics need the actual SQLite version, never guessed feature claims.
    var sqliteVersion:String { String(cString:sqlite3_libversion()) }
    func checkpointForBackup() throws { try execute("PRAGMA wal_checkpoint(FULL)") }

    private func transaction<T>(_ body:()throws->T) throws -> T {
        lock.lock(); defer {lock.unlock()}
        try execute("BEGIN IMMEDIATE")
        do {let result = try body(); try execute("COMMIT"); return result}
        catch {try? execute("ROLLBACK"); throw error}
    }
    private func prepare(_ sql:String,_ values:[OFSQLValue]) throws -> OpaquePointer {
        guard let db else {throw OFIndexError.database("数据库已关闭")}
        var statement:OpaquePointer?
        guard sqlite3_prepare_v2(db,sql,-1,&statement,nil) == SQLITE_OK,let statement else {throw OFIndexError.database(String(cString:sqlite3_errmsg(db)))}
        for (offset,value) in values.enumerated() {
            let i = Int32(offset+1)
            switch value {
            case .text(let v):sqlite3_bind_text(statement,i,v,-1,ofSQLiteTransient)
            case .integer(let v):sqlite3_bind_int64(statement,i,v)
            case .real(let v):sqlite3_bind_double(statement,i,v)
            case .blob(let v):_ = v.withUnsafeBytes {sqlite3_bind_blob(statement,i,$0.baseAddress,Int32(v.count),ofSQLiteTransient)}
            case .null:sqlite3_bind_null(statement,i)
            }
        }
        return statement
    }
    private func execute(_ sql:String,_ values:[OFSQLValue] = []) throws {
        lock.lock(); defer {lock.unlock()}
        if values.isEmpty {
            guard sqlite3_exec(db,sql,nil,nil,nil) == SQLITE_OK else {throw OFIndexError.database(String(cString:sqlite3_errmsg(db)))}
        } else {
            let statement = try prepare(sql,values); defer {sqlite3_finalize(statement)}
            guard sqlite3_step(statement) == SQLITE_DONE else {throw OFIndexError.database(String(cString:sqlite3_errmsg(db)))}
        }
    }
    private func rows(_ sql:String,_ values:[OFSQLValue] = []) throws -> [[String:Any]] {
        lock.lock(); defer {lock.unlock()}
        let statement = try prepare(sql,values); defer {sqlite3_finalize(statement)}
        var found = [[String:Any]]()
        while true {
            let result = sqlite3_step(statement)
            if result == SQLITE_DONE {break}
            guard result == SQLITE_ROW else {throw OFIndexError.database(String(cString:sqlite3_errmsg(db)))}
            var row = [String:Any]()
            for col in 0..<sqlite3_column_count(statement) {
                let name = String(cString:sqlite3_column_name(statement,col))
                switch sqlite3_column_type(statement,col) {
                case SQLITE_INTEGER:row[name] = sqlite3_column_int64(statement,col)
                case SQLITE_FLOAT:row[name] = sqlite3_column_double(statement,col)
                case SQLITE_TEXT:row[name] = String(cString:sqlite3_column_text(statement,col))
                case SQLITE_BLOB:
                    let count = Int(sqlite3_column_bytes(statement,col)); if let bytes = sqlite3_column_blob(statement,col) {row[name] = Data(bytes:bytes,count:count)} else {row[name] = Data()}
                default:break
                }
            }
            found.append(row)
        }
        return found
    }
    private func scalarInt(_ sql:String,_ values:[OFSQLValue] = []) throws -> Int64 { try rows(sql,values).first?.values.first as? Int64 ?? 0 }
    private func scalarText(_ sql:String,_ values:[OFSQLValue] = []) throws -> String { try rows(sql,values).first?.values.first as? String ?? "" }
}
private extension Dictionary where Key == String, Value == Any {
    func string(_ key:String) -> String {self[key] as? String ?? ""}
    func int(_ key:String) -> Int64 {self[key] as? Int64 ?? 0}
    func double(_ key:String) -> Double {self[key] as? Double ?? Double(int(key))}
    func blob(_ key:String) -> Data {self[key] as? Data ?? Data()}
}
