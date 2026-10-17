import AppKit
import Foundation

@MainActor enum ReferenceSelectionTests {
    @MainActor static func run(in directory: URL) throws {
        try check(NSApp == nil, "No App is initialized")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let foreign = directory.appendingPathComponent("Foreign", isDirectory: true)
        let store = WorkspaceStore(); store.tabs = []; store.selection = nil
        store.newText(.markdown, text: "保留现有未保存草稿")
        let previous = store.active!, originalDraft = previous.text
        let first = directory.appendingPathComponent("本人所选原件.md")
        let second = directory.appendingPathComponent("第二份原件.md")
        try Data("原件内容\n".utf8).write(to: first)
        try Data("第二份内容\n".utf8).write(to: second)
        let clock = Date()
        var selected: URL? = first, selectionCalls = 0
        var mode = GaoReferenceOpenMode.copy
        var allowReceive = true
        var offeredReplies: [URL] = []
        var interaction = GaoHandoffInteraction(confirm: { _ in allowReceive }, selectReference: { _ in
            selectionCalls += 1; return selected
        }, offerResult: { _, url in offeredReplies.append(url) })
        let firstReference = try reference(first, id: "first")

        // Default injected behavior stays a verified private copy, so callers
        // that predate the extra choice cannot silently start editing originals.
        let copyRequest = try request([firstReference], root: foreign, now: clock)
        let copied = try GaoHandoffService.receive(url: copyRequest, store: store, interaction: interaction, now: clock)
        guard let copyTab = store.tabs.first(where: { copied.openedTabIDs.contains($0.id) }) else {
            throw FileIssue.message("Reference copy did not open: \(copied.status); \(copied.messages.joined(separator: "; ")); \(store.error ?? "")")
        }
        try check(copied.status == "completed" && copyTab.url != first && copyTab.text == "原件内容\n", "Default mode opens a private verified copy")
        try check(previous.text == originalDraft && previous.dirty, "Existing dirty text survives a reference import")

        allowReceive = false; store.status = "正在复制并核验交接文件，可取消…"; store.error = nil
        let declined = try GaoHandoffService.receive(url: request([firstReference], root: foreign, now: clock), store: store, interaction: interaction, now: clock)
        try check(declined.status == "cancelled" && store.status.contains("已取消") && !store.status.contains("正在复制") && store.error == nil, "Declining request confirmation clears busy wording without an error")
        let declinedResult = try chooseResult([firstReference], foreign: foreign, now: clock)
        store.status = "正在复制并核验交接文件，可取消…"
        let declinedResultOutcome = try GaoHandoffService.receive(url: declinedResult, store: store, interaction: interaction, now: clock)
        try check(declinedResultOutcome.status == "cancelled" && store.status.contains("已取消接收结果") && store.status.contains("对方报告：completed") && !store.status.contains("正在复制") && store.error == nil, "Declining result confirmation distinguishes provider status and local cancellation")
        allowReceive = true

        interaction.referenceMode = { _ in mode }
        mode = .cancel
        let callsBeforeCancel = selectionCalls, tabsBeforeCancel = store.tabs.count
        let cancelled = try GaoHandoffService.receive(url: request([firstReference], root: foreign, now: clock), store: store, interaction: interaction, now: clock)
        try check(cancelled.status == "cancelled" && store.tabs.count == tabsBeforeCancel && selectionCalls == callsBeforeCancel, "Cancelling the mode choice never asks for permission or opens files")
        try check(store.status.contains("已取消") && !store.status.contains("正在复制") && store.error == nil, "Cancelling reference selection leaves a final status without an error")
        try check(try GaoProcessedRequestStore(root: GaoHandoffService.exchangeRoot).lookup(cancelled.requestID)?.phase == .cancelled, "All-reference cancellation is durably recorded as cancelled")
        mode = .original; selected = nil
        let panelCancel = try GaoHandoffService.receive(url: request([firstReference], root: foreign, now: clock), store: store, interaction: interaction, now: clock)
        try check(panelCancel.status == "cancelled" && store.tabs.count == tabsBeforeCancel, "Cancelling local permission selection stays cancellation")

        selected = second
        let mismatch = try GaoHandoffService.receive(url: request([firstReference], root: foreign, now: clock), store: store, interaction: interaction, now: clock)
        try check(mismatch.status == "failed" && store.tabs.count == tabsBeforeCancel, "Another local file does not authorize a declared reference")
        selected = first
        let opened = try GaoHandoffService.receive(url: request([firstReference], root: foreign, now: clock), store: store, interaction: interaction, now: clock)
        guard let originalTab = store.tabs.first(where: { opened.openedTabIDs.contains($0.id) }) else {
            throw FileIssue.message("Reference original did not open: \(opened.status); \(opened.messages.joined(separator: "; ")); \(store.error ?? "")")
        }
        try check(opened.status == "completed" && originalTab.url == first && originalTab.originalDigest == firstReference.sha256, "Explicit original mode opens the independently authorized path")
        originalTab.edited("原件标签的未保存修改")
        let provenanceBefore = originalTab.incoming, beforeExisting = store.tabs.count
        store.select(previous)
        let existing = try GaoHandoffService.receive(url: request([firstReference], root: foreign, now: clock), store: store, interaction: interaction, now: clock)
        try check(existing.status == "completed" && existing.openedTabIDs == [originalTab.id] && store.tabs.count == beforeExisting, "Already-open original selects its existing tab")
        try check(originalTab.text == "原件标签的未保存修改" && originalTab.dirty && originalTab.incoming == provenanceBefore, "A new reference cannot reset dirty content or replace existing provenance")
        try check(try String(contentsOf: first, encoding: .utf8) == "原件内容\n", "Opening and selecting an original never saves its edits")

        let stale = try reference(second, id: "stale")
        try Data("外部新版本\n".utf8).write(to: second)
        selected = second
        let changed = try GaoHandoffService.receive(url: request([stale], root: foreign, now: clock), store: store, interaction: interaction, now: clock)
        try check(changed.status == "failed" && changed.openedTabIDs.isEmpty && originalTab.dirty, "Changed identity/content is an invalid reference, not a replacement")
        let missing = try reference(second, id: "missing")
        try FileManager.default.removeItem(at: second)
        let deleted = try GaoHandoffService.receive(url: request([missing], root: foreign, now: clock), store: store, interaction: interaction, now: clock)
        try check(deleted.status == "failed" && deleted.openedTabIDs.isEmpty, "A deleted original cannot be reconstructed from a stale path")

        try Data("恢复为另一份合法文件".utf8).write(to: second)
        let secondReference = try reference(second, id: "second")
        interaction.referenceMode = { ref in ref.id == "first" ? .copy : .cancel }
        interaction.selectReference = { ref in ref.id == "first" ? first : second }
        let partial = try GaoHandoffService.receive(url: request([firstReference, secondReference], root: foreign, now: clock), store: store, interaction: interaction, now: clock)
        try check(partial.status == "partial" && partial.openedTabIDs.count == 1 && originalTab.dirty && previous.dirty, "Partial cancellation preserves successful copy and earlier edits")
        try check(store.status.contains("本机部分接收") && store.status.contains("1/2") && store.error == nil, "Partial reference cancellation reports the opened fraction without treating cancellation as an error")

        let blocked = directory.appendingPathComponent("权限撤回.md")
        try Data("不能读取".utf8).write(to: blocked)
        let blockedRef = try reference(blocked, id: "permission")
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: blocked.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: blocked.path) }
        interaction.referenceMode = { _ in .copy }; interaction.selectReference = { _ in blocked }
        let denied = try GaoHandoffService.receive(url: request([blockedRef], root: foreign, now: clock), store: store, interaction: interaction, now: clock)
        try check(denied.status == "failed" && denied.openedTabIDs.isEmpty && originalTab.dirty, "Unreadable original fails without losing existing documents")

        interaction.referenceMode = { _ in .cancel }; interaction.selectReference = { _ in first }
        let providerResult = try chooseResult([firstReference], foreign: foreign, now: clock)
        let resultCancel = try GaoHandoffService.receive(url: providerResult, store: store, interaction: interaction, now: clock)
        let resultManifest = try manifest(providerResult)
        let record = try GaoOutgoingJournal(exchangeRoot: GaoHandoffService.exchangeRoot).lookupResult(resultManifest.requestID)
        try check(resultCancel.status == "cancelled" && record?.phase == .cancelled && record?.status == "completed", "Result cancellation remains separate from the provider's reported status")
        try check(store.status.contains("对方报告：completed") && store.status.contains("本机已取消接收") && store.status.contains("0/1") && store.error == nil, "Reference result cancellation replaces busy wording and does not raise an error")

        interaction.referenceMode = { _ in .original }
        let originalResult = try chooseResult([firstReference], foreign: foreign, now: clock)
        let resultOpen = try GaoHandoffService.receive(url: originalResult, store: store, interaction: interaction, now: clock)
        try check(resultOpen.status == "completed" && resultOpen.openedTabIDs == [originalTab.id] && originalTab.text == "原件标签的未保存修改", "files.choose original mode preserves and selects an existing dirty tab")
        let repeatCount = store.tabs.count
        let repeated = try GaoHandoffService.receive(url: originalResult, store: store, interaction: interaction, now: clock)
        try check(repeated.duplicate && store.tabs.count == repeatCount, "Repeated provider result does not reauthorize or duplicate originals")

        interaction.referenceMode = { _ in .copy }
        interaction.selectReference = { ref in ref.id == "first" ? first : second }
        let brokenResult = try chooseResult([firstReference, stale], foreign: foreign, now: clock)
        let partialResult = try GaoHandoffService.receive(url: brokenResult, store: store, interaction: interaction, now: clock)
        try check(partialResult.status == "partial" && partialResult.openedTabIDs.count == 1, "A failed local reference does not discard a successful result copy")
        try check(store.status.contains("对方报告：completed") && store.status.contains("本机部分接收") && store.status.contains("1/2") && !store.status.contains("全部完成") && store.error != nil, "Local failure is distinct from provider completion and shows the accurate opened fraction")
        try check(NSApp == nil && !offeredReplies.isEmpty, "All status replies use injected presentation, without launching an App")
        print("Reference selection: default copy, explicit original, local authorization cancellation, partial import, changed/deleted/unreadable references, dirty-tab preservation and files.choose result routing passed. System sandbox revocation remains unverified.")
    }

    private static func request(_ references: [GaoActionReference], root: URL, now: Date) throws -> URL {
        try GaoActionWriter.writeRequest(action: "documents.open", references: references,
            sourceBundleID: "com.gaoseries.FixtureProvider", targetBundleID: GaoActionContract.bundleID, exchangeRoot: root, now: now)
    }
    private static func chooseResult(_ references: [GaoActionReference], foreign: URL, now: Date) throws -> URL {
        let request = try GaoActionWriter.writeRequest(action: "files.choose", parameters: ["multiple": .bool(true)],
            targetBundleID: "com.gaoseries.GaoZhengLi", exchangeRoot: GaoHandoffService.exchangeRoot, now: now)
        _ = try GaoOutgoingJournal(exchangeRoot: GaoHandoffService.exchangeRoot).registerOutgoing(packageURL: request, expectedTargetBundleID: "com.gaoseries.GaoZhengLi", now: now)
        let package = try GaoActionWriter.writeResult(inReplyTo: manifest(request), status: "completed", references: references, exchangeRoot: foreign, now: now)
        var result = try manifest(package); result.sourceBundleID = "com.gaoseries.GaoZhengLi"
        try JSONEncoder().encode(result).write(to: package.appendingPathComponent("manifest.json"))
        return package
    }
    private static func manifest(_ package: URL) throws -> GaoActionManifest {
        try JSONDecoder().decode(GaoActionManifest.self, from: Data(contentsOf: package.appendingPathComponent("manifest.json")))
    }
    private static func reference(_ url: URL, id: String) throws -> GaoActionReference {
        let stat = try GaoPrivateIO.regularURL(url).statValue()
        let modified = Date(timeIntervalSince1970: Double(stat.st_mtimespec.tv_sec) + Double(stat.st_mtimespec.tv_nsec) / 1_000_000_000)
        let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return .init(id: id, kind: "file", fileURL: url.absoluteString, displayName: url.lastPathComponent,
            declaredIdentity: .init(volumeUUID: try url.resourceValues(forKeys: [.volumeUUIDStringKey]).volumeUUIDString,
                                   device: UInt64(bitPattern: Int64(stat.st_dev)), inode: UInt64(stat.st_ino),
                                   byteCount: Int64(stat.st_size), modifiedAt: formatter.string(from: modified)),
            sha256: FileSafety.digest(try Data(contentsOf: url)))
    }
    private static func check(_ condition: @autoclosure () throws -> Bool, _ text: String) throws {
        if try !condition() { throw FileIssue.message("Reference selection: " + text) }
    }
}
