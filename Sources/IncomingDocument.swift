import Foundation

struct IncomingDocument: Codable, Equatable {
    let requestID: String
    let itemID: String
    let sourceBundleID: String
    let type: String
    let receivedAt: String
    let contentSHA256: String
    let originalName: String
    var ocrProvenance: OCRProvenance?
    var pdfReport: PDFHandoffReport?
    var notes: [String] = []
    var inboundAction: String?
    var manifestSHA256: String?
    var receivedCopyURL: String?
    var sourceDisplayName: String?
    var opensOriginal: Bool?
    var sourceName: String {
        switch sourceBundleID {
        case "com.gaoseries.GaoJieTu": return "搞截图"
        case "com.gaoseries.GaoZhengLi": return "搞整理"
        case "com.academic-achievement.manager": return "搞研究"
        case GaoActionContract.bundleID: return "手动导入"
        default: return sourceBundleID
        }
    }
    var summary: String {
        if opensOriginal == true { return "所选原件 · 保存将写回原文件" }
        if let report=pdfReport { return report.isVerifiedSearchable ? "PDF 基本文字层核验通过" : "PDF 来源待复核" }
        if type == "ocrText" { return "OCR 文字 · 新的未保存文档" }
        return "交接文档 · 原件保留"
    }
}

enum DocumentOriginStorage {
    static func load(for url:URL) throws -> IncomingDocument? {
        let root=FileSafety.root.appendingPathComponent("Exchange/Origins")
        let key=FileSafety.digest(Data(url.standardizedFileURL.path.utf8))+".json"
        let path=root.appendingPathComponent(key)
        guard FileManager.default.fileExists(atPath:path.path) else { return nil }
        return try JSONDecoder().decode(IncomingDocument.self,from:GaoPrivateIO.read(GaoPrivateIO.regularURL(path),maximum:1_048_576))
    }
    static func save(_ value:IncomingDocument, for url:URL) throws {
        let root=FileSafety.root.appendingPathComponent("Exchange/Origins")
        let directory=try GaoPrivateIO.directory(root,create:true,requirePrivate:true)
        let key=FileSafety.digest(Data(url.standardizedFileURL.path.utf8))+".json"
        // A damaged previous record is retained, never silently replaced.
        _ = try load(for:url)
        let bytes=try JSONEncoder().encode(value)
        guard bytes.count <= 1_048_576 else { throw FileIssue.message("来源说明过大，未覆盖已有记录。") }
        try GaoPrivateIO.atomicJSON(bytes,directory:directory,name:key)
    }
}

enum HandoffNames {
    static func display(_ value:String, limit:Int=256)->String {
        String(String.UnicodeScalarView(value.unicodeScalars.filter{!CharacterSet.controlCharacters.contains($0)})).prefix(limit).description
    }
    static func title(_ suggested:String?,fallback:String)->String {
        let value=display(suggested ?? fallback).replacingOccurrences(of:"/",with:"-").replacingOccurrences(of:"\\",with:"-").trimmingCharacters(in:.whitespacesAndNewlines)
        return value.isEmpty ? "交接文档" : value
    }
}
