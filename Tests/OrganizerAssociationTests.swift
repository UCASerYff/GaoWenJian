// Isolated Organizer module regression; compile/run only this @main entry point.
import Foundation
import AppKit

private struct AssociationTestFailure: Error, CustomStringConvertible { let description: String }
private func check(_ value: @autoclosure () throws -> Bool, _ message: String) throws {
    if try !value() { throw AssociationTestFailure(description: message) }
}
private func mustThrow(_ message: String, _ body: () throws -> Void) throws {
    do { try body() } catch { return }
    throw AssociationTestFailure(description: message)
}

/// No method in this fake reads or writes LaunchServices or NSWorkspace.
private final class FakeAssociationSystem: OFAssociationSystem {
    enum Behavior { case apply, noOp, rejected }
    var behavior = Behavior.apply
    var defaults: [String: URL] = [:]
    var installed: [URL] = []
    var requests: [(URL, String, String)] = []
    var reads: [(String, String)] = []
    var rejectReadback = false
    var onSet: (() throws -> Void)?
    func key(_ mode: String, _ identifier: String) -> String { mode + ":" + identifier }
    func current(mode: String, identifier: String) throws -> URL? {
        reads.append((mode, identifier))
        if rejectReadback && !requests.isEmpty { throw OFAppFailure("合成读回失败") }
        return defaults[key(mode, identifier)]
    }
    func candidates(mode: String, identifier: String) throws -> [URL] { installed }
    func set(application: URL, mode: String, identifier: String) async throws {
        try onSet?()
        requests.append((application, mode, identifier))
        switch behavior {
        case .apply: defaults[key(mode, identifier)] = application
        case .noOp: break
        case .rejected: throw OFAppFailure("合成系统拒绝")
        }
    }
}

private final class AssociationFixture {
    let root = URL(fileURLWithPath: "/private/tmp/GaoWenJian-OrganizerAssociationTests-" + UUID().uuidString + ".noindex")
    var old: URL { root.appendingPathComponent("旧应用.app") }
    var new: URL { root.appendingPathComponent("新应用.app") }
    init() throws { try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]) }
    deinit { try? FileManager.default.removeItem(at: root) }
    func fake() -> FakeAssociationSystem {
        let system = FakeAssociationSystem()
        system.defaults[system.key("type", "public.plain-text")] = old
        system.installed = [old, new]
        return system
    }
    func history() throws -> [OFAssociationRecord] { try OFProtectedDocument<[OFAssociationRecord]>(directory: root, name: "associations_history").load(initial: []) }
    func makeOldAppAvailable() throws { try FileManager.default.createDirectory(at: old, withIntermediateDirectories: true) }
}

@main @MainActor struct OrganizerAssociationTests {
    static func main() async throws {
        var count = 0
        func test(_ title: String, _ body: @MainActor () async throws -> Void) async throws {
            try await body(); count += 1; print("PASS \(title)")
        }
        try await test("refresh uses fake current/candidates without global mutation") {
            let f = try AssociationFixture(); let system = f.fake()
            let controller = try OFAssociationController(directory: f.root, system: system)
            controller.refresh()
            try check(controller.current == f.old && controller.selected == f.old && controller.candidates.count == 2, "候选或当前关联错误")
            try check(system.requests.isEmpty && controller.history.isEmpty, "刷新修改了默认关联")
        }
        try await test("pending record precedes mutation; success requires persisted readback") {
            let f = try AssociationFixture(); let system = f.fake()
            let controller = try OFAssociationController(directory: f.root, system: system)
            system.onSet = {
                let disk = try f.history()
                try check(disk.count == 1 && disk[0].status == "pending" && disk[0].previousApplication == f.old, "执行前没有持久化 pending／旧值")
            }
            let success = await controller.change(to: f.new)
            try check(success && system.requests.count == 1, "成功操作未完成")
            let disk = try f.history()
            try check(disk[0].status == "completed" && disk[0].actualApplication == f.new && disk[0].requestedApplication == f.new, "未持久化真实读回值")
        }
        try await test("system rejection fails and retains old actual association") {
            let f = try AssociationFixture(); let system = f.fake(); system.behavior = .rejected
            let controller = try OFAssociationController(directory: f.root, system: system)
            let success = await controller.change(to: f.new)
            let record = try f.history()[0]
            try check(!success && record.status == "failed" && record.actualApplication == f.old, "拒绝被标记成功")
            try check(system.defaults[system.key("type", "public.plain-text")] == f.old, "拒绝后旧值变化")
        }
        try await test("silent system no-op cannot be promoted to completed") {
            let f = try AssociationFixture(); let system = f.fake(); system.behavior = .noOp
            let controller = try OFAssociationController(directory: f.root, system: system)
            let success = await controller.change(to: f.new)
            let record = try f.history()[0]
            try check(!success && record.status == "failed" && record.actualApplication == f.old, "请求回调被误认为修改成功")
        }
        try await test("readback failure cannot be promoted to completed") {
            let f = try AssociationFixture(); let system = f.fake(); system.rejectReadback = true
            let controller = try OFAssociationController(directory: f.root, system: system)
            let success = await controller.change(to: f.new)
            let record = try f.history()[0]
            try check(!success && record.status == "failed" && record.actualApplication == nil, "无法读回仍被标成功")
            try check(system.requests.count == 1, "读回失败重放了请求")
        }
        try await test("pending ledger recovery records interrupted and never reexecutes") {
            let f = try AssociationFixture(); let system = f.fake()
            let pending = OFAssociationRecord(mode: "type", identifier: "public.jpeg", previousApplication: f.old, requestedApplication: f.new, status: "pending", detail: "合成中断")
            let doc = OFProtectedDocument<[OFAssociationRecord]>(directory: f.root, name: "associations_history")
            _ = try doc.load(initial: [pending])
            let recovered = try OFAssociationController(directory: f.root, system: system)
            try check(recovered.history.count == 1 && recovered.history[0].id == pending.id && recovered.history[0].status == "interrupted", "恢复状态错误")
            try check(try f.history()[0].status == "interrupted", "中断状态未落盘")
            _ = try OFAssociationController(directory: f.root, system: system)
            try check(system.requests.isEmpty, "冷启动重放了系统修改")
        }
        try await test("restore missing old application does not call setter") {
            let f = try AssociationFixture(); let system = f.fake()
            let controller = try OFAssociationController(directory: f.root, system: system)
            let record = OFAssociationRecord(mode: "scheme", identifier: "gaosynthetic", previousApplication: f.old, requestedApplication: f.new, status: "completed", detail: "合成记录")
            let success = await controller.restore(record)
            try check(!success && system.requests.isEmpty && controller.history.isEmpty, "旧应用缺失仍请求恢复")
        }
        try await test("restore available old application preserves original mode/scope and verifies readback") {
            let f = try AssociationFixture(); try f.makeOldAppAvailable(); let system = f.fake()
            system.defaults[system.key("scheme", "gaosynthetic")] = f.new
            let controller = try OFAssociationController(directory: f.root, system: system)
            let original = OFAssociationRecord(mode: "scheme", identifier: "gaosynthetic", previousApplication: f.old, requestedApplication: f.new, status: "completed", detail: "合成记录")
            let success = await controller.restore(original)
            let request = system.requests[0]; let record = try f.history()[0]
            try check(success && request.0 == f.old && request.1 == "scheme" && request.2 == "gaosynthetic", "恢复作用范围错误")
            try check(record.actualApplication == f.old && record.status == "completed" && record.previousApplication == f.new, "恢复未保存真实结果")
        }
        try await test("ledger write rejection prevents the system request") {
            let f = try AssociationFixture(); let system = f.fake()
            let controller = try OFAssociationController(directory: f.root, system: system)
            let url = f.root.appendingPathComponent("associations_history.json")
            try FileManager.default.removeItem(at: url)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
            let success = await controller.change(to: f.new)
            try check(!success && system.requests.isEmpty, "写日志失败仍修改默认关联")
        }
        for fault in ["missing", "markerMissing", "badJSON", "badDigest", "futureEnvelope"] {
            try await test("configuration startup \(fault) preserves evidence and fails closed") {
                let f = try AssociationFixture(); let doc = OFProtectedDocument<OFLibraryConfiguration>(directory: f.root, name: "configuration")
                var initial = OFLibraryConfiguration(); initial.appearance = "dark"
                _ = try doc.load(initial: initial)
                if fault == "missing" { try FileManager.default.removeItem(at: doc.url) }
                if fault == "markerMissing" { try FileManager.default.removeItem(at: f.root.appendingPathComponent("configuration.initialized")) }
                if fault == "badJSON" { try Data("{合成损坏".utf8).write(to: doc.url) }
                if fault == "badDigest" || fault == "futureEnvelope" {
                    var envelope = try JSONSerialization.jsonObject(with: Data(contentsOf: doc.url)) as! [String: Any]
                    if fault == "badDigest" { envelope["sha256"] = String(repeating: "0", count: 64) }
                    else { envelope["schemaVersion"] = 999 }
                    try JSONSerialization.data(withJSONObject: envelope).write(to: doc.url)
                }
                let before = try? Data(contentsOf: doc.url)
                try mustThrow("配置损坏／缺失仍加载为空白") { _ = try OFProtectedDocument<OFLibraryConfiguration>(directory: f.root, name: "configuration").load(initial: OFLibraryConfiguration()) }
                try check((try? Data(contentsOf: doc.url)) == before, "失败后改写了恢复依据")
            }
        }
        try await test("configuration genuine first initialization roundtrips user values") {
            let f = try AssociationFixture(); let doc = OFProtectedDocument<OFLibraryConfiguration>(directory: f.root, name: "configuration")
            var original = OFLibraryConfiguration(); original.appearance = "dark"; original.automaticMonitoring = false
            original.workspaces = [OFVirtualWorkspace(name: "原创测试工作区")]
            _ = try doc.load(initial: original)
            let read = try OFProtectedDocument<OFLibraryConfiguration>(directory: f.root, name: "configuration").load(initial: OFLibraryConfiguration())
            try check(read.appearance == "dark" && !read.automaticMonitoring && read.workspaces[0].name == "原创测试工作区", "重载丢失配置")
        }
        for fault in ["deleted", "corrupt", "futureEnvelope", "validExternalEdit"] {
            try await test("configuration runtime \(fault) rejects save and preserves existing evidence") {
                let f = try AssociationFixture()
                let doc = OFProtectedDocument<OFLibraryConfiguration>(directory: f.root, name: "configuration")
                var original = OFLibraryConfiguration(); original.appearance = "dark"
                _ = try doc.load(initial: original)
                if fault == "deleted" { try FileManager.default.removeItem(at: doc.url) }
                if fault == "corrupt" { try Data("合成运行时损坏".utf8).write(to: doc.url) }
                if fault == "futureEnvelope" {
                    var envelope = try JSONSerialization.jsonObject(with: Data(contentsOf: doc.url)) as! [String: Any]
                    envelope["schemaVersion"] = 999
                    try JSONSerialization.data(withJSONObject: envelope).write(to: doc.url)
                }
                if fault == "validExternalEdit" {
                    let external = OFProtectedDocument<OFLibraryConfiguration>(directory: f.root, name: "configuration")
                    var later = try external.load(initial: OFLibraryConfiguration())
                    later.appearance = "light"; later.workspaces = [OFVirtualWorkspace(name: "后来保存的配置")]
                    try external.save(later)
                }
                let before = try? Data(contentsOf: doc.url)
                let marker = f.root.appendingPathComponent("configuration.initialized")
                let markerBefore = try Data(contentsOf: marker)
                var proposed = original; proposed.appearance = "system"
                try mustThrow("运行时资料变化仍允许旧对象写回") { try doc.save(proposed) }
                try check((try? Data(contentsOf: doc.url)) == before, "拒绝保存时改写／重建了资料")
                try check(try Data(contentsOf: marker) == markerBefore, "拒绝保存时改写了初始化依据")
                if fault == "validExternalEdit" {
                    let read = try OFProtectedDocument<OFLibraryConfiguration>(directory: f.root, name: "configuration").load(initial: OFLibraryConfiguration())
                    try check(read.appearance == "light" && read.workspaces.first?.name == "后来保存的配置", "覆盖了后来保存的有效资料")
                }
            }
        }
        for fault in ["missing", "corrupt", "future"] {
            try await test("association ledger startup \(fault) never calls system setter") {
                let f = try AssociationFixture(); let system = f.fake()
                _ = try OFAssociationController(directory: f.root, system: system)
                let url = f.root.appendingPathComponent("associations_history.json")
                if fault == "missing" { try FileManager.default.removeItem(at: url) }
                if fault == "corrupt" { try Data("corrupt".utf8).write(to: url) }
                if fault == "future" {
                    var envelope = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
                    envelope["schemaVersion"] = 999
                    try JSONSerialization.data(withJSONObject: envelope).write(to: url)
                }
                try mustThrow("坏关联账本仍初始化") { _ = try OFAssociationController(directory: f.root, system: system) }
                try check(system.requests.isEmpty, "坏关联账本触发系统修改")
            }
        }
        try await test("corrupt configuration initialization marker rejects load and runtime save") {
            let f = try AssociationFixture()
            let doc = OFProtectedDocument<OFLibraryConfiguration>(directory: f.root, name: "configuration")
            _ = try doc.load(initial: OFLibraryConfiguration())
            let marker = f.root.appendingPathComponent("configuration.initialized")
            try Data("corrupt marker".utf8).write(to: marker)
            let original = try Data(contentsOf: doc.url)
            try mustThrow("坏初始化记录仍允许加载") { _ = try OFProtectedDocument<OFLibraryConfiguration>(directory: f.root, name: "configuration").load(initial: OFLibraryConfiguration()) }
            try mustThrow("坏初始化记录仍允许保存") { try doc.save(OFLibraryConfiguration()) }
            try check(try Data(contentsOf: doc.url) == original, "坏初始化记录导致原文覆盖")
        }
        print("ASSOCIATION/CONFIG TESTS PASSED: \(count); fake adapter only; no real default changed; no app launch.")
    }
}
