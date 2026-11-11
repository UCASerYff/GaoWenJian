import Foundation
import SQLite3
import CryptoKit
import Darwin

/// Actual exporter and import logic, restricted to an explicitly isolated root.
/// No App/GUI, old security-scope resolution or system-association calls.
@MainActor enum OrganizerMigrationTests {
    /// Only the newly added retirement gate. Reuses one actual export while
    /// importing/activating each independent target with its own exact receipt.
    static func runRetirementOnly(in directory: URL) throws {
        try check(directory.path.hasPrefix("/private/tmp/gaowenjian-"), "Retirement checks require an isolated root")
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let source = directory.appendingPathComponent("Source", isDirectory: true)
        let preferences = directory.appendingPathComponent("SourcePreferences.plist")
        let databaseID = UUID().uuidString
        try fixture(source, preferences: preferences, databaseID: databaseID)
        let sourceBefore = try hashFiles(source)
        let snapshot = directory.appendingPathComponent("Snapshot.noindex", isDirectory: true)
        try export(source, preferences: preferences, to: snapshot)
        var assertions = 0
        func verify(_ value: Bool, _ message: String) throws { try check(value, message); assertions += 1 }
        func refuses(_ message: String, _ body: () throws -> Void) throws { try fails(message, body: body); assertions += 1 }
        func newTarget(_ label: String) throws -> URL {
            let parent = directory.appendingPathComponent(label, isDirectory: true)
            try fm.createDirectory(at: parent, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let target = parent.appendingPathComponent("Organizer", isDirectory: true)
            _ = try OrganizerMigration.importSnapshot(url: snapshot, destination: target)
            let authority = parent.appendingPathComponent("AcceptedSourceFreeze.json")
            try writeReceipt(freezeReceipt(snapshot: snapshot, destination: target), to: authority)
            _ = try OrganizerMigration.activate(destination: target, authorityReceipt: authority)
            // These locks are created by the actual runtime before business use.
            // The fixture models that accepted, closed runtime without starting it.
            for relative in [".app.lock", "MovePlans/.lock"] {
                let url = target.appendingPathComponent(relative)
                if !fm.fileExists(atPath: url.path) { try Data().write(to: url) }
                try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            }
            return target
        }
        func activeHashes(_ target: URL) throws -> [String: String] {
            let all = try hashFiles(target)
            return all.filter { name, _ in
                OFAppLocations.expectedDocuments.contains(name) || name.hasPrefix("MovePlans/")
            }
        }
        func removeExactWhitelist(_ report: OrganizerRetirementReport, target: URL) throws {
            let expected = Set(["SourceArchive", "MigrationLedger.json", "SourceIDMapping.json"].map { target.appendingPathComponent($0).path })
            try verify(Set(report.deletablePaths) == expected && report.deletablePaths.count == 3, "Retirement exposes only three exact obsolete source paths")
            for path in report.deletablePaths { try fm.removeItem(at: URL(fileURLWithPath: path)) }
        }
        func withHeldLock(_ url: URL, _ body: () throws -> Void) throws {
            let fd = Darwin.open(url.path, O_RDWR | O_NOFOLLOW | O_CLOEXEC)
            try verify(fd >= 0, "Synthetic existing lock can open")
            defer { flock(fd, LOCK_UN); close(fd) }
            try verify(flock(fd, LOCK_EX | LOCK_NB) == 0, "Synthetic runtime owns its existing lock")
            try body()
        }
        stage("retirement-no-finalized-archive-required")
        let sealed = try newTarget("Unfinalized")
        let archive = sealed.appendingPathComponent("SourceArchive", isDirectory: true)
        let heldArchive = sealed.deletingLastPathComponent().appendingPathComponent("HeldArchive.noindex", isDirectory: true)
        try fm.moveItem(at: archive, to: heldArchive)
        try refuses("Missing archive without finalized receipt must stop runtime") { try OrganizerMigration.requireActiveAuthority(directory: sealed) }
        try refuses("Missing archive cannot be legitimized by finalization") { _ = try OrganizerMigration.finalizeSourceRetirement(destination: sealed) }
        try verify(!fm.fileExists(atPath: sealed.appendingPathComponent("SourceRetirementFinalized.json").path), "Refused finalization publishes no authority")
        try fm.moveItem(at: heldArchive, to: archive)
        try OrganizerMigration.requireActiveAuthority(directory: sealed)

        stage("retirement-existing-runtime-lock-refusal")
        let locked = try newTarget("RuntimeLocks")
        let lockedBefore = try activeHashes(locked)
        for name in [".app.lock", "MovePlans/.lock"] {
            try withHeldLock(locked.appendingPathComponent(name)) {
                try refuses("Finalization cannot race a live module or move writer") { _ = try OrganizerMigration.finalizeSourceRetirement(destination: locked) }
                try verify(!fm.fileExists(atPath: locked.appendingPathComponent("SourceRetirementFinalized.json").path), "Held runtime lock prevents a finalized receipt")
            }
        }
        try verify(try activeHashes(locked) == lockedBefore, "Lock refusals do not change active data")

        stage("retirement-active-archive-reference-refusal")
        let dependent = try newTarget("ActiveArchiveDependency")
        try sql(dependent.appendingPathComponent("metadata.sqlite")) { db in
            let previous = try scalar(db, "SELECT path FROM authorized_roots")
            let archivePath = dependent.appendingPathComponent("SourceArchive/Data").path.replacingOccurrences(of: "'", with: "''")
            try execute(db, "UPDATE authorized_roots SET path='\(archivePath)'")
            let before = try activeHashes(dependent)
            try refuses("A current authorized root still reading the old archive blocks cleanup authority") { _ = try OrganizerMigration.finalizeSourceRetirement(destination: dependent) }
            try verify(!fm.fileExists(atPath: dependent.appendingPathComponent("SourceRetirementFinalized.json").path) && activeHashes(dependent) == before, "Archive dependency refusal leaves current data unchanged")
            let marker = dependent.appendingPathComponent("Marker", isDirectory: true)
            try fm.createDirectory(at: marker, withIntermediateDirectories: false)
            let alias = dependent.deletingLastPathComponent().appendingPathComponent("ArchiveAlias")
            try fm.createSymbolicLink(at: alias, withDestinationURL: dependent.appendingPathComponent("SourceArchive"))
            for path in [marker.path + "/../SourceArchive/Data", alias.appendingPathComponent("Data").path] {
                try execute(db, "UPDATE authorized_roots SET path='\(path.replacingOccurrences(of: "'", with: "''"))'")
                try refuses("Lexical and symlink aliases of active archive roots block finalization") {
                    _ = try OrganizerMigration.finalizeSourceRetirement(destination: dependent)
                }
            }
            try execute(db, "UPDATE authorized_roots SET path='\(previous.replacingOccurrences(of: "'", with: "''"))'")
        }
        let released = try OrganizerMigration.finalizeSourceRetirement(destination: dependent)
        try verify(!released.alreadyFinalized, "Restoring the actual current root permits explicit finalization")

        stage("retirement-atomic-commit-faults")
        enum RetirementStop: Error { case injected }
        for phase in [OrganizerRetirementPhase.beforeCommit, .afterCommit] {
            let target = try newTarget("Fault-" + phase.rawValue)
            let before = try activeHashes(target)
            var triggered = false
            try refuses("Injected finalization boundary interrupts") {
                _ = try OrganizerMigration.finalizeSourceRetirement(destination: target, testingFault: { current in
                    if current == phase { triggered = true; throw RetirementStop.injected }
                })
            }
            let finalURL = target.appendingPathComponent("SourceRetirementFinalized.json")
            try verify(triggered && fm.fileExists(atPath: finalURL.path) == (phase == .afterCommit), "Only the post-commit fault has durable finalized authority")
            try verify(try activeHashes(target) == before, "Either fault boundary preserves current business material")
            try OrganizerMigration.requireActiveAuthority(directory: target)
            let prior = fm.fileExists(atPath: finalURL.path) ? try Data(contentsOf: finalURL) : nil
            let resumed = try OrganizerMigration.finalizeSourceRetirement(destination: target)
            try verify(resumed.alreadyFinalized == (phase == .afterCommit), "Retry recognizes the actual committed boundary")
            if let prior { try verify(try Data(contentsOf: finalURL) == prior, "Post-commit retry never replaces its existing receipt") }
            let committed = try Data(contentsOf: finalURL)
            try removeExactWhitelist(resumed, target: target)
            try OrganizerMigration.requireActiveAuthority(directory: target)
            let repeated = try OrganizerMigration.finalizeSourceRetirement(destination: target)
            try verify(repeated.alreadyFinalized && Data(contentsOf: finalURL) == committed, "Archive-free retry remains read-only idempotent")
        }

        stage("retirement-live-WAL-current-edits-and-recovery")
        let target = try newTarget("AcceptedCurrentData")
        let configurationURL = target.appendingPathComponent("configuration.json")
        var configuration = try decodeEnvelope(configurationURL) as! [String: Any]
        configuration["appearance"] = "dark"
        try envelope(configuration, to: configurationURL)
        let original = directory.appendingPathComponent("UserOriginal.txt")
        try Data("user original and pending recovery must survive".utf8).write(to: original)
        let originalInode = try fm.attributesOfItem(atPath: original.path)[.systemFileNumber] as? NSNumber
        let draft = target.deletingLastPathComponent().appendingPathComponent("Host-Unsaved-Draft.txt")
        let draftBytes = Data("host unsaved draft remains outside organizer retirement".utf8)
        try draftBytes.write(to: draft)
        let moveURL = target.appendingPathComponent("MovePlans/ledger.json")
        var moves = try decodeEnvelope(moveURL) as! [String: Any]
        let operation = OFMoveOperation(source: directory.appendingPathComponent("AbsentOriginal.txt"), destination: original, state: .moved)
        let plan = OFMovePlan(state: .needsRecovery, operations: [operation])
        moves["plans"] = [try JSONSerialization.jsonObject(with: JSONEncoder().encode(plan))]
        try envelope(moves, to: moveURL, schema: false)
        let moveBefore = try Data(contentsOf: moveURL)
        let configBefore = try Data(contentsOf: configurationURL)
        let archiveBefore = try hashFiles(target.appendingPathComponent("SourceArchive"))
        try sql(target.appendingPathComponent("metadata.sqlite")) { writer in
            try execute(writer, "PRAGMA journal_mode=WAL; PRAGMA wal_autocheckpoint=0; UPDATE files SET favorite=1; PRAGMA user_version=999")
            try verify(fm.fileExists(atPath: target.appendingPathComponent("metadata.sqlite-wal").path), "Synthetic committed current state remains in a live WAL")
            try refuses("Future production schema in WAL is not hidden by immutable snapshot reads") { _ = try OrganizerMigration.finalizeSourceRetirement(destination: target) }
            try execute(writer, "PRAGMA user_version=2")
            let report = try OrganizerMigration.finalizeSourceRetirement(destination: target)
            let finalURL = target.appendingPathComponent("SourceRetirementFinalized.json")
            let finalBytes = try Data(contentsOf: finalURL)
            let finalized = try decodeEnvelope(finalURL) as! [String: Any]
            try verify(report.sourceDatabaseID == databaseID && report.destinationPath == target.path && report.receiptPath == finalURL.path && !report.alreadyFinalized, "Finalization binds actual production IDs and exact target")
            try verify(finalBytes.count < 32 * 1024 && finalized["archiveEntries"] == nil && finalized["rawSource"] == nil && finalized["snapshot"] == nil, "Finalized receipt is compact non-recoverable metadata, not a raw archive")
            try verify(finalized["schemaVersion"] as? Int == 1 && finalized["kind"] as? String == "GaoSeriesSourceRetirementFinalized" && finalized["archiveNoLongerRequired"] as? Bool == true && finalized["explicitCoordinatorAcceptance"] as? Bool == true, "Explicit finalized schema and retirement semantics are recorded")
            try verify(try hashFiles(target.appendingPathComponent("SourceArchive")) == archiveBefore, "Finalization only releases dependency and never deletes old source objects")
            try removeExactWhitelist(report, target: target)
            try OrganizerMigration.requireActiveAuthority(directory: target)
            try verify(try scalar(writer, "SELECT favorite FROM files") == "1" && Data(contentsOf: configurationURL) == configBefore && Data(contentsOf: moveURL) == moveBefore, "Current favorite, configuration and pending move journal survive finalization and exact cleanup")
            configuration["appearance"] = "light"
            try envelope(configuration, to: configurationURL)
            try execute(writer, "UPDATE files SET favorite=0")
            try OrganizerMigration.requireActiveAuthority(directory: target)
            try verify(try scalar(writer, "SELECT favorite FROM files") == "0", "Legitimate later current edits remain usable without old content hash gates")
            try execute(writer, "PRAGMA user_version=999")
            try refuses("Finalized authority does not waive future production schema") { try OrganizerMigration.requireActiveAuthority(directory: target) }
            try execute(writer, "PRAGMA user_version=2")

            stage("retirement-corrupt-future-cross-source-finalized-refusal")
            var damagedEnvelope = try JSONSerialization.jsonObject(with: finalBytes) as! [String: Any]
            damagedEnvelope["sha256"] = String(repeating: "0", count: 64)
            try writeReceipt(damagedEnvelope, to: finalURL)
            try refuses("Bad finalized digest never falls back to old authority") { try OrganizerMigration.requireActiveAuthority(directory: target) }
            let mutations: [(String, Any)] = [("schemaVersion", 999), ("sourceBundleID", "com.gaoseries.OtherSource"), ("targetDataRoot", target.deletingLastPathComponent().appendingPathComponent("OtherOrganizer").path), ("sourceDatabaseID", UUID().uuidString), ("moveStoreID", UUID().uuidString), ("issuedAt", "2999-01-01T00:00:00Z")]
            for (field, value) in mutations {
                var changed = finalized; changed[field] = value
                try envelope(changed, to: finalURL)
                let invalidBytes = try Data(contentsOf: finalURL)
                try refuses("Rehashed future or cross-source finalized receipt is rejected") { try OrganizerMigration.requireActiveAuthority(directory: target) }
                try refuses("Explicit retry must not overwrite corrupt finalized authority") { _ = try OrganizerMigration.finalizeSourceRetirement(destination: target) }
                try verify(try Data(contentsOf: finalURL) == invalidBytes, "Rejected finalized receipt remains unchanged for diagnosis")
            }
            try finalBytes.write(to: finalURL)
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: finalURL.path)
            let authorityURL = target.appendingPathComponent("SourceAuthorityReceipt.json")
            let authorityBytes = try Data(contentsOf: authorityURL)
            var changedAuthority = try JSONSerialization.jsonObject(with: authorityBytes) as! [String: Any]
            changedAuthority["scope"] = "changed after finalization"
            try writeReceipt(changedAuthority, to: authorityURL)
            try refuses("Finalized receipt retains exact original active authority binding") { try OrganizerMigration.requireActiveAuthority(directory: target) }
            try authorityBytes.write(to: authorityURL)
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: authorityURL.path)
            try fm.removeItem(at: finalURL)
            try refuses("Missing finalized receipt plus retired ledger cannot silently become a fresh store") { try OrganizerMigration.requireActiveAuthority(directory: target) }
            try finalBytes.write(to: finalURL)
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: finalURL.path)
            try OrganizerMigration.requireActiveAuthority(directory: target)
        }
        try verify(try Data(contentsOf: draft) == draftBytes && Data(contentsOf: moveURL) == moveBefore && (fm.attributesOfItem(atPath: original.path)[.systemFileNumber] as? NSNumber) == originalInode, "Host draft, pending move ledger and original inode remain outside the deletion whitelist")
        try verify(try hashFiles(source) == sourceBefore, "Retirement tests never mutate the original synthetic source")
        print("PASS Organizer source retirement: \(assertions) focused assertions; actual export/import/activation, atomic faults, WAL/current edits and corrupt authority fences; no App/window/smoke")
    }

    static func run(in directory: URL) throws {
        try check(directory.path.hasPrefix("/private/tmp/gaowenjian-"), "Organizer migration tests require isolated root")
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let source = directory.appendingPathComponent("Source", isDirectory: true)
        let prefs = directory.appendingPathComponent("SourcePreferences.plist")
        let id = UUID().uuidString
        stage("create-fixture-with-production-move-store")
        try fixture(source, preferences: prefs, databaseID: id)
        let before = try hashFiles(source)
        let snapshot = directory.appendingPathComponent("Snapshot.noindex")
        stage("actual-export-and-restore")
        try export(source, preferences: prefs, to: snapshot)
        try check(try hashFiles(source) == before, "Exporter leaves source files byte-identical")
        let targetParent = directory.appendingPathComponent("Target", isDirectory: true)
        try fm.createDirectory(at: targetParent, withIntermediateDirectories: true)
        let destination = targetParent.appendingPathComponent("Organizer", isDirectory: true)
        stage("actual-import")
        let report = try OrganizerMigration.importSnapshot(url: snapshot, destination: destination)
        try check(report.importedRoots == 1 && report.importedFiles == 1 && report.needsAuthorization && !report.alreadyImported,
                  "Complete actual import preserves indexed roots and file count")
        try check(try String(contentsOf: targetParent.appendingPathComponent("Organizer.initialized"), encoding: .utf8) == "schema=1\n", "Parent initialization published after complete store")
        try sql(destination.appendingPathComponent("metadata.sqlite")) { db in
            try check(try scalar(db, "SELECT status FROM authorized_roots") == "needsAuthorization", "Old root permission never inherited")
            try check(try scalar(db, "SELECT length(bookmark) FROM authorized_roots") == "0", "Runtime old bookmark erased, archive retains evidence")
            try check(try scalar(db, "SELECT paused FROM authorized_roots") == "1", "Automatic watchers paused")
            try check(try scalar(db, "SELECT count(*) FROM organizer_migration_ids") == "2", "Source IDs explicitly mapped in new namespace")
        }
        try sql(destination.appendingPathComponent("SourceArchive/Data/metadata.sqlite")) { db in
            try check(try scalar(db, "SELECT hex(bookmark) FROM authorized_roots") == "01020304", "Original bookmark preserved only in archive")
        }
        let history = try decodeEnvelope(destination.appendingPathComponent("associations_history.json")) as! [[String: Any]]
        try check(history.count == 1 && history[0]["status"] as? String == "interrupted", "Pending association becomes history, no system replay")
        try check(!fm.fileExists(atPath: destination.appendingPathComponent("Exchange").path)
                  && fm.fileExists(atPath: destination.appendingPathComponent("SourceArchive/Data/Exchange/Journal/ledger.json").path), "Old transport packages archive only")
        stage("source-freeze-activation-and-corruption")
        try fails("Imported store is sealed until explicit source-write-freeze activation") {
            try OrganizerMigration.requireActiveAuthority(directory: destination)
        }
        let authority = directory.appendingPathComponent("Synthetic-SourceFreeze.json")
        var freeze = try freezeReceipt(snapshot: snapshot, destination: destination)
        freeze["kind"] = "SourceDataBaseline"
        try writeReceipt(freeze, to: authority)
        try fails("A preparatory baseline is never production authority") {
            _ = try OrganizerMigration.activate(destination: destination, authorityReceipt: authority)
        }
        freeze["kind"] = "GaoSeriesSourceWriteFreeze"
        let correctInventory = freeze["sourceInventorySHA256"]!
        freeze["sourceInventorySHA256"] = String(repeating: "0", count: 64)
        try writeReceipt(freeze, to: authority)
        try fails("Wrong frozen source inventory cannot activate") {
            _ = try OrganizerMigration.activate(destination: destination, authorityReceipt: authority)
        }
        freeze["sourceInventorySHA256"] = correctInventory
        try writeReceipt(freeze, to: authority)
        let importedBytes = try hashFiles(destination)
        _ = try OrganizerMigration.activate(destination: destination, authorityReceipt: authority)
        try OrganizerMigration.requireActiveAuthority(directory: destination)
        var activatedBytes = try hashFiles(destination)
        activatedBytes.removeValue(forKey: "SourceAuthorityReceipt.json"); activatedBytes.removeValue(forKey: "ActivationReceipt.json")
        try check(activatedBytes == importedBytes, "Activation adds only exact authority evidence, never rewrites existing target data")
        let activatedBaseline = try hashFiles(destination)
        let again = try OrganizerMigration.activate(destination: destination, authorityReceipt: authority)
        try check(again.alreadyImported && hashFiles(destination) == activatedBaseline, "Same authority receipt is read-only idempotent")
        let activationURL = destination.appendingPathComponent("ActivationReceipt.json")
        let validActivation = try Data(contentsOf: activationURL)
        var brokenActivation = try JSONSerialization.jsonObject(with: validActivation) as! [String: Any]
        brokenActivation["sha256"] = String(repeating: "0", count: 64)
        try JSONSerialization.data(withJSONObject: brokenActivation, options: [.sortedKeys]).write(to: activationURL)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: activationURL.path)
        try fails("Corrupt local activation receipt stops runtime writes") {
            try OrganizerMigration.requireActiveAuthority(directory: destination)
        }
        try validActivation.write(to: activationURL)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: activationURL.path)
        freeze["issuedAt"] = "2026-11-02T01:02:03Z"
        try writeReceipt(freeze, to: authority)
        let activeBeforeConflict = try hashFiles(destination)
        try fails("Different freeze receipt cannot replace active authority") {
            _ = try OrganizerMigration.activate(destination: destination, authorityReceipt: authority)
        }
        try check(try hashFiles(destination) == activeBeforeConflict, "Conflicting authority leaves target data and credentials unchanged")
        // Load the exact migrated runtime through the transplanted production
        // stores, rather than accepting only Python/dictionary shape checks.
        do {
            stage("runtime-OFProtectedDocument")
            let configuration = try OFProtectedDocument<OFLibraryConfiguration>(directory: destination, name: "configuration").load(initial: OFLibraryConfiguration())
            try check(!configuration.automaticMonitoring, "Real configuration decoder accepts migrated workspaces")
            stage("runtime-OFIndexStore")
            let index = try OFIndexStore(directory: destination, testing: true)
            let roots = try index.roots()
            try check(roots.count == 1 && roots[0].status == "needsAuthorization", "Actual index initializer accepts migrated store")
            try fails("Actual access lease cannot reuse migrated old grant") { _ = try index.accessLease(rootID: roots[0].id) }
            stage("runtime-OFAssociationController")
            let fakeSystem = NoAssociationSystem()
            let associations = try OFAssociationController(directory: destination, system: fakeSystem)
            try check(fakeSystem.calls == 0 && associations.history.count == 1 && associations.history[0].status == "interrupted", "Actual association decoder loads history without system mutation")
            stage("runtime-OFMoveEngine")
            let mover = try OFMoveEngine(directory: destination.appendingPathComponent("MovePlans"))
            try check(mover.allPlans().isEmpty, "Actual move initializer accepts exact paired ledger and anchor")
        }
        let added = destination.appendingPathComponent("NewUserData.txt")
        try Data("New target user material must survive repeat import".utf8).write(to: added)
        let repeatReport = try OrganizerMigration.importSnapshot(url: snapshot, destination: destination)
        try check(repeatReport.alreadyImported && String(data: try Data(contentsOf: added), encoding: .utf8) == "New target user material must survive repeat import", "Idempotence never restores an old whole database over newer target material")
        try check(try hashFiles(source) == before, "Swift import does not modify source")

        // A valid JSON receipt with one changed report number is still corrupt
        // unless its protected payload digest matches. Idempotence must refuse
        // without rewriting the target's later user material or its bad ledger.
        let corruptParent = directory.appendingPathComponent("CorruptLedgerTarget", isDirectory: true)
        try fm.createDirectory(at: corruptParent, withIntermediateDirectories: true)
        let corruptTarget = corruptParent.appendingPathComponent("Organizer", isDirectory: true)
        try fm.copyItem(at: destination, to: corruptTarget)
        let ledgerURL = corruptTarget.appendingPathComponent("MigrationLedger.json")
        var receiptEnvelope = try JSONSerialization.jsonObject(with: Data(contentsOf: ledgerURL)) as! [String: Any]
        var receiptPayload = try JSONSerialization.jsonObject(with: Data(base64Encoded: receiptEnvelope["payload"] as! String)!) as! [String: Any]
        var changedReport = receiptPayload["report"] as! [String: Any]
        changedReport["importedFiles"] = (changedReport["importedFiles"] as! Int) + 1
        receiptPayload["report"] = changedReport
        receiptEnvelope["payload"] = try JSONSerialization.data(withJSONObject: receiptPayload, options: [.sortedKeys]).base64EncodedString()
        // Deliberately retain the original SHA, so this tests actual corruption.
        try JSONSerialization.data(withJSONObject: receiptEnvelope, options: [.sortedKeys]).write(to: ledgerURL)
        let corruptBefore = try hashFiles(corruptTarget)
        try fails("Changed migration report with mismatched digest is not idempotent success") {
            _ = try OrganizerMigration.importSnapshot(url: snapshot, destination: corruptTarget)
        }
        try check(try hashFiles(corruptTarget) == corruptBefore, "Corrupt migration ledger refuses without overwriting newer target material")

        stage("durable-phase-interruption-recovery")
        // Two actual durable phase interruptions. Both retries use the same
        // snapshot; no test manually invents an initialization/receipt document.
        enum Injected: Error { case stop }
        for phase in [OrganizerMigrationPhase.beforePublish, .afterPublishBeforeAnchor] {
            let faultParent = directory.appendingPathComponent("Fault-" + phase.rawValue, isDirectory: true)
            try fm.createDirectory(at: faultParent, withIntermediateDirectories: true)
            let target = faultParent.appendingPathComponent("Organizer", isDirectory: true)
            var triggered = false
            try fails("Injected durable migration phase must interrupt") {
                _ = try OrganizerMigration.importSnapshot(url: snapshot, destination: target, testingFault: { actual in
                    if actual == phase { triggered = true; throw Injected.stop }
                })
            }
            try check(triggered && !fm.fileExists(atPath: faultParent.appendingPathComponent("Organizer.initialized").path), "Interrupted import does not publish initialization prematurely")
            if phase == .beforePublish {
                try check(!fm.fileExists(atPath: target.path), "Before-publish interruption leaves target absent")
            } else {
                try Data("later material must not be rolled back".utf8).write(to: target.appendingPathComponent("Later.txt"))
            }
            _ = try OrganizerMigration.importSnapshot(url: snapshot, destination: target)
            try check(fm.fileExists(atPath: faultParent.appendingPathComponent("Organizer.initialized").path), "Explicit retry recovers exact owned phase")
            if phase == .afterPublishBeforeAnchor {
                try check(try String(contentsOf: target.appendingPathComponent("Later.txt"), encoding: .utf8) == "later material must not be rolled back", "Recovery never replaces target files added after interrupted publication")
            }
        }
        let occupiedParent = directory.appendingPathComponent("Occupied", isDirectory: true)
        let occupied = occupiedParent.appendingPathComponent("Organizer", isDirectory: true)
        try fm.createDirectory(at: occupied, withIntermediateDirectories: true)
        try Data("unknown real-like material".utf8).write(to: occupied.appendingPathComponent("keep.txt"))
        let occupiedBefore = try hashFiles(occupied)
        try fails("Unknown nonempty target rejected") { _ = try OrganizerMigration.importSnapshot(url: snapshot, destination: occupied) }
        try check(try hashFiles(occupied) == occupiedBefore, "Unknown target survives refusal unchanged")

        let broken = directory.appendingPathComponent("Broken.noindex")
        try fm.copyItem(at: snapshot, to: broken)
        try fm.removeItem(at: broken.appendingPathComponent("Data/configuration.initialized"))
        let brokenParent = directory.appendingPathComponent("BrokenTarget", isDirectory: true)
        try fm.createDirectory(at: brokenParent, withIntermediateDirectories: true)
        try fails("Missing initialized evidence rejected") { _ = try OrganizerMigration.importSnapshot(url: broken, destination: brokenParent.appendingPathComponent("Organizer")) }
        try check(!fm.fileExists(atPath: brokenParent.appendingPathComponent("Organizer").path), "Rejected snapshot creates no target")

        let futureSource = directory.appendingPathComponent("FutureSource", isDirectory: true)
        try fm.copyItem(at: source, to: futureSource)
        try sql(futureSource.appendingPathComponent("metadata.sqlite")) { db in try execute(db, "PRAGMA user_version=999") }
        try fails("Future source schema export rejected") { try export(futureSource, preferences: prefs, to: directory.appendingPathComponent("Future.noindex")) }

        stage("invalid-source-move-ledger-permission-refusal")
        let permissionSource = directory.appendingPathComponent("PermissionSource", isDirectory: true)
        try fm.copyItem(at: source, to: permissionSource)
        try fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: permissionSource.appendingPathComponent("MovePlans/ledger.json").path)
        let permissionBefore = try hashFiles(permissionSource)
        let permissionOutput = directory.appendingPathComponent("Permission.noindex")
        try fails("Source move ledger with public permissions cannot export usable runtime") {
            try export(permissionSource, preferences: prefs, to: permissionOutput)
        }
        try check(!fm.fileExists(atPath: permissionOutput.path) && hashFiles(permissionSource) == permissionBefore,
                  "Unsafe source permissions are refused before output; source is not silently repaired")
        let linkSource = directory.appendingPathComponent("LinkSource", isDirectory: true)
        try fm.copyItem(at: source, to: linkSource)
        try fm.createSymbolicLink(at: linkSource.appendingPathComponent("unsafe-link"), withDestinationURL: prefs)
        try fails("Symlink source export rejected") { try export(linkSource, preferences: prefs, to: directory.appendingPathComponent("Link.noindex")) }

        stage("source-WAL-consistency")
        // WAL transactions must be included without touching the original WAL.
        let walSource = directory.appendingPathComponent("WALSource", isDirectory: true)
        try fm.copyItem(at: source, to: walSource)
        try sql(walSource.appendingPathComponent("metadata.sqlite")) { db in
            try execute(db, "PRAGMA journal_mode=WAL; PRAGMA wal_autocheckpoint=0; UPDATE files SET favorite=1")
            let walBefore = try hashFiles(walSource)
            let walSnapshot = directory.appendingPathComponent("WALSnapshot.noindex")
            try export(walSource, preferences: prefs, to: walSnapshot)
            try check(try hashFiles(walSource) == walBefore, "Online export never opens/writes source SQLite or WAL")
            try sql(walSnapshot.appendingPathComponent("Data/metadata.sqlite")) { copy in
                try check(try scalar(copy, "SELECT favorite FROM files") == "1", "Committed WAL state present in standalone exported SQLite")
            }
        }

        stage("private-pending-inode-retirement-refusal")
        // Copies are NOT originals: pending private-source physical recovery
        // must fail before target creation, never rewrite an inode to pretend.
        let pending = directory.appendingPathComponent("PendingSource", isDirectory: true)
        try fm.copyItem(at: source, to: pending)
        let physical = pending.appendingPathComponent("RecoveryObject.txt")
        try Data("pending original must remain at original inode".utf8).write(to: physical)
        let inode = try fm.attributesOfItem(atPath: physical.path)[.systemFileNumber] as? NSNumber
        let marker = try JSONSerialization.jsonObject(with: Data(contentsOf: pending.appendingPathComponent("MovePlans/initialized.json"))) as! [String: Any]
        let op: [String: Any] = ["id": UUID().uuidString, "source": pending.appendingPathComponent("Absent.txt").absoluteString,
                                "destination": physical.absoluteString, "state": "moved", "crossVolume": false, "journal": []]
        let plan: [String: Any] = ["id": UUID().uuidString, "revision": 0, "createdAt": 0, "updatedAt": 0,
                                   "state": "needsRecovery", "operations": [op], "sourceRoots": []]
        try envelope(["schemaVersion": 1, "storeID": marker["storeID"]!, "plans": [plan]], to: pending.appendingPathComponent("MovePlans/ledger.json"), schema: false)
        let pendingSnapshot = directory.appendingPathComponent("Pending.noindex")
        try export(pending, preferences: prefs, to: pendingSnapshot)
        let pendingParent = directory.appendingPathComponent("PendingTarget", isDirectory: true)
        try fm.createDirectory(at: pendingParent, withIntermediateDirectories: true)
        try fails("Copied recovery object cannot masquerade as source inode") { _ = try OrganizerMigration.importSnapshot(url: pendingSnapshot, destination: pendingParent.appendingPathComponent("Organizer")) }
        try check(!fm.fileExists(atPath: pendingParent.appendingPathComponent("Organizer").path)
            && (try fm.attributesOfItem(atPath: physical.path)[.systemFileNumber] as? NSNumber) == inode,
            "Private pending recovery blocks retirement; source inode retained")
        print("PASS: Organizer migration actual synthetic export/restore/import, WAL, idempotence and failure guards; no App/window/system association/smoke")
    }

    private static func freezeReceipt(snapshot: URL, destination: URL) throws -> [String: Any] {
        let bytes = try Data(contentsOf: snapshot.appendingPathComponent("snapshot.json"))
        let manifest = try JSONSerialization.jsonObject(with: bytes) as! [String: Any]
        return ["schemaVersion": 1, "kind": "GaoSeriesSourceWriteFreeze",
            "sourceBundleID": "com.gaoseries.GaoZhengLi", "targetBundleID": "com.gaoseries.GaoWenJian",
            "sourceDataRoot": manifest["sourceDataRoot"]!, "targetDataRoot": destination.path,
            "snapshotID": manifest["snapshotID"]!, "manifestSHA256": hash(bytes),
            "sourceInventorySHA256": manifest["sourceInventorySHA256"]!,
            "sourcePreferencesSHA256": manifest["sourcePreferencesSHA256"]!,
            "writersStopped": true, "sourceFrozen": true,
            "issuedAt": ISO8601DateFormatter().string(from: Date()),
            "scope": "SYNTHETIC source-freeze declaration for isolated actual-engine test only"]
    }
    private static func writeReceipt(_ value: [String: Any], to url: URL) throws {
        try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
    private final class NoAssociationSystem: OFAssociationSystem {
        var calls = 0
        func current(mode: String, identifier: String) throws -> URL? { calls += 1; throw OrganizerMigrationFailure("Unexpected system-association read during migration") }
        func candidates(mode: String, identifier: String) throws -> [URL] { calls += 1; throw OrganizerMigrationFailure("Unexpected system-association candidates during migration") }
        func set(application: URL, mode: String, identifier: String) async throws { calls += 1; throw OrganizerMigrationFailure("Forbidden system-association write during migration") }
    }
    private static func stage(_ name: String) {
        FileHandle.standardOutput.write(Data(("OrganizerMigrationTests stage: " + name + "\n").utf8))
    }
    private static func export(_ source: URL, preferences: URL, to target: URL) throws {
        let script = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("OrganizerMigrationFixture.py")
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        p.arguments = [script.path, "--source", source.path, "--preferences", preferences.path, "--output", target.path]
        let output = Pipe(); p.standardOutput = output; p.standardError = output
        try p.run()
        let bytes = output.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit()
        guard p.terminationStatus == 0 else { throw OrganizerMigrationFailure("Synthetic exporter failed: " + (String(data: bytes, encoding: .utf8) ?? "")) }
    }
    private static func fixture(_ root: URL, preferences: URL, databaseID: String) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: root.appendingPathComponent("MovePlans"), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try fm.createDirectory(at: root.appendingPathComponent("Exchange/Journal"), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try Data().write(to: root.appendingPathComponent(".app.lock"))
        try PropertyListSerialization.data(fromPropertyList: ["GaoZhengLi.initialized.v1": true], format: .xml, options: 0).write(to: preferences)
        let rootID = UUID().uuidString
        try envelope(["schemaVersion": 1, "workspaces": [], "savedQueries": [], "appearance": "system", "automaticMonitoring": true], to: root.appendingPathComponent("configuration.json"))
        try envelope([["id": UUID().uuidString, "date": 0, "mode": "type", "identifier": "public.plain-text", "requestedApplication": "file:///Applications/TextEdit.app/", "status": "pending", "detail": "synthetic"]], to: root.appendingPathComponent("associations_history.json"))
        for name in ["configuration", "associations_history"] { try Data("schema=1\n".utf8).write(to: root.appendingPathComponent(name + ".initialized")) }
        do {
            let actualMoveStore = try OFMoveEngine(directory: root.appendingPathComponent("MovePlans"))
            try check(actualMoveStore.allPlans().isEmpty, "Fixture move ledger created by actual production engine")
        }
        try JSONSerialization.data(withJSONObject: ["schemaVersion": 1, "initializedAt": "2026-11-02T00:00:00Z"]).write(to: root.appendingPathComponent("exchange-initialized.json"))
        try envelope(["schemaVersion": 1, "generation": 0, "records": [:]], to: root.appendingPathComponent("Exchange/Journal/ledger.json"))
        try JSONSerialization.data(withJSONObject: ["schemaVersion": 2, "databaseID": databaseID]).write(to: root.appendingPathComponent("index-initialized.json"))
        try sql(root.appendingPathComponent("metadata.sqlite")) { db in
            try execute(db, """
            PRAGMA user_version=2;
            CREATE TABLE index_meta(key TEXT PRIMARY KEY,value TEXT NOT NULL);
            INSERT INTO index_meta VALUES('databaseID','\(databaseID)');
            CREATE TABLE schema_history(version INTEGER NOT NULL,applied_at REAL NOT NULL); INSERT INTO schema_history VALUES(2,0);
            CREATE TABLE authorized_roots(id TEXT PRIMARY KEY,display_name TEXT NOT NULL,path TEXT NOT NULL,bookmark BLOB NOT NULL,volume TEXT NOT NULL,device INTEGER NOT NULL,inode INTEGER NOT NULL,root_created REAL NOT NULL,status TEXT NOT NULL DEFAULT 'ready',paused INTEGER NOT NULL DEFAULT 0,last_scan REAL,last_event INTEGER NOT NULL DEFAULT 0,diagnostic TEXT);
            INSERT INTO authorized_roots(id,display_name,path,bookmark,volume,device,inode,root_created) VALUES('\(rootID)','Synthetic','/SYNTHETIC/user-original',X'01020304','synthetic',1,2,0);
            CREATE TABLE files(id TEXT PRIMARY KEY,root_id TEXT NOT NULL REFERENCES authorized_roots(id),relative_path TEXT NOT NULL,name TEXT NOT NULL,extension TEXT NOT NULL,uti TEXT NOT NULL,size INTEGER NOT NULL,modified REAL NOT NULL,created REAL NOT NULL,is_directory INTEGER NOT NULL,is_package INTEGER NOT NULL,is_symlink INTEGER NOT NULL,is_placeholder INTEGER NOT NULL,device INTEGER NOT NULL,inode INTEGER NOT NULL,volume TEXT NOT NULL,name_norm TEXT NOT NULL,path_norm TEXT NOT NULL,generation TEXT NOT NULL,tags TEXT NOT NULL DEFAULT '[]',favorite INTEGER NOT NULL DEFAULT 0,UNIQUE(root_id,relative_path));
            INSERT INTO files VALUES('synthetic-file','\(rootID)','hello.txt','hello.txt','txt','public.plain-text',5,0,0,0,0,0,0,1,3,'synthetic','hello.txt','hello.txt','generation','[]',0);
            CREATE TABLE scan_checkpoints(root_id TEXT PRIMARY KEY REFERENCES authorized_roots(id),payload BLOB NOT NULL,updated_at REAL NOT NULL);
            CREATE TABLE staged_files(root_id TEXT NOT NULL REFERENCES authorized_roots(id),generation TEXT NOT NULL,payload BLOB NOT NULL,file_id TEXT NOT NULL,relative_path TEXT NOT NULL,PRIMARY KEY(root_id,generation,relative_path));
            """)
        }
    }
    private static func envelope(_ value: Any, to url: URL, schema: Bool = true) throws {
        let payload = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
        var object: [String: Any] = ["payload": payload.base64EncodedString(), "sha256": hash(payload)]
        if schema { object["schemaVersion"] = 1 }
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]).write(to: url)
    }
    private static func decodeEnvelope(_ url: URL) throws -> Any {
        let value = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
        return try JSONSerialization.jsonObject(with: Data(base64Encoded: value["payload"] as! String)!)
    }
    private static func sql<T>(_ url: URL, body: (OpaquePointer) throws -> T) throws -> T {
        var db: OpaquePointer?
        guard sqlite3_open(url.path, &db) == SQLITE_OK, let db else { throw OrganizerMigrationFailure("Synthetic SQLite open failed") }
        defer { sqlite3_close(db) }
        return try body(db)
    }
    private static func execute(_ db: OpaquePointer, _ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw OrganizerMigrationFailure(String(cString: sqlite3_errmsg(db))) }
    }
    private static func scalar(_ db: OpaquePointer, _ sql: String) throws -> String {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { throw OrganizerMigrationFailure("Synthetic query failed") }
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW, let text = sqlite3_column_text(stmt, 0) else { throw OrganizerMigrationFailure("Synthetic row missing") }
        return String(cString: text)
    }
    private static func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    private static func hashFiles(_ root: URL) throws -> [String: String] {
        var result: [String: String] = [:]
        guard let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey]) else { throw OrganizerMigrationFailure("Synthetic inventory failed") }
        for case let u as URL in e where try u.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true {
            result[String(u.path.dropFirst(root.path.count + 1))] = hash(try Data(contentsOf: u))
        }
        return result
    }
    private static func check(_ value: Bool, _ message: String) throws { if !value { throw OrganizerMigrationFailure(message) } }
    private static func fails(_ message: String, body: () throws -> Void) throws {
        var failed = false
        do { try body() } catch { failed = true }
        try check(failed, message)
    }
}
