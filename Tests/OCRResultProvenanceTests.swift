import Foundation

enum OCRResultProvenanceTests {
    static func run() throws {
        let baseline = try fixture()
        let first = try normalize(baseline, result: "result-pdf", source: "input-1", sha: firstSHA)
        try check(first.sourceItemID == "input-1" && first.sourceSHA256 == firstSHA, "Output binding identifies original request item")
        try check(first.engine == "Apple Vision VNRecognizeTextRequest" && first.engineVersion == "3", "Actual numeric engineRevision normalizes to engine version")
        try check(first.pages.map(\.pageNumber) == [1, 2] && first.pages.map(\.status) == ["completed", "failed"], "Real sources.pages statuses are preserved")
        try check(first.languages.isEmpty && first.coordinateSystem == nil && first.confidenceSource == nil && first.pages.allSatisfy { $0.confidence == nil && $0.confidenceSource == nil }, "Absent language, coordinates and confidence are never invented")
        let second = try normalize(baseline, result: "result-md", source: "input-2", sha: secondSHA)
        try check(second.pages.count == 1 && second.pages[0].status == "cancelled", "Each output uses its own source pages")
        let roundtrip = try JSONDecoder().decode(GaoActionManifest.self, from: JSONEncoder().encode(baseline))
        try check(try normalize(roundtrip, result: "result-pdf", source: "input-1", sha: firstSHA) == first, "Wire manifest JSON round trips the actual producer shape")

        var missingPages = baseline
        mutateSource(&missingPages, 0) { $0.removeValue(forKey: "pages") }
        missingPages.provenance?["pages"] = .array([.object(["pageNumber": .number(1), "status": .string("completed")])])
        try check(try normalize(missingPages, result: "result-pdf", source: "input-1", sha: firstSHA).pages.isEmpty, "Missing source pages remain unverified even if unrelated top-level pages exist")
        var metadata = baseline
        mutateSource(&metadata, 0) {
            $0["languages"] = .array([.string("zh-Hans")])
            $0["coordinateSystem"] = .string("pdf-points-bottom-left")
            $0["confidenceSource"] = .string("provider-declared")
            $0["pages"] = .array([.object(["pageNumber": .number(1), "status": .string("partial"), "confidence": .number(0.75), "confidenceSource": .string("provider-declared")])])
        }
        let actualMetadata = try normalize(metadata, result: "result-pdf", source: "input-1", sha: firstSHA)
        try check(actualMetadata.languages == ["zh-Hans"] && actualMetadata.pages[0].confidence == 0.75 && actualMetadata.coordinateSystem == "pdf-points-bottom-left", "Only explicitly supplied optional metadata is retained")

        try rejects("Journal source item mismatch") { _ = try normalize(baseline, result: "result-pdf", source: "input-2", sha: firstSHA) }
        try rejects("Journal source digest mismatch") { _ = try normalize(baseline, result: "result-pdf", source: "input-1", sha: secondSHA) }
        try rejects("Unattached result ID") { _ = try normalize(baseline, result: "absent", source: "input-1", sha: firstSHA) }
        var duplicateOutput = baseline
        duplicateOutput.provenance?["outputs"] = .array(baseline.provenance!["outputs"]!.arrayValue! + [baseline.provenance!["outputs"]!.arrayValue![0]])
        try rejects("Duplicate output records") { _ = try normalize(duplicateOutput, result: "result-pdf", source: "input-1", sha: firstSHA) }
        var duplicateSource = baseline
        duplicateSource.provenance?["sources"] = .array(baseline.provenance!["sources"]!.arrayValue! + [baseline.provenance!["sources"]!.arrayValue![0]])
        try rejects("Duplicate source records") { _ = try normalize(duplicateSource, result: "result-pdf", source: "input-1", sha: firstSHA) }
        var repeatedProviderSourceID = baseline
        mutateSource(&repeatedProviderSourceID, 1) { $0["sourceID"] = .string("11111111-1111-4111-8111-111111111111") }
        try rejects("Duplicate provider source IDs") { _ = try normalize(repeatedProviderSourceID, result: "result-pdf", source: "input-1", sha: firstSHA) }
        var repeatedRequestItem = baseline
        mutateSource(&repeatedRequestItem, 1) { $0["sourceItemID"] = .string("input-1") }
        try rejects("Duplicate request source IDs") { _ = try normalize(repeatedRequestItem, result: "result-pdf", source: "input-1", sha: firstSHA) }
        for (key, value) in [("sourceSHA256", GaoJSONValue.string(secondSHA)), ("sourceID", .string("wrong-source-id")), ("sourceItemID", .string("input-2"))] {
            var wrong = baseline
            mutateOutput(&wrong, 1) { $0[key] = value }
            try rejects("Wrong output " + key) { _ = try normalize(wrong, result: "result-pdf", source: "input-1", sha: firstSHA) }
        }
        var wrongDeclaredOutput = baseline
        mutateSource(&wrongDeclaredOutput, 0) { $0["outputItemIDs"] = .array([.string("result-txt"), .string("result-md")]) }
        try rejects("Output list binds another source") { _ = try normalize(wrongDeclaredOutput, result: "result-pdf", source: "input-1", sha: firstSHA) }
        var repeatedDeclaredOutput = baseline
        mutateSource(&repeatedDeclaredOutput, 0) { $0["outputItemIDs"] = .array([.string("result-txt"), .string("result-txt")]) }
        try rejects("Duplicate declared output IDs") { _ = try normalize(repeatedDeclaredOutput, result: "result-pdf", source: "input-1", sha: firstSHA) }
        var extraItem = baseline
        extraItem.items.append(.init(id: "unbound", relativePath: "payload/unbound.txt", uti: "public.utf8-plain-text", byteCount: 1, sha256: firstSHA))
        try rejects("Unbound attachment") { _ = try normalize(extraItem, result: "result-pdf", source: "input-1", sha: firstSHA) }
        var duplicateItem = baseline
        duplicateItem.items.append(duplicateItem.items[0])
        try rejects("Duplicate manifest attachment ID") { _ = try normalize(duplicateItem, result: "result-pdf", source: "input-1", sha: firstSHA) }
        var missingRecords = baseline
        missingRecords.provenance?.removeValue(forKey: "sources")
        try rejects("Incomplete structured records cannot fall back") { _ = try normalize(missingRecords, result: "result-pdf", source: "input-1", sha: firstSHA) }
        for invalid in [GaoJSONValue.bool(true), .number(3.5), .number(-1), .string("3")] {
            var wrong = baseline; wrong.provenance?["engineRevision"] = invalid
            try rejects("Invalid engine revision") { _ = try normalize(wrong, result: "result-pdf", source: "input-1", sha: firstSHA) }
        }
        var conflictingVersion = baseline; conflictingVersion.provenance?["engineVersion"] = .string("4")
        try rejects("Conflicting engine version") { _ = try normalize(conflictingVersion, result: "result-pdf", source: "input-1", sha: firstSHA) }
        for pages in [GaoJSONValue.array([.object(["pageNumber": .number(1), "status": .string("completed")]), .object(["pageNumber": .number(1), "status": .string("completed")])]),
                      .array([.object(["pageNumber": .bool(true), "status": .string("completed")])]),
                      .array([.object(["pageNumber": .number(1), "status": .string("made-up")])]),
                      .array([.object(["pageNumber": .number(1), "confidence": .number(2)])])] {
            var wrong = baseline; mutateSource(&wrong, 0) { $0["pages"] = pages }
            try rejects("Invalid pages") { _ = try normalize(wrong, result: "result-pdf", source: "input-1", sha: firstSHA) }
        }
        var wrongKind = baseline; wrongKind.kind = "request"
        try rejects("Request is not an OCR result") { _ = try normalize(wrongKind, result: "result-pdf", source: "input-1", sha: firstSHA) }
        var wrongAction = baseline; wrongAction.action = "documents.open"
        try rejects("Another action is not an OCR result") { _ = try normalize(wrongAction, result: "result-pdf", source: "input-1", sha: firstSHA) }

        var legacy = baseline
        legacy.items = [baseline.items[0]]
        legacy.provenance = ["sourceItemID": .string("input-1"), "sourceSHA256": .string(firstSHA), "pages": .array([]), "engine": .string("legacy")]
        let legacyParsed = try normalize(legacy, result: "result-txt", source: "input-1", sha: firstSHA)
        try check(legacyParsed.sourceSHA256 == firstSHA && legacyParsed.pages.isEmpty && legacyParsed.engineVersion == nil, "Single-item original V1 shape remains accepted without invented metadata")
        legacy.items.append(baseline.items[1])
        try rejects("Ambiguous legacy multi-output association") { _ = try normalize(legacy, result: "result-txt", source: "input-1", sha: firstSHA) }
        print("OCR result provenance: actual producer JSON, output/source/hash/page binding, engineRevision, absent metadata, duplicates/misbindings and bounded legacy compatibility passed")
    }

    private static let firstSHA = String(repeating: "a", count: 64)
    private static let secondSHA = String(repeating: "b", count: 64)
    private static func normalize(_ manifest: GaoActionManifest, result: String, source: String, sha: String) throws -> OCRProvenance {
        try OCRResultProvenance.normalize(manifest: manifest, resultItemID: result, sourceItemID: source, sourceSHA256: sha)
    }
    private static func fixture() throws -> GaoActionManifest {
        // Matches ExchangeController.performOCR's JSON wire shape, including
        // numeric engineRevision and per-source arrays rather than a fake `ocr`.
        let json = """
        {"engine":"Apple Vision VNRecognizeTextRequest","engineRevision":3,"networkUsed":false,"exportFailures":[],
         "outputs":[
          {"sourceID":"11111111-1111-4111-8111-111111111111","sourceItemID":"input-1","sourceSHA256":"\(firstSHA)","resultItemID":"result-txt","format":"text"},
          {"sourceID":"11111111-1111-4111-8111-111111111111","sourceItemID":"input-1","sourceSHA256":"\(firstSHA)","resultItemID":"result-pdf","format":"searchablePDF"},
          {"sourceID":"22222222-2222-4222-8222-222222222222","sourceItemID":"input-2","sourceSHA256":"\(secondSHA)","resultItemID":"result-md","format":"markdown"}],
         "sources":[
          {"sourceID":"11111111-1111-4111-8111-111111111111","sourceItemID":"input-1","sourceSHA256":"\(firstSHA)","outputItemIDs":["result-txt","result-pdf"],"pages":[
           {"pageNumber":1,"status":"completed","elapsedSeconds":0.25,"lineCount":3,"failureReason":null},
           {"pageNumber":2,"status":"failed","elapsedSeconds":0.1,"lineCount":0,"failureReason":"fixture failure"}]},
          {"sourceID":"22222222-2222-4222-8222-222222222222","sourceItemID":"input-2","sourceSHA256":"\(secondSHA)","outputItemIDs":["result-md"],"pages":[
           {"pageNumber":1,"status":"cancelled","elapsedSeconds":0,"lineCount":0,"failureReason":null}]}]}
        """
        let provenance = try JSONDecoder().decode([String: GaoJSONValue].self, from: Data(json.utf8))
        return GaoActionManifest(kind: "result", requestID: UUID().uuidString, sourceBundleID: "com.gaoseries.GaoJieTu", targetBundleID: GaoActionContract.bundleID,
            action: "ocr.files", createdAt: "2026-10-12T12:00:00Z", expiresAt: "2026-10-12T12:02:00Z", nonce: Data(repeating: 0, count: 32).base64EncodedString(),
            items: [.init(id: "result-txt", relativePath: "payload/result.txt", uti: "public.utf8-plain-text", byteCount: 1, sha256: firstSHA),
                    .init(id: "result-pdf", relativePath: "payload/result.pdf", uti: "com.adobe.pdf", byteCount: 1, sha256: firstSHA),
                    .init(id: "result-md", relativePath: "payload/result.md", uti: "net.daringfireball.markdown", byteCount: 1, sha256: secondSHA)],
            references: [], parameters: ["outputs": .array([.string("text"), .string("searchablePDF"), .string("markdown")])],
            inReplyTo: UUID().uuidString, status: "partial", provenance: provenance)
    }
    private static func mutateSource(_ manifest: inout GaoActionManifest, _ index: Int, _ mutate: (inout [String: GaoJSONValue]) -> Void) {
        var sources = manifest.provenance!["sources"]!.arrayValue!, source = sources[index].objectValue!
        mutate(&source); sources[index] = .object(source); manifest.provenance!["sources"] = .array(sources)
    }
    private static func mutateOutput(_ manifest: inout GaoActionManifest, _ index: Int, _ mutate: (inout [String: GaoJSONValue]) -> Void) {
        var outputs = manifest.provenance!["outputs"]!.arrayValue!, output = outputs[index].objectValue!
        mutate(&output); outputs[index] = .object(output); manifest.provenance!["outputs"] = .array(outputs)
    }
    private static func check(_ condition: @autoclosure () throws -> Bool, _ label: String) throws {
        if try !condition() { throw GaoActionContract.reject("provenanceTest", label) }
    }
    private static func rejects(_ label: String, _ work: () throws -> Void) throws {
        do { try work() } catch { return }
        throw GaoActionContract.reject("provenanceTest", "Expected rejection: " + label)
    }
}
