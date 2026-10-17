import Foundation

enum OCRJSONPayloadVerifierTests {
    @discardableResult static func run() throws -> Int {
        var checks = 0
        func check(_ condition: @autoclosure () throws -> Bool, _ name: String) throws {
            guard try condition() else { throw GaoActionContract.reject("ocrJSONTest", name) }; checks += 1
        }
        func rejects(_ name: String, _ body: () throws -> Void) throws {
            do { try body() } catch { checks += 1; return }
            throw GaoActionContract.reject("ocrJSONTest", "Expected rejection: " + name)
        }
        let sourceID = "11111111-1111-4111-8111-111111111111"
        let otherSourceID = "22222222-2222-4222-8222-222222222222"
        let hash = String(repeating: "a", count: 64)
        let otherHash = String(repeating: "b", count: 64)
        let provenance = OCRProvenance(sourceItemID: "sent-item-1", sourceSHA256: hash,
            engine: "Apple Vision VNRecognizeTextRequest", engineVersion: "3", pages: [
                .init(pageNumber: 1, status: "completed"), .init(pageNumber: 2, status: "failed")])
        let body: [String: Any] = [
            "schemaVersion": 1, "engine": "Apple Vision VNRecognizeTextRequest", "engineRevision": 3,
            "sources": [["id": sourceID, "sha256": hash, "byteCount": 1000, "pageCount": 2, "isPDF": true]],
            "pages": [
                ["sourceID": sourceID, "pageNumber": 1, "originalSHA256": hash, "status": "completed", "lines": [["text": "第一页文字 😀"]]],
                ["sourceID": sourceID, "pageNumber": 2, "originalSHA256": hash, "status": "failed", "lines": []]
            ]
        ]
        func data(_ object: [String: Any]) throws -> Data { try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) }
        func verify(_ object: [String: Any], _ metadata: OCRProvenance? = nil) throws -> OCRJSONPayloadReport {
            try OCRJSONPayloadVerifier.verify(data: data(object), provenance: metadata ?? provenance,
                expectedSourceSHA256: hash, expectedProviderSourceID: sourceID, expectedPageCount: 2, expectedByteCount: 1000)
        }
        func changedSource(_ key: String, _ value: Any) -> [String: Any] {
            var copy = body, source = (body["sources"] as! [[String: Any]])[0]
            source[key] = value; copy["sources"] = [source]; return copy
        }
        func changedPage(_ index: Int, _ key: String, _ value: Any) -> [String: Any] {
            var copy = body, pages = body["pages"] as! [[String: Any]]
            pages[index][key] = value; copy["pages"] = pages; return copy
        }
        let report = try verify(body)
        try check(report.pageNumbers == [1, 2] && report.pageStatuses == ["completed", "failed"] && report.hasIncompletePages, "Genuine provider shape preserves partial page ordering and status")
        try check(report.providerSourceID == sourceID && report.sourceSHA256 == hash, "Correct source/hash survives association check")
        let original = try data(body)
        _ = try verify(body)
        try check(try data(body) == original, "Verifier does not rewrite the JSON body")
        var absentOptional = body
        absentOptional.removeValue(forKey: "engine"); absentOptional.removeValue(forKey: "engineRevision")
        var minimal = provenance; minimal.engine = nil; minimal.engineVersion = nil
        try check(try verify(absentOptional, minimal).pageNumbers == [1, 2] && minimal.languages.isEmpty && minimal.coordinateSystem == nil, "Missing optional metadata remains absent")
        var allCompleted = body, full = provenance
        full.pages[1].status = "completed"
        var completePages = body["pages"] as! [[String: Any]]; completePages[1]["status"] = "completed"; allCompleted["pages"] = completePages
        try check(try !verify(allCompleted, full).hasIncompletePages, "All completed pages remain an association check only")
        var cancelled = body, cancelledMetadata = provenance
        cancelledMetadata.pages[1].status = "cancelled"
        var cancelledPages = body["pages"] as! [[String: Any]]; cancelledPages[1]["status"] = "cancelled"; cancelled["pages"] = cancelledPages
        try check(try verify(cancelled, cancelledMetadata).pageStatuses == ["completed", "cancelled"], "Cancelled trailing page is explicit")

        for (key, value) in [("id", otherSourceID as Any), ("sha256", otherHash), ("pageCount", 3), ("pageCount", true), ("pageCount", 2.5), ("byteCount", 999), ("isPDF", 1)] {
            try rejects("Source " + key) { _ = try verify(changedSource(key, value)) }
        }
        for (key, value) in [("sourceID", otherSourceID as Any), ("originalSHA256", otherHash), ("pageNumber", 2), ("pageNumber", true), ("status", "failed")] {
            try rejects("Page " + key) { _ = try verify(changedPage(0, key, value)) }
        }
        try rejects("Failed page cannot carry recognized lines") { _ = try verify(changedPage(1, "lines", [["text": "wrong successful text"]])) }
        try rejects("Line must have text") { _ = try verify(changedPage(0, "lines", [["confidence": 0.7]])) }
        try rejects("No NUL in text") { _ = try verify(changedPage(0, "lines", [["text": "bad\0body"]])) }
        var reversed = body; reversed["pages"] = Array((body["pages"] as! [[String: Any]]).reversed())
        try rejects("JSON export page order cannot be silently sorted") { _ = try verify(reversed) }
        var duplicate = body; duplicate["pages"] = [(body["pages"] as! [[String: Any]])[0], (body["pages"] as! [[String: Any]])[0]]
        try rejects("Repeated JSON page") { _ = try verify(duplicate) }
        var missing = body; missing["pages"] = [(body["pages"] as! [[String: Any]])[0]]
        try rejects("Missing page") { _ = try verify(missing) }
        var multiple = body; multiple["sources"] = [changedSource("id", otherSourceID)["sources"] as! [[String: Any]], body["sources"] as! [[String: Any]]].flatMap { $0 }
        try rejects("Another input cannot be hidden in the same output") { _ = try verify(multiple) }
        var noManifestPages = provenance; noManifestPages.pages = []
        try rejects("No invented manifest page provenance") { _ = try verify(body, noManifestPages) }
        var repeatedManifest = provenance; repeatedManifest.pages[1].status = "completed"
        try rejects("JSON/manifest status disagreement") { _ = try verify(body, repeatedManifest) }
        var incorrectMetadata = provenance; incorrectMetadata.sourceSHA256 = otherHash
        try rejects("Manifest/source digest disagreement") { _ = try verify(body, incorrectMetadata) }
        var schema = body; schema["schemaVersion"] = 2
        try rejects("Future schema") { _ = try verify(schema) }
        schema["schemaVersion"] = true
        try rejects("Boolean schema") { _ = try verify(schema) }
        var wrongEngine = body; wrongEngine["engine"] = "Other engine"
        try rejects("Engine claim conflict") { _ = try verify(wrongEngine) }
        wrongEngine = body; wrongEngine["engineRevision"] = 4
        try rejects("Revision claim conflict") { _ = try verify(wrongEngine) }
        for bytes in [Data("not JSON".utf8), Data([0xff, 0xfe]), Data(repeating: 32, count: OCRJSONPayloadVerifier.maximumBytes + 1)] {
            try rejects("Invalid/oversized JSON") { _ = try OCRJSONPayloadVerifier.verify(data: bytes, provenance: provenance, expectedSourceSHA256: hash, expectedProviderSourceID: sourceID) }
        }
        print("OCR JSON payload: \(checks) checks passed (actual source ID/hash, ordered complete page records, partial/cancelled statuses, cross-input/malformed rejection; no UI)")
        return checks
    }
}
