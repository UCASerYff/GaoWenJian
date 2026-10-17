import AppKit
import PDFKit
import SwiftUI
import CryptoKit
import ImageIO
import CoreText

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
    var isImage: Bool { annotation.type == "Stamp" && annotation.value(forAnnotationKey: GaoPDFImageAnnotation.imageKey) as? String == "1" }
    var canPosition: Bool { isImage || annotation.type == "FreeText" || annotation.type == "Text" }
    var title: String {
        if isImage { return "插入图片" }
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

/// PDFKit serializes this drawing into the stamp's standard PDF appearance stream.
/// The image therefore remains visible in other readers and after undo/recovery reloads.
final class GaoPDFImageAnnotation: PDFAnnotation {
    static let imageKey = PDFAnnotationKey(rawValue: "/GaoWenJianImage")
    private var insertedImage: NSImage?
    private var imageRotation = 0

    init(image: NSImage, bounds: NSRect, rotation: Int, name: String) {
        insertedImage = image
        imageRotation = (rotation % 360 + 360) % 360
        super.init(bounds: bounds, forType: .stamp, withProperties: nil)
        setValue("1", forAnnotationKey: Self.imageKey)
        contents = name
        color = .clear
        shouldPrint = true
        modificationDate = Date()
    }

    required init?(coder: NSCoder) { super.init(coder: coder) }

    override func draw(with box: PDFDisplayBox, in context: CGContext) {
        guard let insertedImage else { super.draw(with: box, in: context); return }
        guard let cgImage = insertedImage.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
        context.saveGState()
        context.translateBy(x: bounds.minX, y: bounds.minY)
        let quarterTurn = imageRotation == 90 || imageRotation == 270
        switch imageRotation {
        case 90: context.translateBy(x: bounds.width, y: 0)
        case 180: context.translateBy(x: bounds.width, y: bounds.height)
        case 270: context.translateBy(x: 0, y: bounds.height)
        default: break
        }
        context.rotate(by: CGFloat(imageRotation) * .pi / 180)
        context.interpolationQuality = .high
        context.draw(cgImage, in: NSRect(x: 0, y: 0,
                                     width: quarterTurn ? bounds.height : bounds.width,
                                     height: quarterTurn ? bounds.width : bounds.height))
        context.restoreGState()
    }
}

/// FreeText stays a standard editable text annotation, with a generated appearance
/// that keeps newly inserted text upright on rotated pages.
final class GaoPDFTextAnnotation: PDFAnnotation {
    static let rotationKey = PDFAnnotationKey(rawValue: "/GaoWenJianTextRotation")
    init(bounds: NSRect, contents: String, font: NSFont, color: NSColor, rotation: Int) {
        super.init(bounds: bounds, forType: .freeText, withProperties: nil)
        self.contents = contents
        self.font = font
        fontColor = color
        self.color = .clear
        shouldPrint = true
        let border = PDFBorder(); border.lineWidth = 0; self.border = border
        setValue(NSNumber(value: rotation), forAnnotationKey: Self.rotationKey)
        updateDefaultAppearance()
        modificationDate = Date()
    }
    required init?(coder: NSCoder) { super.init(coder: coder) }
    func updateDefaultAppearance() {
        guard let font, let rgb = fontColor?.usingColorSpace(.deviceRGB) else { return }
        // A leading space keeps PDFKit from serializing this PDF command string
        // as a /Name instead of a string when the source document was loaded.
        let appearance = String(format: " /%@ %.3f Tf %.6f %.6f %.6f rg", font.fontName, font.pointSize,
                                rgb.redComponent, rgb.greenComponent, rgb.blueComponent)
        setValue(appearance, forAnnotationKey: .defaultAppearance)
    }
    override func draw(with box: PDFDisplayBox, in context: CGContext) {
        let rotation = (value(forAnnotationKey: Self.rotationKey) as? NSNumber)?.intValue ?? 0
        context.saveGState()
        context.translateBy(x: bounds.minX, y: bounds.minY)
        switch rotation {
        case 90: context.translateBy(x: bounds.width, y: 0)
        case 180: context.translateBy(x: bounds.width, y: bounds.height)
        case 270: context.translateBy(x: 0, y: bounds.height)
        default: break
        }
        context.rotate(by: CGFloat(rotation) * .pi / 180)
        let quarterTurn = rotation == 90 || rotation == 270
        let rect = NSRect(x: 0, y: 0, width: quarterTurn ? bounds.height : bounds.width,
                          height: quarterTurn ? bounds.width : bounds.height).insetBy(dx: 4, dy: 4)
        let paragraph = NSMutableParagraphStyle(); paragraph.alignment = alignment
        let text = NSAttributedString(string: contents ?? "", attributes: [.font: font ?? .systemFont(ofSize: 14),
            .foregroundColor: fontColor ?? .black, .paragraphStyle: paragraph])
        Self.drawTextOutlines(text, in: rect, context: context, color: fontColor ?? .black)
        context.restoreGState()
    }

    private static func drawTextOutlines(_ text: NSAttributedString, in rect: CGRect, context: CGContext, color: NSColor) {
        guard rect.width > 0, rect.height > 0 else { return }
        let frame = CTFramesetterCreateFrame(CTFramesetterCreateWithAttributedString(text), CFRange(location: 0, length: 0),
            CGPath(rect: CGRect(origin: .zero, size: rect.size), transform: nil), nil)
        let lines = CTFrameGetLines(frame) as! [CTLine]
        var origins = [CGPoint](repeating: .zero, count: lines.count)
        CTFrameGetLineOrigins(frame, CFRange(location: 0, length: 0), &origins)
        let outlines = CGMutablePath()
        var needsColorGlyphRendering = false
        for (lineIndex, line) in lines.enumerated() {
            for run in CTLineGetGlyphRuns(line) as! [CTRun] {
                let attributes = CTRunGetAttributes(run) as NSDictionary
                guard let runFont = attributes[kCTFontAttributeName] else { continue }
                let ctFont = runFont as! CTFont
                let count = CTRunGetGlyphCount(run)
                var glyphs = [CGGlyph](repeating: 0, count: count)
                var positions = [CGPoint](repeating: .zero, count: count)
                CTRunGetGlyphs(run, CFRange(location: 0, length: 0), &glyphs)
                CTRunGetPositions(run, CFRange(location: 0, length: 0), &positions)
                for index in 0..<count {
                    if let path = CTFontCreatePathForGlyph(ctFont, glyphs[index], nil) {
                        let offset = CGAffineTransform(translationX: origins[lineIndex].x + positions[index].x,
                                                       y: origins[lineIndex].y + positions[index].y)
                        outlines.addPath(path, transform: offset)
                    } else {
                        var glyph = glyphs[index]
                        let box = CTFontGetBoundingRectsForGlyphs(ctFont, .default, &glyph, nil, 1)
                        if box.width > 0 && box.height > 0 { needsColorGlyphRendering = true }
                    }
                }
            }
        }
        context.saveGState()
        context.translateBy(x: rect.minX, y: rect.minY)
        context.clip(to: CGRect(origin: .zero, size: rect.size))
        if needsColorGlyphRendering {
            // Color emoji have bitmap glyphs rather than vector outlines. Render
            // only this annotation to an image; the original PDF stays vector.
            let scale = min(2, 8192 / max(rect.width, rect.height))
            if let bitmap = CGContext(data: nil, width: max(1, Int(ceil(rect.width * scale))),
                                      height: max(1, Int(ceil(rect.height * scale))), bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) {
                bitmap.scaleBy(x: scale, y: scale)
                bitmap.textMatrix = .identity
                CTFrameDraw(frame, bitmap)
                if let image = bitmap.makeImage() { context.draw(image, in: CGRect(origin: .zero, size: rect.size)) }
            }
        } else {
            // PDFKit can remap subset-font glyph indexes when saving an existing
            // page repeatedly. Standard vector paths avoid that remapping while
            // the annotation retains its Unicode contents and editable styling.
            context.setFillColor(color.cgColor)
            context.addPath(outlines)
            context.fillPath()
        }
        context.restoreGState()
    }
}

struct PDFImageAsset {
    let image: NSImage
    let name: String
    var aspectRatio: CGFloat { image.size.height / image.size.width }

    init(url: URL) throws {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        guard data.count <= 64 * 1024 * 1024, let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
              let height = properties[kCGImagePropertyPixelHeight] as? NSNumber,
              width.doubleValue > 0, height.doubleValue > 0,
              width.doubleValue * height.doubleValue <= 80_000_000,
              let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: max(width.intValue, height.intValue)
              ] as CFDictionary) else {
            throw PDFWorkspaceError.message("无法读取图片。请选择不超过 64 MB、8000 万像素的 PNG、JPEG、HEIC 或 TIFF 图片。")
        }
        image = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
        name = url.lastPathComponent
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
    private struct FormValue: Equatable {
        let page: Int
        let index: Int
        let name: String?
        let type: String
        let value: String?
        let state: Int
    }
    private var observedFormValues: [FormValue] = []
    private var observedDocumentData: Data?
    private var formEditGroupActive = false
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
            synchronizeFormBaseline()
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
        try commitDisplayedForm()
        guard let data = document?.dataRepresentation() else {
            throw PDFWorkspaceError.message("无法保留修改前的版本，本次操作已取消。")
        }
        appendUndoState(data)
    }

    private func appendUndoState(_ data: Data) {
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
        synchronizeFormBaseline()
        pdfView?.needsDisplay = true
        publishDirty()
        persistRecovery()
    }

    /// PDFKit has no public form-value-change notification. Compare its actual
    /// widget values, rather than treating a click (or an editor notification) as
    /// a mutation. The canvas polls this inexpensive signature and also checks
    /// after public AppKit editing notifications, including keyboard navigation.
    func formMayHaveChanged(endingEditing: Bool = false) {
        guard permitsForms else { return }
        let values = currentFormValues()
        if values != observedFormValues {
            guard let currentData = document?.dataRepresentation() else {
                dirty = true
                status = "表单已修改，但恢复稿暂未能生成，请及时另存"
                publishDirty()
                return
            }
            if !formEditGroupActive, let previous = observedDocumentData {
                appendUndoState(previous)
            }
            formEditGroupActive = true
            observedFormValues = values
            observedDocumentData = currentData
            dirty = true
            status = "表单修改待保存"
            revision += 1
            refresh()
            publishDirty()
            // Persist each observed value change; a one-shot timer after the
            // initial mouse click misses later typing and Tab-entered fields.
            persistRecovery()
        }
        if endingEditing { formEditGroupActive = false }
    }

    func formInteractionWillBegin() {
        formMayHaveChanged(endingEditing: true)
    }

    /// Saving and handing off are synchronization boundaries. Refusing to end
    /// field editing must stop serialization instead of writing stale contents.
    func commitDisplayedForm() throws {
        if let window = pdfView?.window, !window.makeFirstResponder(nil) {
            throw PDFWorkspaceError.message("当前 PDF 表单仍在编辑且无法提交，请先完成输入后重试。原件与未保存修改仍保留。")
        }
        formMayHaveChanged(endingEditing: true)
    }

    private func currentFormValues() -> [FormValue] {
        guard let document else { return [] }
        return (0..<document.pageCount).flatMap { pageIndex -> [FormValue] in
            guard let page = document.page(at: pageIndex) else { return [] }
            return page.annotations.filter { $0.type == "Widget" }.enumerated().map { index, annotation in
                return FormValue(page: pageIndex, index: index, name: annotation.fieldName,
                    type: annotation.widgetFieldType.rawValue, value: annotation.widgetStringValue,
                    state: annotation.buttonWidgetState.rawValue)
            }
        }
    }

    private func synchronizeFormBaseline() {
        observedFormValues = currentFormValues()
        observedDocumentData = observedFormValues.isEmpty ? nil : document?.dataRepresentation()
        formEditGroupActive = false
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

    func addText(_ text: String, note: Bool, page: PDFPage, at point: NSPoint, fontSize: CGFloat = 14, color: NSColor = .black) throws {
        guard permitsAnnotations, page.document === document else { throw PDFWorkspaceError.message("此 PDF 不允许批注编辑。") }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        guard fontSize.isFinite, fontSize >= 6, fontSize <= 144 else { throw PDFWorkspaceError.message("文字字号需要在 6–144 点之间。") }
        let pageBounds = page.bounds(for: .cropBox)
        let visible = Self.displaySize(of: pageBounds, on: page)
        let width: CGFloat = note ? min(26, visible.width) : min(300, max(1, visible.width - 16))
        let font = Self.textFont(for: text, size: fontSize)
        let measured = (text as NSString).boundingRect(with: NSSize(width: max(1, width - 12), height: 10_000),
                                                       options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: [.font: font]).height
        let height: CGFloat = note ? min(26, visible.height) : min(max(1, visible.height - 16), max(fontSize + 14, ceil(measured) + 16))
        let bounds = try Self.placementBounds(on: page, at: point, displaySize: NSSize(width: width, height: height))
        try remember()
        let annotation = note ? PDFAnnotation(bounds: bounds, forType: .text, withProperties: nil)
            : GaoPDFTextAnnotation(bounds: bounds, contents: text, font: font, color: color, rotation: (page.rotation % 360 + 360) % 360)
        annotation.contents = text
        annotation.modificationDate = Date()
        annotation.shouldPrint = true
        annotation.color = note ? .systemYellow : .clear
        if !note {
            let border = PDFBorder()
            border.lineWidth = 0
            annotation.border = border
            (annotation as? GaoPDFTextAnnotation)?.updateDefaultAppearance()
        }
        page.addAnnotation(annotation)
        pdfView?.annotationsChanged(on: page)
        if !note { try materializeCustomAppearance() }
        noteMutation(note ? "便签已添加 · 待保存" : "文字批注已添加 · 待保存")
    }

    private static func textFont(for text: String, size: CGFloat) -> NSFont {
        let hasCJK = text.unicodeScalars.contains { (0x3400...0x9fff).contains($0.value) || (0x3000...0x30ff).contains($0.value) }
        return NSFont(name: hasCJK ? "PingFangSC-Regular" : "Helvetica", size: size) ?? .systemFont(ofSize: size)
    }

    static func displaySize(of bounds: NSRect, on page: PDFPage) -> NSSize {
        abs(page.rotation % 180) == 90 ? NSSize(width: bounds.height, height: bounds.width) : bounds.size
    }

    /// The pointer is the visible top-left corner. PDFView has already converted it
    /// to unrotated page coordinates; account for rotation before crop-box clamping.
    static func placementBounds(on page: PDFPage, at point: NSPoint, displaySize: NSSize) throws -> NSRect {
        guard point.x.isFinite, point.y.isFinite, displaySize.width.isFinite, displaySize.height.isFinite,
              displaySize.width > 0, displaySize.height > 0 else { throw PDFWorkspaceError.message("对象尺寸或位置无效。") }
        let crop = page.bounds(for: .cropBox)
        guard crop.width > 0, crop.height > 0 else { throw PDFWorkspaceError.message("此页面没有可用的可见区域。") }
        let visible = Self.displaySize(of: crop, on: page)
        let scale = min(1, visible.width / displaySize.width, visible.height / displaySize.height)
        let w = displaySize.width * scale, h = displaySize.height * scale
        let raw: NSRect
        switch (page.rotation % 360 + 360) % 360 {
        case 90: raw = NSRect(x: point.x, y: point.y, width: h, height: w)
        case 180: raw = NSRect(x: point.x - w, y: point.y, width: w, height: h)
        case 270: raw = NSRect(x: point.x - h, y: point.y - w, width: h, height: w)
        default: raw = NSRect(x: point.x, y: point.y - h, width: w, height: h)
        }
        return NSRect(x: min(max(raw.minX, crop.minX), crop.maxX - raw.width),
                      y: min(max(raw.minY, crop.minY), crop.maxY - raw.height), width: raw.width, height: raw.height)
    }

    func addImage(_ asset: PDFImageAsset, page: PDFPage, at point: NSPoint, width: CGFloat) throws {
        guard permitsAnnotations, page.document === document else { throw PDFWorkspaceError.message("此 PDF 不允许插入图片。") }
        let bounds = try Self.placementBounds(on: page, at: point, displaySize: NSSize(width: width, height: width * asset.aspectRatio))
        try remember()
        page.addAnnotation(GaoPDFImageAnnotation(image: asset.image, bounds: bounds, rotation: page.rotation, name: asset.name))
        pdfView?.annotationsChanged(on: page)
        try materializeCustomAppearance()
        noteMutation("图片已插入 · 可在对象侧栏调整位置与尺寸 · 待保存")
    }

    func repositionAnnotation(_ entry: PDFAnnotationEntry, page: PDFPage, at point: NSPoint) throws {
        guard permitsAnnotations, entry.canPosition, let originalPage = entry.annotation.page,
              originalPage === page else { throw PDFWorkspaceError.message("请在该对象所在页面点击新位置。") }
        let size = Self.displaySize(of: entry.annotation.bounds, on: page)
        let bounds = try Self.placementBounds(on: page, at: point, displaySize: size)
        try remember()
        let annotation = editableTextReplacement(entry.annotation, bounds: bounds) ?? entry.annotation
        annotation.bounds = bounds
        entry.annotation.modificationDate = Date()
        pdfView?.annotationsChanged(on: page)
        if annotation is GaoPDFTextAnnotation { try materializeCustomAppearance() }
        noteMutation("对象位置已调整 · 待保存")
    }

    func resizeAnnotation(_ entry: PDFAnnotationEntry, displayWidth: CGFloat, displayHeight: CGFloat) throws {
        guard permitsAnnotations, entry.canPosition, let page = entry.annotation.page,
              displayWidth.isFinite, displayHeight.isFinite, displayWidth >= 4, displayHeight >= 4 else {
            throw PDFWorkspaceError.message("对象尺寸至少为 4 点。")
        }
        let crop = page.bounds(for: .cropBox)
        let available = Self.displaySize(of: crop, on: page)
        guard displayWidth <= available.width, displayHeight <= available.height else {
            throw PDFWorkspaceError.message("对象尺寸不能超过当前页可见区域。")
        }
        let quarterTurn = abs(page.rotation % 180) == 90
        let size = NSSize(width: quarterTurn ? displayHeight : displayWidth, height: quarterTurn ? displayWidth : displayHeight)
        let old = entry.annotation.bounds
        let bounds = NSRect(x: min(max(old.minX, crop.minX), crop.maxX - size.width),
                            y: min(max(old.minY, crop.minY), crop.maxY - size.height), width: size.width, height: size.height)
        try remember()
        // Preserve appearance streams: a saved image is a normal PDF stamp, not an in-memory image view.
        let annotation = editableTextReplacement(entry.annotation, bounds: bounds) ?? entry.annotation
        annotation.bounds = bounds
        if annotation.type == "FreeText" { annotation.removeValue(forAnnotationKey: .appearanceDictionary) }
        entry.annotation.modificationDate = Date()
        pdfView?.annotationsChanged(on: page)
        if annotation is GaoPDFTextAnnotation { try materializeCustomAppearance() }
        noteMutation("对象尺寸已调整 · 待保存")
    }

    private func editableTextReplacement(_ annotation: PDFAnnotation, bounds: NSRect) -> PDFAnnotation? {
        guard annotation.type == "FreeText", let page = annotation.page,
              let rotation = annotation.value(forAnnotationKey: GaoPDFTextAnnotation.rotationKey) as? NSNumber else { return nil }
        let replacement = GaoPDFTextAnnotation(bounds: bounds, contents: annotation.contents ?? "",
            font: annotation.font ?? .systemFont(ofSize: 14), color: annotation.fontColor ?? .black, rotation: rotation.intValue)
        replacement.userName = annotation.userName
        replacement.alignment = annotation.alignment
        page.removeAnnotation(annotation)
        page.addAnnotation(replacement)
        return replacement
    }

    func removeAnnotation(_ entry: PDFAnnotationEntry) throws {
        guard permitsAnnotations else { throw PDFWorkspaceError.message("此 PDF 不允许删除批注。") }
        guard let page = entry.annotation.page else { return }
        try remember()
        page.removeAnnotation(entry.annotation)
        pdfView?.annotationsChanged(on: page)
        noteMutation("批注已删除 · 待保存")
    }

    func updateAnnotation(_ entry: PDFAnnotationEntry, contents: String, fontSize: CGFloat? = nil, color: NSColor? = nil) throws {
        guard permitsAnnotations, entry.annotation.type == "FreeText" || entry.annotation.type == "Text" else { throw PDFWorkspaceError.message("此对象不支持文字编辑。") }
        if let fontSize, (!fontSize.isFinite || fontSize < 6 || fontSize > 144) { throw PDFWorkspaceError.message("文字字号需要在 6–144 点之间。") }
        try remember()
        let annotation = editableTextReplacement(entry.annotation, bounds: entry.annotation.bounds) ?? entry.annotation
        annotation.removeValue(forAnnotationKey: .appearanceDictionary)
        annotation.contents = contents
        if annotation.type == "FreeText" {
            annotation.font = Self.textFont(for: contents, size: fontSize ?? annotation.font?.pointSize ?? 14)
            if let color { annotation.fontColor = color }
        }
        (annotation as? GaoPDFTextAnnotation)?.updateDefaultAppearance()
        annotation.modificationDate = Date()
        if let page = annotation.page { pdfView?.annotationsChanged(on: page) }
        if annotation is GaoPDFTextAnnotation { try materializeCustomAppearance() }
        noteMutation("批注已修改 · 待保存")
    }

    private func materializeCustomAppearance() throws {
        try commitDisplayedForm()
        // Loaded macOS PDFKit pages can retain an empty AnnotationKit drawing cache.
        // Reload the newly written standard appearance before presenting the object.
        guard let data = document?.dataRepresentation(), let normalized = PDFDocument(data: data) else {
            noteMutation("对象已修改，但外观暂未能生成，请及时另存")
            throw PDFWorkspaceError.message("无法生成对象的 PDF 外观，修改仍保留在当前窗口。")
        }
        document = normalized
        refreshViewDocument()
        go(to: currentPage)
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
        try commitDisplayedForm()
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
            synchronizeFormBaseline()
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
        try commitDisplayedForm()
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
        try commitDisplayedForm()
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
