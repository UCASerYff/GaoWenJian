// Organizer module port; source application is not a runtime dependency.
import AppKit
import UniformTypeIdentifiers
import Foundation

struct OFAssociationRecord: Codable, Identifiable {
    var id = UUID()
    var date = Date()
    let mode: String
    let identifier: String
    let previousApplication: URL?
    let requestedApplication: URL
    var actualApplication: URL?
    var status: String
    var detail: String
}
protocol OFAssociationSystem {
    func current(mode: String, identifier: String) throws -> URL?
    func candidates(mode: String, identifier: String) throws -> [URL]
    func set(application: URL, mode: String, identifier: String) async throws
}
struct OFWorkspaceAssociationSystem: OFAssociationSystem {
    func current(mode: String, identifier: String) throws -> URL? {
        if mode == "type" {
            guard let type = UTType(identifier), !type.isDynamic else { throw OFAppFailure("请输入已注册的 UTType，例如 public.jpeg。") }
            return NSWorkspace.shared.urlForApplication(toOpen: type)
        }
        guard identifier.range(of: "^[A-Za-z][A-Za-z0-9+.-]{0,63}$", options: .regularExpression) != nil, let url = URL(string: identifier + "://") else { throw OFAppFailure("URL scheme 无效。") }
        return NSWorkspace.shared.urlForApplication(toOpen: url)
    }
    func candidates(mode: String, identifier: String) throws -> [URL] {
        if mode == "type" {
            guard let type = UTType(identifier), !type.isDynamic else { throw OFAppFailure("文件类型未注册。") }
            return NSWorkspace.shared.urlsForApplications(toOpen: type)
        }
        _ = try current(mode: mode, identifier: identifier)
        return NSWorkspace.shared.urlsForApplications(toOpen: URL(string: identifier + "://")!)
    }
    func set(application: URL, mode: String, identifier: String) async throws {
        guard Bundle(url: application)?.bundleIdentifier != nil else { throw OFAppFailure("目标不是有效的已安装应用。") }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let done: @Sendable (Error?) -> Void = { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            }
            if mode == "type", let type = UTType(identifier) {
                NSWorkspace.shared.setDefaultApplication(at: application, toOpen: type, completion: done)
            } else if mode == "scheme" {
                NSWorkspace.shared.setDefaultApplication(at: application, toOpenURLsWithScheme: identifier, completion: done)
            } else { continuation.resume(throwing: OFAppFailure("不支持的关联范围。")) }
        }
    }
}

@MainActor final class OFAssociationController: ObservableObject {
    @Published var mode = "type"
    @Published var identifier = "public.plain-text"
    @Published var current: URL?
    @Published var candidates: [URL] = []
    @Published var selected: URL?
    @Published var history: [OFAssociationRecord] = []
    @Published var message = "读取类型后，查看当前应用和候选。提交前会再次确认作用范围。"
    @Published var busy = false
    private let document: OFProtectedDocument<[OFAssociationRecord]>
    private let system: OFAssociationSystem
    init(directory: URL, system: OFAssociationSystem = OFWorkspaceAssociationSystem()) throws {
        self.system = system
        document = OFProtectedDocument(directory: directory, name: "associations_history")
        history = try document.load(initial: [])
        // A crash during a system prompt must not replay a global mutation.
        if history.contains(where: { $0.status == "pending" }) {
            history = history.map { var r = $0; if r.status == "pending" { r.status = "interrupted"; r.detail = "上次请求中断，请先读取系统实际结果。" }; return r }
            try document.save(history)
        }
    }
    func refresh() {
        do {
            current = try system.current(mode: mode, identifier: identifier)
            candidates = try system.candidates(mode: mode, identifier: identifier)
            selected = current ?? candidates.first
            message = current == nil ? "系统没有返回默认应用。可选择候选，提交后仍以读回结果为准。" : "已读取系统实际默认应用。"
        } catch { message = error.localizedDescription; candidates = []; selected = nil }
    }
    func change(to app: URL) async -> Bool {
        guard !busy else { return false }; busy = true; defer { busy = false }
        let scopeMode = mode, scopeIdentifier = identifier
        do {
            let previous = try system.current(mode: scopeMode, identifier: scopeIdentifier)
            var record = OFAssociationRecord(mode: scopeMode, identifier: scopeIdentifier, previousApplication: previous, requestedApplication: app, status: "pending", detail: "等待系统完成并读回")
            history.insert(record, at: 0); try document.save(history)
            do {
                try await system.set(application: app, mode: scopeMode, identifier: scopeIdentifier)
                record.actualApplication = try system.current(mode: scopeMode, identifier: scopeIdentifier)
                let match = record.actualApplication?.standardizedFileURL == app.standardizedFileURL
                record.status = match ? "completed" : "failed"
                record.detail = match ? "系统读回与目标一致。" : "系统未采纳目标关联，请求发送不能视作成功。"
            } catch { record.status = "failed"; record.detail = error.localizedDescription; record.actualApplication = try? system.current(mode: scopeMode, identifier: scopeIdentifier) }
            if let i = history.firstIndex(where: { $0.id == record.id }) { history[i] = record }; try document.save(history)
            if mode == scopeMode && identifier == scopeIdentifier { current = record.actualApplication }
            message = record.detail
            return record.status == "completed"
        } catch { message = "关联账本无法写入，操作停止：" + error.localizedDescription; return false }
    }
    func restore(_ record: OFAssociationRecord) async -> Bool {
        guard let old = record.previousApplication, FileManager.default.fileExists(atPath: old.path) else { message = "旧应用已不存在，无法恢复。"; return false }
        mode = record.mode; identifier = record.identifier
        return await change(to: old)
    }
}
