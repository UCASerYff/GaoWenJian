import AppKit
import Foundation
import Darwin

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

    @MainActor @discardableResult static func runTimePrecision(in directory: URL) throws -> Int {
        guard NSApp == nil, CommandLine.arguments.contains("--data-dir"), FileSafety.root.path.hasPrefix("/private/tmp/gaowenjian-") else {
            throw FileIssue.message("Reference time tests require isolated temporary data without an App")
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let original = directory.appendingPathComponent("公开引用精度.txt"), other = directory.appendingPathComponent("另一公开原件.txt")
        let bytes = Data("公开合成文件：引用保留小数秒并使用严格时间边界。α 😀\n".utf8)
        try bytes.write(to: original); try bytes.write(to: other)
        let seconds = 1_792_020_000
        var assertions = 0
        func check(_ condition: @autoclosure () throws -> Bool, _ label: String) throws {
            guard try condition() else { throw FileIssue.message("Reference time: " + label) }; assertions += 1
        }
        func rejects(_ code: String, _ body: () throws -> Void) throws {
            do { try body() }
            catch let error as GaoActionIssue { try check(error.code == code, "Expected \(code), got \(error.code)"); return }
            throw FileIssue.message("Expected reference time rejection: " + code)
        }
        func setTime(_ nanos: Int) throws {
            let fd = try GaoPrivateIO.regularURL(original)
            var values = [timespec(tv_sec: seconds, tv_nsec: 0), timespec(tv_sec: seconds, tv_nsec: nanos)]
            guard futimens(fd.value, &values) == 0 else { throw FileIssue.message("Cannot set isolated fixture modification time") }
            let stat = try fd.statValue()
            try check(stat.st_mtimespec.tv_sec == seconds && stat.st_mtimespec.tv_nsec == nanos, "Fixture has exact requested stat time")
        }
        func modifiedDate(_ state: stat) -> Date {
            Date(timeIntervalSince1970: Double(state.st_mtimespec.tv_sec) + Double(state.st_mtimespec.tv_nsec) / 1_000_000_000)
        }
        func rewriteInPlace(_ contents: Data) throws {
            let fd = try GaoFixedFD(Darwin.open(original.path, O_WRONLY | O_NOFOLLOW | O_CLOEXEC))
            try check(try fd.statValue().st_size == contents.count, "In-place fixture rewrite retains its size")
            try GaoPrivateIO.writeAll(contents, to: fd.value)
            guard fsync(fd.value) == 0 else { throw FileIssue.message("Cannot sync isolated fixture rewrite") }
        }
        let wholeSecond = GaoActionContract.timestamp(Date(timeIntervalSince1970: Double(seconds)))
        for nanos in [0, 1, 500_000, 999_000] {
            try setTime(nanos)
            var ref = try reference(original, id: "whole-second")
            ref.declaredIdentity.modifiedAt = wholeSecond; ref.sha256 = nil
            try check(abs(modifiedDate(try GaoPrivateIO.regularURL(original).statValue()).timeIntervalSince(GaoActionContract.date(wholeSecond)!)) < 0.001,
                      "Whole-second fixture is inside the original strict bound")
            try GaoActionTransport.verifyReference(ref, selectedURL: original); assertions += 1
        }
        for nanos in [1_001_000, 862_398_221, 999_999_999] {
            try setTime(nanos)
            var ref = try reference(original, id: "whole-second")
            ref.declaredIdentity.modifiedAt = wholeSecond; ref.sha256 = nil
            try check(abs(modifiedDate(try GaoPrivateIO.regularURL(original).statValue()).timeIntervalSince(GaoActionContract.date(wholeSecond)!)) >= 0.001,
                      "Whole-second fixture is outside the original strict bound")
            try rejects("referenceChanged") { try GaoActionTransport.verifyReference(ref, selectedURL: original) }
        }
        var serializedBoundaries: [String] = []
        for nanos in [999_499_999, 999_500_000, 999_999_999, 862_398_221, 1] {
            try setTime(nanos)
            // Match the provider's stat Double -> Date -> fractional ISO8601
            // path, including rounding into the next second. Adjacent nanos may
            // share a Date/serialized value at this epoch; that is not an error.
            var providerReference = try reference(original, id: "fractional-boundary")
            providerReference.sha256 = nil
            let context = try GaoHandoffService.originalContext(original)
            guard let serialized = providerReference.declaredIdentity.modifiedAt, let expected = GaoActionContract.date(serialized) else {
                throw FileIssue.message("Fractional reference boundary did not serialize a valid date")
            }
            try check(serialized.contains(".") && context.declaredIdentity.modifiedAt == serialized && context.sha256 == nil,
                      "Private original context retains the provider's fractional reference precision without adding a SHA")
            let difference = abs(modifiedDate(try GaoPrivateIO.regularURL(original).statValue()).timeIntervalSince(expected))
            try check(difference < 0.001, "Fractional serialization stays inside the unchanged strict 1ms bound")
            try GaoActionTransport.verifyReference(providerReference, selectedURL: original); assertions += 1
            try GaoActionTransport.verifyReference(context, selectedURL: original); assertions += 1
            serializedBoundaries.append("\(nanos)ns=\(serialized),delta=\(String(format: "%.9f", difference))s")
        }

        // A stable rewrite can retain inode, size and the whole declared second.
        // Whole-second/no-SHA declarations must still fail at the real .862 mtime.
        try setTime(0)
        var staleWhole = try reference(original, id: "stale-whole-second")
        staleWhole.declaredIdentity.modifiedAt = wholeSecond; staleWhole.sha256 = nil
        let stateA = try GaoPrivateIO.regularURL(original).statValue()
        var changed = bytes; changed[0] = changed[0] ^ 1
        try rewriteInPlace(changed); try setTime(862_398_221)
        let stateB = try GaoPrivateIO.regularURL(original).statValue()
        try check(stateA.st_dev == stateB.st_dev && stateA.st_ino == stateB.st_ino && stateA.st_size == stateB.st_size
                  && stateA.st_mtimespec.tv_sec == stateB.st_mtimespec.tv_sec && stateB.st_mtimespec.tv_nsec == 862_398_221
                  && (try Data(contentsOf: original)) == changed, "A-to-B rewrite changes content within the same inode, size and second")
        try rejects("referenceChanged") { try GaoActionTransport.verifyReference(staleWhole, selectedURL: original) }
        try check(try GaoPrivateIO.unchanged(stateB, GaoPrivateIO.regularURL(original).statValue()), "Rejection is for a stable changed file, not a concurrent rewrite")
        try rewriteInPlace(bytes)
        try setTime(862_398_221)
        let fraction = try reference(original, id: "fractional")
        try check(GaoActionContract.timestamp(modifiedDate(try GaoPrivateIO.regularURL(original).statValue())) == wholeSecond,
                  "General manifest timestamps retain their existing whole-second format")
        for offset in [-1, 1] {
            var neighbouring = fraction; neighbouring.sha256 = nil
            neighbouring.declaredIdentity.modifiedAt = GaoActionContract.timestamp(Date(timeIntervalSince1970: Double(seconds + offset)))
            try rejects("referenceChanged") { try GaoActionTransport.verifyReference(neighbouring, selectedURL: original) }
        }
        try GaoActionTransport.verifyReference(fraction, selectedURL: original); assertions += 1
        for fractionSuffix in [".861Z", ".864Z"] {
            // Keep the date portion tied to the fixture second rather than a
            // wall clock, while crossing the existing strict 1ms boundary.
            var wrongFraction = fraction
            wrongFraction.declaredIdentity.modifiedAt = String(wholeSecond.dropLast()) + fractionSuffix
            try rejects("referenceChanged") { try GaoActionTransport.verifyReference(wrongFraction, selectedURL: original) }
        }
        for invalid in ["not-a-date", String(wholeSecond.dropLast()), "2026-10-23T06:40:45+00:00"] {
            var malformed = fraction; malformed.declaredIdentity.modifiedAt = invalid
            try rejects("invalidReference") { try GaoActionTransport.verifyReference(malformed, selectedURL: original) }
        }
        var different = fraction; different.declaredIdentity.device! += 1
        try rejects("referenceChanged") { try GaoActionTransport.verifyReference(different, selectedURL: original) }
        different = fraction; different.declaredIdentity.inode! += 1
        try rejects("referenceChanged") { try GaoActionTransport.verifyReference(different, selectedURL: original) }
        different = fraction; different.declaredIdentity.byteCount! += 1
        try rejects("referenceChanged") { try GaoActionTransport.verifyReference(different, selectedURL: original) }
        different = fraction; different.declaredIdentity.volumeUUID = UUID().uuidString
        try rejects("referenceChanged") { try GaoActionTransport.verifyReference(different, selectedURL: original) }
        different = fraction; different.sha256 = String(repeating: "0", count: 64)
        try rejects("referenceChanged") { try GaoActionTransport.verifyReference(different, selectedURL: original) }
        try rejects("referenceMismatch") { try GaoActionTransport.verifyReference(fraction, selectedURL: other) }
        var withoutSHA = fraction; withoutSHA.sha256 = nil
        try rewriteInPlace(changed); try setTime(862_398_221)
        // Fractional/no-SHA references verify the declared attributes at their
        // serialized precision. They cannot prove an absolute content snapshot
        // when content and undeclared attributes change but declared values match.
        try GaoActionTransport.verifyReference(withoutSHA, selectedURL: original); assertions += 1
        try check(try Data(contentsOf: original) == changed, "Matching fractional metadata without SHA does not claim old content proof")
        try rejects("referenceChanged") { try GaoActionTransport.verifyReference(fraction, selectedURL: original) }
        try rewriteInPlace(bytes); try setTime(862_398_221)
        try GaoActionTransport.verifyReference(GaoHandoffService.originalContext(original), selectedURL: original); assertions += 1
        let beforeChange = try GaoPrivateIO.regularURL(original).statValue()
        try setTime(862_398_222)
        try check(try !GaoPrivateIO.unchanged(beforeChange, GaoPrivateIO.regularURL(original).statValue()),
                  "Full FD change detection still rejects even a nanosecond-only change within the declared second")
        try setTime(862_398_221)

        let store = WorkspaceStore(); store.tabs = []; store.selection = nil
        store.newText(.text, text: "保持已有未保存内容")
        let previous = store.active!, previousText = previous.text
        let recovery = FileSafety.root.appendingPathComponent("recovery.json"), recoveryBefore = try Data(contentsOf: FileSafety.root.appendingPathComponent("recovery.json"))
        withoutSHA = try GaoHandoffService.originalContext(original)
        var selected = 0
        let interaction = GaoHandoffInteraction(confirm: { _ in true }, selectReference: { _ in selected += 1; return original }, offerResult: { _, _ in }, referenceMode: { _ in .copy })
        let clock = Date()
        let reply = try chooseResult([withoutSHA], foreign: directory.appendingPathComponent("Foreign"), now: clock)
        let outcome = try GaoHandoffService.receive(url: reply, store: store, interaction: interaction, now: clock)
        guard let copy = store.tabs.first(where: { outcome.openedTabIDs.contains($0.id) }), let copiedURL = copy.url else {
            throw FileIssue.message("Fractional files.choose copy did not open: " + outcome.messages.joined(separator: "; "))
        }
        try check(outcome.status == "completed" && selected == 1 && copy.kind == .text && copiedURL != original && copy.text == String(data: bytes, encoding: .utf8),
                  "Actual files.choose result with fractional mtime and no SHA opens the independently selected verified copy")
        try check(try Data(contentsOf: copiedURL) == bytes && copy.incoming?.contentSHA256 == FileSafety.digest(bytes),
                  "copyReference computes and retains its own payload SHA for a provider reference without SHA")
        try check(previous.dirty && previous.text == previousText && (try Data(contentsOf: recovery)) == recoveryBefore
                  && (try Data(contentsOf: original)) == bytes, "Reference copy preserves original bytes, existing dirty editor and recovery")
        let resultManifest = try manifest(reply)
        try check(resultManifest.references.first?.sha256 == nil && resultManifest.references.first?.declaredIdentity.modifiedAt == withoutSHA.declaredIdentity.modifiedAt
                  && withoutSHA.declaredIdentity.modifiedAt?.contains(".") == true, "Injected production result declares fractional metadata and no provider SHA")
        let record = try GaoOutgoingJournal(exchangeRoot: GaoHandoffService.exchangeRoot).lookupResult(resultManifest.requestID)
        try check(record?.status == "completed" && record?.phase == .completed && record?.openedReferenceIDs == [withoutSHA.id],
                  "Local copy completion records only the actual opened reference")
        try check(NSApp == nil, "Reference precision checks never create an application or window")
        print("Reference fractional boundaries: " + serializedBoundaries.joined(separator: "; "))
        print("Reference modification time: \(assertions) assertions passed (strict <1ms for all declarations; whole/no-SHA .862 and same-inode/size/second rewrite rejection; fractional rounding; identity/size/volume/SHA/path and full FD checks; fractional/no-SHA production copy with local digest and editor/original/recovery preservation; no UI)")
        return assertions
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
