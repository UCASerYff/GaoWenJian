import AppKit
import Foundation

/// Public synthetic documents only; exercises the same transport, journal and
/// service paths that consume a research reply without creating an application.
enum ResearchImportReceiptTests {
    @MainActor @discardableResult static func run(in directory: URL) throws -> Int {
        guard NSApp == nil, CommandLine.arguments.contains("--data-dir"),
              FileSafety.root.path.hasPrefix("/private/tmp/gaowenjian-") else {
            throw GaoActionContract.reject("researchReceiptTest", "Research receipt tests require isolated temporary data and no application")
        }
        let fm = FileManager.default, now = Date(timeIntervalSince1970: 1_792_020_000)
        try fm.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var checks = 0
        func check(_ condition: @autoclosure () throws -> Bool, _ label: String) throws {
            guard try condition() else { throw GaoActionContract.reject("researchReceiptTest", label) }
            checks += 1
        }
        func rejects(_ code: String, _ work: () throws -> Void) throws {
            do { try work() }
            catch let error as GaoActionIssue {
                try check(error.code == code, "Expected \(code), received \(error.code)"); return
            }
            throw GaoActionContract.reject("researchReceiptTest", "Expected rejection: " + code)
        }
        let a = directory.appendingPathComponent("公开样本A.md"), b = directory.appendingPathComponent("公开样本B.txt")
        let aBytes = Data("# 公开合成原件 A\n".utf8), bBytes = Data("公开合成原件 B α\n".utf8)
        try aBytes.write(to: a); try bBytes.write(to: b)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: a.path)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: b.path)
        let store = WorkspaceStore(); store.tabs = []; store.selection = nil; store.open(a)
        guard let tab = store.active else { throw GaoActionContract.reject("researchReceiptTest", "Missing current editor") }
        let edits = "# 用户尚未保存的合成修改 😀\n"
        tab.edited(edits); store.checkpoint()
        let recovery = FileSafety.root.appendingPathComponent("recovery.json")
        let recoveryBefore = try Data(contentsOf: recovery)
        let selectionBefore = store.selection, statusBefore = store.status
        let exchange = GaoHandoffService.exchangeRoot
        let journalURL = exchange.appendingPathComponent("OutgoingSessions.json")
        let target = CurrentDocumentDispatcher.researchBundleID
        func request() throws -> GaoOutgoingSession {
            let url = try GaoActionWriter.writeRequest(action: "research.importDocuments",
                items: [.init(url: a, uti: "net.daringfireball.markdown", id: "source-a"), .init(url: b, uti: "public.utf8-plain-text", id: "source-b")],
                targetBundleID: target, exchangeRoot: exchange, now: now, includePayloadPrefix: true)
            let journal = try GaoOutgoingJournal(exchangeRoot: exchange)
            let session = try journal.registerOutgoing(packageURL: url, expectedTargetBundleID: target, now: now)
            return try journal.markDispatched(requestID: session.requestID, success: true, now: now)
        }
        let session = try request()
        func result(_ current: GaoOutgoingSession, _ status: String = "completed", _ states: [String] = ["imported", "imported"]) -> GaoActionManifest {
            let sources = zip(current.sources, states).map { source, state in GaoJSONValue.object([
                "sourceItemID": .string(source.item.id), "sourceSHA256": .string(source.item.sha256), "status": .string(state)
            ]) }
            return GaoActionManifest(kind: "result", requestID: UUID().uuidString, sourceBundleID: target, targetBundleID: GaoActionContract.bundleID,
                action: "research.importDocuments", createdAt: GaoActionContract.timestamp(now), expiresAt: GaoActionContract.timestamp(now.addingTimeInterval(120)),
                nonce: Data(repeating: 23, count: 32).base64EncodedString(), items: [], references: [], parameters: [:],
                inReplyTo: current.requestID, status: status, provenance: [
                    "requestManifestSHA256": .string(current.manifestSHA256), "workflowState": .string(status == "completed" ? "imported" : status),
                    "sources": .array(sources), "saved": .bool(false), "importedCount": .number(Double(states.filter { $0 == "imported" }.count)),
                    "duplicateCount": .number(0), "receiptID": .string(UUID().uuidString)
                ])
        }
        func write(_ manifest: GaoActionManifest, payload: [String: Data] = [:]) throws -> URL {
            let url = directory.appendingPathComponent(UUID().uuidString + ".gaoaction", isDirectory: true)
            try fm.createDirectory(at: url.appendingPathComponent("payload"), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            for (name, bytes) in payload {
                let destination = url.appendingPathComponent("payload/" + name)
                try bytes.write(to: destination); try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
            }
            let destination = url.appendingPathComponent("manifest.json")
            try JSONEncoder().encode(manifest).write(to: destination)
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
            return url
        }
        func source(_ manifest: inout GaoActionManifest, _ index: Int = 0, _ edit: (inout [String: GaoJSONValue]) -> Void) {
            var values = manifest.provenance!["sources"]!.arrayValue!
            var object = values[index].objectValue!; edit(&object); values[index] = .object(object)
            manifest.provenance!["sources"] = .array(values)
        }
        var confirmations = 0, selections = 0, offers = 0
        let interaction = GaoHandoffInteraction(confirm: { _ in confirmations += 1; return true },
            selectReference: { _ in selections += 1; return nil }, offerResult: { _, _ in offers += 1 })
        func unchanged(_ label: String) throws {
            try check(store.tabs.count == 1 && store.active === tab && store.selection == selectionBefore && tab.url == a
                      && tab.text == edits && tab.dirty && !tab.moduleDirty, "Editor and unsaved state retained: " + label)
            try check(try Data(contentsOf: recovery) == recoveryBefore && Data(contentsOf: a) == aBytes && Data(contentsOf: b) == bBytes,
                      "Originals and recovery retained: " + label)
            try check(confirmations == 0 && selections == 0 && offers == 0, "No document-open or send interaction: " + label)
        }
        func invalid(_ label: String, code: String, receiver: Bool = true, payload: [String: Data] = [:], _ mutate: (inout GaoActionManifest) -> Void) throws {
            var manifest = result(session); mutate(&manifest)
            try rejects(code) { try ResearchImportReceipt.validate(manifest, session: session) }
            if receiver {
                // All these envelopes pass generic transport validation. The
                // research contract must reject them before persisting status.
                let url = try write(manifest, payload: payload)
                let package = try GaoActionTransport.receive(packageURL: url, exchangeRoot: exchange, now: now)
                let bytesBefore = try Data(contentsOf: journalURL)
                try rejects(code) { _ = try GaoOutgoingJournal(exchangeRoot: exchange).receiveResult(package, now: now) }
                try rejects(code) { _ = try GaoHandoffService.receive(url: url, store: store, interaction: interaction, now: now) }
                let reloaded = try GaoOutgoingJournal(exchangeRoot: exchange)
                try check(reloaded.lookup(session.requestID) == session && reloaded.lookupResult(manifest.requestID) == nil
                          && (try Data(contentsOf: journalURL)) == bytesBefore, "Rejected receipt leaves durable status unchanged: " + label)
                try check(store.status == statusBefore, "Rejected receipt leaves the visible business status unchanged: " + label)
                try unchanged(label)
            }
        }
        // Known whole-task states, source order independence and compatible
        // optional metadata are accepted without inventing attachment results.
        for (status, states) in [("completed", ["imported", "imported"]), ("partial", ["imported", "failed"]),
                                  ("pending", ["pending", "pending"]), ("failed", ["failed", "failed"]),
                                  ("cancelled", ["cancelled", "cancelled"]), ("unsupported", ["unsupported", "unsupported"])] {
            try ResearchImportReceipt.validate(result(session, status, states), session: session); checks += 1
        }
        var reversed = result(session)
        reversed.provenance!["sources"] = .array(Array(reversed.provenance!["sources"]!.arrayValue!.reversed()))
        try ResearchImportReceipt.validate(reversed, session: session); checks += 1

        try invalid("request masquerading as receipt", code: "researchResultShape", receiver: false) { $0.kind = "request" }
        try invalid("unknown whole-task status", code: "researchResultShape", receiver: false) { $0.status = "success" }
        try invalid("changed action", code: "researchResultShape", receiver: false) { $0.action = "documents.open" }
        try invalid("changed request association", code: "researchResultShape", receiver: false) { $0.inReplyTo = UUID().uuidString }
        try invalid("request-only parameters", code: "researchResultShape") { $0.parameters = ["targetRecordID": .string("record")] }
        let returned = Data("不应自动打开的结果正文\n".utf8)
        try invalid("unexpected result attachment", code: "researchResultShape", payload: ["result.txt": returned]) {
            $0.items = [.init(id: "returned", relativePath: "payload/result.txt", uti: "public.utf8-plain-text", byteCount: Int64(returned.count), sha256: FileSafety.digest(returned))]
        }
        try invalid("unexpected original reference", code: "researchResultShape") {
            $0.references = [.init(id: "reference", kind: "file", fileURL: a.absoluteString, displayName: "公开原件", declaredIdentity: .init())]
        }
        try invalid("missing provenance", code: "researchResultProvenance", receiver: false) { $0.provenance = nil }
        try invalid("legacy unbound receipt", code: "researchResultProvenance") { $0.provenance = ["workflowState": .string("imported")] }
        try invalid("wrong original request digest", code: "researchResultProvenance") { $0.provenance!["requestManifestSHA256"] = .string(String(repeating: "0", count: 64)) }
        try invalid("wrong workflow state", code: "researchResultProvenance") { $0.provenance!["workflowState"] = .string("completed") }
        try invalid("missing sources despite claimed counts", code: "researchResultProvenance") { $0.provenance!["sources"] = nil }
        try invalid("non-array sources", code: "researchResultProvenance") { $0.provenance!["sources"] = .object([:]) }
        try invalid("missing source", code: "researchResultProvenance") { $0.provenance!["sources"] = .array(Array($0.provenance!["sources"]!.arrayValue!.prefix(1))) }
        try invalid("unknown source", code: "researchResultProvenance") { source(&$0) { $0["sourceItemID"] = .string("unknown") } }
        try invalid("duplicate source", code: "researchResultProvenance") { manifest in
            let first = manifest.provenance!["sources"]!.arrayValue![0]
            manifest.provenance!["sources"] = .array([first, first])
        }
        try invalid("wrong source digest", code: "researchResultProvenance") { source(&$0) { $0["sourceSHA256"] = .string(String(repeating: "f", count: 64)) } }
        try invalid("missing source status", code: "researchResultProvenance") { source(&$0) { $0["status"] = nil } }
        try invalid("unknown source status", code: "researchResultProvenance") { source(&$0) { $0["status"] = .string("completed") } }
        try invalid("non-object source", code: "researchResultProvenance") { $0.provenance!["sources"] = .array([.null, $0.provenance!["sources"]!.arrayValue![1]]) }
        try invalid("false completion", code: "researchResultStatus") { source(&$0, 1) { $0["status"] = .string("failed") } }
        try invalid("partial with all imported", code: "researchResultStatus") { $0.status = "partial"; $0.provenance!["workflowState"] = .string("partial") }
        try invalid("partial with no imported", code: "researchResultStatus") {
            $0 = result(session, "partial", ["failed", "pending"])
        }
        for status in ["pending", "failed", "cancelled", "unsupported"] {
            try invalid(status + " cannot contain imported sources", code: "researchResultStatus") { $0 = result(session, status, ["imported", status]) }
        }

        let partialURL = try write(result(session, "partial", ["imported", "failed"]))
        let partial = try GaoHandoffService.receive(url: partialURL, store: store, interaction: interaction, now: now)
        let partialJournal = try GaoOutgoingJournal(exchangeRoot: exchange)
        try check(partial.status == "partial" && partial.openedTabIDs.isEmpty && !partial.duplicate
                  && partialJournal.lookup(session.requestID)?.phase == .partial
                  && partialJournal.lookupResult(partial.requestID)?.phase == .completed, "Service records the actual partial import as status only")
        try check(partialJournal.lookupResult(partial.requestID)?.researchImportedSourceIDs == ["source-a"],
                  "Verified source-level imported progress is retained across journal reload")
        try unchanged("accepted partial")
        let partialBytes = try Data(contentsOf: journalURL)
        let duplicatePartial = try GaoHandoffService.receive(url: partialURL, store: store, interaction: interaction, now: now)
        try check(duplicatePartial.duplicate && duplicatePartial.status == "partial" && (try Data(contentsOf: journalURL)) == partialBytes,
                  "Repeated partial receipt is idempotent across service and journal reload")
        func rejectProgress(_ manifest: GaoActionManifest, code: String) throws {
            // These are individually valid status snapshots; only the durable
            // history can show that accepting them would erase prior success.
            try ResearchImportReceipt.validate(manifest, session: session)
            let url = try write(manifest)
            let package = try GaoActionTransport.receive(packageURL: url, exchangeRoot: exchange, now: now)
            let journal = try GaoOutgoingJournal(exchangeRoot: exchange)
            let before = try Data(contentsOf: journalURL), beforeSession = journal.lookup(session.requestID), beforeStatus = store.status
            try rejects(code) { _ = try journal.receiveResult(package, now: now) }
            try rejects(code) { _ = try GaoHandoffService.receive(url: url, store: store, interaction: interaction, now: now) }
            let reloaded = try GaoOutgoingJournal(exchangeRoot: exchange)
            try check(reloaded.lookup(session.requestID) == beforeSession && reloaded.lookupResult(manifest.requestID) == nil
                      && (try Data(contentsOf: journalURL)) == before, "Rejected progress regression never changes the durable receipt or session")
            try check(store.status == beforeStatus, "Rejected progress regression never changes the visible status")
            try unchanged("rejected progress regression")
        }
        for status in ["pending", "failed", "cancelled", "unsupported"] {
            try rejectProgress(result(session, status, [status, status]), code: "resultRegression")
        }
        try rejectProgress(result(session, "partial", ["failed", "imported"]), code: "researchSourceRegression")
        let repeatedPartial = try GaoHandoffService.receive(url: write(result(session, "partial", ["imported", "failed"])),
            store: store, interaction: interaction, now: now)
        try check(!repeatedPartial.duplicate && repeatedPartial.status == "partial"
                  && (try GaoOutgoingJournal(exchangeRoot: exchange)).lookupResult(repeatedPartial.requestID)?.researchImportedSourceIDs == ["source-a"],
                  "A new receipt may repeat the same partial progress without erasing imported sources")

        // Read/write only complete synthetic copies inside this test directory.
        // A missing optional field is legacy metadata, never an empty known set.
        func cloneJournal(_ name: String, _ edit: (inout [String: Any]) throws -> Void) throws -> URL {
            let cloned = directory.appendingPathComponent(name, isDirectory: true)
            try fm.copyItem(at: exchange, to: cloned)
            let ledger = cloned.appendingPathComponent("OutgoingSessions.json")
            var wire = try JSONSerialization.jsonObject(with: Data(contentsOf: ledger)) as! [String: Any]
            try edit(&wire)
            try JSONSerialization.data(withJSONObject: wire, options: [.sortedKeys]).write(to: ledger)
            return cloned
        }
        let legacy = try cloneJournal("LegacyOptionalMetadata") { wire in
            var records = wire["results"] as! [[String: Any]]
            for index in records.indices { records[index].removeValue(forKey: "researchImportedSourceIDs") }
            wire["results"] = records
        }
        let legacyLedger = legacy.appendingPathComponent("OutgoingSessions.json")
        let legacyBefore = try Data(contentsOf: legacyLedger), legacyJournal = try GaoOutgoingJournal(exchangeRoot: legacy)
        try check(legacyJournal.lookupResult(partial.requestID)?.researchImportedSourceIDs == nil
                  && legacyJournal.lookup(session.requestID)?.phase == .partial && (try Data(contentsOf: legacyLedger)) == legacyBefore,
                  "Legacy nil metadata loads without rewriting or inventing progress")
        let oldPartial = try GaoActionTransport.receive(packageURL: partialURL, exchangeRoot: legacy, now: now)
        try check(try legacyJournal.receiveResult(oldPartial, now: now).isDuplicate && Data(contentsOf: legacyLedger) == legacyBefore,
                  "Exact legacy partial duplicates retain their existing idempotent record")
        let unknownProgress = try GaoActionTransport.receive(packageURL: write(result(session, "partial", ["failed", "imported"])), exchangeRoot: legacy, now: now)
        try rejects("researchProgressUnknown") { _ = try legacyJournal.receiveResult(unknownProgress, now: now) }
        try check(try Data(contentsOf: legacyLedger) == legacyBefore, "Legacy unknown imported sources cannot be guessed away by a new partial")
        let resolvedProgress = try GaoActionTransport.receive(packageURL: write(result(session)), exchangeRoot: legacy, now: now)
        let resolved = try legacyJournal.receiveResult(resolvedProgress, now: now)
        try check(resolved.session.phase == .completed && resolved.record.researchImportedSourceIDs == ["source-a", "source-b"]
                  && (try GaoOutgoingJournal(exchangeRoot: legacy)).lookup(session.requestID)?.phase == .completed,
                  "A fully verified completed receipt safely resolves legacy unknown partial progress")
        for (name, imported, status) in [("UnknownID", ["unknown"], "partial"), ("DuplicateID", ["source-a", "source-a"], "partial"),
                                         ("EmptyPartial", [], "partial"), ("FullPartial", ["source-a", "source-b"], "partial"),
                                         ("IncompleteCompleted", ["source-a"], "completed"), ("ImportedFailed", ["source-a"], "failed")] {
            let damaged = try cloneJournal("InvalidProgress-" + name) { wire in
                var records = wire["results"] as! [[String: Any]]
                let index = records.firstIndex { $0["requestID"] as? String == partial.requestID }!
                records[index]["researchImportedSourceIDs"] = imported; records[index]["status"] = status
                wire["results"] = records
            }
            let ledger = damaged.appendingPathComponent("OutgoingSessions.json"), before = try Data(contentsOf: damaged.appendingPathComponent("OutgoingSessions.json"))
            try rejects("journalCorrupt") { _ = try GaoOutgoingJournal(exchangeRoot: damaged) }
            try check(try Data(contentsOf: ledger) == before, "Invalid stored imported metadata is retained on rejection: " + name)
        }
        try unchanged("legacy and corrupt synthetic ledger checks")
        let completedURL = try write(result(session))
        let completed = try GaoHandoffService.receive(url: completedURL, store: store, interaction: interaction, now: now)
        let completedJournal = try GaoOutgoingJournal(exchangeRoot: exchange)
        try check(completed.status == "completed" && completed.openedTabIDs.isEmpty && completedJournal.lookup(session.requestID)?.phase == .completed,
                  "A new fully bound receipt advances partial to completed")
        try check(completedJournal.lookupResult(completed.requestID)?.outputs.isEmpty == true
                  && completedJournal.lookupResult(completed.requestID)?.referenceIDs.isEmpty == true
                  && completedJournal.lookupResult(completed.requestID)?.researchImportedSourceIDs == ["source-a", "source-b"],
                  "Completed import retains all imported source IDs and creates no local document result")
        let completeBytes = try Data(contentsOf: journalURL)
        let completedPackage = try GaoActionTransport.receive(packageURL: completedURL, exchangeRoot: exchange, now: now)
        try check(try GaoOutgoingJournal(exchangeRoot: exchange).receiveResult(completedPackage, now: now).isDuplicate
                  && Data(contentsOf: journalURL) == completeBytes, "Repeated completed receipt remains idempotent after journal restart")
        try unchanged("accepted completed")

        for status in ["pending", "failed", "cancelled", "unsupported"] {
            let current = try request(), url = try write(result(current, status, [status, status]))
            let outcome = try GaoHandoffService.receive(url: url, store: store, interaction: interaction, now: now)
            let journal = try GaoOutgoingJournal(exchangeRoot: exchange)
            try check(outcome.status == status && outcome.openedTabIDs.isEmpty && journal.lookup(current.requestID)?.phase.rawValue == status
                      && journal.lookupResult(outcome.requestID)?.phase == .completed, "Explicit " + status + " is retained without implying an imported document")
            try unchanged("accepted " + status)
        }
        try check(NSApp == nil, "Research receipt validation never initializes an application")
        print("Research import receipts: \(checks) checks passed (strict source/request binding, false completion and progress regression rejection, durable per-source imported progress, legacy optional metadata, real transport/journal/service, partial→completed, explicit cancellation, duplicate idempotence, editor/original/recovery preservation; no UI)")
        return checks
    }
}
