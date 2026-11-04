// Isolated Organizer module regression; compile/run only this @main entry point.
import Foundation
import Darwin

private struct TestFailure: Error, CustomStringConvertible { let description: String }
private func expect(_ value: @autoclosure () throws -> Bool, _ message: String) throws {
    if try !value() { throw TestFailure(description: message) }
}
private func expectThrows(_ message: String, _ body: () throws -> Void) throws {
    do { try body() } catch is TestFailure { throw TestFailure(description: message + "（断言失败）") } catch { return }
    throw TestFailure(description: message + "（未抛错）")
}
private final class Fixture {
    let root: URL
    let source: URL
    let target: URL
    let journal: URL
    let fm = FileManager.default
    init() throws {
        root = URL(fileURLWithPath: "/private/tmp/GaoWenJian-OrganizerMoveTests-" + UUID().uuidString + ".noindex")
        source = root.appendingPathComponent("来源")
        target = root.appendingPathComponent("目标")
        journal = root.appendingPathComponent("日志")
        for url in [root, source, target] { try fm.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]) }
    }
    deinit { try? fm.removeItem(at: root) }
    func auth() throws -> OFMoveAuthorization { try OFMoveAuthorization(sourceRoots: [source], destinationRoot: target) }
    func file(_ name: String = "中文 空格 '引号'.txt", content: String = "原创测试内容") throws -> URL {
        let url = source.appendingPathComponent(name)
        try Data(content.utf8).write(to: url)
        return url
    }
    func content(_ url: URL) throws -> String { try String(contentsOf: url, encoding: .utf8) }
    func exists(_ url: URL) -> Bool { fm.fileExists(atPath: url.path) }
    func validated(_ engine: OFMoveEngine, _ urls: [URL]) throws -> OFMovePlan {
        let authorization = try auth()
        return try engine.validate(engine.create(sources: urls, destination: target, authorization: authorization), authorization: authorization)
    }
    func run(_ engine: OFMoveEngine, _ plan: OFMovePlan, progress: ((OFMovePlan) -> Void)? = nil) throws -> OFMovePlan {
        try engine.execute(id: plan.id, confirmation: OFMoveConfirmation(planID: plan.id, revision: plan.revision), authorization: auth(), progress: progress)
    }
}

@main struct OrganizerMoveTests {
    static func main() throws {
        guard CommandLine.arguments.contains("--data-dir"), FileSafety.root.path.hasPrefix("/private/tmp/"), FileSafety.root.path.contains(".noindex/") else { throw TestFailure(description: "Organizer move tests require isolated --data-dir under a private .noindex root") }
        var count = 0
        func test(_ name: String, _ body: () throws -> Void) throws {
            try body(); count += 1; print("PASS \(name)")
        }
        try test("same-volume content/xattr/mode, idempotent execute, safe rollback") {
            let f = try Fixture(); let url = try f.file()
            chmod(url.path, 0o640)
            let attr = Data("原创资源属性".utf8)
            let attrResult = attr.withUnsafeBytes { setxattr(url.path, "com.gaoseries.synthetic-test", $0.baseAddress, attr.count, 0, 0) }
            try expect(attrResult == 0, "设置合成扩展属性失败")
            let engine = try OFMoveEngine(directory: f.journal)
            let plan = try f.validated(engine, [url])
            let result = try f.run(engine, plan)
            let target = result.operations[0].destination
            try expect(result.state == .committed, "计划未完成")
            try expect(!f.exists(url) && f.exists(target), "原子移动结果错误")
            try expect(try f.content(target) == "原创测试内容", "目标字节错误")
            var s = stat(); try expect(lstat(target.path, &s) == 0 && s.st_mode & 0o777 == 0o640, "权限未保留")
            var attrBytes = [UInt8](repeating: 0, count: attr.count)
            try expect(getxattr(target.path, "com.gaoseries.synthetic-test", &attrBytes, attrBytes.count, 0, 0) == attr.count && Data(attrBytes) == attr, "扩展属性未保留")
            let repeated = try f.run(engine, plan)
            try expect(repeated.state == .committed && repeated.revision == result.revision, "重复执行有副作用")
            let restored = try engine.rollback(id: plan.id, authorization: f.auth())
            try expect(restored.state == .cancelled && f.exists(url) && !f.exists(target), "回滚失败")
            try expect(try f.content(url) == "原创测试内容", "恢复内容错误")
        }
        try test("existing destination is never overwritten") {
            let f = try Fixture(); let url = try f.file(); let target = f.target.appendingPathComponent(url.lastPathComponent)
            try Data("用户新资料".utf8).write(to: target)
            let e = try OFMoveEngine(directory: f.journal)
            let p = try e.create(sources: [url], destination: f.target, authorization: f.auth())
            try expectThrows("冲突应拒绝") { _ = try e.validate(p, authorization: f.auth()) }
            try expect(try f.content(target) == "用户新资料" && f.exists(url), "冲突覆盖了用户资料")
        }
        try test("edit during confirmation invalidates source digest") {
            let f = try Fixture(); let url = try f.file(content: "aaaa"); let e = try OFMoveEngine(directory: f.journal)
            let p = try f.validated(e, [url]); try Data("bbbb".utf8).write(to: url)
            try expectThrows("来源变化应拒绝") { _ = try f.run(e, p) }
            try expect(try f.content(url) == "bbbb" && !f.exists(f.target.appendingPathComponent(url.lastPathComponent)), "错误移动了变化后的来源")
        }
        try test("same-name source replacement is rejected") {
            let f = try Fixture(); let url = try f.file(); let e = try OFMoveEngine(directory: f.journal)
            let p = try f.validated(e, [url]); let old = f.source.appendingPathComponent("old.txt")
            try f.fm.moveItem(at: url, to: old); try Data("replacement".utf8).write(to: url)
            try expectThrows("来源替换应拒绝") { _ = try f.run(e, p) }
            try expect(try f.content(url) == "replacement" && f.exists(old), "替换对象被误改")
        }
        try test("destination created after confirmation is retained") {
            let f = try Fixture(); let url = try f.file(); let e = try OFMoveEngine(directory: f.journal)
            let p = try f.validated(e, [url]); let target = p.operations[0].destination
            try Data("后来新建".utf8).write(to: target)
            try expectThrows("新冲突应拒绝") { _ = try f.run(e, p) }
            try expect(try f.content(target) == "后来新建" && f.exists(url), "目标新资料被覆盖")
        }
        for point in [OFMoveFaultPoint.beforeJournal, .afterJournal, .beforeRename, .afterRename, .beforeCommit, .afterCommit] {
            try test("interruption \(point.rawValue): durable stop, no replay, recover original") {
                let f = try Fixture(); let url = try f.file()
                var e: OFMoveEngine? = try OFMoveEngine(directory: f.journal, faultInjector: { injected, _, _ in if injected == point { throw OFMoveInjectedCrash() } })
                let p = try f.validated(e!, [url]); let target = p.operations[0].destination
                try expectThrows("故障应中断") { _ = try f.run(e!, p) }
                let shouldHaveMoved = [OFMoveFaultPoint.afterRename, .beforeCommit, .afterCommit].contains(point)
                try expect(f.exists(target) == shouldHaveMoved && f.exists(url) != shouldHaveMoved, "中断阶段文件结果错误")
                e = nil
                let restart = try OFMoveEngine(directory: f.journal)
                try expect(restart.plan(id: p.id)?.state == .needsRecovery, "冷启动没有标记恢复")
                try expect(f.exists(target) == shouldHaveMoved, "冷启动自动改变文件")
                try expectThrows("恢复前不能重放") { _ = try f.run(restart, p) }
                _ = try restart.rollback(id: p.id, authorization: f.auth())
                try expect(f.exists(url) && !f.exists(target), "安全回滚未恢复原件")
                try expect(try f.content(url) == "原创测试内容", "恢复后原件损坏")
            }
        }
        try test("journal disk-full injection leaves original intact") {
            let f = try Fixture(); let url = try f.file()
            let e = try OFMoveEngine(directory: f.journal, faultInjector: { point, _, _ in
                if point == .beforeJournal { throw NSError(domain: NSPOSIXErrorDomain, code: Int(ENOSPC)) }
            })
            let p = try f.validated(e, [url])
            try expectThrows("模拟磁盘满应停止") { _ = try f.run(e, p) }
            try expect(f.exists(url) && !f.exists(p.operations[0].destination), "日志写入失败仍改了文件")
        }
        try test("source changes immediately before rename: no mutation") {
            let f = try Fixture(); let url = try f.file()
            let e = try OFMoveEngine(directory: f.journal, faultInjector: { point, _, _ in if point == .beforeRename { try Data("临提交修改".utf8).write(to: url) } })
            let p = try f.validated(e, [url])
            try expectThrows("最终复核应拒绝") { _ = try f.run(e, p) }
            try expect(try f.content(url) == "临提交修改" && !f.exists(p.operations[0].destination), "最终变化文件被移动")
        }
        try test("cancel before first mutation") {
            let f = try Fixture(); let url = try f.file(); let e = try OFMoveEngine(directory: f.journal); let p = try f.validated(e, [url])
            let result = try f.run(e, p, progress: { _ in e.requestCancel(id: p.id) })
            try expect(result.state == .cancelled && f.exists(url) && !f.exists(p.operations[0].destination), "取消发生了移动")
        }
        try test("batch cancellation retains completed item for explicit rollback") {
            let f = try Fixture(); let a = try f.file("a"); let b = try f.file("b"); let e = try OFMoveEngine(directory: f.journal)
            let p = try f.validated(e, [a, b])
            let result = try f.run(e, p, progress: { current in if current.operations.first?.state == .moved { e.requestCancel(id: p.id) } })
            try expect(result.state == .cancelled && !f.exists(a) && f.exists(b), "批次取消边界错误")
            _ = try e.rollback(id: p.id, authorization: f.auth())
            try expect(f.exists(a) && f.exists(b), "取消后的原件未恢复")
        }
        for replacement in [false, true] {
            try test("rollback refuses \(replacement ? "replacement" : "edited") target") {
                let f = try Fixture(); let url = try f.file(); let e = try OFMoveEngine(directory: f.journal); let p = try f.validated(e, [url])
                let r = try f.run(e, p); let target = r.operations[0].destination
                if replacement { try f.fm.removeItem(at: target) }
                try Data("目标新资料".utf8).write(to: target, options: replacement ? .atomic : [])
                try expectThrows("回滚不应移动新目标") { _ = try e.rollback(id: p.id, authorization: f.auth()) }
                try expect(!f.exists(url) && (try f.content(target)) == "目标新资料", "回滚误改目标")
                try expect(e.plan(id: p.id)?.state == .needsRecovery, "冲突未进入恢复")
            }
        }
        try test("rollback source conflict never overwrites new source") {
            let f = try Fixture(); let url = try f.file(); let e = try OFMoveEngine(directory: f.journal); let p = try f.validated(e, [url]); let r = try f.run(e, p)
            try Data("source-new".utf8).write(to: url)
            try expectThrows("回滚来源冲突应拒绝") { _ = try e.rollback(id: p.id, authorization: f.auth()) }
            try expect(try f.content(url) == "source-new" && f.exists(r.operations[0].destination), "回滚覆盖来源新资料")
        }
        for point in [OFMoveFaultPoint.beforeRollback, .afterRollback] {
            try test("interrupted rollback \(point.rawValue) recovers idempotently") {
                let f = try Fixture(); let url = try f.file()
                var e: OFMoveEngine? = try OFMoveEngine(directory: f.journal, faultInjector: { injected, _, _ in if injected == point { throw OFMoveInjectedCrash() } })
                let p = try f.validated(e!, [url]); _ = try f.run(e!, p)
                try expectThrows("恢复故障应中断") { _ = try e!.rollback(id: p.id, authorization: f.auth()) }
                e = nil
                let restart = try OFMoveEngine(directory: f.journal)
                try expect(restart.plan(id: p.id)?.state == .needsRecovery, "恢复中断未标记")
                _ = try restart.rollback(id: p.id, authorization: f.auth())
                try expect(f.exists(url) && !f.exists(p.operations[0].destination), "恢复重试错误")
            }
        }
        try test("authorization boundary and changed root fail closed") {
            let f = try Fixture(); let auth = try f.auth(); let e = try OFMoveEngine(directory: f.journal)
            let outside = f.root.appendingPathComponent("outside"); try Data("outside".utf8).write(to: outside)
            try expectThrows("越权来源应拒绝") { _ = try e.create(sources: [outside], destination: f.target, authorization: auth) }
            let movedRoot = f.root.appendingPathComponent("old-root")
            try f.fm.moveItem(at: f.source, to: movedRoot); try f.fm.createDirectory(at: f.source, withIntermediateDirectories: false)
            let newFile = try f.file()
            try expectThrows("替换授权根应拒绝") { _ = try e.create(sources: [newFile], destination: f.target, authorization: auth) }
            try expect(f.exists(outside) && f.exists(newFile), "越权检查改变文件")
        }
        try test("unsupported directories, symlinks, hardlinks never mutate") {
            let f = try Fixture(); let url = try f.file(); let dir = f.source.appendingPathComponent("目录")
            try f.fm.createDirectory(at: dir, withIntermediateDirectories: false)
            let linkURL = f.source.appendingPathComponent("sym")
            try f.fm.createSymbolicLink(at: linkURL, withDestinationURL: url)
            let e = try OFMoveEngine(directory: f.journal)
            for input in [dir, linkURL] { try expectThrows("不支持类型应拒绝") { _ = try e.create(sources: [input], destination: f.target, authorization: f.auth()) } }
            let hard = f.source.appendingPathComponent("hard")
            try f.fm.linkItem(at: url, to: hard)
            try expectThrows("多重硬链接应拒绝") { _ = try e.create(sources: [url], destination: f.target, authorization: f.auth()) }
            try expect(f.exists(url) && f.exists(linkURL) && f.exists(hard) && f.exists(dir), "拒绝类型时改变文件")
        }
        for corrupt in ["missingLedger", "missingMarker", "missingAnchor", "missingDirectory", "badDigest", "futureVersion"] {
            try test("ledger integrity \(corrupt) fails closed") {
                let f = try Fixture(); let url = try f.file()
                var e: OFMoveEngine? = try OFMoveEngine(directory: f.journal); _ = try f.validated(e!, [url]); e = nil
                let ledger = f.journal.appendingPathComponent("ledger.json"); let marker = f.journal.appendingPathComponent("initialized.json")
                if corrupt == "missingLedger" { try f.fm.removeItem(at: ledger) }
                if corrupt == "missingMarker" { try f.fm.removeItem(at: marker) }
                if corrupt == "missingAnchor" { try f.fm.removeItem(at: f.root.appendingPathComponent("日志.initialized")) }
                if corrupt == "missingDirectory" { try f.fm.removeItem(at: f.journal) }
                if corrupt == "badDigest" { try Data("{broken".utf8).write(to: ledger) }
                if corrupt == "futureVersion" {
                    var json = try JSONSerialization.jsonObject(with: Data(contentsOf: marker)) as! [String: Any]
                    json["schemaVersion"] = 999
                    try JSONSerialization.data(withJSONObject: json).write(to: marker)
                }
                try expectThrows("坏日志应拒绝重建") { _ = try OFMoveEngine(directory: f.journal) }
                try expect(f.exists(url), "坏日志导致修改原件")
            }
        }
        try test("duplicate engine cannot concurrently access ledger") {
            let f = try Fixture(); let e = try OFMoveEngine(directory: f.journal)
            try expectThrows("并发日志进程应拒绝") { _ = try OFMoveEngine(directory: f.journal) }
            try expect(e.allPlans().isEmpty, "首实例日志异常")
        }
        try test("host-private data cannot be a physical destination or source") {
            let f = try Fixture(); let e = try OFMoveEngine(directory: f.journal)
            try f.fm.createDirectory(at: FileSafety.root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let plain = try f.file()
            let privateFile = FileSafety.root.appendingPathComponent("only-synthetic-private-" + UUID().uuidString + ".txt")
            let bytes = Data("保留恢复与索引资料".utf8); try bytes.write(to: privateFile)
            defer { try? f.fm.removeItem(at: privateFile) }
            let intoPrivate = try OFMoveAuthorization(sourceRoots: [f.source], destinationRoot: FileSafety.root)
            try expectThrows("私有目标必须拒绝") { _ = try e.create(sources: [plain], destination: FileSafety.root, authorization: intoPrivate) }
            let outOfPrivate = try OFMoveAuthorization(sourceRoots: [FileSafety.root], destinationRoot: f.target)
            try expectThrows("私有来源必须拒绝") { _ = try e.create(sources: [privateFile], destination: f.target, authorization: outOfPrivate) }
            try expect(f.exists(plain) && (try Data(contentsOf: privateFile)) == bytes, "私有边界拒绝时资料变化")
        }
        print("MOVE TESTS PASSED: \(count); synthetic files only; no app launch.")
    }
}
