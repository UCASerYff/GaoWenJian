import Foundation

/// The sender's ticket and the provider's directory publication share one isolated root.
enum OCRReturnCrossImplementationTests {
    static func run(in root: URL) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        let mailbox = root.appendingPathComponent("OcrReturns-v1", isDirectory: true)
        let sender = root.appendingPathComponent("Sender", isDirectory: true)
        let provider = root.appendingPathComponent("Provider", isDirectory: true)
        let original = root.appendingPathComponent("isolated.png")
        let inputData = Data("Cross-implementation input bytes".utf8)
        try inputData.write(to: original)
        let now = GaoActionFixtures.clock
        let input = GaoOutgoingFile(url: original, uti: "public.png")
        guard let id = UUID(uuidString: "ABCD4321-2233-4455-8866-AABBCCDDEEFF") else {
            throw FileIssue.message("Invalid OCR transport fixture identifier")
        }
        let requestURL = try GaoActionWriter.writeRequest(action: "ocr.files", items: [input],
            parameters: ["outputs": .array([.string("text")])], targetBundleID: OCRReturnMailbox.provider,
            exchangeRoot: sender, now: now, requestID: id)
        let senderJournal = try GaoOutgoingJournal(exchangeRoot: sender)
        let session = try senderJournal.registerOutgoing(packageURL: requestURL,
            expectedTargetBundleID: OCRReturnMailbox.provider, now: now)
        let ticket = try OCRReturnMailbox.publishTicket(for: session, packageURL: requestURL,
            exchangeRoot: sender, mailboxRoot: mailbox, now: now)
        let pending = try OCRReturnMailbox.scan(exchangeRoot: sender, mailboxRoot: mailbox, now: now)
        guard pending.pending, pending.results.isEmpty,
              ticket.deletingLastPathComponent().lastPathComponent == id.uuidString.lowercased() else {
            throw FileIssue.message("The request ticket did not enter the isolated pending queue")
        }

        let request = try ScreenshotGaoActionTransport.receive(packageURL: requestURL, exchangeRoot: provider, now: now)
        guard let binding = ScreenshotOCRReturnBinding(request), let source = request.manifest.items.first,
              binding.requestID == id.uuidString, binding.requestManifestSHA256 == session.manifestSHA256,
              ScreenshotOCRReturn.isReady(binding, root: mailbox, now: now) else {
            throw FileIssue.message("The provider did not accept the actual sender ticket and original envelope")
        }
        let text = root.appendingPathComponent("recognized.txt")
        let textData = Data("Cross-implementation OCR result\n".utf8)
        try textData.write(to: text)
        let outputID = "cross-text"
        let origin: [String: ScreenshotGaoJSONValue] = ["sourceID": .string(UUID().uuidString),
            "sourceItemID": .string(source.id), "sourceSHA256": .string(source.sha256)]
        var sourceMap = origin, outputMap = origin
        sourceMap["pages"] = .array([.object(["pageNumber": .number(1), "status": .string("completed"),
            "lineCount": .number(1), "elapsedSeconds": .number(0.1)])])
        sourceMap["outputItemIDs"] = .array([.string(outputID)])
        outputMap["resultItemID"] = .string(outputID)
        outputMap["format"] = .string("text")
        let resultURL = try ScreenshotGaoActionWriter.writeResult(inReplyTo: request.manifest, status: "completed",
            items: [.init(url: text, uti: "public.utf8-plain-text", id: outputID)],
            provenance: ["engine": .string("Apple Vision VNRecognizeTextRequest"), "networkUsed": .bool(false),
                "requestManifestSHA256": .string(binding.requestManifestSHA256), "exportFailures": .array([]),
                "sources": .array([.object(sourceMap)]), "outputs": .array([.object(outputMap)])],
            exchangeRoot: provider, now: now)
        let digest = try ScreenshotFileSafety.digest(Data(contentsOf: resultURL.appendingPathComponent("manifest.json")))
        let providerJournal = try ScreenshotGaoProcessedRequestStore(root: provider)
        _ = try providerJournal.receive(request, now: now)
        _ = try providerJournal.transition(requestID: binding.requestID, to: .approved, now: now)
        _ = try providerJournal.transition(requestID: binding.requestID, to: .executing, now: now)
        let finished = try providerJournal.transition(requestID: binding.requestID, to: .completed,
            resultPackageName: resultURL.lastPathComponent, now: now, resultManifestSHA256: digest)
        guard ScreenshotOCRReturn.publish(finished, resultURL: resultURL, root: mailbox, clock: { now }) == .published else {
            throw FileIssue.message("The provider did not publish the verified result to the sender's mailbox")
        }

        let scan = try OCRReturnMailbox.scan(exchangeRoot: sender, mailboxRoot: mailbox, now: now)
        guard !scan.pending, scan.issues.isEmpty, scan.results.count == 1,
              let candidate = scan.results.first, candidate.manifestSHA256 == digest,
              candidate.requestID == binding.requestID, candidate.sources.first?.pages.map(\.pageNumber) == [1],
              candidate.sources.first?.sha256 == FileSafety.digest(inputData) else {
            throw FileIssue.message("The provider's result did not enter the sender's validated review queue")
        }
        let reviewed = try OCRReturnMailbox.review(requestID: candidate.requestID, expectedDigest: digest,
                                                  exchangeRoot: sender, mailboxRoot: mailbox, now: now)
        guard let staged = reviewed.stagedItems.first, try Data(contentsOf: staged.url) == textData,
              try Data(contentsOf: original) == inputData else {
            throw FileIssue.message("Explicit review did not stage the output with the original left intact")
        }
        print("PASS: real sender ticket, provider ledger/publisher and receiver review on one isolated OCR mailbox")
    }
}
