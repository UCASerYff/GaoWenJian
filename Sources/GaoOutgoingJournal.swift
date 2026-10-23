import Foundation
import CryptoKit
import Darwin

struct GaoOutgoingSourceBinding: Codable, Equatable {
    var itemID: String
    var originalReference: GaoActionReference?
    /// Which version the user explicitly chose. It never authorizes a write to the original.
    var versionKind: String
    init(itemID: String, originalReference: GaoActionReference? = nil, versionKind: String = "original") {
        self.itemID = itemID; self.originalReference = originalReference; self.versionKind = versionKind
    }
}
struct GaoOutgoingSource: Codable, Equatable {
    var item: GaoActionItem
    var privateRelativePath: String
    var binding: GaoOutgoingSourceBinding
}
enum GaoOutgoingPhase: String, Codable {
    case prepared, dispatched, dispatchFailed, pending, partial, completed, cancelled, failed, unsupported
    var terminal: Bool { [.completed,.cancelled,.failed,.unsupported].contains(self) }
}
struct GaoOutgoingSession: Codable, Equatable, Identifiable {
    var requestID: String
    var manifestSHA256: String
    var action: String
    var targetBundleID: String
    var requestPackageName: String
    var createdAt: String
    var updatedAt: String
    var phase: GaoOutgoingPhase
    var sources: [GaoOutgoingSource]
    var id: String { requestID }
}
struct GaoOutgoingResultOutput: Codable, Equatable {
    var resultItemID: String
    var sourceItemID: String?
    var sourceSHA256: String?
    var format: String?
    var itemSHA256: String
    var uti: String
    fileprivate var contentKey: String { [sourceItemID ?? "",sourceSHA256 ?? "",uti,itemSHA256].joined(separator:"\u{001f}") }
}
enum GaoOutgoingResultPhase: String, Codable {
    case received, approved, executing, completed, cancelled, failed, interrupted
    var terminal: Bool { [.completed,.cancelled,.failed,.interrupted].contains(self) }
}
struct GaoOutgoingResultRecord: Codable, Equatable, Identifiable {
    var requestID: String
    var inReplyTo: String
    var manifestSHA256: String
    var status: String
    var phase: GaoOutgoingResultPhase
    var executionStarted: Bool
    var receivedAt: String
    var updatedAt: String
    var outputs: [GaoOutgoingResultOutput]
    var referenceIDs: [String]
    var referenceFingerprints: [String:String]
    var openedItemIDs: [String]
    var openedReferenceIDs: [String]
    var errorCode: String?
    /// Nil preserves records written before per-source research progress was
    /// retained; new receipts store only source IDs already bound and verified.
    var researchImportedSourceIDs: [String]? = nil
    var id: String { requestID }
}
enum GaoOutgoingResultReceipt {
    case new(GaoOutgoingResultRecord, GaoOutgoingSession, [GaoOutgoingResultOutput], [String])
    case duplicate(GaoOutgoingResultRecord, GaoOutgoingSession)
    var record: GaoOutgoingResultRecord { switch self { case .new(let r,_,_,_), .duplicate(let r,_): return r } }
    var session: GaoOutgoingSession { switch self { case .new(_,let s,_,_), .duplicate(_,let s): return s } }
    var newOutputs: [GaoOutgoingResultOutput] { if case .new(_,_,let o,_) = self { return o }; return [] }
    var newReferenceIDs: [String] { if case .new(_,_,_,let r) = self { return r }; return [] }
    var isDuplicate: Bool { if case .duplicate = self { return true }; return false }
}

/// Durable metadata and private source versions only. No OCR body, image bytes or credentials are logged.
/// The journal records a provider's status separately from local approval/opening. A dispatched request is not a completed action.
final class GaoOutgoingJournal {
    private struct Envelope: Codable { var schemaVersion: Int; var sessions: [GaoOutgoingSession]; var results: [GaoOutgoingResultRecord] }
    private static let filename = "OutgoingSessions.json"
    private static let marker = "OutgoingSessions.initialized"
    private static let markerBytes = Data("GaoWenJian outgoing journal v1\n".utf8)
    private let root: URL
    private let directory: GaoFixedFD
    private let lock = NSLock()
    private var sessions: [String:GaoOutgoingSession] = [:]
    private var results: [String:GaoOutgoingResultRecord] = [:]
    private var persistedDigest: String?
    init(exchangeRoot: URL) throws {
        root = exchangeRoot; directory = try GaoPrivateIO.directory(exchangeRoot,create:true,requirePrivate:true)
        let markerFD = openat(directory.value,Self.marker,O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        let hadMarker: Bool
        if markerFD >= 0 {
            guard try GaoPrivateIO.read(GaoFixedFD(markerFD),maximum:128) == Self.markerBytes else { throw Self.issue("journalCorrupt") }; hadMarker = true
        } else { guard errno == ENOENT else { throw Self.issue("journalUnreadable") }; hadMarker = false }
        let fd = openat(directory.value,Self.filename,O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        if fd < 0 { guard errno == ENOENT, !hadMarker else { throw Self.issue("journalMissing") }; return }
        do {
            let bytes = try GaoPrivateIO.read(GaoFixedFD(fd),maximum:16_777_216)
            let envelope = try JSONDecoder().decode(Envelope.self,from:bytes)
            guard envelope.schemaVersion == 1 else { throw Self.issue("journalUnsupported") }
            guard envelope.sessions.count <= 10_000, envelope.results.count <= 100_000 else { throw Self.issue("journalCorrupt") }
            for session in envelope.sessions {
                try validateStoredSession(session)
                guard sessions.updateValue(session,forKey:session.requestID) == nil else { throw Self.issue("journalCorrupt") }
            }
            for record in envelope.results {
                try validateStoredResult(record)
                guard results.updateValue(record,forKey:record.requestID) == nil else { throw Self.issue("journalCorrupt") }
            }
            persistedDigest = FileSafety.digest(bytes)
            // Recovery stops at a visible interruption. Starting the App never repeats an uncertain side effect.
            var recovered = results
            for (id,var r) in recovered where r.phase == .executing {
                r.phase = .interrupted; r.errorCode = "interruptedBeforeAcknowledgement"; r.updatedAt = GaoActionContract.timestamp(Date()); recovered[id] = r
            }
            if recovered != results { try persist(sessions:sessions,results:recovered); results = recovered }
        } catch let issue as GaoActionIssue { throw issue }
        catch { throw Self.issue("journalCorrupt") }
    }
    func lookup(_ requestID: String) -> GaoOutgoingSession? { lock.lock(); defer { lock.unlock() }; return sessions[requestID] }
    func lookupResult(_ requestID: String) -> GaoOutgoingResultRecord? { lock.lock(); defer { lock.unlock() }; return results[requestID] }
    func allSessions() -> [GaoOutgoingSession] { lock.lock(); defer { lock.unlock() }; return sessions.values.sorted { $0.createdAt > $1.createdAt } }
    func allResults() -> [GaoOutgoingResultRecord] { lock.lock(); defer { lock.unlock() }; return results.values.sorted { $0.receivedAt > $1.receivedAt } }

    /// Register only a successfully written request in this App's own Outgoing directory.
    /// The production transport reopens fixed descriptors and hashes every attachment before it becomes an authoritative source version.
    @discardableResult func registerOutgoing(packageURL: URL, expectedTargetBundleID: String, bindings: [GaoOutgoingSourceBinding] = [], now: Date = Date()) throws -> GaoOutgoingSession {
        lock.lock(); defer { lock.unlock() }
        guard GaoActionContract.validBundleID(expectedTargetBundleID), Self.packageName(packageURL.lastPathComponent), packageURL.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL == root.appendingPathComponent("Outgoing",isDirectory:true).resolvingSymlinksInPath().standardizedFileURL else { throw Self.issue("outgoingLocation") }
        let package = try GaoActionTransport.receive(packageURL:packageURL,exchangeRoot:root,expectedTargetBundleID:expectedTargetBundleID,now:now)
        let m = package.manifest
        guard m.kind == "request", m.sourceBundleID == GaoActionContract.bundleID, Self.supports(action:m.action,targetBundleID:m.targetBundleID) else { throw Self.issue("outgoingMismatch") }
        if let old = sessions[m.requestID] {
            guard old.manifestSHA256 == package.manifestSHA256, old.targetBundleID == expectedTargetBundleID else { throw Self.issue("outgoingCollision") }
            try verifySources(old); return old
        }
        guard sessions.count < 10_000 else { throw Self.issue("journalLimit") }
        var bindingMap: [String:GaoOutgoingSourceBinding] = [:]
        for binding in bindings {
            guard m.items.contains(where:{$0.id == binding.itemID}), bindingMap.updateValue(binding,forKey:binding.itemID) == nil else { throw Self.issue("sourceBinding") }
            try validateBinding(binding)
        }
        let sources = try package.stagedItems.map { staged -> GaoOutgoingSource in
            let relative = "Staging/" + package.stagingURL.lastPathComponent + "/" + staged.url.lastPathComponent
            try Self.validateSourcePath(relative)
            return GaoOutgoingSource(item:staged.item,privateRelativePath:relative,binding:bindingMap[staged.id] ?? GaoOutgoingSourceBinding(itemID:staged.id))
        }
        let session = GaoOutgoingSession(requestID:m.requestID,manifestSHA256:package.manifestSHA256,action:m.action,targetBundleID:m.targetBundleID,requestPackageName:packageURL.lastPathComponent,createdAt:GaoActionContract.timestamp(now),updatedAt:GaoActionContract.timestamp(now),phase:.prepared,sources:sources)
        var next = sessions; next[session.requestID] = session
        try persist(sessions:next,results:results); sessions = next
        return session
    }
    @discardableResult func markDispatched(requestID: String, success: Bool, now: Date = Date()) throws -> GaoOutgoingSession {
        lock.lock(); defer { lock.unlock() }
        guard var session = sessions[requestID] else { throw Self.issue("unknownOutgoing") }
        // An asynchronous LaunchServices callback must never regress a result already received.
        guard [.prepared,.dispatchFailed].contains(session.phase) else { return session }
        session.phase = success ? .dispatched : .dispatchFailed; session.updatedAt = GaoActionContract.timestamp(now)
        var next = sessions; next[requestID] = session; try persist(sessions:next,results:results); sessions = next; return session
    }
    func sourceURL(requestID: String, itemID: String) throws -> URL {
        lock.lock(); defer { lock.unlock() }
        guard let source = sessions[requestID]?.sources.first(where:{$0.item.id == itemID}) else { throw Self.issue("unknownSource") }
        try verifySource(source); return root.appendingPathComponent(source.privateRelativePath)
    }
    @discardableResult func receiveResult(_ package: GaoValidatedPackage, now: Date = Date()) throws -> GaoOutgoingResultReceipt {
        lock.lock(); defer { lock.unlock() }
        let m = package.manifest
        guard m.kind == "result", m.targetBundleID == GaoActionContract.bundleID, let reply = m.inReplyTo, let session = sessions[reply], m.action == session.action, m.sourceBundleID == session.targetBundleID, let status = m.status, ["pending","partial","completed","failed","cancelled","unsupported"].contains(status), GaoActionContract.validSHA(package.manifestSHA256) else { throw Self.issue("unmatchedResult") }
        try verifySources(session)
        if let old = results[m.requestID] {
            guard old.manifestSHA256 == package.manifestSHA256 else { throw Self.issue("resultCollision") }
            return .duplicate(old,session)
        }
        guard results.count < 100_000 else { throw Self.issue("journalLimit") }
        try GaoActionContract.validate(m,expectedTargetBundleID:GaoActionContract.bundleID,now:now)
        try ResearchImportReceipt.validate(m,session:session)
        guard package.stagingURL.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL == root.appendingPathComponent("Staging",isDirectory:true).resolvingSymlinksInPath().standardizedFileURL else { throw Self.issue("resultItems") }
        let stage = try GaoPrivateIO.directory(package.stagingURL,requirePrivate:true)
        let manifestBytes = try GaoPrivateIO.read(GaoPrivateIO.regular(stage,components:["manifest.json"]),maximum:Int64(GaoActionContract.maximumManifestBytes))
        guard FileSafety.digest(manifestBytes) == package.manifestSHA256, try JSONDecoder().decode(GaoActionManifest.self,from:manifestBytes) == m else { throw Self.issue("resultManifestChanged") }
        guard package.stagedItems.count == m.items.count, Set(package.stagedItems.map(\.id)) == Set(m.items.map(\.id)) else { throw Self.issue("resultItems") }
        for staged in package.stagedItems { guard m.items.contains(staged.item) else { throw Self.issue("resultItems") }; try Self.verifyFile(staged.url,item:staged.item) }
        // Pending and unsuccessful replies carry status, never silently import a payload as a successful document.
        if status == "pending" { guard m.items.isEmpty, m.references.isEmpty else { throw Self.issue("resultStatus") } }
        let outputs: [GaoOutgoingResultOutput]
        if session.action == "ocr.files" {
            guard m.references.isEmpty else { throw Self.issue("resultItems") }
            outputs = try ocrOutputs(manifest:m,session:session)
        } else {
            outputs = m.items.map { GaoOutgoingResultOutput(resultItemID:$0.id,itemSHA256:$0.sha256,uti:$0.uti) }
        }
        let oldResults = results.values.filter { $0.inReplyTo == reply }
        if session.action == "ocr.files", status == "completed" {
            let requested = try requestedOCRFormats(session)
            let successful = oldResults.filter { ["partial","completed"].contains($0.status) }.flatMap(\.outputs) + outputs
            for source in session.sources {
                let formats = Set(successful.filter { $0.sourceItemID == source.item.id && $0.sourceSHA256 == source.item.sha256 }.compactMap { Self.ocrFormat(for:$0.uti) })
                guard !formats.isEmpty, requested.isSubset(of:formats) else { throw Self.issue("resultIncomplete") }
            }
        }
        // An uncertain executing/interrupted import is also reserved: after a crash we prefer an explicit recovery over duplicate tabs.
        let reserved = Set(oldResults.flatMap { record in record.outputs.filter { record.openedItemIDs.contains($0.resultItemID) || record.executionStarted && [.executing,.interrupted,.failed,.cancelled].contains(record.phase) }.map(\.contentKey) })
        let newOutputs = ["completed","partial"].contains(status) ? outputs.filter { !reserved.contains($0.contentKey) } : []
        let referenceFingerprints = try Dictionary(uniqueKeysWithValues:m.references.map { ($0.id,try Self.referenceFingerprint($0)) })
        let reservedReferences = Set(oldResults.flatMap { record in record.referenceIDs.filter { record.openedReferenceIDs.contains($0) || record.executionStarted && [.executing,.interrupted,.failed,.cancelled].contains(record.phase) }.compactMap { record.referenceFingerprints[$0] } })
        let newReferences = ["completed","partial"].contains(status) ? m.references.map(\.id).filter { !reservedReferences.contains(referenceFingerprints[$0]!) } : []
        if session.phase.terminal {
            guard status == session.phase.rawValue, newOutputs.isEmpty, newReferences.isEmpty else { throw Self.issue("resultAfterTerminal") }
        }
        if status == "pending", [.partial,.completed].contains(session.phase) { throw Self.issue("resultRegression") }
        let researchImportedSourceIDs: [String]?
        if session.action == "research.importDocuments" {
            guard session.phase != .partial || ["partial","completed"].contains(status) else { throw Self.issue("resultRegression") }
            // Older partial records remain readable, but do not identify which
            // sources succeeded. Only full completion can safely resolve that
            // unknown progress; nil must never be treated as an empty success set.
            if oldResults.contains(where: { $0.status == "partial" && $0.researchImportedSourceIDs == nil }) {
                guard status == "completed" else { throw Self.issue("researchProgressUnknown") }
            }
            // The complete source list has already passed the strict research
            // receipt validator. An imported source cannot become unsuccessful
            // in a later full snapshot, even when its overall status is partial.
            let imported = Set((m.provenance?["sources"]?.arrayValue ?? []).compactMap { value -> String? in
                guard let source = value.objectValue, source["status"]?.stringValue == "imported" else { return nil }
                return source["sourceItemID"]?.stringValue
            })
            let previouslyImported = Set(oldResults.flatMap { $0.researchImportedSourceIDs ?? [] })
            guard previouslyImported.isSubset(of:imported) else { throw Self.issue("researchSourceRegression") }
            researchImportedSourceIDs = session.sources.map(\.item.id).filter(imported.contains)
        } else { researchImportedSourceIDs = nil }
        let stamp = GaoActionContract.timestamp(now)
        let record = GaoOutgoingResultRecord(requestID:m.requestID,inReplyTo:reply,manifestSHA256:package.manifestSHA256,status:status,phase:.received,executionStarted:false,receivedAt:stamp,updatedAt:stamp,outputs:outputs,referenceIDs:m.references.map(\.id),referenceFingerprints:referenceFingerprints,openedItemIDs:[],openedReferenceIDs:[],errorCode:m.errorCode,researchImportedSourceIDs:researchImportedSourceIDs)
        var nextSession = session; nextSession.phase = GaoOutgoingPhase(rawValue:status)!; nextSession.updatedAt = stamp
        var nextSessions = sessions; nextSessions[reply] = nextSession
        var nextResults = results; nextResults[m.requestID] = record
        try persist(sessions:nextSessions,results:nextResults); sessions = nextSessions; results = nextResults
        return .new(record,nextSession,newOutputs,newReferences)
    }
    @discardableResult func approveResult(requestID: String, now: Date = Date()) throws -> GaoOutgoingResultRecord { try transitionResult(requestID:requestID,to:.approved,now:now) }
    @discardableResult func startResult(requestID: String, now: Date = Date()) throws -> GaoOutgoingResultRecord { try transitionResult(requestID:requestID,to:.executing,now:now) }
    @discardableResult func finishResult(requestID: String, openedItemIDs: [String] = [], openedReferenceIDs: [String] = [], now: Date = Date()) throws -> GaoOutgoingResultRecord { try transitionResult(requestID:requestID,to:.completed,openedItemIDs:openedItemIDs,openedReferenceIDs:openedReferenceIDs,now:now) }
    @discardableResult func cancelResult(requestID: String, now: Date = Date()) throws -> GaoOutgoingResultRecord { try transitionResult(requestID:requestID,to:.cancelled,now:now) }
    @discardableResult func failResult(requestID: String, errorCode: String? = nil, openedItemIDs: [String] = [], openedReferenceIDs: [String] = [], now: Date = Date()) throws -> GaoOutgoingResultRecord { try transitionResult(requestID:requestID,to:.failed,openedItemIDs:openedItemIDs,openedReferenceIDs:openedReferenceIDs,errorCode:errorCode,now:now) }
    @discardableResult func transitionResult(requestID: String, to phase: GaoOutgoingResultPhase, openedItemIDs: [String] = [], openedReferenceIDs: [String] = [], errorCode: String? = nil, now: Date = Date()) throws -> GaoOutgoingResultRecord {
        lock.lock(); defer { lock.unlock() }
        guard var record = results[requestID] else { throw Self.issue("unknownResult") }
        guard !record.phase.terminal else { if record.phase == phase, openedItemIDs.isEmpty, openedReferenceIDs.isEmpty { return record }; throw Self.issue("resultAlreadyProcessed") }
        let allowed: [GaoOutgoingResultPhase]
        switch record.phase { case .received: allowed = [.approved,.cancelled,.failed]; case .approved: allowed = [.executing,.cancelled,.failed]; case .executing: allowed = [.completed,.cancelled,.failed]; default: allowed = [] }
        guard allowed.contains(phase), Set(openedItemIDs).count == openedItemIDs.count, Set(openedReferenceIDs).count == openedReferenceIDs.count, Set(openedItemIDs).isSubset(of:Set(record.outputs.map(\.resultItemID))), Set(openedReferenceIDs).isSubset(of:Set(record.referenceIDs)), errorCode == nil || errorCode!.utf8.count <= 256 else { throw Self.issue("resultTransition") }
        guard ["completed","partial"].contains(record.status) || (openedItemIDs.isEmpty && openedReferenceIDs.isEmpty) else { throw Self.issue("resultStatus") }
        record.phase = phase; if phase == .executing { record.executionStarted = true }; record.updatedAt = GaoActionContract.timestamp(now); record.openedItemIDs = openedItemIDs; record.openedReferenceIDs = openedReferenceIDs; record.errorCode = errorCode ?? record.errorCode
        var next = results; next[requestID] = record; try persist(sessions:sessions,results:next); results = next; return record
    }
    private func ocrOutputs(manifest m: GaoActionManifest, session: GaoOutgoingSession) throws -> [GaoOutgoingResultOutput] {
        guard let provenance = m.provenance else { throw Self.issue("resultProvenance") }
        guard !m.items.isEmpty else { if let raw = provenance["outputs"], raw.arrayValue?.isEmpty != true { throw Self.issue("resultProvenance") }; return [] }
        guard let values = provenance["outputs"]?.arrayValue, values.count == m.items.count else { throw Self.issue("resultProvenance") }
        var ids = Set<String>(); var result: [GaoOutgoingResultOutput] = []
        for value in values {
            guard let value = value.objectValue, let sourceID = value["sourceItemID"]?.stringValue, let sourceSHA = value["sourceSHA256"]?.stringValue, let resultID = value["resultItemID"]?.stringValue, ids.insert(resultID).inserted, let source = session.sources.first(where:{$0.item.id == sourceID}), source.item.sha256 == sourceSHA, let item = m.items.first(where:{$0.id == resultID}) else { throw Self.issue("resultProvenance") }
            // Format is optional V1 metadata. The real attachment's approved UTI
            // always establishes one supported output kind, even when omitted.
            guard let format = Self.ocrFormat(for:item.uti), value["format"] == nil || value["format"]?.stringValue == format else { throw Self.issue("resultProvenance") }
            result.append(GaoOutgoingResultOutput(resultItemID:resultID,sourceItemID:sourceID,sourceSHA256:sourceSHA,format:format,itemSHA256:item.sha256,uti:item.uti))
        }
        guard Set(result.map(\.resultItemID)) == Set(m.items.map(\.id)) else { throw Self.issue("resultProvenance") }
        if let values = provenance["sources"] {
            guard let values = values.arrayValue, values.count <= session.sources.count else { throw Self.issue("resultProvenance") }
            var sourceIDs = Set<String>()
            for value in values {
                guard let object = value.objectValue, let sourceID = object["sourceItemID"]?.stringValue, sourceIDs.insert(sourceID).inserted, let sourceSHA = object["sourceSHA256"]?.stringValue, session.sources.contains(where:{$0.item.id == sourceID && $0.item.sha256 == sourceSHA}), let outputs = object["outputItemIDs"]?.arrayValue, outputs.allSatisfy({$0.stringValue != nil}), Set(outputs.compactMap(\.stringValue)) == Set(result.filter({$0.sourceItemID == sourceID}).map(\.resultItemID)) else { throw Self.issue("resultProvenance") }
            }
            guard Set(result.compactMap(\.sourceItemID)).isSubset(of:sourceIDs) else { throw Self.issue("resultProvenance") }
        }
        return result
    }
    private static func ocrFormat(for uti: String) -> String? {
        switch uti {
        case "public.utf8-plain-text","public.plain-text","text/plain": return "text"
        case "net.daringfireball.markdown","public.markdown","text/markdown": return "markdown"
        case "public.json","application/json": return "json"
        case "com.adobe.pdf","application/pdf": return "searchablePDF"
        default: return nil
        }
    }
    /// The verified request copy outlives TTL for its approved long-running task.
    /// Do not guess defaults or rely on an editable outgoing package's current contents.
    private func requestedOCRFormats(_ session: GaoOutgoingSession) throws -> Set<String> {
        guard let source = session.sources.first else { throw Self.issue("journalCorrupt") }
        try Self.validateSourcePath(source.privateRelativePath)
        let folder = root.appendingPathComponent(source.privateRelativePath).deletingLastPathComponent()
        let directory = try GaoPrivateIO.directory(folder,requirePrivate:true)
        let bytes = try GaoPrivateIO.read(GaoPrivateIO.regular(directory,components:["manifest.json"]),maximum:Int64(GaoActionContract.maximumManifestBytes))
        guard FileSafety.digest(bytes) == session.manifestSHA256 else { throw Self.issue("privateRequestChanged") }
        let manifest = try GaoActionTransport.decodeManifest(bytes)
        guard manifest.kind == "request", manifest.requestID == session.requestID, manifest.action == "ocr.files", manifest.sourceBundleID == GaoActionContract.bundleID, manifest.targetBundleID == session.targetBundleID, manifest.items.count == session.sources.count, manifest.items.allSatisfy({ item in session.sources.contains(where:{$0.item == item}) }) else { throw Self.issue("privateRequestChanged") }
        guard let value = manifest.parameters["outputs"] else { return [] }
        guard let values = value.arrayValue, !values.isEmpty, values.allSatisfy({ $0.stringValue != nil }) else { throw Self.issue("privateRequestChanged") }
        let formats = Set(values.compactMap(\.stringValue))
        guard formats.isSubset(of:["text","markdown","json","searchablePDF"]) else { throw Self.issue("privateRequestChanged") }
        return formats
    }
    private func validateStoredSession(_ session: GaoOutgoingSession) throws {
        guard UUID(uuidString:session.requestID) != nil, GaoActionContract.validSHA(session.manifestSHA256), Self.supports(action:session.action,targetBundleID:session.targetBundleID), GaoActionContract.validBundleID(session.targetBundleID), Self.packageName(session.requestPackageName), GaoActionContract.date(session.createdAt) != nil, GaoActionContract.date(session.updatedAt) != nil, session.sources.count <= GaoActionContract.maximumItems, Set(session.sources.map({$0.item.id})).count == session.sources.count else { throw Self.issue("journalCorrupt") }
        for source in session.sources { try validateBinding(source.binding); guard source.binding.itemID == source.item.id, GaoActionContract.validSHA(source.item.sha256), source.item.byteCount >= 0, source.item.byteCount <= GaoActionContract.maximumPayloadBytes, GaoActionContract.validUTI(source.item.uti) else { throw Self.issue("journalCorrupt") }; try Self.validateSourcePath(source.privateRelativePath) }
        try verifySources(session)
    }
    private func validateStoredResult(_ r: GaoOutgoingResultRecord) throws {
        guard UUID(uuidString:r.requestID) != nil, let session = sessions[r.inReplyTo], GaoActionContract.validSHA(r.manifestSHA256), ["pending","partial","completed","failed","cancelled","unsupported"].contains(r.status), GaoActionContract.date(r.receivedAt) != nil, GaoActionContract.date(r.updatedAt) != nil, r.outputs.count + r.referenceIDs.count <= GaoActionContract.maximumItems, Set(r.outputs.map(\.resultItemID)).count == r.outputs.count, Set(r.referenceIDs).count == r.referenceIDs.count, Set(r.referenceFingerprints.keys) == Set(r.referenceIDs), r.referenceFingerprints.values.allSatisfy(GaoActionContract.validSHA), Set(r.openedItemIDs).isSubset(of:Set(r.outputs.map(\.resultItemID))), Set(r.openedReferenceIDs).isSubset(of:Set(r.referenceIDs)), r.errorCode == nil || r.errorCode!.utf8.count <= 256 else { throw Self.issue("journalCorrupt") }
        guard ![.executing,.completed,.interrupted].contains(r.phase) || r.executionStarted else { throw Self.issue("journalCorrupt") }
        if let imported = r.researchImportedSourceIDs {
            guard session.action == "research.importDocuments", !session.sources.isEmpty,
                  Set(imported).count == imported.count, Set(imported).isSubset(of:Set(session.sources.map(\.item.id))),
                  r.outputs.isEmpty, r.referenceIDs.isEmpty else { throw Self.issue("journalCorrupt") }
            switch r.status {
            case "completed": guard imported.count == session.sources.count else { throw Self.issue("journalCorrupt") }
            case "partial": guard !imported.isEmpty, imported.count < session.sources.count else { throw Self.issue("journalCorrupt") }
            default: guard imported.isEmpty else { throw Self.issue("journalCorrupt") }
            }
        }
        for output in r.outputs {
            guard !output.resultItemID.isEmpty, GaoActionContract.validSHA(output.itemSHA256), GaoActionContract.validUTI(output.uti) else { throw Self.issue("journalCorrupt") }
            if session.action == "ocr.files" { guard let id = output.sourceItemID, let sha = output.sourceSHA256, session.sources.contains(where:{$0.item.id == id && $0.item.sha256 == sha}) else { throw Self.issue("journalCorrupt") } }
        }
    }
    private func validateBinding(_ binding: GaoOutgoingSourceBinding) throws {
        guard !binding.itemID.isEmpty, ["original","currentEdits","savedVersion"].contains(binding.versionKind) else { throw Self.issue("sourceBinding") }
        if let ref = binding.originalReference { guard ref.kind == "file", !ref.id.isEmpty, ref.sha256 == nil || GaoActionContract.validSHA(ref.sha256!) else { throw Self.issue("sourceBinding") }; _ = try GaoActionContract.localFileURL(ref.fileURL) }
    }
    private func verifySources(_ session: GaoOutgoingSession) throws { for source in session.sources { try verifySource(source) } }
    private func verifySource(_ source: GaoOutgoingSource) throws { try Self.validateSourcePath(source.privateRelativePath); try Self.verifyFile(root.appendingPathComponent(source.privateRelativePath),item:source.item) }
    private static func verifyFile(_ url: URL, item: GaoActionItem) throws {
        let fd = try GaoPrivateIO.regularURL(url); let before = try fd.statValue(); try GaoPrivateIO.checkRegular(before)
        guard before.st_mode & 0o077 == 0, before.st_size == item.byteCount else { throw issue("privateSourceChanged") }
        var hash = SHA256(); var total: Int64 = 0; var buffer = [UInt8](repeating:0,count:65_536)
        while true { let n = Darwin.read(fd.value,&buffer,buffer.count); if n == 0 { break }; if n < 0 { if errno == EINTR { continue }; throw issue("privateSourceChanged") }; total += Int64(n); guard total <= item.byteCount else { throw issue("privateSourceChanged") }; hash.update(data:Data(buffer.prefix(n))) }
        let digest = hash.finalize().map { String(format:"%02x",$0) }.joined()
        guard total == item.byteCount, digest == item.sha256, GaoPrivateIO.unchanged(before,try fd.statValue()) else { throw issue("privateSourceChanged") }
    }
    private static func validateSourcePath(_ path: String) throws {
        let c = try GaoActionContract.payloadComponents(path)
        guard c.count == 3, c[0] == "Staging", UUID(uuidString:c[1]) != nil else { throw issue("journalCorrupt") }
    }
    private func persist(sessions: [String:GaoOutgoingSession], results: [String:GaoOutgoingResultRecord]) throws {
        guard flock(directory.value,LOCK_EX) == 0 else { throw Self.issue("journalConflict") }
        defer { _ = flock(directory.value,LOCK_UN) }
        let markerBefore = openat(directory.value,Self.marker,O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        if markerBefore >= 0 { guard try GaoPrivateIO.read(GaoFixedFD(markerBefore),maximum:128) == Self.markerBytes else { throw Self.issue("journalCorrupt") } }
        else { guard errno == ENOENT else { throw Self.issue("journalUnreadable") } }
        let fd = openat(directory.value,Self.filename,O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        if fd >= 0 { guard persistedDigest == FileSafety.digest(try GaoPrivateIO.read(GaoFixedFD(fd),maximum:16_777_216)) else { throw Self.issue("journalConflict") } }
        else { guard errno == ENOENT, persistedDigest == nil else { throw Self.issue("journalConflict") } }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted,.sortedKeys,.withoutEscapingSlashes]
        let bytes = try encoder.encode(Envelope(schemaVersion:1,sessions:sessions.values.sorted{$0.requestID < $1.requestID},results:results.values.sorted{$0.requestID < $1.requestID}))
        guard bytes.count <= 16_777_216 else { throw Self.issue("journalLimit") }
        try GaoPrivateIO.atomicJSON(bytes,directory:directory,name:Self.filename)
        persistedDigest = FileSafety.digest(bytes)
        let marker = openat(directory.value,Self.marker,O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        if marker >= 0 { guard try GaoPrivateIO.read(GaoFixedFD(marker),maximum:128) == Self.markerBytes else { throw Self.issue("journalCorrupt") } }
        else { guard errno == ENOENT else { throw Self.issue("journalUnreadable") }; try GaoPrivateIO.atomicJSON(Self.markerBytes,directory:directory,name:Self.marker) }
    }
    private static func referenceFingerprint(_ reference: GaoActionReference) throws -> String {
        var canonical = reference; canonical.id = "selected-reference"
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys,.withoutEscapingSlashes]
        return FileSafety.digest(try encoder.encode(canonical))
    }
    private static func supports(action: String, targetBundleID: String) -> Bool {
        if action == "research.importDocuments" { return targetBundleID == "com.academic-achievement.manager" }
        return ["ocr.files","files.choose","documents.open","documents.newText"].contains(action)
    }
    private static func packageName(_ name: String) -> Bool { name.hasSuffix(".gaoaction") && UUID(uuidString:String(name.dropLast(10))) != nil }
    private static func issue(_ code: String) -> GaoActionIssue {
        let message = code == "resultIncomplete"
            ? "识别结果尚未覆盖全部输入或所请求的输出格式，不能按全部完成接收。原件保留，可等待剩余结果或重新发起识别。"
            : "交接会话或来源版本无法安全核对，已停止处理，未覆盖原件或历史记录。"
        return GaoActionContract.reject(code,message)
    }
}
