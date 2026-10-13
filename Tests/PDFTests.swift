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
        guard let document = model.document, let first = document.page(at: 0),
              let selection = document.findString("Hello", withOptions: []).first else {
            throw PDFWorkspaceError.message("PDF test: missing document/text")
        }
        try model.markup(selection: selection, type: .highlight)
        let highlight = first.annotations.first { $0.type == "Highlight" }
        try require(highlight?.quadrilateralPoints?.count == 4, "Highlight QuadPoints")
        let highlightBox = highlight?.bounds ?? .zero
        try require(highlightBox.width > 10 && highlightBox.minY > 100, "Highlight aligns with source text")
        try model.addText("Visible local text", note: false, page: first, at: NSPoint(x: 30, y: 300))
        try model.addText("Local note", note: true, page: model.document!.page(at: 1)!, at: NSPoint(x: 70, y: 350))
        guard let form = model.formEntries.first(where: { $0.title == "Author" }) else {
            throw PDFWorkspaceError.message("PDF test: missing form")
        }
        try model.setForm(form, text: "Gao Files")
        try model.rotateCurrentPage()
        try require(model.document?.page(at: 0)?.rotation == 90, "Rotate page")
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
        try imageEditingTests(in: folder)
        try textAppearanceTests(in: folder)
        print("PDF: load, selection markup, free text, notes, form persistence, undo/redo, rotation, crop, recovery, byte-exact backup, extraction, merge, ordering, delete and external change protection passed")
    }

    @MainActor private static func imageEditingTests(in folder: URL) throws {
        let imageURL = folder.appendingPathComponent("insert-image.png")
        let image = NSImage(size: NSSize(width: 100, height: 60), flipped: false) { rect in
            NSColor.red.setFill(); NSRect(x: 0, y: 0, width: 50, height: 60).fill()
            NSColor.blue.setFill(); NSRect(x: 50, y: 0, width: 50, height: 60).fill()
            NSColor.green.setFill(); NSRect(x: 0, y: 45, width: 100, height: 15).fill()
            return true
        }
        guard let tiff = image.tiffRepresentation, let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else {
            throw PDFWorkspaceError.message("Cannot create image fixture")
        }
        try png.write(to: imageURL)
        let asset = try PDFImageAsset(url: imageURL)
        for rotation in [0, 90, 180, 270] {
            let sourceURL = folder.appendingPathComponent("image-rotation-\(rotation).pdf")
            let source = PDFDocument(data: try makeFixture())!
            source.page(at: 0)!.rotation = rotation
            source.page(at: 0)!.setBounds(NSRect(x: 30, y: 40, width: 320, height: 420), for: .cropBox)
            let original = source.dataRepresentation()!
            try original.write(to: sourceURL)
            let model = PDFWorkspaceModel(url: sourceURL)
            let first = model.document!.page(at: 0)!
            let crop = first.bounds(for: .cropBox)
            try model.addImage(asset, page: first, at: NSPoint(x: crop.maxX - 2, y: crop.maxY - 2), width: 120)
            try require(model.annotationEntries.filter(\.isImage).count == 1, "Image listed as editable object")
            try require(crop.contains(model.annotationEntries.first(where: \.isImage)!.annotation.bounds), "Image fits nonzero crop and rotated page")
            try requireImageRendering(model.document!, "Live image at rotation \(rotation)")
            let recovered = PDFWorkspaceModel(url: sourceURL)
            try require(recovered.dirty, "Image draft recovered")
            try requireImageRendering(recovered.document!, "Recovered image at rotation \(rotation)")
            try model.undo()
            try require(!model.annotationEntries.contains(where: \.isImage), "Undo removes image")
            try model.redo()
            try requireImageRendering(model.document!, "Redo restores image appearance")
            let restoredPage = model.document!.page(at: 0)!
            let entry = model.annotationEntries.first(where: \.isImage)!
            try model.repositionAnnotation(entry, page: restoredPage, at: NSPoint(x: crop.midX, y: crop.midY))
            try model.resizeAnnotation(entry, displayWidth: 80, displayHeight: 48)
            try requireImageRendering(model.document!, "Saved stamp appearance survives move/resize")
            try requireThrows("Reject off-page resizing") { try model.resizeAnnotation(entry, displayWidth: 1000, displayHeight: 600) }
            try require(restoredPage.string?.contains("Hello") == true, "Inserting image preserves original searchable text")
            try model.addText("插入文字测试", note: false, page: model.document!.page(at: 2)!, at: NSPoint(x: 30, y: 300), fontSize: 18, color: .systemBlue)
            let textEntry = model.annotationEntries.first(where: { $0.annotation.contents == "插入文字测试" })!
            try model.updateAnnotation(textEntry, contents: "更新中文文字", fontSize: 22, color: .systemRed)
            _ = try model.save()
            let reopened = PDFDocument(url: sourceURL)!
            try requireImageRendering(reopened, "Saved and reopened image at rotation \(rotation)")
            let annotation = reopened.page(at: 2)!.annotations.first(where: { $0.contents == "更新中文文字" })!
            try require(annotation.font?.pointSize == 22, "Edited font size survives saving")
            try require(annotation.fontColor?.usingColorSpace(.deviceRGB)?.redComponent ?? 0 > 0.6, "Edited text color survives saving")
            try require(reopened.page(at: 1)!.annotations.contains(where: { $0.fieldName == "Author" }), "Image insertion preserves unrelated form")
            try require((try FileSafety.snapshots(for: sourceURL)).contains(where: { (try? Data(contentsOf: $0)) == original }), "Image save keeps byte-exact original")
            let extracted = try model.extractedDocument(pages: [0])
            let extractedBytes = extracted.dataRepresentation()!
            try requireImageRendering(PDFDocument(data: extractedBytes)!, "Extracted image appearance persists")
            let savedModel = PDFWorkspaceModel(url: sourceURL)
            let savedEntry = savedModel.annotationEntries.first(where: \.isImage)!
            try savedModel.removeAnnotation(savedEntry)
            try require(!savedModel.annotationEntries.contains(where: \.isImage), "Reopened image can be deleted")
            try savedModel.undo()
            try requireImageRendering(savedModel.document!, "Undo image delete restores appearance")
            savedModel.discardDraft()
        }
        print("PDF image editing: PNG embed, rendered appearance after save/reopen, undo/redo/recovery/extraction, four rotations, nonzero crop, move/resize/delete, text size/color and exact backups passed")
    }

    private static func requireImageRendering(_ document: PDFDocument, _ label: String) throws {
        guard let page = document.page(at: 0),
              let tiff = page.thumbnail(of: NSSize(width: 500, height: 500), for: .cropBox).tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff) else { throw PDFWorkspaceError.message("Cannot render PDF image test") }
        var red = (count: 0, x: 0.0, y: 0.0), blue = red, green = red
        for y in stride(from: 0, to: bitmap.pixelsHigh, by: 2) {
            for x in stride(from: 0, to: bitmap.pixelsWide, by: 2) {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                if color.redComponent > 0.75 && color.blueComponent < 0.4 && color.greenComponent < 0.4 {
                    red.count += 1; red.x += Double(x); red.y += Double(y)
                } else if color.blueComponent > 0.75 && color.redComponent < 0.4 && color.greenComponent < 0.4 {
                    blue.count += 1; blue.x += Double(x); blue.y += Double(y)
                } else if color.greenComponent > 0.75 && ((color.redComponent < 0.4 && color.blueComponent < 0.4) || (color.greenComponent - max(color.redComponent, color.blueComponent) >= 0.15)) {
                    green.count += 1; green.x += Double(x); green.y += Double(y)
                }
            }
        }
        try require(red.count > 50 && blue.count > 50 && green.count > 20, label + " has all image colors")
        try require(red.x / Double(red.count) < blue.x / Double(blue.count), label + " is upright horizontally")
        try require(green.y / Double(green.count) < red.y / Double(red.count), label + " is upright vertically")
    }

    @MainActor private static func textAppearanceTests(in folder: URL) throws {
        let phrase = "搞文件 PDF 插入文字验证"
        let asset = try PDFImageAsset(url: folder.appendingPathComponent("insert-image.png"))
        for rotation in [0, 90, 180, 270] {
            let url = folder.appendingPathComponent("text-glyphs-\(rotation).pdf")
            let initial = PDFDocument(data: try makeFixture())!
            let page = initial.page(at: 0)!
            page.rotation = rotation
            page.setBounds(NSRect(x: 30, y: 40, width: 320, height: 420), for: .cropBox)
            try initial.dataRepresentation()!.write(to: url)
            var model = PDFWorkspaceModel(url: url)
            func pointer(_ page: PDFPage, x: CGFloat, y: CGFloat) -> CGPoint {
                let box = page.bounds(for: .cropBox)
                switch rotation {
                case 90: return CGPoint(x: box.minX + y, y: box.minY + x)
                case 180: return CGPoint(x: box.maxX - x, y: box.minY + y)
                case 270: return CGPoint(x: box.maxX - y, y: box.maxY - x)
                default: return CGPoint(x: box.minX + x, y: box.maxY - y)
                }
            }
            let imagePage = model.document!.page(at: 0)!
            try model.addImage(asset, page: imagePage, at: pointer(imagePage, x: 10, y: 240), width: 100)
            let textPage = model.document!.page(at: 0)!
            try model.addText(phrase, note: false, page: textPage, at: pointer(textPage, x: 10, y: 120), fontSize: 22, color: .black)
            for pass in 1...3 {
                let entry = model.annotationEntries.first(where: { $0.annotation.contents == phrase })!
                try require(entry.annotation.font?.pointSize == 22, "Initial 22 pt survives image then text materialization")
                _ = try model.save()
                model = PDFWorkspaceModel(url: url)
                let reloaded = model.annotationEntries.first(where: { $0.annotation.contents == phrase })!
                try require(reloaded.annotation.font?.pointSize == 22, "22 pt persists at rotation \(rotation), save \(pass)")
                try requireTextGlyphsMatch(reloaded, phrase: phrase, label: "rotation \(rotation), save \(pass)")
                if rotation == 0 && pass == 1 {
                    try requireThrows("Glyph comparison rejects similarly sized garbled text") {
                        try requireTextGlyphsMatch(reloaded, phrase: "饰擞挫 RFH 食筏擞粮謗媵", label: "incorrect-glyph negative control")
                    }
                }
            }
        }
        print("PDF text appearance: Chinese/Latin glyph silhouettes match independently drawn bitmap after image insertion and three save/reopen cycles at all four rotations; initial 22 pt retained")
    }

    /// Compare rendered glyph shapes with AppKit's independent bitmap text renderer.
    /// Merely checking contents or counting colored pixels cannot detect wrong glyph IDs.
    private static func requireTextGlyphsMatch(_ entry: PDFAnnotationEntry, phrase: String, label: String) throws {
        guard let originalPage = entry.annotation.page, let page = originalPage.copy() as? PDFPage else {
            throw PDFWorkspaceError.message("Cannot copy text test page")
        }
        let document = PDFDocument(); document.insert(page, at: 0)
        page.setBounds(entry.annotation.bounds, for: .cropBox)
        let size = abs(page.rotation % 180) == 90
            ? NSSize(width: entry.annotation.bounds.height, height: entry.annotation.bounds.width)
            : entry.annotation.bounds.size
        let rendered = page.thumbnail(of: NSSize(width: size.width * 2, height: size.height * 2), for: .cropBox)
        let actual = NSBitmapImageRep(data: rendered.tiffRepresentation!)!
        let reference = NSImage(size: NSSize(width: actual.pixelsWide, height: actual.pixelsHigh), flipped: false) { rect in
            NSColor.white.setFill(); rect.fill()
            let context = NSGraphicsContext.current!.cgContext
            context.scaleBy(x: CGFloat(actual.pixelsWide) / size.width, y: CGFloat(actual.pixelsHigh) / size.height)
            NSAttributedString(string: phrase, attributes: [.font: NSFont(name: "PingFangSC-Regular", size: 22)!, .foregroundColor: NSColor.black])
                .draw(with: NSRect(origin: .zero, size: size).insetBy(dx: 4, dy: 4), options: [.usesLineFragmentOrigin, .usesFontLeading])
            return true
        }
        let expected = NSBitmapImageRep(data: reference.tiffRepresentation!)!
        func darkPixels(_ bitmap: NSBitmapImageRep) -> Set<Int> {
            var pixels = Set<Int>()
            for y in 0..<bitmap.pixelsHigh {
                for x in 0..<bitmap.pixelsWide {
                    if let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB),
                       color.redComponent + color.greenComponent + color.blueComponent < 1.5 {
                        pixels.insert(y * bitmap.pixelsWide + x)
                    }
                }
            }
            return pixels
        }
        let observed = darkPixels(actual), wanted = darkPixels(expected)
        try require(observed.count > 500 && wanted.count > 500, "Text has visible glyphs: \(label)")
        var bestOverlap = 0.0
        for dy in -8...8 {
            for dx in -6...6 {
                var overlap = 0
                for pixel in wanted {
                    let x = pixel % expected.pixelsWide + dx, y = pixel / expected.pixelsWide + dy
                    if x >= 0, x < actual.pixelsWide, y >= 0, y < actual.pixelsHigh,
                       observed.contains(y * actual.pixelsWide + x) { overlap += 1 }
                }
                bestOverlap = max(bestOverlap, Double(overlap) / Double(observed.count + wanted.count - overlap))
            }
        }
        // Outline/PDF and bitmap text rasterizers differ slightly in hinting,
        // especially after a 270° page transform; allow those edge pixels.
        try require(bestOverlap > 0.70, "Chinese/Latin rendered glyphs match reference (\(bestOverlap)): \(label)")
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
