import Foundation
import CryptoKit
import SQLite3
import Darwin

struct OrganizerMigrationReport: Codable, Sendable {
    let snapshotID: String
    let sourceDatabaseID: String
    let destinationPath: String
    let importedRoots: Int
    let importedFiles: Int
    let preservedObjects: Int
    let needsAuthorization: Bool
    var alreadyImported: Bool
    let recoveryRequiresReview: Bool
}

enum OrganizerMigrationPhase: String, Sendable { case beforePublish, afterPublishBeforeAnchor }
enum OrganizerRetirementPhase: String, Sendable { case beforeCommit, afterCommit }

struct OrganizerRetirementReport: Codable, Sendable {
    let snapshotID: String
    let sourceDatabaseID: String
    let destinationPath: String
    let receiptPath: String
    let deletablePaths: [String]
    let alreadyFinalized: Bool
}

struct OrganizerMigrationFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
    init(_ message: String) { self.message = message }
}

/// Explicit, offline, new-store import. Never initializes an App, resolves an old
/// bookmark, changes a system association, mutates a source, or merges over data.
enum OrganizerMigration {
    private struct Entry: Codable, Equatable {
        let path: String
        let kind: String
        let mode: Int
        let xattrs: [String: String]
        let bytes: Int?
        let sha256: String?
    }
    private struct Reference: Codable {
        let originalPath: String
        let snapshotRelativePath: String?
        let requiredForRecovery: Bool
        let exists: Bool
        let retiringPath: Bool
    }
    private struct Manifest: Codable {
        let schemaVersion: Int
        let snapshotID: String
        let sourceBundleID: String
        let sourceDatabaseID: String
        let sourceDataRoot: String
        let sourceInventorySHA256: String
        let sourcePreferencesSHA256: String
        let indexSchemaVersion: Int
        let initialized: Bool
        let entries: [Entry]
        let references: [Reference]
        let retiringPrefixes: [String]
        let rootCount: Int
        let fileCount: Int
        let sourceReadOnlyAndStable: Bool
        let sourceBookmarksRequireAuthorization: Bool
        let oldExchangeHistoryOnly: Bool
    }
    private struct Receipt: Codable {
        var schemaVersion = 1
        let snapshotSHA256: String
        let archiveEntries: [Entry]
        let report: OrganizerMigrationReport
        var authority = "destination-only-after-explicit-source-retirement"
        var associationHistoryOnly = true
        var exchangeHistoryOnly = true
    }
    private struct FreezeReceipt: Decodable {
        let schemaVersion: Int
        let kind: String
        let sourceBundleID: String
        let targetBundleID: String
        let sourceDataRoot: String
        let targetDataRoot: String
        let snapshotID: String
        let manifestSHA256: String
        let sourceInventorySHA256: String
        let sourcePreferencesSHA256: String
        let writersStopped: Bool
        let sourceFrozen: Bool
        let issuedAt: String
    }
    private struct Activation: Codable {
        var schemaVersion = 1
        let snapshotID: String
        let manifestSHA256: String
        let sourceBundleID: String
        let targetBundleID: String
        let sourceDataRoot: String
        let targetDataRoot: String
        let sourceInventorySHA256: String
        let sourcePreferencesSHA256: String
        let authorityReceiptSHA256: String
        let issuedAt: String
    }
    private struct Intent: Codable {
        var schemaVersion = 1
        let snapshotSHA256: String
        let destinationPath: String
        let snapshotID: String
    }
    /// Current authority metadata only. No source raw bytes, bookmarks, indexed
    /// rows, archive filenames, preferences or attachment payloads are embedded.
    private struct Finalized: Codable {
        var schemaVersion = 1
        var kind = "GaoSeriesSourceRetirementFinalized"
        let sourceBundleID: String
        let targetBundleID: String
        let targetDataRoot: String
        let snapshotID: String
        let sourceDatabaseID: String
        let moveStoreID: String
        let manifestSHA256: String
        let migrationLedgerSHA256: String
        let authorityReceiptSHA256: String
        let activationReceiptSHA256: String
        var indexSchemaVersion = 2
        var configurationSchemaVersion = 1
        var moveSchemaVersion = 1
        var archiveNoLongerRequired = true
        var explicitCoordinatorAcceptance = true
        var cleanupPolicy = "root-only-exact-source-archive-allowlist"
        let issuedAt: String
    }
    private static let finalizedName = "SourceRetirementFinalized.json"
    private static let cleanupNames = ["SourceArchive", "MigrationLedger.json", "SourceIDMapping.json"]
    private static let fm = FileManager.default
    private static let required = ["configuration.json", "configuration.initialized", "metadata.sqlite", "index-initialized.json",
        "associations_history.json", "associations_history.initialized", "MovePlans/initialized.json", "MovePlans/ledger.json", "MovePlans.initialized"]

    static func importSnapshot(url: URL, destination: URL,
        testingFault: ((OrganizerMigrationPhase) throws -> Void)? = nil) throws -> OrganizerMigrationReport {
        let snapshot = try safe(url), parent = try safe(destination.deletingLastPathComponent())
        try require(destination.isFileURL && destination.lastPathComponent == "Organizer", "迁移目标必须是接收应用的 Organizer 新资料根。")
        let target = parent.appendingPathComponent("Organizer", isDirectory: true)
        try require(testingFault == nil || parent.path.hasPrefix("/private/tmp/gaowenjian-"), "迁移故障注入只允许显式隔离测试根。")
        try require(snapshot.path != target.path && !snapshot.path.hasPrefix(target.path + "/") && !target.path.hasPrefix(snapshot.path + "/"), "快照与目标不能重叠。")
        let manifestBytes = try read(snapshot.appendingPathComponent("snapshot.json"), limit: 32 * 1024 * 1024)
        let manifestSHA = digest(manifestBytes)
        let manifest = try JSONDecoder().decode(Manifest.self, from: manifestBytes)
        try require(manifest.schemaVersion == 1 && manifest.initialized && manifest.sourceBundleID == "com.gaoseries.GaoZhengLi"
            && UUID(uuidString: manifest.snapshotID) != nil && UUID(uuidString: manifest.sourceDatabaseID) != nil
            && (1...2).contains(manifest.indexSchemaVersion) && manifest.sourceReadOnlyAndStable
            && manifest.sourceBookmarksRequireAuthorization && manifest.oldExchangeHistoryOnly, "迁移快照版本、来源或初始化依据不受支持。")
        try require(try read(snapshot.appendingPathComponent("VERIFIED"), limit: 256) == Data("schema=1;sha256=\(manifestSHA)\n".utf8), "快照完整性收据不匹配。")
        let restore = try object(read(snapshot.appendingPathComponent("RestoreReport.json"), limit: 1024 * 1024))
        try require(restore["schemaVersion"] as? Int == 1 && restore["pass"] as? Bool == true
            && restore["actualFilesystemRestore"] as? Bool == true && restore["allExportedObjectsMatch"] as? Bool == true
            && restore["sourceUnchanged"] as? Bool == true && restore["snapshotSHA256"] as? String == manifestSHA,
            "快照缺少匹配的完整恢复演练依据。")
        try require(manifest.retiringPrefixes.allSatisfy { $0.hasPrefix("/") && $0 != "/" && !$0.split(separator: "/").contains("..") }
            && manifest.sourceDataRoot.hasPrefix("/") && manifest.sourceDataRoot != "/"
            && manifest.retiringPrefixes.contains(manifest.sourceDataRoot)
            && Set(manifest.entries.map(\.path)).count == manifest.entries.count,
            "退役边界或快照路径清单损坏。")
        for entry in manifest.entries { _ = try relativePath(entry.path) }
        let actual = try inventory(snapshot).filter { ![".", "snapshot.json", "VERIFIED", "RestoreReport.json"].contains($0.path) }
        try require(actual == manifest.entries.sorted { $0.path < $1.path }, "快照附件、书签、索引或事务历史缺失、变化或包含未知文件。")
        try require(!manifest.references.contains { $0.requiredForRecovery && $0.retiringPath },
                    "待恢复实物仍依赖即将退役的来源私有路径。复制件不继承原 inode，不能冒充可回滚；请保留原同 inode 对象及来源，完成单独恢复核验后再迁移。")
        let sourceDB = snapshot.appendingPathComponent("Data/metadata.sqlite")
        try validateStore(snapshot.appendingPathComponent("Data"), databaseID: manifest.sourceDatabaseID, readonly: true)
        try require(!exists(sourceDB.appendingPathExtension("wal")) && !exists(snapshot.appendingPathComponent("Data/metadata.sqlite-wal"))
            && !exists(snapshot.appendingPathComponent("Data/metadata.sqlite-shm")), "一致性快照不能带未合并的 WAL/SHM。")
        let anchor = parent.appendingPathComponent("Organizer.initialized")
        if exists(target) {
            let receipt = try checkedReceipt(target, manifestSHA: manifestSHA)
            try require(receipt.report.destinationPath == target.path && receipt.report.snapshotID == manifest.snapshotID,
                        "迁移回执属于其他目标；不接管现有资料。")
            try ensureAnchor(anchor)
            var report = receipt.report; report.alreadyImported = true
            return report // No runtime checks or writes over user data added since import.
        }
        try require(!exists(anchor), "Organizer 初始化依据存在但资料根缺失，需恢复，不能建立空资料。")
        let stage = parent.appendingPathComponent(".organizer-migration-\(manifest.snapshotID).noindex", isDirectory: true)
        let intent = Intent(snapshotSHA256: manifestSHA, destinationPath: target.path, snapshotID: manifest.snapshotID)
        if exists(stage) {
            _ = try safe(stage)
            let old = try JSONDecoder().decode(Intent.self, from: read(stage.appendingPathComponent("intent.json"), limit: 4096))
            try require(old.schemaVersion == 1 && old.snapshotSHA256 == manifestSHA && old.destinationPath == target.path && old.snapshotID == manifest.snapshotID,
                        "中断事务不属于本次快照；保留现有资料并停止。")
        } else {
            try fm.createDirectory(at: stage, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            try writeNew(try encode(intent), to: stage.appendingPathComponent("intent.json"))
            try sync(parent)
        }
        let lock = Darwin.open(stage.appendingPathComponent("migration.lock").path, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
        try require(lock >= 0, "无法建立迁移事务锁。")
        defer { close(lock) }
        try require(flock(lock, LOCK_EX | LOCK_NB) == 0, "同一迁移事务正在执行。")
        let prepared = stage.appendingPathComponent("Ready", isDirectory: true)
        if !exists(prepared) {
            // A killed preparation remains as evidence. A retry creates a NEW
            // attempt, never deletes/overwrites an interrupted or unknown tree.
            let attempt = stage.appendingPathComponent("Attempt-\(UUID().uuidString).noindex", isDirectory: true)
            try fm.createDirectory(at: attempt, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            let store = attempt.appendingPathComponent("Organizer", isDirectory: true)
            try fm.copyItem(at: snapshot.appendingPathComponent("Data"), to: store)
            try require(try inventory(store) == inventory(snapshot.appendingPathComponent("Data")), "准备副本摘要或安全属性不符。")
            let archive = store.appendingPathComponent("SourceArchive", isDirectory: true)
            try fm.copyItem(at: snapshot, to: archive)
            try require(try inventory(archive) == inventory(snapshot), "完整来源归档校验失败。")
            // Old exchange is retained ONLY under SourceArchive, never handed to
            // the new provider. It cannot resume/send the old source's requests.
            for name in ["Exchange", "exchange-initialized.json"] {
                let path = store.appendingPathComponent(name)
                if exists(path) { try fm.removeItem(at: path) } // Verified, owned new attempt only.
            }
            let references = store.appendingPathComponent("PreservedReferences", isDirectory: true)
            try fm.createDirectory(at: references, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            var replacements: [String: String] = [:]
            for ref in manifest.references {
                try require(ref.originalPath.hasPrefix("/") && !ref.originalPath.split(separator: "/").contains(".."), "外部引用路径无效。")
                guard let relative = ref.snapshotRelativePath, ref.exists else {
                    try require(!ref.requiredForRecovery, "待恢复实物缺失，不能提交迁移。")
                    continue
                }
                _ = try relativePath(relative)
                let from = snapshot.appendingPathComponent(relative)
                let destinationRef: URL
                if relative == "Data" || relative.hasPrefix("Data/") {
                    destinationRef = target.appendingPathComponent(String(relative.dropFirst(min(relative.count, 5))))
                } else {
                    let key = digest(Data(ref.originalPath.utf8))
                    let held = references.appendingPathComponent(key)
                    try fm.copyItem(at: from, to: held)
                    try require(try inventory(from) == inventory(held), "待恢复实物或外部附件副本核验失败。")
                    destinationRef = target.appendingPathComponent("PreservedReferences/" + key)
                }
                if ref.retiringPath { replacements[ref.originalPath] = destinationRef.path }
            }
            // Known private source root itself is rebased even if no JSON path
            // happened to name the root. Unknown absolute user originals remain.
            replacements[manifest.sourceDataRoot] = target.path
            let counts = try migrateDatabase(store.appendingPathComponent("metadata.sqlite"), databaseID: manifest.sourceDatabaseID, replacements: replacements)
            try migrateConfiguration(store, replacements: replacements, rootIDs: counts.ids)
            try migrateAssociations(store, replacements: replacements)
            let recovery = try migrateMoves(store, replacements: replacements, retiring: manifest.retiringPrefixes)
            // Scan checkpoints are history, never an implicit migration replay.
            let report = OrganizerMigrationReport(snapshotID: manifest.snapshotID, sourceDatabaseID: manifest.sourceDatabaseID,
                destinationPath: target.path, importedRoots: counts.roots, importedFiles: counts.files,
                preservedObjects: manifest.entries.count, needsAuthorization: true, alreadyImported: false, recoveryRequiresReview: recovery)
            try require(counts.roots == manifest.rootCount && counts.files == manifest.fileCount, "迁移前后索引对象数不一致。")
            try writeNew(try encode(["schemaVersion": "1", "sourceBundleID": "com.gaoseries.GaoZhengLi",
                "databaseID": manifest.sourceDatabaseID, "idPolicy": "preserved-in-new-namespace", "oldBookmarks": "SourceArchive/Data/metadata.sqlite",
                "associationPolicy": "history-only-no-system-apply", "movePolicy": "explicit-review-new-authorization-no-replay"]), to: store.appendingPathComponent("SourceIDMapping.json"))
            let receipt = Receipt(snapshotSHA256: manifestSHA, archiveEntries: try inventory(archive), report: report)
            let receiptPayload = try encode(receipt)
            try writeNew(try json(["schemaVersion": 1, "payload": receiptPayload.base64EncodedString(),
                                   "sha256": digest(receiptPayload)]), to: store.appendingPathComponent("MigrationLedger.json"))
            _ = try checkedReceipt(store, manifestSHA: manifestSHA)
            try validateStore(store, databaseID: manifest.sourceDatabaseID, readonly: true)
            try renameNew(store, prepared)
            try sync(stage)
        }
        let receipt = try checkedReceipt(prepared, manifestSHA: manifestSHA)
        try require(try inventory(snapshot).filter { ![".", "snapshot.json", "VERIFIED", "RestoreReport.json"].contains($0.path) } == actual,
                    "来源快照在准备期间变化；未提交。")
        try require(!exists(target) && !exists(anchor), "目标或初始化记录在迁移期间出现，停止且不覆盖。")
        try testingFault?(.beforePublish)
        try renameNew(prepared, target)
        try sync(parent)
        try testingFault?(.afterPublishBeforeAnchor)
        // Crash here is recoverable by the exact committed ledger + immutable
        // archive. Never infer successful migration from an unmarked directory.
        try ensureAnchor(anchor)
        return receipt.report
    }

    /// Run before any module lock, store initializer or write. New non-migrated
    /// stores need no source freeze. A migrated store stays sealed until an
    /// explicit coordinator receipt activates it; no source database is read.
    static func requireActiveAuthority(directory: URL) throws {
        let root = try safe(directory)
        // A damaged/future finalized receipt never falls back to the archive
        // path. After explicit retirement this is the current authority proof.
        if exists(root.appendingPathComponent(finalizedName)) {
            _ = try checkedFinalized(root, receiptURL: root.appendingPathComponent(finalizedName))
            return
        }
        guard exists(root.appendingPathComponent("MigrationLedger.json")) else {
            try require(!["ActivationReceipt.json", "SourceAuthorityReceipt.json", "SourceArchive", "SourceIDMapping.json", ".SourceRetirementFinalized.pending.json"].contains {
                exists(root.appendingPathComponent($0))
            }, "迁入资料缺少迁移账本；不能降级成无需权威切换的新资料库。")
            return
        }
        let context = try migrationContext(root)
        let authority = try checkedAuthority(root)
        try validateFreeze(authority.freeze, manifest: context.manifest, manifestSHA: context.sha, destination: root)
    }

    private static func checkedAuthority(_ root: URL) throws -> (freeze: FreezeReceipt, activation: Activation, authoritySHA: String, activationSHA: String) {
        let activationURL = root.appendingPathComponent("ActivationReceipt.json")
        let authorityURL = root.appendingPathComponent("SourceAuthorityReceipt.json")
        try require(exists(activationURL) && exists(authorityURL), "整理资料已导入，尚待总协调冻结来源并完成权威切换；现在不初始化或写入。")
        let authorityBytes = try privateReceipt(authorityURL)
        let freeze = try JSONDecoder().decode(FreezeReceipt.self, from: authorityBytes)
        let activationBytes = try privateReceipt(activationURL)
        let envelope = try object(activationBytes)
        let activation = try JSONDecoder().decode(Activation.self, from: decodedEnvelope(envelope, schema: true))
        try require(freeze.schemaVersion == 1 && freeze.kind == "GaoSeriesSourceWriteFreeze"
            && freeze.sourceBundleID == "com.gaoseries.GaoZhengLi" && freeze.targetBundleID == "com.gaoseries.GaoWenJian"
            && freeze.targetDataRoot == root.path && freeze.sourceDataRoot.hasPrefix("/")
            && UUID(uuidString: freeze.snapshotID) != nil && freeze.writersStopped && freeze.sourceFrozen
            && validSHA(freeze.manifestSHA256) && validSHA(freeze.sourceInventorySHA256) && validSHA(freeze.sourcePreferencesSHA256)
            && validDate(freeze.issuedAt)
            && activation.schemaVersion == 1 && activation.snapshotID == freeze.snapshotID
            && activation.manifestSHA256 == freeze.manifestSHA256
            && activation.sourceBundleID == freeze.sourceBundleID && activation.targetBundleID == freeze.targetBundleID
            && activation.sourceDataRoot == freeze.sourceDataRoot && activation.targetDataRoot == root.path
            && activation.sourceInventorySHA256 == freeze.sourceInventorySHA256
            && activation.sourcePreferencesSHA256 == freeze.sourcePreferencesSHA256
            && activation.authorityReceiptSHA256 == digest(authorityBytes) && activation.issuedAt == freeze.issuedAt,
            "本地权威切换凭据损坏或不属于此快照/目标；停止写入。")
        return (freeze, activation, digest(authorityBytes), digest(activationBytes))
    }

    /// Explicit coordinator-only step AFTER actual migration/business acceptance.
    /// This changes authority evidence only. It never deletes any archive,
    /// current document, transaction, recovery object or user original.
    static func finalizeSourceRetirement(destination: URL,
        testingFault: ((OrganizerRetirementPhase) throws -> Void)? = nil) throws -> OrganizerRetirementReport {
        let root = try safe(destination)
        try require(root.lastPathComponent == "Organizer", "退役收尾只接受精确的 Organizer 目标。")
        try require(testingFault == nil || root.path.hasPrefix("/private/tmp/gaowenjian-"), "退役故障注入只允许隔离测试根。")
        var info = stat()
        try require(lstat(root.path, &info) == 0 && info.st_uid == getuid() && info.st_mode & S_IFMT == S_IFDIR
            && info.st_mode & 0o077 == 0, "退役目标必须是当前用户的私有现用目录。")
        let appLock = try existingExclusiveLock(root.appendingPathComponent(".app.lock"))
        defer { flock(appLock, LOCK_UN); close(appLock) }
        let moveLock = try existingExclusiveLock(root.appendingPathComponent("MovePlans/.lock"))
        defer { flock(moveLock, LOCK_UN); close(moveLock) }
        let finalURL = root.appendingPathComponent(finalizedName)
        if exists(finalURL) {
            let final = try checkedFinalized(root, receiptURL: finalURL)
            _ = try validateProduction(root, databaseID: final.sourceDatabaseID, forCleanup: true)
            return retirementReport(final, root: root, already: true)
        }
        // Includes the whole immutable source archive and original migration
        // receipt, not a prepared baseline or a filename-only existence check.
        let context = try migrationContext(root), authority = try checkedAuthority(root)
        try validateFreeze(authority.freeze, manifest: context.manifest, manifestSHA: context.sha, destination: root)
        let moveID = try validateProduction(root, databaseID: context.manifest.sourceDatabaseID, forCleanup: true)
        let final = Finalized(sourceBundleID: authority.freeze.sourceBundleID, targetBundleID: authority.freeze.targetBundleID,
            targetDataRoot: root.path, snapshotID: context.manifest.snapshotID, sourceDatabaseID: context.manifest.sourceDatabaseID,
            moveStoreID: moveID, manifestSHA256: context.sha,
            migrationLedgerSHA256: digest(try read(root.appendingPathComponent("MigrationLedger.json"), limit: 32 * 1024 * 1024)),
            authorityReceiptSHA256: authority.authoritySHA, activationReceiptSHA256: authority.activationSHA,
            issuedAt: ISO8601DateFormatter().string(from: Date()))
        let pending = root.appendingPathComponent(".SourceRetirementFinalized.pending.json")
        if exists(pending) {
            // A previous pre-commit interruption is a complete private receipt,
            // reused only after the same current authority/data checks pass.
            _ = try checkedFinalized(root, receiptURL: pending)
        } else {
            let payload = try encode(final)
            try writeNew(try json(["schemaVersion": 1, "payload": payload.base64EncodedString(), "sha256": digest(payload)]), to: pending)
        }
        try testingFault?(.beforeCommit)
        try renameNew(pending, finalURL) // file fsync + EXCL rename + directory fsync
        try testingFault?(.afterCommit)
        let committed = try checkedFinalized(root, receiptURL: finalURL)
        return retirementReport(committed, root: root, already: false)
    }

    private static func retirementReport(_ final: Finalized, root: URL, already: Bool) -> OrganizerRetirementReport {
        OrganizerRetirementReport(snapshotID: final.snapshotID, sourceDatabaseID: final.sourceDatabaseID,
            destinationPath: root.path, receiptPath: root.appendingPathComponent(finalizedName).path,
            deletablePaths: cleanupNames.map { root.appendingPathComponent($0).path }, alreadyFinalized: already)
    }

    private static func checkedFinalized(_ root: URL, receiptURL: URL) throws -> Finalized {
        let final = try JSONDecoder().decode(Finalized.self, from: decodedEnvelope(object(privateReceipt(receiptURL)), schema: true))
        let authority = try checkedAuthority(root)
        try require(final.schemaVersion == 1 && final.kind == "GaoSeriesSourceRetirementFinalized"
            && final.sourceBundleID == "com.gaoseries.GaoZhengLi" && final.targetBundleID == "com.gaoseries.GaoWenJian"
            && final.targetDataRoot == root.path && final.snapshotID == authority.freeze.snapshotID
            && UUID(uuidString: final.sourceDatabaseID) != nil && UUID(uuidString: final.moveStoreID) != nil
            && final.manifestSHA256 == authority.freeze.manifestSHA256 && validSHA(final.migrationLedgerSHA256)
            && final.authorityReceiptSHA256 == authority.authoritySHA && final.activationReceiptSHA256 == authority.activationSHA
            && final.indexSchemaVersion == 2 && final.configurationSchemaVersion == 1 && final.moveSchemaVersion == 1
            && final.archiveNoLongerRequired && final.explicitCoordinatorAcceptance
            && final.cleanupPolicy == "root-only-exact-source-archive-allowlist" && validDate(final.issuedAt, notFuture: true),
            "退役完成凭据损坏、过新或不属于本次权威/目标；停止写入且不降级。")
        if exists(root.appendingPathComponent("MigrationLedger.json")) {
            let bytes = try read(root.appendingPathComponent("MigrationLedger.json"), limit: 32 * 1024 * 1024)
            let original = try JSONDecoder().decode(Receipt.self, from: decodedEnvelope(object(bytes), schema: true))
            try require(digest(bytes) == final.migrationLedgerSHA256 && original.schemaVersion == 1
                && original.snapshotSHA256 == final.manifestSHA256 && original.report.snapshotID == final.snapshotID
                && original.report.sourceDatabaseID == final.sourceDatabaseID && original.report.destinationPath == root.path,
                "退役凭据与尚存的原迁移账本不配对。")
        }
        try require(try validateProduction(root, databaseID: final.sourceDatabaseID) == final.moveStoreID,
            "退役完成凭据不属于现用物理整理库。")
        return final
    }

    private static func existingExclusiveLock(_ url: URL) throws -> Int32 {
        _ = try safe(url)
        let fd = Darwin.open(url.path, O_RDWR | O_NOFOLLOW | O_CLOEXEC)
        try require(fd >= 0, "退役前需停止现用写者并保留原锁文件。")
        do {
            var state = stat(), pathState = stat()
            try require(fstat(fd, &state) == 0 && lstat(url.path, &pathState) == 0 && unchanged(state, pathState)
                && state.st_uid == getuid() && state.st_mode & S_IFMT == S_IFREG && state.st_nlink == 1
                && state.st_mode & 0o077 == 0 && flock(fd, LOCK_EX | LOCK_NB) == 0,
                "现用整理写者尚未停止，或原锁身份异常；不收尾也不删除。")
            return fd
        } catch { close(fd); throw error }
    }

    private static func validSHA(_ value: String) -> Bool {
        value.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
    private static func validDate(_ value: String, notFuture: Bool = false) -> Bool {
        let formatter = ISO8601DateFormatter()
        if let date = formatter.date(from: value) { return !notFuture || date <= Date().addingTimeInterval(60) }
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let date = formatter.date(from: value) else { return false }
        return !notFuture || date <= Date().addingTimeInterval(60)
    }

    /// Explicit activation is separate from import. This verifies the supplied
    /// coordinator declaration, not a digital signature or transferred OS grant.
    /// The coordinator must have actually stopped/frozen the source writers.
    static func activate(destination: URL, authorityReceipt: URL) throws -> OrganizerMigrationReport {
        let root = try safe(destination)
        let context = try migrationContext(root)
        let bytes = try privateReceipt(authorityReceipt)
        let freeze = try JSONDecoder().decode(FreezeReceipt.self, from: bytes)
        try validateFreeze(freeze, manifest: context.manifest, manifestSHA: context.sha, destination: root)
        let savedAuthority = root.appendingPathComponent("SourceAuthorityReceipt.json")
        let savedActivation = root.appendingPathComponent("ActivationReceipt.json")
        if exists(savedActivation) {
            try require(exists(savedAuthority) && privateReceipt(savedAuthority) == bytes, "已激活来源收据不同；不覆盖当前权威或用户资料。")
            try requireActiveAuthority(directory: root)
            var result = context.receipt.report; result.alreadyImported = true
            return result
        }
        if exists(savedAuthority) {
            try require(try privateReceipt(savedAuthority) == bytes, "中断激活收据冲突；保留原凭据，不进行覆盖。")
        } else { try writeNew(bytes, to: savedAuthority) }
        let activation = Activation(snapshotID: freeze.snapshotID, manifestSHA256: freeze.manifestSHA256,
            sourceBundleID: freeze.sourceBundleID, targetBundleID: freeze.targetBundleID,
            sourceDataRoot: freeze.sourceDataRoot, targetDataRoot: root.path,
            sourceInventorySHA256: freeze.sourceInventorySHA256, sourcePreferencesSHA256: freeze.sourcePreferencesSHA256,
            authorityReceiptSHA256: digest(bytes), issuedAt: freeze.issuedAt)
        let payload = try encode(activation)
        try writeNew(try json(["schemaVersion": 1, "payload": payload.base64EncodedString(), "sha256": digest(payload)]), to: savedActivation)
        try requireActiveAuthority(directory: root)
        return context.receipt.report
    }

    private static func migrationContext(_ root: URL) throws -> (receipt: Receipt, manifest: Manifest, sha: String) {
        let ledgerEnvelope = try object(read(root.appendingPathComponent("MigrationLedger.json"), limit: 32 * 1024 * 1024))
        let ledger = try JSONDecoder().decode(Receipt.self, from: decodedEnvelope(ledgerEnvelope, schema: true))
        let receipt = try checkedReceipt(root, manifestSHA: ledger.snapshotSHA256)
        let data = try read(root.appendingPathComponent("SourceArchive/snapshot.json"), limit: 32 * 1024 * 1024)
        try require(digest(data) == receipt.snapshotSHA256, "来源归档与迁移记录不配对。")
        let manifest = try JSONDecoder().decode(Manifest.self, from: data)
        try require(manifest.schemaVersion == 1 && manifest.snapshotID == receipt.report.snapshotID
            && manifest.sourceDatabaseID == receipt.report.sourceDatabaseID && receipt.report.destinationPath == root.path,
            "迁移记录不属于当前目标。")
        return (receipt, manifest, receipt.snapshotSHA256)
    }
    private static func validateFreeze(_ receipt: FreezeReceipt, manifest: Manifest, manifestSHA: String, destination: URL) throws {
        let formatter = ISO8601DateFormatter()
        let ordinary = formatter.date(from: receipt.issuedAt)
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let timestamp = ordinary ?? formatter.date(from: receipt.issuedAt)
        try require(receipt.schemaVersion == 1 && receipt.kind == "GaoSeriesSourceWriteFreeze"
            && receipt.sourceBundleID == "com.gaoseries.GaoZhengLi" && receipt.targetBundleID == "com.gaoseries.GaoWenJian"
            && receipt.sourceDataRoot == manifest.sourceDataRoot && receipt.targetDataRoot == destination.path
            && receipt.snapshotID == manifest.snapshotID && receipt.manifestSHA256 == manifestSHA
            && receipt.sourceInventorySHA256 == manifest.sourceInventorySHA256
            && receipt.sourcePreferencesSHA256 == manifest.sourcePreferencesSHA256
            && receipt.writersStopped && receipt.sourceFrozen && timestamp != nil,
            "需要本次完整快照对应的正式停写收据；预备基线、损坏或不同目标的收据不能启用生产权威。")
    }
    private static func privateReceipt(_ url: URL) throws -> Data {
        _ = try safe(url)
        var info = stat()
        try require(lstat(url.path, &info) == 0 && info.st_uid == getuid() && info.st_mode & S_IFMT == S_IFREG
            && info.st_nlink == 1 && info.st_mode & 0o7777 == 0o600,
            "权威收据必须是当前用户拥有的独立 0600 普通文件。")
        return try read(url, limit: 1024 * 1024)
    }

    private static func checkedReceipt(_ root: URL, manifestSHA: String) throws -> Receipt {
        _ = try safe(root)
        let envelope = try object(read(root.appendingPathComponent("MigrationLedger.json"), limit: 32 * 1024 * 1024))
        let receipt = try JSONDecoder().decode(Receipt.self, from: decodedEnvelope(envelope, schema: true))
        try require(receipt.schemaVersion == 1 && receipt.snapshotSHA256 == manifestSHA && receipt.report.destinationPath.hasSuffix("/Organizer")
            && receipt.authority == "destination-only-after-explicit-source-retirement"
            && receipt.associationHistoryOnly && receipt.exchangeHistoryOnly,
            "目标已有资料或迁移记录损坏，不进行覆盖。")
        try require(try inventory(root.appendingPathComponent("SourceArchive")) == receipt.archiveEntries, "不可变来源归档变化；保留目标且停止。")
        return receipt
    }
    private static func ensureAnchor(_ url: URL) throws {
        if exists(url) { try require(try read(url, limit: 64) == Data("schema=1\n".utf8), "接收方初始化标记损坏。") }
        else { try writeNew(Data("schema=1\n".utf8), to: url); try sync(url.deletingLastPathComponent()) }
    }

    private static func migrateConfiguration(_ root: URL, replacements: [String: String], rootIDs: Set<String>) throws {
        var config = try protectedObject(root, name: "configuration")
        try require(config["schemaVersion"] as? Int == 1 && config["workspaces"] is [[String: Any]] && config["savedQueries"] is [[String: Any]], "工作区配置损坏或过新。")
        let workspaces = config["workspaces"] as! [[String: Any]], queries = config["savedQueries"] as! [[String: Any]]
        try uniqueUUIDs(workspaces); try uniqueUUIDs(queries)
        for workspace in workspaces {
            guard workspace["name"] is String, let panels = workspace["panels"] as? [[String: Any]] else { throw OrganizerMigrationFailure("虚拟工作区结构损坏。") }
            try uniqueUUIDs(panels)
            try require(panels.allSatisfy { $0["name"] is String && ["directory", "query", "favorites"].contains($0["kind"] as? String ?? "") }, "虚拟面板类型不受支持。")
        }
        try validateIDs(config, rootIDs: rootIDs)
        config = try rewritten(config, replacements: replacements) as! [String: Any]
        config["automaticMonitoring"] = false
        try writeProtected(config, to: root.appendingPathComponent("configuration.json"))
    }
    private static func migrateAssociations(_ root: URL, replacements: [String: String]) throws {
        let items = try protectedValue(root, name: "associations_history")
        guard var history = items as? [[String: Any]] else { throw OrganizerMigrationFailure("关联历史不是受支持格式。") }
        var seen = Set<String>()
        for i in history.indices {
            guard let id = history[i]["id"] as? String, UUID(uuidString: id) != nil, seen.insert(id).inserted else { throw OrganizerMigrationFailure("关联历史 ID 损坏或重复。") }
            if history[i]["status"] as? String == "pending" {
                history[i]["status"] = "interrupted"; history[i]["detail"] = "已迁移历史；必须显式核对当前系统关联，不会自动应用旧请求。"
            }
        }
        // System association history must keep the application actually requested
        // at the time; copied .app files must never become new default handlers.
        try writeProtected(history, to: root.appendingPathComponent("associations_history.json"))
    }
    private static func migrateMoves(_ root: URL, replacements: [String: String], retiring: [String]) throws -> Bool {
        let url = root.appendingPathComponent("MovePlans/ledger.json")
        let env = try object(read(url, limit: 32 * 1024 * 1024))
        let payload = try decodedEnvelope(env, schema: false)
        var value = try object(payload)
        guard var plans = value["plans"] as? [[String: Any]] else { throw OrganizerMigrationFailure("整理日志损坏。") }
        var recovery = false
        for i in plans.indices {
            guard let operations = plans[i]["operations"] as? [[String: Any]] else { throw OrganizerMigrationFailure("整理操作日志缺失。") }
            if operations.contains(where: { ["renameIntent", "moved", "rollbackIntent"].contains($0["state"] as? String ?? "") }) || ["executing", "awaitingConfirmation", "validated"].contains(plans[i]["state"] as? String ?? "") {
                recovery = true; plans[i]["state"] = "needsRecovery"
                plans[i]["failure"] = "迁移保留原物理身份与历史；需重新授权并核对原件或保留副本，不会自动执行或回滚。"
            }
        }
        value["plans"] = plans
        value = try rewritten(value, replacements: replacements) as! [String: Any]
        try rejectRetiringReferences(value, prefixes: retiring)
        let bytes = try json(value)
        try replaceOwned(try json(["payload": bytes.base64EncodedString(), "sha256": digest(bytes)]), at: url)
        return recovery
    }
    private static func validateIDs(_ value: Any, rootIDs: Set<String>) throws {
        if let dict = value as? [String: Any] {
            for (key, item) in dict {
                if key == "rootID", let id = item as? String { try require(rootIDs.contains(id), "配置引用了不存在的索引根。") }
                try validateIDs(item, rootIDs: rootIDs)
            }
        } else if let list = value as? [Any] { for item in list { try validateIDs(item, rootIDs: rootIDs) } }
    }
    private static func rewritten(_ value: Any, replacements: [String: String]) throws -> Any {
        if let dict = value as? [String: Any] { return try dict.mapValues { try rewritten($0, replacements: replacements) } }
        if let list = value as? [Any] { return try list.map { try rewritten($0, replacements: replacements) } }
        if let text = value as? String {
            let fileURL = text.hasPrefix("file://") ? URL(string: text) : nil
            let path = fileURL?.path ?? text
            for old in replacements.keys.sorted(by: { $0.count > $1.count }) where path == old || path.hasPrefix(old + "/") {
                let new = replacements[old]! + String(path.dropFirst(old.count))
                return fileURL == nil ? new : URL(fileURLWithPath: new).absoluteString
            }
        }
        return value
    }
    private static func rejectRetiringReferences(_ value: Any, prefixes: [String]) throws {
        if let dict = value as? [String: Any] { for item in dict.values { try rejectRetiringReferences(item, prefixes: prefixes) } }
        else if let list = value as? [Any] { for item in list { try rejectRetiringReferences(item, prefixes: prefixes) } }
        else if let text = value as? String {
            let path = text.hasPrefix("file://") ? URL(string: text)?.path ?? text : text
            try require(!prefixes.contains { path == $0 || path.hasPrefix($0 + "/") }, "运行资料仍引用即将退役的来源私有路径，停止迁移。")
        }
    }

    private static func validateProduction(_ root: URL, databaseID: String, forCleanup: Bool = false) throws -> String {
        try require(try read(root.deletingLastPathComponent().appendingPathComponent("Organizer.initialized"), limit: 64)
            == Data("schema=1\n".utf8), "现用整理模块缺少配对初始化依据。")
        try validateStore(root, databaseID: databaseID, readonly: true, live: true)
        let marker = try object(read(root.appendingPathComponent("MovePlans/initialized.json"), limit: 4096))
        guard let moveID = marker["storeID"] as? String, UUID(uuidString: moveID) != nil else {
            throw OrganizerMigrationFailure("现用物理整理库身份缺失。")
        }
        if forCleanup {
            let blockedComponents = cleanupNames.map { root.appendingPathComponent($0).standardizedFileURL.pathComponents }
            func checkLiveReference(_ url: URL) throws {
                try require(url.isFileURL && url.path.hasPrefix("/"), "现用整理引用不是本机绝对路径。")
                // Compare lexical and real aliases; no old bookmark is resolved
                // and no scope or permission is inherited from this check.
                // Directory URLs may retain a trailing separator in .path.
                // Component ancestry avoids a mistaken double-slash prefix.
                for candidate in [url.standardizedFileURL, url.resolvingSymlinksInPath().standardizedFileURL] {
                    try require(!blockedComponents.contains { candidate.pathComponents.starts(with: $0) },
                        "现用索引或移动实物仍引用待删来源归档，停止退役收尾。")
                }
            }
            // Only actual path-bearing business fields are dependencies. Free
            // search text and historical association/journal descriptions are
            // not rewritten or treated as references to live source bytes.
            try withDatabase(root.appendingPathComponent("metadata.sqlite"), readonly: true, immutableSnapshot: false) { db in
                try exec(db, "BEGIN"); defer { try? exec(db, "ROLLBACK") }
                for path in try values(db, "SELECT path FROM authorized_roots") {
                    try require(path.hasPrefix("/"), "现用索引根不是本机绝对路径。")
                    try checkLiveReference(URL(fileURLWithPath: path))
                }
            }
            let payload = try decodedEnvelope(object(read(root.appendingPathComponent("MovePlans/ledger.json"), limit: 32 * 1024 * 1024)), schema: false)
            struct Moves: Decodable { let plans: [OFMovePlan] }
            for plan in try JSONDecoder().decode(Moves.self, from: payload).plans {
                var urls = plan.operations.flatMap { [$0.source, $0.destination] } + plan.sourceRoots.map(\.url)
                if let destination = plan.destinationRoot { urls.append(destination.url) }
                for url in urls { try checkLiveReference(url) }
            }
        }
        return moveID
    }

    private static func validateStore(_ root: URL, databaseID: String, readonly: Bool, live: Bool = false) throws {
        for rel in required { _ = try safe(root.appendingPathComponent(rel)) }
        var moveDirectoryInfo = stat()
        try require(lstat(root.appendingPathComponent("MovePlans").path, &moveDirectoryInfo) == 0
            && moveDirectoryInfo.st_mode & S_IFMT == S_IFDIR && moveDirectoryInfo.st_uid == getuid()
            && moveDirectoryInfo.st_mode & 0o077 == 0, "来源物理整理目录不符合生产私有权限，不静默改写。")
        for rel in ["MovePlans/initialized.json", "MovePlans/ledger.json", "MovePlans.initialized"] {
            var info = stat()
            try require(lstat(root.appendingPathComponent(rel).path, &info) == 0 && info.st_mode & S_IFMT == S_IFREG
                && info.st_uid == getuid() && info.st_nlink == 1 && info.st_mode & 0o077 == 0,
                "来源物理整理账本类型或私有权限不符合实际引擎，停止迁移且保留原属性。")
        }
        for name in ["configuration", "associations_history"] {
            try require(try read(root.appendingPathComponent(name + ".initialized"), limit: 64) == Data("schema=1\n".utf8), "受保护资料初始化标记缺失或损坏。")
            _ = try protectedValue(root, name: name)
        }
        let configEnvelope = try object(read(root.appendingPathComponent("configuration.json"), limit: 32 * 1024 * 1024))
        let configuration = try JSONDecoder().decode(OFLibraryConfiguration.self, from: decodedEnvelope(configEnvelope, schema: true))
        try require(configuration.schemaVersion == 1, "工作区格式过新。")
        let associationEnvelope = try object(read(root.appendingPathComponent("associations_history.json"), limit: 32 * 1024 * 1024))
        _ = try JSONDecoder().decode([OFAssociationRecord].self, from: decodedEnvelope(associationEnvelope, schema: true))
        let marker = try object(read(root.appendingPathComponent("index-initialized.json"), limit: 1024 * 1024))
        try require((1...2).contains(marker["schemaVersion"] as? Int ?? 0) && marker["databaseID"] as? String == databaseID, "索引初始化身份不匹配。")
        try require(!live || marker["schemaVersion"] as? Int == 2, "现用索引标记必须为已迁移的 schema 2。")
        try withDatabase(root.appendingPathComponent("metadata.sqlite"), readonly: readonly, immutableSnapshot: !live) { db in
            if live { try exec(db, "BEGIN") }
            defer { if live { try? exec(db, "ROLLBACK") } }
            try checkDatabase(db, databaseID: databaseID)
            if live {
                try require(try values(db, "PRAGMA user_version") == ["2"], "现用索引 schema 不支持退役收尾。")
                let columns = [
                    "authorized_roots": "id,display_name,path,bookmark,volume,device,inode,root_created,status,paused,last_scan,last_event,diagnostic",
                    "files": "id,root_id,relative_path,name,extension,uti,size,modified,created,is_directory,is_package,is_symlink,is_placeholder,device,inode,volume,name_norm,path_norm,generation,tags,favorite",
                    "scan_checkpoints": "root_id,payload,updated_at", "staged_files": "root_id,generation,payload,file_id,relative_path",
                    "schema_history": "version,applied_at", "organizer_migration_ids": "kind,source_id,target_id"
                ]
                for (table, list) in columns { _ = try values(db, "SELECT \(list) FROM \(table) LIMIT 0") }
            }
        }
        let moveMarker = try object(read(root.appendingPathComponent("MovePlans/initialized.json"), limit: 4096))
        let anchor = try object(read(root.appendingPathComponent("MovePlans.initialized"), limit: 4096))
        let movePayload = try decodedEnvelope(object(read(root.appendingPathComponent("MovePlans/ledger.json"), limit: 32 * 1024 * 1024)), schema: false)
        struct TypedMoves: Decodable { let schemaVersion: Int; let storeID: UUID; let plans: [OFMovePlan] }
        _ = try JSONDecoder().decode(TypedMoves.self, from: movePayload)
        let moves = try object(movePayload)
        try require(moveMarker["schemaVersion"] as? Int == 1 && NSDictionary(dictionary: moveMarker).isEqual(to: anchor)
            && moves["schemaVersion"] as? Int == 1 && moves["storeID"] as? String == moveMarker["storeID"] as? String
            && UUID(uuidString: moves["storeID"] as? String ?? "") != nil, "物理整理日志的独立初始化依据不完整。")
        guard let plans = moves["plans"] as? [[String: Any]], plans.count <= 1000 else { throw OrganizerMigrationFailure("物理整理日志不受支持。") }
        try uniqueUUIDs(plans)
        for plan in plans {
            guard let operations = plan["operations"] as? [[String: Any]], operations.count <= 256 else { throw OrganizerMigrationFailure("物理整理操作格式损坏。") }
            try uniqueUUIDs(operations)
        }
    }
    private static func uniqueUUIDs(_ rows: [[String: Any]]) throws {
        var seen = Set<UUID>()
        for row in rows {
            guard let text = row["id"] as? String, let id = UUID(uuidString: text), seen.insert(id).inserted else { throw OrganizerMigrationFailure("来源记录含损坏或重复 ID。") }
        }
    }
    private static func checkDatabase(_ db: OpaquePointer, databaseID: String) throws {
        try require(try values(db, "PRAGMA quick_check") == ["ok"], "SQLite 一致性检查失败。")
        let version = Int(try values(db, "PRAGMA user_version").first ?? "0") ?? 0
        try require((1...2).contains(version), "索引数据库过新或不是支持的版本。")
        try require(try values(db, "SELECT value FROM index_meta WHERE key='databaseID'") == [databaseID], "数据库与独立初始化标记不配对。")
        try require(try values(db, "PRAGMA foreign_key_check").isEmpty, "索引存在断开的根引用。")
        let expected = Set(["index_meta", "schema_history", "authorized_roots", "files", "scan_checkpoints", "staged_files"])
        let tables = Set(try values(db, "SELECT name FROM sqlite_master WHERE type='table'"))
        try require(expected.isSubset(of: tables), "索引数据库缺少完整业务表。")
        let rootIDs = try values(db, "SELECT id FROM authorized_roots")
        try require(rootIDs.allSatisfy { UUID(uuidString: $0) != nil } && Set(rootIDs).count == rootIDs.count, "索引根 ID 损坏。")
    }
    private static func migrateDatabase(_ url: URL, databaseID: String, replacements: [String: String]) throws -> (roots: Int, files: Int, ids: Set<String>) {
        try withDatabase(url, readonly: false) { db in
            try checkDatabase(db, databaseID: databaseID)
            let ids = Set(try values(db, "SELECT id FROM authorized_roots"))
            let fileCount = Int(try values(db, "SELECT count(*) FROM files").first ?? "-1") ?? -1
            try exec(db, "PRAGMA journal_mode=DELETE; PRAGMA synchronous=FULL; BEGIN IMMEDIATE")
            do {
                let rootColumns = Set(try tableColumns(db, "authorized_roots"))
                if !rootColumns.contains("root_created") { try exec(db, "ALTER TABLE authorized_roots ADD COLUMN root_created REAL NOT NULL DEFAULT 0") }
                let fileColumns = Set(try tableColumns(db, "files"))
                if !fileColumns.contains("tags") { try exec(db, "ALTER TABLE files ADD COLUMN tags TEXT NOT NULL DEFAULT '[]'") }
                if !fileColumns.contains("favorite") { try exec(db, "ALTER TABLE files ADD COLUMN favorite INTEGER NOT NULL DEFAULT 0") }
                let version = Int(try values(db, "PRAGMA user_version").first ?? "0") ?? 0
                if version == 1 { try exec(db, "INSERT INTO schema_history(version,applied_at) VALUES(2,strftime('%s','now')); PRAGMA user_version=2") }
                for old in try values(db, "SELECT path FROM authorized_roots") {
                    let new = try rewritten(old, replacements: replacements) as! String
                    if new != old { try bound(db, "UPDATE authorized_roots SET path=? WHERE path=?", [new, old]) }
                }
                try exec(db, "UPDATE authorized_roots SET bookmark=X'',status='needsAuthorization',paused=1,diagnostic='迁入搞文件；旧书签仅留归档，必须重新选择目录授权'")
                try exec(db, "CREATE TABLE organizer_migration_ids(kind TEXT NOT NULL,source_id TEXT NOT NULL,target_id TEXT NOT NULL,PRIMARY KEY(kind,source_id)); INSERT INTO organizer_migration_ids SELECT 'root',id,id FROM authorized_roots; INSERT INTO organizer_migration_ids SELECT 'file',id,id FROM files")
                // Interrupted scan input remains in SourceArchive; no automatic
                // continuation can consume a source app's cached authorization.
                try exec(db, "DELETE FROM scan_checkpoints; DELETE FROM staged_files; COMMIT")
            } catch { try? exec(db, "ROLLBACK"); throw error }
            try checkDatabase(db, databaseID: databaseID)
            return (ids.count, fileCount, ids)
        }
    }
    private static func withDatabase<T>(_ url: URL, readonly: Bool, immutableSnapshot: Bool = true, _ body: (OpaquePointer) throws -> T) throws -> T {
        _ = try safe(url)
        var handle: OpaquePointer?
        // Immutable is exclusively for an exported standalone snapshot. Live
        // production validation must see committed WAL and take a read snapshot.
        let path = readonly && immutableSnapshot ? url.absoluteString + "?immutable=1" : url.path
        let flags = readonly ? SQLITE_OPEN_READONLY | SQLITE_OPEN_NOFOLLOW | (immutableSnapshot ? SQLITE_OPEN_URI : 0) : SQLITE_OPEN_READWRITE | SQLITE_OPEN_NOFOLLOW
        let result = sqlite3_open_v2(path, &handle, flags | SQLITE_OPEN_FULLMUTEX, nil)
        guard result == SQLITE_OK, let db = handle else { if let handle { sqlite3_close(handle) }; throw OrganizerMigrationFailure("无法打开迁移索引，未替换原资料。") }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 3000)
        return try body(db)
    }
    private static func exec(_ db: OpaquePointer, _ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw OrganizerMigrationFailure("迁移 SQL 失败：" + String(cString: sqlite3_errmsg(db))) }
    }
    private static func values(_ db: OpaquePointer, _ sql: String) throws -> [String] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else { throw OrganizerMigrationFailure("索引表结构与支持格式不符。") }
        defer { sqlite3_finalize(statement) }
        var values: [String] = []
        while true {
            let step = sqlite3_step(statement)
            if step == SQLITE_DONE { return values }
            try require(step == SQLITE_ROW, "读取索引内容失败。")
            if let p = sqlite3_column_text(statement, 0) { values.append(String(cString: p)) } else { values.append("") }
        }
    }
    private static func tableColumns(_ db: OpaquePointer, _ table: String) throws -> [String] {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "PRAGMA table_info(\(table))", -1, &stmt, nil) == SQLITE_OK, let stmt else { throw OrganizerMigrationFailure("表结构读取失败。") }
        defer { sqlite3_finalize(stmt) }
        var names: [String] = []
        while sqlite3_step(stmt) == SQLITE_ROW { if let name = sqlite3_column_text(stmt, 1) { names.append(String(cString: name)) } }
        return names
    }
    private static func bound(_ db: OpaquePointer, _ sql: String, _ values: [String]) throws {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { throw OrganizerMigrationFailure("路径映射语句失败。") }
        defer { sqlite3_finalize(stmt) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (i, value) in values.enumerated() { try require(sqlite3_bind_text(stmt, Int32(i + 1), value, -1, transient) == SQLITE_OK, "路径映射绑定失败。") }
        try require(sqlite3_step(stmt) == SQLITE_DONE, "路径映射写入失败。")
    }
    private static func protectedObject(_ root: URL, name: String) throws -> [String: Any] {
        guard let value = try protectedValue(root, name: name) as? [String: Any] else { throw OrganizerMigrationFailure("受保护资料结构不符。") }
        return value
    }
    private static func protectedValue(_ root: URL, name: String) throws -> Any {
        try require(try read(root.appendingPathComponent(name + ".initialized"), limit: 64) == Data("schema=1\n".utf8), "受保护资料缺少初始化依据。")
        let data = try decodedEnvelope(object(read(root.appendingPathComponent(name + ".json"), limit: 32 * 1024 * 1024)), schema: true)
        return try JSONSerialization.jsonObject(with: data)
    }
    private static func decodedEnvelope(_ value: [String: Any], schema: Bool) throws -> Data {
        try require(!schema || value["schemaVersion"] as? Int == 1, "受保护文档版本过新。")
        guard let text = value["payload"] as? String, let payload = Data(base64Encoded: text), digest(payload) == value["sha256"] as? String else { throw OrganizerMigrationFailure("受保护文档摘要冲突。") }
        return payload
    }
    private static func writeProtected(_ value: Any, to url: URL) throws {
        let payload = try json(value)
        try replaceOwned(try json(["schemaVersion": 1, "payload": payload.base64EncodedString(), "sha256": digest(payload)]), at: url)
    }
    private static func object(_ data: Data) throws -> [String: Any] {
        guard let value = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw OrganizerMigrationFailure("JSON 对象结构损坏。") }
        return value
    }
    private static func json(_ value: Any) throws -> Data { try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) }
    private static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(value)
    }
    private static func require(_ value: Bool, _ text: String) throws { if !value { throw OrganizerMigrationFailure(text) } }
    private static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    private static func exists(_ url: URL) -> Bool { var info = stat(); return lstat(url.path, &info) == 0 }
    private static func relativePath(_ path: String) throws -> String {
        try require(!path.isEmpty && !path.hasPrefix("/") && path.split(separator: "/", omittingEmptySubsequences: false).allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }, "快照包含不安全相对路径。")
        return path
    }
    private static func safe(_ url: URL) throws -> URL {
        try require(url.isFileURL && url.path.hasPrefix("/") && !url.pathComponents.contains(".."), "只接受绝对本机路径。")
        var current = URL(fileURLWithPath: "/", isDirectory: true)
        for component in url.pathComponents.dropFirst() {
            current.appendPathComponent(component)
            var info = stat()
            try require(lstat(current.path, &info) == 0 && info.st_mode & S_IFMT != S_IFLNK, "路径缺失或含符号链接：\(current.path)")
        }
        return url
    }
    private static func read(_ url: URL, limit: Int) throws -> Data {
        _ = try safe(url)
        let fd = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        try require(fd >= 0, "资料无法读取。")
        defer { close(fd) }
        var a = stat(), b = stat()
        try require(fstat(fd, &a) == 0 && a.st_mode & S_IFMT == S_IFREG && a.st_nlink == 1 && a.st_uid == getuid()
            && a.st_size >= 0 && a.st_size <= limit && a.st_flags & UInt32(SF_DATALESS) == 0, "资料对象不安全、过大或尚未下载。")
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
        let data = try handle.readToEnd() ?? Data()
        try require(fstat(fd, &b) == 0 && unchanged(a, b) && data.count == a.st_size, "资料读取期间变化。")
        return data
    }
    private static func unchanged(_ a: stat, _ b: stat) -> Bool {
        a.st_dev == b.st_dev && a.st_ino == b.st_ino && a.st_mode == b.st_mode && a.st_uid == b.st_uid && a.st_gid == b.st_gid
            && a.st_nlink == b.st_nlink && a.st_size == b.st_size && a.st_mtimespec.tv_sec == b.st_mtimespec.tv_sec
            && a.st_mtimespec.tv_nsec == b.st_mtimespec.tv_nsec && a.st_ctimespec.tv_sec == b.st_ctimespec.tv_sec && a.st_ctimespec.tv_nsec == b.st_ctimespec.tv_nsec
    }
    private static func inventory(_ root: URL) throws -> [Entry] {
        _ = try safe(root)
        var result: [Entry] = []
        func visit(_ url: URL, _ path: String) throws {
            var a = stat(), b = stat()
            try require(lstat(url.path, &a) == 0 && a.st_uid == getuid(), "资料对象身份无法核对。")
            let directory = a.st_mode & S_IFMT == S_IFDIR
            try require(directory || a.st_mode & S_IFMT == S_IFREG, "快照含链接或特殊对象。")
            let attributes = try attributeHashes(url)
            var size: Int?, hash: String?
            if directory {
                for child in try fm.contentsOfDirectory(at: url, includingPropertiesForKeys: nil).sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                    try visit(child, path == "." ? child.lastPathComponent : path + "/" + child.lastPathComponent)
                }
            } else {
                try require(a.st_nlink == 1 && a.st_flags & UInt32(SF_DATALESS) == 0, "附件为硬链接或尚未下载。")
                let fd = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
                try require(fd >= 0, "附件无法读取。")
                let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
                var hasher = SHA256()
                while let data = try handle.read(upToCount: 1024 * 1024), !data.isEmpty { hasher.update(data: data) }
                try handle.close()
                size = Int(a.st_size); hash = hasher.finalize().map { String(format: "%02x", $0) }.joined()
            }
            try require(lstat(url.path, &b) == 0 && unchanged(a, b), "快照在盘点期间变化。")
            result.append(Entry(path: path, kind: directory ? "directory" : "file", mode: Int(a.st_mode & 0o7777), xattrs: attributes, bytes: size, sha256: hash))
        }
        try visit(root, ".")
        return result.sorted { $0.path < $1.path }
    }
    private static func attributeHashes(_ url: URL) throws -> [String: String] {
        let options: Int32 = XATTR_NOFOLLOW | XATTR_SHOWCOMPRESSION | XATTR_NOFOLLOW_ANY
        let count = listxattr(url.path, nil, 0, options)
        try require(count >= 0, "无法完整读取扩展属性。")
        if count == 0 { return [:] }
        var names = [CChar](repeating: 0, count: count)
        try require(listxattr(url.path, &names, count, options) == count && names.last == 0, "扩展属性清单变化。")
        var values: [String: String] = [:]
        let strings = names.dropLast().split(separator: 0)
        for name in strings {
            let text = String(decoding: name.map { UInt8(bitPattern: $0) }, as: UTF8.self)
            let n = getxattr(url.path, text, nil, 0, 0, options)
            try require(n >= 0, "扩展属性内容无法读取。")
            var data = Data(count: n)
            let read = data.withUnsafeMutableBytes { getxattr(url.path, text, $0.baseAddress, n, 0, options) }
            try require(read == n && values[text] == nil, "扩展属性变化或名称重复。")
            values[text] = digest(data)
        }
        return values
    }
    private static func writeNew(_ data: Data, to url: URL) throws {
        _ = try safe(url.deletingLastPathComponent())
        let fd = Darwin.open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        try require(fd >= 0, "迁移输出已存在或不能建立；未覆盖。")
        defer { close(fd) }
        try data.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let n = Darwin.write(fd, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
                if n < 0 && errno == EINTR { continue }
                try require(n > 0, "迁移写入失败。")
                offset += n
            }
        }
        try require(fsync(fd) == 0, "迁移文件无法持久化。")
        try sync(url.deletingLastPathComponent())
    }
    private static func replaceOwned(_ data: Data, at url: URL) throws {
        // Only called inside a freshly allocated private preparation attempt.
        let temp = url.deletingLastPathComponent().appendingPathComponent(".migration-write-" + UUID().uuidString)
        try writeNew(data, to: temp)
        let prior = try read(url, limit: 32 * 1024 * 1024)
        try require(exists(url) && !prior.isEmpty, "准备文件缺失，保留中断现场。")
        try require(renameatx_np(AT_FDCWD, temp.path, AT_FDCWD, url.path, UInt32(RENAME_SWAP | RENAME_NOFOLLOW_ANY)) == 0,
                    "准备资料原子交换失败。")
        try sync(url.deletingLastPathComponent())
        try require(try read(url, limit: 32 * 1024 * 1024) == data && read(temp, limit: 32 * 1024 * 1024) == prior,
                    "准备文件写入后校验失败，原对象仍保留。")
        try fm.removeItem(at: temp) // Exact verified displaced file in this new owned attempt.
        try sync(url.deletingLastPathComponent())
    }
    private static func renameNew(_ source: URL, _ target: URL) throws {
        _ = try safe(source); _ = try safe(target.deletingLastPathComponent())
        try require(!exists(target), "迁移目标已出现，不覆盖现有资料。")
        try require(renameatx_np(AT_FDCWD, source.path, AT_FDCWD, target.path, UInt32(RENAME_EXCL | RENAME_NOFOLLOW_ANY)) == 0, "原子迁移提交失败，已保留原件与准备副本。")
        try sync(source.deletingLastPathComponent()); try sync(target.deletingLastPathComponent())
    }
    private static func sync(_ url: URL) throws {
        let fd = Darwin.open(url.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        try require(fd >= 0, "迁移目录无法同步。")
        defer { close(fd) }
        try require(fsync(fd) == 0, "迁移目录同步失败。")
    }
}
