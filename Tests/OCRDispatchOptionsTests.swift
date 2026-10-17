import AppKit
import Foundation
import ImageIO

/// Calls the real production preparation, journal, validation and editor adapter
/// with generated data. Only user confirmation is supplied without a UI.
@MainActor enum OCRDispatchOptionsTests {
    @discardableResult static func run(in directory: URL) throws -> Int {
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var checks = 0
        func check(_ condition: @autoclosure () throws -> Bool, _ name: String) throws {
            guard try condition() else { throw GaoActionContract.reject("ocrDispatchTest", name) }; checks += 1
        }
        func rejects(_ name: String, _ block: () throws -> Void) throws {
            do { try block() } catch { checks += 1; return }
            throw GaoActionContract.reject("ocrDispatchTest", "Expected rejection: " + name)
        }
        try check(NSApp == nil, "No application before option/dispatcher checks")
        let now = Date(timeIntervalSince1970: 1_792_020_000)
        let store = WorkspaceStore(), registry = CurrentDocumentHandoffRegistry()
        let first = directory.appendingPathComponent("第一输入.png"), second = directory.appendingPathComponent("第二输入.png")
        let firstBytes = try imageData(red: 0.1), secondBytes = try imageData(red: 0.8)
        try firstBytes.write(to: first); try secondBytes.write(to: second)
        func prepare(_ files: [URL], _ formats: [String]) throws -> PreparedOCRHandoff {
            try OCRHandoffDispatcher.prepare(files: files, store: store, registry: registry,
                outputs: formats, chooseVersion: { _ in .diskOriginal }, now: now)
        }
        let standard = try OCRHandoffDispatcher.prepare(files: [first], store: store, registry: registry, chooseVersion: { _ in .diskOriginal }, now: now)
        try check(try manifest(standard.packageURL).parameters["outputs"]?.arrayValue?.compactMap(\.stringValue) == ["text", "searchablePDF"], "Default text+PDF remains compatible")
        for format in ["text", "markdown", "json", "searchablePDF"] {
            let request = try prepare([first], [format])
            try check(try manifest(request.packageURL).parameters["outputs"]?.arrayValue?.compactMap(\.stringValue) == [format] && request.session.sources.count == 1, "Explicit output option is durably prepared: " + format)
        }
        let allFormats = ["text", "markdown", "json", "searchablePDF"]
        let mixed = try prepare([first], allFormats)
        try check(try manifest(mixed.packageURL).parameters["outputs"]?.arrayValue?.compactMap(\.stringValue) == allFormats, "Output order remains explicit")
        for formats in [[], ["text", "text"], ["json", "unknown"], ["TEXT"]] {
            try rejects("Empty, repeated or unsupported output options") { _ = try prepare([first], formats) }
        }
        let missing = directory.appendingPathComponent("must-not-be-read.pdf")
        try rejects("Four outputs cap inputs at 64 before any source read") { _ = try prepare(Array(repeating: missing, count: 65), allFormats) }
        try rejects("Three outputs cap inputs at 85 before any source read") { _ = try prepare(Array(repeating: missing, count: 86), ["text", "json", "searchablePDF"]) }
        try rejects("One output still caps inputs at 128") { _ = try prepare(Array(repeating: missing, count: 129), ["json"]) }
        let sixtyFour = try prepare(Array(repeating: first, count: 64), allFormats)
        try check(sixtyFour.session.sources.count == 64 && Set(sixtyFour.session.sources.map { $0.item.id }).count == 64, "64 inputs × 4 outputs reaches 256-result boundary with distinct item IDs")
        let oneTwentyEight = try prepare(Array(repeating: first, count: 128), ["json"])
        try check(oneTwentyEight.session.sources.count == 128, "128-input single-format boundary remains available")
        try check(try Data(contentsOf: first) == firstBytes && Data(contentsOf: second) == secondBytes, "Option preparation never changes originals")

        store.newText(.markdown, text: "# Existing unsaved draft\n中文与附件引用保持原样\n")
        let previous = store.active!, previousText = previous.text
        let approval = GaoHandoffInteraction(confirm: { _ in true }, selectReference: { _ in nil }, offerResult: { _, _ in })
        let valid = try prepare([first, second], ["text", "json"])
        let validResult = try result(for: valid, inputURLs: [first, second], in: directory.appendingPathComponent("ValidResult"), now: now)
        let received = try GaoHandoffService.receive(url: validResult, store: store, interaction: approval, now: now)
        let receivedTabs = store.tabs.filter { received.openedTabIDs.contains($0.id) }
        let jsonTabs = receivedTabs.filter { $0.incoming?.originalName.hasSuffix(".json") == true }
        try check(received.status == "completed" && receivedTabs.count == 4 && jsonTabs.count == 2,
            "Actual result dispatcher opens text+JSON for both inputs (status=\(received.status), tabs=\(receivedTabs.count), JSON=\(jsonTabs.count), messages=\(received.messages))")
        try check(receivedTabs.allSatisfy { $0.url == nil && $0.kind == .text && $0.dirty && $0.incoming?.type == "ocrText" }, "All text/JSON outputs enter distinct unsaved tabs")
        for source in valid.session.sources {
            guard let tab = jsonTabs.first(where: { $0.incoming?.ocrProvenance?.sourceItemID == source.item.id }),
                  let object = try JSONSerialization.jsonObject(with: Data(tab.text.utf8)) as? [String: Any],
                  let bodySource = (object["sources"] as? [[String: Any]])?.first else { throw GaoActionContract.reject("ocrDispatchTest", "JSON tab/source mapping missing") }
            try check(bodySource["sha256"] as? String == source.item.sha256 && tab.incoming?.ocrProvenance?.sourceSHA256 == source.item.sha256, "JSON body and incoming metadata identify the correct original input")
            try check(tab.incoming?.sourceDisplayName == source.binding.originalReference?.displayName, "User-facing original source filename survives routing")
        }
        try check(previous.dirty && previous.text == previousText && store.tabs.contains { $0 === previous }, "Receiving JSON preserves old unsaved document")
        let restarted = WorkspaceStore()
        try check(jsonTabs.allSatisfy { tab in restarted.tabs.contains { $0.id == tab.id && $0.text == tab.text && $0.dirty && $0.incoming?.ocrProvenance == tab.incoming?.ocrProvenance } }, "Unsaved JSON and associated source metadata survive a cold store reload")

        for corruption in [JSONCorruption.invalidSyntax, .anotherSource, .wrongPage] {
            let bad = try prepare([first, second], ["text", "json"])
            let badResult = try result(for: bad, inputURLs: [first, second], in: directory.appendingPathComponent("Bad-" + corruption.rawValue), now: now, corruption: corruption)
            let outcome = try GaoHandoffService.receive(url: badResult, store: store, interaction: approval, now: now)
            let tabs = store.tabs.filter { outcome.openedTabIDs.contains($0.id) }
            try check(outcome.status == "partial" && tabs.count == 3 && !outcome.messages.isEmpty, "Bad JSON is rejected while the other three outputs remain: " + corruption.rawValue)
            try check(tabs.filter { $0.incoming?.originalName.hasSuffix(".json") == true }.count == 1 && tabs.filter { $0.incoming?.ocrProvenance?.sourceItemID == bad.session.sources[0].item.id }.count == 1, "No mismatched JSON is assigned to its claimed input: " + corruption.rawValue)
            try check(previous.text == previousText && previous.dirty && (try Data(contentsOf: first)) == firstBytes && (try Data(contentsOf: second)) == secondBytes, "Partial JSON failure preserves both original inputs and old draft")
        }
        let declined = try prepare([first, second], ["text", "json"])
        let declinedResult = try result(for: declined, inputURLs: [first, second], in: directory.appendingPathComponent("Declined"), now: now)
        let tabIDs = store.tabs.map(\.id)
        let refusal = GaoHandoffInteraction(confirm: { _ in false }, selectReference: { _ in nil }, offerResult: { _, _ in })
        let cancelled = try GaoHandoffService.receive(url: declinedResult, store: store, interaction: refusal, now: now)
        try check(cancelled.status == "cancelled" && cancelled.openedTabIDs.isEmpty && store.tabs.map(\.id) == tabIDs, "Declining the actual JSON/text result confirmation creates no tabs")
        let record = try GaoOutgoingJournal(exchangeRoot: GaoHandoffService.exchangeRoot).lookupResult(cancelled.requestID)
        try check(record?.phase == .cancelled && record?.executionStarted == false, "User refusal is durable before processing begins")

        let legacy: [String: Any] = ["requestID": UUID().uuidString, "itemID": "legacy", "sourceBundleID": "com.gaoseries.GaoJieTu", "type": "ocrText", "receivedAt": GaoActionContract.timestamp(now), "contentSHA256": FileSafety.digest(firstBytes), "originalName": "old.json", "notes": [], "ocrProvenance": ["sourceItemID": "legacy-input", "sourceSHA256": FileSafety.digest(firstBytes), "languages": [], "pages": [["pageNumber": 1, "status": "completed"]]]]
        let decoded = try JSONDecoder().decode(IncomingDocument.self, from: JSONSerialization.data(withJSONObject: legacy))
        try check(decoded.inboundAction == nil && decoded.manifestSHA256 == nil && decoded.receivedCopyURL == nil && decoded.sourceDisplayName == nil, "V1.06 IncomingDocument decodes with new optional fields absent")
        try check(decoded.ocrProvenance?.pages.first?.failureReason == nil && decoded.ocrProvenance?.pages.first?.status == "completed", "Legacy OCR page metadata remains compatible without invented failure reasons")
        try check(NSApp == nil, "No application after all option and production dispatcher checks")
        print("OCR output options/JSON dispatcher: \(checks) checks passed (format limits, two-input JSON routing, malformed/cross-source/page rejection with partial acceptance, confirmation cancellation, legacy recovery; no UI)")
        return checks
    }

    private enum JSONCorruption: String { case invalidSyntax, anotherSource, wrongPage }
    private static func result(for prepared: PreparedOCRHandoff, inputURLs: [URL], in directory: URL, now: Date, corruption: JSONCorruption? = nil) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let request = try manifest(prepared.packageURL), providerIDs = request.items.map { _ in UUID().uuidString }
        var outputs: [GaoJSONValue] = [], sources: [GaoJSONValue] = [], files: [GaoOutgoingFile] = []
        for (index, source) in request.items.enumerated() {
            var sourceOutputs: [GaoJSONValue] = []
            for format in ["text", "json"] {
                let url = directory.appendingPathComponent("result-\(index)." + (format == "text" ? "txt" : "json"))
                let bytes: Data
                if format == "text" { bytes = Data("OCR INPUT \(index + 1) TEXT\n".utf8) }
                else if index == 0 && corruption == .invalidSyntax { bytes = Data("not JSON and must not be accepted".utf8) }
                else {
                    let bodyIndex = index == 0 && corruption == .anotherSource ? 1 : index
                    let bodySource = request.items[bodyIndex]
                    let object: [String: Any] = ["schemaVersion": 1, "engine": "Apple Vision VNRecognizeTextRequest", "engineRevision": 3,
                        "sources": [["id": providerIDs[bodyIndex], "sha256": bodySource.sha256, "byteCount": bodySource.byteCount, "pageCount": 1, "isPDF": false]],
                        "pages": [["sourceID": providerIDs[bodyIndex], "originalSHA256": bodySource.sha256, "pageNumber": index == 0 && corruption == .wrongPage ? 2 : 1, "status": "completed", "lines": [["text": "OCR INPUT \(bodyIndex + 1) TEXT"]]]]]
                    bytes = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .prettyPrinted])
                }
                try bytes.write(to: url)
                let file = GaoOutgoingFile(url: url, uti: format == "text" ? "public.utf8-plain-text" : "public.json")
                files.append(file); sourceOutputs.append(.string(file.id))
                outputs.append(.object(["sourceID": .string(providerIDs[index]), "sourceItemID": .string(source.id), "sourceSHA256": .string(source.sha256), "resultItemID": .string(file.id), "format": .string(format)]))
            }
            sources.append(.object(["sourceID": .string(providerIDs[index]), "sourceItemID": .string(source.id), "sourceSHA256": .string(source.sha256), "outputItemIDs": .array(sourceOutputs), "pages": .array([.object(["pageNumber": .number(1), "status": .string("completed")])])]))
        }
        let result = try GaoActionWriter.writeResult(inReplyTo: request, status: "completed", items: files,
            provenance: ["engine": .string("Apple Vision VNRecognizeTextRequest"), "engineRevision": .number(3), "outputs": .array(outputs), "sources": .array(sources)],
            exchangeRoot: directory.appendingPathComponent("Exchange"), now: now)
        var wire = try manifest(result); wire.sourceBundleID = request.targetBundleID
        try JSONEncoder().encode(wire).write(to: result.appendingPathComponent("manifest.json"))
        return result
    }
    private static func manifest(_ package: URL) throws -> GaoActionManifest {
        try JSONDecoder().decode(GaoActionManifest.self, from: Data(contentsOf: package.appendingPathComponent("manifest.json")))
    }
    private static func imageData(red: CGFloat) throws -> Data {
        guard let context = CGContext(data: nil, width: 20, height: 12, bitsPerComponent: 8, bytesPerRow: 80,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw GaoActionContract.reject("ocrDispatchTest", "Image fixture allocation failed") }
        context.setFillColor(CGColor(red: red, green: 0.3, blue: 0.6, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 20, height: 12))
        let data = NSMutableData()
        guard let writer = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil), let image = context.makeImage() else { throw GaoActionContract.reject("ocrDispatchTest", "Image fixture writer failed") }
        CGImageDestinationAddImage(writer, image, nil)
        guard CGImageDestinationFinalize(writer) else { throw GaoActionContract.reject("ocrDispatchTest", "Image fixture finalize failed") }
        return data as Data
    }
}
