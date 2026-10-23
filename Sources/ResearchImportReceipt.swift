import Foundation

/// A research import reply reports the reviewed import of each sent source.
/// It never authorizes opening attachments or writing back an edited document.
enum ResearchImportReceipt {
    static func validate(_ manifest: GaoActionManifest, session: GaoOutgoingSession) throws {
        guard session.action == "research.importDocuments" else { return }
        let statuses: Set<String> = ["pending", "partial", "completed", "failed", "cancelled", "unsupported"]
        guard manifest.kind == "result", manifest.action == session.action,
              manifest.inReplyTo == session.requestID,
              manifest.sourceBundleID == session.targetBundleID,
              manifest.targetBundleID == GaoActionContract.bundleID,
              let status = manifest.status, statuses.contains(status),
              manifest.parameters.isEmpty, manifest.items.isEmpty, manifest.references.isEmpty else {
            throw GaoActionContract.reject("researchResultShape", "研究导入回执只能报告所发请求的处理状态，不能携带文档附件、原件引用或请求参数。")
        }
        guard let provenance = manifest.provenance,
              GaoActionContract.validSHA(session.manifestSHA256),
              provenance["requestManifestSHA256"]?.stringValue == session.manifestSHA256,
              provenance["workflowState"]?.stringValue == (status == "completed" ? "imported" : status),
              let sources = provenance["sources"]?.arrayValue,
              !session.sources.isEmpty, sources.count == session.sources.count else {
            throw GaoActionContract.reject("researchResultProvenance", "研究导入回执缺少准确的原请求摘要、流程状态或完整来源清单。")
        }
        var expected: [String: String] = [:]
        for source in session.sources {
            guard !source.item.id.isEmpty, GaoActionContract.validSHA(source.item.sha256),
                  expected.updateValue(source.item.sha256, forKey: source.item.id) == nil else {
                throw GaoActionContract.reject("researchResultProvenance", "所发研究文档的来源清单无效，不能确认导入状态。")
            }
        }
        let sourceStatuses: Set<String> = ["imported", "failed", "cancelled", "pending", "unsupported"]
        var seen = Set<String>(), imported = 0
        for value in sources {
            guard let source = value.objectValue,
                  let id = source["sourceItemID"]?.stringValue, seen.insert(id).inserted,
                  let hash = source["sourceSHA256"]?.stringValue, expected[id] == hash,
                  let sourceStatus = source["status"]?.stringValue, sourceStatuses.contains(sourceStatus) else {
                throw GaoActionContract.reject("researchResultProvenance", "研究导入回执含未知、重复或摘要不匹配的来源，或来源状态无效。")
            }
            if sourceStatus == "imported" { imported += 1 }
        }
        guard seen == Set(expected.keys) else {
            throw GaoActionContract.reject("researchResultProvenance", "研究导入回执未完整覆盖所发文档。")
        }
        let consistent: Bool
        switch status {
        case "completed": consistent = imported == sources.count
        case "partial": consistent = imported > 0 && imported < sources.count
        default: consistent = imported == 0
        }
        guard consistent else {
            throw GaoActionContract.reject("researchResultStatus", "研究导入回执的整体状态与各文档实际报告的导入状态不一致。")
        }
    }
}
