import CryptoKit
import Darwin
import Foundation

struct OCRReturnSource: Equatable, Sendable {
    let itemID: String
    let sha256: String
    let displayName: String
    let originalURL: URL?
    let pages: [OCRPageProvenance]
}

struct OCRReturnCandidate: Equatable, Identifiable, Sendable {
    let requestID: String
    let resultID: String
    let manifestSHA256: String
    let status: String
    let expiresAt: Date
    let sources: [OCRReturnSource]
    var id: String { requestID }
}

struct OCRReturnIssue: Equatable, Identifiable, Sendable {
    let requestID: String
    let message: String
    var id: String { requestID }
}

struct OCRReturnScan: Equatable, Sendable {
    var pending = false
    var results: [OCRReturnCandidate] = []
    var issues: [OCRReturnIssue] = []
}

/// The mailbox carries consent-bound local results. A successful scan has no import side effect.
enum OCRReturnMailbox {
    static let provider = "com.gaoseries.GaoCaoZuo"
    private static let action = "ocr.files"
    private static let ticketName = "request.json"
    private static let resultName = "result.gaoaction"
    private static let suffix = ["GaoSeries", "GaoAction", "OcrReturns-v1"]

    static var defaultRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/GaoSeries/GaoAction/OcrReturns-v1", isDirectory: true)
    }

    final class Cache: @unchecked Sendable {
        fileprivate let lock = NSLock()
        fileprivate var entries: [String: Cached] = [:]
    }

    fileprivate struct Cached {
        let candidate: OCRReturnCandidate
        let members: [[String]]
        let fingerprints: [stat]
    }

    private struct Header {
        let manifest: GaoActionManifest
        let sha256: String
    }

    private struct Ticket: Encodable {
        let schemaVersion = 1
        let requestID: String
        let action: String
        let sourceBundleID: String
        let targetBundleID: String
        let requestManifestSHA256: String
        let expiresAt: String
    }

    /// A lexical fence for all descendants, including invalid paths that must never fall through to manual launch.
    static func isMailboxURL(_ url: URL, mailboxRoot: URL = defaultRoot) -> Bool {
        guard url.isFileURL, mailboxRoot.isFileURL else { return false }
        let path = lexical(url).lowercased(), root = lexical(mailboxRoot).lowercased()
        return path == root || path.hasPrefix(root + "/")
    }

    static func requestID(for url: URL, mailboxRoot: URL = defaultRoot) -> String? {
        guard isMailboxURL(url, mailboxRoot: mailboxRoot) else { return nil }
        let entries = lexical(url).split(separator: "/")
        let count = lexical(mailboxRoot).split(separator: "/").count
        guard entries.count == count + 2, entries.last == Substring(resultName) else { return nil }
        let slot = String(entries[count])
        return canonicalSlot(slot) == slot ? slot : nil
    }

    @discardableResult static func publishTicket(for session: GaoOutgoingSession, packageURL: URL, exchangeRoot: URL,
                                                  mailboxRoot: URL = defaultRoot, now: Date = Date()) throws -> URL {
        let persisted = try GaoOutgoingJournal.returnSnapshot(exchangeRoot: exchangeRoot)
        guard let own = persisted.sessions.first(where: { $0.requestID == session.requestID }),
              !own.phase.terminal, own.manifestSHA256 == session.manifestSHA256,
              let slot = canonicalSlot(own.requestID),
              lexical(packageURL.deletingLastPathComponent()) == lexical(exchangeRoot.appendingPathComponent("Outgoing")),
              packageURL.lastPathComponent == own.requestPackageName else { throw mismatch() }
        let request = try originalRequest(own, exchangeRoot: exchangeRoot, now: now)
        let exchange = try GaoPrivateIO.directory(exchangeRoot, requirePrivate: true)
        let outgoing = try GaoPrivateIO.childDirectory(exchange, "Outgoing", requirePrivate: true)
        let original = try GaoPrivateIO.childDirectory(outgoing, own.requestPackageName, requirePrivate: true)
        guard try header(original).sha256 == own.manifestSHA256 else { throw mismatch() }
        let bytes = try ticketBytes(own, request: request)
        guard let directory = try mailboxSlot(mailboxRoot, slot, create: true) else { throw mismatch() }
        try writeTicket(bytes, to: directory)
        return mailboxRoot.appendingPathComponent(slot, isDirectory: true).appendingPathComponent(ticketName)
    }

    static func scan(exchangeRoot: URL, mailboxRoot: URL = defaultRoot, now: Date = Date(), cache: Cache? = nil) throws -> OCRReturnScan {
        cache?.lock.lock()
        defer { cache?.lock.unlock() }
        var next: [String: Cached] = [:]
        defer { cache?.entries = next }
        // First launch and users who never enabled auto-return have no mailbox.
        guard let root = try mailboxDirectory(mailboxRoot, create: false) else { return OCRReturnScan() }
        let snapshot = try GaoOutgoingJournal.returnSnapshot(exchangeRoot: exchangeRoot)
        let sessions = recentSessions(snapshot.sessions, now: now)
        let existing = Dictionary(uniqueKeysWithValues: snapshot.results.map { ($0.requestID, $0.manifestSHA256) })
        var response = OCRReturnScan()
        for session in sessions {
            try Task.checkCancellation()
            guard let slot = canonicalSlot(session.requestID) else { continue }
            do {
                guard let directory = try directoryChild(root, slot, create: false, privateOnly: true),
                      let ticket = try readTicket(directory),
                      let request = try currentRequest(session, exchangeRoot: exchangeRoot, now: now) else { continue }
                guard ticket == (try ticketBytes(session, request: request)) else { throw mismatch() }
                guard let result = try directoryChild(directory, resultName, create: false, privateOnly: false) else {
                    response.pending = true
                    continue
                }
                let incoming = try header(result)
                if let approved = existing[incoming.manifest.requestID] {
                    guard approved == incoming.sha256 else { throw mismatch() }
                    continue
                }
                let key = lexical(exchangeRoot) + "\u{001f}" + lexical(mailboxRoot) + "\u{001f}" + slot
                if let cached = cache?.entries[key], cached.candidate.manifestSHA256 == incoming.sha256,
                   now < cached.candidate.expiresAt, try matches(cached, in: result) {
                    next[key] = cached
                } else {
                    let candidate = try validate(incoming, request: request, session: session, now: now)
                    let (members, stamps) = try verifyPayload(incoming.manifest.items, in: result)
                    guard try header(result).sha256 == incoming.sha256, try readTicket(directory) == ticket else { throw mismatch() }
                    next[key] = Cached(candidate: candidate, members: members, fingerprints: stamps)
                }
                if let checked = next[key] { response.results.append(checked.candidate) }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                response.issues.append(OCRReturnIssue(requestID: session.requestID, message: error.localizedDescription))
            }
        }
        return response
    }

    /// Reopens the fixed route and checks the displayed digest before staging any bytes.
    static func review(requestID: String, expectedDigest: String? = nil, exchangeRoot: URL,
                       mailboxRoot: URL = defaultRoot, now: Date = Date(),
                       chunkObserver: (() throws -> Void)? = nil) throws -> GaoValidatedPackage {
        guard let slot = canonicalSlot(requestID) else { throw mismatch() }
        let snapshot = try GaoOutgoingJournal.returnSnapshot(exchangeRoot: exchangeRoot)
        guard let session = recentSessions(snapshot.sessions, now: now).first(where: { canonicalSlot($0.requestID) == slot }),
              let directory = try mailboxSlot(mailboxRoot, slot, create: false),
              let request = try currentRequest(session, exchangeRoot: exchangeRoot, now: now),
              let ticket = try readTicket(directory), ticket == (try ticketBytes(session, request: request)),
              let result = try directoryChild(directory, resultName, create: false, privateOnly: false) else { throw mismatch() }
        let incoming = try header(result)
        _ = try validate(incoming, request: request, session: session, now: now)
        guard expectedDigest == nil || expectedDigest == incoming.sha256,
              !snapshot.results.contains(where: { $0.requestID == incoming.manifest.requestID }) else { throw mismatch() }
        try chunkObserver?()
        let staged = try GaoActionTransport.receive(package: result, exchangeRoot: exchangeRoot,
                                                    expectedManifestSHA256: incoming.sha256, now: now, chunkObserver: chunkObserver)
        do {
            try chunkObserver?()
            guard try readTicket(directory) == ticket, try header(result).sha256 == incoming.sha256 else { throw mismatch() }
        } catch {
            try? FileManager.default.removeItem(at: staged.stagingURL)
            throw error
        }
        return staged
    }

    private static func recentSessions(_ sessions: [GaoOutgoingSession], now: Date) -> [GaoOutgoingSession] {
        // Compare canonical slot keys so an ambiguous hand-written ledger cannot redirect one request into another.
        let counts = Dictionary(grouping: sessions.compactMap { canonicalSlot($0.requestID) }, by: { $0 })
        return sessions.filter { session in
            guard session.action == action, session.targetBundleID == provider, !session.phase.terminal,
                  let slot = canonicalSlot(session.requestID), counts[slot]?.count == 1,
                  let created = GaoActionContract.date(session.createdAt) else { return false }
            return created <= now && now.timeIntervalSince(created) < GaoActionContract.ttl
        }
    }

    private static func currentRequest(_ session: GaoOutgoingSession, exchangeRoot: URL, now: Date) throws -> GaoActionManifest? {
        do { return try originalRequest(session, exchangeRoot: exchangeRoot, now: now) }
        catch let issue as GaoActionIssue where issue.code == "expired" { return nil }
    }

    private static func originalRequest(_ session: GaoOutgoingSession, exchangeRoot: URL, now: Date) throws -> GaoActionManifest {
        guard session.action == action, session.targetBundleID == provider, let first = session.sources.first else { throw mismatch() }
        let parts = try GaoActionContract.payloadComponents(first.privateRelativePath)
        guard parts.count == 3, parts[0] == "Staging", UUID(uuidString: parts[1]) != nil else { throw mismatch() }
        let exchange = try GaoPrivateIO.directory(exchangeRoot, requirePrivate: true)
        let staging = try GaoPrivateIO.childDirectory(exchange, parts[0], requirePrivate: true)
        let directory = try GaoPrivateIO.childDirectory(staging, parts[1], requirePrivate: true)
        let saved = try header(directory)
        let manifest = saved.manifest
        guard saved.sha256 == session.manifestSHA256, manifest.kind == "request", manifest.action == action,
              manifest.sourceBundleID == GaoActionContract.bundleID, manifest.targetBundleID == provider,
              manifest.requestID == session.requestID, manifest.items == session.sources.map(\.item),
              manifest.references.isEmpty else { throw mismatch() }
        try GaoActionContract.validate(manifest, expectedTargetBundleID: provider, now: now)
        return manifest
    }

    private static func validate(_ incoming: Header, request: GaoActionManifest, session: GaoOutgoingSession, now: Date) throws -> OCRReturnCandidate {
        let m = incoming.manifest
        try GaoActionContract.validate(m, expectedTargetBundleID: GaoActionContract.bundleID, now: now)
        guard m.kind == "result", m.action == action, m.inReplyTo == request.requestID,
              m.sourceBundleID == provider, m.references.isEmpty,
              let status = m.status, ["completed", "partial"].contains(status),
              let expiry = GaoActionContract.date(m.expiresAt), let requestExpiry = GaoActionContract.date(request.expiresAt),
              m.parameters.isEmpty || m.parameters == request.parameters,
              let provenance = m.provenance,
              provenance["requestManifestSHA256"]?.stringValue == session.manifestSHA256,
              provenance["networkUsed"]?.boolValue == false,
              let engine = provenance["engine"]?.stringValue,
              ["Apple Vision VNRecognizeTextRequest", "Windows.Media.Ocr"].contains(engine),
              let sources = provenance["sources"]?.arrayValue, sources.count == session.sources.count,
              let outputs = provenance["outputs"]?.arrayValue, outputs.count == m.items.count, !outputs.isEmpty,
              let failures = provenance["exportFailures"]?.arrayValue, failures.allSatisfy({ $0.stringValue != nil }),
              (status == "completed") == (m.errorCode == nil) else { throw mismatch() }
        let identities = Dictionary(uniqueKeysWithValues: session.sources.map { ($0.item.id, $0) })
        let items = Dictionary(uniqueKeysWithValues: m.items.map { ($0.id, $0) })
        let requested = Set(request.parameters["outputs"]?.arrayValue?.compactMap(\.stringValue) ?? ["text", "json"])
        var uniqueProviders = Set<String>(), seen = Set<String>()
        var links: [String: (provider: String, ids: Set<String>)] = [:]
        var sourceSummaries: [OCRReturnSource] = []
        var completedPages = 0, allPages = 0
        for value in sources {
            guard let row = value.objectValue, let itemID = row["sourceItemID"]?.stringValue,
                  let saved = identities[itemID], saved.item.sha256 == row["sourceSHA256"]?.stringValue,
                  let providerID = row["sourceID"]?.stringValue, UUID(uuidString: providerID) != nil,
                  seen.insert(itemID).inserted, uniqueProviders.insert(providerID.lowercased()).inserted,
                  let ids = row["outputItemIDs"]?.arrayValue, ids.allSatisfy({ $0.stringValue != nil }),
                  Set(ids.compactMap(\.stringValue)).count == ids.count,
                  let pages = row["pages"]?.arrayValue, (1...200).contains(pages.count) else { throw mismatch() }
            let pageSummaries: [OCRPageProvenance] = try pages.enumerated().map { index, value in
                guard let page = value.objectValue, page["pageNumber"]?.numberValue == Double(index + 1),
                      let pageStatus = page["status"]?.stringValue, ["completed", "failed", "cancelled"].contains(pageStatus),
                      let lines = page["lineCount"]?.numberValue, lines >= 0, lines <= 100_000, lines.rounded() == lines,
                      pageStatus == "completed" || lines == 0,
                      let elapsed = page["elapsedSeconds"]?.numberValue, elapsed >= 0, elapsed.isFinite else { throw mismatch() }
                if pageStatus == "completed" { completedPages += 1 }
                return OCRPageProvenance(pageNumber: index + 1, status: pageStatus, confidence: nil,
                                         confidenceSource: nil, failureReason: page["failureReason"]?.stringValue)
            }
            allPages += pages.count
            links[itemID] = (providerID, Set(ids.compactMap(\.stringValue)))
            let reference = saved.binding.originalReference
            let name = reference?.displayName ?? URL(fileURLWithPath: saved.item.relativePath).lastPathComponent
            let originalURL = try reference.map { try GaoActionContract.localFileURL($0.fileURL) }
            sourceSummaries.append(OCRReturnSource(itemID: itemID, sha256: saved.item.sha256,
                                                  displayName: name, originalURL: originalURL, pages: pageSummaries))
        }
        var resultIDs = Set<String>(), sourceIDs: [String: Set<String>] = [:], formats: [String: Set<String>] = [:]
        for value in outputs {
            guard let output = value.objectValue,
                  let itemID = output["sourceItemID"]?.stringValue, let link = links[itemID],
                  identities[itemID]?.item.sha256 == output["sourceSHA256"]?.stringValue,
                  link.provider == output["sourceID"]?.stringValue,
                  let resultID = output["resultItemID"]?.stringValue, let item = items[resultID], link.ids.contains(resultID),
                  resultIDs.insert(resultID).inserted, let format = output["format"]?.stringValue,
                  allowedUTIs[format]?.contains(item.uti) == true, requested.contains(format),
                  formats[itemID, default: []].insert(format).inserted else { throw mismatch() }
            sourceIDs[itemID, default: []].insert(resultID)
        }
        guard resultIDs == Set(items.keys), links.allSatisfy({ sourceIDs[$0.key, default: []] == $0.value.ids }),
              completedPages > 0 else { throw mismatch() }
        if status == "completed" {
            guard completedPages == allPages, failures.isEmpty,
                  links.keys.allSatisfy({ formats[$0, default: []] == requested }) else { throw mismatch() }
        } else if completedPages == allPages && failures.isEmpty {
            throw mismatch()
        }
        return OCRReturnCandidate(requestID: session.requestID, resultID: m.requestID,
                                  manifestSHA256: incoming.sha256, status: status,
                                  expiresAt: min(expiry, requestExpiry), sources: sourceSummaries)
    }

    private static let allowedUTIs: [String: Set<String>] = [
        "text": ["public.utf8-plain-text", "public.plain-text", "text/plain"],
        "markdown": ["net.daringfireball.markdown", "public.markdown", "text/markdown"],
        "json": ["public.json", "application/json"],
        "searchablePDF": ["com.adobe.pdf", "application/pdf"]
    ]

    private static func verifyPayload(_ items: [GaoActionItem], in directory: GaoFixedFD) throws -> ([[String]], [stat]) {
        let payload = try GaoPrivateIO.childDirectory(directory, "payload")
        var members: [[String]] = [], stamps: [stat] = []
        for item in items {
            let path = try GaoActionContract.payloadComponents(item.relativePath)
            let file = try GaoPrivateIO.regular(payload, components: path)
            let before = try file.statValue()
            guard before.st_size == item.byteCount else { throw mismatch() }
            var hasher = SHA256(), buffer = [UInt8](repeating: 0, count: 65_536)
            var count: Int64 = 0
            while true {
                try Task.checkCancellation()
                let read = Darwin.read(file.value, &buffer, buffer.count)
                if read == 0 { break }
                if read < 0 { if errno == EINTR { continue }; throw mismatch() }
                count += Int64(read)
                guard count <= item.byteCount else { throw mismatch() }
                hasher.update(data: Data(buffer.prefix(read)))
            }
            let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
            guard count == item.byteCount, digest == item.sha256,
                  try GaoPrivateIO.unchanged(before, file.statValue()) else { throw mismatch() }
            members.append(path)
            stamps.append(before)
        }
        return (members, stamps)
    }

    private static func matches(_ cached: Cached, in directory: GaoFixedFD) throws -> Bool {
        let payload = try GaoPrivateIO.childDirectory(directory, "payload")
        for (index, path) in cached.members.enumerated() {
            let current = try GaoPrivateIO.regular(payload, components: path).statValue()
            if !GaoPrivateIO.unchanged(cached.fingerprints[index], current) { return false }
        }
        return true
    }

    private static func header(_ root: GaoFixedFD) throws -> Header {
        let data = try GaoPrivateIO.read(GaoPrivateIO.regular(root, components: ["manifest.json"]),
                                         maximum: Int64(GaoActionContract.maximumManifestBytes))
        return Header(manifest: try GaoActionTransport.decodeManifest(data), sha256: FileSafety.digest(data))
    }

    private static func ticketBytes(_ session: GaoOutgoingSession, request: GaoActionManifest) throws -> Data {
        let ticket = Ticket(requestID: session.requestID, action: action, sourceBundleID: GaoActionContract.bundleID,
                            targetBundleID: provider, requestManifestSHA256: session.manifestSHA256,
                            expiresAt: request.expiresAt)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(ticket)
    }

    private static func readTicket(_ directory: GaoFixedFD) throws -> Data? {
        let value = openat(directory.value, ticketName, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        if value < 0, errno == ENOENT { return nil }
        let file = try GaoFixedFD(value)
        guard actualName(file) == ticketName, try file.statValue().st_mode & 0o077 == 0 else { throw mismatch() }
        return try GaoPrivateIO.read(file, maximum: 4096)
    }

    private static func writeTicket(_ bytes: Data, to directory: GaoFixedFD) throws {
        if let previous = try readTicket(directory) {
            guard previous == bytes else { throw mismatch() }
            return
        }
        let name = ".ticket-" + UUID().uuidString
        let staged = try GaoFixedFD(openat(directory.value, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600))
        defer { _ = unlinkat(directory.value, name, 0) }
        try GaoPrivateIO.writeAll(bytes, to: staged.value)
        guard fsync(staged.value) == 0 else { throw mismatch() }
        if renameatx_np(directory.value, name, directory.value, ticketName, UInt32(RENAME_EXCL)) != 0 {
            guard errno == EEXIST, try readTicket(directory) == bytes else { throw mismatch() }
        }
        guard fsync(directory.value) == 0 else { throw mismatch() }
    }

    private static func mailboxSlot(_ root: URL, _ slot: String, create: Bool) throws -> GaoFixedFD? {
        guard canonicalSlot(slot) == slot, let directory = try mailboxDirectory(root, create: create) else { return nil }
        return try directoryChild(directory, slot, create: create, privateOnly: true)
    }

    private static func mailboxDirectory(_ root: URL, create: Bool) throws -> GaoFixedFD? {
        guard root.isFileURL, root.host == nil || root.host == "" || root.host == "localhost",
              root.path.hasPrefix("/"), !root.path.contains("\0"),
              !root.path.split(separator: "/").contains(where: { $0 == "." || $0 == ".." }) else { throw mismatch() }
        let parts = lexical(root).split(separator: "/").map(String.init)
        guard !parts.isEmpty else { throw mismatch() }
        let standardSuffix = parts.count > suffix.count && Array(parts.suffix(suffix.count)) == suffix
        let protectedIndex = standardSuffix ? parts.count - suffix.count : parts.count - 1
        var directory = try GaoFixedFD(Darwin.open("/", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC))
        for (index, part) in parts.enumerated() {
            if index >= protectedIndex {
                guard let child = try directoryChild(directory, part, create: create, privateOnly: index == parts.count - 1) else { return nil }
                directory = child
            } else {
                let fd = openat(directory.value, part, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                if fd < 0, errno == ENOENT { return nil }
                directory = try GaoFixedFD(fd)
            }
        }
        return directory
    }

    private static func directoryChild(_ parent: GaoFixedFD, _ name: String, create: Bool, privateOnly: Bool) throws -> GaoFixedFD? {
        if create, mkdirat(parent.value, name, 0o700) != 0, errno != EEXIST { throw mismatch() }
        let value = openat(parent.value, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        if value < 0, errno == ENOENT { return nil }
        let fd = try GaoFixedFD(value)
        let info = try fd.statValue()
        guard info.st_uid == geteuid(), info.st_mode & (privateOnly ? 0o077 : 0o022) == 0,
              actualName(fd) == name else { throw mismatch() }
        return fd
    }

    private static func actualName(_ fd: GaoFixedFD) -> String? {
        var path = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        let result = path.withUnsafeMutableBufferPointer { buffer in
            fcntl(fd.value, F_GETPATH, UnsafeMutableRawPointer(buffer.baseAddress!))
        }
        guard result == 0, let value = String(validatingUTF8: path) else { return nil }
        return URL(fileURLWithPath: value).lastPathComponent
    }

    private static func canonicalSlot(_ requestID: String) -> String? {
        guard let uuid = UUID(uuidString: requestID),
              uuid.uuidString.lowercased() == requestID.lowercased() else { return nil }
        return uuid.uuidString.lowercased()
    }

    private static func lexical(_ url: URL) -> String {
        let path = url.standardizedFileURL.path
        for alias in ["/tmp", "/var", "/etc"] where path == alias || path.hasPrefix(alias + "/") { return "/private" + path }
        return path
    }

    private static func mismatch() -> GaoActionIssue {
        GaoActionContract.reject("invalidOCRReturn", "OCR 回传路径、票据或结果不匹配。可从搞操作手工导出交接包，再明确审核。")
    }
}
