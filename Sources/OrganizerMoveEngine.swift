// Organizer module port; source application is not a runtime dependency.
import Foundation
import Darwin
import CryptoKit

/// Fail-closed, same-volume regular-file moves. No copy/delete fallback and no automatic replay.
final class OFMoveEngine: @unchecked Sendable {
    typealias OFFaultInjector = (OFMoveFaultPoint, OFMovePlan, OFMoveOperation?) throws -> Void
    private struct OFMarker: Codable { var schemaVersion = 1; var storeID: UUID }
    private struct OFLedger: Codable { var schemaVersion = 1; var storeID: UUID; var plans: [OFMovePlan] }
    private struct OFEnvelope: Codable { var payload: Data; var sha256: String }
    private let directory: URL
    private let storeID: UUID
    private let lockFD: Int32
    private let operationLock = NSRecursiveLock()
    private let cancellationLock = NSLock()
    private var cancellations = Set<UUID>()
    private var plans: [OFMovePlan]
    private let faultInjector: OFFaultInjector?
    private let encoder: JSONEncoder
    private let decoder = JSONDecoder()

    init(directory: URL, faultInjector: OFFaultInjector? = nil) throws {
        self.directory = try Self.localURL(directory)
        self.faultInjector = faultInjector
        encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let fm = FileManager.default
        let anchorURL = directory.deletingLastPathComponent().appendingPathComponent(directory.lastPathComponent + ".initialized")
        let anchorExists = fm.fileExists(atPath: anchorURL.path)
        if !fm.fileExists(atPath: directory.path) {
            guard !anchorExists else { throw OFMoveError.storage("已初始化的移动日志目录缺失，停止使用并要求恢复。") }
            try fm.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        var ds = stat()
        guard lstat(directory.path, &ds) == 0, ds.st_mode & S_IFMT == S_IFDIR,
              ds.st_uid == getuid(), ds.st_mode & 0o077 == 0 else {
            throw OFMoveError.storage("移动日志目录必须是当前用户拥有的私有目录（0700），且不能是链接。")
        }
        lockFD = open(directory.appendingPathComponent(".lock").path, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard lockFD >= 0 else { throw OFMoveError.storage("无法打开移动日志锁。") }
        var ls = stat()
        guard fstat(lockFD, &ls) == 0, ls.st_uid == getuid(), ls.st_nlink == 1,
              ls.st_mode & S_IFMT == S_IFREG, ls.st_mode & 0o077 == 0,
              flock(lockFD, LOCK_EX | LOCK_NB) == 0 else {
            close(lockFD)
            throw OFMoveError.storage("移动日志正在被其他进程使用，或日志锁不安全。")
        }
        do {
            let markerURL = directory.appendingPathComponent("initialized.json")
            let ledgerURL = directory.appendingPathComponent("ledger.json")
            if fm.fileExists(atPath: markerURL.path) {
                guard anchorExists else { throw OFMoveError.storage("移动日志独立初始化依据缺失，停止使用并要求恢复。") }
                let marker = try decoder.decode(OFMarker.self, from: Self.readPrivate(markerURL, limit: 4096))
                let anchor = try decoder.decode(OFMarker.self, from: Self.readPrivate(anchorURL, limit: 4096))
                guard marker.schemaVersion == 1, anchor.schemaVersion == 1, anchor.storeID == marker.storeID else { throw OFMoveError.storage("移动日志初始化版本或独立依据不匹配，请恢复。") }
                let envelope = try decoder.decode(OFEnvelope.self, from: Self.readPrivate(ledgerURL, limit: 32 * 1024 * 1024))
                guard Self.digest(envelope.payload) == envelope.sha256 else { throw OFMoveError.storage("移动日志摘要错误，请恢复。") }
                let ledger = try decoder.decode(OFLedger.self, from: envelope.payload)
                guard ledger.schemaVersion == 1, ledger.storeID == marker.storeID,
                      ledger.plans.count <= 1000, Set(ledger.plans.map(\.id)).count == ledger.plans.count,
                      ledger.plans.allSatisfy({ $0.operations.count <= 256 && Set($0.operations.map(\.id)).count == $0.operations.count }) else {
                    throw OFMoveError.storage("移动日志版本或内容不合法，请恢复。")
                }
                storeID = marker.storeID
                plans = ledger.plans
            } else {
                guard !anchorExists else { throw OFMoveError.storage("已初始化的移动日志文件缺失，停止使用并要求恢复。") }
                let remaining = try fm.contentsOfDirectory(atPath: directory.path).filter { $0 != ".lock" }
                guard remaining.isEmpty else { throw OFMoveError.storage("移动日志初始化记录缺失，保留现有内容并停止写入。") }
                storeID = UUID()
                plans = []
                let payload = try encoder.encode(OFLedger(storeID: storeID, plans: []))
                try Self.writePrivate(try encoder.encode(OFEnvelope(payload: payload, sha256: Self.digest(payload))), to: ledgerURL)
                try Self.writePrivate(try encoder.encode(OFMarker(storeID: storeID)), to: markerURL)
                try Self.writePrivate(try encoder.encode(OFMarker(storeID: storeID)), to: anchorURL)
            }
            // Only the ledger is changed: recovery never touches any original or destination file.
            for index in plans.indices where plans[index].state == .executing || plans[index].operations.contains(where: { $0.state == .rollbackIntent }) {
                var plan = plans[index]
                plan.state = .needsRecovery
                plan.failure = "上次执行中断。不会自动重试；请检查日志并选择安全回滚或保留现状。"
                for item in plan.operations.indices {
                    plan.operations[item].journal.append(.init(phase: "interrupted", detail: "进程重启后停止，等待人工恢复。"))
                }
                try persist(plan)
            }
        } catch {
            close(lockFD)
            throw error
        }
    }

    deinit { flock(lockFD, LOCK_UN); close(lockFD) }

    func allPlans() -> [OFMovePlan] {
        operationLock.lock(); defer { operationLock.unlock() }
        return plans.sorted { $0.createdAt > $1.createdAt }
    }

    func plan(id: UUID) -> OFMovePlan? {
        operationLock.lock(); defer { operationLock.unlock() }
        return plans.first { $0.id == id }
    }

    func recoverablePlans() -> [OFMovePlan] {
        allPlans().filter { plan in
            plan.operations.contains { $0.state == .rollbackIntent } || ([.needsRecovery, .failed, .cancelled].contains(plan.state) && plan.operations.contains { [.renameIntent, .moved].contains($0.state) })
        }
    }

    func create(sources: [URL], destination: URL, rename: String? = nil, authorization: OFMoveAuthorization) throws -> OFMovePlan {
        operationLock.lock(); defer { operationLock.unlock() }
        return try Self.withNoMaterialization {
            guard !sources.isEmpty, sources.count <= 256, plans.count < 1000 else { throw OFMoveError.invalid("每个计划需要 1–256 个文件，日志最多保存 1000 个计划。") }
            guard rename == nil || sources.count == 1 else { throw OFMoveError.invalid("重命名只能选择一个文件。") }
            let destination = try Self.localURL(destination)
            try Self.requireDocumentLocation(destination)
            let destinationFD = try Self.openDirectory(destination, roots: [authorization.destinationRoot])
            defer { close(destinationFD) }
            var destinationStat = stat()
            guard fstat(destinationFD, &destinationStat) == 0 else { throw Self.posix("读取目标目录") }
            var operations: [OFMoveOperation] = []
            var identities = Set<String>()
            var names = Set<String>()
            for url in sources {
                let source = try Self.localURL(url)
                try Self.requireDocumentLocation(source)
                let name = rename ?? source.lastPathComponent
                try Self.checkLeaf(name)
                let parent = try Self.openParent(source, roots: authorization.sourceRoots)
                defer { close(parent) }
                var parentStat = stat()
                guard fstat(parent, &parentStat) == 0 else { throw Self.posix("读取来源目录身份") }
                let snapshot = try Self.snapshot(parent: parent, name: source.lastPathComponent)
                guard identities.insert("\(snapshot.device):\(snapshot.inode)").inserted else { throw OFMoveError.invalid("同一个来源文件不能重复加入。") }
                guard names.insert(name.precomposedStringWithCanonicalMapping.lowercased()).inserted else { throw OFMoveError.conflict("批次内的目标文件名可能冲突。") }
                let target = destination.appendingPathComponent(name)
                guard source.path != target.path else { throw OFMoveError.invalid("来源与目标相同，无需移动。") }
                let crossVolume = snapshot.device != Int64(destinationStat.st_dev)
                operations.append(OFMoveOperation(source: source, destination: target, snapshot: snapshot,
                                                sourceParentDevice: Int64(parentStat.st_dev), sourceParentInode: UInt64(parentStat.st_ino),
                                                targetParentDevice: Int64(destinationStat.st_dev), targetParentInode: UInt64(destinationStat.st_ino), crossVolume: crossVolume))
            }
            var plan = OFMovePlan(operations: operations)
            plan.sourceRoots = authorization.sourceRoots; plan.destinationRoot = authorization.destinationRoot
            plan.operations.indices.forEach { plan.operations[$0].journal.append(.init(phase: "draft", detail: "仅建立预览；冲突策略为不覆盖。")) }
            try persist(plan)
            return plans.first { $0.id == plan.id }!
        }
    }

    func validate(_ proposal: OFMovePlan, authorization: OFMoveAuthorization) throws -> OFMovePlan {
        operationLock.lock(); defer { operationLock.unlock() }
        return try Self.withNoMaterialization {
            var plan = try current(proposal.id)
            guard plan.revision == proposal.revision, [.draft, .validated, .awaitingConfirmation].contains(plan.state) else { throw OFMoveError.invalid("计划已变化或不允许再次验证，请重新预览。") }
            do {
                for index in plan.operations.indices {
                    let op = plan.operations[index]
                    guard !op.crossVolume else { throw OFMoveError.unsupported("物理整理不执行跨卷移动；请选择同卷目标。未复制、未删除原件。") }
                    try Self.revalidate(op, authorization: authorization)
                    plan.operations[index].state = .validated
                    plan.operations[index].journal.append(.init(phase: "validated", detail: "来源身份、内容、元数据、授权边界与目标空位已核对。"))
                }
                plan.state = .validated
                try persist(plan)
                plan = try current(plan.id)
                plan.state = .awaitingConfirmation
                try persist(plan)
                return try current(plan.id)
            } catch {
                plan.state = .failed; plan.failure = error.localizedDescription
                try persist(plan)
                throw error
            }
        }
    }

    func execute(id: UUID, confirmation: OFMoveConfirmation, authorization: OFMoveAuthorization, progress: ((OFMovePlan) -> Void)? = nil) throws -> OFMovePlan {
        operationLock.lock(); defer { operationLock.unlock() }
        return try Self.withNoMaterialization {
            var plan = try current(id)
            if plan.state == .committed { return plan } // Durable idempotent completion, no replay.
            guard plan.state == .awaitingConfirmation, confirmation.planID == id, confirmation.revision == plan.revision else {
                throw OFMoveError.invalid("只有当前预览的单独确认可以执行；失败或中断计划不能自动重放。")
            }
            plan.state = .executing; try persist(plan); plan = try current(id)
            progress?(plan)
            do {
                for index in plan.operations.indices {
                    if isCancelled(id) {
                        plan.state = .cancelled; plan.failure = "已取消未开始的项；已移动的项保留，可逐项安全回滚。"
                        try persist(plan); return try current(id)
                    }
                    var op = plan.operations[index]
                    try Self.revalidate(op, authorization: authorization, cancelled: { self.isCancelled(id) })
                    try Self.requireDocumentLocation(op.source); try Self.requireDocumentLocation(op.destination)
                    let sourceFD = try Self.openParent(op.source, roots: authorization.sourceRoots)
                    defer { close(sourceFD) }
                    let targetFD = try Self.openParent(op.destination, roots: [authorization.destinationRoot])
                    defer { close(targetFD) }
                    try Self.verifyParents(op, sourceFD: sourceFD, targetFD: targetFD)
                    // Keep parent FDs pinned from final identity check through exclusive rename.
                    guard let original = op.snapshot, try Self.snapshot(parent: sourceFD, name: op.source.lastPathComponent, cancelled: { self.isCancelled(id) }) == original else { throw OFMoveError.changed("来源在确认后发生变化。") }
                    try Self.ensureAbsent(parent: targetFD, name: op.destination.lastPathComponent)
                    op.state = .renameIntent
                    op.journal.append(.init(phase: "renameIntent", detail: "持久化意图后才调用同卷原子排他重命名。"))
                    plan.operations[index] = op
                    try faultInjector?(.beforeJournal, plan, op)
                    try persist(plan); plan = try current(id)
                    try faultInjector?(.afterJournal, plan, op)
                    try faultInjector?(.beforeRename, plan, op)
                    // Recheck after durable journaling, immediately before the filesystem mutation.
                    guard try Self.snapshot(parent: sourceFD, name: op.source.lastPathComponent, cancelled: { self.isCancelled(id) }) == original else { throw OFMoveError.changed("来源在最终提交前变化，停止移动。") }
                    try Self.ensureAbsent(parent: targetFD, name: op.destination.lastPathComponent)
                    guard renameatx_np(sourceFD, op.source.lastPathComponent, targetFD, op.destination.lastPathComponent, UInt32(RENAME_EXCL)) == 0 else { throw Self.posix("移动未完成；目标冲突、权限或卷能力发生变化") }
                    // A killed process after rename retains renameIntent and original identity for recovery.
                    try faultInjector?(.afterRename, plan, op)
                    try Self.syncDirectory(sourceFD); try Self.syncDirectory(targetFD)
                    let actual = try Self.snapshot(parent: targetFD, name: op.destination.lastPathComponent)
                    guard original.matchesMovedObject(actual) else { throw OFMoveError.changed("移动后的目标身份或内容发生变化，请人工恢复。") }
                    op.targetSnapshot = actual
                    op.state = .moved
                    op.journal.append(.init(phase: "moved", detail: "目标读回身份、流式 SHA-256 与元数据摘要一致；来源目录项已原子改名。"))
                    plan.operations[index] = op
                    try faultInjector?(.beforeCommit, plan, op)
                    try persist(plan); plan = try current(id)
                    try faultInjector?(.afterCommit, plan, op)
                    progress?(plan)
                }
                plan.state = .committed; plan.failure = nil
                try persist(plan)
                progress?(try current(id))
                return try current(id)
            } catch is OFMoveInjectedCrash {
                throw OFMoveInjectedCrash()
            } catch {
                plan.state = plan.operations.contains { [.renameIntent, .moved].contains($0.state) } ? .needsRecovery : (isCancelled(id) ? .cancelled : .failed)
                plan.failure = error.localizedDescription
                if let index = plan.operations.firstIndex(where: { $0.state != .moved }) {
                    plan.operations[index].failure = error.localizedDescription
                    plan.operations[index].journal.append(.init(phase: "stopped", detail: error.localizedDescription))
                }
                try persist(plan)
                throw error
            }
        }
    }

    /// Immediate and thread-safe. It takes effect between atomic file operations.
    func requestCancel(id: UUID) { cancellationLock.lock(); cancellations.insert(id); cancellationLock.unlock() }

    func cancel(id: UUID) throws -> OFMovePlan {
        requestCancel(id: id)
        operationLock.lock(); defer { operationLock.unlock() }
        var plan = try current(id)
        guard ![.committed, .needsRecovery].contains(plan.state) else { return plan }
        plan.state = .cancelled
        try persist(plan)
        return try current(id)
    }

    /// Explicit recovery only. Never deletes a destination and never overwrites the source path.
    func rollback(id: UUID, authorization: OFMoveAuthorization, progress: ((OFMovePlan) -> Void)? = nil) throws -> OFMovePlan {
        operationLock.lock(); defer { operationLock.unlock() }
        return try Self.withNoMaterialization {
            var plan = try current(id)
            guard [.needsRecovery, .failed, .cancelled, .committed].contains(plan.state) else { throw OFMoveError.invalid("当前计划没有可恢复的已执行项。") }
            do {
                for index in plan.operations.indices.reversed() {
                    var op = plan.operations[index]
                    guard [.renameIntent, .moved, .rollbackIntent].contains(op.state) else { continue }
                    try Self.requireDocumentLocation(op.source); try Self.requireDocumentLocation(op.destination)
                    let sourceFD = try Self.openParent(op.source, roots: authorization.sourceRoots)
                    defer { close(sourceFD) }
                    let targetFD = try Self.openParent(op.destination, roots: [authorization.destinationRoot])
                    defer { close(targetFD) }
                    try Self.verifyParents(op, sourceFD: sourceFD, targetFD: targetFD)
                    guard let original = op.snapshot else { throw OFMoveError.storage("来源快照缺失，停止恢复。") }
                    let sourceExists = try Self.exists(parent: sourceFD, name: op.source.lastPathComponent)
                    let targetExists = try Self.exists(parent: targetFD, name: op.destination.lastPathComponent)
                    if sourceExists && !targetExists {
                        let sourceNow = try Self.snapshot(parent: sourceFD, name: op.source.lastPathComponent)
                        guard original.matchesMovedObject(sourceNow) else { throw OFMoveError.changed("来源路径已经被其他文件占用，停止恢复。") }
                        op.state = .rolledBack
                        op.journal.append(.init(phase: "noMutationOrAlreadyRestored", detail: "来源仍为原对象且目标不存在，无需改动文件。"))
                        plan.operations[index] = op; try persist(plan); plan = try current(id)
                        continue
                    }
                    guard !sourceExists, targetExists else { throw OFMoveError.conflict("来源或目标存在冲突／缺失，保留所有现有资料并停止恢复。") }
                    let targetNow = try Self.snapshot(parent: targetFD, name: op.destination.lastPathComponent)
                    let expected = op.targetSnapshot ?? original
                    guard expected.matchesMovedObject(targetNow) else { throw OFMoveError.changed("目标已被修改或替换，禁止回滚该项；现有文件保持不动。") }
                    op.state = .rollbackIntent
                    op.journal.append(.init(phase: "rollbackIntent", detail: "已重新核对操作产生的目标与来源空位，准备排他改名恢复。"))
                    plan.operations[index] = op; try persist(plan); plan = try current(id)
                    try faultInjector?(.beforeRollback, plan, op)
                    guard expected.matchesMovedObject(try Self.snapshot(parent: targetFD, name: op.destination.lastPathComponent)) else { throw OFMoveError.changed("目标在最终恢复前变化，停止回滚。") }
                    try Self.ensureAbsent(parent: sourceFD, name: op.source.lastPathComponent)
                    guard renameatx_np(targetFD, op.destination.lastPathComponent, sourceFD, op.source.lastPathComponent, UInt32(RENAME_EXCL)) == 0 else { throw Self.posix("恢复未完成；来源空位、权限或卷能力变化") }
                    try faultInjector?(.afterRollback, plan, op)
                    try Self.syncDirectory(sourceFD); try Self.syncDirectory(targetFD)
                    guard original.matchesMovedObject(try Self.snapshot(parent: sourceFD, name: op.source.lastPathComponent)) else { throw OFMoveError.changed("恢复后的来源校验失败，请人工检查。") }
                    op.state = .rolledBack
                    op.journal.append(.init(phase: "rolledBack", detail: "原对象已排他恢复；未覆盖任何路径，未删除任何文件。"))
                    plan.operations[index] = op; try persist(plan); plan = try current(id)
                    progress?(plan)
                }
                plan.state = .cancelled; plan.failure = "安全恢复完成；此计划不能重放。"
                try persist(plan)
                return try current(id)
            } catch is OFMoveInjectedCrash { throw OFMoveInjectedCrash() }
            catch { plan.state = .needsRecovery; plan.failure = error.localizedDescription; try persist(plan); throw error }
        }
    }

    private func isCancelled(_ id: UUID) -> Bool {
        cancellationLock.lock(); defer { cancellationLock.unlock() }; return cancellations.contains(id)
    }
    private func current(_ id: UUID) throws -> OFMovePlan {
        guard let plan = plans.first(where: { $0.id == id }) else { throw OFMoveError.invalid("移动计划不存在。") }; return plan
    }
    private func persist(_ value: OFMovePlan) throws {
        var next = plans
        var updated = value
        updated.revision += 1; updated.updatedAt = Date()
        if let index = next.firstIndex(where: { $0.id == value.id }) { next[index] = updated } else { next.append(updated) }
        let payload = try encoder.encode(OFLedger(storeID: storeID, plans: next))
        let data = try encoder.encode(OFEnvelope(payload: payload, sha256: Self.digest(payload)))
        guard data.count <= 32 * 1024 * 1024 else { throw OFMoveError.storage("移动日志达到容量上限，停止写入。") }
        try Self.writePrivate(data, to: directory.appendingPathComponent("ledger.json"))
        plans = next
    }

    private static func requireDocumentLocation(_ url: URL) throws {
        let path = url.standardizedFileURL.path
        let privateRoot = FileSafety.root.standardizedFileURL.path
        guard path != privateRoot, !path.hasPrefix(privateRoot + "/") else {
            throw OFMoveError.denied("搞文件内部资料、索引、恢复稿和备份不能作为物理整理来源或目标。")
        }
        // The same APFS directory can have another spelling (for example a Data-volume
        // path). Compare ancestor identities too; string prefixes alone are insufficient.
        var protected = stat()
        if lstat(privateRoot, &protected) == 0 {
            guard protected.st_mode & S_IFMT == S_IFDIR else { throw OFMoveError.denied("搞文件资料根身份异常，停止物理整理。") }
            var ancestor = url.standardizedFileURL
            while ancestor.path != "/" {
                var value = stat()
                if lstat(ancestor.path, &value) == 0,
                   value.st_dev == protected.st_dev, value.st_ino == protected.st_ino {
                    throw OFMoveError.denied("物理整理路径对应搞文件内部资料目录，停止操作。")
                }
                ancestor.deleteLastPathComponent()
            }
        } else if errno != ENOENT { throw OFMoveError.denied("无法核对搞文件资料根，停止物理整理。") }
    }

    static func authorizationRoot(_ url: URL) throws -> OFMoveAuthorization.OFRoot {
        try withNoMaterialization {
            let url = try localURL(url)
            // Resolve each ancestor with O_NOFOLLOW rather than accepting symlink aliases.
            let fd = try openAbsoluteDirectory(url)
            defer { close(fd) }
            var s = stat(); guard fstat(fd, &s) == 0 else { throw posix("读取授权根") }
            return OFMoveAuthorization.OFRoot(url: url, device: Int64(s.st_dev), inode: UInt64(s.st_ino))
        }
    }

    private static func openAbsoluteDirectory(_ url: URL) throws -> Int32 {
        guard url.isFileURL, url.path.hasPrefix("/") else { throw OFMoveError.denied("目录路径不合法。") }
        var fd = open("/", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw posix("打开文件系统根") }
        do {
            for component in url.pathComponents.dropFirst() {
                try checkLeaf(component)
                let next = openat(fd, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                guard next >= 0 else { throw posix("目录不可用或包含符号链接（\(component)）") }
                close(fd); fd = next
                try requireMaterializedDirectory(fd)
            }
            return fd
        } catch { close(fd); throw error }
    }
    private static func openDirectory(_ url: URL, roots: [OFMoveAuthorization.OFRoot]) throws -> Int32 {
        let path = try localURL(url).path
        guard let root = roots.sorted(by: { $0.url.path.count > $1.url.path.count }).first(where: { path == $0.url.path || path.hasPrefix($0.url.path + "/") }) else {
            throw OFMoveError.denied("路径不在本次明确授权的根目录内。")
        }
        var fd = try openAbsoluteDirectory(root.url)
        do {
            var s = stat()
            guard fstat(fd, &s) == 0, Int64(s.st_dev) == root.device, UInt64(s.st_ino) == root.inode else { throw OFMoveError.changed("授权根已被替换或卷已更换，请重新授权。") }
            let relative = String(path.dropFirst(root.url.path.count)).split(separator: "/")
            for part in relative {
                let name = String(part); try checkLeaf(name)
                let next = openat(fd, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                guard next >= 0 else { throw posix("授权目录内部不可用或包含链接") }
                close(fd); fd = next
                try requireMaterializedDirectory(fd)
            }
            return fd
        } catch { close(fd); throw error }
    }
    private static func openParent(_ url: URL, roots: [OFMoveAuthorization.OFRoot]) throws -> Int32 {
        try checkLeaf(url.lastPathComponent)
        return try openDirectory(url.deletingLastPathComponent(), roots: roots)
    }
    private static func requireMaterializedDirectory(_ fd: Int32) throws {
        var s = stat(); guard fstat(fd, &s) == 0 else { throw posix("读取目录") }
        guard s.st_flags & UInt32(SF_DATALESS) == 0 else { throw OFMoveError.unsupported("目录尚未下载；移动不会触发下载。") }
    }
    private static func checkLeaf(_ name: String) throws {
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/"), !name.utf8.contains(0), name.utf8.count <= 255 else { throw OFMoveError.invalid("文件名不合法或过长。") }
    }
    private static func localURL(_ url: URL) throws -> URL {
        guard url.isFileURL, url.host == nil || url.host == "" || url.host == "localhost", url.path.hasPrefix("/"),
              !url.pathComponents.dropFirst().contains(where: { $0 == "." || $0 == ".." }) else { throw OFMoveError.denied("只接受无相对路径片段的本机文件地址。") }
        // standardizedFileURL may shorten /private/tmp into the /tmp symlink on macOS.
        // Preserve the exact selected root spelling, then traverse every component with O_NOFOLLOW.
        return URL(fileURLWithPath: url.path, isDirectory: url.hasDirectoryPath)
    }
    private static func exists(parent: Int32, name: String) throws -> Bool {
        var s = stat()
        if fstatat(parent, name, &s, AT_SYMLINK_NOFOLLOW) == 0 { return true }
        if errno == ENOENT { return false }
        throw posix("检查路径")
    }
    private static func ensureAbsent(parent: Int32, name: String) throws {
        guard try !exists(parent: parent, name: name) else { throw OFMoveError.conflict("目标已存在；默认不覆盖，请改名或选择其他目录。") }
    }
    private static func revalidate(_ op: OFMoveOperation, authorization: OFMoveAuthorization, cancelled: (() -> Bool)? = nil) throws {
        try requireDocumentLocation(op.source); try requireDocumentLocation(op.destination)
        guard !op.crossVolume else { throw OFMoveError.unsupported("物理整理仅支持同卷普通文件移动。") }
        let sourceFD = try openParent(op.source, roots: authorization.sourceRoots); defer { close(sourceFD) }
        let targetFD = try openParent(op.destination, roots: [authorization.destinationRoot]); defer { close(targetFD) }
        try verifyParents(op, sourceFD: sourceFD, targetFD: targetFD)
        guard let original = op.snapshot, try snapshot(parent: sourceFD, name: op.source.lastPathComponent, cancelled: cancelled) == original else { throw OFMoveError.changed("来源文件已变化或被替换，请建立新计划。") }
        var target = stat(); guard fstat(targetFD, &target) == 0, Int64(target.st_dev) == original.device else { throw OFMoveError.changed("目标卷已更换，或属于跨卷目标。") }
        try ensureAbsent(parent: targetFD, name: op.destination.lastPathComponent)
    }
    private static func verifyParents(_ op: OFMoveOperation, sourceFD: Int32, targetFD: Int32) throws {
        var source = stat(); var target = stat()
        guard fstat(sourceFD, &source) == 0, fstat(targetFD, &target) == 0,
              op.sourceParentDevice == Int64(source.st_dev), op.sourceParentInode == UInt64(source.st_ino),
              op.targetParentDevice == Int64(target.st_dev), op.targetParentInode == UInt64(target.st_ino) else {
            throw OFMoveError.changed("来源或目标的父目录身份发生变化，停止操作并重新建立计划／人工恢复。")
        }
    }

    private static func snapshot(parent: Int32, name: String, cancelled: (() -> Bool)? = nil) throws -> OFMoveSnapshot {
        var pathStat = stat()
        guard fstatat(parent, name, &pathStat, AT_SYMLINK_NOFOLLOW) == 0 else { throw posix("读取来源元数据") }
        guard pathStat.st_mode & S_IFMT == S_IFREG, pathStat.st_nlink == 1 else {
            throw OFMoveError.unsupported("物理整理仅支持独立普通文件；目录、包、符号链接与多重硬链接请使用虚拟整理。")
        }
        guard pathStat.st_flags & UInt32(SF_DATALESS) == 0 else { throw OFMoveError.unsupported("文件尚未下载；移动不会触发下载。") }
        let fd = openat(parent, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw posix("打开本地普通文件") }
        defer { close(fd) }
        var before = stat(); guard fstat(fd, &before) == 0, sameStat(pathStat, before) else { throw OFMoveError.changed("文件在读取前被替换。") }
        var sha = SHA256()
        var buffer = [UInt8](repeating: 0, count: 1024 * 1024)
        var bytes: Int64 = 0
        while true {
            if cancelled?() == true { throw OFMoveError.cancelled("校验已取消。") }
            let count = read(fd, &buffer, buffer.count)
            if count == 0 { break }
            if count < 0 { if errno == EINTR { continue }; throw posix("读取来源内容") }
            bytes += Int64(count)
            guard bytes <= before.st_size else { throw OFMoveError.changed("文件读取中变大。") }
            sha.update(data: Data(buffer[0..<count]))
        }
        guard bytes == before.st_size else { throw OFMoveError.changed("文件读取中大小变化。") }
        let metadata = try metadataDigest(fd)
        var after = stat(); var finalPath = stat()
        guard fstat(fd, &after) == 0, fstatat(parent, name, &finalPath, AT_SYMLINK_NOFOLLOW) == 0,
              sameStat(before, after), sameStat(after, finalPath) else { throw OFMoveError.changed("文件或元数据在校验中变化。") }
        return OFMoveSnapshot(device: Int64(after.st_dev), inode: UInt64(after.st_ino), size: after.st_size,
                            modifiedSeconds: Int64(after.st_mtimespec.tv_sec), modifiedNanoseconds: Int64(after.st_mtimespec.tv_nsec),
                            changedSeconds: Int64(after.st_ctimespec.tv_sec), changedNanoseconds: Int64(after.st_ctimespec.tv_nsec),
                            mode: UInt32(after.st_mode), uid: after.st_uid, gid: after.st_gid, flags: after.st_flags,
                            linkCount: UInt64(after.st_nlink), sha256: sha.finalize().map { String(format: "%02x", $0) }.joined(), metadataSHA256: metadata)
    }
    private static func sameStat(_ a: stat, _ b: stat) -> Bool {
        a.st_dev == b.st_dev && a.st_ino == b.st_ino && a.st_size == b.st_size && a.st_mode == b.st_mode && a.st_nlink == b.st_nlink && a.st_uid == b.st_uid && a.st_gid == b.st_gid && a.st_flags == b.st_flags && a.st_mtimespec.tv_sec == b.st_mtimespec.tv_sec && a.st_mtimespec.tv_nsec == b.st_mtimespec.tv_nsec && a.st_ctimespec.tv_sec == b.st_ctimespec.tv_sec && a.st_ctimespec.tv_nsec == b.st_ctimespec.tv_nsec
    }
    private static func metadataDigest(_ fd: Int32) throws -> String {
        let size = flistxattr(fd, nil, 0, 0)
        guard size >= 0, size <= 1024 * 1024 else { throw OFMoveError.unsupported("扩展属性列表不可读或超出安全上限。") }
        var names = [CChar](repeating: 0, count: max(size, 1))
        guard flistxattr(fd, &names, size, 0) == size else { throw OFMoveError.changed("扩展属性列表读取中变化。") }
        let nameData = Data(names.prefix(size).map { UInt8(bitPattern: $0) })
        let ordered = nameData.split(separator: 0).map { Data($0) }.sorted { $0.lexicographicallyPrecedes($1) }
        var sha = SHA256(); var total = 0
        for raw in ordered {
            guard let name = String(data: raw, encoding: .utf8) else { throw OFMoveError.unsupported("扩展属性名不能安全读取。") }
            let length = fgetxattr(fd, name, nil, 0, 0, 0)
            guard length >= 0, length <= 64 * 1024 * 1024, total <= 128 * 1024 * 1024 - length else { throw OFMoveError.unsupported("资源分叉／扩展属性不可读或超出安全上限。") }
            total += length
            var data = Data(count: length)
            let readCount = data.withUnsafeMutableBytes { fgetxattr(fd, name, $0.baseAddress, length, 0, 0) }
            guard readCount == length else { throw OFMoveError.changed("扩展属性读取中变化。") }
            sha.update(data: raw); sha.update(data: Data([0]))
            sha.update(data: Data(String(length).utf8)); sha.update(data: Data([0])); sha.update(data: data)
        }
        // Extended ACLs are not represented by POSIX mode bits or by the xattr list.
        errno = 0
        if let acl = acl_get_fd_np(fd, ACL_TYPE_EXTENDED) {
            defer { acl_free(UnsafeMutableRawPointer(acl)) }
            var textLength = 0
            guard let text = acl_to_text(acl, &textLength), textLength >= 0, textLength <= 1024 * 1024 else { throw OFMoveError.unsupported("文件访问控制列表不可读或过大。") }
            defer { acl_free(text) }
            sha.update(data: Data(bytes: text, count: textLength))
        } else {
            guard errno == ENOENT else { throw posix("读取文件访问控制列表") }
            sha.update(data: Data("no-extended-acl".utf8))
        }
        return sha.finalize().map { String(format: "%02x", $0) }.joined()
    }
    private static func withNoMaterialization<T>(_ body: () throws -> T) throws -> T {
        let old = getiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_THREAD)
        guard old >= 0, setiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_THREAD, IOPOL_MATERIALIZE_DATALESS_FILES_OFF) == 0 else { throw OFMoveError.unsupported("无法阻止占位文件自动下载，停止物理操作。") }
        defer { _ = setiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_THREAD, old) }
        return try body()
    }
    private static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    private static func posix(_ operation: String) -> OFMoveError { let code = errno; return .storage("\(operation)：\(String(cString: strerror(code)))（\(code)）。") }
    private static func readPrivate(_ url: URL, limit: Int) throws -> Data {
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw posix("移动账本缺失或不可读，停止使用") }
        defer { close(fd) }
        var s = stat()
        guard fstat(fd, &s) == 0, s.st_mode & S_IFMT == S_IFREG, s.st_uid == getuid(), s.st_nlink == 1,
              s.st_mode & 0o077 == 0, s.st_size >= 0, s.st_size <= limit else { throw OFMoveError.storage("移动账本类型、权限或容量异常，停止使用。") }
        var output = Data(); var buffer = [UInt8](repeating: 0, count: 65536)
        while true {
            let count = read(fd, &buffer, buffer.count)
            if count == 0 { break }
            if count < 0 { if errno == EINTR { continue }; throw posix("读取移动账本") }
            guard output.count <= limit - count else { throw OFMoveError.storage("移动账本超出容量。") }
            output.append(contentsOf: buffer.prefix(count))
        }
        var after = stat()
        guard fstat(fd, &after) == 0, sameStat(s, after) else { throw OFMoveError.storage("移动账本读取时变化。") }
        return output
    }
    private static func writePrivate(_ data: Data, to url: URL) throws {
        let parent = open(url.deletingLastPathComponent().path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard parent >= 0 else { throw posix("打开移动日志目录") }
        defer { close(parent) }
        let temp = ".write-" + UUID().uuidString
        let fd = openat(parent, temp, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw posix("创建移动日志临时项") }
        var published = false
        defer { close(fd); if !published { unlinkat(parent, temp, 0) } }
        try data.withUnsafeBytes { raw in
            var count = 0
            while count < raw.count {
                let n = write(fd, raw.baseAddress!.advanced(by: count), raw.count - count)
                if n < 0 { if errno == EINTR { continue }; throw posix("写入移动日志") }
                guard n > 0 else { throw OFMoveError.storage("移动日志写入没有进展。") }
                count += n
            }
        }
        guard fsync(fd) == 0 else { throw posix("持久化移动日志") }
        guard renameat(parent, temp, parent, url.lastPathComponent) == 0 else { throw posix("原子提交移动日志") }
        published = true
        try syncDirectory(parent)
    }
    private static func syncDirectory(_ fd: Int32) throws {
        if fsync(fd) != 0 { throw posix("持久化目录项") }
    }
}
