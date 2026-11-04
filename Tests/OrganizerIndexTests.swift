// Isolated Organizer module regression; compile/run only this @main entry point.
import Foundation
import Darwin
import SQLite3

private final class TestFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false
    func set() {lock.lock();flag = true;lock.unlock()}
    func value() -> Bool {lock.lock();defer {lock.unlock()};return flag}
}
private enum TestFailure: Error { case assertion(String) }
private func expect(_ condition:@autoclosure ()throws->Bool,_ message:String) throws {
    if try !condition() {throw TestFailure.assertion(message)}
}
private func expectFailure(_ description:String,_ body:()throws->Void) throws {
    do {try body()} catch {return}
    throw TestFailure.assertion("Expected failure: \(description)")
}
private func sqlite(_ url:URL,_ sql:String) throws {
    var db:OpaquePointer?
    guard sqlite3_open_v2(url.path,&db,SQLITE_OPEN_READWRITE,nil) == SQLITE_OK else {throw TestFailure.assertion("fixture database open")}
    defer {sqlite3_close(db)}
    guard sqlite3_exec(db,sql,nil,nil,nil) == SQLITE_OK else {throw TestFailure.assertion("fixture SQL: \(String(cString:sqlite3_errmsg(db)))")}
}

@main struct OrganizerIndexTests {
    static func main() throws {
        let base = URL(fileURLWithPath:"/private/tmp",isDirectory:true).appendingPathComponent("GaoWenJian-OrganizerIndexTests-"+UUID().uuidString+".noindex")
        try FileManager.default.createDirectory(at:base,withIntermediateDirectories:true)
        defer {try? FileManager.default.removeItem(at:base)}
        let roots = base.appendingPathComponent("files")
        try FileManager.default.createDirectory(at:roots,withIntermediateDirectories:true)
        try Data("original".utf8).write(to:roots.appendingPathComponent("中文 文件.txt"))
        try Data("accent".utf8).write(to:roots.appendingPathComponent("Cafe\u{301}空间 \"引号\".txt"))
        try Data("plain".utf8).write(to:roots.appendingPathComponent("README"))
        try FileManager.default.createDirectory(at:roots.appendingPathComponent("nested"),withIntermediateDirectories:true)
        try Data("nested".utf8).write(to:roots.appendingPathComponent("nested/child.txt"))
        try FileManager.default.createDirectory(at:roots.appendingPathComponent("Demo.app"),withIntermediateDirectories:true)
        try Data("never index app contents".utf8).write(to:roots.appendingPathComponent("Demo.app/private.txt"))
        try FileManager.default.createDirectory(at:roots.appendingPathComponent(".hidden"),withIntermediateDirectories:true)
        try Data("hidden".utf8).write(to:roots.appendingPathComponent(".hidden/secret.txt"))
        try FileManager.default.createDirectory(at:roots.appendingPathComponent("Library"),withIntermediateDirectories:true)
        try Data("library".utf8).write(to:roots.appendingPathComponent("Library/secret.txt"))
        try FileManager.default.createSymbolicLink(at:roots.appendingPathComponent("loop"),withDestinationURL:roots)
        try FileManager.default.linkItem(at:roots.appendingPathComponent("README"),to:roots.appendingPathComponent("hardlink"))
        let directory = base.appendingPathComponent("store")
        var rootID:UUID!
        do {
            let store = try OFIndexStore(directory:directory,testing:true)
            let root = try store.addRoot(url:roots)
            rootID = root.id
            try expect(try store.roots().count == 1,"root persisted")
            let report = try store.scan(rootID:root.id)
            try expect(report.completed,"first scan complete")
            let all = try store.search(OFSearchFilter(),pageSize:500)
            try expect(all.totalCount == 8,"expected bounded metadata count: \(all.totalCount)")
            try expect(all.files.filter {$0.name == "README" || $0.name == "hardlink"}.map(\.id).count == 2,"hardlinks represented as separate directory entries")
            try expect(Set(all.files.filter {$0.name == "README" || $0.name == "hardlink"}.map(\.id)).count == 2,"hardlink IDs distinct")
            var query = OFSearchFilter(); query.query = "中文"
            try expect(try store.search(query).totalCount == 1,"Chinese substring")
            query.query = "CAFÉ空间"
            try expect(try store.search(query).totalCount == 1,"composed Unicode/case/space")
            query.query = "\"引号\""
            try expect(try store.search(query).totalCount == 1,"literal quoted text")
            query.query = "%"
            try expect(try store.search(query).totalCount == 0,"literal wildcard")
            query.query = "' OR 1=1 --"
            try expect(try store.search(query).totalCount == 0,"parameterized SQL and FTS syntax")
            query = OFSearchFilter();query.extensionName = "txt"
            try expect(try store.search(query).totalCount == 3,"extension filter")
            query = OFSearchFilter();query.typeIdentifier = "public.text"
            let textFamily = try store.search(query)
            try expect(textFamily.totalCount == 3,"UTType family conformance filter")
            query = OFSearchFilter();query.kind = .folders
            try expect(try store.search(query).totalCount == 2,"directory/package filter")
            query = OFSearchFilter();query.folder = "nested"
            try expect(try store.search(query).totalCount == 1,"folder filter")
            try expect(try store.search(OFSearchFilter(),page:1,pageSize:3).files.count == 3,"stable pagination")
            let annotated = all.files.first {$0.name == "中文 文件.txt"}!
            try store.setTags(fileID:annotated.id,tags:["项目A","项目A","中文"])
            try store.setFavorite(fileID:annotated.id,value:true)
            try FileManager.default.moveItem(at:roots.appendingPathComponent("中文 文件.txt"),to:roots.appendingPathComponent("改名中文.txt"))
            let edit = try FileHandle(forWritingTo:roots.appendingPathComponent("README"))
            try edit.truncate(atOffset:0); try edit.write(contentsOf:Data("edited data is larger".utf8)); try edit.close()
            try FileManager.default.removeItem(at:roots.appendingPathComponent("nested/child.txt"))
            try Data("new".utf8).write(to:roots.appendingPathComponent("new.txt"))
            try expect(try store.scan(rootID:root.id).completed,"rescan complete")
            var fav = OFSearchFilter();fav.favoritesOnly = true
            let renamed = try store.search(fav).files
            try expect(renamed.count == 1 && renamed[0].id == annotated.id && renamed[0].relativePath == "改名中文.txt","rename uses inode identity and preserves favourite")
            try expect(renamed[0].userTags == ["中文","项目A"],"custom tags preserved")
            var tag = OFSearchFilter();tag.query = "项目A"
            try expect(try store.search(tag).totalCount == 1,"normalized metadata tag query")
            try expectFailure("old cached path after rename") {_ = try store.verifiedURL(for:annotated)}
            try expect(try store.verifiedURL(for:renamed[0]).lastPathComponent == "改名中文.txt","revalidated file action")
            let link = all.files.first {$0.isSymbolicLink}!
            try expectFailure("symbolic link must not be opened implicitly") {_ = try store.verifiedURL(for:link)}
            _ = try store.verifiedURL(for:link,allowSymbolicLink:true)
            try Data("victim".utf8).write(to:roots.appendingPathComponent("victim.txt"))
            _ = try store.scan(rootID:root.id)
            var victimFilter = OFSearchFilter();victimFilter.query = "victim.txt"
            let victim = try store.search(victimFilter).files[0]
            let replacement = roots.appendingPathComponent("replacement.txt")
            try Data("new identity".utf8).write(to:replacement)
            try FileManager.default.removeItem(at:roots.appendingPathComponent("victim.txt"))
            try FileManager.default.moveItem(at:replacement,to:roots.appendingPathComponent("victim.txt"))
            try expectFailure("same path new identity") {_ = try store.verifiedURL(for:victim)}
            let oldCount = try store.search(OFSearchFilter()).totalCount
            try Data("not published until full completion".utf8).write(to:roots.appendingPathComponent("after-cancel.txt"))
            let cancel = TestFlag()
            let interrupted = try store.scan(rootID:root.id,cancel:{cancel.value()},progress:{_ in cancel.set()})
            try expect(!interrupted.completed,"cancelled scan reports incomplete")
            try expect(try store.search(OFSearchFilter()).totalCount == oldCount,"cancel preserves previous complete index")
            let resumed = try store.scan(rootID:root.id)
            try expect(resumed.completed && resumed.resumed,"directory-granularity resume")
            try expect(try store.search(OFSearchFilter()).totalCount == oldCount+1,"resumed snapshot is atomically published")
            try store.setPaused(rootID:root.id,paused:true)
            try expectFailure("paused scan") {_ = try store.scan(rootID:root.id)}
            try store.setPaused(rootID:root.id,paused:false)
            // Synthetic path swap occurs between directory units, with an external secret never authorized by this root.
            let outside = base.appendingPathComponent("outside")
            try FileManager.default.createDirectory(at:outside,withIntermediateDirectories:true)
            try Data("secret".utf8).write(to:outside.appendingPathComponent("escape-secret.txt"))
            let moved = base.appendingPathComponent("held-nested")
            let race = TestFlag()
            try expectFailure("mid-scan directory symlink replacement") {
                _ = try store.scan(rootID:root.id,progress:{ p in
                    if p.currentPath.isEmpty && !race.value() {
                        race.set()
                        try? FileManager.default.moveItem(at:roots.appendingPathComponent("nested"),to:moved)
                        try? FileManager.default.createSymbolicLink(at:roots.appendingPathComponent("nested"),withDestinationURL:outside)
                    }
                })
            }
            var escaped = OFSearchFilter();escaped.query = "escape-secret"
            try expect(try store.search(escaped).totalCount == 0,"symlink boundary never traversed")
            try expect(try store.search(OFSearchFilter()).totalCount == oldCount+1,"race keeps complete old generation")
            try FileManager.default.removeItem(at:roots.appendingPathComponent("nested"))
            try FileManager.default.moveItem(at:moved,to:roots.appendingPathComponent("nested"))
            try store.discardScanCheckpoint(rootID:root.id)
            _ = try store.scan(rootID:root.id)
            let backup = base.appendingPathComponent("backup.sqlite")
            try store.backupDatabase(to:backup)
            try expectFailure("backup refuses overwrite") {try store.backupDatabase(to:backup)}
            try expect(try Data(contentsOf:backup).count > 0,"online database backup exists")
            print("INDEX sqlite=\(store.sqliteVersion) FTS5=\(store.supportsFTS5); functional assertions passed")
        }
        do {
            let reopened = try OFIndexStore(directory:directory,testing:true)
            try expect(try reopened.roots().first?.id == rootID,"cold reopen retains root")
            var fav = OFSearchFilter();fav.favoritesOnly = true
            try expect(try reopened.search(fav).totalCount == 1,"cold reopen retains app annotations")
        }
        let dbURL = directory.appendingPathComponent("metadata.sqlite")
        try sqlite(dbURL,"DROP TRIGGER IF EXISTS files_fts_insert; DROP TRIGGER IF EXISTS files_fts_delete; DROP TRIGGER IF EXISTS files_fts_update; DROP TABLE IF EXISTS metadata_fts; ALTER TABLE files DROP COLUMN tags; ALTER TABLE files DROP COLUMN favorite; ALTER TABLE authorized_roots DROP COLUMN root_created; PRAGMA user_version=1;")
        do {
            let migrated = try OFIndexStore(directory:directory,testing:true)
            try expect(try migrated.search(OFSearchFilter()).totalCount > 0,"v1 metadata migration retains complete files")
            try expect(try migrated.roots().first?.id == rootID,"v1 root identity retained")
            try expect(try migrated.roots().first?.status == "needsAuthorization","legacy root requests identity reauthorization")
            try expectFailure("legacy root not silently trusted") {_ = try migrated.accessLease(rootID:rootID)}
            let reauthorized = try migrated.addRoot(url:roots)
            try expect(reauthorized.id == rootID,"explicit old root reauthorization keeps ID")
            _ = try migrated.scan(rootID:rootID)
        }
        // Migrated-root permission cannot be restored through pause/resume or an old bookmark.
        try sqlite(dbURL,"UPDATE authorized_roots SET bookmark=x'',paused=1,status='needsAuthorization'")
        do {
            let gated = try OFIndexStore(directory:directory,testing:true)
            try gated.setPaused(rootID:rootID,paused:false)
            try expect(try gated.roots().first?.status == "needsAuthorization","pause/resume must not authorize migration roots")
            try expectFailure("migrated empty bookmark access blocked") {_ = try gated.accessLease(rootID:rootID)}
            try expectFailure("migrated scan access blocked") {_ = try gated.scan(rootID:rootID)}
            let again = try gated.addRoot(url:roots)
            try expect(again.id == rootID,"explicit reauthorization preserves migrated root ID")
            _ = try gated.scan(rootID:rootID)
        }
        try sqlite(dbURL,"PRAGMA user_version=999")
        try expectFailure("future schema fail closed") {_ = try OFIndexStore(directory:directory,testing:true)}
        try sqlite(dbURL,"PRAGMA user_version=2")
        let absent = base.appendingPathComponent("absent.sqlite")
        try FileManager.default.moveItem(at:dbURL,to:absent)
        try expectFailure("initialized but missing database") {_ = try OFIndexStore(directory:directory,testing:true)}
        try expect(!FileManager.default.fileExists(atPath:dbURL.path),"missing database not recreated")
        try FileManager.default.moveItem(at:absent,to:dbURL)
        let marker = directory.appendingPathComponent("index-initialized.json")
        let markerData = try Data(contentsOf:marker)
        try Data("corrupt marker".utf8).write(to:marker)
        try expectFailure("corrupt initializer") {_ = try OFIndexStore(directory:directory,testing:true)}
        try markerData.write(to:marker)
        let dbData = try Data(contentsOf:dbURL)
        let corruption = Data("not a SQLite database".utf8)
        try corruption.write(to:dbURL)
        try expectFailure("corrupt database fail closed") {_ = try OFIndexStore(directory:directory,testing:true)}
        try expect(try Data(contentsOf:dbURL) == corruption,"corrupt database not reset or overwritten")
        try dbData.write(to:dbURL)
        let otherParent = base.appendingPathComponent("other")
        try FileManager.default.createDirectory(at:otherParent,withIntermediateDirectories:true)
        let sameName = otherParent.appendingPathComponent("files")
        try FileManager.default.createDirectory(at:sameName,withIntermediateDirectories:true)
        do {
            let store = try OFIndexStore(directory:directory,testing:true)
            let other = try store.addRoot(url:sameName)
            try expect(other.id != rootID,"same display name is not identity")
            try store.removeRoot(id:other.id)
            try expect(FileManager.default.fileExists(atPath:sameName.path),"remove authorized root only removes app configuration")
        }
        var usage = rusage()
        if getrusage(RUSAGE_SELF,&usage) == 0 {
            let cpu = Double(usage.ru_utime.tv_sec)+Double(usage.ru_utime.tv_usec)/1e6+Double(usage.ru_stime.tv_sec)+Double(usage.ru_stime.tv_usec)/1e6
            print(String(format:"INDEX TEST PROCESS cpu=%.3fs peakRSS=%.2fMiB (includes fixtures/all assertions, not scan-only)",cpu,Double(usage.ru_maxrss)/1048576))
        }
        print("PASS IndexTests: Unicode, literal SQL/FTS input, filters/pages, inode rename+hardlinks, symlink/package/hidden boundaries, interruption/resume, path swap, annotations, pause, online backup, migration, future schema/missing/corrupt initialization")
    }
}
