// Organizer module port; source application is not a runtime dependency.
import SwiftUI
import AppKit
import UniformTypeIdentifiers
import CryptoKit

final class OFCancellationFlag: @unchecked Sendable {
    private let lock = NSLock(); private var stopped = false
    func cancel() { lock.lock(); stopped = true; lock.unlock() }
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return stopped }
}

enum OFAppSection: Hashable { case search, favorites, roots, associations, moves, settings, workspace(UUID) }

@MainActor final class OFAppModel: ObservableObject {
    @Published var config = OFLibraryConfiguration()
    @Published var section: OFAppSection = .search
    @Published var roots: [OFIndexRoot] = []
    @Published var filter = OFSearchFilter()
    @Published var result = OFSearchPage(files: [], totalCount: 0, page: 0, pageSize: 100)
    @Published var selection = Set<String>()
    @Published var page = 0
    @Published var searching = false
    @Published var scanMessage = "尚未添加授权目录"
    @Published var scanning = false
    @Published var status = ""
    @Published var fatalError: String?
    @Published var movePlan: OFMovePlan?
    @Published var moveHistory: [OFMovePlan] = []
    @Published var moving = false
    @Published var incomingScopeNote = ""
    @Published var dataRevision = UUID()
    var index: OFIndexStore?
    var associations: OFAssociationController?
    var mover: OFMoveEngine?
    var directory: URL?
    private var configDocument: OFProtectedDocument<OFLibraryConfiguration>?
    private var scanFlag: OFCancellationFlag?
    private var searchTask: Task<Void, Never>?
    private var searchGeneration = UUID()
    private var monitor: OFIndexMonitor?
    private var backgroundObserver: NSObjectProtocol?
    private var pendingScanRoots = Set<UUID>()
    private var moveAuthorization: OFMoveAuthorization?
    private var moveLeases: [OFIndexAccessLease] = []
    private var destinationScope: URL?
    private var ownsRootLock = false

    private let openDocument: @MainActor (URL) throws -> Void
    var validateMoveSources: (([URL]) throws -> Void)?
    private var wakeObserver: NSObjectProtocol?
    @Published private(set) var hasPendingAssociation = false
    private var associationCompletion: (@MainActor (OrganizerProviderResult) -> Void)?
    private var associationRequestedUTI: String?

    init(openDocument: @escaping @MainActor (URL) throws -> Void) {
        self.openDocument = openDocument
        do {
            let dir = try OFAppLocations.prepare(); directory = dir; ownsRootLock = true
            let doc = OFProtectedDocument<OFLibraryConfiguration>(directory: dir, name: "configuration")
            config = try doc.load(initial: OFLibraryConfiguration()); guard config.schemaVersion == 1 else { throw OFAppFailure("工作区资料格式过新，停止写入。") }; configDocument = doc
            index = try OFIndexStore(directory: dir)
            associations = try OFAssociationController(directory: dir)
            mover = try OFMoveEngine(directory: dir.appendingPathComponent("MovePlans", isDirectory: true))
            moveHistory = mover?.allPlans() ?? []
            try OFAppLocations.markInitialized()
            refreshRoots(); configureMonitor()
            for root in roots where !root.isPaused && root.status != "needsAuthorization" { queueScan(root.id) }
            wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in guard let self else { return }; for root in self.roots where !root.isPaused { self.queueScan(root.id) } }
            }
            backgroundObserver = NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.shutdown() }
            }
            refreshSearch()
        } catch {
            fatalError = error.localizedDescription
            if ownsRootLock { index = nil; associations = nil; mover = nil; OFAppLocations.release(); ownsRootLock = false }
        }
    }
    deinit {
        if let backgroundObserver { NotificationCenter.default.removeObserver(backgroundObserver) }
        if let wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver) }
        if ownsRootLock { OFAppLocations.release() }
    }
    var hasActiveOperation: Bool { moving || scanning || associations?.busy == true }
    func shutdown() { pendingScanRoots.removeAll(); scanFlag?.cancel(); monitor?.stop(); searchTask?.cancel(); if let id = movePlan?.id { mover?.requestCancel(id: id) }; if !moving { releaseMoveScopes() } }
    func saveConfig() {
        guard fatalError == nil else { return }
        do { try configDocument?.save(config); dataRevision = UUID() } catch { fatalError = error.localizedDescription }
    }
    func refreshRoots() { do { roots = try index?.roots() ?? [] } catch { status = error.localizedDescription } }
    func configureMonitor() {
        monitor?.stop()
        guard config.automaticMonitoring, let index else { return }
        // Every event is advisory. The monitor requests a bounded, debounced reconciliation.
        monitor = OFIndexMonitor(store: index) { [weak self] rootID in
            Task { @MainActor in self?.queueScan(rootID) }
        }
        do { try monitor?.start() } catch { status = error.localizedDescription }
    }
    func addRoot(suggested: URL? = nil) {
        guard fatalError == nil, !moving, let index else { return }
        let panel = NSOpenPanel(); panel.title = "选择要索引的目录"; panel.message = "只读取所选范围的元数据；不读取正文、不搬动原文件。"; panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = true; panel.directoryURL = suggested
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            do { let root = try index.addRoot(url: url); refreshRoots(); queueScan(root.id) } catch { status = error.localizedDescription }
        }
        refreshRoots(); configureMonitor()
    }
    func queueScan(_ id: UUID) {
        guard let root = roots.first(where: { $0.id == id }), !root.isPaused, root.status != "needsAuthorization" else { status = "目录尚未重新授权或已暂停，请先通过系统面板选择同一目录。"; return }
        pendingScanRoots.insert(id)
        startNextScan()
    }
    private func startNextScan() {
        guard !scanning, !moving, let id = pendingScanRoots.first, let index, fatalError == nil else { return }
        pendingScanRoots.remove(id); scanning = true
        let flag = OFCancellationFlag(); scanFlag = flag
        scanMessage = "正在扫描授权目录…"
        Task {
            do {
                let report = try await Task.detached(priority: .utility) {
                    try index.scan(rootID: id, cancel: { flag.isCancelled }, progress: { progress in
                        Task { @MainActor [weak self = self] in self?.scanMessage = "已索引 \(progress.indexedCount) 项 · 待扫描目录 \(progress.pendingDirectories)" }
                    })
                }.value
                scanMessage = "\(report.completed ? "扫描完成" : "已保留检查点") · \(report.indexedCount) 项 · \(String(format: "%.2f", report.elapsed)) 秒"
                if let diagnostic = report.diagnostic { status = diagnostic }
            } catch { scanMessage = error.localizedDescription }
            scanning = false; scanFlag = nil; refreshRoots(); dataRevision = UUID(); refreshSearch(resetPage: false); startNextScan()
        }
    }
    func restartScan(_ root: OFIndexRoot) {
        guard !scanning else { status = "请先取消当前扫描。"; return }
        do { try index?.discardScanCheckpoint(rootID: root.id); queueScan(root.id) } catch { status = error.localizedDescription }
    }
    func cancelScan() { pendingScanRoots.removeAll(); scanFlag?.cancel() }
    func pause(_ root: OFIndexRoot) {
        guard !moving else { return }
        do { try index?.setPaused(rootID: root.id, paused: !root.isPaused); refreshRoots(); configureMonitor() } catch { status = error.localizedDescription }
    }
    func removeRoot(_ root: OFIndexRoot) {
        guard !hasActiveOperation else { status = "请先结束当前扫描、整理或关联操作。"; return }
        guard ofConfirm(title: "移除目录索引？", message: "仅删除“\(root.displayName)”的索引授权和配置引用，原文件不变。", action: "移除索引") else { return }
        do {
            try index?.removeRoot(id: root.id)
            for w in config.workspaces.indices { config.workspaces[w].panels.removeAll { $0.rootID == root.id } }
            config.savedQueries.removeAll { $0.rootID == root.id }
            if filter.rootID == root.id { filter.rootID = nil }
            saveConfig(); refreshRoots(); configureMonitor(); refreshSearch()
        } catch { status = error.localizedDescription }
    }
    func refreshSearch(resetPage: Bool = true) {
        if resetPage { page = 0 }
        searchTask?.cancel(); let generation = UUID(); searchGeneration = generation
        guard let index, fatalError == nil else { return }
        var f = filter; if section == .favorites { f.favoritesOnly = true }
        let requestedPage = page
        searching = true
        searchTask = Task {
            do {
                try await Task.sleep(nanoseconds: 220_000_000)
                try Task.checkCancellation()
                let found = try await Task.detached(priority: .userInitiated) { try index.search(f, page: requestedPage, pageSize: 100) }.value
                guard !Task.isCancelled, searchGeneration == generation else { return }
                result = found; selection.formIntersection(Set(found.files.map(\.id))); searching = false
            } catch is CancellationError { } catch { guard searchGeneration == generation else { return }; status = error.localizedDescription; searching = false }
        }
    }
    var selectedFiles: [OFIndexedFile] { result.files.filter { selection.contains($0.id) } }
    func action(_ file: OFIndexedFile, allowSymbolicLink: Bool = false, _ body: (URL) throws -> Void) {
        do { try index?.withVerifiedURL(for: file, allowSymbolicLink: allowSymbolicLink, body: body) } catch { status = error.localizedDescription }
    }
    func openFile(_ file: OFIndexedFile) {
        action(file) { url in
            if file.isCloudPlaceholder, !ofConfirm(title: "打开云端文件？", message: "此文件尚未完全下载。继续打开可能由系统下载内容。", action: "继续打开") { return }
            try openDocument(url)
        }
    }
    func openSelected() { selectedFiles.forEach(openFile) }
    func revealSelected() { selectedFiles.forEach { file in action(file, allowSymbolicLink: true) { NSWorkspace.shared.activateFileViewerSelecting([$0]) } } }
    func copySelectedPaths() {
        do {
            let urls = try selectedFiles.map { try index!.verifiedURL(for: $0, allowSymbolicLink: true) }
            guard !urls.isEmpty else { return }
            NSPasteboard.general.clearContents(); NSPasteboard.general.setString(urls.map(\.path).joined(separator: "\n"), forType: .string)
            status = "已复制 \(urls.count) 个核对后的路径"
        } catch { status = error.localizedDescription }
    }
    func favorite(_ file: OFIndexedFile) {
        do { try index?.updateAnnotations(fileID: file.id, tags: file.userTags, favorite: !file.favorite); refreshSearch(resetPage: false); dataRevision = UUID() } catch { status = error.localizedDescription }
    }
    func tag(_ file: OFIndexedFile) {
        guard let text = ofAskText(title: "应用内标签", message: "用逗号分隔，仅修改搞文件整理索引，不改 Finder 标签。", initial: file.userTags.joined(separator: ", ")) else { return }
        let tags = text.components(separatedBy: CharacterSet(charactersIn: ",，")).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        do { try index?.updateAnnotations(fileID: file.id, tags: tags, favorite: file.favorite); refreshSearch(resetPage: false); dataRevision = UUID() } catch { status = error.localizedDescription }
    }
    func createWorkspace() {
        guard let name = ofAskText(title: "新建虚拟工作区", message: "工作区组合目录、查询和收藏；不会移动原件。") else { return }
        let workspace = OFVirtualWorkspace(name: name); config.workspaces.append(workspace); saveConfig(); section = .workspace(workspace.id)
    }
    func renameWorkspace(_ id: UUID) {
        guard let i = config.workspaces.firstIndex(where: { $0.id == id }), let name = ofAskText(title: "工作区名称", message: "", initial: config.workspaces[i].name) else { return }
        config.workspaces[i].name = name; saveConfig()
    }
    func removeWorkspace(_ id: UUID) {
        guard ofConfirm(title: "删除工作区？", message: "只删除此工作区和面板配置，原件、索引和收藏保留。", action: "删除配置") else { return }
        config.workspaces.removeAll { $0.id == id }; saveConfig(); section = .search
    }
    func addPanel(workspaceID: UUID, kind: String, root: OFIndexRoot? = nil) {
        guard let i = config.workspaces.firstIndex(where: { $0.id == workspaceID }) else { return }
        let defaultName = root?.displayName ?? (kind == "favorites" ? "收藏" : (filter.query.isEmpty ? "已保存查询" : filter.query))
        guard let name = ofAskText(title: "添加虚拟面板", message: "面板只保存引用和查询条件。", initial: defaultName) else { return }
        config.workspaces[i].panels.append(OFVirtualPanel(name: name, kind: kind, rootID: root?.id ?? filter.rootID, query: kind == "directory" ? "" : filter.query, extensionName: filter.extensionName, sort: filter.sort.rawValue, ascending: filter.ascending, filter: filter))
        saveConfig()
    }
    func editPanel(workspaceID: UUID, panelID: UUID, action: (inout OFVirtualPanel) -> Void) {
        guard let w = config.workspaces.firstIndex(where: { $0.id == workspaceID }), let p = config.workspaces[w].panels.firstIndex(where: { $0.id == panelID }) else { return }
        action(&config.workspaces[w].panels[p]); saveConfig()
    }
    func movePanel(workspaceID: UUID, panelID: UUID, direction: Int) {
        guard let w = config.workspaces.firstIndex(where: { $0.id == workspaceID }), let p = config.workspaces[w].panels.firstIndex(where: { $0.id == panelID }) else { return }
        let to = p + direction; guard config.workspaces[w].panels.indices.contains(to) else { return }
        config.workspaces[w].panels.swapAt(p, to); saveConfig()
    }
    func removePanel(workspaceID: UUID, panelID: UUID) {
        guard let i = config.workspaces.firstIndex(where: { $0.id == workspaceID }) else { return }
        config.workspaces[i].panels.removeAll { $0.id == panelID }; saveConfig()
    }
    func saveQuery() {
        guard let name = ofAskText(title: "保存当前查询", message: "保存筛选、排序和授权范围。", initial: filter.query) else { return }
        let f = filter
        config.savedQueries.append(OFSavedQuery(name: name, query: f.query, rootID: f.rootID, extensionName: f.extensionName, pathContains: f.pathContains, typeIdentifier: f.typeIdentifier, kind: f.kind.rawValue, minSize: f.minSize, maxSize: f.maxSize, modifiedAfter: f.modifiedAfter, modifiedBefore: f.modifiedBefore, sort: f.sort.rawValue, ascending: f.ascending, filter: f)); saveConfig()
    }
    func applyQuery(_ query: OFSavedQuery) {
        filter = OFSearchFilter(query: query.query, rootID: query.rootID, extensionName: query.extensionName, typeIdentifier: query.typeIdentifier, pathContains: query.pathContains, minSize: query.minSize, maxSize: query.maxSize, modifiedAfter: query.modifiedAfter, modifiedBefore: query.modifiedBefore, kind: OFSearchKind(rawValue: query.kind) ?? .all, sort: OFSearchSort(rawValue: query.sort) ?? .name, ascending: query.ascending)
        if let completeFilter = query.filter { filter = completeFilter }
        section = .search; refreshSearch()
    }
    func acquireSelected(_ files: [OFIndexedFile]) throws -> ([URL], [OFIndexAccessLease]) {
        guard let index else { throw OFAppFailure("索引不可用") }
        let leases = try Set(files.map(\.rootID)).map { try index.accessLease(rootID: $0) }
        do { return (try files.map { try index.verifiedURL(for: $0) }, leases) }
        catch { leases.forEach { $0.release() }; throw error }
    }
    func previewMove(rename: Bool = false) async {
        guard !moving, !scanning, !selectedFiles.isEmpty else { return }
        do {
            releaseMoveScopes()
            let (urls, leases) = try acquireSelected(selectedFiles); moveLeases = leases
            guard let validateMoveSources else { throw OFAppFailure("宿主文档保护尚未就绪，已停止物理整理。") }
            try validateMoveSources(urls)
            var name: String? = nil
            let destination: URL
            if rename {
                guard urls.count == 1 else { throw OFAppFailure("重命名一次请选择一个文件。") }
                guard let value = ofAskText(title: "重命名预览", message: "只支持同卷普通文件，不覆盖任何同名目标。", initial: urls[0].lastPathComponent) else { releaseMoveScopes(); return }
                name = value; destination = urls[0].deletingLastPathComponent()
            } else {
                let p = NSOpenPanel(); p.title = "选择物理移动目标"; p.message = "下一步先生成计划，不会立即移动。V1 仅支持同卷普通文件。"; p.canChooseDirectories = true; p.canChooseFiles = false
                guard p.runModal() == .OK, let value = p.url else { releaseMoveScopes(); return }
                destination = value; if value.startAccessingSecurityScopedResource() { destinationScope = value }
            }
            let authorization = try OFMoveAuthorization(sourceRoots: moveLeases.map(\.url), destinationRoot: destination)
            moveAuthorization = authorization
            guard let mover else { throw OFAppFailure("移动引擎不可用") }
            moving = true
            let plan = try await Task.detached { let p = try mover.create(sources: urls, destination: destination, rename: name, authorization: authorization); return try mover.validate(p, authorization: authorization) }.value
            movePlan = plan; moving = false; section = .moves; refreshMoveHistory()
        } catch { moving = false; releaseMoveScopes(); refreshMoveHistory(); status = error.localizedDescription }
    }
    func executeMove() async {
        guard let mover, let plan = movePlan, let auth = moveAuthorization, !moving else { return }
        guard ofConfirm(title: "执行物理整理？", message: "计划含 \(plan.operations.count) 个普通文件。原件位置会变化。无覆盖；每项独立提交，批次并非整体原子操作。", action: "执行计划") else { return }
        do {
            guard let validateMoveSources else { throw OFAppFailure("宿主文档保护尚未就绪。") }
            try validateMoveSources(plan.operations.flatMap { [$0.source, $0.destination] })
        } catch { status = error.localizedDescription; return }
        moving = true
        do {
            let updated = try await Task.detached { try mover.execute(id: plan.id, confirmation: OFMoveConfirmation(planID: plan.id, revision: plan.revision), authorization: auth, progress: { p in Task { @MainActor [weak self = self] in self?.movePlan = p } }) }.value
            movePlan = updated; status = "计划状态：\(updated.state.rawValue)"
            for root in roots where !root.isPaused && root.status != "needsAuthorization" { queueScan(root.id) }
        } catch { status = error.localizedDescription; movePlan = mover.plan(id: plan.id) }
        moving = false; refreshMoveHistory(); releaseMoveScopes(); startNextScan()
    }
    func refreshMoveHistory() { moveHistory = mover?.allPlans() ?? [] }
    func cancelMove() {
        guard let plan = movePlan else { return }
        mover?.requestCancel(id: plan.id)
        if moving { status = "已请求取消，等待当前安全步骤结束。"; return }
        do { _ = try mover?.cancel(id: plan.id); refreshMoveHistory(); movePlan = nil; releaseMoveScopes() } catch { status = error.localizedDescription }
    }
    func releaseMoveScopes() { moveLeases.forEach { $0.release() }; moveLeases = []; destinationScope?.stopAccessingSecurityScopedResource(); destinationScope = nil; moveAuthorization = nil }
}

extension OFAppModel {
    func rollbackMove(_ plan: OFMovePlan) async {
        guard !moving, let mover else { return }
        guard ofConfirm(title: "恢复原位置", message: "重新选择原位置所在的授权目录和目标目录。只有目标仍是本计划产生的同一对象且原位置没有新资料时才恢复；冲突会停止。", action: "继续授权") else { return }
        let sources = NSOpenPanel(); sources.title = "选择原来源所在目录（可多选）"; sources.canChooseFiles = false; sources.canChooseDirectories = true; sources.allowsMultipleSelection = true; sources.directoryURL = plan.operations.first?.source.deletingLastPathComponent()
        guard sources.runModal() == .OK else { return }
        let targets = NSOpenPanel(); targets.title = "选择原计划目标目录"; targets.canChooseFiles = false; targets.canChooseDirectories = true; targets.directoryURL = plan.operations.first?.destination.deletingLastPathComponent()
        guard targets.runModal() == .OK, let target = targets.url else { return }
        let scoped = (sources.urls + [target]).filter { $0.startAccessingSecurityScopedResource() }
        defer { scoped.forEach { $0.stopAccessingSecurityScopedResource() } }
        moving = true; defer { moving = false; refreshMoveHistory(); startNextScan() }
        do {
            guard let validateMoveSources else { throw OFAppFailure("宿主文档保护尚未就绪。") }
            try validateMoveSources(plan.operations.flatMap { [$0.source, $0.destination] })
            let auth = try OFMoveAuthorization(sourceRoots: sources.urls, destinationRoot: target)
            let restored = try await Task.detached { try mover.rollback(id: plan.id, authorization: auth) }.value
            movePlan = restored; status = "恢复状态：\(restored.state.rawValue)"
            for root in roots where !root.isPaused && root.status != "needsAuthorization" { queueScan(root.id) }
        } catch { status = error.localizedDescription }
    }
}


extension OFAppModel {
    /// A bounded metadata query; leases remain alive through the provider's explicit review/send.
    func providerSearch(query: String, scope: URL?) throws -> OrganizerSearchLease {
        guard fatalError == nil, let index else { throw OFAppFailure("文件索引当前不可用。") }
        var filter = OFSearchFilter(query: query)
        var scopedRootID: UUID?
        var leases: [OFIndexAccessLease] = []
        do {
            if let scope {
                let wanted = scope.standardizedFileURL
                // The narrowest authorized matching root supplies the boundary.
                for root in try index.roots().sorted(by: { $0.path.count > $1.path.count }) {
                    guard root.status != "needsAuthorization", !root.isPaused,
                          wanted.path == root.path || wanted.path.hasPrefix(root.path + "/") else { continue }
                    let lease = try index.accessLease(rootID: root.id)
                    let base = lease.url.standardizedFileURL.path
                    guard wanted.path == base || wanted.path.hasPrefix(base + "/") else { lease.release(); continue }
                    scopedRootID = root.id; filter.rootID = root.id
                    filter.folder = wanted.path == base ? "" : String(wanted.path.dropFirst(base.count + 1))
                    leases.append(lease); break
                }
                guard scopedRootID != nil else { throw OFAppFailure("请求范围尚无当前授权索引；请重新授权该目录。") }
            }
            let currentRoots = Dictionary(uniqueKeysWithValues: try index.roots().map { ($0.id, $0) })
            let page = try index.search(filter, page: 0, pageSize: 100)
            var urls: [URL] = []
            var heldRootIDs = Set(leases.isEmpty ? [] : [scopedRootID!])
            for file in page.files where !file.isDirectory && !file.isSymbolicLink && !file.isCloudPlaceholder {
                guard let root = currentRoots[file.rootID], !root.isPaused, root.status != "needsAuthorization" else { throw OFAppFailure("索引命中目录已暂停或尚未重新授权。") }
                if !heldRootIDs.contains(file.rootID) {
                    // A migrated or unavailable root is never silently authorized by an index hit.
                    let lease = try index.accessLease(rootID: file.rootID)
                    leases.append(lease); heldRootIDs.insert(file.rootID)
                }
                urls.append(try index.verifiedURL(for: file))
            }
            let retained = leases
            return OrganizerSearchLease(urls: urls, release: { retained.forEach { $0.release() } })
        } catch { leases.forEach { $0.release() }; throw error }
    }
    @discardableResult func requestAssociation(uti: String, completion: @escaping @MainActor (OrganizerProviderResult) -> Void) -> Bool {
        guard fatalError == nil, !hasPendingAssociation, let associations, !associations.busy else { return false }
        let effectiveUTI: String
        if uti.isEmpty {
            if let current = UTType(associations.identifier), !current.isDynamic { effectiveUTI = current.identifier }
            else { effectiveUTI = UTType.plainText.identifier }
        } else {
            guard let type = UTType(uti), !type.isDynamic else { return false }
            effectiveUTI = type.identifier
        }
        hasPendingAssociation = true; associationRequestedUTI = uti; associationCompletion = completion
        associations.mode = "type"; associations.identifier = effectiveUTI; associations.refresh(); section = .associations
        return true
    }
    func cancelPendingAssociation() {
        let callback = associationCompletion
        associationCompletion = nil; associationRequestedUTI = nil; hasPendingAssociation = false
        callback?(.cancelled)
    }
    func commitAssociation(to application: URL) async {
        guard let controller = associations, !controller.busy else { return }
        let mode = controller.mode, identifier = controller.identifier
        let success = await controller.change(to: application)
        completeAssociation(mode: mode, identifier: identifier, success: success, detail: controller.message)
    }
    func restoreAssociation(_ record: OFAssociationRecord) async {
        guard let controller = associations, !controller.busy else { return }
        let success = await controller.restore(record)
        completeAssociation(mode: record.mode, identifier: record.identifier, success: success, detail: controller.message)
    }
    private func completeAssociation(mode: String, identifier: String, success: Bool, detail: String) {
        guard let requested = associationRequestedUTI, mode == "type", requested.isEmpty || identifier == requested else { return }
        let callback = associationCompletion
        associationCompletion = nil; associationRequestedUTI = nil; hasPendingAssociation = false
        callback?(success ? .associationChanged(uti: identifier, readBackVerified: true) : .failed(detail))
    }
}

@MainActor func ofAskText(title: String, message: String, initial: String = "") -> String? {
    let alert = NSAlert(); alert.messageText = title; alert.informativeText = message
    let field = NSTextField(string: initial); field.frame = NSRect(x: 0, y: 0, width: 330, height: 25)
    alert.accessoryView = field; alert.addButton(withTitle: "确定"); alert.addButton(withTitle: "取消")
    guard alert.runModal() == .alertFirstButtonReturn else { return nil }
    let text = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
    return text.isEmpty ? nil : text
}
@MainActor func ofConfirm(title: String, message: String, action: String = "确认") -> Bool {
    let alert = NSAlert(); alert.messageText = title; alert.informativeText = message; alert.alertStyle = .warning
    alert.addButton(withTitle: action); alert.addButton(withTitle: "取消")
    return alert.runModal() == .alertFirstButtonReturn
}
