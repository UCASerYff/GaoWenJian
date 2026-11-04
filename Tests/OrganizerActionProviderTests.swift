import AppKit
import Foundation
import UniformTypeIdentifiers
import Darwin

/// Synthetic, presentation-injected tests run the production transport, journal,
/// selection validation and provider dispatch. No system association is changed.
@MainActor enum OrganizerActionProviderTests {
    static func run(in directory: URL) throws -> Int {
        guard NSApp == nil, FileSafety.root.path.hasPrefix("/private/tmp/gaowenjian-") else { throw FileIssue.message("Organizer action tests require an isolated temporary root without an App") }
        var assertions = 0
        func check(_ yes: @autoclosure () throws -> Bool, _ name: String) throws {
            guard try yes() else { throw FileIssue.message("Organizer provider: " + name) }; assertions += 1
        }
        func rejects(_ code: String, _ body: () throws -> Void) throws {
            do { try body() } catch let issue as GaoActionIssue {
                try check(issue.code == code, "expected \(code), got \(issue.code)"); return
            }
            throw FileIssue.message("Organizer provider expected rejection: " + code)
        }
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let files = directory.appendingPathComponent("Synthetic", isDirectory: true)
        let outside = directory.appendingPathComponent("Outside", isDirectory: true)
        try fm.createDirectory(at: files, withIntermediateDirectories: true)
        try fm.createDirectory(at: outside, withIntermediateDirectories: true)
        let text = files.appendingPathComponent("中文报告.txt"), image = files.appendingPathComponent("图示.png")
        try Data("公开测试文件。保留原件。\n".utf8).write(to: text)
        try Data([0x89, 0x50, 0x4e, 0x47]).write(to: image)
        let originalDigest = FileSafety.digest(try Data(contentsOf: text))
        let foreign = directory.appendingPathComponent("Foreign", isDirectory: true)
        let clock = Date()
        func manifest(_ action: String, _ parameters: [String: GaoJSONValue] = [:], _ references: [GaoActionReference] = []) -> GaoActionManifest {
            .init(kind: "request", requestID: UUID().uuidString, sourceBundleID: "com.gaoseries.OrganizerTestClient", targetBundleID: GaoActionContract.bundleID,
                  action: action, createdAt: GaoActionContract.timestamp(clock), expiresAt: GaoActionContract.timestamp(clock.addingTimeInterval(120)),
                  nonce: Data(repeating: 3, count: 32).base64EncodedString(), items: [], references: references, parameters: parameters)
        }
        func package(_ action: String, _ parameters: [String: GaoJSONValue] = [:], _ references: [GaoActionReference] = []) throws -> URL {
            try GaoActionWriter.writeRequest(action: action, references: references, parameters: parameters, sourceBundleID: "com.gaoseries.OrganizerTestClient", targetBundleID: GaoActionContract.bundleID, exchangeRoot: foreign, now: clock)
        }
        // Fault injection exercises the production metadata fallback without
        // initializing LaunchServices or treating file I/O denial as metadata.
        let metadataMiss = NSError(domain: NSCocoaErrorDomain, code: NSFileReadUnknownError, userInfo: [NSUnderlyingErrorKey: NSError(domain: NSOSStatusErrorDomain, code: -10813)])
        let fallback = try OrganizerActionProvider.selectionType(url: text) { throw metadataMiss }
        try check(fallback.conforms(to: .plainText), "only an explicit LS metadata miss uses the real filename extension")
        try check(OrganizerActionProvider.declaredType("public.plain-text")?.identifier == UTType.plainText.identifier, "standard allowed UTI is resolved without registering a dynamic type")
        let pngFallback = try OrganizerActionProvider.selectionType(url: image) { throw metadataMiss }
        try check(pngFallback.identifier == UTType.png.identifier, "explicit LS miss uses the canonical PNG constant")
        let unknownFallback = try OrganizerActionProvider.selectionType(url: files.appendingPathComponent("ordinary.unknown-gao-test")) { throw metadataMiss }
        try check(unknownFallback.identifier == UTType.data.identifier, "unknown extension is not assigned a fabricated concrete type")
        try check(OrganizerActionProvider.declaredType("com.gaoseries.unregistered-test-kind") == nil, "unknown unregistered allowed type is rejected")
        let deniedMetadata = NSError(domain: NSCocoaErrorDomain, code: NSFileReadNoPermissionError)
        do { _ = try OrganizerActionProvider.selectionType(url: text) { throw deniedMetadata }; throw FileIssue.message("metadata permission denial swallowed") }
        catch let error as NSError { try check(error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoPermissionError, "permission metadata error is propagated") }
        let unknownMetadata = NSError(domain: NSOSStatusErrorDomain, code: -50)
        do { _ = try OrganizerActionProvider.selectionType(url: text) { throw unknownMetadata }; throw FileIssue.message("unknown metadata error swallowed") }
        catch let error as NSError { try check(error.domain == NSOSStatusErrorDomain && error.code == -50, "unknown metadata error is propagated") }
        for ext in ["app", "bundle", "framework", "package"] {
            try rejects("invalidSelection") { _ = try OrganizerActionProvider.selectionType(url: files.appendingPathComponent("spoof." + ext)) { throw metadataMiss } }
        }
        let choose = manifest("files.choose", ["multiple": .bool(false), "allowedUTIs": .array([.string("public.plain-text")])])
        let selection = try OrganizerActionProvider.selection([text], for: choose)
        try check(selection.status == "completed" && selection.references.count == 1 && selection.references[0].kind == "file", "selection returns a real reference")
        try check(selection.provenance["accessRequiresReceiverVerification"]?.boolValue == true && selection.references[0].declaredIdentity.inode != nil, "references retain identity without exporting permissions")
        try rejects("invalidSelection") { _ = try OrganizerActionProvider.selection([], for: choose) }
        try rejects("invalidSelection") { _ = try OrganizerActionProvider.selection([text, text], for: choose) }
        try rejects("invalidSelection") { _ = try OrganizerActionProvider.selection([text, image], for: choose) }
        try rejects("typeMismatch") { _ = try OrganizerActionProvider.selection([image], for: choose) }
        let scopeState = try files.resourceValues(forKeys: [.volumeUUIDStringKey])
        var scopeStat = stat()
        guard lstat(files.path, &scopeStat) == 0 else { throw FileIssue.message("scope fixture missing") }
        let scope = GaoActionReference(id: "scope", kind: "directory", fileURL: files.absoluteString, displayName: "Synthetic", declaredIdentity: .init(volumeUUID: scopeState.volumeUUIDString, device: UInt64(scopeStat.st_dev), inode: UInt64(scopeStat.st_ino)))
        let scoped = manifest("files.choose", [:], [scope])
        let elsewhere = outside.appendingPathComponent("outside.txt"); try Data("公开其他文件".utf8).write(to: elsewhere)
        try rejects("outsideScope") { _ = try OrganizerActionProvider.selection([elsewhere], for: scoped) }
        let link = files.appendingPathComponent("link.txt"); try fm.createSymbolicLink(at: link, withDestinationURL: text)
        do { _ = try OrganizerActionProvider.selection([link], for: choose); throw FileIssue.message("link accepted") }
        catch let error as GaoActionIssue { try check(error.code != "", "symlink cannot be returned as an original") }

        let savedSearch = OrganizerActionProvider.indexSearch, savedAssociations = OrganizerActionProvider.manageAssociations
        defer { OrganizerActionProvider.indexSearch = savedSearch; OrganizerActionProvider.manageAssociations = savedAssociations }
        var leaseReleased = false, selectorCalls = 0, selected: [URL]? = [text]
        let ui = OrganizerProviderInteraction(search: { _, _ in selectorCalls += 1; return selected }, choose: { _ in selected }, reveal: { _ in false })
        OrganizerActionProvider.indexSearch = { _, _ in OrganizerSearchLease(urls: [text], release: { leaseReleased = true }) }
        let found = try OrganizerActionProvider.perform(manifest("files.search", ["query": .string("中文")]), interaction: ui, associationCompletion: { _ in })
        try check(found?.status == "completed" && selectorCalls == 1 && leaseReleased, "real index candidates are selected and their scope balanced")
        selected = [elsewhere]
        try rejects("selectionMismatch") { _ = try OrganizerActionProvider.perform(manifest("files.search", ["query": .string("中文")]), interaction: ui, associationCompletion: { _ in }) }
        OrganizerActionProvider.indexSearch = { _, _ in OrganizerSearchLease(urls: [], release: {}) }
        let beforeNoMatch = selectorCalls
        try rejects("noIndexedMatches") { _ = try OrganizerActionProvider.perform(manifest("files.search", ["query": .string("无命中")]), interaction: ui, associationCompletion: { _ in }) }
        try check(selectorCalls == beforeNoMatch, "empty index never falls back to a file picker")
        OrganizerActionProvider.indexSearch = nil
        try rejects("indexUnavailable") { _ = try OrganizerActionProvider.perform(manifest("files.search", ["query": .string("中文")]), interaction: ui, associationCompletion: { _ in }) }
        try rejects("invalidParameter") { try GaoActionContract.validate(manifest("files.search", ["query": .string(" \n")]), expectedTargetBundleID: GaoActionContract.bundleID, now: clock) }
        selected = nil
        try check(try OrganizerActionProvider.perform(choose, interaction: ui, associationCompletion: { _ in })?.status == "cancelled", "native selection cancellation is not completion")
        let association = manifest("associations.manage", ["uti": .string("public.plain-text")])
        try rejects("invalidAssociationReceipt") { try OrganizerActionProvider.validateCompletion(.init(status: "completed", provenance: ["workflowState": .string("opened")]), request: association) }
        try rejects("invalidAssociationReceipt") { try OrganizerActionProvider.validateCompletion(.associationChanged(uti: "public.png", readBackVerified: true), request: association) }
        try OrganizerActionProvider.validateCompletion(.associationChanged(uti: "public.plain-text", readBackVerified: true), request: association)
        assertions += 1

        // Dispatches use the same production receiver and durable ledger as Finder.
        let store = WorkspaceStore(); store.tabs = []; store.selection = nil; store.newText(.markdown, text: "未保存的公开测试稿")
        let draft = store.active!, draftID = draft.id
        selected = [text]
        var offers: [URL] = []
        var interaction = GaoHandoffInteraction(confirm: { _ in true }, selectReference: { _ in nil }, offerResult: { _, url in offers.append(url) })
        interaction.organizer = ui
        let request = try package("files.choose", ["multiple": .bool(true)])
        let first = try GaoHandoffService.receive(url: request, store: store, interaction: interaction, now: clock)
        try check(first.status == "completed" && first.openedTabIDs.isEmpty && store.tabs.count == 1 && draft.dirty, "provider does not replace or open over dirty editor tabs")
        let firstResult = try GaoActionTransport.receive(packageURL: first.resultPackageURL!, exchangeRoot: foreign, expectedTargetBundleID: "com.gaoseries.OrganizerTestClient", now: clock)
        try check(firstResult.manifest.action == "files.choose" && firstResult.manifest.sourceBundleID == GaoActionContract.bundleID && firstResult.manifest.references.count == 1, "wire result comes from new canonical provider and contains selection")
        let repeatRequest = try GaoHandoffService.receive(url: request, store: store, interaction: interaction, now: clock)
        try check(repeatRequest.duplicate && offers.count == 1 && store.active?.id == draftID, "same request is not replayed or resent")
        let revealCancelled = try GaoHandoffService.receive(url: package("files.reveal", [:], selection.references), store: store, interaction: interaction, now: clock)
        try check(revealCancelled.status == "cancelled", "cancelled identity selection is not a revealed completion")

        var completion: (@MainActor (OrganizerProviderResult) -> Void)?
        OrganizerActionProvider.manageAssociations = { uti, finish in
            guard uti == "public.plain-text" else { return false }; completion = finish; return true
        }
        let associationPackage = try package("associations.manage", ["uti": .string("public.plain-text")])
        let pending = try GaoHandoffService.receive(url: associationPackage, store: store, interaction: interaction, now: clock)
        let offersBeforeCallback = offers.count
        try check(pending.status == "pending" && pending.resultPackageURL == nil && completion != nil, "opening association management only waits and emits no completed receipt")
        try check(try GaoProcessedRequestStore(root: GaoHandoffService.exchangeRoot).lookup(pending.requestID)?.phase == .executing, "pending is durably executing rather than completed")
        let duplicatePending = try GaoHandoffService.receive(url: associationPackage, store: store, interaction: interaction, now: clock)
        try check(duplicatePending.duplicate && duplicatePending.status == "executing" && offers.count == offersBeforeCallback, "pending request resend does not replay a system change or fabricate completion")
        // A separate message updates this ledger during the pending UI. The
        // association callback must reopen it and preserve this newer generation.
        let interleaved = try GaoHandoffService.receive(url: package("files.choose"), store: store, interaction: interaction, now: clock)
        try check(interleaved.status == "completed", "other messages may complete while association UI awaits user")
        completion?(.associationChanged(uti: "public.plain-text", readBackVerified: true))
        try check(try GaoProcessedRequestStore(root: GaoHandoffService.exchangeRoot).lookup(pending.requestID)?.phase == .completed, "explicit verified association completion gets a final receipt")
        try check(try GaoProcessedRequestStore(root: GaoHandoffService.exchangeRoot).lookup(interleaved.requestID)?.phase == .completed, "deferred completion preserves interleaved journal updates")
        try check(offers.count == offersBeforeCallback + 2, "one normal receipt plus one final deferred receipt")
        completion?(.associationChanged(uti: "public.plain-text", readBackVerified: true))
        try check(offers.count == offersBeforeCallback + 2, "duplicate completion callback does not repeat business or receipt")
        try check(FileSafety.digest(try Data(contentsOf: text)) == originalDigest && draft.id == draftID && draft.text == "未保存的公开测试稿" && draft.dirty, "all provider workflows preserve original file and existing draft")
        try check(NSApp == nil, "no App, window or default association is initialized by tests")
        return assertions
    }
}
