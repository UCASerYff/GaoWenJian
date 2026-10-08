import AppKit
import PDFKit
import CoreText

enum PDFModuleTests {
    @MainActor static func run(in folder: URL) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let originalURL = folder.appendingPathComponent("pdf-module-original.pdf")
        try makeFixture().write(to: originalURL)
        let originalBytes = try Data(contentsOf: originalURL)
        let model = PDFWorkspaceModel(url: originalURL)
        try require(model.pageCount == 3, "PDF load: three pages")
        try require(model.permitsAnnotations && model.permitsAssembly && model.permitsForms, "PDF permissions")
        guard let document = model.document, let first = document.page(at: 0), let second = document.page(at: 1),
              let selection = document.findString("Hello", withOptions: []).first else {
            throw PDFWorkspaceError.message("PDF test: missing document/text")
        }
        try model.markup(selection: selection, type: .highlight)
        let highlight = first.annotations.first { $0.type == "Highlight" }
        try require(highlight?.quadrilateralPoints?.count == 4, "Highlight QuadPoints")
        let highlightBox = highlight?.bounds ?? .zero
        try require(highlightBox.width > 10 && highlightBox.minY > 100, "Highlight aligns with source text")
        try model.addText("Visible local text", note: false, page: first, at: NSPoint(x: 30, y: 300))
        try model.addText("Local note", note: true, page: second, at: NSPoint(x: 70, y: 350))
        guard let form = model.formEntries.first(where: { $0.title == "Author" }) else {
            throw PDFWorkspaceError.message("PDF test: missing form")
        }
        try model.setForm(form, text: "Gao Files")
        try model.rotateCurrentPage()
        try require(first.rotation == 90, "Rotate page")
        try model.undo()
        try require(model.document?.page(at: 0)?.rotation == 0, "Undo rotation")
        try model.redo()
        try require(model.document?.page(at: 0)?.rotation == 90, "Redo rotation")
        let beforeCrop = model.document?.page(at: 0)?.bounds(for: .cropBox) ?? .zero
        try model.cropCurrentPage(top: 10, left: 20, bottom: 10, right: 20)
        let afterCrop = model.document?.page(at: 0)?.bounds(for: .cropBox) ?? .zero
        try require(afterCrop.width == beforeCrop.width - 40 && afterCrop.height == beforeCrop.height - 20, "Crop changes visible box")
        try model.undo()

        // Recovery uses an isolated data directory supplied by the test runner.
        let recovered = PDFWorkspaceModel(url: originalURL)
        try require(recovered.dirty, "Crash recovery restores dirty PDF")
        try require(recovered.document?.page(at: 0)?.annotations.contains(where: { $0.contents == "Visible local text" }) == true, "Crash recovery preserves text annotation")
        _ = try model.save()
        let reopened = PDFDocument(url: originalURL)
        try require(reopened?.pageCount == 3, "Saved PDF reopens")
        try require(reopened?.page(at: 0)?.rotation == 90, "Saved rotation persists")
        try require(reopened?.page(at: 0)?.annotations.contains(where: { $0.type == "Highlight" }) == true, "Highlight persists")
        try require(reopened?.page(at: 0)?.annotations.contains(where: { $0.contents == "Visible local text" }) == true, "FreeText persists")
        try require(reopened?.page(at: 1)?.annotations.contains(where: { $0.contents == "Local note" }) == true, "Note persists")
        try require(reopened?.page(at: 1)?.annotations.first(where: { $0.fieldName == "Author" })?.widgetStringValue == "Gao Files", "Form value persists")
        let backups = try FileSafety.snapshots(for: originalURL)
        try require(!backups.isEmpty && (try Data(contentsOf: backups[0])) == originalBytes, "Overwrite original backup is byte exact")
        try require(!PDFWorkspaceModel(url: originalURL).dirty, "Saved recovery draft cleared")

        try require(try PDFWorkspaceModel.parsePages("1, 3-3,1", count: 3) == [0, 2], "Page expression and deduplication")
        try requireThrows("Reject invalid range") { _ = try PDFWorkspaceModel.parsePages("0,4", count: 3) }
        try requireThrows("Reject empty range") { _ = try PDFWorkspaceModel.parsePages("", count: 3) }
        let extraction = try model.extractedDocument(pages: [2, 0])
        let extractedURL = folder.appendingPathComponent("pdf-module-extracted.pdf")
        try model.export(extraction, to: extractedURL)
        try require(PDFDocument(url: extractedURL)?.pageCount == 2, "Extracted PDF page count")
        try require(PDFDocument(url: extractedURL)?.page(at: 0)?.string?.contains("Page 3") == true, "Extract page order")
        try model.appendPDFs([extractedURL])
        try require(model.pageCount == 5, "Merge PDF appends real pages")
        model.go(to: 1)
        try model.moveCurrentPage(by: 1)
        try require(model.document?.page(at: 0)?.string?.contains("Page 2") == true, "Page reorder")
        try model.deleteCurrentPage()
        try require(model.pageCount == 4, "Delete real page")

        // A concurrent edit must not be replaced by the stale in-memory PDF.
        var external = try Data(contentsOf: originalURL)
        external.append(Data("\n% external modification\n".utf8))
        try external.write(to: originalURL, options: .atomic)
        try requireThrows("Detect external changes") { _ = try model.save() }
        try require(try Data(contentsOf: originalURL) == external, "Preserve external changes")
        let conflict = PDFWorkspaceModel(url: originalURL)
        try require(conflict.recoveryConflict, "Conflicting recovery is not applied over external file")
        print("PDF: load, selection markup, free text, notes, form persistence, undo/redo, rotation, crop, recovery, byte-exact backup, extraction, merge, ordering, delete and external change protection passed")
    }

    static func makeFixture() throws -> Data {
        let buffer = NSMutableData()
        guard let consumer = CGDataConsumer(data: buffer), let context = CGContext(consumer: consumer, mediaBox: nil, nil) else {
            throw PDFWorkspaceError.message("Cannot create test PDF")
        }
        var bounds = CGRect(x: 0, y: 0, width: 400, height: 500)
        let boundsData = NSData(bytes: &bounds, length: MemoryLayout<CGRect>.size)
        for index in 1...3 {
            context.beginPDFPage([kCGPDFContextMediaBox as String: boundsData] as CFDictionary)
            context.setFillColor(NSColor.black.cgColor)
            context.textPosition = CGPoint(x: 30, y: 420)
            let attributes: [NSAttributedString.Key: Any] = [NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateWithName("Helvetica" as CFString, 20, nil)]
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: "Page \(index) Hello GaoFiles", attributes: attributes))
            CTLineDraw(line, context)
            context.endPDFPage()
        }
        context.closePDF()
        guard let document = PDFDocument(data: buffer as Data), let page = document.page(at: 1) else {
            throw PDFWorkspaceError.message("Cannot parse test fixture")
        }
        let widget = PDFAnnotation(bounds: NSRect(x: 30, y: 350, width: 200, height: 28), forType: .widget, withProperties: nil)
        widget.widgetFieldType = .text
        widget.fieldName = "Author"
        widget.widgetStringValue = "Original"
        widget.font = NSFont(name: "Helvetica", size: 14)
        page.addAnnotation(widget)
        guard let data = document.dataRepresentation() else { throw PDFWorkspaceError.message("Cannot serialize fixture") }
        return data
    }

    private static func require(_ value: @autoclosure () throws -> Bool, _ label: String) throws {
        guard try value() else { throw PDFWorkspaceError.message("PDF test failed: \(label)") }
    }
    private static func requireThrows(_ label: String, _ operation: () throws -> Void) throws {
        do { try operation() } catch { return }
        throw PDFWorkspaceError.message("PDF test failed: \(label)")
    }
}
