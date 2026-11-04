// Organizer module port; source application is not a runtime dependency.
import Foundation

enum OFMovePlanState: String, Codable, Sendable {
    case draft, validated, awaitingConfirmation, executing, committed, cancelled, failed, needsRecovery
}

enum OFMoveOperationState: String, Codable, Sendable {
    case pending, validated, renameIntent, moved, rollbackIntent, rolledBack, failed
}

struct OFMoveSnapshot: Codable, Equatable, Sendable {
    var device: Int64
    var inode: UInt64
    var size: Int64
    var modifiedSeconds: Int64
    var modifiedNanoseconds: Int64
    var changedSeconds: Int64
    var changedNanoseconds: Int64
    var mode: UInt32
    var uid: UInt32
    var gid: UInt32
    var flags: UInt32
    var linkCount: UInt64
    var sha256: String
    var metadataSHA256: String

    /// A rename may update ctime. Contents, identity and all captured metadata must remain equal.
    func matchesMovedObject(_ other: OFMoveSnapshot) -> Bool {
        var lhs = self
        lhs.changedSeconds = other.changedSeconds
        lhs.changedNanoseconds = other.changedNanoseconds
        return lhs == other
    }
}

struct OFMoveJournalEntry: Codable, Sendable, Identifiable {
    var id = UUID()
    var date = Date()
    var phase: String
    var detail: String
}

struct OFMoveOperation: Codable, Sendable, Identifiable {
    var id = UUID()
    var source: URL
    var destination: URL
    var snapshot: OFMoveSnapshot?
    var targetSnapshot: OFMoveSnapshot?
    var sourceParentDevice: Int64?
    var sourceParentInode: UInt64?
    var targetParentDevice: Int64?
    var targetParentInode: UInt64?
    var crossVolume: Bool = false
    var state: OFMoveOperationState = .pending
    var journal: [OFMoveJournalEntry] = []
    var failure: String?
}

struct OFMovePlan: Codable, Sendable, Identifiable {
    var id = UUID()
    var revision = 0
    var createdAt = Date()
    var updatedAt = Date()
    var state: OFMovePlanState = .draft
    var operations: [OFMoveOperation]
    var sourceRoots: [OFMoveAuthorization.OFRoot] = []
    var destinationRoot: OFMoveAuthorization.OFRoot?
    var failure: String?
    var estimatedBytes: Int64 { operations.reduce(0) { $0 + ($1.snapshot?.size ?? 0) } }
}

struct OFMoveConfirmation: Sendable {
    let planID: UUID
    let revision: Int
    init(planID: UUID, revision: Int) { self.planID = planID; self.revision = revision }
}

/// These roots must originate in current user authorization. This value does not grant sandbox access.
/// The caller must hold security scopes until the synchronous engine operation returns.
struct OFMoveAuthorization: Sendable {
    struct OFRoot: Codable, Sendable {
        let url: URL
        let device: Int64
        let inode: UInt64
    }
    let sourceRoots: [OFRoot]
    let destinationRoot: OFRoot
    init(sourceRoots: [URL], destinationRoot: URL) throws {
        self.sourceRoots = try sourceRoots.map { try OFMoveEngine.authorizationRoot($0) }
        self.destinationRoot = try OFMoveEngine.authorizationRoot(destinationRoot)
        guard !self.sourceRoots.isEmpty else { throw OFMoveError.denied("没有来源目录授权。") }
    }
}

enum OFMoveFaultPoint: String, Sendable {
    case beforeJournal, afterJournal, beforeRename, afterRename, beforeCommit, afterCommit
    case beforeRollback, afterRollback
}

/// Tests use this to leave exactly the on-disk state a killed process would leave.
struct OFMoveInjectedCrash: Error {}

enum OFMoveError: Error, LocalizedError {
    case denied(String), unsupported(String), conflict(String), changed(String), invalid(String), storage(String), cancelled(String)
    var errorDescription: String? {
        switch self {
        case .denied(let s), .unsupported(let s), .conflict(let s), .changed(let s), .invalid(let s), .storage(let s), .cancelled(let s): return s
        }
    }
}
