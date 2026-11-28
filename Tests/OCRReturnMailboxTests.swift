import Foundation
import Darwin

enum OCRReturnMailboxTests {
    @discardableResult static func run(in root: URL) throws -> Int {
        let fm = FileManager.default
        try fm.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let mailbox = root.appendingPathComponent("OcrReturns-v1", isDirectory: true)
        let exchange = root.appendingPathComponent("Exchange", isDirectory: true)
        let now = GaoActionFixtures.clock
        let requestID = UUID(uuidString: "ABCDEF12-1111-2222-3333-444444444444")!
        let sourceURL = root.appendingPathComponent("synthetic.png")
        let input = Data("Synthetic OCR source bytes".utf8)
        try input.write(to: sourceURL)
        let sourceFile = GaoOutgoingFile(url: sourceURL, uti: "public.png")
        let request = try GaoActionWriter.writeRequest(action: "ocr.files",
            items: [sourceFile],
            parameters: ["outputs": .array([.string("text")])], targetBundleID: OCRReturnMailbox.provider,
            exchangeRoot: exchange, now: now, requestID: requestID)
        let journal = try GaoOutgoingJournal(exchangeRoot: exchange)
        let reference = GaoActionReference(id: "original", kind: "file", fileURL: sourceURL.absoluteString, displayName: "合成原件",
            declaredIdentity: GaoDeclaredIdentity(volumeUUID: nil, device: nil, inode: nil, byteCount: nil, modifiedAt: nil))
        let binding = GaoOutgoingSourceBinding(itemID: sourceFile.id, originalReference: reference)
        let session = try journal.registerOutgoing(packageURL: request, expectedTargetBundleID: OCRReturnMailbox.provider, bindings: [binding], now: now)
        let original = try Data(contentsOf: request.appendingPathComponent("manifest.json"))
        let originalManifest = try GaoActionTransport.decodeManifest(original)
        let lowercaseID = session.requestID.lowercased()
        let cache = OCRReturnMailbox.Cache()
        let stages = exchange.appendingPathComponent("Staging", isDirectory: true)
        let initialStages = try fm.contentsOfDirectory(atPath: stages.path).count
        var assertions = 0

        func check(_ message: String, _ verify: () throws -> Bool) throws {
            guard try verify() else { throw FileIssue.message("OCR mailbox: " + message) }
            assertions += 1
        }
        func rejects(_ message: String, _ body: () throws -> Void) throws {
            do { try body() } catch {
                assertions += 1
                return
            }
            throw FileIssue.message("OCR mailbox accepted " + message)
        }
        func scan(_ clock: Date = GaoActionFixtures.clock) throws -> OCRReturnScan {
            try OCRReturnMailbox.scan(exchangeRoot: exchange, mailboxRoot: mailbox, now: clock, cache: cache)
        }
        func publish(_ value: GaoOutgoingSession = session) throws -> URL {
            try OCRReturnMailbox.publishTicket(for: value, packageURL: request, exchangeRoot: exchange, mailboxRoot: mailbox, now: now)
        }

        try check("scan before a ticket must not create the mailbox") { try scan() == OCRReturnScan() && !fm.fileExists(atPath: mailbox.path) }
        var forged = session
        forged.manifestSHA256 = String(repeating: "0", count: 64)
        try rejects("a ticket without its persisted outgoing session") { _ = try publish(forged) }
        let ticketURL = try publish()
        let ticket = try Data(contentsOf: ticketURL)
        let ticketObject = try JSONSerialization.jsonObject(with: ticket) as? [String: Any]
        try check("ticket slot lowercases only the physical path") {
            ticketURL.deletingLastPathComponent().lastPathComponent == lowercaseID && session.requestID == requestID.uuidString &&
            ticketObject?["requestID"] as? String == session.requestID
        }
        try check("ticket exact schema, original digest and expiry") {
            guard let ticketObject else { return false }
            return Set(ticketObject.keys) == Set(["schemaVersion", "requestID", "action", "sourceBundleID", "targetBundleID", "requestManifestSHA256", "expiresAt"]) &&
                ticketObject["schemaVersion"] as? Int == 1 && ticketObject["action"] as? String == "ocr.files" &&
                ticketObject["sourceBundleID"] as? String == GaoActionContract.bundleID &&
                ticketObject["targetBundleID"] as? String == OCRReturnMailbox.provider &&
                ticketObject["requestManifestSHA256"] as? String == FileSafety.digest(original) &&
                ticketObject["expiresAt"] as? String == originalManifest.expiresAt && !ticket.starts(with: [0xef, 0xbb, 0xbf])
        }
        try check("stable idempotent publication and private modes") {
            let republished = try publish()
            let mode = try fm.attributesOfItem(atPath: republished.path)[.posixPermissions] as? NSNumber
            let mailboxMode = try fm.attributesOfItem(atPath: mailbox.path)[.posixPermissions] as? NSNumber
            return try Data(contentsOf: republished) == ticket && mode?.intValue == 0o600 && mailboxMode?.intValue == 0o700
        }
        try check("unreturned ticket is pending") { try scan().pending }
        let resultURL = ticketURL.deletingLastPathComponent().appendingPathComponent("result.gaoaction", isDirectory: true)
        let item = originalManifest.items[0]
        let output = Data("OCR synthetic output".utf8)
        let providerID = "BCDEF123-1111-2222-3333-444444444444"
        let resultID = "CDEF1234-1111-2222-3333-444444444444"
        let mapping: [String: GaoJSONValue] = ["sourceID": .string(providerID), "sourceItemID": .string(item.id), "sourceSHA256": .string(item.sha256)]
        let pages: [GaoJSONValue] = [.object(["pageNumber": .number(1), "status": .string("completed"), "lineCount": .number(1), "elapsedSeconds": .number(0.5)])]
        let resultHash = FileSafety.digest(output)
        let entry = GaoActionItem(id: "text-result", relativePath: "output.txt", uti: "public.utf8-plain-text", byteCount: Int64(output.count), sha256: resultHash)
        let result = GaoActionManifest(kind: "result", requestID: resultID, sourceBundleID: OCRReturnMailbox.provider,
            targetBundleID: GaoActionContract.bundleID, action: "ocr.files", createdAt: GaoActionContract.timestamp(now),
            expiresAt: GaoActionContract.timestamp(now.addingTimeInterval(120)), nonce: Data(repeating: 9, count: 32).base64EncodedString(),
            items: [entry], references: [], parameters: [:], inReplyTo: session.requestID, status: "completed", errorCode: nil,
            provenance: ["requestManifestSHA256": .string(session.manifestSHA256), "engine": .string("Apple Vision VNRecognizeTextRequest"),
                "networkUsed": .bool(false), "exportFailures": .array([]),
                "sources": .array([.object(mapping.merging(["outputItemIDs": .array([.string(entry.id)]), "pages": .array(pages)]) { current, _ in current })]),
                "outputs": .array([.object(mapping.merging(["resultItemID": .string(entry.id), "format": .string("text")]) { current, _ in current })])])

        func write(_ manifest: GaoActionManifest, to location: URL) throws {
            try fm.createDirectory(at: location, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try GaoActionFixtures.write(manifest: manifest, payload: ["output.txt": output], to: location)
        }
        let foreign = root.appendingPathComponent("outside.gaoaction", isDirectory: true)
        try write(result, to: foreign)
        try fm.createSymbolicLink(at: resultURL, withDestinationURL: foreign)
        try check("a symbolic result slot cannot be read") { try scan().results.isEmpty && !scan().issues.isEmpty }
        try fm.removeItem(at: resultURL)

        var wrongBinding = result
        wrongBinding.provenance?["requestManifestSHA256"] = .string(String(repeating: "0", count: 64))
        try write(wrongBinding, to: resultURL)
        try check("digest mismatch is rejected without staging") {
            let returned = try scan()
            return try returned.results.isEmpty && !returned.pending && !returned.issues.isEmpty &&
                fm.contentsOfDirectory(atPath: stages.path).count == initialStages
        }
        let manual = try GaoActionTransport.receive(packageURL: resultURL, exchangeRoot: exchange, now: now)
        try rejects("wrong digest on a manual re-export") { _ = try journal.receiveResult(manual, now: now) }
        try fm.removeItem(at: manual.stagingURL)
        try fm.removeItem(at: resultURL)
        try write(result, to: resultURL)
        guard let displayed = try scan().results.first else { throw FileIssue.message("Matching OCR result not visible") }
        try check("result is linked before explicit review") {
            displayed.requestID == session.requestID && displayed.resultID == resultID &&
                displayed.sources.first?.sha256 == item.sha256 && displayed.sources.first?.pages.first?.pageNumber == 1 &&
                displayed.sources.first?.originalURL?.path == sourceURL.path && displayed.sources.first?.displayName == "合成原件"
        }
        try check("ready scan stays read-only and returns one row") {
            try scan().results == [displayed] && fm.contentsOfDirectory(atPath: stages.path).count == initialStages
        }
        try check("only the exact result path is a review route") {
            OCRReturnMailbox.requestID(for: resultURL, mailboxRoot: mailbox) == lowercaseID &&
                OCRReturnMailbox.isMailboxURL(resultURL.appendingPathComponent("payload"), mailboxRoot: mailbox) &&
                OCRReturnMailbox.requestID(for: resultURL.appendingPathComponent("payload"), mailboxRoot: mailbox) == nil
        }
        try rejects("an unreviewed digest") {
            _ = try OCRReturnMailbox.review(requestID: lowercaseID, expectedDigest: String(repeating: "0", count: 64), exchangeRoot: exchange, mailboxRoot: mailbox, now: now)
        }
        let outputPath = resultURL.appendingPathComponent("payload/output.txt")
        try Data(repeating: 0, count: output.count).write(to: outputPath, options: .atomic)
        try check("a changed attachment invalidates the cached approval row") { try scan().results.isEmpty }
        try output.write(to: outputPath, options: .atomic)
        let staged = try OCRReturnMailbox.review(requestID: lowercaseID, expectedDigest: displayed.manifestSHA256,
                                                 exchangeRoot: exchange, mailboxRoot: mailbox, now: now)
        try check("explicit review yields checked bytes and does not change the original") {
            try staged.stagedItems.count == 1 && Data(contentsOf: staged.stagedItems[0].url) == output && Data(contentsOf: sourceURL) == input
        }
        try check("expiry hides the result without removing received data or the transport files") {
            try scan(now.addingTimeInterval(120)) == OCRReturnScan() &&
                Data(contentsOf: staged.stagedItems[0].url) == output && Data(contentsOf: outputPath) == output &&
                Data(contentsOf: sourceURL) == input
        }
        _ = try journal.receiveResult(staged, now: now)
        try check("already handled result is not queued again") { try scan().results.isEmpty }
        try check("request bytes were preserved") { try Data(contentsOf: request.appendingPathComponent("manifest.json")) == original }

        var fractional = originalManifest
        fractional.requestID = UUID().uuidString
        fractional.createdAt = "2026-10-12T12:00:00.000Z"
        fractional.expiresAt = "2026-10-12T12:02:00.000Z"
        let nextPath = exchange.appendingPathComponent("Outgoing/" + UUID().uuidString + ".gaoaction", isDirectory: true)
        try GaoActionFixtures.write(manifest: fractional, payload: [item.relativePath: input], to: nextPath)
        let next = try journal.registerOutgoing(packageURL: nextPath, expectedTargetBundleID: OCRReturnMailbox.provider, now: now)
        let fractionalTicket = try OCRReturnMailbox.publishTicket(for: next, packageURL: nextPath, exchangeRoot: exchange, mailboxRoot: mailbox, now: now)
        try check("fractional expiry is copied byte-for-byte") {
            let adopted = try JSONSerialization.jsonObject(with: Data(contentsOf: fractionalTicket)) as? [String: Any]
            return adopted?["expiresAt"] as? String == fractional.expiresAt
        }
        var legacy = result
        legacy.requestID = UUID().uuidString
        legacy.inReplyTo = next.requestID
        legacy.provenance?.removeValue(forKey: "requestManifestSHA256")
        let manuallyExported = root.appendingPathComponent("legacy.gaoaction", isDirectory: true)
        try write(legacy, to: manuallyExported)
        let legacyStage = try GaoActionTransport.receive(packageURL: manuallyExported, exchangeRoot: exchange, now: now)
        try check("legacy manual return does not require the new ticket digest") {
            try !journal.receiveResult(legacyStage, now: now).isDuplicate
        }
        print("OCR mailbox: PASS (\(assertions) isolated assertions)")
        return assertions
    }
}
