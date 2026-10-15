import Foundation

/// Decode the provider's real per-source/per-output result records. These fields
/// are claims to cross-check against our outgoing journal, not authentication.
enum OCRResultProvenance {
    static func normalize(manifest: GaoActionManifest, resultItemID: String,
                          sourceItemID: String, sourceSHA256: String) throws -> OCRProvenance {
        guard manifest.kind == "result", manifest.action == "ocr.files",
              GaoActionContract.validSHA(sourceSHA256), !sourceItemID.isEmpty,
              let record = manifest.provenance,
              manifest.items.filter({ $0.id == resultItemID }).count == 1,
              Set(manifest.items.map(\.id)).count == manifest.items.count else { throw invalid() }

        if record["sources"] == nil && record["outputs"] == nil {
            // Original V1 single-input results used top-level source fields.
            // With multiple attachments this shape cannot establish a unique
            // per-output binding, so it must never be guessed.
            guard manifest.items.count == 1,
                  try requiredText(record["sourceItemID"]) == sourceItemID,
                  try requiredHash(record["sourceSHA256"]) == sourceSHA256 else { throw mismatch() }
            return try normalized(source: record, common: record)
        }
        guard let sources = record["sources"]?.arrayValue, !sources.isEmpty,
              sources.count <= GaoActionContract.maximumItems,
              let outputs = record["outputs"]?.arrayValue,
              outputs.count <= GaoActionContract.maximumItems else { throw invalid() }

        var sourceIDs = Set<String>(), itemIDs = Set<String>()
        var sourcesByItem: [String: [String: GaoJSONValue]] = [:]
        var parsedSources: [String: OCRProvenance] = [:]
        var listedOutputs: [String: Set<String>] = [:]
        for value in sources {
            guard let source = value.objectValue else { throw invalid() }
            let sourceID = try requiredText(source["sourceID"])
            let itemID = try requiredText(source["sourceItemID"])
            _ = try requiredHash(source["sourceSHA256"])
            guard sourceIDs.insert(sourceID).inserted, itemIDs.insert(itemID).inserted else { throw invalid() }
            sourcesByItem[itemID] = source
            parsedSources[itemID] = try normalized(source: source, common: record)
            if let value = source["outputItemIDs"] {
                guard let ids = value.arrayValue, ids.count <= GaoActionContract.maximumItems else { throw invalid() }
                var unique = Set<String>()
                for id in ids { guard unique.insert(try requiredText(id)).inserted else { throw invalid() } }
                listedOutputs[itemID] = unique
            }
        }
        let resultIDs = Set(manifest.items.map(\.id))
        var outputIDs = Set<String>(), actualOutputs: [String: Set<String>] = [:]
        var selectedSource: String?
        for value in outputs {
            guard let output = value.objectValue else { throw invalid() }
            let outputID = try requiredText(output["resultItemID"])
            let itemID = try requiredText(output["sourceItemID"])
            let hash = try requiredHash(output["sourceSHA256"])
            let providerSourceID = try requiredText(output["sourceID"])
            guard let source = sourcesByItem[itemID],
                  try requiredHash(source["sourceSHA256"]) == hash,
                  try requiredText(source["sourceID"]) == providerSourceID,
                  resultIDs.contains(outputID), outputIDs.insert(outputID).inserted else { throw mismatch() }
            if let format = output["format"] {
                guard let name = format.stringValue, ["text", "markdown", "json", "searchablePDF"].contains(name) else { throw invalid() }
            }
            actualOutputs[itemID, default: []].insert(outputID)
            if outputID == resultItemID { selectedSource = itemID }
        }
        // Every returned attachment needs one binding, including outputs not
        // currently selected. An extra unattached or multiply bound result is
        // not safe to interpret by its filename or array position.
        guard outputIDs == resultIDs else { throw mismatch() }
        for (itemID, ids) in listedOutputs where ids != actualOutputs[itemID, default: []] { throw mismatch() }
        guard selectedSource == sourceItemID,
              let selected = parsedSources[sourceItemID], selected.sourceSHA256 == sourceSHA256 else { throw mismatch() }
        if record["sourceItemID"] != nil || record["sourceSHA256"] != nil {
            guard sources.count == 1,
                  try requiredText(record["sourceItemID"]) == sourceItemID,
                  try requiredHash(record["sourceSHA256"]) == sourceSHA256 else { throw mismatch() }
        }
        return selected
    }

    private static func normalized(source: [String: GaoJSONValue], common: [String: GaoJSONValue]) throws -> OCRProvenance {
        var fields: [String: GaoJSONValue] = [
            "sourceItemID": .string(try requiredText(source["sourceItemID"])),
            "sourceSHA256": .string(try requiredHash(source["sourceSHA256"]))
        ]
        if let pages = source["pages"] { fields["pages"] = pages }
        for key in ["languages", "coordinateSystem", "confidenceSource"] {
            if let value = source[key] ?? common[key] { fields[key] = value }
        }
        if let engine = common["engine"] { fields["engine"] = engine }
        if let version = common["engineVersion"] { fields["engineVersion"] = version }
        if let revisionValue = common["engineRevision"] {
            guard let revision = revisionValue.numberValue, revision.isFinite,
                  revision >= 0, revision <= 9_007_199_254_740_991, revision.rounded() == revision else { throw invalid() }
            let version = String(Int64(revision))
            if let declared = fields["engineVersion"], declared.stringValue != version { throw invalid() }
            if let engine = fields["engine"]?.objectValue, let declared = engine["version"], declared.stringValue != version { throw invalid() }
            if var engine = fields["engine"]?.objectValue {
                engine["version"] = .string(version); fields["engine"] = .object(engine)
            } else { fields["engineVersion"] = .string(version) }
        }
        // Existing parser bounds strings/pages, rejects duplicate page numbers,
        // invalid statuses/confidence and preserves optional metadata as absent.
        return try OCRProvenance.parse(jsonData: JSONEncoder().encode(GaoJSONValue.object(fields)))
    }

    private static func requiredText(_ value: GaoJSONValue?) throws -> String {
        guard let value = value?.stringValue, !value.isEmpty, value.utf8.count <= 256 else { throw invalid() }
        return value
    }
    private static func requiredHash(_ value: GaoJSONValue?) throws -> String {
        let hash = try requiredText(value)
        guard GaoActionContract.validSHA(hash) else { throw invalid() }
        return hash
    }
    private static func invalid() -> GaoActionIssue {
        GaoActionContract.reject("invalidOCRProvenance", "OCR 来源说明格式无效或包含重复记录，原件与当前文档仍保留。")
    }
    private static func mismatch() -> GaoActionIssue {
        GaoActionContract.reject("ocrSourceMismatch", "OCR 结果与本次发出的原件或附件关联不一致，已停止接收，原件与当前文档仍保留。")
    }
}
