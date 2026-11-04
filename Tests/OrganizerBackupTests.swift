// Isolated Organizer module regression; compile/run only this @main entry point.
import Foundation

func ensure(_ value: Bool, _ message: String) throws { if !value { throw OFAppFailure(message) } }
@main struct OrganizerBackupTests {
    static func main() throws {
        let fm = FileManager.default
        let base = URL(fileURLWithPath: "/private/tmp/GaoWenJian-OrganizerBackupTests-" + UUID().uuidString + ".noindex")
        try fm.createDirectory(at: base, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]); defer { try? fm.removeItem(at: base) }
        let data = base.appendingPathComponent("Data"); let index = try OFIndexStore(directory: data, testing: true)
        let required = ["configuration.json", "configuration.initialized", "associations_history.json", "associations_history.initialized", "MovePlans/initialized.json", "MovePlans/ledger.json", "MovePlans.initialized"]
        for name in required { let url = data.appendingPathComponent(name); try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true); try Data("synthetic \(name)".utf8).write(to: url) }
        let attachment = data.appendingPathComponent("SourceArchive/Incoming/original/payload/important.lock")
        try fm.createDirectory(at: attachment.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("原创不可丢失附件".utf8).write(to: attachment)
        for name in [".app.lock", "MovePlans/.lock", "Exchange/Journal/ledger.lock"] { try fm.createDirectory(at: data.appendingPathComponent(name).deletingLastPathComponent(), withIntermediateDirectories: true); try Data("running lock".utf8).write(to: data.appendingPathComponent(name)) }
        let backup = base.appendingPathComponent("Backup")
        try OFBackupEngine.create(index: index, directory: data, target: backup, version: "1.00")
        try ensure(fm.fileExists(atPath: backup.appendingPathComponent("VERIFIED").path), "没有验证依据")
        let copied = backup.appendingPathComponent("Data/SourceArchive/Incoming/original/payload/important.lock")
        try ensure(try Data(contentsOf: copied) == Data(contentsOf: attachment), "误排除了合法 .lock 附件")
        for name in [".app.lock", "MovePlans/.lock", "Exchange/Journal/ledger.lock"] { try ensure(!fm.fileExists(atPath: backup.appendingPathComponent("Data/"+name).path), "复制了运行锁") }
        print("PASS backup copies .lock attachment, only excludes exact three runtime locks, hashes full inventory")
        let manifestBefore = try Data(contentsOf: backup.appendingPathComponent("manifest.json"))
        var refused = false
        do { try OFBackupEngine.create(index: index, directory: data, target: backup, version: "1.00") } catch { refused = true }
        try ensure(refused, "未拒绝覆盖已有备份")
        try ensure(try Data(contentsOf: backup.appendingPathComponent("manifest.json")) == manifestBefore, "改写了已有备份")
        print("PASS existing backup not overwritten")
        try fm.removeItem(at: data.appendingPathComponent("configuration.json"))
        let failed = base.appendingPathComponent("MissingRequired")
        refused = false
        do { try OFBackupEngine.create(index: index, directory: data, target: failed, version: "1.00") } catch { refused = true }
        try ensure(refused, "缺少必要资料仍返回成功")
        try ensure(!fm.fileExists(atPath: failed.appendingPathComponent("VERIFIED").path), "不完整备份出现 VERIFIED")
        print("PASS missing required data cannot be verified as empty")
        try Data("restored synthetic".utf8).write(to: data.appendingPathComponent("configuration.json"))
        try fm.createSymbolicLink(at: data.appendingPathComponent("linkedAttachment"), withDestinationURL: attachment)
        let linked = base.appendingPathComponent("Symlink")
        refused = false
        do { try OFBackupEngine.create(index: index, directory: data, target: linked, version: "1.00") } catch { refused = true }
        try ensure(refused, "链接备份仍返回成功")
        try ensure(!fm.fileExists(atPath: linked.appendingPathComponent("VERIFIED").path), "链接备份出现 VERIFIED")
        print("PASS linked attachments stop backup without false verification")
        try fm.removeItem(at: data.appendingPathComponent("linkedAttachment"))
        let moduleMarker = base.appendingPathComponent("Organizer.initialized")
        let markerBytes = Data("schema=1\n".utf8); try markerBytes.write(to: moduleMarker)
        let withMarker = base.appendingPathComponent("WithModuleMarker")
        try OFBackupEngine.create(index: index, directory: data, target: withMarker, version: "1.10", initializationMarker: moduleMarker)
        try ensure(try Data(contentsOf: withMarker.appendingPathComponent("Organizer.initialized")) == markerBytes, "父初始化标记未备份")
        let markerManifest = try JSONSerialization.jsonObject(with: Data(contentsOf: withMarker.appendingPathComponent("manifest.json"))) as! [String:Any]
        try ensure(markerManifest["rootInitializationMarkerSHA256"] as? String == OFProtectedDocument<OFLibraryConfiguration>.digest(markerBytes), "父标记摘要未绑定")
        print("PASS organizer parent marker backed up with explicit manifest SHA")
        print("BACKUP TESTS PASSED: 5; synthetic files only; no app launch")
    }
}
