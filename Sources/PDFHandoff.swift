import AppKit
import PDFKit
import Foundation
import Darwin

/// Provider statements remain untrusted metadata. A source hash links an OCR
/// result to the bytes sent by this app; it does not authenticate the provider.
struct OCRProvenance: Codable, Equatable {
    var sourceItemID: String?
    var sourceSHA256: String?
    var engine: String?
    var engineVersion: String?
    var languages: [String] = []
    var coordinateSystem: String?
    var confidenceSource: String?
    var pages: [OCRPageProvenance] = []

    static func parse(jsonData: Data) throws -> OCRProvenance {
        guard jsonData.count <= 1024 * 1024,
              let object = try JSONSerialization.jsonObject(with: jsonData) as? [String: Any] else {
            throw PDFWorkspaceError.message("OCR 来源说明格式无效，结果可按普通文档复核。")
        }
        func text(_ value: Any?, limit: Int = 256) throws -> String? {
            guard let value, !(value is NSNull) else { return nil }
            guard let string = value as? String, string.count <= limit else {
                throw PDFWorkspaceError.message("OCR 来源说明包含无效字段。")
            }
            return string
        }
        var result = OCRProvenance()
        result.sourceItemID = try text(object["sourceItemID"])
        result.sourceSHA256 = try text(object["sourceSHA256"], limit: 64)?.lowercased()
        if let hash = result.sourceSHA256,
           hash.count != 64 || hash.range(of: "^[0-9a-f]{64}$", options: .regularExpression) == nil {
            throw PDFWorkspaceError.message("OCR 原件摘要无效。")
        }
        if let engine = object["engine"] as? [String: Any] {
            result.engine = try text(engine["name"])
            result.engineVersion = try text(engine["version"])
        } else {
            result.engine = try text(object["engine"])
            result.engineVersion = try text(object["engineVersion"])
        }
        result.coordinateSystem = try text(object["coordinateSystem"])
        result.confidenceSource = try text(object["confidenceSource"])
        if let value = object["languages"], !(value is NSNull) {
            guard let languages = value as? [String], languages.count <= 32,
                  languages.allSatisfy({ !$0.isEmpty && $0.count <= 64 }) else {
                throw PDFWorkspaceError.message("OCR 语言说明无效。")
            }
            result.languages = languages
        }
        if let value = object["pages"], !(value is NSNull) {
            guard let pages = value as? [[String: Any]], pages.count <= PDFHandoffVerifier.maximumPages else {
                throw PDFWorkspaceError.message("OCR 逐页说明无效。")
            }
            var seen = Set<Int>()
            for page in pages {
                guard let number = page["pageNumber"] as? NSNumber,
                      CFGetTypeID(number) != CFBooleanGetTypeID(),
                      number.doubleValue.rounded() == number.doubleValue,
                      number.intValue >= 1, number.intValue <= PDFHandoffVerifier.maximumPages,
                      seen.insert(number.intValue).inserted else {
                    throw PDFWorkspaceError.message("OCR 页码无效或重复。")
                }
                let status = try text(page["status"], limit: 32)
                if let status, !["completed", "partial", "failed", "unsupported", "cancelled"].contains(status) {
                    throw PDFWorkspaceError.message("OCR 逐页状态无效。")
                }
                var confidence: Double?
                if let value = page["confidence"], !(value is NSNull) {
                    guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
                          number.doubleValue.isFinite, (0...1).contains(number.doubleValue) else {
                        throw PDFWorkspaceError.message("OCR 置信度无效。")
                    }
                    confidence = number.doubleValue
                }
                result.pages.append(OCRPageProvenance(pageNumber: number.intValue, status: status,
                    confidence: confidence, confidenceSource: try text(page["confidenceSource"])))
            }
        }
        return result
    }
}

struct OCRPageProvenance: Codable, Equatable {
    let pageNumber: Int
    var status: String?
    var confidence: Double?
    var confidenceSource: String?
}

struct PDFHandoffIssue: Codable, Equatable {
    let code: String
    let message: String
    var pageNumber: Int?
}

struct PDFHandoffPageCheck: Codable, Equatable {
    let pageNumber: Int
    let rotation: Int
    let mediaBox: [Double]
    let cropBox: [Double]
    let textCharacterCount: Int
    let hasSelectablePageText: Bool
    let geometryMatchesSource: Bool?
    let renderedPageMatchesSource: Bool?
    let declaredOCRStatus: String?
}

struct PDFHandoffReport: Codable, Equatable {
    let resultSHA256: String
    let originalSHA256: String?
    let sourceDigestMatches: Bool?
    let sourceItemIDMatches: Bool?
    let pageChecks: [PDFHandoffPageCheck]
    let issues: [PDFHandoffIssue]
    let isVerifiedSearchable: Bool
    var hasSearchablePageText: Bool { pageChecks.contains(where: \.hasSelectablePageText) }
    var summary: String {
        if isVerifiedSearchable { return "已核对原件摘要、页数、页序、页面尺寸与旋转；每页可检索、选取文字。识别准确率与完整性仍需人工复核。" }
        if hasSearchablePageText { return "PDF 含可检索、选取的页面文字；来源或逐页一致性尚未全部核验，请按检查结果复核。" }
        return "未检测到可检索、选取的页面文字；此结果按普通 PDF 打开，不标为可搜索 OCR 成果。"
    }
}

/// This performs conservative structural checks, never OCR or accuracy scoring.
/// Page rendering is compared by position, so equal-sized reordered scans are
/// not silently accepted merely because MediaBox and CropBox happen to match.
enum PDFHandoffVerifier {
    static let maximumBytes = 512 * 1024 * 1024
    static let maximumPages = 10_000
    static let maximumCharactersPerPage = 1_000_000

    static func inspect(resultData: Data, originalData: Data? = nil,
                        provenance: OCRProvenance? = nil, expectedSourceItemID: String? = nil) throws -> PDFHandoffReport {
        let result = try readableDocument(resultData)
        var issues: [PDFHandoffIssue] = []
        var source: PDFDocument?
        if let originalData {
            do { source = try readableDocument(originalData) }
            catch { issues.append(.init(code: "sourceNotComparable", message: "原件不是可核验的 PDF（例如图像输入）；来源摘要见单独检查，页序、旋转与 PDF 页面尺寸仍需人工复核。")) }
        } else {
            issues.append(.init(code: "sourceUnavailable", message: "未提供原件副本，无法核验原件摘要、页序和页面几何。"))
        }
        let originalHash = originalData.map(FileSafety.digest)
        let hashMatches = originalHash.flatMap { hash in provenance?.sourceSHA256.map { $0.lowercased() == hash } }
        let itemMatches = expectedSourceItemID.map { $0 == provenance?.sourceItemID }
        if originalData != nil && hashMatches != true { issues.append(.init(code: "sourceDigestUnverified", message: "OCR 来源摘要缺失或与本次原件副本不符。")) }
        if provenance?.sourceItemID?.isEmpty != false || itemMatches == false {
            issues.append(.init(code: "sourceItemUnverified", message: "OCR 来源项目标识缺失或与本次送出的项目不符。"))
        }
        let sameCount = source.map { $0.pageCount == result.pageCount }
        if sameCount == false { issues.append(.init(code: "pageCountMismatch", message: "结果与原件页数不同，不能确认完整衍生版本。")) }
        var declaredPages: [Int: OCRPageProvenance] = [:]
        for page in provenance?.pages ?? [] {
            guard page.pageNumber > 0, page.pageNumber <= result.pageCount, declaredPages[page.pageNumber] == nil else {
                issues.append(.init(code: "pageProvenanceInvalid", message: "OCR 逐页说明含重复或范围外页码。"))
                continue
            }
            declaredPages[page.pageNumber] = page
        }
        if declaredPages.count != result.pageCount {
            issues.append(.init(code: "pageProvenanceIncomplete", message: "OCR 逐页来源说明不完整；缺失说明不会阻止按普通文档接收。"))
        }
        var checks: [PDFHandoffPageCheck] = []
        for index in 0..<result.pageCount {
            guard let page = result.page(at: index) else { throw PDFWorkspaceError.message("PDF 页面无法读取。") }
            let pageNumber = index + 1
            let characterCount = page.numberOfCharacters
            guard characterCount <= maximumCharactersPerPage else { throw PDFWorkspaceError.message("PDF 单页文字量过大，无法安全完成交接核验。") }
            let hasText = selectableText(on: page)
            if !hasText { issues.append(.init(code: "noSelectablePageText", message: "本页没有可检索、选取的页面文字；便签和叠加旁注不算 OCR 文字层。", pageNumber: pageNumber)) }
            let declared = declaredPages[pageNumber]
            if declared?.status != "completed" {
                issues.append(.init(code: "pageOCRNotCompleted", message: "本页 OCR 未声明完成或缺少逐页状态。", pageNumber: pageNumber))
            }
            var geometryMatches: Bool?
            var renderMatches: Bool?
            if let originalPage = source?.page(at: index) {
                geometryMatches = normalizedRotation(originalPage.rotation) == normalizedRotation(page.rotation)
                    && rectMatches(originalPage.bounds(for: .mediaBox), page.bounds(for: .mediaBox))
                    && rectMatches(originalPage.bounds(for: .cropBox), page.bounds(for: .cropBox))
                if geometryMatches == false { issues.append(.init(code: "pageGeometryMismatch", message: "本页旋转、MediaBox 或 CropBox 与原件不一致。", pageNumber: pageNumber)) }
                if geometryMatches == true {
                    renderMatches = try renderedPageMatches(originalPage, page)
                    if renderMatches == false {
                        issues.append(.init(code: "pageAppearanceMismatch", message: "本页渲染与原件不同，页序或页面内容需要人工复核。", pageNumber: pageNumber))
                    }
                }
            }
            checks.append(.init(pageNumber: pageNumber, rotation: normalizedRotation(page.rotation),
                mediaBox: components(page.bounds(for: .mediaBox)), cropBox: components(page.bounds(for: .cropBox)),
                textCharacterCount: characterCount, hasSelectablePageText: hasText,
                geometryMatchesSource: geometryMatches, renderedPageMatchesSource: renderMatches,
                declaredOCRStatus: declared?.status))
        }
        return PDFHandoffReport(resultSHA256: FileSafety.digest(resultData), originalSHA256: originalHash,
            sourceDigestMatches: hashMatches, sourceItemIDMatches: itemMatches, pageChecks: checks, issues: issues,
            isVerifiedSearchable: issues.isEmpty)
    }

    private static func readableDocument(_ bytes: Data) throws -> PDFDocument {
        guard !bytes.isEmpty, bytes.count <= maximumBytes,
              let document = PDFDocument(data: bytes), !document.isLocked,
              document.pageCount > 0, document.pageCount <= maximumPages else {
            throw PDFWorkspaceError.message("交接 PDF 损坏、需要密码、超过 512 MB 或页数限制，无法核验。原件未改动。")
        }
        for index in 0..<document.pageCount {
            guard let page = document.page(at: index), validRect(page.bounds(for: .mediaBox)), validRect(page.bounds(for: .cropBox)) else {
                throw PDFWorkspaceError.message("PDF 包含无效页面尺寸，无法核验。")
            }
        }
        return document
    }

    private static func selectableText(on page: PDFPage) -> Bool {
        // PDFPage.string/selection read page content, not annotation.contents.
        // Requiring an in-crop selection also excludes text hidden off-page.
        guard let text = page.string, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let whole = page.selection(for: NSRange(location: 0, length: page.numberOfCharacters)),
              let selected = whole.string, !selected.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        let crop = page.bounds(for: .cropBox)
        let lines = whole.selectionsByLine()
        return lines.contains { selection in
            let bounds = selection.bounds(for: page)
            return bounds.width > 0 && bounds.height > 0 && validRect(bounds) && crop.intersects(bounds)
                && !(selection.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    private static func normalizedRotation(_ rotation: Int) -> Int { (rotation % 360 + 360) % 360 }
    private static func components(_ rect: CGRect) -> [Double] { [Double(rect.origin.x), Double(rect.origin.y), Double(rect.width), Double(rect.height)] }
    private static func validRect(_ rect: CGRect) -> Bool { components(rect).allSatisfy(\.isFinite) && rect.width > 0 && rect.height > 0 && rect.width <= 100_000 && rect.height <= 100_000 }
    private static func rectMatches(_ left: CGRect, _ right: CGRect) -> Bool { zip(components(left), components(right)).allSatisfy { abs($0 - $1) <= 0.01 } }

    private static func renderedPageMatches(_ first: PDFPage, _ second: PDFPage) throws -> Bool {
        let left = try pagePixels(first), right = try pagePixels(second)
        var total = 0, changed = 0
        for offset in stride(from: 0, to: left.count, by: 4) {
            let difference = max(abs(Int(left[offset]) - Int(right[offset])),
                max(abs(Int(left[offset + 1]) - Int(right[offset + 1])), abs(Int(left[offset + 2]) - Int(right[offset + 2]))))
            total += difference
            if difference > 24 { changed += 1 }
        }
        // OCR may resample a scan. A mismatch is a review flag, never data loss
        // or a reason to reject an otherwise readable standard PDF document.
        let pixelCount = left.count / 4
        return Double(total) / Double(pixelCount) <= 0.75 && Double(changed) / Double(pixelCount) <= 0.002
    }

    private static func pagePixels(_ page: PDFPage) throws -> [UInt8] {
        let side = 192
        var pixels = [UInt8](repeating: 255, count: side * side * 4)
        let success = pixels.withUnsafeMutableBytes { memory -> Bool in
            guard let context = CGContext(data: memory.baseAddress, width: side, height: side, bitsPerComponent: 8,
                bytesPerRow: side * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
                  let image = page.thumbnail(of: NSSize(width: side, height: side), for: .cropBox).cgImage(forProposedRect: nil, context: nil, hints: nil) else { return false }
            context.setFillColor(NSColor.white.cgColor)
            context.fill(CGRect(x: 0, y: 0, width: side, height: side))
            let factor = min(CGFloat(side) / CGFloat(image.width), CGFloat(side) / CGFloat(image.height))
            let size = CGSize(width: CGFloat(image.width) * factor, height: CGFloat(image.height) * factor)
            context.draw(image, in: CGRect(x: (CGFloat(side) - size.width) / 2, y: (CGFloat(side) - size.height) / 2, width: size.width, height: size.height))
            return true
        }
        guard success else { throw PDFWorkspaceError.message("PDF 页面预览无法生成，未能核验页序。") }
        return pixels
    }
}

struct PDFHandoffSnapshot {
    let url: URL
    let sha256: String
    let pageCount: Int
}

extension PDFWorkspaceModel {
    /// Export current in-memory edits to an exclusive, private, new file. This
    /// intentionally does not invoke save(), clear drafts or change dirty state.
    @MainActor func safeHandoffSnapshot(to destination: URL) throws -> PDFHandoffSnapshot {
        func canonicalPath(_ url: URL) -> String {
            url.deletingLastPathComponent().resolvingSymlinksInPath().appendingPathComponent(url.lastPathComponent).standardizedFileURL.path
        }
        guard destination.isFileURL, canonicalPath(destination) != canonicalPath(sourceURL) else {
            throw PDFWorkspaceError.message("交接副本必须使用新路径，不能覆盖原 PDF。")
        }
        guard let document, !document.isLocked, !document.isEncrypted else {
            throw PDFWorkspaceError.message("此 PDF 尚未读取或仍带有加密，不能导出交接副本。")
        }
        pdfView?.window?.makeFirstResponder(nil)
        guard let data = document.dataRepresentation(), data.count <= PDFHandoffVerifier.maximumBytes,
              let validation = PDFDocument(data: data), validation.pageCount == document.pageCount else {
            throw PDFWorkspaceError.message("交接副本生成失败；原件和未保存修改仍保留。")
        }
        let descriptor = Darwin.open(destination.path, O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw PDFWorkspaceError.message("无法新建交接副本，请使用可写目录中的新文件名。") }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        var created = stat()
        _ = Darwin.fstat(descriptor, &created)
        do {
            try handle.write(contentsOf: data)
            try handle.synchronize()
            try handle.seek(toOffset: 0)
            guard try handle.readToEnd() == data else { throw PDFWorkspaceError.message("交接副本摘要核验失败。") }
            try handle.close()
        } catch {
            try? handle.close()
            var current = stat()
            if Darwin.lstat(destination.path, &current) == 0, current.st_dev == created.st_dev, current.st_ino == created.st_ino {
                _ = Darwin.unlink(destination.path)
            }
            throw error
        }
        return PDFHandoffSnapshot(url: destination, sha256: FileSafety.digest(data), pageCount: validation.pageCount)
    }
}
