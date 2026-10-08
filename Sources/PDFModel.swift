import AppKit
import PDFKit
import SwiftUI
import CryptoKit

enum PDFWorkspaceError: LocalizedError {
    case message(String)
    var errorDescription: String? {
        switch self { case .message(let text): return text }
    }
}

struct PDFAnnotationEntry: Identifiable {
    let annotation: PDFAnnotation
    let pageIndex: Int
    var id: ObjectIdentifier { ObjectIdentifier(annotation) }
    var title: String {
        switch annotation.type {
        case "Highlight": return "高亮"
        case "Underline": return "下划线"
        case "StrikeOut": return "删除线"
        case "FreeText": return "添加文字"
        case "Text": return "便签"
        case "Ink": return "绘图"
        case "Square": return "矩形"
        case "Circle": return "圆形"
        default: return annotation.type ?? "批注"
        }
    }
}

struct PDFFormEntry: Identifiable {
    let annotation: PDFAnnotation
    let pageIndex: Int
    var id: ObjectIdentifier { ObjectIdentifier(annotation) }
    var title: String { annotation.fieldName ?? "第 \(pageIndex + 1) 页表单" }
    var isButton: Bool { annotation.widgetFieldType == .button }
    var isSignature: Bool { annotation.widgetFieldType.rawValue == "Sig" }
}

/// All editing is applied to PDFKit objects, and serialized as a PDF rather than a visual overlay.
@MainActor
final class PDFWorkspaceModel: ObservableObject {
    @Published var document: PDFDocument?
    @Published var currentPage = 1
    @Published var pageCount = 0
    @Published var zoom: CGFloat = 1
    @Published var dirty = false
    @Published var status = ""
    @Published var loadError: String?
    @Published var annotationEntries: [PDFAnnotationEntry] = []
    @Published var formEntries: [PDFFormEntry] = []
    @Published var hasSelection = false
    @Published var searchResults: [PDFSelection] = []
    @Published var searchResultIndex = 0
    @Published var revision = 0
    @Published var canUndo = false
    @Published var canRedo = false
    @Published var recoveryConflict = false
    let sourceURL: URL
    weak var pdfView: GaoPDFView?
    private var sourceDigest: Data?
    private var undoStates: [Data] = []
    private var redoStates: [Data] = []
    private var hasExternalFormEdits = false
    private var draftGeneration = 0
    private var recoveryIsUnreadable = false

    private var recoveryDirectory: URL {
        let key = FileSafety.digest(Data(sourceURL.standardizedFileURL.path.utf8))
        return FileSafety.root.appendingPathComponent("Recovery/PDF/\(key)", isDirectory: true)
    }

    init(url: URL) {
        sourceURL = url
        do {
            let data = try Data(contentsOf: url)
            guard let loaded = PDFDocument(data: data) else {
                throw PDFWorkspaceError.message("无法读取这个 PDF。原文件已保留。")
            }
            sourceDigest = Self.digest(data)
            document = loaded
            refresh()
            status = loaded.isLocked ? "此文件需要密码才能阅读" : "PDF · 本地文件"
            restoreRecoveryIfPossible()
        } catch { loadError = error.localizedDescription }
    }

    var permitsAnnotations: Bool {
        guard let document else { return false }
        return !document.isLocked && !document.isEncrypted && document.allowsCommenting
    }
    var permitsAssembly: Bool {
        guard let document else { return false }
        return !document.isLocked && !document.isEncrypted && document.allowsDocumentAssembly
    }
    var permitsForms: Bool {
        guard let document else { return false }
        return !document.isLocked && !document.isEncrypted && document.allowsFormFieldEntry
    }
    var containsSignatures: Bool { formEntries.contains(where: { $0.isSignature }) }

    static func digest(_ data: Data) -> Data { Data(SHA256.hash(data: data)) }

    func unlock(password: String) throws {
        guard let document, document.unlock(withPassword: password) else {
            throw PDFWorkspaceError.message("密码不正确，无法打开 PDF。")
        }
        refresh()
        revision += 1
        status = "加密 PDF 已解锁阅读；为保留原有加密设置，此版只读"
    }

    func refresh() {
        guard let document else { return }
        pageCount = document.pageCount
        currentPage = max(1, min(currentPage, max(1, pageCount)))
        var annotations: [PDFAnnotationEntry] = []
        var forms: [PDFFormEntry] = []
        for index in 0..<pageCount {
            guard let page = document.page(at: index) else { continue }
            for annotation in page.annotations {
                if annotation.type == "Widget" {
                    forms.append(PDFFormEntry(annotation: annotation, pageIndex: index))
                } else if annotation.type != "Link" && annotation.type != "Popup" {
                    annotations.append(PDFAnnotationEntry(annotation: annotation, pageIndex: index))
                }
            }
        }
        annotationEntries = annotations
        formEntries = forms
        canUndo = !undoStates.isEmpty
        canRedo = !redoStates.isEmpty
    }

    private func remember() throws {
        guard let data = document?.dataRepresentation() else {
            throw PDFWorkspaceError.message("无法保留修改前的版本，本次操作已取消。")
        }
        undoStates.append(data)
        if undoStates.count > 15 { undoStates.removeFirst() }
        while undoStates.count > 1 && undoStates.reduce(0, { $0 + $1.count }) > 80 * 1024 * 1024 {
            undoStates.removeFirst()
        }
        redoStates.removeAll()
    }

    func noteMutation(_ text: String) {
        dirty = true
        status = text
        revision += 1
        refresh()
        pdfView?.needsDisplay = true
        publishDirty()
        persistRecovery()
    }

    func formMayHaveChanged() {
        guard permitsForms else { return }
        hasExternalFormEdits = true
        dirty = true
        status = "表单修改待保存"
        publishDirty()
        draftGeneration += 1
        let generation = draftGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self, self.draftGeneration == generation else { return }
            self.persistRecovery()
        }
    }

    func go(to page: Int) {
        guard let document, page >= 1, page <= document.pageCount,
              let target = document.page(at: page - 1) else { return }
        currentPage = page
        pdfView?.go(to: target)
    }

    func find(_ query: String) {
        guard let document, !document.isLocked else { return }
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if query.isEmpty {
            searchResults = []
            pdfView?.highlightedSelections = nil
            status = "搜索已清除"
            return
        }
        searchResults = document.findString(query, withOptions: .caseInsensitive)
        searchResultIndex = 0
        for match in searchResults { match.color = NSColor.systemYellow.withAlphaComponent(0.35) }
        pdfView?.highlightedSelections = searchResults
        if !searchResults.isEmpty { showSearchResult(0) }
        else { status = "未找到“\(query)”；扫描页面不提供文字识别" }
    }

    func showSearchResult(_ index: Int) {
        guard !searchResults.isEmpty else { return }
        searchResultIndex = (index + searchResults.count) % searchResults.count
        let selection = searchResults[searchResultIndex]
        pdfView?.setCurrentSelection(selection, animate: true)
        pdfView?.go(to: selection)
        status = "找到 \(searchResults.count) 处 · \(searchResultIndex + 1)/\(searchResults.count)"
    }

    func markupSelection(type: PDFAnnotationSubtype) throws {
        guard permitsAnnotations else { throw PDFWorkspaceError.message("此 PDF 不允许批注编辑。") }
        guard let selection = pdfView?.currentSelection,
              !(selection.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw PDFWorkspaceError.message("请先在 PDF 中选中文字，再添加批注。")
        }
        try markup(selection: selection, type: type)
    }

    func markup(selection: PDFSelection, type: PDFAnnotationSubtype) throws {
        guard permitsAnnotations else { throw PDFWorkspaceError.message("此 PDF 不允许批注编辑。") }
        let lines = selection.selectionsByLine()
        guard !lines.isEmpty else { throw PDFWorkspaceError.message("选区不包含可批注的文字。") }
        try remember()
        for line in lines {
            for page in line.pages {
                let bounds = line.bounds(for: page)
                guard bounds.width > 0, bounds.height > 0 else { continue }
                let annotation = PDFAnnotation(bounds: bounds, forType: type, withProperties: nil)
                annotation.color = type == .highlight ? NSColor.systemYellow.withAlphaComponent(0.5) : NSColor.systemRed
                annotation.contents = line.string
                annotation.modificationDate = Date()
                annotation.shouldPrint = true
                // PDFKit expects QuadPoints relative to the annotation bounds origin.
                annotation.quadrilateralPoints = [
                    NSValue(point: NSPoint(x: 0, y: bounds.height)),
                    NSValue(point: NSPoint(x: bounds.width, y: bounds.height)),
                    NSValue(point: NSPoint(x: 0, y: 0)),
                    NSValue(point: NSPoint(x: bounds.width, y: 0))
                ]
                page.addAnnotation(annotation)
                pdfView?.annotationsChanged(on: page)
            }
        }
        pdfView?.clearSelection()
        noteMutation("文字批注已添加 · 待保存")
    }

    func addText(_ text: String, note: Bool, page: PDFPage, at point: NSPoint, fontSize: CGFloat = 14) throws {
        guard permitsAnnotations else { throw PDFWorkspaceError.message("此 PDF 不允许批注编辑。") }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        try remember()
        let pageBounds = page.bounds(for: .cropBox)
        let width: CGFloat = note ? 26 : min(300, max(80, pageBounds.width - 40))
        let height: CGFloat = note ? 26 : max(52, min(180, CGFloat(text.components(separatedBy: "\n").count) * (fontSize + 5) + 16))
        let x = max(pageBounds.minX + 8, min(point.x, pageBounds.maxX - width - 8))
        let y = max(pageBounds.minY + 8, min(point.y - height, pageBounds.maxY - height - 8))
        let annotation = PDFAnnotation(bounds: NSRect(x: x, y: y, width: width, height: height),
                                       forType: note ? .text : .freeText, withProperties: nil)
        annotation.contents = text
        annotation.modificationDate = Date()
        annotation.shouldPrint = true
        annotation.color = note ? .systemYellow : .clear
        if !note {
            let hasCJK = text.unicodeScalars.contains { scalar in
                (0x3400...0x9fff).contains(scalar.value) || (0x3000...0x30ff).contains(scalar.value)
            }
            annotation.font = NSFont(name: hasCJK ? "PingFangSC-Regular" : "Helvetica", size: fontSize) ?? .systemFont(ofSize: fontSize)
            annotation.fontColor = .black
            let border = PDFBorder()
            border.lineWidth = 0
            annotation.border = border
        }
        page.addAnnotation(annotation)
        pdfView?.annotationsChanged(on: page)
        noteMutation(note ? "便签已添加 · 待保存" : "文字批注已添加 · 待保存")
    }

    func removeAnnotation(_ entry: PDFAnnotationEntry) throws {
        guard permitsAnnotations else { throw PDFWorkspaceError.message("此 PDF 不允许删除批注。") }
        guard let page = entry.annotation.page else { return }
        try remember()
        page.removeAnnotation(entry.annotation)
        pdfView?.annotationsChanged(on: page)
        noteMutation("批注已删除 · 待保存")
    }

    func updateAnnotation(_ entry: PDFAnnotationEntry, contents: String) throws {
        guard permitsAnnotations else { throw PDFWorkspaceError.message("此 PDF 不允许修改批注。") }
        try remember()
        entry.annotation.removeValue(forAnnotationKey: .appearanceDictionary)
        entry.annotation.contents = contents
        entry.annotation.modificationDate = Date()
        if let page = entry.annotation.page { pdfView?.annotationsChanged(on: page) }
        noteMutation("批注已修改 · 待保存")
    }

    func setForm(_ entry: PDFFormEntry, text: String? = nil, checked: Bool? = nil) throws {
        guard permitsForms, !entry.annotation.isReadOnly, !entry.isSignature else {
            throw PDFWorkspaceError.message("该表单字段不可编辑。数字签名不在此处处理。")
        }
        try remember()
        if let checked { entry.annotation.buttonWidgetState = checked ? .onState : .offState }
        else if let text { entry.annotation.widgetStringValue = text }
        if let page = entry.annotation.page { pdfView?.annotationsChanged(on: page) }
        noteMutation("表单已填写 · 待保存")
    }

    func rotateCurrentPage() throws {
        guard permitsAssembly, let page = document?.page(at: currentPage - 1) else {
            throw PDFWorkspaceError.message("此 PDF 不允许调整页面。")
        }
        try remember()
        page.rotation = (page.rotation + 90) % 360
        pdfView?.layoutDocumentView()
        noteMutation("第 \(currentPage) 页已旋转 · 待保存")
    }

    func cropCurrentPage(top: CGFloat, left: CGFloat, bottom: CGFloat, right: CGFloat) throws {
        guard permitsAssembly, let page = document?.page(at: currentPage - 1) else {
            throw PDFWorkspaceError.message("此 PDF 不允许调整页面。")
        }
        let box = page.bounds(for: .cropBox)
        guard top >= 0, left >= 0, bottom >= 0, right >= 0,
              top + bottom < box.height - 20, left + right < box.width - 20 else {
            throw PDFWorkspaceError.message("裁剪边距无效，必须至少保留 20 × 20 点的可见区域。")
        }
        try remember()
        page.setBounds(NSRect(x: box.minX + left, y: box.minY + bottom,
                              width: box.width - left - right, height: box.height - top - bottom), for: .cropBox)
        pdfView?.layoutDocumentView()
        noteMutation("第 \(currentPage) 页可见区域已裁剪 · 待保存")
    }

    func deleteCurrentPage() throws {
        guard permitsAssembly, let document else { throw PDFWorkspaceError.message("此 PDF 不允许调整页面。") }
        guard document.pageCount > 1 else { throw PDFWorkspaceError.message("至少需要保留一页。") }
        try remember()
        let index = currentPage - 1
        document.removePage(at: index)
        currentPage = min(currentPage, document.pageCount)
        refreshViewDocument()
        noteMutation("页面已删除 · 待保存")
        go(to: currentPage)
    }

    func moveCurrentPage(by offset: Int) throws {
        guard permitsAssembly, let document else { throw PDFWorkspaceError.message("此 PDF 不允许调整页面。") }
        let index = currentPage - 1
        let destination = index + offset
        guard destination >= 0, destination < document.pageCount else { return }
        try remember()
        document.exchangePage(at: index, withPageAt: destination)
        currentPage = destination + 1
        refreshViewDocument()
        noteMutation("页面顺序已调整 · 待保存")
        go(to: currentPage)
    }

    func appendPDFs(_ urls: [URL]) throws {
        guard permitsAssembly, let document else { throw PDFWorkspaceError.message("此 PDF 不允许合并页面。") }
        var copiedPages: [PDFPage] = []
        for url in urls {
            guard let other = PDFDocument(url: url), !other.isLocked, other.allowsDocumentAssembly, !other.isEncrypted else {
                throw PDFWorkspaceError.message("无法合并 \(url.lastPathComponent)：文件无法读取、受保护或为加密文件。原文件未修改。")
            }
            for index in 0..<other.pageCount {
                guard let copy = other.page(at: index)?.copy() as? PDFPage else {
                    throw PDFWorkspaceError.message("无法复制 \(url.lastPathComponent) 的第 \(index + 1) 页。")
                }
                copiedPages.append(copy)
            }
        }
        guard !copiedPages.isEmpty else { return }
        try remember()
        for page in copiedPages { document.insert(page, at: document.pageCount) }
        refreshViewDocument()
        noteMutation("已追加 \(copiedPages.count) 页 · 待保存")
    }

    static func parsePages(_ expression: String, count: Int) throws -> [Int] {
        var result: [Int] = []
        let normalized = expression.replacingOccurrences(of: "，", with: ",").replacingOccurrences(of: "–", with: "-")
        for piece in normalized.split(separator: ",", omittingEmptySubsequences: false) {
            let token = piece.trimmingCharacters(in: .whitespaces)
            let bounds = token.split(separator: "-", omittingEmptySubsequences: false)
            guard bounds.count <= 2, let start = Int(bounds[0].trimmingCharacters(in: .whitespaces)), start >= 1, start <= count else {
                throw PDFWorkspaceError.message("页码格式无效，请输入 1,3-5 这样的页码，范围为 1–\(count)。")
            }
            let end: Int
            if bounds.count == 2 {
                guard let last = Int(bounds[1].trimmingCharacters(in: .whitespaces)), last >= start, last <= count else {
                    throw PDFWorkspaceError.message("页面范围无效，请使用递增页码且不超过 \(count)。")
                }
                end = last
            } else { end = start }
            for page in start...end where !result.contains(page - 1) { result.append(page - 1) }
        }
        guard !result.isEmpty else { throw PDFWorkspaceError.message("请输入至少一个页码。") }
        return result
    }

    func extractedDocument(pages: [Int]) throws -> PDFDocument {
        guard let document, !document.isLocked, document.allowsCopying, !document.isEncrypted else {
            throw PDFWorkspaceError.message("此 PDF 不允许提取页面。")
        }
        let output = PDFDocument()
        for index in pages {
            guard index >= 0, index < document.pageCount, let copy = document.page(at: index)?.copy() as? PDFPage else {
                throw PDFWorkspaceError.message("无法提取指定页面。")
            }
            output.insert(copy, at: output.pageCount)
        }
        guard output.pageCount > 0 else { throw PDFWorkspaceError.message("请选择至少一页。") }
        return output
    }

    func save(to destination: URL? = nil) throws -> URL {
        guard let document, !document.isLocked else { throw PDFWorkspaceError.message("PDF 尚未成功读取。") }
        guard !document.isEncrypted else { throw PDFWorkspaceError.message("此版对加密 PDF 提供只读阅读，以保留原有加密设置。") }
        pdfView?.window?.makeFirstResponder(nil) // Commit any currently edited form field before serialization.
        guard let data = document.dataRepresentation(), let validation = PDFDocument(data: data), validation.pageCount == document.pageCount else {
            throw PDFWorkspaceError.message("PDF 序列化或完整性检查失败，原文件未改动。")
        }
        let target = destination ?? sourceURL
        if target.standardizedFileURL == sourceURL.standardizedFileURL,
           !FileManager.default.fileExists(atPath: target.path) {
            throw PDFWorkspaceError.message("原 PDF 已被移动或删除，请另存新文件。")
        }
        if FileManager.default.fileExists(atPath: target.path) {
            if target.standardizedFileURL == sourceURL.standardizedFileURL {
                let current = try Data(contentsOf: target)
                guard Self.digest(current) == sourceDigest else {
                    throw PDFWorkspaceError.message("原 PDF 已被其他程序修改。为避免覆盖，请另存新文件或重新打开。")
                }
            }
            _ = try FileSafety.snapshot(url: target)
        }
        try data.write(to: target, options: .atomic)
        let written = try Data(contentsOf: target)
        guard written == data else { throw PDFWorkspaceError.message("写入后的文件校验失败；原件快照已保留。") }
        if target.standardizedFileURL == sourceURL.standardizedFileURL {
            sourceDigest = Self.digest(written)
            dirty = false
            hasExternalFormEdits = false
            clearRecoveryAfterSave()
            publishDirty()
        }
        status = target.standardizedFileURL == sourceURL.standardizedFileURL ? "已保存 \(target.lastPathComponent)" : "已另存 \(target.lastPathComponent)\(dirty ? " · 原件仍有未保存修改" : "")"
        return target
    }

    func publishDirty() {
        NotificationCenter.default.post(name: Notification.Name("GaoWenJian.moduleDirty"), object: sourceURL.path, userInfo: ["dirty": dirty])
    }

    func discardDraft() {
        draftGeneration += 1
        dirty = false
        clearRecoveryAfterSave()
        publishDirty()
    }

    private func restoreRecoveryIfPossible() {
        let metadataURL = recoveryDirectory.appendingPathComponent("origin.json")
        let pdfURL = recoveryDirectory.appendingPathComponent("draft.pdf")
        guard FileManager.default.fileExists(atPath: metadataURL.path) || FileManager.default.fileExists(atPath: pdfURL.path) else { return }
        do {
            let data = try Data(contentsOf: pdfURL)
            let metadataData = try Data(contentsOf: metadataURL)
            guard let metadata = try JSONSerialization.jsonObject(with: metadataData) as? [String: String],
                  let digest = metadata["digest"], let originalDigest = sourceDigest,
                  let recovered = PDFDocument(data: data), recovered.pageCount > 0 else {
                throw PDFWorkspaceError.message("恢复资料不完整")
            }
            let expected = originalDigest.map { String(format: "%02x", $0) }.joined()
            guard digest == expected else {
                recoveryConflict = true
                status = "原文件已变化；旧恢复草稿已保留，可另存恢复副本"
                return
            }
            document = recovered
            dirty = true
            refresh()
            status = "已恢复上次未保存的 PDF 修改 · 请检查后保存"
            publishDirty()
        } catch {
            recoveryIsUnreadable = true
            status = "恢复草稿无法读取，原件及恢复资料已保留"
        }
    }

    func recoveredDocumentForExport() throws -> PDFDocument {
        let data = try Data(contentsOf: recoveryDirectory.appendingPathComponent("draft.pdf"))
        guard let recovered = PDFDocument(data: data), recovered.pageCount > 0 else {
            throw PDFWorkspaceError.message("恢复草稿无法读取，恢复资料已保留。")
        }
        return recovered
    }

    private func persistRecovery() {
        guard dirty, !recoveryConflict, !recoveryIsUnreadable,
              let data = document?.dataRepresentation(), let sourceDigest else { return }
        do {
            try FileManager.default.createDirectory(at: recoveryDirectory, withIntermediateDirectories: true)
            // Write the PDF first; an interrupted write never replaces the original PDF.
            try data.write(to: recoveryDirectory.appendingPathComponent("draft.pdf"), options: .atomic)
            let metadata = ["path": sourceURL.path, "digest": sourceDigest.map { String(format: "%02x", $0) }.joined()]
            let metadataData = try JSONSerialization.data(withJSONObject: metadata, options: .sortedKeys)
            try metadataData.write(to: recoveryDirectory.appendingPathComponent("origin.json"), options: .atomic)
        } catch { status += " · 恢复草稿未能写入，请及时保存" }
    }

    private func clearRecoveryAfterSave() {
        guard !recoveryConflict, !recoveryIsUnreadable else { return }
        if FileManager.default.fileExists(atPath: recoveryDirectory.path) {
            do { try FileManager.default.removeItem(at: recoveryDirectory) }
            catch { status = "PDF 已保存；旧恢复草稿保留在本地" }
        }
    }

    func export(_ output: PDFDocument, to target: URL) throws {
        guard target.standardizedFileURL != sourceURL.standardizedFileURL else {
            throw PDFWorkspaceError.message("页面导出请另存新文件，以保留原件。")
        }
        guard let data = output.dataRepresentation(), let validation = PDFDocument(data: data), validation.pageCount == output.pageCount else {
            throw PDFWorkspaceError.message("无法生成有效 PDF，操作已取消。")
        }
        if FileManager.default.fileExists(atPath: target.path) { _ = try FileSafety.snapshot(url: target) }
        try data.write(to: target, options: .atomic)
        status = "已导出 \(target.lastPathComponent)"
    }

    private func refreshViewDocument() {
        pdfView?.document = nil
        pdfView?.document = document
        searchResults = []
        pdfView?.highlightedSelections = nil
    }

    func undo() throws {
        guard let data = undoStates.last, let restored = PDFDocument(data: data),
              let current = document?.dataRepresentation() else { return }
        redoStates.append(current)
        undoStates.removeLast()
        document = restored
        refreshViewDocument()
        noteMutation("已撤销 · 待保存")
        go(to: currentPage)
    }

    func redo() throws {
        guard let data = redoStates.last, let restored = PDFDocument(data: data),
              let current = document?.dataRepresentation() else { return }
        undoStates.append(current)
        redoStates.removeLast()
        document = restored
        refreshViewDocument()
        noteMutation("已重做 · 待保存")
        go(to: currentPage)
    }
}
