import Foundation
import CoreFoundation

/// Checks the provider's OCRDocument JSON against its already-normalized wire
/// provenance. This is an association/ordering check, never an OCR accuracy
/// claim. The original JSON stays unchanged in a new unsaved text document.
struct OCRJSONPayloadReport: Equatable {
    let providerSourceID: String
    let sourceSHA256: String
    let pageNumbers: [Int]
    let pageStatuses: [String]
    var hasIncompletePages: Bool { pageStatuses.contains { $0 != "completed" } }
}

enum OCRJSONPayloadVerifier {
    static let maximumBytes = 8_388_608
    static let maximumPages = 10_000

    @discardableResult static func verify(data: Data, provenance: OCRProvenance,
                                         expectedSourceSHA256: String,
                                         expectedProviderSourceID: String,
                                         expectedPageCount: Int? = nil,
                                         expectedByteCount: Int64? = nil) throws -> OCRJSONPayloadReport {
        guard !data.isEmpty, data.count <= maximumBytes,
              String(data: data, encoding: .utf8) != nil,
              GaoActionContract.validSHA(expectedSourceSHA256),
              provenance.sourceSHA256 == expectedSourceSHA256,
              provenance.sourceItemID?.isEmpty == false,
              UUID(uuidString: expectedProviderSourceID) != nil,
              let document = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              integer(document["schemaVersion"], minimum: 1, maximum: 1) == 1,
              let sources = document["sources"] as? [[String: Any]], sources.count == 1,
              let source = sources.first,
              source["id"] as? String == expectedProviderSourceID,
              source["sha256"] as? String == expectedSourceSHA256,
              let pageCount = integer(source["pageCount"], minimum: 1, maximum: maximumPages),
              let byteCount = integer(source["byteCount"], minimum: 1, maximum: 512 * 1024 * 1024),
              boolean(source["isPDF"]) != nil,
              let pages = document["pages"] as? [[String: Any]], pages.count == pageCount,
              provenance.pages.count == pageCount else { throw invalid() }
        if let expectedPageCount, expectedPageCount != pageCount { throw mismatch() }
        if let expectedByteCount, expectedByteCount != Int64(byteCount) { throw mismatch() }

        // Do not fill absent engine/version/metadata from a local default. When
        // supplied in the manifest, the JSON body must make the same claim.
        if let engine = provenance.engine, document["engine"] as? String != engine { throw mismatch() }
        if let version = provenance.engineVersion {
            guard let revision = integer(document["engineRevision"], minimum: 0, maximum: 9_007_199_254_740_991),
                  String(revision) == version else { throw mismatch() }
        }

        let expectedPages = provenance.pages.sorted { $0.pageNumber < $1.pageNumber }
        guard expectedPages.map(\.pageNumber) == Array(1...pageCount) else { throw mismatch() }
        var statuses: [String] = []
        for (offset, page) in pages.enumerated() {
            // JSON document.pages is the provider's actual export/read order.
            // Refuse reordered, repeated or missing page records rather than
            // sorting their content into a guessed association.
            guard integer(page["pageNumber"], minimum: 1, maximum: pageCount) == offset + 1,
                  page["sourceID"] as? String == expectedProviderSourceID,
                  page["originalSHA256"] as? String == expectedSourceSHA256,
                  let status = page["status"] as? String,
                  ["completed", "failed", "cancelled"].contains(status),
                  expectedPages[offset].status == status,
                  let lines = page["lines"] as? [[String: Any]],
                  lines.count <= 100_000 else { throw mismatch() }
            // A failed or cancelled page must not smuggle successful text into
            // an otherwise coherent result. Real provider failures use [].
            if status != "completed", !lines.isEmpty { throw mismatch() }
            for line in lines {
                guard let text = line["text"] as? String,
                      !text.contains("\0"), text.utf8.count <= maximumBytes else { throw invalid() }
            }
            statuses.append(status)
        }
        return OCRJSONPayloadReport(providerSourceID: expectedProviderSourceID,
            sourceSHA256: expectedSourceSHA256, pageNumbers: Array(1...pageCount), pageStatuses: statuses)
    }

    private static func integer(_ value: Any?, minimum: Int, maximum: Int) -> Int? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue.isFinite, number.doubleValue.rounded() == number.doubleValue,
              number.doubleValue >= Double(minimum), number.doubleValue <= Double(maximum) else { return nil }
        return number.intValue
    }
    private static func boolean(_ value: Any?) -> Bool? {
        guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { return nil }
        return number.boolValue
    }
    private static func invalid() -> GaoActionIssue {
        GaoActionContract.reject("invalidOCRJSON", "OCR JSON 正文无效、版本不支持或缺少必要来源/逐页说明；未打开此附件，原件与现有文档保留。")
    }
    private static func mismatch() -> GaoActionIssue {
        GaoActionContract.reject("ocrJSONSourceMismatch", "OCR JSON 正文的来源、摘要、页序或逐页状态与本次交接不一致；未打开此附件，其他已接收结果与原件保留。")
    }
}
